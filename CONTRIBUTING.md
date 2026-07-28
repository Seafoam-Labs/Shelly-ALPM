# Contributing to Shelly

Thank you for your interest in contributing to Shelly! This guide explains the project structure and how the components
interact.

## Project Structure

Shelly is organized into several interconnected projects:

### Core Components

| Project                  | Description                                                                                                    |
|--------------------------|----------------------------------------------------------------------------------------------------------------|
| **Shelly-UI**            | The main Avalonia-based desktop application providing a graphical interface for package management             |
| **Shelly-CLI**           | Command-line interface for terminal-based package management, also used by Shelly-UI for privileged operations |
| **Shelly-Notifications** | Application to handle tray services and notifications. Communicates with Shelly-UI.                            |
| **Shelly.PackageManager** | Core libalpm/AUR/AppImage library and backend-neutral Flatpak facade                                          |
| **Shelly.Flatpak.Backend** | Optional ABI-versioned shared library containing generated libflatpak bindings and native operations          |
| **Shelly.Utilities**     | Shared utility classes and extensions used across projects                                                     |

### Test Projects

| Project                  | Description                                               |
|--------------------------|-----------------------------------------------------------|
| **PackageManager.Tests** | Tests for ALPM bindings, AUR functionality, and utilities |
| **Shelly-UI.Tests**      | Tests for UI services, ViewModels, and Views              |

## How Components Interact

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                  USER                                       │
└──────────┬──────────────────────────┬────────────────────────────┬──────────┘
           │                          │                            │           
           ▼                          │                            ▼           
    ┌──────────────┐                  │                    ┌────────────────┐  
    │              │ ─────────────────┼─────────────────►  │                │  
    │ Shelly-Notif │                  ▼                    │   Shelly-CLI   │  
    │              │  ◄─┐     ┌────────────────┐   sudo    │   (Terminal)   │  
    │              │    │d-bus│                │ ────────► │                │  
    └───────┬──────┘    └─────┤   Shelly-UI    │           └──────┬─────────┘  
            │    d-bus        │   (Avalonia)   │                  │            
            └───────────────► │                │                  │            
                              └────────────────┘                  │            
                                                                  │                            
                                       ┌──────────────────────────┘                                                                                                                          
                                       ▼                                       
                             ┌───────────────────┐                                                              
                             │   PackageManager  │                             
                             │      (core)       │                                                                         
                             └─────────┬─────────┘                                                                      
                            ┌──────────┼───────────┐                           
                            │          │           │                           
                            ▼          ▼           ▼                           
                       ┌─────────┐ ┌────────┐  ┌─────────┐                     
                       │ libalpm │ │  AUR   │  │ flatpak │                     
                       │ (arch)  │ │  API   │  │  .so    │                     
                       └─────────┘ └────────┘  └─────────┘                                    
```

### Key Interactions

1. **Shelly-UI ↔ Shelly-CLI**: The UI launches the CLI via `sudo` with `--ui-mode` flag for privileged operations (
   install, remove, upgrade). The CLI outputs structured messages that the UI parses for progress updates.

2. **Shelly-CLI uses the PackageManager library for:
    - ALPM operations (via `AlpmManager`)
    - AUR package management (via `AurManager`)
    - Flatpak operations (via `FlatpakManager`)
   
3. **Shelly-Notifications** uses the d-bus to communicate with the UI process, tray icon, and notifications.
   -Key interactions are: Start and stop shelly-ui
   -Use CLI to get non-sudo updates

4. **PackageManager → System**:
    - Directly interfaces with `libalpm` for native package operations
    - Calls AUR API for package searches and metadata
    - Lazily loads `/usr/lib/shelly/libshelly-flatpak-backend.so.1` for
      Flatpak operations; PackageManager itself does not link libflatpak

5. Shelly-UI should never directly interact with the PackageManager library. All operations should be performed via the
   CLI. Shelly-notifications can interact with the PackageManager library if necessary.

## Directory Structure

```
Shelly-ALPM/
├── PackageManager/           # Core library
│   ├── Alpm/                 # libalpm bindings and management
│   ├── Aur/                  # AUR integration
│   │   └── Models/           # AUR data models
│   ├── Flatpak/              # Flatpak management
│   ├── Models/               # Shared data models
│   ├── User/                 # User-related functionality
│   ├── Utilities/            # Helper utilities
├── Shelly-CLI/               # Command-line interface
│   └── Commands/             # CLI command implementations
│   │   ├── Aur/              # Aur commands
│   │   ├── Flatpak/          # Flatpak commands
│   │   ├── Keyring/          # Keyring commands
│   │   ├── Standard/         # Standard alpm commands
│   │   └── Utility/          # Utility commands
│   ├── Utility/              # CLI Utility classes
│   └── Writers/              # CLI Output writer classes
├── Shelly-Notifications/     # Tray application
│   ├── Constants/            # Constants 
│   ├── DbusHandlers/         # Handlers for d-bus messages
│   ├── DBusXml/              # D-bus XML files
│   ├── Models/               # Data models
│   └──  Services/            # Application Services
├── Shelly-UI/                # Desktop application
│   ├── Assets/               # Images, icons, resources
│   ├── BaseClasses/          # Base ViewModels and classes
│   ├── Converters/           # XAML value converters
│   ├── CustomControls/       # Custom Avalonia controls
│   ├── Enums/                # Enumeration types
│   ├── Messages/             # Messages for UI Message bus
│   ├── Models/               # UI-specific models
│   ├── Services/             # Application services
│   ├── ViewModels/           # MVVM ViewModels
│   │   ├── AUR/              # AUR-specific ViewModels
│   │   └── Flatpak/          # Flatpak-specific ViewModels
│   └── Views/                # XAML views
│       ├── AUR/              # AUR-specific ViewModels
│       └── Flatpak/          # Flatpak-specific views
├── Shelly.Utilities/         # Shared utilities
│   ├── Extensions/           # Extension methods
│   └── System/               # System utilities
├── Shelly.Protocol/          # Communication protocol
├── Shelly.Service/           # Privileged service
└── wiki/                     # Documentation images
```

## Building the Project

```bash
# Exercise the optional-backend boundary, CLI, and core-only smoke tests
scripts/test-flatpak-separation.sh

