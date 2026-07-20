const std = @import("std");
const catalog = @import("catalog.zig");
const spec = @import("spec.zig");

const Writer = std.Io.Writer;

const Row = struct {
    label: []const u8,
    description: []const u8,
};

pub fn render(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    command: *const spec.Command,
    writer: *Writer,
) !void {
    if (!command.hidden) {
        const action_branch = isActionBranch(manifest, command);
        const standalone_default = standaloneDefaultChild(manifest, command);
        const detail_command = standalone_default orelse command;
        if (detail_command.description) |description|
            try writer.print("Description:\n  {s}\n\n", .{description});

        try writer.print("Usage:\n  {s}", .{command.path});
        if (standalone_default) |default_child| {
            for (default_child.arguments) |argument| {
                try writer.writeByte(' ');
                try writeUsageArgument(allocator, writer, argument);
            }
        } else if (command.isBranch) {
            try writer.writeAll(if (action_branch and !usesNamedSubcommands(command)) " [type]" else " [command]");
        } else {
            for (command.arguments) |argument| {
                try writer.writeByte(' ');
                try writeUsageArgument(allocator, writer, argument);
            }
        }
        try writer.writeAll(" [options]\n");

        if (detail_command.arguments.len > 0) {
            try writer.writeAll("\nArguments:\n");
            var rows: std.ArrayList(Row) = .empty;
            for (detail_command.arguments) |argument| {
                try rows.append(allocator, .{
                    .label = try argumentLabel(allocator, argument),
                    .description = argument.description orelse "",
                });
            }
            try writeRows(writer, rows.items);
        }

        var option_rows: std.ArrayList(Row) = .empty;
        if (command == manifest.root()) {
            for (command.options) |option| {
                if (!option.hidden and !option.builtIn)
                    try appendOptionRow(allocator, &option_rows, option);
            }
            for (command.options) |option| {
                if (!option.hidden and option.builtIn)
                    try appendOptionRow(allocator, &option_rows, option);
            }
        } else {
            for (detail_command.options) |option| {
                if (!option.hidden) try appendOptionRow(allocator, &option_rows, option);
            }
            for (manifest.root().options) |option| {
                if (!option.hidden and option.recursive)
                    try appendOptionRow(allocator, &option_rows, option);
            }
        }
        if (option_rows.items.len > 0) {
            try writer.writeAll("\nOptions:\n");
            try writeRows(writer, option_rows.items);
        }

        if (action_branch and standalone_default == null)
            try writeActionModifiers(allocator, manifest, command, writer);

        var command_rows: std.ArrayList(Row) = .empty;
        if (standalone_default == null) {
            for (manifest.commands) |child| {
                const parent_path = child.parentPath orelse continue;
                if (!std.mem.eql(u8, parent_path, command.path) or child.hidden) continue;
                var label: std.ArrayList(u8) = .empty;
                try label.appendSlice(allocator, if (action_branch) child.path else child.name);
                for (child.arguments) |argument| {
                    try label.append(allocator, ' ');
                    try label.appendSlice(allocator, try argumentLabel(allocator, argument));
                }
                var description: []const u8 = child.description orelse "";
                if (child.actionCode != null and child.typeCode != null) {
                    description = try std.fmt.allocPrint(
                        allocator,
                        "{s} [shortcode: -{c}{c}]",
                        .{ description, child.actionCode.?, child.typeCode.? },
                    );
                }
                try command_rows.append(allocator, .{
                    .label = try label.toOwnedSlice(allocator),
                    .description = description,
                });
            }
        }
        if (command_rows.items.len > 0) {
            try writer.writeAll("\nCommands:\n");
            try writeRows(writer, command_rows.items);
        }

        try writer.writeByte('\n');
    }
    if (command == manifest.root()) {
        try writeRootShortcodeHelp(allocator, manifest, writer);
    } else {
        try writeCommandExamples(allocator, manifest, command, writer);
    }
    try writer.writeByte('\n');
}

