# Package execution and local persistence

The executor implements normal `Transaction.commit()`;
`capabilities().transactions` is enabled. PackageManager still uses libalpm.
Shelly implements runtime selection between libalpm and RLPM, both enabled in
default builds, plus an optional libalpm-disabled build that defaults to RLPM.
See the [backend build and acceptance
contract](../docs/native-package-backends.md). The
Owner/Database/Package/Transaction ownership model and CachyOS extensions remain
intact.

```zig
const tx = try owner.initializeTransaction(io, .{});
defer owner.releaseTransaction() catch unreachable;
try tx.addTarget("example");
try tx.prepare();
// Review tx.plan(); optional tx.preflight() leaves the transaction prepared.
try tx.commit();
const result = tx.result();
// Inspect result.warnings, tx.execution and tx.actions() before release.
```

Commit verifies the reviewed database snapshot and held lock, acquires packages,
loads sealed archives, checks filesystem effects, then starts pre-transaction
hooks. It processes resolved removals followed by additions. Package-operation
start precedes the pre-scriptlet. Removal's post-scriptlet and operation-done event
precede deletion of its old local record. Additions publish the new local record
and cache before their post-scriptlet and operation-done event. Upgrade,
reinstall and downgrade use the incoming script with new/old version arguments.
Successful package work is followed by ldconfig and post-transaction hooks.

The complete native event sequence for the 26 inert executor oracle cases is
replayed, excluding RLPM lifecycle and failed-phase diagnostic extensions.
Acquisition verifies sealed bytes before publishing the accepted batch's keyring
and integrity boundaries. Filesystem failure or cancellation does not produce a
transaction-done event or run post hooks. Action failures that libalpm treats as
nonfatal remain in `actions().outcomes` and contribute to `result().warnings`.
Configured audit files receive timestamped ALPM transaction/package records;
`use_syslog` enables audit forwarding. Audit failures are retained as warnings.

## Filesystem operations

Archive names are validated by preflight. Mutation resolves immediate parents
with `openat2(IN_ROOT | NO_MAGICLINKS)` and uses held directory descriptors.
Regular data, sparse extents, symlinks, directories and supported special entries
are extracted with libarchive into private sibling staging directories, then
published with descriptor-relative rename. Hardlinks use a held source inode.
No archive-controlled pathname reaches libarchive's disk writer. The parent
process's working directory and umask never change.

Extraction preserves native modes, ownership, times and extended attributes,
including file capabilities. The pinned add.c enables XATTR but **does not enable
ACL extraction**; RLPM uses the same flags. Sparse data blocks retain their offsets.
Device-node creation obeys kernel privileges. Existing shared directories retain
their attributes. Removal uses unlink/rmdir and preserves nonempty directories;
it never recursively removes payload trees. Transferred files are left for their
incoming owner. Root and database identities are checked at mutation boundaries.

Backup decisions use the current filesystem after hooks and pre-scriptlets, the
old recorded hash, and the actual extracted incoming hash. `.pacnew` creation,
refresh/removal of existing suffixes, `.pacsave` rotation, NoUpgrade, NoExtract
and NOSAVE follow the native fixtures. Backup hashes reflect actual extraction,
including hardlink and symlink targets. NoExtract retains inventory but leaves
its backup hash unset. Space estimates use serialized desc/files lengths,
block-rounded archive members, and staging/journal directories.

| Mode | Effects |
| --- | --- |
| Normal | Payload, records, scripts, hooks and linker maintenance |
| DBONLY | Record/member publication; no payload/conflict work; native scripts/hooks still run |
| DOWNLOADONLY with additions | Verified cache acquisition; no package/record/action execution |
| DOWNLOADONLY with only removals | Native removal path, including payload and record deletion |
| NOHOOKS / NOSCRIPTLET | Independent suppression; linker maintenance still applies |
| NOLOCK | Commit rejected |
| Read-only local database | Installed-state mutation and reason changes rejected |

## Durable local records and cache lifetime

Local format 9 records include compatible desc/files data, backup hashes,
validation, dates, reasons, install/changelog/mtree members and CachyOS
`INSTALLED_DB`. Newly serialized files are mode 0644 and record directories 0755.
Archive members retain their metadata with the native 0644 permission override.
`Owner.setInstallReason(io, reference, reason)` atomically persists a reason under
`db.lck` and invalidates local references; load the database again before querying
that Owner. A fresh Owner immediately sees the persisted reason.

A new record is fully staged outside `local/`, with files fsynced before
publication. Cooperating readers share the local directory flock; the publisher
holds it exclusively. A durable journal names the old/new records. The old record
moves into staging, the new record moves into local, and both directories are
synced before journal removal is synced as the commit point. Ordinary publication
errors attempt record rollback. Native clients continue to coordinate through
`db.lck`; readers ignoring that lock are outside the atomic publication contract.

An interrupted journal makes RLPM readers return `DatabaseRecoveryRequired`.
`Owner.recoverLocalDatabase(io, allocator, database_path)` acquires the normal
writer lock and restores the old coherent record idempotently. It also removes
abandoned staging with no journal. It never removes a foreign/stale `db.lck`;
resolve a dead writer's lock explicitly before recovery. This recovery concerns
local records, not package payload rollback.

