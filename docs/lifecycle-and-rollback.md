# Lifecycle and rollback

This document describes the installer, upgrade, rollback, and removal lifecycle. Use only the maintained lifecycle scripts at the repository root and preview changes with `--dry-run` first.

Start with [Setup](setup.md) for the supported autofs prerequisites and the complete installation path.

## Before installation

1. Review the exact candidate diff and latest local and CI results.
2. Identify the target Mac from its intended configuration, not merely its shell prompt.
3. Inspect each lifecycle script's `--help` output.
4. Capture the current plist arguments, job registration, enabled/loaded state, installed version and checksums, selected metadata, heartbeat, and status.
5. Confirm every intended local name has exactly one supported map record without printing or saving credential-bearing map lines.
6. Define the protected-backup and rollback procedure before stopping the job.
7. Keep applications off a share during any later owner-authorized recovery test.

Run the nonprivileged repository tests first:

```bash
/bin/bash tests/run.sh
```

## Dry-run

The installer accepts selected mount names plus `--local-user USER` and `--dry-run`. It validates the platform, active-map arrangement, selected mappings, generated config, source scripts, plist, and installation plan. It reports the source mode, prior canonical service policy, and intended lifecycle decision.

A dry-run does not acquire the privileged lifecycle lock, write installed paths, or call mutating launchd operations. Its result is a point-in-time snapshot. An upgrade dry-run may need `sudo` only to inspect the established root-only maintained installation; the later live invocation revalidates everything under the shared root lock.

```bash
/bin/bash ./install_mount_watchdog.sh \
  --dry-run \
  --local-user "$(/usr/bin/whoami)" \
  Archive Studio
```

`Archive` and `Studio` are fictional public examples. Pass exactly the intended selected set for that Mac. The shell evaluates `$(/usr/bin/whoami)` before any later `sudo` invocation, so the installer receives the current macOS username rather than `root`. `--staging-root EXISTING_NON_SYMLINK_DIR` is a nonprivileged fixture boundary, never a live-install redirection mechanism.

## Fresh install or maintained upgrade

After reviewing the dry-run:

```bash
sudo /bin/bash ./install_mount_watchdog.sh \
  --local-user "$(/usr/bin/whoami)" \
  Archive Studio
```

The installer supports only a fresh destination or an exact manifest-owned maintained installation. Canonical artifacts without the maintained manifest are unmanaged collisions and fail closed; the installer has no adoption or historical-install conversion mode.

For a maintained upgrade, every manifest record and present managed-file checksum must validate before overwrite. The installer then creates a unique path-preserving backup, temporarily disables the canonical job before replacement, installs files atomically, restores the intended canonical loaded/disabled policy, and rolls back files and service state after a catchable in-progress failure.

Use `--enable` only when intentionally bootstrapping instead of preserving a disabled or enabled-but-unloaded canonical job. Use `--replace-targets` only after reviewing an intentional selected-set change. Neither option unmounts a removed name, deletes share content, or claims ownership of an unmanaged file.

After installation, verify the version, protected backup, manifest, plist target, job registration, preserved policy, credential-free selected config, and limited status. Expect a heartbeat only when the selected policy leaves the job loaded. A quiet log or exit code 0 is not proof of SMB readability.

## Lifecycle lock and runtime evidence

Installer and uninstaller mutations share `/private/var/db/MountWatchdog.lifecycle.lock`. A catchable exit removes a lock held by that process, but `SIGKILL` or power loss can leave it behind. Lifecycle operations never auto-reclaim it; inspect a present, stale, or unsafe lock before proceeding.

The periodic runtime uses `/var/run/com.antoinemenard.mount-watchdog/.tick.lock`. A trusted later tick may reclaim only a complete lock whose owner is dead and whose command guard proves no process group remains. Incomplete or unsafe evidence fails closed. Runtime records are not lifecycle locks, and neither class is a general-purpose PID file.

## Owner acknowledgment of resolved runtime latches

First use the read-only status command, investigate the recorded cause, and fix it outside MountWatchdog. The acknowledgment is eligible only when the current autofs hookup is valid, no command or durable unmount journal remains, selected paths have reviewed layer shapes, and every latch uses the narrow allowlist.

```bash
sudo /bin/bash '/Library/Application Support/MountWatchdog/watchdog.sh' --acknowledge-manual-attention
```

This command shares the runtime tick lock, validates state and configuration, and takes one read-only mount-table snapshot. It performs no TCP probe, managed-path access, unmount, `automount -c`, or launchd mutation. It refuses active drift, unsafe state, unexpected layers, live command evidence, and unreviewed reasons.

## Post-success rollback

Copy the exact `BACKUP_ID` emitted by the installer and validate it from the same reviewed checkout:

```bash
BACKUP_ID='exact-id-emitted-by-installer'
sudo /bin/bash ./uninstall_mount_watchdog.sh --dry-run rollback "$BACKUP_ID"
```

The identifier is a single directory name beneath `/Library/Application Support/MountWatchdog/backups`; arbitrary paths are refused. The dry-run requires the current format-3 committed install backup, verifies the exact allowlisted path set and file metadata, binds the backup to the current maintained install-manifest digest, and reports the prior canonical service policy.

To perform the rollback:

```bash
sudo /bin/bash ./uninstall_mount_watchdog.sh rollback "$BACKUP_ID"
```

A successful rollback restores or removes only recorded program artifacts and restores the prior canonical loaded/disabled policy. The append-only log and protected backups remain. If restoration is incomplete, the canonical job remains stopped and disabled, an incomplete rollback record is appended, and the same backup cannot be retried as unused.

Rollback never changes autofs maps, credentials, mountpoint directories, NAS data, or unrelated jobs.

## Stop, disable, or remove

```bash
/bin/bash ./uninstall_mount_watchdog.sh --help
sudo /bin/bash ./uninstall_mount_watchdog.sh stop
sudo /bin/bash ./uninstall_mount_watchdog.sh disable
sudo /bin/bash ./uninstall_mount_watchdog.sh remove
```

Use `--dry-run` first. `stop` affects the current loaded job without deleting artifacts. `disable` records future-boot intent and stops the job. `remove` deletes only verified manifest-owned active artifacts after handling service state; it preserves backups and logs.

Every mode requires the maintained manifest, exact allowlisted records and present-file hashes, and the canonical plist's exact execution-affecting schema before any launchd action. Cleanup never follows an untrusted symlink or derives a recursive target from an unchecked name.

## Optional live checks

Reboot, sleep/wake, controlled network interruption, and busy-share tests can trigger recovery actions, including a live normal unmount. Run them only when you explicitly intend those effects and have a maintenance window. Stop if files may be in use, a mount source is unexpected, inspection fails, the normal unmount is busy, an action becomes blocked, or rollback evidence is incomplete.

Metadata status is only one acceptance signal. The owner performs the eventual application access; MountWatchdog never adds an automatic content probe to manufacture that evidence.