fn isActionBranch(manifest: *const spec.Manifest, command: *const spec.Command) bool {
    const parent_path = command.parentPath orelse return false;
    return command.isBranch and std.mem.eql(u8, parent_path, manifest.root().path);
}

fn standaloneDefaultChild(
    manifest: *const spec.Manifest,
    command: *const spec.Command,
) ?*const spec.Command {
    if (!isActionBranch(manifest, command)) return null;
    const default_child = manifest.findDefaultChild(command) orelse return null;
    var child_count: usize = 0;
    for (manifest.commands) |candidate| {
        const parent_path = candidate.parentPath orelse continue;
        if (std.mem.eql(u8, parent_path, command.path)) child_count += 1;
    }
    return if (child_count == 1) default_child else null;
}

fn writeActionModifiers(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    action: *const spec.Command,
    writer: *Writer,
) !void {
    var has_modifiers = false;
    for (manifest.commands) |child| {
        if (!isChildOf(&child, action) or child.options.len == 0) continue;
        has_modifiers = true;
        break;
    }
    if (!has_modifiers) return;

    try writer.writeAll(if (usesNamedSubcommands(action))
        "\nModifiers by Command:\n"
    else
        "\nModifiers by Type:\n");

    var shared_rows: std.ArrayList(Row) = .empty;
    for (manifest.commands) |child| {
        if (!isChildOf(&child, action)) continue;
        for (child.options) |option| {
            if (option.hidden or option.builtIn or optionTypeCount(manifest, action, option.name) < 2) continue;
            if (hasOptionRow(shared_rows.items, option.name)) continue;

            var type_names: std.ArrayList(u8) = .empty;
            for (manifest.commands) |candidate| {
                if (!isChildOf(&candidate, action) or findLocalOption(&candidate, option.name) == null) continue;
                if (type_names.items.len > 0) try type_names.appendSlice(allocator, ", ");
                try type_names.appendSlice(allocator, candidate.name);
            }
            const description = if (usesNamedSubcommands(action))
                try std.fmt.allocPrint(
                    allocator,
                    "{s} [commands: {s}]",
                    .{ option.description orelse "", type_names.items },
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "{s} [types: {s}]",
                    .{ option.description orelse "", type_names.items },
                );
            try shared_rows.append(allocator, .{
                .label = try optionLabel(allocator, option),
                .description = description,
            });
        }
    }
    if (shared_rows.items.len > 0) {
        try writer.writeAll("  Shared:\n");
        try writeIndentedRows(writer, shared_rows.items, 4);
    }

    for (manifest.commands) |child| {
        if (!isChildOf(&child, action)) continue;
        var rows: std.ArrayList(Row) = .empty;
        for (child.options) |option| {
            if (option.hidden or option.builtIn or optionTypeCount(manifest, action, option.name) > 1) continue;
            var description: []const u8 = option.description orelse "";
            if (option.hasExplicitDefault) {
                description = try std.fmt.allocPrint(
                    allocator,
                    "{s} [default: {s}]",
                    .{ description, try formatDefault(allocator, option.defaultValue) },
                );
            }
            try rows.append(allocator, .{
                .label = try optionLabel(allocator, option),
                .description = description,
            });
        }
        if (rows.items.len == 0) continue;
        if (usesNamedSubcommands(action))
            try writer.print("  {s}:\n", .{child.name})
        else
            try writer.print("  {s} only:\n", .{child.name});
        try writeIndentedRows(writer, rows.items, 4);
    }
}

fn isChildOf(command: *const spec.Command, parent: *const spec.Command) bool {
    const parent_path = command.parentPath orelse return false;
    return std.mem.eql(u8, parent_path, parent.path);
}

fn usesNamedSubcommands(command: *const spec.Command) bool {
    return std.mem.eql(u8, command.name, "mark") or
        std.mem.eql(u8, command.name, "keyring") or
        std.mem.eql(u8, command.name, "config");
}

