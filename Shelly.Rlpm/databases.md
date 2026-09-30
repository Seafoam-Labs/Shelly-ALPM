# Database backends and queries

RLPM implements local directory and sync archive backends behind
`Database.Backend`. `Owner` still owns registrations, metadata arenas, typed IDs
and cache generations. No production code or normal test links or loads libalpm.
Dependencies are Zig 0.16.0, libc, libarchive and SQLite with
`sqlite3_deserialize` support. A small C helper allocates libc's opaque
`regex_t`; search policy and queries remain Zig.

## Opening and querying

```zig
const rlpm = @import("Shelly_Rlpm");
var owner = try rlpm.Owner.init(io, allocator, .{
    .root = root_path,
    .database_path = database_path,
    .local_database_mode = .read_only,
}, &.{.{ .database_name = "cachyos" }});
defer owner.deinit() catch unreachable;

const repo = owner.findDatabase("cachyos").?;
if (try owner.queryPackage(io, repo, "example")) |reference| {
    const package = try owner.packageMetadata(io, reference, .{});
    _ = package; // Borrowed until the next mutation; retain reference instead.
}
const matches = try owner.search(io, allocator, &.{ "editor", "terminal" });
defer allocator.free(matches);
for (matches) |reference| {
    const package = try owner.package(reference);
    _ = package;
}
```

Root and database paths must exist. The default `local_database_mode = .create`
creates an absent local directory or the format marker in an empty directory.
`ALPM_DB_VERSION` must start with version 9 (the reference accepts trailing text).
Missing markers in populated directories and unsupported versions fail.
`.read_only` never creates anything; a missing local directory yields an empty,
missing snapshot. An existing directory still requires a valid marker. The CLI
example explicitly chooses this mode. Sync registration requires no archive or
network; first access loads `<dbpath>/sync/<name><database_extension>`.

| API | Behavior |
| --- | --- |
| `database`, `packageIds`, `findPackage`, `packageReference`, `package` | Snapshot accessors; no hidden I/O; unloaded package caches report `DatabaseNotLoaded` |
| `ensureDatabase(io, db)` | Idempotent lazy load; errors can be retried |
| `loadDatabase(io, db)` | Explicit load; reports `DatabaseAlreadyLoaded` when cached |
| `queryPackage(io, db, name)` | Lazy exact lookup, independent of usage flags |
| `packageMetadata(io, pkg, request)` | Load local description, files/backups or member availability; default request loads description |
| `findGroup(io, db, name)`, `groupIds(io, db)` | Lazy group loading, independent of usage flags |
| `searchDatabase(io, allocator, db, patterns)` | Database search, honoring that database's search flag |
| `search(io, allocator, patterns)` | Search eligible sync repositories in priority order, deduplicating matching package names |
| `groupPackages(io, allocator, name)` | Raw group membership across sync repositories, deduplicating names in priority order |
| `repositoriesFor(allocator, usage)` | Registrations eligible for sync/search/install/upgrade operations |
| `findCandidate(io, name, usage)` | First exact package among repositories eligible for that operation |
| `requiredBy`, `optionalFor` | Sorted unique reverse relations for a `PackageRef` |
| `reverseDependencies(io, allocator, package, optional)` | Also accepts archive packages; uses the installed universe for local/archive targets and all sync databases for sync targets |

Query result arrays belong to the supplied allocator. Their `PackageRef` values
belong to the Owner and are checked on resolution. Package enumeration and group
members follow package-name order. Group enumeration follows first encounter in
that order, as in the reference. Repeated group names on one package create
repeated same-name groups in cache enumeration, matching the pinned reference;
exact group lookup selects the first. Group/candidate queries here are metadata
queries; ignored-package questions, transaction flags such as `NEEDED`,
replacements and dependency selection belong to resolution and transaction
preparation.

Search uses POSIX extended regular expressions with case-insensitive and newline
flags. Patterns are combined with AND; each can match the name, description,
provided **name** or group. Package names also receive the reference's literal
substring fallback. Invalid regexes fail even after a previous pattern has
eliminated every candidate. An empty pattern list returns no results; a disabled
search returns no results without compiling patterns or loading the database.
Regex case folding follows libc's current locale, like libalpm; independent
fixtures capture the C locale. Shelly's ranked frontend search remains separate.

## Local metadata and streams

Local initialization loads identities from directory names, splitting at the
last two hyphens. Descriptions, inventories and groups stay lazy. Missing `desc`
files do not remove installed identities. Invalid directory names and duplicate
names appear in `Database.skipped_entries` with a reason; the first duplicate
encountered in filesystem enumeration wins. Metadata identity disagreements
retain the directory identity and set `Package.metadata_issues.identity_mismatch`.

`description_loaded`, `files_loaded`, `members` and `metadata_error` distinguish
loaded, unavailable and damaged data. A successful metadata request publishes
its requested fields together. Corrupt metadata errors are sticky until a reload;
already loaded fields remain readable. Operational and allocation failures
propagate and can be retried. Group/search/reverse queries retain base identities
with corrupt descriptions and use their available fields, as reference queries do.

