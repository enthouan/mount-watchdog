# Future local Open Directory migration

Status: researched design only. MountWatchdog does not implement this migration, no local Open Directory record was created or changed during repository work, and no command in this document authorizes doing so.

## Why consider it

The current deployment adds this direct-map record to `/etc/auto_master`:

```text
/- auto_smb
```

macOS updates have repeatedly restored that file and removed the customization. Apple's stock [`auto_master`](https://github.com/apple-oss-distributions/autofs/blob/main/files/auto_master) already contains `+auto_master`. Apple's [`auto_master(5)` source](https://github.com/apple-oss-distributions/autofs/blob/main/files/auto_master.5) describes a `+name` record as including a map obtained through Directory Service at that point. A local Open Directory record imported by the stock hook is therefore a plausible way to keep the master-map hookup outside the update-owned file while leaving `/etc/auto_smb` unchanged.

This is not needed for MountWatchdog's ordinary monitoring model, and it is not yet a supported configuration. The current runtime requires the explicit file entry and reports `autofs-hook-missing` when that entry disappears, even if `+auto_master` is present.

## Candidate record semantics

Apple's current open-source [`ns_od.c`](https://github.com/apple-oss-distributions/autofs/blob/main/automountlib/ns_od.c) queries `kODRecordTypeAutomount` records whose `kODAttributeTypeMetaAutomountMap` value matches the requested master map. For a master-map result, it reads the record name as the mount point and `kODAttributeTypeAutomountInformation` as the map/options field. Apple's Open Directory API also publishes the [`Automount` record type](https://developer.apple.com/documentation/opendirectory/record-types).

That source suggests this candidate local record, expressed as data rather than as a mutating command:

| Open Directory field | Candidate value | Purpose |
| --- | --- | --- |
| Record type | `Automount` | The record type queried by autofs. |
| Record name | `/-` | The direct-map mount-point marker. |
| `MetaAutomountMap` | `auto_master` | Makes the stock `+auto_master` lookup select the record. |
| `AutomountInformation` | `auto_smb` | Refers to the existing `/etc/auto_smb` map by its conventional name. |

The record must not contain SMB credentials, a NAS address, or an SMB share. Those remain solely in the existing protected `/etc/auto_smb` deployment file. Historical maps embedded credentials; that is deployment context, not a recommended credential-storage pattern.

These candidate values are an inference from Apple's source, not validated operational instructions. In particular, this repository has not established the correct local-node record path or quoting rules for the target macOS release, whether other directory nodes contribute conflicting records, or how the effective direct-map ordering behaves on both machines.

## Required validation before any migration

A future, separately approved maintenance session must complete all of the following on a real target Mac before a record is created:

1. Record the exact macOS version and inspect its stock `/etc/auto_master`, installed autofs manual pages, and relevant Apple source revision.
2. Produce a credential-safe, read-only inventory of local and effective `auto_master` Automount records. Prove that it cannot print `auto_smb` locations or user information before using it on a real machine.
3. Confirm that no existing Open Directory record, `-null` entry, other direct map, or directory-service node conflicts with the selected paths.
4. Define a recoverable backup/export and an exact rollback procedure for the local record, without copying `/etc/auto_smb` credentials into Git or ordinary logs.
5. Add a MountWatchdog inspection mode that can prove the selected map is reachable through the effective Open Directory result without mutating Directory Service or calling `automount -c`.
6. Add synthetic fixtures for valid, absent, duplicate, malformed, conflicting, and unavailable Open Directory results, plus credential-leak regression tests.
7. Obtain separate owner approval for the exact mutation and, separately, for any autofs refresh or live mount validation.

Only after the record exists under that approval should a controlled native check verify that the stock `+auto_master` path exposes the direct trigger and that legitimate user/application access still performs the on-demand SMB mount. The check must not proactively browse NAS content. A refresh reloads mapping metadata; it does not itself prove or initiate an SMB remount.

## Rollback boundary

Rollback would remove only the specifically created local Automount record and return to a separately approved master-map arrangement. It must not alter `/etc/auto_smb`, passwords, Keychain entries, mountpoint content, or unrelated Open Directory records. The exact deletion and restoration commands are intentionally omitted until the create/read/export semantics have been validated on the real macOS release.

Until those gates are complete, keep the explicit `/- auto_smb` line and let MountWatchdog fail closed if it disappears.
