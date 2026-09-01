#!/bin/bash
# shellcheck disable=SC2034
set -u

TEST_DIR=$(cd "${0%/*}" && pwd -P)
PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd -P)
RUNTIME=$PROJECT_DIR/mount_watchdog.sh
STATUS=$PROJECT_DIR/mount_watchdog_status.sh
STUBS=$TEST_DIR/stubs
TEST_TMP_BASE=${TMPDIR:-/tmp}
TEST_TMP_BASE=${TEST_TMP_BASE%/}
PASS_COUNT=0
OUTSIDE_FILE=
OUTSIDE_DIR=
BLOCK_PGID=
SIGNAL_RUNTIME_PID=

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok %s - %s\n' "$PASS_COUNT" "$1"
}

assert_contains() {
  /usr/bin/grep -Fq "$2" "$1" || fail "expected '$2' in $1"
}

assert_not_action() {
  if /usr/bin/grep -Eq "^($2)(\\||$)" "$1"; then
    fail "forbidden action '$2' was requested"
  fi
}

assert_log_safe() {
  [ -f "$1" ] || fail "expected credential-free log at $1"
  for mw_secret in '192.0.2.10' '/Users/testuser' 'testuser' 'guest@' 'Media' 'Studio' 'OldShare'; do
    if /usr/bin/grep -Fq "$mw_secret" "$1"; then
      fail "credential-derived value '$mw_secret' appeared in $1"
    fi
  done
}

