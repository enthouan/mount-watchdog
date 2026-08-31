#!/bin/bash
set -e

TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH='' cd -- "$TEST_DIR/.." && pwd)

# shellcheck disable=SC1091
. "$TEST_DIR/lib/testlib.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/common.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/mountwatchdog-common.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    "${TMPDIR:-/tmp}"/mountwatchdog-common.*) /bin/rm -R "$TEST_TMP" ;;
    *) printf 'Refusing unsafe test cleanup: %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT HUP INT TERM

write_valid_config() {
  printf '# fictional fixture\n\nMedia\t/Users/testuser/Media\t192.0.2.10\tMedia\nStudio\t/Users/testuser/Studio\t192.0.2.10\tWorkspace\n' >"$1"
}

test_valid_config() {
  config=$TEST_TMP/valid.conf
  write_valid_config "$config"
  mw_parse_config "$config" || return 1
  [ "${#MW_MOUNT_NAMES[@]}" -eq 2 ] || return 1
  [ "${MW_MOUNT_NAMES[0]}" = Media ] || return 1
  [ "${MW_MOUNT_NAMES[1]}" = Studio ] || return 1
  [ "${MW_MOUNT_SHARES[1]}" = Workspace ] || return 1
  [ "$MW_CONFIG_LOCAL_USER" = testuser ] || return 1
}

test_safe_names_are_not_normalized() {
  mw_is_safe_name Media || return 1
  mw_is_safe_name Studio || return 1
  mw_is_safe_name Media_ || return 1
  [ Media = "$(printf '%s' Media)" ] || return 1
  ! mw_is_safe_name . || return 1
  ! mw_is_safe_name .. || return 1
  ! mw_is_safe_name _Media || return 1
  ! mw_is_safe_name 'Media/name' || return 1
  ! mw_is_safe_name 'Media name' || return 1
}

test_rejects_duplicate_case_collision() {
  config=$TEST_TMP/duplicate.conf
  printf 'Media\t/Users/testuser/Media\t192.0.2.10\tMedia\nmedia\t/Users/testuser/media\t192.0.2.10\tother\n' >"$config"
  ! mw_parse_config "$config" 2>"$TEST_TMP/error" || return 1
  /usr/bin/grep -q 'case-colliding' "$TEST_TMP/error" || return 1
}

test_rejects_wrong_path_and_user_mix() {
  config=$TEST_TMP/path.conf
  printf 'Media\t/Users/testuser/Other\t192.0.2.10\tMedia\n' >"$config"
  ! mw_parse_config "$config" >/dev/null 2>&1 || return 1
  printf 'Media\t/Users/testuser/Media\t192.0.2.10\tMedia\nStudio\t/Users/another/Studio\t192.0.2.10\tWorkspace\n' >"$config"
  ! mw_parse_config "$config" >/dev/null 2>&1 || return 1
}

test_rejects_bad_field_shapes() {
  config=$TEST_TMP/shape.conf
  printf 'Media\t/Users/testuser/Media\t192.0.2.10\n' >"$config"
  ! mw_parse_config "$config" >/dev/null 2>&1 || return 1
  printf 'Media\t/Users/testuser/Media\t192.0.2.10\tMedia\textra\n' >"$config"
  ! mw_parse_config "$config" >/dev/null 2>&1 || return 1
  printf 'Media\t\t192.0.2.10\tMedia\n' >"$config"
  ! mw_parse_config "$config" >/dev/null 2>&1 || return 1
}

test_rejects_unsupported_remote_syntax() {
  config=$TEST_TMP/remote.conf
  printf 'Media\t/Users/testuser/Media\t192.0.2.10:445\tMedia\n' >"$config"
  ! mw_parse_config "$config" >/dev/null 2>&1 || return 1
  printf 'Media\t/Users/testuser/Media\t192.0.2.10\tMedia/subdir\n' >"$config"
  ! mw_parse_config "$config" >/dev/null 2>&1 || return 1
  printf 'Media\t/Users/testuser/Media\tserver.-invalid.example\tMedia\n' >"$config"
  ! mw_parse_config "$config" >/dev/null 2>&1 || return 1
}

