# Shelly.Rlpm

RLPM is the native Zig package backend under development. The [completion
plan](../docs/rlpm-libalpm-completion-plan.md) targets libalpm's functional
behavior **including CachyOS extensions**, following the existing
Owner/Database/Package design. Shelly integrates runtime configuration-based
libalpm/RLPM selection, with both backends built by default and
`-Dlibalpm=false` for an RLPM-only build. See the [backend
guide](../docs/native-package-backends.md). Integration is implemented; full
release parity remains subject to the plan's acceptance gates.

RLPM exports an owning `Owner` with copied options, ordered repository
registration, read-only local queries, stable database identity, package cache
generations, typed callbacks, diagnostics and cancellation. Configuration and
metadata have separate arenas; failed configuration replacement retains the
previous state. Group membership uses package IDs. The [options and lifetimes
guide](options.md) contains a usable example and the complete option/consumer
inventory.

The metadata API provides complete metadata shapes, permissive relation
parsing/formatting and satisfaction, archive inventories, file/backup metadata
and owned member streams. The [metadata API guide](metadata.md) covers source
provenance, sizes, signatures, mtree behavior and the explicit arena conversion
API. Strict Version construction remains available alongside permissive metadata
ingestion.

CachyOS physical architecture enumeration and independent network-sandbox
configuration are available. Installed-repository provenance survives local
queries. Database backends provide local format validation, lazy
metadata/streams, production tar and CachyOS SQLite repositories, transactional
reloads and database queries. The [database guide](databases.md) documents the
APIs and explicit compatibility boundaries. Verification provides checksum,
signature and trust enforcement, consented key import, structured GPG results
and sealed archive snapshots. The [verification guide](verification.md)
documents policy, ownership and APIs. The resolver provides native resolution
and owned install/removal/system-upgrade plans with provider questions,
future-state checks and dependency ordering. The [resolution
guide](resolution.md) covers plans, flags, lifetimes and evidence. The
transaction API provides owned transactions, exclusive locks, frozen
preparation, typed lifecycle events and PackageManager
deferred-question/cancellation support. The [transaction guide](transactions.md)
covers the state machine and lock contract. The executor enables normal commit
and installed-repository provenance writes.

Downloads use the shared PackageManager transport for verified cache
acquisition, repository refresh and DOWNLOADONLY transactions. See
[downloads.md](downloads.md) for APIs, publication/recovery, privilege controls,
reference differences and validation. The sandbox fixtures pass in Debug and
ReleaseSafe inside a subordinate-ID namespace, including credential changes,
overlapping worker downloads and prompt callbacks.

Preflight provides full-archive verification and an owned filesystem preflight
manifest, including file conflicts, backup/pattern decisions, root-relative
inspection and space/access checks. See [preflight.md](preflight.md) for the
API, executor contract, pinned reference evidence and compatibility boundaries.

Transaction actions provide native Zig hook discovery/matching, chrooted
hook/scriptlet execution, linker-cache maintenance and CachyOS network controls.
Outcomes retain nonfatal failures; cancellation terminates action process
groups. See [actions.md](actions.md) for the executor contract, worker
deployment, reference comparisons and limits.

The executor connects these stages to confined payload extraction, backup
handling and journaled local-record publication. It adds persisted reasons,
audit records, cache rebuilding and retained partial-failure reports. See
[execution.md](execution.md) for behavior, recovery, native comparisons and
acceptance boundaries.

## Build and tests

Use Linux with `openat2`, `/proc` and memfd sealing, Zig 0.16.0, libc, libarchive, SQLite and libcurl development headers/libraries
(SQLite must support `sqlite3_deserialize`). `Shelly.Key` is a local
module dependency. From this directory:

| Command | Scope |
| --- | --- |
| `zig build` | Build the read-only example executable |
| `zig build run -- ROOT DBPATH` | Print local package names/versions using explicit directory paths |
| `zig build run -- --help` | Show example usage |
| `zig build test` | Hermetic unit tests, external API consumer, reference/ledger checks, example compilation |
| `zig build test-public-api` | External Owner and metadata API, ownership, references and failure cases |
| `zig build test-database` | Local/tar/SQLite metadata, queries, reloads and allocation failures |
| `zig build test-verification` | Policy/status, checksums, reference cases, imports and sealed-file tests |
| `zig build test-resolver` | Plans, flags, questions, removal/upgrade behavior and 314 reference scenarios |
| `zig build test-transaction` | Lifecycle, locks/process contention, archive ownership, cancellation and 16 reference scenarios |
| `zig build test-executor` | Payload, persistence, failure and 26 complete native state/event cases |
| `zig build test-executor-integration` | Full commits, 19 native process traces, attributes and ENOSPC in namespaces |
| `zig build test-executor-interop` | Both-way disposable-database interoperability with the pinned native binary |
| `zig build test-hooks` | Hermetic parser, precedence, matching and ownership fixtures |
| `zig build test-actions` | Real disposable-root actions under user namespaces, including 19 pinned oracle cases |
| `zig build check-actions` | Compile the action integration without running it |
| `zig build test-preflight` | Private-root conflicts, backups, links, current policies, space and 15 pinned oracle cases |
| `zig build test-download` | Cache, refresh, URL batches, DOWNLOADONLY and six pinned oracle cases |
| `zig build check-download-sandbox` | Compile privileged sandbox fixture; run explicitly as root with `test-download-sandbox` |
| `zig build test-metadata` | Relation, archive, metadata and independent reference fixtures |
| `zig build test-compatibility` | Frozen reference integrity, complete API inventory and evidence schema |
| `zig build test-version` | Existing fixed version expectations and ownership tests |
| `zig build test-package` | Package archive/metadata tests, including imported unit tests |
| `zig build test-signature` | Fifteen real GPG regression, trust, key and publication cases |
| `zig build test-host-readonly` | Opt-in smoke reads of `/var/lib/pacman/local` and `sync` |

