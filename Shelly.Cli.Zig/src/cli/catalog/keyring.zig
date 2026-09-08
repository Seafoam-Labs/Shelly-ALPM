const types = @import("types.zig");

const repeatedArgument = types.repeatedArgument;
const stringOption = types.stringOption;
const voidOption = types.voidOption;

pub const variants = [_]types.Variant{
    .{
        .action = .keyring,
        .name = "init",
        .type_code = 'i',
        .description = "Initialize the package-signing keyring.",
        .implementation = "shelly-key --init",
    },
    .{
        .action = .keyring,
        .name = "list",
        .type_code = 'l',
        .description = "List package-signing keys.",
        .implementation = "shelly-key --list-keys",
    },
    .{
        .action = .keyring,
        .name = "refresh",
        .type_code = 'r',
        .description = "Refresh package-signing keys from the configured keyserver.",
        .implementation = "shelly-key --refresh-keys",
    },
    .{
        .action = .keyring,
        .name = "lsign",
        .type_code = 's',
        .description = "Locally sign one or more package-signing keys.",
        .implementation = "shelly-key --lsign-key for each requested key",
        .arguments = &.{repeatedArgument(
            "keys",
            1,
            "One or more key identifiers",
        )},
    },
    .{
        .action = .keyring,
        .name = "populate",
        .type_code = 'p',
        .description = "Populate the package-signing keyring with default or named distribution keys.",
        .implementation = "shelly-key --populate",
        .arguments = &.{repeatedArgument(
            "keys",
            0,
            "Distribution keyring names; omit to populate the defaults",
        )},
    },
    .{
        .action = .keyring,
        .name = "recv",
        .type_code = 'v',
        .description = "Receive keys into the package-signing keyring or the current user's source-signing keyring.",
        .implementation = "shelly-key --recv-keys, or shelly-key --user --recv-keys with --user",
        .arguments = &.{repeatedArgument(
            "keys",
            1,
            "One or more key identifiers",
        )},
        .options = &.{
            stringOption(
                "--keyserver",
                &.{},
                "Keyserver from which to receive keys",
                false,
            ),
            voidOption(
                "--user",
                &.{},
                "Import into the current user's GnuPG keyring for PKGBUILD source verification",
                false,
                false,
            ),
        },
    },
};
