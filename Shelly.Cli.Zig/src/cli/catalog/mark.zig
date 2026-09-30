const types = @import("types.zig");

const flag = types.flag;
const repeatedArgument = types.repeatedArgument;
const requiredArgument = types.requiredArgument;

pub const variants = [_]types.Variant{
    .{
        .action = .mark,
        .name = "ignore",
        .type_code = 'g',
        .description = "List or modify packages excluded from ALPM upgrades through IgnorePkg.",
        .implementation = "PackageManager.Manager ignore_package(s) / unignore_package(s) / get_ignored_packages",
        .arguments = &.{repeatedArgument(
            "packages",
            0,
            "Package names to add to or remove from IgnorePkg",
        )},
        .options = &.{
            flag("--list", &.{"-l"}, "List packages in IgnorePkg"),
            flag("--add", &.{"-a"}, "Add packages to IgnorePkg"),
            flag("--remove", &.{"-r"}, "Remove packages from IgnorePkg"),
            flag("--clear", &.{"-c"}, "Clear IgnorePkg"),
        },
    },
    .{
        .action = .mark,
        .name = "hold",
        .type_code = 'o',
        .description = "List or modify packages protected from removal through HoldPkg.",
        .implementation = "PackageManager.Manager hold_package(s) / unhold_package(s) / get_held_packages",
        .arguments = &.{repeatedArgument(
            "packages",
            0,
            "Package names to add to or remove from HoldPkg",
        )},
        .options = &.{
            flag("--list", &.{"-l"}, "List packages in HoldPkg"),
            flag("--add", &.{"-a"}, "Add packages to HoldPkg"),
            flag("--remove", &.{"-r"}, "Remove packages from HoldPkg"),
            flag("--clear", &.{"-c"}, "Clear HoldPkg except for Shelly's protected entry"),
        },
    },
    .{
        .action = .mark,
        .name = "explicit",
        .type_code = 'e',
        .description = "Mark an installed ALPM package as explicitly installed.",
        .implementation = "PackageManager.Manager.update_package_reason(.Explicit)",
        .arguments = &.{requiredArgument(
            "package",
            "Installed package whose reason should be changed",
        )},
    },
    .{
        .action = .mark,
        .name = "dependency",
        .type_code = 'd',
        .description = "Mark an installed ALPM package as installed as a dependency.",
        .implementation = "PackageManager.Manager.update_package_reason(.Dependency)",
        .arguments = &.{requiredArgument(
            "package",
            "Installed package whose reason should be changed",
        )},
    },
};
