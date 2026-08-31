#!/bin/bash

# Shared, side-effect-free parsing and validation for MountWatchdog.
# This file supports the /bin/bash 3.2 shipped with macOS.

mw_error() {
  printf 'MountWatchdog: %s\n' "$*" >&2
}

# Parse launchctl's print-disabled dictionary without treating label
# punctuation as regular-expression syntax. The complete quoted key must be
# followed only by the dictionary arrow and a literal true value.
mw_launchctl_label_is_disabled() {
  mw_disabled_label=$1
  /usr/bin/awk -v label="$mw_disabled_label" '
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/[[:space:]]*$/, "", line)
      quoted = "\"" label "\""
      if (substr(line, 1, length(quoted)) != quoted) next
      rest = substr(line, length(quoted) + 1)
      sub(/^[[:space:]]*/, "", rest)
      if (substr(rest, 1, 2) != "=>") next
      rest = substr(rest, 3)
      sub(/^[[:space:]]*/, "", rest)
      sub(/[[:space:]]*$/, "", rest)
      if (rest == "true" || rest == "true,") found = 1
    }
    END { print found ? 1 : 0 }
  '
}

mw_is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    0[0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

mw_is_safe_name() {
  [ "${#1}" -le 64 ] || return 1
  case "${1:-}" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    [A-Za-z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

mw_is_safe_user() {
  [ "${#1}" -le 64 ] || return 1
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*|[0-9.-]*|*..*) return 1 ;;
    *) return 0 ;;
  esac
}

mw_is_safe_host() {
  [ "${#1}" -le 253 ] || return 1
  case "${1:-}" in
    ''|*[!A-Za-z0-9.-]*|[-.]*|*[-.]|*..*) return 1 ;;
  esac

  mw_host_rest=$1
  while :; do
    case "$mw_host_rest" in
      *.*)
        mw_host_label=${mw_host_rest%%.*}
        mw_host_rest=${mw_host_rest#*.}
        ;;
      *)
        mw_host_label=$mw_host_rest
        mw_host_rest=
        ;;
    esac
    [ -n "$mw_host_label" ] && [ "${#mw_host_label}" -le 63 ] || return 1
    case "$mw_host_label" in
      [A-Za-z0-9]*[A-Za-z0-9]|[A-Za-z0-9]) ;;
      *) return 1 ;;
    esac
    [ -n "$mw_host_rest" ] || break
  done
  return 0
}

