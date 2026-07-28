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
- **Flatpak Support**: Manage Flatpak applications alongside native packages.

## Roadmap

Upcoming features and development targets:

- **Repository Modification**: Allow modification of supported repositories (In progress).
- **Package Import**: Allow for import of a previously existing package list to bring the system back to a saved package
  state. (Not yet started)
- **Multi Language Support**: Translation layer for supporting languages outside english
- **Offline Updates**: Similar functionality to pacman-offline script
- **Layout Customization**: Allow for customization of the individual user experience.

## Prerequisites

- **Arch Linux** (or an Arch-based distribution)
- **.NET 10.0 SDK** (for building)
- **vala** (for building)
- **libalpm** (provided by `pacman`)

#### Optional Prerequisites

- **Flatpak**: Can be installed via shelly inside settings by turning flatpak on.

## Installation

### Using PKGBUILD (Arch Linux)

Since Shelly is designed for Arch Linux, the recommended installation method is using the provided PKGBUILD files.

For the latest development version, use `PKGBUILD-git`:

```bash
git clone https://github.com/Seafoam-Labs/Shelly-ALPM.git
cd Shelly-ALPM
cp PKGBUILD-git PKGBUILD
makepkg -si
```

`PKGBUILD-git` follows the latest development branch and includes the newest changes.

If you previously installed Shelly manually using `local-install.sh`, remove the previous installation first to avoid conflicts with files managed by `pacman`:

```bash
sudo ./uninstall.sh
```

### Manual Build

Shelly can also be built manually from source.

The project currently uses Zig for building. Make sure all required build dependencies are installed before compiling.

Alternatively, you can use:

```bash
sudo ./local-install.sh
```

This will build Shelly and perform the installation steps automatically.

The binary files will be installed in:

```
/opt/shelly
```

To remove a manual installation:

```bash
sudo ./uninstall.sh
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

### CLI Configuration

Shelly-CLI uses a JSON configuration file to customize its behavior. On the first run, it automatically creates a
default configuration file at:

`~/.config/shelly/config.json`

#### Configuration Options

These are listed on the [Shelly Configuration](https://www.seafoam-labs.org/shelly-alpm/docs/config/) page.

## Development

Shelly is structured into several components:

- **Shelly.Gtk**: The main GUI desktop application.
- **Shelly-CLI**: Command-line interface for terminal-based package management.
- **Shelly-Notifications**: Tray service to manage notifactions the Shelly-UI.
- **PackageManager**: The core logic library providing bindings and abstractions for `libalpm`.
- **PackageManager.Tests**: Comprehensive tests for the package management logic.

### Building for Development

```bash
dotnet build
```

### Running Tests

```bash
dotnet test
```

### Generate CLI References

```bash
dotnet run --file help_compiler.cs
```

## License

This project is licensed under the GPL-3.0 License – see the [LICENSE](LICENSE) file for details.


