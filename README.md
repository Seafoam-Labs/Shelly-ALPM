![shelly_banner.png](shelly_banner.png)
 
### Powered by

<a href="https://jb.gg/OpenSource">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://www.jetbrains.com/company/brand/img/logo_jb_dos_3.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://resources.jetbrains.com/storage/products/company/brand/logos/jetbrains.svg">
    <img alt="JetBrains logo." src="https://resources.jetbrains.com/storage/products/company/brand/logos/jetbrains.svg">
  </picture>
</a>

## About

Shelly is a modern package manager for Arch Linux designed to be a more user-friendly alternative. Offering a visual interface with a focus on user experience and ease of use. Shelly supports native package operations through `libalpm` or `Shelly.Rlpm`, with libalpm selected by default. It is a complete reimagination of how a user interacts with their Arch Linux system, providing a more intuitive experience.

## Native backend selection

Default builds include both engines. Select RLPM with
`shelly config set NativePackageBackend rlpm`, or restore libalpm with
`shelly config set NativePackageBackend libalpm`. Build the CLI with
`zig build -Dlibalpm=false` for an RLPM-only binary. See the
[backend guide](https://seafoam-labs.org/shelly-alpm/docs/rlpm/) for defaults, packaging,
verification and the remaining release acceptance gates.

## Quick Install

The recommended installation method for Shelly is for CachyOS or using CachyOS packages

```bash
sudo pacman -S shelly
```

This will download and install the latest release, including the UI and CLI tools.

To install with an AUR helper like yay or paru.

```bash
yay -S shelly
```

or

```bash
paru -S shelly
```

## Uninstall

### For standard package removal

```bash
sudo pacman -Rns shelly
```

#### If installed from AUR

```bash
yay -Rns shelly
```

or

```bash
paru -Rns shelly
```

## Features

- **Modern-CLI**: Provides a command-line interface for advanced users and automation, with a focus on ease of use.
- **Native Arch Integration**: Configurable libalpm or RLPM backend, retaining CachyOS extensions.
- **Native Wayland Support**: Front end built using GTK4.
- **Package Management**: Supports searching and filtering for, installing, updating, and removing packages.
- **Repository Management**: Synchronizes with official repositories to keep package lists up to date.
- **AUR Support**: Integration with the Arch User Repository for a wider range of software.
- **Optional Flatpak Support**: Install `shelly-flatpak-backend` to manage
  Flatpak applications alongside native packages without making Flatpak a
  runtime dependency of the base Shelly package.

## AUR package availability

`shelly install aur` (`shelly -Ia`) requires the requested package and any AUR
build dependencies to be listed by the configured AUR service. Cached checkouts
and surviving Git repositories do not authorize building a removed package.
This also applies to `--version` installs. If availability cannot be verified
because the service is unreachable, retry once the connection is restored.

When an unavailable AUR package has an exact match in a configured repository,
Shelly suggests `shelly -Is <package>`. Explicit local builds with
`shelly build /path/to/PKGBUILD` and removal of installed packages remain
available without an AUR availability check.

To build an AUR package in a fresh native build root before installing it:

```bash
shelly -Ia --isolated <package>
```

Repository build dependencies stay in the guest; the exported package and its
runtime dependencies are installed on the host. This also supports `--needed`
and `--version`. As with `shelly build --isolated`, AUR-only build dependencies
and package signing are not yet supported. `--isolated` cannot be combined with
`--chroot` or dependency-only installation. See [isolated builds](https://seafoam-labs.org/shelly-alpm/docs/build/#isolated-container-builds--i---isolated)
for requirements and limitations.

## CLI file size display

To select units automatically in CLI size listings and transaction summaries:

```bash
shelly config set FileSizeDisplay Auto
```

`Auto` uses B, KiB, MiB, GiB, or TiB according to the magnitude. Bytes are shown
as integers; larger units are rounded to two decimal places. Negative size
changes retain their sign. Values that round to 1024 in a scaled unit are
shown in the next unit, up to TiB.

The existing `Bytes`, `Megabytes` (MiB), and `Gigabytes` (GiB) options remain
available. `Megabytes` remains the default; restore it with
`shelly config set FileSizeDisplay Megabytes`. This setting affects human-readable
CLI output; structured output keeps numeric byte counts.

## PKGBUILD review

Terminal PKGBUILD reviews show changed lines with three unchanged lines of
context before and after each change. Nearby changes share their context;
omitted sections are marked with the number of hidden lines. First reviews
without a previous PKGBUILD show the complete file.

`CollapsePkgbuildDiff` defaults to `true`, including for existing configurations
that do not contain the setting. To show the full file during review:

```bash
shelly config set CollapsePkgbuildDiff false
```

Restore the collapsed view with `shelly config set CollapsePkgbuildDiff true`.
Security warnings, attached source files, and approval prompts are always
handled as before. This setting controls terminal review output; GUI reviews
continue to receive the complete diff.

## AppImage checks during combined upgrades

To skip AppImage update checks and upgrades during `shelly upgrade all`:

```bash
shelly config set DisableAppImageUpdateCheck true
```

This also applies to combined-upgrade aliases, including bare `shelly` and
`shelly -U`. The setting defaults to `false`; restore AppImage checks with
`shelly config set DisableAppImageUpdateCheck false`. Explicit
`shelly upgrade appimage` and `shelly list-updates` checks remain available.
The one-time `shelly upgrade all --no-appimage` flag also skips AppImages.

## Flatpak checks during combined upgrades

To skip Flatpak update checks and upgrades during `shelly upgrade all`:

```bash
shelly config set DisableFlatpakUpdateCheck true
```

This also applies to combined-upgrade aliases, including bare `shelly` and
`shelly -U`. The setting defaults to `false`; restore Flatpak checks with
`shelly config set DisableFlatpakUpdateCheck false`. Explicit
`shelly upgrade flatpak` and `shelly list-updates` checks remain available.
The one-time `shelly upgrade all --no-flatpak` flag also skips Flatpak.
This preference can be used together with `DisableAppImageUpdateCheck`.

## Upgrade cache cleaning

To skip the package-cache cleanup prompt and deletion during `shelly upgrade all`:

```bash
shelly config set DisableCacheClean true
```

This also applies to upgrade-all aliases and takes precedence over
`AutoConfirmCacheClean`. The setting defaults to `false`; restore the existing
cleanup behavior with `shelly config set DisableCacheClean false`.
Standalone `shelly upgrade standard` keeps its existing cleanup behavior.
You can still clean the cache manually with `shelly purify standard --cache`.

Add `--aur-cache` to also delete **everything inside** the invoking user's
`$XDG_CACHE_HOME/Shelly` cache
(default: `~/.cache/Shelly`):

```bash
shelly purify standard --cache --aur-cache --dry-run
shelly purify standard --cache --aur-cache
```

The command previews each cache entry and asks for confirmation before deleting
it. Previewed directories are removed with all their contents, including AUR
PKGBUILDs, checkout history, sources, build trees, package archives, and metadata.
This also removes caches for packages that are no longer installed. The cache
root directory is retained; symlinks are removed without following their targets.
Files outside Shelly's cache are not included.

`--aur-cache` can also be used without `--cache`; standard purify still checks
for corrupted archives. The `--cache` retention count applies only to repository
package archives, not to Shelly's cache. The UI's **Clean Package Cache** action
performs both operations and clears the entire Shelly cache regardless of the
selected repository retention count.

## Roadmap

Upcoming features and development targets:

- **Repository Modification**: Allow modification of supported repositories (In progress).
- **Offline Updates**: Similar functionality to pacman-offline script
- **Layout Customization**: Allow for customization of the individual user experience.

## Prerequisites

- **Arch Linux** (or an Arch-based distribution)
- **zig 0.16.0** (for building)
- **vala** (for building)
- **libalpm** (provided by `pacman`; omitted from the CLI build with `-Dlibalpm=false`)

CI installs the prebuilt Arch **zig 0.16.0-1** package with its LLVM 21 runtime
dependencies. This package includes the `R_X86_64_PC64` linker fix required by
newer glibc startup objects. The shared setup action installs it after system
updates and verifies the package and compiler versions. Builds retain Zig's
normal backend defaults; CI does not rebuild the compiler.

### Optional Prerequisites

- **Flatpak support**: Install both `flatpak` and
  `shelly-flatpak-backend`. The backend is loaded only for a Flatpak operation.
  A base-only Shelly installation keeps ALPM, AUR, AppImage, help, version, and
  completion commands available.

## Installation

### Using PKGBUILD

Since Shelly is designed for Arch Linux, you can build and install it using the provided git `PKGBUILD`:

```bash
git clone https://github.com/Seafoam-Labs/Shelly-ALPM.git
cd Shelly-ALPM
cp PKGBUILD-git PKGBUILD
makepkg -si
```

### Manual Build

The native Zig components can be built and tested independently:

```bash
(cd Shelly.Flatpak.Backend && zig build integration-test)
(cd Shelly.Http && zig build test)
(cd Shelly.PackageManager && zig build test)
(cd Shelly.Cli.Zig && zig build test)
(cd Shelly.Ui.Gtk && zig build test)
```

To build both optional configurations and verify their ELF boundaries:

```bash
scripts/test-flatpak-separation.sh
```

## Usage

Run the application from your terminal:

For ui:

```bash
shelly-ui
```

For cli:

```bash
shelly
```

Notifications will be started with the ui, or it can be configured to launch at startup using your systems startup
configuration to run:

```bash
shelly-notifications
```

## Shelly-CLI

Shelly also includes a command-line interface (`shelly-cli`) for users who prefer terminal-based package management. The
CLI provides the same core functionality as the UI but in a scriptable, terminal-friendly format.

### CLI Commands

Full documentation can be viewed on the [Shelly CLI Reference](https://seafoam-labs.org/shelly-alpm/docs/cli-reference/) page.

Standard searches show available repository packages by default, with ranked
matches for a query or a paginated listing when no query is supplied:

```bash
shelly search standard firefox
shelly -Ss firefox
shelly search standard
shelly -Ss
```

Use `--detail`, `--info`, or `-d` to show metadata for one exact package name
(for example, `shelly -Ss --detail firefox`). Use `--installed` to search
installed ALPM packages or `--local` for Shelly-managed binary packages.
`--explicit` and `--depends` select installed packages when no source is given.
`--available` remains supported as an explicit repository source selector.

Use `--needed` with standard installs to skip same-version reinstalls while still
installing missing packages and allowing upgrades. The flag works before or after
package names, and `-n` remains the separate no-confirm option:

```bash
shelly -Is zed --needed
shelly -Is --needed zed git -n
```

This also applies to local Arch package archives. URL archives are downloaded
before their package metadata can be checked. Without `--needed`, reinstall
behavior is unchanged; Shelly binary archives are unaffected.

For AUR installs, `--needed` skips building and reinstalling packages with the
same installed version, including individual members of split packages:

```bash
shelly -Ia --needed yay
shelly install aur yay --needed -n
```

Shelly fetches and reviews the PKGBUILD before checking its generated package
metadata. Dynamic versions and VCS packages may still require a build; the
resulting archives also use `--needed` when installed. With `--version`, the
comparison uses the selected Git commit. Dependency-only installs still check
the requested dependencies even when the parent package is already installed.

Build a PKGBUILD and install the resulting packages in one command, including
any missing build dependencies:

```bash
shelly build -s -l
```

This mirrors `makepkg -si`. Administrator credentials are requested once, up
front: the build itself runs as your regular user, and the elevated
coordinator installs the built archives after the build completes. Like
`makepkg -i`, the install transaction adds only the built archives, so
combine it with `--sync-deps` when the package's dependencies may be missing.

Choose package compression with `shelly build --compression-level 3` (also
supported with `--isolated`). Presets 1–5 range from conservative resource use
to maximum compression effort. Set `package.compression_level` in
`shellybuild.conf` for a persistent preference; omission preserves library
defaults. See the [preset mappings and tradeoffs](docs/shellybuild.conf.md#package-compression).

Versioned JSON contracts for unattended package-building services are
available. Probe an installed binary with `shelly --version --json` before
scheduling a build.

Generate makepkg-compatible SRCINFO from a reviewed PKGBUILD without running
its build lifecycle:

```bash
shelly build --makesrcinfo --reviewed PKGBUILD > .SRCINFO
```

Update source checksums and the adjacent `.SRCINFO` together:

```bash
shelly build PKGBUILD --updpkgsums --reviewed
```

The path defaults to `./PKGBUILD`. Shelly downloads missing sources, preserves
existing checksum algorithms and `SKIP` entries, and updates generic and
architecture-specific arrays. Recipes without checksum arrays get SHA-256.
Pinned Git tags/commits use deterministic archive checksums; moving references
use `SKIP`. Existing cached downloads are reused; remove a cached file first
when intentionally refreshing a URL whose contents changed.

Both files are staged before publication. Metadata uses the same native
generator as `--makesrcinfo`, including `prepare()` and `pkgver()` when a version
function exists; checksums are refreshed for the resulting sources. Generation
failures leave the original files intact. Progress goes to stderr, and `--json`
reports success. This mode runs as a regular user and cannot be combined with
building, installation, or `--makesrcinfo`.

The AUR builder extracts source archives and decompresses standalone gzip/Unix
compress (`.gz`, `.z`, `.Z`), bzip2 (`.bz2`, `.bz`), xz (`.xz`), and zstd (`.zst`)
files before running `prepare()`. Standalone files must have matching compression
content and extensions. The output uses the source alias with its compression
extension removed: `dsearch-x86_64-1.6.0.gz` becomes `dsearch-x86_64-1.6.0`.
The original compressed file remains in `src`, and `noextract` entries stay
compressed. Decompression rejects output collisions and files exceeding 4 GiB;
failed source preparation discards the staging tree.

### CLI Configuration

Shelly-CLI uses a JSON configuration file to customize its behavior. On the first run, it automatically creates a
default configuration file at:

`~/.config/shelly/config.json`

#### Configuration Options

These are listed on the [Shelly Configuration](https://seafoam-labs.org/shelly-alpm/docs/config/) page.

## Development

Shelly is structured into several components:

- **Shelly.Ui.Gtk**: The native GTK4 desktop application.
- **Shelly.Cli.Zig**: Command-line interface for terminal and UI operations.
- **Shelly.Flatpak.Backend**: Optional versioned shared library containing all
  libflatpak/GLib-native implementation details.
- **Shelly.Http**: Standalone HTTP client with a compatibility TLS implementation.
- **Shelly-Notifications**: Tray service to manage notifactions the Shelly-UI.
- **Shelly.PackageManager**: Configurable libalpm/RLPM plus AUR/AppImage logic plus the
  backend-neutral Flatpak facade and secure loader.

### Building for Development

```bash
scripts/test-flatpak-separation.sh
```

### Running Tests

```bash
(cd Shelly.Flatpak.Backend && zig build test abi-test parity-test integration-test)
(cd Shelly.Http && zig build test)
(cd Shelly.PackageManager && zig build test)
(cd Shelly.Cli.Zig && zig build test)
```

The backend ABI, memory ownership, discovery rules, and version-bump procedure
are documented in [docs/flatpak-backend-abi.md](docs/flatpak-backend-abi.md).

## License

This project is licensed under the GPL-3.0 License – see the [LICENSE](LICENSE) file for details.
