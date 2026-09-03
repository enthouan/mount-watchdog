# MountWatchdog

MountWatchdog is a small macOS `autofs`/SMB mount-state monitor and conservative recovery helper. It manages only mount names selected by the operator and leaves the existing autofs maps in charge of credentials and on-demand mounting.

This tree is version `0.1.0-dev`. It is unreleased, has not been production-validated, and is not deployment-ready. The development baseline includes fixture-tested post-success rollback, narrow owner acknowledgment for resolved `manual-attention` latches, and a fail-closed macOS ACL policy. Exact-candidate review, remaining synthetic gaps, live target inventory, native lifecycle/recovery validation, and the other items in the [Roadmap](docs/roadmap.md) still block deployment. Building or testing the repository does not authorize installing it on a Mac, restarting a service, unmounting a share, or changing autofs.

## What it can observe

The runtime compares the local mount table with credential-free host/share metadata and checks whether the host accepts a TCP connection on port 445. A `mounted-reachable` result therefore means only:

- the expected `smbfs` layer appears at the exact configured path; and
- the configured host accepted the limited TCP reachability check.

Every status also reports `check_scope=mount-table-and-tcp` and `readability=not-tested`. MountWatchdog does not prove authentication, filesystem readability, server identity, application recovery, or a usable new SMB session.

## The autofs setup it accompanies

MountWatchdog observes SMB mounts that macOS autofs already defines. A supported setup has a direct-map entry in `/etc/auto_master`:

```text
/- auto_smb
```

The corresponding `/etc/auto_smb` records use absolute local paths. Historical deployments used this general structural form:

```text
/Users/<local-user>/<local-name> -fstype=smb,soft,noowners,nosuid ://<credentials>@<nas-host>/<remote-share>
```

`<credentials>` is a non-secret placeholder that documents deployment history only, not a recommended map pattern. This usable sanitized example omits credentials, uses a reserved TEST-NET address, and maps the local name `Archive` to a different remote share name, `Vault`:

```text
/Users/example/Archive -fstype=smb,soft,noowners,nosuid ://192.0.2.10/Vault
```

Local and remote names are independent. In this sanitized example, the local name `Studio` maps to the remote share `Workspace`; MountWatchdog therefore records both values and never derives the share from the local name. Some historical installations contained embedded SMB credentials in their maps. That is deployment context, not a recommended pattern or something to copy into this repository, logs, or diagnostics.

MountWatchdog never creates or edits `/etc/auto_master`, `/etc/auto_smb`, passwords, or Keychain entries. A recovery refresh asks autofs to reload already-defined mapping metadata; it does not browse the mount or proactively remount SMB. The next legitimate user or application access triggers the normal on-demand mount.

Every runtime tick first proves that the supported effective hookup is still present: the trusted master file must contain exactly one active `/- auto_smb` (or `/- /etc/auto_smb`) direct-map entry, the selected map must still be a trusted regular file, and each installed credential-free path/host/share tuple must still match it. The same check runs again immediately before every unmount and immediately before a coalesced `automount -c`. If a macOS update restores the stock master file and removes the direct-map entry, MountWatchdog reports `action_state=configuration-drift` with `last_error=autofs-hook-missing`, performs no mount snapshot or network probe, and runs neither `umount` nor `automount -c`.

Apple's stock master map imports Directory Service records through `+auto_master`. Moving the direct-map hookup into a local Open Directory automount record could make it survive updates to `/etc/auto_master`, while leaving `/etc/auto_smb` unchanged. That path is [research-only future work](docs/open-directory-migration.md): this release does not create, modify, or accept such a record as proof of the selected hookup.

## Safety model

MountWatchdog never reads, lists, creates, removes, or probes content below a managed mount path. It never force-unmounts. When a relevant transition makes recovery appropriate, it may request a normal unmount of a revalidated expected SMB layer and a coalesced `automount -c` refresh. The next legitimate user or application access performs the on-demand mount.

The utility does not edit `auto_master`, direct maps, SMB settings, Keychain, TCC, or SIP. Unexpected sources, non-SMB layers, ambiguous snapshots, and inspection failures block recovery rather than being guessed away.

Every privileged path is checked using both POSIX metadata and macOS ACL metadata. Canonical deny-only ACLs are accepted only on repository/protected-input ancestors where they can reduce access; any allow entry or noncanonical ACL is rejected. MountWatchdog-owned installed files, backups, locks, and runtime state must have no ACL entries. Newly created managed nodes are normalized to no ACL, while an ACL found later on an existing managed node fails closed rather than being silently removed.

