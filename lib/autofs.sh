#!/bin/bash

# Strict, credential-redacting parsers for the narrow autofs subset used by
# MountWatchdog. This file is compatible with macOS /bin/bash 3.2.

mw_autofs_error() {
  printf 'MountWatchdog: %s\n' "$*" >&2
}

mw_autofs_valid_percent_escapes() {
  mw_pct_value=$1
  mw_pct_index=0
  while [ "$mw_pct_index" -lt "${#mw_pct_value}" ]; do
    mw_pct_char=${mw_pct_value:$mw_pct_index:1}
    if [ "$mw_pct_char" = '%' ]; then
      [ $((mw_pct_index + 2)) -lt "${#mw_pct_value}" ] || return 1
      mw_pct_pair=${mw_pct_value:$((mw_pct_index + 1)):2}
      case "$mw_pct_pair" in
        *[!A-Fa-f0-9]*) return 1 ;;
      esac
      mw_pct_index=$((mw_pct_index + 3))
    else
      mw_pct_index=$((mw_pct_index + 1))
    fi
  done
  return 0
}

mw_autofs_array_contains() {
  mw_autofs_wanted=$1
  shift
  for mw_autofs_item in "$@"; do
    [ "$mw_autofs_item" = "$mw_autofs_wanted" ] && return 0
  done
  return 1
}

mw_validate_auto_master() {
  mw_master_file=$1
  MW_AUTO_MASTER_HOOK_MISSING=0
  [ -f "$mw_master_file" ] && [ ! -L "$mw_master_file" ] || {
    mw_autofs_error 'auto_master is missing, not regular, or a symlink'
    return 1
  }

  mw_master_line_number=0
  mw_master_smb_count=0
  MW_AUTO_MASTER_DIRECTORY_INCLUDE=0
  MW_AUTO_MASTER_STATIC_PRESENT=0
  MW_AUTO_MASTER_EXPLICIT_TARGETS=()
  MW_AUTO_MASTER_EXPLICIT_LINES=()
  while IFS= read -r mw_master_line || [ -n "$mw_master_line" ]; do
    mw_master_line_number=$((mw_master_line_number + 1))
    case "$mw_master_line" in
      *\\*)
        mw_autofs_error "unsupported auto_master escaping at line $mw_master_line_number"
        return 1
        ;;
    esac

    # Inline comments are conventional in Apple's auto_master. They are safe
    # to strip here because this file does not contain SMB locations.
    mw_master_record=${mw_master_line%%#*}
    mw_master_old_ifs=$IFS
    IFS=' 	'
    set -f
    # shellcheck disable=SC2086 # Intentional whitespace field split; globbing is disabled.
    set -- $mw_master_record
    set +f
    IFS=$mw_master_old_ifs
    [ "$#" -gt 0 ] || continue

    case "$1" in
      +auto_master)
        [ "$#" -eq 1 ] && [ "$MW_AUTO_MASTER_DIRECTORY_INCLUDE" -eq 0 ] || {
          mw_autofs_error "malformed auto_master include at line $mw_master_line_number"
          return 1
        }
        MW_AUTO_MASTER_DIRECTORY_INCLUDE=1
        continue
        ;;
      +*)
        mw_autofs_error "unsupported auto_master include at line $mw_master_line_number"
        return 1
        ;;
    esac

    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || {
      mw_autofs_error "malformed auto_master record at line $mw_master_line_number"
      return 1
    }
    case "$1" in
      /*) ;;
      *)
        mw_autofs_error "unsupported auto_master target at line $mw_master_line_number"
        return 1
        ;;
    esac
    mw_is_absolute_path "$1" || {
      mw_autofs_error "unsupported auto_master target at line $mw_master_line_number"
      return 1
    }
    case "$1" in
      /) ;;
      */)
        mw_autofs_error "unsupported auto_master target at line $mw_master_line_number"
        return 1
        ;;
    esac
    if [ "$#" -eq 3 ]; then
      case "$3" in
        -?*)
          case "${3#-}" in
            *[!A-Za-z0-9_,.=-]*)
              mw_autofs_error "unsupported auto_master options at line $mw_master_line_number"
              return 1
              ;;
          esac
          ;;
        *)
          mw_autofs_error "unsupported auto_master options at line $mw_master_line_number"
          return 1
          ;;
      esac
    fi

    if [ "$1" != '/-' ]; then
      MW_AUTO_MASTER_EXPLICIT_TARGETS[${#MW_AUTO_MASTER_EXPLICIT_TARGETS[@]}]=$1
      MW_AUTO_MASTER_EXPLICIT_LINES[${#MW_AUTO_MASTER_EXPLICIT_LINES[@]}]=$mw_master_line_number
      continue
    fi
    case "$2" in
      auto_smb|/etc/auto_smb)
        mw_master_smb_count=$((mw_master_smb_count + 1))
        ;;
      -static)
        # Apple's standard direct static map can coexist with auto_smb.
        [ "$MW_AUTO_MASTER_STATIC_PRESENT" -eq 0 ] || {
          mw_autofs_error "duplicate -static direct map at auto_master line $mw_master_line_number"
          return 1
        }
        MW_AUTO_MASTER_STATIC_PRESENT=1
        ;;
      *)
        mw_autofs_error "conflicting active direct map at auto_master line $mw_master_line_number"
        return 1
        ;;
    esac
  done < "$mw_master_file"

  [ "$mw_master_smb_count" -eq 1 ] || {
    [ "$mw_master_smb_count" -ne 0 ] || MW_AUTO_MASTER_HOOK_MISSING=1
    mw_autofs_error 'auto_master must contain exactly one active /- auto_smb entry'
    return 1
  }
}

