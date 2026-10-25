# Shelly-TUI implementation tracker

This file tracks the implementation plan, findings, and changes for Shelly-TUI. Entries should be brief and include source or commit references where useful. 

## Compatibility target

The target is the latest `development`. CLI/package-manager changes affecting the TUI require review throughout implementation.

- Development checked remotely on 2026-10-25: `27a699514db3ce3ffe27d871a4e8151de81eefc8`.
- Source assessment: `613b58e544b5b8a490be4d6ee51188e67f40420e`; code matches that development commit. Branch differences were documentation only.
- Full runtime compatibility audit: pending.

## Architecture

`Vaxis views → application state → CLI client → Shelly CLI / workflows`

- The existing TUI is a simple prototype with selective reuse; substantial changes are expected.
- Views display information. State owns selection, questions, results, and operation lifetimes. The client handles processes and messages. Shelly owns package operations.
- Initially, one package-changing operation runs at a time, with review and execution in the same process.
- Authentication will move out of the password modal. The TUI must work without the GUI installed.
- Package identity/source/scope and accurate outcomes must survive refresh and interruption.
- Devario tooling is preferred. Real package mutations require disposable environments and verification with both native engines.

## Implementation plan

“Documented” means source assessment is complete, not runtime verification.

| Step | Scope | Status |
| --- | --- | --- |
| TUI-01 | Existing implementation, CLI inventory, ownership, first native workflow, and gaps. | Documented |
| TUI-02 | Independent CLI communication, repeated questions, authentication, cancellation, and terminal recovery. | Not started |
| TUI-03 | State/view separation, responsive queries, stable selection, and refresh. | Not started |
| TUI-04 | Reviewed native install/remove with accurate outcomes on both engines. | Not started |
| TUI-05 | Remaining native actions, AUR, AppImage, and Flatpak. | Not started |
| TUI-06 | Maintenance/settings/advanced coverage, packaging, and release checks. | Not started |

## TUI-01 findings

| Area | Finding |
| --- | --- |
| Working behavior | Browsing, listing, selection, and metadata display work in maintainer testing. Other workflows remain unverified. |
| Read-only flow | Startup launches a background loader → CLI queries available/installed packages → decoded data reaches the UI through polling → filtering and details use the loaded array. |
| Ownership | `Model.parsed` owns package data; lists and overlays borrow pointers. Detached workers and result cleanup need explicit lifetimes. |
| Reuse | Vaxis setup, lists, formatting, data models, and framing can be adapted. State, process lifecycle, and authentication need restructuring. |
| CLI scope | Compiled catalog contains 62 variants, 191 command-specific options, and 11 global options. It covers native/AUR/AppImage/Flatpak, builds, settings, repositories, keyrings, backup, and maintenance. The catalog remains the detailed inventory authority. |
| Authentication | Package details → `i` opens a password modal → `sudo -S` runs install with `--no-confirm --ui-mode`. Implemented in source; not runtime-verified. Replacement belongs to TUI-02. |
| Protocol | UI mode emits Base64 JSON frames between `[JSON]` and `[/JSON]`. Questions use string `QuestionId` values; answers must match the ID and kind. |
| Outcomes | Install can emit `TransactionCancelled` and exit zero. Exit status alone cannot establish success; removal has different cancellation reporting. |
| Shared services | Recommendations, Atoll browsing, and notification settings have GUI-side services needing reusable interfaces. Tray and graphical-content equivalents remain undecided. |

### First native workflow

All commands below use `--ui-mode`; mutations require authorization and input kept open for answers.

| Action | CLI arguments |
| --- | --- |
| Available packages | `search standard --available` (`-Ssv`) |
| Installed packages | `list standard` (`-Ls`) |
| Exact details | `search standard <name> --detail` |
| Install | `install standard <repository/name>` |
| Remove | `remove standard <name>`; dependency cascade defaults to enabled. |

The intended flow is browse → details → review/provider questions → execution → refresh. Repository/name and configuration context must be preserved. AppImage settings already have CLI commands; notification configuration still needs a shared boundary.

### Source references

- [Startup](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Tui/src/main.zig)
- [Model, workers, views, and authentication](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Tui/src/model.zig)
- [CLI client](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Tui/src/shelly_cli.zig)
- [CLI catalog](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Cli.Zig/src/cli/catalog.zig)
- [CLI questions and outcomes](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Cli.Zig/src/output/ui_operation.zig)
- [CLI wire formats](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Cli.Zig/src/output/config.zig)
- [Native backend guide](/home/vinnyqf/RiderProjects/Shelly-ALPM/docs/native-package-backends.md)

## Known issues and follow-up

| ID | Finding | Remaining work |
| --- | --- | --- |
| TUI-B01 | Debug CLI path depends on the working directory. Listing works when launched from `Shelly.Tui`. | Reliable executable discovery and errors. |
| TUI-B02 | Reported `LoadState` leak; source also leaves installed-query data and some failure/unconsumed results unreleased. | Define worker completion and result ownership before freeing shared state. |
| TUI-B03 | Tabbing out of the unimplemented Updates/Upgrade page reportedly crashes. | Exact reproduction and panic trace; cause unconfirmed. |
| TUI-B04 | Mouse-reporting sequences remain visible after a crash. | Terminal restoration; connection to B03 unconfirmed. |
| TUI-B05 | Unused detail-query helper omits `--detail`; working details render loaded metadata. Empty searches may emit only an info frame. | Correct query contracts and distinguish empty results from errors. |
| TUI-B06 | Native selection uses names; Flatpak helpers omit remote/branch information and one uses outdated command ordering. | Preserve exact identities and validate command arguments. |
| TUI-B07 | Install buffers output, closes stdin, and uses `--no-confirm`. | Streaming questions/answers, authentication, cancellation, and outcome tests in TUI-02. |

## Changes and verification

| Date | Checkpoint | Result |
| --- | --- | --- |
| 2026-10-25 | `27a69951` / `020f9db8` | Initial tracker and maintainer findings: working read-only behavior, leak, navigation crash, and terminal disruption. Tested binary revision unrecorded. |
| 2026-10-25 | `613b58e5` | Step 1 source assessment and compiled CLI inventory completed with Zig 0.16.0; remote development checked. No new TUI runtime tests or package operations. |

Further verification is required for authentication, repeated questions, decline/cancellation, source availability, refresh identity, both native engines, and terminal recovery. Exclusions or deferrals require explicit decisions.