mw_is_safe_share() {
  [ "${#1}" -le 80 ] || return 1
  case "${1:-}" in
    ''|.|..|*[!A-Za-z0-9._\$-]*) return 1 ;;
    [A-Za-z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

mw_is_absolute_path() {
  case "${1:-}" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *//*|*/../*|*/..|*/./*|*/.) return 1 ;;
  esac
  return 0
}

mw_validate_interval_values() {
  mw_is_uint "$MW_INTERVAL_SECONDS" || {
    mw_error 'interval_seconds must be an integer'
    return 1
  }
  mw_is_uint "$MW_SCHEDULING_GAP_SECONDS" || {
    mw_error 'scheduling_gap_seconds must be an integer'
    return 1
  }
  mw_is_uint "$MW_RECOVERY_COOLDOWN_SECONDS" || {
    mw_error 'recovery_cooldown_seconds must be an integer'
    return 1
  }
  mw_is_uint "$MW_COMMAND_TIMEOUT_SECONDS" || {
    mw_error 'command_timeout_seconds must be an integer'
    return 1
  }

  [ "$MW_INTERVAL_SECONDS" -ge 10 ] && [ "$MW_INTERVAL_SECONDS" -le 3600 ] || {
    mw_error 'interval_seconds must be between 10 and 3600'
    return 1
  }
  [ "$MW_SCHEDULING_GAP_SECONDS" -ge "$MW_INTERVAL_SECONDS" ] || {
    mw_error 'scheduling_gap_seconds must be at least interval_seconds'
    return 1
  }
  [ "$MW_RECOVERY_COOLDOWN_SECONDS" -ge "$MW_INTERVAL_SECONDS" ] || {
    mw_error 'recovery_cooldown_seconds must be at least interval_seconds'
    return 1
  }
  [ "$MW_COMMAND_TIMEOUT_SECONDS" -ge 1 ] && [ "$MW_COMMAND_TIMEOUT_SECONDS" -le 60 ] || {
    mw_error 'command_timeout_seconds must be between 1 and 60'
    return 1
  }
}

mw_parse_defaults() {
  mw_defaults_file=$1
  [ -f "$mw_defaults_file" ] && [ ! -L "$mw_defaults_file" ] || {
    mw_error "defaults file is missing, not regular, or a symlink: $mw_defaults_file"
    return 1
  }

  MW_INTERVAL_SECONDS=
  MW_SCHEDULING_GAP_SECONDS=
  MW_RECOVERY_COOLDOWN_SECONDS=
  MW_COMMAND_TIMEOUT_SECONDS=
  mw_defaults_format=

  while IFS= read -r mw_line || [ -n "$mw_line" ]; do
    case "$mw_line" in
      ''|'#'*) continue ;;
    esac
    case "$mw_line" in
      *'|'*) ;;
      *) mw_error 'malformed defaults record'; return 1 ;;
    esac
    mw_key=${mw_line%%|*}
    mw_value=${mw_line#*|}
    case "$mw_value" in
      *'|'*) mw_error 'malformed defaults record'; return 1 ;;
    esac
    [ -n "$mw_key" ] && [ -n "$mw_value" ] || {
      mw_error 'malformed defaults record'
      return 1
    }
    case "$mw_key" in
      format)
        [ -z "$mw_defaults_format" ] || { mw_error 'duplicate defaults format'; return 1; }
        mw_defaults_format=$mw_value
        ;;
      interval_seconds)
        [ -z "$MW_INTERVAL_SECONDS" ] || { mw_error 'duplicate interval_seconds'; return 1; }
        MW_INTERVAL_SECONDS=$mw_value
        ;;
      scheduling_gap_seconds)
        [ -z "$MW_SCHEDULING_GAP_SECONDS" ] || { mw_error 'duplicate scheduling_gap_seconds'; return 1; }
        MW_SCHEDULING_GAP_SECONDS=$mw_value
        ;;
      recovery_cooldown_seconds)
        [ -z "$MW_RECOVERY_COOLDOWN_SECONDS" ] || { mw_error 'duplicate recovery_cooldown_seconds'; return 1; }
        MW_RECOVERY_COOLDOWN_SECONDS=$mw_value
        ;;
      command_timeout_seconds)
        [ -z "$MW_COMMAND_TIMEOUT_SECONDS" ] || { mw_error 'duplicate command_timeout_seconds'; return 1; }
        MW_COMMAND_TIMEOUT_SECONDS=$mw_value
        ;;
      *) mw_error "unknown defaults key: $mw_key"; return 1 ;;
    esac
  done < "$mw_defaults_file"

  [ "$mw_defaults_format" = 1 ] || { mw_error 'unsupported defaults format'; return 1; }
  [ -n "$MW_INTERVAL_SECONDS" ] &&
    [ -n "$MW_SCHEDULING_GAP_SECONDS" ] &&
    [ -n "$MW_RECOVERY_COOLDOWN_SECONDS" ] &&
    [ -n "$MW_COMMAND_TIMEOUT_SECONDS" ] || {
      mw_error 'defaults file is incomplete'
      return 1
    }
  mw_validate_interval_values
}

mw_array_contains() {
  mw_wanted=$1
  shift
  for mw_item in "$@"; do
    [ "$mw_item" = "$mw_wanted" ] && return 0
  done
  return 1
}

mw_array_contains_folded() {
  mw_wanted_folded=$(printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]')
  shift
  for mw_item in "$@"; do
    mw_item_folded=$(printf '%s' "$mw_item" | /usr/bin/tr '[:upper:]' '[:lower:]')
    [ "$mw_item_folded" = "$mw_wanted_folded" ] && return 0
  done
  return 1
}

