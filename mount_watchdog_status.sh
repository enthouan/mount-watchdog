#!/bin/bash
# shellcheck disable=SC1090,SC2034
set +x

# Cached, read-only diagnostics. This command never runs a watchdog tick,
# probes a NAS, inspects a managed path, or creates runtime state.

PATH=/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
export PATH LC_ALL

case "$0" in /*) mw_entry_path=$0 ;; *) mw_entry_path=$PWD/$0 ;; esac
mw_script_dir=${mw_entry_path%/*}
mw_common_file=$mw_script_dir/lib/common.sh
mw_runtime_file=$mw_script_dir/lib/runtime.sh
mw_test_requested=0
[ -z "${MW_TEST_ROOT:-}${MW_TEST_COMMAND_DIR:-}" ] || mw_test_requested=1
mw_watchdog_file=$mw_script_dir/watchdog.sh
[ "$mw_test_requested" -ne 1 ] || mw_watchdog_file=$mw_script_dir/mount_watchdog.sh
if [ "$mw_test_requested" -eq 1 ] && [ "$EUID" -eq 0 ]; then
  printf 'MountWatchdog: test backend is disabled before source loading for root\n' >&2
  exit 3
fi
if [ "$mw_test_requested" -eq 0 ]; then
  [ "$mw_script_dir" = '/Library/Application Support/MountWatchdog' ] || exit 3
  for mw_trusted_path in /Library '/Library/Application Support' \
    "$mw_script_dir" "$mw_script_dir/lib"; do
    [ -d "$mw_trusted_path" ] && [ ! -L "$mw_trusted_path" ] || exit 3
    mw_trusted_meta=$(/usr/bin/stat -f '%Su|%Lp' "$mw_trusted_path" 2>/dev/null) || exit 3
    [ "${mw_trusted_meta%%|*}" = root ] || exit 3
    mw_trusted_mode=${mw_trusted_meta#*|}
    case "$mw_trusted_mode" in ''|*[!0-7]*) exit 3 ;; esac
    [ $(( (10#$mw_trusted_mode / 10) % 10 & 2 )) -eq 0 ] || exit 3
    [ $(( 10#$mw_trusted_mode % 10 & 2 )) -eq 0 ] || exit 3
  done
  for mw_trusted_path in "$mw_entry_path" "$mw_watchdog_file" "$mw_common_file" "$mw_runtime_file" \
    "$mw_script_dir/defaults.conf" "$mw_script_dir/mounts.conf" "$mw_script_dir/VERSION"; do
    [ -f "$mw_trusted_path" ] && [ ! -L "$mw_trusted_path" ] || exit 3
    mw_trusted_meta=$(/usr/bin/stat -f '%Su|%Lp' "$mw_trusted_path" 2>/dev/null) || exit 3
    [ "${mw_trusted_meta%%|*}" = root ] || exit 3
    mw_trusted_mode=${mw_trusted_meta#*|}
    case "$mw_trusted_mode" in ''|*[!0-7]*) exit 3 ;; esac
    [ $(( (10#$mw_trusted_mode / 10) % 10 & 2 )) -eq 0 ] || exit 3
    [ $(( 10#$mw_trusted_mode % 10 & 2 )) -eq 0 ] || exit 3
  done
fi
[ -f "$mw_common_file" ] && [ ! -L "$mw_common_file" ] || {
  printf 'MountWatchdog: missing trusted common library\n' >&2
  exit 3
}
[ -f "$mw_runtime_file" ] && [ ! -L "$mw_runtime_file" ] || {
  printf 'MountWatchdog: missing trusted runtime library\n' >&2
  exit 3
}
. "$mw_common_file"
. "$mw_runtime_file"
MW_RUNTIME_PROGRAM_FILE=$mw_watchdog_file
MW_RUNTIME_COMMON_FILE=$mw_common_file
MW_RUNTIME_LIBRARY_FILE=$mw_runtime_file

case "${1:-}" in
  ''|--status) ;;
  --help|-h)
    printf 'Usage: %s [--status]\n' "${0##*/}"
    exit 0
    ;;
  *) mw_error 'status accepts only --status or --help'; exit 3 ;;