# Build individual native projects
(cd Shelly.Flatpak.Backend && zig build)
(cd Shelly.PackageManager && zig build)
(cd Shelly.Cli.Zig && zig build)
(cd Shelly.Ui.Gtk && zig build)
```

## Running Tests

```bash
(cd Shelly.Flatpak.Backend && zig build test)
(cd Shelly.Flatpak.Backend && zig build abi-test)
(cd Shelly.Flatpak.Backend && zig build parity-test)
(cd Shelly.Flatpak.Backend && zig build integration-test)
(cd Shelly.PackageManager && zig build test)
(cd Shelly.PackageManager && zig build flatpak-test)
(cd Shelly.Cli.Zig && zig build test)
```

## Flatpak backend contributions

All generated libflatpak declarations, GObject pointers, and native Flatpak
calls must remain under `Shelly.Flatpak.Backend`. Consumers use owned records
from `Shelly.PackageManager/src/flatpak/types.zig`; never expose a generated
binding type in a public PackageManager declaration.

Protocol schema 1 rejects unknown and duplicate fields. Add a new operation by
updating the wire inventory, backend dispatch, PackageManager facade, fake
backend coverage, and parity tests together. Run
`scripts/check-flatpak-separation.sh` before submitting a change.

An incompatible C table change requires an ABI version and SONAME bump. An
incompatible JSON change requires a schema bump. Update the exact
base/backend package dependency in the same release. The complete ownership,
threading, discovery, and bump procedure is in
[`docs/flatpak-backend-abi.md`](docs/flatpak-backend-abi.md).

## Development Guidelines

1. **Code Style**: Follow the existing code style in each project
2. **Testing**: Add tests for new functionality in the appropriate test project
3. **Documentation**: Update relevant documentation when adding features
4. **Commits**: Use clear, descriptive commit messages

## Localization Guidelines

If you're interested in helping localize Shelly into your language, please follow the steps below

### Locate the resource folder:

Navigate to:

```
├── Shelly-UI/               
│   ├── Assets/ 
```

This folder contains the localization resource files used by the application.

**Warning:** The file Resources.resx contains the default (English) language and acts as the fallback language.

- Do not rename this file.
- Do not remove it.
- Do not translate it to another language.

All new cultures must be created as separate `.resx` files.

### Create a new culture file

Create a new `.resx` file using the correct ISO culture naming convention:

```

Resources.<culture-code>.resx

```

Examples:

```

Resources.fr-FR.resx -> French (France)
Resources.es-ES.resx -> Spanish (Spain)
Resources.de-DE.resx -> German (Germany)

```

Make sure the culture code follows the standard .NET naming convention.

If you are unsure which culture code to use, refer to Microsoft’s documentation:
https://learn.microsoft.com/en-us/dotnet/api/system.globalization.culturetypes

### Copy existing keys

Using `Resources.resx` as your reference file:
- Copy all keys over to another document
- Translate the values within each key to the appropriate language

You may use:

- A regular text editor

- An IDE such as JetBrains Rider or Visual Studio

If editing manually, a typical entry looks like this:

``` xml

    <data name="Home" xml:space="preserve">
        <value>Home</value>
    </data>

```

Only modify the text inside `<value>`:

``` xml

    <data name="Home" xml:space="preserve">
        <value>Translation</value>
    </data>

```

Do not change:

- The name attribute

- The XML structure

- The xml:space attribute

### Build and Test

1. Build the application
2. Verify that the application builds and starts correctly
3. Confirm that all UI elements are translated and that no unexpected fallback to English occurs

Once these steps are validated, please submit a pull request.
  
## Getting Help

If you have questions or need help, please open an issue on the GitHub repository or reach out on Discord to zoeybear.
