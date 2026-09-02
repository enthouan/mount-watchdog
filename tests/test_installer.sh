#!/bin/bash
set -u

TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH='' cd -- "$TEST_DIR/.." && pwd)
INSTALLER=$PROJECT_DIR/install_mount_watchdog.sh
UNINSTALLER=$PROJECT_DIR/uninstall_mount_watchdog.sh
# shellcheck disable=SC1091
. "$TEST_DIR/lib/testlib.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/mountwatchdog-installer.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    "${TMPDIR:-/tmp}"/mountwatchdog-installer.*) /bin/rm -R "$TEST_TMP" ;;
    *) printf 'Refusing unsafe installer-test cleanup: %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT HUP INT TERM

new_root() {
  root=$TEST_TMP/$1
  /bin/mkdir -p "$root/etc"
  printf '# synthetic master\n+auto_master # standard Directory Service include\n/- -static\n/- auto_smb\n' > "$root/etc/auto_master"
  printf '# no active synthetic fstab records\n' > "$root/etc/fstab"
  printf '/Users/testuser/Media -fstype=smbfs,soft ://test:p%%40ss!@192.0.2.10/Media\n/Users/testuser/Studio -fstype=smbfs,soft ://test:secret@192.0.2.10/Workspace\n' > "$root/etc/auto_smb"
  printf '%s\n' "$root"
}