`packageMetadata(io, ref, .{ .files = true, .members = true })` correlates `desc`,
`files`, backup hashes, and install/changelog/mtree presence. CachyOS
`installed_database` preserves the installed repository, even if unregistered.
The local database never receives detached repository signature checks.

`Package.openMember(allocator, .install/.changelog/.mtree)` now opens local
members as well as archive members. A missing member returns null. Readers own
their open stream independently of the package/Owner and must be deinitialized.
Local bytes are returned verbatim; `openMtree` handles compressed mtree parsing.
Sync packages have no installed member location and return `UnsupportedPackageOrigin`.
Reads neither execute scriptlets nor extract archives.

## Tar and CachyOS SQLite repositories

The same libarchive traversal handles plain, gzip, xz, Zstandard and bzip2 fixtures,
and the installed library's other filters. `desc`, `depends` and `files` entries
are merged into one package by directory identity, even when interleaved.
Duplicate tar records keep the first identity and apply subsequent metadata;
later scalar values replace earlier values and relation lists append. Unknown
members with a valid package directory retain a base package. A configured
`.files` extension selects that archive; it is not merged implicitly with `.db`.
File names are sorted for exact `Package.findFile` containment queries.

A tar member named `pacman.db` selects CachyOS SQLite ingestion. Its `packages`
table is read in memory using SQLite's read-only deserialization; no member is
extracted. Supported columns match the pinned backend: name/version/filename,
base/description, groups/licenses, architecture, build date, packager, sizes,
SHA-256/signature, all relation families and file lists. Comma lists skip empty
tokens and preserve token whitespace, matching CachyOS. SQLite does not add MD5
or installed-repository columns absent from the pinned backend. All rows become
the common Package model and indexes. `backend.sync.format` records tar, SQLite
or mixed input; refreshing can switch formats.

Malformed tar/SQLite, truncation, unsafe identities or invalid repository
filenames fail before a cache is published. Sizes/dates follow the permissive
database rules, independently of strict `ParsedDescription.parse`. Negative or
invalid reference sizes (`off_t -1`) are represented as null with `invalid_size`;
invalid dates become zero with `invalid_date`. This avoids unsigned wrapping.

Intentional boundaries remain explicit: null/missing SQLite identities, duplicate
SQLite package names, nonregular sync metadata members and unsafe names are
rejected. The pinned SQLite reader can expose unusable null identities or duplicate
rows. Its malformed row behavior is not reproduced at the cost of invalid indexes.
Metadata is bounded to 1 MiB for local descriptions, 32 MiB for local files/sync
records/mtree, 512 KiB per metadata line, and 512 MiB per embedded SQLite image.
The local version marker is bounded to 4 KiB. These bounds report errors
instead of silently dropping records.

`DatabaseStatus.validation` becomes valid after structural loading and the
effective signature policy pass. Disabled policy permits unsigned metadata.
`last_verification` retains structured results from the latest GPG attempt,
including rejected reloads. Sync package digests/signatures are advertised
metadata; their `validation` remains `none` until an archive is checked by
`Owner.loadPackage`. See [verification](verification.md) for policy and sealed
snapshot lifetimes. Downloads and transactions remain disabled capabilities.

## Reloads and lifetimes

`reloadDatabase(io, db)` builds a candidate arena and indexes. Success replaces
the old generation and makes every old package reference stale. Failure retains
the complete previous generation, including groups, and records `last_load_error`.
If there was no usable cache, it remains unloaded with missing/invalid status.
No partial indexes escape. `invalidateDatabase` explicitly discards the cache;
subsequent queries can retry after external repair/replacement.

Borrowed pointers/slices must be used before the next mutation. Re-resolve IDs
after mutations; they do not pin arenas. Successful publication frees the old
arena. This thread-confined contract avoids dangling public references without
retaining retired caches indefinitely. Metadata requests use candidate arenas;
allocation failure does not publish half-loaded fields or groups.

Unrelated option changes and usage/server edits preserve cache generations.
Changing the sync path, effective signature policy or GPG directory invalidates
the affected caches. `setServers`, `addServer` and `removeServer` work on either
`.servers` or `.cache_servers`, keep duplicates/order, strip one trailing slash
from incoming URLs, and remove the first match. All edits copy before publishing.

## Evidence

`zig build test-database` is included in the normal external consumer suite.
The [independent fixture](src/tests/fixtures/database-reference.json), captured by
[record_database.py](src/tests/reference/record_database.py), covers 12 local and
16 sync cases with corruption, identities, scalar rules, groups, regex searches,
usage visibility and reverse relations. It checks the pinned binary hash and
uses private roots and forked workers; ordinary tests consume the JSON offline.

Additional tests cover five compression formats, local streams and provenance,
format switching, failed-load/retry state, stale references, direct versus
candidate usage rules, and every Zig allocation failure across tar/SQLite
loading, metadata, regex, queries, server edits, option replacement and reloads.
SQLite/libarchive/libc internal allocations are not controlled by Zig's failing
allocator; their error returns are propagated. Optional host smoke tests now use
these production backends, but host data is not independent parity evidence.
Full compatibility remains tracked by the [ledger](src/tests/compatibility-ledger.tsv).
