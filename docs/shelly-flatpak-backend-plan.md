# Shelly Flatpak Backend Separation Plan

## Objective

Move Shelly's libflatpak integration into a separate
`Shelly.Flatpak.Backend` project while preserving `Shelly.PackageManager` as the
only public integration point used by the CLI and other consumers.

The installed `shelly` executable must start and support every non-Flatpak
operation when Flatpak is not installed. Installing the optional backend must
enable Flatpak support without rebuilding Shelly.

The resulting dependency boundary is:

```text
shelly
  |
  v
Shelly.PackageManager
  |-- Flatpak facade and owned domain types
  |-- backend discovery, loading, and ABI validation
  |
  +-- dlopen("/usr/lib/shelly/libshelly-flatpak-backend.so.1")
            |
            v
      Shelly.Flatpak.Backend
            |
            +-- libflatpak.so.0
            +-- libostree and GLib dependencies
```

`Shelly.PackageManager` must not link the backend with a normal ELF link. Doing
so would propagate the backend's `DT_NEEDED` entries into `shelly` and make
libflatpak mandatory at process startup. PackageManager must load the backend
only when a Flatpak operation is requested.

## Success Criteria

The migration is complete when all of the following are true:

- `shelly` has no `DT_NEEDED` entry for `libflatpak.so.0` or
  `libostree-1.so.1`.
- `libshelly-flatpak-backend.so.1` has a `DT_NEEDED` entry for
  `libflatpak.so.0`.
- The CLI, TUI, and UI never load or call the backend directly.
- All Flatpak operations remain exposed through `Shelly.PackageManager`.
- Removing both Flatpak and the backend does not affect non-Flatpak commands.
- Installing the backend and Flatpak enables Flatpak support without rebuilding
  or replacing the main Shelly executable.
- No Flatpak, GLib, or GObject pointer crosses the backend ABI.
- A missing or incompatible backend produces a controlled, actionable error.
- Existing Flatpak status, progress, error, and cancellation behavior is
  preserved.

## Non-Goals

- Replacing libflatpak with the `flatpak` command-line program.
- Statically linking libflatpak into Shelly.
- Defining a public third-party plugin ecosystem in the first implementation.
- Maintaining ABI compatibility for arbitrary external backends.
- Exposing the backend directly to the CLI, GTK UI, TUI, or notification
  service.
- Changing the user-visible Flatpak command catalog except where an unavailable
  backend must be reported.

## Current State

`Shelly.PackageManager/build.zig` currently creates a module from the generated
Flatpak binding and attaches libflatpak to the exported `Zigalpm` module:

```zig
const flatpak_mod = b.createModule(.{
    .root_source_file = b.path("src/flatpak/flatpak.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});

mod.addImport("flatpak", flatpak_mod);
mod.linkSystemLibrary("flatpak", .{});
```

Because `Shelly.Cli.Zig` imports `Zigalpm`, the native dependency propagates
into the final `shelly` executable.

The current Flatpak implementation is under:

```text
Shelly.PackageManager/src/flatpak/
├── appstream_manager.zig
├── appstream_parser.zig
├── bindings.zig
├── events.zig
├── flatpak.zig
├── flatpak_include.h
├── manager.zig
└── remote_manager.zig
```

The public facade currently exposes several generated-binding types, including
`bindings.libflatpak.Scope`, and some CLI code directly releases GObjects and
formats native Flatpak references. Those native details must be removed from
the consumer-facing API before the implementation can cross a process-local
shared-library boundary safely.

## 1. Establish the Project Layout

Add a sibling Zig project:

```text
Shelly.Flatpak.Backend/
├── build.zig
├── build.zig.zon
└── src/
    ├── protocol.zig
    ├── root.zig
    ├── exports.zig
    ├── wire.zig
    └── flatpak/
        ├── appstream_manager.zig
        ├── appstream_parser.zig
        ├── bindings.zig
        ├── events.zig
        ├── flatpak.zig
        ├── flatpak_include.h
        ├── manager.zig
        └── remote_manager.zig
```

The project should expose two distinct build products:

1. `Shelly_Flatpak_Protocol`, a pure Zig module containing ABI constants,
   wire-format declarations, and data-only types. It must not import the
   generated C binding or link a system library.
