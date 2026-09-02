#!/bin/bash

# Conservative MountWatchdog lifecycle/removal tool for macOS /bin/bash 3.2.
set -u
set +x
umask 077
PATH='/usr/bin:/bin:/usr/sbin:/sbin'
export PATH
LC_ALL=C
export LC_ALL

MW_LABEL='com.antoinemenard.mount-watchdog'
MW_APP='/Library/Application Support/MountWatchdog'
MW_PLIST="/Library/LaunchDaemons/$MW_LABEL.plist"
MW_LOG='/var/log/mount-watchdog.log'

mw_uninstaller_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || {
  printf 'MountWatchdog: cannot resolve uninstaller directory\n' >&2
  exit 1
}
mw_bootstrap_euid=${EUID:-$(/usr/bin/id -u)}
mw_bootstrap_sudo_uid=
case "${SUDO_UID:-}" in
  ''|*[!0-9]*) ;;
  *)
    if [ "$mw_bootstrap_euid" -eq 0 ] && [ "$SUDO_UID" -gt 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != root ] && \
      [ "$(/usr/bin/id -u "$SUDO_USER" 2>/dev/null)" = "$SUDO_UID" ]; then
      mw_bootstrap_sudo_uid=$SUDO_UID
    fi
    ;;
esac
mw_bootstrap_acl_is_deny_only() {
  mw_bootstrap_acl_path=$1
  if /bin/chmod -C "$mw_bootstrap_acl_path" >/dev/null 2>&1; then
    return 1
  fi
  mw_bootstrap_acl_output=$(/bin/ls -lde "$mw_bootstrap_acl_path" 2>/dev/null) || return 1
  printf '%s\n' "$mw_bootstrap_acl_output" | /usr/bin/awk '
    NR == 1 { header_seen = 1; next }
    { if ($1 !~ /^[0-9]+:$/ || NF < 4 || $(NF - 1) != "deny") exit 1 }
    END { if (!header_seen) exit 1 }
  '
}
mw_repo_node_is_trusted() {
  mw_repo_node=$1
  mw_repo_type=$2
  [ ! -L "$mw_repo_node" ] || return 1
  case "$mw_repo_type" in
    file) [ -f "$mw_repo_node" ] || return 1 ;;
    directory) [ -d "$mw_repo_node" ] || return 1 ;;
    *) return 1 ;;
  esac
  if /usr/bin/stat -f '%u' "$mw_repo_node" >/dev/null 2>&1; then
    mw_repo_uid=$(/usr/bin/stat -f '%u' "$mw_repo_node") || return 1
    mw_repo_mode=$(/usr/bin/stat -f '%Lp' "$mw_repo_node") || return 1
  else
    mw_repo_uid=$(/usr/bin/stat -c '%u' "$mw_repo_node") || return 1
    mw_repo_mode=$(/usr/bin/stat -c '%a' "$mw_repo_node") || return 1
  fi
  [ "$mw_repo_uid" -eq 0 ] || [ "$mw_repo_uid" -eq "$mw_bootstrap_euid" ] || \
    { [ -n "$mw_bootstrap_sudo_uid" ] && [ "$mw_repo_uid" -eq "$mw_bootstrap_sudo_uid" ]; } || return 1
  mw_repo_mode_value=$((8#$mw_repo_mode))
  [ $((mw_repo_mode_value & 18)) -eq 0 ] && mw_bootstrap_acl_is_deny_only "$mw_repo_node"
}
mw_repo_file_is_trusted() {
  mw_repo_file=$1
  case "$mw_repo_file" in "$mw_uninstaller_dir"/*) ;; *) return 1 ;; esac
  mw_repo_node_is_trusted "$mw_repo_file" file || return 1
  mw_repo_parent=$(dirname -- "$mw_repo_file")
  while :; do
    mw_repo_node_is_trusted "$mw_repo_parent" directory || return 1
    [ "$mw_repo_parent" != "$mw_uninstaller_dir" ] || break
    case "$mw_repo_parent" in "$mw_uninstaller_dir"/*) ;; *) return 1 ;; esac
    mw_repo_parent=$(dirname -- "$mw_repo_parent")
  done
}
mw_repo_directory_chain_is_trusted() {
  mw_repo_ancestor=$1
  while :; do
    mw_repo_node_is_trusted "$mw_repo_ancestor" directory || return 1
    [ "$mw_repo_ancestor" != / ] || break
    mw_repo_ancestor=$(dirname -- "$mw_repo_ancestor")
  done
}
mw_repo_directory_chain_is_trusted "$mw_uninstaller_dir" || {
  printf 'MountWatchdog: uninstaller directory ancestor ownership or mode is unsafe\n' >&2
  exit 1
}
mw_uninstaller_source="$mw_uninstaller_dir/$(basename -- "${BASH_SOURCE[0]}")"
mw_repo_file_is_trusted "$mw_uninstaller_source" || {
  printf 'MountWatchdog: uninstaller source ownership or mode is unsafe\n' >&2
  exit 1
}
mw_repo_file_is_trusted "$mw_uninstaller_dir/lib/common.sh" || {
  printf 'MountWatchdog: common library is missing or untrusted\n' >&2
  exit 1
}
# shellcheck source=lib/common.sh
. "$mw_uninstaller_dir/lib/common.sh" || exit 1

mw_usage() {
  cat <<'EOF'
Usage:
  sudo /bin/bash ./uninstall_mount_watchdog.sh [--dry-run] stop
  sudo /bin/bash ./uninstall_mount_watchdog.sh [--dry-run] disable
  sudo /bin/bash ./uninstall_mount_watchdog.sh [--dry-run] remove
  sudo /bin/bash ./uninstall_mount_watchdog.sh [--dry-run] rollback BACKUP_ID

Options:
  --dry-run            Show the validated action without changing files/jobs.
  --staging-root DIR   Nonprivileged test root; never live '/'.
  -h, --help           Show help.

stop affects the current boot only. disable records a future-boot launchd
override and stops the job. remove disables/stops the job and removes manifest-
owned program artifacts. Backups, logs, autofs maps, mountpoints, and NAS
content are always preserved.
rollback accepts only one protected install-backup directory name, verifies its
manifest and content hashes against the current maintained install, and restores
the exact prior canonical service policy.
Before the protected commit boundary, catchable HUP, INT, TERM, and QUIT
signals and unexpected shell exits trigger transaction rollback. SIGKILL cannot
be caught and is outside that guarantee.
EOF
}

mw_mode=
mw_backup_id=
mw_root=
mw_dry_run=0
mw_transaction_phase=none
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) mw_dry_run=1; shift ;;
    --staging-root) [ "$#" -ge 2 ] || { mw_usage >&2; exit 2; }; mw_root=$2; shift 2 ;;
    -h|--help) mw_usage; exit 0 ;;
    stop|disable|remove) [ -z "$mw_mode" ] || { printf 'MountWatchdog: choose one mode\n' >&2; exit 2; }; mw_mode=$1; shift ;;
    rollback)
      [ -z "$mw_mode" ] || { printf 'MountWatchdog: choose one mode\n' >&2; exit 2; }
      [ "$#" -ge 2 ] || { printf 'MountWatchdog: rollback requires one BACKUP_ID\n' >&2; mw_usage >&2; exit 2; }
      mw_mode=rollback
      mw_backup_id=$2
      shift 2
      ;;
    *) printf 'MountWatchdog: unknown argument: %s\n' "$1" >&2; mw_usage >&2; exit 2 ;;
  esac
done
[ -n "$mw_mode" ] || { mw_usage >&2; exit 2; }
if [ "$mw_mode" = rollback ]; then
  mw_is_safe_name "$mw_backup_id" || { printf 'MountWatchdog: rollback BACKUP_ID is unsafe\n' >&2; exit 2; }
fi

mw_die() { printf 'MountWatchdog: %s\n' "$*" >&2; exit 1; }
if [ -n "$mw_root" ]; then
  [ "${EUID:-$(/usr/bin/id -u)}" -ne 0 ] || mw_die '--staging-root is forbidden when running as root'
  case "$mw_root" in /*) ;; *) mw_die '--staging-root must be absolute' ;; esac
  [ -d "$mw_root" ] && [ ! -L "$mw_root" ] || mw_die '--staging-root must be an existing non-symlink directory'
  mw_root=$(CDPATH='' cd -- "$mw_root" 2>/dev/null && pwd -P) || mw_die 'cannot canonicalize --staging-root'
  case "$mw_root" in /|/System|/Library|/usr|/etc|/private|/var|/Users) mw_die 'refusing unsafe --staging-root' ;; esac
else
  [ "$(/usr/bin/uname -s)" = Darwin ] || mw_die 'live removal is supported only on macOS'
  [ "$mw_dry_run" -eq 1 ] || [ "${EUID:-$(/usr/bin/id -u)}" -eq 0 ] || mw_die 'live lifecycle changes must run as root (dry-run does not)'
fi

mw_dest() {
  case "$1" in /*) ;; *) return 1 ;; esac
  if [ -n "$mw_root" ]; then printf '%s%s\n' "$mw_root" "$1"; else printf '%s\n' "$1"; fi
}

mw_check_path() {
  [ ! -L "$1" ] || return 1
  if [ -z "$mw_root" ]; then
    mw_current=$1
    while [ "$mw_current" != / ]; do
      [ ! -L "$mw_current" ] || return 1
      mw_current=$(dirname -- "$mw_current")
    done
    return 0
  fi
  case "$1" in "$mw_root"/*) ;; *) return 1 ;; esac
  mw_rel=${1#"$mw_root"/}
  mw_current=$mw_root
  mw_old_ifs=$IFS
  IFS=/
  set -f
  # shellcheck disable=SC2086 # Intentional slash-delimited component split.
  set -- $mw_rel
  set +f
  IFS=$mw_old_ifs
  for mw_component in "$@"; do
    [ -n "$mw_component" ] || continue
    mw_current=$mw_current/$mw_component
    [ ! -L "$mw_current" ] || return 1
  done
}

mw_stat_mode() {
  if /usr/bin/stat -f '%Lp' "$1" >/dev/null 2>&1; then /usr/bin/stat -f '%Lp' "$1"; else /usr/bin/stat -c '%a' "$1"; fi
}
mw_stat_uid() {
  if /usr/bin/stat -f '%u' "$1" >/dev/null 2>&1; then /usr/bin/stat -f '%u' "$1"; else /usr/bin/stat -c '%u' "$1"; fi
}
mw_stat_gid() {
  if /usr/bin/stat -f '%g' "$1" >/dev/null 2>&1; then /usr/bin/stat -f '%g' "$1"; else /usr/bin/stat -c '%g' "$1"; fi
}
mw_stat_nlink() {
  if /usr/bin/stat -f '%l' "$1" >/dev/null 2>&1; then /usr/bin/stat -f '%l' "$1"; else /usr/bin/stat -c '%h' "$1"; fi
}
mw_file_sha() {
  if [ -n "$mw_root" ]; then
    case "${MOUNTWATCHDOG_TEST_SHASUM_BEHAVIOR:-}" in
      fail) return 1 ;;
      malformed) mw_sha_output='NOT-A-LOWERCASE-SHA256  injected' ;;
      '') mw_sha_output=$(/usr/bin/shasum -a 256 "$1" 2>/dev/null) || return 1 ;;
      *) return 1 ;;
    esac
  else
    mw_sha_output=$(/usr/bin/shasum -a 256 "$1" 2>/dev/null) || return 1
  fi
  mw_sha_newline=$(printf '\nX'); mw_sha_newline=${mw_sha_newline%X}
  case "$mw_sha_output" in *"$mw_sha_newline"*) return 1 ;; esac
  mw_sha_digest=${mw_sha_output%% *}
  [ "${#mw_sha_digest}" -eq 64 ] || return 1
  case "$mw_sha_digest" in *[!0-9a-f]*) return 1 ;; esac
  mw_sha_remainder=${mw_sha_output#"$mw_sha_digest"}
  case "$mw_sha_remainder" in '  '?*) ;; *) return 1 ;; esac
  printf '%s\n' "$mw_sha_digest"
}
mw_live_safe_owned() {
  [ -e "$1" ] || return 0
  [ ! -L "$1" ] && [ "$(mw_stat_uid "$1")" -eq 0 ] || return 1
  mw_owned_mode=$((8#$(mw_stat_mode "$1")))
  [ $((mw_owned_mode & 18)) -eq 0 ] && mw_acl_policy_is_safe "$1" deny-only
}
mw_live_safe_parent_chain() {
  mw_chain_current=$(dirname -- "$1")
  while [ "$mw_chain_current" != / ]; do
    [ -d "$mw_chain_current" ] && [ ! -L "$mw_chain_current" ] || return 1
    mw_live_safe_owned "$mw_chain_current" || return 1
    mw_chain_current=$(dirname -- "$mw_chain_current")
  done
}

mw_record_action() {
  [ -n "$mw_root" ] || return 0
  [ -n "${MOUNTWATCHDOG_TEST_ACTION_LOG:-}" ] || return 0
  mw_action_parent=$(CDPATH='' cd -- "$(dirname -- "$MOUNTWATCHDOG_TEST_ACTION_LOG")" 2>/dev/null && pwd -P) || return 1
  mw_action_log="$mw_action_parent/$(basename -- "$MOUNTWATCHDOG_TEST_ACTION_LOG")"
  case "$mw_action_log" in "$mw_root"/*) ;; *) return 1 ;; esac
  mw_check_path "$mw_action_log" || return 1
  if [ -e "$mw_action_log" ]; then
    [ -f "$mw_action_log" ] && [ "$(mw_stat_nlink "$mw_action_log")" -eq 1 ] || return 1
  fi
  printf '%s\n' "$*" >> "$mw_action_log"
}
mw_test_fail() { [ -n "$mw_root" ] && [ "${MOUNTWATCHDOG_TEST_UNINSTALL_FAIL_AT:-}" = "$1" ]; }
mw_test_unhandled_exit() {
  [ -n "$mw_root" ] && [ "${MOUNTWATCHDOG_TEST_UNHANDLED_EXIT_AT:-}" = "$1" ] || return 0
  return 73
}
mw_test_signal_self() {
  mw_test_signal_kind=${MOUNTWATCHDOG_TEST_SIGNAL_KIND:-TERM}
  case "$mw_test_signal_kind" in TERM|QUIT) ;; *) return 1 ;; esac
  kill -"$mw_test_signal_kind" "$$"
}

mw_test_actual_loaded=${MOUNTWATCHDOG_TEST_LOADED:-0}
mw_launchctl_job_state() {
  mw_state_context=$1
  if [ -n "$mw_root" ]; then
    if [ "${MOUNTWATCHDOG_TEST_LAUNCHCTL_UNKNOWN_AT:-}" = "$mw_state_context" ]; then
      printf 'unknown\n'
      return 0
    fi
    case "$mw_test_actual_loaded" in
      1) printf 'loaded\n' ;;
      0) printf 'unloaded\n' ;;
      *) printf 'unknown\n' ;;
    esac
    return 0
  fi
  mw_state_output=$(/bin/launchctl print "system/$MW_LABEL" 2>&1)
  mw_state_status=$?
  if [ "$mw_state_status" -eq 0 ]; then
    printf 'loaded\n'
    return 0
  fi
  mw_state_not_found=$(printf 'Bad request.\nCould not find service "%s" in domain for system' "$MW_LABEL")
  if [ "$mw_state_status" -eq 113 ] && [ "$mw_state_output" = "$mw_state_not_found" ]; then
    printf 'unloaded\n'
  else
    printf 'unknown\n'
  fi
}

mw_validate_loaded_job_identity() {
  mw_identity_label=$1
  mw_identity_path=$2
  mw_identity_program=$3
  mw_identity_argc=$4
  mw_identity_arg0=$5
  mw_identity_arg1=${6:-}
  if [ -n "$mw_root" ]; then
    case "${MOUNTWATCHDOG_TEST_LOADED_IDENTITY_MISMATCH:-}" in
      '') return 0 ;;
      canonical) return 1 ;;
      *) return 1 ;;
    esac
  fi
  mw_identity_output=$(/bin/launchctl print "system/$mw_identity_label" 2>/dev/null) || return 1
  printf '%s\n' "$mw_identity_output" | /usr/bin/awk \
    -v expected_path="$mw_identity_path" \
    -v expected_program="$mw_identity_program" \
    -v expected_argc="$mw_identity_argc" \
    -v expected_arg0="$mw_identity_arg0" \
    -v expected_arg1="$mw_identity_arg1" '
      function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        return value
      }
      {
        line = trim($0)
        if (in_arguments) {
          if (line == "}") {
            in_arguments = 0
            next
          }
          if (line != "") {
            arguments[argument_count] = line
            argument_count++
          }
          next
        }
        if (line == "arguments = {") {
          arguments_seen++
          in_arguments = 1
          next
        }
        if (index(line, "path = ") == 1) {
          path_seen++
          actual_path = substr(line, 8)
          next
        }
        if (index(line, "program = ") == 1) {
          program_seen++
          actual_program = substr(line, 11)
        }
      }
      END {
        valid = path_seen == 1 && program_seen == 1 && arguments_seen == 1 && !in_arguments
        valid = valid && actual_path == expected_path && actual_program == expected_program
        valid = valid && argument_count == expected_argc && arguments[0] == expected_arg0
        if (expected_argc == 2) valid = valid && arguments[1] == expected_arg1
        exit valid ? 0 : 1
      }
    '
}

mw_lock_held=0
mw_lock_exempt=0
mw_lock_path=
mw_release_lifecycle_lock() {
  [ "$mw_lock_held" -eq 1 ] || return 0
  if [ -n "$mw_root" ]; then
    [ "$mw_lock_path" = "$mw_root/.mountwatchdog-lifecycle.lock" ] || return 1
  else
    [ "$mw_lock_path" = /private/var/db/MountWatchdog.lifecycle.lock ] || return 1
    [ -d "$mw_lock_path" ] && [ ! -L "$mw_lock_path" ] || return 1
    [ "$(mw_stat_uid "$mw_lock_path")" -eq 0 ] && [ "$(mw_stat_mode "$mw_lock_path")" = 700 ] || return 1
    mw_acl_policy_is_safe "$mw_lock_path" none || return 1
  fi
  [ -d "$mw_lock_path" ] && [ ! -L "$mw_lock_path" ] || return 1
  /bin/rmdir "$mw_lock_path" || return 1
  mw_lock_held=0
}
mw_acquire_lifecycle_lock() {
  if [ "$mw_dry_run" -eq 1 ]; then
    mw_lock_exempt=1
    return 0
  fi
  if [ -n "$mw_root" ]; then
    mw_lock_path="$mw_root/.mountwatchdog-lifecycle.lock"
    mw_check_path "$mw_lock_path" || return 1
  else
    mw_lock_path=/private/var/db/MountWatchdog.lifecycle.lock
    [ -d /private/var/db ] && [ ! -L /private/var/db ] || return 1
    mw_live_safe_owned /private/var/db || return 1
  fi
  trap '' HUP INT TERM QUIT
  if ! /bin/mkdir -m 700 "$mw_lock_path" 2>/dev/null; then
    trap 'mw_die "lifecycle operation interrupted"' HUP INT TERM QUIT
    return 1
  fi
  mw_strip_acl_from_new_node "$mw_lock_path" || { /bin/rmdir "$mw_lock_path" 2>/dev/null || true; return 1; }
  mw_lock_held=1
  trap 'mw_release_lifecycle_lock' EXIT
  if [ -z "$mw_root" ]; then
    /usr/sbin/chown root:wheel "$mw_lock_path" || return 1
    [ "$(mw_stat_uid "$mw_lock_path")" -eq 0 ] && [ "$(mw_stat_mode "$mw_lock_path")" = 700 ] || return 1
  fi
  trap 'mw_die "lifecycle operation interrupted"' HUP INT TERM QUIT
}
mw_acquire_lifecycle_lock || mw_die 'lifecycle operation lock is busy, stale, or unsafe; inspect it before retrying'

MW_ALLOWED=(
  "$MW_APP/watchdog.sh" "$MW_APP/status.sh" "$MW_APP/lib/common.sh"
  "$MW_APP/lib/runtime.sh" "$MW_APP/lib/autofs.sh" "$MW_APP/defaults.conf" "$MW_APP/mounts.conf"
  "$MW_APP/VERSION" "$MW_PLIST"
)
MW_REMOVE=()
mw_manifest=$(mw_dest "$MW_APP/install-manifest.tsv") || mw_die 'cannot resolve installed manifest'
mw_app=$(mw_dest "$MW_APP") || mw_die 'cannot resolve installed app dir'
mw_check_path "$mw_app" || mw_die 'unsafe installed app path'
mw_check_path "$mw_manifest" || mw_die 'unsafe installed manifest path'
[ -d "$mw_app" ] && [ ! -L "$mw_app" ] || mw_die 'installed app directory is missing or unsafe'
[ -f "$mw_manifest" ] && [ ! -L "$mw_manifest" ] || mw_die 'owned install manifest is missing or unsafe; refusing lifecycle action'
[ "$(mw_stat_mode "$mw_app")" = 700 ] || mw_die 'installed app directory mode is not 0700'
mw_acl_policy_is_safe "$mw_app" none || mw_die 'installed app directory has an ACL'
mw_acl_policy_is_safe "$mw_manifest" none || mw_die 'installed manifest has an ACL'
if [ -z "$mw_root" ]; then
  mw_live_safe_parent_chain "$mw_manifest" || mw_die 'installed manifest parent chain is unsafe'
  mw_live_safe_owned "$mw_app" || mw_die 'installed app directory is not safely root-owned'
  mw_live_safe_owned "$mw_manifest" || mw_die 'installed manifest is not safely root-owned'
fi

mw_manifest_format_seen=0
mw_manifest_version_seen=0
mw_tab=$(printf '\tX'); mw_tab=${mw_tab%X}
while IFS="$mw_tab" read -r mw_kind mw_a mw_b mw_extra; do
  case "$mw_kind" in
    format)
      [ "$mw_a" = 1 ] && [ -z "$mw_b" ] && [ -z "$mw_extra" ] && [ "$mw_manifest_format_seen" -eq 0 ] || mw_die 'installed manifest has invalid format metadata'
      mw_manifest_format_seen=1
      ;;
    version)
      case "$mw_a" in ''|*[!A-Za-z0-9._-]*) mw_die 'installed manifest has an unsafe version' ;; esac
      [ -z "$mw_b" ] && [ -z "$mw_extra" ] && [ "$mw_manifest_version_seen" -eq 0 ] || mw_die 'installed manifest has invalid version metadata'
      mw_manifest_version_seen=1
      ;;
    file)
      [ -n "$mw_a" ] && [ "${#mw_b}" -eq 64 ] && [ -z "$mw_extra" ] || mw_die 'installed manifest has a malformed file record'
      case "$mw_b" in *[!0-9a-f]*) mw_die 'installed manifest has an invalid checksum' ;; esac
      mw_array_contains "$mw_a" "${MW_ALLOWED[@]}" || mw_die "manifest contains a non-allowlisted path: $mw_a"
      if [ "${#MW_REMOVE[@]}" -gt 0 ] && mw_array_contains "$mw_a" "${MW_REMOVE[@]}"; then
        mw_die "duplicate manifest path: $mw_a"
      fi
      MW_REMOVE[${#MW_REMOVE[@]}]=$mw_a
      mw_physical=$(mw_dest "$mw_a") || mw_die 'manifest path resolution failed'
      mw_check_path "$mw_physical" || mw_die "unsafe owned path: $mw_a"
      [ -n "$mw_root" ] || mw_live_safe_parent_chain "$mw_physical" || mw_die "unsafe owned parent chain: $mw_a"
      if [ -e "$mw_physical" ] || [ -L "$mw_physical" ]; then
        [ -f "$mw_physical" ] && [ ! -L "$mw_physical" ] || mw_die "owned path is not a regular file: $mw_a"
        mw_acl_policy_is_safe "$mw_physical" none || mw_die "owned path has an ACL: $mw_a"
        [ -n "$mw_root" ] || mw_live_safe_owned "$mw_physical" || mw_die "owned path is not safely root-owned: $mw_a"
        mw_current_sha=$(mw_file_sha "$mw_physical") || mw_die "cannot hash owned path: $mw_a"
        [ "$mw_current_sha" = "$mw_b" ] || mw_die "owned file was modified; preserve and inspect it: $mw_a"
      fi
      ;;
    *) mw_die 'installed manifest contains an unknown record' ;;
  esac
done < "$mw_manifest"
[ "$mw_manifest_format_seen" -eq 1 ] && [ "$mw_manifest_version_seen" -eq 1 ] || mw_die 'installed manifest metadata is incomplete'
[ "${#MW_REMOVE[@]}" -eq "${#MW_ALLOWED[@]}" ] || mw_die 'installed manifest is incomplete; refusing lifecycle action'

mw_plist=$(mw_dest "$MW_PLIST") || mw_die 'cannot resolve canonical plist'
[ -f "$mw_plist" ] && [ ! -L "$mw_plist" ] || mw_die 'validated canonical plist is required for lifecycle actions'
mw_acl_policy_is_safe "$mw_plist" none || mw_die 'canonical plist has an ACL'
[ -x /usr/libexec/PlistBuddy ] || mw_die 'PlistBuddy is required for canonical plist identity validation'
/usr/bin/plutil -lint "$mw_plist" >/dev/null 2>&1 || mw_die 'canonical plist is malformed'
mw_plist_keys=$(/usr/bin/plutil -convert xml1 -o - "$mw_plist" 2>/dev/null | \
  /usr/bin/sed -n 's/^[[:space:]]*<key>\([^<]*\)<\/key>[[:space:]]*$/\1/p' | /usr/bin/sort)
mw_expected_keys=$(printf '%s\n' Label ProgramArguments RunAtLoad StandardErrorPath StandardOutPath StartInterval WorkingDirectory | /usr/bin/sort)
[ "$mw_plist_keys" = "$mw_expected_keys" ] || mw_die 'canonical plist has unexpected keys'
[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$mw_plist" 2>/dev/null)" = "$MW_LABEL" ] || mw_die 'canonical plist label is unexpected'
[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$mw_plist" 2>/dev/null)" = /bin/bash ] || mw_die 'canonical plist program is unexpected'
[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$mw_plist" 2>/dev/null)" = "$MW_APP/watchdog.sh" ] || mw_die 'canonical plist runtime target is unexpected'
/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$mw_plist" >/dev/null 2>&1 && mw_die 'canonical plist has unexpected program arguments'
[ "$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$mw_plist" 2>/dev/null)" = true ] || mw_die 'canonical plist RunAtLoad policy is unexpected'
mw_plist_interval=$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$mw_plist" 2>/dev/null) || mw_die 'canonical plist interval is missing'
mw_is_uint "$mw_plist_interval" && [ "$mw_plist_interval" -ge 10 ] && [ "$mw_plist_interval" -le 3600 ] || mw_die 'canonical plist interval is unsafe'
[ "$(/usr/libexec/PlistBuddy -c 'Print :WorkingDirectory' "$mw_plist" 2>/dev/null)" = / ] || mw_die 'canonical plist working directory is unexpected'
[ "$(/usr/libexec/PlistBuddy -c 'Print :StandardOutPath' "$mw_plist" 2>/dev/null)" = "$MW_LOG" ] || mw_die 'canonical plist stdout path is unexpected'
[ "$(/usr/libexec/PlistBuddy -c 'Print :StandardErrorPath' "$mw_plist" 2>/dev/null)" = "$MW_LOG" ] || mw_die 'canonical plist stderr path is unexpected'

mw_loaded=0
mw_disabled=0
mw_prior_state=$(mw_launchctl_job_state canonical-initial)
case "$mw_prior_state" in
  loaded) mw_loaded=1 ;;
  unloaded) mw_loaded=0 ;;
  *) mw_die 'cannot reliably inspect canonical launchd state' ;;
esac
if [ -n "$mw_root" ]; then
  mw_disabled=${MOUNTWATCHDOG_TEST_DISABLED:-0}
else
  mw_disabled_output=$(/bin/launchctl print-disabled system 2>&1) || mw_die 'cannot inspect launchd disabled state'
  mw_disabled_match=$(printf '%s\n' "$mw_disabled_output" | mw_launchctl_label_is_disabled "$MW_LABEL")
  [ "$mw_disabled_match" = 1 ] && mw_disabled=1
fi
if [ "$mw_loaded" -eq 1 ]; then
  mw_validate_loaded_job_identity "$MW_LABEL" "$MW_PLIST" /bin/bash 2 /bin/bash "$MW_APP/watchdog.sh" || \
    mw_die 'loaded canonical job does not match the exact on-disk plist path and program arguments'
fi
mw_current_state=$mw_prior_state

mw_bootout() {
  mw_record_action "bootout system/$MW_LABEL" || return 1
  mw_current_state=unknown
  if [ -n "$mw_root" ]; then
    if [ "${MOUNTWATCHDOG_TEST_BOOTOUT_FAIL_BEFORE_EFFECT:-0}" = 1 ]; then
      mw_current_state=$(mw_launchctl_job_state canonical-after-bootout-failure)
      return 1
    fi
    mw_test_actual_loaded=0
    if [ "${MOUNTWATCHDOG_TEST_BOOTOUT_FAIL_AFTER_EFFECT:-0}" = 1 ]; then
      mw_current_state=$(mw_launchctl_job_state canonical-after-bootout-failure)
      return 1
    fi
    mw_current_state=unloaded
    return 0
  fi
  if /bin/launchctl bootout "system/$MW_LABEL"; then
    mw_current_state=unloaded
    return 0
  fi
  mw_current_state=$(mw_launchctl_job_state canonical-after-bootout-failure)
  return 1
}
mw_bootstrap_job() {
  mw_bootstrap_plist=$(mw_dest "$MW_PLIST") || return 1
  mw_record_action "bootstrap system $mw_bootstrap_plist" || return 1
  mw_current_state=unknown
  if [ -n "$mw_root" ]; then
    if [ "${MOUNTWATCHDOG_TEST_BOOTSTRAP_FAIL_BEFORE_EFFECT:-0}" = 1 ]; then
      mw_current_state=$(mw_launchctl_job_state canonical-after-bootstrap-failure)
      return 1
    fi
    mw_test_actual_loaded=1
    if [ "${MOUNTWATCHDOG_TEST_BOOTSTRAP_FAIL_AFTER_EFFECT:-0}" = 1 ]; then
      mw_current_state=$(mw_launchctl_job_state canonical-after-bootstrap-failure)
      return 1
    fi
    mw_current_state=loaded
    return 0
  fi
  if /bin/launchctl bootstrap system "$mw_bootstrap_plist"; then
    mw_current_state=loaded
    return 0
  fi
  mw_current_state=$(mw_launchctl_job_state canonical-after-bootstrap-failure)
  return 1
}
mw_disable_job() {
  mw_record_action "disable system/$MW_LABEL" || return 1
  if [ -n "$mw_root" ]; then
    [ "${MOUNTWATCHDOG_TEST_DISABLE_FAIL_AFTER_EFFECT:-0}" != 1 ] || return 1
    return 0
  fi
  /bin/launchctl disable "system/$MW_LABEL"
}
mw_enable_job() {
  mw_record_action "enable system/$MW_LABEL" || return 1
  [ -n "$mw_root" ] && return 0
  /bin/launchctl enable "system/$MW_LABEL"
}

mw_restore_prior_enable_policy() {
  if [ "$mw_disabled" -eq 1 ]; then
    mw_disable_job
  else
    mw_enable_job
  fi
}

mw_restore_prior_service_state() {
  mw_current_state=$(mw_launchctl_job_state canonical-restore)
  [ "$mw_current_state" != unknown ] || return 1

  if [ "$mw_loaded" -eq 1 ]; then
    if [ "$mw_current_state" = unloaded ]; then
      mw_enable_job || return 1
      mw_bootstrap_job || return 1
    fi
  elif [ "$mw_current_state" = loaded ]; then
    mw_bootout || return 1
  fi
  mw_restore_prior_enable_policy
}

mw_prove_service_unloaded() {
  mw_current_state=$(mw_launchctl_job_state canonical-remove-rollback)
  if [ "$mw_current_state" = unloaded ]; then return 0; fi
  mw_bootout >/dev/null 2>&1 || true
  [ "$mw_current_state" = unloaded ]
}

mw_quiesce_service_after_incomplete_rollback() {
  mw_bootout >/dev/null 2>&1 || true
  mw_disable_job >/dev/null 2>&1 || true
}

mw_replace_rollback_file() {
  mw_restore_source=$1
  mw_restore_target=$2
  mw_restore_mode=$3
  mw_restore_uid=$4
  mw_restore_gid=$5
  mw_restore_parent=$(dirname -- "$mw_restore_target")
  [ -d "$mw_restore_parent" ] && [ ! -L "$mw_restore_parent" ] || return 1
  case "$mw_restore_parent" in
    "$mw_app"|"$mw_app"/*) mw_acl_policy_is_safe "$mw_restore_parent" none || return 1 ;;
    *) mw_acl_policy_is_safe "$mw_restore_parent" deny-only || return 1 ;;
  esac
  mw_check_path "$mw_restore_target" || return 1
  [ -n "$mw_root" ] || mw_live_safe_parent_chain "$mw_restore_target" || return 1
  [ ! -L "$mw_restore_target" ] || return 1
  mw_restore_tmp=$(/usr/bin/mktemp "$mw_restore_target.rollback.XXXXXX") || return 1
  /bin/cp "$mw_restore_source" "$mw_restore_tmp" || { /bin/rm -f "$mw_restore_tmp"; return 1; }
  mw_strip_acl_from_new_node "$mw_restore_tmp" || { /bin/rm -f "$mw_restore_tmp"; return 1; }
  /bin/chmod "$mw_restore_mode" "$mw_restore_tmp" || { /bin/rm -f "$mw_restore_tmp"; return 1; }
  if [ -z "$mw_root" ]; then
    /usr/sbin/chown "$mw_restore_uid:$mw_restore_gid" "$mw_restore_tmp" || { /bin/rm -f "$mw_restore_tmp"; return 1; }
  fi
  /bin/mv -f "$mw_restore_tmp" "$mw_restore_target" || { /bin/rm -f "$mw_restore_tmp"; return 1; }
}

mw_record_removal_rollback_result() {
  mw_removal_rollback_result=$1
  if [ -n "$mw_root" ] && [ "$mw_removal_rollback_result" = rolled-back ] &&
    [ "${MOUNTWATCHDOG_TEST_FAIL_ROLLBACK_MARKER:-0}" = 1 ]; then
    return 1
  fi
  printf 'result\t%s\n' "$mw_removal_rollback_result" >> "$mw_backup_manifest"
}

mw_abort_lifecycle() {
  mw_lifecycle_message=$1
  mw_transaction_phase=none
  trap '' HUP INT TERM QUIT
  if [ -n "$mw_root" ] && [ "${MOUNTWATCHDOG_TEST_SIGNAL_DURING_ROLLBACK:-0}" = 1 ]; then
    mw_test_signal_self || true
  fi
  if mw_restore_prior_service_state; then
    printf 'MountWatchdog: %s; prior service state restored\n' "$mw_lifecycle_message" >&2
  else
    mw_quiesce_service_after_incomplete_rollback
    printf 'MountWatchdog: %s; service-state rollback incomplete\n' "$mw_lifecycle_message" >&2
  fi
  mw_release_lifecycle_lock || printf 'MountWatchdog: lifecycle lock release failed; inspect %s\n' "$mw_lock_path" >&2
  exit 1
}

mw_abort_post_success_rollback() {
  mw_rollback_message=$1
  mw_transaction_phase=none
  trap '' HUP INT TERM QUIT
  mw_quiesce_service_after_incomplete_rollback
  if [ -n "${mw_rollback_manifest:-}" ]; then
    printf 'post_success_rollback\tincomplete\n' >> "$mw_rollback_manifest" 2>/dev/null || true
  fi
  printf 'MountWatchdog: %s; rollback incomplete, the affected job remains stopped and disabled; retain %s\n' \
    "$mw_rollback_message" "${mw_rollback_backup:-unknown}" >&2
  mw_release_lifecycle_lock || printf 'MountWatchdog: lifecycle lock release failed; inspect %s\n' "$mw_lock_path" >&2
  exit 1
}

mw_transaction_exit_handler() {
  mw_exit_status=$?
  trap - EXIT
  trap '' HUP INT TERM QUIT
  case "${mw_transaction_phase:-none}" in
    lifecycle) mw_abort_lifecycle 'unexpected lifecycle exit' ;;
    remove) mw_abort_remove 'unexpected removal exit' ;;
    post-success-rollback) mw_abort_post_success_rollback 'unexpected post-success rollback exit' ;;
  esac
  if ! mw_release_lifecycle_lock; then
    printf 'MountWatchdog: lifecycle lock release failed; inspect %s\n' "${mw_lock_path:-unknown}" >&2
    mw_exit_status=1
  fi
  exit "$mw_exit_status"
}

if [ "$mw_mode" = rollback ]; then
  mw_rollback_backups=$(mw_dest "$MW_APP/backups") || mw_die 'cannot resolve protected backup root'
  mw_rollback_backup="$mw_rollback_backups/$mw_backup_id"
  mw_rollback_manifest="$mw_rollback_backup/manifest.tsv"
  mw_check_path "$mw_rollback_backup" || mw_die 'protected rollback backup path is unsafe'
  mw_check_path "$mw_rollback_manifest" || mw_die 'protected rollback manifest path is unsafe'
  [ -d "$mw_rollback_backups" ] && [ ! -L "$mw_rollback_backups" ] || mw_die 'protected backup root is missing or unsafe'
  [ -d "$mw_rollback_backup" ] && [ ! -L "$mw_rollback_backup" ] || mw_die 'selected rollback backup is missing or unsafe'
  [ "$(mw_stat_mode "$mw_rollback_backups")" = 700 ] || mw_die 'protected backup root mode is not 0700'
  [ "$(mw_stat_mode "$mw_rollback_backup")" = 700 ] || mw_die 'selected rollback backup mode is not 0700'
  [ -f "$mw_rollback_manifest" ] && [ ! -L "$mw_rollback_manifest" ] &&
    [ "$(mw_stat_nlink "$mw_rollback_manifest")" -eq 1 ] || mw_die 'protected rollback manifest is not a safe regular file'
  [ "$(mw_stat_mode "$mw_rollback_manifest")" = 600 ] || mw_die 'protected rollback manifest mode is not 0600'
  mw_acl_policy_is_safe "$mw_rollback_backups" none || mw_die 'protected backup root has an ACL'
  mw_acl_policy_is_safe "$mw_rollback_backup" none || mw_die 'selected rollback backup has an ACL'
  mw_acl_policy_is_safe "$mw_rollback_manifest" none || mw_die 'protected rollback manifest has an ACL'
  if [ -z "$mw_root" ]; then
    mw_live_safe_parent_chain "$mw_rollback_manifest" || mw_die 'protected rollback manifest parent chain is unsafe'
    mw_live_safe_owned "$mw_rollback_backups" || mw_die 'protected backup root is not safely root-owned'
    mw_live_safe_owned "$mw_rollback_backup" || mw_die 'selected rollback backup is not safely root-owned'
    mw_live_safe_owned "$mw_rollback_manifest" || mw_die 'protected rollback manifest is not safely root-owned'
  fi

  MW_ROLLBACK_REQUIRED=(
    "${MW_ALLOWED[@]}" "$MW_APP/install-manifest.tsv" "$MW_LOG"
  )
  MW_ROLLBACK_PATHS=()
  MW_ROLLBACK_EXISTED=()
  MW_ROLLBACK_REL=()
  MW_ROLLBACK_MODE=()
  MW_ROLLBACK_UID=()
  MW_ROLLBACK_GID=()
  MW_ROLLBACK_SHA=()
  mw_rollback_format_seen=0
  mw_rollback_operation_seen=0
  mw_rollback_prior_loaded_seen=0
  mw_rollback_prior_disabled_seen=0
  mw_rollback_resulting_sha_seen=0
  mw_rollback_committed_seen=0
  mw_rollback_post_result_seen=0
  mw_rollback_prior_loaded=
  mw_rollback_prior_disabled=
  mw_rollback_resulting_sha=
  while IFS="$mw_tab" read -r mw_kind mw_a mw_b mw_c mw_d mw_e mw_f mw_g mw_extra; do
    case "$mw_kind" in
      format)
        [ "$mw_a" = 3 ] && [ -z "$mw_b$mw_c$mw_d$mw_e$mw_f$mw_g$mw_extra" ] &&
          [ "$mw_rollback_format_seen" -eq 0 ] || mw_die 'selected backup does not have the reviewed rollback format'
        mw_rollback_format_seen=1
        ;;
      operation)
        [ "$mw_a" = install ] && [ -z "$mw_b$mw_c$mw_d$mw_e$mw_f$mw_g$mw_extra" ] &&
          [ "$mw_rollback_operation_seen" -eq 0 ] || mw_die 'selected backup is not one committed install transaction'
        mw_rollback_operation_seen=1
        ;;
      prior_loaded)
        case "$mw_a" in 0|1) ;; *) mw_die 'selected backup has invalid prior loaded policy' ;; esac
        [ -z "$mw_b$mw_c$mw_d$mw_e$mw_f$mw_g$mw_extra" ] && [ "$mw_rollback_prior_loaded_seen" -eq 0 ] ||
          mw_die 'selected backup has duplicate prior loaded policy'
        mw_rollback_prior_loaded=$mw_a
        mw_rollback_prior_loaded_seen=1
        ;;
      prior_disabled)
        case "$mw_a" in 0|1) ;; *) mw_die 'selected backup has invalid prior disabled policy' ;; esac
        [ -z "$mw_b$mw_c$mw_d$mw_e$mw_f$mw_g$mw_extra" ] && [ "$mw_rollback_prior_disabled_seen" -eq 0 ] ||
          mw_die 'selected backup has duplicate prior disabled policy'
        mw_rollback_prior_disabled=$mw_a
        mw_rollback_prior_disabled_seen=1
        ;;
      resulting_manifest_sha)
        [ "${#mw_a}" -eq 64 ] || mw_die 'selected backup has malformed resulting manifest digest'
        case "$mw_a" in *[!0-9a-f]*) mw_die 'selected backup has invalid resulting manifest digest' ;; esac
        [ -z "$mw_b$mw_c$mw_d$mw_e$mw_f$mw_g$mw_extra" ] && [ "$mw_rollback_resulting_sha_seen" -eq 0 ] ||
          mw_die 'selected backup has duplicate resulting manifest digest'
        mw_rollback_resulting_sha=$mw_a
        mw_rollback_resulting_sha_seen=1
        ;;
      result)
        [ "$mw_a" = committed ] && [ -z "$mw_b$mw_c$mw_d$mw_e$mw_f$mw_g$mw_extra" ] &&
          [ "$mw_rollback_committed_seen" -eq 0 ] || mw_die 'selected backup is not an unused committed installation'
        mw_rollback_committed_seen=1
        ;;
      post_success_rollback)
        mw_rollback_post_result_seen=1
        ;;
      file)
        [ -n "$mw_a" ] && [ -z "$mw_extra" ] || mw_die 'selected backup has a malformed file record'
        mw_array_contains "$mw_a" "${MW_ROLLBACK_REQUIRED[@]}" || mw_die "selected backup contains a non-allowlisted path: $mw_a"
        if [ "${#MW_ROLLBACK_PATHS[@]}" -gt 0 ] && mw_array_contains "$mw_a" "${MW_ROLLBACK_PATHS[@]}"; then
          mw_die "selected backup contains a duplicate path: $mw_a"
        fi
        case "$mw_b" in
          0)
            [ "$mw_c" = - ] && [ "$mw_d" = - ] && [ "$mw_e" = - ] && [ "$mw_f" = - ] && [ "$mw_g" = - ] ||
              mw_die "selected backup has malformed absent-file metadata: $mw_a"
            ;;
          1)
            mw_expected_rel="files/${mw_a#/}"
            [ "$mw_c" = "$mw_expected_rel" ] || mw_die "selected backup has an unsafe source path: $mw_a"
            mw_is_uint "$mw_d" && [ "$mw_d" -le 7777 ] || mw_die "selected backup has an invalid file mode: $mw_a"
            mw_is_uint "$mw_e" || mw_die "selected backup has an invalid file owner: $mw_a"
            mw_is_uint "$mw_f" || mw_die "selected backup has an invalid file group: $mw_a"
            [ "${#mw_g}" -eq 64 ] || mw_die "selected backup has a malformed file digest: $mw_a"
            case "$mw_g" in *[!0-9a-f]*) mw_die "selected backup has an invalid file digest: $mw_a" ;; esac
            mw_source="$mw_rollback_backup/$mw_c"
            mw_check_path "$mw_source" || mw_die "selected backup source path is unsafe: $mw_a"
            [ -f "$mw_source" ] && [ ! -L "$mw_source" ] && [ "$(mw_stat_nlink "$mw_source")" -eq 1 ] ||
              mw_die "selected backup source is not a safe regular file: $mw_a"
            mw_acl_policy_is_safe "$mw_source" none || mw_die "selected backup source has an ACL: $mw_a"
            [ "$(mw_stat_mode "$mw_source")" = "$mw_d" ] || mw_die "selected backup source mode changed: $mw_a"
            if [ -z "$mw_root" ]; then
              mw_live_safe_parent_chain "$mw_source" || mw_die "selected backup source parent chain is unsafe: $mw_a"
              mw_live_safe_owned "$mw_source" || mw_die "selected backup source is not safely root-owned: $mw_a"
              [ "$(mw_stat_uid "$mw_source")" = "$mw_e" ] && [ "$(mw_stat_gid "$mw_source")" = "$mw_f" ] ||
                mw_die "selected backup source ownership changed: $mw_a"
            fi
            mw_source_sha=$(mw_file_sha "$mw_source") || mw_die "cannot hash selected backup source: $mw_a"
            [ "$mw_source_sha" = "$mw_g" ] || mw_die "selected backup source checksum mismatch: $mw_a"
            ;;
          *) mw_die "selected backup has an invalid existence field: $mw_a" ;;
        esac
        MW_ROLLBACK_PATHS[${#MW_ROLLBACK_PATHS[@]}]=$mw_a
        MW_ROLLBACK_EXISTED[${#MW_ROLLBACK_EXISTED[@]}]=$mw_b
        MW_ROLLBACK_REL[${#MW_ROLLBACK_REL[@]}]=$mw_c
        MW_ROLLBACK_MODE[${#MW_ROLLBACK_MODE[@]}]=$mw_d
        MW_ROLLBACK_UID[${#MW_ROLLBACK_UID[@]}]=$mw_e
        MW_ROLLBACK_GID[${#MW_ROLLBACK_GID[@]}]=$mw_f
        MW_ROLLBACK_SHA[${#MW_ROLLBACK_SHA[@]}]=$mw_g
        ;;
      '') mw_die 'selected backup contains an empty record' ;;
      *) mw_die 'selected backup contains an unknown record' ;;
    esac
  done < "$mw_rollback_manifest"

  [ "$mw_rollback_format_seen" -eq 1 ] && [ "$mw_rollback_operation_seen" -eq 1 ] &&
    [ "$mw_rollback_prior_loaded_seen" -eq 1 ] && [ "$mw_rollback_prior_disabled_seen" -eq 1 ] &&
    [ "$mw_rollback_resulting_sha_seen" -eq 1 ] && [ "$mw_rollback_committed_seen" -eq 1 ] ||
    mw_die 'selected backup metadata is incomplete'
  [ "$mw_rollback_post_result_seen" -eq 0 ] || mw_die 'selected backup already has post-success rollback evidence'
  for mw_required in "${MW_ROLLBACK_REQUIRED[@]}"; do
    mw_array_contains "$mw_required" "${MW_ROLLBACK_PATHS[@]}" || mw_die "selected backup path set is incomplete: $mw_required"
  done
  [ "${#MW_ROLLBACK_PATHS[@]}" -eq "${#MW_ROLLBACK_REQUIRED[@]}" ] || mw_die 'selected backup path set is invalid'

  for mw_current_logical in "${MW_ALLOWED[@]}"; do
    mw_current_physical=$(mw_dest "$mw_current_logical") || mw_die 'cannot resolve current installed artifact'
    [ -f "$mw_current_physical" ] && [ ! -L "$mw_current_physical" ] ||
      mw_die "current maintained install is incomplete: $mw_current_logical"
  done
  mw_current_manifest_sha=$(mw_file_sha "$mw_manifest") || mw_die 'cannot hash current installed manifest'
  [ "$mw_current_manifest_sha" = "$mw_rollback_resulting_sha" ] ||
    mw_die 'selected backup does not belong to the current maintained install'
  mw_current_log=$(mw_dest "$MW_LOG") || mw_die 'cannot resolve current log'
  [ -f "$mw_current_log" ] && [ ! -L "$mw_current_log" ] && [ "$(mw_stat_nlink "$mw_current_log")" -eq 1 ] ||
    mw_die 'current log is missing or unsafe; refusing rollback'
  mw_acl_policy_is_safe "$mw_current_log" none || mw_die 'current log has an ACL; refusing rollback'
  [ -n "$mw_root" ] || mw_live_safe_owned "$mw_current_log" || mw_die 'current log is not safely root-owned'

  mw_rollback_canonical_plist_existed=0
  mw_i=0
  while [ "$mw_i" -lt "${#MW_ROLLBACK_PATHS[@]}" ]; do
    if [ "${MW_ROLLBACK_PATHS[$mw_i]}" = "$MW_PLIST" ]; then
      mw_rollback_canonical_plist_existed=${MW_ROLLBACK_EXISTED[$mw_i]}
    fi
    mw_i=$((mw_i + 1))
  done
  [ "$mw_rollback_prior_loaded" -eq 0 ] || [ "$mw_rollback_canonical_plist_existed" -eq 1 ] ||
    mw_die 'selected backup says the prior canonical job was loaded without a plist'
  printf 'MountWatchdog lifecycle plan: rollback\n'
  printf '  protected backup: %s\n' "$mw_backup_id"
  printf '  current canonical policy: loaded=%s, disabled=%s\n' "$mw_loaded" "$mw_disabled"
  printf '  restore canonical policy: loaded=%s, disabled=%s\n' "$mw_rollback_prior_loaded" "$mw_rollback_prior_disabled"
  printf '  log policy: preserve current append-only log\n'
  [ "$mw_lock_exempt" -eq 0 ] || printf '  snapshot scope: point-in-time and non-authoritative; the live mutating invocation revalidates while holding the shared root lock\n'
  if [ "$mw_dry_run" -eq 1 ]; then
    printf 'Dry-run complete: current install, protected backup, file hashes, and service policies validated; nothing changed.\n'
    exit 0
  fi

  mw_transaction_phase=post-success-rollback
  trap 'mw_transaction_exit_handler' EXIT
  trap 'mw_abort_post_success_rollback "post-success rollback interrupted by a signal"' HUP INT TERM QUIT
  mw_disable_job || mw_abort_post_success_rollback 'could not disable canonical job before rollback'
  if [ "$mw_loaded" -eq 1 ]; then
    mw_bootout || mw_abort_post_success_rollback 'could not stop canonical job before rollback'
  fi
  mw_test_fail after_rollback_stop && mw_abort_post_success_rollback 'injected failure after rollback service stop'

  mw_i=0
  while [ "$mw_i" -lt "${#MW_ROLLBACK_PATHS[@]}" ]; do
    mw_logical=${MW_ROLLBACK_PATHS[$mw_i]}
    if [ "$mw_logical" = "$MW_LOG" ]; then
      mw_i=$((mw_i + 1))
      continue
    fi
    mw_target=$(mw_dest "$mw_logical") || mw_abort_post_success_rollback "cannot resolve rollback target: $mw_logical"
    if [ "${MW_ROLLBACK_EXISTED[$mw_i]}" -eq 1 ]; then
      mw_source="$mw_rollback_backup/${MW_ROLLBACK_REL[$mw_i]}"
      mw_replace_rollback_file "$mw_source" "$mw_target" "${MW_ROLLBACK_MODE[$mw_i]}" \
        "${MW_ROLLBACK_UID[$mw_i]}" "${MW_ROLLBACK_GID[$mw_i]}" ||
        mw_abort_post_success_rollback "could not restore rollback target: $mw_logical"
      mw_restored_sha=$(mw_file_sha "$mw_target") || mw_abort_post_success_rollback "cannot hash restored target: $mw_logical"
      [ "$mw_restored_sha" = "${MW_ROLLBACK_SHA[$mw_i]}" ] ||
        mw_abort_post_success_rollback "restored target checksum mismatch: $mw_logical"
      [ "$(mw_stat_mode "$mw_target")" = "${MW_ROLLBACK_MODE[$mw_i]}" ] ||
        mw_abort_post_success_rollback "restored target mode mismatch: $mw_logical"
      if [ -z "$mw_root" ]; then
        [ "$(mw_stat_uid "$mw_target")" = "${MW_ROLLBACK_UID[$mw_i]}" ] &&
          [ "$(mw_stat_gid "$mw_target")" = "${MW_ROLLBACK_GID[$mw_i]}" ] ||
          mw_abort_post_success_rollback "restored target ownership mismatch: $mw_logical"
      fi
    else
      [ ! -L "$mw_target" ] || mw_abort_post_success_rollback "rollback target became a symlink: $mw_logical"
      /bin/rm -f "$mw_target" || mw_abort_post_success_rollback "could not remove newly installed target: $mw_logical"
      [ ! -e "$mw_target" ] && [ ! -L "$mw_target" ] ||
        mw_abort_post_success_rollback "newly installed target remained after rollback: $mw_logical"
    fi
    mw_i=$((mw_i + 1))
    mw_test_fail after_rollback_file && mw_abort_post_success_rollback 'injected failure after rollback file restoration'
  done

  mw_current_state=$(mw_launchctl_job_state canonical-rollback-restore)
  [ "$mw_current_state" = unloaded ] || mw_abort_post_success_rollback 'canonical job state became unsafe during rollback'
  if [ "$mw_rollback_prior_loaded" -eq 1 ]; then
    mw_enable_job || mw_abort_post_success_rollback 'could not enable canonical job for prior registration'
    mw_bootstrap_job || mw_abort_post_success_rollback 'could not restore prior canonical loaded state'
  fi
  if [ "$mw_rollback_prior_disabled" -eq 1 ]; then
    mw_disable_job || mw_abort_post_success_rollback 'could not restore prior canonical disabled policy'
  else
    mw_enable_job || mw_abort_post_success_rollback 'could not restore prior canonical enabled policy'
  fi

  mw_test_fail after_rollback_services && mw_abort_post_success_rollback 'injected failure after rollback service restoration'

  trap '' HUP INT TERM QUIT
  if [ -n "$mw_root" ] && [ "${MOUNTWATCHDOG_TEST_SIGNAL_AT_COMMIT:-0}" = 1 ]; then
    mw_test_signal_self || mw_abort_post_success_rollback 'cannot inject post-success rollback commit signal'
  fi
  printf 'post_success_rollback\tcompleted\n' >> "$mw_rollback_manifest" ||
    mw_abort_post_success_rollback 'could not record completed post-success rollback'
  mw_transaction_phase=none
  mw_release_lifecycle_lock || mw_die 'post-success rollback completed but lock release failed'
  trap - EXIT
  printf 'MountWatchdog post-success rollback completed.\n'
  printf 'Restored backup: %s\n' "$mw_rollback_backup"
  printf 'The current append-only log and protected backups were preserved.\n'
  exit 0
fi

printf 'MountWatchdog lifecycle plan: %s\n' "$mw_mode"
printf '  job currently loaded: %s\n  job currently disabled: %s\n' "$mw_loaded" "$mw_disabled"
[ "$mw_lock_exempt" -eq 0 ] || printf '  snapshot scope: point-in-time and non-authoritative; the live mutating invocation revalidates while holding the shared root lock\n'
if [ "$mw_dry_run" -eq 1 ] && [ "$mw_mode" != remove ]; then
  printf 'Dry-run complete: no files or service state changed.\n'
  exit 0
fi

case "$mw_mode" in
  stop)
    mw_transaction_phase=lifecycle
    trap 'mw_transaction_exit_handler' EXIT
    trap 'mw_abort_lifecycle "stop interrupted by a signal"' HUP INT TERM QUIT
    if [ "$mw_loaded" -eq 1 ] && ! mw_bootout; then
      mw_abort_lifecycle 'could not stop canonical job'
    fi
    trap '' HUP INT TERM QUIT
    mw_transaction_phase=none
    mw_release_lifecycle_lock || mw_die 'lifecycle operation completed but lock release failed'
    trap - EXIT
    printf 'MountWatchdog stopped for the current boot; its enable policy was not changed.\n'
    exit 0
    ;;
  disable)
    mw_transaction_phase=lifecycle
    trap 'mw_transaction_exit_handler' EXIT
    trap 'mw_abort_lifecycle "disable interrupted by a signal"' HUP INT TERM QUIT
    if ! mw_disable_job; then mw_abort_lifecycle 'could not disable canonical job'; fi
    mw_test_fail after_disable && mw_abort_lifecycle 'injected lifecycle failure after disable'
    if [ "$mw_loaded" -eq 1 ] && ! mw_bootout; then
      mw_abort_lifecycle 'job could not be stopped'
    fi
    trap '' HUP INT TERM QUIT
    mw_transaction_phase=none
    mw_release_lifecycle_lock || mw_die 'lifecycle operation completed but lock release failed'
    trap - EXIT
    printf 'MountWatchdog disabled for future boots and stopped now.\n'
    exit 0
    ;;
esac

mw_manifest=$(mw_dest "$MW_APP/install-manifest.tsv") || mw_die 'cannot resolve installed manifest'
[ -f "$mw_manifest" ] && [ ! -L "$mw_manifest" ] || mw_die 'owned install manifest is missing or unsafe; refusing removal'

MW_ALLOWED=(
  "$MW_APP/watchdog.sh" "$MW_APP/status.sh" "$MW_APP/lib/common.sh"
  "$MW_APP/lib/runtime.sh" "$MW_APP/lib/autofs.sh" "$MW_APP/defaults.conf" "$MW_APP/mounts.conf"
  "$MW_APP/VERSION" "$MW_PLIST"
)
MW_REMOVE=()
mw_tab=$(printf '\tX'); mw_tab=${mw_tab%X}
while IFS="$mw_tab" read -r mw_kind mw_logical mw_sha mw_extra; do
  [ "$mw_kind" = file ] || continue
  [ -n "$mw_logical" ] && [ -n "$mw_sha" ] && [ -z "$mw_extra" ] || mw_die 'malformed installed manifest'
  mw_array_contains "$mw_logical" "${MW_ALLOWED[@]}" || mw_die "manifest contains a non-allowlisted path: $mw_logical"
  mw_physical=$(mw_dest "$mw_logical") || mw_die 'manifest path resolution failed'
  mw_check_path "$mw_physical" || mw_die "unsafe owned path: $mw_logical"
  if [ -e "$mw_physical" ]; then
    [ -f "$mw_physical" ] && [ ! -L "$mw_physical" ] || mw_die "owned path is not a regular file: $mw_logical"
    mw_current_sha=$(mw_file_sha "$mw_physical") || mw_die "cannot hash owned path: $mw_logical"
    [ "$mw_current_sha" = "$mw_sha" ] || mw_die "owned file was modified; preserve and inspect it: $mw_logical"
  fi
  if [ "${#MW_REMOVE[@]}" -gt 0 ] && mw_array_contains "$mw_logical" "${MW_REMOVE[@]}"; then
    mw_die "duplicate manifest path: $mw_logical"
  fi
  MW_REMOVE[${#MW_REMOVE[@]}]=$mw_logical
done < "$mw_manifest"
[ "${#MW_REMOVE[@]}" -eq "${#MW_ALLOWED[@]}" ] || mw_die 'installed manifest is incomplete; refusing removal'
MW_REMOVE[${#MW_REMOVE[@]}]="$MW_APP/install-manifest.tsv"

if [ -z "$mw_root" ]; then
  for mw_owned_parent in \
    "$(mw_dest "$MW_APP")" "$(mw_dest "$MW_APP/lib")" \
    "$(dirname -- "$(mw_dest "$MW_PLIST")")"; do
    if ! mw_check_path "$mw_owned_parent" || ! mw_live_safe_owned "$mw_owned_parent"; then
      mw_die "unsafe privileged parent: $mw_owned_parent"
    fi
  done
  mw_live_safe_owned "$mw_manifest" || mw_die 'installed manifest is not safely root-owned'
fi

if [ "$mw_dry_run" -eq 1 ]; then
  printf 'Dry-run complete: owned manifest and file hashes validated; no files or service state changed.\n'
  exit 0
fi

mw_backups=$(mw_dest "$MW_APP/backups") || mw_die 'cannot resolve backups'
mw_check_path "$mw_backups" || mw_die 'unsafe backups path'
if [ -e "$mw_backups" ] || [ -L "$mw_backups" ]; then
  [ -d "$mw_backups" ] && [ ! -L "$mw_backups" ] || mw_die 'backups path is not a safe directory'
  [ "$(mw_stat_mode "$mw_backups")" = 700 ] || mw_die 'backups directory mode is not 0700'
  mw_acl_policy_is_safe "$mw_backups" none || mw_die 'backups directory has an ACL'
  [ -n "$mw_root" ] || mw_live_safe_owned "$mw_backups" || mw_die 'backups path is not safely root-owned'
else
  /bin/mkdir -m 700 "$mw_backups" || mw_die 'cannot create retained backup directory'
  mw_strip_acl_from_new_node "$mw_backups" || mw_die 'cannot normalize retained backup directory ACL'
fi
mw_backup_base=$(/bin/date -u +%Y%m%dT%H%M%SZ)-uninstall-$$
mw_n=0
while :; do
  mw_backup="$mw_backups/$mw_backup_base-$mw_n"
  if /bin/mkdir -m 700 "$mw_backup" 2>/dev/null; then
    mw_strip_acl_from_new_node "$mw_backup" || mw_die 'cannot normalize removal backup ACL'
    break
  fi
  mw_n=$((mw_n + 1)); [ "$mw_n" -lt 1000 ] || mw_die 'cannot allocate removal backup'
done
mw_backup_manifest="$mw_backup/manifest.tsv"
printf 'format\t1\noperation\tremove\nprior_loaded\t%s\nprior_disabled\t%s\n' "$mw_loaded" "$mw_disabled" > "$mw_backup_manifest" || mw_die 'cannot create removal manifest'
mw_acl_policy_is_safe "$mw_backup_manifest" none || mw_die 'removal manifest inherited an ACL'

mw_make_removal_backup_dir() {
  mw_backup_target_dir=$1
  case "$mw_backup_target_dir" in "$mw_backup"/*) ;; *) return 1 ;; esac
  mw_backup_relative=${mw_backup_target_dir#"$mw_backup"/}
  mw_backup_current=$mw_backup
  mw_backup_ifs=$IFS
  IFS=/
  set -f
  # shellcheck disable=SC2086 # Intentional slash-delimited component split.
  set -- $mw_backup_relative
  set +f
  IFS=$mw_backup_ifs
  for mw_backup_component in "$@"; do
    [ -n "$mw_backup_component" ] || return 1
    mw_backup_current=$mw_backup_current/$mw_backup_component
    mw_check_path "$mw_backup_current" || return 1
    if [ -e "$mw_backup_current" ] || [ -L "$mw_backup_current" ]; then
      [ -d "$mw_backup_current" ] && [ ! -L "$mw_backup_current" ] || return 1
      mw_acl_policy_is_safe "$mw_backup_current" none || return 1
    else
      /bin/mkdir -m 700 "$mw_backup_current" || return 1
      mw_strip_acl_from_new_node "$mw_backup_current" || return 1
    fi
  done
}

for mw_logical in "${MW_REMOVE[@]}"; do
  mw_physical=$(mw_dest "$mw_logical") || mw_die 'cannot resolve removal path'
  mw_remove_rel=${mw_logical#/}
  if [ -e "$mw_physical" ]; then
    mw_copy="$mw_backup/files/$mw_remove_rel"
    mw_make_removal_backup_dir "$(dirname -- "$mw_copy")" || mw_die "cannot stage removal backup: $mw_logical"
    /bin/cp -p "$mw_physical" "$mw_copy" || mw_die "cannot back up removal path: $mw_logical"
    mw_acl_policy_is_safe "$mw_copy" none || mw_die "removal backup inherited an ACL: $mw_logical"
    mw_copy_sha=$(mw_file_sha "$mw_copy") || mw_die "cannot hash removal backup: $mw_logical"
    mw_source_sha=$(mw_file_sha "$mw_physical") || mw_die "cannot hash removal source: $mw_logical"
    [ "$mw_copy_sha" = "$mw_source_sha" ] || mw_die "removal backup verification failed: $mw_logical"
    mw_mode_value=$(mw_stat_mode "$mw_physical") || mw_die "cannot stat removal path: $mw_logical"
    mw_uid_value=$(mw_stat_uid "$mw_physical") || mw_die "cannot stat removal path: $mw_logical"
    mw_gid_value=$(mw_stat_gid "$mw_physical") || mw_die "cannot stat removal path: $mw_logical"
    printf 'file\t%s\t1\t%s\t%s\t%s\t%s\t%s\n' "$mw_logical" "files/$mw_remove_rel" "$mw_mode_value" "$mw_uid_value" "$mw_gid_value" "$mw_copy_sha" >> "$mw_backup_manifest" || mw_die 'cannot record removal backup'
  else
    printf 'file\t%s\t0\t-\t-\t-\t-\t-\n' "$mw_logical" >> "$mw_backup_manifest" || mw_die 'cannot record absent removal path'
  fi
done

MW_REMOVED_PATHS=()
mw_restore_removed() {
  mw_restore_ok=1
  [ "${#MW_REMOVED_PATHS[@]}" -gt 0 ] || return 0
  if [ -n "$mw_root" ] && [ "${MOUNTWATCHDOG_TEST_TAMPER_REMOVE_BACKUP_ON_ROLLBACK:-0}" = 1 ]; then
    mw_test_restore_source="$mw_backup/files/Library/Application Support/MountWatchdog/watchdog.sh"
    [ ! -f "$mw_test_restore_source" ] || printf '# injected removal-backup tamper\n' >> "$mw_test_restore_source" || mw_restore_ok=0
  fi
  while IFS="$mw_tab" read -r mw_kind mw_logical mw_existed mw_rel mw_mode mw_uid mw_gid mw_sha; do
    [ "$mw_kind" = file ] && [ "$mw_existed" = 1 ] || continue
    mw_array_contains "$mw_logical" "${MW_REMOVED_PATHS[@]}" || continue
    mw_target=$(mw_dest "$mw_logical") || { mw_restore_ok=0; continue; }
    mw_restore_source="$mw_backup/$mw_rel"
    mw_acl_policy_is_safe "$mw_restore_source" none || { mw_restore_ok=0; continue; }
    mw_restore_source_sha=$(mw_file_sha "$mw_restore_source") || { mw_restore_ok=0; continue; }
    [ "$mw_sha" = "$mw_restore_source_sha" ] || { mw_restore_ok=0; continue; }
    if [ -e "$mw_target" ] || [ -L "$mw_target" ]; then
      [ -f "$mw_target" ] && [ ! -L "$mw_target" ] || { mw_restore_ok=0; continue; }
      mw_existing_target_sha=$(mw_file_sha "$mw_target") || { mw_restore_ok=0; continue; }
      [ "$mw_existing_target_sha" = "$mw_sha" ] || mw_restore_ok=0
      continue
    fi
    mw_restore_parent=$(dirname -- "$mw_target")
    if [ ! -e "$mw_restore_parent" ] && [ ! -L "$mw_restore_parent" ]; then
      mw_restore_lib=$(mw_dest "$MW_APP/lib") || { mw_restore_ok=0; continue; }
      [ "$mw_restore_parent" = "$mw_restore_lib" ] || { mw_restore_ok=0; continue; }
      /bin/mkdir -m 700 "$mw_restore_parent" || { mw_restore_ok=0; continue; }
      mw_strip_acl_from_new_node "$mw_restore_parent" || { mw_restore_ok=0; continue; }
    fi
    [ -d "$mw_restore_parent" ] && [ ! -L "$mw_restore_parent" ] || { mw_restore_ok=0; continue; }
    case "$mw_restore_parent" in
      "$mw_app"|"$mw_app"/*) mw_acl_policy_is_safe "$mw_restore_parent" none || { mw_restore_ok=0; continue; } ;;
      *) mw_acl_policy_is_safe "$mw_restore_parent" deny-only || { mw_restore_ok=0; continue; } ;;
    esac
    mw_restore_tmp=$(/usr/bin/mktemp "$mw_target.restore.XXXXXX") || { mw_restore_ok=0; continue; }
    /bin/cp "$mw_restore_source" "$mw_restore_tmp" || { /bin/rm -f "$mw_restore_tmp"; mw_restore_ok=0; continue; }
    mw_strip_acl_from_new_node "$mw_restore_tmp" || { /bin/rm -f "$mw_restore_tmp"; mw_restore_ok=0; continue; }
    /bin/chmod "$mw_mode" "$mw_restore_tmp" || { /bin/rm -f "$mw_restore_tmp"; mw_restore_ok=0; continue; }
    [ -n "$mw_root" ] || /usr/sbin/chown "$mw_uid:$mw_gid" "$mw_restore_tmp" || { /bin/rm -f "$mw_restore_tmp"; mw_restore_ok=0; continue; }
    /bin/mv -f "$mw_restore_tmp" "$mw_target" || { /bin/rm -f "$mw_restore_tmp"; mw_restore_ok=0; continue; }
    mw_restored_target_sha=$(mw_file_sha "$mw_target") || { mw_restore_ok=0; continue; }
    [ "$mw_sha" = "$mw_restored_target_sha" ] || mw_restore_ok=0
  done < "$mw_backup_manifest"
  [ "$mw_restore_ok" -eq 1 ]
}

mw_abort_remove() {
  mw_abort_message=$1
  mw_transaction_phase=none
  trap '' HUP INT TERM QUIT
  if [ -n "$mw_root" ] && [ "${MOUNTWATCHDOG_TEST_SIGNAL_DURING_ROLLBACK:-0}" = 1 ]; then
    mw_test_signal_self || true
  fi
  mw_abort_ok=0
  mw_files_ready=1
  if [ "${#MW_REMOVED_PATHS[@]}" -gt 0 ]; then
    if ! mw_prove_service_unloaded; then
      mw_files_ready=0
      mw_quiesce_service_after_incomplete_rollback
    elif ! mw_restore_removed; then
      mw_files_ready=0
      mw_quiesce_service_after_incomplete_rollback
    fi
  fi
  if [ "$mw_files_ready" -eq 1 ] && mw_restore_prior_service_state; then
    mw_abort_ok=1
  else
    mw_quiesce_service_after_incomplete_rollback
  fi
  if [ "$mw_abort_ok" -eq 1 ]; then
    if mw_record_removal_rollback_result rolled-back; then
      mw_release_lifecycle_lock || printf 'MountWatchdog: lifecycle lock release failed; inspect %s\n' "$mw_lock_path" >&2
      printf 'MountWatchdog: %s; prior files and service state restored\n' "$mw_abort_message" >&2
      exit 1
    fi
    mw_abort_ok=0
    mw_quiesce_service_after_incomplete_rollback
  fi
  if [ "$mw_abort_ok" -eq 0 ]; then
    mw_record_removal_rollback_result rollback-incomplete 2>/dev/null || true
    printf 'MountWatchdog: %s; rollback incomplete, retain %s and inspect manually\n' "$mw_abort_message" "$mw_backup" >&2
  fi
  mw_release_lifecycle_lock || printf 'MountWatchdog: lifecycle lock release failed; inspect %s\n' "$mw_lock_path" >&2
  exit 1
}

mw_interrupt_remove() {
  mw_abort_remove 'removal interrupted by a signal'
}

mw_transaction_phase=remove
trap 'mw_transaction_exit_handler' EXIT
trap 'mw_interrupt_remove' HUP INT TERM QUIT

mw_test_fail before_service_change && mw_abort_remove 'injected staging removal failure before service change'
[ "$mw_disabled" -eq 1 ] || mw_disable_job || mw_abort_remove 'could not reliably disable canonical job'
if [ "$mw_loaded" -eq 1 ] && ! mw_bootout; then
  mw_abort_remove 'could not reliably stop canonical job'
fi
mw_test_fail after_stop && mw_abort_remove 'injected staging removal failure after stop'

mw_removed_any=0
for mw_logical in "${MW_REMOVE[@]}"; do
  mw_physical=$(mw_dest "$mw_logical") || mw_abort_remove 'removal path resolution failed'
  [ -e "$mw_physical" ] || continue
  MW_REMOVED_PATHS[${#MW_REMOVED_PATHS[@]}]=$mw_logical
  /bin/rm -f "$mw_physical" || mw_abort_remove "could not remove owned file: $mw_logical"
  if [ -n "$mw_root" ] && [ "${MOUNTWATCHDOG_TEST_SIGNAL_AFTER_UNLINK:-0}" = 1 ]; then
    mw_test_signal_self || mw_abort_remove 'cannot inject staging post-unlink signal'
  fi
  [ ! -e "$mw_physical" ] && [ ! -L "$mw_physical" ] || mw_abort_remove "owned file remained after removal: $mw_logical"
  mw_removed_any=1
  if [ -n "$mw_root" ] && mw_is_uint "${MOUNTWATCHDOG_TEST_UNINSTALL_FAIL_AFTER_REMOVALS:-}" &&
    [ "${#MW_REMOVED_PATHS[@]}" -eq "$MOUNTWATCHDOG_TEST_UNINSTALL_FAIL_AFTER_REMOVALS" ]; then
    mw_abort_remove 'injected staging failure after partial file removal'
  fi
done
mw_test_fail after_remove && mw_abort_remove 'injected staging removal failure after file removal'
mw_test_unhandled_exit after_remove || exit $?

/bin/rmdir "$(mw_dest "$MW_APP/lib")" 2>/dev/null || true
trap '' HUP INT TERM QUIT
if [ -n "$mw_root" ] && [ "${MOUNTWATCHDOG_TEST_SIGNAL_AT_COMMIT:-0}" = 1 ]; then
  mw_test_signal_self || mw_abort_remove 'cannot inject staging commit signal'
fi
printf 'result\tcommitted\n' >> "$mw_backup_manifest" || mw_abort_remove 'cannot finalize removal manifest'
mw_transaction_phase=none
mw_release_lifecycle_lock || mw_die 'removal committed but lifecycle lock release failed'
trap - EXIT
printf 'MountWatchdog owned program artifacts removed: %s\n' "$mw_removed_any"
printf 'Retained backup: %s\n' "$mw_backup"
printf 'Backups, logs, runtime state, autofs maps, mountpoints, and NAS content were preserved.\n'
