const std = @import("std");
const spec = @import("spec.zig");

pub const GlobalOptions = struct {
    no_confirm: bool = false,
    ui_mode: bool = false,
    json: bool = false,
};

pub const ParsedOption = struct {
    name: []const u8,
    value: ?[]const u8,
};

pub const Invocation = struct {
    command: *const spec.Command,
    arguments: []const []const u8,
    positionals: []const []const u8,
    options: []const ParsedOption,
    globals: GlobalOptions,
};

pub const Failure = struct {
    message: []const u8,
    help_command: *const spec.Command,
    leading_help_newline: bool = false,
};

pub const Outcome = union(enum) {
    help: *const spec.Command,
    version: GlobalOptions,
    dispatch: Invocation,
    failure: Failure,
};

pub fn parse(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    arguments: []const []const u8,
) !Outcome {
    var command = manifest.root();
    var positionals: std.ArrayList([]const u8) = .empty;
    var parsed_options: std.ArrayList(ParsedOption) = .empty;
    var globals: GlobalOptions = .{};
    var help_requested = false;
    var version_requested = false;
    var positional_only = false;
    var index: usize = 0;

    while (index < arguments.len) : (index += 1) {
        const token = arguments[index];
        if (!positional_only and std.mem.eql(u8, token, "--")) {
            positional_only = true;
            continue;
        }

        if (!positional_only and isOptionToken(token)) {
            const split = splitOption(token);
            const option = manifest.findOption(command, split.name) orelse
                return unrecognized(allocator, command, token, true);

            var value = split.value;
            if (std.mem.eql(u8, option.type, "void")) {
                if (value != null) return unrecognized(allocator, command, token, true);
            } else if (std.mem.eql(u8, option.type, "bool")) {
                if (value == null and index + 1 < arguments.len and isBoolean(arguments[index + 1])) {
                    index += 1;
                    value = arguments[index];
                }
                if (value != null and !isBoolean(value.?))
                    return invalidValue(allocator, command, option.name, value.?);
                if (value == null) value = "true";
            } else {
                if (value == null) {
                    const optional_value = option.minimumArity == 0;
                    const next_is_option = index + 1 < arguments.len and
                        isOptionToken(arguments[index + 1]);
                    if (!optional_value and index + 1 >= arguments.len)
                        return .{ .failure = .{
                            .message = try std.fmt.allocPrint(
                                allocator,
                                "Required argument missing for option: '{s}'.",
                                .{option.name},
                            ),
                            .help_command = command,
                        } };
                    if (!optional_value or (index + 1 < arguments.len and !next_is_option)) {
                        index += 1;
                        value = arguments[index];
                    }
                }
                if (value) |provided| {
                    if (!validTypedValue(option.type, provided))
                        return invalidValue(allocator, command, option.name, provided);
                    if (!inChoices(option.choices, provided))
                        return invalidValue(allocator, command, option.name, provided);
                }
            }

            if (std.mem.eql(u8, option.name, "--help")) help_requested = true;
            if (option.builtIn and std.mem.eql(u8, option.name, "--version"))
                version_requested = true;
            applyGlobal(&globals, option.name, value);
            try parsed_options.append(allocator, .{ .name = option.name, .value = value });
            continue;
        }

        if (positionals.items.len == 0) {
            if (manifest.findChild(command, token)) |child| {
                command = child;
                continue;
            }
            // Root actions with a catalog-defined default backend may accept
            // that backend's positionals without spelling the backend name.
            // Explicit child names still win above, so both `downgrade pkg`
            // and `downgrade standard pkg` resolve deterministically.
            if (command.isBranch) {
                if (manifest.findDefaultChild(command)) |default_child|
                    command = default_child;
            }
        }
        try positionals.append(allocator, token);
    }

    if (help_requested) return .{ .help = command };
    if (version_requested) return .{ .version = globals };

    if (command.isBranch and positionals.items.len == 0) {
        if (manifest.findDefaultChild(command)) |default_child| command = default_child;
    }

    for (command.options) |option| {
        if (!option.required) continue;
        var present = false;
        for (parsed_options.items) |parsed_option| {
            if (std.mem.eql(u8, parsed_option.name, option.name)) {
                present = true;
                break;
            }
        }
        if (!present) return .{ .failure = .{
            .message = try std.fmt.allocPrint(
                allocator,
                "Option '{s}' is required.",
                .{option.name},
            ),
            .help_command = command,
        } };
    }

    if (command == manifest.root() and positionals.items.len == 0) {
        command = manifest.findByPath("shelly upgrade all") orelse return error.InvalidCatalog;
    } else if (command.isBranch and positionals.items.len > 0 and command != manifest.root()) {
        return unrecognized(allocator, command, positionals.items[0], false);
    } else if (command.isBranch and !command.hasAction) {
        return .{ .failure = .{
            .message = "Required command was not provided.",
            .help_command = command,
        } };
    }

    if (try validateArguments(allocator, command, positionals.items)) |failure|
        return .{ .failure = failure };

    return .{ .dispatch = .{
        .command = command,
        .arguments = arguments,
        .positionals = try positionals.toOwnedSlice(allocator),
        .options = try parsed_options.toOwnedSlice(allocator),
        .globals = globals,
    } };
}

