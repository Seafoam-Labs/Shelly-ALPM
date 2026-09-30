# Filesystem and package preflight

The preflight API exposes `Transaction.preflight()`, `manifest()` and
`revalidatePreflight()`. `filesystem_preflight` and `transactions` are enabled.
The executor consumes this manifest in [normal commit](execution.md).

```zig
const tx = try owner.initializeTransaction(io, .{});
defer owner.releaseTransaction() catch unreachable;
try tx.addTarget("example");
try tx.prepare();
try tx.preflight(); // acquire packages if needed; inspect without extracting
const manifest = tx.manifest().?;
try manifest.check();
for (manifest.entries.items) |entry| {
    // package is an id in tx.plan(); path is relative to the configured root.
    _ = entry;
}
try tx.revalidatePreflight();
```

The transaction owns the manifest, archive snapshots, descriptors and all views.
Release frees them even after cancellation, verification failure or an
allocation error. Successful preflight leaves the transaction prepared. Repeated
preflight revalidates the existing result. Failure transitions to
failed/interrupted and retains `manifest.failure` and `manifest.conflicts` when
available. Start a fresh transaction to retry. DOWNLOADONLY has a separate
download commit path and rejects preflight. DBONLY loads and verifies full
archives and plans database changes, but omits payload conflict checks and file
effects.

## Packages and execution input

Preflight rechecks source-policy signatures/digests, name, version, architecture,
installed size, dependencies, provisions, conflicts, replacements and groups.
Local and remote archive loads retain their source kind; preflight uses the current
effective policy for that source. Repository
packages use the current registered policy, verified downloaded bytes and
detached signature. A portable archive whose source registration no longer exists
retains its explicit captured repository policy. Metadata-only packages acquire a sealed snapshot here.
`revalidatePreflight` reapplies verification because trust and detached signatures
can change even when the package bytes cannot.

Each selected archive is traversed completely, including payload data. Mtree
inventory must agree with actual payload paths and directory markers. The scanned stream supplies
file modes/sizes and actual scriptlet membership. Root-dot entries are separated
from payload; `.PKGINFO`, `.BUILDINFO`, `.INSTALL`, `.CHANGELOG` and `.MTREE` must
be regular files. Root metadata never becomes an installation-root operation.
The archive header index and sealed archive allow later phases to read the exact
entry, including ownership/timestamps and special-file metadata, without opening
the original pathname again.

The manifest contains:

- Ordered file effects: explicit removals, then each ordered upgrade's old-file
  removals and new payload. Actions distinguish install, replace, remove,
  preserve, shared directories, NoExtract, pacnew and pacsave.
- Implicit parent creation, conditional `rmdir`, pacsave rotations, backup MD5
  decisions and existing-pacnew refresh. Removing a directory never authorizes
  recursively deleting its contents.
- Database changes with installed inventory, backup hashes, final install reason
  and CachyOS installed-repository provenance. NoExtract paths remain in the
  installed file list, as in the reference.
- Structured target/target and target/filesystem conflicts with root-relative
  paths and package ids. `FileConflicts` is distinct from dependency conflicts;
  NOCONFLICTS does not suppress these checks.
- Filesystem observations, access checks, capacity estimates and warnings.

Ownership includes every local file inventory, not just selected packages. Missing
local file records fail preflight. Shared directories, old ownership, scheduled
removals and transfers between upgrading packages affect conflict decisions.
Replacing a directory requires eligible directory owners and ownership of every
existing descendant. Overwrite cannot authorize replacement of an unowned tree.

## Patterns and backups

`Owner.matchNoExtract(path)` and `matchNoUpgrade(path)` return `PathPatterns.Match`:
`unmatched = -1`, `matched = 0`, `excluded = 1`. Lists are tested in reverse order,
so the last matching rule wins. Leading `!` negates; a leading backslash escapes
that position. The libc `fnmatch` flags are zero: `*` spans slashes and matches
leading dots, and trailing directory slashes matter. Overwrite accepts either a
relative-path match or a full rooted-path match. Thus a full-path wildcard can
still allow overwrite after a relative-path exclusion, matching libalpm.

