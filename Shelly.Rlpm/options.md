# Owner options and lifetimes

`Owner.init(io, allocator, configuration, repositories)` copies configuration
and registration inputs, validates/initializes the local format and loads local
identities. Descriptions, files and groups load lazily; see [databases.md](databases.md).
`OwnerConfiguration` and `DatabaseConfiguration` are borrowed input values;
the owner and each database retain their own arena storage. No allocator pointer
or owner back-pointer points into an initializer's temporary stack value.

```zig
const rlpm = @import("Shelly_Rlpm");
var owner = try rlpm.Owner.init(io, allocator, .{
    .root = root_path,
    .database_path = database_path,
    .cache_directories = &.{cache_path},
    .architectures = &.{"x86_64"},
}, &.{
    .{ .database_name = "core", .servers = &.{core_url} },
    .{ .database_name = "cachyos", .servers = &.{cachyos_url} },
});
defer owner.deinit() catch unreachable;
const local = owner.localDatabase().?;
if (try owner.findPackage(local, "example")) |reference| {
    const package = try owner.packageMetadata(io, reference, .{});
    // package is a borrowed view; use or copy it before another mutation.
    _ = package;
}
```

## Paths and defaults

Root and database path must already be directories. Both are canonicalized with
realpath and receive a terminal slash; an explicitly supplied DB path is
independent of root. Local metadata uses `<dbpath>/local/`, sync registrations use
`<dbpath>/sync/<name><database_extension>`, and the transaction/refresh lock uses
`<dbpath>/db.lck`. Repository registration performs no download and does not
require an existing sync archive.

Cache/hook/GPG directory options receive a terminal slash but are not resolved,
created or prefixed with root. Relative paths stay relative to the caller's
working directory. A null hook-directory list chooses
`<root>/usr/share/libalpm/hooks/`; an empty list chooses no directories. Explicit
hook lists replace that default. Logfile paths are copied as supplied.

Library defaults match the pinned handle defaults: no cache or architecture
lists, one parallel download, check-space/syslog/download-timeout-disable off,
and all sandbox-disable switches off. Default/local/remote signature policies
start disabled, as in an unconfigured libalpm handle. `SignaturePolicy{}` itself
retains the project's required-signature defaults; supply it explicitly where
wanted. Null repository/local/remote overrides inherit the owner's current
default policy. A local installed database never receives a detached repository
signature policy. Pacman.conf parsing, Include, `$repo`/`$arch` expansion, and
frontend policy defaults stay in PackageManager.

The default local mode creates absent storage or a version-9 marker in an empty
directory, matching the pinned initializer. Unsupported formats and populated
directories without a marker fail. `local_database_mode = .read_only` never writes;
an absent local directory yields an empty missing snapshot. The example CLI uses
this explicit mode. Repository archives are loaded lazily without downloads.

## Option inventory

All fields below are copied and available through `options()`. Storing an option
is not implementation of its downstream effects. The compatibility ledger keeps
these rows partial until the downstream consumer fixtures pass.

| Configuration field | Implemented now | Remaining consumer |
| --- | --- | --- |
| `root`, `database_path` | Independent canonical paths, held descriptors and confined filesystem mutations | — |
| `local_database_mode` | Default creation/validation or explicit read-only local opening | — |
| `database_extension` | Sync registration paths and replacement; rejects NUL/path separators | — |
| `cache_directories` | Ordered cache search, current-policy verification and writable selection | — |
| `hook_directories` | Discovery, overrides, parsing, matching and transaction execution | — |
| `gpg_directory` | Explicit home for verification and consented key operations; null uses system pacman keyring | — |
| `key_acquisition` | Owned single-key source paths, WKD/keyserver controls; import requires callback consent and reverification | Live server interoperability |
| `log_file`, `use_syslog` | Timestamped ALPM audit file and syslog forwarding; failures retained | — |
| `architectures` | Owned list and initial-target architecture validation, including CachyOS architectures | Frontend architecture auto mapping |
| `ignore_packages`, `ignore_groups` | Owned lists, glob matching, candidate questions and upgrade filtering | — |
| `assume_installed` | Owned unversioned/exact provisions, permissive raw versions, descriptions and dependency checks | — |
| `no_upgrade`, `no_extract`, `overwrite_files` | Ordered glob/negation matching, manifest decisions and backup/payload effects | — |
| `check_space` | Per-filesystem peak, native cushion, serialized DB sizes and staging; actual ENOSPC tested | Broader mount matrix |
| `default_signature_policy`, `local_file_signature_policy`, `remote_file_signature_policy` | Enforced inheritance, presence, crypto validity and trust; sealed snapshots and preflight full-stream/current-policy checks | — |
| `disable_download_timeout`, `parallel_downloads` | Shared bounded queue and cancellable setup/header/body deadlines | — |
| `worker_executable` | Optional copied absolute path implementing `Workers.dispatch`; null launches `/proc/self/exe` with the reserved action/download argument | Early dispatcher or embedding override required |
| `sandbox_user` | Account lookup and child credential changes when native applicability requires it | Root-only integration must run in a privileged environment |
| `sandbox.disable_filesystem`, `sandbox.disable_syscalls` | Independent Landlock and syscall filter controls in the child | Privileged integration |
| `sandbox.disable_network` | Hook/scriptlet isolation, per-hook permission and best-effort ldconfig; global `setDisabled` updates all three switches; consumed during commit | — |
| `callbacks` | Typed callbacks, owned deferred questions, guarded phase/package/backup producers | — |
| Repository `servers`, `cache_servers`, `usage`, `signature_policy` | Owned lists, queries, resolver usage/priority, enforced inherited/explicit policy | — |