esac
[ "$#" -le 1 ] || { mw_error 'too many status arguments'; exit 3; }

mw_runtime_init_paths status || exit 3
mw_parse_defaults "$MW_DEFAULTS_FILE" || exit 3
mw_parse_config "$MW_CONFIG_FILE" || exit 3
mw_compute_runtime_fingerprint || { mw_error 'could not fingerprint runtime inputs'; exit 3; }

mw_version=unavailable
if [ -f "$MW_VERSION_FILE" ] && [ ! -L "$MW_VERSION_FILE" ]; then
  IFS= read -r mw_version < "$MW_VERSION_FILE" || mw_version=unavailable
  mw_version=$(mw_sanitize_field "$mw_version")
fi
printf 'MountWatchdog version=%s\n' "$mw_version"
printf 'check_scope=%s readability=%s\n' "$MW_CHECK_SCOPE" "$MW_READABILITY"

if ! mw_validate_mount_state_dirs; then
  printf 'state_cache=unsafe mount=%s\n' "$MW_UNSAFE_MOUNT_STATE_NAME"
  exit 3
fi
if ! mw_validate_runtime_state_leaves; then
  printf 'state_cache=unsafe leaf=%s\n' "$MW_UNSAFE_STATE_LEAF"
  exit 3
fi

mw_status_exit=0
if "$MW_CMD_LAUNCHCTL" print "system/$MW_LABEL" >/dev/null 2>&1; then
  printf 'job=registered\n'
else
  printf 'job=not-registered-or-unavailable\n'
  mw_status_exit=1
fi

mw_status_now=$($MW_CMD_DATE +%s 2>/dev/null || true)
mw_is_uint "$mw_status_now" || mw_status_now=0
mw_heartbeat=$MW_STATE_DIR/heartbeat
if [ -f "$mw_heartbeat" ] && [ ! -L "$mw_heartbeat" ] &&
  [ "$(mw_state_value "$mw_heartbeat" format 2>/dev/null || true)" = "$MW_STATE_FORMAT" ]; then
  mw_heartbeat_phase=$(mw_state_value "$mw_heartbeat" phase 2>/dev/null || printf 'unknown')
  mw_heartbeat_result=$(mw_state_value "$mw_heartbeat" result 2>/dev/null || printf 'unknown')
  mw_heartbeat_completed=$(mw_state_value "$mw_heartbeat" completed_epoch 2>/dev/null || printf '0')
  mw_heartbeat_fingerprint=$(mw_state_value "$mw_heartbeat" runtime_fingerprint 2>/dev/null || true)
  case "$mw_heartbeat_phase" in running|complete) mw_heartbeat_phase_valid=1 ;; *) mw_heartbeat_phase_valid=0 ;; esac
  mw_heartbeat_result_valid=1
  mw_heartbeat_result_severity=3
  case "$mw_heartbeat_phase:$mw_heartbeat_result" in
    running:in-progress|complete:ok) mw_heartbeat_result_severity=0 ;;
    complete:pending|complete:interrupted) mw_heartbeat_result_severity=1 ;;
    complete:manual-attention|complete:interrupted-command-blocked|complete:blocked-command-unsafe-block-record|complete:blocked-command-invalid-block-record|complete:blocked-command-invalid-block-identifiers|complete:blocked-command-surviving-descendant-group|complete:blocked-command-live-unverifiable-command-group|complete:blocked-command-live-command-group|complete:blocked-command-live-command-group-token-mismatch|complete:blocked-command-block-record-retire-failed) mw_heartbeat_result_severity=2 ;;
    complete:inspection-error|complete:state-write-error|complete:clock-error|complete:internal-error|complete:unsafe-mount-state-directory-*|complete:unsafe-state-leaf-*) mw_heartbeat_result_severity=3 ;;
    *) mw_heartbeat_result_valid=0 ;;
  esac
  case "$mw_heartbeat_result" in ''|*[!A-Za-z0-9._-]*) mw_heartbeat_result_valid=0 ;; esac
  if [ "$mw_heartbeat_phase_valid" -ne 1 ] || [ "$mw_heartbeat_result_valid" -ne 1 ]; then
    printf 'heartbeat=unsafe\n'
    mw_status_exit=3
  elif [ "$mw_heartbeat_fingerprint" != "$MW_RUNTIME_FINGERPRINT" ]; then
    printf 'heartbeat=input-mismatch\n'
    [ "$mw_status_exit" -ne 0 ] || mw_status_exit=1
  elif mw_is_uint "$mw_heartbeat_completed" && [ "$mw_status_now" -ge "$mw_heartbeat_completed" ]; then
    mw_heartbeat_age=$((mw_status_now - mw_heartbeat_completed))
    printf 'heartbeat_phase=%s heartbeat_result=%s heartbeat_age_seconds=%s\n' \
      "$mw_heartbeat_phase" "$mw_heartbeat_result" "$mw_heartbeat_age"
    if [ "$mw_heartbeat_phase" != complete ] ||
      [ "$mw_heartbeat_age" -gt $((MW_SCHEDULING_GAP_SECONDS * 2)) ]; then
      [ "$mw_status_exit" -ne 0 ] || mw_status_exit=1
    fi
    if [ "$mw_heartbeat_result_severity" -gt "$mw_status_exit" ]; then
      mw_status_exit=$mw_heartbeat_result_severity
    fi
  else
    printf 'heartbeat=invalid-or-clock-rollback\n'
    mw_status_exit=3
  fi
