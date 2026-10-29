# Shelly-TUI implementation tracker

This file tracks the implementation plan, findings, and changes for Shelly-TUI. Entries should be brief and include source or commit references where useful. 

## Compatibility target

The target is the latest `development`. CLI/package-manager changes affecting the TUI require review throughout implementation.

- Development checked remotely on 2026-10-25: `27a699514db3ce3ffe27d871a4e8151de81eefc8`.
- Source assessment: `613b58e544b5b8a490be4d6ee51188e67f40420e`; code matches that development commit. Branch differences were documentation only.
- Full runtime compatibility audit: pending.

## Build toolchain

- Zig 0.17.0 or newer; from `Shelly.Tui`: `zig build run`.
- Vaxis is pinned to `b24be454926b012316cb44d9f0e95da45d6bc3d9`, the latest upstream main commit checked on 2026-10-28. Pins are updated deliberately.
- LLVM/LLD is used for linking. The TUI communicates through the CLI and does not link the package-manager backend.
- Zig 0.16 support and compiler-specific package directories have been dropped.

## Architecture

`Vaxis views → application state → CLI client → Shelly CLI / workflows`

- The existing TUI is a simple prototype with selective reuse; substantial changes are expected.
- Views display information. State owns selection, questions, results, and operation lifetimes. The client handles processes and messages. Shelly owns package operations.
- Initially, one package-changing operation runs at a time, with review and execution in the same process.
- Authentication remains in the TUI password modal. AUR operations validate with `sudo -S -v`, then use `sudo -n` with protocol stdin kept open. The TUI must work without the GUI installed.
- Package identity/source/scope and accurate outcomes must survive refresh and interruption.
- Devario tooling is preferred. Real package mutations require disposable environments and verification with both native engines.

### Client and operation refactor

| Component | Responsibility |
| --- | --- |
| `shelly_cli.zig` | Queries and short commands: arguments, execution, decoded data, and useful errors. Existing GTK methods provide a reference for coverage. |
| `shelly_operation.zig` or equivalent | Interactive transactions: streaming output, questions/answers, progress, cancellation, process cleanup, and outcomes, with a separate authentication boundary. |
| Application state / `Model` | Coordinate actions, selection, pending questions, and results; views render state. Subprocess handling moves into the client layer. |

Implementation starts with the existing query client's foundation, then one native transaction and the corresponding `Model` refactor. Full query coverage is not a prerequisite for that transaction. Further workflows and view extraction follow incrementally, using both GTK client and operation implementations as references.

## Implementation plan

“Documented” means source assessment is complete, not runtime verification.

| Step | Scope | Status |
| --- | --- | --- |
| TUI-01 | Existing implementation, CLI inventory, ownership, first native workflow, and gaps. | Documented |
| TUI-02 | Independent CLI communication, repeated questions, authentication, cancellation, and terminal recovery. | In progress: streaming and repeated AUR questions/answers implemented; live authentication, cancellation, and recovery checks remain. |
| TUI-03 | State/view separation, responsive queries, stable selection, and refresh. | Not started |
| TUI-04 | Reviewed native install/remove with accurate outcomes on both engines. | Not started |
| TUI-05 | Remaining native actions, AUR, AppImage, and Flatpak. | In progress: AUR install/upgrade review wired; live verification and remaining sources pending. |
| TUI-06 | Maintenance/settings/advanced coverage, packaging, and release checks. | In progress: persisted TUI source settings; remaining settings, maintenance, and release checks pending. |

## TUI-01 findings

| Area | Finding |
| --- | --- |
| Working behavior | Browsing, listing, selection, and metadata display work in maintainer testing. Other workflows remain unverified. |
| Read-only flow | Startup launches a background loader → CLI queries available/installed packages → decoded data reaches the UI through polling → filtering and details use the loaded array. |
| Ownership | `Model.parsed` owns package data; lists and overlays borrow pointers. Operation now owns and joins the mutation worker; detached AUR worker cleanup remains open. |
| Reuse | Vaxis setup, lists, formatting, data models, and framing can be adapted. State, process lifecycle, and authentication need restructuring. |
| CLI scope | Compiled catalog contains 62 variants, 191 command-specific options, and 11 global options. It covers native/AUR/AppImage/Flatpak, builds, settings, repositories, keyrings, backup, and maintenance. The catalog remains the detailed inventory authority. |
| Authentication | Password modal retained. Native operations keep the existing flow; AUR install/upgrade separates password validation from the protocol process. Policies disabling sudo credential reuse fail visibly; live checks remain. |
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
- [CLI client](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Tui/src/services/shelly_cli.zig)
- [Operation protocol and install lifecycle](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Tui/src/services/shelly_operation.zig)
- [PKGBUILD preview and operation review](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Tui/src/views/pkgbuild_view.zig)
- [CLI catalog](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Cli.Zig/src/cli/catalog.zig)
- [CLI questions and outcomes](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Cli.Zig/src/output/ui_operation.zig)
- [CLI wire formats](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Cli.Zig/src/output/config.zig)
- [Native backend guide](/home/vinnyqf/RiderProjects/Shelly-ALPM/docs/native-package-backends.md)