fn optionTypeCount(manifest: *const spec.Manifest, action: *const spec.Command, name: []const u8) usize {
    if (usesNamedSubcommands(action)) return 1;
    var count: usize = 0;
    for (manifest.commands) |candidate| {
        if (isChildOf(&candidate, action) and findLocalOption(&candidate, name) != null) count += 1;
    }
    return count;
}

fn findLocalOption(command: *const spec.Command, name: []const u8) ?*const spec.Option {
    for (command.options) |*option| {
        if (std.mem.eql(u8, option.name, name)) return option;
    }
    return null;
}

fn hasOptionRow(rows: []const Row, name: []const u8) bool {
    for (rows) |row| {
        if (std.mem.indexOf(u8, row.label, name) != null) return true;
    }
    return false;
}

fn writeIndentedRows(writer: *Writer, rows: []const Row, indent: usize) !void {
    var width: usize = 0;
    for (rows) |row| width = @max(width, row.label.len);
    for (rows) |row| {
        try writer.splatByteAll(' ', indent);
        try writer.print("{s}", .{row.label});
        try writer.splatByteAll(' ', width - row.label.len + 2);
        try writer.print("{s}\n", .{row.description});
    }
}

fn writeRootShortcodeHelp(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    writer: *Writer,
) !void {
    try writer.writeAll(
        \\Shortcodes and top-level examples:
        \\  Grammar: -<UppercaseAction><lowercaseTypeOrCommand><modifiers...> [positionals]
        \\  Uppercase Action selects the operation, the lowercase selector chooses its target or subcommand, and
        \\  modifiers are that action/type pair's short flags (case-sensitive).
        \\  Standalone root actions such as downgrade omit the lowercase Type.
        \\  Search may combine standard, AUR, and Flatpak types (s/a/f); modifiers apply
        \\  only to selected search types that support them.
        \\  List also accepts the compatibility selectors I/A/F used in the examples.
        \\
        \\  Types:
        \\
    );
    for (catalog.types) |command_type| {
        const code = command_type.code orelse continue;
        try writer.print("    {c}  {s}\n", .{ code, command_type.name });
    }
    try writer.writeByte('\n');

    var rows: std.ArrayList(Row) = .empty;
    for (manifest.commands) |*action| {
        const parent_path = action.parentPath orelse continue;
        if (!std.mem.eql(u8, parent_path, manifest.root().path)) continue;
        if (try appendRootActionExample(allocator, manifest, &rows, action)) continue;
    }
    try writeIndentedRows(writer, rows.items, 4);
    try writer.writeAll("\n  Run `shelly <command> --help` for examples within a command.\n");
    try writer.writeAll("  In shortcode mode use --ui-mode instead of -U.\n");
}

fn appendRootActionExample(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    rows: *std.ArrayList(Row),
    action: *const spec.Command,
) !bool {
    if (!std.mem.eql(u8, action.name, "upgrade")) {
        if (actionHelpShortcode(action)) |help_shortcode| {
            try rows.append(allocator, .{
                .label = help_shortcode,
                .description = try std.fmt.allocPrint(allocator, "Show help for `{s}`", .{action.path}),
            });
            return true;
        }
    }

    const child = rootExampleChild(manifest, action) orelse return false;
    const shortcode = try shortcodeUsage(allocator, child, null) orelse return false;
    const invocation = if (child.defaultForAction)
        try longInvocationAtPath(allocator, action.path, child.arguments)
    else
        try longInvocation(allocator, child);
    try rows.append(allocator, .{
        .label = shortcode,
        .description = invocation,
    });
    return true;
}

fn rootExampleChild(manifest: *const spec.Manifest, action: *const spec.Command) ?*const spec.Command {
    if (std.mem.eql(u8, action.name, "upgrade") or std.mem.eql(u8, action.name, "list-updates")) {
        for (manifest.commands) |*candidate| {
            if (!isChildOf(candidate, action) or !std.mem.eql(u8, candidate.name, "all")) continue;
            return candidate;
        }
    }
    if (manifest.findDefaultChild(action)) |default_child| return default_child;
    for (manifest.commands) |*candidate| {
        if (isChildOf(candidate, action) and candidate.actionCode != null) return candidate;
    }
    return null;
}