else
  printf 'heartbeat=unavailable\n'
  [ "$mw_status_exit" -ne 0 ] || mw_status_exit=1
fi

mw_block_file=$MW_STATE_DIR/blocked-command
if [ -e "$mw_block_file" ] || [ -L "$mw_block_file" ]; then
  if ! mw_read_blocked_command_record "$mw_block_file"; then
    if [ "$MW_BLOCK_RECORD_REASON" = unsafe-block-record ]; then
      printf 'blocked_command=unsafe manual_attention=required\n'
    else
      printf 'blocked_command=invalid manual_attention=required\n'
    fi
    mw_status_exit=3
  else
    printf 'blocked_command=recorded command=%s manual_attention=required\n' \
      "$MW_BLOCK_RECORD_COMMAND"
    [ "$mw_status_exit" -eq 3 ] || mw_status_exit=2
  fi
fi

mw_refresh_file=$MW_STATE_DIR/autofs-refresh
if [ -e "$mw_refresh_file" ] || [ -L "$mw_refresh_file" ]; then
  mw_refresh_fingerprint=$(mw_state_value "$mw_refresh_file" runtime_fingerprint 2>/dev/null || true)
  if [ "$mw_refresh_fingerprint" != "$MW_RUNTIME_FINGERPRINT" ]; then
    printf 'autofs_refresh=input-mismatch\n'
    [ "$mw_status_exit" -ne 0 ] || mw_status_exit=1
  elif mw_read_autofs_refresh_record "$mw_refresh_file"; then
    mw_refresh_epoch=$(mw_state_value "$mw_refresh_file" last_attempt_epoch 2>/dev/null || true)
    if mw_is_uint "$mw_refresh_epoch" && [ "$mw_refresh_epoch" -le "$mw_status_now" ]; then
      printf 'autofs_refresh_last_result=%s autofs_refresh_exit_status=%s\n' \
        "$MW_REFRESH_RECORD_RESULT" "$MW_REFRESH_RECORD_EXIT_STATUS"
      case "$MW_REFRESH_RECORD_RESULT" in
        attempting)
          printf 'autofs_refresh_pending=required\n'
          [ "$mw_status_exit" -ne 0 ] || mw_status_exit=1
          ;;
        failed) [ "$mw_status_exit" -ne 0 ] || mw_status_exit=1 ;;
        timed-out|supervision-failed) [ "$mw_status_exit" -eq 3 ] || mw_status_exit=2 ;;
      esac
    else
      printf 'autofs_refresh=invalid-or-clock-rollback manual_attention=required\n'
      mw_status_exit=3
    fi
  else
    printf 'autofs_refresh=unsafe manual_attention=required\n'
    mw_status_exit=3
  fi
