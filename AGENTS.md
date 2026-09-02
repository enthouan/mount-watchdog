# MountWatchdog agent guidance

These instructions apply to this repository.

## Scope and safety

MountWatchdog is a small macOS autofs/SMB metadata monitor, not an SMB client, content-health checker, or general daemon framework.

- Do not run `sudo`, a live installer or uninstaller, the installed runtime, mutating `launchctl`, `umount`, `automount`, a NAS probe, or a reboot/outage test during repository development.
- Do not modify live autofs maps, SMB credentials, Keychain, TCC, SIP, installed watchdog files, system state, or managed mount contents.
- Never read, enumerate, `stat`, test, create, or remove content at a managed mount path as an automatic health check or mount trigger.
- Never force-unmount or add a hidden force fallback. A normal unmount is still a live mutation and belongs only in an explicitly authorized recovery path.
- Treat maps and runtime configuration as data. Never `source` or `eval` them, and never log credential-bearing source lines.
- Reject unsafe names, ambiguous mappings, unexpected filesystems, malformed records, unsafe symlinks, and containment failures before mutation.
- Preserve unrelated work and stop before deployment, commits, pushes, releases, or GitHub settings changes unless separately requested.

## Engineering contract

Target macOS `/bin/bash` 3.2 and native system tools. Do not add Bash 4/5-only syntax or a Homebrew runtime dependency. Keep command effects behind explicit adapters so fixture tests cannot fall through to absolute production executables.

The maintained runtime is `mount_watchdog.sh`, installed as `watchdog.sh`. Read-only diagnostics must use `mount_watchdog_status.sh`, installed as `status.sh`, and must not create state, probe the network, or take recovery actions.

Keep public examples fictional and credential-free. Do not copy live maps, logs, state, backups, host addresses, or older credential-bearing scripts into the repository.

## Validation and reporting

Run the nonprivileged local validation entry point from this directory:

```bash
/bin/bash tests/run.sh
```

Tests must own their temporary roots, use deterministic fixtures and fake command results, and fail immediately on forbidden actions. Linux fixture success is not native macOS launchd/autofs validation.

Report exact commands, platform and Bash version, checks actually completed, unavailable/manual checks, and unresolved risks. Never present a workflow file as evidence that CI ran or a metadata-only status as proof of readable SMB content.
