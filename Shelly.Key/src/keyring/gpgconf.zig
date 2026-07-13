const std = @import("std");
const Io = std.Io;

pub const GpgConfError = error{
    NotARegularFile,
    OptionTooLong,
    ConfigFileTooLarge,
} || std.Io.Dir.OpenError ||
    std.Io.Dir.StatFileError ||
    std.Io.Dir.SetFilePermissionsError ||
    std.Io.File.OpenError ||
    std.Io.File.ReadPositionalError ||
    std.Io.File.WritePositionalError ||
    std.Io.File.LengthError;

pub fn ensureGpgConf(
    base: std.Io.Dir,
    io: Io,
    keyring_dir: []const u8,
) GpgConfError!void {
    var dir = try base.openDir(io, keyring_dir, .{});
    defer dir.close(io);

    try ensureRegularFile(dir, io, "gpg.conf");
    try dir.setFilePermissions(io, "gpg.conf", @enumFromInt(0o644), .{});

    try ensureOption(dir, io, "gpg.conf", "no-greeting", null);
    try ensureOption(dir, io, "gpg.conf", "no-permission-warning", null);
    try ensureOption(dir, io, "gpg.conf", "keyserver-options", "timeout=10");
    try ensureOption(dir, io, "gpg.conf", "keyserver-options", "import-clean");
    try ensureOption(dir, io, "gpg.conf", "keyserver-options", "no-self-sigs-only");
}

pub fn ensureGpgAgentConf(
    base: std.Io.Dir,
    io: Io,
    keyring_dir: []const u8,
) GpgConfError!void {
    var dir = try base.openDir(io, keyring_dir, .{});
    defer dir.close(io);

    try ensureRegularFile(dir, io, "gpg-agent.conf");
    try dir.setFilePermissions(io, "gpg-agent.conf", @enumFromInt(0o644), .{});

    try ensureOption(dir, io, "gpg-agent.conf", "disable-scdaemon", null);
}

pub fn ensureOption(
    dir: std.Io.Dir,
    io: Io,
    conf_name: []const u8,
    option_name: []const u8,
    option_value: ?[]const u8,
) GpgConfError!void {
    var opt_buf: [128]u8 = undefined;
    const option_str = buildOptionString(&opt_buf, option_name, option_value) catch
        return error.OptionTooLong;

    if (try optionExists(dir, io, conf_name, option_str)) return;

    try appendOption(dir, io, conf_name, option_str);
}

fn ensureRegularFile(dir: std.Io.Dir, io: Io, name: []const u8) GpgConfError!void {
    if (try isRegularFile(dir, io, name)) return;

    var f = dir.createFile(io, name, .{}) catch |err| switch (err) {
        error.IsDir => return error.NotARegularFile,
        else => |e| return e,
    };
    f.close(io);
}

fn isRegularFile(dir: std.Io.Dir, io: Io, name: []const u8) GpgConfError!bool {
    const st = dir.statFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return st.kind == .file;
}

