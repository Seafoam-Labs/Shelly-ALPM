# `Zigalpm.repo`: repository database maintenance

Native Zig replacement for `repo-add` / `repo-remove`: maintains a repository
database pair (`<name>.db.tar.<ext>` plus its `<name>.files.tar.<ext>` companion) without
shelling out to external tooling. Output follows the upstream formats
(alpm-repo-desc(5), alpm-repo-files(5)), so unmodified clients read it.

`Shelly.Cli.Zig` exposes it as `shelly repo-db add|remove|list|verify`.

## Files

| File | Contents |
| --- | --- |
| `pkginfo.zig` | Package-side primitives: `parse` (`.PKGINFO` text), `readFromPackage` (`.PKGINFO` from an archive), `listFilePaths` (member list behind `%FILES%`). Everything returned is owned by the caller. |
| `database.zig` | The database side: `Database` with `open`, `addPackages`, `removePackages`, `listEntries`, `verifySignatures`, plus the option and summary types. |

Both are exported from `Zigalpm.repo`.

## Behavior

- The files database is derived from the db path and is not optional: both archives are
  extracted, mutated, and republished together. Supported suffixes: `.tar`, `.tar.gz`,
  `.tar.bz2`, `.tar.xz`, `.tar.zst`; others are rejected up front.
- Entry dirs are `<pkgname>-<pkgver>` from `.PKGINFO`, never the filename; `%FILENAME%`
  is the basename of the package path passed on the command line.
- Entries are mutated in a private staging tree and repacked, so nothing is published
  unless every argument succeeded and something changed.
- Publication writes `.tmp.<filename>` next to the target, fsyncs, moves the previous
  generation to `.old` (one generation, with `.old.sig`), renames the tmp into place, and
  refreshes the extension-less `demo.db` / `demo.files` symlinks. A crash leaves the
  previous database plus harmless `.tmp.*` files.
- The lock is an exclusive `flock` on a sidecar `<db>.lock`, never on the database file:
  rotation replaces the database inode, which would silently void a lock held on it. A
  leftover lock file is inert (the kernel releases it on process exit). Contention is
  `LockHeld`; `--wait` blocks instead of failing. `list` and `verify` take no lock.
- `add` embeds a package's detached signature in `%PGPSIG%` when requested and present;
  ASCII-armored signatures and signatures over 16384 bytes are rejected. Publication
  optionally signs both archives; a signing failure warns and publishes unsigned,
  matching upstream.
- `verify` checks each present archive's detached signature with no pinned key ids, so
  only a key GnuPG ultimately trusts counts as verified (plain `gpg --verify` would
  accept a good signature from an untrusted key). A missing signature is skipped with a
  warning; an invalid one exits 1.

## Intentional divergences from upstream

- Locking: sidecar flock instead of the `<db>.lck` pidfile. The exit code 2 contract on
  contention is kept, `--wait` blocks on the lock rather than polling every 3 seconds,
  and a crashed run cannot leave a blocking stale lock (or shadow-block stock `repo-add`).
- `--remove-old-files` deletes replaced package files (and their `.sig`) only after
  successful publication. Upstream deletes during the entry write, so a failed batch can
  lose package files while the database stays unchanged.
- Signatures are embedded by default (`--exclude-sigs` opts out); upstream's
  `--include-sigs` is opt-in.
- `verify` is standalone and resolves paths against the database directory. Upstream
  v7.1.0's verify-only branch builds its candidate paths from an unset variable and
  silently verifies nothing (exit 0).
- No `-n` alias for `--new`: the global `-n` is `--no-confirm`.
- No `.lrz`, `.lz`, `.lz4`, `.lzo`, or `.Z` suffixes and no sqlite `--use-new-db-format`.
- Messages are bare text: progress and results on stdout, warnings and errors on stderr;
  `list` honors the global `--json`.

## Tests

- `zig build repo-db-test` runs the curated set; its filter list in `build.zig` names
  every test that runs. Add new test names there or the step silently skips them.
- `zig build test` runs the full suite.
- Parity against stock tooling is manual: `bash scripts/repo-db-parity.sh` (build
  `Shelly.Cli.Zig` first). It replays the scenario matrix on cloned fixture trees and
  compares member-name sets, member contents byte-for-byte, rotation layout, and exit
  codes. Archive files are never compared as a whole (mtimes and member order are not
  reproducible). Last recorded run: 2026-09-17, 89 PASS / 0 FAIL.
