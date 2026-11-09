//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
pub const sudo_terminal = @import("services/sudo_terminal.zig");
pub const sudo_session = @import("services/sudo_session.zig");
pub const model = @import("model.zig");
/// Exported so consumers share the same runtime globals (io, environ_map)
/// that ShellyCli depends on. Do not import runtime.zig directly from
/// another module — that would create a second copy of the globals.
pub const runtime = @import("runtime.zig");

// Register new source modules here; main.zig has its own executable suite.
test "all source modules are included" {
    std.testing.refAllDecls(@import("commands.zig"));
    std.testing.refAllDecls(@import("model.zig"));
    std.testing.refAllDecls(@import("models/appimage.zig"));
    std.testing.refAllDecls(@import("models/aur_model.zig"));
    std.testing.refAllDecls(@import("models/flatpak.zig"));
    std.testing.refAllDecls(@import("models/flatpak_model.zig"));
    std.testing.refAllDecls(@import("models/operation_model.zig"));
    std.testing.refAllDecls(@import("models/packages.zig"));
    std.testing.refAllDecls(@import("models/packages_model.zig"));
    std.testing.refAllDecls(@import("models/pkgbuild.zig"));
    std.testing.refAllDecls(@import("models/settings.zig"));
    std.testing.refAllDecls(@import("models/settings_model.zig"));
    std.testing.refAllDecls(@import("models/sync.zig"));
    std.testing.refAllDecls(@import("models/updates_model.zig"));
    std.testing.refAllDecls(@import("runtime.zig"));
    std.testing.refAllDecls(@import("services/atoll_catalog.zig"));
    std.testing.refAllDecls(@import("services/flatpak_images.zig"));
    std.testing.refAllDecls(@import("services/settings.zig"));
    std.testing.refAllDecls(@import("services/shelly_cli.zig"));
    std.testing.refAllDecls(@import("services/shelly_operation.zig"));
    std.testing.refAllDecls(@import("services/ui_decode.zig"));
    std.testing.refAllDecls(sudo_terminal);
    std.testing.refAllDecls(sudo_session);
    std.testing.refAllDecls(@import("views/aur_view.zig"));
    std.testing.refAllDecls(@import("views/border.zig"));
    std.testing.refAllDecls(@import("views/detail_fields.zig"));
    std.testing.refAllDecls(@import("views/detail_format.zig"));
    std.testing.refAllDecls(@import("views/flatpak_view.zig"));
    std.testing.refAllDecls(@import("views/footer_view.zig"));
    std.testing.refAllDecls(@import("views/help_view.zig"));
    std.testing.refAllDecls(@import("views/image_view.zig"));
    std.testing.refAllDecls(@import("views/operation_view.zig"));
    std.testing.refAllDecls(@import("views/packages_view.zig"));
    std.testing.refAllDecls(@import("views/pkgbuild_view.zig"));
    std.testing.refAllDecls(@import("views/settings_view.zig"));
    std.testing.refAllDecls(@import("views/source_highlight.zig"));
    std.testing.refAllDecls(@import("views/split_layout.zig"));
    std.testing.refAllDecls(@import("views/styles.zig"));
    std.testing.refAllDecls(@import("views/updates_view.zig"));
    std.testing.refAllDecls(@import("xdg_paths.zig"));
}
