const types = @import("types.zig");

const flag = types.flag;
const integerOption = types.integerOption;
const optionalArgument = types.optionalArgument;
const repeatedArgument = types.repeatedArgument;
const requiredArgument = types.requiredArgument;

pub const variants = [_]types.Variant{
    .{
        .action = .search,
        .name = "standard",
        .type_code = 's',
        .description = "Search ALPM repository and installed packages, or Shelly-managed local binary packages. With a package and no source modifier, show exact package details.",
        .implementation = "Zigalpm.AlpmManager.get_installed_packages / get_available_packages; Zigalpm.LocalManager.getInstalledBinaryPackages for --local",
        .arguments = &.{optionalArgument(
            "package",
            "Package name or search term; without a source modifier, an exact name opens package details",
        )},
        .options = &.{
            flag("--repos", &.{"-r"}, "List repositories parsed from pacman.conf and ignore other search modifiers"),
            flag("--available", &.{"-v"}, "Search packages from the configured ALPM synchronization databases"),
            flag("--installed", &.{"-i"}, "Search packages from the local ALPM database"),
            flag("--local", &.{"-l"}, "Search Shelly-managed binary packages installed under /opt/shelly"),
            integerOption("--limit", &.{"-t"}, "Maximum number of search results to return per page"),
            integerOption("--page", &.{"-p"}, "Page number for paginated results"),
            flag("--show-hidden", &.{"-w"}, "Include packages excluded by the configured ignore list"),
            flag("--detail", &.{ "--info", "-d" }, "Show complete metadata for one exact ALPM package name"),
            flag("--group", &.{"-g"}, "List package groups or restrict available packages to the requested group"),
            flag("--explicit", &.{"-e"}, "Shows only explicitly installed pacakges"),
            flag("--depends", &.{"-D"}, "Shows only dependency packages"),
        },
    },
    .{
        .action = .search,
        .name = "aur",
        .type_code = 'a',
        .description = "Search the AUR RPC, fetch exact package PKGBUILDs, append high-confidence standard repository matches, or show complete metadata for one AUR package.",
        .implementation = "Zigalpm.AurManager.searchPackages / fetchPkgbuild; Zigalpm.AlpmManager.get_available_packages when --standard is passed",
        .arguments = &.{repeatedArgument(
            "query",
            1,
            "Search words joined for an AUR RPC query, or exact AUR package names when --pkgbuild or --detail is passed",
        )},
        .options = &.{
            flag("--standard", &.{"-s"}, "Append high-confidence standard ALPM repository matches to the AUR results"),
            flag("--pkgbuild", &.{"-p"}, "Fetch and display the PKGBUILD for each exact AUR package name"),
            flag("--detail", &.{ "--info", "-d" }, "Show complete metadata for one exact AUR package name"),
        },
    },
    .{
        .action = .search,
        .name = "flatpak",
        .type_code = 'f',
        .description = "Search cached AppStream catalogs from every configured system and user Flatpak remote, with local pagination and remote-reference sizes and permissions.",
        .implementation = "Zigalpm.flatpak.AppstreamManager.getAllRemoteCatalogs; Zigalpm.FlatpakManager.get_remote_ref_info_flatpak",
        .arguments = &.{requiredArgument(
            "query",
            "Application name or ID matched against the configured remotes' local AppStream catalogs",
        )},
        .options = &.{
            integerOption("--limit", &.{"-t"}, "Maximum number of search results to return per page"),
            integerOption("--page", &.{"-p"}, "Page number for paginated results"),
        },
    },
};