fn validateArguments(
    allocator: std.mem.Allocator,
    command: *const spec.Command,
    values: []const []const u8,
) !?Failure {
    var value_index: usize = 0;
    for (command.arguments, 0..) |argument, argument_index| {
        var later_minimum: usize = 0;
        for (command.arguments[argument_index + 1 ..]) |later| later_minimum += later.minimumArity;
        const available = values.len - value_index;
        if (available < argument.minimumArity + later_minimum) {
            return .{
                .message = try std.fmt.allocPrint(
                    allocator,
                    "Required argument '{s}' missing for command: '{s}'.",
                    .{ argument.name, command.name },
                ),
                .help_command = command,
            };
        }
        const maximum = argument.maximumArity orelse available;
        const take = @min(maximum, available - later_minimum);
        for (values[value_index .. value_index + take]) |value| {
            if (!validTypedValue(argument.type, value) or !inChoices(argument.choices, value)) {
                return .{
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "Cannot parse argument '{s}' for command: '{s}'.",
                        .{ value, command.name },
                    ),
                    .help_command = command,
                };
            }
        }
        value_index += take;
    }
    if (value_index < values.len)
        return (try unrecognized(allocator, command, values[value_index], false)).failure;
    return null;
}

fn unrecognized(
    allocator: std.mem.Allocator,
    command: *const spec.Command,
    token: []const u8,
    leading_help_newline: bool,
) !Outcome {
    return .{ .failure = .{
        .message = try std.fmt.allocPrint(
            allocator,
            "Unrecognized command or argument '{s}'.",
            .{token},
        ),
        .help_command = command,
        .leading_help_newline = leading_help_newline,
    } };
}

fn invalidValue(
    allocator: std.mem.Allocator,
    command: *const spec.Command,
    option_name: []const u8,
    value: []const u8,
) !Outcome {
    return .{ .failure = .{
        .message = try std.fmt.allocPrint(
            allocator,
            "Cannot parse argument '{s}' for option '{s}'.",
            .{ value, option_name },
        ),
        .help_command = command,
    } };
}

const SplitOption = struct { name: []const u8, value: ?[]const u8 };

fn splitOption(token: []const u8) SplitOption {
    if (std.mem.indexOfScalar(u8, token, '=')) |equals|
        return .{ .name = token[0..equals], .value = token[equals + 1 ..] };
    return .{ .name = token, .value = null };
}

fn isOptionToken(token: []const u8) bool {
    if (token.len > 1 and token[0] == '-') return true;
    return std.mem.eql(u8, token, "/?") or std.ascii.eqlIgnoreCase(token, "/h");
}

fn isBoolean(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "false");
}

fn validTypedValue(value_type: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, value_type, "int")) {
        _ = std.fmt.parseInt(i64, value, 10) catch return false;
    } else if (std.mem.eql(u8, value_type, "uint")) {
        _ = std.fmt.parseInt(usize, value, 10) catch return false;
    } else if (std.mem.eql(u8, value_type, "bool")) {
        return isBoolean(value);
    }
    return true;
}

fn inChoices(choices: []const []const u8, value: []const u8) bool {
    if (choices.len == 0) return true;
    for (choices) |choice| {
        if (std.ascii.eqlIgnoreCase(choice, value)) return true;
    }
    return false;
}

fn applyGlobal(globals: *GlobalOptions, name: []const u8, value: ?[]const u8) void {
    const enabled = value == null or !std.ascii.eqlIgnoreCase(value.?, "false");
    if (std.mem.eql(u8, name, "--no-confirm")) globals.no_confirm = enabled;
    if (std.mem.eql(u8, name, "--ui-mode")) globals.ui_mode = enabled;
    if (std.mem.eql(u8, name, "--json")) globals.json = enabled;
}

test "parses local options and recursive globals around command tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parse(arena.allocator(), &manifest, &.{
        "--json",
        "search",
        "standard",
        "firefox",
        "--limit",
        "25",
    });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqualStrings("shelly search standard", outcome.dispatch.command.path);
    try std.testing.expectEqualStrings("firefox", outcome.dispatch.positionals[0]);
    try std.testing.expect(outcome.dispatch.globals.json);
    try std.testing.expectEqual(@as(usize, 2), outcome.dispatch.options.len);
}