fi

mw_index=0
while [ "$mw_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
  mw_name=${MW_MOUNT_NAMES[$mw_index]}
  mw_status_file=$MW_STATE_DIR/$mw_name/status
  printf '\nmount=%s path=%s expected=%s/%s\n' \
    "$mw_name" "${MW_MOUNT_PATHS[$mw_index]}" \
    "${MW_MOUNT_HOSTS[$mw_index]}" "${MW_MOUNT_SHARES[$mw_index]}"
  if [ ! -f "$mw_status_file" ] || [ -L "$mw_status_file" ] ||
    [ "$(mw_state_value "$mw_status_file" format 2>/dev/null || true)" != "$MW_STATE_FORMAT" ]; then
    printf 'state=unavailable pending_recovery=unknown action_state=unknown\n'
    [ "$mw_status_exit" -ne 0 ] || mw_status_exit=1
    mw_index=$((mw_index + 1))
    continue
  fi
  mw_status_fingerprint=$(mw_state_value "$mw_status_file" runtime_fingerprint 2>/dev/null || true)
  if [ "$mw_status_fingerprint" != "$MW_RUNTIME_FINGERPRINT" ]; then
    printf 'state=input-mismatch pending_recovery=unknown action_state=stale\n'
    [ "$mw_status_exit" -ne 0 ] || mw_status_exit=1
    mw_index=$((mw_index + 1))
    continue
  fi
  mw_load_mount_state "$mw_status_file"
  if [ "$MW_STATE_VALID" -ne 1 ] || [ "$MW_PREV_FINGERPRINT" != "$MW_RUNTIME_FINGERPRINT" ]; then
    printf 'state=unsafe pending_recovery=unknown action_state=manual-attention\n'
    mw_status_exit=3
    mw_index=$((mw_index + 1))
    continue
  fi
  mw_state=$(mw_state_value "$mw_status_file" state 2>/dev/null || printf 'unavailable')
  mw_cached_name=$(mw_state_value "$mw_status_file" mount_name 2>/dev/null || true)
  mw_cached_path=$(mw_state_value "$mw_status_file" mount_path 2>/dev/null || true)
  mw_cached_host=$(mw_state_value "$mw_status_file" expected_host 2>/dev/null || true)
  mw_cached_share=$(mw_state_value "$mw_status_file" expected_share 2>/dev/null || true)
  mw_cached_scope=$(mw_state_value "$mw_status_file" check_scope 2>/dev/null || true)
  mw_cached_readability=$(mw_state_value "$mw_status_file" readability 2>/dev/null || true)
  mw_checked=$(mw_state_value "$mw_status_file" checked_at 2>/dev/null || printf 'unavailable')
  mw_pending=$(mw_state_value "$mw_status_file" pending_recovery 2>/dev/null || printf 'unknown')
  mw_action=$(mw_state_value "$mw_status_file" action_state 2>/dev/null || printf 'unknown')
  mw_status_core_valid=1
  [ "$mw_cached_name" = "$mw_name" ] || mw_status_core_valid=0
  [ "$mw_cached_path" = "${MW_MOUNT_PATHS[$mw_index]}" ] || mw_status_core_valid=0
  [ "$mw_cached_host" = "${MW_MOUNT_HOSTS[$mw_index]}" ] || mw_status_core_valid=0
  [ "$mw_cached_share" = "${MW_MOUNT_SHARES[$mw_index]}" ] || mw_status_core_valid=0
  [ "$mw_cached_scope" = "$MW_CHECK_SCOPE" ] || mw_status_core_valid=0
  [ "$mw_cached_readability" = "$MW_READABILITY" ] || mw_status_core_valid=0
  [ "${#mw_checked}" -eq 20 ] || mw_status_core_valid=0
  case "$mw_checked" in
    ????-??-??T??:??:??Z) ;;
    *) mw_status_core_valid=0 ;;
  esac
  case "$mw_checked" in *[!0-9TZ:-]*) mw_status_core_valid=0 ;; esac
  case "$mw_state" in
    mounted-reachable|mounted-unreachable|mounted-reachability-unknown|trigger-only|trigger-missing|unexpected-mount|ambiguous-mount|inspection-error) ;;
    *) mw_status_core_valid=0 ;;
  esac
  case "$mw_pending" in
    none|network-restored|scheduling-gap|trigger-missing|multiple) ;;
    *) mw_status_core_valid=0 ;;
  esac
  case "$mw_action" in
    idle|deferred-cooldown|deferred-network|deferred-command-block|unmount-required|refresh-required|manual-attention|canceled) ;;
    *) mw_status_core_valid=0 ;;
  esac
  if [ "$mw_status_core_valid" -ne 1 ]; then
    printf 'state=unsafe pending_recovery=unknown action_state=manual-attention\n'
    mw_status_exit=3
    mw_index=$((mw_index + 1))
    continue
  fi
  mw_last_action=$(mw_state_value "$mw_status_file" last_attempt_action 2>/dev/null || printf 'unavailable')
  mw_last_result=$(mw_state_value "$mw_status_file" last_attempt_result 2>/dev/null || printf 'unavailable')
  mw_last_exit_status=$(mw_state_value "$mw_status_file" last_attempt_exit_status 2>/dev/null || printf 'unavailable')
  mw_last_attempt_epoch=$(mw_state_value "$mw_status_file" last_attempt_epoch 2>/dev/null || printf '0')
  mw_is_uint "$mw_last_attempt_epoch" || mw_last_attempt_epoch=0
  if ! mw_exit_status_value_is_valid "$mw_last_exit_status"; then
    printf 'state=unsafe pending_recovery=unknown action_state=manual-attention\n'
    mw_status_exit=3
    mw_index=$((mw_index + 1))
    continue
  fi
  mw_last_error=$(mw_state_value "$mw_status_file" last_error 2>/dev/null || printf 'unavailable')
  mw_last_success=$(mw_state_value "$mw_status_file" last_successful_action 2>/dev/null || printf 'unavailable')
  mw_journal_state=none
  mw_journal_file=$MW_STATE_DIR/$mw_name/unmount-attempt
  if [ -e "$mw_journal_file" ] || [ -L "$mw_journal_file" ]; then
    if ! mw_read_unmount_attempt_journal "$mw_journal_file"; then
      mw_journal_state=unsafe
      mw_status_exit=3
    else
      mw_journal_fingerprint=$(mw_state_value "$mw_journal_file" runtime_fingerprint 2>/dev/null || true)
      mw_journal_epoch=$(mw_state_value "$mw_journal_file" attempt_epoch 2>/dev/null || printf '0')
      if [ "$mw_journal_fingerprint" != "$MW_RUNTIME_FINGERPRINT" ]; then
        mw_journal_state=input-mismatch
        [ "$mw_status_exit" -ne 0 ] || mw_status_exit=1
      elif ! mw_is_uint "$mw_journal_epoch"; then
        mw_journal_state=unsafe
        mw_status_exit=3
      elif [ "$mw_journal_epoch" -gt "$mw_status_now" ]; then
        mw_journal_state=invalid-or-clock-rollback
        mw_status_exit=3
      elif mw_committed_state_supersedes_unmount_journal \
        "$mw_journal_fingerprint" "$mw_journal_epoch"; then
        mw_journal_state=superseded
      elif [ "$mw_journal_epoch" -eq "$mw_last_attempt_epoch" ] &&
        [ "$MW_JOURNAL_REFRESH_REQUIRED" = 1 ] &&
        [ "$mw_last_action" = autofs-refresh ] &&
        [ "$MW_PREV_CHECKED" -ge "$mw_journal_epoch" ]; then
        mw_pending=$MW_JOURNAL_PENDING
        mw_journal_state=$MW_JOURNAL_PHASE
        case "$mw_action" in
          manual-attention) [ "$mw_status_exit" -eq 3 ] || mw_status_exit=2 ;;
          *) [ "$mw_status_exit" -ne 0 ] || mw_status_exit=1 ;;
        esac
      elif [ "$mw_journal_epoch" -eq "$mw_last_attempt_epoch" ] && {
        [ "$mw_last_action" != normal-unmount ] ||
          [ "$mw_last_result" != "$MW_JOURNAL_RESULT" ] ||
          [ "$mw_last_exit_status" != "$MW_JOURNAL_EXIT_STATUS" ] ||
          [ "$MW_PREV_CHECKED" -lt "$mw_journal_epoch" ];
      }; then
        mw_journal_state=conflicting
        mw_action=manual-attention
        mw_last_error=unmount-attempt-not-finalized
        mw_status_exit=3
      elif [ "$mw_journal_epoch" -ge "$mw_last_attempt_epoch" ]; then
        mw_last_action=normal-unmount
        mw_last_result=$MW_JOURNAL_RESULT
        mw_last_exit_status=$MW_JOURNAL_EXIT_STATUS
        mw_last_error=$MW_JOURNAL_LAST_ERROR
        mw_pending=$MW_JOURNAL_PENDING
        mw_journal_state=$MW_JOURNAL_PHASE
        mw_action=$MW_JOURNAL_ACTION_STATE
        case "$mw_action" in
          manual-attention) [ "$mw_status_exit" -eq 3 ] || mw_status_exit=2 ;;
          *) [ "$mw_status_exit" -ne 0 ] || mw_status_exit=1 ;;
        esac
      elif [ "$MW_JOURNAL_REFRESH_REQUIRED" = 1 ]; then
        mw_journal_state=$MW_JOURNAL_PHASE
        if [ "$mw_pending" = none ] && [ "$mw_action" = idle ]; then
          mw_pending=$MW_JOURNAL_PENDING
          mw_action=refresh-required
        fi
        [ "$mw_status_exit" -ne 0 ] || mw_status_exit=1
      fi
    fi
  fi
  printf 'state=%s checked_at=%s\n' "$mw_state" "$mw_checked"
  printf 'pending_recovery=%s action_state=%s\n' "$mw_pending" "$mw_action"
  printf 'last_attempt=%s last_attempt_result=%s last_error=%s last_attempt_exit_status=%s\n' \
    "$mw_last_action" "$mw_last_result" "$mw_last_error" "$mw_last_exit_status"
  printf 'last_successful_action=%s\n' "$mw_last_success"
  [ "$mw_journal_state" = none ] || printf 'durable_unmount_attempt=%s\n' "$mw_journal_state"
  case "$mw_journal_state:$MW_JOURNAL_REFRESH_REQUIRED" in
    attempting:1|complete:1) printf 'durable_unmount_refresh=required\n' ;;
  esac
  case "$mw_action" in
    manual-attention) [ "$mw_status_exit" -eq 3 ] || mw_status_exit=2 ;;
    deferred-*|unmount-required|refresh-required) [ "$mw_status_exit" -ne 0 ] || mw_status_exit=1 ;;
  esac
  mw_index=$((mw_index + 1))
done

exit "$mw_status_exit"