## Known issues and follow-up

| ID | Finding | Remaining work |
| --- | --- | --- |
| TUI-B01 | Debug CLI path depends on the working directory. Listing works when launched from `Shelly.Tui`. | Reliable executable discovery and errors. |
| TUI-B02 | Fixed in `3b210700`: loader joined before cleanup, result ownership transferred explicitly, and temporary/unconsumed results freed. | Maintainer exit test passed with no allocator warning. Exit during loading and query-failure cleanup still need separate verification. Shutdown waits for the loader. |
| TUI-B03 | Fixed in `3245dc70`: Updates now focuses the root instead of leaving focus on a hidden search field. | Regression test and build passed; maintainer confirmed tab switching works. |
| TUI-B04 | Partially addressed by `3245dc70`: the fixed tab-switching crash no longer triggers the broken terminal state. | Terminal restoration after other crashes remains unverified. |
| TUI-B05 | Corrected in `4b84daae`: detail query includes `--detail`; shared decoding classifies frames, detects trailing errors, and handles the existing empty-native-search message. | Decoder tests passed; live detail/empty-query verification pending. |
| TUI-B06 | Corrected remote-list ordering and removed ignored remote/branch parameters in `4b84daae`. Native selection remains name-based; Flatpak lookup searches by ID. | Exact identity/scope handling remains open. |
| TUI-B07 | Progress is streamed. AUR install/upgrade keeps stdin open and requires answers, including repeated PKGBUILD reviews. Native operations still use `--no-confirm`. | Live AUR review/authentication checks; native review, cancellation, and recovery remain open. |

## Changes and verification

| Date | Checkpoint | Result |
| --- | --- | --- |
| 2026-10-25 | `27a69951` / `020f9db8` | Initial tracker and maintainer findings: working read-only behavior, leak, navigation crash, and terminal disruption. Tested binary revision unrecorded. |
| 2026-10-25 | `613b58e5` | Step 1 source assessment and compiled CLI inventory completed with Zig 0.16.0; remote development checked. No new TUI runtime tests or package operations. |
| 2026-10-26 | `3b210700` | TUI-B02 loader cleanup fixed. Maintainer reported successful exit; captured stderr contained only Vaxis debug messages. Early-exit and failure-path checks remain unconfirmed. |
| 2026-10-26 | `4b84daae` | Fetching methods expanded toward GTK parity: native search/lookup, installed AUR, Flatpak search, AppImage lists/updates, and PKGBUILD previews/scans. Added models, hidden-query options, and decoding corrections. Three decoder tests and AppImage/PKGBUILD model tests passed; build passed with `-Dlibalpm=false`. Maintainer confirmed native and AUR browsing still work. Other query integration checks and full data-model parity remain pending. |
| 2026-10-27 | `3b86cc39` / `8b395946` / `a8e8fc46` | Added protocol codecs/builders and moved install execution, worker ownership, and cleanup into `InstallOperation`. Model uses start/poll/deinit and renders results. Build and six operation tests passed; maintainer confirmed installation works after migration. Closing during installation waits for completion; live shutdown remains unverified. |
| 2026-10-27 | `3245dc70` | Fixed Updates tab focus crash; regression test, build, and maintainer navigation check passed. |

## Next slice

- Verify AUR install and `A: upgrade AUR` in a disposable environment: source review, repeated revisions, provider choices, decline, and authorization failure.
- Browsing previews remain separate from operation approval. Operation reviews use the CLI's exact source, findings, attachments, and question ID.
- Fake-process checks cover install/upgrade, repeated questions, stale answers, decline, authorization failure, missing completion, heavy stderr, and shutdown during review. Live mutations and sudo policies remain unverified.
- Native transaction review, cancellation, and terminal recovery remain open.