All test modules honor `-Doptimize=ReleaseSafe` and the other standard optimize
modes. CI runs `test` in Debug and ReleaseSafe and `test-signature` in Debug.
Normal builds/tests do not link, load or call libalpm. Python is required for
optional reference recording and the explicit pinned-binary interoperability test.

`test` uses temporary package/database fixtures; it neither reads the host
package database nor launches GPG. It requires libarchive, SQLite and libcurl for
the shared worker modules. GPG integration requires `gpg`, `gpgconf`, `gpg-agent` and Unix socket access. It uses private
`/tmp/rlpm-gpg-*` homes, ephemeral keys, explicit verifier homes and cleanup of
its own agents/files. Missing tools or blocked agents fail with
`GpgIntegrationUnavailable`; skips cannot satisfy that gate. The suite includes
full/marginal/unknown trust, consented import and reverification, multiple
signatures, expired/disabled/revoked keys and authenticated cache publication.

The host smoke suite may skip absent data. It now uses the production local and
sync backends, including all supported archive filters and CachyOS SQLite. Host
smoke results are never a parity acceptance gate.

## Current limits and compatibility evidence

Root and database directories must already exist. Initialization creates missing
local storage/version 9 by default; explicit `.read_only` mode never writes.
Descriptions/files/groups load lazily. Registered sync databases need not exist;
queries load their tar/SQLite archives under their effective signature policy.
Signature policy enforcement, downloads, `filesystem_preflight` and
`transaction_lifecycle` are enabled in capability reporting, along with
package-executing transactions. Metadata-only `Package.loadArchive` is
explicitly unverified; `Owner.loadPackage` performs policy checks and retains
the verified bytes. Sealed snapshots require RAM/swap proportional to archive
size.

- The [manifest](src/tests/reference/manifest.json) pins the exact upstream,
  CachyOS and packaging revisions, headers, patches and binary identity.
  [Reference documentation](src/tests/reference/README.md) explains attribution,
  corpus provenance and optional capture on disposable roots.
- The [ledger](src/tests/compatibility-ledger.tsv) tracks 493 public symbols and
  25 behavioral contracts. There are 92 missing, 393 partial and 33
  representation-only rows. No row claims verified full compatibility, and
  every CachyOS extension remains required.
- [Owner reference fixtures](src/tests/fixtures/owner-reference.json) capture
  independent libalpm defaults, paths, registration and sandbox controls.
  Allocation failures, stale references, rollback/retry and callback contracts
  also have external consumer tests. Option storage alone does not establish
  that downstream consumers apply those values.
- The 54 fixed version expectations remain unchanged. Vendoring upstream tests
  does not mean they have run against RLPM; those cases still need adaptation
  and reviewed independent evidence.
- [Metadata reference fixtures](src/tests/fixtures/metadata-reference.json) add
  independent relation, provision, byte-version, archive-mode, signature-decoding
  and local file/provenance expectations. Archive and installed-package streams and file correlation are available. Metadata loading
  does not establish payload or signature integrity.

- [Database reference fixtures](src/tests/fixtures/database-reference.json) capture
  12 local and 16 tar/SQLite cases, including identity/corruption/scalar rules,
  group ordering, regex/AND search, reverse relations and usage visibility.
  Additional hermetic tests cover five filters, format switching, stale
  references, local streams and allocation failures.

- [Signature reference fixtures](src/tests/fixtures/signature-reference.json)
  capture 144 file-policy decisions across twelve isolated libalpm cases, plus
  digest/issuer expectations. Normal tests replay these offline without libalpm
  or GPG. The original frozen corpus remains unchanged.

Filesystem preflight validation on 2026-09-28: `test` passes **167 tests** in
Debug and ReleaseSafe (49 library, 114 external consumer, four ledger checks).
The **19** focused preflight tests overlap that suite and replay **15** pinned
native outcomes. PackageManager downloader/adapter regressions pass **65 tests**
in both modes. All **15 real GPG tests** pass, including preflight policy
retention and reverification. See [preflight.md](preflight.md) for stricter
archive checks, conservative space estimates and the unexecuted privileged
mount/extraction validation boundary. CI has not run remotely.