mw_autofs_paths_overlap() {
  mw_overlap_left=$1
  mw_overlap_right=$2
  [ "$mw_overlap_left" = "$mw_overlap_right" ] && return 0
  [ "$mw_overlap_left" = / ] && return 0
  [ "$mw_overlap_right" = / ] && return 0
  case "$mw_overlap_left" in
    "$mw_overlap_right"/*) return 0 ;;
  esac
  case "$mw_overlap_right" in
    "$mw_overlap_left"/*) return 0 ;;
  esac
  return 1
}

mw_validate_auto_master_selected_paths() {
  for mw_selected_path in "$@"; do
    mw_is_absolute_path "$mw_selected_path" || {
      mw_autofs_error 'unsafe selected mount path'
      return 1
    }
    mw_master_target_index=0
    while [ "$mw_master_target_index" -lt "${#MW_AUTO_MASTER_EXPLICIT_TARGETS[@]}" ]; do
      mw_master_target=${MW_AUTO_MASTER_EXPLICIT_TARGETS[$mw_master_target_index]}
      if mw_autofs_paths_overlap "$mw_master_target" "$mw_selected_path"; then
        mw_master_target_line=${MW_AUTO_MASTER_EXPLICIT_LINES[$mw_master_target_index]}
        mw_autofs_error "conflicting explicit auto_master target at line $mw_master_target_line"
        return 1
      fi
      mw_master_target_index=$((mw_master_target_index + 1))
    done
  done
  return 0
}

mw_autofs_validate_options() {
  mw_options_token=$1
  case "$mw_options_token" in
    -?*) ;;
    *) return 1 ;;
  esac
  mw_options_rest=${mw_options_token#-}
  mw_options_fstype_count=0
  while :; do
    mw_options_atom=${mw_options_rest%%,*}
    [ -n "$mw_options_atom" ] || return 1
    case "$mw_options_atom" in
      fstype=smb|fstype=smbfs)
        mw_options_fstype_count=$((mw_options_fstype_count + 1))
        ;;
      fstype=*) return 1 ;;
      *[!A-Za-z0-9._=-]*) return 1 ;;
    esac
    case "$mw_options_rest" in
      *,*) mw_options_rest=${mw_options_rest#*,} ;;
      *) break ;;
    esac
  done
  [ "$mw_options_fstype_count" -eq 1 ]
}

mw_parse_auto_smb() {
  mw_smb_file=$1
  mw_smb_user=$2
  [ -f "$mw_smb_file" ] && [ ! -L "$mw_smb_file" ] || {
    mw_autofs_error 'auto_smb is missing, not regular, or a symlink'
    return 1
  }
  mw_is_safe_user "$mw_smb_user" || {
    mw_autofs_error 'unsafe local user'
    return 1
  }

  MW_AUTO_NAMES=()
  MW_AUTO_PATHS=()
  MW_AUTO_HOSTS=()
  MW_AUTO_SHARES=()
  MW_AUTO_SOFT=()
  MW_AUTO_FOLDED_NAMES=()
  mw_smb_line_number=0

  while IFS= read -r mw_smb_line || [ -n "$mw_smb_line" ]; do
    mw_smb_line_number=$((mw_smb_line_number + 1))

    mw_smb_old_ifs=$IFS
    IFS=' 	'
    set -f
    # shellcheck disable=SC2086 # Intentional whitespace field split; globbing is disabled.
    set -- $mw_smb_line
    set +f
    IFS=$mw_smb_old_ifs
    [ "$#" -gt 0 ] || continue
    case "$1" in
      \#*) continue ;;
    esac

    case "$mw_smb_line" in
      *\\*)
        mw_autofs_error "unsupported auto_smb escaping at line $mw_smb_line_number"
        return 1
        ;;
    esac
    [ "$#" -eq 3 ] || {
      mw_autofs_error "malformed auto_smb record at line $mw_smb_line_number"
      return 1
    }

    mw_smb_path=$1
    mw_smb_options=$2
    mw_smb_location=$3
    case "$mw_smb_path" in
      "/Users/$mw_smb_user/"*) ;;
      *)
        mw_autofs_error "unexpected auto_smb target at line $mw_smb_line_number"
        return 1
        ;;
    esac
    mw_smb_name=${mw_smb_path#"/Users/$mw_smb_user/"}
    mw_is_safe_name "$mw_smb_name" &&
      [ "$mw_smb_path" = "/Users/$mw_smb_user/$mw_smb_name" ] || {
        mw_autofs_error "unsafe auto_smb target at line $mw_smb_line_number"
        return 1
      }
    mw_autofs_validate_options "$mw_smb_options" || {
      mw_autofs_error "unsupported SMB options at line $mw_smb_line_number"
      return 1
    }

    case "$mw_smb_location" in
      ://*) mw_smb_authority_path=${mw_smb_location#://} ;;
      *)
        mw_autofs_error "unsupported SMB location at line $mw_smb_line_number"
        return 1
        ;;
    esac
    case "$mw_smb_authority_path" in
      *\#*|*\?*)
        mw_autofs_error "unsupported SMB location suffix at line $mw_smb_line_number"
        return 1
        ;;
    esac
    case "$mw_smb_authority_path" in
      *@*)
        mw_smb_userinfo=${mw_smb_authority_path%%@*}
        mw_smb_authority_path=${mw_smb_authority_path#*@}
        if [ -z "$mw_smb_userinfo" ] || ! mw_autofs_valid_percent_escapes "$mw_smb_userinfo"; then
            mw_autofs_error "unsupported SMB user information at line $mw_smb_line_number"
            return 1
        fi
        case "$mw_smb_authority_path" in
          *@*)
            mw_autofs_error "ambiguous SMB authority at line $mw_smb_line_number"
            return 1
            ;;
        esac
        ;;
    esac

    case "$mw_smb_authority_path" in
      */*) ;;
      *)
        mw_autofs_error "missing SMB share at line $mw_smb_line_number"
        return 1
        ;;
    esac
    mw_smb_host=${mw_smb_authority_path%%/*}
    mw_smb_share=${mw_smb_authority_path#*/}
    case "$mw_smb_share" in
      */*)
        mw_autofs_error "SMB subpaths are unsupported at line $mw_smb_line_number"
        return 1
        ;;
    esac
    if ! mw_is_safe_host "$mw_smb_host" || ! mw_is_safe_share "$mw_smb_share"; then
      mw_autofs_error "unsupported SMB host or share at line $mw_smb_line_number"
      return 1
    fi

    mw_smb_folded=$(printf '%s' "$mw_smb_name" | /usr/bin/tr '[:upper:]' '[:lower:]')
    if [ "${#MW_AUTO_FOLDED_NAMES[@]}" -gt 0 ] && mw_autofs_array_contains "$mw_smb_folded" "${MW_AUTO_FOLDED_NAMES[@]}"; then
      mw_autofs_error "duplicate auto_smb target at line $mw_smb_line_number"
      return 1
    fi
    MW_AUTO_FOLDED_NAMES[${#MW_AUTO_FOLDED_NAMES[@]}]=$mw_smb_folded
    MW_AUTO_NAMES[${#MW_AUTO_NAMES[@]}]=$mw_smb_name
    MW_AUTO_PATHS[${#MW_AUTO_PATHS[@]}]=$mw_smb_path
    MW_AUTO_HOSTS[${#MW_AUTO_HOSTS[@]}]=$mw_smb_host
    MW_AUTO_SHARES[${#MW_AUTO_SHARES[@]}]=$mw_smb_share
    case ",$mw_smb_options," in
      *,soft,*) MW_AUTO_SOFT[${#MW_AUTO_SOFT[@]}]=1 ;;
      *) MW_AUTO_SOFT[${#MW_AUTO_SOFT[@]}]=0 ;;
    esac
  done < "$mw_smb_file"

  [ "${#MW_AUTO_NAMES[@]}" -gt 0 ] || {
    mw_autofs_error 'auto_smb contains no supported mappings'
    return 1
  }
}

# Validate the installed selection against the supported, effective file-map
# hookup before the runtime may probe or recover anything. Directory Service
# expansion through +auto_master is deliberately not treated as an alternative
# source here; that migration needs separate native validation before support.
# shellcheck disable=SC2034 # MW_AUTOFS_DRIFT_REASON is consumed by the sourcing runtime.
mw_validate_runtime_autofs_configuration() {
  MW_AUTOFS_DRIFT_REASON=autofs-master-map-invalid

  if ! mw_regular_file_is_trusted "$MW_AUTO_MASTER_FILE" deny-only ||
    ! mw_file_has_single_link "$MW_AUTO_MASTER_FILE"; then
    return 1
  fi
  if ! mw_validate_auto_master "$MW_AUTO_MASTER_FILE"; then
    if [ "${MW_AUTO_MASTER_HOOK_MISSING:-0}" -eq 1 ]; then
      MW_AUTOFS_DRIFT_REASON=autofs-hook-missing
    fi
    return 1
  fi

  if [ ! -e "$MW_AUTO_SMB_FILE" ] && [ ! -L "$MW_AUTO_SMB_FILE" ]; then
    MW_AUTOFS_DRIFT_REASON=autofs-selected-map-missing
    return 1
  fi
  MW_AUTOFS_DRIFT_REASON=autofs-selected-map-invalid
  if ! mw_regular_file_is_trusted "$MW_AUTO_SMB_FILE" deny-only ||
    ! mw_file_has_single_link "$MW_AUTO_SMB_FILE" ||
    ! mw_parse_auto_smb "$MW_AUTO_SMB_FILE" "$MW_CONFIG_LOCAL_USER" ||
    ! mw_validate_auto_master_selected_paths "${MW_MOUNT_PATHS[@]}"; then
    return 1
  fi

  mw_runtime_selected_index=0
  while [ "$mw_runtime_selected_index" -lt "${#MW_MOUNT_NAMES[@]}" ]; do
    mw_runtime_map_match=0
    mw_runtime_map_index=0
    while [ "$mw_runtime_map_index" -lt "${#MW_AUTO_NAMES[@]}" ]; do
      if [ "${MW_AUTO_NAMES[$mw_runtime_map_index]}" = "${MW_MOUNT_NAMES[$mw_runtime_selected_index]}" ] &&
        [ "${MW_AUTO_PATHS[$mw_runtime_map_index]}" = "${MW_MOUNT_PATHS[$mw_runtime_selected_index]}" ] &&
        [ "${MW_AUTO_HOSTS[$mw_runtime_map_index]}" = "${MW_MOUNT_HOSTS[$mw_runtime_selected_index]}" ] &&
        [ "${MW_AUTO_SHARES[$mw_runtime_map_index]}" = "${MW_MOUNT_SHARES[$mw_runtime_selected_index]}" ]; then
        mw_runtime_map_match=$((mw_runtime_map_match + 1))
      fi
      mw_runtime_map_index=$((mw_runtime_map_index + 1))
    done
    if [ "$mw_runtime_map_match" -ne 1 ]; then
      MW_AUTOFS_DRIFT_REASON=autofs-selected-mapping-mismatch
      return 1
    fi
    mw_runtime_selected_index=$((mw_runtime_selected_index + 1))
  done

  return 0
}
