const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_entries_examined: usize = 8192;

pub const max_suggestions: usize = 256;

pub const AppImagePaths = struct {
    allocator: Allocator,

    max_entries_examined: usize = max_entries_examined,
    max_suggestions: usize = max_suggestions,

    pub const Candidate = struct {
        path: []u8,
        is_directory: bool,
    };

    pub const Completion = struct {
        candidates: []Candidate,
        truncated: bool,
    };

    pub fn resolve(self: AppImagePaths, input: []const u8, cwd: []const u8, home: []const u8) ![]u8 {
        const parsed = try self.parse(input, cwd, home);
        return parsed.path;
    }

    pub fn complete(self: AppImagePaths, io: std.Io, input: []const u8, cwd: []const u8, home: []const u8) !Completion {
        const parsed = try self.parse(input, cwd, home);
        defer self.allocator.free(parsed.path);

        var parent: []const u8 = undefined;
        var prefix: []const u8 = "";
        if (parsed.trailing_separator) {
            parent = parsed.path;
        } else {
            parent = std.fs.path.dirname(parsed.path) orelse parsed.path;
            prefix = std.fs.path.basename(parsed.path);
        }

        const dir = try std.Io.Dir.openDirAbsolute(io, parent, .{ .iterate = true });
        defer std.Io.Dir.close(dir, io);

        var candidates = std.ArrayList(AppImagePaths.Candidate).empty;
        errdefer {
            for (candidates.items) |candidate| self.allocator.free(candidate.path);
            candidates.deinit(self.allocator);
        }

        var examined: usize = 0;
        var truncated = false;

        var it = std.Io.Dir.iterate(dir);
        while (try it.next(io)) |entry| {
            examined += 1;
            if (examined > self.max_entries_examined) {
                truncated = true;
                break;
            }
            if (entry.kind == .file and !hasAppImageExtension(entry.name)) continue;
            if (entry.kind != .directory and entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
            if (candidates.items.len >= self.max_suggestions) {
                truncated = true;
                break;
            }

            const base = try std.fs.path.join(self.allocator, &.{ parent, entry.name });
            defer self.allocator.free(base);
            const is_directory = entry.kind == .directory;
            const path = if (is_directory) try self.appendSeparator(base) else try self.allocator.dupe(u8, base);
            errdefer self.allocator.free(path);
            try candidates.append(self.allocator, .{ .path = path, .is_directory = is_directory });
        }

        std.mem.sort(AppImagePaths.Candidate, candidates.items, {}, compareCandidates);
        return .{ .candidates = try candidates.toOwnedSlice(self.allocator), .truncated = truncated };
    }

    pub fn validate(self: AppImagePaths, io: std.Io, input: []const u8, cwd: []const u8, home: []const u8) ![]u8 {
        const resolved = try self.resolve(input, cwd, home);
        errdefer self.allocator.free(resolved);

        const stat = try std.Io.Dir.cwd().statFile(io, resolved, .{});
        if (stat.kind != .file) return error.NotAFile;
        if (!hasAppImageExtension(resolved)) return error.WrongExtension;

        var file = try std.Io.Dir.openFileAbsolute(io, resolved, .{ .mode = .read_only });
        defer file.close(io);

        return resolved;
    }

    pub fn freeCompletion(self: AppImagePaths, completion: Completion) void {
        for (completion.candidates) |candidate| self.allocator.free(candidate.path);
        self.allocator.free(completion.candidates);
    }

    const ParsedPath = struct {
        path: []u8,
        trailing_separator: bool,
    };

    fn parse(self: AppImagePaths, input: []const u8, cwd: []const u8, home: []const u8) !ParsedPath {
        if (std.mem.indexOfScalar(u8, input, 0) != null) return error.InvalidPath;

        const unquoted = stripQuotes(input) orelse input;
        if (unquoted.len == 0) return error.EmptyPath;

        var expanded_owned: ?[]u8 = null;
        defer if (expanded_owned) |s| self.allocator.free(s);
        var expanded: []const u8 = unquoted;
        if (std.mem.eql(u8, unquoted, "~")) {
            const s = try self.allocator.dupe(u8, home);
            expanded = s;
            expanded_owned = s;
        } else if (std.mem.startsWith(u8, unquoted, "~/")) {
            const s = try std.fs.path.join(self.allocator, &.{ home, unquoted[2..] });
            expanded = s;
            expanded_owned = s;
        }

        const trailing_separator = expanded.len > 0 and std.fs.path.isSep(expanded[expanded.len - 1]);

        var joined_owned: ?[]u8 = null;
        defer if (joined_owned) |s| self.allocator.free(s);
        var root: []const u8 = expanded;
        if (!std.fs.path.isAbsolute(expanded)) {
            const joined = try std.fs.path.join(self.allocator, &.{ cwd, expanded });
            joined_owned = joined;
            root = joined;
        }

        const resolved = try std.fs.path.resolveAlloc(self.allocator, &.{root});
        errdefer self.allocator.free(resolved);
        return .{ .path = resolved, .trailing_separator = trailing_separator };
    }

    fn stripQuotes(input: []const u8) ?[]const u8 {
        if (input.len < 2) return null;
        const first = input[0];
        const last = input[input.len - 1];
        const matching = (first == '"' and last == '"') or (first == '\'' and last == '\'');
        if (!matching) return null;
        return input[1 .. input.len - 1];
    }

    fn hasAppImageExtension(name: []const u8) bool {
        const ext = std.fs.path.extension(name);
        return ext.len == ".appimage".len and std.ascii.eqlIgnoreCase(ext, ".appimage");
    }

    fn compareCandidates(_: void, a: AppImagePaths.Candidate, b: AppImagePaths.Candidate) bool {
        if (a.is_directory != b.is_directory) return a.is_directory;
        const order = std.ascii.orderIgnoreCase(a.path, b.path);
        return if (order == .eq) std.mem.order(u8, a.path, b.path) == .lt else order == .lt;
    }

    fn appendSeparator(self: AppImagePaths, path: []const u8) ![]u8 {
        const with_sep = try self.allocator.alloc(u8, path.len + 1);
        @memcpy(with_sep[0..path.len], path);
        with_sep[path.len] = std.fs.path.sep;
        return with_sep;
    }
};

test "resolve handles absolute, relative, quoted, tilde, spaces, and literal shell characters" {
    const allocator = std.testing.allocator;
    const cwd = "/work";
    const home = "/home/u";
    var service = AppImagePaths{ .allocator = allocator };

    const cases = &[_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "/home/user/App.AppImage", .expected = "/home/user/App.AppImage" },
        .{ .input = "sub/App.AppImage", .expected = "/work/sub/App.AppImage" },
        .{ .input = ".", .expected = "/work" },
        .{ .input = "./foo.AppImage", .expected = "/work/foo.AppImage" },
        .{ .input = "~/App.AppImage", .expected = "/home/u/App.AppImage" },
        .{ .input = "~", .expected = "/home/u" },
        .{ .input = "~/../etc/App.AppImage", .expected = "/home/etc/App.AppImage" },
        .{ .input = "/home/u/my App.AppImage", .expected = "/home/u/my App.AppImage" },
        .{ .input = "\"/home/u/App.AppImage\"", .expected = "/home/u/App.AppImage" },
        .{ .input = "'my App.AppImage'", .expected = "/work/my App.AppImage" },
        .{ .input = "\"a b c.AppImage\"", .expected = "/work/a b c.AppImage" },
        .{ .input = "'", .expected = "/work/'" },
        .{ .input = "/a/b/../c.AppImage", .expected = "/a/c.AppImage" },
        .{ .input = "/a/`rm -rf`.AppImage", .expected = "/a/`rm -rf`.AppImage" },
        .{ .input = "/a/$HOME.AppImage", .expected = "/a/$HOME.AppImage" },
        .{ .input = "/a/*.AppImage", .expected = "/a/*.AppImage" },
        .{ .input = "/a/foo~bar.AppImage", .expected = "/a/foo~bar.AppImage" },
    };
    for (cases) |case| {
        const resolved = try service.resolve(case.input, cwd, home);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings(case.expected, resolved);
    }

    try std.testing.expectError(error.EmptyPath, service.resolve("", cwd, home));
    try std.testing.expectError(error.EmptyPath, service.resolve("\"\"", cwd, home));
    try std.testing.expectError(error.InvalidPath, service.resolve("a\x00b.AppImage", cwd, home));
}