fn optionExists(
    dir: std.Io.Dir,
    io: Io,
    conf_name: []const u8,
    option_str: []const u8,
) GpgConfError!bool {
    var read_buf: [4096]u8 = undefined;

    var file = dir.openFile(io, conf_name, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer file.close(io);

    const n = try file.readPositionalAll(io, &read_buf, 0);

    // If the buffer was filled, the file may be larger than we can scan.
    if (n == read_buf.len) {
        const size = try file.length(io);
        if (size > n) return error.ConfigFileTooLarge;
    }

    var it = std.mem.splitScalar(u8, read_buf[0..n], '\n');
    while (it.next()) |line| {
        if (lineMatchesOption(line, option_str)) return true;
    }
    return false;
}

fn buildOptionString(
    buf: []u8,
    name: []const u8,
    value: ?[]const u8,
) error{NoSpaceLeft}![]u8 {
    if (value) |v| {
        const total = name.len + 1 + v.len;
        if (total > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = ' ';
        @memcpy(buf[name.len + 1 ..][0..v.len], v);
        return buf[0..total];
    } else {
        if (name.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
}

fn appendOption(
    dir: std.Io.Dir,
    io: Io,
    conf_name: []const u8,
    option_str: []const u8,
) GpgConfError!void {
    var line_buf: [256]u8 = undefined;
    if (option_str.len + 1 > line_buf.len) return error.OptionTooLong;
    @memcpy(line_buf[0..option_str.len], option_str);
    line_buf[option_str.len] = '\n';
    const line = line_buf[0 .. option_str.len + 1];

    var file = try dir.openFile(io, conf_name, .{ .mode = .read_write });
    defer file.close(io);

    const offset = try file.length(io);
    try file.writePositionalAll(io, line, offset);
}

fn lineMatchesOption(line: []const u8, option_str: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (isSpace(line[i]) or line[i] == '#')) : (i += 1) {}

    if (i + option_str.len > line.len) return false;
    if (!std.mem.eql(u8, line[i..][0..option_str.len], option_str)) return false;

    const after = i + option_str.len;
    if (after == line.len) return true;
    return isSpace(line[after]);
}

fn isSpace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', 0x0B, 0x0C => true, // 0x0B is \v, 0x0C is \f
        else => false,
    };
}

const testing = std.testing;

fn statMode(dir: Io.Dir, io: Io, sub_path: []const u8) !std.posix.mode_t {
    const st = try dir.statFile(io, sub_path, .{});
    return st.permissions.toMode() & 0o7777;
}

fn readFile(dir: Io.Dir, io: Io, name: []const u8) ![]u8 {
    var buf: [4096]u8 = undefined;
    var file = try dir.openFile(io, name, .{});
    defer file.close(io);
    const n = try file.readPositionalAll(io, &buf, 0);
    const out = try testing.allocator.dupe(u8, buf[0..n]);
    return out;
}

test "lineMatchesOption: exact active line" {
    try testing.expect(lineMatchesOption("no-greeting", "no-greeting"));
}

test "lineMatchesOption: leading whitespace" {
    try testing.expect(lineMatchesOption("  no-greeting", "no-greeting"));
    try testing.expect(lineMatchesOption("\tno-greeting", "no-greeting"));
}

test "lineMatchesOption: leading hash comments" {
    try testing.expect(lineMatchesOption("#no-greeting", "no-greeting"));
    try testing.expect(lineMatchesOption("# no-greeting", "no-greeting"));
    try testing.expect(lineMatchesOption("## no-greeting", "no-greeting"));
    try testing.expect(lineMatchesOption("# # no-greeting", "no-greeting"));
}

test "lineMatchesOption: trailing whitespace and text" {
    try testing.expect(lineMatchesOption("no-greeting ", "no-greeting"));
    try testing.expect(lineMatchesOption("no-greeting extra stuff", "no-greeting"));
    try testing.expect(lineMatchesOption("no-greeting\t", "no-greeting"));
}

test "lineMatchesOption: trailing carriage return" {
    try testing.expect(lineMatchesOption("no-greeting\r", "no-greeting"));
}

test "lineMatchesOption: rejects extra char before" {
    try testing.expect(!lineMatchesOption("xno-greeting", "no-greeting"));
}

test "lineMatchesOption: rejects extra char after" {
    try testing.expect(!lineMatchesOption("no-greetingx", "no-greeting"));
}

test "lineMatchesOption: rejects empty line" {
    try testing.expect(!lineMatchesOption("", "no-greeting"));
}

test "lineMatchesOption: rejects bare prefix of option" {
    try testing.expect(!lineMatchesOption("no-greet", "no-greeting"));
}

test "lineMatchesOption: option with value matches exactly" {
    const opt = "keyserver-options timeout=10";
    try testing.expect(lineMatchesOption("keyserver-options timeout=10", opt));
    try testing.expect(lineMatchesOption("# keyserver-options timeout=10", opt));
}

test "lineMatchesOption: option with value rejects different value" {
    const opt = "keyserver-options timeout=10";
    try testing.expect(!lineMatchesOption("keyserver-options timeout=20", opt));
    try testing.expect(!lineMatchesOption("keyserver-options import-clean", opt));
}

test "ensureOption appends to an empty file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    {
        var dir = try tmp.dir.openDir(testing.io, ".", .{});
        defer dir.close(testing.io);
        var f = try dir.createFile(testing.io, "gpg.conf", .{});
        f.close(testing.io);
    }

    try ensureOption(tmp.dir, testing.io, "gpg.conf", "no-greeting", null);

    const content = try readFile(tmp.dir, testing.io, "gpg.conf");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("no-greeting\n", content);
}

test "ensureOption does not duplicate an active option" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    {
        var dir = try tmp.dir.openDir(testing.io, ".", .{});
        defer dir.close(testing.io);
        var f = try dir.createFile(testing.io, "gpg.conf", .{});
        try f.writeStreamingAll(testing.io, "no-greeting\n");
        f.close(testing.io);
    }

    try ensureOption(tmp.dir, testing.io, "gpg.conf", "no-greeting", null);

    const content = try readFile(tmp.dir, testing.io, "gpg.conf");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("no-greeting\n", content);
}

test "ensureOption does not duplicate a commented-out option" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    {
        var dir = try tmp.dir.openDir(testing.io, ".", .{});
        defer dir.close(testing.io);
        var f = try dir.createFile(testing.io, "gpg.conf", .{});
        try f.writeStreamingAll(testing.io, "# no-greeting\n");
        f.close(testing.io);
    }

    try ensureOption(tmp.dir, testing.io, "gpg.conf", "no-greeting", null);

    const content = try readFile(tmp.dir, testing.io, "gpg.conf");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("# no-greeting\n", content);
}

test "ensureOption appends a value option when only the name differs" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    {
        var dir = try tmp.dir.openDir(testing.io, ".", .{});
        defer dir.close(testing.io);
        var f = try dir.createFile(testing.io, "gpg.conf", .{});
        try f.writeStreamingAll(testing.io, "keyserver-options timeout=10\n");
        f.close(testing.io);
    }

    try ensureOption(tmp.dir, testing.io, "gpg.conf", "keyserver-options", "import-clean");

    const content = try readFile(tmp.dir, testing.io, "gpg.conf");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(
        "keyserver-options timeout=10\nkeyserver-options import-clean\n",
        content,
    );
}

