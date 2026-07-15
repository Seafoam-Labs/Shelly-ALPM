const std = @import("std");

const default_candidate_paths = [_][]const u8{
    "/etc/os-release",
    "/usr/lib/os-release",
};

/// Returns the operating system's display name from the standard os-release
/// locations. The returned slice is owned by `allocator`.
pub fn prettyName(allocator: std.mem.Allocator, io: std.Io) ?[]u8 {
    return getPrettyName(allocator, io, &default_candidate_paths);
}

/// Returns the display name from the first readable candidate file.
///
/// `PRETTY_NAME` takes precedence over `NAME`, even when `NAME` appears first.
/// The returned slice is owned by `allocator`. As with the C# implementation,
/// file and allocation errors are represented by `null`.
pub fn getPrettyName(
    allocator: std.mem.Allocator,
    io: std.Io,
    candidate_paths: []const []const u8,
) ?[]u8 {
    const path = resolvePath(io, candidate_paths) orelse return null;
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return null;
    defer allocator.free(contents);

    const name = parsePrettyName(contents) orelse return null;
    return allocator.dupe(u8, name) catch null;
}

fn resolvePath(io: std.Io, candidate_paths: []const []const u8) ?[]const u8 {
    for (candidate_paths) |candidate| {
        std.Io.Dir.cwd().access(io, candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}

/// Parses os-release contents and returns a slice borrowed from `contents`.
pub fn parsePrettyName(contents: []const u8) ?[]const u8 {
    var name: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, contents, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const separator = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (separator == 0) continue;

        const key = std.mem.trim(u8, trimmed[0..separator], " \t\r");
        const raw_value = std.mem.trim(u8, trimmed[separator + 1 ..], " \t\r");
        const value = std.mem.trim(u8, raw_value, "\"'");

        if (std.mem.eql(u8, key, "PRETTY_NAME")) return value;
        if (std.mem.eql(u8, key, "NAME")) name = value;
    }

    return name;
}

const testing = std.testing;

test "parsePrettyName prefers PRETTY_NAME over NAME" {
    const contents =
        \\NAME=Arch Linux
        \\PRETTY_NAME="CachyOS Linux"
    ;
    try testing.expectEqualStrings("CachyOS Linux", parsePrettyName(contents).?);
}

test "parsePrettyName falls back to the last NAME" {
    const contents =
        \\NAME='First Name'
        \\IGNORED=value
        \\NAME="Fallback OS"
    ;
    try testing.expectEqualStrings("Fallback OS", parsePrettyName(contents).?);
}

test "parsePrettyName trims keys values and quote characters" {
    const contents = "  PRETTY_NAME = '\"Shelly Linux\"'  \r\n";
    try testing.expectEqualStrings("Shelly Linux", parsePrettyName(contents).?);
}

test "parsePrettyName ignores malformed and case-mismatched keys" {
    const contents =
        \\=missing-key
        \\PRETTY_NAME
        \\pretty_name="wrong case"
    ;
    try testing.expect(parsePrettyName(contents) == null);
}

test "getPrettyName uses the first existing candidate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "first", .data = "NAME=First\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "second", .data = "NAME=Second\n" });

    var first_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var second_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const first_len = try tmp.dir.realPathFile(testing.io, "first", &first_buffer);
    const second_len = try tmp.dir.realPathFile(testing.io, "second", &second_buffer);
    const candidates = [_][]const u8{ first_buffer[0..first_len], second_buffer[0..second_len] };

    const result = getPrettyName(testing.allocator, testing.io, &candidates).?;
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("First", result);
}

test "getPrettyName skips missing candidates and returns null when none exist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "fallback", .data = "PRETTY_NAME=Fallback\n" });

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const missing = try std.fs.path.join(testing.allocator, &.{ root, "missing" });
    defer testing.allocator.free(missing);
    const fallback = try std.fs.path.join(testing.allocator, &.{ root, "fallback" });
    defer testing.allocator.free(fallback);

    const candidates = [_][]const u8{ missing, fallback };
    const result = getPrettyName(testing.allocator, testing.io, &candidates).?;
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Fallback", result);

    const missing_only = [_][]const u8{missing};
    try testing.expect(getPrettyName(testing.allocator, testing.io, &missing_only) == null);
}
