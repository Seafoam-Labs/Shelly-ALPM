# Downloads, cache and refresh

RLPM uses `Shelly.Download`, extracted from PackageManager's existing downloader
and bounded queue. PackageManager retains its operation-context adapter and
public downloader imports. Neither RLPM nor the shared transport links libalpm.
HTTP/HTTPS use `Shelly.Http`; the Zig `Curl.zig` adapter calls libcurl for its other
enabled protocols and proxy/redirect schemes that the HTTP client cannot handle.
Local-file transport and HTTP-date parsing are native Zig. TLS verification is
on by default. Standard proxy environment variables and `NO_PROXY` are supported.

```zig
var refreshed = try owner.refreshDatabases(io, false);
defer refreshed.deinit();
try refreshed.check(); // every repository has an individual outcome/cause

var file = try owner.fetchPackage(io, url);
defer file.deinit();
// file.path is the published cache name; file.snapshot pins the verified bytes.

var batch = try owner.fetchPackageUrls(io, urls);
defer batch.deinit();

const tx = try owner.initializeTransaction(io, .{ .download_only = true });
defer owner.releaseTransaction() catch unreachable;
try tx.addTarget("example");
try tx.prepare();
const remaining = try tx.downloadSize(); // bytes, unknown sizes, verified hits
_ = remaining;
try tx.commit(); // acquisition/verification only; zero installed packages changed
```

`Transaction.download()` explicitly acquires a prepared plan without committing.
The transaction owns its `downloaded_files` and sealed descriptors until release.
Normal commits consume acquisition, preflight,
hooks and installation. Runtime backend selection works in builds with libalpm;
builds without it use RLPM throughout. CachyOS tar/SQLite repositories,
architecture handling, provenance and sandbox switches are retained.

## Cache and transfer contract

Ordered cache directories are searched before choosing a writable destination.
Every hit is checked under the current size/digest/signature/trust policy, with
key acquisition still requiring consent. Disabled signatures deliberately do not
imply a cryptographic identity guarantee. Corrupt-cache questions can authorize
removal. Package archives are not unpacked by DOWNLOADONLY; inventory and
prepared-plan identity checks run in preflight, matching the native stage boundary.

Package basenames reject traversal, separators and NUL, including decoded URL
paths. Partial downloads live in private mode-0700 staging directories guarded
against concurrent reuse. HTTP Range responses are validated; a server returning
200 restarts the partial, and rejected ranges cannot append unrelated bytes.
Timeouts and cancellation interrupt setup, headers, bodies and retry delays.
Size ceilings apply while transferring, including the 16 KiB signature limit.

Cache servers precede repository mirrors. Soft errors do not blacklist cache
servers; repository hosts stop after three soft failures. DNS failures blacklist
both. Host counters survive successive package batches. Requests, signature
fetches and retries retain the same bounded job slot; resource exhaustion reduces
concurrency. The queue caps its worker count at 255 even for larger configured
limits. HTTP connections are pooled across an ordinary batch. Privileged sandbox
requests use separate workers and therefore do not share that connection pool.
Detached signatures follow the effective redirect URL when its filename contains
the configured database extension or `.pkg`, matching the pinned selection rule.

Workers only update transfer state. Owner dispatches callbacks on its calling
thread, under the existing reentry guard. `init` means queued acquisition;
`started` identifies an occupied worker slot and its candidate attempt.
`progress` and `retry` belong to that attempt. `transferred` ends the payload and
applicable signature requests promptly, even while other files are downloading.
It does not authenticate the candidate. `processing` identifies the filename,
verification/publication stage, boundary, and position in the batch. Only
`completed` means final acceptance (verified and durably published, accepted
unchanged, or failed). Cached files do not create artificial transfer events.
Fast progress updates may be coalesced; a completed transfer never emits later
progress. Verification and publication remain on the owner thread after workers
join. A database candidate rejected during verification can reopen transfer work
with a new attempt identity, followed by one final acquisition result. Custom
fetch callbacks also run on that thread, in private staging, and support updated/unchanged/error results. Custom
fetch batches are serial; the callback owns transport and privilege policy, as
in libalpm. Cancellation still prevents verification/publication afterward.

If configured cache locations cannot be used, the fallback is a private
`/tmp/rlpm-cache-UID` directory retained for later calls on that Owner. This differs
from libalpm's shared `/tmp` fallback. The returned File/FileSet owns strings and
sealed descriptors; `deinit` does not delete successfully cached archives.

## Presentation

PackageManager finishes each download child on `transferred`, leaving acceptance
and transaction success independent. Verification and publication show the
current filename and completed/total position. A new candidate attempt creates
a fresh download child; final acquisition completion does not repeat its bar.

Isolated-root provisioning retains each active file's latest byte counters and
prints one aggregate summary at most every 250 ms while work is active. Starts,
retries, terminal results, stage changes, errors and hook/scriptlet output flush
immediately; a final idle summary is also immediate. Unknown totals remain
unknown. Both native backends feed this presentation through metadata observers
that do not change standalone confirmation policy. Interactive CLI per-file
bars remain intact.

## Refresh and publication

