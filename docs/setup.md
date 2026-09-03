# Setup

MountWatchdog accompanies an existing macOS autofs/SMB configuration. It does not create or edit `/etc/auto_master`, `/etc/auto_smb`, SMB credentials, Keychain entries, or mountpoint content.

## Prerequisites

Use a macOS host with Apple `/bin/bash` 3.2 and an existing autofs configuration that satisfies the [supported subset](configuration.md#supported-autofs-subset):

- `/etc/auto_master` contains exactly one active `/- auto_smb` or `/- /etc/auto_smb` direct-map entry;
- `/etc/auto_smb` contains exactly one supported SMB record for every mount you intend to select; and
- each selected target is `/Users/<current-user>/<mount-name>`.

For example, selecting `Archive` for a user named `example` requires an existing mapping for `/Users/example/Archive`. Local mount names and remote SMB share names may differ. Do not print, copy, or paste a real map record because historical maps may contain credentials.

MountWatchdog validates the complete map before installation. It fails closed on unsupported records, ambiguous mappings, unsafe metadata, conflicting targets, or an unexpected path instead of changing the maps.

## Get a release

Clone the repository and check out the release tag you intend to install:

```bash
git clone https://github.com/enthouan/mount-watchdog.git
cd mount-watchdog
git switch --detach v0.1.0
```

Run the nonprivileged fixture suite and inspect the installer help:

```bash
/bin/bash tests/run.sh
/bin/bash ./install_mount_watchdog.sh --help
```

The test suite does not touch live mounts, launchd, autofs maps, system directories, or NAS hosts.

## Preview the installation

Run these commands from the intended local user's normal shell. Replace `Archive Studio` with the complete set of local mount names you want MountWatchdog to manage:

```bash
/bin/bash ./install_mount_watchdog.sh \
  --dry-run \
  --local-user "$(/usr/bin/whoami)" \
  Archive Studio
```

The shell evaluates `$(/usr/bin/whoami)` before any later `sudo` invocation, so the installer receives the current macOS username rather than `root`. The dry-run validates the release sources, platform, maps, selected paths, generated configuration, and intended service policy without acquiring the lifecycle lock, writing installed files, or changing launchd state.

A maintained upgrade may require `sudo` for its dry-run because the existing installation is root-readable:

```bash
sudo /bin/bash ./install_mount_watchdog.sh \
  --dry-run \
  --local-user "$(/usr/bin/whoami)" \
  Archive Studio
```

Review the reported user, every selected path/host/share tuple, source mode, prior service policy, and lifecycle decision. Stop if anything is unexpected.

## Install

After reviewing the dry-run:

```bash
sudo /bin/bash ./install_mount_watchdog.sh \
  --local-user "$(/usr/bin/whoami)" \
  Archive Studio
```

A fresh install registers and enables the canonical LaunchDaemon unless macOS still has a disabled override from an earlier installation. The installer preserves that override by default and leaves the job disabled and unloaded. Pass `--enable` only when the dry-run reports that policy and you intentionally want to clear it and bootstrap the job.

A maintained upgrade validates the existing manifest and checksums, creates a protected path-preserving backup, replaces the managed files atomically, and preserves the canonical loaded/disabled policy. Catchable failures before the commit boundary attempt to restore the files and service state.

Record the protected backup path and rollback identifier printed by the installer. Use `--replace-targets` only after reviewing an intentional removal from the installed selected set.

## Verify

Confirm the installed version and use the dedicated read-only status command:

```bash
sudo /bin/cat '/Library/Application Support/MountWatchdog/VERSION'
sudo /bin/bash '/Library/Application Support/MountWatchdog/status.sh' --status
```

Do not invoke the installed `watchdog.sh` merely to inspect the machine: it runs a normal tick and may enter recovery logic. A new or upgraded runtime fingerprint establishes a non-mutating baseline first, so status may remain unavailable or pending until the next scheduled tick.

Status proves only cached mount-table and bounded TCP observations. It never proves SMB authentication, share readability, application recovery, or a usable new SMB session.

## Update an existing maintained installation

Check out the new release, rerun `/bin/bash tests/run.sh`, capture the current version and read-only status, and then repeat the dry-run and install commands above with the same complete mount-name list.

The installer accepts only an exact manifest-owned maintained installation. If `/Library/Application Support/MountWatchdog/install-manifest.tsv` is absent, unsafe, or inconsistent with the installed files, the installer reports an unmanaged collision and makes no changes. Version `0.1.0` has no automatic adoption or historical-install conversion path.

## Roll back or remove

To inspect a post-success rollback, use the exact identifier printed by the installer from the same reviewed checkout:

```bash
BACKUP_ID='exact-id-emitted-by-installer'
sudo /bin/bash ./uninstall_mount_watchdog.sh --dry-run rollback "$BACKUP_ID"
```

To perform the rollback:

```bash
sudo /bin/bash ./uninstall_mount_watchdog.sh rollback "$BACKUP_ID"
```

See [Lifecycle and rollback](lifecycle-and-rollback.md) for backup semantics, stopping, disabling, removal, lifecycle-lock handling, and optional live checks. See [Troubleshooting](troubleshooting.md) before acting on configuration drift, manual-attention state, or retained crash evidence.