NoExtract skips extraction but does not bypass file conflict checks. NoUpgrade
preserves an existing file and selects `.pacnew`, even for identical contents;
an absent destination installs normally. Backup comparisons follow the native
old/local/new order: matching local/new replaces, matching old/new preserves,
matching old/local replaces, otherwise a pacnew is planned. Modified removed
backups become pacsave unless NOSAVE is set. An existing pacnew can be refreshed
even when the local file is preserved. The manifest records that separate effect.

## Confinement and mutable state

Linux `openat2(RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS)` resolves paths relative to
a held root descriptor. There is no unconstrained fallback on unsupported kernels.
Absolute symlink contents stay literal; followed links resolve as inside a chroot.
Archive absolute paths, internal dot/dot-dot components, duplicate payload paths,
invalid hardlink targets and inconsistent inventories are rejected. Hardlinks must
resolve to regular payload in the same archive; cycles and excluded sources fail.
Existing symlinked directories are supported and their observations are retained.
Targets that simultaneously require a leaf and a directory ancestor conflict.

Root/database identity, inode, mount identity when available, kind, mode, ownership,
size and modification/change timestamps are checked again before execution.
Backup content reads follow only confined paths. Mount and parent access checks
are repeated, including sticky-directory ownership and read-only file mounts.

Preflight does not make later pathname writes race-safe. The executor must
consume the manifest through confined parent descriptors, use no-follow
temporary outputs and descriptor-relative publication, revalidate after
pre-transaction hooks, and check each operation against its expected state. It
must update those expectations as its own operations change the filesystem. A
stale or failed transaction cannot authorize extraction. Preflight does not
write installed payloads.

## Space checks and compatibility boundaries

Affected paths are inspected with `fstatvfs`; requirements aggregate by filesystem.
Ordered removals credit regular-file blocks, and staging is reserved before a
replacement is credited. Preserved backups/pacsaves retain their space. Implicit
directories, symlinks and database record staging are included. Database paths may
be on a different filesystem from the installation root. Read-only mounts and
known access failures reject work. Unavailable capacity is retained as a warning
and skipped, matching the native unknown-capacity policy.

`check_space` applies the native cushion, the smaller of roughly five percent of
capacity and 20 MiB. RLPM deliberately estimates more conservatively than libalpm's
payload-only peak: it includes staging, directory/link allocation, actual serialized desc/files lengths, block-rounded
archive members and publication staging/journal directories. This can reject a near-full filesystem that libalpm accepts. Access
failures are also reported earlier than native extraction. Stricter archive and
mtree consistency checks are intentional safety differences from permissive
metadata loading, which remains unchanged.

## Evidence

`zig build test-preflight` runs 19 hermetic tests, also included in `test`. They
cover conflict classes, shared/transitioning directories, transfers, backup and
pattern decisions, source identity/dependency substitution, signatures required
for raw metadata-only targets, confined links, stale state, DBONLY, cancellation,
allocation failure, a 2,048-file inventory and CachyOS repository provenance.

The [pinned oracle](src/tests/reference/preflight.json) records 15 native outcomes
in disposable roots. Its independent recorder commits only generated inert
`conf` payloads, with hooks and scriptlets disabled and root/database/flag guards
immediately before commit. Normal tests project manifest decisions into expected
contents and inventory without running an RLPM executor or loading libalpm.

The real GPG suite adds remote-policy retention and rejection of a changed
detached signature during revalidation. Executor tests cover actual payload
extraction, metadata attributes and ENOSPC on a private tmpfs; preflight tests
retain controlled space/read-only boundary checks. Download sandbox tests now
pass inside a subordinate-ID namespace, including credential changes. See
[execution.md](execution.md) for executor validation results; full backend
equivalence remains a production acceptance gate.
