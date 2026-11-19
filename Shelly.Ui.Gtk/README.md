# Shelly GTK UI

The GTK 4, GLib, GObject, GIO, and Pango bindings come from the pinned
`ghostty-gobject` release artifact in `build.zig.zon`. Zig downloads and
verifies the generated bindings automatically; they are not committed to this
repository.

## Memory leak checking with Valgrind

Shelly allocates through `std.heap.c_allocator` (glibc malloc), so Valgrind's
memcheck tool tracks both the Zig-side allocations and everything GLib/GTK
allocates. Note that memcheck **only instruments the C allocator**:
`page_allocator` and `std.testing.allocator` traffic is invisible to it.

Canonical invocation (software rendering keeps driver noise down):

```bash
GSK_RENDERER=cairo zig build valgrind -Dskip-background-services=true -- --page firmware
```

Arguments after `--` go to the **app**, not to valgrind. Extra valgrind flags
are passed with `-Dvalgrind-args` (whitespace-separated, no shell quoting —
fine for flags, not for values containing spaces):

```bash
# suppression audit (prints used_suppression lines)
zig build valgrind -Dvalgrind-args="-s" -Dskip-background-services=true -- --page firmware
# indirect-leak deep dive
zig build valgrind -Dvalgrind-args="--show-leak-kinds=all" -Dskip-background-services=true -- --page firmware
```

The equivalent manual invocation on the built binary:

```bash
valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite,possible \
    --errors-for-leak-kinds=definite --track-origins=yes --num-callers=50 \
    --gen-suppressions=all --error-exitcode=42 \
    --suppressions=valgrind/glib-gtk.supp --log-file=valgrind-%p.log \
    zig-out/bin/Shelly_Ui_Gtk --page firmware
```

### CPU requirement on AVX-512 hosts

Valgrind 3.25.1 has no EVEX (AVX-512) decoder, and `native` or
`-Dcpu=x86_64_v4` Zig builds emit EVEX instructions even in compiler_rt
memset/memcpy, so the run dies with SIGILL before any leak output.
`x86_64_v3` is the safe ceiling. The `valgrind` step refuses AVX-512 targets
up front with instructions; on such hosts rerun with `-Dcpu=x86_64_v3`.
Plain `zig build`, `run` and `test` with the native target are unaffected.

### Notes

- Background threads (icon download, tray) should be done before you quit,
  otherwise their still-live allocations appear in the report. To keep them
  out of a leak-checking session entirely, pass
  `-Dskip-background-services=true`.
- The step gates on **definite leaks only**
  (`--errors-for-leak-kinds=definite`): `--error-exitcode=42` fails the build
  when definitely-lost blocks remain; indirect leaks are never errors.
  Exit 0 is a regression signal.
- New noise comes with paste-able suppression stanzas
  (`--gen-suppressions=all`); add reviewed ones to `valgrind/glib-gtk.supp`.
- Every process gets its own `valgrind-<pid>.log`; spawned helpers produce
  tiny stub logs. Pick the main log by its million-scale `total heap usage`
  alloc count (stubs have ~2k), the absence of a
  `Process terminating with default action of signal 15` line, and a
  `Parent PID:` that differs from the file-name PID (equal ⇒ child process).
- The logs contain a flood of harmless `DWARF2 reader` warnings; filter them
  with `grep -v 'DWARF2 reader'` (`-q` does not suppress them under memcheck).

### Running the tests under Valgrind

```bash
GSK_RENDERER=cairo zig build valgrind-test -Dcpu=x86_64_v3   # -Dcpu only needed on AVX-512 hosts
```

Runs the test suite (the libc+GTK-linked test binary) under memcheck with the
same gate as the app step; logs land in `valgrind-test-<pid>.log`. The cairo
renderer avoids Vulkan driver probing noise in the widget tests. Limits:

- Memcheck only sees `c_allocator` traffic. Most tests use
  `std.testing.allocator` (a SafeAllocator, invisible to memcheck), so Zig's
  own leak check under plain `zig build test` stays the primary detector.
- Coverage is deterministic, but GTK-init noise depends on display presence;
  widget tests skip themselves when no display is available.
- Tests spin up local HTTP servers; the memcheck slowdown can cause timeout
  flakes. Keep the default Debug optimize level.
- Test filtering is compile-time only (`-Dtest-filter=...`); the test binary
  rejects runtime `--test-filter` arguments, so the step passes no app args.