test "completion filters, orders, marks directories, and truncates" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const real = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(real);

    (try tmp.dir.createFile(io, "a.AppImage", .{})).close(io);
    (try tmp.dir.createFile(io, "b.AppImage", .{})).close(io);
    (try tmp.dir.createFile(io, "upper.APPIMAGE", .{})).close(io);
    (try tmp.dir.createFile(io, "notes.txt", .{})).close(io);
    try tmp.dir.createDir(io, "Downloads", .default_dir);
    try tmp.dir.createDir(io, "Applications", .default_dir);

    var service = AppImagePaths{ .allocator = allocator };

    {
        const listing = try std.mem.concat(allocator, u8, &.{ real, "/" });
        defer allocator.free(listing);
        const comp = try service.complete(io, listing, real, "/home/u");
        defer service.freeCompletion(comp);

        try std.testing.expect(!comp.truncated);
        try std.testing.expectEqual(@as(usize, 5), comp.candidates.len);
        try std.testing.expect(comp.candidates[0].is_directory);
        try std.testing.expect(comp.candidates[1].is_directory);
        try std.testing.expect(!comp.candidates[2].is_directory);
        try std.testing.expect(!comp.candidates[3].is_directory);
        try std.testing.expect(!comp.candidates[4].is_directory);

        const dir2 = try std.mem.concat(allocator, u8, &.{ real, "/Applications/" });
        defer allocator.free(dir2);
        try std.testing.expectEqualStrings(dir2, comp.candidates[0].path);
        const sub = try std.mem.concat(allocator, u8, &.{ real, "/Downloads/" });
        defer allocator.free(sub);
        try std.testing.expectEqualStrings(sub, comp.candidates[1].path);
        const a = try std.mem.concat(allocator, u8, &.{ real, "/a.AppImage" });
        defer allocator.free(a);
        try std.testing.expectEqualStrings(a, comp.candidates[2].path);
        const b = try std.mem.concat(allocator, u8, &.{ real, "/b.AppImage" });
        defer allocator.free(b);
        try std.testing.expectEqualStrings(b, comp.candidates[3].path);
        const upper = try std.mem.concat(allocator, u8, &.{ real, "/upper.APPIMAGE" });
        defer allocator.free(upper);
        try std.testing.expectEqualStrings(upper, comp.candidates[4].path);
    }

    const upper_candidate: AppImagePaths.Candidate = .{ .path = @constCast("/A.AppImage"), .is_directory = false };
    const lower_candidate: AppImagePaths.Candidate = .{ .path = @constCast("/a.AppImage"), .is_directory = false };
    try std.testing.expect(AppImagePaths.compareCandidates({}, upper_candidate, lower_candidate));
    try std.testing.expect(!AppImagePaths.compareCandidates({}, lower_candidate, upper_candidate));

    {
        const upper = try std.mem.concat(allocator, u8, &.{ real, "/upper" });
        defer allocator.free(upper);
        const comp = try service.complete(io, upper, real, "/home/u");
        defer service.freeCompletion(comp);
        try std.testing.expectEqual(@as(usize, 1), comp.candidates.len);
        try std.testing.expectEqualStrings("upper.APPIMAGE", std.fs.path.basename(comp.candidates[0].path));

        const capital = try std.mem.concat(allocator, u8, &.{ real, "/Upper" });
        defer allocator.free(capital);
        const empty = try service.complete(io, capital, real, "/home/u");
        defer service.freeCompletion(empty);
        try std.testing.expectEqual(@as(usize, 0), empty.candidates.len);
    }

    {
        const many = try std.mem.concat(allocator, u8, &.{ real, "/" });
        defer allocator.free(many);
        var bounded = AppImagePaths{ .allocator = allocator, .max_suggestions = 2 };
        const comp = try bounded.complete(io, many, real, "/home/u");
        defer bounded.freeCompletion(comp);
        try std.testing.expect(comp.truncated);
        try std.testing.expectEqual(@as(usize, 2), comp.candidates.len);
    }

    {
        const many = try std.mem.concat(allocator, u8, &.{ real, "/" });
        defer allocator.free(many);
        var bounded = AppImagePaths{ .allocator = allocator, .max_entries_examined = 2 };
        const comp = try bounded.complete(io, many, real, "/home/u");
        defer bounded.freeCompletion(comp);
        try std.testing.expect(comp.truncated);
        try std.testing.expect(comp.candidates.len <= 2);
    }
}

