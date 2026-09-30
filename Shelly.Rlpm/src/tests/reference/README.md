# Frozen libalpm reference

The required target is **CachyOS pacman 7.1.0.r9.g54d9411-4 / libalpm 16.0.1**,
including its extensions. These files are reference material, never compiled or
executed by RLPM. `test-compatibility` checks their SHA-256 hashes and the API
ledger without loading libalpm or invoking pacman.

## Provenance

[manifest.json](manifest.json) records full revisions, archive URLs/hashes,
installed binary identity, runtime capabilities, build evidence and every frozen
asset hash. The relevant sources are:

- [Pristine upstream revision](https://gitlab.archlinux.org/pacman/pacman/-/commit/54d94116164b0b2202c6061c4a59c6f3e70820d8),
  identified by the package version's abbreviated `54d9411`.
- [Actual CachyOS source revision](https://github.com/CachyOS/pacman/tree/4056cd687f6379e61e7decb9b66e9b57cb3949a9),
  recorded in the package's PKGBUILD; it differs from that upstream revision.
- [Packaging revision](https://github.com/CachyOS/CachyOS-PKGBUILDS/tree/d90418d0be6eb4dbf8aac57a8c71ff64630aaf9e/pacman).
  The vendored PKGBUILD's hash exactly matches the installed package's
  `.BUILDINFO`. The downstream header exactly matches `/usr/include/alpm.h`
  observed on 2026-09-27. Both upstream and installed `alpm_list.h` match.

`packaging/` retains the recipe, `.SRCINFO`, package `.BUILDINFO`/`.PKGINFO`,
configuration files and patches. The manifest lists the four patches applied to
this x86_64 build in recipe order. The aarch64-only patch is retained separately
and was not applied to the reference. The bundled source precedes those patches;
consult them as well when deriving expectations. The SQLite source URL/hash
comes from `.SRCINFO` and the PKGBUILD and is recorded, not vendored or rebuilt.
Build flags/options come from the recipe and `.BUILDINFO`, not a reproduced build.

Each `*-source-tests.tar.gz` is a deterministic subset of the corresponding
source archive, with the top-level directory removed. It contains **all regular
files under `test/`**, libalpm sources/headers except translations, `COPYING`,
`AUTHORS`, Meson build/options, the hook manual and pacman's configuration parser.
Paths are sorted; timestamps, UID/GID and names are zeroed; file modes are 0644;
gzip mtime is zero. The upstream bundle has 404 test files including 341 pactest
cases; downstream has 407 test files including 344 pactest cases. Acquisition
is not execution: these cases have not yet been adapted to the RLPM runner.
`downstream-libalpm.diff` records every non-translation libalpm source change
between these two revisions, before packaging patches.

Original copyright headers and [COPYING](COPYING) are retained. Pacman/libalpm
reference material is GPL-2.0-or-later, as stated in its source and package
metadata. Vendoring the corpus preserves attribution; it does not change the
license declarations of other project files.

## Coverage and CachyOS requirements

[../compatibility-ledger.tsv](../compatibility-ledger.tsv) contains 493 public
symbols from the two headers plus 25 behavioral contracts. Header provenance
uses paths relative to this directory; `archive!member` identifies a source
inside a bundle. Symbols present upstream are labeled `upstream`; that label
does not imply the downstream implementation is identical. Separate CachyOS
behavior rows cover shared APIs, including:

- SQLite repository metadata in the archive's `pacman.db` member.
- Physical architecture enumeration and `Architecture=auto` integration.
- Reading `%INSTALLED_DB%` and preserving repository provenance during
  selection, install and upgrade.
- Mandatory hook/scriptlet network isolation, `NetworkAccess=allowed`, the
  global DisableSandbox interaction, and best-effort isolation for `ldconfig`.
- Safe chroot child cleanup after downloads, from the packaged curl fix.

Each row gives the equivalent current/proposed Zig operation, responsible
feature, existing evidence and a **planned** fixture ID. A planned ID is an
acceptance obligation, not an existing test. `missing` and `partial` do not count
as parity. `representation_only` is restricted to C linked-list mechanics
represented by Zig containers and ownership; it cannot exclude an extension.
`verified` requires independent reference evidence and reviewed coverage of the
full row contract. No row is currently labeled `verified`.

[../compatibility-evidence.tsv](../compatibility-evidence.tsv) distinguishes
handwritten unit tests, real GPG integration, independently recorded Owner
defaults/registration, and the existing 54 fixed version expectations captured
independently from libalpm. Those version expectations remain
inline in Version.zig and are unchanged. The ledger is an inventory, not proof
that all behavior is implemented, and a passing ledger test is not a parity gate.

## Updating the reference

Reference updates need an explicit review of source/patch changes, required
CachyOS behavior, ledger coverage and expectation provenance. Keep the normal
build independent of live reference execution. Do not regenerate expected
results from RLPM.

The optional identity recorder only hashes explicit files and calls
`alpm_version`/`alpm_capabilities`. It creates no ALPM handle and performs no
package operation. From the module directory:

```sh
python3 src/tests/reference/record_identity.py \
  --library /usr/lib/libalpm.so.16.0.1 \
  --alpm-header /usr/include/alpm.h \
  --list-header /usr/include/alpm_list.h
```

Compare its JSON with the frozen manifest; it never edits committed evidence.
There is no live version comparison build target.

The optional Owner recorder captures defaults and repository registration:

```sh
python3 src/tests/reference/record_owner.py \
  --library /usr/lib/libalpm.so.16.0.1
```

It verifies the pinned library hash before execution, creates dedicated temporary
root/database directories, queries defaults, and exercises in-memory repository
registration and independent sandbox controls. The reference initializer creates
its local version file inside that temporary database; the recorder releases the
handle and removes its own temporary tree. It does not open the host database.
Its reviewed output is [../fixtures/owner-reference.json](../fixtures/owner-reference.json),
consumed offline by the external Owner tests. It does not alter the frozen
source assets or their manifest.

The deprecated aggregate sandbox getter/setter are declared in the pinned header
but not exported by the installed binary. Their behavior is derived from
the pinned source; the fixture records execution of the independent filesystem,
syscall and CachyOS network controls. The Owner fixture captures native
version-file creation. Database tests cover default creation, format validation
and explicit read-only initialization.
Neither the fixture nor source-derived CPU feature tests establish full parity.
Future operation recorders and pactest adaptations must likewise use dedicated
disposable roots and reviewed independent expectations.

The optional metadata recorder captures metadata and relation behavior:

```sh
python3 src/tests/reference/record_metadata.py \
  --library /usr/lib/libalpm.so.16.0.1
```

It checks the library hash, selects the C locale and builds its own temporary
root, local database and archives. It loads metadata with signature checking
disabled, queries local records, compares versions, parses/formats relations and
decodes embedded signature bytes. No transaction or host database is used.
Native archive cases run in forked workers with core dumps disabled; the parent
records abnormal exit signals and removes the temporary tree. This is needed
because the pinned binary segfaults on the recorded valid-mtree/invalid-duplicate
case. RLPM's expected result for that case is the documented `InvalidMtree`
error, not reproduction of the native crash.

The reviewed [metadata fixture](../fixtures/metadata-reference.json) retains
25 relation cases, 13 satisfaction decisions, nine byte-version comparisons,
18 archives in both modes, six signature-decoding inputs, five install reasons
and local file/backup/CachyOS provenance. Original reference assets and the
54 existing version signs are unchanged. `test-metadata` consumes this output
offline; it never regenerates expected results. The [metadata API guide](../../../metadata.md)
documents coverage and remaining backend/verification work.

The optional database recorder is separate from the frozen source corpus:

```sh
python3 src/tests/reference/record_database.py \
  --library /usr/lib/libalpm.so.16.0.1
```

It checks the same binary hash and records 12 local and 16 sync cases from private
roots: version creation/validation, directory identities, corrupt descriptions,
duplicates, tar and SQLite records, truncation, scalar parsing, ordered groups,
regex/AND search, reverse dependencies and usage visibility. SQLite fixtures use
Python's standard sqlite3 module. Native reads run in forked workers; no package
operation or host database is used. The parent cleans its private fixture tree.

The [database fixture](../fixtures/database-reference.json) is consumed offline
by `test-database`. Null/missing SQLite identities are recorded as reference
behavior but rejected by RLPM so they cannot corrupt typed indexes. Negative
reference size/error sentinels map to unavailable unsigned sizes with explicit
issues. [The database guide](../../../databases.md) lists these boundaries,
metadata limits, generation semantics and policy-aware verification.

The signature recorder captures integrity and signature policy:

```sh
python3 src/tests/reference/record_signature.py \
  --library /usr/lib/libalpm.so.16.0.1
```

The recorder checks the frozen library hash, creates private roots and ephemeral
GPG homes, and records 144 file-policy outcomes across twelve cases: full and
unknown trust, missing/unknown-key/bad/malformed signatures, multiple signatures,
expired keys/signatures, disabled keys and revocation. It captures real GPG
status/key listings, reference digest values and binary issuer data. No network
or host package operation is used; only fixture agents are stopped on cleanup.

Each case runs libalpm in a fresh fork because its GPGME initialization caches the
first home process-wide. Package-load expired-key preflight is recorded separately
from the low-level helper's acceptance of KEY_EXPIRED under allowed trust. The
[signature fixture](../fixtures/signature-reference.json) is replayed offline by
`test-verification`; live GPG tests independently exercise these integrations.
All original manifest assets remain unchanged. See the
[verification guide](../../../verification.md) for limits and remaining transfer/
transaction integration.

The resolver recorder captures prepare-time resolution without performing a
transaction commit:

```sh
python3 src/tests/reference/record_resolver.py \
  --library /usr/lib/libalpm.so.16.0.1
```

It checks the same frozen library hash and uses private local/repository/archive
fixtures, the C locale, scripted question answers and `NOLOCK`. It never calls
commit, downloads, refresh or the host package database. Native prepare runs in
forked workers; the parent owns and cleans the temporary tree. The recorder's
36 frozen pacman adaptations retain source paths/hashes and expected-failure
annotations. They exercise package selection, rather than the originals'
filesystem assertions. Another 118 focused cases and 160 seeded small universes
record ordered identities, preparation reasons, removals, questions, cycles,
failure payloads and final dependency edges/provisions. Nine option cases record
the native ANY/EQ restriction on AssumeInstalled; raw versions remain permissive.

The [resolver fixture](../fixtures/resolver-reference.json) is consumed offline
by `test-resolver` and `test`. Query captures include ignore and new-version
behavior. The final reason overrides are additionally checked against the pinned
commit source without committing any package. The [resolution guide](../../../resolution.md)
documents plan ownership, safety boundaries, evidence and deferred execution work.
This is prepare coverage, not a complete run of pacman's installation test suite.

The transaction recorder captures lifecycle errors, locks and events:

```sh
python3 src/tests/reference/record_transaction.py \
  --library /usr/lib/libalpm.so.16.0.1
```

The [transaction fixture](transaction.json) contains 16 scenarios for lock mode,
contents, timing, lifecycle errors, duplicate removals, flag-dependent prepare
events, and empty commit. The recorder checks the binary hash and uses only
private roots. It guards every commit by checking both native target lists;
nonempty commits are permitted only with NOLOCK, which is rejected before work.
It performs no downloads, refresh, package writes or host database operations.
`test-transaction` replays the lifecycle fixture; download, action and executor
suites cover later phases. Normal builds never load the reference library. See the
[transaction guide](../../../transactions.md) for representation and safety
differences, independent process tests and deferred UI integration.

`record_download.py` captures acquisition and refresh outcomes in
`download-oracle.jsonl`. The recorder checks the
frozen library hash and uses private roots, caches and file mirrors. Its only
nonempty commits independently require DOWNLOADONLY and an empty removal list.
Six outcomes are replayed by `src/tests/download.zig`; rejected-file cache retention
is an explicitly documented staging difference. These additions do not change
any original frozen asset.

The preflight recorder captures conflict, backup and inventory decisions in
[preflight.json](preflight.json):

```sh
python3 src/tests/reference/record_preflight.py \
  --library /usr/lib/libalpm.so.16.0.1
```

The 15 cases use the pinned library hash and disposable private roots. The
recorder commits inert generated `conf` payloads to observe private native
preflight/backup routines. Hooks/scriptlets are disabled and root, DB path and
flags are independently checked immediately before commit. No host package
database, downloads, hooks or scriptlets are used. Normal tests replay conflicts,
backup/pattern decisions and resulting inventory through the RLPM manifest;
they do not run an RLPM executor or load libalpm. The original frozen assets and
manifest remain unchanged. See [preflight.md](../../../preflight.md) for safety
differences and remaining executor/privileged-mount validation.

The action recorder captures hook and scriptlet behavior in
[actions.json](actions.json):

```sh
unshare --user --map-root-user --mount \
  python3 src/tests/reference/record_actions.py --library /usr/lib/libalpm.so.16.0.1
```

Nineteen cases capture hook tokenization, NeedsTargets, network permission,
AbortOnFail, dependencies, repeated actions, empty masking, scriptlet source and
version arguments, DBONLY, NOHOOKS and NOSCRIPTLET. Each native commit is guarded
by the pinned library hash and private root/DB/hook-directory checks. Only trusted
bash and runtime libraries are copied into the root; scripts are generated fixture
text. Host hook directories, services and ldconfig are never invoked. Run in an
environment that permits local Unix socket sendto: a transport sandbox that
blocks it makes native NeedsTargets input appear empty and invalidates capture.

`zig build test-actions` compares the frozen decisions and traces with real RLPM
stages. It uses a fixture executor to place the new local install member between
pre/post stages; executor tests cover production file and DB mutation. The
original frozen manifest/assets are unchanged. Source review additionally checked
`src/common/ini.c` and `util-common.c` from the exact downstream tarball identified
by `manifest.json` (download SHA-256 verified), since they were not included in the
original reduced source bundle. See [actions.md](../../../actions.md).

[record_executor.py](record_executor.py) captures full transaction behavior in
[executor.json](executor.json).
The 26 guarded private-root commits capture complete native phase/package/backup
ordering, inventories, contents, DBONLY/DOWNLOADONLY and suffix rotation. Regenerate:

```sh
unshare --user --map-root-user --mount \
  python3 src/tests/reference/record_executor.py --library /usr/lib/libalpm.so.16.0.1
zig build test-executor
zig build test-executor-integration
zig build test-executor-interop
```

The last target runs [check_executor_interop.py](check_executor_interop.py) with a
test-only Zig driver. It alternates RLPM and the pinned binary in both directions,
comparing local records (normalizing install time), modes/owners/times/xattrs,
hardlinks, backup preservation and native removal after an RLPM downgrade.
It never uses a host database or runs hooks/scripts. The driver requires an
explicit generated fixture marker under `/tmp/rlpm-executor-interop-*`. Ordinary
builds/tests do not depend on libalpm; the pinned-binary test is an explicit gate.
The executor also replays all 19 action traces through full commits in the
namespace suite.
See [execution.md](../../../execution.md) for scope and failure differences.
