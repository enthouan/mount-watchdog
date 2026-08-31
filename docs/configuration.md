# Configuration

MountWatchdog observes only mount names explicitly selected at installation time. The existing direct autofs maps remain authoritative; the installer reads the supported mapping metadata, validates every selected record, and renders a credential-free installed configuration. It never edits the maps.

## Installed `mounts.conf`

Each data record contains exactly four TAB-separated fields:

```text
name<TAB>absolute_path<TAB>host<TAB>share
```

The fields mean:

1. `name`: the stable local identifier and state-directory name;
2. `absolute_path`: the exact local autofs target;
3. `host`: a credential-free hostname or supported address used for the port-445 observation; and
4. `share`: the actual remote SMB share.

The local name and remote share are independent. A friendly local alias must not be used to infer the share. [The fictional example](../examples/mounts.conf) deliberately maps `Studio` to `Workspace`.

Blank lines are accepted. A full-line comment is accepted only when `#` is the first character. Inline comments, leading-space comments, extra fields, empty fields, and non-tab separators are rejected. The file is parsed as data and must never be sourced or evaluated as shell code.

The installed file is root-owned and restrictive. Runtime validation rejects unsafe POSIX modes, ownership, parent paths, hard links where relevant, or symlinks rather than continuing with an untrusted privileged configuration. Version `0.1.0-dev` does not yet classify macOS ACL entries that can grant write-like access despite a safe-looking POSIX mode; a reviewed ACL rejection/normalization policy is therefore a release and migration blocker.

The established volatile state root remains `/var/run/com.antoinemenard.mount-watchdog`. Before reading or creating state, the production runtime verifies macOS's exact root-owned `/var -> private/var` alias, its non-writable `/private` ancestors, and the physical `/private/var/run` parent. The standard root-owned `daemon` group-write bit on `/private/var/run` is a narrow platform exception; world write is rejected, and the MountWatchdog state directory itself must be a real root-owned `0700` directory with trusted leaves.

## Selected-name contract

The initial supported name grammar is intentionally narrow: names are at most 64 characters, the first character must be alphanumeric, and every later character must be alphanumeric, dot, underscore, or hyphen. The reserved names `.` and `..`, leading punctuation, separators, traversal, whitespace, control characters, duplicates, case-colliding names, and values that cannot stay inside the state root are rejected. Names are validated, not silently normalized into potentially colliding cleanup targets.

Selected target paths are derived from the explicit local user as `/Users/<local-user>/<name>`. The user must exist for a live install. An unexpected target elsewhere is rejected rather than guessed or rewritten.

## Supported autofs subset

The initial implementation requires the local `auto_master` file to contain exactly one `/- auto_smb` or `/- /etc/auto_smb` entry and supports simple credential-free extraction from records shaped like:

```text
/Users/testuser/Archive -fstype=smb,soft,noowners,nosuid ://192.0.2.10/Archive
```

See the fictional [`auto_master`](../examples/auto_master) and [`auto_smb`](../examples/auto_smb) files. The example addresses are reserved TEST-NET values and must not be contacted.

The installer validates the entire `auto_smb` file, not only selected records, so an unsupported unselected record also blocks installation. Every record must have exactly three whitespace-separated fields: the exact `/Users/<user>/<name>` target, one options token, and one `://[userinfo@]host/share` location. The options token must contain exactly one `fstype=smb` or `fstype=smbfs` atom; other atoms are accepted only when nonempty and limited to ASCII letters, digits, dot, underscore, equals, or hyphen. Existing options such as `soft`, `noowners`, and `nosuid` are observed, not added or removed. This is a narrow lexical contract, not an endorsement of every macOS SMB option spelling. Either accepted map spelling still produces an SMB mount that MountWatchdog classifies from the macOS mount table as `smbfs`.

Validation requires exactly one supported SMB mapping for each selected path. It rejects duplicate or case-colliding targets, conflicting active direct maps, explicit non-direct master targets equal to or above/below a selected path, non-SMB entries, missing host/share values, embedded ports, unsupported escaping or subpaths, ambiguous URL/userinfo forms, unexpected targets, and malformed records. Disjoint explicit master targets remain allowed. Hosts are at most 253 characters with DNS/IPv4-style labels of at most 63 characters; the initial subset does not accept IPv6 literals. Shares are at most 80 characters, start alphanumerically, and otherwise use letters, digits, dot, underscore, dollar sign, or hyphen. Local usernames are at most 64 characters and use the separately validated local-user grammar.

Two stock macOS records receive narrow treatment. A single `+auto_master` Directory Service include may coexist with the required explicit file hook, but it is not accepted as an alternative route to `auto_smb`; Open Directory expansion remains unsupported until the [future migration](open-directory-migration.md) has owner-approved native validation. A single `/- -static` entry is accepted only when `/etc/fstab` is absent or is a safe regular file with no active records; a symlink, including a dangling symlink, is rejected. Any other active direct map or include is rejected. These exceptions are residual inspection limits, not proof that no external mapping exists.

The runtime revalidates the supported hookup at tick start, immediately before each normal unmount, and immediately before a coalesced refresh. It requires trusted, single-link `/etc/auto_master` and `/etc/auto_smb` files, the exact explicit `/- auto_smb` or `/- /etc/auto_smb` entry, strict parsing of both maps, and one exact map tuple for every installed selection. Failure is configuration drift, not an outage: `autofs-hook-missing`, `autofs-master-map-invalid`, `autofs-selected-map-missing`, `autofs-selected-map-invalid`, or `autofs-selected-mapping-mismatch` is persisted without running a mount snapshot, TCP probe, unmount, or refresh. A later tick may re-evaluate the files, but it never repeatedly invokes `automount -c` while drift remains.

A parsing error identifies a sanitized line number or selected path and reason without printing the raw map line. A real map may contain credentials, including punctuation or encoded `@`, and must never be copied into config, logs, output, manifests, fixtures, or Git.

## Timing defaults

`config/defaults.conf` is the maintained source for these defaults:

| Setting | Default | Meaning |
| --- | ---: | --- |
| Interval | 60 seconds | Requested periodic launchd schedule; not a strict execution guarantee. |
| Scheduling gap | 120 seconds | Heuristic indicating a long delay; not proof of sleep or wake. |
| Attempt cooldown | 180 seconds | Minimum interval between recovery attempts, including failures. |
| Command timeout | 20 seconds | Supervisor wait bound for a slow external action; it does not guarantee termination of kernel-blocked I/O. |

Changing recovery aggressiveness requires explicit owner review. First startup, reboot-created state, clock rollback, or upgraded state must establish a baseline rather than being treated as a confirmed network transition.

## Runtime input identity

Cached state is bound to one runtime fingerprint. The fingerprint combines the installed config, defaults, and version inputs with SHA-256 identities for the maintained watchdog program and its common, runtime, and autofs libraries. A code-only change therefore changes the fingerprint even when `VERSION` is unchanged. Mismatched cached records are reported as stale input, and the next runtime tick establishes a fresh non-mutating baseline instead of replaying transition history from different code or configuration.