2. `libshelly-flatpak-backend.so.1`, a shared library containing the native
   implementation and linked to libflatpak.

PackageManager may import `Shelly_Flatpak_Protocol`. It must not import an
implementation module or call `linkLibrary` for the backend.

The backend build must require a valid libflatpak pkg-config definition:

```zig
backend.root_module.linkSystemLibrary("flatpak", .{
    .use_pkg_config = .force,
});
```

The installed production location should be fixed and versioned:

```text
/usr/lib/shelly/libshelly-flatpak-backend.so.1
```

The SONAME major and the Shelly backend ABI version should change together when
an incompatible boundary change is made.

## 2. Define a Stable C ABI

Do not expose Zig structs, slices, error sets, allocators, `std.Io`, or function
calling conventions across the dynamic-library boundary. Zig does not promise
a stable ABI for those values.

Export a small C ABI. Prefer one lookup entry point that returns a versioned
function table:

```zig
pub const BackendApiV1 = extern struct {
    struct_size: usize,
    abi_version: u32,
    create: *const fn (*const HostApiV1, *?*anyopaque) callconv(.c) Status,
    destroy: *const fn (?*anyopaque) callconv(.c) void,
    execute: *const fn (
        ?*anyopaque,
        RequestBuffer,
        *ResponseBuffer,
    ) callconv(.c) Status,
    cancel: *const fn (?*anyopaque, u64) callconv(.c) Status,
    free_response: *const fn (?*anyopaque, ResponseBuffer) callconv(.c) void,
};

export fn shelly_flatpak_backend_get_api(
    requested_version: u32,
    host: *const HostApiV1,
    api: *BackendApiV1,
) callconv(.c) Status;
```

PackageManager then needs to resolve only
`shelly_flatpak_backend_get_api`. The returned table must contain a
`struct_size` field so fields can be appended compatibly in future ABI
revisions.

### Memory Ownership

Use explicit pointer-and-length buffers:

```zig
pub const RequestBuffer = extern struct {
    ptr: [*]const u8,
    len: usize,
};

pub const ResponseBuffer = extern struct {
    ptr: ?[*]u8,
    len: usize,
};
```

Ownership rules must be documented and tested:

- PackageManager owns request memory and keeps it valid until `execute`
  returns.
- The backend owns response memory.
- PackageManager copies or decodes the response and then calls
  `free_response`.
- Callback strings and payloads are borrowed only for the duration of the
  callback.
- Backend handles are opaque and may only be passed back to the backend
  instance that created them.
- No Flatpak, GLib, GObject, or XML parser pointer may appear in a response.

### Wire Format

Use versioned JSON for the first implementation. Its overhead is insignificant
relative to Flatpak filesystem and network operations, and it makes migration
failures inspectable.

Every request should contain:

```json
{
  "schema": 1,
  "operation_id": 42,
  "method": "list_installed",
  "arguments": {}
}
```

Every successful response should contain:

```json
{
  "schema": 1,
  "operation_id": 42,
  "result": {}
}
```

Every failed response should contain a stable error code and a display message:

```json
{
  "schema": 1,
  "operation_id": 42,
  "error": {
    "code": "flatpak.remote_not_found",
    "message": "The requested Flatpak remote was not found.",
    "native_code": null
  }
}
```

The protocol must reject unknown schema versions, missing required fields,
oversized messages, duplicate fields where the decoder permits detection, and
invalid enum values.

## 3. Define Backend-Neutral Domain Types

Create PackageManager-owned public types under:

```text
Shelly.PackageManager/src/flatpak/types.zig
```

At minimum, define owned representations for:

- `Scope`
- `RefKind`
- `InstalledApplication`
- `InstalledRef`
- `Remote`
- `RemoteRef`
- `RunningInstance`
- `UnusedDependency`
- `AppstreamIcon`
- `AppstreamImage`
- `AppstreamScreenshot`
- `AppstreamRelease`
- `AppstreamApp`
- `AppstreamCatalog`

For example:

