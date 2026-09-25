# RLPM implementation gaps relative to libalpm

Re-evaluated on 2026-09-23 against repository commit `d880f9e1`, including the
completed [version compatibility work](../Shelly.Rlpm/version-compatibility.md).
Version-test layout updated on 2026-09-24: fixed expected-result tests now live
directly in `Version.zig`, without a libalpm-linked test target.

RLPM currently provides package metadata types, version comparison, a local
database reader, package/group indexes, and detached database signature checking.
It does not yet provide an independently usable package-management backend:
repository loading, dependency solving, transactions, and filesystem installation
are still missing or incomplete.

This review covers the code in `Shelly.Rlpm`, using the installed `alpm.h` and the
[libalpm public API](https://man.archlinux.org/man/libalpm.3.en) as the comparison
surface. The referenced Arch manuals describe pacman 7.1. This is a source-level
gap analysis, not a claim that all existing behavior has been proven compatible.
Targeted relation comparisons use the installed CachyOS libalpm 16.0.1, with
[recorded provenance](../Shelly.Rlpm/version-compatibility.md#expected-result-provenance).

The assessment is functional parity for a Zig backend. Matching every C symbol,
ABI, or private data structure is a separate goal. A working version comparator
does not imply parity in dependency parsing, metadata ingestion, or transactions.

## What changed in this re-evaluation

- **Version comparison is implemented within its declared scope.** String epochs,
  permissive raw comparison, separate structural validation, and fixed expected-result
  tests are present. Do not keep the old `u64` epoch limit or missing raw comparator on
  the implementation backlog.
- **The handle is still a compile blocker.** A compile-only probe invoking
  `Owner.init` fails at its three-argument `Database.init` call.
- **Sync database support is still test-only.** Parsing repository descriptions
  in an integration test does not provide a production repository database/cache.
- **Relation parity is still incomplete.** Direct comparisons confirmed operator
  selection and accepted-input differences. The older `foo==1` example was not a
  parity mismatch: both implementations accept it the same way.
- **No resolver or transaction backend has appeared.** The source tree still has
  no independent satisfy/prepare/commit path, and Shelly still calls libalpm.

The earlier [dependency-resolution gap analysis](shelly-libalpm-compatible-dependency-resolution-gaps.md)
discusses Shelly's existing AUR/libalpm backend. Its claims that metadata readers
and version comparison need to be implemented from scratch should not be applied
unchanged to RLPM: RLPM now has implementations of those building blocks.

## Current coverage

| Area | RLPM status | Evidence |
| --- | --- | --- |
| Version parsing and comparison | Implemented with string epochs, separate validation/raw comparison, and inline expected-result tests | [Version.zig](../Shelly.Rlpm/src/structs/Version.zig): `init`, `validate`, `compareVersions`, `compareStrings` |
| Package metadata and relations | Substantial model; incomplete for archive and transaction use | [Package.zig](../Shelly.Rlpm/src/structs/Package.zig), [PackageRelation.zig](../Shelly.Rlpm/src/structs/PackageRelation.zig) |
| Local database descriptions | Implemented, including relation conversion and group indexing | [Database.zig](../Shelly.Rlpm/src/structs/Database.zig): `loadDatabase`, `parseDescription`; [ParsedDescription.zig](../Shelly.Rlpm/src/structs/ParsedDescription.zig): `intoPackage` |
| Sync database archives | Test-only parsing path; no production loader | `Database.zig`: sync integration test and `parseSyncTarDescriptions` |
| Signatures | Detached GPG verification exists; policy enforcement is incomplete | `Database.zig`: `validateSignature`; [SignaturePolicy.zig](../Shelly.Rlpm/src/structs/SignaturePolicy.zig) |
| Handle/configuration lifecycle | Unfinished; initializing Owner fails compilation | [Owner.zig](../Shelly.Rlpm/src/structs/Owner.zig), [DatabaseConfiguration.zig](../Shelly.Rlpm/src/structs/DatabaseConfiguration.zig) |
| Dependency relation parsing | Partial; confirmed input/operator differences, no public round-trip API | `ParsedDescription.zig`: private `parseRelation` |
| Dependency/conflict/replacement resolution | Missing | Relations are stored but no solver consumes them |
| Download, prepare, commit, removal, upgrade execution | Missing | No transaction engine in `Shelly.Rlpm/src` |
| Integration into Shelly | Missing | [PackageManager build](../Shelly.PackageManager/build.zig) still binds to system libalpm |

## 1. Complete the public module and owner lifecycle

[root.zig](../Shelly.Rlpm/src/root.zig) directly exports only `Version` and
`ParsedDescription` as domain types. It still contains template `add` and print
functions, and [main.zig](../Shelly.Rlpm/src/main.zig) remains a template executable.
There is no complete exported handle through which a caller can operate RLPM.

`Owner.init` has specific unfinished code:

- It creates configured databases and then discards them instead of retaining
  them in `sync_databases`.
- Its local `Database.init` call supplies three arguments; the function now
  requires four, including a signature policy.
- Its returned struct omits the required `sync_databases` field.
- It passes `database_path` directly to the local loader without constructing a
  distinct local database path.
- It has no `deinit` or complete failure cleanup for retained databases.

`Owner.zig` is not imported by the root test block, so the current test suite does
not exercise this initializer. A temporary external test invoking it with
`zig test -fno-emit-bin` confirmed the compiler error at `Owner.zig:45`:
`expected 4 argument(s), found 3`. The missing returned field and discarded
databases are additional source findings, beyond that first compiler diagnostic.
These issues must be resolved before treating the owner as a working handle.

Remaining work includes explicit ownership/lifetime rules, database registration
and unregistration, repository ordering, root-relative paths, and configuration
application. `DatabaseConfiguration` currently contains only a name and signature
policy. Mirror lists, usage, and relevant handle options need a usable path into
the backend. Options such as ignore rules, assumed-installed dependencies,
architectures, multiple cache/hook directories, extraction exclusions, overwrite
rules, disk-space checking, and download sandbox configuration need implementation
or integration. See the [libalpm options API](https://man.archlinux.org/man/libalpm_options.3.en).

## 2. Finish database loading, validation, and refresh

`Database.loadDatabase` reads directories containing `desc` files. It does not open
a repository `.db` archive. The sync integration test independently reads gzip or
plain tar data and converts descriptions to temporary packages; it does not
populate a reusable sync `Database`, and explicitly skips Zstandard archives.

Missing production capabilities include:

- Separate local and sync backends with appropriate path and validation rules.
- Sync archive loading, supported compression formats, archive validation, and
  population of package/group indexes.
- Repository refresh through configured mirrors/cache servers, including forced
  refresh, unchanged results, signature retrieval, and safe cache replacement.
- Cache invalidation and reload; the current loader rejects a second load with
  `DatabaseAlreadyLoaded`.
- Search/query operations beyond directly accessing the stored indexes, including
  multi-term search, cross-repository group lookup with duplicate/ignore handling,
  and enforcement of `DatabaseUsage`.
- Local database format/version validation and write support.

These correspond to the registration, update, search, cache, and usage operations
in the [database API](https://man.archlinux.org/man/libalpm_databases.3.en).

The existing loader also needs stronger failure semantics. Missing, unreadable,
malformed, mismatched, or duplicate descriptions are logged and skipped, after
which the remaining database can be marked valid. That may be useful for a
diagnostic reader, but a solver must know whether installed state is incomplete.
Allocation failures caught during parsing/conversion can also become skipped
packages. A failed load can leave populated indexes behind without a reset path.
Define structured diagnostics and cleanup/retry behavior before using this state
to approve transactions.

`DatabaseStatus.markMissing`, `markInvalid`, and `clearCaches` exist as helpers,
but the loader does not call them on failure. `clearCaches` only resets flags;
it does not clear package/group storage. A failed signature check happens after
the indexes are populated, and a retry can rebuild groups over retained state.
The next implementation should establish consistent status, index, and borrowed
pointer lifetimes for success, failure, invalidation, and reload. Differential
fixtures should determine which corrupt metadata libalpm skips or rejects;
simply making RLPM stricter is not itself proof of parity.

## 3. Complete package metadata and package archive support

The existing model already carries name, version, base, repository name,
description, architecture, dates, installed size, install reason, validation
flags, groups, licenses, extended data, and dependency/provision/conflict/replacement
relations. Those fields should be reused.

It still lacks the information and readers needed for downloading and installing:

- Package filename, compressed/download size, checksum values, and encoded
  package signatures. Sync fields such as `%FILENAME%`, `%CSIZE%`, `%MD5SUM%`,
  `%SHA256SUM%`, and `%PGPSIG%` are not handled by the description parser.
- Preservation of MD5 validation metadata: `Package.Validation` has no MD5 field,
  and the `%VALIDATION%` parser ignores `md5`.
- An explicit local/sync/archive origin and ownership contract for loaded archives.
- Installed file lists and backup-file hashes from local database `files` entries.
- Package archive loading and `.PKGINFO` parsing.
- Access to install scriptlets, changelogs, and mtree metadata.
- Persistent install-reason updates and required-by/optional-for queries.

The [package API](https://man.archlinux.org/man/libalpm_packages.3.en) exposes the
corresponding loading, metadata, file-list, reason, changelog, and mtree operations.
Parsing `desc` alone cannot support file ownership checks or configuration-file
preservation during upgrades.

Ownership also needs a public contract: database packages borrow arena-backed
storage, while future independently loaded archive packages need a clear release
operation. `ParsedDescription.intoPackage` allocates through a supplied allocator
and borrows description strings; `Package` currently has no general cleanup API.
Do not assume it can safely serve both ownership modes without further design.

## 4. Turn signature verification into policy enforcement

`validateSignature` really invokes GPG through `Shelly.Key` and returns success or
failure; this is not a stub. The missing layer is how verification results affect
database and package acceptance:

- `loadDatabase` calls verification only when database signatures are `required`.
  `optional` currently skips checking even when a signature is present.
- The same loader applies archive-signature logic to local directory loading.
  With default settings it looks for `<path>/local.db` and its signature; local
  database tests explicitly disable this policy.
- The package signature setting is stored but has no package-loading path to
  enforce it.
- Policy has no representation for inherited defaults or marginal/unknown trust
  allowances. Captured GPG status output is discarded rather than converted into
  detailed signature/trust results.
- Key acquisition/questions, package checksum verification, and package signature
  decoding are not wired into RLPM operations.

Optional signatures mean a missing signature may be accepted while a present one
is checked. libalpm also distinguishes verification status from key trust; those
need explicit decisions rather than a single boolean. See the
[signature API](https://man.archlinux.org/man/libalpm_sig.3.en).

## 5. Add dependency, conflict, removal, and upgrade resolution

`ParsedDescription` already parses unversioned relations and `=`, `>=`, `<=`, `>`,
and `<` constraints, including optional-dependency descriptions separated by
`: `. `Version.compareVersions` handles epochs, numeric/alphabetic segments, and
ignores pkgrel when only one side has one. Neither is a dependency solver.

RLPM still needs:

- Package-name and versioned/unversioned `provides` satisfaction, with provider
  lookup and selection across ordered repositories.
- Recursive dependency closure for all targets together, retaining each original
  constraint and the selected satisfying package/provision.
- Selection rules for explicit targets, installed providers, repository usage,
  ignored packages/groups, and assumed-installed dependencies.
- Future-state validation after removals, upgrades, and replacements, including
  reverse-dependency failures.
- Target/target and target/installed conflicts, replacement decisions, and
  installation-reason propagation.
- Dependency ordering, cycle handling, recursive/cascade removal, and full-system
  upgrade/downgrade selection.
- A reviewable transaction plan, provider/replacement/conflict questions, and
  structured missing-dependency/conflict errors.

The [dependency API](https://man.archlinux.org/man/libalpm_depends.3.en) provides
the relevant satisfier, conflict, and reverse-dependency contracts. Existing
package/group hash maps help, but there is no provider index or operation graph.

### Confirmed relation differences

A temporary probe compared `ParsedDescription.intoPackage` with
`alpm_dep_from_string` on the installed library:

| Input | RLPM | libalpm 16.0.1 |
| --- | --- | --- |
| `foo>1<2` | Name `foo`, `>` constraint, version `1<2` | Name `foo>1`, `<` constraint, version `2` |
| `foo>=alpha:1.0` | `InvalidCharacter` from `Version.init` | Retains version `alpha:1.0` |
| `foo=1.0-` | `InvalidVersion` from `Version.init` | Retains version `1.0-` |
| `foo=` | `InvalidPackageRelation` | Retains an empty equality version |
| `foo: description` in `depends` | Entire string becomes the name | Name `foo`, description `description` |

These unusual-input differences matter for exact parser/API parity; they do not
establish that all such inputs are valid package metadata. RLPM handles the last
row like libalpm in `optional_depends`, where its description parsing is enabled.
Its parser currently applies that behavior only to optional dependencies.

For comparison, `foo==1` yields name `foo`, equality, and version `=1` in both
implementations. `lib:libfoo.so.1` also survives as an unversioned name in both.
The previous assessment should not treat those examples as missing parsing.

The remaining work is to specify and implement standalone relation parsing and
formatting, test its accepted-input contract, and separate raw relation versions
from strict package metadata construction where parity requires it. The new
`compareStrings` function already provides permissive version ordering; routing
every relation through the validated `Version.init` still narrows accepted inputs.
Versioned provisions must eventually be checked against the provision's version,
not automatically against the provider package's version.

### Remaining version-specific scope

There is no newly demonstrated raw comparison mismatch within the declared
ASCII, NUL-free domain. Tests in `Version.zig` cover 54 fixed expected-result
cases plus the original 13 valid-version examples, without linking libalpm.
Before the live differential runner was removed, it also passed 2,916 cross-corpus
pairs and 20,000 generated pairs. Those generated comparisons are historical
evidence, not part of the current test suite. Remaining work is broader verified
upstream expected-result coverage and any deliberately expanded input or C API
contract. Non-ASCII, embedded NUL, and nullable C pointers are explicitly
outside the current contract. Those limitations do not justify rewriting the
working comparator. See [version compatibility](../Shelly.Rlpm/version-compatibility.md).

## 6. Implement the transaction engine

There is no RLPM transaction object or initialize/prepare/commit/interrupt/release
lifecycle. It needs transaction locking, add/remove target ownership, state
validation, cancellation, and useful errors on partial failure. Flags must affect
the appropriate stage: dependency/removal flags during solving, and flags such as
`DBONLY`, `DOWNLOADONLY`, `NOSAVE`, `NOSCRIPTLET`, and `NOHOOKS` during execution.
See the [transaction API](https://man.archlinux.org/man/libalpm_trans.3.en).

Execution requires additional work beyond resolution:

- Package downloads and cache lookup, mirror fallback, partial-download handling,
  progress reporting, and configured concurrency/sandbox behavior.
- Integrity/signature checks and architecture validation before installation.
- File conflicts against other targets and the filesystem, overwrite rules,
  available-space checks, and extraction exclusions.
- Extraction with correct paths, file types, permissions, ownership, and links;
  removal of obsolete files and handling of shared directories.
- Backup-file comparison and `.pacnew`/`.pacsave` behavior.
- Local database writes/removals and persistence of file lists, reasons, and
  validation metadata.
- Scriptlet execution and pre/post-transaction hooks with matching, ordering,
  target input, and failure behavior. See [ALPM hooks](https://man.archlinux.org/man/alpm-hooks.5.en).
- Logging plus event, progress, download, and question callbacks suitable for the
  existing CLI and UI.

Interrupted commits need defined cleanup and reporting; full filesystem rollback
is a separate design choice, not an assumed libalpm compatibility requirement.

The transaction flags still need actual implementations, not just names in a
future enum. Resolution includes `NODEPS`, `NODEPVERSION`, `NOCONFLICTS`, `NEEDED`,
`ALLDEPS`, `ALLEXPLICIT`, `CASCADE`, `RECURSE`, `RECURSEALL`, and `UNNEEDED`.
Execution also needs the download/database-only, hook/scriptlet, backup, and lock
flag behaviors. Test interactions, not only individual flags.

## 7. Integrate RLPM and prove compatibility

Shelly still generates system libalpm bindings in
[Shelly.PackageManager/build.zig](../Shelly.PackageManager/build.zig).
[alpm/manager.zig](../Shelly.PackageManager/src/alpm/manager.zig) still calls
`alpm_initialize`, `alpm_trans_prepare`, and `alpm_trans_commit`. Repository-wide
Zig/build-manifest searches found RLPM references only inside `Shelly.Rlpm`.

A migration therefore needs an adapter from RLPM to Shelly's operation plans,
callbacks, errors, and package queries. Existing archive, HTTP, key, configuration,
and UI code elsewhere in the repository may be reusable, but its existence does
not make these capabilities available through RLPM today.

RLPM needs a stable observable result contract too: distinguish absent packages
from broken databases, missing dependencies from conflicting targets, signature
failures from I/O failures, and interrupted transactions from completed ones.
Expose enough error data and callback context for the current UI to explain and
answer provider/replacement/conflict/key questions. Scattered Zig errors and
warning logs do not yet provide that operation-level interface.

Behavioral compatibility does not require copying libalpm's private structs or
linked-list implementation. A drop-in C/ABI replacement would additionally require
exported C symbols, compatible types/calling conventions, and library packaging;
RLPM currently exposes a Zig module instead. AUR RPC, PKGBUILD parsing, source
builds, and `.SRCINFO` resolution are Shelly features outside libalpm itself.

The remaining verification work is:

- Extend the inline version tests with verified upstream expected results, and
  add relation/satisfier cases including malformed inputs, without linking libalpm.
- Add hermetic local/sync/archive fixtures covering metadata preservation,
  compression, corrupt data, trust policies, and retry/cleanup paths.
- Exercise `Owner.init` and the exported API so unused unfinished code cannot
  escape the build checks.
- Add transaction fixtures for providers, conflicts, replacements, removals,
  cycles, repository priority, flags, backup files, hooks, and scriptlets.
- Run install/upgrade/remove comparisons in disposable roots and compare both
  filesystem contents and local database state.

## Suggested implementation order

| Priority | Deliverable | Completion evidence |
| --- | --- | --- |
| 1 | Usable handle and database lifecycle | An external caller can initialize, register ordered repositories, read local state, and release everything; failure/retry tests pass |
| 2 | Complete metadata ingestion and query layer | Local, sync, and archive fixtures retain required metadata; signature policy and query/usage behavior match the reference |
| 3 | Relation satisfaction and transaction planning | Equivalent selected package sets, removals, required questions, and dependency/conflict failures for install/remove/upgrade fixtures |
| 4 | Download and transaction execution | Disposable-root operations reproduce file contents, metadata, backups, local database state, hooks, and scriptlet outcomes |
| 5 | Shelly integration and compatibility coverage | CLI/UI paths use RLPM with equivalent callbacks/errors; production operations no longer delegate to libalpm |

Relation parsing/formatting and versioned-provider satisfaction are the next
small compatibility units that can be implemented independently. Repairing the
owner and implementing production sync loading are the prerequisites for making
those units into a usable backend. No additional comparator rewrite is needed
before beginning that work.

An independent resolver is complete when it can produce compatible plans without
libalpm deciding the package set. A replacement package backend additionally has
to execute those plans and maintain compatible installed state.

## Validation performed for this review

This re-evaluation inspected all RLPM production modules, build/test wiring,
the installed public `alpm.h`, and Shelly's active libalpm call sites. It also ran
two temporary probes without changing production code:

- Compile-only invocation of `Owner.init`: failed at the missing database
  signature-policy argument. The probe did not execute or access a package root.
- Relation differential probe: confirmed the table above and the matching
  `foo==1` and `lib:libfoo.so.1` cases against installed libalpm 16.0.1.

The existing version implementation's recorded Zig 0.16.0 results remain the
latest suite results, rather than a fresh full-suite run for this documentation
review: build and focused/differential tests passed; the full library runner
reported **43 passed, 5 failed, 0 skipped**, and both executable template tests
passed. All five failures occurred while creating GPG fixtures because
`gpg-agent` could not start, before signature assertions ran. This limits the
evidence for real-signature verification in that environment; it is not a
demonstrated signature-verification implementation failure.

This re-evaluation updates documentation only. The concrete next milestone is a
compiling, exported owner with reliable local/sync database lifecycle semantics.
