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

Shelly is a modern package manager for Arch Linux designed to be a more user-friendly alternative. Offering a visual interface with a focus on user experience and ease of use. Shelly interfaces directly with `libalpm`. It is a complete reimagination of how a user interacts with their Arch Linux system, providing a more intuitive experience.

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

#### For standard package removal

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
- **Native Arch Integration**: Directly interacts with `libalpm` for accurate and fast package management.
- **Native Wayland Support**: Front end built using GTK4.
- **Package Management**: Supports searching and filtering for, installing, updating, and removing packages.
- **Repository Management**: Synchronizes with official repositories to keep package lists up to date.
- **AUR Support**: Integration with the Arch User Repository for a wider range of software.
- **Optional Flatpak Support**: Install `shelly-flatpak-backend` to manage
  Flatpak applications alongside native packages without making Flatpak a
  runtime dependency of the base Shelly package.

## Roadmap

Upcoming features and development targets:

- **Repository Modification**: Allow modification of supported repositories (In progress).
- **Offline Updates**: Similar functionality to pacman-offline script
- **Layout Customization**: Allow for customization of the individual user experience.

## Prerequisites

- **Arch Linux** (or an Arch-based distribution)
- **zig 0.16.0** (for building)
- **vala** (for building)
- **libalpm** (provided by `pacman`)

#### Optional Prerequisites

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

Full documentation can be viewed on the [Shelly CLI Reference](https://www.seafoam-labs.org/shelly-alpm/docs/cli-reference/) page.

The versioned JSON contracts used by unattended package-building services are
documented in [Remora automation contract](docs/remora-automation.md). Probe an
installed binary with `shelly --version --json` before scheduling a build.

Generate makepkg-compatible SRCINFO from a reviewed PKGBUILD without running
its build lifecycle:

```bash
shelly build --makesrcinfo --reviewed PKGBUILD > .SRCINFO
```

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

These are listed on the [Shelly Configuration](https://www.seafoam-labs.org/shelly-alpm/docs/config/) page.

## Development

Shelly is structured into several components:

- **Shelly.Ui.Gtk**: The native GTK4 desktop application.
- **Shelly.Cli.Zig**: Command-line interface for terminal and UI operations.
- **Shelly.Flatpak.Backend**: Optional versioned shared library containing all
  libflatpak/GLib-native implementation details.
- **Shelly.Http**: Standalone HTTP client with a compatibility TLS implementation.
- **Shelly-Notifications**: Tray service to manage notifactions the Shelly-UI.
- **Shelly.PackageManager**: Core libalpm/AUR/AppImage logic plus the
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
