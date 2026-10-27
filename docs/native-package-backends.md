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

## Distribution paths and configuration

Path selection is independent of backend selection. Builds use the `pacman`
profile by default, including RLPM-only builds. Opt into Devario defaults with:

```sh
(cd Shelly.Cli.Zig && zig build -Dlibalpm=false -Dpath-profile=devario)
(cd Shelly.Key && zig build -Dpath-profile=devario)
```

`Shelly.PackageManager` accepts the same `-Dpath-profile=pacman|devario` option.
The shared `Shelly.Paths` module supplies these defaults:

| Setting | `pacman` (default) | `devario` |
| --- | --- | --- |
| Configuration | `/etc/pacman.conf` | `/etc/shelly.conf` |
| Database | `/var/lib/pacman` | `/var/lib/shelly` |
| Package cache | `/var/cache/pacman/pkg` | `/var/cache/shelly/pkg` |
| Keyring | `/etc/pacman.d/gnupg` | `/etc/shelly.d/gnupg` |
| Public key bundles | `/usr/share/pacman/keyrings` | `/usr/share/shelly/keyrings` |
| Transaction log | `/var/log/shelly.log` | `/var/log/shelly.log` |
| System hooks | `/usr/share/libalpm/hooks` | `/usr/share/rlpm/hooks` |
| Administrator hooks | `/etc/pacman.d/hooks` | `/etc/shelly.d/hooks` |

Bootstrap uses the selected profile too; the default profile retains its legacy
`/var/log/pacman.log` bootstrap log. Profiles supply defaults, not a migration:
building a new profile does not move an existing database or keyring.

Pacfile, cache-cleanup, and archive-cache fallback options use the same profile.
Explicit caller options and configuration still override those defaults.
`shelly --config /path/to/config utility --repair-db` resolves `DBPath` from that
configuration before removing a stale lock. Configuration is parsed without
opening the package database; an unreadable explicit configuration fails before
any lock is touched.

`shelly-key --populate` reads public bundles and their trusted/revoked lists from
the profile's public key bundle directory. `--populate-from` overrides that
source directory. Devario keyring packages must install their bundles under
`/usr/share/shelly/keyrings`; the Devario profile does not fall back to the pacman
bundle directory.

[Isolated dependency plans](build-dependency-plans.md) use these same profiles and
configuration rules for both resolution and pinned provisioning.

Select another native package configuration for an invocation with the global
`--config` option, before or after the command:

```sh
shelly --config /etc/shelly.conf search standard --repos
shelly search standard --config=/etc/shelly.conf firefox
```

The selected path is made absolute before dispatch and retained across elevation,
AUR build coordinators, and native bootstrap subprocesses. Native key commands
use the selected file's `GPGDir`; `keyring ... --user` still uses the user's keys.
An explicitly selected unreadable file or unreadable include fails instead of
silently using defaults. The existing tolerant read policy remains in place when
no explicit configuration was supplied.

Configuration directives (`DBPath`, `CacheDir`, `GPGDir`, `LogFile`, `HookDir`,
and others) override the profile defaults. Library callers can override those
values with `Manager.InitOptions`; `config_path` selects the file to read.

### File migration policy

RLPM supports package-declared `shelly_migrate` entries and automatic adoption
of eligible unowned files supplied by incoming archives. Devario builds enable
automatic discovery by default; pacman-profile builds disable it. Override with
`AutoMigrateUnowned = true|false` under `[options]` in the native configuration.
Explicit declarations remain available when automatic discovery is disabled.

See the [migration guide](../Shelly.Rlpm/migration.md) for PKGBUILD syntax,
replacement ownership rules, backup behavior, and release compatibility.
Shelly's libalpm backend rejects archives declaring these RLPM semantics.

### Hook directory policy

`HookDir` remains additive by default. To use only the listed directories:

```ini
[options]
HookDirMode = Replace
HookDir = /usr/share/rlpm/hooks/
HookDir = /etc/shelly.d/hooks/
```

`HookDirMode = Append` is the default. Mode selection applies to the complete
list, including entries from included files, regardless of where the mode is
specified. In replacement mode, omitting `HookDir` disables discovery. An unknown
mode is an error. Directory order is preserved so later administrator hooks and
`/dev/null` masks can override earlier system hooks.

