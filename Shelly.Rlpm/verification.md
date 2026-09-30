# Integrity and signature verification

RLPM enforces the effective `SignaturePolicy` when loading sync databases and
packages through `Owner`. CachyOS SQLite and tar repositories use the same
verification path. Local installed-database metadata retains its recorded
validation history; it does not receive a detached database-signature check.

```zig
var package = try owner.loadPackage(io, archive_path, .local_file, .{ .mode = .full });
defer package.deinit();
// package.validation describes the checks performed during this load.
var reader = try package.openArchive(allocator);
defer reader.deinit();
```

`Owner.PackageSource` selects `.local_file`, `.remote_file`, or
`.{ .repository = package_ref }`. Repository references must belong to the
current sync-cache generation. They supply the expected name/version, digests,
embedded signature and repository policy. Local and remote file policies inherit
the owner's default when null. Repository overrides likewise inherit when null.
The owner's initial policies remain disabled, matching the pinned library's
handle defaults. A standalone `SignaturePolicy{}` requires signatures.

| Requirement | Absent signature | Present signature |
| --- | --- | --- |
| `disabled` | No signature check | No signature check |
| `optional` | Allowed | Every signature must satisfy validity and trust |
| `required` | `SignatureMissing` | Every signature must satisfy validity and trust |

Full/ultimate trust passes. Marginal and unknown trust require their respective
allowances; neither allowance permits never-trusted, revoked, disabled, unknown
or invalid signing keys. Signature expiry fails. The pinned helper accepts a
cryptographically valid signature from an expired key subject to trust, but
`alpm_pkg_load` first tries to refresh expired keys. RLPM preserves that distinction:
database/repository checks apply trust directly, while local/remote file loading
asks the import question before retrying an expired key.

Repository checksums prefer SHA-256, falling back to MD5. An enabled embedded
signature supersedes repository digests, matching the reference; detached
signatures still require any supplied digest. Disabled signature checking still
checks supplied digests. `ChecksumMismatch` stops loading before archive parsing.
Neither a successful metadata-only parse nor a populated file inventory proves
payload integrity.

## Ownership and file identity

Loading copies the input into an anonymous sealed Linux `memfd`, using a fixed
64 KiB copy buffer. GPG and libarchive read the same sealed bytes. A database
candidate is published only after verification and parsing succeed; rejected
reloads retain the prior usable cache and package references. A returned package
owns its sealed file until `deinit`, and `openArchive`, `openMember`, and
`openMtree` use that file even if the original path is replaced. Readers already
opened remain valid after package release. `archive_path` retains the original
pathname for diagnostics and sidecar retrieval.

The snapshot occupies RAM/swap proportional to the archive size and requires
Linux memfd sealing and `/proc` access. Descriptor, memory and copy failures
propagate. Changing file size during copying reports `FileChanged`. Future
transaction extraction must use the package's retained archive reader; reopening
the original path would require verification again. Every `Owner.loadPackage`,
including a cache hit, applies the current policy. Existing metadata snapshots
remain owned generations; changing the effective database policy or GPG directory
invalidates them through `setOptions`.

`Package.loadArchive` remains an explicitly unverified metadata API. Use
`Owner.loadPackage` for an authenticated load. Sync metadata has
`validation.none = true`; `availableValidation()` reports which digests/signature
are advertised. Local `validation` flags retain installation history. This
separation intentionally avoids presenting repository promises as performed
checks, unlike libalpm's sync metadata getter.

## Results and key acquisition

`Owner.last_verification` describes the last package attempt;
`Database.last_verification` describes the last database attempt, including
rejected reloads. They are owned by their containing object and replaced by the
next attempt. Null means no GPG check completed. `SignatureResult` retains all
signature results, signing and primary fingerprints, key IDs, decoded UID/name/
email, signature dates/algorithms, key dates/size/revocation state, crypto
validity, trust, termination, raw status output and stderr. Key-list/import
process diagnostics are retained in `key_operations`. Spawn/read errors propagate
as their original Zig errors; unsuccessful completed processes retain results.

`Verification.check` is the lower-level policy API, taking an `ImmutableFile`,
expected digests/signature, a `Context`, and an optional result slot. The caller
must release a returned report even when the check returns an error.
`SignatureResult.check` applies trust to already captured results.
`Verification.verify` exposes structured cryptographic results without applying
trust; callers of this path-based primitive must pin their own input files.
The legacy `Database.validateSignature` returns only cryptographic success and
does not enforce trust. It is not used to authorize cache publication.

GPG always uses the configured `gpg_directory`, or `/etc/pacman.d/gnupg` when
null, never the user's default home. Verification/listing uses `--no-options`,
disables automatic key acquisition, trustdb updates and agent startup, and requests
all signatures even after a bad one. Trust is read from the configured keyring's
trustdb; keyring maintenance must refresh that trustdb when appropriate.

Unknown keys invoke the existing `Callbacks.Question.import_key`, defaulting to
denial. Callback reentry is rejected and cancellation is checked before any
import. After consent, `key_acquisition` tries configured `key_files` in order,
then WKD when an email is available, then the configured keyserver. Network
routes can be disabled independently; a null keyserver uses the configured
keyring's GPG server settings. Only acquisition commands read those GPG options.
WKD must supply the requested key before it can skip the keyserver fallback.

Local key sources must each contain one public primary key and its subkeys;
unrelated bundles and secret keys are rejected. The requested fingerprint or
long key ID must match before import. A successful import triggers verification
again and never grants trust by itself. Denial, unavailable acquisition routes,
and failed imports produce distinct errors. No live network service is used by
the tests; remote acquisition argument/order behavior uses an injected process
adapter, and consent/import/reverification use real disposable GPG keyrings.

## Helpers and evidence

- `Checksum.bytes` / `Checksum.file` return lowercase MD5 or SHA-256; `check`
  compares the expected digest. `Package.checkMd5sum` requires a sync package and
  an explicit cached path.
- `Package.getSignature` returns embedded signature bytes first, otherwise the
  supplied archive's sidecar; `decodeSignature` and `OpenPgp.decode` decode base64.
  The caller owns returned bytes. Cache-directory selection belongs to download planning.
- `OpenPgp.extractIssuers` owns ordered key IDs and issuer fingerprints from
  binary v4 document-signature packets. It does not authenticate those claims.
  Partial/indeterminate packets and unsupported versions/classes return errors.
  Detached and decoded embedded signatures are bounded to 16 KiB. ASCII-armored
  sidecars are accepted by GPG verification; binary issuer extraction is separate.

`test-verification` includes an offline replay of 144 package policy decisions
across twelve independently captured reference cases, plus checksums, issuer
parsing, inherited policies, performed flags, malformed statuses, multiple
signatures, process failures, allocation failures, cache replacement and kernel
sealing. `test-signature` retains five legacy regressions and adds seven real
GPG cases covering trust, consent, cancellation, unrelated-key rejection,
reverification, multiple signatures, expiry, disabled/revoked keys, tampering and
database publication. The optional [recorder](src/tests/reference/record_signature.py)
hash-checks the pinned library and isolates each keyring in a fresh process.

Validated on 2026-09-28: 105 normal tests in both Debug and ReleaseSafe, 14 focused
verification tests and 25 standalone package tests (overlapping the normal
suite), 12 real GPG cases, and 147 `Shelly.Key` tests. No claim of exhaustive
libalpm parity is made; compatibility rows remain partial with explicit evidence.

Downloads feed files through these checks before refresh publication; preflight
and execution use verified package readers before installation. Full libalpm
parity remains subject to production acceptance.
