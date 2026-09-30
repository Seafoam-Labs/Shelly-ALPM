# Package metadata and relations

RLPM supplies the shared metadata model and archive/relation primitives. The
[database backends](databases.md) add local format validation, lazy
descriptions, files/backup/member correlation, and tar/CachyOS SQLite ingestion.

## Sources, sizes and ownership

`Package.origin` distinguishes `.local`, `.sync` and `.archive`.
`database_name` identifies the current database association; an archive uses an
empty string. CachyOS `installed_database` independently retains `%INSTALLED_DB%`,
including a repository that is no longer configured. Missing provenance remains
null. `archive_path` is the input archive location; `repository_filename` is the
repository's `%FILENAME%` value. Neither overwrites the other.

| Field | Meaning |
| --- | --- |
| `compressed_size` | Repository `%CSIZE%`, or the archive's file size |
| `installed_size` | `%SIZE%`/`%ISIZE%`, or `.PKGINFO`'s installed size |
| `download_size` | Remaining transfer after cache planning; null for unplanned sync metadata, zero for local/archive metadata; download planning computes cache effects |
| `md5_sum`, `sha256_sum` | Recorded digest strings; checked by `Owner.loadPackage` using repository metadata |
| `base64_signature` | Recorded encoded signature; `decodeSignature(allocator)` returns caller-owned bytes or null when absent |
| `validation` | Performed checks for `Owner.loadPackage`, historical flags for local packages; unverified archive/sync metadata sets `none`; sync promises use `availableValidation()` |
| `install_reason` | Explicit, dependency or unknown; missing metadata defaults to explicit, matching the reference |
| `files` | Sorted file records: name, optional size/mode, kind and link target |
| `backups` | File names and optional installed-content hashes; archive backup declarations have no hash yet |

Database file lists do not contain sizes or modes; these remain null rather than
invented zero values. File inventories retain directory terminal slashes.
`findFile` performs exact lookup in a normalized package's sorted inventory.
`files_loaded` distinguishes an empty inventory from one not loaded, while
`files_source` records database, archive or mtree provenance. Stored validation
flags, digests and decoded signatures do not establish current file integrity.
The [verification guide](verification.md) describes policy-aware loading and
retained immutable archive readers.

Description parsing borrows input strings and owns only temporary list storage.
Conversion now explicitly requires an enclosing arena and a source:

```zig
const rlpm = @import("Shelly_Rlpm");
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
var parsed = try rlpm.ParsedDescription.parse(allocator, description_bytes);
defer parsed.deinit(allocator);
const package = try parsed.intoPackage(&arena, .{
    .origin = .sync,
    .database_name = "cachyos",
});
```

Conversion copies every string, relation, file and backup record. Input buffers
and parser storage may be released immediately afterward. Conversion leaves the
parser unchanged. Releasing the enclosing arena reclaims all allocations from
successful and unsuccessful conversions; a general allocator no longer implies
a standalone package ownership contract. Archive loading creates its own arena:
call `Package.deinit` once for each successful load. Do not shallow-copy owning
packages, streams or iterators and then release both copies.

## Relations and versions

`PackageRelation.parse(text)` returns a borrowed, allocation-free relation.
It follows the pinned parser's `<`, then `>`, then `=` precedence and recognizes
`: ` descriptions in every relation family. Empty names/constraint versions and
unusual version spellings are preserved; embedded NUL is rejected.

```zig
const requirement = try rlpm.PackageRelation.parse("virtual>=alpha:1.0: explanation");
const matched = package.satisfies(requirement);
const formatted = try requirement.formatAlloc(allocator);
defer allocator.free(formatted);
```

`format(writer)` and `formatAlloc` preserve that parsed representation. `clone`
creates an owned copy paired with `deinit(allocator)`; borrowed parse results
must not be deinitialized. Owner's assumed-installed relations use owned copies.
Constraint payloads are now `[]const u8`, so callers read `.constraint.equal`
in place of `.constraint.equal.raw`.

`Package.satisfies` first checks literal package name/version, then provisions.
Only an equality provision carries a version for a versioned requirement. An
unversioned provision does not inherit its package's version. Soname-like names
use exact name matching and the same version rules. Selecting among multiple
packages belongs to dependency resolution.

