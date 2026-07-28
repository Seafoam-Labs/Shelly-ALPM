# Shelly Flatpak backend ABI

Flatpak support is an optional native backend. The base CLI and
`Shelly.PackageManager` do not link libflatpak, GLib, GIO, GObject, or OSTree
for Flatpak support. Native Flatpak objects and generated bindings live only in
`Shelly.Flatpak.Backend`.

The production loader opens exactly:

```text
/usr/lib/shelly/libshelly-flatpak-backend.so.1
```

It does not search the working directory, `PATH`, or an environment variable.
A build-time `-Dflatpak-backend-path=/absolute/path` option exists only for
development and fake-backend tests; release packages do not set it.

## Component boundary

```text
CLI / UI
    |
    v
PackageManager-owned Flatpak facade and owned domain values
    |
    v
strict JSON schema 1 over C ABI 1
    |
    v
libshelly-flatpak-backend.so.1
    |
    v
libflatpak / GLib / OSTree
```

`Shelly.PackageManager/src/flatpak/types.zig` owns all values returned to
consumers. No generated binding, GObject pointer, or backend allocation is
exposed through its public declarations. AppStream XML parsing stays in
PackageManager because it is native-library-independent; the backend returns
owned catalog locations and metadata.

## C ABI version 1

The declarations are defined in
`Shelly.Flatpak.Backend/src/protocol.zig`. The only exported backend symbol is:

```c
shelly_flatpak_backend_get_api
```

Conceptually, ABI 1 contains these C-compatible tables:

```c
typedef struct {
    const uint8_t *ptr;
    size_t len;
} ShellyRequestBuffer;

typedef struct {
    uint8_t *ptr;
    size_t len;
} ShellyResponseBuffer;

typedef struct {
    const uint8_t *ptr;
    size_t len;
} ShellyEventBuffer;

typedef struct {
    size_t struct_size;
    uint32_t abi_version;
    void *user_data;
    void (*emit_event)(void *user_data, ShellyEventBuffer event);
} ShellyHostApiV1;

typedef struct {
    size_t struct_size;
    uint32_t abi_version;
    Status (*create)(const ShellyHostApiV1 *host, void **handle);
    void (*destroy)(void *handle);
    Status (*execute)(
        void *handle,
        ShellyRequestBuffer request,
        ShellyResponseBuffer *response);
    Status (*cancel)(void *handle, uint64_t operation_id);
    void (*free_response)(void *handle, ShellyResponseBuffer response);
} ShellyBackendApiV1;
```

The loader requests the exact supported ABI. It rejects a different version,
a short `struct_size`, or any null required function pointer before creating a
handle. A library rejected as incompatible is not retried during that process.
The validated dynamic library remains open for the process lifetime, so it
cannot be unloaded during an operation or callback.

## Ownership and lifetime

- The request buffer is borrowed by the backend and is valid only for the
  synchronous `execute` call.
- Every non-empty response buffer is allocated and owned by the backend.
  PackageManager calls `free_response` on success, backend errors, schema
  errors, malformed JSON, and result decode failures.
- An event buffer is borrowed by the host and valid only for the
  `emit_event` callback. PackageManager parses or copies it before returning.
- Decoded results are deep-copied into PackageManager-owned domain records.
  Their documented `deinit` or `deinitSlice` function releases them.
- A handle remains alive until execution, callbacks, response decoding, and
  response release have completed.

`destroy` must not race an active `execute`. `cancel` is idempotent: cancelling
an unknown or already-completed operation succeeds without touching stale
state. Both sides unsubscribe borrowed cancellation handlers and drain any
callbacks that were already snapshotted before destroying the backend handle
or its `GCancellable`.

## Wire schema 1

Messages are UTF-8 JSON and are limited to 16 MiB. Schema 1 is strict:
duplicate fields, unknown fields, missing required fields, invalid enum tags,
truncated JSON, and oversized messages are rejected.

Request:

```json
{
  "schema": 1,
  "operation_id": 42,
  "method": "list_installed",
  "arguments": {
    "mode": "applications"
  }
}
```

Success:

```json
{
  "schema": 1,
  "operation_id": 42,
  "result": []
}
```

Failure:

```json
{
  "schema": 1,
  "operation_id": 42,
  "error": {
    "code": "flatpak.not_found",
    "message": "The requested Flatpak was not found.",
    "native_code": null
  }
}
```

Exactly one of `result` or `error` is required. The response operation ID must
match the request.

Events carry `schema`, `operation_id`, `kind`, stable `code`, display
`message`, `level`, and optional progress/native fields. Event kinds are
`started`, `status`, `progress`, `failure`, and `completed`.

Callbacks can originate from a Flatpak callback or worker thread.
PackageManager callback work is deliberately small and does not assume caller
thread affinity. The loader mutex is never held while backend code executes,
which avoids callback reentrancy through loader state.

## Operations

Schema 1 covers:

- install by ref, `.flatpakref`, or bundle;
- update, uninstall, repair, upgrade-all, and unused-runtime removal;
- installed apps/refs, updates, unused dependencies, and running instances;
- remote search/ref inspection, launch, and kill;
- remote list/add/remove, priority, and remote refs;
- AppStream update, catalog discovery, and catalog loading.

Live mutation parity tests remain opt-in. Default tests use protocol fixtures
and a Flatpak-free fake shared library.

## Errors and optional behavior

Discovery failures map to `FlatpakBackendUnavailable`; ABI failures map to
`FlatpakBackendIncompatible`. Direct Flatpak CLI commands explain that
`shelly-flatpak-backend` and Flatpak must be installed. Aggregate update and
upgrade commands emit a warning, skip only Flatpak, and continue other
backends. Backup emits a warning and omits Flatpak records.

Non-Flatpak commands, parsing, help, version, and completion generation do not
load or probe the backend.

## Building and testing

```bash
cd Shelly.Flatpak.Backend
zig build
zig build test
zig build abi-test
zig build parity-test
zig build integration-test
```

Tests that inspect or launch applications from the current user's configured
Flatpak installation are deliberately excluded from every default step. Run
`zig build live-test` only when that live-system access is intended.

From the repository root, the complete boundary and core-only smoke suite is:

```bash
scripts/test-flatpak-separation.sh
```

The fake shared library tests loading, old/new ABI requests, missing symbols,
short/null tables, success, stable errors, malformed responses, event/progress
delivery, cancellation, concurrent clients, and response release. The ELF gate
asserts that the CLI has no Flatpak/OSTree dependency, the real backend does
depend on `libflatpak.so.0`, its SONAME is ABI 1, and its entry point is
exported.

## Changing the ABI

An incompatible C table change requires all of the following in one release:

1. increment `abi_version`;
2. introduce the corresponding API table type;
3. increment the shared-library SONAME;
4. update the fixed production filename;
5. update fake/loader compatibility tests;
6. update the exact base/backend package dependency;
7. document the migration here.

An incompatible wire change also increments `schema_version`. Do not add a
field that older schema-1 decoders would reject while continuing to label the
message schema 1.