new_fixture() {
  FIXTURE=$(/usr/bin/mktemp -d "$TEST_TMP_BASE/mountwatchdog-test.XXXXXX") || exit 1
  COMMANDS=$FIXTURE/commands
  /bin/mkdir -p "$COMMANDS" "$FIXTURE/network" "$FIXTURE/etc"
  /bin/cp "$STUBS"/* "$COMMANDS"/
  /bin/chmod 700 "$COMMANDS"/*
  /bin/cp "$PROJECT_DIR/config/defaults.conf" "$FIXTURE/defaults.conf"
  /bin/cp "$PROJECT_DIR/VERSION" "$FIXTURE/VERSION"
  : > "$FIXTURE/actions.log"
  printf '1000\n' > "$FIXTURE/now"
  printf 'reachable\n' > "$FIXTURE/network/192.0.2.10"
  printf '0\n' > "$FIXTURE/umount.exit"
  printf '0\n' > "$FIXTURE/automount.exit"
  {
    printf '+auto_master\n'
    printf '/- auto_smb\n'
    printf '/- -static\n'
  } > "$FIXTURE/etc/auto_master"
}

drop_fixture() {
  if [ -n "$SIGNAL_RUNTIME_PID" ]; then
    case "$SIGNAL_RUNTIME_PID" in
      *[!0-9]*|'') fail 'unsafe signal-runtime identifier' ;;
      *)
        kill -TERM "$SIGNAL_RUNTIME_PID" 2>/dev/null || true
        wait "$SIGNAL_RUNTIME_PID" 2>/dev/null || true
        ;;
    esac
    SIGNAL_RUNTIME_PID=
  fi
  if [ -n "$BLOCK_PGID" ]; then
    case "$BLOCK_PGID" in
      *[!0-9]*|'') fail 'unsafe blocked process-group identifier' ;;
      *)
        kill -TERM -- "-$BLOCK_PGID" 2>/dev/null || true
        wait "$BLOCK_PGID" 2>/dev/null || true
        ;;
    esac
    BLOCK_PGID=
  fi
  if [ -n "$OUTSIDE_FILE" ]; then
    case "$OUTSIDE_FILE" in
      "$TEST_TMP_BASE"/mountwatchdog-outside.*) /bin/rm -f "$OUTSIDE_FILE" ;;
      *) fail 'unsafe outside-sentinel cleanup path' ;;
    esac
    OUTSIDE_FILE=
  fi
  if [ -n "$OUTSIDE_DIR" ]; then
    case "$OUTSIDE_DIR" in
      "$TEST_TMP_BASE"/mountwatchdog-outside-dir.*) /bin/rm -R "$OUTSIDE_DIR" ;;
      *) fail 'unsafe outside-directory cleanup path' ;;
    esac
    OUTSIDE_DIR=
  fi
  [ -n "${FIXTURE:-}" ] || return 0
  case "$FIXTURE" in "$TEST_TMP_BASE"/mountwatchdog-test.*) /bin/rm -R "$FIXTURE" ;; *) fail 'unsafe fixture cleanup path' ;; esac
  FIXTURE=
}

trap 'drop_fixture' EXIT HUP INT TERM

run_runtime() {
  [ -f "$FIXTURE/preserve-autofs-fixture" ] || write_fixture_autofs
  MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$RUNTIME"
  RUNTIME_RC=$?
}

write_fixture_autofs() {
  : > "$FIXTURE/etc/auto_smb"
  mw_fixture_tab=$(printf '\tX'); mw_fixture_tab=${mw_fixture_tab%X}
  while IFS="$mw_fixture_tab" read -r mw_fixture_name mw_fixture_path mw_fixture_host mw_fixture_share mw_fixture_extra; do
    [ -n "$mw_fixture_name" ] || continue
    printf '%s -fstype=smb,soft,noowners,nosuid ://fixture-user@%s/%s\n' \
      "$mw_fixture_path" "$mw_fixture_host" "$mw_fixture_share" >> "$FIXTURE/etc/auto_smb"
  done < "$FIXTURE/mounts.conf"
}

write_one_config() {
  printf 'Media\t/Users/testuser/Media\t192.0.2.10\tMedia\n' > "$FIXTURE/mounts.conf"
  write_fixture_autofs
}

write_expected_media_mount() {
  {
    printf 'map auto_smb on /Users/testuser/Media (autofs, automounted, nobrowse)\n'
    printf '//guest@192.0.2.10/Media on /Users/testuser/Media (smbfs, nodev, nosuid)\n'
  } > "$FIXTURE/mount.output"
}

seed_state() {
  mw_seed_name=$1
  mw_seed_path=$2
  mw_seed_host=$3
  mw_seed_share=$4
  mw_seed_network=$5
  mw_seed_summary=${6:-mounted-unreachable}
  mw_seed_mount_state=${7:-expected-smb}
  mw_seed_error=${8:-none}
  mw_seed_config_sum=$(/usr/bin/cksum "$FIXTURE/mounts.conf")
  mw_seed_defaults_sum=$(/usr/bin/cksum "$FIXTURE/defaults.conf")
  mw_seed_version_sum=$(/usr/bin/cksum "$FIXTURE/VERSION")
  mw_seed_program_sum=$(/usr/bin/shasum -a 256 "$RUNTIME")
  mw_seed_common_sum=$(/usr/bin/shasum -a 256 "$PROJECT_DIR/lib/common.sh")
  mw_seed_runtime_sum=$(/usr/bin/shasum -a 256 "$PROJECT_DIR/lib/runtime.sh")
  mw_seed_autofs_sum=$(/usr/bin/shasum -a 256 "$PROJECT_DIR/lib/autofs.sh")
  mw_seed_fingerprint=${mw_seed_config_sum%% *}-${mw_seed_defaults_sum%% *}-${mw_seed_version_sum%% *}-${mw_seed_program_sum%% *}-${mw_seed_common_sum%% *}-${mw_seed_runtime_sum%% *}-${mw_seed_autofs_sum%% *}
  /bin/mkdir -p "$FIXTURE/state/$mw_seed_name"
  {
    printf 'format|1\n'
    printf 'checked_at_epoch|900\n'
    printf 'checked_at|2026-08-30T00:00:00Z\n'
    printf 'mount_name|%s\n' "$mw_seed_name"
    printf 'mount_path|%s\n' "$mw_seed_path"
    printf 'expected_host|%s\n' "$mw_seed_host"
    printf 'expected_share|%s\n' "$mw_seed_share"
    printf 'state|%s\n' "$mw_seed_summary"
    printf 'mount_state|%s\n' "$mw_seed_mount_state"
    printf 'network_state|%s\n' "$mw_seed_network"
    printf 'last_network_state|%s\n' "$mw_seed_network"
    printf 'check_scope|mount-table-and-tcp\n'
    printf 'readability|not-tested\n'
    printf 'runtime_fingerprint|%s\n' "$mw_seed_fingerprint"
    printf 'initialized|1\n'
    printf 'pending_recovery|none\n'
    printf 'pending_since_epoch|0\n'
    printf 'action_state|idle\n'
    printf 'last_attempt_epoch|0\n'
    printf 'last_attempt_action|never\n'
    printf 'last_attempt_result|never\n'
    printf 'last_attempt_exit_status|not-run\n'
    printf 'last_successful_action_epoch|0\n'
    printf 'last_successful_action|never\n'
    printf 'last_error|%s\n' "$mw_seed_error"
    printf 'blocked_pid|none\n'
  } > "$FIXTURE/state/$mw_seed_name/status"
}

# First startup establishes a baseline without tearing down a matching share.
new_fixture
write_one_config
write_expected_media_mount
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "first baseline exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'state|mounted-reachable'
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|none'
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
[ "$(/usr/bin/grep -c '^nc|' "$FIXTURE/actions.log")" -eq 1 ] || fail 'host was not probed exactly once'
assert_contains "$FIXTURE/watchdog.log" 'event=state-transition scope=slot slot=1 action=observe reason=state-changed result=changed from=uninitialized to=mounted-reachable'
assert_log_safe "$FIXTURE/watchdog.log"
pass 'first observation is a non-mutating baseline'

# Protected autofs inputs may carry canonical deny-only ACLs such as the
# standard home-directory deny-delete entry. They must never carry an allow
# entry, even when their POSIX modes look safe.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
: > "$FIXTURE/preserve-autofs-fixture"
/bin/chmod +a "everyone deny delete" "$FIXTURE/etc/auto_master" || fail 'could not add deny-only master-map ACL fixture'
/bin/chmod +a "everyone deny delete" "$FIXTURE/etc/auto_smb" || fail 'could not add deny-only selected-map ACL fixture'
run_runtime
/bin/chmod -N "$FIXTURE/etc/auto_master" "$FIXTURE/etc/auto_smb" || fail 'could not clear deny-only map ACL fixtures'
[ "$RUNTIME_RC" -eq 0 ] || fail "deny-only autofs ACL baseline exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'state|mounted-reachable'
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'canonical deny-only ACLs are accepted on protected autofs inputs'

drop_fixture
new_fixture
write_one_config
write_expected_media_mount
: > "$FIXTURE/preserve-autofs-fixture"
/bin/chmod +a "everyone allow write" "$FIXTURE/etc/auto_master" || fail 'could not add allow ACL fixture'
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$RUNTIME" > "$FIXTURE/allow-master.out" 2>&1
RUNTIME_RC=$?
/bin/chmod -N "$FIXTURE/etc/auto_master" || fail 'could not clear allow ACL fixture'
[ "$RUNTIME_RC" -eq 2 ] || fail "allow-ACL master-map drift exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'action_state|configuration-drift'
assert_contains "$FIXTURE/state/Media/status" 'last_error|autofs-master-map-invalid'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'write-capable allow ACLs on protected autofs inputs fail closed'

# Runtime-owned state is created without ACLs and any later ACL is treated as
# untrusted managed state by both the watchdog and cached status command.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "ACL-free state creation exited $RUNTIME_RC"
for mw_acl_path in "$FIXTURE/state" "$FIXTURE/state/Media" \
  "$FIXTURE/state/Media/status" "$FIXTURE/state/heartbeat"; do
  /bin/ls -lde "$mw_acl_path" 2>/dev/null | /usr/bin/awk 'NR > 1 { exit 1 }' || fail "managed runtime node inherited an ACL: $mw_acl_path"
done
/bin/chmod +a "everyone allow write" "$FIXTURE/state" || fail 'could not add managed-state ACL fixture'
: > "$FIXTURE/actions.log"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$RUNTIME" > "$FIXTURE/acl-state-runtime.out" 2>&1
RUNTIME_RC=$?
[ "$RUNTIME_RC" -eq 70 ] || fail "ACL-bearing state root runtime exited $RUNTIME_RC"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/acl-state-status.out" 2>&1
STATUS_RC=$?
/bin/chmod -N "$FIXTURE/state" || fail 'could not clear managed-state ACL fixture'
[ "$STATUS_RC" -eq 3 ] || fail "ACL-bearing state root status exited $STATUS_RC"
assert_contains "$FIXTURE/acl-state-status.out" 'state_cache=unsafe mount=state-root'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'runtime-owned state is ACL-free and later ACLs fail closed'

# A macOS update-restored stock master map no longer reaches auto_smb. The
# watchdog reports drift before even taking a mount snapshot or probing a host.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
{
  printf '+auto_master\n'
  printf '/home auto_home -nobrowse,hidefromfinder\n'
  printf '/Network/Servers -fstab\n'
  printf '/- -static\n'
} > "$FIXTURE/etc/auto_master"
: > "$FIXTURE/preserve-autofs-fixture"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$RUNTIME" > "$FIXTURE/stock-master.out" 2>&1
RUNTIME_RC=$?
[ "$RUNTIME_RC" -eq 2 ] || fail "stock-master drift exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'action_state|configuration-drift'
assert_contains "$FIXTURE/state/Media/status" 'last_error|autofs-hook-missing'
assert_contains "$FIXTURE/state/heartbeat" 'result|configuration-drift'
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/stock-master-status.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 2 ] || fail "stock-master drift status exited $STATUS_RC"
assert_contains "$FIXTURE/stock-master-status.out" 'heartbeat_phase=complete heartbeat_result=configuration-drift'
assert_contains "$FIXTURE/stock-master-status.out" 'pending_recovery=none action_state=configuration-drift'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'update-restored stock auto_master fails closed before observation or recovery'

# The selected file map must still exist after the master hook is proven.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
/bin/rm -f "$FIXTURE/etc/auto_smb"
: > "$FIXTURE/preserve-autofs-fixture"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$RUNTIME" > "$FIXTURE/missing-map.out" 2>&1
RUNTIME_RC=$?
[ "$RUNTIME_RC" -eq 2 ] || fail "missing auto_smb drift exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'action_state|configuration-drift'
assert_contains "$FIXTURE/state/Media/status" 'last_error|autofs-selected-map-missing'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'missing selected auto_smb map fails closed'

# Malformed master-map syntax is distinct from a cleanly missing hook.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
printf '/- auto_smb definitely-not-an-option\n' > "$FIXTURE/etc/auto_master"
: > "$FIXTURE/preserve-autofs-fixture"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$RUNTIME" > "$FIXTURE/malformed-master.out" 2>&1
RUNTIME_RC=$?
[ "$RUNTIME_RC" -eq 2 ] || fail "malformed auto_master drift exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'last_error|autofs-master-map-invalid'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'malformed auto_master fails closed as configuration drift'

# Map parse failures never echo the raw credential-bearing record.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
printf '/Users/testuser/Media -fstype=smb,soft ://fixture-user:MalformedMapSecret@192.0.2.10/Media extra\n' > "$FIXTURE/etc/auto_smb"
: > "$FIXTURE/preserve-autofs-fixture"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$RUNTIME" > "$FIXTURE/malformed-map.out" 2>&1
RUNTIME_RC=$?
[ "$RUNTIME_RC" -eq 2 ] || fail "malformed auto_smb drift exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'last_error|autofs-selected-map-invalid'
if /usr/bin/grep -R -Fq 'MalformedMapSecret' "$FIXTURE/malformed-map.out" "$FIXTURE/watchdog.log" "$FIXTURE/state"; then
  fail 'malformed auto_smb exposed credential material'
fi
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'malformed auto_smb is rejected without leaking credentials'

# A valid credential-bearing map can authorize the existing recovery path, but
# only the sanitized tuple is compared and persisted.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
printf '/Users/testuser/Media -fstype=smb,soft,noowners,nosuid ://fixture-user:DetectionSecret%%21@192.0.2.10/Media\n' > "$FIXTURE/etc/auto_smb"
: > "$FIXTURE/preserve-autofs-fixture"
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
printf '1\n' > "$FIXTURE/umount.exit"
printf 'umount: Resource busy\n' > "$FIXTURE/umount.stderr"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$RUNTIME" > "$FIXTURE/valid-map.out" 2>&1
RUNTIME_RC=$?
[ "$RUNTIME_RC" -eq 1 ] || fail "valid map recovery exited $RUNTIME_RC"
assert_contains "$FIXTURE/actions.log" 'umount|/Users/testuser/Media'
assert_contains "$FIXTURE/state/Media/status" 'action_state|unmount-required'
if /usr/bin/grep -R -Fq 'DetectionSecret' "$FIXTURE/valid-map.out" "$FIXTURE/watchdog.log" "$FIXTURE/state"; then
  fail 'valid auto_smb detection exposed credential material'
fi
assert_not_action "$FIXTURE/actions.log" automount
pass 'valid selected map detection remains credential-safe'

# A narrow, well-formed static NFS target may coexist when it is structurally
# disjoint from every selected SMB path. Its source is never reported.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
printf 'private-server:/RuntimeFstabSecret /Users/testuser/Developer/mnt/docker nfs rw,resvport 0 0\n' > "$FIXTURE/etc/fstab"
: > "$FIXTURE/preserve-autofs-fixture"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$RUNTIME" > "$FIXTURE/disjoint-fstab.out" 2>&1
RUNTIME_RC=$?
[ "$RUNTIME_RC" -eq 0 ] || fail "disjoint fstab runtime exited $RUNTIME_RC"
if /usr/bin/grep -R -Fq 'RuntimeFstabSecret' "$FIXTURE/disjoint-fstab.out" "$FIXTURE/watchdog.log" "$FIXTURE/state"; then
  fail 'disjoint fstab validation exposed private source material'
fi
pass 'disjoint static fstab target remains supported and credential-safe'

# An overlapping static direct target is configuration drift, not an outage.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
printf 'private-server:/OverlapFstabSecret /Users/testuser/Media nfs rw 0 0\n' > "$FIXTURE/etc/fstab"
: > "$FIXTURE/preserve-autofs-fixture"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$RUNTIME" > "$FIXTURE/overlap-fstab.out" 2>&1
RUNTIME_RC=$?
[ "$RUNTIME_RC" -eq 2 ] || fail "overlapping fstab drift exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'action_state|configuration-drift'
assert_contains "$FIXTURE/state/Media/status" 'last_error|autofs-static-map-conflict'
if /usr/bin/grep -R -Fq 'OverlapFstabSecret' "$FIXTURE/overlap-fstab.out" "$FIXTURE/watchdog.log" "$FIXTURE/state"; then
  fail 'overlapping fstab validation exposed private source material'
fi
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'overlapping static fstab target fails closed as configuration drift'

# Malformed fstab data also fails before any observation without echoing the
# source field that may contain private infrastructure details.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
printf 'private-server:/MalformedRuntimeFstabSecret /Users/testuser/Developer/mnt/docker nfs defaults 0 0\n' > "$FIXTURE/etc/fstab"
: > "$FIXTURE/preserve-autofs-fixture"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$RUNTIME" > "$FIXTURE/malformed-fstab.out" 2>&1
RUNTIME_RC=$?
[ "$RUNTIME_RC" -eq 2 ] || fail "malformed fstab drift exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'last_error|autofs-static-map-invalid'
if /usr/bin/grep -R -Fq 'MalformedRuntimeFstabSecret' "$FIXTURE/malformed-fstab.out" "$FIXTURE/watchdog.log" "$FIXTURE/state"; then
  fail 'malformed fstab validation exposed private source material'
fi
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'malformed static fstab fails closed without source leakage'

# Revalidation closes the gap between initial observation and a normal unmount.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
{
  printf '+auto_master\n'
  printf '/home auto_home -nobrowse,hidefromfinder\n'
  printf '/Network/Servers -fstab\n'
  printf '/- -static\n'
} > "$FIXTURE/auto_master.after_mount.1"
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "pre-unmount map drift exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'action_state|configuration-drift'
assert_contains "$FIXTURE/state/Media/status" 'last_error|autofs-hook-missing'
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'master-map drift discovered before unmount blocks the action'

# The same last-moment guard covers a newly overlapping -static target.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
printf 'private-server:/ChangedFstabSecret /Users/testuser/Media nfs rw 0 0\n' > "$FIXTURE/fstab.after_mount.1"
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "pre-unmount fstab drift exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'action_state|configuration-drift'
assert_contains "$FIXTURE/state/Media/status" 'last_error|autofs-static-map-conflict'
if /usr/bin/grep -R -Fq 'ChangedFstabSecret' "$FIXTURE/watchdog.log" "$FIXTURE/state"; then
  fail 'pre-action fstab drift exposed private source material'
fi
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'static-map drift discovered before unmount blocks the action'

# Refresh-only recovery has an independent last-moment map validation.
drop_fixture
new_fixture
write_one_config
: > "$FIXTURE/mount.output"
{
  printf '+auto_master\n'
  printf '/home auto_home -nobrowse,hidefromfinder\n'
  printf '/Network/Servers -fstab\n'
  printf '/- -static\n'
} > "$FIXTURE/auto_master.after_mount.1"
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "pre-refresh map drift exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'action_state|configuration-drift'
assert_contains "$FIXTURE/state/Media/status" 'last_error|autofs-hook-missing'
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'master-map drift discovered before refresh blocks automount -c'

# Status never presents cached observations from different runtime inputs as current.
printf 'changed-version\n' > "$FIXTURE/VERSION"
: > "$FIXTURE/actions.log"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-mismatch.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 1 ] || fail "input-mismatch status exited $STATUS_RC"
assert_contains "$FIXTURE/status-mismatch.out" 'heartbeat=input-mismatch'
assert_contains "$FIXTURE/status-mismatch.out" 'state=input-mismatch pending_recovery=unknown action_state=stale'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'status reports changed inputs as stale without running a tick'

# Cached status must reject corrupted core identity and lifecycle fields.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "status-schema baseline exited $RUNTIME_RC"
/usr/bin/sed 's/^action_state|idle$/action_state|forged/' \
  "$FIXTURE/state/Media/status" > "$FIXTURE/state/Media/status.changed"
/bin/mv "$FIXTURE/state/Media/status.changed" "$FIXTURE/state/Media/status"
: > "$FIXTURE/actions.log"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-invalid-core.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 3 ] || fail "invalid core status exited $STATUS_RC"
assert_contains "$FIXTURE/status-invalid-core.out" 'state=unsafe pending_recovery=unknown action_state=manual-attention'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'status rejects corrupted cached identity and lifecycle fields'

# A mount-cache write failure remains the terminal result even when the same
# tick also reaches manual attention for an unexpected layer.
drop_fixture
new_fixture
write_one_config
printf '//guest@192.0.2.10/WrongShare on /Users/testuser/Media (smbfs, nodev)\n' > "$FIXTURE/mount.output"
: > "$FIXTURE/fail-mount-status-write"
run_runtime
[ "$RUNTIME_RC" -eq 70 ] || fail "mixed manual/write failure exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/heartbeat" 'result|state-write-error'
[ ! -e "$FIXTURE/state/Media/status" ] || fail 'injected mount status write unexpectedly succeeded'
: > "$FIXTURE/actions.log"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-heartbeat-error.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 3 ] || fail "failed-heartbeat status exited $STATUS_RC"
assert_contains "$FIXTURE/status-heartbeat-error.out" 'heartbeat_phase=complete heartbeat_result=state-write-error'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'terminal state-write errors outrank simultaneous manual attention'

# Any unexpected internal exit after the running heartbeat gets a terminal
# internal-error heartbeat instead of leaving a permanent in-progress record.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media reachable mounted-reachable
{
  printf 'format|1\n'
  printf 'runtime_fingerprint|%s\n' "$mw_seed_fingerprint"
  printf 'last_attempt_epoch|900\n'
  printf 'last_result|invalid\n'
  printf 'last_exit_status|0\n'
} > "$FIXTURE/state/autofs-refresh"
run_runtime
[ "$RUNTIME_RC" -eq 70 ] || fail "internal refresh-record failure exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/heartbeat" 'phase|complete'
assert_contains "$FIXTURE/state/heartbeat" 'result|internal-error'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-internal-error.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 3 ] || fail "internal-error status exited $STATUS_RC"
assert_contains "$FIXTURE/status-internal-error.out" 'heartbeat_phase=complete heartbeat_result=internal-error'
pass 'unexpected tick exits commit a terminal internal-error heartbeat'

# A signal immediately after the running heartbeat becomes durable must still
# replace it with a terminal interrupted heartbeat before the process exits.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
: > "$FIXTURE/signal-after-running-heartbeat"
run_runtime
[ "$RUNTIME_RC" -eq 143 ] || fail "post-heartbeat signal exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/heartbeat" 'phase|complete'
assert_contains "$FIXTURE/state/heartbeat" 'result|interrupted'
[ ! -e "$FIXTURE/state/.tick.lock" ] || fail 'post-heartbeat signal retained the runtime lock'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'post-heartbeat signals commit a terminal interrupted heartbeat'

# Inherited xtrace is disabled before configuration or cached state is parsed.
drop_fixture
new_fixture
printf 'TraceSlot\t/Users/trace-secret/TraceSlot\t198.51.100.77\tTraceShare\n' > "$FIXTURE/mounts.conf"
write_fixture_autofs
{
  printf 'map auto_smb on /Users/trace-secret/TraceSlot (autofs, automounted, nobrowse)\n'
  printf '//trace-user@198.51.100.77/TraceShare on /Users/trace-secret/TraceSlot (smbfs, nodev)\n'
} > "$FIXTURE/mount.output"
printf 'reachable\n' > "$FIXTURE/network/198.51.100.77"
/usr/bin/env SHELLOPTS=xtrace "MW_TEST_ROOT=$FIXTURE" "MW_TEST_COMMAND_DIR=$COMMANDS" \
  /bin/bash "$RUNTIME" > "$FIXTURE/xtrace-runtime.out" 2> "$FIXTURE/xtrace.err"
XTRACE_RC=$?
[ "$XTRACE_RC" -eq 0 ] || fail "inherited-xtrace runtime exited $XTRACE_RC"
/usr/bin/env SHELLOPTS=xtrace "MW_TEST_ROOT=$FIXTURE" "MW_TEST_COMMAND_DIR=$COMMANDS" \
  /bin/bash "$STATUS" --status > "$FIXTURE/xtrace-status.out" 2>> "$FIXTURE/xtrace.err"
XTRACE_RC=$?
[ "$XTRACE_RC" -eq 0 ] || fail "inherited-xtrace status exited $XTRACE_RC"
[ "$(/usr/bin/grep -c '^+ set +x$' "$FIXTURE/xtrace.err")" -eq 2 ] || fail 'xtrace was not active at both entrypoint boundaries'
for mw_trace_secret in TraceSlot trace-secret TraceShare 198.51.100.77 trace-user; do
  if /usr/bin/grep -Fq "$mw_trace_secret" "$FIXTURE/xtrace.err" ||
    /usr/bin/grep -Fq "$mw_trace_secret" "$FIXTURE/watchdog.log"; then
    fail "inherited xtrace leaked '$mw_trace_secret' to stderr or log"
  fi
done
pass 'inherited xtrace cannot expose configuration through stderr or logs'

# A changed config/version fingerprint cannot replay old transition state.
drop_fixture
new_fixture
printf 'Media\t/Users/testuser/Media\t192.0.2.10\tOldShare\n' > "$FIXTURE/mounts.conf"
seed_state Media /Users/testuser/Media 192.0.2.10 OldShare unreachable
write_one_config
write_expected_media_mount
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "fingerprint reset exited $RUNTIME_RC"
assert_not_action "$FIXTURE/actions.log" umount
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|none'
pass 'config fingerprint change establishes a fresh baseline'

# A cache keyed only by config/defaults/VERSION is stale after a same-version
# code upgrade and cannot authorize transition replay.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
mw_stale_code_blind_fingerprint=${mw_seed_config_sum%% *}-${mw_seed_defaults_sum%% *}-${mw_seed_version_sum%% *}
/usr/bin/sed \
  -e "s@^runtime_fingerprint|$mw_seed_fingerprint\$@runtime_fingerprint|$mw_stale_code_blind_fingerprint@" \
  "$FIXTURE/state/Media/status" > "$FIXTURE/state/Media/status.code-blind"
/bin/mv "$FIXTURE/state/Media/status.code-blind" "$FIXTURE/state/Media/status"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "code-identity fingerprint reset exited $RUNTIME_RC"
assert_not_action "$FIXTURE/actions.log" umount
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|none'
if /usr/bin/grep -Fxq "runtime_fingerprint|$mw_stale_code_blind_fingerprint" "$FIXTURE/state/Media/status"; then
  fail 'runtime preserved a code-blind state fingerprint'
fi
pass 'same-version code identity changes establish a fresh baseline'

# A fresh SMB session is not recovery for an outage observed at trigger-only.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable trigger-only trigger-only
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "fresh SMB observation exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|none'
assert_contains "$FIXTURE/state/Media/status" 'state|mounted-reachable'
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'trigger-only outage followed by fresh SMB access is non-disruptive'

# A long scheduling delay is a heuristic reason only for a previously mounted layer.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media reachable mounted-reachable expected-smb
{
  printf 'format|1\n'
  printf 'phase|complete\n'
  printf 'started_epoch|790\n'
  printf 'completed_epoch|800\n'
  printf 'checked_at|2026-08-30T00:00:00Z\n'
  printf 'runtime_fingerprint|%s\n' "$mw_seed_fingerprint"
  printf 'result|ok\n'
} > "$FIXTURE/state/heartbeat"
printf '1\n' > "$FIXTURE/umount.exit"
printf 'umount: Resource busy\n' > "$FIXTURE/umount.stderr"
run_runtime
[ "$RUNTIME_RC" -eq 1 ] || fail "scheduling-gap recovery exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|scheduling-gap'
assert_contains "$FIXTURE/state/Media/status" 'action_state|unmount-required'
assert_contains "$FIXTURE/actions.log" 'umount|/Users/testuser/Media'
pass 'scheduling gaps remain explicit heuristic recovery reasons'

# A wall-clock rollback cannot turn old unreachable state into a recovery edge.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
{
  printf 'format|1\n'
  printf 'phase|complete\n'
  printf 'started_epoch|900\n'
  printf 'completed_epoch|1000\n'
  printf 'checked_at|2026-08-30T00:00:00Z\n'
  printf 'runtime_fingerprint|%s\n' "$mw_seed_fingerprint"
  printf 'result|ok\n'
} > "$FIXTURE/state/heartbeat"
{
  printf 'format|1\n'
  printf 'runtime_fingerprint|%s\n' "$mw_seed_fingerprint"
  printf 'attempt_epoch|1000\n'
  printf 'action|normal-unmount\n'
  printf 'phase|attempting\n'
  printf 'result|attempting\n'
  printf 'exit_status|unknown\n'
  printf 'pending_recovery|network-restored\n'
  printf 'refresh_required|1\n'
} > "$FIXTURE/state/Media/unmount-attempt"
/bin/chmod 600 "$FIXTURE/state/Media/unmount-attempt"
printf '500\n' > "$FIXTURE/now"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "clock rollback baseline exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|none'
assert_contains "$FIXTURE/state/Media/status" 'last_network_state|reachable'
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
[ ! -e "$FIXTURE/state/Media/unmount-attempt" ] || fail 'future unmount journal survived clock reset'
pass 'clock rollback resets transition history to a safe baseline'

# Future global cooldown timestamps are ignored after a wall-clock rollback.
drop_fixture
new_fixture
write_one_config
: > "$FIXTURE/mount.output"
seed_state Media /Users/testuser/Media 192.0.2.10 Media reachable
{
  printf 'format|1\n'
  printf 'phase|complete\n'
  printf 'started_epoch|900\n'
  printf 'completed_epoch|1000\n'
  printf 'checked_at|2026-08-30T00:00:00Z\n'
  printf 'runtime_fingerprint|%s\n' "$mw_seed_fingerprint"
  printf 'result|ok\n'
} > "$FIXTURE/state/heartbeat"
{
  printf 'format|1\n'
  printf 'last_attempt_epoch|1000\n'
  printf 'last_result|failed\n'
} > "$FIXTURE/state/autofs-refresh"
printf '500\n' > "$FIXTURE/now"
printf 'map auto_smb on /Users/testuser/Media (autofs, automounted, nobrowse)\n' > "$FIXTURE/mount.after_automount"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "rollback global cooldown exited $RUNTIME_RC"
[ "$(/usr/bin/grep -c '^automount|' "$FIXTURE/actions.log")" -eq 1 ] || fail 'future global cooldown suppressed rollback recovery'
assert_contains "$FIXTURE/state/Media/status" 'last_successful_action|autofs-refresh'
pass 'clock rollback clears future global refresh cooldown state'

# Unsupported state formats fail closed without replaying recovery.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
/bin/mkdir -p "$FIXTURE/state/Media"
printf 'state=healthy-mounted\nchecked_at=unsupported\n' > "$FIXTURE/state/Media/status"
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "unsupported state exited $RUNTIME_RC"
assert_not_action "$FIXTURE/actions.log" umount
assert_contains "$FIXTURE/state/Media/status" 'format|1'
assert_contains "$FIXTURE/state/Media/status" 'action_state|manual-attention'
pass 'unsupported regular state fails closed without replaying recovery'

# Incomplete current-format state also fails closed.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
/usr/bin/sed '/^last_attempt_exit_status|/d' "$FIXTURE/state/Media/status" > "$FIXTURE/state/Media/status.old"
/bin/mv "$FIXTURE/state/Media/status.old" "$FIXTURE/state/Media/status"
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "incomplete current-format state exited $RUNTIME_RC"
assert_not_action "$FIXTURE/actions.log" umount
assert_contains "$FIXTURE/state/Media/status" 'action_state|manual-attention'
pass 'incomplete current-format state fails closed without recovery'

# A live lock with an unknown start token is never removed on PID evidence alone.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
/bin/mkdir -p "$FIXTURE/state/.tick.lock"
{
  printf 'format|1\n'
  printf 'pid|%s\n' "$$"
  printf 'process_token|unknown\n'
} > "$FIXTURE/state/.tick.lock/owner"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "concurrent lock exited $RUNTIME_RC"
[ -d "$FIXTURE/state/.tick.lock" ] || fail 'live unknown-token lock was removed'
assert_not_action "$FIXTURE/actions.log" mount
pass 'unknown-token live lock is treated as busy, not stale'

# Atomic state replacement rejects a pre-existing symlink without clobbering it.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
/bin/mkdir -p "$FIXTURE/state"
printf 'sentinel\n' > "$FIXTURE/symlink-target"
/bin/ln -s "$FIXTURE/symlink-target" "$FIXTURE/state/heartbeat"
: > "$FIXTURE/actions.log"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-unsafe-heartbeat.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 3 ] || fail "symlinked heartbeat status exited $STATUS_RC"
assert_contains "$FIXTURE/status-unsafe-heartbeat.out" 'state_cache=unsafe leaf=heartbeat'
assert_not_action "$FIXTURE/actions.log" launchctl
run_runtime
[ "$RUNTIME_RC" -eq 70 ] || fail "symlinked heartbeat exited $RUNTIME_RC"
assert_contains "$FIXTURE/symlink-target" sentinel
assert_not_action "$FIXTURE/actions.log" mount
pass 'heartbeat symlinks are unsafe in runtime and read-only status'

# Dangling global state leaves are present-but-unsafe and block observation.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
/bin/mkdir -p "$FIXTURE/state"
/bin/ln -s "$FIXTURE/missing-block-record" "$FIXTURE/state/blocked-command"
run_runtime
[ "$RUNTIME_RC" -eq 70 ] || fail "dangling block record exited $RUNTIME_RC"
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
: > "$FIXTURE/actions.log"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-dangling-block.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 3 ] || fail "dangling block-record status exited $STATUS_RC"
assert_contains "$FIXTURE/status-dangling-block.out" 'state_cache=unsafe leaf=blocked-command'
assert_not_action "$FIXTURE/actions.log" launchctl
pass 'dangling blocked-command records fail closed before external commands'

# A dangling per-mount status is not an absent first-run baseline.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
/bin/mkdir -p "$FIXTURE/state/Media"
/bin/ln -s "$FIXTURE/missing-status" "$FIXTURE/state/Media/status"
run_runtime
[ "$RUNTIME_RC" -eq 70 ] || fail "dangling mount status exited $RUNTIME_RC"
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
: > "$FIXTURE/actions.log"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-dangling-status.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 3 ] || fail "dangling mount status report exited $STATUS_RC"
assert_contains "$FIXTURE/status-dangling-status.out" 'state_cache=unsafe leaf=Media/status'
assert_not_action "$FIXTURE/actions.log" launchctl
pass 'dangling per-mount status leaves cannot become a recovery baseline'

# A dangling attempt journal cannot be treated as no previous mutation.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
/bin/ln -s "$FIXTURE/missing-attempt" "$FIXTURE/state/Media/unmount-attempt"
run_runtime
[ "$RUNTIME_RC" -eq 70 ] || fail "dangling unmount journal exited $RUNTIME_RC"
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
: > "$FIXTURE/actions.log"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-dangling-journal.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 3 ] || fail "dangling unmount journal status exited $STATUS_RC"
assert_contains "$FIXTURE/status-dangling-journal.out" 'state_cache=unsafe leaf=Media/unmount-attempt'
assert_not_action "$FIXTURE/actions.log" launchctl
pass 'dangling unmount journals fail closed before observation or recovery'

# The test backend validates its log destination before anything can append.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
OUTSIDE_FILE=$(/usr/bin/mktemp "$TEST_TMP_BASE/mountwatchdog-outside.XXXXXX") || exit 1
printf 'outside-sentinel\n' > "$OUTSIDE_FILE"
/bin/rm -f "$FIXTURE/watchdog.log"
/bin/ln -s "$OUTSIDE_FILE" "$FIXTURE/watchdog.log"
run_runtime
[ "$RUNTIME_RC" -eq 70 ] || fail "symlinked test log exited $RUNTIME_RC"
[ "$(/usr/bin/wc -l < "$OUTSIDE_FILE" | /usr/bin/tr -d ' ')" -eq 1 ] || fail 'outside log sentinel was appended'
assert_contains "$OUTSIDE_FILE" outside-sentinel
assert_not_action "$FIXTURE/actions.log" mount
pass 'test log containment rejects symlinks without touching the target'

# The append-only test log cannot escape containment through a hard link.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
OUTSIDE_FILE=$(/usr/bin/mktemp "$TEST_TMP_BASE/mountwatchdog-outside.XXXXXX") || exit 1
printf 'outside-hardlink-sentinel\n' > "$OUTSIDE_FILE"
/bin/ln "$OUTSIDE_FILE" "$FIXTURE/watchdog.log"
run_runtime
[ "$RUNTIME_RC" -eq 70 ] || fail "hardlinked test log exited $RUNTIME_RC"
[ "$(/usr/bin/wc -l < "$OUTSIDE_FILE" | /usr/bin/tr -d ' ')" -eq 1 ] || fail 'outside hardlink sentinel was appended'
assert_contains "$OUTSIDE_FILE" outside-hardlink-sentinel
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
pass 'test log containment rejects outside hard links before append'

# Executable test adapters must also be unique inodes inside the test root.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
OUTSIDE_FILE=$(/usr/bin/mktemp "$TEST_TMP_BASE/mountwatchdog-outside.XXXXXX") || exit 1
/bin/cp "$STUBS/nc" "$OUTSIDE_FILE"
/bin/chmod 700 "$OUTSIDE_FILE"
/bin/rm -f "$COMMANDS/nc"
/bin/ln "$OUTSIDE_FILE" "$COMMANDS/nc"
run_runtime
[ "$RUNTIME_RC" -eq 70 ] || fail "hardlinked test command exited $RUNTIME_RC"
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
pass 'test command containment rejects outside hard links before execution'

# A writable privileged log is rejected before the watchdog observes anything.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
printf 'unsafe-log\n' > "$FIXTURE/watchdog.log"
/bin/chmod 666 "$FIXTURE/watchdog.log"
run_runtime
[ "$RUNTIME_RC" -eq 70 ] || fail "writable test log exited $RUNTIME_RC"
assert_contains "$FIXTURE/watchdog.log" unsafe-log
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'group/world-writable log destinations fail closed before observation'

# Per-mount state is never followed through an intermediate directory symlink.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
OUTSIDE_DIR=$(/usr/bin/mktemp -d "$TEST_TMP_BASE/mountwatchdog-outside-dir.XXXXXX") || exit 1
/bin/mv "$FIXTURE/state/Media" "$OUTSIDE_DIR/Media"
/bin/ln -s "$OUTSIDE_DIR/Media" "$FIXTURE/state/Media"
run_runtime
[ "$RUNTIME_RC" -eq 70 ] || fail "symlinked mount-state directory exited $RUNTIME_RC"
assert_contains "$OUTSIDE_DIR/Media/status" 'last_network_state|unreachable'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
: > "$FIXTURE/actions.log"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-unsafe-cache.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 3 ] || fail "unsafe cached-state status exited $STATUS_RC"
assert_contains "$FIXTURE/status-unsafe-cache.out" 'state_cache=unsafe mount=Media'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'runtime and status reject intermediate state-directory symlinks'

# A failed mount-table snapshot is an inspection error, never an absent trigger.
drop_fixture
new_fixture
write_one_config
printf '1\n' > "$FIXTURE/mount.exit"
run_runtime
[ "$RUNTIME_RC" -eq 70 ] || fail "failed snapshot exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'state|inspection-error'
assert_contains "$FIXTURE/state/Media/status" 'last_error|mount-inspection-failed'
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
assert_contains "$FIXTURE/watchdog.log" 'event=inspection scope=global action=observe reason=mount-snapshot-failed result=failed'
assert_log_safe "$FIXTURE/watchdog.log"
pass 'failed mount snapshots block recovery without inferring absence'

# A failed first snapshot during a clock reset cannot preserve a stale edge.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
{
  printf 'format|1\n'
  printf 'phase|complete\n'
  printf 'started_epoch|900\n'
  printf 'completed_epoch|1000\n'
  printf 'checked_at|2026-08-30T00:00:00Z\n'
  printf 'runtime_fingerprint|%s\n' "$mw_seed_fingerprint"
  printf 'result|ok\n'
} > "$FIXTURE/state/heartbeat"
printf '500\n' > "$FIXTURE/now"
printf '1\n' > "$FIXTURE/mount.exit"
run_runtime
[ "$RUNTIME_RC" -eq 70 ] || fail "rollback snapshot failure exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|none'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_action|never'
printf '501\n' > "$FIXTURE/now"
printf '0\n' > "$FIXTURE/mount.exit"
: > "$FIXTURE/actions.log"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "post-inspection baseline exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|none'
assert_contains "$FIXTURE/state/Media/status" 'action_state|idle'
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'snapshot failure after reset cannot make stale recovery sticky'

# A trusted blocked-command record is retired after its group is gone.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
/bin/mkdir -p "$FIXTURE/state"
{
  printf 'format|1\n'
  printf 'active|1\n'
  printf 'pid|999999\n'
  printf 'pgid|999999\n'
  printf 'process_token|old-token\n'
  printf 'command|nc\n'
  printf 'recorded_epoch|900\n'
} > "$FIXTURE/state/blocked-command"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-recorded-block.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 2 ] || fail "recorded block with unavailable mount status exited $STATUS_RC"
assert_contains "$FIXTURE/status-recorded-block.out" 'blocked_command=recorded command=nc manual_attention=required'
[ -f "$FIXTURE/state/blocked-command" ] || fail 'read-only status retired a valid dead block record'
: > "$FIXTURE/actions.log"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "dead blocked-command cleanup exited $RUNTIME_RC"
[ ! -e "$FIXTURE/state/blocked-command" ] || fail 'dead blocked-command record was not retired'
: > "$FIXTURE/actions.log"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-retired-block.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 0 ] || fail "retired blocked-command status exited $STATUS_RC"
if /usr/bin/grep -Fq 'blocked_command=recorded' "$FIXTURE/status-retired-block.out"; then
  fail 'status reported a retired blocked-command record'
fi
pass 'dead blocked-command records do not remain stale in status'

# A present blocked-command record has only one valid state: active=1.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
/bin/mkdir -p "$FIXTURE/state"
{
  printf 'format|1\n'
  printf 'pid|999999\n'
  printf 'pgid|999999\n'
  printf 'process_token|missing-active\n'
  printf 'command|nc\n'
  printf 'recorded_epoch|900\n'
} > "$FIXTURE/state/blocked-command"
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "missing-active blocked record exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/heartbeat" 'result|blocked-command-invalid-block-record'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-invalid-block.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 3 ] || fail "missing-active blocked status exited $STATUS_RC"
assert_contains "$FIXTURE/status-invalid-block.out" 'blocked_command=invalid manual_attention=required'
{
  printf 'format|1\n'
  printf 'active|0\n'
  printf 'pid|999999\n'
  printf 'pgid|999999\n'
  printf 'process_token|inactive-is-invalid\n'
  printf 'command|nc\n'
  printf 'recorded_epoch|900\n'
} > "$FIXTURE/state/blocked-command"
: > "$FIXTURE/actions.log"
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "inactive blocked record exited $RUNTIME_RC"
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'malformed blocked-command records fail closed in runtime and status'

# Invalid persisted process identifiers are never presented as a usable block
# record, and their writer-produced heartbeat remains severity 2 after the
# record is removed even when the mount cache is unavailable.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
/bin/mkdir -p "$FIXTURE/state"
{
  printf 'format|1\n'
  printf 'active|1\n'
  printf 'pid|1\n'
  printf 'pgid|1\n'
  printf 'process_token|invalid-identifiers\n'
  printf 'command|nc\n'
  printf 'recorded_epoch|900\n'
} > "$FIXTURE/state/blocked-command"
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "invalid-identifier blocked record exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/heartbeat" 'result|blocked-command-invalid-block-identifiers'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-invalid-identifiers.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 3 ] || fail "invalid-identifier blocked status exited $STATUS_RC"
assert_contains "$FIXTURE/status-invalid-identifiers.out" 'blocked_command=invalid manual_attention=required'
/bin/rm -f "$FIXTURE/state/blocked-command"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-block-heartbeat.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 2 ] || fail "blocked heartbeat with unavailable mount status exited $STATUS_RC"
assert_contains "$FIXTURE/status-block-heartbeat.out" 'heartbeat_phase=complete heartbeat_result=blocked-command-invalid-block-identifiers'
assert_contains "$FIXTURE/status-block-heartbeat.out" 'state=unavailable pending_recovery=unknown action_state=unknown'
pass 'blocked-record schema and severity remain truthful without status mutation'

# A persisted live command group blocks all later observations without being killed.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
set -m
/bin/sleep 60 &
BLOCK_PGID=$!
set +m
/bin/mkdir -p "$FIXTURE/state"
{
  printf 'format|1\n'
  printf 'active|1\n'
  printf 'pid|%s\n' "$BLOCK_PGID"
  printf 'pgid|%s\n' "$BLOCK_PGID"
  printf 'process_token|mismatched-test-token\n'
  printf 'command|nc\n'
  printf 'recorded_epoch|900\n'
} > "$FIXTURE/state/blocked-command"
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "live blocked-command tick exited $RUNTIME_RC"
kill -0 "$BLOCK_PGID" 2>/dev/null || fail 'persisted blocked group was killed from stale state'
assert_contains "$FIXTURE/state/heartbeat" 'result|blocked-command-live-command-group-token-mismatch'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'persisted live command groups gate the tick despite token mismatch'

# A timed-out command is supervised as a process group, including descendants.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
printf 'spawn-timeout\n' > "$FIXTURE/network/192.0.2.10"
{
  printf 'format|1\n'
  printf 'interval_seconds|60\n'
  printf 'scheduling_gap_seconds|120\n'
  printf 'recovery_cooldown_seconds|180\n'
  printf 'command_timeout_seconds|1\n'
} > "$FIXTURE/defaults.conf"
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "descendant timeout tick exited $RUNTIME_RC"
[ -f "$FIXTURE/timeout-child.pid" ] || fail 'timeout stub did not record its child'
IFS= read -r TIMEOUT_CHILD < "$FIXTURE/timeout-child.pid"
case "$TIMEOUT_CHILD" in ''|*[!0-9]*) fail 'timeout stub recorded an invalid child PID' ;; esac
if kill -0 "$TIMEOUT_CHILD" 2>/dev/null; then
  kill -KILL "$TIMEOUT_CHILD" 2>/dev/null || true
  fail 'timed-out command descendant survived process-group cleanup'
fi
assert_contains "$FIXTURE/state/Media/status" 'action_state|manual-attention'
assert_contains "$FIXTURE/state/Media/status" 'last_error|network-probe-timed-out'
assert_contains "$FIXTURE/watchdog.log" 'event=network-probe scope=slot slot=1 action=observe reason=command-timeout result=manual-attention'
assert_log_safe "$FIXTURE/watchdog.log"
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'bounded command timeout terminates the entire descendant group'

# A service-stop signal supervises the currently active command group before exit.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
: > "$FIXTURE/mount.spawn-timeout"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$RUNTIME" &
SIGNAL_RUNTIME_PID=$!
SIGNAL_WAIT=0
while [ ! -f "$FIXTURE/mount-child.pid" ] && kill -0 "$SIGNAL_RUNTIME_PID" 2>/dev/null; do
  [ "$SIGNAL_WAIT" -lt 50 ] || break
  /bin/sleep 0.1
  SIGNAL_WAIT=$((SIGNAL_WAIT + 1))
done
[ -f "$FIXTURE/mount-child.pid" ] || fail 'signal fixture did not start the mount descendant'
IFS= read -r SIGNAL_CHILD < "$FIXTURE/mount-child.pid"
IFS= read -r SIGNAL_GROUP < "$FIXTURE/mount-command.pid"
case "$SIGNAL_CHILD:$SIGNAL_GROUP" in *[!0-9:]*|:|*:) fail 'signal fixture recorded invalid process identifiers' ;; esac
kill -TERM "$SIGNAL_RUNTIME_PID" || fail 'could not signal the staging runtime'
wait "$SIGNAL_RUNTIME_PID"
SIGNAL_RC=$?
SIGNAL_RUNTIME_PID=
[ "$SIGNAL_RC" -eq 143 ] || fail "signaled runtime exited $SIGNAL_RC"
SIGNAL_GROUP_LIVE=0
kill -0 -- "-$SIGNAL_GROUP" 2>/dev/null && SIGNAL_GROUP_LIVE=1
if [ "$SIGNAL_GROUP_LIVE" -eq 1 ] || kill -0 "$SIGNAL_CHILD" 2>/dev/null; then
  SIGNAL_RECORD=$FIXTURE/state/blocked-command
  SIGNAL_RECORD_VALID=1
  [ -f "$SIGNAL_RECORD" ] && [ ! -L "$SIGNAL_RECORD" ] || SIGNAL_RECORD_VALID=0
  /usr/bin/grep -Fqx 'format|1' "$SIGNAL_RECORD" 2>/dev/null || SIGNAL_RECORD_VALID=0
  /usr/bin/grep -Fqx 'active|1' "$SIGNAL_RECORD" 2>/dev/null || SIGNAL_RECORD_VALID=0
  /usr/bin/grep -Fqx "pid|$SIGNAL_GROUP" "$SIGNAL_RECORD" 2>/dev/null || SIGNAL_RECORD_VALID=0
  /usr/bin/grep -Fqx "pgid|$SIGNAL_GROUP" "$SIGNAL_RECORD" 2>/dev/null || SIGNAL_RECORD_VALID=0
  /usr/bin/grep -Eq '^process_token\|[^|]+$' "$SIGNAL_RECORD" 2>/dev/null || SIGNAL_RECORD_VALID=0
  kill -TERM -- "-$SIGNAL_GROUP" 2>/dev/null || true
  /bin/sleep 1
  kill -KILL -- "-$SIGNAL_GROUP" 2>/dev/null || true
  kill -KILL "$SIGNAL_CHILD" 2>/dev/null || true
  [ "$SIGNAL_RECORD_VALID" -eq 1 ] || fail 'surviving signaled group had no valid blocked-command record'
fi
pass 'signal handling cleans or durably records the active process group'

# A signal in the post-fork identifier-capture window retains the preparing guard.
drop_fixture
new_fixture
/bin/mkdir -p "$FIXTURE/state/.tick.lock"
{
  printf 'format|1\n'
  printf 'pid|999999\n'
  printf 'process_token|old-owner\n'
} > "$FIXTURE/state/.tick.lock/owner"
{
  printf 'format|1\n'
  printf 'active|1\n'
  printf 'pid|0\n'
  printf 'pgid|0\n'
  printf 'process_token|unknown\n'
  printf 'command|mount\n'
} > "$FIXTURE/state/.tick.lock/command-guard"
(
  # shellcheck disable=SC1090,SC1091
  . "$PROJECT_DIR/lib/common.sh"
  # shellcheck disable=SC1090,SC1091
  . "$PROJECT_DIR/lib/runtime.sh"
  MW_TEST_MODE=1
  MW_STATE_DIR=$FIXTURE/state
  MW_LOCK_DIR=$FIXTURE/state/.tick.lock
  MW_LOCK_HELD=1
  MW_RETAIN_LOCK=0
  MW_ACTIVE_COMMAND_PID=
  MW_ACTIVE_COMMAND_PGID=
  MW_ACTIVE_COMMAND_TOKEN=
  MW_ACTIVE_COMMAND_NAME=mount
  MW_ACTIVE_COMMAND_PREPARING=1
  mw_terminate_active_command_group
  [ "$?" -eq 1 ] || exit 1
  [ "$MW_RETAIN_LOCK" -eq 1 ] || exit 1
  mw_release_lock
  [ -d "$MW_LOCK_DIR" ] || exit 1
  [ -f "$MW_LOCK_DIR/command-guard" ] || exit 1
) || fail 'identifier-capture signal window released its fail-closed guard'
pass 'signal handling retains a preparing command guard with unknown child IDs'

# An untrappable supervisor crash leaves a durable guard that blocks overlap.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
: > "$FIXTURE/mount.spawn-timeout"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$RUNTIME" &
SIGNAL_RUNTIME_PID=$!
SIGNAL_WAIT=0
while [ ! -f "$FIXTURE/mount-command.pid" ] && kill -0 "$SIGNAL_RUNTIME_PID" 2>/dev/null; do
  [ "$SIGNAL_WAIT" -lt 50 ] || break
  /bin/sleep 0.1
  SIGNAL_WAIT=$((SIGNAL_WAIT + 1))
done
[ -f "$FIXTURE/mount-command.pid" ] || fail 'crash fixture did not start the guarded command'
IFS= read -r CRASH_GROUP < "$FIXTURE/mount-command.pid"
case "$CRASH_GROUP" in ''|*[!0-9]*) fail 'crash fixture recorded an invalid group' ;; esac
BLOCK_PGID=$CRASH_GROUP
kill -KILL "$SIGNAL_RUNTIME_PID" || fail 'could not kill the staging supervisor'
wait "$SIGNAL_RUNTIME_PID" 2>/dev/null
CRASH_RC=$?
SIGNAL_RUNTIME_PID=
[ "$CRASH_RC" -eq 137 ] || fail "killed supervisor exited $CRASH_RC"
assert_contains "$FIXTURE/state/.tick.lock/command-guard" 'active|1'
assert_contains "$FIXTURE/state/.tick.lock/command-guard" "pgid|$CRASH_GROUP"
printf 'mismatched-after-crash\n' > "$FIXTURE/ps.token"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "guarded replacement tick exited $RUNTIME_RC"
[ "$(/usr/bin/grep -c '^mount$' "$FIXTURE/actions.log")" -eq 1 ] || fail 'replacement tick overlapped the guarded command'
kill -0 -- "-$CRASH_GROUP" 2>/dev/null || fail 'replacement tick altered the persisted live group'
pass 'active command guard survives SIGKILL and blocks a replacement tick'

# If survivor persistence fails, the prewritten guard retains the tick lock.
drop_fixture
new_fixture
/bin/mkdir -p "$FIXTURE/state/.tick.lock"
{
  printf 'format|1\n'
  printf 'pid|999999\n'
  printf 'process_token|old-owner\n'
} > "$FIXTURE/state/.tick.lock/owner"
{
  printf 'format|1\n'
  printf 'active|1\n'
  printf 'pid|424242\n'
  printf 'pgid|424242\n'
  printf 'process_token|guard-token\n'
  printf 'command|mount\n'
} > "$FIXTURE/state/.tick.lock/command-guard"
(
  # shellcheck disable=SC1090,SC1091
  . "$PROJECT_DIR/lib/common.sh"
  # shellcheck disable=SC1090,SC1091
  . "$PROJECT_DIR/lib/runtime.sh"
  MW_TEST_MODE=1
  MW_STATE_DIR=$FIXTURE/state
  MW_LOCK_DIR=$FIXTURE/state/.tick.lock
  MW_LOCK_HELD=1
  MW_RETAIN_LOCK=0
  MW_BLOCK_PERSIST_FAILED=0
  MW_ACTIVE_COMMAND_PID=424242
  MW_ACTIVE_COMMAND_PGID=424242
  MW_ACTIVE_COMMAND_TOKEN=guard-token
  MW_ACTIVE_COMMAND_NAME=mount
  MW_NOW_EPOCH=1000
  mw_group_is_live() { return 0; }
  mw_persist_blocked_command() { return 1; }
  mw_log_global_event() { return 0; }
  kill() { return 0; }
  mw_terminate_active_command_group
  [ "$?" -eq 1 ] || exit 1
  [ "$MW_RETAIN_LOCK" -eq 1 ] || exit 1
  [ "$MW_BLOCK_PERSIST_FAILED" -eq 1 ] || exit 1
  mw_release_lock
  [ -d "$MW_LOCK_DIR" ] || exit 1
  MW_LOCK_HELD=0
  kill() { case "${2:-}" in -*) return 0 ;; *) return 1 ;; esac; }
  mw_acquire_lock
  [ "$?" -eq 75 ] || exit 1
) || fail 'failed blocked-command persistence did not retain a fail-closed lock'
[ -d "$FIXTURE/state/.tick.lock" ] || fail 'fail-closed lock was released after persistence failure'
assert_contains "$FIXTURE/state/.tick.lock/command-guard" 'active|1'
pass 'survivor persistence failure retains a durable no-overlap guard'

# A failed unmount leaves durable pending intent and the attempt cooldown stops a storm.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
printf '1\n' > "$FIXTURE/umount.exit"
printf 'umount: Resource busy\n' > "$FIXTURE/umount.stderr"
run_runtime
[ "$RUNTIME_RC" -eq 1 ] || fail "failed unmount exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|network-restored'
assert_contains "$FIXTURE/state/Media/status" 'action_state|unmount-required'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_result|busy'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_exit_status|1'
assert_contains "$FIXTURE/state/Media/status" 'last_error|normal-unmount-busy'
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-unmount-exit.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 1 ] || fail "failed-unmount status exited $STATUS_RC"
assert_contains "$FIXTURE/status-unmount-exit.out" 'last_attempt_exit_status=1'
assert_contains "$FIXTURE/watchdog.log" 'event=recovery-action scope=slot slot=1 action=normal-unmount reason=resource-busy result=busy'
assert_log_safe "$FIXTURE/watchdog.log"
[ "$(/usr/bin/grep -c '^umount|' "$FIXTURE/actions.log")" -eq 1 ] || fail 'normal unmount was not attempted once'
assert_contains "$FIXTURE/actions.log" 'umount|/Users/testuser/Media'
printf '1060\n' > "$FIXTURE/now"
: > "$FIXTURE/actions.log"
run_runtime
[ "$RUNTIME_RC" -eq 1 ] || fail "cooldown tick exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|network-restored'
assert_contains "$FIXTURE/state/Media/status" 'action_state|deferred-cooldown'
assert_contains "$FIXTURE/state/Media/status" 'last_error|normal-unmount-busy'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_exit_status|1'
assert_not_action "$FIXTURE/actions.log" umount
pass 'pending recovery survives failure and is attempt-rate-limited'

# The unmount attempt is durable before mutation, even if the supervisor dies.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
: > "$FIXTURE/umount.kill-supervisor"
run_runtime
[ "$RUNTIME_RC" -eq 137 ] || fail "crashed unmount supervisor exited $RUNTIME_RC"
[ -f "$FIXTURE/state/Media/unmount-attempt" ] || fail 'unmount mutation had no durable attempt journal'
assert_contains "$FIXTURE/state/Media/unmount-attempt" 'phase|attempting'
assert_contains "$FIXTURE/state/Media/unmount-attempt" 'attempt_epoch|1000'
assert_contains "$FIXTURE/state/Media/unmount-attempt" 'exit_status|unknown'
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-unmount-journal.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 1 ] || fail "unfinalized unmount status exited $STATUS_RC"
assert_contains "$FIXTURE/status-unmount-journal.out" 'pending_recovery=network-restored action_state=refresh-required'
assert_contains "$FIXTURE/status-unmount-journal.out" 'durable_unmount_attempt=attempting'
assert_contains "$FIXTURE/status-unmount-journal.out" 'durable_unmount_refresh=required'
assert_contains "$FIXTURE/status-unmount-journal.out" 'last_attempt_exit_status=unknown'
/bin/rm -f "$FIXTURE/umount.kill-supervisor"
: > "$FIXTURE/actions.log"
run_runtime
[ "$RUNTIME_RC" -eq 1 ] || fail "post-crash cooldown tick exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_action|normal-unmount'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_result|attempting'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_exit_status|unknown'
assert_contains "$FIXTURE/state/Media/status" 'action_state|deferred-cooldown'
assert_not_action "$FIXTURE/actions.log" umount
[ ! -e "$FIXTURE/state/Media/unmount-attempt" ] || fail 'committed unmount journal was not retired'
pass 'pre-action journal prevents immediate repeat after supervisor crash'

# If an unmount supervisor dies with the expected SMB layer still present,
# the attempting journal must not consume an already-persisted recovery edge.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media reachable mounted-reachable
/usr/bin/sed \
  -e 's/^pending_recovery|none$/pending_recovery|network-restored/' \
  -e 's/^pending_since_epoch|0$/pending_since_epoch|800/' \
  "$FIXTURE/state/Media/status" > "$FIXTURE/state/Media/status.pending"
/bin/mv "$FIXTURE/state/Media/status.pending" "$FIXTURE/state/Media/status"
: > "$FIXTURE/umount.kill-supervisor"
run_runtime
[ "$RUNTIME_RC" -eq 137 ] || fail "persisted-pending unmount crash exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/unmount-attempt" 'phase|attempting'
assert_contains "$FIXTURE/state/Media/unmount-attempt" 'pending_recovery|network-restored'
/bin/rm -f "$FIXTURE/umount.kill-supervisor"
: > "$FIXTURE/actions.log"
run_runtime
[ "$RUNTIME_RC" -eq 1 ] || fail "persisted-pending crash continuation exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|network-restored'
assert_contains "$FIXTURE/state/Media/status" 'action_state|deferred-cooldown'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_result|attempting'
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
[ ! -e "$FIXTURE/state/Media/unmount-attempt" ] || fail 'persisted pending journal was not retired after state commit'
pass 'attempting journals retain an already-persisted recovery edge'

# A writer-produced complete journal remains valid until status commits it.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
{
  printf 'format|1\n'
  printf 'runtime_fingerprint|%s\n' "$mw_seed_fingerprint"
  printf 'attempt_epoch|950\n'
  printf 'action|normal-unmount\n'
  printf 'phase|complete\n'
  printf 'result|busy\n'
  printf 'exit_status|1\n'
  printf 'pending_recovery|network-restored\n'
  printf 'refresh_required|0\n'
} > "$FIXTURE/state/Media/unmount-attempt"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-complete-journal.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 1 ] || fail "valid complete journal status exited $STATUS_RC"
assert_contains "$FIXTURE/status-complete-journal.out" 'pending_recovery=network-restored action_state=unmount-required'
assert_contains "$FIXTURE/status-complete-journal.out" 'last_attempt=normal-unmount last_attempt_result=busy last_error=normal-unmount-busy'
assert_contains "$FIXTURE/status-complete-journal.out" 'last_attempt_exit_status=1'
assert_contains "$FIXTURE/status-complete-journal.out" 'durable_unmount_attempt=complete'
: > "$FIXTURE/actions.log"
run_runtime
[ "$RUNTIME_RC" -eq 1 ] || fail "complete journal cooldown exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_result|busy'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_exit_status|1'
assert_contains "$FIXTURE/state/Media/status" 'action_state|deferred-cooldown'
assert_not_action "$FIXTURE/actions.log" umount
[ ! -e "$FIXTURE/state/Media/unmount-attempt" ] || fail 'committed complete journal was not retired'
pass 'complete unmount journals survive the final-status failure window'

# A conflicting equal-epoch journal is writer-impossible and fails closed.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
/usr/bin/sed \
  -e 's/^checked_at_epoch|900$/checked_at_epoch|950/' \
  -e 's/^last_attempt_epoch|0$/last_attempt_epoch|950/' \
  -e 's/^last_attempt_action|never$/last_attempt_action|recovery-validation/' \
  -e 's/^last_attempt_result|never$/last_attempt_result|inspection-failed/' \
  "$FIXTURE/state/Media/status" > "$FIXTURE/state/Media/status.equal"
/bin/mv "$FIXTURE/state/Media/status.equal" "$FIXTURE/state/Media/status"
{
  printf 'format|1\n'
  printf 'runtime_fingerprint|%s\n' "$mw_seed_fingerprint"
  printf 'attempt_epoch|950\n'
  printf 'action|normal-unmount\n'
  printf 'phase|complete\n'
  printf 'result|busy\n'
  printf 'exit_status|1\n'
  printf 'pending_recovery|network-restored\n'
  printf 'refresh_required|0\n'
} > "$FIXTURE/state/Media/unmount-attempt"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-equal-journal.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 3 ] || fail "equal-epoch journal status exited $STATUS_RC"
assert_contains "$FIXTURE/status-equal-journal.out" 'pending_recovery=none action_state=manual-attention'
assert_contains "$FIXTURE/status-equal-journal.out" 'last_attempt=recovery-validation last_attempt_result=inspection-failed last_error=unmount-attempt-not-finalized last_attempt_exit_status=not-run'
assert_contains "$FIXTURE/status-equal-journal.out" 'durable_unmount_attempt=conflicting'
[ -f "$FIXTURE/state/Media/unmount-attempt" ] || fail 'read-only status retired an equal-epoch journal'
pass 'conflicting equal-epoch journals fail closed without hiding cached truth'

# A completed unmount timeout is manual attention even when the older cache was idle.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
{
  printf 'format|1\n'
  printf 'runtime_fingerprint|%s\n' "$mw_seed_fingerprint"
  printf 'attempt_epoch|950\n'
  printf 'action|normal-unmount\n'
  printf 'phase|complete\n'
  printf 'result|timed-out\n'
  printf 'exit_status|124\n'
  printf 'pending_recovery|network-restored\n'
  printf 'refresh_required|0\n'
} > "$FIXTURE/state/Media/unmount-attempt"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-timeout-journal.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 2 ] || fail "timed-out journal status exited $STATUS_RC"
assert_contains "$FIXTURE/status-timeout-journal.out" 'pending_recovery=network-restored action_state=manual-attention'
assert_contains "$FIXTURE/status-timeout-journal.out" 'last_attempt=normal-unmount last_attempt_result=timed-out last_error=normal-unmount-timed-out last_attempt_exit_status=124'
assert_contains "$FIXTURE/status-timeout-journal.out" 'durable_unmount_attempt=complete'
pass 'uncommitted unmount timeouts retain manual-attention severity'

# Stale-input and future-clock journals remain visible without being followed.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
{
  printf 'format|1\n'
  printf 'runtime_fingerprint|stale-input\n'
  printf 'attempt_epoch|950\n'
  printf 'action|normal-unmount\n'
  printf 'phase|complete\n'
  printf 'result|busy\n'
  printf 'exit_status|1\n'
  printf 'pending_recovery|network-restored\n'
  printf 'refresh_required|0\n'
} > "$FIXTURE/state/Media/unmount-attempt"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-mismatched-journal.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 1 ] || fail "mismatched journal status exited $STATUS_RC"
assert_contains "$FIXTURE/status-mismatched-journal.out" 'durable_unmount_attempt=input-mismatch'
/usr/bin/sed \
  -e "s/^runtime_fingerprint|stale-input$/runtime_fingerprint|$mw_seed_fingerprint/" \
  -e 's/^attempt_epoch|950$/attempt_epoch|1100/' \
  "$FIXTURE/state/Media/unmount-attempt" > "$FIXTURE/state/Media/unmount-attempt.future"
/bin/mv "$FIXTURE/state/Media/unmount-attempt.future" "$FIXTURE/state/Media/unmount-attempt"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-future-journal.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 3 ] || fail "future journal status exited $STATUS_RC"
assert_contains "$FIXTURE/status-future-journal.out" 'durable_unmount_attempt=invalid-or-clock-rollback'
pass 'status exposes stale-input and future-clock unmount journals'

# A confirmed unmount journal resumes the required refresh after a crash.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
printf 'map auto_smb on /Users/testuser/Media (autofs, automounted, nobrowse)\n' > "$FIXTURE/mount.after_umount"
/bin/cp "$FIXTURE/mount.after_umount" "$FIXTURE/mount.after_automount"
: > "$FIXTURE/crash-after-unmount-journal"
run_runtime
[ "$RUNTIME_RC" -eq 137 ] || fail "post-unmount journal crash exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/unmount-attempt" 'phase|complete'
assert_contains "$FIXTURE/state/Media/unmount-attempt" 'result|unmounted'
assert_contains "$FIXTURE/state/Media/unmount-attempt" 'exit_status|0'
assert_contains "$FIXTURE/state/Media/unmount-attempt" 'refresh_required|1'
[ ! -e "$FIXTURE/state/autofs-refresh" ] || fail 'post-unmount crash unexpectedly reached the refresh journal'
/bin/rm -f "$FIXTURE/crash-after-unmount-journal"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "post-unmount refresh continuation exited $RUNTIME_RC"
[ "$(/usr/bin/grep -c '^umount|' "$FIXTURE/actions.log")" -eq 1 ] || fail 'post-crash continuation repeated the normal unmount'
[ "$(/usr/bin/grep -c '^automount|' "$FIXTURE/actions.log")" -eq 1 ] || fail 'post-crash continuation did not run the required refresh once'
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|none'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_action|autofs-refresh'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_exit_status|0'
assert_contains "$FIXTURE/state/Media/status" 'last_successful_action|normal-unmount-and-autofs-refresh'
[ ! -e "$FIXTURE/state/Media/unmount-attempt" ] || fail 'completed post-crash refresh did not retire the unmount journal'
pass 'confirmed unmount journals durably resume the required autofs refresh'

# A crash after the combined-success status commit but before journal retirement
# must not replay an already-completed refresh after the cooldown expires.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
printf 'map auto_smb on /Users/testuser/Media (autofs, automounted, nobrowse)\n' > "$FIXTURE/mount.after_umount"
/bin/cp "$FIXTURE/mount.after_umount" "$FIXTURE/mount.after_automount"
: > "$FIXTURE/crash-after-mount-status-write"
run_runtime
[ "$RUNTIME_RC" -eq 137 ] || fail "post-status journal-retirement crash exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|none'
assert_contains "$FIXTURE/state/Media/status" 'action_state|idle'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_epoch|1000'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_action|autofs-refresh'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_result|succeeded'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_exit_status|0'
assert_contains "$FIXTURE/state/Media/status" 'last_successful_action_epoch|1000'
assert_contains "$FIXTURE/state/Media/status" 'last_successful_action|normal-unmount-and-autofs-refresh'
assert_contains "$FIXTURE/state/Media/status" 'last_error|none'
assert_contains "$FIXTURE/state/Media/unmount-attempt" 'phase|complete'
assert_contains "$FIXTURE/state/Media/unmount-attempt" 'result|unmounted'
assert_contains "$FIXTURE/state/Media/unmount-attempt" 'exit_status|0'
assert_contains "$FIXTURE/state/Media/unmount-attempt" 'refresh_required|1'
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-superseded-journal.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 1 ] || fail "superseded journal status exited $STATUS_RC"
assert_contains "$FIXTURE/status-superseded-journal.out" 'pending_recovery=none action_state=idle'
assert_contains "$FIXTURE/status-superseded-journal.out" 'last_attempt=autofs-refresh last_attempt_result=succeeded last_error=none last_attempt_exit_status=0'
assert_contains "$FIXTURE/status-superseded-journal.out" 'durable_unmount_attempt=superseded'
[ -f "$FIXTURE/state/Media/unmount-attempt" ] || fail 'read-only status retired the superseded journal'
printf '1300\n' > "$FIXTURE/now"
: > "$FIXTURE/actions.log"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "superseded-journal retirement tick exited $RUNTIME_RC"
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
[ ! -e "$FIXTURE/state/Media/unmount-attempt" ] || fail 'superseded combined-success journal was not retired'
pass 'committed combined success suppresses stale journal replay'

# A malformed durable attempt record cannot authorize or merely defer recovery.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
{
  printf 'format|1\n'
  printf 'runtime_fingerprint|%s\n' "$mw_seed_fingerprint"
  printf 'attempt_epoch|950\n'
  printf 'action|normal-unmount\n'
  printf 'phase|complete\n'
  printf 'result|attempting\n'
  printf 'exit_status|1\n'
  printf 'pending_recovery|network-restored\n'
  printf 'refresh_required|0\n'
} > "$FIXTURE/state/Media/unmount-attempt"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-malformed-journal.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 3 ] || fail "malformed journal status exited $STATUS_RC"
assert_contains "$FIXTURE/status-malformed-journal.out" 'durable_unmount_attempt=unsafe'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "malformed unmount journal exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'action_state|manual-attention'
assert_contains "$FIXTURE/state/Media/status" 'last_error|state-requires-manual-attention'
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
[ -f "$FIXTURE/state/Media/unmount-attempt" ] || fail 'malformed journal was silently discarded'
pass 'malformed unmount attempt journals fail closed'

# A vanished SMB layer cancels obsolete error state from an earlier attempt.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable \
  mounted-unreachable expected-smb normal-unmount-busy
printf 'map auto_smb on /Users/testuser/Media (autofs, automounted, nobrowse)\n' > "$FIXTURE/mount.output.2"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "trigger-only cancellation exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'state|trigger-only'
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|none'
assert_contains "$FIXTURE/state/Media/status" 'action_state|canceled'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_result|canceled-target-disappeared'
assert_contains "$FIXTURE/state/Media/status" 'last_error|none'
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'trigger-only revalidation clears stale unmount failure state'

# A target that changes between observation and action is never unmounted.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable \
  mounted-unreachable expected-smb normal-unmount-busy
printf '//guest@192.0.2.10/Other on /Users/testuser/Media (smbfs, nodev)\n' > "$FIXTURE/mount.output.2"
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "pre-action change exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'action_state|manual-attention'
assert_contains "$FIXTURE/state/Media/status" 'last_error|target-changed-before-unmount'
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'pre-action snapshot changes cancel the unmount'

# If the SMB layer disappears during validation, only the refresh is credited.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable \
  mounted-unreachable expected-smb normal-unmount-busy
: > "$FIXTURE/mount.output.2"
printf 'map auto_smb on /Users/testuser/Media (autofs, automounted, nobrowse)\n' > "$FIXTURE/mount.after_automount"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "disappeared target refresh exited $RUNTIME_RC"
assert_not_action "$FIXTURE/actions.log" umount
[ "$(/usr/bin/grep -c '^automount|' "$FIXTURE/actions.log")" -eq 1 ] || fail 'target-disappeared refresh was not attempted once'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_action|autofs-refresh'
assert_contains "$FIXTURE/state/Media/status" 'last_successful_action|autofs-refresh'
assert_contains "$FIXTURE/state/Media/status" 'last_error|none'
if /usr/bin/grep -Fq 'last_successful_action|normal-unmount-and-autofs-refresh' "$FIXTURE/state/Media/status"; then
  fail 'status credited an unmount that did not run'
fi
pass 'target-disappeared refresh reports only the action that ran'

# A failed system-wide autofs refresh remains pending and is not called success.
drop_fixture
new_fixture
write_one_config
: > "$FIXTURE/mount.output"
seed_state Media /Users/testuser/Media 192.0.2.10 Media reachable
printf '1\n' > "$FIXTURE/automount.exit"
run_runtime
[ "$RUNTIME_RC" -eq 1 ] || fail "failed refresh exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|trigger-missing'
assert_contains "$FIXTURE/state/Media/status" 'action_state|refresh-required'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_result|failed'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_exit_status|1'
assert_contains "$FIXTURE/state/Media/status" 'last_error|autofs-refresh-failed'
assert_contains "$FIXTURE/state/autofs-refresh" 'last_exit_status|1'
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-refresh-exit.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 1 ] || fail "failed-refresh status exited $STATUS_RC"
assert_contains "$FIXTURE/status-refresh-exit.out" 'last_attempt_exit_status=1'
assert_contains "$FIXTURE/status-refresh-exit.out" 'autofs_refresh_last_result=failed autofs_refresh_exit_status=1'
assert_contains "$FIXTURE/watchdog.log" 'event=recovery-action scope=global action=autofs-refresh reason=autofs-refresh-failed result=failed'
assert_log_safe "$FIXTURE/watchdog.log"
[ "$(/usr/bin/grep -c '^automount|' "$FIXTURE/actions.log")" -eq 1 ] || fail 'failed refresh was not attempted exactly once'
assert_not_action "$FIXTURE/actions.log" umount
printf '1060\n' > "$FIXTURE/now"
: > "$FIXTURE/actions.log"
run_runtime
[ "$RUNTIME_RC" -eq 1 ] || fail "refresh cooldown tick exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'action_state|deferred-cooldown'
assert_contains "$FIXTURE/state/Media/status" 'last_error|autofs-refresh-failed'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_exit_status|1'
assert_contains "$FIXTURE/state/autofs-refresh" 'last_exit_status|1'
assert_not_action "$FIXTURE/actions.log" automount
pass 'failed autofs refresh remains pending with its actual result'

# A durable global refresh timeout carries manual-attention severity even when
# the per-mount cache predates the failed command.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media reachable
{
  printf 'format|1\n'
  printf 'runtime_fingerprint|%s\n' "$mw_seed_fingerprint"
  printf 'last_attempt_epoch|950\n'
  printf 'last_result|timed-out\n'
  printf 'last_exit_status|124\n'
} > "$FIXTURE/state/autofs-refresh"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-refresh-timeout.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 2 ] || fail "timed-out refresh status exited $STATUS_RC"
assert_contains "$FIXTURE/status-refresh-timeout.out" 'autofs_refresh_last_result=timed-out autofs_refresh_exit_status=124'
pass 'global refresh timeouts retain manual-attention severity'

# An uncommitted global refresh record remains pending and is safely retried.
drop_fixture
new_fixture
write_one_config
: > "$FIXTURE/mount.output"
seed_state Media /Users/testuser/Media 192.0.2.10 Media reachable
printf 'map auto_smb on /Users/testuser/Media (autofs, automounted, nobrowse)\n' > "$FIXTURE/mount.after_automount"
: > "$FIXTURE/crash-after-automount-command"
run_runtime
[ "$RUNTIME_RC" -eq 137 ] || fail "post-automount command crash exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/autofs-refresh" 'last_result|attempting'
assert_contains "$FIXTURE/state/autofs-refresh" 'last_exit_status|unknown'
[ "$(/usr/bin/grep -c '^automount|' "$FIXTURE/actions.log")" -eq 1 ] || fail 'crash fixture did not complete one automount command'
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-uncommitted-refresh.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 1 ] || fail "uncommitted-refresh status exited $STATUS_RC"
assert_contains "$FIXTURE/status-uncommitted-refresh.out" 'autofs_refresh_last_result=attempting autofs_refresh_exit_status=unknown'
assert_contains "$FIXTURE/status-uncommitted-refresh.out" 'autofs_refresh_pending=required'
/bin/rm -f "$FIXTURE/crash-after-automount-command"
printf '1400\n' > "$FIXTURE/now"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "uncommitted-refresh retry exited $RUNTIME_RC"
[ "$(/usr/bin/grep -c '^automount|' "$FIXTURE/actions.log")" -eq 2 ] || fail 'uncommitted refresh was not retried exactly once after cooldown'
assert_contains "$FIXTURE/state/autofs-refresh" 'last_result|completed'
assert_contains "$FIXTURE/state/autofs-refresh" 'last_exit_status|0'
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|none'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_exit_status|0'
assert_not_action "$FIXTURE/actions.log" umount
pass 'uncommitted global refresh attempts stay visible and retry after cooldown'

# A verified unmount retains its refresh journal across a failed global refresh,
# then retries only the refresh and retires after verified success.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
printf 'map auto_smb on /Users/testuser/Media (autofs, automounted, nobrowse)\n' > "$FIXTURE/mount.after_umount"
/bin/cp "$FIXTURE/mount.after_umount" "$FIXTURE/mount.after_automount"
printf '1\n' > "$FIXTURE/automount.exit"
run_runtime
[ "$RUNTIME_RC" -eq 1 ] || fail "combined failed refresh exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'action_state|refresh-required'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_action|autofs-refresh'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_result|failed'
[ -f "$FIXTURE/state/Media/unmount-attempt" ] || fail 'failed combined refresh retired its unmount journal'
[ "$(/usr/bin/grep -c '^umount|' "$FIXTURE/actions.log")" -eq 1 ] || fail 'combined failure did not run exactly one unmount'
[ "$(/usr/bin/grep -c '^automount|' "$FIXTURE/actions.log")" -eq 1 ] || fail 'combined failure did not run exactly one refresh'
printf '0\n' > "$FIXTURE/automount.exit"
printf '1300\n' > "$FIXTURE/now"
: > "$FIXTURE/actions.log"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "combined refresh retry exited $RUNTIME_RC"
assert_not_action "$FIXTURE/actions.log" umount
[ "$(/usr/bin/grep -c '^automount|' "$FIXTURE/actions.log")" -eq 1 ] || fail 'combined retry did not run exactly one refresh'
assert_contains "$FIXTURE/state/Media/status" 'last_successful_action|normal-unmount-and-autofs-refresh'
[ ! -e "$FIXTURE/state/Media/unmount-attempt" ] || fail 'verified combined retry did not retire its unmount journal'
pass 'failed combined refresh retries only the required refresh'

# A later slot inspection failure blocks the shared refresh without discarding
# an earlier slot's confirmed-unmount continuation.
drop_fixture
new_fixture
printf 'Media\t/Users/testuser/Media\t192.0.2.10\tMedia\nStudio\t/Users/testuser/Studio\t198.51.100.20\tWorkspace\n' > "$FIXTURE/mounts.conf"
{
  printf 'map auto_smb on /Users/testuser/Media (autofs, automounted, nobrowse)\n'
  printf '//guest@192.0.2.10/Media on /Users/testuser/Media (smbfs, nodev)\n'
  printf 'map auto_smb on /Users/testuser/Studio (autofs, automounted, nobrowse)\n'
  printf '//guest@198.51.100.20/Workspace on /Users/testuser/Studio (smbfs, nodev)\n'
} > "$FIXTURE/mount.output"
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
seed_state Studio /Users/testuser/Studio 198.51.100.20 Workspace unreachable
printf 'reachable\n' > "$FIXTURE/network/198.51.100.20"
{
  printf 'map auto_smb on /Users/testuser/Media (autofs, automounted, nobrowse)\n'
  printf 'map auto_smb on /Users/testuser/Studio (autofs, automounted, nobrowse)\n'
  printf '//guest@198.51.100.20/Workspace on /Users/testuser/Studio (smbfs, nodev)\n'
} > "$FIXTURE/mount.after_umount"
/bin/cp "$FIXTURE/mount.after_umount" "$FIXTURE/mount.after_automount"
printf '1\n' > "$FIXTURE/mount.exit.4"
run_runtime
[ "$RUNTIME_RC" -eq 1 ] || fail "blocked shared refresh exited $RUNTIME_RC"
[ -f "$FIXTURE/state/Media/unmount-attempt" ] || fail 'blocked shared refresh retired the confirmed-unmount journal'
assert_contains "$FIXTURE/state/Media/status" 'action_state|refresh-required'
assert_not_action "$FIXTURE/actions.log" automount
printf 'unreachable\n' > "$FIXTURE/network/198.51.100.20"
printf '1300\n' > "$FIXTURE/now"
: > "$FIXTURE/actions.log"
run_runtime
[ "$RUNTIME_RC" -eq 1 ] || fail "blocked shared refresh continuation exited $RUNTIME_RC"
assert_not_action "$FIXTURE/actions.log" umount
[ "$(/usr/bin/grep -c '^automount|' "$FIXTURE/actions.log")" -eq 1 ] || fail 'retained shared refresh did not run once'
[ ! -e "$FIXTURE/state/Media/unmount-attempt" ] || fail 'retained shared refresh journal was not retired after success'
pass 'later global blockers cannot discard a confirmed refresh obligation'

# A failed terminal global-record write leaves the attempting record and
# per-mount journal intact, before any per-mount success can commit.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
printf 'map auto_smb on /Users/testuser/Media (autofs, automounted, nobrowse)\n' > "$FIXTURE/mount.after_umount"
/bin/cp "$FIXTURE/mount.after_umount" "$FIXTURE/mount.after_automount"
: > "$FIXTURE/fail-terminal-global-refresh-write"
run_runtime
[ "$RUNTIME_RC" -eq 70 ] || fail "terminal global-record failure exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/autofs-refresh" 'last_result|attempting'
assert_contains "$FIXTURE/state/Media/unmount-attempt" 'result|unmounted'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_action|never'
assert_contains "$FIXTURE/state/heartbeat" 'result|state-write-error'
/bin/rm -f "$FIXTURE/fail-terminal-global-refresh-write"
printf '1300\n' > "$FIXTURE/now"
: > "$FIXTURE/actions.log"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "terminal global-record retry exited $RUNTIME_RC"
assert_not_action "$FIXTURE/actions.log" umount
[ "$(/usr/bin/grep -c '^automount|' "$FIXTURE/actions.log")" -eq 1 ] || fail 'terminal-record retry did not run exactly one refresh'
assert_contains "$FIXTURE/state/autofs-refresh" 'last_result|completed'
[ ! -e "$FIXTURE/state/Media/unmount-attempt" ] || fail 'terminal-record retry did not retire the unmount journal'
pass 'terminal global-record failure cannot commit or discard recovery state'

# A crash after a durable busy result restores its pending reason and cooldown.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
printf '1\n' > "$FIXTURE/umount.exit"
printf 'umount: Resource busy\n' > "$FIXTURE/umount.stderr"
: > "$FIXTURE/crash-after-unmount-journal"
run_runtime
[ "$RUNTIME_RC" -eq 137 ] || fail "busy journal crash exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/unmount-attempt" 'result|busy'
/bin/rm -f "$FIXTURE/crash-after-unmount-journal"
printf '1060\n' > "$FIXTURE/now"
: > "$FIXTURE/actions.log"
run_runtime
[ "$RUNTIME_RC" -eq 1 ] || fail "busy journal continuation exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|network-restored'
assert_contains "$FIXTURE/state/Media/status" 'action_state|deferred-cooldown'
assert_contains "$FIXTURE/state/Media/status" 'last_error|normal-unmount-busy'
assert_not_action "$FIXTURE/actions.log" umount
[ ! -e "$FIXTURE/state/Media/unmount-attempt" ] || fail 'committed busy journal was not retired'
pass 'busy crash recovery preserves pending intent and cooldown'

# A crash after a durable terminal unmount result cannot downgrade manual policy
# or retry the unmount after cooldown.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
printf '124\n' > "$FIXTURE/umount.exit"
: > "$FIXTURE/crash-after-unmount-journal"
run_runtime
[ "$RUNTIME_RC" -eq 137 ] || fail "terminal unmount journal crash exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/unmount-attempt" 'result|timed-out'
/bin/rm -f "$FIXTURE/crash-after-unmount-journal"
printf '1300\n' > "$FIXTURE/now"
: > "$FIXTURE/actions.log"
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "terminal unmount continuation exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|network-restored'
assert_contains "$FIXTURE/state/Media/status" 'action_state|manual-attention'
assert_contains "$FIXTURE/state/Media/status" 'last_error|normal-unmount-timed-out'
assert_not_action "$FIXTURE/actions.log" umount
assert_contains "$FIXTURE/state/heartbeat" 'result|manual-attention'
[ ! -e "$FIXTURE/state/Media/unmount-attempt" ] || fail 'committed terminal journal was not retired'
printf '1600\n' > "$FIXTURE/now"
: > "$FIXTURE/actions.log"
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "latched terminal unmount policy exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'last_error|normal-unmount-timed-out'
assert_contains "$FIXTURE/state/Media/status" 'action_state|manual-attention'
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'terminal unmount journals preserve manual-attention policy across crashes'

# A crash after a durable terminal global timeout creates a global manual latch;
# it remains observable but no later mount can claim or retry that action.
drop_fixture
new_fixture
write_one_config
: > "$FIXTURE/mount.output"
seed_state Media /Users/testuser/Media 192.0.2.10 Media reachable
printf '124\n' > "$FIXTURE/automount.exit"
: > "$FIXTURE/crash-after-terminal-global-refresh-record"
run_runtime
[ "$RUNTIME_RC" -eq 137 ] || fail "terminal global timeout crash exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/autofs-refresh" 'last_result|timed-out'
assert_contains "$FIXTURE/state/autofs-refresh" 'last_exit_status|124'
printf '1300\n' > "$FIXTURE/now"
: > "$FIXTURE/actions.log"
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "terminal global timeout latch exited $RUNTIME_RC"
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
assert_contains "$FIXTURE/state/heartbeat" 'result|manual-attention'
assert_contains "$FIXTURE/state/autofs-refresh" 'last_result|timed-out'
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-global-timeout-latch.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 2 ] || fail "terminal global timeout status exited $STATUS_RC"
assert_contains "$FIXTURE/status-global-timeout-latch.out" 'autofs_refresh_last_result=timed-out autofs_refresh_exit_status=124'
pass 'terminal global refresh results remain a global manual-attention latch'

# An explicit owner acknowledgment uses the runtime lock, validates current
# autofs and mount-table metadata, and clears only reviewed latches. It never
# probes a host, unmounts a share, or refreshes autofs itself.
: > "$FIXTURE/actions.log"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$RUNTIME" \
  --acknowledge-manual-attention > "$FIXTURE/ack-global.out" 2>&1
ACK_RC=$?
[ "$ACK_RC" -eq 0 ] || fail "global acknowledgment exited $ACK_RC"
[ ! -e "$FIXTURE/state/autofs-refresh" ] || fail 'global acknowledgment retained the reviewed refresh latch'
assert_contains "$FIXTURE/state/heartbeat" 'result|pending'
[ "$(/usr/bin/grep -c '^mount$' "$FIXTURE/actions.log")" -eq 1 ] || fail 'global acknowledgment did not take exactly one read-only mount snapshot'
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
assert_contains "$FIXTURE/watchdog.log" 'event=owner-acknowledgment scope=global action=manual-attention reason=reviewed-latch-cleared result=pending-reevaluation'
pass 'owner acknowledgment clears a reviewed global latch without recovery actions'

drop_fixture
new_fixture
write_one_config
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media reachable
/usr/bin/sed 's/^action_state|idle$/action_state|manual-attention/; s/^last_error|none$/last_error|normal-unmount-timed-out/; s/^blocked_pid|none$/blocked_pid|unknown/' \
  "$FIXTURE/state/Media/status" > "$FIXTURE/state/Media/status-new" || fail 'could not stage acknowledged state'
/bin/mv "$FIXTURE/state/Media/status-new" "$FIXTURE/state/Media/status"
: > "$FIXTURE/actions.log"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$RUNTIME" \
  --acknowledge-manual-attention > "$FIXTURE/ack-slot.out" 2>&1
ACK_RC=$?
[ "$ACK_RC" -eq 0 ] || fail "per-mount acknowledgment exited $ACK_RC"
assert_contains "$FIXTURE/state/Media/status" 'action_state|idle'
assert_contains "$FIXTURE/state/Media/status" 'last_error|none'
assert_contains "$FIXTURE/state/Media/status" 'blocked_pid|none'
assert_contains "$FIXTURE/state/Media/status" 'last_attempt_result|never'
[ "$(/usr/bin/grep -c '^mount$' "$FIXTURE/actions.log")" -eq 1 ] || fail 'per-mount acknowledgment did not take exactly one read-only mount snapshot'
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'owner acknowledgment clears only a validated per-mount latch and preserves history'

drop_fixture
new_fixture
write_one_config
printf '//guest@192.0.2.10/Other on /Users/testuser/Media (smbfs, nodev)\n' > "$FIXTURE/mount.output"
seed_state Media /Users/testuser/Media 192.0.2.10 Media reachable
/usr/bin/sed 's/^action_state|idle$/action_state|manual-attention/; s/^last_error|none$/last_error|unexpected-or-ambiguous-mount-layer/' \
  "$FIXTURE/state/Media/status" > "$FIXTURE/state/Media/status-new" || fail 'could not stage unresolved state'
/bin/mv "$FIXTURE/state/Media/status-new" "$FIXTURE/state/Media/status"
: > "$FIXTURE/actions.log"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$RUNTIME" \
  --acknowledge-manual-attention > "$FIXTURE/ack-unresolved.out" 2>&1
ACK_RC=$?
[ "$ACK_RC" -eq 2 ] || fail "unresolved acknowledgment exited $ACK_RC"
assert_contains "$FIXTURE/state/Media/status" 'action_state|manual-attention'
assert_contains "$FIXTURE/state/Media/status" 'last_error|unexpected-or-ambiguous-mount-layer'
assert_contains "$FIXTURE/ack-unresolved.out" 'has an unexpected or ambiguous mount layer'
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'owner acknowledgment refuses an unresolved unexpected mount layer'

# SIGKILL may leave credential-bearing command captures, but the next trusted
# locked tick removes only those exact files before the first observation.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
printf 'mount helper rejected //backup:CrashSecret@192.0.2.10/Media\n' > "$FIXTURE/mount.stderr"
: > "$FIXTURE/mount.kill-supervisor-after-output"
run_runtime
[ "$RUNTIME_RC" -eq 137 ] || fail "credential temp crash exited $RUNTIME_RC"
[ -f "$FIXTURE/mount-kill.pid" ] || fail 'credential temp crash did not record its command pid'
IFS= read -r mw_killed_mount_pid < "$FIXTURE/mount-kill.pid"
mw_kill_wait=0
while kill -0 "$mw_killed_mount_pid" 2>/dev/null; do
  [ "$mw_kill_wait" -lt 50 ] || fail 'credential temp command did not exit'
  /bin/sleep 0.1
  mw_kill_wait=$((mw_kill_wait + 1))
done
: > "$FIXTURE/runtime-orphan-paths"
for mw_orphan_path in "$FIXTURE/state"/.mount-snapshot.* "$FIXTURE/state"/.mount-error.*; do
  { [ -e "$mw_orphan_path" ] || [ -L "$mw_orphan_path" ]; } || continue
  printf '%s\n' "$mw_orphan_path" >> "$FIXTURE/runtime-orphan-paths"
done
[ "$(/usr/bin/wc -l < "$FIXTURE/runtime-orphan-paths" | /usr/bin/tr -d ' ')" -eq 2 ] || fail 'credential crash did not leave both expected captures'
mw_secret_residue=0
while IFS= read -r mw_orphan_path; do
  if /usr/bin/grep -Fq 'CrashSecret' "$mw_orphan_path"; then mw_secret_residue=1; fi
done < "$FIXTURE/runtime-orphan-paths"
[ "$mw_secret_residue" -eq 1 ] || fail 'credential-like crash residue was not captured by the fixture'
/bin/rm -f "$FIXTURE/mount.kill-supervisor-after-output"
: > "$FIXTURE/reject-listed-runtime-orphans"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "credential temp cleanup tick exited $RUNTIME_RC"
assert_not_action "$FIXTURE/actions.log" mount-observed-orphan
while IFS= read -r mw_orphan_path; do
  [ ! -e "$mw_orphan_path" ] && [ ! -L "$mw_orphan_path" ] || fail 'credential-bearing orphan survived cleanup'
done < "$FIXTURE/runtime-orphan-paths"
if /usr/bin/grep -Fq 'CrashSecret' "$FIXTURE/watchdog.log" "$FIXTURE/state/heartbeat" "$FIXTURE/state/Media/status"; then
  fail 'credential-like orphan data reached durable diagnostics'
fi
pass 'next-tick orphan cleanup removes credential-bearing crash captures first'

# Managed-looking orphan types fail closed and remain available for inspection.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
/bin/mkdir -p "$FIXTURE/state"
/bin/ln -s "$FIXTURE/missing-orphan-target" "$FIXTURE/state/.mount-error.ABC123"
run_runtime
[ "$RUNTIME_RC" -eq 70 ] || fail "unsafe orphan type exited $RUNTIME_RC"
[ -L "$FIXTURE/state/.mount-error.ABC123" ] || fail 'unsafe orphan symlink was removed'
assert_not_action "$FIXTURE/actions.log" mount
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status-unsafe-orphan.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 3 ] || fail "unsafe orphan status exited $STATUS_RC"
assert_contains "$FIXTURE/status-unsafe-orphan.out" 'state_cache=unsafe leaf=.mount-error.ABC123'
pass 'unsafe managed-looking orphan types fail closed without deletion'

# A reconciled dead owner may leave a trusted atomic temp; it is removed before
# stale-lock rmdir. An owner-absent lock remains fail-closed to avoid overlap.
drop_fixture
new_fixture
write_one_config
write_expected_media_mount
/bin/mkdir -p "$FIXTURE/state/.tick.lock"
{
  printf 'format|1\n'
  printf 'pid|999999\n'
  printf 'process_token|dead-owner\n'
} > "$FIXTURE/state/.tick.lock/owner"
{
  printf 'format|1\n'
  printf 'active|0\n'
  printf 'pid|0\n'
  printf 'pgid|0\n'
  printf 'process_token|none\n'
  printf 'command|none\n'
} > "$FIXTURE/state/.tick.lock/command-guard"
printf 'partial-atomic-write\n' > "$FIXTURE/state/.tick.lock/.tmp.ABC123"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "dead-owner lock temp cleanup exited $RUNTIME_RC"
[ ! -e "$FIXTURE/state/.tick.lock" ] || fail 'reconciled stale lock was not released'
pass 'reconciled dead-owner locks remove only trusted atomic temps'

drop_fixture
new_fixture
write_one_config
write_expected_media_mount
/bin/mkdir -p "$FIXTURE/state/.tick.lock"
printf 'partial-owner\n' > "$FIXTURE/state/.tick.lock/.tmp.ABC123"
run_runtime
[ "$RUNTIME_RC" -eq 70 ] || fail "incomplete-owner lock exited $RUNTIME_RC"
[ -f "$FIXTURE/state/.tick.lock/.tmp.ABC123" ] || fail 'incomplete-owner lock was auto-recovered'
assert_not_action "$FIXTURE/actions.log" mount
pass 'owner-absent locks remain fail-closed instead of risking overlap'

# Same-host shares share one probe and independent refresh requests coalesce.
drop_fixture
new_fixture
printf 'Media\t/Users/testuser/Media\t192.0.2.10\tMedia\nStudio\t/Users/testuser/Studio\t192.0.2.10\tWorkspace\n' > "$FIXTURE/mounts.conf"
write_expected_media_mount
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
seed_state Studio /Users/testuser/Studio 192.0.2.10 Workspace reachable
printf 'map auto_smb on /Users/testuser/Media (autofs, automounted, nobrowse)\n' > "$FIXTURE/mount.after_umount"
{
  printf 'map auto_smb on /Users/testuser/Media (autofs, automounted, nobrowse)\n'
  printf 'map auto_smb on /Users/testuser/Studio (autofs, automounted, nobrowse)\n'
} > "$FIXTURE/mount.after_automount"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "coalesced recovery exited $RUNTIME_RC"
[ "$(/usr/bin/grep -c '^nc|' "$FIXTURE/actions.log")" -eq 2 ] || fail 'same host was not cached once plus one pre-action recheck'
[ "$(/usr/bin/grep -c '^automount|' "$FIXTURE/actions.log")" -eq 1 ] || fail 'autofs refresh was not coalesced'
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|none'
assert_contains "$FIXTURE/state/Studio/status" 'expected_share|Workspace'
assert_contains "$FIXTURE/state/Studio/status" 'pending_recovery|none'
pass 'same-host observations are cached and refresh is coalesced'

# DNS hostname cache keys follow the case-insensitive source-matching rules.
drop_fixture
new_fixture
printf 'Media\t/Users/testuser/Media\tNAS.Example\tMedia\nStudio\t/Users/testuser/Studio\tnas.example\tWorkspace\n' > "$FIXTURE/mounts.conf"
{
  printf '//guest@nas.example/Media on /Users/testuser/Media (smbfs, nodev)\n'
  printf '//guest@NAS.EXAMPLE/Workspace on /Users/testuser/Studio (smbfs, nodev)\n'
} > "$FIXTURE/mount.output"
printf 'reachable\n' > "$FIXTURE/network/NAS.Example"
run_runtime
[ "$RUNTIME_RC" -eq 0 ] || fail "case-folded host cache exited $RUNTIME_RC"
[ "$(/usr/bin/grep -c '^nc|' "$FIXTURE/actions.log")" -eq 1 ] || fail 'case variants triggered more than one host probe'
assert_contains "$FIXTURE/actions.log" 'nc|NAS.Example|445'
assert_contains "$FIXTURE/state/Media/status" 'state|mounted-reachable'
assert_contains "$FIXTURE/state/Studio/status" 'state|mounted-reachable'
assert_contains "$FIXTURE/state/Studio/status" 'last_network_state|reachable'
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'case-variant DNS hosts share one observation result per tick'

# Different hosts retain independent observations and recovery decisions.
drop_fixture
new_fixture
printf 'Media\t/Users/testuser/Media\t192.0.2.10\tMedia\nStudio\t/Users/testuser/Studio\t198.51.100.20\tWorkspace\n' > "$FIXTURE/mounts.conf"
{
  printf 'map auto_smb on /Users/testuser/Media (autofs, automounted, nobrowse)\n'
  printf '//guest@192.0.2.10/Media on /Users/testuser/Media (smbfs, nodev, nosuid)\n'
  printf 'map auto_smb on /Users/testuser/Studio (autofs, automounted, nobrowse)\n'
  printf '//guest@198.51.100.20/Workspace on /Users/testuser/Studio (smbfs, nodev, nosuid)\n'
} > "$FIXTURE/mount.output"
printf 'unreachable\n' > "$FIXTURE/network/198.51.100.20"
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable mounted-unreachable expected-smb
seed_state Studio /Users/testuser/Studio 198.51.100.20 Workspace reachable mounted-reachable expected-smb
printf '1\n' > "$FIXTURE/umount.exit"
printf 'umount: Resource busy\n' > "$FIXTURE/umount.stderr"
run_runtime
[ "$RUNTIME_RC" -eq 1 ] || fail "different-host tick exited $RUNTIME_RC"
[ "$(/usr/bin/grep -c '^nc|192.0.2.10|445$' "$FIXTURE/actions.log")" -eq 2 ] || fail 'recovering host did not get one observation plus one recheck'
[ "$(/usr/bin/grep -c '^nc|198.51.100.20|445$' "$FIXTURE/actions.log")" -eq 1 ] || fail 'independent host was not observed exactly once'
assert_contains "$FIXTURE/state/Media/status" 'pending_recovery|network-restored'
assert_contains "$FIXTURE/state/Studio/status" 'state|mounted-unreachable'
assert_contains "$FIXTURE/state/Studio/status" 'pending_recovery|none'
pass 'different hosts keep independent observation and recovery state'

# An unexpected SMB source blocks recovery and is never unmounted.
drop_fixture
new_fixture
write_one_config
printf '//guest@192.0.2.10/Other on /Users/testuser/Media (smbfs, nodev)\n' > "$FIXTURE/mount.output"
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "unexpected mount exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'state|unexpected-mount'
assert_contains "$FIXTURE/state/Media/status" 'action_state|manual-attention'
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'unexpected source blocks all recovery actions'

# The auto_smb map may spell its option fstype as smb, but Darwin's mounted
# filesystem metadata must still report smbfs before recovery is authorized.
drop_fixture
new_fixture
write_one_config
printf '//guest@192.0.2.10/Media on /Users/testuser/Media (smb, nodev, nosuid)\n' > "$FIXTURE/mount.output"
seed_state Media /Users/testuser/Media 192.0.2.10 Media unreachable
run_runtime
[ "$RUNTIME_RC" -eq 2 ] || fail "non-smbfs mounted layer exited $RUNTIME_RC"
assert_contains "$FIXTURE/state/Media/status" 'state|unexpected-mount'
assert_contains "$FIXTURE/state/Media/status" 'action_state|manual-attention'
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
pass 'mounted layer classification remains exact smbfs metadata'

# Status consumes cached state only; launchctl print is its sole service query.
: > "$FIXTURE/actions.log"
MW_TEST_ROOT=$FIXTURE MW_TEST_COMMAND_DIR=$COMMANDS /bin/bash "$STATUS" --status > "$FIXTURE/status.out"
STATUS_RC=$?
[ "$STATUS_RC" -eq 2 ] || fail "manual-attention status exited $STATUS_RC"
assert_contains "$FIXTURE/status.out" 'check_scope=mount-table-and-tcp readability=not-tested'
assert_not_action "$FIXTURE/actions.log" mount
assert_not_action "$FIXTURE/actions.log" nc
assert_not_action "$FIXTURE/actions.log" umount
assert_not_action "$FIXTURE/actions.log" automount
[ "$(/usr/bin/grep -c '^launchctl|' "$FIXTURE/actions.log")" -eq 1 ] || fail 'status did not make exactly one launchctl query'
pass 'status is cached and read-only'

# Source regression guard: ls is permitted only inside the narrowly scoped ACL
# metadata helpers. It must never appear in runtime decision code where a
# managed mount path could be traversed.
if {
  /usr/bin/sed '/^mw_bootstrap_acl_policy_is_safe()/,/^}/d' "$RUNTIME"
  /usr/bin/sed '/^mw_acl_policy_is_safe()/,/^}/d' "$PROJECT_DIR/lib/common.sh"
  /bin/cat "$PROJECT_DIR/lib/runtime.sh"
} | /usr/bin/grep -En '(/bin/ls|test -d|\[ -d .*MW_MOUNT|umount[[:space:]]+-f)'; then
  fail 'runtime contains a prohibited mount-content probe or forced unmount'
fi
if /usr/bin/grep -Fq "\$mw_script_dir/config/defaults.conf" "$RUNTIME" "$STATUS"; then
  fail 'entrypoint contains the removed production defaults fallback'
fi
mw_prepare_source=$(/usr/bin/sed -n '/^mw_prepare_runtime_state()/,/^}/p' "$PROJECT_DIR/lib/runtime.sh")
case "$mw_prepare_source" in
  *"if [ -e \"\$MW_STATE_DIR\" ] || [ -L \"\$MW_STATE_DIR\" ]; then"*) ;;
  *) fail 'production state-root validation does not recognize dangling symlinks' ;;
esac
mw_fingerprint_source=$(/usr/bin/sed -n '/^mw_compute_runtime_fingerprint()/,/^}/p' "$PROJECT_DIR/lib/runtime.sh")
case "$mw_fingerprint_source" in
  *'MW_RUNTIME_PROGRAM_FILE'*'MW_RUNTIME_COMMON_FILE'*'MW_RUNTIME_LIBRARY_FILE'*'/usr/bin/shasum -a 256'*) ;;
  *) fail 'runtime fingerprint does not bind all maintained executable code' ;;
esac
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
assert_contains "$STATUS" 'mw_watchdog_file=$mw_script_dir/watchdog.sh'
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
assert_contains "$STATUS" 'mw_watchdog_file=$mw_script_dir/mount_watchdog.sh'
assert_contains "$PROJECT_DIR/packaging/com.antoinemenard.mount-watchdog.plist.in" '<string>/Library/Application Support/MountWatchdog/watchdog.sh</string>'
pass 'runtime source contains no content probe, forced unmount, or dangling state-root gap'

printf '1..%s\n' "$PASS_COUNT"
