#!/bin/bash
# shellcheck disable=SC2034,SC2153

# Runtime helpers for the periodic watchdog and the read-only status command.
# Keep this file compatible with the macOS system Bash 3.2.

MW_STATE_FORMAT=1
MW_LABEL=com.antoinemenard.mount-watchdog
MW_CHECK_SCOPE=mount-table-and-tcp
MW_READABILITY=not-tested

mw_runtime_init_paths() {
  MW_RUNTIME_MODE=${1:-runtime}
  MW_TEST_MODE=0

  if [ -n "${MW_TEST_ROOT:-}" ] || [ -n "${MW_TEST_COMMAND_DIR:-}" ]; then
    [ -n "${MW_TEST_ROOT:-}" ] && [ -n "${MW_TEST_COMMAND_DIR:-}" ] || {
      mw_error 'MW_TEST_ROOT and MW_TEST_COMMAND_DIR must be supplied together'
      return 1
    }
    [ "$EUID" -ne 0 ] || {
      mw_error 'the command test backend is disabled for root execution'
      return 1
    }
    case "$MW_TEST_ROOT" in
      /|''|*'//'*|*/../*|*/..|*/./*|*/.)
        mw_error 'MW_TEST_ROOT must be a contained absolute non-root path'
        return 1
        ;;
      /*) ;;
      *) mw_error 'MW_TEST_ROOT must be absolute'; return 1 ;;
    esac
    case "$MW_TEST_COMMAND_DIR" in
      "$MW_TEST_ROOT"/*) ;;
      *) mw_error 'MW_TEST_COMMAND_DIR must be contained beneath MW_TEST_ROOT'; return 1 ;;
    esac
    case "$MW_TEST_COMMAND_DIR" in
      *'//'*|*/../*|*/..|*/./*|*/.)
        mw_error 'MW_TEST_COMMAND_DIR contains an unsafe path component'
        return 1
        ;;
    esac
    [ -d "$MW_TEST_ROOT" ] && [ ! -L "$MW_TEST_ROOT" ] || {
      mw_error 'MW_TEST_ROOT must already be a real directory'
      return 1
    }
    [ -d "$MW_TEST_COMMAND_DIR" ] && [ ! -L "$MW_TEST_COMMAND_DIR" ] || {
      mw_error 'MW_TEST_COMMAND_DIR must already be a real directory'
      return 1
    }
    mw_test_root_physical=$(cd "$MW_TEST_ROOT" 2>/dev/null && pwd -P) || return 1
    mw_test_commands_physical=$(cd "$MW_TEST_COMMAND_DIR" 2>/dev/null && pwd -P) || return 1
    case "$mw_test_commands_physical" in
      "$mw_test_root_physical"/*) ;;
      *) mw_error 'physical test command directory escapes MW_TEST_ROOT'; return 1 ;;
    esac
    MW_TEST_ROOT=$mw_test_root_physical
    MW_TEST_COMMAND_DIR=$mw_test_commands_physical

    MW_TEST_MODE=1
    MW_CONFIG_FILE=$MW_TEST_ROOT/mounts.conf
    MW_DEFAULTS_FILE=$MW_TEST_ROOT/defaults.conf
    MW_VERSION_FILE=$MW_TEST_ROOT/VERSION
    MW_AUTO_MASTER_FILE=$MW_TEST_ROOT/etc/auto_master
    MW_AUTO_SMB_FILE=$MW_TEST_ROOT/etc/auto_smb
    MW_STATE_DIR=$MW_TEST_ROOT/state
    MW_LOG_FILE=$MW_TEST_ROOT/watchdog.log
    MW_CMD_MOUNT=$MW_TEST_COMMAND_DIR/mount
    MW_CMD_NC=$MW_TEST_COMMAND_DIR/nc
    MW_CMD_UMOUNT=$MW_TEST_COMMAND_DIR/umount
    MW_CMD_AUTOMOUNT=$MW_TEST_COMMAND_DIR/automount
    MW_CMD_DATE=$MW_TEST_COMMAND_DIR/date
    MW_CMD_PS=$MW_TEST_COMMAND_DIR/ps
    MW_CMD_LAUNCHCTL=$MW_TEST_COMMAND_DIR/launchctl
  else
    MW_CONFIG_FILE='/Library/Application Support/MountWatchdog/mounts.conf'
    MW_DEFAULTS_FILE='/Library/Application Support/MountWatchdog/defaults.conf'
    MW_VERSION_FILE='/Library/Application Support/MountWatchdog/VERSION'
    MW_AUTO_MASTER_FILE=/etc/auto_master
    MW_AUTO_SMB_FILE=/etc/auto_smb
    MW_STATE_DIR=/var/run/com.antoinemenard.mount-watchdog
    MW_LOG_FILE=/var/log/mount-watchdog.log
    MW_CMD_MOUNT=/sbin/mount
    MW_CMD_NC=/usr/bin/nc
    MW_CMD_UMOUNT=/sbin/umount
    MW_CMD_AUTOMOUNT=/usr/sbin/automount
    MW_CMD_DATE=/bin/date
    MW_CMD_PS=/bin/ps
    MW_CMD_LAUNCHCTL=/bin/launchctl
  fi

  if [ "$MW_RUNTIME_MODE" = status ]; then
    mw_required_commands="$MW_CMD_DATE $MW_CMD_LAUNCHCTL"
  else
    mw_required_commands="$MW_CMD_MOUNT $MW_CMD_NC $MW_CMD_UMOUNT $MW_CMD_AUTOMOUNT $MW_CMD_DATE $MW_CMD_PS $MW_CMD_LAUNCHCTL"
  fi
  for mw_required_command in $mw_required_commands; do
    [ -f "$mw_required_command" ] && [ -x "$mw_required_command" ] && [ ! -L "$mw_required_command" ] || {
      mw_error "required command is missing, not executable, or a symlink: $mw_required_command"
      return 1
    }
    if [ "$MW_TEST_MODE" -eq 1 ] && ! mw_file_has_single_link "$mw_required_command"; then
      mw_error "test command has multiple hard links: $mw_required_command"
      return 1
    fi
  done
  if [ "$MW_TEST_MODE" -eq 0 ]; then
    mw_production_state_parent_is_trusted || {
      mw_error 'runtime state parent does not match the trusted macOS /var/run boundary'
      return 1
    }
  fi
  return 0
}

mw_production_state_parent_is_trusted() {
  [ "$MW_STATE_DIR" = /var/run/com.antoinemenard.mount-watchdog ] || return 1
  [ -L /var ] || return 1
  [ "$(/usr/bin/readlink /var 2>/dev/null)" = private/var ] || return 1
  mw_var_link_meta=$(/usr/bin/stat -f '%Su|%Sg|%Lp' /var 2>/dev/null) || return 1
  [ "$mw_var_link_meta" = 'root|wheel|755' ] || return 1
  for mw_state_ancestor in /private /private/var; do
    [ -d "$mw_state_ancestor" ] && [ ! -L "$mw_state_ancestor" ] || return 1
    mw_state_ancestor_meta=$(/usr/bin/stat -f '%Su|%Lp' "$mw_state_ancestor" 2>/dev/null) || return 1
    [ "${mw_state_ancestor_meta%%|*}" = root ] || return 1
    mw_state_ancestor_mode=${mw_state_ancestor_meta#*|}
    case "$mw_state_ancestor_mode" in ''|*[!0-7]*) return 1 ;; esac
    [ $(( (10#$mw_state_ancestor_mode / 10) % 10 & 2 )) -eq 0 ] || return 1
    [ $(( 10#$mw_state_ancestor_mode % 10 & 2 )) -eq 0 ] || return 1
    mw_acl_policy_is_safe "$mw_state_ancestor" deny-only || return 1
  done
  [ -d /private/var/run ] && [ ! -L /private/var/run ] || return 1
  mw_run_parent_meta=$(/usr/bin/stat -f '%Su|%Sg|%Lp' /private/var/run 2>/dev/null) || return 1
  mw_run_parent_owner=${mw_run_parent_meta%%|*}
  mw_run_parent_rest=${mw_run_parent_meta#*|}
  mw_run_parent_group=${mw_run_parent_rest%%|*}
  mw_run_parent_mode=${mw_run_parent_rest#*|}
  [ "$mw_run_parent_owner" = root ] || return 1
  case "$mw_run_parent_mode" in ''|*[!0-7]*) return 1 ;; esac
  [ $((10#$mw_run_parent_mode % 10 & 2)) -eq 0 ] || return 1
  if [ $(( (10#$mw_run_parent_mode / 10) % 10 & 2 )) -ne 0 ]; then
    [ "$mw_run_parent_group" = daemon ] || return 1
  fi
  mw_acl_policy_is_safe /private/var/run deny-only || return 1
  mw_run_parent_physical=$(CDPATH='' cd -- /var/run 2>/dev/null && pwd -P) || return 1
  [ "$mw_run_parent_physical" = /private/var/run ]
}

mw_prepare_runtime_state() {
  umask 077
  if [ "$MW_TEST_MODE" -eq 1 ]; then
    [ ! -L "$MW_STATE_DIR" ] || { mw_error 'test state directory is a symlink'; return 1; }
    if [ -e "$MW_STATE_DIR" ]; then
      [ -d "$MW_STATE_DIR" ] || return 1
      mw_directory_is_trusted "$MW_STATE_DIR" none || return 1
    else
      /bin/mkdir -p "$MW_STATE_DIR" || return 1
      mw_strip_acl_from_new_node "$MW_STATE_DIR" || return 1
    fi
    /bin/chmod 700 "$MW_STATE_DIR" || return 1
    mw_directory_is_trusted "$MW_STATE_DIR" none || return 1
    case "$MW_LOG_FILE" in "$MW_TEST_ROOT"/*) ;; *) mw_error 'test log escapes MW_TEST_ROOT'; return 1 ;; esac
    mw_directory_is_trusted "${MW_LOG_FILE%/*}" deny-only || {
      mw_error 'test log parent is unsafe'
      return 1
    }
    if [ -e "$MW_LOG_FILE" ] || [ -L "$MW_LOG_FILE" ]; then
      mw_regular_file_is_trusted "$MW_LOG_FILE" || {
        mw_error 'test log destination is unsafe'
        return 1
      }
      mw_file_has_single_link "$MW_LOG_FILE" || {
        mw_error 'test log destination has multiple hard links'
        return 1
      }
    fi
    return 0
  fi

  [ "$EUID" -eq 0 ] || { mw_error 'the periodic runtime must run as root'; return 1; }
  [ ! -L "$MW_CONFIG_FILE" ] && [ -f "$MW_CONFIG_FILE" ] && [ -O "$MW_CONFIG_FILE" ] || {
    mw_error 'installed configuration must be a root-owned regular file, not a symlink'
    return 1
  }
  if [ -e "$MW_STATE_DIR" ] || [ -L "$MW_STATE_DIR" ]; then
    [ -d "$MW_STATE_DIR" ] && [ ! -L "$MW_STATE_DIR" ] && [ -O "$MW_STATE_DIR" ] || {
      mw_error 'runtime state destination is unsafe'
      return 1
    }
    mw_directory_is_trusted "$MW_STATE_DIR" none || return 1
  else
    /usr/bin/install -d -o root -g wheel -m 700 "$MW_STATE_DIR" || return 1
    mw_strip_acl_from_new_node "$MW_STATE_DIR" || return 1
  fi
  /bin/chmod 700 "$MW_STATE_DIR" || return 1
  mw_directory_is_trusted "$MW_STATE_DIR" none || return 1
  mw_directory_is_trusted "${MW_LOG_FILE%/*}" deny-only || {
    mw_error 'log parent is unsafe'
    return 1
  }
  if [ -e "$MW_LOG_FILE" ] || [ -L "$MW_LOG_FILE" ]; then
    mw_regular_file_is_trusted "$MW_LOG_FILE" || {
      mw_error 'log destination is unsafe'
      return 1
    }
    mw_file_has_single_link "$MW_LOG_FILE" || {
      mw_error 'log destination has multiple hard links'
      return 1
    }
  fi
  return 0
}

mw_file_has_single_link() {
  if /usr/bin/stat -f '%l' "$1" >/dev/null 2>&1; then
    [ "$(/usr/bin/stat -f '%l' "$1")" = 1 ]
  else
    [ "$(/usr/bin/stat -c '%h' "$1" 2>/dev/null || printf '0')" = 1 ]
  fi
}

mw_exit_status_value_is_valid() {
  case "${1:-}" in
    not-run|unknown) return 0 ;;
  esac
  mw_is_uint "$1" && [ "$1" -le 255 ]
}

mw_attempt_action_value_is_valid() {
  case "${1:-}" in never|recovery-validation|normal-unmount|autofs-refresh) return 0 ;; esac
  return 1
}

mw_attempt_result_value_is_valid() {
  case "${1:-}" in
    never|attempting|inspection-failed|canceled-target-disappeared|target-disappeared-refresh-needed|blocked-target-changed|canceled-network-unreachable|network-recheck-failed|journal-failed|unmounted|verification-failed|timed-out|supervision-failed|busy|failed|succeeded) return 0 ;;
  esac
  return 1
}

mw_success_action_value_is_valid() {
  case "${1:-}" in never|autofs-refresh|normal-unmount-and-autofs-refresh) return 0 ;; esac
  return 1
}

mw_last_error_value_is_valid() {
  case "${1:-}" in
    none|autofs-hook-missing|autofs-master-map-invalid|autofs-selected-map-missing|autofs-selected-map-invalid|autofs-selected-mapping-mismatch|mount-inspection-failed|state-requires-manual-attention|another-command-requires-manual-attention|network-probe-timed-out|network-probe-supervision-failed|pre-action-inspection-failed|target-changed-before-unmount|network-recheck-timed-out|unmount-attempt-journal-failed|unmount-attempt-not-finalized|expected-smb-still-present-after-unmount|post-unmount-inspection-failed|normal-unmount-verification-failed|normal-unmount-timed-out|normal-unmount-supervision-failed|normal-unmount-busy|normal-unmount-failed|trigger-still-missing-after-refresh|unexpected-layer-after-refresh|post-refresh-inspection-failed|autofs-refresh-failed|autofs-refresh-timed-out|autofs-refresh-supervision-failed|unexpected-or-ambiguous-mount-layer) return 0 ;;
  esac
  return 1
}

mw_blocked_pid_value_is_valid() {
  case "${1:-}" in none|unknown|supervisor-error) return 0 ;; esac
  mw_is_uint "$1" && [ "$1" -gt 1 ]
}

mw_regular_file_is_trusted() {
  mw_trusted_file=$1
  mw_trusted_file_acl_policy=${2:-none}
  [ -f "$mw_trusted_file" ] && [ ! -L "$mw_trusted_file" ] || return 1
  mw_trusted_file_meta=$(/usr/bin/stat -f '%Su|%Lp' "$mw_trusted_file" 2>/dev/null) || return 1
  mw_trusted_file_owner=${mw_trusted_file_meta%%|*}
  mw_trusted_file_mode=${mw_trusted_file_meta#*|}
  if [ "$MW_TEST_MODE" -eq 1 ]; then
    [ -O "$mw_trusted_file" ] || return 1
  else
    [ "$mw_trusted_file_owner" = root ] || return 1
  fi
  case "$mw_trusted_file_mode" in ''|*[!0-7]*) return 1 ;; esac
  [ $(( (10#$mw_trusted_file_mode / 10) % 10 & 2 )) -eq 0 ] &&
    [ $(( 10#$mw_trusted_file_mode % 10 & 2 )) -eq 0 ] &&
    mw_acl_policy_is_safe "$mw_trusted_file" "$mw_trusted_file_acl_policy"
}

mw_directory_is_trusted() {
  mw_trusted_directory=$1
  mw_trusted_directory_acl_policy=${2:-none}
  [ -d "$mw_trusted_directory" ] && [ ! -L "$mw_trusted_directory" ] || return 1
  mw_trusted_directory_meta=$(/usr/bin/stat -f '%Su|%Lp' "$mw_trusted_directory" 2>/dev/null) || return 1
  mw_trusted_directory_owner=${mw_trusted_directory_meta%%|*}
  mw_trusted_directory_mode=${mw_trusted_directory_meta#*|}
  if [ "$MW_TEST_MODE" -eq 1 ]; then
    [ -O "$mw_trusted_directory" ] || return 1
  else
    [ "$mw_trusted_directory_owner" = root ] || return 1
  fi
  case "$mw_trusted_directory_mode" in ''|*[!0-7]*) return 1 ;; esac
  [ $(( (10#$mw_trusted_directory_mode / 10) % 10 & 2 )) -eq 0 ] &&
    [ $(( 10#$mw_trusted_directory_mode % 10 & 2 )) -eq 0 ] &&
    mw_acl_policy_is_safe "$mw_trusted_directory" "$mw_trusted_directory_acl_policy"
}

mw_validate_mount_state_dirs() {
  MW_UNSAFE_MOUNT_STATE_NAME=none
  if [ -e "$MW_STATE_DIR" ] || [ -L "$MW_STATE_DIR" ]; then
    mw_directory_is_trusted "$MW_STATE_DIR" || {
      MW_UNSAFE_MOUNT_STATE_NAME=state-root
      return 1
    }
    if [ "$MW_TEST_MODE" -eq 1 ]; then
      mw_validate_state_root=$(cd "$MW_STATE_DIR" 2>/dev/null && pwd -P) || return 1
      case "$mw_validate_state_root" in "$MW_TEST_ROOT"/*) ;; *) MW_UNSAFE_MOUNT_STATE_NAME=state-root; return 1 ;; esac
    fi
  fi
  mw_validate_index=0
  while [ "$mw_validate_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
    mw_validate_name=${MW_MOUNT_NAMES[$mw_validate_index]}
    case "$mw_validate_name" in
      ''|.|..|*/*)
        MW_UNSAFE_MOUNT_STATE_NAME=$mw_validate_name
        return 1
        ;;
    esac
    mw_validate_dir=$MW_STATE_DIR/$mw_validate_name
    if [ -e "$mw_validate_dir" ] || [ -L "$mw_validate_dir" ]; then
      mw_directory_is_trusted "$mw_validate_dir" || {
        MW_UNSAFE_MOUNT_STATE_NAME=$mw_validate_name
        return 1
      }
      if [ "$MW_TEST_MODE" -eq 1 ]; then
        mw_validate_physical=$(cd "$mw_validate_dir" 2>/dev/null && pwd -P) || {
          MW_UNSAFE_MOUNT_STATE_NAME=$mw_validate_name
          return 1
        }
        case "$mw_validate_physical" in
          "$MW_TEST_ROOT"/*) ;;
          *) MW_UNSAFE_MOUNT_STATE_NAME=$mw_validate_name; return 1 ;;
        esac
      fi
    fi
    mw_validate_index=$((mw_validate_index + 1))
  done
  return 0
}

mw_validate_runtime_state_leaves() {
  MW_UNSAFE_STATE_LEAF=none
  for mw_validate_leaf in heartbeat blocked-command autofs-refresh; do
    mw_validate_path=$MW_STATE_DIR/$mw_validate_leaf
    if [ -e "$mw_validate_path" ] || [ -L "$mw_validate_path" ]; then
      mw_regular_file_is_trusted "$mw_validate_path" || {
        MW_UNSAFE_STATE_LEAF=$mw_validate_leaf
        return 1
      }
    fi
  done

  mw_validate_index=0
  while [ "$mw_validate_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
    mw_validate_name=${MW_MOUNT_NAMES[$mw_validate_index]}
    for mw_validate_leaf in status unmount-attempt; do
      mw_validate_path=$MW_STATE_DIR/$mw_validate_name/$mw_validate_leaf
      if [ -e "$mw_validate_path" ] || [ -L "$mw_validate_path" ]; then
        mw_regular_file_is_trusted "$mw_validate_path" || {
          MW_UNSAFE_STATE_LEAF=$mw_validate_name/$mw_validate_leaf
          return 1
        }
      fi
    done
    mw_validate_index=$((mw_validate_index + 1))
  done
  mw_process_runtime_orphan_temps validate
}

mw_runtime_temp_basename_is_managed() {
  mw_temp_basename=$1
  case "$mw_temp_basename" in
    .tmp.??????|.mount-snapshot.??????|.mount-error.??????|.probe-out.??????|.probe-err.??????|.pre-action.??????|.umount-out.??????|.umount-err.??????|.post-unmount.??????|.automount-out.??????|.automount-err.??????|.post-refresh.??????) ;;
    *) return 1 ;;
  esac
  mw_temp_suffix=${mw_temp_basename##*.}
  case "$mw_temp_suffix" in ''|*[!A-Za-z0-9]*) return 1 ;; esac
  return 0
}

mw_process_runtime_orphan_temp() {
  mw_orphan_mode=$1
  mw_orphan_path=$2
  { [ -e "$mw_orphan_path" ] || [ -L "$mw_orphan_path" ]; } || return 0
  mw_orphan_basename=${mw_orphan_path##*/}
  mw_runtime_temp_basename_is_managed "$mw_orphan_basename" || return 0
  if ! mw_regular_file_is_trusted "$mw_orphan_path" ||
    ! mw_file_has_single_link "$mw_orphan_path"; then
    MW_UNSAFE_STATE_LEAF=${mw_orphan_path#"$MW_STATE_DIR"/}
    return 1
  fi
  if [ "$mw_orphan_mode" = cleanup ] && ! /bin/rm -f "$mw_orphan_path"; then
    MW_UNSAFE_STATE_LEAF=${mw_orphan_path#"$MW_STATE_DIR"/}
    return 1
  fi
  return 0
}

mw_process_runtime_orphan_temps() {
  mw_orphan_mode=$1
  for mw_orphan_path in \
    "$MW_STATE_DIR"/.tmp.* \
    "$MW_STATE_DIR"/.mount-snapshot.* \
    "$MW_STATE_DIR"/.mount-error.* \
    "$MW_STATE_DIR"/.probe-out.* \
    "$MW_STATE_DIR"/.probe-err.* \
    "$MW_STATE_DIR"/.pre-action.* \
    "$MW_STATE_DIR"/.umount-out.* \
    "$MW_STATE_DIR"/.umount-err.* \
    "$MW_STATE_DIR"/.post-unmount.* \
    "$MW_STATE_DIR"/.automount-out.* \
    "$MW_STATE_DIR"/.automount-err.* \
    "$MW_STATE_DIR"/.post-refresh.*; do
    mw_process_runtime_orphan_temp "$mw_orphan_mode" "$mw_orphan_path" || return 1
  done
  mw_orphan_index=0
  while [ "$mw_orphan_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
    mw_orphan_dir=$MW_STATE_DIR/${MW_MOUNT_NAMES[$mw_orphan_index]}
    for mw_orphan_path in "$mw_orphan_dir"/.tmp.*; do
      mw_process_runtime_orphan_temp "$mw_orphan_mode" "$mw_orphan_path" || return 1
    done
    mw_orphan_index=$((mw_orphan_index + 1))
  done
  return 0
}

mw_cleanup_runtime_orphan_temps() {
  mw_process_runtime_orphan_temps cleanup
}

mw_cleanup_reconciled_lock_temps() {
  for mw_lock_temp in "$MW_LOCK_DIR"/.tmp.*; do
    { [ -e "$mw_lock_temp" ] || [ -L "$mw_lock_temp" ]; } || continue
    mw_runtime_temp_basename_is_managed "${mw_lock_temp##*/}" || continue
    mw_regular_file_is_trusted "$mw_lock_temp" &&
      mw_file_has_single_link "$mw_lock_temp" || return 1
    /bin/rm -f "$mw_lock_temp" || return 1
  done
  return 0
}

mw_now_epoch() {
  MW_NOW_EPOCH=$($MW_CMD_DATE +%s 2>/dev/null) || return 1
  mw_is_uint "$MW_NOW_EPOCH"
}

mw_now_iso() {
  MW_NOW_ISO=$($MW_CMD_DATE -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 1
  MW_NOW_ISO=$(mw_sanitize_field "$MW_NOW_ISO")
  [ -n "$MW_NOW_ISO" ]
}

mw_log_event() {
  mw_log_text=$(mw_sanitize_field "$*")
  if mw_now_iso; then
    printf '%s %s\n' "$MW_NOW_ISO" "$mw_log_text" >> "$MW_LOG_FILE" 2>/dev/null || true
  fi
}

mw_log_slot_event() {
  mw_log_slot_index=$1
  mw_log_event_name=$2
  mw_log_action_name=$3
  mw_log_reason_name=$4
  mw_log_result_name=$5
  mw_is_uint "$mw_log_slot_index" || return 1
  mw_log_event "event=$mw_log_event_name scope=slot slot=$((mw_log_slot_index + 1)) action=$mw_log_action_name reason=$mw_log_reason_name result=$mw_log_result_name"
}

mw_log_global_event() {
  mw_log_event_name=$1
  mw_log_action_name=$2
  mw_log_reason_name=$3
  mw_log_result_name=$4
  mw_log_event "event=$mw_log_event_name scope=global action=$mw_log_action_name reason=$mw_log_reason_name result=$mw_log_result_name"
}

mw_log_state_transition() {
  mw_log_slot_index=$1
  mw_log_from_state=$2
  mw_log_to_state=$3
  mw_is_uint "$mw_log_slot_index" || return 1
  mw_log_event "event=state-transition scope=slot slot=$((mw_log_slot_index + 1)) action=observe reason=state-changed result=changed from=$mw_log_from_state to=$mw_log_to_state"
}

mw_compute_runtime_fingerprint() {
  for mw_fp_code_file in "$MW_CONFIG_FILE" "$MW_DEFAULTS_FILE" "$MW_VERSION_FILE" \
    "$MW_RUNTIME_PROGRAM_FILE" "$MW_RUNTIME_COMMON_FILE" \
    "$MW_RUNTIME_LIBRARY_FILE" "$MW_RUNTIME_AUTOFS_FILE"; do
    mw_regular_file_is_trusted "$mw_fp_code_file" &&
      mw_file_has_single_link "$mw_fp_code_file" || return 1
  done
  mw_fp_config=$(/usr/bin/cksum "$MW_CONFIG_FILE" 2>/dev/null) || return 1
  mw_fp_defaults=$(/usr/bin/cksum "$MW_DEFAULTS_FILE" 2>/dev/null) || return 1
  mw_fp_version=$(/usr/bin/cksum "$MW_VERSION_FILE" 2>/dev/null) || return 1
  mw_fp_program=$(/usr/bin/shasum -a 256 "$MW_RUNTIME_PROGRAM_FILE" 2>/dev/null) || return 1
  mw_fp_common=$(/usr/bin/shasum -a 256 "$MW_RUNTIME_COMMON_FILE" 2>/dev/null) || return 1
  mw_fp_runtime=$(/usr/bin/shasum -a 256 "$MW_RUNTIME_LIBRARY_FILE" 2>/dev/null) || return 1
  mw_fp_autofs=$(/usr/bin/shasum -a 256 "$MW_RUNTIME_AUTOFS_FILE" 2>/dev/null) || return 1
  mw_fp_config=${mw_fp_config%% *}
  mw_fp_defaults=${mw_fp_defaults%% *}
  mw_fp_version=${mw_fp_version%% *}
  mw_fp_program=${mw_fp_program%% *}
  mw_fp_common=${mw_fp_common%% *}
  mw_fp_runtime=${mw_fp_runtime%% *}
  mw_fp_autofs=${mw_fp_autofs%% *}
  for mw_fp_code_hash in "$mw_fp_program" "$mw_fp_common" "$mw_fp_runtime" "$mw_fp_autofs"; do
    [ "${#mw_fp_code_hash}" -eq 64 ] || return 1
    case "$mw_fp_code_hash" in *[!0-9a-f]*) return 1 ;; esac
  done
  MW_RUNTIME_FINGERPRINT=$mw_fp_config-$mw_fp_defaults-$mw_fp_version-$mw_fp_program-$mw_fp_common-$mw_fp_runtime-$mw_fp_autofs
}

mw_atomic_write_lines() {
  mw_destination=$1
  shift
  mw_test_signal_after_running_write=0
  mw_test_crash_after_mount_status_write=0
  mw_test_terminal_refresh_write=0
  if [ "${MW_TEST_MODE:-0}" -eq 1 ] &&
    [ "$mw_destination" = "$MW_STATE_DIR/heartbeat" ] &&
    [ -f "$MW_TEST_ROOT/signal-after-running-heartbeat" ]; then
    for mw_test_write_line in "$@"; do
      [ "$mw_test_write_line" != 'phase|running' ] || mw_test_signal_after_running_write=1
    done
  fi
  if [ "${MW_TEST_MODE:-0}" -eq 1 ] &&
    [ -f "$MW_TEST_ROOT/crash-after-mount-status-write" ]; then
    case "$mw_destination" in
      "$MW_STATE_DIR"/*/status) mw_test_crash_after_mount_status_write=1 ;;
    esac
  fi
  if [ "${MW_TEST_MODE:-0}" -eq 1 ] &&
    [ "$mw_destination" = "$MW_STATE_DIR/autofs-refresh" ]; then
    for mw_test_write_line in "$@"; do
      case "$mw_test_write_line" in
        last_result\|completed|last_result\|failed|last_result\|timed-out|last_result\|supervision-failed)
          mw_test_terminal_refresh_write=1
          ;;
      esac
    done
  fi
  mw_parent=${mw_destination%/*}
  if [ -e "$mw_destination" ] || [ -L "$mw_destination" ]; then
    [ -f "$mw_destination" ] && [ ! -L "$mw_destination" ] && [ -O "$mw_destination" ] || return 1
    mw_acl_policy_is_safe "$mw_destination" none || return 1
  fi
  mw_tmp=$(/usr/bin/mktemp "$mw_parent/.tmp.XXXXXX") || return 1
  mw_strip_acl_from_new_node "$mw_tmp" || { /bin/rm -f "$mw_tmp"; return 1; }
  MW_WRITE_COUNTER=$((${MW_WRITE_COUNTER:-0} + 1))
  if [ "${MW_TEST_MODE:-0}" -eq 1 ] && [ -f "$MW_TEST_ROOT/fail-mount-status-write" ]; then
    case "$mw_destination" in "$MW_STATE_DIR"/*/status) /bin/rm -f "$mw_tmp"; return 1 ;; esac
  fi
  if [ "$mw_test_terminal_refresh_write" -eq 1 ] &&
    [ -f "$MW_TEST_ROOT/fail-terminal-global-refresh-write" ]; then
    /bin/rm -f "$mw_tmp"
    return 1
  fi
  [ -f "$mw_tmp" ] && [ ! -L "$mw_tmp" ] || return 1
  : > "$mw_tmp" || return 1
  for mw_output_line in "$@"; do
    printf '%s\n' "$mw_output_line" >> "$mw_tmp" || { /bin/rm -f "$mw_tmp"; return 1; }
  done
  /bin/chmod 600 "$mw_tmp" || { /bin/rm -f "$mw_tmp"; return 1; }
  /bin/mv -f "$mw_tmp" "$mw_destination" || return 1
  if [ "$mw_test_signal_after_running_write" -eq 1 ]; then
    /bin/rm -f "$MW_TEST_ROOT/signal-after-running-heartbeat" || return 1
    kill -TERM "$$"
  fi
  if [ "$mw_test_crash_after_mount_status_write" -eq 1 ]; then
    /bin/rm -f "$MW_TEST_ROOT/crash-after-mount-status-write" || return 1
    kill -KILL "$$"
  fi
  if [ "$mw_test_terminal_refresh_write" -eq 1 ] &&
    [ -f "$MW_TEST_ROOT/crash-after-terminal-global-refresh-record" ]; then
    /bin/rm -f "$MW_TEST_ROOT/crash-after-terminal-global-refresh-record" || return 1
    kill -KILL "$$"
  fi
}

mw_make_temp() {
  mw_temp_parent=$1
  mw_temp_prefix=$2
  MW_TEMP_PATH=$(/usr/bin/mktemp "$mw_temp_parent/$mw_temp_prefix.XXXXXX") || return 1
  [ -f "$MW_TEMP_PATH" ] && [ ! -L "$MW_TEMP_PATH" ] &&
    mw_strip_acl_from_new_node "$MW_TEMP_PATH"
}

mw_process_token() {
  mw_token=$($MW_CMD_PS -p "$1" -o lstart= 2>/dev/null) || return 1
  mw_token=$(mw_sanitize_field "$mw_token")
  [ -n "$mw_token" ] || return 1
  printf '%s\n' "$mw_token"
}

mw_group_is_live() {
  mw_group_id=$1
  mw_is_uint "$mw_group_id" && [ "$mw_group_id" -gt 1 ] || return 1
  kill -0 -- "-$mw_group_id" 2>/dev/null
}

mw_clear_active_command() {
  MW_ACTIVE_COMMAND_PID=
  MW_ACTIVE_COMMAND_PGID=
  MW_ACTIVE_COMMAND_TOKEN=
  MW_ACTIVE_COMMAND_NAME=
  MW_ACTIVE_COMMAND_PREPARING=0
}

mw_write_command_guard() {
  mw_guard_active=$1
  mw_guard_pid=$2
  mw_guard_pgid=$3
  mw_guard_token=$4
  mw_guard_name=$5
  mw_atomic_write_lines "$MW_LOCK_DIR/command-guard" \
    'format|1' "active|$mw_guard_active" "pid|$mw_guard_pid" \
    "pgid|$mw_guard_pgid" "process_token|$mw_guard_token" \
    "command|$mw_guard_name"
}

mw_persist_blocked_command() {
  mw_blocked_pid=$1
  mw_blocked_pgid=$2
  mw_blocked_token=$3
  mw_blocked_name=$4
  mw_atomic_write_lines "$MW_STATE_DIR/blocked-command" \
    'format|1' 'active|1' "pid|$mw_blocked_pid" "pgid|$mw_blocked_pgid" \
    "process_token|$mw_blocked_token" "command|$mw_blocked_name" \
    "recorded_epoch|${MW_NOW_EPOCH:-0}"
}

mw_terminate_active_command_group() {
  mw_active_pid=${MW_ACTIVE_COMMAND_PID:-}
  mw_active_pgid=${MW_ACTIVE_COMMAND_PGID:-}
  mw_active_token=${MW_ACTIVE_COMMAND_TOKEN:-unknown}
  mw_active_name=${MW_ACTIVE_COMMAND_NAME:-unknown}
  mw_is_uint "$mw_active_pid" && mw_is_uint "$mw_active_pgid" &&
    [ "$mw_active_pid" -gt 1 ] && [ "$mw_active_pgid" -gt 1 ] || {
      if [ "${MW_ACTIVE_COMMAND_PREPARING:-0}" -eq 1 ]; then
        # The durable preparing guard predates the fork. If a signal lands
        # before the new process-group identifiers are captured, retain the
        # lock rather than risk releasing an untracked child group.
        MW_RETAIN_LOCK=1
        return 1
      fi
      return 0
    }
  if ! mw_group_is_live "$mw_active_pgid"; then
    mw_clear_active_command
    return 0
  fi

  # These identifiers come only from the job-control launch in the currently
  # executing mw_run_bounded call. Persisted identifiers are never passed here.
  kill -TERM -- "-$mw_active_pgid" 2>/dev/null || true
  /bin/sleep 1
  if mw_group_is_live "$mw_active_pgid"; then
    kill -KILL -- "-$mw_active_pgid" 2>/dev/null || true
    /bin/sleep 1
  fi
  if mw_group_is_live "$mw_active_pgid"; then
    MW_RUN_BLOCKED_PID=$mw_active_pid
    if ! mw_persist_blocked_command "$mw_active_pid" "$mw_active_pgid" \
      "$mw_active_token" "$mw_active_name"; then
      # The command guard was durably written before the command was allowed
      # to run. Retain the lock so a later tick cannot treat its dead owner as
      # stale while this unkillable group remains unrecorded elsewhere.
      MW_RETAIN_LOCK=1
      MW_BLOCK_PERSIST_FAILED=1
      mw_log_global_event supervisor command-supervision blocked-record-write-failed fail-closed
    fi
    return 1
  fi
  mw_clear_active_command
  return 0
}

mw_read_blocked_command_record() {
  mw_block_record_file=$1
  MW_BLOCK_RECORD_REASON=none
  MW_BLOCK_RECORD_PID=
  MW_BLOCK_RECORD_PGID=
  MW_BLOCK_RECORD_TOKEN=
  MW_BLOCK_RECORD_COMMAND=

  if ! mw_regular_file_is_trusted "$mw_block_record_file"; then
    MW_BLOCK_RECORD_REASON=unsafe-block-record
    return 1
  fi
  if [ "$(mw_state_value "$mw_block_record_file" format 2>/dev/null || true)" != 1 ] ||
    [ "$(mw_state_value "$mw_block_record_file" active 2>/dev/null || true)" != 1 ]; then
    MW_BLOCK_RECORD_REASON=invalid-block-record
    return 1
  fi

  MW_BLOCK_RECORD_PID=$(mw_state_value "$mw_block_record_file" pid 2>/dev/null || true)
  MW_BLOCK_RECORD_PGID=$(mw_state_value "$mw_block_record_file" pgid 2>/dev/null || true)
  MW_BLOCK_RECORD_TOKEN=$(mw_state_value "$mw_block_record_file" process_token 2>/dev/null || true)
  MW_BLOCK_RECORD_COMMAND=$(mw_state_value "$mw_block_record_file" command 2>/dev/null || true)
  case "$MW_BLOCK_RECORD_COMMAND" in
    mount|nc|umount|automount) ;;
    *)
      MW_BLOCK_RECORD_REASON=invalid-block-record
      return 1
      ;;
  esac
  if [ -z "$MW_BLOCK_RECORD_TOKEN" ]; then
    MW_BLOCK_RECORD_REASON=invalid-block-record
    return 1
  fi
  if ! mw_is_uint "$MW_BLOCK_RECORD_PID" || ! mw_is_uint "$MW_BLOCK_RECORD_PGID" ||
    [ "$MW_BLOCK_RECORD_PID" -le 1 ] || [ "$MW_BLOCK_RECORD_PGID" -le 1 ]; then
    MW_BLOCK_RECORD_REASON=invalid-block-identifiers
    return 1
  fi
  return 0
}