mw_parse_config() {
  mw_config_file=$1
  [ -f "$mw_config_file" ] && [ ! -L "$mw_config_file" ] || {
    mw_error "configuration is missing, not regular, or a symlink: $mw_config_file"
    return 1
  }

  MW_CONFIG_LOCAL_USER=
  MW_MOUNT_NAMES=()
  MW_MOUNT_PATHS=()
  MW_MOUNT_HOSTS=()
  MW_MOUNT_SHARES=()
  MW_CONFIG_LOCAL_USER=

  while IFS= read -r mw_line || [ -n "$mw_line" ]; do
    case "$mw_line" in
      ''|'#'*) continue ;;
    esac

    mw_tab=$(printf '\tX')
    mw_tab=${mw_tab%X}
    case "$mw_line" in
      *"$mw_tab"*) ;;
      *) mw_error 'configuration record must contain exactly four tab-separated fields'; return 1 ;;
    esac
    mw_a=${mw_line%%"$mw_tab"*}
    mw_rest=${mw_line#*"$mw_tab"}
    case "$mw_rest" in
      *"$mw_tab"*) ;;
      *) mw_error 'configuration record must contain exactly four tab-separated fields'; return 1 ;;
    esac
    mw_b=${mw_rest%%"$mw_tab"*}
    mw_rest=${mw_rest#*"$mw_tab"}
    case "$mw_rest" in
      *"$mw_tab"*) ;;
      *) mw_error 'configuration record must contain exactly four tab-separated fields'; return 1 ;;
    esac
    mw_c=${mw_rest%%"$mw_tab"*}
    mw_d=${mw_rest#*"$mw_tab"}
    case "$mw_d" in
      *"$mw_tab"*) mw_error 'configuration record has more than four fields'; return 1 ;;
    esac

    [ -n "$mw_a" ] && [ -n "$mw_b" ] && [ -n "$mw_c" ] && [ -n "$mw_d" ] || {
      mw_error 'configuration fields must not be empty'
      return 1
    }
    mw_is_safe_name "$mw_a" || { mw_error "unsafe mount name: $mw_a"; return 1; }
    mw_is_absolute_path "$mw_b" || { mw_error "unsafe mount path for $mw_a"; return 1; }
    mw_is_safe_host "$mw_c" || { mw_error "unsafe mount host for $mw_a"; return 1; }
    mw_is_safe_share "$mw_d" || { mw_error "unsafe mount share for $mw_a"; return 1; }
    if [ "${#MW_MOUNT_NAMES[@]}" -gt 0 ] &&
      mw_array_contains_folded "$mw_a" "${MW_MOUNT_NAMES[@]}"; then
      mw_error "duplicate or case-colliding mount name: $mw_a"
      return 1
    fi
    if [ "${#MW_MOUNT_PATHS[@]}" -gt 0 ] &&
      mw_array_contains "$mw_b" "${MW_MOUNT_PATHS[@]}"; then
      mw_error "duplicate mount path: $mw_b"
      return 1
    fi

    mw_path_prefix=${mw_b%/"$mw_a"}
    case "$mw_path_prefix" in
      /Users/*) mw_user=${mw_path_prefix#/Users/} ;;
      *) mw_error "mount path must be /Users/<user>/$mw_a"; return 1 ;;
    esac
    case "$mw_user" in
      */*) mw_error "mount path must be /Users/<user>/$mw_a"; return 1 ;;
    esac
    mw_is_safe_user "$mw_user" || { mw_error "unsafe local user for $mw_a"; return 1; }
    [ "$mw_b" = "/Users/$mw_user/$mw_a" ] || {
      mw_error "mount path must end with its exact mount name: $mw_a"
      return 1
    }
    if [ -z "$MW_CONFIG_LOCAL_USER" ]; then
      MW_CONFIG_LOCAL_USER=$mw_user
    elif [ "$MW_CONFIG_LOCAL_USER" != "$mw_user" ]; then
      mw_error 'all configured mounts must use the same local user'
      return 1
    fi

    MW_MOUNT_NAMES[${#MW_MOUNT_NAMES[@]}]=$mw_a
    MW_MOUNT_PATHS[${#MW_MOUNT_PATHS[@]}]=$mw_b
    MW_MOUNT_HOSTS[${#MW_MOUNT_HOSTS[@]}]=$mw_c
    MW_MOUNT_SHARES[${#MW_MOUNT_SHARES[@]}]=$mw_d
  done < "$mw_config_file"

  [ "${#MW_MOUNT_NAMES[@]}" -gt 0 ] || { mw_error 'configuration has no mounts'; return 1; }
}

mw_state_value() {
  mw_state_file=$1
  mw_state_key=$2
  [ -f "$mw_state_file" ] && [ ! -L "$mw_state_file" ] || return 1
  while IFS= read -r mw_state_line || [ -n "$mw_state_line" ]; do
    case "$mw_state_line" in
      *'|'*) ;;
      *) continue ;;
    esac
    mw_key=${mw_state_line%%|*}
    mw_value=${mw_state_line#*|}
    [ "$mw_key" = "$mw_state_key" ] || continue
    case "$mw_value" in
      *'|'*) return 1 ;;
    esac
    printf '%s\n' "$mw_value"
    return 0
  done < "$mw_state_file"
  return 1
}

mw_sanitize_field() {
  printf '%s' "${1:-}" | /usr/bin/tr '\n\r|\t' '    '
}