test "ensureOption preserves existing content and appends after it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    {
        var dir = try tmp.dir.openDir(testing.io, ".", .{});
        defer dir.close(testing.io);
        var f = try dir.createFile(testing.io, "gpg.conf", .{});
        try f.writeStreamingAll(testing.io, "# my config\nuse-agent\n");
        f.close(testing.io);
    }

    try ensureOption(tmp.dir, testing.io, "gpg.conf", "no-greeting", null);

    const content = try readFile(tmp.dir, testing.io, "gpg.conf");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("# my config\nuse-agent\nno-greeting\n", content);
}

test "ensureOption is idempotent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    {
        var dir = try tmp.dir.openDir(testing.io, ".", .{});
        defer dir.close(testing.io);
        var f = try dir.createFile(testing.io, "gpg.conf", .{});
        f.close(testing.io);
    }

    try ensureOption(tmp.dir, testing.io, "gpg.conf", "no-greeting", null);
    try ensureOption(tmp.dir, testing.io, "gpg.conf", "no-greeting", null);
    try ensureOption(tmp.dir, testing.io, "gpg.conf", "no-greeting", null);

    const content = try readFile(tmp.dir, testing.io, "gpg.conf");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("no-greeting\n", content);
}

test "ensureGpgConf creates gpg.conf with required options" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);

    try ensureGpgConf(tmp.dir, testing.io, "gnupg");

    var gnupg = try tmp.dir.openDir(testing.io, "gnupg", .{});
    defer gnupg.close(testing.io);

    try testing.expectEqual(
        @as(std.posix.mode_t, 0o644),
        try statMode(gnupg, testing.io, "gpg.conf"),
    );

    const content = try readFile(gnupg, testing.io, "gpg.conf");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(
        \\no-greeting
        \\no-permission-warning
        \\keyserver-options timeout=10
        \\keyserver-options import-clean
        \\keyserver-options no-self-sigs-only
        \\
    , content);
}

test "ensureGpgConf is idempotent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);

    try ensureGpgConf(tmp.dir, testing.io, "gnupg");
    try ensureGpgConf(tmp.dir, testing.io, "gnupg");

    var gnupg = try tmp.dir.openDir(testing.io, "gnupg", .{});
    defer gnupg.close(testing.io);

    const content = try readFile(gnupg, testing.io, "gpg.conf");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(
        \\no-greeting
        \\no-permission-warning
        \\keyserver-options timeout=10
        \\keyserver-options import-clean
        \\keyserver-options no-self-sigs-only
        \\
    , content);
}

test "ensureGpgConf preserves user comments and does not duplicate" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);
    {
        var gnupg = try tmp.dir.openDir(testing.io, "gnupg", .{});
        defer gnupg.close(testing.io);
        var f = try gnupg.createFile(testing.io, "gpg.conf", .{});
        try f.writeStreamingAll(testing.io, "# my greeting pref\nno-greeting\n");
        f.close(testing.io);
    }

    try ensureGpgConf(tmp.dir, testing.io, "gnupg");

    var gnupg = try tmp.dir.openDir(testing.io, "gnupg", .{});
    defer gnupg.close(testing.io);

    const content = try readFile(gnupg, testing.io, "gpg.conf");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(
        \\# my greeting pref
        \\no-greeting
        \\no-permission-warning
        \\keyserver-options timeout=10
        \\keyserver-options import-clean
        \\keyserver-options no-self-sigs-only
        \\
    , content);
}

test "ensureGpgConf fails when gpg.conf path is a directory" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);
    try tmp.dir.createDir(testing.io, "gnupg/gpg.conf", .default_dir);

    try testing.expectError(
        error.NotARegularFile,
        ensureGpgConf(tmp.dir, testing.io, "gnupg"),
    );
}

test "ensureGpgAgentConf creates gpg-agent.conf with disable-scdaemon" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);

    try ensureGpgAgentConf(tmp.dir, testing.io, "gnupg");

    var gnupg = try tmp.dir.openDir(testing.io, "gnupg", .{});
    defer gnupg.close(testing.io);

    try testing.expectEqual(
        @as(std.posix.mode_t, 0o644),
        try statMode(gnupg, testing.io, "gpg-agent.conf"),
    );

    const content = try readFile(gnupg, testing.io, "gpg-agent.conf");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("disable-scdaemon\n", content);
}

test "ensureGpgAgentConf is idempotent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);

    try ensureGpgAgentConf(tmp.dir, testing.io, "gnupg");
    try ensureGpgAgentConf(tmp.dir, testing.io, "gnupg");

    var gnupg = try tmp.dir.openDir(testing.io, "gnupg", .{});
    defer gnupg.close(testing.io);

    const content = try readFile(gnupg, testing.io, "gpg-agent.conf");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("disable-scdaemon\n", content);
}