Refresh requires `db.lck`, rejects an active transaction, honors repository sync
usage and the configured extension, and tries every enabled repository. It reports
updated/unchanged/skipped/failed outcomes separately, in configured repository
order. Independent databases acquire their payload/signature pairs concurrently
under the same `ParallelDownloads` limit as packages. Candidate verification,
key-import questions, parsing and journaled publication remain on the owner
thread. Rejected candidates with remaining mirrors enter another bounded
acquisition round; successful repositories are not downloaded again. It preserves
source file modification times for conditional refresh. A forced refresh bypasses
conditions.

Database data and detached signatures are sealed, verified and parsed before
publication. A successful update replaces only that database's generation; an
unchanged database retains references. Invalid downloads leave the previous
usable database and generation intact. A signature-only repair can publish a
matched pair without changing unchanged metadata references.

Publication synchronizes new files and backups, atomically publishes a small
journal, replaces the two names, then removes the journal as its commit point.
Recovery retains backups until its own durable commit, so it is repeatable after
another interruption. Database readers hold a shared directory lock while
capturing and validating a pair. Publishers and cache acquisition hold the
exclusive lock, since cache validation can authorize corrupt-file removal. Pending journals
produce `DatabaseRecoveryRequired` for database readers; refresh recovers under
`db.lck`. Cache acquisition can recover its own interrupted publication.

These guarantees require cooperating RLPM readers and a filesystem honoring
rename/fsync. External libalpm readers do not take the additional directory lock;
writers still coordinate through native `db.lck`. No claim is made that arbitrary
uncoordinated processes observe two separate pathnames atomically.

## Privilege separation

The pinned applicability rule is retained: root plus a configured sandbox user
and at least one enabled sandbox switch uses a child. An unprivileged caller,
no configured user, or all three switches disabled avoids that path. The child
applies native Zig Landlock write confinement and the seccomp filter as configured, clears
supplementary groups and changes GID/UID. Setup failure aborts the request. The
parent never changes credentials. Downloads need network access; the CachyOS
network switch's execution restrictions apply to hook and scriptlet execution.
The filter retains all 81 distinct pinned syscall denials and rejects alternate
syscall ABIs. It uses Linux syscalls directly, without libseccomp. Account lookup
uses libc/NSS; libc credential setters retain their thread-coordination behavior.

The parent reads regular worker outputs without following symlinks, verifies
sealed bytes, and publishes mode-0644 files under its own ownership. Cancellation
terminates/reaps the child. Children re-execute `/proc/self/exe` with
`--internal-download-worker`; deployments ship only Shelly. Embedders must install
`rlpm.Workers.dispatch` before application setup or set the copied, absolute
`OwnerConfiguration.worker_executable` override to a matching dispatcher host.
There is no build-cache fallback. The bounded queue still launches independent
requests concurrently; this change does not introduce a shared connection pool
across sandboxed children.

## Evidence and limits

`zig build test-download` covers private file mirrors, cache checks, size and
signature rejection, custom callbacks, aggregate refresh, locking, independent
readers, CachyOS repository names, custom extensions, URL batches, callbacks and
DOWNLOADONLY. Local HTTP fixtures verify overlap and limits 1/3/10 for packages
and repositories including mirror/signature requests, fast transfer completion
while a slow response remains blocked, unknown response lengths, retries after
candidate rejection, and cancellation before publication. These tests require
localhost socket access. These tests are also in `zig build test`; publication recovery is
in the module tests. Normal tests do not use the host package database or GPG.

`Shelly.Download: zig build test` exercises local HTTP and FTP, redirects,
conditional responses, connection reuse, truncation, partial resume/restart,
invalid ranges, deadlines, cancellation, injected disk-full failure and queue
bounds. PackageManager's `downloader-test` retains its adapter and manager tests.
`Shelly.Http: zig build test` includes proxy CONNECT and NO_PROXY cases.
`zig build test-signature` includes real signed transfers, missing-key consent,
cache tampering and failed signed refresh, using disposable GPG homes.

The six [pinned oracle cases](src/tests/reference/download-oracle.jsonl) are
replayed by `test-download`. The recorder checks the frozen libalpm hash and
independently refuses a non-DOWNLOADONLY commit or any removal. An intentional
safety difference is recorded: native failures may leave invalid bytes at the
cache's final name; RLPM leaves rejected bytes in private staging instead.
Original frozen assets are unchanged. Ledger rows remain partial, not a claim
of full behavioral equivalence across all servers and protocols.

`zig build check-download-sandbox` compiles the privileged integration fixture.
`Shelly.Download: zig build test-sandbox` separately tests real Landlock/seccomp
enforcement in four fresh unprivileged children, covering both switches, allowed
staging writes, denied outside writes, syscall rejection and unchanged parent
access. It passes locally and requires no sudo. Ordinary shared tests also check
filter decisions, including alternate-ABI rejection.
`zig build test-download-sandbox` requires namespace root, account `nobody`,
working Landlock/seccomp, and permission to change supplementary groups. It uses
disposable `/tmp/rlpm-sandbox-*` roots to check all switch combinations, denied
private-source reads, successful public reads, final permissions, unchanged parent
UID, overlapping child downloads, and prompt completion callbacks. On hosts with
subordinate UID/GID ranges and `newuidmap`/`newgidmap`, it can run without sudo:

```sh
unshare --user --map-auto --map-root-user --setgroups allow zig build test-download-sandbox
```

This namespace-based run passes locally; it does not claim host-root parity.
Live TLS
server combinations and every libcurl protocol are not individually exercised;
the adapter's enabled protocol inventory and a local FTP transfer are checked.
