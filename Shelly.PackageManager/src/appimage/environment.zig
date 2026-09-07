const std = @import("std");

pub const Variable = struct {
    key: []const u8,
    value: []const u8,
};

pub fn validate(variables: []const Variable) !void {
    for (variables, 0..) |variable, i| {
        if (!validName(variable.key)) return error.InvalidEnvironmentName;
        if (std.mem.indexOfAny(u8, variable.value, "\x00\r\n") != null)
            return error.InvalidEnvironmentValue;
        for (variables[0..i]) |previous| {
            if (std.mem.eql(u8, previous.key, variable.key)) return error.DuplicateEnvironmentName;
        }
    }
}

pub fn validName(key: []const u8) bool {
    if (key.len == 0 or (!std.ascii.isAlphabetic(key[0]) and key[0] != '_')) return false;
    for (key[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

pub fn free(allocator: std.mem.Allocator, variables: []const Variable) void {
    for (variables) |variable| {
        allocator.free(variable.key);
        allocator.free(variable.value);
    }
    allocator.free(variables);
}

pub fn clone(allocator: std.mem.Allocator, variables: []const Variable) ![]Variable {
    var result: std.ArrayList(Variable) = .empty;
    errdefer {
        for (result.items) |variable| {
            allocator.free(variable.key);
            allocator.free(variable.value);
        }
        result.deinit(allocator);
    }
    try result.ensureTotalCapacityPrecise(allocator, variables.len);
    for (variables) |variable| {
        const key = try allocator.dupe(u8, variable.key);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, variable.value);
        result.appendAssumeCapacity(.{ .key = key, .value = value });
    }
    return result.toOwnedSlice(allocator);
}

pub const Mutation = union(enum) {
    set: Variable,
    unset: []const u8,
    clear,
    replace: []const Variable,
};

pub fn mutate(allocator: std.mem.Allocator, existing: []const Variable, mutation: Mutation) ![]Variable {
    var result: std.ArrayList(Variable) = .empty;
    defer result.deinit(allocator);
    switch (mutation) {
        .clear => {},
        .replace => |variables| try result.appendSlice(allocator, variables),
        .set, .unset => {
            const key = switch (mutation) {
                .set => |variable| variable.key,
                .unset => |name| name,
                else => unreachable,
            };
            if (!validName(key)) return error.InvalidEnvironmentName;
            for (existing) |variable| {
                if (!std.mem.eql(u8, variable.key, key)) try result.append(allocator, variable);
            }
            if (mutation == .set) try result.append(allocator, mutation.set);
        },
    }
    try validate(result.items);
    return clone(allocator, result.items);
}

pub fn parseJson(allocator: std.mem.Allocator, json: []const u8) ![]Variable {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.EnvironmentObjectRequired;
    var variables: std.ArrayList(Variable) = .empty;
    defer variables.deinit(allocator);
    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.EnvironmentStringRequired;
        try variables.append(allocator, .{ .key = entry.key_ptr.*, .value = entry.value_ptr.string });
    }
    try validate(variables.items);
    return clone(allocator, variables.items);
}

pub fn overlay(map: *std.process.Environ.Map, variables: []const Variable) !void {
    try validate(variables);
    for (variables) |variable| try map.put(variable.key, variable.value);
}

// Keep bundled arguments as desktop-entry text, including field codes. Only
// the executable and user-provided literal assignments are serialized anew.
pub const Exec = struct {
    assignments: []const u8 = "",
    executable: []const u8,
    suffix: []const u8,
};

fn tokenEnd(text: []const u8) !usize {
    var quoted = false;
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        switch (try desktopCharacter(text, &i)) {
            '\\' => _ = try desktopCharacter(text, &i),
            '"' => quoted = !quoted,
            ' ', '\t' => if (!quoted) return start,
            else => {},
        }
    }
    if (quoted) return error.InvalidDesktopExec;
    return i;
}

// Desktop string escapes are decoded before the Exec command's quoting rules.
fn desktopCharacter(text: []const u8, index: *usize) !u8 {
    if (index.* == text.len) return error.InvalidDesktopExec;
    const c = text[index.*];
    index.* += 1;
    if (c != '\\') return c;
    if (index.* == text.len) return error.InvalidDesktopExec;
    const escaped = text[index.*];
    index.* += 1;
    return switch (escaped) {
        '\\' => '\\',
        's' => ' ',
        't' => '\t',
        'n' => '\n',
        'r' => '\r',
        else => error.InvalidDesktopExec,
    };
}

fn unquote(token: []const u8) []const u8 {
    if (token.len >= 2 and token[0] == '"' and token[token.len - 1] == '"') return token[1 .. token.len - 1];
    return token;
}

