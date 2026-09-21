# Isolated package builds

`shelly build --isolated` executes the native Shelly package builder in a
fresh, operation-scoped Arch root through `systemd-nspawn`.

The stable JSON schemas, capability probe, and exit behavior for unattended
callers are defined by the [Remora automation contract](remora-automation.md).

The elevated process is a coordinator only. It reviews the host PKGBUILD and
local inputs, materializes only those byte-exact reviewed inputs in the guest,
provisions the guest with Shelly's libalpm-based `shellystrap` helper, and
starts nspawn. The helper runs in a short-lived private mount/PID namespace,
copies the host pacman trust database into the operation root, and keeps its
database, cache, and log under that root. PKGBUILD lifecycle functions run as
the fixed unprivileged `shelly-build` guest account. Private UID mapping is
required, and the command fails closed when systemd cannot provide it.

The container does not bind the host checkout, home directory, package
database, configuration directories, or runtime sockets. Its merged
`shellybuild.conf` uses root-local work, source, log, and artifact paths. The
staged copy must reproduce the review digest before the builder executes it.
Shelly explicitly sets guest traversal directories and the staged executable
to `0755`, and the generated configuration to `0644`, independently of the
coordinator's umask. Existing bootstrap-managed `/usr` and `/usr/local`
permissions are preserved. Writable build directories belong to the guest
UID/GID `1000:1000`; the enclosing host operation directory remains root-owned
`0700`. Reviewed files retain their exact reviewed permissions.
The resulting package's `.BUILDINFO` records the exact package set installed
in the guest. Before export, libalpm loads every candidate archive and Shelly
rejects malformed, duplicate, missing, or unexpected package identities.

Source-signing keys listed in the evaluated `validpgpkeys` are prepared as the
invoking host user before provisioning. Shelly checks the approved digest again,
requests approval for missing keys, and exports only the required public keys.
The guest imports that bundle into its own user keyring before the normal source
signature checks. Host private keys, ownertrust, and GnuPG configuration are not
copied.

`--no-confirm` still declines missing-key imports; approving a review digest does
not approve an import. For unattended callers such as Remora, import the required
fingerprints once with `shelly keyring recv --user FINGERPRINT`, running as the
account that invokes Shelly. Missing keys fail before provisioning and identify
the import commands. Keys in root's keyring or pacman's keyring do not replace
the invoking user's source-signing keys.

The root lives under
`/var/lib/shelly/build-roots/v1/operations/<random-id>/root`, is mode `0700` at
the operation boundary, and is removed after success, failure, or
cancellation. Artifacts are copied out explicitly and returned to the user who
authorized elevation. Existing artifacts are rejected with `--no-overwrite`.

SIGINT and SIGTERM are handled gracefully across the initial privilege
elevation boundary. Sending either signal to the original, unprivileged Shelly
process forwards cancellation to the elevator and elevated coordinator, waits
for the active child tree to stop, and then lets the coordinator unwind its
normal cleanup. If a child does not stop, Shelly escalates to SIGTERM and then
SIGKILL. A cancelled JSON build still emits exactly one result document and
exits with status 130.

Requirements:

