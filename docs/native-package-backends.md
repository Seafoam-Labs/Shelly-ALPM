# Native package backends

Shelly builds both libalpm and RLPM by default and initially selects libalpm.
RLPM uses its Owner/Database/Package/Transaction implementation, including the
CachyOS SQLite database, architecture, installed-repository, and action sandbox
extensions. It does not delegate transactions to libalpm.

## Select a backend

```sh
shelly config get NativePackageBackend
shelly config set NativePackageBackend rlpm
shelly config set NativePackageBackend libalpm
```

The setting is stored in `shelly/config.json` under the resolved XDG configuration
directory, separately from `pacman.conf`. It takes effect on the next CLI
invocation. GTK uses the same selection through its CLI commands. Bootstrap
children explicitly receive the selected backend. Existing invoking-user/XDG
resolution also applies to this setting during privilege elevation.

An unknown value or non-string value fails with `InvalidBackend`. Explicit
`libalpm` in an RLPM-only build fails with `BackendUnavailable`, before package
work. There is no fallback after initialization or transaction failure.
`config get/list/set/reset` remain usable to inspect and repair these settings.
`config reset` resets **all** Shelly settings to that build's defaults. A saved
explicit backend survives changing builds; an omitted setting uses the compiled
default.

## Build and package

```sh
# Both backends, with libalpm as the initial selection (also the default).
(cd Shelly.Cli.Zig && zig build -Dlibalpm=true)
# RLPM only, with RLPM as the initial selection.
(cd Shelly.Cli.Zig && zig build -Dlibalpm=false)
```

`Shelly.PackageManager` and `Shelly.Tui` accept the same build option. The disabled
variant omits libalpm imports, header translation, pkg-config discovery, linkage,
and native binding tests. The GUI invokes the CLI and does not link either engine.

Install `shelly`; download and RLPM action workers are reserved modes of that
same executable. Child operations re-execute `/proc/self/exe`, so they also work
when the installed pathname is replaced during an upgrade. No companion worker
binaries or build-cache paths are needed.

Library embedders must call `PackageManager.internal_workers.dispatch(init, args)`
before application initialization and exit when it returns a status. Here `args`
excludes argv[0]. Alternatively, set `Manager.InitOptions.worker_executable` to an
absolute path to Shelly or another executable implementing that dispatcher.
RLPM owns a copy of the override and retains it across manager refreshes.
Worker modes share the host executable's dynamic dependencies: a libalpm-enabled
CLI loads libalpm even for an RLPM action, while an RLPM-only CLI excludes it.

Source PKGBUILDs accept `SHELLY_LIBALPM=false makepkg`; omitting it builds both.
The shared build needs libarchive, SQLite, curl, Zig, and the existing project
inputs. Default packages retain pacman/libalpm. RLPM-only source packages omit
the pacman build and runtime dependency, and verify that the shipped CLI matches
the requested variant. Prebuilt packages likewise declare the expected variant
with `SHELLY_LIBALPM` and reject a mismatched release binary. Pacman is optional for package-owner lookup during pacfile merging.
GPG and a populated host trust database remain necessary for signature verification.

`PKGBUILD-devario` builds the full application with RLPM only, pinned to a
published RLPM commit. It always passes `-Dlibalpm=false`, including in CLI and
PackageManager checks; `SHELLY_LIBALPM` does not override this recipe. The package
is named `shelly`, keeps Flatpak optional, and has no pacman, libalpm, or
`devario-alpm-runtime` dependency. Packaging rejects unresolved libraries or
transitive libalpm linkage in the shipped executables.

```sh
shelly build ./PKGBUILD-devario
# Alternatively, with makepkg and the build dependencies already installed:
makepkg -p PKGBUILD-devario
```

The recipe is self-contained: assets and configuration come from the pinned
checkout. It builds upstream's configuration/storage defaults. It does not apply
the separate Devario distribution patches for `/etc/shelly.conf`,
`/var/lib/shelly`, or `SHELLY_ALPM_CONFIG`; that distribution integration remains
in Devario's own package repository.

Only binaries compiled with `-Dlibalpm=false` use the explicit bootstrap package
set without requiring pacman in the [isolated-build profile](isolated-builds.md).
Selecting RLPM at runtime in a libalpm-enabled binary retains the existing
bootstrap packages and staging.
Recipe dependencies may still install pacman or libalpm inside the guest;
Shelly's compiled backend does not change the package being built.

## Library boundary

