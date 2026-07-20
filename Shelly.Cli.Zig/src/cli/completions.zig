const std = @import("std");
const spec = @import("spec.zig");

pub const Shell = enum {
    bash,
    fish,
    zsh,

    pub fn parse(value: []const u8) ?Shell {
        if (std.ascii.eqlIgnoreCase(value, "bash")) return .bash;
        if (std.ascii.eqlIgnoreCase(value, "fish")) return .fish;
        if (std.ascii.eqlIgnoreCase(value, "zsh")) return .zsh;
        return null;
    }
};

pub fn render(
    manifest: *const spec.Manifest,
    shell: Shell,
    writer: *std.Io.Writer,
) !void {
    switch (shell) {
        .bash => try renderBash(manifest, writer),
        .fish => try renderFish(manifest, writer),
        .zsh => try renderZsh(manifest, writer),
    }
}

fn renderBash(manifest: *const spec.Manifest, writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\# Bash completions for shelly
        \\# Auto-generated from the native Shelly CLI catalog. Do not edit.
        \\_shelly() {
        \\    local cur prev action selector
        \\    COMPREPLY=()
        \\    cur="${COMP_WORDS[COMP_CWORD]}"
        \\    prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\    action="${COMP_WORDS[1]}"
        \\    selector="${COMP_WORDS[2]}"
        \\
        \\    if (( COMP_CWORD == 1 )); then
        \\        COMPREPLY=( $(compgen -W '
    );
    try writeChildNames(manifest, manifest.root(), writer);
    try writer.writeByte(' ');
    try writeOptionWords(manifest.root().options, writer);
    try writer.writeAll(
        \\' -- "$cur") )
        \\        return
        \\    fi
        \\
        \\    case "$action" in
        \\
    );

    for (manifest.commands) |*action| {
        if (!isChildOf(action, manifest.root())) continue;
        try writer.print("        {s})\n", .{action.name});
        try writeBashChoiceCases(manifest, action, writer);
        const default_child = manifest.findDefaultChild(action);
        if (default_child) |child| {
            try writer.writeAll("            if (( COMP_CWORD == 2 )); then\n                COMPREPLY=( $(compgen -W '");
            try writeNonDefaultChildNames(manifest, action, child, writer);
            if (hasNonDefaultChildren(manifest, action, child)) try writer.writeByte(' ');
            try writeEffectiveOptionWords(manifest, child, writer);
            try writer.writeAll("' -- \"$cur\") )\n                return\n            fi\n");
            try writer.writeAll("            case \"$selector\" in\n");
            for (manifest.commands) |*candidate| {
                if (!isChildOf(candidate, action) or candidate == child) continue;
                try writer.print("                {s}) COMPREPLY=( $(compgen -W '", .{candidate.name});
                try writeEffectiveOptionWords(manifest, candidate, writer);
                try writer.writeAll("' -- \"$cur\") ) ;;\n");
            }
            try writer.writeAll("                *) COMPREPLY=( $(compgen -W '");
            try writeEffectiveOptionWords(manifest, child, writer);
            try writer.writeAll("' -- \"$cur\") ) ;;\n            esac\n");
        } else {
            try writer.writeAll("            if (( COMP_CWORD == 2 )); then\n                COMPREPLY=( $(compgen -W '");
            try writeChildNames(manifest, action, writer);
            try writer.writeAll("' -- \"$cur\") )\n                return\n            fi\n");
            try writer.writeAll("            case \"$selector\" in\n");
            for (manifest.commands) |*child| {
                if (!isChildOf(child, action)) continue;
                try writer.print("                {s}) COMPREPLY=( $(compgen -W '", .{child.name});
                try writeEffectiveOptionWords(manifest, child, writer);
                try writer.writeAll("' -- \"$cur\") ) ;;\n");
            }
            try writer.writeAll("            esac\n");
        }
        try writer.writeAll("            ;;\n");
    }
    try writer.writeAll(
        \\    esac
        \\}
        \\complete -F _shelly shelly
        \\
    );
}

fn writeBashChoiceCases(
    manifest: *const spec.Manifest,
    action: *const spec.Command,
    writer: *std.Io.Writer,
) !void {
    var wrote_case = false;
    for (manifest.commands) |*child| {
        if (!isChildOf(child, action)) continue;
        for (child.options) |option| {
            if (option.choices.len == 0) continue;
            if (!wrote_case) {
                try writer.writeAll("            case \"$prev\" in\n");
                wrote_case = true;
            }
            try writer.writeAll("                ");
            try writeBashPattern(option, writer);
            try writer.writeAll(") COMPREPLY=( $(compgen -W '");
            try writeWords(option.choices, writer);
            try writer.writeAll("' -- \"$cur\") ); return ;;\n");
        }
    }
    if (wrote_case) try writer.writeAll("            esac\n");
}

fn writeBashPattern(option: spec.Option, writer: *std.Io.Writer) !void {
    try writer.writeAll(option.name);
    for (option.aliases) |alias| try writer.print("|{s}", .{alias});
}

fn renderFish(manifest: *const spec.Manifest, writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\# Fish completions for shelly
        \\# Auto-generated from the native Shelly CLI catalog. Do not edit.
        \\complete -c shelly -f
        \\
    );
    for (manifest.root().options) |option| {
        try writeFishOption(
            option,
            if (option.recursive) null else "__fish_use_subcommand",
            writer,
        );
    }
    try writer.writeByte('\n');

    for (manifest.commands) |*action| {
        if (!isChildOf(action, manifest.root())) continue;
        try writer.print("complete -c shelly -f -n '__fish_use_subcommand' -a '{s}' -d '", .{action.name});
        try writeFishEscaped(writer, action.description orelse "");
        try writer.writeAll("'\n");

        const default_child = manifest.findDefaultChild(action);
        for (manifest.commands) |*child| {
            if (!isChildOf(child, action) or child == default_child) continue;
            try writer.print("complete -c shelly -f -n '__fish_seen_subcommand_from {s}; and not __fish_seen_subcommand_from ", .{action.name});
            try writeChildNames(manifest, action, writer);
            try writer.print("' -a '{s}' -d '", .{child.name});
            try writeFishEscaped(writer, child.description orelse "");
            try writer.writeAll("'\n");
        }

        if (default_child) |child| {
            var condition = std.Io.Writer.Allocating.init(std.heap.page_allocator);
            defer condition.deinit();
            try condition.writer.print("__fish_seen_subcommand_from {s}", .{action.name});
            for (manifest.commands) |*other| {
                if (!isChildOf(other, action) or other == child) continue;
                try condition.writer.print("; and not __fish_seen_subcommand_from {s}", .{other.name});
            }
            for (child.options) |option| try writeFishOption(option, condition.writer.buffered(), writer);
        }
        for (manifest.commands) |*child| {
            if (!isChildOf(child, action) or child == default_child) continue;
            var condition = std.Io.Writer.Allocating.init(std.heap.page_allocator);
            defer condition.deinit();
            try condition.writer.print("__fish_seen_subcommand_from {s}; and __fish_seen_subcommand_from {s}", .{ action.name, child.name });
            for (child.options) |option| try writeFishOption(option, condition.writer.buffered(), writer);
        }
    }
}