- `systemd-nspawn` (provided by Arch's `systemd` package)
- `unshare` (provided by Arch's `util-linux` package) for private provisioning
- an invoking-user-preserving elevator such as sudo, doas, run0, or pkexec

Dependency review refreshes the repositories configured in the host's
`/etc/pacman.conf` into a private temporary database before classifying
dependencies. This lets newly published local repository packages participate
without refreshing or modifying the host package database. The temporary
database is removed after review; provisioning refreshes and verifies the
repositories again using the configured signature policy. Local repository
servers must be readable by the invoking user during review. A built archive
must be published in a configured repository's database to be resolved here.

Build dependency planning uses the PKGBUILD's global `depends`, `makedepends`,
and (unless checks are disabled) `checkdepends`, including the active
architecture's arrays. Dependencies assigned inside `package()` or
`package_<name>()` describe the resulting package and do not add provisioning
targets. This follows makepkg's dependency rules and lets conflicting split
outputs such as PipeWire's JACK implementations be built together. Their
runtime dependencies and `provides` remain in the package metadata. An output
that is also explicitly required as a global build input must still be
installed before the build; its future artifact does not satisfy that input.

Current limitations are deliberately fail-closed:

- `--sign` is rejected because private signing keys are never copied or mounted
  into a build root. Sign exported artifacts as a separate user operation.
- `--sync-deps` supports repository dependencies. If dependency resolution
  finds an AUR-only dependency, the isolated build stops before executing the
  PKGBUILD; building and installing an operation-wide AUR dependency DAG in the
  same root remains required before that case can be enabled safely.
- Root-required integration tests must be run from a real user session because
  Shelly will not guess an artifact owner when invoked directly as root.
- A configured package destination must already exist. Artifact files are
  written through an opened directory handle, assigned to the invoking UID/GID
  before publication, and atomically renamed; the root coordinator will not
  create an arbitrary host destination from elevated configuration.

The nspawn backend invokes Shelly's native builder. It does not invoke or
construct a command for `makepkg`, `makechrootpkg`, or `arch-nspawn`.

During each package function, Shelly prepends a private directory of `chown`,
`chgrp`, `install`, and `mknod` wrappers to the build PATH. External helpers
launched by Meson, make, or `/bin/sh` inherit these commands and share the
package's inode-based ownership journal. Journal writes are locked across
processes; wrapper files and journals are removed when the step ends, including
failure and cancellation. Each split-package member has its own state.

The `mknod` wrapper supports temporary character and block device requests
inside `$pkgdir`, with decimal device numbers and optional octal permissions.
It creates ordinary placeholders, never real devices. This supports helpers
such as FUSE's installer when the recipe subsequently removes its staged
`/dev` directory. Placeholders support existence checks and removal, but do
not emulate device I/O or device-type queries such as `test -c`. A surviving
placeholder, including a renamed or hard-linked one, is rejected before
package assembly instead of being silently shipped as a regular file.

This emulation covers commands resolved through PATH. Absolute command paths,
helpers that replace PATH, and programs making ownership or device syscalls
directly are outside its scope. Lifecycle functions continue to run without
root privileges.

The optional PKGBUILD path is resolved from the current directory. For a
development binary run from `Shelly.Cli.Zig/zig-out/bin`, build this repository
with an explicit recipe path:

```sh
./shelly build --isolated --sync-deps ../../../PKGBUILD
```

Copying only `PKGBUILD` into the binary directory is not sufficient: every
local entry in its `source=()` array must reside beside that copy.

The reviewed-input staging and digest-integrity regressions run in separate
processes under umasks `0022`, `0007`, `0027`, and `0077`. They cover guest
directory traversal permissions, readable configuration creation and replacement,
the private host boundary, exact reviewed bytes and permissions, and rejection
of subsequent input changes. Run them
without elevation with:

```sh
zig build --build-file Shelly.Cli.Zig/build.zig isolated-build-test
```

This target also runs as part of the CLI's `zig build test` and executes every
time, including when the test executable is cached.

The public-key handoff, import approval, and signed-source regressions also run
through the CLI's `test` target, or directly with:

```sh
zig build --build-file Shelly.Cli.Zig/build.zig isolated-source-keys-test
```

Run the root-required smoke test from a normal user session with `jq` and
`sudo` installed:

```sh
Shelly.Cli.Zig/scripts/test-isolated-build.sh
```

The smoke fixture runs all four umasks, applying each mask after sudo elevation
and checking the coordinator's effective mask. Inside real nspawn it verifies
UID/GID 1000, root-owned traversal-directory and executable permissions,
configuration readability and destinations, and build-directory ownership.
A host supervisor checks the operation's `0700` boundary before allowing the
guest to finish, then verifies operation-root cleanup.

Each case also reviews a group-writable (`0660`) local source, passes the
returned digest through `--review-digest`, checks the staged input in the guest,
and verifies that the package artifact is exported with the invoking user's UID
and GID. Standard purge targets must be absent when stripping is disabled.
Set `SHELLY_BIN` to test an already-built CLI. The script authenticates sudo
interactively when run from a terminal; unattended runs require an existing
sudo credential and exit `77` (skipped) if authentication is unavailable.

Cancellation across the elevation boundary has a rootless integration fixture
that uses a deterministic fake elevator:

```sh
Shelly.Cli.Zig/scripts/test-elevation-cancellation.sh
```

The full fixture requires a working invoking-user-preserving elevator and the
same privileges as a real isolated build. It sends SIGINT and SIGTERM only to
the original Shelly process and verifies that nspawn descendants and the
operation root are gone. When sudo is selected, the fixture authenticates once
in the foreground before starting Shelly as the background process under test:

```sh
Shelly.Cli.Zig/scripts/test-isolated-cancellation.sh
```

Native build PATH additions from `[build] extra_path` in `shellybuild.conf` are
preserved in the generated guest configuration. They refer to paths inside the
guest and must exist there; they do not create host bind mounts. A host-only
custom toolchain path must be removed from the effective configuration before
an isolated build. See [build PATH configuration](shellybuild.conf.md#build-executable-search-path).