test_config_is_data_not_code() {
  config=$TEST_TMP/data.conf
  marker=$TEST_TMP/executed
  # shellcheck disable=SC2016
  printf 'Media\t/Users/testuser/Media\t$(touch %s)\tMedia\n' "$marker" >"$config"
  ! mw_parse_config "$config" >/dev/null 2>&1 || return 1
  assert_file_absent "$marker" || return 1
}

test_defaults_are_complete_and_strict() {
  mw_parse_defaults "$PROJECT_DIR/config/defaults.conf" || return 1
  [ "$MW_INTERVAL_SECONDS" -eq 60 ] || return 1
  [ "$MW_SCHEDULING_GAP_SECONDS" -eq 120 ] || return 1
  [ "$MW_RECOVERY_COOLDOWN_SECONDS" -eq 180 ] || return 1
  [ "$MW_COMMAND_TIMEOUT_SECONDS" -eq 20 ] || return 1

  defaults=$TEST_TMP/defaults.conf
  printf 'format|1|\ninterval_seconds|60\nscheduling_gap_seconds|120\nrecovery_cooldown_seconds|180\ncommand_timeout_seconds|20\n' >"$defaults"
  ! mw_parse_defaults "$defaults" >/dev/null 2>&1 || return 1

  printf 'format|1\ninterval_seconds|060\nscheduling_gap_seconds|0120\nrecovery_cooldown_seconds|0180\ncommand_timeout_seconds|020\n' >"$defaults"
  ! mw_parse_defaults "$defaults" >/dev/null 2>&1 || return 1
}

test_state_reader_rejects_extra_delimiter() {
  state=$TEST_TMP/status
  printf 'state|mounted-reachable|\n' >"$state"
  ! mw_state_value "$state" state >/dev/null 2>&1 || return 1
  printf 'state|mounted-reachable\n' >"$state"
  [ "$(mw_state_value "$state" state)" = mounted-reachable ] || return 1
}

test_config_parser_survives_bash32_nounset() {
  config=$TEST_TMP/nounset.conf
  write_valid_config "$config"
  /bin/bash -uc '. "$1"; mw_parse_config "$2"; [ "${MW_MOUNT_NAMES[0]}" = Media ] && [ "${MW_MOUNT_SHARES[1]}" = Workspace ]' \
    mountwatchdog-test "$PROJECT_DIR/lib/common.sh" "$config"
}

test_launchctl_disabled_parser_matches_literal_label() {
  disabled_output='disabled services = {
    "comXantoinemenardYmount-watchdog" => true
    "com.antoinemenard.mount-watchdog.extra" => true
    "com.antoinemenard.mount-watchdog" => false
  }'
  actual=$(printf '%s\n' "$disabled_output" | mw_launchctl_label_is_disabled 'com.antoinemenard.mount-watchdog')
  assert_eq 0 "$actual" 'near-collision launchd labels were treated as exact matches' || return 1

  disabled_output='disabled services = {
    "com.antoinemenard.mount-watchdog" => true,
  }'
  actual=$(printf '%s\n' "$disabled_output" | mw_launchctl_label_is_disabled 'com.antoinemenard.mount-watchdog')
  assert_eq 1 "$actual" 'exact disabled launchd label was not recognized' || return 1
}

run_test 'valid two-target config preserves Studio to Workspace mapping' test_valid_config
run_test 'safe names remain exact and unsafe names are rejected' test_safe_names_are_not_normalized
run_test 'case-colliding names are rejected' test_rejects_duplicate_case_collision
run_test 'path derivation and one-user rule are enforced' test_rejects_wrong_path_and_user_mix
run_test 'malformed and empty TSV fields are rejected' test_rejects_bad_field_shapes
run_test 'ports, subpaths, and invalid host labels are rejected' test_rejects_unsupported_remote_syntax
run_test 'configuration is parsed as inert data' test_config_is_data_not_code
run_test 'timing defaults are centralized and strict' test_defaults_are_complete_and_strict
run_test 'state records require exactly one delimiter' test_state_reader_rejects_extra_delimiter
run_test 'config parser handles first record under Bash 3.2 nounset' test_config_parser_survives_bash32_nounset
run_test 'launchd disabled-state parsing treats label punctuation literally' test_launchctl_disabled_parser_matches_literal_label

finish_tests
