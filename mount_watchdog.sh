#!/bin/bash
# shellcheck disable=SC1090,SC2034,SC2004,SC2329
set +x

# MountWatchdog periodic runtime. It observes mount metadata and TCP 445 only.
# It never reads, stats, creates, or enumerates content under a managed path.

PATH=/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
export PATH LC_ALL
umask 077

case "$0" in /*) mw_entry_path=$0 ;; *) mw_entry_path=$PWD/$0 ;; esac
mw_script_dir=${mw_entry_path%/*}
mw_common_file=$mw_script_dir/lib/common.sh
mw_runtime_file=$mw_script_dir/lib/runtime.sh
mw_autofs_file=$mw_script_dir/lib/autofs.sh

mw_bootstrap_acl_policy_is_safe() {
  mw_bootstrap_acl_path=$1
  mw_bootstrap_acl_policy=$2
  mw_bootstrap_acl_output=$(/bin/ls -lde "$mw_bootstrap_acl_path" 2>/dev/null) || return 1
  if /bin/chmod -C "$mw_bootstrap_acl_path" >/dev/null 2>&1; then
    return 1
  fi
  printf '%s\n' "$mw_bootstrap_acl_output" | /usr/bin/awk -v policy="$mw_bootstrap_acl_policy" '
    NR == 1 { header_seen = 1; next }
    {
      if ($1 !~ /^[0-9]+:$/ || NF < 4 || $(NF - 1) != "deny") exit 1
      entries++
    }
    END {
      if (!header_seen) exit 1
      if (policy == "none" && entries != 0) exit 1
    }
  '
}

mw_test_requested=0
[ -z "${MW_TEST_ROOT:-}${MW_TEST_COMMAND_DIR:-}" ] || mw_test_requested=1
if [ "$mw_test_requested" -eq 1 ] && [ "$EUID" -eq 0 ]; then
  printf 'MountWatchdog: test backend is disabled before source loading for root\n' >&2
  exit 70
fi
if [ "$mw_test_requested" -eq 0 ]; then
  [ "$EUID" -eq 0 ] || { printf 'MountWatchdog: periodic runtime must run as root\n' >&2; exit 70; }
  [ "$mw_script_dir" = '/Library/Application Support/MountWatchdog' ] || {
    printf 'MountWatchdog: production runtime path is not canonical\n' >&2
    exit 70
  }
  for mw_trusted_path in /Library '/Library/Application Support'; do
    [ -d "$mw_trusted_path" ] && [ ! -L "$mw_trusted_path" ] || exit 70
    mw_trusted_meta=$(/usr/bin/stat -f '%Su|%Lp' "$mw_trusted_path" 2>/dev/null) || exit 70
    [ "${mw_trusted_meta%%|*}" = root ] || exit 70
    mw_trusted_mode=${mw_trusted_meta#*|}
    case "$mw_trusted_mode" in ''|*[!0-7]*) exit 70 ;; esac
    [ $(( (10#$mw_trusted_mode / 10) % 10 & 2 )) -eq 0 ] || exit 70
    [ $(( 10#$mw_trusted_mode % 10 & 2 )) -eq 0 ] || exit 70
    mw_bootstrap_acl_policy_is_safe "$mw_trusted_path" deny-only || exit 70
  done
  for mw_trusted_path in "$mw_script_dir" "$mw_script_dir/lib"; do
    [ -d "$mw_trusted_path" ] && [ ! -L "$mw_trusted_path" ] || exit 70
    mw_trusted_meta=$(/usr/bin/stat -f '%Su|%Lp' "$mw_trusted_path" 2>/dev/null) || exit 70
    [ "${mw_trusted_meta%%|*}" = root ] || exit 70
    mw_trusted_mode=${mw_trusted_meta#*|}
    case "$mw_trusted_mode" in ''|*[!0-7]*) exit 70 ;; esac
    [ $(( (10#$mw_trusted_mode / 10) % 10 & 2 )) -eq 0 ] || exit 70
    [ $(( 10#$mw_trusted_mode % 10 & 2 )) -eq 0 ] || exit 70
    mw_bootstrap_acl_policy_is_safe "$mw_trusted_path" none || exit 70
  done
  for mw_trusted_path in "$mw_entry_path" "$mw_common_file" "$mw_runtime_file" "$mw_autofs_file" \
    "$mw_script_dir/defaults.conf" "$mw_script_dir/mounts.conf" "$mw_script_dir/VERSION"; do
    [ -f "$mw_trusted_path" ] && [ ! -L "$mw_trusted_path" ] || exit 70
    mw_trusted_meta=$(/usr/bin/stat -f '%Su|%Lp' "$mw_trusted_path" 2>/dev/null) || exit 70
    [ "${mw_trusted_meta%%|*}" = root ] || exit 70
    mw_trusted_mode=${mw_trusted_meta#*|}
    case "$mw_trusted_mode" in ''|*[!0-7]*) exit 70 ;; esac
    [ $(( (10#$mw_trusted_mode / 10) % 10 & 2 )) -eq 0 ] || exit 70
    [ $(( 10#$mw_trusted_mode % 10 & 2 )) -eq 0 ] || exit 70
    mw_bootstrap_acl_policy_is_safe "$mw_trusted_path" none || exit 70
  done
fi
[ -f "$mw_common_file" ] && [ ! -L "$mw_common_file" ] || {
  printf 'MountWatchdog: missing trusted common library\n' >&2
  exit 70
}
[ -f "$mw_runtime_file" ] && [ ! -L "$mw_runtime_file" ] || {
  printf 'MountWatchdog: missing trusted runtime library\n' >&2
  exit 70
}
[ -f "$mw_autofs_file" ] && [ ! -L "$mw_autofs_file" ] || {
  printf 'MountWatchdog: missing trusted autofs library\n' >&2
  exit 70
}
. "$mw_common_file"
. "$mw_runtime_file"
. "$mw_autofs_file"
MW_RUNTIME_PROGRAM_FILE=$mw_entry_path
MW_RUNTIME_COMMON_FILE=$mw_common_file
MW_RUNTIME_LIBRARY_FILE=$mw_runtime_file
MW_RUNTIME_AUTOFS_FILE=$mw_autofs_file

mw_invocation_mode=tick
case "$#:${1:-}" in
  0:) ;;
  1:--acknowledge-manual-attention) mw_invocation_mode=acknowledge ;;
  *)
    mw_error 'usage: mount_watchdog.sh [--acknowledge-manual-attention]'
    mw_error 'use the separate status command for read-only diagnostics'
    exit 64
    ;;
esac

mw_runtime_init_paths runtime || exit 70
mw_parse_defaults "$MW_DEFAULTS_FILE" || exit 70
mw_parse_config "$MW_CONFIG_FILE" || exit 70
mw_compute_runtime_fingerprint || { mw_error 'could not fingerprint runtime inputs'; exit 70; }
mw_prepare_runtime_state || exit 70

MW_LOCK_HELD=0
mw_acquire_lock
mw_lock_rc=$?
if [ "$mw_lock_rc" -eq 75 ]; then
  if [ "$mw_invocation_mode" = acknowledge ]; then
    mw_error 'cannot acknowledge while a watchdog tick owns the runtime lock'
    exit 75
  fi
  exit 0
fi
[ "$mw_lock_rc" -eq 0 ] || exit 70
mw_clear_active_command
MW_HEARTBEAT_RUNNING_WRITTEN=0
MW_HEARTBEAT_TERMINAL_WRITTEN=0
MW_RUNTIME_EXIT_HEARTBEAT_RESULT=internal-error
mw_write_terminal_heartbeat() {
  mw_write_heartbeat complete "$1" || return 1
  MW_HEARTBEAT_TERMINAL_WRITTEN=1
}
mw_runtime_exit_cleanup() {
  mw_cleanup_exit_status=$?
  trap - EXIT
  trap '' HUP INT QUIT TERM
  if [ "$MW_HEARTBEAT_RUNNING_WRITTEN" -eq 1 ] &&
    [ "$MW_HEARTBEAT_TERMINAL_WRITTEN" -ne 1 ]; then
    if mw_now_epoch && mw_now_iso; then
      MW_TICK_COMPLETED_EPOCH=$MW_NOW_EPOCH
    else
      MW_TICK_COMPLETED_EPOCH=${MW_TICK_STARTED_EPOCH:-0}
    fi
    mw_write_terminal_heartbeat "$MW_RUNTIME_EXIT_HEARTBEAT_RESULT" || true
  fi
  mw_release_lock
  exit "$mw_cleanup_exit_status"
}
mw_handle_runtime_signal() {
  mw_signal_exit=$1
  trap '' HUP INT QUIT TERM
  MW_RUNTIME_EXIT_HEARTBEAT_RESULT=interrupted
  if ! mw_terminate_active_command_group; then
    MW_RUNTIME_EXIT_HEARTBEAT_RESULT=interrupted-command-blocked
  fi
  exit "$mw_signal_exit"
}
trap 'mw_runtime_exit_cleanup' EXIT
trap 'mw_handle_runtime_signal 129' HUP
trap 'mw_handle_runtime_signal 130' INT
trap 'mw_handle_runtime_signal 131' QUIT
trap 'mw_handle_runtime_signal 143' TERM

if ! mw_now_epoch || ! mw_now_iso; then
  mw_error 'could not read the clock'
  exit 70
fi
MW_TICK_STARTED_EPOCH=$MW_NOW_EPOCH
MW_TICK_COMPLETED_EPOCH=0
MW_WRITE_COUNTER=0

if ! mw_validate_mount_state_dirs; then
  MW_TICK_COMPLETED_EPOCH=$MW_NOW_EPOCH
  mw_write_terminal_heartbeat "unsafe-mount-state-directory-$MW_UNSAFE_MOUNT_STATE_NAME" || true
  mw_error "unsafe per-mount state directory: $MW_UNSAFE_MOUNT_STATE_NAME"
  exit 70
fi
if ! mw_validate_runtime_state_leaves; then
  MW_TICK_COMPLETED_EPOCH=$MW_NOW_EPOCH
  case "$MW_UNSAFE_STATE_LEAF" in
    heartbeat) ;;
    *) mw_write_terminal_heartbeat "unsafe-state-leaf-$MW_UNSAFE_STATE_LEAF" || true ;;
  esac
  mw_error "unsafe runtime state leaf: $MW_UNSAFE_STATE_LEAF"
  exit 70
fi
if ! mw_cleanup_runtime_orphan_temps; then
  MW_TICK_COMPLETED_EPOCH=$MW_NOW_EPOCH
  mw_write_terminal_heartbeat "unsafe-state-leaf-$MW_UNSAFE_STATE_LEAF" || true
  mw_error "could not safely remove orphaned runtime temporary file: $MW_UNSAFE_STATE_LEAF"
  exit 70
fi

mw_acknowledge_error_is_clearable() {
  case "$1" in
    network-probe-timed-out|network-probe-supervision-failed|pre-action-inspection-failed|\
    target-changed-before-unmount|network-recheck-timed-out|unmount-attempt-journal-failed|\
    expected-smb-still-present-after-unmount|post-unmount-inspection-failed|\
    normal-unmount-verification-failed|normal-unmount-timed-out|normal-unmount-supervision-failed|\
    trigger-still-missing-after-refresh|unexpected-layer-after-refresh|post-refresh-inspection-failed|\
    autofs-refresh-timed-out|autofs-refresh-supervision-failed|unexpected-or-ambiguous-mount-layer)
      return 0
      ;;
  esac
  return 1
}

mw_acknowledge_manual_attention() {
  if mw_global_block_is_active; then
    mw_error "cannot acknowledge while blocked command evidence is active: $MW_GLOBAL_BLOCK_REASON"
    return 2
  fi
  if ! mw_validate_runtime_autofs_configuration; then
    mw_error "cannot acknowledge while autofs configuration drift remains: $MW_AUTOFS_DRIFT_REASON"
    return 2
  fi

  mw_ack_global_refresh=0
  mw_ack_refresh_file=$MW_STATE_DIR/autofs-refresh
  if [ -e "$mw_ack_refresh_file" ] || [ -L "$mw_ack_refresh_file" ]; then
    mw_read_autofs_refresh_record "$mw_ack_refresh_file" || {
      mw_error 'cannot acknowledge an invalid autofs refresh record'
      return 70
    }
    mw_ack_refresh_fingerprint=$(mw_state_value "$mw_ack_refresh_file" runtime_fingerprint 2>/dev/null || true)
    mw_ack_refresh_epoch=$(mw_state_value "$mw_ack_refresh_file" last_attempt_epoch 2>/dev/null || true)
    [ "$mw_ack_refresh_fingerprint" = "$MW_RUNTIME_FINGERPRINT" ] &&
      mw_is_uint "$mw_ack_refresh_epoch" && [ "$mw_ack_refresh_epoch" -le "$MW_NOW_EPOCH" ] || {
      mw_error 'cannot acknowledge stale or clock-invalid autofs refresh evidence'
      return 70
    }
    case "$MW_REFRESH_RECORD_RESULT" in
      timed-out|supervision-failed) mw_ack_global_refresh=1 ;;
    esac
  fi

  mw_make_temp "$MW_STATE_DIR" .mount-snapshot || {
    mw_error 'cannot create a safe mount snapshot for acknowledgment'
    return 70
  }
  mw_ack_snapshot=$MW_TEMP_PATH
  if ! mw_capture_mount_snapshot "$mw_ack_snapshot"; then
    /bin/rm -f "$mw_ack_snapshot" 2>/dev/null || true
    mw_error 'cannot acknowledge without a successful read-only mount snapshot'
    return 70
  fi

  MW_ACKNOWLEDGE_INDEXES=()
  mw_ack_index=0
  while [ "$mw_ack_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
    mw_ack_state_dir=$MW_STATE_DIR/${MW_MOUNT_NAMES[$mw_ack_index]}
    mw_ack_state_file=$mw_ack_state_dir/status
    mw_ack_journal=$mw_ack_state_dir/unmount-attempt
    if [ -e "$mw_ack_journal" ] || [ -L "$mw_ack_journal" ]; then
      /bin/rm -f "$mw_ack_snapshot" 2>/dev/null || true
      mw_error "cannot acknowledge while durable unmount evidence remains for slot $((mw_ack_index + 1))"
      return 2
    fi
    [ -f "$mw_ack_state_file" ] && [ ! -L "$mw_ack_state_file" ] || {
      /bin/rm -f "$mw_ack_snapshot" 2>/dev/null || true
      mw_error "cannot acknowledge without trusted state for slot $((mw_ack_index + 1))"
      return 70
    }
    mw_load_mount_state "$mw_ack_state_file"
    [ "$MW_STATE_VALID" -eq 1 ] && [ "$MW_PREV_FINGERPRINT" = "$MW_RUNTIME_FINGERPRINT" ] &&
      [ "$MW_PREV_CHECKED" -le "$MW_NOW_EPOCH" ] || {
      /bin/rm -f "$mw_ack_snapshot" 2>/dev/null || true
      mw_error "cannot acknowledge invalid or stale-input state for slot $((mw_ack_index + 1))"
      return 70
    }
    mw_classify_snapshot "$mw_ack_snapshot" "${MW_MOUNT_PATHS[$mw_ack_index]}" \
      "${MW_MOUNT_HOSTS[$mw_ack_index]}" "${MW_MOUNT_SHARES[$mw_ack_index]}"
    case "$MW_MOUNT_CLASS" in
      expected-smb|trigger-only|trigger-missing) ;;
      *)
        /bin/rm -f "$mw_ack_snapshot" 2>/dev/null || true
        mw_error "cannot acknowledge while slot $((mw_ack_index + 1)) has an unexpected or ambiguous mount layer"
        return 2
        ;;
    esac
    if [ "$MW_PREV_ACTION" = manual-attention ]; then
      mw_acknowledge_error_is_clearable "$MW_PREV_LAST_ERROR" || {
        /bin/rm -f "$mw_ack_snapshot" 2>/dev/null || true
        mw_error "manual-attention reason is not owner-clearable for slot $((mw_ack_index + 1)): $MW_PREV_LAST_ERROR"
        return 2
      }
      MW_ACKNOWLEDGE_INDEXES[${#MW_ACKNOWLEDGE_INDEXES[@]}]=$mw_ack_index
    fi
    mw_ack_index=$((mw_ack_index + 1))
  done

  if [ "$mw_ack_global_refresh" -eq 0 ] && [ "${#MW_ACKNOWLEDGE_INDEXES[@]}" -eq 0 ]; then
    /bin/rm -f "$mw_ack_snapshot" 2>/dev/null || true
    mw_error 'no reviewed manual-attention latch is eligible for acknowledgment'
    return 2
  fi
  if ! mw_validate_runtime_autofs_configuration; then
    /bin/rm -f "$mw_ack_snapshot" 2>/dev/null || true
    mw_error "autofs configuration changed during acknowledgment: $MW_AUTOFS_DRIFT_REASON"
    return 2
  fi

  if [ "$mw_ack_global_refresh" -eq 1 ]; then
    /bin/rm -f "$mw_ack_refresh_file" || {
      /bin/rm -f "$mw_ack_snapshot" 2>/dev/null || true
      mw_error 'could not retire acknowledged autofs refresh evidence'
      return 70
    }
  fi

  mw_ack_position=0
  while [ "$mw_ack_position" -lt "${#MW_ACKNOWLEDGE_INDEXES[@]}" ]; do
    mw_ack_index=${MW_ACKNOWLEDGE_INDEXES[$mw_ack_position]}
    mw_ack_state_file=$MW_STATE_DIR/${MW_MOUNT_NAMES[$mw_ack_index]}/status
    mw_load_mount_state "$mw_ack_state_file"
    if [ "$MW_STATE_VALID" -ne 1 ] || [ "$MW_PREV_FINGERPRINT" != "$MW_RUNTIME_FINGERPRINT" ] ||
      [ "$MW_PREV_ACTION" != manual-attention ] || ! mw_acknowledge_error_is_clearable "$MW_PREV_LAST_ERROR"; then
      /bin/rm -f "$mw_ack_snapshot" 2>/dev/null || true
      mw_error "manual-attention state changed during acknowledgment for slot $((mw_ack_index + 1))"
      return 70
    fi
    mw_classify_snapshot "$mw_ack_snapshot" "${MW_MOUNT_PATHS[$mw_ack_index]}" \
      "${MW_MOUNT_HOSTS[$mw_ack_index]}" "${MW_MOUNT_SHARES[$mw_ack_index]}"
    mw_ack_summary=$(mw_summary_state "$MW_MOUNT_CLASS" unknown)
    mw_atomic_write_lines "$mw_ack_state_file" \
      "format|$MW_STATE_FORMAT" \
      "checked_at_epoch|$MW_NOW_EPOCH" \
      "checked_at|$MW_NOW_ISO" \
      "mount_name|${MW_MOUNT_NAMES[$mw_ack_index]}" \
      "mount_path|${MW_MOUNT_PATHS[$mw_ack_index]}" \
      "expected_host|${MW_MOUNT_HOSTS[$mw_ack_index]}" \
      "expected_share|${MW_MOUNT_SHARES[$mw_ack_index]}" \
      "state|$mw_ack_summary" \
      "mount_state|$MW_MOUNT_CLASS" \
      'network_state|unknown' \
      "last_network_state|$MW_PREV_NETWORK" \
      "check_scope|$MW_CHECK_SCOPE" \
      "readability|$MW_READABILITY" \
      "runtime_fingerprint|$MW_RUNTIME_FINGERPRINT" \
      'initialized|1' \
      "pending_recovery|$MW_PREV_PENDING" \
      "pending_since_epoch|$MW_PREV_PENDING_SINCE" \
      'action_state|idle' \
      "last_attempt_epoch|$MW_PREV_LAST_ATTEMPT" \
      "last_attempt_action|$MW_PREV_LAST_ATTEMPT_ACTION" \
      "last_attempt_result|$MW_PREV_LAST_ATTEMPT_RESULT" \
      "last_attempt_exit_status|$MW_PREV_LAST_ATTEMPT_EXIT_STATUS" \
      "last_successful_action_epoch|$MW_PREV_LAST_SUCCESS" \
      "last_successful_action|$MW_PREV_LAST_SUCCESS_ACTION" \
      'last_error|none' \
      'blocked_pid|none' || {
      /bin/rm -f "$mw_ack_snapshot" 2>/dev/null || true
      mw_error "could not commit acknowledged state for slot $((mw_ack_index + 1))"
      return 70
    }
    mw_ack_position=$((mw_ack_position + 1))
  done
  /bin/rm -f "$mw_ack_snapshot" || {
    mw_error 'could not remove acknowledgment mount snapshot'
    return 70
  }
  MW_TICK_COMPLETED_EPOCH=$MW_NOW_EPOCH
  mw_write_terminal_heartbeat pending || {
    mw_error 'could not commit post-acknowledgment heartbeat'
    return 70
  }
  mw_log_global_event owner-acknowledgment manual-attention reviewed-latch-cleared pending-reevaluation
  printf 'MountWatchdog acknowledged %s per-mount latch(es); global refresh latch acknowledged=%s.\n' \
    "${#MW_ACKNOWLEDGE_INDEXES[@]}" "$mw_ack_global_refresh"
  printf 'No mount, network probe, unmount, or autofs refresh was performed; wait for the next scheduled tick.\n'
  return 0
}

if [ "$mw_invocation_mode" = acknowledge ]; then
  mw_acknowledge_manual_attention
  exit $?
fi

mw_previous_heartbeat=$MW_STATE_DIR/heartbeat
mw_gap_detected=0
mw_clock_rollback=0
if [ -f "$mw_previous_heartbeat" ] && [ ! -L "$mw_previous_heartbeat" ] &&
  [ "$(mw_state_value "$mw_previous_heartbeat" format 2>/dev/null || true)" = "$MW_STATE_FORMAT" ] &&
  [ "$(mw_state_value "$mw_previous_heartbeat" phase 2>/dev/null || true)" = complete ] &&
  [ "$(mw_state_value "$mw_previous_heartbeat" runtime_fingerprint 2>/dev/null || true)" = "$MW_RUNTIME_FINGERPRINT" ]; then
  mw_previous_completed=$(mw_state_value "$mw_previous_heartbeat" completed_epoch 2>/dev/null || true)
  if mw_is_uint "$mw_previous_completed" && [ "$MW_NOW_EPOCH" -ge "$mw_previous_completed" ] &&
    [ $((MW_NOW_EPOCH - mw_previous_completed)) -gt "$MW_SCHEDULING_GAP_SECONDS" ]; then
    mw_gap_detected=1
  elif mw_is_uint "$mw_previous_completed" && [ "$MW_NOW_EPOCH" -lt "$mw_previous_completed" ]; then
    mw_clock_rollback=1
  fi
fi
MW_HEARTBEAT_RUNNING_WRITTEN=1
if ! mw_write_heartbeat running in-progress; then
  MW_HEARTBEAT_RUNNING_WRITTEN=0
  exit 70
fi

mw_reset_previous_to_baseline() {
  MW_PREV_INITIALIZED=0
  MW_PREV_CHECKED=0
  MW_PREV_SUMMARY=uninitialized
  MW_PREV_NETWORK=unknown
  MW_PREV_PENDING=none
  MW_PREV_PENDING_SINCE=0
  MW_PREV_LAST_ATTEMPT=0
  MW_PREV_LAST_ATTEMPT_ACTION=never
  MW_PREV_LAST_ATTEMPT_RESULT=never
  MW_PREV_LAST_ATTEMPT_EXIT_STATUS=not-run
  MW_PREV_UNMOUNT_REFRESH_REQUIRED=0
  MW_PREV_UNMOUNT_CONFIRMED=0
  MW_PREV_LAST_SUCCESS=0
  MW_PREV_LAST_SUCCESS_ACTION=never
  MW_PREV_ACTION=idle
  MW_PREV_BLOCKED_PID=none
  MW_PREV_LAST_ERROR=none
}

mw_normalize_previous_for_tick() {
  mw_mount_clock_rollback=$mw_clock_rollback
  if [ "$MW_PREV_FINGERPRINT" = "$MW_RUNTIME_FINGERPRINT" ] &&
    [ "$MW_STATE_VALID" -eq 1 ]; then
    if [ "$MW_PREV_CHECKED" -gt "$MW_NOW_EPOCH" ] ||
      [ "$MW_PREV_PENDING_SINCE" -gt "$MW_NOW_EPOCH" ] ||
      [ "$MW_PREV_LAST_ATTEMPT" -gt "$MW_NOW_EPOCH" ] ||
      [ "$MW_PREV_LAST_SUCCESS" -gt "$MW_NOW_EPOCH" ]; then
      mw_mount_clock_rollback=1
    fi
  fi
  if [ "$MW_PREV_FINGERPRINT" != "$MW_RUNTIME_FINGERPRINT" ] ||
    [ "$mw_mount_clock_rollback" -eq 1 ]; then
    mw_reset_previous_to_baseline
  fi
}

MW_OBS=()
MW_NET=()
MW_LAST_NET=()
MW_INITIALIZED=()
MW_PENDING=()
MW_PENDING_SINCE=()
MW_ACTION=()
MW_LAST_ATTEMPT=()
MW_LAST_ATTEMPT_ACTION=()
MW_LAST_ATTEMPT_RESULT=()
MW_LAST_ATTEMPT_EXIT_STATUS=()
MW_LAST_SUCCESS=()
MW_LAST_SUCCESS_ACTION=()
MW_LAST_ERROR=()
MW_BLOCKED_PID=()
MW_WANT_UNMOUNT=()
MW_WANT_REFRESH=()
MW_DID_UNMOUNT=()
MW_CONTINUE_REFRESH=()
MW_PREV_SUMMARIES=()

mw_block_actions_for_configuration_drift() {
  mw_drift_reason=$1
  mw_drift_index=0
  while [ "$mw_drift_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
    MW_ACTION[$mw_drift_index]=configuration-drift
    MW_LAST_ERROR[$mw_drift_index]=$mw_drift_reason
    MW_BLOCKED_PID[$mw_drift_index]=none
    MW_WANT_UNMOUNT[$mw_drift_index]=0
    MW_WANT_REFRESH[$mw_drift_index]=0
    mw_drift_index=$((mw_drift_index + 1))
  done
  mw_log_global_event inspection autofs-configuration "$mw_drift_reason" configuration-drift
}

mw_commit_initial_configuration_drift() {
  mw_initial_drift_reason=$1
  mw_initial_drift_write_failed=0
  mw_initial_drift_index=0
  while [ "$mw_initial_drift_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
    mw_load_mount_state "$MW_STATE_DIR/${MW_MOUNT_NAMES[$mw_initial_drift_index]}/status"
    mw_normalize_previous_for_tick
    if ! mw_apply_unmount_attempt_journal "$MW_STATE_DIR/${MW_MOUNT_NAMES[$mw_initial_drift_index]}"; then
      MW_STATE_VALID=0
    fi
    MW_PREV_SUMMARIES[$mw_initial_drift_index]=$MW_PREV_SUMMARY
    MW_OBS[$mw_initial_drift_index]=inspection-error
    MW_NET[$mw_initial_drift_index]=unknown
    MW_LAST_NET[$mw_initial_drift_index]=$MW_PREV_NETWORK
    MW_INITIALIZED[$mw_initial_drift_index]=$MW_PREV_INITIALIZED
    MW_PENDING[$mw_initial_drift_index]=$MW_PREV_PENDING
    MW_PENDING_SINCE[$mw_initial_drift_index]=$MW_PREV_PENDING_SINCE
    MW_ACTION[$mw_initial_drift_index]=configuration-drift
    MW_LAST_ATTEMPT[$mw_initial_drift_index]=$MW_PREV_LAST_ATTEMPT
    MW_LAST_ATTEMPT_ACTION[$mw_initial_drift_index]=$MW_PREV_LAST_ATTEMPT_ACTION
    MW_LAST_ATTEMPT_RESULT[$mw_initial_drift_index]=$MW_PREV_LAST_ATTEMPT_RESULT
    MW_LAST_ATTEMPT_EXIT_STATUS[$mw_initial_drift_index]=$MW_PREV_LAST_ATTEMPT_EXIT_STATUS
    MW_LAST_SUCCESS[$mw_initial_drift_index]=$MW_PREV_LAST_SUCCESS
    MW_LAST_SUCCESS_ACTION[$mw_initial_drift_index]=$MW_PREV_LAST_SUCCESS_ACTION
    MW_LAST_ERROR[$mw_initial_drift_index]=$mw_initial_drift_reason
    MW_BLOCKED_PID[$mw_initial_drift_index]=none
    MW_WANT_UNMOUNT[$mw_initial_drift_index]=0
    MW_WANT_REFRESH[$mw_initial_drift_index]=0
    MW_DID_UNMOUNT[$mw_initial_drift_index]=$MW_PREV_UNMOUNT_CONFIRMED
    MW_CONTINUE_REFRESH[$mw_initial_drift_index]=$MW_PREV_UNMOUNT_REFRESH_REQUIRED
    mw_write_mount_status_index "$mw_initial_drift_index" || mw_initial_drift_write_failed=1
    mw_initial_drift_index=$((mw_initial_drift_index + 1))
  done
  mw_log_global_event inspection autofs-configuration "$mw_initial_drift_reason" configuration-drift
  MW_TICK_COMPLETED_EPOCH=$MW_NOW_EPOCH
  if [ "$mw_initial_drift_write_failed" -eq 1 ]; then
    mw_write_terminal_heartbeat state-write-error || true
    return 70
  fi
  mw_write_terminal_heartbeat configuration-drift || return 70
  return 2
}

if mw_global_block_is_active; then
  MW_TICK_COMPLETED_EPOCH=$MW_NOW_EPOCH
  mw_write_terminal_heartbeat "blocked-command-$MW_GLOBAL_BLOCK_REASON" || true
  exit 2
fi

if ! mw_validate_runtime_autofs_configuration; then
  mw_commit_initial_configuration_drift "$MW_AUTOFS_DRIFT_REASON"
  exit $?
fi

mw_global_refresh_file=$MW_STATE_DIR/autofs-refresh
mw_global_last_refresh=0
mw_global_refresh_uncommitted=0
mw_global_refresh_manual_attention=0
if [ -e "$mw_global_refresh_file" ] || [ -L "$mw_global_refresh_file" ]; then
  mw_regular_file_is_trusted "$mw_global_refresh_file" || {
    mw_log_global_event supervisor autofs-refresh unsafe-attempt-journal fail-closed
    exit 70
  }
  mw_global_refresh_fingerprint=$(mw_state_value "$mw_global_refresh_file" runtime_fingerprint 2>/dev/null || true)
  mw_global_refresh_epoch=$(mw_state_value "$mw_global_refresh_file" last_attempt_epoch 2>/dev/null || true)
  if [ "$mw_global_refresh_fingerprint" != "$MW_RUNTIME_FINGERPRINT" ] ||
    ! mw_is_uint "$mw_global_refresh_epoch" ||
    [ "$mw_global_refresh_epoch" -gt "$MW_NOW_EPOCH" ]; then
    /bin/rm -f "$mw_global_refresh_file" || exit 70
  else
    mw_read_autofs_refresh_record "$mw_global_refresh_file" || {
      mw_log_global_event supervisor autofs-refresh invalid-attempt-record fail-closed
      exit 70
    }
    case "$MW_REFRESH_RECORD_RESULT" in
      attempting) mw_global_refresh_uncommitted=1 ;;
      timed-out|supervision-failed) mw_global_refresh_manual_attention=1 ;;
    esac
    mw_global_last_refresh=$mw_global_refresh_epoch
  fi
fi
mw_global_refresh_eligible=1
if [ $((MW_NOW_EPOCH - mw_global_last_refresh)) -lt "$MW_RECOVERY_COOLDOWN_SECONDS" ]; then
  mw_global_refresh_eligible=0
fi

mw_make_temp "$MW_STATE_DIR" .mount-snapshot || exit 70
mw_snapshot=$MW_TEMP_PATH
if ! mw_capture_mount_snapshot "$mw_snapshot"; then
  mw_snapshot_failure_reason=mount-snapshot-failed
  [ "${MW_RUN_RC:-0}" -ne 124 ] || mw_snapshot_failure_reason=mount-snapshot-timeout
  mw_log_global_event inspection observe "$mw_snapshot_failure_reason" failed
  mw_index=0
  while [ "$mw_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
    mw_state_file=$MW_STATE_DIR/${MW_MOUNT_NAMES[$mw_index]}/status
    mw_load_mount_state "$mw_state_file"
    mw_normalize_previous_for_tick
    if ! mw_apply_unmount_attempt_journal "$MW_STATE_DIR/${MW_MOUNT_NAMES[$mw_index]}"; then
      MW_STATE_VALID=0
    fi
    MW_OBS[$mw_index]=inspection-error
    MW_NET[$mw_index]=unknown
    MW_LAST_NET[$mw_index]=$MW_PREV_NETWORK
    MW_INITIALIZED[$mw_index]=$MW_PREV_INITIALIZED
    MW_PENDING[$mw_index]=$MW_PREV_PENDING
    MW_PENDING_SINCE[$mw_index]=$MW_PREV_PENDING_SINCE
    MW_ACTION[$mw_index]=manual-attention
    MW_LAST_ATTEMPT[$mw_index]=$MW_PREV_LAST_ATTEMPT
    MW_LAST_ATTEMPT_ACTION[$mw_index]=$MW_PREV_LAST_ATTEMPT_ACTION
    MW_LAST_ATTEMPT_RESULT[$mw_index]=$MW_PREV_LAST_ATTEMPT_RESULT
    MW_LAST_ATTEMPT_EXIT_STATUS[$mw_index]=$MW_PREV_LAST_ATTEMPT_EXIT_STATUS
    MW_CONTINUE_REFRESH[$mw_index]=$MW_PREV_UNMOUNT_REFRESH_REQUIRED
    MW_DID_UNMOUNT[$mw_index]=$MW_PREV_UNMOUNT_CONFIRMED
    MW_LAST_SUCCESS[$mw_index]=$MW_PREV_LAST_SUCCESS
    MW_LAST_SUCCESS_ACTION[$mw_index]=$MW_PREV_LAST_SUCCESS_ACTION
    MW_LAST_ERROR[$mw_index]=mount-inspection-failed
    MW_BLOCKED_PID[$mw_index]=${MW_RUN_BLOCKED_PID:-none}
    if mw_write_mount_status_index "$mw_index" &&
      [ "${MW_CONTINUE_REFRESH[$mw_index]}" -ne 1 ]; then
      mw_retire_committed_unmount_journal "$MW_STATE_DIR/${MW_MOUNT_NAMES[$mw_index]}" \
        "${MW_LAST_ATTEMPT[$mw_index]}" || true
    fi
    mw_index=$((mw_index + 1))
  done
  MW_TICK_COMPLETED_EPOCH=$MW_NOW_EPOCH
  mw_write_terminal_heartbeat inspection-error || true
  /bin/rm -f "$mw_snapshot" 2>/dev/null || true
  exit 70
fi

MW_PROBE_HOSTS=()
MW_PROBE_RESULTS=()
MW_PROBE_BLOCKED_PIDS=()
MW_PROBE_ERRORS=()
mw_global_refresh_all_satisfied=1
mw_index=0
while [ "$mw_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
  mw_name=${MW_MOUNT_NAMES[$mw_index]}
  mw_path=${MW_MOUNT_PATHS[$mw_index]}
  mw_host=${MW_MOUNT_HOSTS[$mw_index]}
  mw_share=${MW_MOUNT_SHARES[$mw_index]}
  mw_load_mount_state "$MW_STATE_DIR/$mw_name/status"
  mw_normalize_previous_for_tick
  if ! mw_apply_unmount_attempt_journal "$MW_STATE_DIR/$mw_name"; then
    MW_STATE_VALID=0
  fi
  MW_PREV_SUMMARIES[$mw_index]=$MW_PREV_SUMMARY
  mw_classify_snapshot "$mw_snapshot" "$mw_path" "$mw_host" "$mw_share"
  MW_OBS[$mw_index]=$MW_MOUNT_CLASS
  [ "$MW_MOUNT_CLASS" = expected-smb ] || mw_global_refresh_all_satisfied=0
  mw_probe_deferred_for_global=0
  if mw_global_block_is_active; then
    MW_PROBE_RESULT=unknown
    MW_PROBE_BLOCKED_PID=$(mw_state_value "$MW_STATE_DIR/blocked-command" pid 2>/dev/null || printf 'unknown')
    mw_probe_deferred_for_global=1
  else
    mw_probe_host_cached "$mw_host"
  fi
  MW_NET[$mw_index]=$MW_PROBE_RESULT
  mw_observation_blocked_pid=${MW_PROBE_BLOCKED_PID:-none}
  mw_observation_probe_error=${MW_PROBE_ERROR:-command-timeout}

  MW_LAST_NET[$mw_index]=$MW_PREV_NETWORK
  case "$MW_PROBE_RESULT" in reachable|unreachable) MW_LAST_NET[$mw_index]=$MW_PROBE_RESULT ;; esac
  MW_INITIALIZED[$mw_index]=1
  MW_PENDING[$mw_index]=$MW_PREV_PENDING
  MW_PENDING_SINCE[$mw_index]=$MW_PREV_PENDING_SINCE
  MW_ACTION[$mw_index]=idle
  MW_LAST_ATTEMPT[$mw_index]=$MW_PREV_LAST_ATTEMPT
  MW_LAST_ATTEMPT_ACTION[$mw_index]=$MW_PREV_LAST_ATTEMPT_ACTION
  MW_LAST_ATTEMPT_RESULT[$mw_index]=$MW_PREV_LAST_ATTEMPT_RESULT
  MW_LAST_ATTEMPT_EXIT_STATUS[$mw_index]=$MW_PREV_LAST_ATTEMPT_EXIT_STATUS
  MW_LAST_SUCCESS[$mw_index]=$MW_PREV_LAST_SUCCESS
  MW_LAST_SUCCESS_ACTION[$mw_index]=$MW_PREV_LAST_SUCCESS_ACTION
  MW_LAST_ERROR[$mw_index]=$MW_PREV_LAST_ERROR
  MW_BLOCKED_PID[$mw_index]=none
  MW_WANT_UNMOUNT[$mw_index]=0
  MW_WANT_REFRESH[$mw_index]=0
  MW_DID_UNMOUNT[$mw_index]=$MW_PREV_UNMOUNT_CONFIRMED
  MW_CONTINUE_REFRESH[$mw_index]=$MW_PREV_UNMOUNT_REFRESH_REQUIRED

  if [ "$MW_STATE_VALID" -ne 1 ]; then
    MW_ACTION[$mw_index]=manual-attention
    MW_LAST_ERROR[$mw_index]=state-requires-manual-attention
    MW_BLOCKED_PID[$mw_index]=${MW_PREV_BLOCKED_PID:-none}
    mw_index=$((mw_index + 1))
    continue
  fi
  if [ "$MW_PREV_ACTION" = manual-attention ] &&
    [ "$MW_PREV_LAST_ERROR" != mount-inspection-failed ]; then
    MW_ACTION[$mw_index]=manual-attention
    MW_LAST_ERROR[$mw_index]=$MW_PREV_LAST_ERROR
    MW_BLOCKED_PID[$mw_index]=${MW_PREV_BLOCKED_PID:-none}
    mw_index=$((mw_index + 1))
    continue
  fi
  if [ "$mw_probe_deferred_for_global" -eq 1 ]; then
    MW_INITIALIZED[$mw_index]=$MW_PREV_INITIALIZED
    MW_ACTION[$mw_index]=deferred-command-block
    MW_LAST_ERROR[$mw_index]=another-command-requires-manual-attention
    MW_BLOCKED_PID[$mw_index]=$mw_observation_blocked_pid
    mw_index=$((mw_index + 1))
    continue
  fi
  if [ "$MW_PROBE_RESULT" = unknown ] && [ "$mw_observation_blocked_pid" != none ]; then
    MW_ACTION[$mw_index]=manual-attention
    MW_LAST_ERROR[$mw_index]=network-probe-timed-out
    [ "$mw_observation_probe_error" != command-supervision-failed ] || \
      MW_LAST_ERROR[$mw_index]=network-probe-supervision-failed
    MW_BLOCKED_PID[$mw_index]=$mw_observation_blocked_pid
    mw_log_slot_event "$mw_index" network-probe observe "$mw_observation_probe_error" manual-attention
    mw_index=$((mw_index + 1))
    continue
  fi

  case "$MW_MOUNT_CLASS" in
    trigger-only)
      if [ "${MW_CONTINUE_REFRESH[$mw_index]}" -ne 1 ]; then
        [ "${MW_PENDING[$mw_index]}" = none ] || MW_ACTION[$mw_index]=canceled
        MW_PENDING[$mw_index]=none
        MW_PENDING_SINCE[$mw_index]=0
      fi
      ;;
    trigger-missing)
      [ "${MW_CONTINUE_REFRESH[$mw_index]}" -eq 1 ] || MW_PENDING[$mw_index]=trigger-missing
      [ "${MW_PENDING_SINCE[$mw_index]}" -gt 0 ] || MW_PENDING_SINCE[$mw_index]=$MW_NOW_EPOCH
      ;;
    unexpected-mount|ambiguous-mount)
      MW_ACTION[$mw_index]=manual-attention
      MW_LAST_ERROR[$mw_index]=unexpected-or-ambiguous-mount-layer
      mw_index=$((mw_index + 1))
      continue
      ;;
    expected-smb)
      if [ "${MW_CONTINUE_REFRESH[$mw_index]}" -eq 1 ]; then
        # A confirmed unmount keeps its refresh obligation even if the expected
        # layer legitimately returns before the next tick. An uncertain
        # attempting journal instead falls back to the original pending unmount.
        [ "${MW_DID_UNMOUNT[$mw_index]}" -eq 1 ] || MW_CONTINUE_REFRESH[$mw_index]=0
      elif [ "${MW_PENDING[$mw_index]}" = trigger-missing ]; then
        MW_PENDING[$mw_index]=none
        MW_PENDING_SINCE[$mw_index]=0
        MW_ACTION[$mw_index]=canceled
      fi
      ;;
  esac

  if [ "$MW_PREV_INITIALIZED" -eq 1 ] && [ "$MW_MOUNT_CLASS" = expected-smb ] &&
    [ "$MW_PROBE_RESULT" = reachable ]; then
    mw_new_reason=
    mw_prior_expected_smb=0
    case "$MW_PREV_SUMMARY" in mounted-*) mw_prior_expected_smb=1 ;; esac
    if [ "$MW_PREV_SUMMARY" = mounted-unreachable ] &&
      [ "$MW_PREV_NETWORK" = unreachable ]; then
      mw_new_reason=network-restored
    fi
    if [ "$mw_gap_detected" -eq 1 ] && [ "$mw_prior_expected_smb" -eq 1 ]; then
      if [ -n "$mw_new_reason" ]; then mw_new_reason=multiple; else mw_new_reason=scheduling-gap; fi
    fi
    if [ -n "$mw_new_reason" ]; then
      if [ "${MW_PENDING[$mw_index]}" = none ]; then
        MW_PENDING[$mw_index]=$mw_new_reason
        MW_PENDING_SINCE[$mw_index]=$MW_NOW_EPOCH
      elif [ "${MW_PENDING[$mw_index]}" != "$mw_new_reason" ]; then
        MW_PENDING[$mw_index]=multiple
      fi
    fi
  fi

  mw_attempt_eligible=1
  if [ "$MW_NOW_EPOCH" -lt "${MW_LAST_ATTEMPT[$mw_index]}" ] ||
    [ $((MW_NOW_EPOCH - ${MW_LAST_ATTEMPT[$mw_index]})) -lt "$MW_RECOVERY_COOLDOWN_SECONDS" ]; then
    mw_attempt_eligible=0
  fi
  if [ "${MW_CONTINUE_REFRESH[$mw_index]}" -eq 1 ]; then
    case "$MW_MOUNT_CLASS" in
      trigger-only|trigger-missing|expected-smb)
        if [ "$mw_global_refresh_eligible" -eq 0 ]; then
          MW_ACTION[$mw_index]=deferred-cooldown
        else
          MW_ACTION[$mw_index]=refresh-required
          MW_WANT_REFRESH[$mw_index]=1
        fi
        ;;
    esac
  elif [ "$mw_global_refresh_uncommitted" -eq 1 ] && {
    [ "$MW_MOUNT_CLASS" = trigger-only ] || [ "$MW_MOUNT_CLASS" = trigger-missing ];
  }; then
    if [ "$mw_global_refresh_eligible" -eq 1 ]; then
      MW_ACTION[$mw_index]=refresh-required
      MW_WANT_REFRESH[$mw_index]=1
    fi
  else
    case "${MW_PENDING[$mw_index]}:${MW_MOUNT_CLASS}" in
    none:*) ;;
    trigger-missing:trigger-missing)
      if [ "$mw_attempt_eligible" -eq 0 ] || [ "$mw_global_refresh_eligible" -eq 0 ]; then
        MW_ACTION[$mw_index]=deferred-cooldown
      else
        MW_ACTION[$mw_index]=refresh-required
        MW_WANT_REFRESH[$mw_index]=1
      fi
      ;;
    *:expected-smb)
      if [ "$MW_PROBE_RESULT" != reachable ]; then
        MW_ACTION[$mw_index]=deferred-network
      elif [ "$mw_attempt_eligible" -eq 0 ] || [ "$mw_global_refresh_eligible" -eq 0 ]; then
        MW_ACTION[$mw_index]=deferred-cooldown
      else
        MW_ACTION[$mw_index]=unmount-required
        MW_WANT_UNMOUNT[$mw_index]=1
      fi
      ;;
    esac
  fi
  if [ "${MW_PENDING[$mw_index]}" = none ]; then
    case "${MW_ACTION[$mw_index]}" in idle|canceled) MW_LAST_ERROR[$mw_index]=none ;; esac
  fi
  mw_index=$((mw_index + 1))
done

if [ "$mw_global_refresh_uncommitted" -eq 1 ] &&
  [ "$mw_global_refresh_all_satisfied" -eq 1 ]; then
  /bin/rm -f "$mw_global_refresh_file" || exit 70
  mw_global_refresh_uncommitted=0
fi

mw_action_blocked=$mw_global_refresh_manual_attention
if [ "$mw_global_refresh_manual_attention" -eq 1 ]; then
  mw_index=0
  while [ "$mw_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
    if [ "${MW_WANT_UNMOUNT[$mw_index]}" -eq 1 ] ||
      [ "${MW_WANT_REFRESH[$mw_index]}" -eq 1 ]; then
      MW_ACTION[$mw_index]=deferred-command-block
      MW_LAST_ERROR[$mw_index]=another-command-requires-manual-attention
    fi
    mw_index=$((mw_index + 1))
  done
fi
if mw_global_block_is_active; then
  mw_action_blocked=1
  mw_index=0
  while [ "$mw_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
    if [ "${MW_WANT_UNMOUNT[$mw_index]}" -eq 1 ] ||
      [ "${MW_WANT_REFRESH[$mw_index]}" -eq 1 ]; then
      MW_ACTION[$mw_index]=deferred-command-block
      MW_LAST_ERROR[$mw_index]=another-command-requires-manual-attention
    fi
    mw_index=$((mw_index + 1))
  done
fi
mw_index=0
while [ "$mw_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
  if [ "${MW_WANT_UNMOUNT[$mw_index]}" -ne 1 ]; then
    mw_index=$((mw_index + 1))
    continue
  fi
  if [ "$mw_action_blocked" -eq 1 ]; then
    MW_ACTION[$mw_index]=deferred-command-block
    MW_LAST_ERROR[$mw_index]=another-command-requires-manual-attention
    mw_index=$((mw_index + 1))
    continue
  fi

  MW_LAST_ATTEMPT[$mw_index]=$MW_NOW_EPOCH
  MW_LAST_ATTEMPT_ACTION[$mw_index]=recovery-validation
  MW_LAST_ATTEMPT_EXIT_STATUS[$mw_index]=not-run
  mw_make_temp "$MW_STATE_DIR" .pre-action || exit 70
  mw_pre_snapshot=$MW_TEMP_PATH
  if ! mw_capture_mount_snapshot "$mw_pre_snapshot"; then
    MW_LAST_ATTEMPT_RESULT[$mw_index]=inspection-failed
    MW_LAST_ERROR[$mw_index]=pre-action-inspection-failed
    MW_ACTION[$mw_index]=unmount-required
    if [ "${MW_RUN_RC:-0}" -eq 124 ] || [ "${MW_RUN_RC:-0}" -eq 125 ]; then
      MW_ACTION[$mw_index]=manual-attention
      MW_BLOCKED_PID[$mw_index]=${MW_RUN_BLOCKED_PID:-unknown}
    fi
    mw_log_slot_event "$mw_index" inspection normal-unmount pre-action-inspection-failed blocked
    mw_action_blocked=1
    /bin/rm -f "$mw_pre_snapshot" 2>/dev/null || true
    mw_index=$((mw_index + 1))
    continue
  fi
  mw_classify_snapshot "$mw_pre_snapshot" "${MW_MOUNT_PATHS[$mw_index]}" \
    "${MW_MOUNT_HOSTS[$mw_index]}" "${MW_MOUNT_SHARES[$mw_index]}"
  MW_OBS[$mw_index]=$MW_MOUNT_CLASS
  /bin/rm -f "$mw_pre_snapshot" 2>/dev/null || true
  case "$MW_MOUNT_CLASS" in
    trigger-only)
      MW_PENDING[$mw_index]=none
      MW_PENDING_SINCE[$mw_index]=0
      MW_ACTION[$mw_index]=canceled
      MW_LAST_ATTEMPT_RESULT[$mw_index]=canceled-target-disappeared
      MW_LAST_ERROR[$mw_index]=none
      mw_index=$((mw_index + 1))
      continue
      ;;
    trigger-missing)
      MW_PENDING[$mw_index]=trigger-missing
      MW_ACTION[$mw_index]=refresh-required
      MW_WANT_REFRESH[$mw_index]=1
      MW_LAST_ATTEMPT_RESULT[$mw_index]=target-disappeared-refresh-needed
      MW_LAST_ERROR[$mw_index]=none
      mw_index=$((mw_index + 1))
      continue
      ;;
    expected-smb) ;;
    *)
      MW_ACTION[$mw_index]=manual-attention
      MW_LAST_ATTEMPT_RESULT[$mw_index]=blocked-target-changed
      MW_LAST_ERROR[$mw_index]=target-changed-before-unmount
      mw_log_slot_event "$mw_index" recovery-action normal-unmount target-changed blocked
      mw_index=$((mw_index + 1))
      continue
      ;;
  esac

  mw_probe_host_now "${MW_MOUNT_HOSTS[$mw_index]}" || MW_PROBE_RESULT=unknown
  MW_NET[$mw_index]=$MW_PROBE_RESULT
  case "$MW_PROBE_RESULT" in
    reachable) MW_LAST_NET[$mw_index]=reachable ;;
    unreachable)
      MW_LAST_NET[$mw_index]=unreachable
      MW_ACTION[$mw_index]=deferred-network
      MW_LAST_ATTEMPT_RESULT[$mw_index]=canceled-network-unreachable
      mw_index=$((mw_index + 1))
      continue
      ;;
    *)
      MW_ACTION[$mw_index]=manual-attention
      MW_LAST_ATTEMPT_RESULT[$mw_index]=network-recheck-failed
      MW_LAST_ERROR[$mw_index]=network-recheck-timed-out
      MW_BLOCKED_PID[$mw_index]=${MW_PROBE_BLOCKED_PID:-unknown}
      mw_action_blocked=1
      mw_log_slot_event "$mw_index" network-probe normal-unmount command-timeout blocked
      mw_index=$((mw_index + 1))
      continue
      ;;
  esac

  if ! mw_validate_runtime_autofs_configuration; then
    mw_block_actions_for_configuration_drift "$MW_AUTOFS_DRIFT_REASON"
    mw_action_blocked=1
    break
  fi

  mw_make_temp "$MW_STATE_DIR" .umount-out || exit 70
  mw_cmd_out=$MW_TEMP_PATH
  mw_make_temp "$MW_STATE_DIR" .umount-err || exit 70
  mw_cmd_err=$MW_TEMP_PATH
  MW_LAST_ATTEMPT_ACTION[$mw_index]=normal-unmount
  mw_unmount_journal=$MW_STATE_DIR/${MW_MOUNT_NAMES[$mw_index]}/unmount-attempt
  if ! mw_atomic_write_lines "$mw_unmount_journal" \
    'format|1' "runtime_fingerprint|$MW_RUNTIME_FINGERPRINT" \
    "attempt_epoch|$MW_NOW_EPOCH" 'action|normal-unmount' \
    'phase|attempting' 'result|attempting' 'exit_status|unknown' \
    "pending_recovery|${MW_PENDING[$mw_index]}" 'refresh_required|1'; then
    MW_LAST_ATTEMPT_RESULT[$mw_index]=journal-failed
    MW_ACTION[$mw_index]=manual-attention
    MW_LAST_ERROR[$mw_index]=unmount-attempt-journal-failed
    mw_action_blocked=1
    mw_log_slot_event "$mw_index" supervisor normal-unmount attempt-journal-write-failed fail-closed
    /bin/rm -f "$mw_cmd_out" "$mw_cmd_err" 2>/dev/null || true
    mw_index=$((mw_index + 1))
    continue
  fi
  mw_log_slot_event "$mw_index" recovery-action normal-unmount recovery-required attempt
  mw_run_bounded "$mw_cmd_out" "$mw_cmd_err" "$MW_CMD_UMOUNT" "${MW_MOUNT_PATHS[$mw_index]}"
  mw_unmount_exit_status=$MW_RUN_RC
  MW_LAST_ATTEMPT_EXIT_STATUS[$mw_index]=$mw_unmount_exit_status
  if [ "$mw_unmount_exit_status" -eq 0 ]; then
    mw_make_temp "$MW_STATE_DIR" .post-unmount || exit 70
    mw_post_snapshot=$MW_TEMP_PATH
    if mw_capture_mount_snapshot "$mw_post_snapshot"; then
      mw_classify_snapshot "$mw_post_snapshot" "${MW_MOUNT_PATHS[$mw_index]}" \
        "${MW_MOUNT_HOSTS[$mw_index]}" "${MW_MOUNT_SHARES[$mw_index]}"
      if [ "$MW_MOUNT_CLASS" = trigger-only ] || [ "$MW_MOUNT_CLASS" = trigger-missing ]; then
        MW_LAST_ATTEMPT_RESULT[$mw_index]=unmounted
        MW_DID_UNMOUNT[$mw_index]=1
        MW_CONTINUE_REFRESH[$mw_index]=1
        MW_ACTION[$mw_index]=refresh-required
        MW_WANT_REFRESH[$mw_index]=1
        mw_log_slot_event "$mw_index" recovery-action normal-unmount post-unmount-verified unmounted
      else
        MW_LAST_ATTEMPT_RESULT[$mw_index]=verification-failed
        MW_LAST_ERROR[$mw_index]=expected-smb-still-present-after-unmount
        MW_ACTION[$mw_index]=unmount-required
        mw_log_slot_event "$mw_index" verification normal-unmount expected-layer-remained failed
      fi
    else
      MW_LAST_ATTEMPT_RESULT[$mw_index]=verification-failed
      MW_ACTION[$mw_index]=manual-attention
      MW_LAST_ERROR[$mw_index]=post-unmount-inspection-failed
      MW_BLOCKED_PID[$mw_index]=${MW_RUN_BLOCKED_PID:-none}
      mw_action_blocked=1
      mw_log_slot_event "$mw_index" inspection normal-unmount post-unmount-inspection-failed failed
    fi
    /bin/rm -f "$mw_post_snapshot" 2>/dev/null || true
  else
    if [ "$mw_unmount_exit_status" -eq 124 ] || [ "$mw_unmount_exit_status" -eq 125 ]; then
      MW_LAST_ATTEMPT_RESULT[$mw_index]=timed-out
      MW_LAST_ERROR[$mw_index]=normal-unmount-timed-out
      mw_unmount_failure_reason=command-timeout
      mw_unmount_failure_result=timed-out
      if [ "$mw_unmount_exit_status" -eq 125 ]; then
        MW_LAST_ATTEMPT_RESULT[$mw_index]=supervision-failed
        MW_LAST_ERROR[$mw_index]=normal-unmount-supervision-failed
        mw_unmount_failure_reason=command-supervision-failed
        mw_unmount_failure_result=fail-closed
      fi
      MW_ACTION[$mw_index]=manual-attention
      MW_BLOCKED_PID[$mw_index]=${MW_RUN_BLOCKED_PID:-unknown}
      mw_action_blocked=1
      mw_log_slot_event "$mw_index" recovery-action normal-unmount \
        "$mw_unmount_failure_reason" "$mw_unmount_failure_result"
    else
      if /usr/bin/grep -Eqi 'resource[[:space:]]+busy' "$mw_cmd_err" 2>/dev/null; then
        MW_LAST_ATTEMPT_RESULT[$mw_index]=busy
        MW_LAST_ERROR[$mw_index]=normal-unmount-busy
        mw_log_slot_event "$mw_index" recovery-action normal-unmount resource-busy busy
      else
        MW_LAST_ATTEMPT_RESULT[$mw_index]=failed
        MW_LAST_ERROR[$mw_index]=normal-unmount-failed
        mw_log_slot_event "$mw_index" recovery-action normal-unmount command-failed failed
      fi
      MW_ACTION[$mw_index]=unmount-required
    fi
  fi
  mw_journal_refresh_required=0
  [ "${MW_LAST_ATTEMPT_RESULT[$mw_index]}" != unmounted ] || mw_journal_refresh_required=1
  mw_unmount_journal_complete=0
  if mw_atomic_write_lines "$mw_unmount_journal" \
    'format|1' "runtime_fingerprint|$MW_RUNTIME_FINGERPRINT" \
    "attempt_epoch|$MW_NOW_EPOCH" 'action|normal-unmount' \
    'phase|complete' "result|${MW_LAST_ATTEMPT_RESULT[$mw_index]}" \
    "exit_status|${MW_LAST_ATTEMPT_EXIT_STATUS[$mw_index]}" \
    "pending_recovery|${MW_PENDING[$mw_index]}" \
    "refresh_required|$mw_journal_refresh_required"; then
    mw_unmount_journal_complete=1
  fi
  if [ "$MW_TEST_MODE" -eq 1 ] && [ "$mw_unmount_journal_complete" -eq 1 ] &&
    [ -f "$MW_TEST_ROOT/crash-after-unmount-journal" ]; then
    kill -KILL $$
  fi
  /bin/rm -f "$mw_cmd_out" "$mw_cmd_err" 2>/dev/null || true
  mw_index=$((mw_index + 1))
done

mw_refresh_requested=0
mw_index=0
while [ "$mw_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
  [ "${MW_WANT_REFRESH[$mw_index]}" -ne 1 ] || mw_refresh_requested=1
  mw_index=$((mw_index + 1))
done

if [ "$mw_refresh_requested" -eq 1 ] && [ "$mw_action_blocked" -eq 0 ]; then
  if ! mw_validate_runtime_autofs_configuration; then
    mw_block_actions_for_configuration_drift "$MW_AUTOFS_DRIFT_REASON"
    mw_action_blocked=1
  fi
fi

if [ "$mw_refresh_requested" -eq 1 ] && [ "$mw_action_blocked" -eq 0 ]; then
  mw_atomic_write_lines "$mw_global_refresh_file" \
    'format|1' "runtime_fingerprint|$MW_RUNTIME_FINGERPRINT" \
    "last_attempt_epoch|$MW_NOW_EPOCH" 'last_result|attempting' \
    'last_exit_status|unknown' || {
      mw_error 'could not persist the autofs refresh attempt'
      exit 70
    }
  mw_index=0
  while [ "$mw_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
    if [ "${MW_WANT_REFRESH[$mw_index]}" -eq 1 ]; then
      MW_LAST_ATTEMPT[$mw_index]=$MW_NOW_EPOCH
      MW_LAST_ATTEMPT_ACTION[$mw_index]=autofs-refresh
      MW_LAST_ATTEMPT_EXIT_STATUS[$mw_index]=unknown
    fi
    mw_index=$((mw_index + 1))
  done

  mw_make_temp "$MW_STATE_DIR" .automount-out || exit 70
  mw_refresh_out=$MW_TEMP_PATH
  mw_make_temp "$MW_STATE_DIR" .automount-err || exit 70
  mw_refresh_err=$MW_TEMP_PATH
  mw_refresh_result=completed
  mw_log_global_event recovery-action autofs-refresh recovery-required attempt
  mw_run_bounded "$mw_refresh_out" "$mw_refresh_err" "$MW_CMD_AUTOMOUNT" -c
  mw_refresh_exit_status=$MW_RUN_RC
  mw_index=0
  while [ "$mw_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
    if [ "${MW_WANT_REFRESH[$mw_index]}" -eq 1 ]; then
      MW_LAST_ATTEMPT_EXIT_STATUS[$mw_index]=$mw_refresh_exit_status
    fi
    mw_index=$((mw_index + 1))
  done
  if [ "$MW_TEST_MODE" -eq 1 ] &&
    [ -f "$MW_TEST_ROOT/crash-after-automount-command" ]; then
    kill -KILL $$
  fi
  if [ "$mw_refresh_exit_status" -eq 0 ]; then
    mw_make_temp "$MW_STATE_DIR" .post-refresh || exit 70
    mw_verify_snapshot=$MW_TEMP_PATH
    if mw_capture_mount_snapshot "$mw_verify_snapshot"; then
      mw_index=0
      while [ "$mw_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
        if [ "${MW_WANT_REFRESH[$mw_index]}" -eq 1 ]; then
          mw_classify_snapshot "$mw_verify_snapshot" "${MW_MOUNT_PATHS[$mw_index]}" \
            "${MW_MOUNT_HOSTS[$mw_index]}" "${MW_MOUNT_SHARES[$mw_index]}"
          MW_OBS[$mw_index]=$MW_MOUNT_CLASS
          if [ "$MW_MOUNT_CLASS" = trigger-only ] || [ "$MW_MOUNT_CLASS" = expected-smb ]; then
            MW_CONTINUE_REFRESH[$mw_index]=0
            MW_PENDING[$mw_index]=none
            MW_PENDING_SINCE[$mw_index]=0
            MW_ACTION[$mw_index]=idle
            MW_LAST_ATTEMPT_RESULT[$mw_index]=succeeded
            MW_LAST_SUCCESS[$mw_index]=$MW_NOW_EPOCH
            if [ "${MW_DID_UNMOUNT[$mw_index]}" -eq 1 ]; then
              MW_LAST_SUCCESS_ACTION[$mw_index]=normal-unmount-and-autofs-refresh
            else
              MW_LAST_SUCCESS_ACTION[$mw_index]=autofs-refresh
            fi
            MW_LAST_ERROR[$mw_index]=none
            mw_log_slot_event "$mw_index" recovery-action autofs-refresh post-refresh-verified succeeded
          elif [ "$MW_MOUNT_CLASS" = trigger-missing ]; then
            MW_ACTION[$mw_index]=refresh-required
            MW_LAST_ATTEMPT_RESULT[$mw_index]=verification-failed
            MW_LAST_ERROR[$mw_index]=trigger-still-missing-after-refresh
            mw_log_slot_event "$mw_index" verification autofs-refresh trigger-still-missing failed
          else
            MW_ACTION[$mw_index]=manual-attention
            MW_LAST_ATTEMPT_RESULT[$mw_index]=verification-failed
            MW_LAST_ERROR[$mw_index]=unexpected-layer-after-refresh
            mw_log_slot_event "$mw_index" verification autofs-refresh unexpected-layer failed
          fi
        fi
        mw_index=$((mw_index + 1))
      done
    else
      mw_index=0
      while [ "$mw_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
        if [ "${MW_WANT_REFRESH[$mw_index]}" -eq 1 ]; then
          MW_ACTION[$mw_index]=refresh-required
          MW_LAST_ATTEMPT_RESULT[$mw_index]=verification-failed
          MW_LAST_ERROR[$mw_index]=post-refresh-inspection-failed
        fi
        mw_index=$((mw_index + 1))
      done
      mw_log_global_event inspection autofs-refresh post-refresh-inspection-failed failed
    fi
    /bin/rm -f "$mw_verify_snapshot" 2>/dev/null || true
  else
    mw_refresh_result=failed
    [ "$mw_refresh_exit_status" -ne 124 ] || mw_refresh_result=timed-out
    [ "$mw_refresh_exit_status" -ne 125 ] || mw_refresh_result=supervision-failed
    mw_log_global_event recovery-action autofs-refresh "autofs-refresh-$mw_refresh_result" "$mw_refresh_result"
    mw_index=0
    while [ "$mw_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
      if [ "${MW_WANT_REFRESH[$mw_index]}" -eq 1 ]; then
        MW_ACTION[$mw_index]=refresh-required
        MW_LAST_ATTEMPT_RESULT[$mw_index]=$mw_refresh_result
        MW_LAST_ERROR[$mw_index]=autofs-refresh-$mw_refresh_result
        if [ "$mw_refresh_exit_status" -eq 124 ] || [ "$mw_refresh_exit_status" -eq 125 ]; then
          MW_ACTION[$mw_index]=manual-attention
          MW_BLOCKED_PID[$mw_index]=${MW_RUN_BLOCKED_PID:-unknown}
        fi
      fi
      mw_index=$((mw_index + 1))
    done
  fi
  /bin/rm -f "$mw_refresh_out" "$mw_refresh_err" 2>/dev/null || true
  mw_atomic_write_lines "$mw_global_refresh_file" \
    'format|1' "runtime_fingerprint|$MW_RUNTIME_FINGERPRINT" \
    "last_attempt_epoch|$MW_NOW_EPOCH" "last_result|$mw_refresh_result" \
    "last_exit_status|$mw_refresh_exit_status" || {
      MW_RUNTIME_EXIT_HEARTBEAT_RESULT=state-write-error
      mw_error 'could not persist the final autofs refresh result'
      exit 70
    }
  mw_global_refresh_uncommitted=0
fi

mw_result=ok
mw_exit=0
mw_index=0
while [ "$mw_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
  mw_current_summary=$(mw_summary_state "${MW_OBS[$mw_index]}" "${MW_NET[$mw_index]}")
  mw_previous_summary=${MW_PREV_SUMMARIES[$mw_index]:-uninitialized}
  if [ "$mw_previous_summary" != "$mw_current_summary" ]; then
    mw_log_state_transition "$mw_index" "$mw_previous_summary" "$mw_current_summary"
  fi
  if ! mw_write_mount_status_index "$mw_index"; then
    mw_result=state-write-error
    mw_exit=70
  elif [ "${MW_CONTINUE_REFRESH[$mw_index]}" -ne 1 ]; then
    mw_retire_committed_unmount_journal "$MW_STATE_DIR/${MW_MOUNT_NAMES[$mw_index]}" \
      "${MW_LAST_ATTEMPT[$mw_index]}" || true
  fi
  case "${MW_ACTION[$mw_index]}" in
    configuration-drift)
      if [ "$mw_exit" -ne 70 ]; then
        mw_exit=2
        mw_result=configuration-drift
      fi
      ;;
    manual-attention)
      if [ "$mw_exit" -ne 70 ]; then
        mw_exit=2
        mw_result=manual-attention
      fi
      ;;
    deferred-*|unmount-required|refresh-required)
      [ "$mw_exit" -ne 0 ] || mw_exit=1
      [ "$mw_result" != ok ] || mw_result=pending
      ;;
  esac
  mw_index=$((mw_index + 1))
done

if [ "$mw_global_refresh_uncommitted" -eq 1 ] && [ "$mw_exit" -eq 0 ]; then
  mw_result=pending
  mw_exit=1
fi
if [ "$mw_global_refresh_manual_attention" -eq 1 ] && [ "$mw_exit" -ne 70 ]; then
  mw_result=manual-attention
  mw_exit=2
fi

/bin/rm -f "$mw_snapshot" 2>/dev/null || true
if mw_now_epoch && mw_now_iso; then
  MW_TICK_COMPLETED_EPOCH=$MW_NOW_EPOCH
else
  MW_TICK_COMPLETED_EPOCH=0
  mw_result=clock-error
  mw_exit=70
fi
mw_write_terminal_heartbeat "$mw_result" || mw_exit=70
exit "$mw_exit"
