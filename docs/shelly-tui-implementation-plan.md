# Shelly-TUI implementation tracker

This file is to be used for tracking and implementation of new Shelly-TUI changes. Entries should be concise and include links to source, commits, issues, or PRs so other maintainers can check findings and help with unresolved work.

## Compatibility target

- Target: the latest `development` commit, updated throughout implementation.
- Initial local checkpoint (2026-10-25):
  `27a699514db3ce3ffe27d871a4e8151de81eefc8`. Local `development` and
  `shelly-tui-development` both pointed here; remote freshness was not checked.
- Last complete compatibility audit: not performed.

A checkpoint records which source was inspected; it does not freeze scope or
prove compatibility. When CLI or package-manager changes affect the TUI, the affected commands/messages,
required work, and verification should be recorded below. The development commit
used for the final coverage audit should be recorded before release.

## Architecture and constraints

`Vaxis views → application state / operation control → CLI client → Shelly CLI / workflows`

- Development extends the existing Zig/Vaxis TUI in `Shelly.Tui`.
- The existing TUI is a simple prototype. Its structure does not constrain the
  target architecture; existing pieces may be retained, adapted, or replaced
  after assessment. Working read-only behavior provides a regression baseline.
- Views display state and emit user actions. Application state owns selection,
  pending questions, asynchronous results, and operation outcomes.
- The CLI client owns process communication independently of widgets. Shelly owns
  validation, package policy, dependency resolution, builds, and mutations.
- Initially, only one package-changing operation runs at a time, with review and
  execution in the same CLI process.
- Repeated questions and terminal authentication must be supported without
  collecting passwords inside the TUI. Handoffs must restore the terminal.
- Package identity, source, and scope must be preserved. Stale query results must
  be rejected, and unavailable sources must remain distinct from empty results.
- Outcome handling must distinguish success, decline, cancellation, failure, and
  unknown outcomes using messages and process status. Interrupted mutations require
  a refresh of actual state.
- The TUI must work without the GUI installed. Tray behavior remains undecided.
- Devario tooling is preferred. Real mutations require validation in disposable
  environments with supported libalpm and RLPM configurations. Terminal checks
  include keyboard use at 80×24 and resizing.

## Implementation plan

Status: **Not started**, **Investigating**, **Ready**, **In progress**, **Blocked**,
or **Verified**. Verified status requires linked evidence.

| ID | Task and completion condition | Status | Evidence / remaining work |
| --- | --- | --- | --- |
| TUI-01 | CLI capability inventory and existing TUI assessment, including the first native workflow's commands, messages, identities, and missing support. | Investigating | Manual findings and known issues recorded below; full inventory and contract review remain open. |
| TUI-02 | Independent CLI communication and authentication, with verification of streaming, repeated answers, malformed output, failures, cancellation, and terminal restoration. | Not started | Early authentication feasibility investigation required. |
| TUI-03 | Application state separated from views, with verified responsive search/details/refresh, stable selection, stale-result rejection, and source errors. | Not started | Initial scope: a small read-only journey. |
| TUI-04 | Complete native install/remove workflows with review, provider choices, and accurate outcomes on both native engines. | Not started | Requires communication and authentication evidence. |
| TUI-05 | Expanded native actions, AUR, AppImage, and Flatpak workflows with preserved source-specific identity and settings. | Not started | Each scoped workflow requires separate tracking and success/failure evidence. |
| TUI-06 | Complete maintenance/settings/advanced coverage and release checks against an agreed development commit. | Not started | Coverage includes packaging, CLI compatibility, SSH/tmux, terminal recovery, and child cleanup. |

The order permits small end-to-end slices. Reusable components are added as workflows need them. 

Listing commands become browsing/detail views. Advanced actions need discoverable access. 

Exclusions and deferrals require explicit records and do not count as completed coverage.

### Current task: TUI-01

1. A trace of startup → native package loading → selection → details, covering
   data ownership, cleanup, background work, and delivery of results to the UI.
2. An inventory of command variants and meaningful options from the CLI catalog,
   with an execution owner and proposed terminal interaction for each capability.
3. Separate assessments of query output and interactive messages, identifying
   missing CLI support and required authentication experiments before mutation work.

Starting points:

- [TUI startup](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Tui/src/main.zig)
- [Current model, event handling, and rendering](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Tui/src/model.zig)
- [Current CLI client](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Tui/src/shelly_cli.zig)
- [CLI command catalog](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Cli.Zig/src/cli/catalog.zig)
- [CLI interactive output](/home/vinnyqf/RiderProjects/Shelly-ALPM/Shelly.Cli.Zig/src/output/ui_operation.zig)
- [Native backend guide](/home/vinnyqf/RiderProjects/Shelly-ALPM/docs/native-package-backends.md)