```zig
pub const Scope = enum(u8) {
    system,
    user,
    unknown,
};

pub const InstalledRef = struct {
    id: []u8,
    name: []u8,
    arch: []u8,
    branch: []u8,
    reference: []u8,
    origin: []u8,
    version: []u8,
    installed_size: u64,
    scope: Scope,

    pub fn deinit(self: *InstalledRef, allocator: std.mem.Allocator) void {
        // Free all owned fields.
    }
};
```

These types should be the canonical public representations used by
PackageManager and the CLI. The backend should convert native Flatpak values
into equivalent wire values before returning.

Replace consumer references to:

```zig
Zigalpm.flatpak.bindings.libflatpak.Scope
```

with:

```zig
Zigalpm.flatpak.Scope
```

Replace the native object access in
`Shelly.Cli.Zig/src/commands/list_updates.zig` with owned `InstalledRef`
fields. The CLI must no longer call `g_object_unref`, access `.ptr`, or call a
binding helper such as `refToString`.

## 4. Inventory and Version the Operations

Assign a stable protocol method name to every public Flatpak operation before
moving implementation code.

The initial operation inventory is:

### Installation and Mutation

- `install`
- `install_ref_file`
- `install_bundle`
- `update_installed`
- `uninstall_installed`
- `repair_installed`
- `upgrade_all`
- `remove_unused`

### Inspection

- `list_installed`
- `find_installed`
- `list_updates`
- `list_unused`
- `list_running`
- `search_remote_refs`
- `get_remote_ref`

### Execution

- `launch`
- `kill`

### Remotes

- `list_remotes`
- `add_remote`
- `remove_remote`
- `highest_priority_remote`
- `list_remote_refs`

### AppStream

- `update_all_appstreams`
- `update_remote_appstream`
- `get_remote_catalog`
- `get_all_remote_catalogs`
- `load_catalog`

Each method needs:

- Request type and field validation.
- Response type and ownership rules.
- Stable error-code mapping.
- Required user or system scope.
- Cancellation behavior.
- Progress and status event behavior.
- Tests for serialization and invalid input.

Do not use source-level Zig function names as the protocol contract. Protocol
names should remain stable if implementation functions are renamed.

## 5. Move the Native Implementation

Move the generated binding and all direct native calls into
`Shelly.Flatpak.Backend`.

The backend owns:

- Creation and release of Flatpak installations and references.
- GObject reference management.
- GLib error conversion and release.
- Transaction construction and execution.
- Flatpak cancellable objects.
- Native Flatpak callbacks.
- Conversion from native objects to wire objects.

The move should preserve history where practical. First copy behavior without
redesigning it, establish parity tests, and then simplify native wrappers after
the new boundary is working.

The backend must not depend on `Shelly.PackageManager`, because PackageManager
already depends on the backend protocol and a reverse dependency would create a
cycle. Backend events must be expressed through the host callback ABI rather
than importing `OperationContext`.

If the AppStream parser remains free of all native dependencies, it may remain
in PackageManager. In that variant, the backend should return catalog paths or
contents and PackageManager should parse them. Otherwise, move the parser into
the backend and return fully owned application records. Select one owner and
avoid maintaining two parsers.

## 6. Add the PackageManager Loader

Add:

```text
Shelly.PackageManager/src/flatpak/backend_loader.zig
Shelly.PackageManager/src/flatpak/client.zig
Shelly.PackageManager/src/flatpak/types.zig
Shelly.PackageManager/src/flatpak/errors.zig
```

`backend_loader.zig` should:

1. Open the backend only when the first Flatpak operation begins.
2. Resolve `shelly_flatpak_backend_get_api`.
3. Request the exact supported ABI version.
4. Validate the returned version, `struct_size`, and required function
   pointers.
5. Create the opaque backend handle with PackageManager host callbacks.
6. Keep the dynamic library open until all clients and active operations have
   released it.
7. Map discovery errors to `error.FlatpakBackendUnavailable`.
8. Map ABI errors to `error.FlatpakBackendIncompatible`.
9. Avoid retrying a known-incompatible library repeatedly during one process
   lifetime.

Use a mutex and explicit reference count if multiple managers can share a
process-wide loaded backend. Never call `close` while a backend operation,
response, or callback may still be active.

### Secure Discovery