`setOptions` constructs a complete replacement before publishing it. Failed
allocation or validation leaves the old configuration and registrations intact.
It preserves database IDs and local metadata. Sync generations change only for
changed paths/effective signature policies/GPG directories; unrelated options
retain cached package/group data. `setList`, `addListValue`, and `removeListValue` provide typed list
updates; duplicates remain ordered and removal affects the first match. Directory
removal uses the same terminal-slash normalization as insertion. To update typed
assumed-installed relations, supply a replacement list through `setOptions` or
use `addAssumedInstalled`/`removeAssumedInstalled`. Only ANY/EQ provisions are
accepted; removal compares the name and raw version, ignoring description/operator.
See [resolution plans](resolution.md) for flags and selection semantics.

`PhysicalArchitectures.init(allocator)` queries runtime CPU/OS state,
independent of the binary's compile target, and owns its result until `deinit`.
It retains CachyOS's ordered base/v2/v3/v4 feature rules, including OS
vector-state checks. The pinned source tests ECX bit 0 under its SSSE3 label;
RLPM preserves that observed rule. Aarch64 returns its base architecture.
`Architecture=auto` mapping belongs to frontend integration.
`Sandbox.legacyDisabledState()` retains the source's filesystem/ syscall-only
aggregate getter, even though the global setter affects networking.

## References, callbacks and cancellation

Owner is an owning value: do not shallow-copy it. Keep its address stable after
publishing it to callbacks or cancellation callers. `deinit` is fallible so a
callback or active operation cannot destroy the handle underneath its caller.
A cancelled idle owner can always be released.

Database references combine a process-local owner ID and a monotonically
assigned database ID. Registration order remains repository priority; removing
one repository preserves other entries' order. IDs are not reused after removal.
Even another owner over the same paths rejects a foreign reference. The local
database can also be unregistered, matching the public reference operation.

Package references additionally contain cache generation and package ID.
`invalidateDatabase` discards metadata and changes its generation; old package
references fail before and after reload. Group membership stores IDs rather than
pointers into a growable array. Package enumeration and group membership follow
package-name order; groups are enumerated in first-encounter order. Borrowed strings, database/group views and slices must not
be retained across mutations or owner release. Resolve references again instead.
These IDs are not persistent identifiers to serialize across process runs.

Configuration and metadata use separate arenas. Reloads publish a complete
generation only on success; failure retains any previous usable generation.
Initial failures leave a clearly unloaded cache and propagate operational/OOM
errors. Local metadata and group loads also publish through candidate arenas.
See [database corruption and lifetime rules](databases.md).

Callbacks run synchronously on the owner's thread. Their payloads and contexts
are borrowed; callers own context lifetimes. They must not reenter owner
operations or mutate configuration/databases directly. Event/question dispatch
rejects reentry and checks cancellation before and after callbacks. Questions
start with conservative answers, enforce provider bounds, and reject changing
the union tag. A rejected or cancelled answer restores the original question.
Transaction phases emit these events; Owner configuration does not simulate
them.

`requestCancellation()` is the only method permitted from another thread or an
active callback. Other access is thread-confined; a download worker must send
results back to the owner thread. Reset cancellation only when idle. No callback
payload survives its call unless the receiver makes an owned copy.

Errors are Zig errors. Registration, configuration replacement, cache operations
and event/question dispatch retain a value-only `Diagnostic` with operation,
category, cause and optional database reference, so error context cannot dangle
after input strings or a registration are freed. `Diagnostic.format` provides a
plain textual description. Query errors and errors before entering those
operations (such as list-helper temporary allocation) are returned directly.

Transaction initialization freezes configuration and invalidates cached package
references. Release the active transaction before reconfiguration, explicit cache
reload/invalidation, or Owner teardown. See the [transaction guide](transactions.md).

The preflight API also exposes `matchNoExtract` and `matchNoUpgrade` with native
tri-state results. See [preflight.md](preflight.md) for pattern precedence,
filesystem inspection, backup decisions, execution-manifest lifetimes and
capacity limits.

Transaction actions consume hook directories and network controls. See
[actions.md](actions.md) for process setup, independent sandbox switches,
callback output and diagnostics.