### Installed package browsing (2026-10-29)

- Ctrl+L toggles installed-only browsing on both package pages. Text filters remain available; Enter opens details and existing removal actions.
- System browsing filters installed flags. AUR browsing uses `list aur`, independently of remote search; completed AUR operations refresh the active list.
- AUR workers are joined and unconsumed results freed on exit. Zig 0.17 build/tests and focused filtering/selection tests pass; AUR install/removal were user-validated; live installed-list checks remain open.

### Optional Flatpak tab (2026-10-29)

- Initial implementation gated Flatpak visibility on a successful `list flatpak remote --ui-mode`. Saved source preferences now control visibility; backend readiness is handled separately (see Settings below).
- Navigation, shortcuts, and mouse selection share the visible-tab list. The backend probe now runs independently of native loading, only for enabled Flatpak support, and can be retried.
- Tests cover hidden/visible navigation, rendering, empty remotes, backend errors, and independent native loading failure. Live backend-present/absent checks remain open.
- Availability-gate build/test and six focused tests pass. The stale remote-info fixture was corrected during browsing implementation below.

### Flatpak browsing (2026-10-29)

- Configured-remote catalog browsing, Ctrl+L installed applications/runtimes, local filtering, Enter details, and Ctrl+R refresh. Installed identity retains scope, kind, architecture, branch, remote, and refs; refresh preserves selection by identity.
- Queries run in joined workers. Errors and empty lists remain distinct; details are read-only. Catalogs use existing AppStream metadata; installation status and permissions are not inferred.
- Zig 0.17 build/test and 12 focused tests pass, including scoped duplicates, refresh ownership, cleanup, rendering at 80×24/40×12, and wire decoding. Live CLI queries returned 3,369 catalog entries and 43 installed references; interactive browsing verification remains open.

### Flatpak operations (2026-10-29)

- Catalog details: I selects a remote/scope, then confirms installation. Installed details: R requests removal while keeping configuration and unused dependencies. Updates: F upgrades system and user Flatpaks.
- Operations stream progress and questions through the existing review UI, require completion messages, and refresh Flatpak/update state afterward. System install/removal uses sudo authentication; user operations and upgrades run as the invoking user. System upgrades may require a Flatpak authorization agent.
- Flatpak removal delegates ID/name resolution to the CLI, as GTK does. The TUI-only ambiguity/identity guard was removed; exact scope/ref targeting remains a CLI/backend gap. No CLI changes are included.
- After guard removal, Zig 0.17 build/test and 33 focused tests pass. Earlier fake-process coverage remains recorded; guard-specific rejection tests were removed. Flatpak flows were subsequently user-validated.

### Combined upgrade (2026-10-29)

- G on Updates runs `upgrade all --no-appimage`, with `--no-flatpak` when the optional backend is unavailable. U/A/F remain source-specific. The full action synchronizes again even when the cached check reports no updates.
- One authenticated CLI coordinator retains interactive transaction/provider/PKGBUILD review and streams progress. Nested source completion cannot stand in for coordinator completion. Failures may follow completed source changes; native, AUR, Flatpak, and update state are refreshed as applicable.
- Zig 0.17 build/test and 37 focused tests pass. Six fake-process scenarios cover combined success, missing Flatpak, partial failure, missing outer completion, decline, and authentication failure, including inherited child stdin/stdout. No real combined upgrade was run.
- AppImage operations remain deferred until after UI/UX work. Existing AppImage update rows are informational only.

### Settings and startup source visibility (2026-10-29)

- Settings saves independent TUI preferences to `$XDG_CONFIG_HOME/shelly/tui-settings.json` (fallback: `~/.config`). AUR and Flatpak default off; system packages remain enabled. Arrow keys select, Enter/Space toggles and saves, R reloads.
- Saved preferences control tabs from the first frame, source-specific update queries, and combined-upgrade exclusions. Enabled Flatpak remains visible while its independent backend probe runs or reports an error. Disabled-source and stale update results are discarded.
- Saves are atomic, preserve unknown keys, and leave invalid files intact. Failed saves do not apply unsaved preferences. GTK settings and shared CLI configuration are unchanged; shared CLI option editing/backend installation remain separate work.
- Zig 0.17 build/test and 43 focused tests pass. Four fake-CLI cases verify enabled-source query selection. An isolated PTY smoke verified immediate saved tabs, keyboard saving, unknown-key preservation, and clean exit without touching real preferences.
