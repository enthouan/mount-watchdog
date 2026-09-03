# Troubleshooting

Use the dedicated status command for observation. Never invoke the installed `watchdog.sh` merely to inspect a machine: it runs a normal tick and can enter recovery logic.

For an installed copy, use the dedicated installed status script:

```bash
sudo /bin/bash '/Library/Application Support/MountWatchdog/status.sh' --status
```

The maintained status source intentionally rejects a noncanonical production path, so invoking the repository copy directly is not an installed-machine diagnostic. `sudo` may be necessary only because the established installed config and state paths are root-readable. The status implementation itself is read-only: it must not create state, contact port 445, unmount, refresh autofs, start/stop launchd, or run a tick.

## Reading a status

Observation state and recovery state are separate. The command prints `check_scope=mount-table-and-tcp` and `readability=not-tested` once for the whole invocation; those limits apply to every following mount report.

The stable top-level record families are `MountWatchdog version=...`, `check_scope=... readability=...`, `job=...`, and one heartbeat result (`heartbeat=...` or `heartbeat_phase=... heartbeat_result=... heartbeat_age_seconds=...`). A trusted cache may additionally emit `blocked_command=...` and `autofs_refresh...` records. Each selected mount then starts with `mount=... path=... expected=...` and reports `state`, `pending_recovery`, `action_state`, last-attempt fields, `last_successful_action`, and any durable-unmount overlay. Consumers should match keys rather than line positions; optional evidence is absent when no corresponding record exists, and an unsafe cache can terminate before every family is available.

| Field/value | Meaning |
| --- | --- |
| `mounted-reachable` | The exact expected `smbfs` layer was listed and the limited host TCP check succeeded. It does not prove readable content. |
| `mounted-unreachable` | The expected layer was listed but port 445 was not reachable during the observation. The mount is left untouched. |
| `mounted-reachability-unknown` | The expected layer was listed, but the bounded TCP observation did not produce a trustworthy reachable/unreachable result. |
| `trigger-only` | The expected autofs trigger exists without a mounted SMB layer. Normal user/application access may mount it; no content probe is issued. |
| `trigger-missing` | The expected trigger was not observed. A rate-limited, coalesced refresh may be pending. |
| `unexpected-mount` | A wrong SMB source or non-SMB filesystem occupies the path. Recovery is blocked. |
| `ambiguous-mount` | More than one exact expected layer or another non-unique mount-table shape was observed. Recovery is blocked. |
| `inspection-error` | The mount snapshot failed or could not be trusted. This is never interpreted as an absent mount. |
| `pending_recovery=network-restored` | A previously observed network outage ended and scoped recovery remains pending. |
| `pending_recovery=scheduling-gap` | A long scheduling delay was observed. This is a heuristic, not confirmed wake evidence. |
| `pending_recovery=multiple` | More than one applicable reason was retained; it is not silently reduced to a single diagnosis. |
| `action_state=deferred-cooldown` | The reason remains pending until another attempt is eligible. |
| `action_state=deferred-network` | Recovery remains pending because the fresh network observation is not reachable. |
| `action_state=deferred-command-block` | A surviving or unverifiable command group globally gates later mutations. |
| `action_state=unmount-required` | A normal unmount remains pending, including after an ordinary busy or failed attempt. |
| `action_state=refresh-required` | A coalesced system-wide autofs refresh remains pending or failed verification. |
| `action_state=configuration-drift` | The installed selection is no longer provably reachable through the supported explicit master-map hookup. No recovery command is allowed. |
| `action_state=canceled` | Revalidation showed that the prior recovery action was no longer relevant. |
| `action_state=manual-attention` | An unsafe state, timeout, inspection/verification failure, or unexpected layer requires review. |

Most `manual-attention` results remain latched after the immediate cause is fixed. Reinstall and remove preserve runtime state, and ordinary runtime ticks do not guess that a latch is safe to clear. Use the narrow owner acknowledgment procedure below only after reviewing the cause; never delete state by hand or run an ordinary tick merely to try to clear it.

