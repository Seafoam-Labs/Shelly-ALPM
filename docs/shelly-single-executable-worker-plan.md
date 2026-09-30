# Run download and action workers through Shelly

## Target

Ship one `shelly` executable for the CLI, sandboxed downloads, and RLPM package
actions. Remove the separately installed `shelly-download-worker` and
`shelly-rlpm-action-worker` executables.

Shelly will launch a fresh instance of itself for each existing worker operation:

```text
shelly --internal-download-worker
shelly --internal-rlpm-action-worker
```

These reserved modes use the existing private protocols. They are excluded from
public help, completions, generated manuals, and normal command dispatch.
Credentials, chroot, network isolation, signal handling, and cancellation remain
confined to child processes. Download concurrency continues to use the existing
bounded queue.

This consolidation applies to both `-Dlibalpm=true` and `-Dlibalpm=false` builds.
Its scope is the CLI and these two helpers; GUI/TUI applications, external tools
such as GPG and systemd-nspawn, and the optional Flatpak library keep their
existing roles.

## Implementation evidence

The executable consolidation is implemented. Production builds install one CLI;
worker modules are linked into it, and RLPM launches `/proc/self/exe` with the
reserved argument. Library consumers have the shared dispatcher and one owned,
absolute `worker_executable` override. Noninstalled fixtures remain test-only.
Packaging and guest staging no longer copy companion worker executables.

Validation on 2026-09-28 with Zig 0.16.0:

- RLPM: 230 core/public/ledger tests, 15 signature cases, 18 action cases,
  7 executor cases, and the replaced-executable transport test pass in Debug
  and ReleaseSafe.
- Download sandbox: both tests pass in Debug and ReleaseSafe inside a
  subordinate-ID namespace. They cover all eight switch combinations, actual
  UID/GID changes, parent preservation, overlapping worker processes, and a
  fast transfer callback while a slow response remains blocked.
- Shared download module: 47 transport/queue tests and the native sandbox
  fixture pass in Debug. The minimal package module also passes its 27 tests.
- PackageManager: native, adapter, bootstrap and real guest-hook tests pass
  with libalpm enabled and disabled.
- CLI: 414 tests per build/optimization variant pass; copied-executable tests
  cover private protocols, malformed/bounded input, command exit statuses,
  extra arguments, and absence of CLI logs/configuration side effects.
  All four native matrix runs pass with libalpm enabled/disabled and Debug/
  ReleaseSafe. Real sandboxed downloads also pass through both CLI variants.
- Clean CLI and PackageManager install prefixes contain no companion workers
  or test fixtures. Shell recipes and workflow YAML validate; Flatpak separation
  remains intact. Stale local helper outputs were removed after rebuilding
  the existing RLPM-only ReleaseSmall CLI.

The full `systemd-nspawn` isolated-build gate remains unverified: the smoke
script exited 77 because this session lacked sudo credentials. Permission,
reviewed-input, source-key, private-root action and bootstrap regressions passed;
these do not substitute for that end-to-end gate.

A local warm-launch measurement (100 launches after 10 warmups, action command
`/usr/bin/true`, network allowed) measured median 0.533 ms for the previous
standalone action helper and 3.406 ms for the rebuilt RLPM-only ReleaseSmall CLI;
p95 was 0.802 ms and 4.212 ms respectively. Consolidation adds CLI/library startup
cost; it does not change the queue's concurrency or connection-sharing model.

## Starting implementation

- `Shelly.Cli.Zig/src/main.zig` already handles reserved self-execution modes for
  sandboxed commands and isolated-root provisioning before normal CLI setup.
- `Shelly.Download/src/worker.zig` receives one download request, applies the
  configured download sandbox, and returns binary progress/result packets.
- `Shelly.Rlpm/src/actions/worker.zig` receives framed action setup and stdin,
  configures the target root and network, and executes the requested command.
- `DownloadSandbox.zig` and `ActionProcess.zig` spawn separate worker paths.
  `OwnerConfiguration` stores independent `download_worker` and `action_worker`
  overrides; generated build options supply cache paths as fallbacks.
- PackageManager searches beside its executable for both helpers. CLI build
  targets, four package recipes, release archives, and isolated-root staging
  explicitly copy them.
- Tests rely on emitted helper paths, a staged-sibling fixture, and a separate
  action launcher that deliberately makes network namespace setup fail.

## Implementation sequence