run_install() {
  root=$1
  shift
  output=$TEST_TMP/${root##*/}-install-output
  MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions /bin/bash "$INSTALLER" \
    --staging-root "$root" --local-user testuser "$@" > "$output" 2>&1
}

latest_install_backup_id() {
  backup_root=$1/Library/Application\ Support/MountWatchdog/backups
  /usr/bin/find "$backup_root" -mindepth 2 -maxdepth 2 -name manifest.tsv -type f -print | \
    /usr/bin/sort | /usr/bin/tail -1 | /usr/bin/awk -F/ '{ print $(NF - 1) }'
}

copy_installer_tree() {
  copy_target=$1
  /bin/mkdir -p "$copy_target/lib" "$copy_target/config" "$copy_target/packaging"
  /bin/cp "$INSTALLER" "$copy_target/install_mount_watchdog.sh"
  /bin/cp "$PROJECT_DIR/mount_watchdog.sh" "$copy_target/mount_watchdog.sh"
  /bin/cp "$PROJECT_DIR/mount_watchdog_status.sh" "$copy_target/mount_watchdog_status.sh"
  /bin/cp "$PROJECT_DIR/VERSION" "$copy_target/VERSION"
  /bin/cp "$PROJECT_DIR/lib/common.sh" "$copy_target/lib/common.sh"
  /bin/cp "$PROJECT_DIR/lib/autofs.sh" "$copy_target/lib/autofs.sh"
  /bin/cp "$PROJECT_DIR/lib/runtime.sh" "$copy_target/lib/runtime.sh"
  /bin/cp "$PROJECT_DIR/config/defaults.conf" "$copy_target/config/defaults.conf"
  /bin/cp "$PROJECT_DIR/packaging/com.antoinemenard.mount-watchdog.plist.in" "$copy_target/packaging/com.antoinemenard.mount-watchdog.plist.in"
}

test_dry_run_is_read_only_and_redacted() {
  root=$(new_root dry-run)
  before=$TEST_TMP/dry-before
  after=$TEST_TMP/dry-after
  /usr/bin/find "$root" -print | /usr/bin/sort > "$before"
  run_install "$root" --dry-run Media Studio || return 1
  /usr/bin/find "$root" -print | /usr/bin/sort > "$after"
  /usr/bin/cmp -s "$before" "$after" || return 1
  output=$TEST_TMP/${root##*/}-install-output
  /usr/bin/grep -q 'Dry-run complete' "$output" || return 1
  /usr/bin/grep -q 'source mode: new' "$output" || return 1
  /usr/bin/grep -q 'prior policy: unloaded, enabled' "$output" || return 1
  /usr/bin/grep -q 'lifecycle decision: bootstrap canonical job with enabled policy' "$output" || return 1
  /usr/bin/grep -q 'snapshot scope: point-in-time and non-authoritative' "$output" || return 1
  ! /usr/bin/grep -q 'p%40ss\|test:secret' "$output" || return 1
  assert_file_absent "$root/Library/Application Support/MountWatchdog/mounts.conf" || return 1
  assert_file_absent "$root/actions" || return 1
}

test_smb_fstype_aliases_are_exact_and_redacted() {
  mw_alias_case=0
  for mw_alias_options in \
    '-fstype=smb,soft,noowners,nosuid' \
    '-soft,fstype=smbfs,noowners,nosuid'; do
    mw_alias_case=$((mw_alias_case + 1))
    root=$(new_root "fstype-alias-$mw_alias_case")
    printf '/Users/testuser/Studio %s ://alias-user:AliasSecret@192.0.2.10/Workspace\n' \
      "$mw_alias_options" > "$root/etc/auto_smb"
    run_install "$root" --dry-run Studio || return 1
    output=$TEST_TMP/${root##*/}-install-output
    /usr/bin/grep -Fq '  Studio -> /Users/testuser/Studio -> 192.0.2.10/Workspace' "$output" || return 1
    ! /usr/bin/grep -Fq 'alias-user' "$output" || return 1
    ! /usr/bin/grep -Fq 'AliasSecret' "$output" || return 1
    assert_file_absent "$root/Library" || return 1
    assert_file_absent "$root/actions" || return 1
  done

  mw_alias_case=0
  for mw_bad_options in \
    '-fstype=smb,fstype=smbfs,soft' \
    '-fstype=smb,fstype=smb' \
    '-fstype=smbfs,fstype=smbfs' \
    '-fstype=nfs,soft' \
    '-soft,noowners,nosuid'; do
    mw_alias_case=$((mw_alias_case + 1))
    root=$(new_root "fstype-reject-$mw_alias_case")
    printf '/Users/testuser/Studio %s ://alias-user:AliasSecret@192.0.2.10/Workspace\n' \
      "$mw_bad_options" > "$root/etc/auto_smb"
    if run_install "$root" --dry-run Studio; then
      return 1
    fi
    output=$TEST_TMP/${root##*/}-install-output
    /usr/bin/grep -Fq 'unsupported SMB options at line 1' "$output" || return 1
    ! /usr/bin/grep -Fq 'alias-user' "$output" || return 1
    ! /usr/bin/grep -Fq 'AliasSecret' "$output" || return 1
    assert_file_absent "$root/Library" || return 1
    assert_file_absent "$root/actions" || return 1
  done
}

test_privileged_entrypoints_reject_untrusted_sources_before_sourcing() {
  unsafe_installer=$TEST_TMP/unsafe-installer-source
  /bin/mkdir -p "$unsafe_installer/lib"
  /bin/cp "$INSTALLER" "$unsafe_installer/install_mount_watchdog.sh"
  /bin/cp "$PROJECT_DIR/lib/common.sh" "$unsafe_installer/lib/common.sh"
  /bin/cp "$PROJECT_DIR/lib/autofs.sh" "$unsafe_installer/lib/autofs.sh"
  /bin/chmod 666 "$unsafe_installer/lib/common.sh"
  if /bin/bash "$unsafe_installer/install_mount_watchdog.sh" --help > "$unsafe_installer/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'common library is missing or untrusted' "$unsafe_installer/output" || return 1

  unsafe_uninstaller=$TEST_TMP/unsafe-uninstaller-source
  /bin/mkdir -p "$unsafe_uninstaller/lib"
  /bin/cp "$UNINSTALLER" "$unsafe_uninstaller/uninstall_mount_watchdog.sh"
  /bin/cp "$PROJECT_DIR/lib/common.sh" "$unsafe_uninstaller/lib/common.sh"
  /bin/chmod 666 "$unsafe_uninstaller/lib/common.sh"
  if /bin/bash "$unsafe_uninstaller/uninstall_mount_watchdog.sh" --help > "$unsafe_uninstaller/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'common library is missing or untrusted' "$unsafe_uninstaller/output" || return 1

  writable_parent=$TEST_TMP/writable-source-parent
  writable_installer=$writable_parent/installer
  /bin/mkdir -p "$writable_installer/lib"
  /bin/cp "$INSTALLER" "$writable_installer/install_mount_watchdog.sh"
  /bin/cp "$PROJECT_DIR/lib/common.sh" "$writable_installer/lib/common.sh"
  /bin/cp "$PROJECT_DIR/lib/autofs.sh" "$writable_installer/lib/autofs.sh"
  /bin/chmod 777 "$writable_parent"
  if /bin/bash "$writable_installer/install_mount_watchdog.sh" --help > "$writable_parent/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'installer directory ancestor ownership or mode is unsafe' "$writable_parent/output" || return 1
}

test_acl_policy_rejects_allow_entries_and_accepts_deny_only_sources() {
  acl_installer=$TEST_TMP/acl-installer-source
  copy_installer_tree "$acl_installer" || return 1
  /bin/cp "$UNINSTALLER" "$acl_installer/uninstall_mount_watchdog.sh" || return 1

  /bin/chmod +a "everyone allow write" "$acl_installer/lib/common.sh" || return 1
  if /bin/bash "$acl_installer/install_mount_watchdog.sh" --help > "$TEST_TMP/acl-installer-allow-output" 2>&1; then
    /bin/chmod -N "$acl_installer/lib/common.sh" 2>/dev/null || true
    return 1
  fi
  /bin/chmod -N "$acl_installer/lib/common.sh" || return 1
  /usr/bin/grep -q 'common library is missing or untrusted' "$TEST_TMP/acl-installer-allow-output" || return 1

  /bin/chmod +a "everyone allow write" "$acl_installer/uninstall_mount_watchdog.sh" || return 1
  if /bin/bash "$acl_installer/uninstall_mount_watchdog.sh" --help > "$TEST_TMP/acl-uninstaller-allow-output" 2>&1; then
    /bin/chmod -N "$acl_installer/uninstall_mount_watchdog.sh" 2>/dev/null || true
    return 1
  fi
  /bin/chmod -N "$acl_installer/uninstall_mount_watchdog.sh" || return 1
  /usr/bin/grep -q 'uninstaller source ownership or mode is unsafe' "$TEST_TMP/acl-uninstaller-allow-output" || return 1

  /bin/chmod +a "everyone deny delete" "$acl_installer" || return 1
  /bin/bash "$acl_installer/install_mount_watchdog.sh" --help > "$TEST_TMP/acl-installer-deny-output" 2>&1 || {
    /bin/chmod -N "$acl_installer" 2>/dev/null || true
    return 1
  }
  /bin/bash "$acl_installer/uninstall_mount_watchdog.sh" --help > "$TEST_TMP/acl-uninstaller-deny-output" 2>&1 || {
    /bin/chmod -N "$acl_installer" 2>/dev/null || true
    return 1
  }
  /bin/chmod -N "$acl_installer" || return 1

  protected_root=$(new_root acl-protected-inputs)
  /bin/chmod +a "everyone deny delete" "$protected_root/etc/auto_master" || return 1
  /bin/chmod +a "everyone deny delete" "$protected_root/etc/auto_smb" || return 1
  run_install "$protected_root" --dry-run Media || {
    /bin/chmod -N "$protected_root/etc/auto_master" "$protected_root/etc/auto_smb" 2>/dev/null || true
    return 1
  }
  /bin/chmod -N "$protected_root/etc/auto_master" "$protected_root/etc/auto_smb" || return 1

  malformed_root=$(new_root acl-noncanonical-input)
  /bin/chmod +ai "everyone deny read" "$malformed_root/etc/auto_master" || return 1
  /bin/chmod +a# 1 "everyone deny write" "$malformed_root/etc/auto_master" || return 1
  if run_install "$malformed_root" --dry-run Media; then
    /bin/chmod -N "$malformed_root/etc/auto_master" 2>/dev/null || true
    return 1
  fi
  /bin/chmod -N "$malformed_root/etc/auto_master" || return 1
  output=$TEST_TMP/${malformed_root##*/}-install-output
  /usr/bin/grep -q 'auto_master ACL is unsafe' "$output" || return 1
}

test_managed_nodes_are_acl_free_and_existing_acl_fails_closed() {
  root=$(new_root acl-managed-nodes)
  run_install "$root" Media || return 1
  backup_id=$(latest_install_backup_id "$root")
  [ -n "$backup_id" ] || return 1
  for acl_path in \
    "$root/Library/Application Support/MountWatchdog" \
    "$root/Library/Application Support/MountWatchdog/lib" \
    "$root/Library/Application Support/MountWatchdog/backups" \
    "$root/Library/Application Support/MountWatchdog/install-manifest.tsv" \
    "$root/Library/Application Support/MountWatchdog/watchdog.sh" \
    "$root/Library/Application Support/MountWatchdog/backups/$backup_id" \
    "$root/Library/Application Support/MountWatchdog/backups/$backup_id/manifest.tsv"; do
    /bin/ls -lde "$acl_path" 2>/dev/null | /usr/bin/awk 'NR > 1 { exit 1 }' || return 1
  done

  installed_manifest="$root/Library/Application Support/MountWatchdog/install-manifest.tsv"
  /bin/chmod +a "everyone allow write" "$installed_manifest" || return 1
  : > "$root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$root" --dry-run remove > "$root/acl-output" 2>&1; then
    /bin/chmod -N "$installed_manifest" 2>/dev/null || true
    return 1
  fi
  /bin/chmod -N "$installed_manifest" || return 1
  /usr/bin/grep -q 'installed manifest has an ACL\|installed manifest is not safe' "$root/acl-output" || return 1
  [ ! -s "$root/actions" ] || return 1
  assert_file_absent "$root/.mountwatchdog-lifecycle.lock" || return 1
}

test_staged_version_and_plist_schema_are_strict() {
  plist_repo=$TEST_TMP/malicious-template-repo
  copy_installer_tree "$plist_repo" || return 1
  /bin/cp "$TEST_DIR/fixtures/malicious-canonical.plist.in" "$plist_repo/packaging/com.antoinemenard.mount-watchdog.plist.in"
  plist_root=$(new_root malicious-template-root)
  if /bin/bash "$plist_repo/install_mount_watchdog.sh" --staging-root "$plist_root" \
    --local-user testuser --dry-run Media > "$plist_root/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'rendered plist does not match the exact allowlisted schema and program target' "$plist_root/output" || return 1
  assert_file_absent "$plist_root/Library" || return 1

  version_repo=$TEST_TMP/malformed-version-repo
  copy_installer_tree "$version_repo" || return 1
  printf '0.1.0\nsecond-line\n' > "$version_repo/VERSION"
  version_root=$(new_root multiline-version-root)
  if /bin/bash "$version_repo/install_mount_watchdog.sh" --staging-root "$version_root" \
    --local-user testuser --dry-run Media > "$version_root/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'staged VERSION must contain exactly one safe line' "$version_root/output" || return 1
  assert_file_absent "$version_root/Library" || return 1

  : > "$version_repo/VERSION"
  empty_root=$(new_root empty-version-root)
  if /bin/bash "$version_repo/install_mount_watchdog.sh" --staging-root "$empty_root" \
    --local-user testuser --dry-run Media > "$empty_root/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'staged VERSION must contain exactly one safe line' "$empty_root/output" || return 1
  assert_file_absent "$empty_root/Library" || return 1
}

test_install_preserves_parent_modes_and_strips_credentials() {
  root=$(new_root install)
  /bin/mkdir -p "$root/Library/LaunchDaemons" "$root/usr/local/sbin"
  /bin/chmod 755 "$root/Library/LaunchDaemons"
  /bin/chmod 775 "$root/usr/local/sbin"
  printf 'homebrew-owned sentinel\n' > "$root/usr/local/sbin/homebrew-owned"
  run_install "$root" Media Studio || { /bin/cat "$TEST_TMP/${root##*/}-install-output" >&2; return 1; }
  config="$root/Library/Application Support/MountWatchdog/mounts.conf"
  manifest="$root/Library/Application Support/MountWatchdog/install-manifest.tsv"
  [ -f "$config" ] || return 1
  [ -f "$manifest" ] || return 1
  ! /usr/bin/grep -Fq '/usr/local' "$manifest" || return 1
  expected=$(printf 'Media\t/Users/testuser/Media\t192.0.2.10\tMedia\nStudio\t/Users/testuser/Studio\t192.0.2.10\tWorkspace')
  actual=$(/bin/cat "$config")
  assert_eq "$expected" "$actual" 'installed config preserves local/remote names' || return 1
  ! /usr/bin/grep -R -q 'p%40ss\|test:secret' "$root/Library" || return 1
  mode_launch=$(/usr/bin/stat -f '%Lp' "$root/Library/LaunchDaemons")
  mode_sbin=$(/usr/bin/stat -f '%Lp' "$root/usr/local/sbin")
  assert_eq 755 "$mode_launch" 'LaunchDaemons parent mode changed' || return 1
  assert_eq 775 "$mode_sbin" 'Homebrew sbin parent mode changed' || return 1
  assert_eq 'homebrew-owned sentinel' "$(/bin/cat "$root/usr/local/sbin/homebrew-owned")" 'Homebrew-owned content changed' || return 1
  homebrew_entry_count=$(/usr/bin/find "$root/usr/local/sbin" -mindepth 1 -maxdepth 1 | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  assert_eq 1 "$homebrew_entry_count" 'Homebrew-owned directory contents changed' || return 1
  /usr/bin/grep -q 'bootstrap system' "$root/actions" || return 1
  temporary_disable_line=$(/usr/bin/grep -n '^disable system/com.antoinemenard.mount-watchdog$' "$root/actions" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)
  enable_line=$(/usr/bin/grep -n '^enable system/com.antoinemenard.mount-watchdog$' "$root/actions" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)
  bootstrap_line=$(/usr/bin/grep -n '^bootstrap system ' "$root/actions" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)
  [ "$temporary_disable_line" -lt "$enable_line" ] && [ "$enable_line" -lt "$bootstrap_line" ] || return 1
  [ -f "$root/var/log/mount-watchdog.log" ] || return 1
  version=$(/usr/bin/tr -d '\r\n' < "$PROJECT_DIR/VERSION")
  /usr/bin/grep -q "Installed version: $version" "$TEST_TMP/${root##*/}-install-output" || return 1
  /usr/bin/grep -Fq "Next read-only verification: sudo /bin/bash '/Library/Application Support/MountWatchdog/status.sh' --status" "$TEST_TMP/${root##*/}-install-output" || return 1

  backup_count_before=$(/usr/bin/find "$root/Library/Application Support/MountWatchdog/backups" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  run_install "$root" Media Studio || return 1
  /usr/bin/grep -q 'source mode: maintained' "$TEST_TMP/${root##*/}-install-output" || return 1
  /usr/bin/grep -q 'lifecycle decision: preserve enabled and unloaded policy' "$TEST_TMP/${root##*/}-install-output" || return 1
  backup_count_after=$(/usr/bin/find "$root/Library/Application Support/MountWatchdog/backups" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  [ "$backup_count_after" -eq $((backup_count_before + 1)) ] || return 1
  [ "$(/usr/bin/find "$root/Library/Application Support/MountWatchdog/backups" -mindepth 2 -maxdepth 2 -name manifest.tsv -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')" -eq "$backup_count_after" ] || return 1
}

test_failed_replace_rolls_back_files_and_modes() {
  root=$(new_root rollback)
  run_install "$root" Media || return 1
  config="$root/Library/Application Support/MountWatchdog/mounts.conf"
  plist="$root/Library/LaunchDaemons/com.antoinemenard.mount-watchdog.plist"
  config_before=$(/usr/bin/shasum -a 256 "$config" | /usr/bin/awk '{print $1}')
  plist_before=$(/usr/bin/shasum -a 256 "$plist" | /usr/bin/awk '{print $1}')
  /bin/chmod 640 "$config"
  printf '/Users/testuser/Media -fstype=smbfs,soft ://test:new@198.51.100.20/Media\n/Users/testuser/Studio -fstype=smbfs,soft ://test:secret@192.0.2.10/Workspace\n' > "$root/etc/auto_smb"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_FAIL_AT=after_replace \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions /bin/bash "$INSTALLER" \
      --staging-root "$root" --local-user testuser Media > "$root/rollback-output" 2>&1; then
    return 1
  fi
  [ "$config_before" = "$(/usr/bin/shasum -a 256 "$config" | /usr/bin/awk '{print $1}')" ] || return 1
  [ "$plist_before" = "$(/usr/bin/shasum -a 256 "$plist" | /usr/bin/awk '{print $1}')" ] || return 1
  [ "$(/usr/bin/stat -f '%Lp' "$config")" = 640 ] || return 1
  /usr/bin/grep -q 'rollback-begin' "$root/actions" || return 1
  /usr/bin/grep -R -q $'result\trolled-back' "$root/Library/Application Support/MountWatchdog/backups" || return 1
}

test_installer_transaction_signals_are_nonreentrant() {
  rollback_root=$(new_root rollback-signal)
  run_install "$rollback_root" Media || return 1
  config="$rollback_root/Library/Application Support/MountWatchdog/mounts.conf"
  config_before=$(/usr/bin/shasum -a 256 "$config" | /usr/bin/awk '{print $1}')
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_FAIL_AT=after_replace \
    MOUNTWATCHDOG_TEST_SIGNAL_DURING_ROLLBACK=1 \
    MOUNTWATCHDOG_TEST_SIGNAL_KIND=QUIT \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$rollback_root/actions /bin/bash "$INSTALLER" \
      --staging-root "$rollback_root" --local-user testuser Media > "$rollback_root/output" 2>&1; then
    return 1
  fi
  [ "$config_before" = "$(/usr/bin/shasum -a 256 "$config" | /usr/bin/awk '{print $1}')" ] || return 1
  /usr/bin/grep -R -q $'result\trolled-back' "$rollback_root/Library/Application Support/MountWatchdog/backups" || return 1
  ! /usr/bin/grep -R -q $'result\trollback-incomplete' "$rollback_root/Library/Application Support/MountWatchdog/backups" || return 1

  commit_root=$(new_root commit-signal)
  MOUNTWATCHDOG_TEST_SIGNAL_AT_COMMIT=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$commit_root/actions \
    /bin/bash "$INSTALLER" --staging-root "$commit_root" --local-user testuser Media > "$commit_root/output" 2>&1 || return 1
  /usr/bin/grep -R -q $'result\tcommitted' "$commit_root/Library/Application Support/MountWatchdog/backups" || return 1
  /usr/bin/grep -q 'MountWatchdog files installed successfully' "$commit_root/output" || return 1
  /bin/bash "$INSTALLER" --help 2>&1 | /usr/bin/grep -q 'SIGKILL cannot' || return 1
  /bin/bash "$UNINSTALLER" --help 2>&1 | /usr/bin/grep -q 'SIGKILL cannot' || return 1
}

test_installer_bootout_failures_track_actual_loaded_state() {
  before_root=$(new_root install-bootout-before-effect)
  run_install "$before_root" Media || return 1
  : > "$before_root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=0 \
    MOUNTWATCHDOG_TEST_INSTALL_BOOTOUT_FAIL_BEFORE_EFFECT=1 \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$before_root/actions /bin/bash "$INSTALLER" \
      --staging-root "$before_root" --local-user testuser Media > "$before_root/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'rollback incomplete' "$before_root/output" || return 1
  /usr/bin/grep -R -q $'result\trollback-incomplete' "$before_root/Library/Application Support/MountWatchdog/backups" || return 1
  /usr/bin/grep -q '^disable system/com.antoinemenard.mount-watchdog$' "$before_root/actions" || return 1
  ! /usr/bin/grep -q '^bootstrap ' "$before_root/actions" || return 1
  ! /usr/bin/grep -q '^enable ' "$before_root/actions" || return 1

  after_root=$(new_root install-bootout-after-effect)
  run_install "$after_root" Media || return 1
  : > "$after_root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=0 \
    MOUNTWATCHDOG_TEST_INSTALL_BOOTOUT_FAIL_AFTER_EFFECT=1 \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$after_root/actions /bin/bash "$INSTALLER" \
      --staging-root "$after_root" --local-user testuser Media > "$after_root/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -R -q $'result\trolled-back' "$after_root/Library/Application Support/MountWatchdog/backups" || return 1
  /usr/bin/grep -q '^bootstrap system ' "$after_root/actions" || return 1
  /usr/bin/grep -q '^enable system/com.antoinemenard.mount-watchdog$' "$after_root/actions" || return 1
}

test_staging_action_logs_reject_external_hardlinks() {
  install_root=$(new_root install-action-hardlink)
  install_sentinel=$TEST_TMP/install-action-sentinel
  printf 'outside installer sentinel\n' > "$install_sentinel"
  /bin/ln "$install_sentinel" "$install_root/actions" || return 1
  install_sha=$(/usr/bin/shasum -a 256 "$install_sentinel" | /usr/bin/awk '{print $1}')
  if MOUNTWATCHDOG_TEST_ACTION_LOG=$install_root/actions /bin/bash "$INSTALLER" \
    --staging-root "$install_root" --local-user testuser Media > "$install_root/output" 2>&1; then
    return 1
  fi
  [ "$install_sha" = "$(/usr/bin/shasum -a 256 "$install_sentinel" | /usr/bin/awk '{print $1}')" ] || return 1

  uninstall_root=$(new_root uninstall-action-hardlink)
  run_install "$uninstall_root" Media || return 1
  /bin/rm -f "$uninstall_root/actions"
  uninstall_sentinel=$TEST_TMP/uninstall-action-sentinel
  printf 'outside uninstaller sentinel\n' > "$uninstall_sentinel"
  /bin/ln "$uninstall_sentinel" "$uninstall_root/actions" || return 1
  uninstall_sha=$(/usr/bin/shasum -a 256 "$uninstall_sentinel" | /usr/bin/awk '{print $1}')
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$uninstall_root/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$uninstall_root" stop > "$uninstall_root/output" 2>&1; then
    return 1
  fi
  [ "$uninstall_sha" = "$(/usr/bin/shasum -a 256 "$uninstall_sentinel" | /usr/bin/awk '{print $1}')" ] || return 1
}

test_uninstaller_transaction_signals_are_nonreentrant() {
  lifecycle_root=$(new_root uninstall-lifecycle-signal)
  run_install "$lifecycle_root" Media || return 1
  : > "$lifecycle_root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=0 \
    MOUNTWATCHDOG_TEST_UNINSTALL_FAIL_AT=after_disable \
    MOUNTWATCHDOG_TEST_SIGNAL_DURING_ROLLBACK=1 \
    MOUNTWATCHDOG_TEST_SIGNAL_KIND=QUIT \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$lifecycle_root/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$lifecycle_root" disable > "$lifecycle_root/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'prior service state restored' "$lifecycle_root/output" || return 1
  /usr/bin/grep -q '^enable system/com.antoinemenard.mount-watchdog$' "$lifecycle_root/actions" || return 1

  rollback_root=$(new_root uninstall-remove-rollback-signal)
  run_install "$rollback_root" Media || return 1
  runtime="$rollback_root/Library/Application Support/MountWatchdog/watchdog.sh"
  runtime_sha=$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')
  : > "$rollback_root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=0 \
    MOUNTWATCHDOG_TEST_UNINSTALL_FAIL_AT=after_remove \
    MOUNTWATCHDOG_TEST_SIGNAL_DURING_ROLLBACK=1 \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$rollback_root/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$rollback_root" remove > "$rollback_root/output" 2>&1; then
    return 1
  fi
  [ "$runtime_sha" = "$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')" ] || return 1
  /usr/bin/grep -R -q $'result\trolled-back' "$rollback_root/Library/Application Support/MountWatchdog/backups" || return 1
  ! /usr/bin/grep -R -q $'result\trollback-incomplete' "$rollback_root/Library/Application Support/MountWatchdog/backups" || return 1

  commit_root=$(new_root uninstall-remove-commit-signal)
  run_install "$commit_root" Media || return 1
  : > "$commit_root/actions"
  MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=0 \
    MOUNTWATCHDOG_TEST_SIGNAL_AT_COMMIT=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$commit_root/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$commit_root" remove > "$commit_root/output" 2>&1 || return 1
  /usr/bin/grep -R -q $'result\tcommitted' "$commit_root/Library/Application Support/MountWatchdog/backups" || return 1
  /usr/bin/grep -q 'MountWatchdog owned program artifacts removed' "$commit_root/output" || return 1
}

test_disabled_and_unloaded_states_are_preserved() {
  missing=$(new_root canonical-loaded-missing)
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$missing/actions \
    /bin/bash "$INSTALLER" --staging-root "$missing" --local-user testuser --dry-run Media > "$missing/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'loaded but its validated on-disk plist is missing' "$missing/output" || return 1
  assert_file_absent "$missing/actions" || return 1

  root=$(new_root disabled)
  MOUNTWATCHDOG_TEST_DISABLED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions \
    /bin/bash "$INSTALLER" --staging-root "$root" --local-user testuser Media > "$root/output" 2>&1 || return 1
  /usr/bin/grep -q 'preserve-disabled' "$root/actions" || return 1
  ! /usr/bin/grep -q '^bootstrap ' "$root/actions" || return 1

  : > "$root/actions"
  MOUNTWATCHDOG_TEST_DISABLED=0 MOUNTWATCHDOG_TEST_LOADED=0 MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions \
    /bin/bash "$INSTALLER" --staging-root "$root" --local-user testuser Media > "$root/output-2" 2>&1 || return 1
  /usr/bin/grep -q 'preserve-unloaded' "$root/actions" || return 1
  ! /usr/bin/grep -q '^bootstrap ' "$root/actions" || return 1

  root_loaded=$(new_root disabled-loaded)
  run_install "$root_loaded" Media || return 1
  : > "$root_loaded/actions"
  MOUNTWATCHDOG_TEST_DISABLED=1 MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$root_loaded/actions \
    /bin/bash "$INSTALLER" --staging-root "$root_loaded" --local-user testuser Media > "$root_loaded/output" 2>&1 || return 1
  enable_line=$(/usr/bin/grep -n '^enable system/com.antoinemenard.mount-watchdog$' "$root_loaded/actions" | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)
  bootstrap_line=$(/usr/bin/grep -n '^bootstrap system ' "$root_loaded/actions" | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)
  disable_line=$(/usr/bin/grep -n '^disable system/com.antoinemenard.mount-watchdog$' "$root_loaded/actions" | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)
  [ -n "$enable_line" ] && [ "$enable_line" -lt "$bootstrap_line" ] && [ "$bootstrap_line" -lt "$disable_line" ] || return 1
  /usr/bin/grep -q 'remains disabled and loaded' "$root_loaded/output" || return 1

  : > "$root_loaded/actions"
  if MOUNTWATCHDOG_TEST_DISABLED=1 MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_FAIL_AT=after_replace \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$root_loaded/actions /bin/bash "$INSTALLER" \
      --staging-root "$root_loaded" --local-user testuser Media > "$root_loaded/rollback-output" 2>&1; then
    return 1
  fi
  enable_line=$(/usr/bin/grep -n '^enable system/com.antoinemenard.mount-watchdog$' "$root_loaded/actions" | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)
  bootstrap_line=$(/usr/bin/grep -n '^bootstrap system ' "$root_loaded/actions" | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)
  disable_line=$(/usr/bin/grep -n '^disable system/com.antoinemenard.mount-watchdog$' "$root_loaded/actions" | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)
  [ -n "$enable_line" ] && [ "$enable_line" -lt "$bootstrap_line" ] && [ "$bootstrap_line" -lt "$disable_line" ] || return 1
  /usr/bin/grep -R -q $'result\trolled-back' "$root_loaded/Library/Application Support/MountWatchdog/backups" || return 1
}

test_strict_map_and_static_fstab_validation_is_redacted_and_nonmutating() {
  root=$(new_root malformed)
  printf '/Users/testuser/Media -fstype=nfs ://test:do-not-print@192.0.2.10/Media\n' > "$root/etc/auto_smb"
  if run_install "$root" --dry-run Media; then return 1; fi
  ! /usr/bin/grep -q 'do-not-print' "$TEST_TMP/${root##*/}-install-output" || return 1
  assert_file_absent "$root/Library" || return 1

  root2=$(new_root fstab-overlap)
  printf 'private-server:/private-export /Users/testuser/Media nfs rw 0 0\n' > "$root2/etc/fstab"
  if run_install "$root2" --dry-run Media; then return 1; fi
  /usr/bin/grep -q 'conflicting -static fstab target at line 1' "$TEST_TMP/${root2##*/}-install-output" || return 1
  ! /usr/bin/grep -q 'private-server\|private-export' "$TEST_TMP/${root2##*/}-install-output" || return 1
  assert_file_absent "$root2/Library" || return 1

  root3=$(new_root fstab-disjoint)
  printf 'private-server:/private-export /Users/testuser/Developer/mnt/docker nfs rw,resvport 0 0\n' > "$root3/etc/fstab"
  run_install "$root3" --dry-run Media || return 1
  /usr/bin/grep -q 'Dry-run complete' "$TEST_TMP/${root3##*/}-install-output" || return 1
  ! /usr/bin/grep -q 'private-server\|private-export' "$TEST_TMP/${root3##*/}-install-output" || return 1
  assert_file_absent "$root3/Library" || return 1

  root4=$(new_root fstab-special-records)
  {
    printf 'UUID=00000000-0000-0000-0000-000000000000 none apfs rw,noauto 0 0\n'
    printf 'private-server:/private-export /Users/testuser/Media nfs rw,net 0 0\n'
    printf 'ignored-source /Users/testuser/Media nfs xx 0 0\n'
  } > "$root4/etc/fstab"
  run_install "$root4" --dry-run Media || return 1
  /usr/bin/grep -q 'Dry-run complete' "$TEST_TMP/${root4##*/}-install-output" || return 1
  ! /usr/bin/grep -q 'private-server\|private-export\|ignored-source' "$TEST_TMP/${root4##*/}-install-output" || return 1
  assert_file_absent "$root4/Library" || return 1

  root5=$(new_root fstab-malformed)
  printf 'private-server:/MalformedFstabSecret /Users/testuser/Developer/mnt/docker nfs defaults 0 0\n' > "$root5/etc/fstab"
  if run_install "$root5" --dry-run Media; then return 1; fi
  /usr/bin/grep -q 'ambiguous fstab mount type at line 1' "$TEST_TMP/${root5##*/}-install-output" || return 1
  ! /usr/bin/grep -q 'private-server\|MalformedFstabSecret' "$TEST_TMP/${root5##*/}-install-output" || return 1
  assert_file_absent "$root5/Library" || return 1
}

test_explicit_master_targets_cannot_overlap_selected_paths() {
  for overlap_case in exact ancestor descendant; do
    overlap_root=$(new_root "master-overlap-$overlap_case")
    case "$overlap_case" in
      exact) overlap_target=/Users/testuser/Media ;;
      ancestor) overlap_target=/Users/testuser ;;
      descendant) overlap_target=/Users/testuser/Media/subdir ;;
    esac
    printf '%s\n' "$overlap_target auto_conflict" >> "$overlap_root/etc/auto_master"
    if run_install "$overlap_root" --dry-run Media; then return 1; fi
    /usr/bin/grep -q 'conflicting explicit auto_master target at line' "$TEST_TMP/${overlap_root##*/}-install-output" || return 1
    ! /usr/bin/grep -q 'p%40ss\|test:secret' "$TEST_TMP/${overlap_root##*/}-install-output" || return 1
    assert_file_absent "$overlap_root/Library" || return 1
  done

  disjoint_root=$(new_root master-disjoint)
  printf '/Volumes/Other auto_other\n' >> "$disjoint_root/etc/auto_master"
  run_install "$disjoint_root" --dry-run Media || return 1
  /usr/bin/grep -q 'Dry-run complete' "$TEST_TMP/${disjoint_root##*/}-install-output" || return 1

  trailing_root=$(new_root master-noncanonical-trailing)
  printf '/Users/testuser/ auto_conflict\n' >> "$trailing_root/etc/auto_master"
  if run_install "$trailing_root" --dry-run Media; then return 1; fi
  /usr/bin/grep -q 'unsupported auto_master target at line' "$TEST_TMP/${trailing_root##*/}-install-output" || return 1
  assert_file_absent "$trailing_root/Library" || return 1
}

test_dangling_fstab_symlink_is_rejected() {
  root=$(new_root dangling-fstab)
  /bin/rm -f "$root/etc/fstab"
  /bin/ln -s "$root/etc/missing-fstab" "$root/etc/fstab"
  if run_install "$root" --dry-run Media; then return 1; fi
  /usr/bin/grep -q 'refusing symlinked path' "$TEST_TMP/${root##*/}-install-output" || return 1
  assert_file_absent "$root/Library" || return 1
}

test_symlinked_root_and_destination_are_rejected() {
  real_root=$(new_root symlink-real)
  link=$TEST_TMP/symlink-root
  /bin/ln -s "$real_root" "$link"
  if /bin/bash "$INSTALLER" --staging-root "$link" --local-user testuser --dry-run Media >/dev/null 2>&1; then return 1; fi

  root=$(new_root symlink-destination)
  outside=$TEST_TMP/outside
  /bin/mkdir "$outside"
  /bin/ln -s "$outside" "$root/Library"
  if run_install "$root" --dry-run Media; then return 1; fi
  assert_file_absent "$outside/Application Support" || return 1

  root_etc=$(new_root symlink-etc)
  outside_etc=$(new_root outside-etc)
  /bin/rm -R "${root_etc:?}/etc"
  /bin/ln -s "$outside_etc/etc" "$root_etc/etc"
  if run_install "$root_etc" --dry-run Media; then return 1; fi
  /usr/bin/grep -q 'path escapes staging root' "$TEST_TMP/${root_etc##*/}-install-output" || return 1
  assert_file_absent "$root_etc/Library" || return 1

  root_parent=$(new_root nondirectory-parent)
  printf 'not a directory\n' > "$root_parent/var"
  if run_install "$root_parent" --dry-run Media; then return 1; fi
  /usr/bin/grep -q 'unsafe privileged parent in installation plan' "$TEST_TMP/${root_parent##*/}-install-output" || return 1

  root_log=$(new_root unsafe-log-type)
  /bin/mkdir -p "$root_log/var/log/mount-watchdog.log"
  if run_install "$root_log" --dry-run Media; then return 1; fi
  /usr/bin/grep -q 'existing log path is not a safe regular file' "$TEST_TMP/${root_log##*/}-install-output" || return 1
}

test_install_provenance_blocks_tampering_and_collisions() {
  root=$(new_root manifest-tamper)
  run_install "$root" Media || return 1
  printf '# changed after maintained installation\n' >> "$root/Library/Application Support/MountWatchdog/watchdog.sh"
  if run_install "$root" --dry-run Media; then return 1; fi
  /usr/bin/grep -q 'manifest-owned artifact checksum mismatch' "$TEST_TMP/${root##*/}-install-output" || return 1

  manifest_root=$(new_root manifest-shape)
  run_install "$manifest_root" Media || return 1
  manifest="$manifest_root/Library/Application Support/MountWatchdog/install-manifest.tsv"
  /bin/cp "$manifest" "$TEST_TMP/valid-install-manifest.tsv"
  duplicate_manifest_record=$(/usr/bin/grep '^file' "$manifest" | /usr/bin/head -1)
  printf '%s\n' "$duplicate_manifest_record" >> "$manifest"
  if run_install "$manifest_root" --dry-run Media; then return 1; fi
  /usr/bin/grep -q 'duplicate path' "$TEST_TMP/${manifest_root##*/}-install-output" || return 1
  /bin/cp "$TEST_TMP/valid-install-manifest.tsv" "$manifest"
  printf 'file\t/tmp/not-owned-by-mountwatchdog\t%s\n' '0000000000000000000000000000000000000000000000000000000000000000' >> "$manifest"
  if run_install "$manifest_root" --dry-run Media; then return 1; fi
  /usr/bin/grep -q 'non-allowlisted path' "$TEST_TMP/${manifest_root##*/}-install-output" || return 1

  unmanaged=$(new_root unmanaged-install)
  app="$unmanaged/Library/Application Support/MountWatchdog"
  /bin/mkdir -p "$app"
  /bin/chmod 700 "$app"
  /bin/cp "$PROJECT_DIR/mount_watchdog.sh" "$app/watchdog.sh"
  printf 'Media\t/Users/testuser/Media\t192.0.2.10\tMedia\n' > "$app/mounts.conf"
  if run_install "$unmanaged" --dry-run Media; then return 1; fi
  /usr/bin/grep -q 'canonical artifacts exist without a maintained manifest; refusing overwrite' "$TEST_TMP/${unmanaged##*/}-install-output" || return 1
  assert_file_absent "$unmanaged/Library/LaunchDaemons/com.antoinemenard.mount-watchdog.plist" || return 1

  collision=$(new_root arbitrary-collision)
  collision_app="$collision/Library/Application Support/MountWatchdog"
  /bin/mkdir -p "$collision_app"
  /bin/chmod 700 "$collision_app"
  printf '#!/bin/bash\nprintf arbitrary-collision\n' > "$collision_app/watchdog.sh"
  printf 'Media\t/Users/testuser/Media\t192.0.2.10\tMedia\n' > "$collision_app/mounts.conf"
  if run_install "$collision" --dry-run Media; then return 1; fi
  /usr/bin/grep -q 'canonical artifacts exist without a maintained manifest; refusing overwrite' "$TEST_TMP/${collision##*/}-install-output" || return 1
  assert_file_absent "$collision/Library/LaunchDaemons/com.antoinemenard.mount-watchdog.plist" || return 1

  plist_collision=$(new_root canonical-plist-program-collision)
  run_install "$plist_collision" Media || return 1
  /bin/rm -f "$plist_collision/Library/Application Support/MountWatchdog/install-manifest.tsv"
  /usr/libexec/PlistBuddy -c 'Add :Program string /tmp/not-allowlisted' "$plist_collision/Library/LaunchDaemons/com.antoinemenard.mount-watchdog.plist" || return 1
  if run_install "$plist_collision" --dry-run Media; then return 1; fi
  /usr/bin/grep -q 'canonical artifacts exist without a maintained manifest; refusing overwrite' "$TEST_TMP/${plist_collision##*/}-install-output" || return 1
}

test_managed_directory_metadata_is_not_rewritten_before_backup() {
  root=$(new_root managed-mode)
  run_install "$root" Media || return 1
  app="$root/Library/Application Support/MountWatchdog"
  backups="$app/backups"
  count_before=$(/usr/bin/find "$backups" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  /bin/chmod 755 "$app"
  if run_install "$root" --dry-run Media; then return 1; fi
  /usr/bin/grep -q 'unsafe managed directory in installation plan' "$TEST_TMP/${root##*/}-install-output" || return 1
  if run_install "$root" Media; then return 1; fi
  [ "$(/usr/bin/stat -f '%Lp' "$app")" = 755 ] || return 1
  count_after=$(/usr/bin/find "$backups" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  assert_eq "$count_before" "$count_after" 'unsafe managed mode caused a pre-backup mutation' || return 1
  /usr/bin/grep -q 'unsafe managed directory in installation plan' "$TEST_TMP/${root##*/}-install-output" || return 1

  remove_root=$(new_root removal-backups-mode)
  run_install "$remove_root" Media || return 1
  remove_backups="$remove_root/Library/Application Support/MountWatchdog/backups"
  /bin/chmod 755 "$remove_backups"
  : > "$remove_root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$remove_root/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$remove_root" remove > "$remove_root/output" 2>&1; then
    return 1
  fi
  [ "$(/usr/bin/stat -f '%Lp' "$remove_backups")" = 755 ] || return 1
  [ ! -s "$remove_root/actions" ] || return 1
  /usr/bin/grep -q 'backups directory mode is not 0700' "$remove_root/output" || return 1
}

test_rollback_rejects_tampered_backup_content() {
  root=$(new_root rollback-backup-hash)
  run_install "$root" Media || return 1
  : > "$root/actions"
  printf '/Users/testuser/Media -fstype=smbfs,soft ://test:new@198.51.100.20/Media\n' > "$root/etc/auto_smb"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=0 \
    MOUNTWATCHDOG_TEST_FAIL_AT=after_replace MOUNTWATCHDOG_TEST_TAMPER_BACKUP_ON_ROLLBACK=1 \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions /bin/bash "$INSTALLER" \
      --staging-root "$root" --local-user testuser Media > "$root/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'rollback incomplete' "$root/output" || return 1
  /usr/bin/grep -R -q $'result\trollback-incomplete' "$root/Library/Application Support/MountWatchdog/backups" || return 1
  /usr/bin/grep -q '^disable system/com.antoinemenard.mount-watchdog$' "$root/actions" || return 1
  ! /usr/bin/grep -q '^bootstrap ' "$root/actions" || return 1
  ! /usr/bin/grep -q '^enable ' "$root/actions" || return 1

  remove_root=$(new_root remove-rollback-backup-hash)
  run_install "$remove_root" Media || return 1
  : > "$remove_root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=0 \
    MOUNTWATCHDOG_TEST_UNINSTALL_FAIL_AT=after_remove \
    MOUNTWATCHDOG_TEST_TAMPER_REMOVE_BACKUP_ON_ROLLBACK=1 \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$remove_root/actions /bin/bash "$UNINSTALLER" \
      --staging-root "$remove_root" remove > "$remove_root/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'rollback incomplete' "$remove_root/output" || return 1
  /usr/bin/grep -R -q $'result\trollback-incomplete' "$remove_root/Library/Application Support/MountWatchdog/backups" || return 1
  /usr/bin/grep -q '^disable system/com.antoinemenard.mount-watchdog$' "$remove_root/actions" || return 1
  ! /usr/bin/grep -q '^bootstrap ' "$remove_root/actions" || return 1
  ! /usr/bin/grep -q '^enable ' "$remove_root/actions" || return 1

  install_marker_root=$(new_root install-rollback-marker-failure)
  run_install "$install_marker_root" Media || return 1
  : > "$install_marker_root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=0 \
    MOUNTWATCHDOG_TEST_FAIL_AT=after_replace MOUNTWATCHDOG_TEST_FAIL_ROLLBACK_MARKER=1 \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$install_marker_root/actions /bin/bash "$INSTALLER" \
      --staging-root "$install_marker_root" --local-user testuser Media > "$install_marker_root/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'rollback incomplete' "$install_marker_root/output" || return 1
  /usr/bin/grep -R -q $'result\trollback-incomplete' "$install_marker_root/Library/Application Support/MountWatchdog/backups" || return 1
  ! /usr/bin/grep -R -q $'result\trolled-back' "$install_marker_root/Library/Application Support/MountWatchdog/backups" || return 1
  /usr/bin/grep -q '^disable system/com.antoinemenard.mount-watchdog$' "$install_marker_root/actions" || return 1

  remove_marker_root=$(new_root remove-rollback-marker-failure)
  run_install "$remove_marker_root" Media || return 1
  : > "$remove_marker_root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=0 \
    MOUNTWATCHDOG_TEST_UNINSTALL_FAIL_AT=after_remove MOUNTWATCHDOG_TEST_FAIL_ROLLBACK_MARKER=1 \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$remove_marker_root/actions /bin/bash "$UNINSTALLER" \
      --staging-root "$remove_marker_root" remove > "$remove_marker_root/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'rollback incomplete' "$remove_marker_root/output" || return 1
  /usr/bin/grep -R -q $'result\trollback-incomplete' "$remove_marker_root/Library/Application Support/MountWatchdog/backups" || return 1
  ! /usr/bin/grep -R -q $'result\trolled-back' "$remove_marker_root/Library/Application Support/MountWatchdog/backups" || return 1
  /usr/bin/grep -q '^disable system/com.antoinemenard.mount-watchdog$' "$remove_marker_root/actions" || return 1
}

test_remove_preserves_backups_logs_maps_and_mountpoints() {
  root=$(new_root remove)
  run_install "$root" Media Studio || return 1
  /bin/mkdir -p "$root/Users/testuser/Media"
  printf 'synthetic content\n' > "$root/Users/testuser/Media/keep"
  /bin/cp "$root/etc/auto_master" "$root/master-before"
  /bin/cp "$root/etc/auto_smb" "$root/smb-before"

  /bin/bash "$UNINSTALLER" --staging-root "$root" --dry-run remove > "$root/uninstall-dry" 2>&1 || return 1
  [ -f "$root/Library/Application Support/MountWatchdog/watchdog.sh" ] || return 1
  MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$root" remove > "$root/uninstall-output" 2>&1 || { /bin/cat "$root/uninstall-output" >&2; return 1; }
  assert_file_absent "$root/Library/Application Support/MountWatchdog/watchdog.sh" || return 1
  assert_file_absent "$root/Library/LaunchDaemons/com.antoinemenard.mount-watchdog.plist" || return 1
  [ -d "$root/Library/Application Support/MountWatchdog/backups" ] || return 1
  [ -f "$root/var/log/mount-watchdog.log" ] || return 1
  [ -f "$root/Users/testuser/Media/keep" ] || return 1
  /usr/bin/cmp -s "$root/master-before" "$root/etc/auto_master" || return 1
  /usr/bin/cmp -s "$root/smb-before" "$root/etc/auto_smb" || return 1
}

test_stop_and_disable_require_maintained_provenance() {
  root=$(new_root lifecycle-owned)
  run_install "$root" Media || return 1
  : > "$root/actions"
  MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$root" --dry-run stop > "$root/stop-dry-output" 2>&1 || return 1
  [ ! -s "$root/actions" ] || return 1
  MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$root" stop > "$root/stop-output" 2>&1 || return 1
  /usr/bin/grep -q '^bootout system/com.antoinemenard.mount-watchdog$' "$root/actions" || return 1
  : > "$root/actions"
  MOUNTWATCHDOG_TEST_LOADED=0 MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$root" disable > "$root/disable-output" 2>&1 || return 1
  /usr/bin/grep -q '^disable system/com.antoinemenard.mount-watchdog$' "$root/actions" || return 1

  missing_manifest=$(new_root lifecycle-missing-manifest)
  run_install "$missing_manifest" Media || return 1
  /bin/rm -f "$missing_manifest/Library/Application Support/MountWatchdog/install-manifest.tsv"
  : > "$missing_manifest/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$missing_manifest/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$missing_manifest" stop > "$missing_manifest/output" 2>&1; then
    return 1
  fi
  [ ! -s "$missing_manifest/actions" ] || return 1
  /usr/bin/grep -q 'manifest is missing or unsafe' "$missing_manifest/output" || return 1

  tampered_manifest=$(new_root lifecycle-tampered-manifest)
  run_install "$tampered_manifest" Media || return 1
  printf 'file\t/tmp/not-owned\t%s\n' '0000000000000000000000000000000000000000000000000000000000000000' >> "$tampered_manifest/Library/Application Support/MountWatchdog/install-manifest.tsv"
  : > "$tampered_manifest/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$tampered_manifest/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$tampered_manifest" disable > "$tampered_manifest/output" 2>&1; then
    return 1
  fi
  [ ! -s "$tampered_manifest/actions" ] || return 1
  /usr/bin/grep -q 'non-allowlisted path' "$tampered_manifest/output" || return 1

  missing_plist=$(new_root lifecycle-loaded-missing-plist)
  run_install "$missing_plist" Media || return 1
  runtime="$missing_plist/Library/Application Support/MountWatchdog/watchdog.sh"
  runtime_sha=$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')
  /bin/rm -f "$missing_plist/Library/LaunchDaemons/com.antoinemenard.mount-watchdog.plist"
  : > "$missing_plist/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$missing_plist/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$missing_plist" remove > "$missing_plist/output" 2>&1; then
    return 1
  fi
  [ ! -s "$missing_plist/actions" ] || return 1
  [ "$runtime_sha" = "$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')" ] || return 1
  /usr/bin/grep -q 'validated canonical plist is required' "$missing_plist/output" || return 1
}

test_loaded_job_identity_mismatch_fails_before_actions() {
  root=$(new_root loaded-identity-installer)
  run_install "$root" Media || return 1
  runtime="$root/Library/Application Support/MountWatchdog/watchdog.sh"
  runtime_sha=$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')
  backup_count=$(/usr/bin/find "$root/Library/Application Support/MountWatchdog/backups" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  : > "$root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_LOADED_IDENTITY_MISMATCH=canonical \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions /bin/bash "$INSTALLER" \
      --staging-root "$root" --local-user testuser Media > "$root/install-output" 2>&1; then
    return 1
  fi
  [ ! -s "$root/actions" ] || return 1
  [ "$runtime_sha" = "$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')" ] || return 1
  [ "$backup_count" = "$(/usr/bin/find "$root/Library/Application Support/MountWatchdog/backups" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')" ] || return 1
  /usr/bin/grep -q 'loaded canonical job does not match the exact on-disk plist path and program arguments' "$root/install-output" || return 1

  : > "$root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_LOADED_IDENTITY_MISMATCH=canonical \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions /bin/bash "$UNINSTALLER" \
      --staging-root "$root" stop > "$root/uninstall-output" 2>&1; then
    return 1
  fi
  [ ! -s "$root/actions" ] || return 1
  [ "$runtime_sha" = "$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')" ] || return 1
  /usr/bin/grep -q 'loaded canonical job does not match the exact on-disk plist path and program arguments' "$root/uninstall-output" || return 1

}

test_failed_remove_restores_files_and_service_policy() {
  root=$(new_root remove-rollback)
  run_install "$root" Media || return 1
  runtime="$root/Library/Application Support/MountWatchdog/watchdog.sh"
  runtime_sha=$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')
  : > "$root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=0 \
    MOUNTWATCHDOG_TEST_UNINSTALL_FAIL_AT=after_remove \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$root" remove > "$TEST_TMP/remove-rollback-output" 2>&1; then
    return 1
  fi
  [ -f "$runtime" ] || return 1
  [ "$runtime_sha" = "$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')" ] || return 1
  [ -f "$root/Library/LaunchDaemons/com.antoinemenard.mount-watchdog.plist" ] || return 1
  /usr/bin/grep -q '^disable system/com.antoinemenard.mount-watchdog$' "$root/actions" || return 1
  /usr/bin/grep -q '^bootstrap system ' "$root/actions" || return 1
  /usr/bin/grep -q '^enable system/com.antoinemenard.mount-watchdog$' "$root/actions" || return 1
  /usr/bin/grep -q 'prior files and service state restored' "$TEST_TMP/remove-rollback-output" || return 1
}

test_lifecycle_abort_restores_exact_service_state() {
  disable_root=$(new_root disable-abort)
  run_install "$disable_root" Media || return 1
  : > "$disable_root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=0 \
    MOUNTWATCHDOG_TEST_UNINSTALL_FAIL_AT=after_disable \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$disable_root/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$disable_root" disable > "$disable_root/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q '^disable system/com.antoinemenard.mount-watchdog$' "$disable_root/actions" || return 1
  /usr/bin/grep -q '^enable system/com.antoinemenard.mount-watchdog$' "$disable_root/actions" || return 1
  ! /usr/bin/grep -q '^bootout ' "$disable_root/actions" || return 1
  ! /usr/bin/grep -q '^bootstrap ' "$disable_root/actions" || return 1
  /usr/bin/grep -q 'prior service state restored' "$disable_root/output" || return 1

  remove_root=$(new_root remove-abort-before-service)
  run_install "$remove_root" Media || return 1
  runtime="$remove_root/Library/Application Support/MountWatchdog/watchdog.sh"
  runtime_sha=$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')
  : > "$remove_root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=0 \
    MOUNTWATCHDOG_TEST_UNINSTALL_FAIL_AT=before_service_change \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$remove_root/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$remove_root" remove > "$remove_root/output" 2>&1; then
    return 1
  fi
  [ "$runtime_sha" = "$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')" ] || return 1
  ! /usr/bin/grep -q '^bootout ' "$remove_root/actions" || return 1
  ! /usr/bin/grep -q '^bootstrap ' "$remove_root/actions" || return 1
  /usr/bin/grep -q 'prior files and service state restored' "$remove_root/output" || return 1

  disable_effect_root=$(new_root remove-disable-partial-effect)
  run_install "$disable_effect_root" Media || return 1
  runtime="$disable_effect_root/Library/Application Support/MountWatchdog/watchdog.sh"
  runtime_sha=$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')
  : > "$disable_effect_root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=0 \
    MOUNTWATCHDOG_TEST_DISABLE_FAIL_AFTER_EFFECT=1 \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$disable_effect_root/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$disable_effect_root" remove > "$disable_effect_root/output" 2>&1; then
    return 1
  fi
  [ "$runtime_sha" = "$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')" ] || return 1
  /usr/bin/grep -q '^disable system/com.antoinemenard.mount-watchdog$' "$disable_effect_root/actions" || return 1
  /usr/bin/grep -q '^enable system/com.antoinemenard.mount-watchdog$' "$disable_effect_root/actions" || return 1
  ! /usr/bin/grep -q '^bootout ' "$disable_effect_root/actions" || return 1
  /usr/bin/grep -q 'prior files and service state restored' "$disable_effect_root/output" || return 1

  bootout_effect_root=$(new_root remove-bootout-partial-effect)
  run_install "$bootout_effect_root" Media || return 1
  runtime="$bootout_effect_root/Library/Application Support/MountWatchdog/watchdog.sh"
  runtime_sha=$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')
  : > "$bootout_effect_root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=0 \
    MOUNTWATCHDOG_TEST_BOOTOUT_FAIL_AFTER_EFFECT=1 \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$bootout_effect_root/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$bootout_effect_root" remove > "$bootout_effect_root/output" 2>&1; then
    return 1
  fi
  [ "$runtime_sha" = "$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')" ] || return 1
  /usr/bin/grep -q '^bootout system/com.antoinemenard.mount-watchdog$' "$bootout_effect_root/actions" || return 1
  /usr/bin/grep -q '^bootstrap system ' "$bootout_effect_root/actions" || return 1
  /usr/bin/grep -q 'prior files and service state restored' "$bootout_effect_root/output" || return 1

  lifecycle_incomplete=$(new_root lifecycle-restore-incomplete)
  run_install "$lifecycle_incomplete" Media || return 1
  : > "$lifecycle_incomplete/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=1 \
    MOUNTWATCHDOG_TEST_BOOTOUT_FAIL_AFTER_EFFECT=1 \
    MOUNTWATCHDOG_TEST_DISABLE_FAIL_AFTER_EFFECT=1 \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$lifecycle_incomplete/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$lifecycle_incomplete" stop > "$lifecycle_incomplete/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'service-state rollback incomplete' "$lifecycle_incomplete/output" || return 1
  last_enable=$(/usr/bin/grep -n '^enable system/com.antoinemenard.mount-watchdog$' "$lifecycle_incomplete/actions" | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)
  last_disable=$(/usr/bin/grep -n '^disable system/com.antoinemenard.mount-watchdog$' "$lifecycle_incomplete/actions" | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)
  last_bootout=$(/usr/bin/grep -n '^bootout system/com.antoinemenard.mount-watchdog$' "$lifecycle_incomplete/actions" | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)
  [ -n "$last_enable" ] && [ -n "$last_disable" ] && [ -n "$last_bootout" ] || return 1
  [ "$last_enable" -lt "$last_disable" ] || return 1
}

test_launchctl_unknown_states_and_operation_lock_fail_closed() {
  unknown_install=$(new_root install-initial-state-unknown)
  if MOUNTWATCHDOG_TEST_LAUNCHCTL_UNKNOWN_AT=canonical-initial \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$unknown_install/actions /bin/bash "$INSTALLER" \
      --staging-root "$unknown_install" --local-user testuser Media > "$unknown_install/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'cannot reliably inspect canonical launchd state' "$unknown_install/output" || return 1
  assert_file_absent "$unknown_install/actions" || return 1
  assert_file_absent "$unknown_install/.mountwatchdog-lifecycle.lock" || return 1
  assert_file_absent "$unknown_install/Library" || return 1

  unknown_uninstall=$(new_root uninstall-initial-state-unknown)
  run_install "$unknown_uninstall" Media || return 1
  : > "$unknown_uninstall/actions"
  if MOUNTWATCHDOG_TEST_LAUNCHCTL_UNKNOWN_AT=canonical-initial \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$unknown_uninstall/actions /bin/bash "$UNINSTALLER" \
      --staging-root "$unknown_uninstall" stop > "$unknown_uninstall/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'cannot reliably inspect canonical launchd state' "$unknown_uninstall/output" || return 1
  [ ! -s "$unknown_uninstall/actions" ] || return 1
  assert_file_absent "$unknown_uninstall/.mountwatchdog-lifecycle.lock" || return 1

  contention=$(new_root lifecycle-lock-contention)
  /bin/mkdir -m 700 "$contention/.mountwatchdog-lifecycle.lock" || return 1
  if MOUNTWATCHDOG_TEST_ACTION_LOG=$contention/actions /bin/bash "$INSTALLER" \
    --staging-root "$contention" --local-user testuser Media > "$contention/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'lifecycle operation lock is busy, stale, or unsafe' "$contention/output" || return 1
  assert_file_absent "$contention/actions" || return 1
  assert_file_absent "$contention/Library" || return 1
  /bin/rmdir "$contention/.mountwatchdog-lifecycle.lock" || return 1

  uninstall_contention=$(new_root uninstall-lock-contention)
  run_install "$uninstall_contention" Media || return 1
  runtime="$uninstall_contention/Library/Application Support/MountWatchdog/watchdog.sh"
  runtime_sha=$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')
  : > "$uninstall_contention/actions"
  /bin/mkdir -m 700 "$uninstall_contention/.mountwatchdog-lifecycle.lock" || return 1
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$uninstall_contention/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$uninstall_contention" remove > "$uninstall_contention/output" 2>&1; then
    return 1
  fi
  [ "$runtime_sha" = "$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')" ] || return 1
  [ ! -s "$uninstall_contention/actions" ] || return 1
  /bin/rmdir "$uninstall_contention/.mountwatchdog-lifecycle.lock" || return 1

  abnormal_install=$(new_root install-abnormal-exit)
  run_install "$abnormal_install" Media || return 1
  : > "$abnormal_install/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_UNHANDLED_EXIT_AT=after_replace \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$abnormal_install/actions /bin/bash "$INSTALLER" \
      --staging-root "$abnormal_install" --local-user testuser Media > "$abnormal_install/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -R -q $'result\trolled-back' "$abnormal_install/Library/Application Support/MountWatchdog/backups" || return 1
  assert_file_absent "$abnormal_install/.mountwatchdog-lifecycle.lock" || return 1

  abnormal_remove=$(new_root uninstall-abnormal-exit)
  run_install "$abnormal_remove" Media || return 1
  runtime="$abnormal_remove/Library/Application Support/MountWatchdog/watchdog.sh"
  runtime_sha=$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')
  : > "$abnormal_remove/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_UNHANDLED_EXIT_AT=after_remove \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$abnormal_remove/actions /bin/bash "$UNINSTALLER" \
      --staging-root "$abnormal_remove" remove > "$abnormal_remove/output" 2>&1; then
    return 1
  fi
  [ "$runtime_sha" = "$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')" ] || return 1
  assert_file_absent "$abnormal_remove/.mountwatchdog-lifecycle.lock" || return 1

  unknown_effect=$(new_root install-bootout-state-unknown)
  run_install "$unknown_effect" Media || return 1
  : > "$unknown_effect/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_INSTALL_BOOTOUT_FAIL_BEFORE_EFFECT=1 \
    MOUNTWATCHDOG_TEST_LAUNCHCTL_UNKNOWN_AT=canonical-after-bootout-failure \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$unknown_effect/actions /bin/bash "$INSTALLER" \
      --staging-root "$unknown_effect" --local-user testuser Media > "$unknown_effect/output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q 'rollback incomplete' "$unknown_effect/output" || return 1
  assert_file_absent "$unknown_effect/.mountwatchdog-lifecycle.lock" || return 1
}

test_hash_output_validation_fails_before_lifecycle_actions() {
  root=$(new_root hash-validation)
  run_install "$root" Media || return 1
  runtime="$root/Library/Application Support/MountWatchdog/watchdog.sh"
  runtime_sha=$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')
  backup_count=$(/usr/bin/find "$root/Library/Application Support/MountWatchdog/backups" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  for behavior in fail malformed; do
    : > "$root/actions"
    if MOUNTWATCHDOG_TEST_SHASUM_BEHAVIOR=$behavior MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions \
      /bin/bash "$INSTALLER" --staging-root "$root" --local-user testuser --dry-run Media > "$root/install-$behavior" 2>&1; then
      return 1
    fi
    [ ! -s "$root/actions" ] || return 1
    [ "$runtime_sha" = "$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')" ] || return 1
    [ "$backup_count" = "$(/usr/bin/find "$root/Library/Application Support/MountWatchdog/backups" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')" ] || return 1
    if MOUNTWATCHDOG_TEST_SHASUM_BEHAVIOR=$behavior MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions \
      /bin/bash "$UNINSTALLER" --staging-root "$root" stop > "$root/uninstall-$behavior" 2>&1; then
      return 1
    fi
    [ ! -s "$root/actions" ] || return 1
  done
}

test_rollbacks_preserve_logs_and_restore_only_removed_files() {
  log_root=$(new_root existing-log-rollback)
  /bin/mkdir -p "$log_root/var/log"
  printf 'existing log line\n' > "$log_root/var/log/mount-watchdog.log"
  if MOUNTWATCHDOG_TEST_FAIL_AT=after_replace MOUNTWATCHDOG_TEST_APPEND_EXISTING_LOG_ON_ROLLBACK=1 \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$log_root/actions /bin/bash "$INSTALLER" \
      --staging-root "$log_root" --local-user testuser Media > "$log_root/output" 2>&1; then
    return 1
  fi
  expected_log=$(printf 'existing log line\nconcurrent log append retained by rollback')
  assert_eq "$expected_log" "$(/bin/cat "$log_root/var/log/mount-watchdog.log")" 'rollback replaced an existing append-only log' || return 1

  created_log=$(new_root created-log-rollback)
  if MOUNTWATCHDOG_TEST_FAIL_AT=after_replace MOUNTWATCHDOG_TEST_ACTION_LOG=$created_log/actions \
    /bin/bash "$INSTALLER" --staging-root "$created_log" --local-user testuser Media > "$created_log/output" 2>&1; then
    return 1
  fi
  assert_file_absent "$created_log/var/log/mount-watchdog.log" || return 1

  no_remove=$(new_root no-removal-rewrite)
  run_install "$no_remove" Media || return 1
  runtime="$no_remove/Library/Application Support/MountWatchdog/watchdog.sh"
  runtime_inode=$(/usr/bin/stat -f '%i' "$runtime")
  : > "$no_remove/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_UNINSTALL_FAIL_AT=before_service_change \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$no_remove/actions /bin/bash "$UNINSTALLER" \
      --staging-root "$no_remove" remove > "$no_remove/output" 2>&1; then
    return 1
  fi
  [ "$runtime_inode" = "$(/usr/bin/stat -f '%i' "$runtime")" ] || return 1

  partial=$(new_root partial-removal-rollback)
  run_install "$partial" Media || return 1
  runtime="$partial/Library/Application Support/MountWatchdog/watchdog.sh"
  status="$partial/Library/Application Support/MountWatchdog/status.sh"
  runtime_sha=$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')
  status_inode=$(/usr/bin/stat -f '%i' "$status")
  : > "$partial/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_UNINSTALL_FAIL_AFTER_REMOVALS=1 \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$partial/actions /bin/bash "$UNINSTALLER" \
      --staging-root "$partial" remove > "$partial/output" 2>&1; then
    return 1
  fi
  [ "$runtime_sha" = "$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')" ] || return 1
  [ "$status_inode" = "$(/usr/bin/stat -f '%i' "$status")" ] || return 1

  unlink_signal=$(new_root post-unlink-signal)
  run_install "$unlink_signal" Media || return 1
  runtime="$unlink_signal/Library/Application Support/MountWatchdog/watchdog.sh"
  runtime_sha=$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')
  : > "$unlink_signal/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_SIGNAL_AFTER_UNLINK=1 \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$unlink_signal/actions /bin/bash "$UNINSTALLER" \
      --staging-root "$unlink_signal" remove > "$unlink_signal/output" 2>&1; then
    return 1
  fi
  [ "$runtime_sha" = "$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')" ] || return 1
  /usr/bin/grep -R -q $'result\trolled-back' "$unlink_signal/Library/Application Support/MountWatchdog/backups" || return 1
}

test_post_success_rollback_restores_fresh_and_upgrade_states() {
  fresh=$(new_root post-success-fresh)
  run_install "$fresh" Media || return 1
  fresh_backup=$(latest_install_backup_id "$fresh")
  [ -n "$fresh_backup" ] || return 1
  /usr/bin/grep -Fq "Post-success rollback dry-run: sudo /bin/bash ./uninstall_mount_watchdog.sh --dry-run rollback $fresh_backup" \
    "$TEST_TMP/${fresh##*/}-install-output" || return 1
  printf 'retained post-install evidence\n' >> "$fresh/var/log/mount-watchdog.log"
  fresh_log_before=$(/bin/cat "$fresh/var/log/mount-watchdog.log")
  : > "$fresh/actions"
  MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$fresh/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$fresh" --dry-run rollback "$fresh_backup" \
      > "$fresh/rollback-dry-output" 2>&1 || return 1
  [ ! -s "$fresh/actions" ] || return 1
  [ -f "$fresh/Library/Application Support/MountWatchdog/watchdog.sh" ] || return 1
  ! /usr/bin/grep -q '^post_success_rollback' \
    "$fresh/Library/Application Support/MountWatchdog/backups/$fresh_backup/manifest.tsv" || return 1

  MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$fresh/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$fresh" rollback "$fresh_backup" \
      > "$fresh/rollback-output" 2>&1 || { /bin/cat "$fresh/rollback-output" >&2; return 1; }
  assert_file_absent "$fresh/Library/Application Support/MountWatchdog/watchdog.sh" || return 1
  assert_file_absent "$fresh/Library/Application Support/MountWatchdog/install-manifest.tsv" || return 1
  assert_file_absent "$fresh/Library/LaunchDaemons/com.antoinemenard.mount-watchdog.plist" || return 1
  assert_eq "$fresh_log_before" "$(/bin/cat "$fresh/var/log/mount-watchdog.log")" 'post-success rollback replaced the retained log' || return 1
  /usr/bin/grep -q $'^post_success_rollback\tcompleted$' \
    "$fresh/Library/Application Support/MountWatchdog/backups/$fresh_backup/manifest.tsv" || return 1
  /usr/bin/grep -q '^bootout system/com.antoinemenard.mount-watchdog$' "$fresh/actions" || return 1
  /usr/bin/grep -q '^enable system/com.antoinemenard.mount-watchdog$' "$fresh/actions" || return 1

  upgrade=$(new_root post-success-upgrade)
  run_install "$upgrade" Media || return 1
  old_config=$(/bin/cat "$upgrade/Library/Application Support/MountWatchdog/mounts.conf")
  old_manifest_sha=$(/usr/bin/shasum -a 256 "$upgrade/Library/Application Support/MountWatchdog/install-manifest.tsv" | /usr/bin/awk '{print $1}')
  printf '/Users/testuser/Media -fstype=smbfs,soft ://test:new@198.51.100.20/Media\n/Users/testuser/Studio -fstype=smbfs,soft ://test:secret@192.0.2.10/Workspace\n' > "$upgrade/etc/auto_smb"
  MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$upgrade/actions \
    /bin/bash "$INSTALLER" --staging-root "$upgrade" --local-user testuser Media > "$upgrade/upgrade-output" 2>&1 || return 1
  upgrade_backup=$(latest_install_backup_id "$upgrade")
  [ -n "$upgrade_backup" ] || return 1
  [ "$old_config" != "$(/bin/cat "$upgrade/Library/Application Support/MountWatchdog/mounts.conf")" ] || return 1
  : > "$upgrade/actions"
  MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_DISABLED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$upgrade/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$upgrade" rollback "$upgrade_backup" \
      > "$upgrade/rollback-output" 2>&1 || { /bin/cat "$upgrade/rollback-output" >&2; return 1; }
  assert_eq "$old_config" "$(/bin/cat "$upgrade/Library/Application Support/MountWatchdog/mounts.conf")" 'post-success rollback did not restore prior config' || return 1
  [ "$old_manifest_sha" = "$(/usr/bin/shasum -a 256 "$upgrade/Library/Application Support/MountWatchdog/install-manifest.tsv" | /usr/bin/awk '{print $1}')" ] || return 1
  enable_line=$(/usr/bin/grep -n '^enable system/com.antoinemenard.mount-watchdog$' "$upgrade/actions" | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)
  bootstrap_line=$(/usr/bin/grep -n '^bootstrap system ' "$upgrade/actions" | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)
  disable_line=$(/usr/bin/grep -n '^disable system/com.antoinemenard.mount-watchdog$' "$upgrade/actions" | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)
  [ -n "$enable_line" ] && [ "$enable_line" -lt "$bootstrap_line" ] && [ "$bootstrap_line" -lt "$disable_line" ] || return 1
}

test_post_success_rollback_rejects_unbound_or_tampered_backups() {
  unsupported=$(new_root post-success-unsupported-format)
  run_install "$unsupported" Media || return 1
  unsupported_backup=$(latest_install_backup_id "$unsupported")
  unsupported_manifest="$unsupported/Library/Application Support/MountWatchdog/backups/$unsupported_backup/manifest.tsv"
  /usr/bin/sed $'s/^format\t3$/format\t2/' "$unsupported_manifest" > "$unsupported/manifest-old" || return 1
  /bin/mv "$unsupported/manifest-old" "$unsupported_manifest" || return 1
  /bin/chmod 600 "$unsupported_manifest" || return 1
  : > "$unsupported/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$unsupported/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$unsupported" rollback "$unsupported_backup" > "$unsupported/output" 2>&1; then
    return 1
  fi
  [ ! -s "$unsupported/actions" ] || return 1
  /usr/bin/grep -q 'selected backup does not have the reviewed rollback format' "$unsupported/output" || return 1

  tampered=$(new_root post-success-tampered)
  run_install "$tampered" Media || return 1
  MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$tampered/actions \
    /bin/bash "$INSTALLER" --staging-root "$tampered" --local-user testuser Media > "$tampered/upgrade-output" 2>&1 || return 1
  tampered_backup=$(latest_install_backup_id "$tampered")
  tampered_source="$tampered/Library/Application Support/MountWatchdog/backups/$tampered_backup/files/etc-does-not-exist"
  manifest="$tampered/Library/Application Support/MountWatchdog/backups/$tampered_backup/manifest.tsv"
  real_source="$tampered/Library/Application Support/MountWatchdog/backups/$tampered_backup/files/Library/Application Support/MountWatchdog/mounts.conf"
  printf '# tampered backup content\n' >> "$real_source"
  : > "$tampered/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$tampered/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$tampered" rollback "$tampered_backup" > "$tampered/output" 2>&1; then
    return 1
  fi
  [ ! -s "$tampered/actions" ] || return 1
  /usr/bin/grep -q 'selected backup source checksum mismatch' "$tampered/output" || return 1
  assert_file_absent "$tampered/.mountwatchdog-lifecycle.lock" || return 1
  [ ! -e "$tampered_source" ] || return 1

  mismatch=$(new_root post-success-mismatch)
  run_install "$mismatch" Media || return 1
  mismatch_backup=$(latest_install_backup_id "$mismatch")
  manifest="$mismatch/Library/Application Support/MountWatchdog/install-manifest.tsv"
  /usr/bin/sed 's/^version\t.*/version\t0.1.0-other/' "$manifest" > "$mismatch/manifest-new" || return 1
  /bin/mv "$mismatch/manifest-new" "$manifest" || return 1
  /bin/chmod 600 "$manifest" || return 1
  : > "$mismatch/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$mismatch/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$mismatch" rollback "$mismatch_backup" > "$mismatch/output" 2>&1; then
    return 1
  fi
  [ ! -s "$mismatch/actions" ] || return 1
  /usr/bin/grep -q 'selected backup does not belong to the current maintained install' "$mismatch/output" || return 1
}

test_post_success_rollback_failure_is_latched_and_quiesced() {
  root=$(new_root post-success-incomplete)
  run_install "$root" Media || return 1
  MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions \
    /bin/bash "$INSTALLER" --staging-root "$root" --local-user testuser Media > "$root/upgrade-output" 2>&1 || return 1
  backup_id=$(latest_install_backup_id "$root")
  manifest="$root/Library/Application Support/MountWatchdog/backups/$backup_id/manifest.tsv"
  : > "$root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=1 MOUNTWATCHDOG_TEST_UNINSTALL_FAIL_AT=after_rollback_file \
    MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions /bin/bash "$UNINSTALLER" \
      --staging-root "$root" rollback "$backup_id" > "$root/rollback-output" 2>&1; then
    return 1
  fi
  /usr/bin/grep -q $'^post_success_rollback\tincomplete$' "$manifest" || return 1
  /usr/bin/grep -q 'rollback incomplete, the affected job remains stopped and disabled' "$root/rollback-output" || return 1
  /usr/bin/grep -q '^bootout system/com.antoinemenard.mount-watchdog$' "$root/actions" || return 1
  /usr/bin/grep -q '^disable system/com.antoinemenard.mount-watchdog$' "$root/actions" || return 1
  assert_file_absent "$root/.mountwatchdog-lifecycle.lock" || return 1
  : > "$root/actions"
  if MOUNTWATCHDOG_TEST_LOADED=0 MOUNTWATCHDOG_TEST_ACTION_LOG=$root/actions \
    /bin/bash "$UNINSTALLER" --staging-root "$root" rollback "$backup_id" > "$root/retry-output" 2>&1; then
    return 1
  fi
  [ ! -s "$root/actions" ] || return 1
  /usr/bin/grep -q 'selected backup already has post-success rollback evidence' "$root/retry-output" || return 1
}

run_test 'installer dry-run is destination-read-only and credential-redacted' test_dry_run_is_read_only_and_redacted
run_test 'auto_smb accepts only exact smb or smbfs fstype aliases' test_smb_fstype_aliases_are_exact_and_redacted
run_test 'privileged entrypoints reject untrusted repository sources before sourcing' test_privileged_entrypoints_reject_untrusted_sources_before_sourcing
run_test 'ACL policy rejects allow entries and accepts canonical deny-only sources' test_acl_policy_rejects_allow_entries_and_accepts_deny_only_sources
run_test 'managed install and backup nodes are ACL-free and existing ACLs fail closed' test_managed_nodes_are_acl_free_and_existing_acl_fails_closed
run_test 'staged VERSION and rendered plist require their exact safe schemas' test_staged_version_and_plist_schema_are_strict
run_test 'staging install preserves Homebrew-owned paths parent modes credentials and noncolliding backups' test_install_preserves_parent_modes_and_strips_credentials
run_test 'post-replacement failure restores prior files and exact mode' test_failed_replace_rolls_back_files_and_modes
run_test 'installer rollback and commit signals have deterministic nonreentrant outcomes' test_installer_transaction_signals_are_nonreentrant
run_test 'installer rollback distinguishes bootout failure before and after effect' test_installer_bootout_failures_track_actual_loaded_state
run_test 'staging action logs reject hardlinks to outside sentinels' test_staging_action_logs_reject_external_hardlinks
run_test 'uninstaller rollback and commit signals have deterministic nonreentrant outcomes' test_uninstaller_transaction_signals_are_nonreentrant
run_test 'disabled and enabled-but-unloaded service states are preserved' test_disabled_and_unloaded_states_are_preserved
run_test 'map and static fstab validation is overlap-aware redacted and nonmutating' test_strict_map_and_static_fstab_validation_is_redacted_and_nonmutating
run_test 'explicit master targets cannot overlap selected paths' test_explicit_master_targets_cannot_overlap_selected_paths
run_test 'dangling fstab symlinks fail closed before mutation' test_dangling_fstab_symlink_is_rejected
run_test 'symlinked staging roots and privileged destination components are rejected' test_symlinked_root_and_destination_are_rejected
run_test 'maintained manifests reject tampering and unmanaged collisions' test_install_provenance_blocks_tampering_and_collisions
run_test 'unsafe managed-directory metadata is rejected without a pre-backup rewrite' test_managed_directory_metadata_is_not_rewritten_before_backup
run_test 'rollback verifies backup content before restoring it' test_rollback_rejects_tampered_backup_content
run_test 'stop disable and remove require maintained manifest and exact plist provenance' test_stop_and_disable_require_maintained_provenance
run_test 'loaded canonical job identity mismatches fail before lifecycle actions' test_loaded_job_identity_mismatch_fails_before_actions
run_test 'remove preserves backups logs maps mountpoints and synthetic content' test_remove_preserves_backups_logs_maps_and_mountpoints
run_test 'failed remove atomically restores files and enabled loaded policy' test_failed_remove_restores_files_and_service_policy
run_test 'lifecycle aborts restore policy without bootstrapping an already-loaded job' test_lifecycle_abort_restores_exact_service_state
run_test 'launchctl unknown states and lifecycle lock contention fail closed' test_launchctl_unknown_states_and_operation_lock_fail_closed
run_test 'hash failures and malformed digests fail before lifecycle actions' test_hash_output_validation_fails_before_lifecycle_actions
run_test 'rollbacks preserve logs and restore only removal intents that changed files' test_rollbacks_preserve_logs_and_restore_only_removed_files
run_test 'post-success rollback restores fresh and maintained-upgrade files and service policy' test_post_success_rollback_restores_fresh_and_upgrade_states
run_test 'post-success rollback rejects tampered or unbound protected backups before actions' test_post_success_rollback_rejects_unbound_or_tampered_backups
run_test 'incomplete post-success rollback is latched and leaves affected jobs quiesced' test_post_success_rollback_failure_is_latched_and_quiesced

finish_tests
