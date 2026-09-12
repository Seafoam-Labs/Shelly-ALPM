const types = @import("types.zig");

const flag = types.flag;
const optionalArgument = types.optionalArgument;
const optionalArgumentWithChoices = types.optionalArgumentWithChoices;

pub const variants = [_]types.Variant{
    .{
        .action = .list,
        .name = "standard",
        .type_code = 's',
        .description = "List packages installed in the local ALPM database, including ignored packages, with optional install-reason filters.",
        .implementation = "Zigalpm.AlpmManager.get_installed_packages",
        .options = &.{
            flag("--show-hidden", &.{"-w"}, "Accepted for compatibility; ignored packages are always included"),
            flag("--explicitOnly", &.{"-e"}, "List explicitly installed packages only"),
            flag("--dependencyOnly", &.{"-d"}, "List dependency-installed packages only"),
            flag("--required-by", &.{}, "Include packages that directly require each listed package"),
            flag("--optional-for", &.{}, "Include packages that directly use each listed package optionally"),
        },
    },
    .{
        .action = .list,
        .name = "appimage",
        .type_code = 'i',
        .alias_type_codes = &.{'I'},
        .description = "List installed AppImages.",
        .implementation = "Zigalpm.AppImageManager.getAppImagesFromLocalDb",
    },
    .{
        .action = .list,
        .name = "aur",
        .type_code = 'a',
        .alias_type_codes = &.{'A'},
        .description = "List installed foreign packages tracked as AUR packages.",
        .implementation = "Zigalpm.AurManager.getInstalledPackages",
        .options = &.{
            flag("--show-hidden", &.{}, "Include hidden packages"),
            flag("--explicitOnly", &.{"-e"}, "List explicitly installed packages only"),
            flag("--dependencyOnly", &.{"-d"}, "List dependency-installed packages only"),
            flag("--required-by", &.{}, "Include packages that directly require each listed package"),
            flag("--optional-for", &.{}, "Include packages that directly use each listed package optionally"),
        },
    },
    .{
        .action = .list,
        .name = "flatpak",
        .type_code = 'f',
        .alias_type_codes = &.{'F'},
        .description = "List installed Flatpaks, configured system and user remotes, or cached AppStream JSON for one or every remote.",
        .implementation = "Zigalpm.FlatpakManager.list_installed_applications / get_remote_appstream / get_all_remote_appstreams",
        .arguments = &.{
            optionalArgumentWithChoices(
                "source",
                "Use remote to return cached remote AppStream applications instead of installed Flatpaks",
                &.{"remote"},
            ),
            optionalArgument(
                "query",
                "Remote name, or all; omit it to list the configured system and user remotes",
            ),
        },
    },
};
