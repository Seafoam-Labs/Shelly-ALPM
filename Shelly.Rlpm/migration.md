# In-place file migration

`Transaction.addMigration(rlpm.Migration.Request)` adopts an existing regular
file or symlink into a package installed by the same transaction. It preserves
the existing object, contents and attributes. The path need not appear in the
incoming archive. Requests are exact, canonical root-relative paths; there is
no wildcard expansion, recursive directory adoption, rename or copy operation.

Declare requests before `prepare()`. Preparation resolves package identities;
preflight validates ownership and existing objects. Requests are copied into
transaction-owned storage. A missing destination, including a target skipped
by `NEEDED`, is an error.

## Devario system integration example

The example follows
[`devario-system-integration`](https://github.com/Seafoam-Labs/devario-custom-packagbuilds/tree/59f2d8e179437bdcaa782d68ac31400a64c08fe4/devario-installer/devario-system-integration)
in `devario-custom-packagbuilds`. Its PKGBUILD declares a replacement/conflict
with `devario-aqueous-desktop`; `files.tsv` supplies GPU helpers, services and
UWSM configuration. The paths below come from that inventory.

```zig
const tx = try owner.initializeTransaction(io, .{});
defer owner.releaseTransaction() catch unreachable;
try tx.addTarget("devario-system-integration");

// For an installation replacing devario-aqueous-desktop, preserve these
// previously packaged files instead of extracting new bytes over them.
for ([_][]const u8{
    "usr/lib/devario/gpu-driver-setup",
    "etc/xdg/uwsm/env.d/60-devario-gpu.sh",
}) |path| {
    try tx.addMigration(.{
        .package = "devario-system-integration",
        .path = path,
        .source = .{ .replaced_package = "devario-aqueous-desktop" },
    });
}

try tx.prepare(); // normal replacement/conflict question must be accepted
try tx.preflight();
for (tx.manifest().?.adoptions.items) |adoption| {
    // Review path, source (null means unowned), destination package and backup.
    _ = adoption;
}
try tx.commit();
```

For a file previously placed by an installer without a package record, use
`.source = .unowned` (the default). The frontend must choose the source from
the actual installed state; rlpm does not fall back from a mismatched owner to
an unowned claim. A same-name upgrade may name its previous package as the
replacement source. An unrelated explicit removal does not authorize transfer.

The requests above deliberately preserve the old helper/configuration even
though the current package supplies those paths. Callers should select only
paths whose existing bytes they intend to retain. For ordinary package updates,
omit the migration request and use normal extraction/backup behavior.

The hermetic fixture uses these package names and paths with inert payloads.
It also omits them from a generated incoming archive to exercise adoption of
archive-absent files. No production PKGBUILD changes or migration declarations
are inferred from this example. This API is an RLPM extension; CLI/PKGBUILD
syntax and automatic frontend policy are not introduced.

## Validation and backups

- An unowned claim must have no installed owner. A replacement claim must have
  exactly the expected owner and a confirmed relationship to the destination.
  Competing archive claims and aliases through symlinked parents are rejected.
  Overwrite and NOCONFLICTS do not relax these checks.
- A missing path fails unless `optional = true`. Optional missing paths create
  no adoption; normal archive payload installation can still supply the path.
- Directories, special files and incompatible archive file types are rejected.
  Existing symlink leaves are adopted without following their target. Hardlink
  archive entries cannot use an adopted path as their source.
- DBONLY and DOWNLOADONLY cannot accept explicit migration requests. DBONLY
  cannot upgrade a package carrying archive-absent adoption metadata. Overlapping
  NoExtract rules fail. Adoption keeps the existing file even under NoUpgrade.
- Replacement backups retain their original baseline hashes. Otherwise an
  incoming archive's backup declaration supplies its distributed hash. For an
  unowned regular file absent from the archive, `backup = true` records the
  current hash as its initial baseline. Symlink backups are unsupported.

Preflight records leaf and ancestor observations. The executor preserves adopted
leaves and their necessary ancestors during removal, skips their archive
extraction, and checks their state after pre-transaction hooks, pre-package
scripts, removal post-scripts, and before publishing local records. A changed
object fails with `StaleFilesystemState` and a migration path diagnostic.
Path hook matching includes adopted paths absent from the archive.

## Persistence, upgrades and failures

Every adopted path enters the ordinary `%FILES%` inventory. Paths absent from
the archive also enter the local-only `%RLPM_ADOPTED%` section. Fresh Owners load
it through `Package.adopted_files`. Archive and repository inventories, signatures
and mtree contents remain descriptions of the distributed package; adoption
does not turn local contents into verified archive data.

RLPM carries existing marked files and backup hashes through subsequent
upgrades, reinstalls and downgrades without repeating the request. A deleted
marked file is dropped from the next inventory. When a future archive supplies
the path, normal extraction and backup rules take over and the marker disappears.
Uninstall uses normal removal/pacsave rules. Other package managers can read the
ordinary ownership inventory, but retention across upgrades requires RLPM;
libalpm does not implement `%RLPM_ADOPTED%` retention.

`tx.execution.adoptions_planned` and `adoptions_committed` report progress; the
manifest retains each path and its source/destination. Ownership is committed
only when the destination record is published. Existing record journaling and
recovery apply; there is no full filesystem or cross-package rollback.

Replacement removal can finish before destination installation fails. Adopted
files remain in place but can then be unowned. Review the retained execution
report and fresh database state before retrying with an explicit unowned claim.
Do not silently broaden a failed replacement claim.

## Validation

`zig build test-migration` runs the Devario fixtures, ownership/type/alias checks,
upgrade and uninstall lifecycle, backup handling, cancellation, publication and
partial-replacement failures, and allocation-failure sweeps. It is included in
`zig build test`. `test-executor-integration` adds real hook/scriptlet mutations
in disposable user-namespace roots. Run both in Debug and ReleaseSafe.
