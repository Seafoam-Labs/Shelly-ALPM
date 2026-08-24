# AUR Package Builder

Shelly's standalone AUR build engine. It builds packages directly from
PKGBUILDs **without makepkg**: PKGBUILD lifecycle functions run as ordinary
bash child processes of a **non-root** builder, and package archives are
written by Shelly's own archive writer. The engine is split into focused
modules so each stage of the pipeline can be reviewed and tested on its own.

## Build lifecycle at a glance

```
                preparePkgbuildReview (pkgbuild_review.zig)
                  digest PKGBUILD + reviewed files
                              │
PackageBuilder.runWithOperation (builder.zig)
  1. re-check the reviewed digest            (runWithOperation)
  2. validate build directories              (steps.zig)
  3. open the build log                      (steps.zig)
  4. buildPackage:
     a. sandbox-evaluate deferred metadata   (steps.zig)
        and re-review discovered local files (pkgbuild_review.zig)
     b. validate package-function shape      (builder.zig)
     c. acquire + verify + extract sources   (sources.zig)
     d. run prepare/pkgver/build/check steps (steps.zig)
     e. per package: run package() step,
        assemble + sign the archive          (package_file.zig)
```

`PackageBuilder` (in `builder.zig`) is the orchestrator; it owns no pipeline
logic itself anymore — every stage is delegated to a sibling module and passed
the builder as `self: *PackageBuilder` for access to configuration, IO, and
the active operation/log.

## Files

| File | Role |
|---|---|
| `builder.zig` | **Orchestrator + public API.** `PackageBuilder` (init/run/runWithOperation/BuildPackage), review re-check, sandbox-evaluated scalar/array reparse, ordinal-safe remapping of shell-resolved split-package names, and lifecycle sequencing, plus the public types `BuildArtifact`, `BuildOptions`, `BuilderErrors`, `FailureLocation`. Re-exports the security entry points and the review/validation modules so external callers (`aur/manager.zig`, `root.zig`, the CLI) only import this file. |
| `source_spec.zig` | **Pure source-entry parsing.** `ParsedSource.parse` classifies `source=()` entries (local/http/git), handles `name::url` renames, `#branch=/tag=/commit=` fragments and `?signed` queries; detached-signature pairing (`findDetachedPayload`); archive-name and symlink-target safety checks. No IO, no builder state — fully unit-tested in-file. |
| `checksums.zig` | **Checksum tables.** Maps the seven PKGBUILD sum arrays (`sha512sums` … `b2sums`) into `checksumSets`, enforces count/SKIP rules, and verifies file hashes (`verifyFileHash`). |
| `metadata.zig` | **Metadata + option helpers.** makepkg option merging (`effectivePackageOptions`, `!option` semantics), `pkgver` validation, ownership-safe replacement of optional strings/arrays, and application of runtime-captured package metadata onto the parsed PKGBUILD (`applyPackageMetadata`). |
| `security.zig` | **Privilege guards.** Non-root effective-UID policy, `prctl(NO_NEW_PRIVS)` process lockdown (`setNoNewPrivs` is shared with the sandbox wrapper), randomized unique work directories, and `narrowBuilderError` (anyerror → `BuilderErrors`). |
| `sandbox.zig` | **Landlock step confinement.** Raw Landlock syscalls (ruleset create/add-rule/restrict-self), the ABI probe, the base and per-build allow-list, the `__sandbox-exec` wrapper protocol (`parseWrapperArguments`/`buildWrappedCommand`), and their unit tests. Steps re-execute through the CLI wrapper so only the untrusted bash children are confined. |
| `sources.zig` | **Source pipeline.** Copies local files, downloads HTTP sources into the cache, mirror-clones git sources, verifies checksums and PGP signatures (including compressed `.sig` payloads), runs the optional `verify()` step, and safely extracts archives into the staging tree (path traversal, symlink, and size limits). |
| `steps.zig` | **Step execution.** Build-directory validation, build logging, lifecycle Bash execution, and atomic sandboxed capture of the reviewed PKGBUILD's changed scalar and indexed-array state. Scalar and array set/unset records are NUL-delimited, validated, and bounded before becoming parser overrides. Also owns messaging/virtual-metadata preludes, stream forwarding, `pkgver()` capture, and package-metadata capture. |
| `package_file.zig` | **Package assembly.** `tidy`/strip handling, `.PKGINFO` and `.BUILDINFO` writers, install-script/changelog placement from reviewed contents, `.MTREE` generation, archive creation via the Shelly archive writer, detached OpenPGP signing, and rollback cleanup. |
| `pkgbuild_review.zig` | **Review snapshot.** `preparePkgbuildReview` hashes the PKGBUILD plus its local/install/auxiliary files into a `Digest` and keeps byte-exact copies (`ReviewedFile`); the builder re-checks this digest immediately before executing anything, so a PKGBUILD changed after approval is rejected. |
| `pkgbuild_validation.zig` | **Validation facade.** Runs the pkgbuild validator suite (shared validator, homograph, post-install/install-script scanners, local-source checks) over parsed PKGBUILDs and reports findings. |
| `builder_test.zig` | **Black-box test suite (~2,900 lines).** Exercises `PackageBuilder` strictly through its public API: full builds, split packages, review-integrity rejection, PGP verification, signing, strip behavior, non-root guard. Wired in via the test block in `src/root.zig` and the aur-test filter in `build.zig`. |
| `chroot-builder/models.zig` | Work-in-progress stub (8 lines) for a future chroot-based builder: `Role` and `BuildNode` only. Not referenced by the pipeline yet. |

## Module dependencies

```
builder.zig ──> security, sandbox, steps, sources, package_file, metadata,
                pkgbuild_review, pkgbuild_validation
sources.zig ──> steps, checksums, source_spec, metadata
steps.zig   ──> metadata, sandbox
package_file.zig ──> steps, metadata
security.zig, sandbox.zig, checksums.zig, source_spec.zig, metadata.zig ──> (leaves)
```

All modules import `PackageBuilder` from `builder.zig` for the shared build
context (allocator, IO, options, active operation/log); struct fields are
accessible across files, so no getters are needed.

## Reviewing tips

- **Start with `builder.zig`** (~340 lines) — it reads as the pipeline index.
- **Security-critical paths:** `sources.zig` extraction guards
  (`ensureSafeArchivePath`, `rejectSymlinkDestination`, size caps),
  `security.zig` privilege handling, `sandbox.zig` Landlock confinement
  (allow-list construction and the `__sandbox-exec` wrapper protocol), and
  the virtual-metadata prelude in `steps.zig` (fakeroot simulation that
  rejects privileged operations with exit code 97 →
  `PrivilegedPackageOperationUnsupported`).
- **Integrity model:** nothing executes until the reviewed digest matches
  (`builder.zig` `runWithOperation`). Deferred source commands execute only
  after that check and inside the configured build sandbox. A resolved local
  source changes the review digest and requires a supplemental structured
  review before source acquisition; the final snapshot is checked again to
  close review/build races.
- Every module carries `//!` header docs, and leaf modules carry their unit
  tests in-file.

## Running the tests

```sh
cd Shelly.PackageManager
zig build test          # full suite incl. builder_test.zig and module unit tests
zig build flatpak-test  # CI gate
```

Note: `builder-test` output includes a `failed command: .../test --listen=-`
line even on a fully green run — judge results by the exit code and the
`Build Summary` line, not by grepping for "failed".