Historical download and refresh validation on 2026-09-28: `test` passes **148
tests** in Debug and ReleaseSafe (49 library, 95 external consumer, four ledger
checks). `test-download` reruns 13 focused cases already included in that suite,
including six pinned oracle cases. PackageManager's downloader and RLPM adapter
targets pass **65 tests** in both modes, including 46 shared transport/queue
tests. All **14 real GPG tests** pass; Shelly.Http passes **26 tests**. The
root-only sandbox fixture compiles in both modes but was not executed because
sudo requires a password. The native Zig sandbox additionally passes its
unprivileged child-process test in both modes, exercising all four
filesystem/syscall switch combinations. See [downloads.md](downloads.md) for the
API, deployment requirements and limits. CI is configured but has not run
remotely.

Historical dependency resolution validation on 2026-09-28: `test` passed **117
tests** in Debug and ReleaseSafe (47 library, 66 external consumer, four ledger
checks). The 12 focused resolver tests overlap the normal suite and replay **314
independent prepare cases**, including 36 frozen corpus adaptations, final
edges/provisions, and 160 generated universes. Nine additional reference cases
validate AssumeInstalled options. Owner lifetime/cancellation, allocation
failures, sealed archive retention and a 1,024-package chain pass. All **12 real
GPG regression cases** also pass. See [resolution limits](resolution.md). CI is
configured but was not run remotely.

Historical checksum, signature and trust validation on 2026-09-28: `test` passed
**105 tests** in Debug and ReleaseSafe (47 library, 54 external consumer, four
ledger checks). The focused verification and standalone package targets pass 14
and 25 tests respectively, overlapping the normal suite. All **12 real GPG
cases** pass; `Shelly.Key` passes its **147 tests**. The reference matrix covers
**144 file-policy decisions**. No live WKD/keyserver service was contacted. See
the [verification guide](verification.md) for limits and ownership. CI is
configured but was not run remotely.

Historical database backend validation on 2026-09-28: `test` passed **91 tests**
in both Debug and ReleaseSafe (47 library, 40 external consumer, four ledger
checks). This includes 12 database consumer tests and every Zig allocation
failure across tar and SQLite loading, metadata, regex/query,
configuration/server editing and reload paths. All five real GPG regression
cases and three host smoke/discovery cases passed; the production host reader
saw 1,813 local packages and eight sync repositories. The installed ReleaseSafe
example passed help, absent/populated DB and invalid format checks without
changing fixture contents, modes or modification times. The example and cached
test executables have no libalpm dynamic dependency. Private GPG/reference
fixtures were cleaned up; formatting, recorder syntax, reference integrity,
ledger schema and documentation links passed. CI was updated for SQLite but was
not run remotely.

Historical metadata and relation validation on 2026-09-27: `test` passed all 78
tests in Debug and ReleaseSafe (47 library, 27 external consumer, four ledger
tests). The focused metadata, version and package targets passed 9/13/25 tests
respectively; these overlap the normal suite. All five real GPG cases and the
three host smoke/discovery cases passed. The installed ReleaseSafe example read
permissive metadata without changing fixture contents, permissions or
modification times. No libalpm dynamic dependency was found in the example or
cached test executables. Reference/GPG fixtures were cleaned up, and formatting,
recorder syntax and local links pass.

Historical Owner and configuration validation on 2026-09-27: `test` passed 68
tests in both Debug and ReleaseSafe (47 library, 17 external consumer, four
ledger tests), and real GPG integration passed all five cases. The optional host
suite passed its two smoke cases and discovery test. The installed ReleaseSafe
example passed help, empty-database and populated-database checks; fixture
contents, permissions and modification times were unchanged. The example and
cached test executables have no libalpm dynamic dependency, and GPG fixture
homes were cleaned up. Formatting and local documentation links were checked.
The initial baseline had 54 ordinary tests and five GPG cases. CI is configured
but has not been run remotely.

Hook and scriptlet validation on 2026-09-28: `test` passes **174 tests** (49
library, 121 public API, 4 ledger) and `test-actions` passes **18 real-process
tests**, including **19 pinned CachyOS oracle cases**, in Debug and ReleaseSafe.
PackageManager's downloader and RLPM adapter targets pass **65 tests** in each
mode. The executor supplies normal package commit. See [actions.md](actions.md).

Executor validation adds the complete package cycle and both directions of
native interoperability, with matching serialized records and attributes. The
new executor suites run in Debug and ReleaseSafe; [execution.md](execution.md)
records tested scope and intentional failure/interruption differences.

Executor validation on 2026-09-28: **188 tests** (49 library, 135 public API, 4
ledger), **18 action tests**, **6 executor integration tests**, and both-way
pinned native interoperability pass in Debug and ReleaseSafe. PackageManager
downloader/adapter checks pass **65 tests** per mode; the real GPG suite passes
**15 tests** in Debug.

Worker modes run through the hosting executable. Shelly and the standalone RLPM
example dispatch them before application setup. Other embedders must call
`Workers.dispatch(init, args_without_argv0)` and exit with any returned status,
or configure an absolute `OwnerConfiguration.worker_executable` implementing
both reserved modes. See [actions.md](actions.md) for the embedding contract.
