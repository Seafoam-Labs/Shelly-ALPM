# Hooks and scriptlets

The executor consumes these stages in normal commit; both `transaction_actions`
and `transactions` are enabled. See [execution.md](execution.md) for
payload/database publication and the full-commit validation.

## Ownership and executor contract

`Hooks` owns parsed files, commands, triggers, issues, and match lists in an
arena. `Hooks.changes` derives package/path operations from the frozen
`TransactionPlan` and `ExecutionManifest`. Path matching includes old inventories
of upgraded/removed packages, even if files are missing. Incoming NoExtract
paths are excluded. Ownership transfers become Upgrade; directories retain their
trailing slash; `.pacnew` matches the original pathname.

`Transaction` owns `TransactionActions` until release. `actions()` borrows its
state and outcomes, including nonfatal exit/signal/setup/cleanup failures.
`startActions()` is an internal executor entry: it requires the committing
state, active Owner busy guard, owned lock, and completed preflight.
Applications must not change transaction fields to call it. The action
integration fixtures use an explicit miniature executor; full executor tests
also replay their 19 native traces through real commits.

The executor follows this sequence:

1. Revalidate prepared state, archives, root/DB identity and the manifest, then
   enter committing with the Owner operation guard held.
2. `startActions()` discovers and runs pre-transaction hooks. Abort on failure.
   Recheck root/DB identity and database state; recompute backup decisions from
   the filesystem after hooks and scripts.
3. In plan order, process explicit removals, then additions. Call
   `beforePackage(id)` before each package mutation and `afterPackage(id)` after.
   For removal, post_remove runs before deleting the old local record. For
   addition, write the new local `install` member before post_install/post_upgrade.
4. Publish the actual resulting local cache before `finish()`. It checks all
   packages reached their post stage, runs linker-cache maintenance, emits the
   transaction phase completion, then rediscovers and runs post hooks.
5. If payload/database work fails or is interrupted, call `fail()` and retain the
   session for diagnostics. Do not call `finish()`. These stages provide no rollback.

Hook Depends uses the actual local cache at invocation time, including versioned
providers. AssumeInstalled does not satisfy it. No post hook runs after a failed
pre hook, failed payload stage, or cancellation. Pre hooks without AbortOnFail,
all post hooks, scriptlets, and ldconfig retain failures without converting them
into fatal transaction errors. Allocation failure and cancellation propagate.

## Hook format and process behavior

The parser handles repeated Trigger/Action sections, Operation, Type (including
legacy File), Target, When, Exec, Depends, Description, AbortOnFail, NeedsTargets,
and CachyOS NetworkAccess. Last matching patterns win, including negations.
Repeated scalar options warn and replace; list options accumulate. Later
configured directories override earlier files by basename. Empty files and
`/dev/null` symlinks mask lower hooks. Files sort lexically without `.hook`.
Malformed pre-hook discovery stops all hooks; post discovery retains errors and
runs the remaining valid hooks. Discovery happens again after package writes.