mw_global_block_is_active() {
  mw_block_file=$MW_STATE_DIR/blocked-command
  MW_GLOBAL_BLOCK_REASON=none
  { [ -e "$mw_block_file" ] || [ -L "$mw_block_file" ]; } || return 1
  if ! mw_read_blocked_command_record "$mw_block_file"; then
    MW_GLOBAL_BLOCK_REASON=$MW_BLOCK_RECORD_REASON
    return 0
  fi
  mw_block_pid=$MW_BLOCK_RECORD_PID
  mw_block_pgid=$MW_BLOCK_RECORD_PGID
  mw_block_token=$MW_BLOCK_RECORD_TOKEN
  mw_block_command=$MW_BLOCK_RECORD_COMMAND

  mw_block_pid_live=0
  kill -0 "$mw_block_pid" 2>/dev/null && mw_block_pid_live=1
  if ! mw_group_is_live "$mw_block_pgid"; then
    if ! /bin/rm -f "$mw_block_file"; then
      MW_GLOBAL_BLOCK_REASON=block-record-retire-failed
      return 0
    fi
    return 1
  fi
  if [ "$mw_block_pid_live" -eq 0 ]; then
    MW_GLOBAL_BLOCK_REASON=surviving-descendant-group
    return 0
  fi
  if [ "$mw_block_token" = unknown ] || [ -z "$mw_block_token" ]; then
    MW_GLOBAL_BLOCK_REASON=live-unverifiable-command-group
    return 0
  fi
  mw_block_current_token=$(mw_process_token "$mw_block_pid" 2>/dev/null || true)
  if [ "$mw_block_current_token" = "$mw_block_token" ]; then
    MW_GLOBAL_BLOCK_REASON=live-command-group
    return 0
  fi
  # A live persisted process group is never authorization to resume, even if
  # its leader token cannot be reconciled. Do not signal it from cached state.
  MW_GLOBAL_BLOCK_REASON=live-command-group-token-mismatch
  return 0
}