Initial source observations at the checkpoint above (not runtime verification):

- `ShellyCli.runInner` collects process output; `install_package` uses
  `--no-confirm`. Interactive communication still needs assessment.
- `Model` handles password input and elevated installation alongside UI behavior.
  This needs to move toward the authentication boundary described above.

## Capability and verification register

| Capability ID / user action | Command / options and source evidence | Execution owner / TUI interaction | Task / dependencies | Verification / gaps |
| --- | --- | --- | --- | --- |
| NATIVE-001 / Browse and list packages | `ShellyCli.get_packages` (`-Ssv`) and `get_installed_packages` (`-Ls`); client adds `--ui-mode`. | CLI queries; model loads and displays packages. | TUI-01, TUI-03 | Working in maintainer manual exploration when launched from `Shelly.Tui`; broader source/engine coverage remains unverified. |
| NATIVE-002 / Select a package and inspect metadata | `Model` selection and details rendering in `model.zig`. | TUI selection and metadata view. | TUI-01, TUI-03 | Correct selection and associated metadata display reported by maintainer; field completeness has not been independently audited. |

### Manual findings and known issues

These findings come from maintainer exploration reported on 2026-10-25, including an allocator trace and a screenshot of terminal output after a crash.

Browsing, listing, package selection, and metadata display work in a basic form.
The earlier apparent listing failure was resolved by launching from `Shelly.Tui`
instead of `Shelly.Tui/zig-out/bin`. Other workflows remain unverified; this is
not evidence of a complete interactive package-management workflow.

| ID | Finding / evidence | Status and next investigation |
| --- | --- | --- |
| TUI-B01 | Debug CLI discovery depends on the working directory. `ShellyCli.runInner` uses `../Shelly.Cli.Zig/zig-out/bin/shelly`; launching from the binary directory caused the apparent listing failure. | Open. Executable discovery and error reporting need assessment. |
| TUI-B02 | DebugAllocator reported a leaked `LoadState` allocation from `Model.init` at `model.zig:127`. Source inspection shows no corresponding destruction on successful initialization. | Confirmed ownership gap; unfixed. Loader lifetime and unconsumed result ownership need definition before cleanup is added, because the worker is detached and may still access the allocation. |
| TUI-B03 | Tabbing out of the unimplemented Updates/Upgrade page reportedly crashes the application. | Reported trigger; cause unconfirmed. Exact key sequence, panic message, and stack trace are still needed. |
| TUI-B04 | After a crash, mouse movement produces visible terminal sequences and the terminal remains disrupted. | Observed symptom, consistent with mouse reporting remaining enabled. Crash cleanup and terminal restoration need investigation; the relationship to TUI-B03 is not yet proven. |

No fixes have been verified for these issues. The immediate investigation remains the `LoadState` lifetime (TUI-B02), with navigation and terminal recovery tracked separately. Existing browsing and details behavior should remain testable during architectural changes.

## Changes and compatibility reviews

| Date | Commit / PR inspected or implemented | Affected tasks / capabilities | Change / required follow-up | Verification and environment |
| --- | --- | --- | --- | --- |
| 2026-10-25 | `27a699514db3ce3ffe27d871a4e8151de81eefc8` | TUI-01 | Established initial local checkpoint and tracker. | Read-only source inspection; no runtime tests or complete compatibility audit. |
| 2026-10-25 | Source recheck: `020f9db84a9735b546dc0bfb6ff717880f7486ba`; tested binary revision unrecorded. | TUI-01, NATIVE-001–002, TUI-B01–04 | Recorded working read-only behavior, prototype reuse approach, and unresolved loading-path, memory, navigation, and terminal issues. | Maintainer manual exploration and supplied diagnostics; source inspection only during documentation update. No fixes or full compatibility audit. |

## Decisions, questions, and help wanted

| Item | Status / owner | Next action or decision evidence |
| --- | --- | --- |
| Development is the moving compatibility target. | Decided | Relevant CLI/package-manager changes require review throughout implementation. |
| Existing implementation is a prototype with selective reuse. | Decided | Basic browsing and details work; substantial architectural changes are expected. Reuse requires assessment rather than preservation of the current structure. |
| Terminal authentication and interactive protocol feasibility. | Open / unassigned | Current CLI behavior needs tracing before a disposable terminal experiment is defined. |
| Tray support without a GUI dependency. | Open / unassigned | Decision pending on exposing existing notification support or omitting tray behavior. |