Each successful publication rebuilds local identities. On failure the cache is
invalidated/reloaded from disk; a failed reload cannot advertise old cached
packages. Plan and manifest metadata are independent copies and remain valid
until release. Post hooks resolve dependencies against the new local state.

## Partial failure and evidence

`tx.execution` retains completed and remaining package IDs, current package,
boundary, path, mutation count, publication confirmation, cause, native extraction
message/errno and cleanup failures. `packages_committed` counts fully completed
package operations. `database_published` confirms the current record's successful
publication; it is not a payload rollback indicator. A failed fsync/recovery can
require journal inspection even if some files are already visible.

RLPM deliberately stops at a failed mutation instead of continuing to advertise
an extracted package after an error. Cancellation checks between data blocks and
operation boundaries can stop within a package sooner than native libalpm's
between-package interruption checks. The result remains failed/interrupted,
with partial work retained. Locks/resources are released by `releaseTransaction`.
No full filesystem rollback or crash-safe payload transaction is claimed.

## Batched payload durability

The executor registers each affected mount through a held readable directory
descriptor before its first payload mutation. Extraction, old-payload removal,
backup renames, and staging cleanup defer their writeback to a package barrier.
Registration deduplicates device/mount identities conservatively: bind mounts or
Btrfs subvolumes can cause more than one flush of a shared underlying filesystem.
If mount IDs are unavailable, registration retains distinct directory identities.

After an addition's payload and staging cleanup finish, `syncfs()` flushes each
registered target before the new local record is published. Upgrades share one
tracker across old-payload removal and incoming extraction. Standalone removals
flush before their existing post-scriptlet and operation-done events; their
database record is still removed afterward. DBONLY does not introduce a payload
barrier. Database members, local records, and the publication/recovery journal
retain their immediate `fsync()` ordering.

On a failed flush, execution stops at `payload_sync`, retains the affected path
and errno, and does not publish the current package's record. A successful flush
on one mount cannot make a failed multi-mount operation atomic. Cancellation is
checked before and after each flush and before database publication; a kernel
writeback wait itself may not be promptly interruptible. Scriptlet/hook writes
are outside the executor's tracked payload contract.

A crash before a package's barrier may lose more recent payload changes than
the former per-entry sync implementation. The old record can therefore describe
partially changed files, as with other interrupted payload work. Database journal
recovery restores coherent records, not package files. A committed record still
requires successful payload barriers followed by durable journal publication.

Entry-count progress is throttled and shared across upgrade removal/extraction.
The status `Finishing writes for <package>` precedes the barrier; it does not
estimate kernel flush completion. The execution report includes cumulative
`payload_work_ms`, `payload_sync_ms`, `payload_sync_targets`, and
`database_publish_ms`. Filesystem-wide `syncfs()` can also wait for unrelated
writes or report their writeback errors.

`test-executor` covers writeback errors, registration/allocation failures,
descriptor cleanup, cancellation on both sides of the barrier, backups,
DBONLY/NoExtract/empty packages, progress, and publication ordering. It is part
of `zig build test`. The namespace integration adds nested and bind mounts with
a separate database filesystem, including failure on the second flush.

One-time VM crash and performance validation is recorded in the
[payload synchronization report](../docs/rlpm-payload-sync-results.md).
The Python VM harnesses and guest-only test hooks were subsequently removed;
maintained coverage lives in the Zig executor and namespace integration suites.

For direct host-filesystem benchmarks in disposable roots:

```bash
RLPM_PAYLOAD_BENCH_MODE=immediate zig build bench-payload -Doptimize=ReleaseSafe
RLPM_PAYLOAD_BENCH_MODE=batched zig build bench-payload -Doptimize=ReleaseSafe
```

`RLPM_PAYLOAD_BENCH_FILES` defaults to 10000, `RLPM_PAYLOAD_BENCH_RUNS` to 3,
and `RLPM_PAYLOAD_BENCH_WORKLOAD` selects `headers` or `large`. The latter defaults
to four 8 MiB files. `RLPM_PAYLOAD_BENCH_ARCHIVE` optionally installs a specified
real archive into disposable roots with scripts, hooks, and dependency checks
disabled. The immediate comparison policy exists only in test binaries. Results
and reproducibility limits are recorded in the
[payload synchronization report](../docs/rlpm-payload-sync-results.md).

- `zig build test-executor`: full package cycle, 26 pinned native state/event
  cases, flags/backups, persisted reasons/provenance, transfers, recovery,
  cancellation, root replacement, audit, operation-boundary fault injection and
  real filesystem write failures. Included in `test`.
- `zig build test-executor-integration`: real chroot commits replay all 19 hook/scriptlet
  native traces, attributes/capabilities/sparse/ACL behavior, script-modified
  backup inputs, post-hook dependencies, private-tmpfs ENOSPC and device creation
  or its kernel denial. Missing namespace/mount support fails, never skips.
- `zig build test-executor-interop`: requires the pinned libalpm binary and
  alternates both implementations against generated private databases. It checks
  both directions, upgrades/downgrades/removal, exact local record contents
  (normalizing install time), attributes and backup outcomes. No host package
  database, hooks or services are used.

Run each in Debug and ReleaseSafe. CI runs the hermetic and namespace suites;
the pinned-binary interoperability gate is explicit because stock Arch CI does
not carry the frozen CachyOS build. These are executor validation results, not a
declaration of complete public libalpm parity: the overall ledger and production
acceptance remain open.