mw_acquire_lock() {
  MW_LOCK_DIR=$MW_STATE_DIR/.tick.lock
  MW_RETAIN_LOCK=0
  MW_BLOCK_PERSIST_FAILED=0
  if /bin/mkdir "$MW_LOCK_DIR" 2>/dev/null; then
    mw_strip_acl_from_new_node "$MW_LOCK_DIR" || { /bin/rmdir "$MW_LOCK_DIR" 2>/dev/null || true; return 1; }
    mw_lock_token=$(mw_process_token $$ 2>/dev/null || printf 'unknown')
    mw_atomic_write_lines "$MW_LOCK_DIR/owner" \
      'format|1' "pid|$$" "process_token|$mw_lock_token" || {
        /bin/rm -f "$MW_LOCK_DIR/owner" 2>/dev/null || true
        /bin/rmdir "$MW_LOCK_DIR" 2>/dev/null || true
        return 1
      }
    mw_write_command_guard 0 0 0 none none || {
      /bin/rm -f "$MW_LOCK_DIR/owner" "$MW_LOCK_DIR/command-guard" 2>/dev/null || true
      /bin/rmdir "$MW_LOCK_DIR" 2>/dev/null || true
      return 1
    }
    MW_LOCK_HELD=1
    return 0
  fi

  [ -d "$MW_LOCK_DIR" ] && [ ! -L "$MW_LOCK_DIR" ] || {
    mw_error 'runtime lock destination is unsafe'
    return 1
  }
  mw_directory_is_trusted "$MW_LOCK_DIR" none || {
    mw_error 'runtime lock ACL is unsafe'
    return 1
  }
  mw_lock_owner=$MW_LOCK_DIR/owner
  mw_regular_file_is_trusted "$mw_lock_owner" &&
    mw_file_has_single_link "$mw_lock_owner" &&
    [ "$(mw_state_value "$mw_lock_owner" format 2>/dev/null || true)" = 1 ] || {
    mw_error 'runtime lock is incomplete; manual attention is required'
    return 1
  }
  mw_lock_pid=$(mw_state_value "$mw_lock_owner" pid 2>/dev/null || true)
  mw_lock_token=$(mw_state_value "$mw_lock_owner" process_token 2>/dev/null || true)
  mw_is_uint "$mw_lock_pid" && [ "$mw_lock_pid" -gt 1 ] &&
    [ -n "$mw_lock_token" ] || {
    mw_error 'runtime lock is incomplete; manual attention is required'
    return 1
  }
  if kill -0 "$mw_lock_pid" 2>/dev/null; then
    mw_current_token=$(mw_process_token "$mw_lock_pid" 2>/dev/null || true)
    if [ "$mw_lock_token" = unknown ] || [ -z "$mw_current_token" ] ||
      [ "$mw_current_token" = "$mw_lock_token" ]; then
      return 75
    fi
  fi

  mw_lock_guard=$MW_LOCK_DIR/command-guard
  if [ -e "$mw_lock_guard" ] || [ -L "$mw_lock_guard" ]; then
    [ -f "$mw_lock_guard" ] && [ ! -L "$mw_lock_guard" ] && [ -O "$mw_lock_guard" ] || {
      mw_error 'runtime command guard is unsafe; manual attention is required'
      return 1
    }
    [ "$(mw_state_value "$mw_lock_guard" format 2>/dev/null || true)" = 1 ] || {
      mw_error 'runtime command guard is invalid; manual attention is required'
      return 1
    }
    mw_guard_active=$(mw_state_value "$mw_lock_guard" active 2>/dev/null || true)
    case "$mw_guard_active" in
      0) ;;
      1)
        mw_guard_pid=$(mw_state_value "$mw_lock_guard" pid 2>/dev/null || true)
        mw_guard_pgid=$(mw_state_value "$mw_lock_guard" pgid 2>/dev/null || true)
        mw_guard_token=$(mw_state_value "$mw_lock_guard" process_token 2>/dev/null || true)
        mw_is_uint "$mw_guard_pid" && mw_is_uint "$mw_guard_pgid" &&
          [ "$mw_guard_pid" -gt 1 ] && [ "$mw_guard_pgid" -gt 1 ] || {
            mw_error 'runtime command guard is incomplete; manual attention is required'
            return 1
          }
        if mw_group_is_live "$mw_guard_pgid"; then
          # A stale guard is observational only. Any live recorded group keeps
          # the lock fail-closed; token disagreement never permits overlap.
          return 75
        fi
        ;;
      *)
        mw_error 'runtime command guard has an invalid state; manual attention is required'
        return 1
        ;;
    esac
  fi

  mw_cleanup_reconciled_lock_temps || {
    mw_error 'runtime lock contains an unsafe temporary file; manual attention is required'
    return 1
  }
  /bin/rm -f "$mw_lock_owner" "$mw_lock_guard" || return 1
  /bin/rmdir "$MW_LOCK_DIR" || return 1
  /bin/mkdir "$MW_LOCK_DIR" || return 75
  mw_strip_acl_from_new_node "$MW_LOCK_DIR" || { /bin/rmdir "$MW_LOCK_DIR" 2>/dev/null || true; return 1; }
  mw_lock_token=$(mw_process_token $$ 2>/dev/null || printf 'unknown')
  mw_atomic_write_lines "$MW_LOCK_DIR/owner" \
    'format|1' "pid|$$" "process_token|$mw_lock_token" || {
      /bin/rm -f "$MW_LOCK_DIR/owner" 2>/dev/null || true
      /bin/rmdir "$MW_LOCK_DIR" 2>/dev/null || true
      return 1
    }
  mw_write_command_guard 0 0 0 none none || {
    /bin/rm -f "$MW_LOCK_DIR/owner" "$MW_LOCK_DIR/command-guard" 2>/dev/null || true
    /bin/rmdir "$MW_LOCK_DIR" 2>/dev/null || true
    return 1
  }
  MW_LOCK_HELD=1
  return 0
}

