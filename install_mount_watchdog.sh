#!/bin/bash

# Transactional MountWatchdog installer for macOS /bin/bash 3.2.
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
MW_RUNTIME_WRAPPER='/usr/local/sbin/mount_watchdog.sh'
MW_STATUS_WRAPPER='/usr/local/sbin/mount_watchdog_status.sh'
MW_LOG='/var/log/mount-watchdog.log'

mw_installer_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || {
  printf 'MountWatchdog: cannot resolve installer directory\n' >&2
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
  case "$mw_repo_file" in "$mw_installer_dir"/*) ;; *) return 1 ;; esac
  mw_repo_node_is_trusted "$mw_repo_file" file || return 1
  mw_repo_parent=$(dirname -- "$mw_repo_file")
  while :; do
    mw_repo_node_is_trusted "$mw_repo_parent" directory || return 1
    [ "$mw_repo_parent" != "$mw_installer_dir" ] || break
    case "$mw_repo_parent" in "$mw_installer_dir"/*) ;; *) return 1 ;; esac
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
mw_repo_directory_chain_is_trusted "$mw_installer_dir" || {
  printf 'MountWatchdog: installer directory ancestor ownership or mode is unsafe\n' >&2
  exit 1
}
mw_installer_source="$mw_installer_dir/$(basename -- "${BASH_SOURCE[0]}")"
mw_repo_file_is_trusted "$mw_installer_source" || {
  printf 'MountWatchdog: installer source ownership or mode is unsafe\n' >&2
  exit 1
}
mw_repo_file_is_trusted "$mw_installer_dir/lib/common.sh" || {
  printf 'MountWatchdog: common library is missing or untrusted\n' >&2
  exit 1
}
mw_repo_file_is_trusted "$mw_installer_dir/lib/autofs.sh" || {
  printf 'MountWatchdog: autofs library is missing or untrusted\n' >&2
  exit 1
}
# shellcheck source=lib/common.sh
. "$mw_installer_dir/lib/common.sh" || exit 1
# shellcheck source=lib/autofs.sh
. "$mw_installer_dir/lib/autofs.sh" || exit 1

mw_usage() {
  cat <<'EOF'
Usage:
  sudo /bin/bash ./install_mount_watchdog.sh [options] MOUNT_NAME [MOUNT_NAME ...]

Options:
  --local-user USER              Require /Users/USER/<name> targets.
  --dry-run                      Validate and print the plan; install nothing.
  --enable                       Bootstrap instead of preserving a disabled or unloaded job.
  --replace-targets              Permit removing names from installed config.
  --staging-root DIR             Nonprivileged test root; never live '/'.
  -h, --help                     Show help.

The installer reads /etc/auto_master and /etc/auto_smb but never changes them.
Before the protected commit boundary, catchable HUP, INT, TERM, and QUIT
signals and unexpected shell exits trigger transaction rollback. SIGKILL cannot
be caught and is outside that guarantee.
EOF
}

mw_transaction_started=0
mw_backup_dir=
mw_stage_dir=

mw_die() {
  trap '' HUP INT TERM QUIT
  printf 'MountWatchdog: %s\n' "$*" >&2
  if [ "$mw_transaction_started" -eq 1 ]; then
    mw_rollback || printf 'MountWatchdog: rollback incomplete; retain %s\n' "${mw_backup_dir:-unknown}" >&2
  fi
  exit 1
}

mw_root=
mw_dry_run=0
mw_enable=0
mw_replace_targets=0
mw_local_user=
MW_REQUESTED=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --local-user) [ "$#" -ge 2 ] || { mw_usage >&2; exit 2; }; mw_local_user=$2; shift 2 ;;
    --dry-run) mw_dry_run=1; shift ;;
    --enable) mw_enable=1; shift ;;
    --replace-targets) mw_replace_targets=1; shift ;;
    --staging-root) [ "$#" -ge 2 ] || { mw_usage >&2; exit 2; }; mw_root=$2; shift 2 ;;
    -h|--help) mw_usage; exit 0 ;;
    --) shift; while [ "$#" -gt 0 ]; do MW_REQUESTED[${#MW_REQUESTED[@]}]=$1; shift; done ;;
    -*) printf 'MountWatchdog: unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) MW_REQUESTED[${#MW_REQUESTED[@]}]=$1; shift ;;
  esac
done
[ "${#MW_REQUESTED[@]}" -gt 0 ] || { mw_usage >&2; exit 2; }

if [ -n "$mw_root" ]; then
  [ "${EUID:-$(/usr/bin/id -u)}" -ne 0 ] || mw_die '--staging-root is forbidden when running as root'
  case "$mw_root" in /*) ;; *) mw_die '--staging-root must be absolute' ;; esac
  [ -d "$mw_root" ] && [ ! -L "$mw_root" ] || mw_die '--staging-root must be an existing non-symlink directory'
  mw_root=$(CDPATH='' cd -- "$mw_root" 2>/dev/null && pwd -P) || mw_die 'cannot canonicalize --staging-root'
  case "$mw_root" in /|/System|/Library|/usr|/etc|/private|/var|/Users) mw_die 'refusing unsafe --staging-root' ;; esac
else
  [ "$(/usr/bin/uname -s)" = Darwin ] || mw_die 'live installation is supported only on macOS'
  [ "$mw_dry_run" -eq 1 ] || [ "${EUID:-$(/usr/bin/id -u)}" -eq 0 ] || mw_die 'live installation must run as root (dry-run does not)'
fi

if [ -z "$mw_local_user" ]; then
  case "${SUDO_USER:-}" in ''|root) mw_die 'use --local-user USER' ;; *) mw_local_user=$SUDO_USER ;; esac
fi
mw_is_safe_user "$mw_local_user" || mw_die 'unsafe local user'
[ -n "$mw_root" ] || /usr/bin/id "$mw_local_user" >/dev/null 2>&1 || mw_die "local user not found: $mw_local_user"

MW_REQUESTED_FOLDED=()
for mw_name in "${MW_REQUESTED[@]}"; do
  mw_is_safe_name "$mw_name" || mw_die "unsafe mount name: $mw_name"
  mw_folded=$(printf '%s' "$mw_name" | /usr/bin/tr '[:upper:]' '[:lower:]')
  if [ "${#MW_REQUESTED_FOLDED[@]}" -gt 0 ] && mw_array_contains "$mw_folded" "${MW_REQUESTED_FOLDED[@]}"; then
    mw_die "duplicate mount name: $mw_name"
  fi
  MW_REQUESTED_FOLDED[${#MW_REQUESTED_FOLDED[@]}]=$mw_folded
done

mw_dest() {
  case "$1" in /*) ;; *) return 1 ;; esac
  if [ -n "$mw_root" ]; then
    printf '%s%s\n' "$mw_root" "$1"
  else
    case "$1" in
      /var|/var/*) printf '/private%s\n' "$1" ;;
      *) printf '%s\n' "$1" ;;
    esac
  fi
}

mw_check_containment() {
  [ -n "$mw_root" ] || return 0
  case "$1" in "$mw_root"/*) ;; *) return 1 ;; esac
  mw_check_rel=${1#"$mw_root"/}
  mw_check_current=$mw_root
  mw_check_ifs=$IFS
  IFS=/
  set -f
  # shellcheck disable=SC2086 # Intentional slash-delimited component split.
  set -- $mw_check_rel
  set +f
  IFS=$mw_check_ifs
  for mw_check_component in "$@"; do
    [ -n "$mw_check_component" ] || continue
    mw_check_current=$mw_check_current/$mw_check_component
    [ ! -L "$mw_check_current" ] || return 1
  done
}

mw_require_safe_path() {
  [ ! -L "$1" ] || mw_die "refusing symlinked path: $1"
  mw_check_containment "$1" || mw_die "path escapes staging root: $1"
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
mw_mode_is_not_group_world_writable() {
  mw_mode_value=$1
  mw_mode_numeric=$((8#$mw_mode_value))
  [ $((mw_mode_numeric & 18)) -eq 0 ]
}
mw_validate_live_regular() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  [ "$(mw_stat_uid "$1")" -eq 0 ] || return 1
  [ "$(mw_stat_nlink "$1")" -eq 1 ] || return 1
  mw_mode_is_not_group_world_writable "$(mw_stat_mode "$1")" &&
    mw_acl_policy_is_safe "$1" deny-only
}
mw_validate_live_directory() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  [ "$(mw_stat_uid "$1")" -eq 0 ] || return 1
  mw_mode_is_not_group_world_writable "$(mw_stat_mode "$1")" &&
    mw_acl_policy_is_safe "$1" deny-only
}

mw_master=$(mw_dest /etc/auto_master) || mw_die 'cannot resolve auto_master'
mw_smb=$(mw_dest /etc/auto_smb) || mw_die 'cannot resolve auto_smb'
mw_require_safe_path "$mw_master"
mw_require_safe_path "$mw_smb"
[ -n "$mw_root" ] || mw_validate_live_regular "$mw_master" || mw_die 'auto_master must be a root-owned, non-writable regular file'
[ -n "$mw_root" ] || mw_validate_live_regular "$mw_smb" || mw_die 'auto_smb must be a root-owned, non-writable regular file'
mw_acl_policy_is_safe "$mw_master" deny-only || mw_die 'auto_master ACL is unsafe'
mw_acl_policy_is_safe "$mw_smb" deny-only || mw_die 'auto_smb ACL is unsafe'
mw_validate_auto_master "$mw_master" || exit 1
mw_parse_auto_smb "$mw_smb" "$mw_local_user" || exit 1
mw_fstab=
if [ "$MW_AUTO_MASTER_STATIC_PRESENT" -eq 1 ]; then
  mw_fstab=$(mw_dest /etc/fstab) || mw_die 'cannot resolve fstab'
  if [ -e "$mw_fstab" ] || [ -L "$mw_fstab" ]; then
    mw_require_safe_path "$mw_fstab"
    [ -f "$mw_fstab" ] && [ ! -L "$mw_fstab" ] || mw_die 'fstab is not a safe regular file'
    [ -n "$mw_root" ] || mw_validate_live_regular "$mw_fstab" || mw_die 'fstab must be root-owned and non-writable'
    mw_acl_policy_is_safe "$mw_fstab" deny-only || mw_die 'fstab ACL is unsafe'
  fi
fi

MW_SELECTED_NAMES=()
MW_SELECTED_PATHS=()
MW_SELECTED_HOSTS=()
MW_SELECTED_SHARES=()
for mw_name in "${MW_REQUESTED[@]}"; do
  mw_found=-1
  mw_i=0
  while [ "$mw_i" -lt "${#MW_AUTO_NAMES[@]}" ]; do
    [ "${MW_AUTO_NAMES[$mw_i]}" = "$mw_name" ] && mw_found=$mw_i
    mw_i=$((mw_i + 1))
  done
  [ "$mw_found" -ge 0 ] || mw_die "no supported auto_smb mapping for /Users/$mw_local_user/$mw_name"
  MW_SELECTED_NAMES[${#MW_SELECTED_NAMES[@]}]=${MW_AUTO_NAMES[$mw_found]}
  MW_SELECTED_PATHS[${#MW_SELECTED_PATHS[@]}]=${MW_AUTO_PATHS[$mw_found]}
  MW_SELECTED_HOSTS[${#MW_SELECTED_HOSTS[@]}]=${MW_AUTO_HOSTS[$mw_found]}
  MW_SELECTED_SHARES[${#MW_SELECTED_SHARES[@]}]=${MW_AUTO_SHARES[$mw_found]}
done
mw_validate_auto_master_selected_paths "${MW_SELECTED_PATHS[@]}" || exit 1
if [ -n "$mw_fstab" ] && { [ -e "$mw_fstab" ] || [ -L "$mw_fstab" ]; }; then
  mw_validate_fstab_selected_paths "$mw_fstab" "${MW_SELECTED_PATHS[@]}" || exit 1
fi

for mw_source in \
  "$mw_installer_dir/mount_watchdog.sh" \
  "$mw_installer_dir/mount_watchdog_status.sh" \
  "$mw_installer_dir/lib/common.sh" \
  "$mw_installer_dir/lib/runtime.sh" \
  "$mw_installer_dir/lib/autofs.sh" \
  "$mw_installer_dir/config/defaults.conf" \
  "$mw_installer_dir/VERSION" \
  "$mw_installer_dir/packaging/com.antoinemenard.mount-watchdog.plist.in" \
  "$mw_installer_dir/packaging/runtime-wrapper.sh" \
  "$mw_installer_dir/packaging/status-wrapper.sh"; do
  mw_repo_file_is_trusted "$mw_source" || mw_die "required source missing or untrusted: $mw_source"
done
mw_parse_defaults "$mw_installer_dir/config/defaults.conf" || exit 1

# Resolve and component-check every planned path before dry-run can succeed or
# an existing installed artifact can be read.
mw_app=$(mw_dest "$MW_APP") || mw_die 'cannot resolve app dir'
mw_backups=$(mw_dest "$MW_APP/backups") || mw_die 'cannot resolve backups'
mw_plist=$(mw_dest "$MW_PLIST") || mw_die 'cannot resolve plist'
mw_runtime_wrapper=$(mw_dest "$MW_RUNTIME_WRAPPER") || mw_die 'cannot resolve wrapper'
mw_status_wrapper=$(mw_dest "$MW_STATUS_WRAPPER") || mw_die 'cannot resolve status wrapper'
mw_log=$(mw_dest "$MW_LOG") || mw_die 'cannot resolve log path'
mw_installed_manifest_path=$(mw_dest "$MW_APP/install-manifest.tsv") || mw_die 'cannot resolve installed manifest'

MW_OWNED_PATHS=(
  "$MW_APP/watchdog.sh" "$MW_APP/status.sh" "$MW_APP/lib/common.sh"
  "$MW_APP/lib/runtime.sh" "$MW_APP/lib/autofs.sh" "$MW_APP/defaults.conf" "$MW_APP/mounts.conf"
  "$MW_APP/VERSION" "$MW_PLIST" "$MW_RUNTIME_WRAPPER" "$MW_STATUS_WRAPPER"
)
for mw_path in "$mw_app" "$mw_backups" "$mw_plist" \
  "$mw_runtime_wrapper" "$mw_status_wrapper" "$mw_log" "$mw_installed_manifest_path"; do
  mw_require_safe_path "$mw_path"
done
for mw_logical in "${MW_OWNED_PATHS[@]}"; do
  mw_require_safe_path "$(mw_dest "$mw_logical")"
done

mw_library=$(mw_dest /Library) || mw_die 'cannot resolve /Library'
mw_application_support=$(mw_dest '/Library/Application Support') || mw_die 'cannot resolve Application Support'
mw_launchdaemons=$(mw_dest /Library/LaunchDaemons) || mw_die 'cannot resolve LaunchDaemons'
mw_usr=$(mw_dest /usr) || mw_die 'cannot resolve /usr'
mw_usr_local=$(mw_dest /usr/local) || mw_die 'cannot resolve /usr/local'
mw_usr_local_sbin=$(mw_dest /usr/local/sbin) || mw_die 'cannot resolve /usr/local/sbin'
mw_var=$(mw_dest /var) || mw_die 'cannot resolve /var'
mw_var_log=$(mw_dest /var/log) || mw_die 'cannot resolve /var/log'
mw_lib=$(mw_dest "$MW_APP/lib") || mw_die 'cannot resolve installed library dir'

mw_preflight_parent() {
  mw_preflight_dir=$1
  mw_require_safe_path "$mw_preflight_dir"
  if [ -e "$mw_preflight_dir" ] || [ -L "$mw_preflight_dir" ]; then
    [ -d "$mw_preflight_dir" ] && [ ! -L "$mw_preflight_dir" ] || return 1
    [ -n "$mw_root" ] || mw_validate_live_directory "$mw_preflight_dir" || return 1
    mw_acl_policy_is_safe "$mw_preflight_dir" deny-only || return 1
  fi
}
mw_preflight_managed_dir() {
  mw_preflight_dir=$1
  mw_require_safe_path "$mw_preflight_dir"
  if [ -e "$mw_preflight_dir" ] || [ -L "$mw_preflight_dir" ]; then
    [ -d "$mw_preflight_dir" ] && [ ! -L "$mw_preflight_dir" ] || return 1
    [ "$(mw_stat_mode "$mw_preflight_dir")" = 700 ] || return 1
    mw_acl_policy_is_safe "$mw_preflight_dir" none || return 1
    if [ -z "$mw_root" ]; then
      mw_validate_live_directory "$mw_preflight_dir" || return 1
      [ "$(mw_stat_uid "$mw_preflight_dir")" -eq 0 ] && [ "$(mw_stat_gid "$mw_preflight_dir")" -eq 0 ] || return 1
    fi
  fi
}
for mw_parent in "$mw_library" "$mw_application_support" "$mw_launchdaemons" "$mw_usr" "$mw_usr_local" "$mw_usr_local_sbin" "$mw_var" "$mw_var_log"; do
  mw_preflight_parent "$mw_parent" || mw_die "unsafe privileged parent in installation plan: $mw_parent"
done
for mw_managed in "$mw_app" "$mw_backups" "$mw_lib"; do
  mw_preflight_managed_dir "$mw_managed" || mw_die "unsafe managed directory in installation plan: $mw_managed"
done
if [ -e "$mw_log" ] || [ -L "$mw_log" ]; then
  [ -f "$mw_log" ] && [ ! -L "$mw_log" ] || mw_die 'existing log path is not a safe regular file'
  [ -n "$mw_root" ] || mw_validate_live_regular "$mw_log" || mw_die 'existing log path is not root-owned and mode-safe'
  mw_acl_policy_is_safe "$mw_log" none || mw_die 'existing log path has an ACL'
fi

mw_validate_exact_plist() {
  mw_plist_file=$1
  mw_expected_label=$2
  mw_expected_arg0=$3
  mw_expected_arg1=${4:-}
  [ -x /usr/libexec/PlistBuddy ] || return 1
  /usr/bin/plutil -lint "$mw_plist_file" >/dev/null 2>&1 || return 1
  mw_actual_keys=$(/usr/bin/plutil -convert xml1 -o - "$mw_plist_file" 2>/dev/null | \
    /usr/bin/sed -n 's/^[[:space:]]*<key>\([^<]*\)<\/key>[[:space:]]*$/\1/p' | /usr/bin/sort) || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$mw_plist_file" 2>/dev/null)" = "$mw_expected_label" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$mw_plist_file" 2>/dev/null)" = "$mw_expected_arg0" ] || return 1
  if [ -n "$mw_expected_arg1" ]; then
    [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$mw_plist_file" 2>/dev/null)" = "$mw_expected_arg1" ] || return 1
    /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$mw_plist_file" >/dev/null 2>&1 && return 1
  else
    /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$mw_plist_file" >/dev/null 2>&1 && return 1
  fi
  [ "$mw_expected_label" = "$MW_LABEL" ] || return 1
  mw_expected_keys=$(printf '%s\n' Label ProgramArguments RunAtLoad StandardErrorPath StandardOutPath StartInterval WorkingDirectory | /usr/bin/sort)
  [ "$mw_actual_keys" = "$mw_expected_keys" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$mw_plist_file" 2>/dev/null)" = true ] || return 1
  mw_plist_interval=$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$mw_plist_file" 2>/dev/null) || return 1
  mw_is_uint "$mw_plist_interval" && [ "$mw_plist_interval" -ge 10 ] && [ "$mw_plist_interval" -le 3600 ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :WorkingDirectory' "$mw_plist_file" 2>/dev/null)" = / ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :StandardOutPath' "$mw_plist_file" 2>/dev/null)" = "$MW_LOG" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :StandardErrorPath' "$mw_plist_file" 2>/dev/null)" = "$MW_LOG" ] || return 1
  return 0
}

mw_validate_existing_regular() {
  mw_existing_file=$1
  [ -f "$mw_existing_file" ] && [ ! -L "$mw_existing_file" ] || return 1
  mw_require_safe_path "$mw_existing_file"
  [ -n "$mw_root" ] || mw_validate_live_regular "$mw_existing_file" || return 1
  mw_acl_policy_is_safe "$mw_existing_file" none || return 1
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

mw_validate_maintained_manifest() {
  mw_manifest_file=$1
  mw_validate_existing_regular "$mw_manifest_file" || mw_die 'installed manifest is not a safe regular file'
  mw_manifest_format_seen=0
  mw_manifest_version_seen=0
  MW_MANIFEST_PATHS=()
  mw_manifest_tab=$(printf '\tX'); mw_manifest_tab=${mw_manifest_tab%X}
  while IFS="$mw_manifest_tab" read -r mw_kind mw_a mw_b mw_extra; do
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
        mw_array_contains "$mw_a" "${MW_OWNED_PATHS[@]}" || mw_die "installed manifest contains a non-allowlisted path: $mw_a"
        if [ "${#MW_MANIFEST_PATHS[@]}" -gt 0 ] && mw_array_contains "$mw_a" "${MW_MANIFEST_PATHS[@]}"; then
          mw_die "installed manifest contains a duplicate path: $mw_a"
        fi
        MW_MANIFEST_PATHS[${#MW_MANIFEST_PATHS[@]}]=$mw_a
        mw_manifest_physical=$(mw_dest "$mw_a") || mw_die 'cannot resolve installed manifest path'
        if [ -e "$mw_manifest_physical" ] || [ -L "$mw_manifest_physical" ]; then
          mw_validate_existing_regular "$mw_manifest_physical" || mw_die "manifest-owned artifact is unsafe: $mw_a"
          mw_manifest_actual_sha=$(mw_file_sha "$mw_manifest_physical") || mw_die "cannot hash manifest-owned artifact: $mw_a"
          [ "$mw_manifest_actual_sha" = "$mw_b" ] || mw_die "manifest-owned artifact checksum mismatch: $mw_a"
        fi
        ;;
      *) mw_die 'installed manifest contains an unknown record' ;;
    esac
  done < "$mw_manifest_file"
  [ "$mw_manifest_format_seen" -eq 1 ] && [ "$mw_manifest_version_seen" -eq 1 ] || mw_die 'installed manifest metadata is incomplete'
  [ "${#MW_MANIFEST_PATHS[@]}" -eq "${#MW_OWNED_PATHS[@]}" ] || mw_die 'installed manifest path set is incomplete'
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
    mw_check_containment "$mw_lock_path" || return 1
  else
    mw_lock_path=/private/var/db/MountWatchdog.lifecycle.lock
    [ -d /private/var/db ] && [ ! -L /private/var/db ] || return 1
    mw_validate_live_directory /private/var/db || return 1
  fi
  trap '' HUP INT TERM QUIT
  if ! /bin/mkdir -m 700 "$mw_lock_path" 2>/dev/null; then
    trap 'mw_die "installation interrupted"' HUP INT TERM QUIT
    return 1
  fi
  mw_strip_acl_from_new_node "$mw_lock_path" || { /bin/rmdir "$mw_lock_path" 2>/dev/null || true; return 1; }
  mw_lock_held=1
  trap 'mw_release_lifecycle_lock' EXIT
  if [ -z "$mw_root" ]; then
    /usr/sbin/chown root:wheel "$mw_lock_path" || return 1
    [ "$(mw_stat_uid "$mw_lock_path")" -eq 0 ] && [ "$(mw_stat_mode "$mw_lock_path")" = 700 ] || return 1
  fi
  trap 'mw_die "installation interrupted"' HUP INT TERM QUIT
}
mw_acquire_lifecycle_lock || mw_die 'lifecycle operation lock is busy, stale, or unsafe; inspect it before retrying'

mw_canonical_present=0
for mw_logical in "${MW_OWNED_PATHS[@]}"; do
  mw_candidate=$(mw_dest "$mw_logical") || mw_die 'cannot resolve canonical artifact'
  if [ -e "$mw_candidate" ] || [ -L "$mw_candidate" ]; then mw_canonical_present=1; fi
done
mw_source_mode=new
if [ -e "$mw_installed_manifest_path" ] || [ -L "$mw_installed_manifest_path" ]; then
  mw_validate_maintained_manifest "$mw_installed_manifest_path"
  mw_source_mode=maintained
elif [ "$mw_canonical_present" -eq 1 ]; then
  mw_die 'canonical artifacts exist without a maintained manifest; refusing overwrite'
fi

mw_stage_parent=/private/tmp
[ -n "$mw_root" ] || mw_stage_parent=/private/var/tmp
mw_acl_policy_is_safe "$mw_stage_parent" deny-only || mw_die 'temporary staging parent ACL is unsafe'
mw_stage_dir=$(/usr/bin/mktemp -d "$mw_stage_parent/mountwatchdog.install.XXXXXX") || mw_die 'cannot create private staging directory'
mw_strip_acl_from_new_node "$mw_stage_dir" || mw_die 'cannot normalize private staging directory ACL'
mw_cleanup() {
  [ -n "$mw_stage_dir" ] && [ -d "$mw_stage_dir" ] || return 0
  for mw_cleanup_name in watchdog.sh status.sh common.sh runtime.sh autofs.sh defaults.conf VERSION runtime-wrapper.sh status-wrapper.sh mounts.conf launchd.plist install-manifest.tsv mount-watchdog.log; do
    [ ! -e "$mw_stage_dir/$mw_cleanup_name" ] || /bin/rm -f -- "$mw_stage_dir/$mw_cleanup_name"
  done
  /bin/rmdir "$mw_stage_dir" 2>/dev/null || true
}
mw_exit_handler() {
  mw_exit_status=$?
  trap - EXIT
  trap '' HUP INT TERM QUIT
  if [ "${mw_transaction_started:-0}" -eq 1 ]; then
    printf 'MountWatchdog: unexpected installer exit; rolling back transaction\n' >&2
    if ! mw_rollback; then
      printf 'MountWatchdog: rollback incomplete; retain %s\n' "${mw_backup_dir:-unknown}" >&2
    fi
    mw_exit_status=1
  fi
  mw_cleanup
  if ! mw_release_lifecycle_lock; then
    printf 'MountWatchdog: lifecycle lock release failed; inspect %s\n' "${mw_lock_path:-unknown}" >&2
    mw_exit_status=1
  fi
  exit "$mw_exit_status"
}
trap 'mw_exit_handler' EXIT
trap 'mw_die "installation interrupted"' HUP INT TERM QUIT

/bin/cp "$mw_installer_dir/mount_watchdog.sh" "$mw_stage_dir/watchdog.sh" || mw_die 'cannot stage runtime'
/bin/cp "$mw_installer_dir/mount_watchdog_status.sh" "$mw_stage_dir/status.sh" || mw_die 'cannot stage status'
/bin/cp "$mw_installer_dir/lib/common.sh" "$mw_stage_dir/common.sh" || mw_die 'cannot stage common library'
/bin/cp "$mw_installer_dir/lib/runtime.sh" "$mw_stage_dir/runtime.sh" || mw_die 'cannot stage runtime library'
/bin/cp "$mw_installer_dir/lib/autofs.sh" "$mw_stage_dir/autofs.sh" || mw_die 'cannot stage autofs library'
/bin/cp "$mw_installer_dir/config/defaults.conf" "$mw_stage_dir/defaults.conf" || mw_die 'cannot stage defaults'
/bin/cp "$mw_installer_dir/VERSION" "$mw_stage_dir/VERSION" || mw_die 'cannot stage version'
/bin/cp "$mw_installer_dir/packaging/runtime-wrapper.sh" "$mw_stage_dir/runtime-wrapper.sh" || mw_die 'cannot stage wrapper'
/bin/cp "$mw_installer_dir/packaging/status-wrapper.sh" "$mw_stage_dir/status-wrapper.sh" || mw_die 'cannot stage status wrapper'
: > "$mw_stage_dir/mount-watchdog.log" || mw_die 'cannot stage log file'
for mw_staged_leaf in watchdog.sh status.sh common.sh runtime.sh autofs.sh defaults.conf VERSION runtime-wrapper.sh status-wrapper.sh mount-watchdog.log; do
  mw_strip_acl_from_new_node "$mw_stage_dir/$mw_staged_leaf" || mw_die "cannot normalize staged artifact ACL: $mw_staged_leaf"
done

mw_version_count=0
mw_installed_version=
while IFS= read -r mw_version_line || [ -n "$mw_version_line" ]; do
  mw_version_count=$((mw_version_count + 1))
  [ "$mw_version_count" -eq 1 ] || mw_die 'staged VERSION must contain exactly one safe line'
  mw_installed_version=$mw_version_line
done < "$mw_stage_dir/VERSION"
[ "$mw_version_count" -eq 1 ] || mw_die 'staged VERSION must contain exactly one safe line'
case "$mw_installed_version" in
  ''|*[!A-Za-z0-9._-]*) mw_die 'staged VERSION must contain exactly one safe line' ;;
esac

: > "$mw_stage_dir/mounts.conf" || mw_die 'cannot stage config'
mw_i=0
while [ "$mw_i" -lt "${#MW_SELECTED_NAMES[@]}" ]; do
  printf '%s\t%s\t%s\t%s\n' "${MW_SELECTED_NAMES[$mw_i]}" "${MW_SELECTED_PATHS[$mw_i]}" "${MW_SELECTED_HOSTS[$mw_i]}" "${MW_SELECTED_SHARES[$mw_i]}" >> "$mw_stage_dir/mounts.conf" || mw_die 'cannot write config'
  mw_i=$((mw_i + 1))
done
/usr/bin/sed "s/@INTERVAL_SECONDS@/$MW_INTERVAL_SECONDS/g" "$mw_installer_dir/packaging/com.antoinemenard.mount-watchdog.plist.in" > "$mw_stage_dir/launchd.plist" || mw_die 'cannot render plist'
mw_strip_acl_from_new_node "$mw_stage_dir/mounts.conf" || mw_die 'cannot normalize staged config ACL'
mw_strip_acl_from_new_node "$mw_stage_dir/launchd.plist" || mw_die 'cannot normalize staged plist ACL'

for mw_script in watchdog.sh status.sh common.sh runtime.sh autofs.sh runtime-wrapper.sh status-wrapper.sh; do
  /bin/bash -n "$mw_stage_dir/$mw_script" || mw_die "syntax validation failed: $mw_script"
done
mw_parse_config "$mw_stage_dir/mounts.conf" || mw_die 'generated config validation failed'
mw_parse_defaults "$mw_stage_dir/defaults.conf" || mw_die 'generated defaults validation failed'
[ -x /usr/bin/plutil ] || mw_die 'plutil is required'
/usr/bin/plutil -lint "$mw_stage_dir/launchd.plist" >/dev/null || mw_die 'plist validation failed'
mw_validate_exact_plist "$mw_stage_dir/launchd.plist" "$MW_LABEL" /bin/bash "$MW_APP/watchdog.sh" || \
  mw_die 'rendered plist does not match the exact allowlisted schema and program target'
/usr/bin/grep -Fq '<string>com.antoinemenard.mount-watchdog</string>' "$mw_stage_dir/launchd.plist" || mw_die 'wrong rendered label'
/usr/bin/grep -Fq '<string>/Library/Application Support/MountWatchdog/watchdog.sh</string>' "$mw_stage_dir/launchd.plist" || mw_die 'wrong rendered runtime path'

mw_existing_config=$(mw_dest "$MW_APP/mounts.conf") || mw_die 'cannot resolve installed config'
if [ -e "$mw_existing_config" ]; then
  [ -f "$mw_existing_config" ] && [ ! -L "$mw_existing_config" ] || mw_die 'unsafe existing config'
  if [ "$mw_replace_targets" -ne 1 ]; then
    mw_tab=$(printf '\tX'); mw_tab=${mw_tab%X}
    while IFS= read -r mw_line || [ -n "$mw_line" ]; do
      case "$mw_line" in ''|'#'*) continue ;; esac
      mw_old_name=${mw_line%%"$mw_tab"*}
      mw_array_contains "$mw_old_name" "${MW_SELECTED_NAMES[@]}" || mw_die "existing target would be removed; use --replace-targets: $mw_old_name"
    done < "$mw_existing_config"
  fi
fi

mw_prior_plist=$(mw_dest "$MW_PLIST") || mw_die 'cannot resolve prior plist'
mw_prior_plist_present=0
[ -e "$mw_prior_plist" ] && mw_prior_plist_present=1
mw_prior_loaded=0
mw_prior_disabled=0

mw_record_action() {
  [ -n "$mw_root" ] || return 0
  [ -n "${MOUNTWATCHDOG_TEST_ACTION_LOG:-}" ] || return 0
  mw_action_parent=$(CDPATH='' cd -- "$(dirname -- "$MOUNTWATCHDOG_TEST_ACTION_LOG")" 2>/dev/null && pwd -P) || return 1
  mw_action_log="$mw_action_parent/$(basename -- "$MOUNTWATCHDOG_TEST_ACTION_LOG")"
  case "$mw_action_log" in "$mw_root"/*) ;; *) return 1 ;; esac
  mw_check_containment "$mw_action_log" || return 1
  [ ! -L "$mw_action_log" ] || return 1
  if [ -e "$mw_action_log" ]; then
    [ -f "$mw_action_log" ] && [ "$(mw_stat_nlink "$mw_action_log")" -eq 1 ] || return 1
  fi
  printf '%s\n' "$*" >> "$mw_action_log"
}
mw_test_fail() { [ -n "$mw_root" ] && [ "${MOUNTWATCHDOG_TEST_FAIL_AT:-}" = "$1" ]; }
mw_test_unhandled_exit() {
  [ -n "$mw_root" ] && [ "${MOUNTWATCHDOG_TEST_UNHANDLED_EXIT_AT:-}" = "$1" ] || return 0
  return 73
}
mw_test_signal_self() {
  mw_test_signal_kind=${MOUNTWATCHDOG_TEST_SIGNAL_KIND:-TERM}
  case "$mw_test_signal_kind" in TERM|QUIT) ;; *) return 1 ;; esac
  kill -"$mw_test_signal_kind" "$$"
}

mw_test_canonical_actual_loaded=${MOUNTWATCHDOG_TEST_LOADED:-0}
mw_launchctl_job_state() {
  mw_state_label=$1
  mw_state_context=$2
  if [ -n "$mw_root" ]; then
    if [ "${MOUNTWATCHDOG_TEST_LAUNCHCTL_UNKNOWN_AT:-}" = "$mw_state_context" ]; then
      printf 'unknown\n'
      return 0
    fi
    [ "$mw_state_label" = "$MW_LABEL" ] || { printf 'unknown\n'; return 0; }
    mw_state_value=$mw_test_canonical_actual_loaded
    case "$mw_state_value" in
      1) printf 'loaded\n' ;;
      0) printf 'unloaded\n' ;;
      *) printf 'unknown\n' ;;
    esac
    return 0
  fi
  mw_state_output=$(/bin/launchctl print "system/$mw_state_label" 2>&1)
  mw_state_status=$?
  if [ "$mw_state_status" -eq 0 ]; then
    printf 'loaded\n'
    return 0
  fi
  mw_state_not_found=$(printf 'Bad request.\nCould not find service "%s" in domain for system' "$mw_state_label")
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

mw_prior_state=$(mw_launchctl_job_state "$MW_LABEL" canonical-initial)
case "$mw_prior_state" in
  loaded) mw_prior_loaded=1 ;;
  unloaded) mw_prior_loaded=0 ;;
  *) mw_die 'cannot reliably inspect canonical launchd state' ;;
esac
if [ -n "$mw_root" ]; then
  mw_prior_disabled=${MOUNTWATCHDOG_TEST_DISABLED:-0}
else
  mw_disabled_output=$(/bin/launchctl print-disabled system 2>&1) || mw_die 'cannot inspect launchd disabled state'
  mw_disabled_match=$(printf '%s\n' "$mw_disabled_output" | mw_launchctl_label_is_disabled "$MW_LABEL")
  [ "$mw_disabled_match" = 1 ] && mw_prior_disabled=1
fi
mw_current_state=$mw_prior_state
if [ "$mw_prior_plist_present" -eq 1 ]; then
  mw_validate_existing_regular "$mw_prior_plist" || mw_die 'canonical plist is not a safe regular file'
  mw_validate_exact_plist "$mw_prior_plist" "$MW_LABEL" /bin/bash "$MW_APP/watchdog.sh" || \
    mw_die 'canonical plist does not have the exact allowlisted schema and program target'
elif [ "$mw_prior_loaded" -eq 1 ]; then
  mw_die 'canonical job is loaded but its validated on-disk plist is missing'
fi
if [ "$mw_prior_loaded" -eq 1 ]; then
  mw_validate_loaded_job_identity "$MW_LABEL" "$MW_PLIST" /bin/bash 2 /bin/bash "$MW_APP/watchdog.sh" || \
    mw_die 'loaded canonical job does not match the exact on-disk plist path and program arguments'
fi
if [ "$mw_prior_loaded" -eq 1 ]; then mw_plan_loaded=loaded; else mw_plan_loaded=unloaded; fi
if [ "$mw_prior_disabled" -eq 1 ]; then mw_plan_disabled=disabled; else mw_plan_disabled=enabled; fi
if [ "$mw_prior_disabled" -eq 1 ] && [ "$mw_enable" -ne 1 ]; then
  if [ "$mw_prior_loaded" -eq 1 ]; then
    mw_lifecycle_decision='bootstrap canonical job, then restore disabled policy'
  else
    mw_lifecycle_decision='preserve disabled and unloaded policy'
  fi
elif [ "$mw_prior_plist_present" -eq 1 ] && [ "$mw_prior_loaded" -eq 0 ] && [ "$mw_enable" -eq 0 ]; then
  mw_lifecycle_decision='preserve enabled and unloaded policy'
else
  mw_lifecycle_decision='bootstrap canonical job with enabled policy'
fi

printf 'MountWatchdog installation plan\n  source mode: %s\n  prior policy: %s, %s\n  lifecycle decision: %s\n  local user: %s\n  selected mappings: %s\n' \
  "$mw_source_mode" "$mw_plan_loaded" "$mw_plan_disabled" "$mw_lifecycle_decision" "$mw_local_user" "${#MW_SELECTED_NAMES[@]}"
[ "$mw_lock_exempt" -eq 0 ] || printf '  snapshot scope: point-in-time and non-authoritative; the live mutating invocation revalidates while holding the shared root lock\n'
[ "$MW_AUTO_MASTER_DIRECTORY_INCLUDE" -eq 0 ] || printf '  warning: standard +auto_master Directory Service include is not remotely expanded\n'
mw_i=0
while [ "$mw_i" -lt "${#MW_SELECTED_NAMES[@]}" ]; do
  printf '  %s -> %s -> %s/%s\n' "${MW_SELECTED_NAMES[$mw_i]}" "${MW_SELECTED_PATHS[$mw_i]}" "${MW_SELECTED_HOSTS[$mw_i]}" "${MW_SELECTED_SHARES[$mw_i]}"
  mw_i=$((mw_i + 1))
done
if [ "$mw_dry_run" -eq 1 ]; then
  printf 'Dry-run complete: artifacts validated; no installed files or service state changed.\n'
  exit 0
fi

mw_ensure_parent_dir() {
  mw_dir=$1
  mw_mode=$2
  mw_check_containment "$mw_dir" || return 1
  [ ! -L "$mw_dir" ] || return 1
  if [ -e "$mw_dir" ]; then
    [ -d "$mw_dir" ] || return 1
    [ -n "$mw_root" ] || mw_validate_live_directory "$mw_dir" || return 1
    mw_acl_policy_is_safe "$mw_dir" deny-only || return 1
    return 0
  fi
  mw_parent_dir=$(dirname -- "$mw_dir")
  [ -d "$mw_parent_dir" ] && [ ! -L "$mw_parent_dir" ] || return 1
  if [ -n "$mw_root" ]; then
    /bin/mkdir "$mw_dir" && mw_strip_acl_from_new_node "$mw_dir" && /bin/chmod "$mw_mode" "$mw_dir"
  else
    /usr/bin/install -d -o root -g wheel -m "$mw_mode" "$mw_dir" &&
      mw_strip_acl_from_new_node "$mw_dir"
  fi
}

mw_ensure_managed_dir() {
  mw_dir=$1
  mw_mode=$2
  mw_check_containment "$mw_dir" || return 1
  [ ! -L "$mw_dir" ] || return 1
  if [ -e "$mw_dir" ]; then
    [ -d "$mw_dir" ] || return 1
    [ "$(mw_stat_mode "$mw_dir")" = "$mw_mode" ] || return 1
    mw_acl_policy_is_safe "$mw_dir" none || return 1
    if [ -z "$mw_root" ]; then
      mw_validate_live_directory "$mw_dir" || return 1
      [ "$(mw_stat_uid "$mw_dir")" -eq 0 ] || return 1
      [ "$(mw_stat_gid "$mw_dir")" -eq 0 ] || return 1
    fi
    return 0
  fi
  mw_ensure_parent_dir "$mw_dir" "$mw_mode" || return 1
  [ "$(mw_stat_mode "$mw_dir")" = "$mw_mode" ] || return 1
  if [ -z "$mw_root" ]; then
    [ "$(mw_stat_uid "$mw_dir")" -eq 0 ] && [ "$(mw_stat_gid "$mw_dir")" -eq 0 ] || return 1
  fi
}

for mw_parent in "$mw_library" "$mw_application_support" "$mw_launchdaemons" "$mw_usr" "$mw_usr_local" "$mw_usr_local_sbin" "$mw_var" "$mw_var_log"; do
  mw_ensure_parent_dir "$mw_parent" 755 || mw_die "unsafe or unavailable privileged parent: $mw_parent"
done
mw_ensure_managed_dir "$mw_app" 700 || mw_die 'cannot create app dir'
mw_ensure_managed_dir "$mw_backups" 700 || mw_die 'cannot create backups dir'
mw_backup_base=$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$
mw_backup_n=0
while :; do
  mw_backup_dir="$mw_backups/$mw_backup_base-$mw_backup_n"
  if /bin/mkdir -m 700 "$mw_backup_dir" 2>/dev/null; then
    mw_strip_acl_from_new_node "$mw_backup_dir" || mw_die 'cannot normalize protected backup ACL'
    break
  fi
  mw_backup_n=$((mw_backup_n + 1))
  [ "$mw_backup_n" -lt 1000 ] || mw_die 'cannot allocate unique backup dir'
done
mw_backup_manifest="$mw_backup_dir/manifest.tsv"
printf 'format\t3\noperation\tinstall\nprior_loaded\t%s\nprior_disabled\t%s\n' \
  "$mw_prior_loaded" "$mw_prior_disabled" > "$mw_backup_manifest" || mw_die 'cannot create backup manifest'
mw_acl_policy_is_safe "$mw_backup_manifest" none || mw_die 'protected backup manifest inherited an ACL'

mw_make_backup_dir() {
  case "$1" in "$mw_backup_dir"/*) ;; *) return 1 ;; esac
  mw_check_containment "$1" || return 1
  [ ! -L "$1" ] || return 1
  /bin/mkdir -p "$1" && mw_strip_acl_from_new_node "$1" && /bin/chmod 700 "$1"
}

mw_backup_one() {
  mw_logical=$1
  mw_physical=$(mw_dest "$mw_logical") || return 1
  mw_rel=${mw_logical#/}
  mw_copy="$mw_backup_dir/files/$mw_rel"
  if [ -e "$mw_physical" ]; then
    [ -f "$mw_physical" ] && [ ! -L "$mw_physical" ] || return 1
    mw_make_backup_dir "$(dirname -- "$mw_copy")" || return 1
    /bin/cp -p "$mw_physical" "$mw_copy" || return 1
    mw_acl_policy_is_safe "$mw_copy" none || return 1
    mw_sha=$(mw_file_sha "$mw_copy") || return 1
    mw_original_sha=$(mw_file_sha "$mw_physical") || return 1
    [ "$mw_sha" = "$mw_original_sha" ] || return 1
    mw_mode=$(mw_stat_mode "$mw_physical") || return 1
    mw_uid=$(mw_stat_uid "$mw_physical") || return 1
    mw_gid=$(mw_stat_gid "$mw_physical") || return 1
    printf 'file\t%s\t1\t%s\t%s\t%s\t%s\t%s\n' "$mw_logical" "files/$mw_rel" "$mw_mode" "$mw_uid" "$mw_gid" "$mw_sha" >> "$mw_backup_manifest"
  else
    printf 'file\t%s\t0\t-\t-\t-\t-\t-\n' "$mw_logical" >> "$mw_backup_manifest"
  fi
}

MW_INSTALL_PATHS=(
  "$MW_APP/watchdog.sh" "$MW_APP/status.sh" "$MW_APP/lib/common.sh"
  "$MW_APP/lib/runtime.sh" "$MW_APP/lib/autofs.sh" "$MW_APP/defaults.conf" "$MW_APP/mounts.conf"
  "$MW_APP/VERSION" "$MW_APP/install-manifest.tsv" "$MW_PLIST"
  "$MW_RUNTIME_WRAPPER" "$MW_STATUS_WRAPPER" "$MW_LOG"
)
for mw_logical in "${MW_INSTALL_PATHS[@]}"; do mw_backup_one "$mw_logical" || mw_die "backup failed: $mw_logical"; done

mw_installed_manifest="$mw_stage_dir/install-manifest.tsv"
printf 'format\t1\nversion\t%s\n' "$mw_installed_version" > "$mw_installed_manifest" || mw_die 'cannot create installed manifest'
for mw_pair in \
  "watchdog.sh|$MW_APP/watchdog.sh" "status.sh|$MW_APP/status.sh" \
  "common.sh|$MW_APP/lib/common.sh" "runtime.sh|$MW_APP/lib/runtime.sh" \
  "autofs.sh|$MW_APP/lib/autofs.sh" \
  "defaults.conf|$MW_APP/defaults.conf" "mounts.conf|$MW_APP/mounts.conf" \
  "VERSION|$MW_APP/VERSION" "launchd.plist|$MW_PLIST" \
  "runtime-wrapper.sh|$MW_RUNTIME_WRAPPER" "status-wrapper.sh|$MW_STATUS_WRAPPER"; do
  mw_file=${mw_pair%%|*}; mw_logical=${mw_pair#*|}
  mw_sha=$(mw_file_sha "$mw_stage_dir/$mw_file") || mw_die 'cannot hash artifact'
  printf 'file\t%s\t%s\n' "$mw_logical" "$mw_sha" >> "$mw_installed_manifest" || mw_die 'cannot write installed manifest'
done
mw_resulting_manifest_sha=$(mw_file_sha "$mw_installed_manifest") || mw_die 'cannot hash resulting installed manifest'
printf 'resulting_manifest_sha\t%s\n' "$mw_resulting_manifest_sha" >> "$mw_backup_manifest" || \
  mw_die 'cannot bind protected backup to resulting install manifest'

mw_set_current_state() {
  [ "$1" = "$MW_LABEL" ] || return 1
  mw_current_state=$2
}
mw_bootout() {
  mw_bootout_label=$1
  [ "$mw_bootout_label" = "$MW_LABEL" ] || return 1
  mw_record_action "bootout system/$mw_bootout_label" || return 1
  mw_set_current_state "$mw_bootout_label" unknown
  if [ -n "$mw_root" ]; then
    if [ "$mw_bootout_label" = "$MW_LABEL" ] &&
      [ "${MOUNTWATCHDOG_TEST_INSTALL_BOOTOUT_FAIL_BEFORE_EFFECT:-0}" = 1 ]; then
      mw_bootout_state=$(mw_launchctl_job_state "$mw_bootout_label" canonical-after-bootout-failure)
      mw_set_current_state "$mw_bootout_label" "$mw_bootout_state"
      return 1
    fi
    mw_test_canonical_actual_loaded=0
    if [ "$mw_bootout_label" = "$MW_LABEL" ] &&
      [ "${MOUNTWATCHDOG_TEST_INSTALL_BOOTOUT_FAIL_AFTER_EFFECT:-0}" = 1 ]; then
      mw_bootout_state=$(mw_launchctl_job_state "$mw_bootout_label" canonical-after-bootout-failure)
      mw_set_current_state "$mw_bootout_label" "$mw_bootout_state"
      return 1
    fi
    mw_set_current_state "$mw_bootout_label" unloaded
    return 0
  fi
  if /bin/launchctl bootout "system/$mw_bootout_label"; then
    mw_set_current_state "$mw_bootout_label" unloaded
    return 0
  fi
  mw_bootout_state=$(mw_launchctl_job_state "$mw_bootout_label" canonical-after-bootout-failure)
  mw_set_current_state "$mw_bootout_label" "$mw_bootout_state"
  return 1
}
mw_bootstrap() {
  mw_bootstrap_plist=$1
  [ "$mw_bootstrap_plist" = "$mw_plist" ] || return 1
  mw_bootstrap_label=$MW_LABEL
  mw_record_action "bootstrap system $mw_bootstrap_plist" || return 1
  mw_set_current_state "$mw_bootstrap_label" unknown
  if [ -n "$mw_root" ]; then
    if [ "${MOUNTWATCHDOG_TEST_INSTALL_BOOTSTRAP_FAIL_BEFORE_EFFECT:-0}" = 1 ]; then
      mw_bootstrap_state=$(mw_launchctl_job_state "$mw_bootstrap_label" canonical-after-bootstrap-failure)
      mw_set_current_state "$mw_bootstrap_label" "$mw_bootstrap_state"
      return 1
    fi
    mw_test_canonical_actual_loaded=1
    if [ "${MOUNTWATCHDOG_TEST_INSTALL_BOOTSTRAP_FAIL_AFTER_EFFECT:-0}" = 1 ]; then
      mw_bootstrap_state=$(mw_launchctl_job_state "$mw_bootstrap_label" canonical-after-bootstrap-failure)
      mw_set_current_state "$mw_bootstrap_label" "$mw_bootstrap_state"
      return 1
    fi
    mw_set_current_state "$mw_bootstrap_label" loaded
    return 0
  fi
  if /bin/launchctl bootstrap system "$mw_bootstrap_plist"; then
    mw_set_current_state "$mw_bootstrap_label" loaded
    return 0
  fi
  mw_bootstrap_state=$(mw_launchctl_job_state "$mw_bootstrap_label" canonical-after-bootstrap-failure)
  mw_set_current_state "$mw_bootstrap_label" "$mw_bootstrap_state"
  return 1
}
mw_enable_job() {
  mw_record_action "enable system/$MW_LABEL" || return 1
  [ -n "$mw_root" ] && return 0
  /bin/launchctl enable "system/$MW_LABEL"
}
mw_disable_job() {
  mw_record_action "disable system/$MW_LABEL" || return 1
  [ -n "$mw_root" ] && return 0
  /bin/launchctl disable "system/$MW_LABEL"
}
mw_replace_file() {
  mw_source=$1; mw_target=$2; mw_mode=$3
  mw_target_parent=$(dirname -- "$mw_target")
  [ -d "$mw_target_parent" ] && [ ! -L "$mw_target_parent" ] || return 1
  mw_check_containment "$mw_target" || return 1
  [ -n "$mw_root" ] || mw_validate_live_directory "$mw_target_parent" || return 1
  [ ! -L "$mw_target" ] || return 1
  mw_tmp=$(/usr/bin/mktemp "$mw_target.new.XXXXXX") || return 1
  /bin/cp "$mw_source" "$mw_tmp" || { /bin/rm -f "$mw_tmp"; return 1; }
  mw_strip_acl_from_new_node "$mw_tmp" || { /bin/rm -f "$mw_tmp"; return 1; }
  /bin/chmod "$mw_mode" "$mw_tmp" || { /bin/rm -f "$mw_tmp"; return 1; }
  if [ -z "$mw_root" ]; then /usr/sbin/chown root:wheel "$mw_tmp" || { /bin/rm -f "$mw_tmp"; return 1; }; fi
  /bin/mv -f "$mw_tmp" "$mw_target"
}

mw_restore_services() {
  mw_restored_plist=$(mw_dest "$MW_PLIST") || return 1
  mw_current_state=$(mw_launchctl_job_state "$MW_LABEL" canonical-service-restore)
  [ "$mw_current_state" != unknown ] || return 1
  if [ "$mw_prior_loaded" -eq 1 ]; then
    if [ "$mw_current_state" = unloaded ]; then
      [ -f "$mw_restored_plist" ] || return 1
      mw_enable_job || return 1
      mw_bootstrap "$mw_restored_plist" || return 1
    fi
  elif [ "$mw_current_state" = loaded ]; then
    mw_bootout "$MW_LABEL" || return 1
  fi
  if [ "$mw_prior_disabled" -eq 1 ]; then
    mw_disable_job || return 1
  else
    mw_enable_job || return 1
  fi
}

mw_quiesce_services_after_incomplete_rollback() {
  mw_bootout "$MW_LABEL" >/dev/null 2>&1 || true
  mw_disable_job >/dev/null 2>&1 || true
}

mw_record_rollback_result() {
  mw_rollback_result=$1
  if [ -n "$mw_root" ] && [ "$mw_rollback_result" = rolled-back ] &&
    [ "${MOUNTWATCHDOG_TEST_FAIL_ROLLBACK_MARKER:-0}" = 1 ]; then
    return 1
  fi
  printf 'result\t%s\n' "$mw_rollback_result" >> "$mw_backup_manifest"
}

mw_prove_job_unloaded() {
  mw_prove_label=$1
  mw_prove_kind=$2
  mw_prove_state=$(mw_launchctl_job_state "$mw_prove_label" "$mw_prove_kind-rollback")
  mw_set_current_state "$mw_prove_label" "$mw_prove_state"
  if [ "$mw_prove_state" = unloaded ]; then return 0; fi
  mw_bootout "$mw_prove_label" >/dev/null 2>&1 || true
  [ "$mw_current_state" = unloaded ]
}

mw_rollback() {
  trap '' HUP INT TERM QUIT
  mw_transaction_started=0
  mw_record_action rollback-begin || true
  if [ -n "$mw_root" ] && [ "${MOUNTWATCHDOG_TEST_SIGNAL_DURING_ROLLBACK:-0}" = 1 ]; then
    mw_test_signal_self || true
  fi
  mw_ok=1
  mw_prove_job_unloaded "$MW_LABEL" canonical || mw_ok=0
  if [ "$mw_ok" -eq 1 ]; then
    if [ -n "$mw_root" ] && [ "${MOUNTWATCHDOG_TEST_APPEND_EXISTING_LOG_ON_ROLLBACK:-0}" = 1 ] &&
      [ -f "$mw_log" ] && [ ! -L "$mw_log" ]; then
      printf 'concurrent log append retained by rollback\n' >> "$mw_log" || mw_ok=0
    fi
    if [ -n "$mw_root" ] && [ "${MOUNTWATCHDOG_TEST_TAMPER_BACKUP_ON_ROLLBACK:-0}" = 1 ]; then
      mw_test_backup="$mw_backup_dir/files/Library/Application Support/MountWatchdog/mounts.conf"
      [ ! -f "$mw_test_backup" ] || printf '# injected backup tamper\n' >> "$mw_test_backup" || mw_ok=0
    fi
    mw_tab=$(printf '\tX'); mw_tab=${mw_tab%X}
    while IFS="$mw_tab" read -r mw_kind mw_logical mw_existed mw_rel mw_mode mw_uid mw_gid mw_sha; do
      [ "$mw_kind" = file ] || continue
      mw_target=$(mw_dest "$mw_logical") || { mw_ok=0; continue; }
      if [ "$mw_logical" = "$MW_LOG" ]; then
        if [ "$mw_existed" = 0 ] && [ "$mw_log_created_by_transaction" -eq 1 ]; then
          [ ! -L "$mw_target" ] && /bin/rm -f "$mw_target" || mw_ok=0
        fi
        continue
      fi
      if [ "$mw_existed" = 1 ]; then
        mw_backup_source="$mw_backup_dir/$mw_rel"
        [ -f "$mw_backup_source" ] && [ ! -L "$mw_backup_source" ] || { mw_ok=0; continue; }
        mw_backup_actual_sha=$(mw_file_sha "$mw_backup_source") || { mw_ok=0; continue; }
        [ "$mw_backup_actual_sha" = "$mw_sha" ] || { mw_ok=0; continue; }
        mw_replace_file "$mw_backup_source" "$mw_target" "$mw_mode" || { mw_ok=0; continue; }
        [ -n "$mw_root" ] || /usr/sbin/chown "$mw_uid:$mw_gid" "$mw_target" || mw_ok=0
        mw_target_actual_sha=$(mw_file_sha "$mw_target") || { mw_ok=0; continue; }
        [ "$mw_target_actual_sha" = "$mw_sha" ] || mw_ok=0
      else
        [ ! -L "$mw_target" ] && /bin/rm -f "$mw_target" || mw_ok=0
      fi
    done < "$mw_backup_manifest"
  fi
  if [ "$mw_ok" -eq 1 ]; then
    if ! mw_restore_services; then
      mw_ok=0
      mw_quiesce_services_after_incomplete_rollback
    fi
  else
    mw_quiesce_services_after_incomplete_rollback
  fi
  if [ "$mw_ok" -eq 1 ]; then
    if mw_record_rollback_result rolled-back; then return 0; fi
    mw_ok=0
    mw_quiesce_services_after_incomplete_rollback
  fi
  mw_record_rollback_result rollback-incomplete || true
  return 1
}

mw_log_created_by_transaction=0
mw_transaction_started=1
mw_disable_job || mw_die 'cannot temporarily disable canonical job during replacement'
[ "$mw_prior_loaded" -eq 0 ] || mw_bootout "$MW_LABEL" || mw_die 'cannot stop canonical job'
mw_test_fail after_stop && mw_die 'injected staging failure after stop'

mw_ensure_managed_dir "$mw_app/lib" 700 || mw_die 'cannot create installed library dir'
mw_replace_file "$mw_stage_dir/watchdog.sh" "$(mw_dest "$MW_APP/watchdog.sh")" 700 || mw_die 'cannot install runtime'
mw_replace_file "$mw_stage_dir/status.sh" "$(mw_dest "$MW_APP/status.sh")" 700 || mw_die 'cannot install status'
mw_replace_file "$mw_stage_dir/common.sh" "$(mw_dest "$MW_APP/lib/common.sh")" 700 || mw_die 'cannot install common library'
mw_replace_file "$mw_stage_dir/runtime.sh" "$(mw_dest "$MW_APP/lib/runtime.sh")" 700 || mw_die 'cannot install runtime library'
mw_replace_file "$mw_stage_dir/autofs.sh" "$(mw_dest "$MW_APP/lib/autofs.sh")" 700 || mw_die 'cannot install autofs library'
mw_replace_file "$mw_stage_dir/defaults.conf" "$(mw_dest "$MW_APP/defaults.conf")" 600 || mw_die 'cannot install defaults'
mw_replace_file "$mw_stage_dir/mounts.conf" "$(mw_dest "$MW_APP/mounts.conf")" 600 || mw_die 'cannot install config'
mw_replace_file "$mw_stage_dir/VERSION" "$(mw_dest "$MW_APP/VERSION")" 600 || mw_die 'cannot install version'
mw_replace_file "$mw_installed_manifest" "$(mw_dest "$MW_APP/install-manifest.tsv")" 600 || mw_die 'cannot install manifest'
mw_replace_file "$mw_stage_dir/launchd.plist" "$mw_plist" 600 || mw_die 'cannot install plist'
mw_replace_file "$mw_stage_dir/runtime-wrapper.sh" "$mw_runtime_wrapper" 755 || mw_die 'cannot install wrapper'
mw_replace_file "$mw_stage_dir/status-wrapper.sh" "$mw_status_wrapper" 755 || mw_die 'cannot install status wrapper'
if [ -e "$mw_log" ]; then
  [ -f "$mw_log" ] && [ ! -L "$mw_log" ] || mw_die 'existing log path is not a regular file'
  [ -n "$mw_root" ] || mw_validate_live_regular "$mw_log" || mw_die 'existing log must be root-owned and non-writable'
else
  mw_log_created_by_transaction=1
  mw_replace_file "$mw_stage_dir/mount-watchdog.log" "$mw_log" 640 || mw_die 'cannot establish safe log file'
fi

/bin/bash -n "$(mw_dest "$MW_APP/watchdog.sh")" || mw_die 'installed runtime syntax invalid'
/bin/bash -n "$(mw_dest "$MW_APP/lib/autofs.sh")" || mw_die 'installed autofs library syntax invalid'
mw_parse_config "$(mw_dest "$MW_APP/mounts.conf")" || mw_die 'installed config invalid'
/usr/bin/plutil -lint "$mw_plist" >/dev/null || mw_die 'installed plist invalid'
mw_test_fail after_replace && mw_die 'injected staging failure after replace'
mw_test_unhandled_exit after_replace || exit $?

if [ "$mw_prior_disabled" -eq 1 ] && [ "$mw_enable" -ne 1 ]; then
  if [ "$mw_prior_loaded" -eq 1 ]; then
    mw_enable_job || mw_die 'cannot temporarily enable canonical job for registration'
    mw_bootstrap "$mw_plist" || mw_die 'cannot bootstrap canonical job'
    mw_disable_job || mw_die 'cannot restore disabled canonical policy'
    if [ -z "$mw_root" ]; then
      [ "$(mw_launchctl_job_state "$MW_LABEL" canonical-post-bootstrap)" = loaded ] || mw_die 'canonical job registration state is unknown'
    fi
  else
    mw_disable_job || mw_die 'cannot preserve disabled canonical policy'
    mw_record_action "preserve-disabled system/$MW_LABEL" || mw_die 'cannot preserve disabled state'
  fi
elif [ "$mw_prior_plist_present" -eq 1 ] && [ "$mw_prior_loaded" -eq 0 ] && [ "$mw_enable" -eq 0 ]; then
  mw_enable_job || mw_die 'cannot preserve enabled canonical policy'
  mw_record_action "preserve-unloaded system/$MW_LABEL" || mw_die 'cannot preserve unloaded state'
else
  mw_enable_job || mw_die 'cannot enable canonical job'
  mw_bootstrap "$mw_plist" || mw_die 'cannot bootstrap canonical job'
  if [ -z "$mw_root" ]; then
    [ "$(mw_launchctl_job_state "$MW_LABEL" canonical-post-bootstrap)" = loaded ] || mw_die 'canonical job registration state is unknown'
  fi
fi
mw_test_fail after_bootstrap && mw_die 'injected staging failure after bootstrap'

trap '' HUP INT TERM QUIT
if [ -n "$mw_root" ] && [ "${MOUNTWATCHDOG_TEST_SIGNAL_AT_COMMIT:-0}" = 1 ]; then
  mw_test_signal_self || mw_die 'cannot inject staging commit signal'
fi
printf 'result\tcommitted\n' >> "$mw_backup_manifest" || mw_die 'cannot finalize manifest'
mw_transaction_started=0
printf 'MountWatchdog files installed successfully.\n'
printf 'Installed version: %s\n' "$mw_installed_version"
if [ "$mw_prior_disabled" -eq 1 ] && [ "$mw_enable" -ne 1 ]; then
  if [ "$mw_prior_loaded" -eq 1 ]; then
    printf 'The canonical job remains disabled and loaded.\n'
  else
    printf 'The canonical job remains disabled and unloaded.\n'
  fi
elif [ "$mw_prior_plist_present" -eq 1 ] && [ "$mw_prior_loaded" -eq 0 ] && [ "$mw_enable" -eq 0 ]; then
  printf 'The canonical job remains enabled but unloaded.\n'
else
  printf 'The canonical job registered; this does not prove SMB readability.\n'
fi
printf 'Next read-only verification: sudo /usr/local/sbin/mount_watchdog_status.sh --status\n'
printf 'Protected backup: %s\n' "$mw_backup_dir"
printf 'Post-success rollback dry-run: sudo /bin/bash ./uninstall_mount_watchdog.sh --dry-run rollback %s\n' "${mw_backup_dir##*/}"
