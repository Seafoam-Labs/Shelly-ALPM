const std = @import("std");
const catalog = @import("catalog.zig");
const spec = @import("spec.zig");

pub const Translation = union(enum) {
    unchanged: []const []const u8,
    translated: []const []const u8,
    expanded: []const []const []const u8,
    failure: []const u8,

    pub fn arguments(self: Translation) ?[]const []const u8 {
        return switch (self) {
            .unchanged => |value| value,
            .translated => |value| value,
            .expanded, .failure => null,
        };
    }
};

pub fn translate(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    args: []const []const u8,
) !Translation {
    if (args.len == 0) return .{ .unchanged = args };
    const token = args[0];
    if (try translateTopLevelHelp(allocator, manifest, args, token)) |translation|
        return translation;
    if (std.mem.eql(u8, token, "-U")) {
        var result: std.ArrayList([]const u8) = .empty;
        try result.appendSlice(allocator, &.{ "upgrade", "all" });
        try result.appendSlice(allocator, args[1..]);
        return .{ .translated = try result.toOwnedSlice(allocator) };
    }
    if (std.mem.eql(u8, token, "-Uh")) {
        var result: std.ArrayList([]const u8) = .empty;
        try result.appendSlice(allocator, &.{ "upgrade", "--help" });
        try result.appendSlice(allocator, args[1..]);
        return .{ .translated = try result.toOwnedSlice(allocator) };
    }
    if (std.mem.eql(u8, token, "-P")) {
        var result: std.ArrayList([]const u8) = .empty;
        try result.appendSlice(allocator, &.{ "list-updates", "all" });
        try result.appendSlice(allocator, args[1..]);
        return .{ .translated = try result.toOwnedSlice(allocator) };
    }
    if (std.mem.eql(u8, token, "-Ih")) {
        var result: std.ArrayList([]const u8) = .empty;
        try result.appendSlice(allocator, &.{ "install", "--help" });
        try result.appendSlice(allocator, args[1..]);
        return .{ .translated = try result.toOwnedSlice(allocator) };
    }
    if (std.mem.eql(u8, token, "-Mh")) {
        var result: std.ArrayList([]const u8) = .empty;
        try result.appendSlice(allocator, &.{ "mark", "--help" });
        try result.appendSlice(allocator, args[1..]);
        return .{ .translated = try result.toOwnedSlice(allocator) };
    }
    if (std.mem.eql(u8, token, "-K") or std.mem.eql(u8, token, "-Kh")) {
        var result: std.ArrayList([]const u8) = .empty;
        try result.appendSlice(allocator, &.{ "keyring", "--help" });
        try result.appendSlice(allocator, args[1..]);
        return .{ .translated = try result.toOwnedSlice(allocator) };
    }
    if (std.mem.startsWith(u8, token, "-CI")) {
        var result: std.ArrayList([]const u8) = .empty;
        try result.appendSlice(allocator, &.{ "sync", "appimage", "--configure-updates" });
        for (token[3..]) |modifier| switch (modifier) {
            'p' => try result.append(allocator, "--prerelease"),
            'h' => try result.append(allocator, "--help"),
            else => return .{ .failure = try std.fmt.allocPrint(
                allocator,
                "Unknown modifier '{c}' for AppImage update configuration. Valid modifiers: h, p",
                .{modifier},
            ) },
        };
        try result.appendSlice(allocator, args[1..]);
        return .{ .translated = try result.toOwnedSlice(allocator) };
    }
    if (try translateAurVersionInstall(allocator, manifest, args, token)) |translation|
        return translation;
    if (try translateStandaloneAction(allocator, manifest, args, token)) |translation|
        return translation;
    if (token.len < 3 or token[0] != '-') return .{ .unchanged = args };

    const action_code = token[1];
    if (!std.ascii.isAlphabetic(action_code) or !catalog.hasActionCode(action_code))
        return .{ .unchanged = args };

    if (try translateCombinedSearch(allocator, manifest, args, token)) |translation|
        return translation;

    const source_type_code = token[2];
    const type_code = normalizeTypeCode(action_code, source_type_code);
    if (!std.ascii.isAlphabetic(type_code)) {
        return .{ .failure = try std.fmt.allocPrint(
            allocator,
            "Unknown shortcode type '{c}' for action code '{c}'. Valid types: {s}",
            .{ source_type_code, action_code, try validTypes(allocator, action_code) },
        ) };
    }

    const variant = catalog.findVariantByCodes(action_code, type_code) orelse {
        if (catalog.findTypeByCode(type_code) == null) {
            return .{ .failure = try std.fmt.allocPrint(
                allocator,
                "Unknown shortcode type '{c}' for action code '{c}'. Valid types: {s}",
                .{ source_type_code, action_code, try validTypes(allocator, action_code) },
            ) };
        }
        return .{ .failure = try std.fmt.allocPrint(
            allocator,
            "Action code '{c}' is not available for type '{c}'. Valid types: {s}",
            .{ action_code, source_type_code, try validTypes(allocator, action_code) },
        ) };
    };
    const path = try std.fmt.allocPrint(
        allocator,
        "shelly {s} {s}",
        .{ variant.action, variant.type_name },
    );
    const command = manifest.findByPath(path) orelse return error.InvalidCatalog;

    var result: std.ArrayList([]const u8) = .empty;
    try result.appendSlice(allocator, &.{ variant.action, variant.type_name });
    for (token[3..]) |modifier| {
        const alias = try std.fmt.allocPrint(allocator, "-{c}", .{modifier});
        if (findLocalOption(command, alias) != null) {
            try result.append(allocator, alias);
            continue;
        }
        if (findRecursiveHelpOption(manifest, alias)) |option| {
            try result.append(allocator, option.name);
            continue;
        }
        return .{ .failure = try std.fmt.allocPrint(
            allocator,
            "Unknown modifier '{c}' for '{s} {s}'. Valid modifiers: {s}",
            .{ modifier, variant.action, variant.type_name, try validModifiers(allocator, manifest, command) },
        ) };
    }
    try result.appendSlice(allocator, args[1..]);
    return .{ .translated = try result.toOwnedSlice(allocator) };
}

