const types = @import("types.zig");

const flag = types.flag;
const optionalArgument = types.optionalArgument;
const requiredArgument = types.requiredArgument;

pub const variants = [_]types.Variant{
    .{
        .action = .run,
        .name = "flatpak",
        .type_code = 'f',
        .description = "Launch an installed Flatpak application, stop it with --kill, or list running instances with `run flatpak list`.",
        .implementation = "PackageManager.FlatpakManager.launch_flatpak / kill_flatpak / get_running_instances_flatpak",
        .arguments = &.{optionalArgument(
            "package",
            "Flatpak application ID or friendly name; use `list` to show running applications",
        )},
        .options = &.{
            flag("--kill", &.{"-k"}, "Stop the selected application instead of launching it"),
            flag("--list", &.{"-l"}, "List running Flatpak applications and process identifiers"),
        },
    },
    .{
        .action = .run,
        .name = "appimage",
        .type_code = 'i',
        .description = "Launch an installed AppImage, or stop it with --kill.",
        .implementation = "Native AppImage resolution, process spawning, tracking, and signaling",
        .arguments = &.{requiredArgument(
            "package",
            "Installed AppImage name or path",
        )},
        .options = &.{flag(
            "--kill",
            &.{"-k"},
            "Stop the selected application instead of launching it",
        )},
    },
};
