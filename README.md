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

Shelly is a modern reimagination of the Arch Linux package manager, designed to be a more intuitive and user-friendly
alternative to `pacman` and `octopi`. Unlike other Arch package managers, Shelly offers a modern, visual interface with
a focus on
user experience and ease of use; It **IS NOT** built as a `pacman` wrapper or front-end. It is a complete reimagination
of how a user
interacts with their Arch Linux system, providing a more streamlined and intuitive experience.

<details>
  <summary>Screenshots</summary>
  <p align="center">
  Search Standard Packages, AUR, and Flatpak in one place

  <img width="1372" height="1019" alt="image" src="https://github.com/user-attachments/assets/6aa86662-d9f6-4d3c-9164-9df5d05257b3" />
  <img width="1768" height="1177" alt="image" src="https://github.com/user-attachments/assets/8e9d851b-a3a0-4aaf-b91a-b3b3c3ec7f6d" />
  <img width="1768" height="1177" alt="image" src="https://github.com/user-attachments/assets/cc2a8d31-e5c9-42d4-ba87-db25e10a1110" />
  </p>
</details>

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
- **App Image Support**: Further app image support similar to [AppLever](https://github.com/mijorus/gearlever). (In
  progress)
- **Package Import**: Allow for import of a previously existing package list to bring the system back to a saved package
  state. (Not yet started)
- **Multi Language Support**: Translation layer for supporting languages outside english
- **Offline Updates**: Similar functionality to pacman-offline script
- **Layout Customization**: Allow for customization of the individual user experience.

## Prerequisites

- **Arch Linux** (or an Arch-based distribution)
- **.NET 10.0 SDK** (for building)
- **libalpm** (provided by `pacman`)

#### Optional Prerequisites

- **Flatpak**: Can be installed via shelly inside settings by turning flatpak on.

## Installation

### Using PKGBUILD

Since Shelly is designed for Arch Linux, you can build and install it using the provided `PKGBUILD`:

```bash
git clone https://github.com/ZoeyErinBauer/Shelly-ALPM.git
cd Shelly-ALPM
makepkg -si
```

### Manual Build

You can also build the project manually using the .NET CLI:

```bash
dotnet publish Shelly.Gtk/Shelly.Gtk.csproj -c Release -o publish/shelly-ui
dotnet publish Shelly-CLI/Shelly-CLI.csproj -c Release -o publish/shelly-cli
dotnet publish Shelly-CLI/Shelly-CLI.csproj -c Release -o publish/shelly-notifications
```

alternatively, you can run

```bash
sudo ./local-install.sh
```

This will build and perform the functions of install.sh

The binary will be located in the `/opt/shelly` directory.

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

## License

This project is licensed under the GPL-3.0 License – see the [LICENSE](LICENSE) file for details.