mw_release_lock() {
  [ "${MW_LOCK_HELD:-0}" -eq 1 ] || return 0
  [ "${MW_RETAIN_LOCK:-0}" -ne 1 ] || return 0
  /bin/rm -f "$MW_LOCK_DIR/owner" "$MW_LOCK_DIR/command-guard" 2>/dev/null || true
  /bin/rmdir "$MW_LOCK_DIR" 2>/dev/null || true
  MW_LOCK_HELD=0
}

mw_run_bounded() {
  mw_run_stdout=$1
  mw_run_stderr=$2
  shift 2
  MW_RUN_BLOCKED_PID=
  MW_RUN_TIMED_OUT=0
  MW_RUN_SUPERVISOR_ERROR=0
  mw_run_name=${1##*/}
  MW_ACTIVE_COMMAND_PREPARING=1
  if ! mw_write_command_guard 1 0 0 unknown "$mw_run_name"; then
    MW_ACTIVE_COMMAND_PREPARING=0
    MW_RUN_SUPERVISOR_ERROR=1
    MW_RUN_RC=125
    return 125
  fi
  mw_monitor_was_on=0
  case "$-" in *m*) mw_monitor_was_on=1 ;; *) set -m ;; esac
  "$@" > "$mw_run_stdout" 2> "$mw_run_stderr" &
  mw_run_pid=$!
  mw_run_pgid=$mw_run_pid
  MW_ACTIVE_COMMAND_PID=$mw_run_pid
  MW_ACTIVE_COMMAND_PGID=$mw_run_pgid
  MW_ACTIVE_COMMAND_TOKEN=unknown
  MW_ACTIVE_COMMAND_NAME=$mw_run_name
  mw_run_token=$(mw_process_token "$mw_run_pid" 2>/dev/null || printf 'unknown')
  MW_ACTIVE_COMMAND_TOKEN=$mw_run_token
  [ "$mw_monitor_was_on" -eq 1 ] || set +m
  if ! mw_write_command_guard 1 "$mw_run_pid" "$mw_run_pgid" "$mw_run_token" "$mw_run_name"; then
    MW_RUN_SUPERVISOR_ERROR=1
    mw_guarded_group_stopped=0
    mw_terminate_active_command_group && mw_guarded_group_stopped=1
    [ "${MW_RETAIN_LOCK:-0}" -eq 1 ] || /bin/rm -f "$MW_LOCK_DIR/command-guard" 2>/dev/null || true
    [ "$mw_guarded_group_stopped" -ne 1 ] || wait "$mw_run_pid" 2>/dev/null || true
    MW_RUN_RC=125
    return 125
  fi
  MW_ACTIVE_COMMAND_PREPARING=0
  mw_run_waited=0
  while mw_group_is_live "$mw_run_pgid"; do
    if [ "$mw_run_waited" -ge "$MW_COMMAND_TIMEOUT_SECONDS" ]; then
      MW_RUN_TIMED_OUT=1
      if mw_terminate_active_command_group; then
        wait "$mw_run_pid" 2>/dev/null || true
      fi
      [ "${MW_RETAIN_LOCK:-0}" -eq 1 ] || /bin/rm -f "$MW_LOCK_DIR/command-guard" 2>/dev/null || true
      MW_RUN_RC=124
      return 124
    fi
    /bin/sleep 1
    mw_run_waited=$((mw_run_waited + 1))
  done
  wait "$mw_run_pid"
  MW_RUN_RC=$?
  mw_clear_active_command
  /bin/rm -f "$MW_LOCK_DIR/command-guard" 2>/dev/null || true
  return "$MW_RUN_RC"
}

