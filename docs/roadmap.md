# Roadmap

MountWatchdog should remain a small native utility. This roadmap distinguishes the implemented development baseline from evidence and lifecycle work that still blocks a release candidate.

## Implemented development baseline

- One Bash 3.2-compatible maintained runtime, separate read-only status path, shared defaults, plist template, transactional installer, and conservative uninstaller replace the independent historical copies.
- Selected names, tab-delimited config, direct-SMB records, privileged artifact provenance, ownership, permissions, symlinks, and staging containment are validated before service or installed-file mutation.
- Fixture coverage includes first-start/reset safety, same-version code-fingerprint resets, monotonic status severity, clock and scheduling-gap handling, failed snapshots, terminal heartbeat severity, active-autofs-hook drift, missing and malformed map failures, credential-safe successful map detection, pending/cooldown and crash-window intent preservation, durable unmount/global-refresh record precedence, refresh-only retry, later-slot blocking, pre-action revalidation, bounded command groups, trusted orphan cleanup and incomplete-lock fail-closed behavior, credential-safe logs, narrow owner acknowledgment, dry-run non-mutation, shared lifecycle locking, privileged source and loaded-job identity, strict staged schemas and digests, path-preserving backups, in-progress and post-success rollback, temporary disable ordering, exact canonical service-policy restoration, append-only log preservation, ACL enforcement, and allowlisted removal.
- Committed install backups are bound to the resulting maintained manifest and can be consumed by an exact-ID post-success rollback. Resolved allowlisted manual-attention latches have an explicit owner action that performs only a read-only mount-table snapshot before state acknowledgment. Canonical deny-only ACLs are accepted on protected/source ancestors, while managed nodes are ACL-free and all allow/noncanonical ACLs fail closed.
- Public examples are fictional and credential-free; the runtime contains no intentional content probe, synthetic mount trigger, or forced-unmount fallback.

## Release blockers

- Define an owner-reviewed inspection and recovery procedure for stale lifecycle locks, incomplete runtime locks, unsafe temporary residue, and other retained fail-closed evidence. Automatic cleanup is intentionally limited to exact trusted cases.
- Design and review a strictly allowlisted command-diagnostic detail field if numeric exit status plus semantic error categories are insufficient; never persist raw stderr that may contain paths, sources, or credentials.
- Close the material synthetic gaps listed in [Testing](testing.md), or record an explicit owner acceptance for each gap after exact-candidate review.
- Review the exact rollback, acknowledgment, and ACL implementation as part of the release candidate and validate those paths on the target macOS release. Fixture behavior is not native lifecycle evidence.
- Run and record the final local suite on macOS `/bin/bash` 3.2, inspect the exact diff, and obtain actual hosted CI results. A checked-in workflow alone is not CI evidence.
- Inspect each target Mac's installed checksums, plist/job definition, enabled/loaded state, selected metadata, and provenance. Resolve any unmanaged installation outside this repository before using the maintained installer.
- Complete the owner-authorized native acceptance checks below before calling the utility production-validated.
- Obtain owner decisions before deployment, publication, release, or choosing a license.

## Owner-authorized release-candidate checks

After the repository gates pass, use a controlled maintenance window to validate launchd registration/disabled-state behavior, reboot-created state, periodic scheduling, one approved outage/return transition, sleep/wake heuristic reporting, busy normal-unmount handling, and the owner's manual application access after recovery. These checks cannot be replaced by CI and are not authorized by repository implementation alone.

## Optional later enhancements

- Complete the [researched local Open Directory migration](open-directory-migration.md): add credential-safe effective-map inspection, validate the exact record schema on the target macOS release, prove rollback, and obtain separate owner approval before creating a record or refreshing autofs. `/etc/auto_smb` remains unchanged.
- Deterministic generation of a standalone installer from maintained source, with checksums and no network-fetched executable code.
- Optional pinned lint/format checks that do not become runtime dependencies.
- More structured credential-safe diagnostic export and log-rotation guidance.
- Additional direct-map grammar only when backed by concrete fixtures and a real deployment need.
- Notifications or fleet-oriented reporting only after the local state/action model is stable and the owner asks for them.

## Explicitly deferred

A GUI, package-manager distribution, automatic updates, arbitrary autofs grammar, NFS, custom SMB ports, URL-encoding generalization, a universal timeout daemon, automatic content-health probes, synthetic mount triggers, NAS writes, force-unmount fallbacks, broad permission grants, and credential management are outside the initial product.
