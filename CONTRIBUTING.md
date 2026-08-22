# Contributing to Shelly

Thank you for your interest in contributing to Shelly! This guide explains the project structure and how the components
interact.

## Project Structure

Shelly is organized into several interconnected projects:

### Core Components

| Project                             | Description                                                                                           |
|-------------------------------------|-------------------------------------------------------------------------------------------------------|
| **Shelly.UI.GTK**                   | GTK UI Frontend                                                                                       |
| **Shelly.CLI.Zig**                  | Command-line interface for terminal-based package management                                          |
| **Shelly-Notifications**            | Application to handle tray services and notifications.                                                |
| **Shelly.Http**                     | Standalone HTTP client and compatibility TLS implementation                                           |
| **Shelly.PackageManager**           | Core libalpm/AUR/AppImage library and backend-neutral Flatpak facade                                  |
| **Shelly.Flatpak.Backend**          | Optional ABI-versioned shared library containing generated libflatpak bindings and native operations  |
| **Shelly.Utilities**                | Shared utility classes and extensions used across projects                                            |

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
            │    d-bus        │     (GTK)      │                  │            
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
                       │ Backend │ │  API   │  │ Backend │                     
                       └─────────┘ └────────┘  └─────────┘                                    
```

### Key Interactions

1. **Shelly-UI ↔ Shelly-CLI**: The UI launches the CLI via `sudo` with `--ui-mode` flag for privileged operations (
   install, remove, upgrade). The CLI outputs structured frames that the UI parses for progress updates.

2. **Shelly-CLI uses the PackageManager library for:
    - ALPM operation
    - AUR package management (
    - Flatpak operations
    - AppImage Operations
   
3. **Shelly-Notifications** uses the d-bus to communicate with the UI process, tray icon, and notifications.

4. **PackageManager → System**:
    - Directly interfaces with `libalpm` for native package operations
    - Calls AUR API for package searches and metadata
    - Lazily loads `/usr/lib/shelly/libshelly-flatpak-backend.so.1` for
      Flatpak operations; PackageManager itself does not link libflatpak

5. Shelly-UI should never directly interact with the PackageManager library. All operations should be performed via the
   CLI.

## Building the Project

```bash
# Exercise the optional-backend boundary, CLI, and core-only smoke tests
scripts/test-flatpak-separation.sh

# Build individual native projects
(cd Shelly.Flatpak.Backend && zig build)
(cd Shelly.Http && zig build)
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
(cd Shelly.Http && zig build test)
(cd Shelly.PackageManager && zig build test)
(cd Shelly.PackageManager && zig build flatpak-test)
(cd Shelly.Cli.Zig && zig build test)
```

## Flatpak backend contributions

All generated libflatpak declarations, GObject pointers, and native Flatpak
calls must remain under `Shelly.Flatpak.Backend`. Consumers use owned records
from `Shelly.PackageManager/src/flatpak/types.zig`; never expose a generated
binding type in a public PackageManager declaration.

Protocol schema 2 rejects unknown and duplicate fields. Add a new operation by
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
│   ├── po/ 
```

This folder contains the localization  files used by the application.

### Launcher entries

The app menu entry, its right-click actions and the notification service entry
are generated from the templates in `packaging/desktop/`. To translate them, copy
`packaging/desktop/po/shelly-desktop.pot` to `packaging/desktop/po/<lang>.po` and
fill it in. Use the plain language code (`ru`, not `ru_RU`) unless the country
really matters, so the translation also applies to `ru_UA`, `ru_BY` and so on.
The packaging picks up every po file in that folder automatically.

### Build and Test

1. Build the application
2. Verify that the application builds and starts correctly
3. Confirm that all UI elements are translated and that no unexpected fallback to English occurs

Once these steps are validated, please submit a pull request.
  
## Getting Help

If you have questions or need help, please open an issue on the GitHub repository or join or community https://fluxer.gg/hAxUFvJP