## Repository layout

- `mount_watchdog.sh` is the maintained periodic runtime.
- `mount_watchdog_status.sh` is the separate read-only diagnostic entry point.
- `install_mount_watchdog.sh` and `uninstall_mount_watchdog.sh` own lifecycle operations.
- `config/defaults.conf` contains the shared 60-second interval, 120-second scheduling-gap heuristic, 180-second attempt cooldown, and 20-second supervisor wait bound.
- `packaging/` contains the LaunchDaemon template.
- `examples/` contains fictional, credential-free data.
- `tests/` uses synthetic fixtures and command adapters only.

The installation uses these locations:

```text
/Library/Application Support/MountWatchdog/watchdog.sh
/Library/Application Support/MountWatchdog/mounts.conf
/Library/Application Support/MountWatchdog/backups/
/Library/LaunchDaemons/com.antoinemenard.mount-watchdog.plist
/var/run/com.antoinemenard.mount-watchdog/
/var/run/com.antoinemenard.mount-watchdog/heartbeat
/var/run/com.antoinemenard.mount-watchdog/<name>/status
/var/log/mount-watchdog.log
```

The maintained implementation adds these installed artifacts and explicit state/lock leaves:

```text
/Library/Application Support/MountWatchdog/status.sh
/Library/Application Support/MountWatchdog/lib/common.sh
/Library/Application Support/MountWatchdog/lib/runtime.sh
/Library/Application Support/MountWatchdog/lib/autofs.sh
/Library/Application Support/MountWatchdog/defaults.conf
/Library/Application Support/MountWatchdog/VERSION
/Library/Application Support/MountWatchdog/install-manifest.tsv
/var/run/com.antoinemenard.mount-watchdog/blocked-command
/var/run/com.antoinemenard.mount-watchdog/autofs-refresh
/var/run/com.antoinemenard.mount-watchdog/.tick.lock/
/var/run/com.antoinemenard.mount-watchdog/<name>/unmount-attempt
/private/var/db/MountWatchdog.lifecycle.lock
```

`/var/run` resolves through macOS's trusted `/var -> private/var` alias. The volatile tick lock and durable action records belong to runtime recovery; the `/private/var/db` lifecycle lock serializes installer and uninstaller mutations. They have different recovery rules; see [Troubleshooting](docs/troubleshooting.md) and [Lifecycle and rollback](docs/lifecycle-and-rollback.md).

MountWatchdog installs nothing beneath `/usr/local` or `/opt/homebrew`. This keeps both Intel Homebrew's customary `/usr/local` prefix and Apple Silicon Homebrew's customary `/opt/homebrew` prefix outside its ownership and validation boundary. Launchd invokes the canonical root-owned runtime under `/Library/Application Support/MountWatchdog` directly.

The installed `watchdog.sh` runs a normal tick. It is not a status command and must not be invoked merely to inspect an installation.

## Safe local validation

From this directory, the canonical nonprivileged check is:

```bash
/bin/bash tests/run.sh
```

The test command syntax-checks maintained shell sources, validates generated artifacts when available, and runs fixture tests without `sudo`, live mounts, launchd mutation, system-directory writes, or NAS access. See [Testing](docs/testing.md) for evidence boundaries and the direct harness command.

Read-only installed diagnostics are provided by the dedicated status script; established root-only file modes require the owner to run:

```bash
sudo /bin/bash '/Library/Application Support/MountWatchdog/status.sh' --status
```

Read-only means it performs no tick, state creation, TCP probe, unmount, refresh, or service mutation.

The installed runtime also has an explicit, state-mutating owner command for a narrow class of resolved manual-attention latches. It is not a diagnostic shortcut; follow the review and eligibility procedure in [Troubleshooting](docs/troubleshooting.md) before using `--acknowledge-manual-attention`.

Before considering an owner-authorized deployment, review [Configuration](docs/configuration.md), [Lifecycle and rollback](docs/lifecycle-and-rollback.md), [Troubleshooting](docs/troubleshooting.md), and the [Roadmap](docs/roadmap.md). Always inspect each lifecycle script's `--help` output before running it.

## License

MountWatchdog is available under the [MIT License](LICENSE).

No public release, compatibility guarantee, successful CI run, or production recovery claim is implied by this development tree.