fn writeCommandExamples(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    command: *const spec.Command,
    writer: *Writer,
) !void {
    const standalone_default = standaloneDefaultChild(manifest, command);
    if (command.isBranch and standalone_default == null) {
        try writeActionExamples(allocator, manifest, command, writer);
        return;
    }
    try writeLeafExamples(
        allocator,
        standalone_default orelse command,
        if (standalone_default != null) command.path else null,
        writer,
    );
}

fn writeActionExamples(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    action: *const spec.Command,
    writer: *Writer,
) !void {
    var rows: std.ArrayList(Row) = .empty;
    if (actionHelpShortcode(action)) |help_shortcode| {
        try rows.append(allocator, .{
            .label = help_shortcode,
            .description = try std.fmt.allocPrint(allocator, "Show help for `{s}`", .{action.path}),
        });
    }
    for (manifest.commands) |*child| {
        if (!isChildOf(child, action)) continue;
        const shortcode = try shortcodeUsage(allocator, child, null) orelse continue;
        try rows.append(allocator, .{
            .label = shortcode,
            .description = try longInvocation(allocator, child),
        });
    }
    if (rows.items.len == 0) return;
    try writer.writeAll("Examples:\n");
    try writeRows(writer, rows.items);
}

fn writeLeafExamples(
    allocator: std.mem.Allocator,
    command: *const spec.Command,
    display_path: ?[]const u8,
    writer: *Writer,
) !void {
    const base_shortcode = try shortcodeUsage(allocator, command, null) orelse return;
    var rows: std.ArrayList(Row) = .empty;
    try rows.append(allocator, .{
        .label = if (std.mem.eql(u8, command.path, "shelly backup utility"))
            try std.fmt.allocPrint(
                allocator,
                "{s} --export",
                .{display_path orelse command.path},
            )
        else if (display_path) |path|
            try longInvocationAtPath(allocator, path, command.arguments)
        else
            try longInvocation(allocator, command),
        .description = "Long form",
    });
    try rows.append(allocator, .{
        .label = base_shortcode,
        .description = "Shortcode",
    });
    if (std.mem.eql(u8, command.path, "shelly sync appimage")) {
        try rows.append(allocator, .{
            .label = "-CI <appimage> <url> <type>",
            .description = "Compatibility shortcode for update configuration",
        });
    }

    for (command.options) |*option| {
        if (option.hidden or option.builtIn) continue;
        if (shortOptionAlias(option) == null) continue;
        const usage = try shortcodeUsage(allocator, command, option) orelse continue;
        try rows.append(allocator, .{
            .label = usage,
            .description = option.description orelse "",
        });
    }

    const help_usage = try std.fmt.allocPrint(allocator, "{s}h", .{try shortcodePrefix(allocator, command, false) orelse return});
    try rows.append(allocator, .{
        .label = help_usage,
        .description = "Show help for this command",
    });

    try writer.writeAll("Examples:\n");
    try writeRows(writer, rows.items);
}

fn actionHelpShortcode(action: *const spec.Command) ?[]const u8 {
    if (std.mem.eql(u8, action.name, "install")) return "-Ih";
    if (std.mem.eql(u8, action.name, "upgrade")) return "-Uh";
    if (std.mem.eql(u8, action.name, "mark")) return "-Mh";
    if (std.mem.eql(u8, action.name, "keyring")) return "-K / -Kh";
    if (std.mem.eql(u8, action.name, "config")) return "-Ch";
    return null;
}