pub fn parseExec(text: []const u8) !Exec {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const first_end = try tokenEnd(trimmed);
    if (first_end == 0) return error.InvalidDesktopExec;
    const first = trimmed[0..first_end];
    var remaining = std.mem.trimStart(u8, trimmed[first_end..], " \t");
    if (!std.mem.eql(u8, std.fs.path.basename(unquote(first)), "env"))
        return .{ .executable = first, .suffix = remaining };
    if (std.mem.startsWith(u8, remaining, "-- ")) remaining = std.mem.trimStart(u8, remaining[3..], " \t");
    const assignment_start = remaining;
    while (remaining.len > 0) {
        const end = try tokenEnd(remaining);
        const token = unquote(remaining[0..end]);
        if (std.mem.indexOfScalar(u8, token, '=')) |equals| {
            if (!validName(token[0..equals])) return error.InvalidEnvironmentName;
            remaining = std.mem.trimStart(u8, remaining[end..], " \t");
        } else {
            if (token.len == 0 or token[0] == '-') return error.UnsupportedDesktopExec;
            return .{
                .assignments = assignment_start[0 .. assignment_start.len - remaining.len],
                .executable = remaining[0..end],
                .suffix = std.mem.trimStart(u8, remaining[end..], " \t"),
            };
        }
    }
    return error.InvalidDesktopExec;
}

fn writeLiteral(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |c| switch (c) {
        '\\' => try writer.writeAll("\\\\\\\\"),
        '"', '$', '`' => {
            try writer.writeAll("\\\\");
            try writer.writeByte(c);
        },
        '%' => try writer.writeAll("%%"),
        '\n', '\r', 0 => return error.InvalidEnvironmentValue,
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

pub fn composeExec(allocator: std.mem.Allocator, path: []const u8, source: ?[]const u8, variables: []const Variable) ![]u8 {
    try validate(variables);
    const command = if (source) |text| try parseExec(text) else Exec{ .executable = "", .suffix = "" };
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    if (variables.len > 0 or command.assignments.len > 0) {
        try out.writer.writeAll("env ");
        try out.writer.writeAll(command.assignments);
        for (variables) |variable| {
            const assignment = try std.fmt.allocPrint(allocator, "{s}={s}", .{ variable.key, variable.value });
            defer allocator.free(assignment);
            try writeLiteral(&out.writer, assignment);
            try out.writer.writeByte(' ');
        }
    }
    try writeLiteral(&out.writer, path);
    if (command.suffix.len > 0) try out.writer.print(" {s}", .{command.suffix});
    return out.toOwnedSlice();
}

pub fn sameExecutable(a: []const u8, b: []const u8) bool {
    const left = parseExec(a) catch return false;
    const right = parseExec(b) catch return false;
    return std.mem.eql(u8, unquote(left.executable), unquote(right.executable));
}

test "environment validation and JSON preserve literal values" {
    const allocator = std.testing.allocator;
    const variables = try parseJson(allocator, "{\"EMPTY\":\"\",\"VALUE\":\" a=b $HOME %U \"}");
    defer free(allocator, variables);
    try std.testing.expectEqualStrings("", variables[0].value);
    try std.testing.expectEqualStrings(" a=b $HOME %U ", variables[1].value);
    try std.testing.expectError(error.InvalidEnvironmentName, validate(&.{.{ .key = "1BAD", .value = "" }}));
    try std.testing.expectError(error.InvalidEnvironmentValue, validate(&.{.{ .key = "OK", .value = "x\ny" }}));
    try std.testing.expectError(error.DuplicateEnvironmentName, validate(&.{ .{ .key = "A", .value = "1" }, .{ .key = "A", .value = "2" } }));
    try std.testing.expectError(error.DuplicateField, parseJson(allocator, "{\"A\":\"1\",\"A\":\"2\"}"));
}

test "desktop composition preserves bundled arguments and overrides bundled environment" {
    const allocator = std.testing.allocator;
    const command = try composeExec(allocator, "/apps/My App.AppImage", "env FOO=old BAR=keep AppRun --safe %U", &.{.{ .key = "FOO", .value = "new" }});
    defer allocator.free(command);
    try std.testing.expectEqualStrings("env FOO=old BAR=keep \"FOO=new\" \"/apps/My App.AppImage\" --safe %U", command);
    try std.testing.expectError(error.UnsupportedDesktopExec, composeExec(allocator, "/app", "env -S AppRun", &.{}));
}

test "environment overlay retains inherited values and overrides an existing value" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("KEEP", "inherited");
    try map.put("OVERRIDE", "old");
    try overlay(&map, &.{.{ .key = "OVERRIDE", .value = "" }});
    try std.testing.expectEqualStrings("inherited", map.get("KEEP").?);
    try std.testing.expectEqualStrings("", map.get("OVERRIDE").?);
}

test "desktop composition parses quoted bundled assignments without losing arguments" {
    const allocator = std.testing.allocator;
    const source = try composeExec(allocator, "/apps/old app", "AppRun --safe %U", &.{.{ .key = "SPECIAL", .value = "a \"q r\" \\ $HOME `text` %U" }});
    defer allocator.free(source);
    const parsed = try parseExec(source);
    try std.testing.expectEqualStrings("\"/apps/old app\"", parsed.executable);
    try std.testing.expectEqualStrings("--safe %U", parsed.suffix);
    const command = try composeExec(allocator, "/apps/new app", source, &.{});
    defer allocator.free(command);
    try std.testing.expect(std.mem.endsWith(u8, command, "\"/apps/new app\" --safe %U"));
}
