const std = @import("std");
const build_options = @import("build_options");
const core = @import("catalog/types.zig");

const backup = @import("catalog/backup.zig");
const config = @import("catalog/config.zig");
const downgrade = @import("catalog/downgrade.zig");
const install = @import("catalog/install.zig");
const keyring = @import("catalog/keyring.zig");
const list = @import("catalog/list.zig");
const list_updates = @import("catalog/list_updates.zig");
const mark = @import("catalog/mark.zig");
const news = @import("catalog/news.zig");
const purify = @import("catalog/purify.zig");
const remove = @import("catalog/remove.zig");
const repository = @import("catalog/repository.zig");
const run = @import("catalog/run.zig");
const search = @import("catalog/search.zig");
const sync = @import("catalog/sync.zig");
const update = @import("catalog/update.zig");
const upgrade = @import("catalog/upgrade.zig");
const utility = @import("catalog/utility.zig");
const builder = @import("catalog/builder.zig");
const resolve = @import("catalog/resolve.zig");

pub const Action = core.Action;
pub const Argument = core.Argument;
pub const Option = core.Option;
pub const SharedModifier = core.SharedModifier;
pub const Variant = core.Variant;

pub const binary = "shelly";
pub const version = build_options.version;
pub const informational_version = version;
pub const root_description = "Shelly — a native, unified package manager for Arch Linux repository packages, the AUR, Flatpaks, and AppImages. A bare value searches standard repositories and the AUR, then prompts for a package to install.";

fn hiddenGlobalFlag(name: []const u8, description: []const u8) Option {
    var option = core.globalFlag(name, &.{}, description);
    option.hidden = true;
    return option;
}

pub const root_options = [_]Option{
    core.voidOption("--help", &.{ "-?", "-h", "/?", "/h" }, "Show command-specific help and usage information", true, true),
    core.voidOption("--version", &.{"-V"}, "Show version information", false, true),
    core.globalFlag("--no-confirm", &.{"-n"}, "Use safe automatic answers instead of prompting"),
    core.globalFlag("--ui-mode", &.{"-U"}, "Emit framed output for the Shelly UI"),
    core.globalFlag("--json", &.{"-j"}, "Output structured JSON where the command supports it"),
    core.globalStringOption(
        "--aur-url",
        &.{},
        "Base URL of the AUR service used for Git clones and RPC requests",
    ),
    hiddenGlobalFlag(
        "--auto-confirm-cache-clean",
        "Preserve the invoking user's cache-clean policy across elevation",
    ),
    hiddenGlobalFlag(
        "--disable-cache-clean",
        "Preserve disabled upgrade-all cache cleaning across elevation",
    ),
};

pub const root_arguments = [_]Argument{.{
    .name = "query",
    .minimumArity = 1,
    .maximumArity = null,
    .description = "Package search words used by the interactive standard/AUR install fallback",
}};

pub const Type = struct {
    name: []const u8,
    code: ?u8,
    description: []const u8,
};

pub const types = [_]Type{
    .{ .name = "standard", .code = 's', .description = "Arch Linux repository and local ALPM packages" },
    .{ .name = "aur", .code = 'a', .description = "Arch User Repository packages" },
    .{ .name = "flatpak", .code = 'f', .description = "Flatpak applications and runtimes" },
    .{ .name = "appimage", .code = 'i', .description = "AppImage applications" },
    .{ .name = "utility", .code = 'u', .description = "System and Shelly utility operations" },
    .{ .name = "keyring", .code = 'k', .description = "Package and source-signing keyring operations" },
    .{ .name = "all", .code = 'x', .description = "All supported package backends" },
};

pub const variants = search.variants ++
    install.variants ++
    upgrade.variants ++
    downgrade.variants ++
    mark.variants ++
    news.variants ++
    list_updates.variants ++
    list.variants ++
    backup.variants ++
    utility.variants ++
    purify.variants ++
    remove.variants ++
    repository.variants ++
    sync.variants ++
    update.variants ++
    config.variants ++
    keyring.variants ++
    run.variants ++
    builder.variants ++
    resolve.variants;

