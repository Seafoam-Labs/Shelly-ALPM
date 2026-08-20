# Shelly GTK UI

The GTK 4, GLib, GObject, GIO, and Pango bindings come from the pinned
`ghostty-gobject` release artifact in `build.zig.zon`. Zig downloads and
verifies the generated bindings automatically; they are not committed to this
repository.

## Memory leak checking with Valgrind

Shelly allocates through `std.heap.c_allocator` (glibc malloc), so Valgrind's
memcheck tool tracks both the Zig-side allocations and everything
GLib/GTK allocates.

```bash
zig build valgrind
```

```bash
valgrind --tool=memcheck --leak-check=full --show-leak-kinds=all \
    --track-origins=yes --num-callers=50 \
    --suppressions=valgrind/glib-gtk.supp \
    zig-out/bin/Shelly_Ui_Gtk
```

### Environment requirements

Unable to run on cachyos, use base arch with unptomized glibc as valgrind has issues with zen4 extended 
instruction sets when building also may be required:

```bash
zig build valgrind -Dcpu=x86_64
```

Notes:

- Background threads (icon download, tray) should be done before you quit,
  otherwise their still-live allocations appear in the report. To keep them
  out of a leak-checking session entirely, pass
  `-Dskip-background-services=true`, e.g.
  `zig build valgrind -Dcpu=x86_64_v3 -Dskip-background-services=true`.
- `--error-exitcode=42` makes `zig build valgrind` fail when definite or
  indirect leaks are found, so it can be used in checks.
- Repeated noise not covered by the suppression file can be captured with
  `--gen-suppressions=all` and pasted into `valgrind/glib-gtk.supp`.