test "validation accepts a local AppImage and rejects missing, directory, and wrong-extension inputs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const real = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(real);

    (try tmp.dir.createFile(io, "Good.AppImage", .{})).close(io);
    try tmp.dir.createDir(io, "NotAFile.AppImage", .default_dir);
    (try tmp.dir.createFile(io, "notes.txt", .{})).close(io);

    // A symlink to a regular .AppImage is accepted.
    try tmp.dir.symLink(io, "Good.AppImage", "link.AppImage", .{});

    var service = AppImagePaths{ .allocator = allocator };

    const good = try std.mem.concat(allocator, u8, &.{ real, "/Good.AppImage" });
    defer allocator.free(good);
    {
        const resolved = try service.validate(io, good, real, "/home/u");
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings(good, resolved);
    }
    {
        const linked = try std.mem.concat(allocator, u8, &.{ real, "/link.AppImage" });
        defer allocator.free(linked);
        const resolved = try service.validate(io, linked, real, "/home/u");
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings(linked, resolved);
    }

    const missing = try std.mem.concat(allocator, u8, &.{ real, "/Missing.AppImage" });
    defer allocator.free(missing);
    try std.testing.expectError(error.FileNotFound, service.validate(io, missing, real, "/home/u"));

    const dir = try std.mem.concat(allocator, u8, &.{ real, "/NotAFile.AppImage" });
    defer allocator.free(dir);
    try std.testing.expectError(error.NotAFile, service.validate(io, dir, real, "/home/u"));

    const wrong = try std.mem.concat(allocator, u8, &.{ real, "/notes.txt" });
    defer allocator.free(wrong);
    try std.testing.expectError(error.WrongExtension, service.validate(io, wrong, real, "/home/u"));
}

test "completion and validation free cleanly through the testing allocator" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const real = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(real);
    (try tmp.dir.createFile(io, "x.AppImage", .{})).close(io);

    var service = AppImagePaths{ .allocator = allocator };
    const listing = try std.mem.concat(allocator, u8, &.{ real, "/" });
    defer allocator.free(listing);

    const comp = try service.complete(io, listing, real, "/home/u");
    service.freeCompletion(comp);
    try tmp.dir.createDir(io, "Downloads", .default_dir);
    try std.testing.checkAllAllocationFailures(allocator, completionAllocationCheck, .{real});

    const file = try std.mem.concat(allocator, u8, &.{ real, "/x.AppImage" });
    defer allocator.free(file);
    const resolved = try service.validate(io, file, real, "/home/u");
    allocator.free(resolved);
}

fn completionAllocationCheck(allocator: Allocator, directory: []const u8) !void {
    const service: AppImagePaths = .{ .allocator = allocator };
    const input = try std.mem.concat(allocator, u8, &.{ directory, "/" });
    defer allocator.free(input);
    const completion = try service.complete(std.testing.io, input, directory, directory);
    defer service.freeCompletion(completion);
}
