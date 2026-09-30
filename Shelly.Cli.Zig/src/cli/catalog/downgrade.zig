const types = @import("types.zig");

const flag = types.flag;
const optionalArgument = types.optionalArgument;
const stringOption = types.stringOption;

pub const variants = [_]types.Variant{
    .{
        .action = .downgrade,
        .name = "standard",
        .default_for_action = true,
        .description = "Discover cached and archived versions of an installed ALPM package, select one, and install it as a downgrade.",
        .implementation = "PackageManager.Manager.get_single_installed_package / PackageManager.Manager.ArchiveManager.find_candidates / install_candidate / PackageManager.Manager.ignore_package",
        .arguments = &.{optionalArgument(
            "package",
            "Installed ALPM package to downgrade",
        )},
        .options = &.{
            flag("--oldest", &.{"-o"}, "Select the oldest available version instead of prompting or selecting the newest version"),
            flag("--ignore", &.{"-i"}, "Add the package to IgnorePkg after a successful downgrade"),
            flag("--list-options", &.{"-l"}, "List cached and archived versions without installing one"),
            stringOption("--target", &.{"-t"}, "Install an exact version-release or package filename", false),
        },
    },
};