Production builds must load the backend from a trusted, fixed absolute path.
This is particularly important because system-scoped Flatpak operations may
cause Shelly to run with elevated privileges.

Production discovery must not:

- Search the current working directory.
- Honor a user-controlled relative path.
- Load an arbitrary library found through `PATH`.
- Honor a backend override environment variable after privilege elevation.

A test or development-only build option may supply an alternate absolute path
for fake-backend tests. That option must not be enabled in release packages.

## 7. Preserve the PackageManager Facade

Keep the existing consumer-facing entry points where practical:

```zig
Zigalpm.FlatpakManager
Zigalpm.flatpak.RemoteManager
Zigalpm.flatpak.AppstreamManager
```

Change their internals to use `flatpak.client`. The CLI, GTK UI, TUI, and
notifications should not know whether the operation is implemented locally or
by a loaded backend.

The facade is responsible for:

- Encoding typed requests.
- Invoking the backend API.
- Decoding and validating responses.
- Allocating PackageManager-owned result values.
- Translating stable backend errors into Zig errors.
- Translating backend events into the existing operation lifecycle.
- Releasing backend response memory in every success and failure path.

Remove public access to the generated libflatpak binding from
`Shelly.PackageManager/src/root.zig`. Raw bindings should exist only inside the
backend project.

## 8. Bridge Events, Progress, and Cancellation

Define a host callback table passed to the backend during initialization:

```zig
pub const HostApiV1 = extern struct {
    struct_size: usize,
    abi_version: u32,
    user_data: ?*anyopaque,
    emit_event: *const fn (
        ?*anyopaque,
        EventBuffer,
    ) callconv(.c) void,
};
```

Backend events should contain:

- Protocol schema version.
- Operation identifier.
- Event kind.
- Stable event code.
- Display message.
- Optional progress percentage.
- Optional native error code.

PackageManager should translate them as follows:

- Backend status event to `Operation.reportStatus`.
- Backend progress event to `Operation.reportProgress`.
- Backend error event to `Operation.reportError`.
- Backend completion event to the existing completion state.

When an `OperationContext` cancellation is requested, PackageManager should
invoke the backend's `cancel` function for the corresponding operation ID. The
backend should then cancel its `GCancellable` or transaction and return the
stable cancellation error.

Callbacks may be delivered from a backend worker or Flatpak callback thread.
The ABI contract must document threading, and the PackageManager bridge must not
assume callbacks always occur on the caller thread.

## 9. Define Unavailable-Backend Behavior

Add a capability query through PackageManager:

```zig
pub fn backendStatus() BackendStatus;

pub const BackendStatus = union(enum) {
    available: BackendInfo,
    unavailable,
    incompatible: u32,
};
```

Recommended command behavior:

- A direct Flatpak command fails with a concise message explaining that
  `shelly-flatpak-backend` and Flatpak must be installed.
- An aggregate update or upgrade operation marks Flatpak as skipped, emits a
  warning, and continues ALPM, AUR, and AppImage work.
- Backup omits Flatpak records, emits a warning, and continues.
- Non-Flatpak commands do not probe or load the backend.
- Help, completion generation, documentation generation, and command parsing
  work without the backend.

If the UI needs to hide or disable Flatpak pages, expose the capability through
the CLI's structured output instead of loading the backend from the UI.

## 10. Remove the Native Link from PackageManager

After the facade no longer contains direct native calls, remove the Flatpak
module and system-library link from `Shelly.PackageManager/build.zig`:

```zig
mod.addImport("flatpak", flatpak_mod);
mod.linkSystemLibrary("flatpak", .{});
```

Add the new project as a path dependency in
`Shelly.PackageManager/build.zig.zon`, but import only its pure protocol module:

```zig
.shelly_flatpak_backend = .{
    .path = "../Shelly.Flatpak.Backend",
},
```

The exact dependency and module names should follow the repository's final Zig
package naming convention.

Building PackageManager alone must not build or link the backend implementation
unless a dedicated backend build or aggregate repository build step requests
it.

## 11. Add Build Orchestration

Provide explicit build steps in the backend project:

```text
zig build
zig build test
zig build abi-test
zig build integration-test
```

The default backend build should:

- Build the shared library.
- Assign its SONAME.
- Install its versioned file.
- Install or create the unversioned development link only when needed for local
  development.

Repository release builds should:

1. Build and test `Shelly.Flatpak.Backend`.
2. Build and test `Shelly.PackageManager`.
3. Build and test `Shelly.Cli.Zig`.
4. Build remaining UI and service artifacts.
5. Verify ELF dependencies before packaging.
6. Stage the backend independently from the base Shelly files.

Update:

- `.github/workflows/build-and-publish.yml`
- `.github/workflows/release.yml`
- `PKGBUILD`
- `PKGBUILD-git`
- `PKGBUILD-bin`
- `PKGBUILD-cli`

## 12. Split Packaging

Prefer two installable Arch packages:

```text
shelly
shelly-flatpak-backend
```

The base package should declare:

```bash
optdepends=(
    'shelly-flatpak-backend: Flatpak package management support'
)
```

The backend package should declare:

```bash
depends=(
    "shelly=${pkgver}"
    'flatpak'
)
```

The source build may retain Flatpak in `makedepends` because it builds the
optional backend artifact. Flatpak must not remain in the base package's
runtime `depends`.

The backend subpackage should install:

```text
/usr/lib/shelly/libshelly-flatpak-backend.so.1
```

If ABI compatibility requires exact Shelly and backend versions, use an exact
package version dependency or a versioned virtual provision. Do not silently
load a backend built for an incompatible PackageManager protocol.

Binary release archives should either:

- Publish separate base and backend archives, or
- Contain clearly separated staging directories that the split PKGBUILD can
  package independently.

## 13. Testing Strategy

### Protocol Tests

- Round-trip every request and response type.
- Reject unknown schemas and enum values.
- Reject malformed, truncated, and oversized JSON.
- Verify stable error-code mapping.
- Verify that unknown optional fields are handled according to the versioning
  policy.

### Fake Backend Tests

Build a test-only shared library that implements the C ABI without linking
libflatpak. Use it to test:

- Successful loading.
- Missing entry point.
- Older and newer ABI versions.
- Short function-table structures.
- Null required function pointers.
- Successful responses.
- Backend errors.
- Malformed responses.
- Event delivery.
- Progress delivery.
- Cancellation.
- Concurrent clients.
- Response release on decode failure.

### PackageManager Tests

- Existing manager calls retain their public semantics.
- All returned records own their memory.
- No generated binding type appears in a public declaration.
- Missing backend maps to the expected error.
- Aggregate commands skip only Flatpak when the backend is unavailable.
- A backend cannot be unloaded during a callback or operation.

### Backend Parity Tests

Port the existing Flatpak tests to the backend project and preserve coverage
for:

- Install, update, uninstall, repair, and upgrade.
- User and system scope.
- Reference-file and bundle installation.
- Remote listing and mutation.
- AppStream update and parsing.
- Installed and update discovery.
- Running-instance discovery, launch, and kill.
- Unused dependency discovery and removal.
- Status, progress, error, and cancellation propagation.

Live-system mutation tests must remain separate from safe default tests and
must require explicit opt-in.

### ELF and Packaging Tests

After building release artifacts:

```bash
readelf -d Shelly.Cli.Zig/zig-out/bin/shelly
readelf -d Shelly.Flatpak.Backend/zig-out/lib/libshelly-flatpak-backend.so.1
```

Assert:

- `shelly` does not contain `libflatpak.so.0`.
- `shelly` does not contain `libostree-1.so.1` solely because of Flatpak.
- The backend contains `libflatpak.so.0`.
- Installing only the base package leaves no broken required package
  dependency.
- Installing the backend package enables the capability query and Flatpak
  commands.

Run a core-only smoke test in an environment without Flatpak:

```text
shelly --help
shelly --version
shelly list standard
shelly search standard <query>
shelly completion ...
```

Then install Flatpak and the backend and run the Flatpak integration suite.

## 14. Documentation Updates

Update:

- `README.md`
- `CONTRIBUTING.md`
- `MANUAL_TESTING.md`
- `Shelly.Cli.Zig/UI_INTEGRATION.md`
- Arch package descriptions

Document:

- Flatpak support is optional.
- Which package enables it.
- How a missing or incompatible backend is reported.
- The fixed production backend location.
- The backend ABI and ownership rules.
- How to build and test the backend locally.
- How to bump the ABI and SONAME.

## 15. Implementation Order

Use the following sequence so each change remains reviewable:

1. Record the current ELF dependencies and Flatpak behavior as a baseline.
2. Inventory all public Flatpak operations and native types used by consumers.
3. Add PackageManager-owned domain types and migrate CLI callers away from raw
   pointers.
4. Scaffold `Shelly.Flatpak.Backend` and its pure protocol module.
5. Define and test protocol request, response, event, and error schemas.
6. Define the versioned C ABI and build a fake backend.
7. Implement and test the PackageManager loader against the fake backend.
8. Move the generated binding and native implementation into the backend.
9. Add protocol dispatch to the real backend one operation group at a time.
10. Switch PackageManager managers to the backend client while preserving their
    public API.
11. Bridge operation events, progress, errors, and cancellation.
12. Port Flatpak parity tests to the backend project.
13. Remove the libflatpak import and link from PackageManager.
14. Add ELF dependency gates to CI.
15. Split source and binary packaging.
16. Test base-only installation and optional backend installation.
17. Update user, contributor, and integration documentation.

Do not remove the existing direct implementation until the replacement covers
all operations and passes the parity suite. During migration, an internal build
option may select the legacy or backend path, but release builds should use
only one implementation once parity is achieved.

## Risks and Mitigations

### ABI Drift

Risk: PackageManager loads a backend built for a different contract.

Mitigation: Version the ABI, function-table size, wire schema, SONAME, and
package dependency. Reject mismatches before creating a backend handle.

### Native Pointer Leakage

Risk: A caller retains memory owned by libflatpak or the backend.

Mitigation: Use only owned domain records across the boundary and enforce
explicit response release.

### Privileged Library Injection

Risk: An elevated Shelly process loads a user-controlled shared library.

Mitigation: Use a fixed absolute production path and disable all user-controlled
backend overrides in release and elevated execution.

### Event Reentrancy

Risk: Backend callbacks re-enter PackageManager while state or allocators are
locked.

Mitigation: Document callback threading, keep callback work small, avoid
holding loader locks while executing backend code, and copy event data before
queueing it.

### Cancellation Races

Risk: Cancellation targets a completed or destroyed operation.

Mitigation: Use unique operation IDs, make cancellation idempotent, and retain
operation state until both execution and cancellation callbacks have settled.

### Partial Migration

Risk: Some CLI path continues to import the generated binding and restores the
native dependency.

Mitigation: Add a source check forbidding generated Flatpak imports outside the
backend and an ELF dependency check on every release build.

### Packaging Skew

Risk: The backend and base package are upgraded independently to incompatible
versions.

Mitigation: Use exact package-version dependencies until the ABI has proven
stable enough for a wider compatibility range.

## Final Acceptance Checklist

- [ ] `Shelly.Flatpak.Backend` builds a versioned shared library.
- [ ] The backend links libflatpak through pkg-config.
- [ ] PackageManager imports only the pure protocol module.
- [ ] PackageManager loads the backend only for Flatpak operations.
- [ ] Production loading uses a trusted absolute path.
- [ ] The ABI rejects incompatible backends.
- [ ] All public results contain owned, backend-neutral values.
- [ ] The CLI contains no direct Flatpak or GLib calls.
- [ ] All current Flatpak operations pass backend parity tests.
- [ ] Events, progress, errors, and cancellation cross the boundary.
- [ ] Direct Flatpak commands report an unavailable backend clearly.
- [ ] Aggregate commands continue other backends when Flatpak is unavailable.
- [ ] `shelly` has no Flatpak or OSTree `DT_NEEDED` entry.
- [ ] The backend has the expected `libflatpak.so.0` dependency.
- [ ] Base and backend packages can be installed independently as designed.
- [ ] A base-only installation passes non-Flatpak smoke tests.
- [ ] Installing the optional backend enables Flatpak without rebuilding
      Shelly.
- [ ] Build, release, packaging, contributor, and user documentation is updated.
