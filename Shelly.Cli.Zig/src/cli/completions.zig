const std = @import("std");
const spec = @import("spec.zig");
const catalog = @import("catalog.zig");

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
        \\_shelly_packages_standard_sync() {
        \\    pacman -Slq 2>/dev/null
        \\}
        \\
        \\_shelly_packages_standard_local() {
        \\    pacman -Qq 2>/dev/null
        \\}
        \\
        \\_shelly_packages_aur_local() {
        \\    pacman -Qqm 2>/dev/null
        \\}
        \\
        \\_shelly_packages_flatpak_remote() {
        \\    flatpak remote-ls --app --columns=application 2>/dev/null
        \\}
        \\
        \\_shelly_packages_flatpak_local() {
        \\    flatpak list --app --columns=application 2>/dev/null
        \\}
        \\
        \\_shelly() {
        \\    local cur prev action selector consumed
        \\    COMPREPLY=()
        \\    cur="${COMP_WORDS[COMP_CWORD]}"
        \\    prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\    action="${COMP_WORDS[1]}"
        \\    selector="${COMP_WORDS[2]}"
        \\    consumed=0
        \\
        \\    if (( COMP_CWORD == 1 )); then
        \\        COMPREPLY=( $(compgen -W '
    );
    try writeChildNames(manifest, manifest.root(), writer);
    try writer.writeByte(' ');
    try writeOptionWords(manifest.root().options, writer);
    if (hasShortcodes(manifest)) {
        try writer.writeByte(' ');
        try writeShortcodeWords(manifest, writer);
    }
    try writer.writeAll(
        \\' -- "$cur") )
        \\        return
        \\    fi
        \\
        \\    case "$action" in
        \\
    );
    try writeBashShortcodes(manifest, writer);
    try writer.writeAll(
        \\    esac
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
            try writer.writeAll("            if (( COMP_CWORD == 2 && consumed == 0 )); then\n                COMPREPLY=( $(compgen -W '");
            try writeNonDefaultChildNames(manifest, action, child, writer);
            if (hasNonDefaultChildren(manifest, action, child)) try writer.writeByte(' ');
            try writeEffectiveOptionWords(manifest, child, writer);
            try writer.writeAll("' -- \"$cur\") )\n                return\n            fi\n");
            try writer.writeAll("            case \"$selector\" in\n");
            for (manifest.commands) |*candidate| {
                if (!isChildOf(candidate, action) or candidate == child) continue;
                try writer.print("                {s})\n", .{candidate.name});
                try writeBashArguments(manifest, candidate, "                    ", writer);
                try writer.writeAll("                    ;;\n");
            }
            try writer.writeAll("                *)\n");
            try writeBashArguments(manifest, child, "                    ", writer);
            try writer.writeAll("                    ;;\n            esac\n");
        } else {
            try writer.writeAll("            if (( COMP_CWORD == 2 && consumed == 0 )); then\n                COMPREPLY=( $(compgen -W '");
            try writeChildNames(manifest, action, writer);
            try writer.writeAll("' -- \"$cur\") )\n                return\n            fi\n");
            try writer.writeAll("            case \"$selector\" in\n");
            for (manifest.commands) |*child| {
                if (!isChildOf(child, action)) continue;
                try writer.print("                {s})\n", .{child.name});
                try writeBashArguments(manifest, child, "                    ", writer);
                try writer.writeAll("                    ;;\n");
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

fn writeBashArguments(
    manifest: *const spec.Manifest,
    command: *const spec.Command,
    indent: []const u8,
    writer: *std.Io.Writer,
) !void {
    try writer.print("{s}if [[ \"$cur\" == -* ]]; then\n", .{indent});
    try writer.print("{s}    COMPREPLY=( $(compgen -W '", .{indent});
    try writeEffectiveOptionWords(manifest, command, writer);
    try writer.writeAll("' -- \"$cur\") )\n");
    if (command.arguments.len > 0) {
        if (packageCompleter(command)) |helper| {
            if (bashPackageCompleter(helper)) |bash_helper| {
                try writer.print("{s}else\n", .{indent});
                try writer.print("{s}    COMPREPLY=( $(compgen -W \"$({s})\" -- \"$cur\") )\n", .{ indent, bash_helper });
            }
        } else if (isAppimageInstall(command)) {
            try writer.print("{s}else\n", .{indent});
            try writer.print("{s}    COMPREPLY=( $(compgen -f -X '!*.AppImage' -- \"$cur\") )\n", .{indent});
        }
    }
    try writer.print("{s}fi\n", .{indent});
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
        \\function __shelly_packages_standard_sync
        \\    pacman -Slq 2>/dev/null
        \\end
        \\
        \\function __shelly_packages_standard_local
        \\    pacman -Qq 2>/dev/null
        \\end
        \\
        \\function __shelly_packages_aur_local
        \\    pacman -Qqm 2>/dev/null
        \\end
        \\
        \\function __shelly_packages_flatpak_remote
        \\    flatpak remote-ls --app --columns=application 2>/dev/null
        \\end
        \\
        \\function __shelly_packages_flatpak_local
        \\    flatpak list --app --columns=application 2>/dev/null
        \\end
        \\
        \\function __shelly_shortcut
        \\    set -l cmd (commandline -opc)
        \\    test (count $cmd) -ge 2; or return 1
        \\    for shortcut in $argv
        \\        string match -q -- "$shortcut*" "$cmd[2]"; and return 0
        \\    end
        \\    return 1
        \\end
        \\
        \\function __shelly_shortcode_token
        \\    set -l token (commandline -ct)
        \\    for shortcode in $argv
        \\        string match -q -- "$shortcode*" "$token"; and return 0
        \\    end
        \\    return 1
        \\end
        \\
        \\complete -c shelly -f
        \\
    );
    var top_level_condition = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer top_level_condition.deinit();
    try top_level_condition.writer.writeAll("__fish_use_subcommand");
    {
        var any_shortcut = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        defer any_shortcut.deinit();
        try any_shortcut.writer.writeAll("__shelly_shortcut");
        for (manifest.commands) |*command| {
            const action_code = command.actionCode orelse continue;
            var codes: [16]u8 = undefined;
            for (collectTypeCodes(command, &codes)) |type_code| {
                try any_shortcut.writer.print(" -{c}{c}", .{ action_code, type_code });
            }
            if (isBareShortcode(command)) {
                try any_shortcut.writer.print(" -{c}", .{action_code});
            }
        }
        if (any_shortcut.writer.buffered().len > "__shelly_shortcut".len) {
            try top_level_condition.writer.print("; and not {s}", .{any_shortcut.writer.buffered()});
        }
    }

    for (manifest.root().options) |option| {
        try writeFishOption(
            option,
            if (option.recursive) null else top_level_condition.writer.buffered(),
            writer,
        );
    }
    try writer.writeByte('\n');

    // Top-level shortcode completions (e.g., -Ss, -Is, -Ks) plus modifier extensions (e.g., -Sad).
    for (manifest.commands) |*command| {
        const action_code = command.actionCode orelse continue;
        var codes: [16]u8 = undefined;
        var modifiers: [16]Modifier = undefined;
        const modifier_list = collectModifiers(manifest, command, &modifiers);
        for (collectTypeCodes(command, &codes)) |type_code| {
            try writer.print(
                "complete -c shelly -f -n '{s}' -a '-{c}{c}' -d '",
                .{ top_level_condition.writer.buffered(), action_code, type_code },
            );
            try writeFishEscaped(writer, command.description orelse "");
            try writer.writeAll("'\n");
            for (modifier_list) |modifier| {
                try writer.print(
                    "complete -c shelly -f -n '__shelly_shortcode_token -{c}{c}' -a '-{c}{c}{c}' -d '",
                    .{ action_code, type_code, action_code, type_code, modifier.character },
                );
                try writeFishEscaped(writer, modifier.description orelse "");
                try writer.writeAll("'\n");
            }
        }
    }

    // Top-level bare shortcode completions (e.g., -U, -N) plus standalone modifier
    // extensions (e.g., -Na). Bare-action-code variants accept no modifiers, so only
    // standalone variants emit extensions.
    for (manifest.commands) |*command| {
        const action_code = command.actionCode orelse continue;
        if (!isBareShortcode(command)) continue;
        try writer.print(
            "complete -c shelly -f -n '{s}' -a '-{c}' -d '",
            .{ top_level_condition.writer.buffered(), action_code },
        );
        try writeFishEscaped(writer, command.description orelse "");
        try writer.writeAll("'\n");
        if (command.typeCode != null) continue;
        var modifiers: [16]Modifier = undefined;
        for (collectStandaloneModifiers(manifest, command, &modifiers)) |modifier| {
            try writer.print(
                "complete -c shelly -f -n '__shelly_shortcode_token -{c}' -a '-{c}{c}' -d '",
                .{ action_code, action_code, modifier.character },
            );
            try writeFishEscaped(writer, modifier.description orelse "");
            try writer.writeAll("'\n");
        }
    }

    // Shortcut-conditioned option and positional completions.
    for (manifest.commands) |*command| {
        var codes: [16]u8 = undefined;
        if (collectTypeCodes(command, &codes).len == 0 and !isBareShortcode(command)) continue;

        var shortcut_condition = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        defer shortcut_condition.deinit();
        try writeFishShortcodeCondition(manifest, command, &shortcut_condition.writer);

        for (command.options) |option| {
            try writeFishOption(option, shortcut_condition.writer.buffered(), writer);
        }
        try writeFishPositional(command, shortcut_condition.writer.buffered(), writer);
    }

    for (manifest.commands) |*action| {
        if (!isChildOf(action, manifest.root())) continue;
        try writer.print("complete -c shelly -f -n '{s}' -a '{s}' -d '", .{ top_level_condition.writer.buffered(), action.name });
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
            try writeFishPositional(child, condition.writer.buffered(), writer);
        }
        for (manifest.commands) |*child| {
            if (!isChildOf(child, action) or child == default_child) continue;
            var condition = std.Io.Writer.Allocating.init(std.heap.page_allocator);
            defer condition.deinit();
            try condition.writer.print("__fish_seen_subcommand_from {s}; and __fish_seen_subcommand_from {s}", .{ action.name, child.name });
            for (child.options) |option| try writeFishOption(option, condition.writer.buffered(), writer);
            try writeFishPositional(child, condition.writer.buffered(), writer);
        }
    }
}

fn writeFishPositional(command: *const spec.Command, condition: []const u8, writer: *std.Io.Writer) !void {
    if (command.arguments.len == 0) return;
    if (packageCompleter(command)) |helper| {
        if (fishPackageCompleter(helper)) |fish_helper| {
            try writer.print("complete -c shelly -f -n '{s}' -a '({s})'\n", .{ condition, fish_helper });
        }
        return;
    }
    if (isAppimageInstall(command)) {
        try writer.print("complete -c shelly -f -n '{s}' -a '(__fish_complete_suffix .AppImage)'\n", .{condition});
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

/// Builds the fish condition that activates a command's shortcode completions. A bare
/// shortcode (e.g., `-U`) shares its prefix with its action's typed shortcodes
/// (e.g., `-Us`), so an exclusion clause keeps the bare form from activating on the
/// sibling tokens that the translator routes to typed variants instead.
fn writeFishShortcodeCondition(
    manifest: *const spec.Manifest,
    command: *const spec.Command,
    writer: *std.Io.Writer,
) !void {
    const action_code = command.actionCode orelse return;
    var codes: [16]u8 = undefined;
    try writer.writeAll("__shelly_shortcut");
    for (collectTypeCodes(command, &codes)) |type_code| {
        try writer.print(" -{c}{c}", .{ action_code, type_code });
    }
    if (!isBareShortcode(command)) return;
    try writer.print(" -{c}", .{action_code});

    var wrote_exclusion = false;
    for (manifest.commands) |*sibling| {
        if (sibling == command or sibling.actionCode != action_code) continue;
        var sibling_codes: [16]u8 = undefined;
        for (collectTypeCodes(sibling, &sibling_codes)) |type_code| {
            if (!wrote_exclusion) {
                try writer.writeAll("; and not __shelly_shortcut");
                wrote_exclusion = true;
            }
            try writer.print(" -{c}{c}", .{ action_code, type_code });
        }
    }
}

fn renderZsh(manifest: *const spec.Manifest, writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\#compdef shelly
        \\# Zsh completions for shelly
        \\# Auto-generated from the native Shelly CLI catalog. Do not edit.
        \\
        \\typeset -ga _shelly_repo_packages
        \\typeset -ga _shelly_flatpak_remote_packages
        \\
        \\_shelly_packages_standard_sync() {
        \\    if (( ${#_shelly_repo_packages} == 0 )); then
        \\        _shelly_repo_packages=(${(f)"$(pacman -Slq 2>/dev/null)"})
        \\    fi
        \\    _describe -t packages 'package' _shelly_repo_packages
        \\}
        \\
        \\_shelly_packages_standard_local() {
        \\    local -a packages
        \\    packages=(${(f)"$(pacman -Qq 2>/dev/null)"})
        \\    _describe -t packages 'package' packages
        \\}
        \\
        \\_shelly_packages_aur_local() {
        \\    local -a packages
        \\    packages=(${(f)"$(pacman -Qqm 2>/dev/null)"})
        \\    _describe -t packages 'package' packages
        \\}
        \\
        \\_shelly_packages_flatpak_remote() {
        \\    if (( ${#_shelly_flatpak_remote_packages} == 0 )); then
        \\        _shelly_flatpak_remote_packages=(${(f)"$(flatpak remote-ls --app --columns=application 2>/dev/null)"})
        \\    fi
        \\    _describe -t packages 'package' _shelly_flatpak_remote_packages
        \\}
        \\
        \\_shelly_packages_flatpak_local() {
        \\    local -a packages
        \\    packages=(${(f)"$(flatpak list --app --columns=application 2>/dev/null)"})
        \\    _describe -t packages 'package' packages
        \\}
        \\
        \\_shelly() {
        \\    local action selector
        \\    integer consumed=0
        \\    action=$words[2]
        \\    selector=
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
    for (manifest.commands) |*command| {
        const action_code = command.actionCode orelse continue;
        var codes: [16]u8 = undefined;
        var modifiers: [16]Modifier = undefined;
        const modifier_list = collectModifiers(manifest, command, &modifiers);
        for (collectTypeCodes(command, &codes)) |type_code| {
            try writer.print("            '-{c}{c}:", .{ action_code, type_code });
            try writeZshEscaped(writer, command.description orelse "");
            try writer.writeAll("'\n");
            for (modifier_list) |modifier| {
                try writer.print("            '-{c}{c}{c}:", .{ action_code, type_code, modifier.character });
                try writeZshEscaped(writer, modifier.description orelse "");
                try writer.writeAll("'\n");
            }
        }
    }
    // Bare action shortcode candidates (e.g., -U, -N) plus standalone modifier
    // extensions (e.g., -Na). Bare-action-code variants accept no modifiers.
    for (manifest.commands) |*command| {
        const action_code = command.actionCode orelse continue;
        if (!isBareShortcode(command)) continue;
        try writer.print("            '-{c}:", .{action_code});
        try writeZshEscaped(writer, command.description orelse "");
        try writer.writeAll("'\n");
        if (command.typeCode != null) continue;
        var modifiers: [16]Modifier = undefined;
        for (collectStandaloneModifiers(manifest, command, &modifiers)) |modifier| {
            try writer.print("            '-{c}{c}:", .{ action_code, modifier.character });
            try writeZshEscaped(writer, modifier.description orelse "");
            try writer.writeAll("'\n");
        }
    }
    try writer.writeAll(
        \\        )
        \\        _describe 'command' actions
        \\        return
        \\    fi
        \\    case $action in
        \\
    );
    for (manifest.commands) |*command| {
        const action_code = command.actionCode orelse continue;
        var codes: [16]u8 = undefined;
        for (collectTypeCodes(command, &codes)) |type_code| {
            try writer.print("        -{c}{c}*) action={s}; selector={s}; consumed=1 ;;\n", .{
                action_code,
                type_code,
                parentActionName(command),
                command.name,
            });
        }
    }
    // Bare action shortcode branches trail the typed branches so a typed token such
    // as `-Us` matches its own three-character branch before the two-character `-U*`.
    for (manifest.commands) |*command| {
        const action_code = command.actionCode orelse continue;
        if (!isBareShortcode(command)) continue;
        try writer.print("        -{c}*) action={s}; selector={s}; consumed=1 ;;\n", .{
            action_code,
            parentActionName(command),
            command.name,
        });
    }
    try writer.writeAll(
        \\    esac
        \\    case $action in
        \\
    );
    for (manifest.commands) |*action| {
        if (!isChildOf(action, manifest.root())) continue;
        try writer.print("        {s})\n", .{action.name});
        const default_child = manifest.findDefaultChild(action);
        if (default_child) |child| {
            if (hasNonDefaultChildren(manifest, action, child)) {
                try writer.writeAll(
                    \\            if [[ -z $selector ]]; then
                    \\                if (( CURRENT == 3 )); then
                    \\                    local -a commands
                    \\                    commands=(
                );
                for (manifest.commands) |*other| {
                    if (!isChildOf(other, action) or other == child) continue;
                    try writer.print(" '{s}'", .{other.name});
                }
                try writer.writeAll(" )\n                    _alternative 'commands:command:commands' 'options:option:(");
                try writeEffectiveOptionWords(manifest, child, writer);
                try writer.writeAll(
                    \\)'
                    \\                    return
                    \\                fi
                    \\                selector=$words[3]
                    \\                consumed=2
                    \\            fi
                    \\            case $selector in
                    \\
                );
                for (manifest.commands) |*other| {
                    if (!isChildOf(other, action) or other == child) continue;
                    try writer.print("                {s}) ", .{other.name});
                    try writeZshArguments(manifest, other, writer);
                    try writer.writeAll(" ;;\n");
                }
                try writer.print("                *) [[ $selector != {s} ]] && consumed=1; ", .{child.name});
                try writeZshArguments(manifest, child, writer);
                try writer.writeAll(" ;;\n            esac\n");
            } else {
                try writer.writeAll("            (( consumed == 0 )) && consumed=1; ");
                try writeZshArguments(manifest, child, writer);
                try writer.writeByte('\n');
            }
        } else {
            try writer.writeAll(
                \\            if [[ -z $selector ]]; then
                \\                if (( CURRENT == 3 )); then
                \\                    local -a commands
                \\                    commands=(
            );
            try writeChildNames(manifest, action, writer);
            try writer.writeAll(
                \\)
                \\                    _describe 'command' commands
                \\                    return
                \\                fi
                \\                selector=$words[3]
                \\                consumed=2
                \\            fi
                \\            case $selector in
                \\
            );
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
    try writer.writeAll(
        \\(( consumed > 0 )) && { words=("$words[1]" "${(@)words[consumed+2,$#words]}"); (( CURRENT -= consumed )); }; _arguments
    );
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
    if (packageCompleter(command)) |helper| {
        if (command.arguments.len > 0)
            try writeZshPositional(command.arguments[0], helper, writer);
    } else if (isAppimageInstall(command)) {
        if (command.arguments.len > 0)
            try writeZshPositional(command.arguments[0], "_files -g \"*.AppImage\"", writer);
    }
}

fn writeZshPositional(argument: spec.Argument, action: []const u8, writer: *std.Io.Writer) !void {
    try writer.print(" '{s}{s}:{s}'", .{ zshPositionalPrefix(argument), argument.name, action });
}

fn zshPositionalPrefix(argument: spec.Argument) []const u8 {
    const repeated = argument.maximumArity == null or argument.maximumArity.? > 1;
    if (repeated) return "*:";
    return if (argument.minimumArity == 0) "1::" else "1:";
}

fn writeZshOption(option: spec.Option, writer: *std.Io.Writer) !void {
    var wrote = false;
    if (isZshArgumentsOptionName(option.name)) {
        try writeZshOptionName(option.name, option, writer);
        wrote = true;
    }
    for (option.aliases) |alias| {
        if (!isZshArgumentsOptionName(alias)) continue;
        if (wrote) try writer.writeByte(' ');
        try writeZshOptionName(alias, option, writer);
        wrote = true;
    }
}

fn writeZshOptionName(name: []const u8, option: spec.Option, writer: *std.Io.Writer) !void {
    try writer.writeByte('\'');
    try writer.writeAll(name);
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

/// Returns true when `name` is a valid zsh `_arguments` option spec (`-x` or `--long`).
fn isZshArgumentsOptionName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "-")) return false;
    return std.mem.indexOfAny(u8, name, "?/") == null;
}

/// Returns the primary type code followed by any catalog alias type codes.
fn collectTypeCodes(command: *const spec.Command, buffer: *[16]u8) []const u8 {
    var count: usize = 0;
    if (command.typeCode) |type_code| {
        buffer[count] = type_code;
        count += 1;
    }
    for (command.aliasTypeCodes) |type_code| {
        if (count >= buffer.len) break;
        buffer[count] = type_code;
        count += 1;
    }
    return buffer[0..count];
}

fn parentActionName(command: *const spec.Command) []const u8 {
    const parent_path = command.parentPath orelse return command.name;
    if (std.mem.lastIndexOfScalar(u8, parent_path, ' ')) |index|
        return parent_path[index + 1 ..];
    return parent_path;
}

const Modifier = struct {
    character: u8,
    description: ?[]const u8,
};

/// Returns the shortcode modifier character for an option alias like `-d`, if it is one.
fn modifierCharacter(alias: []const u8) ?u8 {
    if (alias.len != 2 or alias[0] != '-' or alias[1] == '-') return null;
    return alias[1];
}

/// Collects the shortcode modifier characters a command accepts, one per non-hidden option,
/// in option order. For combined-type actions a character that doubles as another type code
/// is omitted, since the translator parses such tokens as combined searches (e.g. `-Sas`
/// searches aur and standard together rather than passing `--standard` to `search aur`).
fn collectModifiers(
    manifest: *const spec.Manifest,
    command: *const spec.Command,
    buffer: *[16]Modifier,
) []const Modifier {
    const action_code = command.actionCode orelse return buffer[0..0];
    const combined = actionSupportsCombinedTypes(action_code);
    var count: usize = 0;
    var seen = [_]bool{false} ** 256;
    for (command.options) |option| {
        if (count >= buffer.len) break;
        if (option.hidden) continue;
        for (option.aliases) |alias| {
            const character = modifierCharacter(alias) orelse continue;
            if (seen[character]) continue;
            if (combined and isActionTypeCode(manifest, action_code, character)) continue;
            seen[character] = true;
            buffer[count] = .{ .character = character, .description = option.description };
            count += 1;
            break;
        }
    }
    return buffer[0..count];
}

fn actionSupportsCombinedTypes(action_code: u8) bool {
    const action = catalog.Action.findByCode(action_code) orelse return false;
    return action.supportsCombinedTypes();
}

fn isActionTypeCode(manifest: *const spec.Manifest, action_code: u8, type_code: u8) bool {
    for (manifest.commands) |*command| {
        if (command.actionCode != action_code) continue;
        var codes: [16]u8 = undefined;
        for (collectTypeCodes(command, &codes)) |code| {
            if (code == type_code) return true;
        }
    }
    return false;
}

/// Returns true when the command is addressed by a bare action shortcode: either a
/// bare-action-code variant (e.g., `-U` for `upgrade all`) or a standalone default
/// variant without a type code (e.g., `-N` for `news standard`).
fn isBareShortcode(command: *const spec.Command) bool {
    if (command.bareActionCode) return true;
    return command.defaultForAction and command.typeCode == null;
}

/// Collects shortcode modifier characters for a standalone variant, omitting any
/// character that is a sibling variant's type code: the translator routes such
/// tokens to the typed sibling instead of treating the character as a modifier.
fn collectStandaloneModifiers(
    manifest: *const spec.Manifest,
    command: *const spec.Command,
    buffer: *[16]Modifier,
) []const Modifier {
    const action_code = command.actionCode orelse return buffer[0..0];
    var count: usize = 0;
    var seen = [_]bool{false} ** 256;
    for (command.options) |option| {
        if (count >= buffer.len) break;
        if (option.hidden) continue;
        for (option.aliases) |alias| {
            const character = modifierCharacter(alias) orelse continue;
            if (seen[character]) continue;
            if (isActionTypeCode(manifest, action_code, character)) continue;
            seen[character] = true;
            buffer[count] = .{ .character = character, .description = option.description };
            count += 1;
            break;
        }
    }
    return buffer[0..count];
}

/// Returns true when at least one catalog command exposes a shortcode.
fn hasShortcodes(manifest: *const spec.Manifest) bool {
    for (manifest.commands) |*command| {
        if (command.actionCode == null) continue;
        var codes: [16]u8 = undefined;
        if (collectTypeCodes(command, &codes).len > 0) return true;
    }
    return false;
}

/// Returns true when a root option name or alias already contributes the word
/// `-X` to the Bash top-level word list (e.g., `-U` for `--ui-mode`). The
/// translator treats a bare `-X` first token as the shortcode, so the list only
/// needs the token once.
fn isRootOptionWord(manifest: *const spec.Manifest, action_code: u8) bool {
    const word = [_]u8{ '-', action_code };
    for (manifest.root().options) |option| {
        if (std.mem.eql(u8, option.name, &word)) return true;
        for (option.aliases) |alias| {
            if (std.mem.eql(u8, alias, &word)) return true;
        }
    }
    return false;
}

/// Writes the space-separated shortcode tokens (e.g., `-Ss -Is -Ks`) for compgen word lists,
/// including single-modifier extensions (e.g., `-Sad`) and bare action shortcodes (e.g., `-U -N`).
fn writeShortcodeWords(manifest: *const spec.Manifest, writer: *std.Io.Writer) !void {
    var wrote = false;
    for (manifest.commands) |*command| {
        const action_code = command.actionCode orelse continue;
        var codes: [16]u8 = undefined;
        var modifiers: [16]Modifier = undefined;
        const modifier_list = collectModifiers(manifest, command, &modifiers);
        for (collectTypeCodes(command, &codes)) |type_code| {
            if (wrote) try writer.writeByte(' ');
            try writer.print("-{c}{c}", .{ action_code, type_code });
            for (modifier_list) |modifier| {
                try writer.print(" -{c}{c}{c}", .{ action_code, type_code, modifier.character });
            }
            wrote = true;
        }
    }
    for (manifest.commands) |*command| {
        const action_code = command.actionCode orelse continue;
        if (!isBareShortcode(command)) continue;
        if (isRootOptionWord(manifest, action_code)) continue;
        if (wrote) try writer.writeByte(' ');
        try writer.print("-{c}", .{action_code});
        wrote = true;
        if (command.typeCode != null) continue;
        var modifiers: [16]Modifier = undefined;
        for (collectStandaloneModifiers(manifest, command, &modifiers)) |modifier| {
            try writer.print(" -{c}{c}", .{ action_code, modifier.character });
        }
    }
}

/// Writes the Bash `case` branches that translate shortcode tokens into action/selector/consumed.
/// Patterns are prefix matches so modifier extensions (e.g., `-Sad`) dispatch like their base.
/// Bare action shortcode branches trail the typed branches so a typed token such as `-Us`
/// matches its own three-character branch before the two-character `-U*` branch.
fn writeBashShortcodes(manifest: *const spec.Manifest, writer: *std.Io.Writer) !void {
    for (manifest.commands) |*command| {
        const action_code = command.actionCode orelse continue;
        var codes: [16]u8 = undefined;
        for (collectTypeCodes(command, &codes)) |type_code| {
            try writer.print(
                "        -{c}{c}*) action=\"{s}\"; selector=\"{s}\"; consumed=1 ;;\n",
                .{ action_code, type_code, parentActionName(command), command.name },
            );
        }
    }
    for (manifest.commands) |*command| {
        const action_code = command.actionCode orelse continue;
        if (!isBareShortcode(command)) continue;
        try writer.print(
            "        -{c}*) action=\"{s}\"; selector=\"{s}\"; consumed=1 ;;\n",
            .{ action_code, parentActionName(command), command.name },
        );
    }
}

fn packageCompleter(command: *const spec.Command) ?[]const u8 {
    if (std.mem.eql(u8, command.path, "shelly install standard") or
        std.mem.eql(u8, command.path, "shelly search standard"))
        return "_shelly_packages_standard_sync";
    if (std.mem.eql(u8, command.path, "shelly remove standard"))
        return "_shelly_packages_standard_local";
    if (std.mem.eql(u8, command.path, "shelly remove aur"))
        return "_shelly_packages_aur_local";
    if (std.mem.eql(u8, command.path, "shelly install flatpak") or
        std.mem.eql(u8, command.path, "shelly search flatpak"))
        return "_shelly_packages_flatpak_remote";
    if (std.mem.eql(u8, command.path, "shelly remove flatpak"))
        return "_shelly_packages_flatpak_local";
    return null;
}

fn bashPackageCompleter(helper: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, helper, "_shelly_packages_standard_sync")) return "_shelly_packages_standard_sync";
    if (std.mem.eql(u8, helper, "_shelly_packages_standard_local")) return "_shelly_packages_standard_local";
    if (std.mem.eql(u8, helper, "_shelly_packages_aur_local")) return "_shelly_packages_aur_local";
    if (std.mem.eql(u8, helper, "_shelly_packages_flatpak_remote")) return "_shelly_packages_flatpak_remote";
    if (std.mem.eql(u8, helper, "_shelly_packages_flatpak_local")) return "_shelly_packages_flatpak_local";
    return null;
}

fn fishPackageCompleter(helper: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, helper, "_shelly_packages_standard_sync")) return "__shelly_packages_standard_sync";
    if (std.mem.eql(u8, helper, "_shelly_packages_standard_local")) return "__shelly_packages_standard_local";
    if (std.mem.eql(u8, helper, "_shelly_packages_aur_local")) return "__shelly_packages_aur_local";
    if (std.mem.eql(u8, helper, "_shelly_packages_flatpak_remote")) return "__shelly_packages_flatpak_remote";
    if (std.mem.eql(u8, helper, "_shelly_packages_flatpak_local")) return "__shelly_packages_flatpak_local";
    return null;
}

fn isAppimageInstall(command: *const spec.Command) bool {
    return std.mem.eql(u8, command.path, "shelly install appimage");
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
        if (expected.shell == .bash) {
            try std.testing.expect(std.mem.indexOf(u8, script, "_shelly_packages_standard_sync") != null);
            try std.testing.expect(std.mem.indexOf(u8, script, "_shelly_packages_flatpak_local") != null);
            try std.testing.expect(std.mem.indexOf(u8, script, "compgen -f -X '!*.AppImage'") != null);
            // Shortcodes dispatch directly to their command variant, with prefix
            // patterns so modifier extensions (e.g., -Sad) dispatch like their base.
            try std.testing.expect(std.mem.indexOf(u8, script, "-Ss*) action=\"search\"; selector=\"standard\"; consumed=1 ;;") != null);
            try std.testing.expect(std.mem.indexOf(u8, script, "-Ks*) action=\"keyring\"; selector=\"lsign\"; consumed=1 ;;") != null);
            // Alias type codes dispatch to the same variant.
            try std.testing.expect(std.mem.indexOf(u8, script, "-LI*) action=\"list\"; selector=\"appimage\"; consumed=1 ;;") != null);
            // Single-modifier extensions are offered alongside their base shortcode.
            try std.testing.expect(std.mem.indexOf(u8, script, "-Sad") != null);
            // Bare action shortcodes are offered and dispatch to their variant after
            // the typed branches so typed tokens like -Us keep their own dispatch.
            try std.testing.expect(std.mem.indexOf(u8, script, " -U ") != null or std.mem.indexOf(u8, script, " -U'") != null);
            try std.testing.expect(std.mem.indexOf(u8, script, "-U*) action=\"upgrade\"; selector=\"all\"; consumed=1 ;;") != null);
            try std.testing.expect(std.mem.indexOf(u8, script, "-B*) action=\"backup\"; selector=\"utility\"; consumed=1 ;;") != null);
            // Standalone modifier extensions are offered alongside their bare shortcode.
            try std.testing.expect(std.mem.indexOf(u8, script, "-Na") != null);
            try std.testing.expect(std.mem.indexOf(u8, script, "-Be") != null);
        }
        if (expected.shell == .fish) {
            try std.testing.expect(std.mem.indexOf(u8, script, "function __shelly_packages_standard_sync") != null);
            try std.testing.expect(std.mem.indexOf(u8, script, "function __shelly_packages_flatpak_local") != null);
            try std.testing.expect(std.mem.indexOf(u8, script, "(__fish_complete_suffix .AppImage)") != null);
            // Shortcodes themselves, their command options, and alias type codes are emitted.
            try std.testing.expect(std.mem.indexOf(u8, script, "-a '-Ss'") != null);
            try std.testing.expect(std.mem.indexOf(u8, script, "__shelly_shortcut -Is") != null);
            try std.testing.expect(std.mem.indexOf(u8, script, "-a '-LI'") != null);
            // Modifier extensions are emitted conditioned on their base shortcode token.
            try std.testing.expect(std.mem.indexOf(u8, script, "__shelly_shortcode_token -Sa' -a '-Sad'") != null);
            // Bare action shortcodes are offered as top-level candidates.
            try std.testing.expect(std.mem.indexOf(u8, script, "-a '-U'") != null);
            try std.testing.expect(std.mem.indexOf(u8, script, "-a '-N'") != null);
            // Standalone modifier extensions are conditioned on the bare token.
            try std.testing.expect(std.mem.indexOf(u8, script, "__shelly_shortcode_token -N' -a '-Na'") != null);
            // Bare shortcodes exclude their typed siblings from their option condition.
            try std.testing.expect(std.mem.indexOf(u8, script, "__shelly_shortcut -Ux -U; and not __shelly_shortcut -Us -Ui -Ua -Uf") != null);
            // Standalone shortcodes whose action also has typed variants are still offered.
            try std.testing.expect(std.mem.indexOf(u8, script, "-a '-C'") != null);
        }
        if (expected.shell == .zsh) {
            // Regression for malformed _arguments specs.
            try std.testing.expect(std.mem.indexOf(u8, script, "'{--") == null);
            try std.testing.expect(std.mem.indexOf(u8, script, "'/?[") == null);
            // Shortcode completion is generated.
            try std.testing.expect(std.mem.indexOf(u8, script, "'-Is:") != null);
            // Modifier extensions are generated alongside their base shortcode.
            try std.testing.expect(std.mem.indexOf(u8, script, "'-Sad:") != null);
            // Bare action shortcodes and standalone extensions are generated.
            try std.testing.expect(std.mem.indexOf(u8, script, "'-U:") != null);
            try std.testing.expect(std.mem.indexOf(u8, script, "'-Na:") != null);
            try std.testing.expect(std.mem.indexOf(u8, script, "-U*) action=upgrade; selector=all; consumed=1 ;;") != null);
            try std.testing.expect(std.mem.indexOf(u8, script, "-B*) action=backup; selector=utility; consumed=1 ;;") != null);
            // Repeated and single positional arguments are represented.
            try std.testing.expect(std.mem.indexOf(u8, script, "'*:packages:") != null);
            try std.testing.expect(std.mem.indexOf(u8, script, "'1:package:") != null);
        }
    }
}

test "shell parser accepts only the supported completion targets" {
    try std.testing.expectEqual(Shell.bash, Shell.parse("BASH").?);
    try std.testing.expectEqual(Shell.fish, Shell.parse("fish").?);
    try std.testing.expectEqual(Shell.zsh, Shell.parse("zsh").?);
    try std.testing.expect(Shell.parse("powershell") == null);
}
