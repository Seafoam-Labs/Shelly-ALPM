// flatpak_include.h
//
// Wrapper header used to generate the committed static binding `flatpak.zig`.
//
// Regenerate with (run once, from this directory):
//
//   zig translate-c -lc $(pkg-config --cflags flatpak) flatpak_include.h > flatpak.zig
//
// then re-apply the manual fixup noted at the top of flatpak.zig.
//
// The `_Pragma` neutralization below works around a Zig 0.16 translate-c (arocc)
// limitation: GLib's deprecation macros (e.g. G_GNUC_BEGIN_IGNORE_DEPRECATIONS)
// expand to `_Pragma("GCC diagnostic push")`, which the arocc-based translator
// cannot yet parse. Defining `_Pragma` away lets translation proceed; it only
// suppresses compiler diagnostic pragmas, which are irrelevant to bindings.
#define _Pragma(x)

#include <flatpak/flatpak.h>