fn writeFishOption(option: spec.Option, condition: ?[]const u8, writer: *std.Io.Writer) !void {
    if (option.hidden) return;
    try writer.writeAll("complete -c shelly -f");
    if (condition) |value| try writer.print(" -n '{s}'", .{value});
    try writeFishNames(option, writer);
    if (option.description) |description| {
        try writer.writeAll(" -d '");
        try writeFishEscaped(writer, description);
        try writer.writeByte('\'');
    }
    if (!std.mem.eql(u8, option.type, "bool") and !std.mem.eql(u8, option.type, "void")) {
        try writer.writeAll(" -r");
        if (option.choices.len > 0) {
            try writer.writeAll(" -a '");
            try writeWords(option.choices, writer);
            try writer.writeByte('\'');
        }
    }
    try writer.writeByte('\n');
}

fn writeFishNames(option: spec.Option, writer: *std.Io.Writer) !void {
    try writeFishName(option.name, writer);
    for (option.aliases) |alias| try writeFishName(alias, writer);
}

fn writeFishName(name: []const u8, writer: *std.Io.Writer) !void {
    if (std.mem.startsWith(u8, name, "--"))
        try writer.print(" -l {s}", .{name[2..]})
    else if (std.mem.startsWith(u8, name, "-"))
        try writer.print(" -s {s}", .{name[1..]});
}

fn writeFishEscaped(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '\'' => try writer.writeAll("\\'"),
        '\r', '\n' => try writer.writeByte(' '),
        else => try writer.writeByte(byte),
    };
}