fn shortcodeUsage(
    allocator: std.mem.Allocator,
    command: *const spec.Command,
    option: ?*const spec.Option,
) !?[]const u8 {
    var usage: std.ArrayList(u8) = .empty;
    try usage.appendSlice(allocator, try shortcodePrefix(allocator, command, option == null) orelse return null);
    if (option) |selected_option| {
        if (std.mem.eql(u8, command.path, "shelly backup utility") and
            !std.mem.eql(u8, selected_option.name, "--export"))
            try usage.append(allocator, 'e');
        const alias = shortOptionAlias(selected_option) orelse return null;
        if (modifierMustBeSeparate(command, alias[1])) {
            try usage.appendSlice(allocator, " ");
            try usage.appendSlice(allocator, alias);
        } else {
            try usage.append(allocator, alias[1]);
        }
        if (!std.mem.eql(u8, selected_option.type, "void") and
            !std.mem.eql(u8, selected_option.type, "bool"))
        {
            try usage.append(allocator, ' ');
            if (selected_option.minimumArity == 0) try usage.append(allocator, '[');
            try usage.append(allocator, '<');
            try usage.appendSlice(allocator, std.mem.trimStart(u8, selected_option.name, "-"));
            try usage.append(allocator, '>');
            if (selected_option.minimumArity == 0) try usage.append(allocator, ']');
        }
    }

    if (option) |selected_option| {
        if (std.mem.eql(u8, command.path, "shelly run flatpak") and
            std.mem.eql(u8, selected_option.name, "--list"))
        {
            const result: []const u8 = try usage.toOwnedSlice(allocator);
            return result;
        }
    }

    if (option) |selected_option| {
        if (std.mem.eql(u8, command.path, "shelly install aur") and
            std.mem.eql(u8, selected_option.name, "--version"))
        {
            try usage.appendSlice(allocator, " <package> <commit>");
            const result: []const u8 = try usage.toOwnedSlice(allocator);
            return result;
        }
    }
    try appendArgumentsToUsage(allocator, &usage, command.arguments);
    const result: []const u8 = try usage.toOwnedSlice(allocator);
    return result;
}

fn shortcodePrefix(
    allocator: std.mem.Allocator,
    command: *const spec.Command,
    allow_bare_alias: bool,
) !?[]const u8 {
    const action_code = command.actionCode orelse return null;
    if (allow_bare_alias and
        ((std.mem.eql(u8, command.path, "shelly upgrade all") and action_code == 'U') or
            (std.mem.eql(u8, command.path, "shelly list-updates all") and action_code == 'P')))
    {
        const prefix: []const u8 = try std.fmt.allocPrint(allocator, "-{c}", .{action_code});
        return prefix;
    }
    const type_code = displayTypeCode(command) orelse {
        const prefix: []const u8 = try std.fmt.allocPrint(allocator, "-{c}", .{action_code});
        return prefix;
    };
    const prefix: []const u8 = try std.fmt.allocPrint(allocator, "-{c}{c}", .{ action_code, type_code });
    return prefix;
}

fn modifierMustBeSeparate(command: *const spec.Command, modifier: u8) bool {
    const action_code = command.actionCode orelse return false;
    if (action_code != 'S') return false;
    const variant = catalog.findVariantByCodes(action_code, modifier) orelse return false;
    return std.mem.eql(u8, variant.action, "search");
}

fn displayTypeCode(command: *const spec.Command) ?u8 {
    const type_code = command.typeCode orelse return null;
    if (!std.mem.startsWith(u8, command.path, "shelly list ")) return type_code;
    return switch (type_code) {
        'i' => 'I',
        'a' => 'A',
        'f' => 'F',
        else => type_code,
    };
}

fn longInvocation(allocator: std.mem.Allocator, command: *const spec.Command) ![]const u8 {
    return longInvocationAtPath(allocator, command.path, command.arguments);
}

fn longInvocationAtPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    arguments: []const spec.Argument,
) ![]const u8 {
    var usage: std.ArrayList(u8) = .empty;
    try usage.appendSlice(allocator, path);
    try appendArgumentsToUsage(allocator, &usage, arguments);
    return usage.toOwnedSlice(allocator);
}