### Extract reusable worker entry points

Turn the two worker entry points into callable routines with the same process
initialization inputs and exit behavior. Keep download logic in `Shelly.Download`
and action execution in `Shelly.Rlpm`.

Expose dedicated worker modules from their build scripts. The download worker
module can import the existing transport module; the action worker needs its
protocol and libc. A small RLPM worker dispatcher imports those two modules and
owns the reserved argument constants. PackageManager exposes that dispatcher to
the CLI through its existing dependency on RLPM.

The dispatcher must not depend on Owner initialization, PackageManager runtime
configuration, or CLI command code. Avoid a build dependency from either library
back to `Shelly.Cli.Zig`. Keep all new imports at the tops of their files.

Preserve both protocols, including action request versioning, request size
bounds, progress/result packets, setup errors, and child exit statuses. Handle
malformed input and unexpected worker arguments without entering normal CLI
dispatch or starting a package transaction.

### Dispatch worker modes before CLI initialization

Call the worker dispatcher immediately after decoding process arguments in
`Shelly.Cli.Zig/src/main.zig`, before normal stream wrappers, proxy input
processing, signal handlers, session logs, configuration loading, or UI setup.

Recognized worker modes complete their operation and exit directly. Preserve the
existing sandbox and bootstrap modes in the same early-dispatch layer. A worker
invocation must not produce banners, JSON/UI frames, log headers, or CLI error
formatting on its protocol streams.

The download mode still initializes proxy handling from its inherited environment
and applies credential/filesystem/syscall restrictions before fetching. The
action mode retains root descriptor validation, chroot, network policy, umask,
environment cleanup, signal reset, descriptor closure, and `exec` behavior.

### Re-execute Shelly from both parent transports

Replace `OwnerConfiguration.action_worker` and `download_worker` with one optional
`worker_executable` path. Copy and validate that path with the rest of the owned
configuration and update option ownership/allocation coverage.

For the normal Linux CLI, an absent override launches `/proc/self/exe` with the
appropriate reserved argument. This uses the running executable without a PATH
search or sibling-file lookup and continues to work if its installed pathname is
replaced during an upgrade. An explicit override must name an absolute executable
that implements both reserved modes.

Update `ActionProcess.zig` and `DownloadSandbox.zig` to construct those argument
vectors. Preserve their pipes/socketpair, process groups, progress forwarding,
timeouts, cancellation, partial-download recovery, sealed-file verification, and
publication behavior. Additional worker invocations remain governed by the same
download concurrency limit.

Remove `installedWorker()` from PackageManager configuration and delete the two
generated helper-path imports from production RLPM code. There must be no
production fallback to build-cache worker paths or legacy helper filenames.

Document the embedding contract: an executable using RLPM actions or sandboxed
downloads must either install the shared early dispatcher in its own entry point
or supply a matching Shelly executable through `worker_executable`. Audit the
standalone RLPM example and test executables against this contract. The current
TUI delegates package operations to the CLI, so those operations use Shelly's
dispatcher.

### Remove standalone production build artifacts

Remove worker executable creation and installation from the production targets
in `Shelly.Download/build.zig` and `Shelly.Rlpm/build.zig`. Wire the reusable worker
modules into RLPM/PackageManager without emitting separate production binaries.
Remove helper installation and artifact lookups from:

- `Shelly.PackageManager/build.zig`
- `Shelly.Cli.Zig/build.zig`
- `PKGBUILD`, `PKGBUILD-cli`, `PKGBUILD-git`, and `PKGBUILD-bin`
- `.github/workflows/release.yml`, including the CLI bundled with the GUI

Use clean install prefixes and release staging directories to verify that old
build outputs cannot hide a dependency on the removed executables. Package
upgrades should remove the old package-owned helper files through their ordinary
file lists; no replacement helper scripts or symlinks are needed.

Worker modes now share Shelly's ELF dependencies. A libalpm-enabled Shelly can
therefore load libalpm and curl even when entering action mode. Replace tests and
documentation that assume the action executable has its own minimal dependency
set. An RLPM-only Shelly must still have no direct or transitive libalpm dependency,
and the optional Flatpak loading boundary must continue to pass its existing
checks.

### Stage one executable in isolated build roots

