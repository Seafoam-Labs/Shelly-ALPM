const std = @import("std");

pub const Action = enum {
    search,
    install,
    upgrade,
    downgrade,
    mark,
    news,
    list_updates,
    list,
    backup,
    utility,
    purify,
    remove,
    sync,
    update,
    config,
    run,
    keyring,
    build,
    resolve,

    pub fn name(self: Action) []const u8 {
        return switch (self) {
            .list_updates => "list-updates",
            else => |action| @tagName(action),
        };
    }

    pub fn code(self: Action) u8 {
        return switch (self) {
            .search => 'S',
            .install => 'I',
            .upgrade => 'U',
            .downgrade => 'D',
            .mark => 'M',
            .news => 'N',
            .list_updates => 'P',
            .list => 'L',
            .backup => 'B',
            .utility => 'T',
            .purify => 'Z',
            .remove => 'R',
            .sync => 'Y',
            .update => 'E',
            .config => 'C',
            .run => 'X',
            .keyring => 'K',
            .build => 'A',
            .resolve => 'Q',
        };
    }

    pub fn description(self: Action) []const u8 {
        return switch (self) {
            .search => "Search ALPM repositories, the AUR, or cached Flatpak AppStream catalogs.",
            .install => "Install packages or applications from ALPM repositories, the AUR, AppImages, Flatpak remotes, or local Flatpak files, and repair installed Flatpaks.",
            .upgrade => "Upgrade standard, AUR, AppImage, or Flatpak packages, including all supported backends together.",
            .list => "List installed standard packages, AppImages, AUR packages, or Flatpak applications.",
            .list_updates => "List available updates for standard, AUR, AppImage, or Flatpak packages.",
            .purify => "Remove corrupted or orphaned ALPM packages, optionally clean the package cache, or remove unused Flatpak dependencies.",
            .remove => "Remove standard or local packages, AUR packages, AppImages, or Flatpak applications.",
            .sync => "Synchronize ALPM package databases, AppImage metadata, or cached Flatpak AppStream metadata.",
            .update => "Update selected standard, AUR, or Flatpak packages.",
            .downgrade => "Select and install an older version of a standard package.",
            .news => "Read Arch Linux news and track viewed entries.",
            .backup => "Back up explicitly installed packages as type-grouped TOML.",
            .utility => "Repair Shelly directory ownership, manage pacfiles, or generate CLI documentation and shell completions.",
            .mark => "Manage IgnorePkg and HoldPkg package marks, or change an installed package's explicit/dependency reason.",
            .keyring => "Manage package-signing keys and user PKGBUILD source-signing keys.",
            .config => "Read and modify Shelly configuration.",
            .run => "Launch or stop a Flatpak or AppImage application.",
            .build => "Builds a PKGBUILD into an installable package",
            .resolve => "Resolve exact package names to source package bases without changing package state.",
        };
    }

    pub fn findByCode(action_code: u8) ?Action {
        for (std.enums.values(Action)) |action| {
            if (action.code() == action_code) return action;
        }
        return null;
    }

    pub fn supportsCombinedTypes(self: Action) bool {
        return self == .search;
    }

    pub fn bareCodeMeansHelp(self: Action) bool {
        return self == .keyring or self == .build or self == .resolve;
    }
};

pub const Argument = struct {
    name: []const u8,
    type: []const u8 = "string",
    minimumArity: usize,
    maximumArity: ?usize,
    description: ?[]const u8 = null,
    choices: []const []const u8 = &.{},
};

pub const Option = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    type: []const u8 = "bool",
    minimumArity: usize = 0,
    maximumArity: ?usize = 1,
    required: bool = false,
    description: ?[]const u8 = null,
    hidden: bool = false,
    recursive: bool = false,
    builtIn: bool = false,
    hasExplicitDefault: bool = false,
    defaultValue: ?std.json.Value = null,
    choices: []const []const u8 = &.{},

    pub fn matches(self: Option, token: []const u8) bool {
        if (std.mem.eql(u8, self.name, token)) return true;
        for (self.aliases) |alias| {
            if (std.mem.eql(u8, alias, token)) return true;
        }
        return false;
    }
};

