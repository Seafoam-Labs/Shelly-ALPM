const types = @import("types.zig");

const flag = types.flag;
const optionalArgument = types.optionalArgument;
const stringOption = types.stringOption;

pub const variants = [_]types.Variant{
    .{
        .action = .utility,
        .name = "repository",
        .type_code = 'r',
        .description = "Add, remove, or list pacman.conf ALPM repositories; optionally locally sign a key and refresh databases.",
        .implementation = "Zigalpm.AlpmManager.add_repository / remove_repository / get_repository_names; pacman-key --lsign-key; Zigalpm.AlpmManager.sync",
        .arguments = &.{
            optionalArgument("name", "Repository (database) name, e.g. my-repo"),
            optionalArgument("url", "Server URL; required for --add, e.g. 'https://my-repo.ee/$arch/$repo', ignored for --remove/--list"),
        },
        .options = &.{
            flag("--add", &.{"-a"}, "Add the named repository (requires name and url)"),
            flag("--remove", &.{"-x"}, "Remove the named repository"),
            flag("--list", &.{"-l"}, "List configured repositories"),
            flag("--no-sync", &.{"-n"}, "Skip the final database refresh"),
            stringOption("--lsign-key", &.{"-s"}, "Key to locally sign with pacman-key before adding", false),
        },
    },
};