`heartbeat=input-mismatch` or `state=input-mismatch` means the cached result belongs to different config/default/version or maintained-code inputs and is intentionally not presented as current. `heartbeat_result=pending` is operationally pending; `configuration-drift`, `manual-attention`, or `blocked-command-*` is severity 2; and `inspection-error`, `state-write-error`, `clock-error`, `internal-error`, or an unsafe-state result is severity 3. A catchable service-stop signal may leave `heartbeat_result=interrupted`; an unexpected post-start shell exit makes a best-effort terminal `internal-error` record instead of silently leaving an in-progress heartbeat. `state_cache=unsafe` rejects an untrusted state path. `blocked_command=recorded` means a prior bounded command may still have a live process group; later ticks fail closed globally and never kill a process from persisted identifiers.

Status exit codes are diagnostic severity, not SMB-readability results: `0` means the available cache has no reported pending/manual condition, `1` means unavailable, stale, unregistered, or pending information, `2` means configuration drift, manual attention, or a recorded blocked command, and `3` means the status input/cache itself could not be trusted or used. The exit code is the maximum severity across job, heartbeat, global refresh, blocked-command, journal, and every mount record. Later unavailable or pending evidence cannot downgrade an earlier severity 2 or 3 result.

`last_attempt`, `last_attempt_result`, `last_attempt_exit_status`, and `last_successful_action` are intentionally distinct. The numeric exit status belongs to the last attempted external recovery command; `not-run` or `unknown` means no trustworthy command status was available. Raw command stderr is not copied into durable status or logs because it can contain private path or source text. A successful process exit or recent heartbeat does not prove every mount is useful.

### Durable unmount and refresh records

Before a normal unmount, the runtime writes a per-mount `unmount-attempt` journal. Its writer-produced phases are `attempting` and `complete`; complete results distinguish verified unmount, busy/nonzero failure, timeout, supervision failure, and verification failure. Status overlays a valid equal-or-newer journal on cached attempt fields so a crash cannot hide the most durable action evidence. An exact later committed `normal-unmount-and-autofs-refresh` success supersedes the completed journal; status reports `durable_unmount_attempt=superseded` as inactive residue but never unlinks it, while a trusted runtime tick performs retirement.

An equal-epoch journal that conflicts with committed fields is reported as `conflicting`, forces `action_state=manual-attention`, and has severity 3. A different runtime fingerprint is `input-mismatch` at severity 1; an unsafe, malformed, future-dated, or clock-rollback journal is severity 3. An older unsuperseded journal with `refresh_required=1` remains visible. It preserves the newer cached attempt metadata but, when the cache would otherwise say idle/no pending work, exposes the retained pending reason with `action_state=refresh-required` and severity 1.

The global `autofs-refresh` record has separate semantics. `attempting/unknown` is pending at severity 1, `completed/0` adds no error severity, and `failed/<nonzero>` is severity 1 with any recorded per-mount refresh obligation still pending. `timed-out/124` and `supervision-failed/125` are global manual-attention latches at severity 2; later runtime ticks fail closed until the owner uses the reviewed acknowledgment path after resolving and inspecting the cause. `completed/0` confirms only that `automount -c` exited successfully; per-mount fields carry subsequent mount-table verification, and none of this proves SMB readability.

## Common conditions

### Missing or stale heartbeat

First determine whether the LaunchDaemon is registered and whether the heartbeat belongs to the installed version. A missing state file immediately after reboot can mean the first tick has not completed; it is not by itself proof of an SMB outage. Do not invoke the installed runtime to manufacture a fresh heartbeat during diagnosis.

### Expected mount is not present

A valid idle autofs trigger is normal. MountWatchdog intentionally waits for legitimate access and does not run `ls`, `stat`, `test -d`, or any synthetic access to trigger the share. After an authorized normal unmount, the owner or application must perform the next real access.

### Normal unmount is busy

MountWatchdog does not escalate to a forced unmount. An ordinary busy result preserves the pending reason with `action_state=unmount-required`, records `last_error=normal-unmount-busy`, and rate-limits later attempts. A command timeout or unsafe verification path can instead require manual attention. Close or identify applications using the share during an owner-approved maintenance window; do not kill processes by broad name.