Package conversion uses permissive `Version.initRaw`; strict `Version.init` and
`validate` remain available explicitly. Raw comparison supports NUL-free byte
strings under the reference's C-locale classification, including non-ASCII bytes
as separators. Missing pkgrel and arbitrarily large epochs keep their established
behavior; comparator equality is not a deduplication identity. See
[version compatibility](version-compatibility.md) for the unchanged 54 fixed
expectations and the additional byte fixtures.

## Archive inventories and streams

```zig
var package = try rlpm.Package.loadArchive(allocator, path, .{ .mode = .full });
defer package.deinit();
if (try package.openMember(allocator, .changelog)) |opened| {
    var stream = opened;
    defer stream.deinit();
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = try stream.read(&buffer);
        if (count == 0) break;
        try destination.writeAll(buffer[0..count]);
    }
}
```

The two-argument `initializePackageFromArchive` remains a metadata-mode wrapper.
Metadata mode scans required headers until a payload entry follows package
metadata. Full mode builds an inventory from tar entries, or from `.MTREE` when
available. A valid mtree replaces an earlier tar-derived inventory and can end
scanning before the payload finishes, matching the pinned implementation.
Neither mode constitutes complete payload, digest or signature verification.
Tar, Zstandard, gzip, xz and bzip2 are exercised; readers enable libarchive's
available compression filters.

Repeated `.PKGINFO` records merge lists and let later scalar values replace earlier
values. Malformed non-key lines are ignored as in the reference. Existing RLPM
conveniences for CRLF input and leading `./` member names are retained. Package
archives require a nonempty name/version and a release separator; raw constraint
versions do not inherit those archive requirements.

`members` tracks install/changelog/mtree availability as present, absent or
unknown. Early stopping leaves unseen members unknown. `has_scriptlet` reflects
a discovered `.INSTALL` or its mtree record. `openMember` independently searches
for the first install/changelog/mtree member and returns null if absent; it never
extracts archive paths. Readers own independent archive handles and can outlive
the package. `readAll` takes an explicit byte limit; `finish` reports close errors
and `deinit` always releases the reader.

`openMtree` owns the encoded mtree bytes and returns a `MtreeIterator`, supporting
plain and compressed mtree data. Each `next` result borrows name/link strings
until the next call or iterator release. Iterator names remove leading `./`;
unlike the sorted package inventory, their directory spelling comes from mtree.
Archive and local member streams are implemented. Local streams use the owned
`metadata_directory` source path and return verbatim bytes; `openMtree` handles
compressed local mtree data. Sync packages report `UnsupportedPackageOrigin`.
The returned `MemberReader` owns its file/archive stream independently of the
package or Owner. Local metadata fields are requested through
`Owner.packageMetadata(io, ref, .{ .files = true, .members = true })`; bare
`Owner.package` is an I/O-free snapshot accessor.

Metadata has explicit bounds: 1 MiB per `.PKGINFO`, 512 KiB per metadata line and
32 MiB for an encoded `.MTREE` member. Invalid initial mtree data falls back to
tar enumeration. The pinned library segfaults on the recorded case of a valid
mtree followed by an invalid duplicate; RLPM returns `InvalidMtree` and releases
its candidate storage. These bounds and malformed-input choices remain explicit
limits on broader load-compatibility claims.

## Evidence

`zig build test-metadata` runs nine external consumer tests, also included in the
normal `test` target. They consume [independent reference fixtures](src/tests/fixtures/metadata-reference.json):
25 relation/format cases, 13 satisfaction decisions, nine byte-version comparisons,
18 archives in both load modes, six signature-decoding inputs, five install
reasons and local file/backup/CachyOS provenance. Additional fixtures check owned
conversion, five compression filters, compressed mtree, absent streams, metadata
bounds, independent stream lifetimes and failures at every Zig allocation.

The [optional recorder](src/tests/reference/record_metadata.py) verifies the pinned
library hash and uses private temporary roots with signature checking disabled.
Native archive cases run in forked workers; the parent records crashes and cleans
up its own fixture tree. No normal build/test loads libalpm, regenerates expected
results or changes the host package database. Full parity remains tracked by the
[compatibility ledger](src/tests/compatibility-ledger.tsv).
