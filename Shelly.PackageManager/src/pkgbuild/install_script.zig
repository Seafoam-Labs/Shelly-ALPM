const std = @import("std");

/// Functions libalpm recognizes after it sources a package's `.INSTALL` file.
/// Shelly preserves the script and does not invoke any of these functions while
/// building the package.
pub const Hook = enum {
    pre_install,
    post_install,
    pre_upgrade,
    post_upgrade,
    pre_remove,
    post_remove,

    pub fn name(self: Hook) []const u8 {
        return @tagName(self);
    }

    pub fn argumentCount(self: Hook) u2 {
        return switch (self) {
            .pre_install, .post_install, .pre_remove, .post_remove => 1,
            .pre_upgrade, .post_upgrade => 2,
        };
    }

    pub fn fromName(name_value: []const u8) ?Hook {
        inline for (std.meta.tags(Hook)) |hook| {
            if (std.mem.eql(u8, name_value, hook.name())) return hook;
        }
        return null;
    }
};

pub const Function = struct {
    name: []const u8,
    hook: ?Hook,
    /// Full function definition, including its closing brace when present.
    start: usize,
    end: usize,
    /// Contents between the function's opening and closing braces.
    body_start: usize,
    body_end: usize,
};

pub const Scope = union(enum) {
    top_level,
    helper: []const u8,
    hook: Hook,
};

/// Owned, byte-exact install-script snapshot used by review and packaging.
pub const Script = struct {
    file_name: []const u8,
    contents: []const u8,
    functions: []Function,

    pub fn init(
        allocator: std.mem.Allocator,
        file_name: []const u8,
        contents: []const u8,
    ) !Script {
        const owned_name = try allocator.dupe(u8, file_name);
        errdefer allocator.free(owned_name);
        const owned_contents = try allocator.dupe(u8, contents);
        errdefer allocator.free(owned_contents);
        const functions = try discoverFunctions(allocator, owned_contents);
        return .{
            .file_name = owned_name,
            .contents = owned_contents,
            .functions = functions,
        };
    }

    pub fn deinit(self: *Script, allocator: std.mem.Allocator) void {
        allocator.free(self.functions);
        allocator.free(self.contents);
        allocator.free(self.file_name);
        self.* = undefined;
    }

    /// Bash keeps the last definition when a hook is defined more than once.
    pub fn effectiveHook(self: *const Script, hook: Hook) ?Function {
        var result: ?Function = null;
        for (self.functions) |function| {
            if (function.hook == hook) result = function;
        }
        return result;
    }

    pub fn scopeAt(self: *const Script, offset: usize) Scope {
        for (self.functions) |function| {
            if (offset < function.start or offset >= function.end) continue;
            if (function.hook) |hook| return .{ .hook = hook };
            return .{ .helper = function.name };
        }
        return .top_level;
    }
};

fn discoverFunctions(allocator: std.mem.Allocator, contents: []const u8) ![]Function {
    var functions: std.ArrayList(Function) = .empty;
    errdefer functions.deinit(allocator);

    var line_start: usize = 0;
    while (line_start < contents.len) {
        if (parseHeader(contents, line_start)) |header| {
            const close = findClosingBrace(contents, header.open_brace);
            const end = if (close) |index| index + 1 else contents.len;
            try functions.append(allocator, .{
                .name = contents[header.name_start..header.name_end],
                .hook = Hook.fromName(contents[header.name_start..header.name_end]),
                .start = line_start,
                .end = end,
                .body_start = header.open_brace + 1,
                .body_end = close orelse contents.len,
            });
            line_start = end;
            if (line_start < contents.len and contents[line_start] == '\n') line_start += 1;
            continue;
        }
        line_start = (std.mem.indexOfScalarPos(u8, contents, line_start, '\n') orelse contents.len) +| 1;
    }
    return functions.toOwnedSlice(allocator);
}

const Header = struct {
    name_start: usize,
    name_end: usize,
    open_brace: usize,
};