pub const Variant = struct {
    action: Action,
    name: []const u8,
    type_code: ?u8 = null,
    alias_type_codes: []const u8 = &.{},
    bare_action_code: bool = false,
    default_for_action: bool = false,
    description: []const u8,
    implementation: ?[]const u8 = null,
    arguments: []const Argument = &.{},
    options: []const Option = &.{},
};

pub const SharedModifier = struct {
    action: Action,
    type_names: []const []const u8,
    name: []const u8,
    aliases: []const []const u8,
    description: []const u8,

    pub fn appliesTo(self: SharedModifier, action: Action, type_name: []const u8, option_name: []const u8) bool {
        if (self.action != action) return false;
        for (self.type_names) |candidate| {
            if (std.mem.eql(u8, candidate, type_name))
                return std.mem.eql(u8, self.name, option_name);
        }
        return false;
    }
};

pub fn requiredArgument(name: []const u8, description: []const u8) Argument {
    return .{ .name = name, .minimumArity = 1, .maximumArity = 1, .description = description };
}

pub fn optionalArgument(name: []const u8, description: []const u8) Argument {
    return .{ .name = name, .minimumArity = 0, .maximumArity = 1, .description = description };
}

pub fn optionalArgumentWithChoices(
    name: []const u8,
    description: []const u8,
    choices: []const []const u8,
) Argument {
    return .{
        .name = name,
        .minimumArity = 0,
        .maximumArity = 1,
        .description = description,
        .choices = choices,
    };
}

pub fn repeatedArgument(name: []const u8, minimum: usize, description: []const u8) Argument {
    return .{ .name = name, .type = "string[]", .minimumArity = minimum, .maximumArity = null, .description = description };
}

pub fn integerArgument(name: []const u8, description: []const u8) Argument {
    return .{ .name = name, .type = "int", .minimumArity = 1, .maximumArity = 1, .description = description };
}

pub fn flag(name: []const u8, aliases: []const []const u8, description: []const u8) Option {
    return .{ .name = name, .aliases = aliases, .description = description };
}

pub fn booleanOptionWithDefault(
    name: []const u8,
    aliases: []const []const u8,
    description: []const u8,
    default_value: bool,
) Option {
    var option = flag(name, aliases, description);
    option.hasExplicitDefault = true;
    option.defaultValue = .{ .bool = default_value };
    return option;
}

pub fn globalFlag(name: []const u8, aliases: []const []const u8, description: []const u8) Option {
    var option = flag(name, aliases, description);
    option.recursive = true;
    return option;
}

pub fn voidOption(
    name: []const u8,
    aliases: []const []const u8,
    description: []const u8,
    recursive: bool,
    built_in: bool,
) Option {
    return .{
        .name = name,
        .aliases = aliases,
        .type = "void",
        .maximumArity = 0,
        .description = description,
        .recursive = recursive,
        .builtIn = built_in,
    };
}

pub fn integerOption(name: []const u8, aliases: []const []const u8, description: []const u8) Option {
    return .{
        .name = name,
        .aliases = aliases,
        .type = "int",
        .minimumArity = 1,
        .maximumArity = 1,
        .description = description,
    };
}

pub fn optionalIntegerOptionWithDefault(
    name: []const u8,
    aliases: []const []const u8,
    description: []const u8,
    default_value: i64,
) Option {
    return .{
        .name = name,
        .aliases = aliases,
        .type = "uint",
        .minimumArity = 0,
        .maximumArity = 1,
        .description = description,
        .hasExplicitDefault = true,
        .defaultValue = .{ .integer = default_value },
    };
}

pub fn stringOption(
    name: []const u8,
    aliases: []const []const u8,
    description: []const u8,
    required: bool,
) Option {
    return .{
        .name = name,
        .aliases = aliases,
        .type = "string",
        .minimumArity = 1,
        .maximumArity = 1,
        .required = required,
        .description = description,
    };
}

pub fn globalStringOption(name: []const u8, aliases: []const []const u8, description: []const u8) Option {
    var option = stringOption(name, aliases, description, false);
    option.recursive = true;
    return option;
}
