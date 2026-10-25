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
| TUI-01 | CLI capability inventory and existing TUI assessment, including the first native workflow's commands, messages, identities, and missing support. | Investigating | Initial source observations below; full inventory and contract review remain open. |
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
| To inventory | — | — | TUI-01 | No complete coverage claim yet. |

## Changes and compatibility reviews

| Date | Commit / PR inspected or implemented | Affected tasks / capabilities | Change / required follow-up | Verification and environment |
| --- | --- | --- | --- | --- |
| 2026-10-25 | `27a699514db3ce3ffe27d871a4e8151de81eefc8` | TUI-01 | Established initial local checkpoint and tracker. | Read-only source inspection; no runtime tests or complete compatibility audit. |

## Decisions, questions, and help wanted

| Item | Status / owner | Next action or decision evidence |
| --- | --- | --- |
| Development is the moving compatibility target. | Decided | Relevant CLI/package-manager changes require review throughout implementation. |
| Terminal authentication and interactive protocol feasibility. | Open / unassigned | Current CLI behavior needs tracing before a disposable terminal experiment is defined. |
| Tray support without a GUI dependency. | Open / unassigned | Decision pending on exposing existing notification support or omitting tray behavior. |