Remove the worker-name inventory from
`Shelly.PackageManager/src/alpm/build_root.zig`. Update
`Shelly.Cli.Zig/src/commands/isolated_build.zig` to stage only Shelly at the existing
guest executable path and validate that executable's runtime library closure.
Both worker modes then re-execute the staged Shelly inside the guest.

Update guest permission fixtures and
`Shelly.Cli.Zig/scripts/test-isolated-build.sh` to assert the single-executable
layout. Preserve the compile-time provisioning profile selection: only
`-Dlibalpm=false` uses the explicit RLPM-only package set without requiring
pacman/libalpm for Shelly itself. Recipe dependencies may install those packages
in the guest. Runtime backend selection must not change the provisioning profile.

Exercise host bootstrap, guest queries, dependency installation, package actions,
artifact validation/export, and optional host installation using the new launch
path. Retain reviewed-input, source-key, ownership, and operation-root cleanup
checks.

### Adapt fixtures and deployment documentation

Library tests must not acquire a dependency on building the whole CLI. Provide a
test-only executable that imports the shared worker dispatcher directly. Build it
only for relevant test targets, do not install it, and pass its path explicitly
through fixture configuration. Its module graph must not depend on the Owner
module that consumes the fixture path.

Update the action failure-injection launcher to forward the reserved argument to
this dispatcher while retaining the controlled namespace failure. Update executor
fixtures, sandbox tests, and PackageManager tests that invoke child operations.
Retain the existing Zig test runners and their test-discovery behavior.

Replace the staged-sibling assertion in
`Shelly.PackageManager/src/alpm/backend_test.zig` with appropriate launcher
configuration checks. Move the deployed-executable proof into
`scripts/test-native-backends.sh`: copy only the built Shelly into a fresh
directory and exercise both worker modes there with disposable fixtures and
isolated configuration. This must demonstrate behavior, not just path equality.

Update `docs/native-package-backends.md`, `docs/isolated-builds.md`,
`Shelly.Download/README.md`, and RLPM action/download/configuration documentation
to describe self-execution, the embedding API, and the new installation layout.
Use descriptive test and section names throughout.

## Validation and acceptance

| Area | Required evidence |
| --- | --- |
| Build variants | Build and test both libalpm settings; exercise both runtime backends when compiled in and retain the unavailable-backend error otherwise. |
| Installed artifacts | Clean CLI install and release/package staging contain `shelly` with no separate worker executables or legacy launch dependencies. |
| Early dispatch | Valid worker requests succeed without CLI setup; invalid/truncated/oversized requests and extra arguments fail without contaminating protocol output or creating session logs. |
| Download behavior | Existing cache, refresh, signature, resume, timeout, retry, concurrency, progress, and cancellation tests pass through the new launch interface. Run actual sandboxed downloads in an environment that permits the required privilege transitions. |
| Action behavior | Hook/scriptlet/ldconfig, network-policy failure, concurrent stdin/output, parent-state preservation, process-group cancellation, and full executor integration tests pass. |
| Relocation | A copied Shelly runs both modes without sibling helpers or source-cache paths; self-execution also works after its original pathname is renamed/replaced. |
| Isolated builds | Complete an RLPM-only isolated build with only Shelly staged and no pacman/libalpm needed by the recipe; also build a recipe that declares and links to libalpm while Shelly remains independent, and run the existing libalpm-enabled isolation regressions. |
| Library consumers | Relevant library test targets use explicit, noninstalled fixtures; embedders have a documented dispatcher/override contract and configuration ownership coverage. |
| Dynamic dependencies | Inspect the unified executable and transitive libraries for each build variant; preserve the RLPM-only and optional Flatpak boundaries. |
| User-facing behavior | Help, version, completions, normal output formatting, UI protocol, and bootstrap/sandbox entry points retain their behavior. |

Run the existing RLPM `test`, `test-signature`, `test-actions`, and
`test-executor-integration` suites, plus download sandbox integration where
privileges permit it. Run PackageManager native-backend/adapter/bootstrap tests,
CLI tests, and the updated native-backend and isolated-build scripts. Include
Debug and ReleaseSafe coverage for the worker/executor paths.

Measure child startup and concurrent-download behavior against the current
implementation: the action child now loads the larger CLI, and the refactor must
not introduce serialization or delayed progress. Keep privileged runtime gates
explicitly unverified if only their compilation was possible.

Implementation is complete when one deployed Shelly handles normal commands and
both worker protocols in fresh processes, clean packaging requires no companion
workers, and the integration gates above pass.