fn appendArgumentsToUsage(
    allocator: std.mem.Allocator,
    usage: *std.ArrayList(u8),
    arguments: []const spec.Argument,
) !void {
    for (arguments) |argument| {
        try usage.append(allocator, ' ');
        if (argument.minimumArity == 0) try usage.append(allocator, '[');
        try usage.append(allocator, '<');
        try usage.appendSlice(allocator, argument.name);
        try usage.append(allocator, '>');
        if (std.mem.endsWith(u8, argument.type, "[]")) try usage.appendSlice(allocator, "...");
        if (argument.minimumArity == 0) try usage.append(allocator, ']');
    }
}

fn shortOptionAlias(option: *const spec.Option) ?[]const u8 {
    for (option.aliases) |alias| {
        if (alias.len == 2 and alias[0] == '-' and alias[1] != '-') return alias;
    }
    return null;
}

fn appendOptionRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    option: spec.Option,
) !void {
    var description: []const u8 = option.description orelse "";
    if (option.hasExplicitDefault) {
        const value = try formatDefault(allocator, option.defaultValue);
        description = try std.fmt.allocPrint(allocator, "{s} [default: {s}]", .{ description, value });
    }
    try rows.append(allocator, .{
        .label = try optionLabel(allocator, option),
        .description = description,
    });
}

fn writeRows(writer: *Writer, rows: []const Row) !void {
    var width: usize = 0;
    for (rows) |row| width = @max(width, row.label.len);
    for (rows) |row| {
        try writer.print("  {s}", .{row.label});
        try writer.splatByteAll(' ', width - row.label.len + 2);
        try writer.print("{s}\n", .{row.description});
    }
}

fn writeUsageArgument(allocator: std.mem.Allocator, writer: *Writer, argument: spec.Argument) !void {
    const label = try std.fmt.allocPrint(allocator, "<{s}>", .{argument.name});
    const is_many = std.mem.endsWith(u8, argument.type, "[]");
    if (argument.minimumArity == 0) try writer.writeByte('[');
    try writer.writeAll(label);
    if (is_many) try writer.writeAll("...");
    if (argument.minimumArity == 0) try writer.writeByte(']');
}

fn argumentLabel(allocator: std.mem.Allocator, argument: spec.Argument) ![]const u8 {
    if (argument.choices.len == 0)
        return std.fmt.allocPrint(allocator, "<{s}>", .{argument.name});

    const choices = try allocator.dupe([]const u8, argument.choices);
    std.mem.sort([]const u8, choices, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    var label: std.ArrayList(u8) = .empty;
    try label.append(allocator, '<');
    for (choices, 0..) |choice, index| {
        if (index > 0) try label.append(allocator, '|');
        try label.appendSlice(allocator, choice);
    }
    try label.append(allocator, '>');
    return label.toOwnedSlice(allocator);
}

fn optionLabel(allocator: std.mem.Allocator, option: spec.Option) ![]const u8 {
    var label: std.ArrayList(u8) = .empty;
    var needs_separator = false;
    for (option.aliases) |alias| {
        if (!std.mem.startsWith(u8, alias, "-") or std.mem.startsWith(u8, alias, "--")) continue;
        if (needs_separator) try label.appendSlice(allocator, ", ");
        try label.appendSlice(allocator, alias);
        needs_separator = true;
    }
    if (needs_separator) try label.appendSlice(allocator, ", ");
    try label.appendSlice(allocator, option.name);
    for (option.aliases) |alias| {
        if (!std.mem.startsWith(u8, alias, "--")) continue;
        try label.appendSlice(allocator, ", ");
        try label.appendSlice(allocator, alias);
    }
    if (!std.mem.eql(u8, option.type, "void") and !std.mem.eql(u8, option.type, "bool")) {
        try label.append(allocator, ' ');
        if (option.minimumArity == 0) try label.append(allocator, '[');
        try label.append(allocator, '<');
        try label.appendSlice(allocator, std.mem.trimStart(u8, option.name, "-"));
        try label.append(allocator, '>');
        if (option.minimumArity == 0) try label.append(allocator, ']');
    }
    if (option.required) try label.appendSlice(allocator, " (REQUIRED)");
    return label.toOwnedSlice(allocator);
}

fn formatDefault(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const u8 {
    const actual = value orelse return "null";
    return switch (actual) {
        .null => "null",
        .bool => |boolean| if (boolean) "true" else "false",
        .integer => |integer| std.fmt.allocPrint(allocator, "{d}", .{integer}),
        .float => |float| std.fmt.allocPrint(allocator, "{d}", .{float}),
        .number_string => |number| number,
        .string => |string| string,
        else => "",
    };
}

test "action help shows shared and type-specific modifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const command = manifest.findByPath("shelly install").?;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try render(arena.allocator(), &manifest, command, &output.writer);
    const rendered = output.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "shelly install [type]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Modifiers by Type:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Shared:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--build-deps") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[types: standard, aur]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "aur only:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--chroot") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-v, --version") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-e, --ref-file") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-u, --bundle") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "shelly install aur <packages>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\nTypes:\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[shortcode: -Ia]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Implementation:") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[implementation:") == null);
    for ([_][]const u8{ "-Ih", "-Is [<packages>...]", "-Ii <location>", "-Ia [<packages>...]", "-If <package>" }) |needle|
        try std.testing.expect(std.mem.indexOf(u8, rendered, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Top-level examples:") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-Ua") == null);
}