fn translateAurVersionInstall(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    args: []const []const u8,
    token: []const u8,
) !?Translation {
    if (token.len < 4 or !std.mem.eql(u8, token[0..4], "-Iav")) return null;
    const command = manifest.findByPath("shelly install aur") orelse return error.InvalidCatalog;

    var result: std.ArrayList([]const u8) = .empty;
    try result.appendSlice(allocator, &.{ "install", "aur", "--version" });
    for (token[4..]) |modifier| {
        const alias = try std.fmt.allocPrint(allocator, "-{c}", .{modifier});
        if (findLocalOption(command, alias)) |option| {
            try result.append(allocator, option.name);
            continue;
        }
        if (findRecursiveHelpOption(manifest, alias)) |option| {
            try result.append(allocator, option.name);
            continue;
        }
        return .{ .failure = try std.fmt.allocPrint(
            allocator,
            "Unknown modifier '{c}' for 'install aur --version'. Valid modifiers: {s}",
            .{ modifier, try validModifiers(allocator, manifest, command) },
        ) };
    }
    try result.appendSlice(allocator, args[1..]);
    return .{ .translated = try result.toOwnedSlice(allocator) };
}

fn translateStandaloneAction(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    args: []const []const u8,
    token: []const u8,
) !?Translation {
    if (token.len < 2 or token[0] != '-') return null;
    const variant = catalog.findStandaloneVariantByActionCode(token[1]) orelse return null;
    // A legacy typed action may share the same uppercase action code. Its
    // exact action/type pair wins when the first suffix character is a valid
    // type; otherwise every suffix character is a standalone modifier.
    if (token.len > 2 and catalog.findVariantByCodes(token[1], token[2]) != null)
        return null;
    const path = try std.fmt.allocPrint(
        allocator,
        "shelly {s} {s}",
        .{ variant.action, variant.type_name },
    );
    const command = manifest.findByPath(path) orelse return error.InvalidCatalog;

    var result: std.ArrayList([]const u8) = .empty;
    try result.append(allocator, variant.action);
    for (token[2..]) |modifier| {
        const alias = try std.fmt.allocPrint(allocator, "-{c}", .{modifier});
        if (findLocalOption(command, alias) != null) {
            try result.append(allocator, alias);
            continue;
        }
        if (findRecursiveHelpOption(manifest, alias)) |option| {
            try result.append(allocator, option.name);
            continue;
        }
        return .{ .failure = try std.fmt.allocPrint(
            allocator,
            "Unknown modifier '{c}' for '{s}'. Valid modifiers: {s}",
            .{ modifier, variant.action, try validModifiers(allocator, manifest, command) },
        ) };
    }
    try result.appendSlice(allocator, args[1..]);
    return .{ .translated = try result.toOwnedSlice(allocator) };
}

