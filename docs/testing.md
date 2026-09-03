# Testing

MountWatchdog's automated tests are nonprivileged simulations. They exercise parsing, state decisions, staged filesystem operations, selected command requests, rollback, cleanup, and cached diagnostics without touching live mounts, launchd domains, autofs maps, NAS hosts, or system directories.

## Command and platform

Run the canonical fixture harness from the repository root on macOS:

```bash
/bin/bash tests/run.sh
```

The harness requires and invokes all three fixture scripts: `test_common.sh`, `test_runtime.sh`, and `test_installer.sh`. A missing script fails the run. It syntax-checks maintained shell sources, renders and lints the plist, then runs the fixtures.

No third-party runtime or test framework is required. The full installer suite does rely on macOS-native `PlistBuddy`, `plutil`, and BSD `stat` behavior, so this command is not advertised as a portable Linux integration test. ShellCheck is an optional additional developer check and is not installed or invoked by the utility.

## Current fixture coverage

The common fixtures cover exact two-target config parsing, the distinct local `Studio`/remote `Workspace` mapping, safe-name and case-collision rules, path/user binding, malformed fields, unsupported host/share forms, inert-data parsing, canonical decimal timing defaults, strict state records, and Bash 3.2 nounset behavior.

The runtime fixtures cover safe first baseline; config/schema/version, same-version code-identity, and clock-reset baselines; scheduling-gap heuristics; stale, incomplete, unsupported-format, or corrupted cached status; maximum-severity aggregation; terminal heartbeat fallback; dangling/hardlinked/symlinked state and log containment; unsafe log modes; and failed mount snapshots. They specifically model an update-restored stock `auto_master`, a missing selected `auto_smb`, malformed master and direct maps, successful credential-bearing map detection without credential output, disjoint and overlapping `-static` fstab targets, malformed fstab data without source leakage, protected deny-only ACLs, rejected allow ACLs, and ACL-free managed state. They also cover bounded process-group timeout and signal handling, durable command-group/unmount/global-refresh records, equal/newer/older journal precedence, conflicting and stale-input journals, persisted exit status and recovery intent across crash windows, busy and refresh-only retry cooldowns, later-slot blockers, terminal record-write failure, trusted orphan cleanup, unsafe residue, dead-owner lock reconciliation, incomplete-lock fail-closed behavior, pre-action revalidation including changed fstab targets, refresh coalescing, host caching, unexpected sources, inherited-xtrace suppression, narrow owner acknowledgment with no recovery actions, and read-only cached status. The runtime suite also contains a limited source regression scan that permits `ls -lde` only inside ACL metadata helpers and rejects the explicit mount-content probe/forced-unmount spellings it knows about elsewhere.

The installer fixtures cover destination-read-only dry-run and explicit point-in-time plans, credential redaction, distinct local/remote names, exact `fstype=smb`/`fstype=smbfs` acceptance with mixed/duplicate/other/missing values rejected, privileged source trust, strict staged version/plist schemas, parent and managed-directory modes, canonical deny-only source/protected ACLs, rejected allow/noncanonical ACLs, ACL-free managed/backup nodes, a shared lifecycle lock, noncolliding path-preserving backup manifests, strict digest-command output, explicit-master overlap, narrow disjoint/static fstab acceptance, overlapping/malformed/dangling-fstab rejection without source leakage, injected, signal, QUIT, and unexpected-exit rollback, fail-closed incomplete restoration, temporary-disable ordering, disabled/loaded/unloaded policy preservation, literal disabled-label and tri-state loaded-state parsing, exact canonical loaded-job identity, strict map failures, staging/hardlink containment, maintained-manifest provenance, fail-closed unmanaged collisions, provenance-gated lifecycle commands, append-only log preservation, format-3 exact-ID post-success rollback for fresh and maintained-upgrade states, rejected tampered or unbound backups, incomplete post-success rollback latching/quiescence, allowlisted removal intent, and failed/aborted removal restoration.

## What the adapters prove

Runtime fixtures replace the seven expected external commands (`mount`, `nc`, `umount`, `automount`, `date`, `ps`, and `launchctl`) with contained adapters. Their action log lets a case assert exact requests and selected forbidden requests. Installer and uninstaller test hooks similarly record synthetic launchctl intent beneath a staging root.

This is not a general process sandbox. The adapters do not automatically intercept an arbitrary new absolute command, and the static scan does not recognize every possible way future code could read a mount path or force an unmount. The no-content-probe and normal-unmount-only rules therefore require fixture assertions, ShellCheck/source review, and exact-candidate review together; no single grep is presented as complete proof.

Each fixture owns a temporary directory and fictional TEST-NET metadata. Tests may create synthetic files below a staged mountpoint to verify that removal preserves them, but they never contact or inspect a real managed mount.

## Known automated-test gaps

Remaining synthetic gaps include additional non-SMB/ambiguous/prefix layer shapes, broader unsupported unselected-map/options records, backup failure before service stop, bootstrap-failure rollback, failure during multi-record owner acknowledgment, additional noncanonical/inherited ACL combinations, and more exhaustive positive command-argument assertions. The candidate records semantic error categories and numeric command exit status but deliberately excludes raw command stderr from durable diagnostics; a strictly allowlisted, credential-safe detail design remains unresolved.

Native checks remain separate: launchd disabled-state semantics, reboot recreation, real periodic scheduling, a controlled outage/return, sleep/wake behavior, a busy normal unmount, and manual application access after recovery. No ordinary fixture or CI run may perform those actions.

## Reporting evidence

A passing fixture suite establishes only the represented synthetic behavior. Record the exact command, platform, `/bin/bash --version`, case count, result, and skipped native checks in completion reports. A workflow file in Git is not evidence that GitHub Actions ran.
