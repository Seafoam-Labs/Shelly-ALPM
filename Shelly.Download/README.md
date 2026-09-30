# Shelly.Download

Shared Zig 0.16 transport and bounded queue extracted from
`Shelly.PackageManager/src/shared/downloader.zig` and `download_queue.zig`.
Both PackageManager and RLPM consume the same module; backend callbacks and
verification stay in those consumers. The existing `.succes` result spelling
is retained for compatibility.

`DownloadSession` owns a reusable HTTP connection pool. `CoreDownloader` accepts
an allocator, `std.Io`, transfer configuration, events and cancellation callback.
Default partial files are unique and cleaned on failure. An explicit, caller-owned
`resume_path` enables retained partials; callers must serialize access to it.
Callers validate integrity before treating transport output as a package.

HTTP/HTTPS use Shelly.Http; local files and HTTP-date parsing use Zig directly.
`Curl.zig` calls libcurl for its other enabled protocols and fallback for unsupported
proxy/redirect schemes. The adapter's file I/O, callbacks and ownership are Zig.
`Shelly_Download_Worker.run` applies Linux Landlock/seccomp through `Sandbox.zig`
and changes credentials in its own process. Shelly invokes it through the reserved
`--internal-download-worker` mode of the CLI; no separate executable is installed.
Account lookup retains libc/NSS integration. Its protocol is internal to the
matching build; RLPM owns its parent-side lifecycle. Embedding applications use
RLPM's shared early dispatcher or configure an absolute `worker_executable`.
There are no C implementation files in this module.

Run `zig build test` for local/file transport and queue fixtures. Loopback sockets
must be available. `zig build test-sandbox` checks actual Landlock/seccomp
enforcement in disposable child processes without root; kernel support is
required. `check-sandbox` compiles that fixture without running it. The privileged
UID/GID integration fixture remains in RLPM. Build dependencies are libc, libcurl,
Shelly.Http and Shelly.Diagnostics; libseccomp is no longer needed.
The syscall deny list follows the pinned
pacman source, Copyright 2021–2025 Pacman Development Team, GPL-2.0-or-later;
see [COPYING](COPYING).
