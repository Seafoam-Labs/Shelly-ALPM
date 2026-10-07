const types = @import("types.zig");

const booleanOptionWithDefault = types.booleanOptionWithDefault;
const flag = types.flag;
const repeatedArgument = types.repeatedArgument;
const requiredArgument = types.requiredArgument;

pub const variants = [_]types.Variant{
    .{
        .action = .remove,
        .name = "standard",
        .type_code = 's',
        .alias_type_codes = &.{'S'},
        .description = "Remove installed ALPM packages or Shelly-managed local binaries, with optional dependency and configuration cleanup.",
        .implementation = "PackageManager.Manager.remove_packages / LocalManager.removeBinaryPackages",
        .arguments = &.{repeatedArgument(
            "packages",
            0,
            "Packages to remove",
        )},
        .options = &.{
            booleanOptionWithDefault("--cascade", &.{"-c"}, "Remove dependencies that are no longer needed", true),
            flag("--no-cascade", &.{}, "Keep dependencies that become unneeded after removal"),
            flag("--opt-deps", &.{"-o"}, "Remove unused optional dependencies installed with the packages"),
            flag("--ripple", &.{"-i"}, "Remove packages that depend on the removed packages"),
            flag("--remove-config", &.{}, "Remove configuration associated with the removed package"),
            flag("--local", &.{"-l"}, "Remove Shelly-managed local binaries"),
            flag("--force", &.{"-f"}, "Force local binary removal"),
        },
    },
    .{
        .action = .remove,
        .name = "appimage",
        .type_code = 'i',
        .alias_type_codes = &.{'I'},
        .description = "Remove an installed AppImage and optionally delete its associated configuration.",
        .implementation = "PackageManager.AppImageManager.removeAppImage",
        .arguments = &.{requiredArgument(
            "appimage",
            "Installed AppImage to remove",
        )},
        .options = &.{flag(
            "--remove-config",
            &.{},
            "Remove configuration associated with the removed package",
        )},
    },
    .{
        .action = .remove,
        .name = "mise",
        .type_code = 'm',
        .description = "Remove mise tools from the configuration file that declares them and prune their unused installs. Runs as the invoking user.",
        .implementation = "PackageManager.MiseManager.remove",
        .arguments = &.{repeatedArgument(
            "tools",
            1,
            "mise tools to remove",
        )},
    },
    .{
        .action = .remove,
        .name = "aur",
        .type_code = 'a',
        .alias_type_codes = &.{'A'},
        .description = "Remove installed AUR packages and optionally remove dependent or optional packages through ALPM.",
        .implementation = "PackageManager.AurManager.removePackages",
        .arguments = &.{repeatedArgument(
            "packages",
            0,
            "Packages to remove",
        )},
        .options = &.{
            flag("--cascade", &.{"-c"}, "Remove dependencies that are no longer needed"),
            flag("--opt-deps", &.{"-o"}, "Remove unused optional dependencies installed with the packages"),
            flag("--ripple", &.{"-i"}, "Remove packages that depend on the removed packages"),
        },
    },
    .{
        .action = .remove,
        .name = "flatpak",
        .type_code = 'f',
        .alias_type_codes = &.{'F'},
        .description = "Remove an installed Flatpak application or runtime, with optional unused dependency and configuration cleanup.",
        .implementation = "PackageManager.FlatpakManager.find_installed_flatpak / uninstall_flatpak",
        .arguments = &.{requiredArgument(
            "package",
            "Installed Flatpak application or runtime ID",
        )},
        .options = &.{
            flag("--remove-unused", &.{"-r"}, "Remove newly unused Flatpak dependencies"),
            flag("--remove-config", &.{}, "Remove configuration associated with the removed package"),
        },
    },
};
