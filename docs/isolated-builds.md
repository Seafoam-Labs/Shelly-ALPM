# Isolated package builds

`shelly build --isolated` executes the native Shelly package builder in a
fresh, operation-scoped Arch root through `systemd-nspawn`.

The elevated process is a coordinator only. It reviews the host PKGBUILD and
local inputs, materializes only those byte-exact reviewed inputs in the guest,
provisions the guest, and starts nspawn. PKGBUILD lifecycle functions run as
the fixed unprivileged `shelly-build` guest account. Private UID mapping is
required, and the command fails closed when systemd cannot provide it.

The container does not bind the host checkout, home directory, package
database, configuration directories, or runtime sockets. Its merged
`shellybuild.conf` uses root-local work, source, log, and artifact paths. The
staged copy must reproduce the review digest before the builder executes it.
The resulting package's `.BUILDINFO` records the exact package set installed
in the guest. Before export, libalpm loads every candidate archive and Shelly
rejects malformed, duplicate, missing, or unexpected package identities.

The root lives under
`/var/lib/shelly/build-roots/v1/operations/<random-id>/root`, is mode `0700` at
the operation boundary, and is removed after success, failure, or
cancellation. Artifacts are copied out explicitly and returned to the user who
authorized elevation. Existing artifacts are rejected with `--no-overwrite`.

Requirements:

- `systemd-nspawn` (provided by Arch's `systemd` package)
- `pacstrap` (provided by `arch-install-scripts`) for fresh-root provisioning
- an invoking-user-preserving elevator such as sudo, doas, run0, or pkexec

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

The optional PKGBUILD path is resolved from the current directory. For a
development binary run from `Shelly.Cli.Zig/zig-out/bin`, build this repository
with an explicit recipe path:

```sh
./shelly build --isolated --sync-deps ../../../PKGBUILD
```

Copying only `PKGBUILD` into the binary directory is not sufficient: every
local entry in its `source=()` array must reside beside that copy.

Run the root-required smoke test from a normal user session with:

```sh
Shelly.Cli.Zig/scripts/test-isolated-build.sh
```