mw_capture_mount_snapshot() {
  mw_snapshot_path=$1
  mw_make_temp "$MW_STATE_DIR" .mount-error || return 1
  mw_snapshot_error=$MW_TEMP_PATH
  mw_run_bounded "$mw_snapshot_path" "$mw_snapshot_error" "$MW_CMD_MOUNT"
  mw_snapshot_rc=$?
  /bin/rm -f "$mw_snapshot_error" 2>/dev/null || true
  return "$mw_snapshot_rc"
}

mw_probe_host_now() {
  mw_probe_wanted=$1
  mw_make_temp "$MW_STATE_DIR" .probe-out || return 1
  mw_probe_out=$MW_TEMP_PATH
  mw_make_temp "$MW_STATE_DIR" .probe-err || { /bin/rm -f "$mw_probe_out"; return 1; }
  mw_probe_err=$MW_TEMP_PATH
  MW_PROBE_BLOCKED_PID=
  MW_PROBE_ERROR=none
  if mw_run_bounded "$mw_probe_out" "$mw_probe_err" \
    "$MW_CMD_NC" -G 2 -w 2 -z "$mw_probe_wanted" 445; then
    MW_PROBE_RESULT=reachable
  elif [ "$MW_RUN_RC" -eq 124 ]; then
    MW_PROBE_RESULT=unknown
    MW_PROBE_BLOCKED_PID=${MW_RUN_BLOCKED_PID:-unknown}
    MW_PROBE_ERROR=command-timeout
  elif [ "$MW_RUN_RC" -eq 125 ]; then
    MW_PROBE_RESULT=unknown
    MW_PROBE_BLOCKED_PID=supervisor-error
    MW_PROBE_ERROR=command-supervision-failed
  else
    MW_PROBE_RESULT=unreachable
  fi
  /bin/rm -f "$mw_probe_out" "$mw_probe_err" 2>/dev/null || true
}

