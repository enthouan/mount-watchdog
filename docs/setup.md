# Setup

MountWatchdog accompanies an existing macOS autofs/SMB configuration. It does not create or edit `/etc/auto_master`, `/etc/auto_smb`, SMB credentials, Keychain entries, or mountpoint content.

## Prerequisites

Use a macOS host with Apple `/bin/bash` 3.2 and an existing autofs configuration that satisfies the [supported subset](configuration.md#supported-autofs-subset):

- `/etc/auto_master` contains exactly one active `/- auto_smb` or `/- /etc/auto_smb` direct-map entry;
- `/etc/auto_smb` contains exactly one supported SMB record for every mount you intend to select; and
- each selected target is `/Users/<current-user>/<mount-name>`.

A fictional configuration for the user `example` and the mount names `Archive` and `Studio` looks like this. The first block is only the relevant line in `/etc/auto_master`, not a replacement for the rest of that system file:

```text
/- /etc/auto_smb
```

The corresponding `/etc/auto_smb` records use absolute local paths:

```text
/Users/example/Archive -fstype=smb,soft,noowners,nosuid ://192.0.2.10/Vault
/Users/example/Studio -fstype=smbfs,soft,noowners,nosuid ://198.51.100.20/Workspace
```

Replace `example` with the output of `/usr/bin/whoami`. The final path components must match the mount names passed to the installer. Local mount names and remote SMB share names may differ: the example maps `Archive` to `Vault` and `Studio` to `Workspace`. The addresses are reserved TEST-NET examples and must not be contacted. Do not print, copy, or paste a real map record because historical maps may contain credentials.

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

### Select all mappings (development checkout)

The development installer supports `--all`; the published `v0.1.0` tag still requires explicit names. With a checkout that lists `--all` in its help, you can preview all mappings without repeating their names:

```bash
sudo /bin/bash ./install_mount_watchdog.sh \
  --dry-run \
  --all \
  --local-user "$(/usr/bin/whoami)"
```

Review every mapping, then run the same command without `--dry-run` to install. `--all` and explicit mount names are mutually exclusive. Omitting both is an error.

`--all` selects the complete validated map at installation time, in map order. The existing parser still requires every active record to be a supported SMB mapping under `/Users/<local-user>/`; records for another user, empty maps, unsupported records, and duplicate names cause an error. It does not silently skip entries or expose credentials. The running watchdog uses the saved selection, so new map entries are included only when you run the installer again.

### Select named mappings

Run these commands from the intended local user's normal shell. Replace `Archive Studio` with the complete set of local mount names you want MountWatchdog to manage:

```bash
/bin/bash ./install_mount_watchdog.sh \
  --dry-run \
  --local-user "$(/usr/bin/whoami)" \
  Archive Studio
```

The shell evaluates `$(/usr/bin/whoami)` before an optional `sudo` invocation, so the installer receives the current macOS username rather than `root`. The dry-run validates the release sources, platform, maps, selected paths, generated configuration, and intended service policy without acquiring the lifecycle lock, writing installed files, or changing launchd state.

A fresh-install dry-run may require `sudo` when an autofs map is readable only by `root`; a maintained-upgrade dry-run may also require it because the existing installation is root-readable. Do not loosen the permissions of protected maps or installed files. Instead, rerun the same preview with `sudo`:

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

MountWatchdog does not update itself. To update an existing maintained installation, fetch the new release in your repository clone and check out its exact tag. Replace `vX.Y.Z` with the release you intend to install:

```bash
cd mount-watchdog
git fetch --tags origin
git switch --detach vX.Y.Z
/bin/bash tests/run.sh
```

Before changing the installation, record its current version and cached read-only status:

```bash
sudo /bin/cat '/Library/Application Support/MountWatchdog/VERSION'
sudo /bin/bash '/Library/Application Support/MountWatchdog/status.sh' --status
```

Preview the update from the new release checkout. For a named selection, pass the complete existing mount-name set, not only names that changed.

If the new checkout supports `--all`, you may replace `Archive Studio` with `--all` in both update commands to select the whole current map. This can add mappings beyond your previous selection, so review the complete plan. Removing a previously selected mapping still requires `--replace-targets`, even with `--all`. To keep a subset, continue supplying its complete names.

```bash
sudo /bin/bash ./install_mount_watchdog.sh \
  --dry-run \
  --local-user "$(/usr/bin/whoami)" \
  Archive Studio
```

Review the reported source mode, local user, selected path/host/share tuples, prior service policy, and lifecycle decision. If the plan is correct, run the same command without `--dry-run`:

```bash
sudo /bin/bash ./install_mount_watchdog.sh \
  --local-user "$(/usr/bin/whoami)" \
  Archive Studio
```

The update validates the maintained manifest and installed checksums, creates a protected rollback backup, replaces the managed scripts and configuration, and restores the prior enabled/loaded policy. Record the emitted backup identifier. Use `--replace-targets` only when intentionally removing a previously selected mount, and use `--enable` only when intentionally changing a preserved disabled or unloaded service policy.

Afterward, repeat the version and read-only status commands above. A changed runtime fingerprint establishes a new baseline, so status may initially be unavailable or pending until the next scheduled tick.

The development installer and uninstaller fix a `v0.1.0` loaded-job identity parser bug that could reject valid jobs during upgrades, stopping, or removal. The first program argument was stored under an uninitialized AWK index. Use the corrected checkout's normal dry-run with the job still loaded; no manual unload is needed for this bug. A remaining identity error should be investigated before changing service state.

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