fn renderZsh(manifest: *const spec.Manifest, writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\#compdef shelly
        \\# Zsh completions for shelly
        \\# Auto-generated from the native Shelly CLI catalog. Do not edit.
        \\_shelly() {
        \\    local action
        \\    action=$words[2]
        \\    if (( CURRENT == 2 )); then
        \\        local -a actions
        \\        actions=(
        \\
    );
    for (manifest.commands) |*action| {
        if (!isChildOf(action, manifest.root())) continue;
        try writer.print("            '{s}:", .{action.name});
        try writeZshEscaped(writer, action.description orelse "");
        try writer.writeAll("'\n");
    }
    try writer.writeAll(
        \\        )
        \\        _describe 'command' actions
        \\        return
        \\    fi
        \\    case $action in
        \\
    );
    for (manifest.commands) |*action| {
        if (!isChildOf(action, manifest.root())) continue;
        try writer.print("        {s})\n", .{action.name});
        const default_child = manifest.findDefaultChild(action);
        if (default_child) |child| {
            if (hasNonDefaultChildren(manifest, action, child)) {
                try writer.writeAll("            if (( CURRENT == 3 )); then\n                local -a commands\n                commands=(");
                for (manifest.commands) |*other| {
                    if (!isChildOf(other, action) or other == child) continue;
                    try writer.print(" '{s}'", .{other.name});
                }
                try writer.writeAll(" )\n                _alternative 'commands:command:commands' 'options:option:(");
                try writeEffectiveOptionWords(manifest, child, writer);
                try writer.writeAll(")'\n                return\n            fi\n");
                try writer.writeAll("            case $words[3] in\n");
                for (manifest.commands) |*other| {
                    if (!isChildOf(other, action) or other == child) continue;
                    try writer.print("                {s}) ", .{other.name});
                    try writeZshArguments(manifest, other, writer);
                    try writer.writeAll(" ;;\n");
                }
                try writer.writeAll("                *) ");
                try writeZshArguments(manifest, child, writer);
                try writer.writeAll(" ;;\n            esac\n");
            } else {
                try writer.writeAll("            ");
                try writeZshArguments(manifest, child, writer);
                try writer.writeByte('\n');
            }
        } else {
            try writer.writeAll("            if (( CURRENT == 3 )); then\n                local -a commands\n                commands=(");
            try writeChildNames(manifest, action, writer);
            try writer.writeAll(")\n                _describe 'command' commands\n                return\n            fi\n            case $words[3] in\n");
            for (manifest.commands) |*child| {
                if (!isChildOf(child, action)) continue;
                try writer.print("                {s}) ", .{child.name});
                try writeZshArguments(manifest, child, writer);
                try writer.writeAll(" ;;\n");
            }
            try writer.writeAll("            esac\n");
        }
        try writer.writeAll("            ;;\n");
    }
    try writer.writeAll(
        \\    esac
        \\}
        \\_shelly "$@"
        \\
    );
}

fn writeZshArguments(
    manifest: *const spec.Manifest,
    command: *const spec.Command,
    writer: *std.Io.Writer,
) !void {
    try writer.writeAll("_arguments");
    for (command.options) |option| {
        if (option.hidden) continue;
        try writer.writeAll(" ");
        try writeZshOption(option, writer);
    }
    for (manifest.root().options) |option| {
        if (!option.recursive or option.hidden) continue;
        try writer.writeAll(" ");
        try writeZshOption(option, writer);
    }
}

fn writeZshOption(option: spec.Option, writer: *std.Io.Writer) !void {
    try writer.writeByte('\'');
    if (option.aliases.len > 0) {
        try writer.writeByte('{');
        try writer.writeAll(option.name);
        for (option.aliases) |alias| try writer.print(",{s}", .{alias});
        try writer.writeByte('}');
    } else {
        try writer.writeAll(option.name);
    }
    try writer.writeByte('[');
    try writeZshEscaped(writer, option.description orelse "");
    try writer.writeByte(']');
    if (!std.mem.eql(u8, option.type, "bool") and !std.mem.eql(u8, option.type, "void")) {
        try writer.writeByte(':');
        try writer.writeAll(std.mem.trimStart(u8, option.name, "-"));
        if (option.choices.len > 0) {
            try writer.writeAll(":(");
            try writeWords(option.choices, writer);
            try writer.writeByte(')');
        }
    }
    try writer.writeByte('\'');
}