### Autofs refresh failed

A failed `automount -c` is an action error, not a successful remount. The command operates at system scope, so refresh requests are coalesced and limited. An ordinary nonzero failure remains retry-pending; timeout or supervision failure is a global manual-attention latch and blocks later mutations. Inspect the credential-safe result/exit status and installed macOS command behavior before any owner-reviewed retry.

### Autofs configuration drift

`action_state=configuration-drift` means the runtime refused recovery before touching a mount. `last_error=autofs-hook-missing` is the expected signature when a macOS update restores the stock `/etc/auto_master` and removes `/- auto_smb`. The other sanitized reasons distinguish an invalid master map, missing or invalid `auto_smb`, and a selected tuple that no longer matches the map. Do not invoke the runtime or `automount -c` repeatedly; inspect the two protected files without pasting their raw credential-bearing records. Restoring a file hook or attempting the [future Open Directory migration](open-directory-migration.md) is a separate owner-authorized system change.

### A resolved manual-attention latch

Run the read-only status command first and investigate the recorded error. After the cause is resolved, the installed runtime exposes one explicit owner action:

```bash
sudo /bin/bash '/Library/Application Support/MountWatchdog/watchdog.sh' --acknowledge-manual-attention
```

This is not a general reset. It refuses configuration drift, active/unverifiable command evidence, durable unmount journals, unsafe or stale-input state, unexpected/ambiguous mount layers, and error reasons outside its reviewed allowlist. It takes one read-only mount-table snapshot but performs no TCP probe, mount-path access, unmount, autofs refresh, or service mutation. It preserves attempt/success history, marks eligible latches idle, records a pending heartbeat, and leaves normal observation to the next scheduled tick. Run status again after that tick; if the command refuses, preserve the evidence rather than deleting files.

### A lock remains after interruption

The runtime tick lock is `/var/run/com.antoinemenard.mount-watchdog/.tick.lock`. A trustworthy live owner or live command guard prevents overlap. A later tick can reclaim a complete, trusted dead-owner lock only after proving that no guarded process group remains; an absent or malformed owner, unsafe metadata, or unverifiable live group fails closed before heartbeat or observation. Do not remove this directory based only on a stale-looking PID.

`/private/var/db/MountWatchdog.lifecycle.lock` is different: it serializes installer and uninstaller mutations and is never auto-reclaimed. A lifecycle lock left by `SIGKILL` or power loss requires owner inspection of the interrupted transaction and protected backup evidence. Neither lock is cleared by runtime owner acknowledgment, and version `0.1.0` still has no general manual-reset command.

### Unexpected source or filesystem

Do not unmount it through MountWatchdog. Compare the installed credential-free config with the intended direct map without printing a raw potentially credential-bearing map record. Resolve the ownership/source ambiguity manually before recovery is enabled again.

### Port 445 reachable but application still fails

This is compatible with `mounted-reachable`: the check does not authenticate SMB or read a file. MountWatchdog deliberately cannot diagnose every server, credential, stale-session, Finder, or application failure. Use an owner-directed manual application check; do not broaden the daemon's permissions or add an automatic content probe as a workaround.

## Logs and privacy

The established log is `/var/log/mount-watchdog.log`. Transition and action errors should be actionable but credential-free. Raw helper stdout/stderr is not copied into durable status, heartbeat, or log fields; it exists transiently in root-only capture files beneath the `0700` runtime state directory. Normal command completion removes those files, and catchable shutdown supervises the active command group before exit. A trusted next tick removes only exact recognized temporary names that are safe regular single-link files before making any observation.

`SIGKILL`, power loss, or an interrupted catchable shutdown can leave a capture file until that next trusted cleanup. Such residue can contain private helper output, so keep the state root protected. A managed-looking symlink, hard link, wrong owner/mode, or other unsafe residue is not deleted: runtime and read-only status fail closed so the owner can inspect it. Never paste raw direct-map lines, captured stderr, protected backups, or historical credential-bearing scripts into an issue or public report.
