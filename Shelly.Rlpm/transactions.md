# Transactions, locks and callbacks

The executor enables normal commit, payload changes and durable local records.
`transaction_lifecycle`, `downloads`, `filesystem_preflight`,
`transaction_actions` and `transactions` are enabled. See
[execution.md](execution.md) for execution order, partial-progress reports,
recovery and validation. DOWNLOADONLY with additions completes without
installed-state changes.

```zig
var owner = try rlpm.Owner.init(io, allocator, configuration, repositories);
defer owner.deinit() catch unreachable;

const transaction = try owner.initializeTransaction(io, .{});
defer owner.releaseTransaction() catch unreachable;
try transaction.addTarget("example");
try transaction.prepare();
const reviewed = transaction.plan().?; // borrowed until another prepare/release
try reviewed.check();
// Inspect additions, removals, answers, sizes and issues here.
try transaction.commit();
```

Owner owns a stable heap allocation for the transaction. Never move an Owner
after publishing its address, shallow-copy ownership-bearing values, modify
implementation fields directly, or retain a transaction/plan view after release.
`Owner.deinit` rejects an active transaction; release it explicitly first.
Unlike native `alpm_release`, this keeps outstanding transaction borrows visible
to the caller. Release errors still destroy the transaction and clear Owner's
active pointer: do not retry cleanup using the old pointer.

| State | Allowed work |
| --- | --- |
| `initialized` | `addTarget`, `addPackage`, `takeArchive`, `remove`, `systemUpgrade`, `prepare`, release |
| `preparing` | Synchronous callbacks; atomic cancellation only |
| `prepared` | Read the plan/manifest, `downloadSize`, `download`, `preflight`, `revalidatePreflight`, `commit`, release |
| `committing` | Synchronous callbacks; atomic cancellation only |
| `completed`, `failed`, `interrupted` | Read retained outcome/diagnostics, release |
| `released` | Final lifecycle notification; pointer expires after callback |

Wrong-state calls return `InvalidTransactionState`. A failed prepare retains
semantic diagnostics when a plan exists. Operational failure can leave no plan.
Retry by releasing, resetting cancellation if necessary, and starting a new
transaction. Native libalpm may retain its initialized state after a failed
prepare; RLPM makes this failure explicit. `Owner.resolve` remains a separate
read-only planning API and cannot run while a transaction is active.

Initially empty preparation succeeds but stays initialized, matching libalpm.
The same applies when initial selection skips all targets under `NEEDED` or
finds no system upgrades. If preparation itself removes every target (for
example `UNNEEDED` or accepted unresolvable-target removal), it reaches prepared;
its empty commit can complete. The typed `completed` state is a Shelly extension
to the native empty-commit behavior. Even an empty commit rejects `NOLOCK` first.

`addPackage` requires a current sync `PackageRef`; repeating the same reference
is harmless. Distinct packages with the same name are rejected. Repeating a
removal name is harmless. Exact repeated frontend target text is rejected;
identity duplicates discovered while resolving follow the resolver's rules.
`systemUpgrade(allow_downgrade)` records upgrade intent for preparation. Text and
upgrade selection happen during prepare, whereas native frontends usually select
before calling `alpm_trans_prepare`; question timing follows that distinction.

`takeArchive(*?Package)` makes transfer explicit. It requires an owned archive
with an arena, nulls the caller's optional only on success, and preserves caller
ownership on every rejection or allocation failure. Accepted archives, including
skipped ones, remain transaction-owned until release. A prepared plan independently
retains sealed descriptors. Metadata-only archives gain no verification claim until successful preflight.

## Lock and snapshot contract

Initialization creates `<database_path>/db.lck` with `O_EXCL|O_CLOEXEC`, mode 000,
and no contents, matching the pinned library. It retains the descriptor until
release, including on prepare failure, cancellation, and uncommitted release.
`NOLOCK` skips acquisition but cannot authorize commit. Permission and contention
errors leave no active transaction. Allocation failure after acquisition cleans
up the lock. Ordinary initialization and `Owner.unlock()` never delete a lock
owned by another process or a stale lock from a previous process.

`Owner.unlock()` explicitly releases only this Owner's lock. The transaction
cannot commit afterward. Release compares the retained descriptor's device/inode
with the current path before unlinking. A missing path is harmless; replacement
returns `LockOwnershipLost` and preserves the replacement. This improves on native
pathname-only cleanup. It protects cooperating writers, not an adversarial
replacement between the final identity check and unlink.

