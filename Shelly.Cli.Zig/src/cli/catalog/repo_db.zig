const types = @import("types.zig");

const flag = types.flag;
const repeatedArgument = types.repeatedArgument;
const requiredArgument = types.requiredArgument;
const stringOption = types.stringOption;

const database_argument = "Path to the <name>.db.tar.<ext> database";

pub const variants = [_]types.Variant{
    .{
        .action = .repo_db,
        .name = "add",
        .type_code = 'a',
        .description = "Add package archives to a pacman repository database (repo-add).",
        .implementation = "Zigalpm.repo.Database.addPackages",
        .arguments = &.{
            requiredArgument("database", database_argument),
            repeatedArgument("packages", 1, "Package archive paths to add"),
        },
        .options = &.{
            flag("--new", &.{}, "Skip packages whose identical entry already exists"),
            flag("--prevent-downgrade", &.{"-p"}, "Skip packages older than the database entry"),
            flag("--remove-old-files", &.{"-R"}, "Delete replaced package files (and .sig) after publishing"),
            flag("--exclude-sigs", &.{}, "Do not embed existing <pkg>.sig signatures"),
            flag("--wait", &.{"-w"}, "Block until the database lock is free"),
            flag("--quiet", &.{"-q"}, "Do not print per-package adding lines"),
            flag("--sign", &.{"-s"}, "Sign each published database archive with gpg"),
            stringOption("--key", &.{"-k"}, "gpg key id to sign with (requires --sign)", false),
        },
    },
    .{
        .action = .repo_db,
        .name = "remove",
        .type_code = 'r',
        .description = "Remove package entries from a pacman repository database (repo-remove).",
        .implementation = "Zigalpm.repo.Database.removePackages",
        .arguments = &.{
            requiredArgument("database", database_argument),
            repeatedArgument("names", 1, "Exact package names to remove"),
        },
        .options = &.{
            flag("--remove-old-files", &.{"-R"}, "Delete replaced package files (and .sig) after publishing"),
            flag("--wait", &.{"-w"}, "Block until the database lock is free"),
            flag("--quiet", &.{"-q"}, "Do not print per-package removing lines"),
            flag("--sign", &.{"-s"}, "Sign each published database archive with gpg"),
            stringOption("--key", &.{"-k"}, "gpg key id to sign with (requires --sign)", false),
        },
    },
    .{
        .action = .repo_db,
        .name = "list",
        .type_code = 'l',
        .description = "List the entries of a repository database.",
        .implementation = "Zigalpm.repo.Database.listEntries",
        .arguments = &.{requiredArgument("database", database_argument)},
    },
    .{
        .action = .repo_db,
        .name = "verify",
        .type_code = 'v',
        .description = "Verify the detached gpg signatures of a repository database. Verification is trust-based: a good signature from an untrusted key is reported as invalid.",
        .implementation = "Zigalpm.repo.Database.verifySignatures",
        .arguments = &.{requiredArgument("database", database_argument)},
    },
};