`PackageManager.Manager.init(allocator, environ, .{ .backend = .rlpm, ... })` selects an
engine explicitly. An omitted backend captures `PackageManager.Manager.defaultBackend()`.
`PackageManager.Manager.Backend.available()`, `PackageManager.Manager.libalpm_enabled`, and `PackageManager.Manager.default_backend`
expose compiled availability. Changing the process default affects future managers;
release the existing manager before switching engines for the same operation.
Both use the database's common `db.lck` transaction lock.

Public flags, events, errors, and package records live in backend-neutral modules.
Callers own query snapshots, including `get_single_installed_package` and
`load_archive` results, and must deinitialize them with the manager's allocator.
Snapshots survive refresh; borrowed satisfier names expire on refresh/deinit.
Use `CacheManager.Options.manager` instead of a raw libalpm handle. Raw C bindings
are confined to the libalpm implementation and its conditional reference tests.
AUR dependency callbacks propagate errors and cancellation separately from missing
packages.

Both mappings accept multiple cache directories/architectures, CacheServer,
AssumeInstalled, ParallelDownloads (1–255), DownloadUser, download timeout and
sandbox controls. `auto` expands using CachyOS runtime CPU/OS capabilities;
mirror `$arch` uses the first configured architecture. The system hook directory
precedes configured hook directories. `root_hooks_only` restricts bootstrap hooks
to the guest. RLPM update previews copy local metadata into a separate database
and reject transactions and aliased preview roots. On the first RLPM update check,
a legacy libalpm cache link to the configured local database is replaced with a
private metadata copy. Other database links are rejected; manual cache removal
is unnecessary when switching from libalpm.

## Verification and acceptance

```sh
scripts/test-native-backends.sh true Debug
scripts/test-native-backends.sh false Debug
scripts/test-native-backends.sh true ReleaseSafe
scripts/test-native-backends.sh false ReleaseSafe
```

The script runs private-root facade transactions and copied-executable worker tests, CLI
regressions, setting persistence/repair/reset and JSON/UI smoke checks, then ELF
checks on the installed CLI. The default variant tests both engines
and alternates writers against the same disposable root. RLPM-only artifacts must
have no direct/transitive libalpm dependencies or imported `alpm_*` symbols.
A clean local production build also passed in a temporary mount namespace with
libalpm headers, pkg-config metadata and libraries masked by empty files; the CLI
ran there successfully. CI repeats the disabled build after removing libalpm headers, pkg-config metadata,
and shared libraries **inside its disposable container**. Do not remove those
files from a working Arch system.

Worker consolidation validation on 2026-09-28 (Zig 0.16.0):

| Check | Result |
| --- | --- |
| CLI and native selection matrix | 414 CLI tests and 16 facade tests per variant; clean install, runtime selection, public help/completions and private worker protocols checked |
| RLPM core/public API/ledger | 230 tests passed in Debug and ReleaseSafe |
| GPG, action and executor integration | 15 signature, 18 action and 7 executor cases passed in Debug and ReleaseSafe |
| Download credential changes and queue callbacks | Both integration tests passed in a subordinate-ID namespace in Debug and ReleaseSafe |
| Copied executable and replaced pathname | Worker modes run from a copy without helpers; the real action transport re-executes after its host pathname is replaced |
| Optional Flatpak boundary | Both unified CLI variants passed the ELF separation check |
| Full nspawn isolated build | Not run: the smoke script returned 77 because sudo credentials were unavailable |
| Shell recipes, workflow YAML, whitespace | Passed |

The copied-worker check can also exercise real credential-drop downloads:

```sh
SHELLY_TEST_DOWNLOAD_SANDBOX=1 unshare --user --map-auto --map-root-user --setgroups allow \
  scripts/test-worker-modes.sh /absolute/path/to/shelly
```

This requires configured subordinate IDs, `newuidmap`/`newgidmap`, and kernel
sandbox support. Ordinary native matrix runs check the download setup-failure
protocol without requiring these privileges.

These integration checks do not certify the complete libalpm compatibility ledger.
The [completion plan](rlpm-libalpm-completion-plan.md) retains release gates for
privileged actions/sandboxes, independent reference behavior, parser fuzzing,
large-repository performance and full frontend workflows. The broad local PackageManager runs were restricted by socket and GPG permissions.
The loopback download and temporary-keyring signing fixtures subsequently passed
outside that restriction via `zig build native-environment-test`; CI runs that
focused target in both build variants. The broad suite's real AppImage download
remains unverified locally. Run the broad suite and privileged RLPM matrix in the
configured CI/container before release acceptance; do not treat blocked checks as
passes.