Both native backends receive the resolved list; neither adapter adds a legacy
hook directory afterward. Library callers can set
`Manager.InitOptions.hook_directories` to replace the complete list: `null` uses
configuration, `&.{}` disables discovery, and a nonempty slice specifies the
ordered directories. With `root_hooks_only`, explicitly supplied directories
are interpreted beneath the target root; otherwise that mode uses the profile's
system and administrator hook locations beneath the target root.

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
with `SHELLY_LIBALPM` and reject a mismatched release binary. Pacfile owner lookup
reads the configured local package database directly, so three-way diff and merge
do not require the pacman executable. They still need a suitable cached base
archive and the configured extraction/diff/merge tools. Missing owners or base
archives retain the two-way diff fallback; unreadable owner metadata is an error.
GPG and a populated host trust database remain necessary for signature verification.

`packaging/devario/PKGBUILD` builds the release tag matching `pkgver` (currently
`v3.1.8`). `packaging/devario/shelly-git/PKGBUILD` tracks the `development` branch.
Both use `-Dlibalpm=false -Dpath-profile=devario`, including the matching key tool
and backend tests. Neither recipe applies downstream patches
or requires `devario-alpm-runtime`. Their checks include native pacfile ownership,
helper path defaults, BUILDINFO database selection, and sandbox allow-list
regressions.

```sh
shelly build ./packaging/devario/PKGBUILD
```

The separate root `PKGBUILD-devario` is a historical pinned recipe. Its current
`bcbba6aa` pin predates path-profile support even though the recipe passes that
option. Refresh that pin to a published commit containing these fixes before
using it for a release. The release and development recipes above do not use that pin.
Use `--config` for runtime configuration overrides; the former downstream
`SHELLY_ALPM_CONFIG` variable is not supported.

Only binaries compiled with `-Dlibalpm=false` use the explicit bootstrap package
set without requiring pacman in the [isolated-build profile](isolated-builds.md).
Selecting RLPM at runtime in a libalpm-enabled binary retains the existing
bootstrap packages and staging.
Recipe dependencies may still install pacman or libalpm inside the guest;
Shelly's compiled backend does not change the package being built.

## Native build metadata

CLI builds pass their selected configuration to BUILDINFO collection. AUR builds
also preserve the active manager's backend, root, and database overrides. The
builder enumerates installed packages when writing metadata, after build
dependencies have been installed. Isolated guests use their own configuration;
the host-only configuration used during provisioning is not forwarded into the
guest build command.

Library callers can set `builder.BuildOptions.native_database` with
`builder.BuildDatabase.fromManager(manager, config_path)`, or supply its
`backend`, `config_path`, `root_directory`, and `database_path` fields directly.
These paths are borrowed until `PackageBuilder.deinit()`. The existing
`installed_packages` snapshot overrides database collection when supplied.
`Manager.PacfileManagerOptions.pacman_command` was removed along with the subprocess;
callers should select `database_path` and `root_directory` instead.

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

For local validation, the test runner detects whether native libalpm headers,
linker inputs, and runtime loading are available:

```sh
scripts/test-native-backends.sh                  # auto, Debug
scripts/test-native-backends.sh auto ReleaseSafe
```

When libalpm is unavailable it prints a `SKIP` message for the libalpm-specific
checks and continues with the complete RLPM-only variant. Explicit `false`
bypasses detection. Explicit `true` requires libalpm and fails if it is missing,
so CI cannot silently lose coverage.

Direct `zig build test --summary all` commands in `Shelly.PackageManager` and
`Shelly.Cli.Zig` also work without libalpm. With no `-Dlibalpm` option, native
test targets check for `libalpm` through pkg-config and omit libalpm-specific
tests when its development files are unavailable, printing a diagnostic. RLPM
and backend-independent tests still run. An installed but broken libalpm
installation remains a test failure. Explicit `-Dlibalpm=true` requires libalpm;
`-Dlibalpm=false` disables it. Cross-target tests retain the default enabled
backend unless explicitly disabled. Production modules retain their default
of including both backends, even when built alongside auto-selected tests.

The wrapper's selection logic has an independent regression suite:

```sh
python3 scripts/test-native-backend-selection.py
```

CI and hosts with libalpm can require each matrix variant explicitly:

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
