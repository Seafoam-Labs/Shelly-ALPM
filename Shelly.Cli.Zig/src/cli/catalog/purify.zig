const types = @import("types.zig");

const flag = types.flag;
const optionalIntegerOptionWithDefault = types.optionalIntegerOptionWithDefault;

pub const variants = [_]types.Variant{
    .{
        .action = .purify,
        .name = "standard",
        .type_code = 's',
        .description = "Plan corrupted archives, optional orphan cleanup, and optional cache retention cleanup; show the targets, then confirm before changing ALPM or cache state.",
        .implementation = "Zigalpm.AlpmManager.purify / Zigalpm.alpm.CacheManager",
        .options = &.{
            flag("--dry-run", &.{"-d"}, "Show the cleanup plan without changing packages"),
            flag("--orphans", &.{"-o"}, "Include orphaned packages"),
            flag("--aur-cache", &.{}, "Delete all built AUR package archives and matching signatures from Shelly's cache"),
            .{
                .name = "--aur-cache-root",
                .type = "string",
                .minimumArity = 1,
                .hidden = true,
                .description = "Preserve the invoking user's AUR cache path across elevation",
            },
            optionalIntegerOptionWithDefault(
                "--cache",
                &.{"-c"},
                "Remove older cached package versions while retaining this many versions",
                3,
            ),
        },
    },
    .{
        .action = .purify,
        .name = "flatpak",
        .type_code = 'f',
        .description = "Plan unused dependency cleanup across system and user Flatpak installations, then show and confirm the targets.",
        .implementation = "Zigalpm.FlatpakManager.remove_unused_dependencies",
    },
};