fn normalizeTypeCode(action_code: u8, type_code: u8) u8 {
    if (action_code == 'L') return switch (type_code) {
        'I' => 'i',
        'A' => 'a',
        'F' => 'f',
        else => type_code,
    };
    if (action_code != 'R') return type_code;
    return switch (type_code) {
        'S' => 's',
        'I' => 'i',
        'A' => 'a',
        'F' => 'f',
        else => type_code,
    };
}

fn translateCombinedSearch(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    args: []const []const u8,
    token: []const u8,
) !?Translation {
    if (token[1] != 'S') return null;

    var selected: std.ArrayList(*const catalog.Variant) = .empty;
    var modifiers: std.ArrayList(u8) = .empty;
    var seen = [_]bool{false} ** 256;
    for (token[2..]) |code| {
        const variant = catalog.findVariantByCodes('S', code) orelse {
            try modifiers.append(allocator, code);
            continue;
        };
        if (!std.mem.eql(u8, variant.action, "search")) {
            try modifiers.append(allocator, code);
            continue;
        }
        if (seen[code]) {
            return .{ .failure = try std.fmt.allocPrint(
                allocator,
                "Duplicate search type '{c}' in shortcode.",
                .{code},
            ) };
        }
        seen[code] = true;
        try selected.append(allocator, variant);
    }
    if (selected.items.len < 2) return null;

    var commands: std.ArrayList(*const spec.Command) = .empty;
    for (selected.items) |variant| {
        const path = try std.fmt.allocPrint(
            allocator,
            "shelly {s} {s}",
            .{ variant.action, variant.type_name },
        );
        try commands.append(allocator, manifest.findByPath(path) orelse return error.InvalidCatalog);
    }

    var expanded: std.ArrayList([]const []const u8) = .empty;
    for (selected.items, commands.items) |variant, command| {
        var result: std.ArrayList([]const u8) = .empty;
        try result.appendSlice(allocator, &.{ variant.action, variant.type_name });
        for (modifiers.items) |modifier| {
            const alias = try std.fmt.allocPrint(allocator, "-{c}", .{modifier});
            if (findLocalOption(command, alias) != null) {
                try result.append(allocator, alias);
            } else if (findRecursiveHelpOption(manifest, alias)) |option| {
                try result.append(allocator, option.name);
            }
        }
        try result.appendSlice(allocator, args[1..]);
        try expanded.append(allocator, try result.toOwnedSlice(allocator));
    }

    for (modifiers.items) |modifier| {
        const alias = try std.fmt.allocPrint(allocator, "-{c}", .{modifier});
        if (findRecursiveHelpOption(manifest, alias) != null) continue;
        for (commands.items) |command| {
            if (findLocalOption(command, alias) != null) break;
        } else {
            return .{ .failure = try std.fmt.allocPrint(
                allocator,
                "Unknown modifier '{c}' for combined search.",
                .{modifier},
            ) };
        }
    }

    return .{ .expanded = try expanded.toOwnedSlice(allocator) };
}

fn findLocalOption(command: *const spec.Command, alias: []const u8) ?*const spec.Option {
    for (command.options) |*option| {
        if (option.matches(alias)) return option;
    }
    return null;
}

fn findRecursiveHelpOption(manifest: *const spec.Manifest, alias: []const u8) ?*const spec.Option {
    for (manifest.root().options) |*option| {
        if (!option.recursive or !std.mem.eql(u8, option.name, "--help")) continue;
        if (option.matches(alias)) return option;
    }
    return null;
}

fn validTypes(allocator: std.mem.Allocator, action_code: u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (catalog.variants) |variant| {
        if (variant.action_code != action_code or variant.type_code == null) continue;
        if (result.items.len > 0) try result.appendSlice(allocator, ", ");
        try result.append(allocator, variant.type_code.?);
    }
    return result.toOwnedSlice(allocator);
}

fn validModifiers(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    command: *const spec.Command,
) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    try appendModifierAliases(allocator, &result, command.options);
    for (manifest.root().options) |option| {
        if (!option.recursive or !std.mem.eql(u8, option.name, "--help")) continue;
        try appendModifierAliases(allocator, &result, &.{option});
    }
    if (result.items.len == 0) return "(none)";
    return result.toOwnedSlice(allocator);
}

fn appendModifierAliases(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    options: []const spec.Option,
) !void {
    for (options) |option| {
        for (option.aliases) |alias| {
            if (alias.len != 2 or alias[0] != '-' or alias[1] == '-') continue;
            if (result.items.len > 0) try result.appendSlice(allocator, ", ");
            try result.append(allocator, alias[1]);
        }
    }
}

