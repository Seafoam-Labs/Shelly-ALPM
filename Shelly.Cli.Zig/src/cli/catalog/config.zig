const types = @import("types.zig");

const integerArgument = types.integerArgument;
const requiredArgument = types.requiredArgument;

pub const variants = [_]types.Variant{
    .{
        .action = .config,
        .name = "appimage",
        .description = "Edit an installed AppImage's environment overrides.",
        .implementation = "Zigalpm.AppImageManager.configureEnvironment",
        .arguments = &.{requiredArgument("name", "Exact installed AppImage name")},
        .options = &.{
            types.stringOption("--set-env", &.{}, "Add or replace one KEY=value environment override", false),
            types.stringOption("--unset-env", &.{}, "Remove one environment override by key", false),
            types.flag("--clear-env", &.{}, "Remove all environment overrides"),
            types.stringOption("--replace-env", &.{}, "Replace all overrides with a JSON object of string values", false),
        },
    },
    .{
        .action = .config,
        .name = "list",
        .default_for_action = true,
        .description = "List every Shelly configuration value.",
        .implementation = "config_manager.Manager.read",
    },
    .{
        .action = .config,
        .name = "get",
        .type_code = 'g',
        .description = "Read a Shelly configuration value.",
        .implementation = "config_manager.Manager.get",
        .arguments = &.{requiredArgument(
            "key",
            "Configuration property name",
        )},
    },
    .{
        .action = .config,
        .name = "set",
        .type_code = 's',
        .description = "Set a Shelly configuration value.",
        .implementation = "config_manager.Manager.update",
        .arguments = &.{
            requiredArgument("key", "Configuration property name"),
            requiredArgument("value", "New configuration value"),
        },
    },
    .{
        .action = .config,
        .name = "reset",
        .type_code = 'r',
        .description = "Reset Shelly configuration to native defaults.",
        .implementation = "config_manager.Manager.reset",
    },
    .{
        .action = .config,
        .name = "parallel",
        .type_code = 'p',
        .description = "Set Shelly's parallel download count.",
        .implementation = "config_manager.Manager.update(\"ParallelDownloadCount\", value)",
        .arguments = &.{integerArgument(
            "downloadCount",
            "Maximum number of parallel downloads",
        )},
    },
};