test "sync action help lists standard AppImage and Flatpak variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const command = manifest.findByPath("shelly sync").?;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try render(arena.allocator(), &manifest, command, &output.writer);
    const rendered = output.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "standard") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "appimage") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "flatpak") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[shortcode: -Ys]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[shortcode: -Yi]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[shortcode: -Yf]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Implementation:") == null);
}

test "upgrade action help documents every backend and its actual modifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const command = manifest.findByPath("shelly upgrade").?;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try render(arena.allocator(), &manifest, command, &output.writer);
    const rendered = output.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-Uh") != null);
    for ([_][]const u8{ "[shortcode: -Us]", "[shortcode: -Ux]", "[shortcode: -Ui]", "[shortcode: -Ua]", "[shortcode: -Uf]" }) |needle|
        try std.testing.expect(std.mem.indexOf(u8, rendered, needle) != null);
    for ([_][]const u8{ "--all", "--no-repo", "--no-aur", "--no-flatpak", "--no-appimage", "--check", "--singlepane" }) |needle|
        try std.testing.expect(std.mem.indexOf(u8, rendered, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Implementation:") == null);
}

test "update action help documents targeted native backends and shortcodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const command = manifest.findByPath("shelly update").?;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try render(arena.allocator(), &manifest, command, &output.writer);
    const rendered = output.writer.buffered();
    for ([_][]const u8{ "[shortcode: -Es]", "[shortcode: -Ea]", "[shortcode: -Ef]" }) |needle|
        try std.testing.expect(std.mem.indexOf(u8, rendered, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Implementation:") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "partial-upgrade warning and confirmation") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--check") != null);
}

test "downgrade help renders its single default backend as a root command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    var rendered = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer rendered.deinit();

    try render(
        arena.allocator(),
        &manifest,
        manifest.findByPath("shelly downgrade").?,
        &rendered.writer,
    );
    const value = rendered.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, value, "shelly downgrade [<package>] [options]") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "shelly downgrade [type]") == null);
    try std.testing.expect(std.mem.indexOf(u8, value, "--list-options") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "Implementation:") == null);
    try std.testing.expect(std.mem.indexOf(u8, value, "shelly downgrade [<package>]  Long form") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "-D [<package>]") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "-Do [<package>]") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "-Ds [<package>]") == null);
}

test "purify action help documents native standard and Flatpak backends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const command = manifest.findByPath("shelly purify").?;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try render(arena.allocator(), &manifest, command, &output.writer);
    const rendered = output.writer.buffered();
    for ([_][]const u8{ "[shortcode: -Zs]", "[shortcode: -Zf]", "--dry-run", "--orphans", "--cache" }) |needle|
        try std.testing.expect(std.mem.indexOf(u8, rendered, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[default: 3]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Implementation:") == null);
}

test "leaf help describes the selected type without implementation metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try render(
        arena.allocator(),
        &manifest,
        manifest.findByPath("shelly search flatpak").?,
        &output.writer,
    );
    const rendered = output.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Search cached AppStream catalogs") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Implementation:") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "AppstreamManager.getAllRemoteCatalogs") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Flathub") == null);
}