fn translateTopLevelHelp(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    args: []const []const u8,
    token: []const u8,
) !?Translation {
    // A bare action shortcode must be exactly "-X".
    if (token.len != 2 or token[0] != '-')
        return null;

    if (args.len < 2)
        return null;

    // Recognizes --help, -h, -?, /h, and /?.
    const help_option =
        findRecursiveHelpOption(manifest, args[1]) orelse return null;

    const action =
        catalog.findActionByCode(token[1]) orelse return null;

    // Ensure the corresponding top-level command exists.
    const path = try std.fmt.allocPrint(
        allocator,
        "shelly {s}",
        .{action},
    );
    if (manifest.findByPath(path) == null)
        return error.InvalidCatalog;

    var result: std.ArrayList([]const u8) = .empty;
    try result.append(allocator, action);
    try result.append(allocator, help_option.name);
    try result.appendSlice(allocator, args[2..]);

    return .{
        .translated = try result.toOwnedSlice(allocator),
    };
}

test "translates action-type shortcodes from the command manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = try spec.Manifest.load(allocator);

    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-Isu", "firefox" },
        &.{ "install", "standard", "-u", "firefox" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-Iamb", "package" },
        &.{ "install", "aur", "-m", "-b", "package" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-Iav", "demo-git", "deadbeef" },
        &.{ "install", "aur", "--version", "demo-git", "deadbeef" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{"-Iavh"},
        &.{ "install", "aur", "--version", "--help" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-Ife", "/tmp/demo.flatpakref" },
        &.{ "install", "flatpak", "-e", "/tmp/demo.flatpakref" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-Ifu", "/tmp/demo.flatpak" },
        &.{ "install", "flatpak", "-u", "/tmp/demo.flatpak" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{"-Ifeh"},
        &.{ "install", "flatpak", "-e", "--help" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-Sa", "query" },
        &.{ "search", "aur", "query" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-Sap", "yay" },
        &.{ "search", "aur", "-p", "yay" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-Ssv", "query" },
        &.{ "search", "standard", "-v", "query" },
    );
    try expectExpandedTranslation(
        allocator,
        &manifest,
        &.{ "-Ssafv", "query" },
        &.{
            &.{ "search", "standard", "-v", "query" },
            &.{ "search", "aur", "query" },
            &.{ "search", "flatpak", "query" },
        },
    );
    try expectExpandedTranslation(
        allocator,
        &manifest,
        &.{ "-Sasv", "query" },
        &.{
            &.{ "search", "aur", "query" },
            &.{ "search", "standard", "-v", "query" },
        },
    );
    try expectExpandedTranslation(
        allocator,
        &manifest,
        &.{ "-Ssva", "query" },
        &.{
            &.{ "search", "standard", "-v", "query" },
            &.{ "search", "aur", "query" },
        },
    );
    try expectExpandedTranslation(
        allocator,
        &manifest,
        &.{ "-Ssav", "query" },
        &.{
            &.{ "search", "standard", "-v", "query" },
            &.{ "search", "aur", "query" },
        },
    );
    try expectTranslation(allocator, &manifest, &.{"-K"}, &.{ "keyring", "--help" });
    try expectTranslation(allocator, &manifest, &.{"-Kh"}, &.{ "keyring", "--help" });
    try expectTranslation(allocator, &manifest, &.{"-Ki"}, &.{ "keyring", "init" });
    try expectTranslation(allocator, &manifest, &.{"-Kl"}, &.{ "keyring", "list" });
    try expectTranslation(allocator, &manifest, &.{"-Kr"}, &.{ "keyring", "refresh" });
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-Ks", "ABCD" },
        &.{ "keyring", "lsign", "ABCD" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-Kp", "archlinux" },
        &.{ "keyring", "populate", "archlinux" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-Kv", "ABCD" },
        &.{ "keyring", "recv", "ABCD" },
    );
    try expectTranslation(allocator, &manifest, &.{"-C"}, &.{"config"});
    try expectTranslation(allocator, &manifest, &.{"-Ch"}, &.{ "config", "--help" });
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-Cg", "ParallelDownloadCount" },
        &.{ "config", "get", "ParallelDownloadCount" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-Cs", "ParallelDownloadCount", "12" },
        &.{ "config", "set", "ParallelDownloadCount", "12" },
    );
    try expectTranslation(allocator, &manifest, &.{"-Cr"}, &.{ "config", "reset" });
    try expectTranslation(allocator, &manifest, &.{ "-Cp", "12" }, &.{ "config", "parallel", "12" });
    try expectTranslation(
        allocator,
        &manifest,
        &.{"-Ysf"},
        &.{ "sync", "standard", "-f" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{"-Yf"},
        &.{ "sync", "flatpak" },
    );
    try expectTranslation(allocator, &manifest, &.{"-Us"}, &.{ "upgrade", "standard" });
    try expectTranslation(allocator, &manifest, &.{"-Usa"}, &.{ "upgrade", "standard", "-a" });
    try expectTranslation(allocator, &manifest, &.{"-U"}, &.{ "upgrade", "all" });
    try expectTranslation(allocator, &manifest, &.{"-Uh"}, &.{ "upgrade", "--help" });
    try expectTranslation(allocator, &manifest, &.{"-Ua"}, &.{ "upgrade", "aur" });
    try expectTranslation(allocator, &manifest, &.{"-P"}, &.{ "list-updates", "all" });
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-U", "--no-aur" },
        &.{ "upgrade", "all", "--no-aur" },
    );
    try expectTranslation(allocator, &manifest, &.{"-Ux"}, &.{ "upgrade", "all" });
    try expectTranslation(allocator, &manifest, &.{"-Ui"}, &.{ "upgrade", "appimage" });
    try expectTranslation(allocator, &manifest, &.{"-Uf"}, &.{ "upgrade", "flatpak" });
    try expectTranslation(allocator, &manifest, &.{"-Ih"}, &.{ "install", "--help" });
    try expectTranslation(allocator, &manifest, &.{ "-D", "linux" }, &.{ "downgrade", "linux" });
    try expectTranslation(allocator, &manifest, &.{ "-Do", "linux" }, &.{ "downgrade", "-o", "linux" });
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-Dt", "6.12.1-1", "linux" },
        &.{ "downgrade", "-t", "6.12.1-1", "linux" },
    );
    try expectTranslation(allocator, &manifest, &.{"-Zs"}, &.{ "purify", "standard" });
    try expectTranslation(allocator, &manifest, &.{"-Zf"}, &.{ "purify", "flatpak" });
    try expectTranslation(
        allocator,
        &manifest,
        &.{"-Uah"},
        &.{ "upgrade", "aur", "--help" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{"-Sah"},
        &.{ "search", "aur", "--help" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{"-Ys?"},
        &.{ "sync", "standard", "--help" },
    );
}

test "uses centralized effective modifiers and rejects invalid shortcode types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = try spec.Manifest.load(allocator);

    const invalid_modifier = try translate(allocator, &manifest, &.{"-Iao"});
    try std.testing.expectEqualStrings(
        "Unknown modifier 'o' for 'install aur'. Valid modifiers: b, m, c, v, ?, h",
        invalid_modifier.failure,
    );

    const redundant_downgrade_type = try translate(allocator, &manifest, &.{ "-Ds", "linux" });
    try std.testing.expectEqualStrings(
        "Unknown modifier 's' for 'downgrade'. Valid modifiers: o, i, l, t, ?, h",
        redundant_downgrade_type.failure,
    );

    const uppercase_standard = try translate(allocator, &manifest, &.{ "-SS", "query" });
    try std.testing.expectEqualStrings(
        "Unknown shortcode type 'S' for action code 'S'. Valid types: s, a, f",
        uppercase_standard.failure,
    );
    const uppercase_aur = try translate(allocator, &manifest, &.{ "-IA", "package" });
    try std.testing.expectEqualStrings(
        "Unknown shortcode type 'A' for action code 'I'. Valid types: s, i, a, f",
        uppercase_aur.failure,
    );
    const invalid_pair = try translate(allocator, &manifest, &.{ "-Si", "query" });
    try std.testing.expectEqualStrings(
        "Action code 'S' is not available for type 'i'. Valid types: s, a, f",
        invalid_pair.failure,
    );
    const duplicate_search_type = try translate(allocator, &manifest, &.{ "-Ssas", "query" });
    try std.testing.expectEqualStrings(
        "Duplicate search type 's' in shortcode.",
        duplicate_search_type.failure,
    );
    const invalid_combined_modifier = try translate(allocator, &manifest, &.{ "-Ssao", "query" });
    try std.testing.expectEqualStrings(
        "Unknown modifier 'o' for combined search.",
        invalid_combined_modifier.failure,
    );
}

test "translates uppercase remove aliases and preserves lowercase compatibility" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = try spec.Manifest.load(allocator);

    for ([_]struct {
        uppercase: []const u8,
        lowercase: []const u8,
        command_type: []const u8,
    }{
        .{ .uppercase = "-RS", .lowercase = "-Rs", .command_type = "standard" },
        .{ .uppercase = "-RI", .lowercase = "-Ri", .command_type = "appimage" },
        .{ .uppercase = "-RA", .lowercase = "-Ra", .command_type = "aur" },
        .{ .uppercase = "-RF", .lowercase = "-Rf", .command_type = "flatpak" },
    }) |case| {
        try expectTranslation(
            allocator,
            &manifest,
            &.{ case.uppercase, "package" },
            &.{ "remove", case.command_type, "package" },
        );
        try expectTranslation(
            allocator,
            &manifest,
            &.{ case.lowercase, "package" },
            &.{ "remove", case.command_type, "package" },
        );
    }

    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-RScoilf", "package" },
        &.{ "remove", "standard", "-c", "-o", "-i", "-l", "-f", "package" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-RAcoi", "package" },
        &.{ "remove", "aur", "-c", "-o", "-i", "package" },
    );

    const unrelated_uppercase = try translate(allocator, &manifest, &.{ "-RC", "value" });
    try std.testing.expectEqualStrings(
        "Unknown shortcode type 'C' for action code 'R'. Valid types: s, i, a, f",
        unrelated_uppercase.failure,
    );

    for ([_][]const u8{ "standard", "appimage", "aur", "flatpak" }) |command_type| {
        const parsed = try @import("parser.zig").parse(
            allocator,
            &manifest,
            &.{ "remove", command_type, "package" },
        );
        try std.testing.expect(parsed == .dispatch);
        const expected_path = try std.fmt.allocPrint(allocator, "shelly remove {s}", .{command_type});
        try std.testing.expectEqualStrings(expected_path, parsed.dispatch.command.path);
    }
}

test "passes ordinary long form and unrelated options through unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = try spec.Manifest.load(allocator);

    try expectTranslation(
        allocator,
        &manifest,
        &.{ "install", "standard", "pkg" },
        &.{ "install", "standard", "pkg" },
    );
    try expectTranslation(allocator, &manifest, &.{"-n"}, &.{"-n"});
    try expectTranslation(allocator, &manifest, &.{ "-WW", "x" }, &.{ "-WW", "x" });
}

test "every catalog leaf supports native long-form help and shortcode help" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = try spec.Manifest.load(allocator);

    for (catalog.variants) |variant| {
        const long_form = try @import("parser.zig").parse(
            allocator,
            &manifest,
            &.{ variant.action, variant.type_name, "--help" },
        );
        try std.testing.expect(long_form == .help);
        try std.testing.expectEqualStrings(variant.action, long_form.help.parentPath.?["shelly ".len..]);

        if (variant.action_code == null or variant.type_code == null) continue;
        const token = try std.fmt.allocPrint(
            allocator,
            "-{c}{c}h",
            .{ variant.action_code.?, variant.type_code.? },
        );
        const translated = try translate(allocator, &manifest, &.{token});
        const translated_arguments = translated.arguments() orelse return error.ShortcodeTranslationFailed;
        const shortcode = try @import("parser.zig").parse(allocator, &manifest, translated_arguments);
        try std.testing.expect(shortcode == .help);
        try std.testing.expectEqualStrings(long_form.help.path, shortcode.help.path);
    }
}

fn expectTranslation(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    input: []const []const u8,
    expected: []const []const u8,
) !void {
    const result = try translate(allocator, manifest, input);
    const actual = result.arguments() orelse return error.UnexpectedTranslationFailure;
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_argument, actual_argument|
        try std.testing.expectEqualStrings(expected_argument, actual_argument);
}

fn expectExpandedTranslation(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    input: []const []const u8,
    expected: []const []const []const u8,
) !void {
    const result = try translate(allocator, manifest, input);
    try std.testing.expect(result == .expanded);
    try std.testing.expectEqual(expected.len, result.expanded.len);
    for (expected, result.expanded) |expected_arguments, actual_arguments| {
        try std.testing.expectEqual(expected_arguments.len, actual_arguments.len);
        for (expected_arguments, actual_arguments) |expected_argument, actual_argument|
            try std.testing.expectEqualStrings(expected_argument, actual_argument);
    }
}