fn writeZshEscaped(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '\'' => try writer.writeAll("'\\''"),
        '\r', '\n' => try writer.writeByte(' '),
        '[' => try writer.writeByte('('),
        ']' => try writer.writeByte(')'),
        else => try writer.writeByte(byte),
    };
}

fn writeEffectiveOptionWords(
    manifest: *const spec.Manifest,
    command: *const spec.Command,
    writer: *std.Io.Writer,
) !void {
    try writeOptionWords(command.options, writer);
    for (manifest.root().options) |option| {
        if (!option.recursive or option.hidden) continue;
        if (command.options.len > 0 or option.name.ptr != manifest.root().options[0].name.ptr)
            try writer.writeByte(' ');
        try writeOneOptionWords(option, writer);
    }
}

fn writeOptionWords(options: []const spec.Option, writer: *std.Io.Writer) !void {
    var wrote = false;
    for (options) |option| {
        if (option.hidden) continue;
        if (wrote) try writer.writeByte(' ');
        try writeOneOptionWords(option, writer);
        wrote = true;
    }
}

fn writeOneOptionWords(option: spec.Option, writer: *std.Io.Writer) !void {
    try writer.writeAll(option.name);
    for (option.aliases) |alias| try writer.print(" {s}", .{alias});
}

fn writeChildNames(
    manifest: *const spec.Manifest,
    parent: *const spec.Command,
    writer: *std.Io.Writer,
) !void {
    var wrote = false;
    for (manifest.commands) |*child| {
        if (!isChildOf(child, parent)) continue;
        if (wrote) try writer.writeByte(' ');
        try writer.writeAll(child.name);
        wrote = true;
    }
}

fn writeNonDefaultChildNames(
    manifest: *const spec.Manifest,
    parent: *const spec.Command,
    default_child: *const spec.Command,
    writer: *std.Io.Writer,
) !void {
    var wrote = false;
    for (manifest.commands) |*child| {
        if (!isChildOf(child, parent) or child == default_child) continue;
        if (wrote) try writer.writeByte(' ');
        try writer.writeAll(child.name);
        wrote = true;
    }
}

fn hasNonDefaultChildren(
    manifest: *const spec.Manifest,
    parent: *const spec.Command,
    default_child: *const spec.Command,
) bool {
    for (manifest.commands) |*child| {
        if (isChildOf(child, parent) and child != default_child) return true;
    }
    return false;
}

fn writeWords(words: []const []const u8, writer: *std.Io.Writer) !void {
    for (words, 0..) |word, index| {
        if (index > 0) try writer.writeByte(' ');
        try writer.writeAll(word);
    }
}

fn isChildOf(command: *const spec.Command, parent: *const spec.Command) bool {
    const parent_path = command.parentPath orelse return false;
    return std.mem.eql(u8, parent_path, parent.path);
}

test "renders Bash Fish and Zsh scripts from the native catalog" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    for ([_]struct { shell: Shell, header: []const u8, registration: []const u8, permission_option: []const u8 }{
        .{ .shell = .bash, .header = "# Bash completions for shelly", .registration = "complete -F _shelly shelly", .permission_option = "--fix-permissions" },
        .{ .shell = .fish, .header = "# Fish completions for shelly", .registration = "complete -c shelly", .permission_option = "-l fix-permissions" },
        .{ .shell = .zsh, .header = "#compdef shelly", .registration = "_shelly \"$@\"", .permission_option = "--fix-permissions" },
    }) |expected| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        try render(&manifest, expected.shell, &output.writer);
        const script = output.writer.buffered();
        try std.testing.expect(std.mem.startsWith(u8, script, expected.header));
        try std.testing.expect(std.mem.indexOf(u8, script, expected.registration) != null);
        try std.testing.expect(std.mem.indexOf(u8, script, "utility") != null);
        try std.testing.expect(std.mem.indexOf(u8, script, expected.permission_option) != null);
        try std.testing.expect(std.mem.indexOf(u8, script, "pacfiles") != null);
        try std.testing.expect(std.mem.indexOf(u8, script, "threeway") != null);
        try std.testing.expect(std.mem.indexOf(u8, script, "bash fish zsh") != null);
    }
}

test "shell parser accepts only the supported completion targets" {
    try std.testing.expectEqual(Shell.bash, Shell.parse("BASH").?);
    try std.testing.expectEqual(Shell.fish, Shell.parse("fish").?);
    try std.testing.expectEqual(Shell.zsh, Shell.parse("zsh").?);
    try std.testing.expect(Shell.parse("powershell") == null);
}