Under the lock, initialization invalidates existing local and sync cache
generations and reloads local identities. Obtain PackageRefs after initialization;
earlier refs are stale. Configuration, callbacks, repository registration, usage,
servers, reload and invalidation are frozen until release. Lazy queries and
verified archive loads remain available outside callbacks. Plans deep-copy their
metadata; later lazy queries cannot change the reviewed set.

A sorted SHA-256 content fingerprint of local/sync state is checked at
initialization, before and after preparation, and before commit. Out-of-band
edits fail with `StaleDatabaseState`; no silent reprepare or changed plan is
committed. Regular file symlinks are read through; symlinked subdirectories are
rejected because the walker would otherwise omit their contents. Full hashing is
a deliberately conservative first implementation; repository refresh must
integrate legitimate publication, and performance acceptance must measure
hashing costs on large databases. The fingerprint is not a filesystem preflight
or keyring validation substitute.

## Events, questions and cancellation

Native prepare events follow actual work: dependency resolution, inter-package
conflict checks, removal dependency checks, and optional-dependency removal.
`NODEPS`/`NOCONFLICTS` suppress the corresponding phases. Failed native phases
do not receive a synthetic `done` event. The separate `lifecycle` extension
reports state, cause, completed-package count and warning count. Execution
produces retrieval, integrity, load, keyring, disk-space, package-operation,
backup, scriptlet and hook events. The executor writes configured audit logs and
syslog records.

All seven questions have conservative defaults. Only answer fields are copied
back; changing the tag or choosing an invalid provider fails with `InvalidAnswer`.
`question_with_error` is the optional fallible adapter callback and takes
precedence over `question`. Resolver decisions and answers remain in the plan.
`OwnedQuestion` deep-copies strings, relations, references and package metadata,
without copying arenas or acquiring file-descriptor ownership.

Callbacks run synchronously and borrow payloads. Reentry fails with
`CallbackReentry`. `Owner.requestCancellation` is the only cross-thread
operation; it sets an atomic flag. Preparation checks it during hashing/solving,
before and after questions/events, and before the commit boundary. Release
remains available after cancellation. Downloads, preflight, actions and payload
mutations check cancellation. The executor retains partial work and
completed/remaining package IDs; no full rollback is assumed.

PackageManager exports the opt-in `RlpmOperationAdapter`; the default backend
selection is unchanged. Attach it at a stable address before initialization and
detach after release. It owns question payloads until deferred responses return,
maps typed answers, forwards event/progress/status callbacks, and reports one
completion per operation. Failed/interrupted transactions map to failed/cancelled;
releasing uncommitted work maps to cancelled. Context cancellation notifies RLPM.
A nonblocking probe also checks direct Owner cancellation during deferred waits
at 10ms intervals. The UI must copy anything retained after answering.

## Validation

`zig build test-transaction` runs 15 private-root tests, also included in `test`.
They cover lifecycle errors, ownership, callback reentry, stale state, permissions
for unprivileged runners, two Owners, independent POSIX writer processes in both
acquisition orders, cancellation, descriptor closure, and every Zig allocation
failure across initialization/prepare/archive transfer. Native malloc failures
are not injected. Permission-denial assertions are inapplicable for UID 0.

The [transaction reference fixture](src/tests/reference/transaction.json)
replays 16 pinned libalpm scenarios for errors, lock contents/mode/timing and
native event order. The optional `record_transaction.py --library
/usr/lib/libalpm.so.16.0.1` recorder verifies the frozen library hash, uses
disposable roots, and independently guards every commit against nonempty targets
unless NOLOCK guarantees rejection. Normal tests never load libalpm. Original
frozen reference assets remain unchanged.

From `Shelly.PackageManager`, run `zig build rlpm-adapter-test
-Drlpm-adapter-only=true` for three adapter tests and six shared-context
regressions. The deferred tests use a real responder thread and both
cancellation routes. Debug and ReleaseSafe each pass 132 RLPM tests and nine
adapter/context tests; all 12 real-GPG regressions pass. These checks validate
transaction lifecycle behavior; they do not establish full backend equivalence.

The action API provides transaction-owned action stages and `actions()`
outcomes. An internal `startActions()` entry requires committing state, the
Owner busy guard and the transaction lock. It is reserved for the executor,
which now supplies normal commit. Hooks, scriptlets and ldconfig retain process
setup/exit/signal and cleanup failures, with cancellation terminating the child
group. See [actions.md](actions.md) for stage order, independent flags and
CachyOS network semantics.