fn parseHeader(contents: []const u8, line_start: usize) ?Header {
    var i = skipHorizontalWhitespace(contents, line_start);
    if (i >= contents.len or contents[i] == '#') return null;

    if (std.mem.startsWith(u8, contents[i..], "function") and
        i + "function".len < contents.len and
        std.ascii.isWhitespace(contents[i + "function".len]))
    {
        i = skipHorizontalWhitespace(contents, i + "function".len);
    }

    const name_start = i;
    if (i >= contents.len or !isIdentifierStart(contents[i])) return null;
    i += 1;
    while (i < contents.len and isIdentifierContinue(contents[i])) i += 1;
    const name_end = i;
    i = skipHorizontalWhitespace(contents, i);

    if (i < contents.len and contents[i] == '(') {
        i = skipHorizontalWhitespace(contents, i + 1);
        if (i >= contents.len or contents[i] != ')') return null;
        i = skipHorizontalWhitespace(contents, i + 1);
    }
    if (i >= contents.len or contents[i] != '{') return null;
    return .{ .name_start = name_start, .name_end = name_end, .open_brace = i };
}

fn findClosingBrace(contents: []const u8, open_brace: usize) ?usize {
    var depth: usize = 1;
    var single_quoted = false;
    var double_quoted = false;
    var escaped = false;
    var comment = false;
    var i = open_brace + 1;
    while (i < contents.len) : (i += 1) {
        const c = contents[i];
        if (comment) {
            if (c == '\n') comment = false;
            continue;
        }
        if (escaped) {
            escaped = false;
            continue;
        }
        if (!single_quoted and c == '\\') {
            escaped = true;
            continue;
        }
        if (!double_quoted and c == '\'') {
            single_quoted = !single_quoted;
            continue;
        }
        if (!single_quoted and c == '"') {
            double_quoted = !double_quoted;
            continue;
        }
        if (single_quoted or double_quoted) continue;
        if (c == '#') {
            comment = true;
        } else if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn skipHorizontalWhitespace(contents: []const u8, start: usize) usize {
    var i = start;
    while (i < contents.len and (contents[i] == ' ' or contents[i] == '\t')) i += 1;
    return i;
}

fn isIdentifierStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentifierContinue(c: u8) bool {
    return isIdentifierStart(c) or std.ascii.isDigit(c);
}

test "install script discovers every libalpm hook and preserves exact bytes" {
    const source =
        "#!/bin/bash\n" ++
        "enabled=1\n" ++
        "helper() { echo \"}\"; }\n" ++
        "pre_install() { helper \"$1\"; }\n" ++
        "post_install() { true; }\n" ++
        "pre_upgrade() { echo \"$1 $2\"; }\n" ++
        "post_upgrade() { true; }\n" ++
        "pre_remove() { true; }\n" ++
        "post_remove() { true; }\n";
    var script = try Script.init(std.testing.allocator, "demo.install", source);
    defer script.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(source, script.contents);
    try std.testing.expectEqual(@as(usize, 7), script.functions.len);
    inline for (std.meta.tags(Hook)) |hook|
        try std.testing.expect(script.effectiveHook(hook) != null);
    try std.testing.expectEqual(@as(u2, 2), Hook.pre_upgrade.argumentCount());
    try std.testing.expectEqual(@as(u2, 1), Hook.post_remove.argumentCount());
}

test "install script uses the last duplicate hook definition" {
    const source = "post_install() { echo first; }\npost_install() { echo second; }\n";
    var script = try Script.init(std.testing.allocator, "demo.install", source);
    defer script.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), script.functions.len);
    const effective = script.effectiveHook(.post_install).?;
    try std.testing.expect(std.mem.indexOf(u8, script.contents[effective.body_start..effective.body_end], "second") != null);
}

test "install script classifies helpers hooks and top-level code" {
    const source = "echo top\nhelper() { true; }\npre_remove() { helper; }\n";
    var script = try Script.init(std.testing.allocator, "demo.install", source);
    defer script.deinit(std.testing.allocator);

    try std.testing.expect(script.scopeAt(0) == .top_level);
    try std.testing.expect(script.scopeAt(script.functions[0].body_start) == .helper);
    try std.testing.expect(script.scopeAt(script.functions[1].body_start) == .hook);
}