pub const shared_modifiers = [_]SharedModifier{
    .{
        .action = .list,
        .type_names = &.{ "standard", "aur" },
        .name = "--required-by",
        .aliases = &.{},
        .description = "Include packages that directly require each listed package",
    },
    .{
        .action = .list,
        .type_names = &.{ "standard", "aur" },
        .name = "--optional-for",
        .aliases = &.{},
        .description = "Include packages that directly use each listed package optionally",
    },
    .{
        .action = .install,
        .type_names = &.{ "standard", "aur" },
        .name = "--build-deps",
        .aliases = &.{"-b"},
        .description = "Install build dependencies for the requested packages",
    },
    .{
        .action = .install,
        .type_names = &.{ "standard", "aur" },
        .name = "--make-deps",
        .aliases = &.{"-m"},
        .description = "Install make dependencies for the requested packages",
    },
    .{
        .action = .remove,
        .type_names = &.{ "standard", "aur" },
        .name = "--cascade",
        .aliases = &.{"-c"},
        .description = "Remove dependencies that are no longer needed",
    },
    .{
        .action = .remove,
        .type_names = &.{ "standard", "aur" },
        .name = "--opt-deps",
        .aliases = &.{"-o"},
        .description = "Remove unused optional dependencies installed with the packages",
    },
    .{
        .action = .remove,
        .type_names = &.{ "standard", "aur" },
        .name = "--ripple",
        .aliases = &.{"-i"},
        .description = "Remove packages that depend on the removed packages",
    },
    .{
        .action = .remove,
        .type_names = &.{ "standard", "flatpak", "appimage" },
        .name = "--remove-config",
        .aliases = &.{},
        .description = "Remove configuration associated with the removed package",
    },
    .{
        .action = .search,
        .type_names = &.{ "standard", "flatpak" },
        .name = "--limit",
        .aliases = &.{"-t"},
        .description = "Maximum number of search results to return per page",
    },
    .{
        .action = .search,
        .type_names = &.{ "standard", "flatpak" },
        .name = "--page",
        .aliases = &.{"-p"},
        .description = "Page number for paginated results",
    },
};

pub fn resolveOptions(comptime variant: Variant) []const Option {
    @setEvalBranchQuota(100_000);
    const resolved = comptime blk: {
        var result = variant.options[0..variant.options.len].*;
        for (&result) |*option| {
            if (findSharedModifier(variant.action, variant.name, option.name)) |shared| {
                option.name = shared.name;
                option.aliases = shared.aliases;
                option.description = shared.description;
            }
        }
        break :blk result;
    };
    return &resolved;
}

pub fn findVariant(comptime action: Action, comptime name: []const u8) ?Variant {
    for (variants) |variant| {
        if (variant.action == action and std.mem.eql(u8, variant.name, name)) return variant;
    }
    return null;
}

pub fn findVariantByCodes(action_code: u8, type_code: u8) ?*const Variant {
    for (&variants) |*variant| {
        if (variant.action.code() == action_code and variant.type_code == type_code) return variant;
    }
    return null;
}

pub fn findStandaloneVariantByActionCode(action_code: u8) ?*const Variant {
    for (&variants) |*variant| {
        if (variant.action.code() == action_code and
            variant.type_code == null and
            variant.default_for_action)
            return variant;
    }
    return null;
}

pub fn findBareCodeVariant(action_code: u8) ?*const Variant {
    for (&variants) |*variant| {
        if (variant.action.code() == action_code and variant.bare_action_code) return variant;
    }
    return null;
}

pub fn findVariantByAliasTypeCode(action_code: u8, alias_code: u8) ?*const Variant {
    for (&variants) |*variant| {
        if (variant.action.code() != action_code) continue;
        for (variant.alias_type_codes) |candidate| {
            if (candidate == alias_code) return variant;
        }
    }
    return null;
}

pub fn findTypeByCode(code: u8) ?Type {
    for (types) |command_type| {
        if (command_type.code == code) return command_type;
    }
    return null;
}

