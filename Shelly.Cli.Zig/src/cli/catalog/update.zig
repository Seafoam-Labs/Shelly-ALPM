const types = @import("types.zig");

const flag = types.flag;
const repeatedArgument = types.repeatedArgument;
const requiredArgument = types.requiredArgument;

pub const variants = [_]types.Variant{
    .{
        .action = .update,
        .name = "standard",
        .type_code = 's',
        .description = "Update only the named installed ALPM packages after an explicit partial-upgrade warning and confirmation.",
        .implementation = "Zigalpm.AlpmManager.update_packages",
        .arguments = &.{repeatedArgument(
            "packages",
            0,
            "One or more installed repository package names to update; partial upgrades are unsupported by Arch Linux and require confirmation",
        )},
    },
    .{
        .action = .update,
        .name = "aur",
        .type_code = 'a',
        .description = "Fetch, review, rebuild, and reinstall only the named AUR packages.",
        .implementation = "Zigalpm.AurManager.updatePackages",
        .arguments = &.{repeatedArgument(
            "packages",
            0,
            "One or more AUR package names to rebuild and reinstall",
        )},
        .options = &.{
            flag("--check", &.{}, "Run each PKGBUILD check() function during the rebuild"),
            flag("--no-check", &.{}, "Skip each PKGBUILD check() function during the rebuild"),
            flag("--sign", &.{}, "Sign rebuilt packages with GPG"),
            flag("--nosign", &.{}, "Skip signing rebuilt packages"),
        },
    },
    .{
        .action = .update,
        .name = "flatpak",
        .type_code = 'f',
        .description = "Update one installed Flatpak application or runtime in its existing user or system installation.",
        .implementation = "Zigalpm.FlatpakManager.update_installed_flatpak",
        .arguments = &.{requiredArgument(
            "package",
            "Installed Flatpak application/runtime ID or unambiguous friendly name",
        )},
    },
};
