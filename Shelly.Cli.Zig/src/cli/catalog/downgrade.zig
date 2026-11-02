const types = @import("types.zig");

const flag = types.flag;
const repeatedArgument = types.repeatedArgument;
const stringOption = types.stringOption;

pub const variants = [_]types.Variant{
    .{
        .action = .downgrade,
        .name = "standard",
        .default_for_action = true,
        .description = "Discover cached and archived versions of one or more installed ALPM packages, select a version for each, and install them together as a downgrade.",
        .implementation = "PackageManager.Manager.get_single_installed_package / PackageManager.Manager.ArchiveManager.find_candidates / install_candidates / PackageManager.Manager.ignore_packages",
        .arguments = &.{repeatedArgument(
            "packages",
            1,
            "Installed ALPM packages to downgrade",
        )},
        .options = &.{
            flag("--oldest", &.{"-o"}, "Select the oldest available version for every package instead of prompting or selecting the newest version"),
            flag("--ignore", &.{"-i"}, "Add every downgraded package to IgnorePkg after a successful downgrade"),
            flag("--list-options", &.{"-l"}, "List cached and archived versions without installing one"),
            stringOption("--target", &.{"-t"}, "Install an exact version-release or package filename (single package only)", false),
        },
    },
};