pub fn findTypeByName(name: []const u8) ?Type {
    for (types) |command_type| {
        if (std.mem.eql(u8, command_type.name, name)) return command_type;
    }
    return null;
}

pub fn findSharedModifier(action: Action, type_name: []const u8, option_name: []const u8) ?SharedModifier {
    for (shared_modifiers) |modifier| {
        if (modifier.appliesTo(action, type_name, option_name)) return modifier;
    }
    return null;
}

pub fn findActionByCode(action_code: u8) ?[]const u8 {
    const action = Action.findByCode(action_code) orelse return null;
    return action.name();
}

pub fn hasActionCode(action_code: u8) bool {
    return Action.findByCode(action_code) != null;
}

comptime {
    validate();
}

fn validate() void {
    @setEvalBranchQuota(1_000_000);

    for (variants, 0..) |variant, index| {
        const where = std.fmt.comptimePrint("{s} {s}", .{ variant.action.name(), variant.name });

        if (variant.description.len == 0)
            @compileError(std.fmt.comptimePrint("variant '{s}' needs a description", .{where}));

        for (variant.alias_type_codes) |alias_code| {
            if (!std.ascii.isUpper(alias_code))
                @compileError(std.fmt.comptimePrint("alias type code '{c}' of '{s}' must be uppercase", .{ alias_code, where }));
            if (variant.type_code != null and variant.type_code.? == alias_code)
                @compileError(std.fmt.comptimePrint("alias type code '{c}' of '{s}' duplicates its own type code", .{ alias_code, where }));
        }

        for (variants[index + 1 ..]) |other| {
            if (variant.action == other.action and std.mem.eql(u8, variant.name, other.name))
                @compileError(std.fmt.comptimePrint("duplicate variant '{s}'", .{where}));
            if (variant.action == other.action and
                variant.type_code != null and
                other.type_code != null and
                variant.type_code.? == other.type_code.?)
                @compileError(std.fmt.comptimePrint("duplicate shortcode type code '{c}' for action '{s}'", .{ variant.type_code.?, variant.action.name() }));
            if (variant.action == other.action and variant.default_for_action and other.default_for_action)
                @compileError(std.fmt.comptimePrint("action '{s}' has more than one default type", .{variant.action.name()}));
            if (variant.action == other.action and variant.bare_action_code and other.bare_action_code)
                @compileError(std.fmt.comptimePrint("action '{s}' has more than one bare action-code variant", .{variant.action.name()}));
            if (variant.action == other.action) {
                for (variant.alias_type_codes) |alias_code| {
                    if (other.type_code != null and other.type_code.? == alias_code)
                        @compileError(std.fmt.comptimePrint("alias type code '{c}' of '{s}' collides with a type code of '{s} {s}'", .{ alias_code, where, other.action.name(), other.name }));
                    for (other.alias_type_codes) |other_alias| {
                        if (alias_code == other_alias)
                            @compileError(std.fmt.comptimePrint("alias type code '{c}' of '{s}' collides with '{s} {s}'", .{ alias_code, where, other.action.name(), other.name }));
                    }
                }
            }
        }

        for (variant.arguments) |argument| {
            if (argument.name.len == 0)
                @compileError(std.fmt.comptimePrint("variant '{s}' has an unnamed argument", .{where}));
            if (argument.description == null or argument.description.?.len == 0)
                @compileError(std.fmt.comptimePrint("argument '{s}' of '{s}' needs a description", .{ argument.name, where }));
            if (argument.maximumArity) |maximum| {
                if (maximum < argument.minimumArity)
                    @compileError(std.fmt.comptimePrint("argument '{s}' of '{s}' has an inverted arity", .{ argument.name, where }));
            }
        }

        const resolved = resolveOptions(variant);
        for (resolved, 0..) |option, option_index| {
            if (option.name.len <= 2 or !std.mem.startsWith(u8, option.name, "--"))
                @compileError(std.fmt.comptimePrint("option '{s}' of '{s}' needs a long --name", .{ option.name, where }));
            if (option.description == null or option.description.?.len == 0)
                @compileError(std.fmt.comptimePrint("option '{s}' of '{s}' needs a description", .{ option.name, where }));
            for (option.aliases) |alias| {
                if (!std.mem.startsWith(u8, alias, "-"))
                    @compileError(std.fmt.comptimePrint("alias '{s}' of '{s}' option '{s}' must start with '-'", .{ alias, where, option.name }));
            }
            for (resolved[option_index + 1 ..]) |other| {
                if (std.mem.eql(u8, option.name, other.name))
                    @compileError(std.fmt.comptimePrint("option '{s}' of '{s}' is declared twice", .{ option.name, where }));
                for (option.aliases) |alias| {
                    if (other.matches(alias))
                        @compileError(std.fmt.comptimePrint("alias '{s}' of '{s}' collides with option '{s}'", .{ alias, where, other.name }));
                }
            }
        }
    }

    for (shared_modifiers) |modifier| {
        if (modifier.type_names.len < 2)
            @compileError(std.fmt.comptimePrint("shared modifier '{s}' must apply to at least two types", .{modifier.name}));
        for (modifier.type_names) |type_name| {
            const variant = findVariant(modifier.action, type_name) orelse
                @compileError(std.fmt.comptimePrint("shared modifier '{s}' lists unknown type '{s}'", .{ modifier.name, type_name }));
            var declared = false;
            for (variant.options) |option| {
                if (std.mem.eql(u8, option.name, modifier.name)) declared = true;
            }
            if (!declared)
                @compileError(std.fmt.comptimePrint("'{s} {s}' does not declare shared modifier '{s}'", .{ modifier.action.name(), type_name, modifier.name }));
        }
    }
}