mw_classify_snapshot() {
  mw_snapshot_file=$1
  mw_expected_path=$2
  mw_expected_host=$3
  mw_expected_share=$4
  mw_expected_smb=0
  mw_expected_autofs=0
  mw_unexpected=0
  mw_exact_layers=0
  mw_marker=" on $mw_expected_path ("

  while IFS= read -r mw_mount_line || [ -n "$mw_mount_line" ]; do
    case "$mw_mount_line" in
      *"$mw_marker"*")") ;;
      *) continue ;;
    esac
    mw_exact_layers=$((mw_exact_layers + 1))
    mw_mount_source=${mw_mount_line%%"$mw_marker"*}
    mw_mount_options=${mw_mount_line#*"$mw_marker"}
    mw_mount_options=${mw_mount_options%)}
    mw_mount_type=${mw_mount_options%%,*}

    case "$mw_mount_type" in
      smbfs)
        case "$mw_mount_source" in
          //*)
            mw_remote=${mw_mount_source#//}
            mw_remote=${mw_remote##*@}
            mw_actual_host=${mw_remote%%/*}
            mw_actual_share=${mw_remote#*/}
            case "$mw_actual_share" in */*) mw_unexpected=$((mw_unexpected + 1)); continue ;; esac
            mw_actual_host_folded=$(printf '%s' "$mw_actual_host" | /usr/bin/tr '[:upper:]' '[:lower:]')
            mw_expected_host_folded=$(printf '%s' "$mw_expected_host" | /usr/bin/tr '[:upper:]' '[:lower:]')
            if [ "$mw_actual_host_folded" = "$mw_expected_host_folded" ] &&
              [ "$mw_actual_share" = "$mw_expected_share" ] &&
              [ "$mw_remote" != "$mw_actual_share" ]; then
              mw_expected_smb=$((mw_expected_smb + 1))
            else
              mw_unexpected=$((mw_unexpected + 1))
            fi
            ;;
          *) mw_unexpected=$((mw_unexpected + 1)) ;;
        esac
        ;;
      autofs)
        case "$mw_mount_source" in
          'map auto_smb'|'map /etc/auto_smb') mw_expected_autofs=$((mw_expected_autofs + 1)) ;;
          *) mw_unexpected=$((mw_unexpected + 1)) ;;
        esac
        ;;
      *) mw_unexpected=$((mw_unexpected + 1)) ;;
    esac
  done < "$mw_snapshot_file"

  if [ "$mw_unexpected" -gt 0 ]; then
    MW_MOUNT_CLASS=unexpected-mount
  elif [ "$mw_expected_smb" -gt 1 ] || [ "$mw_expected_autofs" -gt 1 ]; then
    MW_MOUNT_CLASS=ambiguous-mount
  elif [ "$mw_expected_smb" -eq 1 ]; then
    MW_MOUNT_CLASS=expected-smb
  elif [ "$mw_expected_autofs" -eq 1 ]; then
    MW_MOUNT_CLASS=trigger-only
  elif [ "$mw_exact_layers" -eq 0 ]; then
    MW_MOUNT_CLASS=trigger-missing
  else
    MW_MOUNT_CLASS=ambiguous-mount
  fi
}

MW_PROBE_HOSTS=()
MW_PROBE_RESULTS=()
MW_PROBE_BLOCKED_PIDS=()
MW_PROBE_ERRORS=()

mw_probe_host_cached() {
  mw_probe_wanted=$1
  mw_probe_key=$(printf '%s' "$mw_probe_wanted" | /usr/bin/tr '[:upper:]' '[:lower:]')
  mw_probe_index=0
  while [ "$mw_probe_index" -lt "${#MW_PROBE_HOSTS[@]}" ]; do
    if [ "${MW_PROBE_HOSTS[$mw_probe_index]}" = "$mw_probe_key" ]; then
      MW_PROBE_RESULT=${MW_PROBE_RESULTS[$mw_probe_index]}
      MW_PROBE_BLOCKED_PID=${MW_PROBE_BLOCKED_PIDS[$mw_probe_index]}
      MW_PROBE_ERROR=${MW_PROBE_ERRORS[$mw_probe_index]}
      return 0
    fi
    mw_probe_index=$((mw_probe_index + 1))
  done

  mw_probe_host_now "$mw_probe_wanted" || MW_PROBE_RESULT=unknown
  MW_PROBE_HOSTS[${#MW_PROBE_HOSTS[@]}]=$mw_probe_key
  MW_PROBE_RESULTS[${#MW_PROBE_RESULTS[@]}]=$MW_PROBE_RESULT
  MW_PROBE_BLOCKED_PIDS[${#MW_PROBE_BLOCKED_PIDS[@]}]=${MW_PROBE_BLOCKED_PID:-none}
  MW_PROBE_ERRORS[${#MW_PROBE_ERRORS[@]}]=${MW_PROBE_ERROR:-none}
}

mw_load_mount_state() {
  mw_load_file=$1
  MW_STATE_VALID=1
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
  MW_PREV_FINGERPRINT=

  { [ -e "$mw_load_file" ] || [ -L "$mw_load_file" ]; } || return 0
  [ -f "$mw_load_file" ] && [ ! -L "$mw_load_file" ] || { MW_STATE_VALID=0; return 0; }
  [ "$(mw_state_value "$mw_load_file" format 2>/dev/null || true)" = "$MW_STATE_FORMAT" ] || { MW_STATE_VALID=0; return 0; }
  mw_load_exit_status=$(mw_state_value "$mw_load_file" last_attempt_exit_status 2>/dev/null || true)
  [ -n "$mw_load_exit_status" ] || { MW_STATE_VALID=0; return 0; }
  MW_PREV_INITIALIZED=$(mw_state_value "$mw_load_file" initialized 2>/dev/null || true)
  MW_PREV_CHECKED=$(mw_state_value "$mw_load_file" checked_at_epoch 2>/dev/null || true)
  MW_PREV_SUMMARY=$(mw_state_value "$mw_load_file" state 2>/dev/null || true)
  MW_PREV_NETWORK=$(mw_state_value "$mw_load_file" last_network_state 2>/dev/null || true)
  MW_PREV_PENDING=$(mw_state_value "$mw_load_file" pending_recovery 2>/dev/null || true)
  MW_PREV_PENDING_SINCE=$(mw_state_value "$mw_load_file" pending_since_epoch 2>/dev/null || true)
  MW_PREV_LAST_ATTEMPT=$(mw_state_value "$mw_load_file" last_attempt_epoch 2>/dev/null || true)
  MW_PREV_LAST_ATTEMPT_ACTION=$(mw_state_value "$mw_load_file" last_attempt_action 2>/dev/null || true)
  MW_PREV_LAST_ATTEMPT_RESULT=$(mw_state_value "$mw_load_file" last_attempt_result 2>/dev/null || true)
  MW_PREV_LAST_ATTEMPT_EXIT_STATUS=$mw_load_exit_status
  MW_PREV_LAST_SUCCESS=$(mw_state_value "$mw_load_file" last_successful_action_epoch 2>/dev/null || true)
  MW_PREV_LAST_SUCCESS_ACTION=$(mw_state_value "$mw_load_file" last_successful_action 2>/dev/null || true)
  MW_PREV_ACTION=$(mw_state_value "$mw_load_file" action_state 2>/dev/null || true)
  MW_PREV_BLOCKED_PID=$(mw_state_value "$mw_load_file" blocked_pid 2>/dev/null || true)
  MW_PREV_LAST_ERROR=$(mw_state_value "$mw_load_file" last_error 2>/dev/null || true)
  MW_PREV_FINGERPRINT=$(mw_state_value "$mw_load_file" runtime_fingerprint 2>/dev/null || true)

  case "$MW_PREV_INITIALIZED" in 0|1) ;; *) MW_STATE_VALID=0 ;; esac
  case "$MW_PREV_SUMMARY" in
    mounted-reachable|mounted-unreachable|mounted-reachability-unknown|trigger-only|trigger-missing|unexpected-mount|ambiguous-mount|inspection-error) ;;
    *) MW_PREV_SUMMARY=unknown; MW_STATE_VALID=0 ;;
  esac
  case "$MW_PREV_NETWORK" in reachable|unreachable|unknown) ;; *) MW_STATE_VALID=0 ;; esac
  case "$MW_PREV_PENDING" in none|network-restored|scheduling-gap|trigger-missing|multiple) ;; *) MW_STATE_VALID=0 ;; esac
  case "$MW_PREV_ACTION" in idle|deferred-cooldown|deferred-network|deferred-command-block|unmount-required|refresh-required|configuration-drift|manual-attention|canceled) ;; *) MW_STATE_VALID=0 ;; esac
  mw_is_uint "$MW_PREV_CHECKED" || MW_STATE_VALID=0
  mw_is_uint "$MW_PREV_PENDING_SINCE" || MW_STATE_VALID=0
  mw_is_uint "$MW_PREV_LAST_ATTEMPT" || MW_STATE_VALID=0
  mw_attempt_action_value_is_valid "$MW_PREV_LAST_ATTEMPT_ACTION" || MW_STATE_VALID=0
  mw_attempt_result_value_is_valid "$MW_PREV_LAST_ATTEMPT_RESULT" || MW_STATE_VALID=0
  mw_exit_status_value_is_valid "$MW_PREV_LAST_ATTEMPT_EXIT_STATUS" || MW_STATE_VALID=0
  mw_is_uint "$MW_PREV_LAST_SUCCESS" || MW_STATE_VALID=0
  mw_success_action_value_is_valid "$MW_PREV_LAST_SUCCESS_ACTION" || MW_STATE_VALID=0
  mw_last_error_value_is_valid "$MW_PREV_LAST_ERROR" || MW_STATE_VALID=0
  mw_blocked_pid_value_is_valid "$MW_PREV_BLOCKED_PID" || MW_STATE_VALID=0
}

mw_read_unmount_attempt_journal() {
  mw_journal_file=$1
  mw_regular_file_is_trusted "$mw_journal_file" || return 1
  [ "$(mw_state_value "$mw_journal_file" format 2>/dev/null || true)" = 1 ] || return 1
  MW_JOURNAL_ACTION=$(mw_state_value "$mw_journal_file" action 2>/dev/null || true)
  MW_JOURNAL_PHASE=$(mw_state_value "$mw_journal_file" phase 2>/dev/null || true)
  MW_JOURNAL_RESULT=$(mw_state_value "$mw_journal_file" result 2>/dev/null || true)
  MW_JOURNAL_EXIT_STATUS=$(mw_state_value "$mw_journal_file" exit_status 2>/dev/null || true)
  MW_JOURNAL_PENDING=$(mw_state_value "$mw_journal_file" pending_recovery 2>/dev/null || true)
  MW_JOURNAL_REFRESH_REQUIRED=$(mw_state_value "$mw_journal_file" refresh_required 2>/dev/null || true)
  [ "$MW_JOURNAL_ACTION" = normal-unmount ] || return 1
  case "$MW_JOURNAL_PENDING" in network-restored|scheduling-gap|multiple) ;; *) return 1 ;; esac
  case "$MW_JOURNAL_PHASE:$MW_JOURNAL_RESULT:$MW_JOURNAL_EXIT_STATUS:$MW_JOURNAL_REFRESH_REQUIRED" in
    attempting:attempting:unknown:1|complete:unmounted:0:1|complete:verification-failed:0:0|complete:timed-out:124:0|complete:supervision-failed:125:0) ;;
    complete:busy:*:0|complete:failed:*:0)
      mw_exit_status_value_is_valid "$MW_JOURNAL_EXIT_STATUS" || return 1
      case "$MW_JOURNAL_EXIT_STATUS" in 0|not-run|unknown) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  MW_JOURNAL_ACTION_STATE=refresh-required
  MW_JOURNAL_LAST_ERROR=unmount-attempt-not-finalized
  MW_JOURNAL_BLOCKED_PID=none
  case "$MW_JOURNAL_RESULT" in
    unmounted)
      MW_JOURNAL_LAST_ERROR=none
      ;;
    busy)
      MW_JOURNAL_ACTION_STATE=unmount-required
      MW_JOURNAL_LAST_ERROR=normal-unmount-busy
      ;;
    failed)
      MW_JOURNAL_ACTION_STATE=unmount-required
      MW_JOURNAL_LAST_ERROR=normal-unmount-failed
      ;;
    verification-failed)
      MW_JOURNAL_ACTION_STATE=manual-attention
      MW_JOURNAL_LAST_ERROR=normal-unmount-verification-failed
      MW_JOURNAL_BLOCKED_PID=unknown
      ;;
    timed-out)
      MW_JOURNAL_ACTION_STATE=manual-attention
      MW_JOURNAL_LAST_ERROR=normal-unmount-timed-out
      MW_JOURNAL_BLOCKED_PID=unknown
      ;;
    supervision-failed)
      MW_JOURNAL_ACTION_STATE=manual-attention
      MW_JOURNAL_LAST_ERROR=normal-unmount-supervision-failed
      MW_JOURNAL_BLOCKED_PID=supervisor-error
      ;;
  esac
  return 0
}

mw_committed_state_supersedes_unmount_journal() {
  mw_supersede_journal_fingerprint=$1
  mw_supersede_journal_epoch=$2
  mw_is_uint "$mw_supersede_journal_epoch" || return 1
  [ "$MW_STATE_VALID" -eq 1 ] &&
    [ "$MW_PREV_FINGERPRINT" = "$MW_RUNTIME_FINGERPRINT" ] &&
    [ "$mw_supersede_journal_fingerprint" = "$MW_RUNTIME_FINGERPRINT" ] &&
    [ "$MW_JOURNAL_PHASE" = complete ] &&
    [ "$MW_JOURNAL_RESULT" = unmounted ] &&
    [ "$MW_JOURNAL_EXIT_STATUS" = 0 ] &&
    [ "$MW_JOURNAL_REFRESH_REQUIRED" = 1 ] &&
    [ "$MW_PREV_PENDING" = none ] &&
    [ "$MW_PREV_ACTION" = idle ] &&
    [ "$MW_PREV_LAST_ERROR" = none ] &&
    [ "$MW_PREV_LAST_ATTEMPT_ACTION" = autofs-refresh ] &&
    [ "$MW_PREV_LAST_ATTEMPT_RESULT" = succeeded ] &&
    [ "$MW_PREV_LAST_ATTEMPT_EXIT_STATUS" = 0 ] &&
    [ "$MW_PREV_LAST_SUCCESS_ACTION" = normal-unmount-and-autofs-refresh ] &&
    [ "$MW_PREV_LAST_ATTEMPT" -gt 0 ] &&
    [ "$mw_supersede_journal_epoch" -gt 0 ] &&
    [ "$MW_PREV_LAST_ATTEMPT" -eq "$MW_PREV_LAST_SUCCESS" ] &&
    [ "$MW_PREV_LAST_SUCCESS" -ge "$mw_supersede_journal_epoch" ] &&
    [ "$MW_PREV_CHECKED" -ge "$MW_PREV_LAST_SUCCESS" ]
}

mw_read_autofs_refresh_record() {
  mw_refresh_record=$1
  mw_regular_file_is_trusted "$mw_refresh_record" || return 1
  [ "$(mw_state_value "$mw_refresh_record" format 2>/dev/null || true)" = 1 ] || return 1
  MW_REFRESH_RECORD_RESULT=$(mw_state_value "$mw_refresh_record" last_result 2>/dev/null || true)
  MW_REFRESH_RECORD_EXIT_STATUS=$(mw_state_value "$mw_refresh_record" last_exit_status 2>/dev/null || true)
  case "$MW_REFRESH_RECORD_RESULT:$MW_REFRESH_RECORD_EXIT_STATUS" in
    attempting:unknown|completed:0|timed-out:124|supervision-failed:125) return 0 ;;
    failed:*)
      mw_exit_status_value_is_valid "$MW_REFRESH_RECORD_EXIT_STATUS" || return 1
      case "$MW_REFRESH_RECORD_EXIT_STATUS" in 0|not-run|unknown) return 1 ;; esac
      return 0
      ;;
  esac
  return 1
}

mw_apply_unmount_attempt_journal() {
  mw_journal_dir=$1
  mw_journal_file=$mw_journal_dir/unmount-attempt
  { [ -e "$mw_journal_file" ] || [ -L "$mw_journal_file" ]; } || return 0
  mw_read_unmount_attempt_journal "$mw_journal_file" || { MW_STATE_VALID=0; return 1; }
  mw_journal_fingerprint=$(mw_state_value "$mw_journal_file" runtime_fingerprint 2>/dev/null || true)
  if [ "$mw_journal_fingerprint" != "$MW_RUNTIME_FINGERPRINT" ]; then
    /bin/rm -f "$mw_journal_file" || { MW_STATE_VALID=0; return 1; }
    return 0
  fi
  mw_journal_epoch=$(mw_state_value "$mw_journal_file" attempt_epoch 2>/dev/null || true)
  mw_is_uint "$mw_journal_epoch" || { MW_STATE_VALID=0; return 1; }
  # Future attempt timestamps belong to a pre-rollback clock domain and cannot
  # be used for arithmetic or transition history in the current tick.
  if [ "$mw_journal_epoch" -gt "$MW_NOW_EPOCH" ]; then
    /bin/rm -f "$mw_journal_file" || { MW_STATE_VALID=0; return 1; }
    return 0
  fi
  if mw_committed_state_supersedes_unmount_journal \
    "$mw_journal_fingerprint" "$mw_journal_epoch"; then
    # The combined action is already durably committed. Leave journal removal
    # to the normal post-status retirement path, but do not replay its overlay.
    return 0
  fi
  if [ "$mw_journal_epoch" -lt "$MW_PREV_LAST_ATTEMPT" ]; then
    if [ "$MW_JOURNAL_REFRESH_REQUIRED" = 1 ]; then
      MW_PREV_UNMOUNT_REFRESH_REQUIRED=1
      [ "$MW_JOURNAL_RESULT" != unmounted ] || MW_PREV_UNMOUNT_CONFIRMED=1
    fi
    return 0
  fi
  mw_journal_downstream_attempt=0
  if [ "$mw_journal_epoch" -eq "$MW_PREV_LAST_ATTEMPT" ] &&
    [ "$MW_JOURNAL_REFRESH_REQUIRED" = 1 ] &&
    [ "$MW_PREV_LAST_ATTEMPT_ACTION" = autofs-refresh ] &&
    [ "$MW_PREV_CHECKED" -ge "$mw_journal_epoch" ]; then
    mw_journal_downstream_attempt=1
  fi
  if [ "$mw_journal_epoch" -eq "$MW_PREV_LAST_ATTEMPT" ] &&
    [ "$mw_journal_downstream_attempt" -ne 1 ] && {
    [ "$MW_PREV_LAST_ATTEMPT_ACTION" != normal-unmount ] ||
      [ "$MW_PREV_LAST_ATTEMPT_RESULT" != "$MW_JOURNAL_RESULT" ] ||
      [ "$MW_PREV_LAST_ATTEMPT_EXIT_STATUS" != "$MW_JOURNAL_EXIT_STATUS" ] ||
      [ "$MW_PREV_CHECKED" -lt "$mw_journal_epoch" ];
  }; then
    MW_PREV_UNMOUNT_REFRESH_REQUIRED=1
    MW_STATE_VALID=0
    return 1
  fi
  if [ "$mw_journal_downstream_attempt" -eq 1 ]; then
    MW_PREV_PENDING=$MW_JOURNAL_PENDING
    [ "$MW_PREV_PENDING_SINCE" -gt 0 ] || MW_PREV_PENDING_SINCE=$mw_journal_epoch
    MW_PREV_UNMOUNT_REFRESH_REQUIRED=1
    [ "$MW_JOURNAL_RESULT" != unmounted ] || MW_PREV_UNMOUNT_CONFIRMED=1
    return 0
  fi
  if [ "$mw_journal_epoch" -ge "$MW_PREV_LAST_ATTEMPT" ]; then
    MW_PREV_LAST_ATTEMPT=$mw_journal_epoch
    MW_PREV_LAST_ATTEMPT_ACTION=normal-unmount
    MW_PREV_LAST_ATTEMPT_RESULT=$MW_JOURNAL_RESULT
    MW_PREV_LAST_ATTEMPT_EXIT_STATUS=$MW_JOURNAL_EXIT_STATUS
    MW_PREV_PENDING=$MW_JOURNAL_PENDING
    [ "$MW_PREV_PENDING_SINCE" -gt 0 ] || MW_PREV_PENDING_SINCE=$mw_journal_epoch
    MW_PREV_ACTION=$MW_JOURNAL_ACTION_STATE
    MW_PREV_LAST_ERROR=$MW_JOURNAL_LAST_ERROR
    MW_PREV_BLOCKED_PID=$MW_JOURNAL_BLOCKED_PID
  fi
  if [ "$MW_JOURNAL_REFRESH_REQUIRED" = 1 ]; then
    MW_PREV_UNMOUNT_REFRESH_REQUIRED=1
    [ "$MW_JOURNAL_RESULT" != unmounted ] || MW_PREV_UNMOUNT_CONFIRMED=1
  fi
  return 0
}

mw_retire_committed_unmount_journal() {
  mw_journal_dir=$1
  mw_committed_epoch=$2
  mw_journal_file=$mw_journal_dir/unmount-attempt
  { [ -e "$mw_journal_file" ] || [ -L "$mw_journal_file" ]; } || return 0
  mw_read_unmount_attempt_journal "$mw_journal_file" || return 1
  [ "$(mw_state_value "$mw_journal_file" runtime_fingerprint 2>/dev/null || true)" = "$MW_RUNTIME_FINGERPRINT" ] || return 1
  mw_journal_epoch=$(mw_state_value "$mw_journal_file" attempt_epoch 2>/dev/null || true)
  mw_is_uint "$mw_journal_epoch" && mw_is_uint "$mw_committed_epoch" || return 1
  [ "$mw_journal_epoch" -le "$mw_committed_epoch" ] || return 1
  /bin/rm -f "$mw_journal_file"
}

mw_summary_state() {
  case "$1:$2" in
    expected-smb:reachable) printf 'mounted-reachable\n' ;;
    expected-smb:unreachable) printf 'mounted-unreachable\n' ;;
    expected-smb:*) printf 'mounted-reachability-unknown\n' ;;
    trigger-only:*) printf 'trigger-only\n' ;;
    trigger-missing:*) printf 'trigger-missing\n' ;;
    unexpected-mount:*) printf 'unexpected-mount\n' ;;
    ambiguous-mount:*) printf 'ambiguous-mount\n' ;;
    *) printf 'inspection-error\n' ;;
  esac
}

mw_write_mount_status_index() {
  mw_write_i=$1
  mw_write_dir=$MW_STATE_DIR/${MW_MOUNT_NAMES[$mw_write_i]}
  [ ! -L "$mw_write_dir" ] || return 1
  if [ -e "$mw_write_dir" ] || [ -L "$mw_write_dir" ]; then
    [ -d "$mw_write_dir" ] && [ -O "$mw_write_dir" ] || return 1
    mw_directory_is_trusted "$mw_write_dir" none || return 1
  else
    /bin/mkdir "$mw_write_dir" || return 1
    mw_strip_acl_from_new_node "$mw_write_dir" || return 1
  fi
  /bin/chmod 700 "$mw_write_dir" || return 1
  mw_directory_is_trusted "$mw_write_dir" none || return 1
  mw_write_summary=$(mw_summary_state "${MW_OBS[$mw_write_i]}" "${MW_NET[$mw_write_i]}")
  mw_atomic_write_lines "$mw_write_dir/status" \
    "format|$MW_STATE_FORMAT" \
    "checked_at_epoch|$MW_NOW_EPOCH" \
    "checked_at|$MW_NOW_ISO" \
    "mount_name|${MW_MOUNT_NAMES[$mw_write_i]}" \
    "mount_path|${MW_MOUNT_PATHS[$mw_write_i]}" \
    "expected_host|${MW_MOUNT_HOSTS[$mw_write_i]}" \
    "expected_share|${MW_MOUNT_SHARES[$mw_write_i]}" \
    "state|$mw_write_summary" \
    "mount_state|${MW_OBS[$mw_write_i]}" \
    "network_state|${MW_NET[$mw_write_i]}" \
    "last_network_state|${MW_LAST_NET[$mw_write_i]}" \
    "check_scope|$MW_CHECK_SCOPE" \
    "readability|$MW_READABILITY" \
    "runtime_fingerprint|$MW_RUNTIME_FINGERPRINT" \
    "initialized|${MW_INITIALIZED[$mw_write_i]}" \
    "pending_recovery|${MW_PENDING[$mw_write_i]}" \
    "pending_since_epoch|${MW_PENDING_SINCE[$mw_write_i]}" \
    "action_state|${MW_ACTION[$mw_write_i]}" \
    "last_attempt_epoch|${MW_LAST_ATTEMPT[$mw_write_i]}" \
    "last_attempt_action|${MW_LAST_ATTEMPT_ACTION[$mw_write_i]}" \
    "last_attempt_result|${MW_LAST_ATTEMPT_RESULT[$mw_write_i]}" \
    "last_attempt_exit_status|${MW_LAST_ATTEMPT_EXIT_STATUS[$mw_write_i]}" \
    "last_successful_action_epoch|${MW_LAST_SUCCESS[$mw_write_i]}" \
    "last_successful_action|${MW_LAST_SUCCESS_ACTION[$mw_write_i]}" \
    "last_error|${MW_LAST_ERROR[$mw_write_i]}" \
    "blocked_pid|${MW_BLOCKED_PID[$mw_write_i]}"
}

mw_write_heartbeat() {
  mw_heartbeat_phase=$1
  mw_heartbeat_result=$2
  mw_atomic_write_lines "$MW_STATE_DIR/heartbeat" \
    "format|$MW_STATE_FORMAT" \
    "phase|$mw_heartbeat_phase" \
    "started_epoch|$MW_TICK_STARTED_EPOCH" \
    "completed_epoch|${MW_TICK_COMPLETED_EPOCH:-0}" \
    "checked_at|$MW_NOW_ISO" \
    "runtime_fingerprint|$MW_RUNTIME_FINGERPRINT" \
    "result|$mw_heartbeat_result"
}