INI comments occupy whole lines. Exec performs the pinned native word splitting,
without shell expansion or PATH lookup: quotes group words; only quote delimiters
are escapable; an unquoted backslash before whitespace stays literal. Targets
from all matching triggers are sorted, deduplicated, and sent as newline-delimited
stdin when NeedsTargets is present. See the upstream
[hook format](https://man.archlinux.org/man/alpm-hooks.5.en) and the pinned oracle
for parser details.

Pre-install/upgrade uses the sealed incoming archive's `.INSTALL`; post uses the
new local DB member. Both removal stages use the old local member. Reinstalls and
downgrades use upgrade functions. Arguments are new version then old version;
install/remove functions receive one version. Script detection preserves the
native comment-stripping 1023-byte line scan. Scriptlets are staged in a private
directory under the held root's `tmp`, sourced with no initial positional
arguments, and cleaned after success, failure, or cancellation. Versions are
shell-quoted to preserve literal metadata safely. This intentionally closes the
native shell-injection behavior for malformed version strings.

The pinned CachyOS paths are `/usr/bin/bash` and `/usr/bin/ldconfig`. A fresh
`shelly --internal-rlpm-action-worker` process receives framed setup data, then
action stdin.
It enters the held root, changes cwd to `/`, preserves/defaults SHLVL, removes
BASH_ENV, applies umask 0022, resets signals/masks and closes inherited descriptors
on exec. Parent cwd, umask, credentials, environment and network stay unchanged.
The fresh process does not inherit Owner/resolver state. It shares the hosting
executable's ELF dependencies, including libcurl and, in enabled builds, libalpm.

Parent transport drains merged stdout/stderr while feeding stdin. It forwards
scriptlet-output lines (including partial final lines), reports setup failures
separately from a command's exit code, and checks cancellation while waiting.
Cancellation terminates the process group and reaps the direct child.

| Control | Behavior |
| --- | --- |
| Default hook/scriptlet | Required network namespace, loopback brought up best effort; isolation failure prevents execution |
| Hook `NetworkAccess=allowed` | Permit network for that hook |
| `sandbox.disable_network` | Permit network for hooks, scriptlets and ldconfig |
| `sandbox.setDisabled(true)` | Also disables network isolation, preserving CachyOS global behavior |
| Filesystem/syscall sandbox controls | Remain independent download controls; do not disable action network isolation |
| ldconfig | Run only with `etc/ld.so.conf` and an executable configured-root binary; isolation failure warns and proceeds |
| NOHOOKS / NOSCRIPTLET | Independently suppress their respective actions; neither suppresses ldconfig |
| DBONLY | Still runs hooks, scriptlets and ldconfig |
| DOWNLOADONLY with additions | No transaction actions |

Both action and download children launch `/proc/self/exe` with their reserved mode.
The dispatcher must run before normal application setup or protocol streams can
be corrupted by ordinary output. Embedders call `rlpm.Workers.dispatch(init, args)`
with argv[0] removed, and exit with a returned status; `null` means normal arguments.
Alternatively, `OwnerConfiguration.worker_executable` accepts a copied, absolute
path to an executable implementing both modes. Neither path searches for helpers
beside the executable or falls back to build-cache files. The standalone RLPM
example installs the dispatcher; library tests explicitly select an uninstalled
fixture using the same dispatcher.

Resource bounds are explicit: hook files 4 MiB, scriptlet members 16 MiB, worker
setup JSON 1 MiB. Oversized/malformed input produces a retained error. Unlike the
native parser, empty executable names and embedded NUL are rejected safely.
These limits and literal version quoting are intentional differences, not parity
claims for malformed or unbounded input.

## Validation

`zig build test-hooks` runs seven hermetic parser/discovery/matching/ownership
tests, also included in `test`. `zig build test-actions` runs 18 real-process tests
under `unshare --user --map-root-user --mount`, using only disposable roots and
fixture scripts. It requires Linux user/network namespaces, chroot, pidfd,
close_range, bash, ldd and util-linux; unavailable facilities fail the tests.
`check-actions` only compiles the integration. CI enables the nested namespaces
for this job and executes both Debug and ReleaseSafe integrations.

The integration verifies action ordering, current DB sources, independent flags,
nonfatal diagnostics, root/environment/fd isolation, bidirectional large I/O,
process-group cancellation and cleanup. A test-only seccomp launcher forces
network namespace failure, exercising required, permitted and best-effort paths.
No production fault-injection switch exists.

Nineteen independently recorded CachyOS libalpm scenarios in
[src/tests/reference/actions.json](src/tests/reference/actions.json) are replayed
against real RLPM actions. The recorder validates the frozen library hash and
checks private root, DB and hook paths immediately before every native commit.
It installs no host hooks, service managers or real ldconfig into the fixture.
See [reference capture instructions](src/tests/reference/README.md).

These tests cover hook and scriptlet stages. Executor tests add full execution,
record recovery and audit logging. The ledger retains partial status until the
complete production acceptance gate.