test "remove variants expose native help and modifier aliases" {
    for ([_]u8{ 's', 'i', 'a', 'f' }) |type_code| {
        const variant = findVariantByCodes('R', type_code).?;
        try std.testing.expect(variant.description.len > 0);
        try std.testing.expect(variant.implementation != null);
    }

    inline for (.{ "standard", "aur" }) |type_name| {
        const options = resolveOptions(comptime findVariant(.remove, type_name).?);
        for ([_]struct {
            name: []const u8,
            alias: []const u8,
        }{
            .{ .name = "--cascade", .alias = "-c" },
            .{ .name = "--opt-deps", .alias = "-o" },
            .{ .name = "--ripple", .alias = "-i" },
        }) |expected| {
            var found = false;
            for (options) |option| {
                if (!std.mem.eql(u8, option.name, expected.name)) continue;
                found = option.matches(expected.alias);
                break;
            }
            try std.testing.expect(found);
        }
    }

    const standard_options = resolveOptions(comptime findVariant(.remove, "standard").?);
    var found_no_cascade = false;
    for (standard_options) |option| {
        if (std.mem.eql(u8, option.name, "--cascade")) {
            try std.testing.expect(option.hasExplicitDefault);
            try std.testing.expect(option.defaultValue.?.bool);
        }
        if (std.mem.eql(u8, option.name, "--no-cascade")) {
            found_no_cascade = true;
            break;
        }
    }
    try std.testing.expect(found_no_cascade);
}

test "shared modifiers stay shared across their listed types" {
    inline for (.{ "standard", "aur" }) |type_name| {
        const options = resolveOptions(comptime findVariant(.install, type_name).?);
        try std.testing.expect(options[0].matches("-b"));
        try std.testing.expect(options[1].matches("-m"));
    }

    const aur_search = resolveOptions(comptime findVariant(.search, "aur").?);
    try std.testing.expectEqualStrings("--pkgbuild", aur_search[1].name);

    const standard_search = resolveOptions(comptime findVariant(.search, "standard").?);
    try std.testing.expectEqualStrings(
        "Maximum number of search results to return per page",
        standard_search[4].description.?,
    );
    try std.testing.expect(standard_search[4].matches("-t"));
}