test "verbose options are not accepted by commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const long = try parse(arena.allocator(), &manifest, &.{ "search", "standard", "firefox", "--verbose" });
    try std.testing.expect(long == .failure);
    try std.testing.expectEqualStrings("Unrecognized command or argument '--verbose'.", long.failure.message);

    const short = try parse(arena.allocator(), &manifest, &.{ "install", "flatpak", "demo-git", "-v" });
    try std.testing.expect(short == .failure);
    try std.testing.expectEqualStrings("Unrecognized command or argument '-v'.", short.failure.message);
}

test "removed commands are treated as root package queries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const outcome = try parse(arena.allocator(), &manifest, &.{ "add-remotes", "flatpak", "flathub" });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqualStrings("shelly", outcome.dispatch.command.path);
    try std.testing.expectEqualStrings("add-remotes", outcome.dispatch.positionals[0]);
}

test "maps an empty invocation to upgrade all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parse(arena.allocator(), &manifest, &.{});
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqualStrings("shelly upgrade all", outcome.dispatch.command.path);
}

test "maps unknown bare values to the root search-install fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parse(arena.allocator(), &manifest, &.{ "visual", "studio", "code" });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqualStrings("shelly", outcome.dispatch.command.path);
    try std.testing.expectEqual(@as(usize, 3), outcome.dispatch.positionals.len);
    try std.testing.expectEqualStrings("visual", outcome.dispatch.positionals[0]);
    try std.testing.expectEqualStrings("code", outcome.dispatch.positionals[2]);
}

test "command-local AUR install version does not trigger program version output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const program_version = try parse(arena.allocator(), &manifest, &.{"--version"});
    try std.testing.expect(program_version == .version);
    try std.testing.expect(!program_version.version.json);

    const machine_version = try parse(arena.allocator(), &manifest, &.{ "--version", "--json" });
    try std.testing.expect(machine_version == .version);
    try std.testing.expect(machine_version.version.json);

    const install_version = try parse(arena.allocator(), &manifest, &.{
        "install",
        "aur",
        "--version",
        "demo-git",
        "deadbeef",
    });
    try std.testing.expect(install_version == .dispatch);
    try std.testing.expectEqualStrings("shelly install aur", install_version.dispatch.command.path);
    try std.testing.expectEqualStrings("--version", install_version.dispatch.options[0].name);
    try std.testing.expectEqualStrings("demo-git", install_version.dispatch.positionals[0]);
    try std.testing.expectEqualStrings("deadbeef", install_version.dispatch.positionals[1]);
}

test "maps bare sync to its catalog-defined standard type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parse(arena.allocator(), &manifest, &.{ "sync", "--force" });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqualStrings("shelly sync standard", outcome.dispatch.command.path);
    try std.testing.expectEqualStrings("--force", outcome.dispatch.options[0].name);
}

test "maps a default root action positional to its catalog-defined backend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parse(arena.allocator(), &manifest, &.{
        "downgrade",
        "--target",
        "6.12.1-1",
        "linux",
    });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqualStrings("shelly downgrade standard", outcome.dispatch.command.path);
    try std.testing.expectEqualStrings("linux", outcome.dispatch.positionals[0]);
    try std.testing.expectEqualStrings("6.12.1-1", outcome.dispatch.options[0].value.?);
}

test "parses Flatpak AppStream sync as an action-type command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parse(arena.allocator(), &manifest, &.{ "sync", "flatpak" });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqualStrings("shelly sync flatpak", outcome.dispatch.command.path);
}

test "unknown old root paths fall back to search while known commands still validate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const type_first = try parse(arena.allocator(), &manifest, &.{ "flatpak", "search", "query" });
    try std.testing.expect(type_first == .dispatch);
    try std.testing.expectEqualStrings("shelly", type_first.dispatch.command.path);

    const old_flatpak_sync = try parse(arena.allocator(), &manifest, &.{ "sync-remote-appstream", "flatpak" });
    try std.testing.expect(old_flatpak_sync == .dispatch);
    try std.testing.expectEqualStrings("shelly", old_flatpak_sync.dispatch.command.path);

    const implicit_standard = try parse(arena.allocator(), &manifest, &.{ "install", "firefox" });
    try std.testing.expect(implicit_standard == .failure);
    try std.testing.expectEqualStrings(
        "Unrecognized command or argument 'firefox'.",
        implicit_standard.failure.message,
    );

    const upgrade_all = try parse(arena.allocator(), &manifest, &.{"upgrade-all"});
    try std.testing.expect(upgrade_all == .dispatch);
    try std.testing.expectEqualStrings("shelly", upgrade_all.dispatch.command.path);
}