test "root help combines shortcodes with implemented top-level command examples" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try render(arena.allocator(), &manifest, manifest.root(), &output.writer);
    const rendered = output.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Implementation:") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[implementation:") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-<UppercaseAction><lowercaseTypeOrCommand><modifiers...>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Shortcodes and top-level examples:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\n  Top-level examples:") == null);
    for ([_][]const u8{ "-Ss [<package>]", "-Ih", "-U", "-D [<package>]", "-Mh", "-P", "-Ls", "-C", "-K / -Kh" }) |shortcode|
        try std.testing.expect(std.mem.indexOf(u8, rendered, shortcode) != null);
    for ([_][]const u8{ "-Ife", "-Ifu", "-Iav", "-Mga", "-Ki", "-Ks", "-Sap", "-Ssa", "-Ssafv" }) |nested_example|
        try std.testing.expect(std.mem.indexOf(u8, rendered, nested_example) == null);
    for ([_][]const u8{ "sync-meta", "configure-updates", "running", "get-remote-appstream", "list-remotes", "add-remotes", "remove-remotes", "app-remote-info" }) |unimplemented|
        try std.testing.expect(std.mem.indexOf(u8, rendered, unimplemented) == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Search may combine standard, AUR, and Flatpak types (s/a/f)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Run `shelly <command> --help` for examples within a command.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\n    s  standard\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\n    S  standard\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-<Type><Action>") == null);
}

test "named action help shows only examples within that action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try render(
        arena.allocator(),
        &manifest,
        manifest.findByPath("shelly keyring").?,
        &output.writer,
    );
    const rendered = output.writer.buffered();
    for ([_][]const u8{ "-K / -Kh", "-Ki", "-Kl", "-Kr", "-Ks <keys>...", "-Kp [<keys>...]", "-Kv <keys>..." }) |shortcode|
        try std.testing.expect(std.mem.indexOf(u8, rendered, shortcode) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Top-level examples:") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-Ih") == null);
}

test "leaf help shows long-form and modifier shortcode usage for that command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try render(
        arena.allocator(),
        &manifest,
        manifest.findByPath("shelly install flatpak").?,
        &output.writer,
    );
    const rendered = output.writer.buffered();
    for ([_][]const u8{
        "shelly install flatpak <package>  Long form",
        "-If <package>",
        "-Ifr <remote> <package>",
        "-Iff <package>",
        "-Ifb <branch> <package>",
        "-Ife <package>",
        "-Ifu <package>",
        "-Ifh",
    }) |example| try std.testing.expect(std.mem.indexOf(u8, rendered, example) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Top-level examples:") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-Ua") == null);
}

test "leaf examples keep ambiguous and bare-alias modifiers executable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    var aur_search = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aur_search.deinit();
    try render(
        arena.allocator(),
        &manifest,
        manifest.findByPath("shelly search aur").?,
        &aur_search.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, aur_search.writer.buffered(), "-Sa -s <query>...") != null);
    try std.testing.expect(std.mem.indexOf(u8, aur_search.writer.buffered(), "-Sas <query>...") == null);

    var upgrade_all = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer upgrade_all.deinit();
    try render(
        arena.allocator(),
        &manifest,
        manifest.findByPath("shelly upgrade all").?,
        &upgrade_all.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, upgrade_all.writer.buffered(), "-U                  Shortcode") != null);
    try std.testing.expect(std.mem.indexOf(u8, upgrade_all.writer.buffered(), "-Uxh") != null);
    try std.testing.expect(std.mem.indexOf(u8, upgrade_all.writer.buffered(), "-Uh") == null);
}
