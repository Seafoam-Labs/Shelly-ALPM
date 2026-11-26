const std = @import("std");
const features = @import("build_features.zig");
const saved_list = @import("../helpers/saved_list.zig");
const models = @import("../models/packages.zig");
pub const PackageRow = models.PackageRow;
const ShellyCli = @import("shelly_cli.zig").ShellyCli;

extern fn g_get_user_cache_dir() [*:0]const u8;

/// the packages of every repository and the installed ones.
pub const PackageLists = struct {
    Available: []const PackageRow = &.{},
    /// null when the installed packages could not be listed.
    Installed: ?[]const PackageRow = null,

    /// equal for equal lists, so an unchanged listing is not shown or saved again.
    pub fn hash(self: PackageLists) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        std.hash.autoHashStrat(&hasher, self, .DeepRecursive);
        return hasher.final();
    }
};

pub const Saved = struct {
    cached: saved_list.Cached,
    parsed: std.json.Parsed(PackageLists),

    pub fn deinit(self: Saved, alloc: std.mem.Allocator) void {
        self.parsed.deinit();
        self.cached.deinit(alloc);
    }
};

pub fn readSaved(alloc: std.mem.Allocator, io: std.Io, path: []const u8, kind: []const u8) ?Saved {
    const cached = saved_list.read(alloc, io, path, kind, features.version) orelse return null;
    const parsed = std.json.parseFromSlice(PackageLists, alloc, cached.json, .{}) catch {
        cached.deinit(alloc);
        return null;
    };
    const saved: Saved = .{ .cached = cached, .parsed = parsed };
    if (parsed.value.Available.len == 0) {
        saved.deinit(alloc);
        return null;
    }
    return saved;
}

pub fn writeSaved(alloc: std.mem.Allocator, io: std.Io, path: []const u8, kind: []const u8, lists: PackageLists, hash: u64) !void {
    const json = try std.json.Stringify.valueAlloc(alloc, lists, .{ .emit_null_optional_fields = false });
    defer alloc.free(json);
    try saved_list.write(io, path, kind, features.version, hash, json);
}

/// a listing made by the command line.
pub const Fetched = struct {
    available: std.json.Parsed([]PackageRow),
    installed: ?std.json.Parsed([]PackageRow),

    pub fn lists(self: Fetched) PackageLists {
        return .{
            .Available = self.available.value,
            .Installed = if (self.installed) |installed| installed.value else null,
        };
    }

    pub fn deinit(self: Fetched) void {
        self.available.deinit();
        if (self.installed) |installed| installed.deinit();
    }
};

const InstalledFetch = struct {
    cli: ShellyCli,
    parsed: ?std.json.Parsed([]PackageRow) = null,

    fn run(self: *InstalledFetch) void {
        self.parsed = self.cli.get_installed_packages() catch null;
    }
};

/// lists both at the same time. `cli` needs a thread-safe allocator.
pub fn fetch(cli: ShellyCli, show_hidden: bool) !Fetched {
    var installed: InstalledFetch = .{ .cli = cli };
    const thread = std.Thread.spawn(.{}, InstalledFetch.run, .{&installed}) catch null;
    const available = cli.get_packages(show_hidden);
    if (thread) |t| t.join() else installed.run();

    return .{
        .available = available catch |err| {
            if (installed.parsed) |parsed| parsed.deinit();
            return err;
        },
        .installed = installed.parsed,
    };
}

/// where the list for one `show_hidden` value is saved.
pub const Slot = struct {
    path: []const u8 = "",
    kind: []const u8 = "",
    buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,

    pub fn init(self: *Slot, show_hidden: bool) void {
        self.kind = if (show_hidden) "packages-hidden" else "packages";
        self.path = std.fmt.bufPrint(&self.buffer, "{s}/shelly/{s}", .{ g_get_user_cache_dir(), self.kind }) catch "";
    }

    pub fn read(self: *const Slot, cli: ShellyCli) ?Saved {
        return readSaved(cli.allocator, cli.io, self.path, self.kind);
    }

    /// keeps the listing for the next visit unless `saved_hash` says it is there already.
    pub fn update(self: *const Slot, cli: ShellyCli, lists: PackageLists, hash: u64, saved_hash: ?u64) void {
        if (saved_hash == hash or lists.Installed == null) return;
        writeSaved(cli.allocator, cli.io, self.path, self.kind, lists, hash) catch |err|
            std.log.warn("Could not save the package list: {s}", .{@errorName(err)});
    }
};

const testing = std.testing;

const TestPath = struct {
    tmp: testing.TmpDir,
    buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,

    fn path(self: *TestPath) ![]const u8 {
        const len = try self.tmp.dir.realPath(testing.io, &self.buffer);
        const tail = "/packages";
        @memcpy(self.buffer[len..][0..tail.len], tail);
        return self.buffer[0 .. len + tail.len];
    }
};

test "saved lists come back with every field" {
    var t: TestPath = .{ .tmp = testing.tmpDir(.{}) };
    defer t.tmp.cleanup();
    const path = try t.path();

    const row: PackageRow = .{
        .Name = "foo",
        .Version = "1-1",
        .Description = "tab\there \"quoted\" ünïcode",
        .Repository = "core",
        .Groups = &.{ "base", "devel" },
        .InstallReason = "Explicit",
        .InstallDate = "2026-11-25",
        .InstalledSize = 7,
        .InstalledFrom = "core",
        .InstalledFromInferred = true,
    };
    const lists: PackageLists = .{ .Available = &.{ row, .{ .Name = "bar" } }, .Installed = &.{row} };
    try writeSaved(testing.allocator, testing.io, path, "packages", lists, lists.hash());

    const saved = readSaved(testing.allocator, testing.io, path, "packages") orelse return error.NotSaved;
    defer saved.deinit(testing.allocator);
    try testing.expectEqualDeep(lists, saved.parsed.value);
    try testing.expectEqual(lists.hash(), saved.cached.stamp);
    try testing.expect(readSaved(testing.allocator, testing.io, path, "packages-hidden") == null);
}

test "a saved list that is not valid is ignored" {
    var t: TestPath = .{ .tmp = testing.tmpDir(.{}) };
    defer t.tmp.cleanup();
    const path = try t.path();

    for ([_][]const u8{ "{\"Available\":[", "[]", "{\"Available\":[]}" }) |json| {
        try saved_list.write(testing.io, path, "packages", features.version, 1, json);
        try testing.expect(readSaved(testing.allocator, testing.io, path, "packages") == null);
    }
}

test "the hash is stable and follows every saved field" {
    const base: PackageRow = .{ .Name = "foo", .Version = "1-1", .Repository = "core", .InstallReason = "Explicit" };
    const lists: PackageLists = .{ .Available = &.{base}, .Installed = &.{base} };
    var copy_name = "foo".*;
    var copy = base;
    copy.Name = &copy_name;
    try testing.expectEqual(lists.hash(), (PackageLists{ .Available = &.{copy}, .Installed = &.{copy} }).hash());

    inline for (comptime std.meta.fieldNames(PackageRow)) |name| {
        var changed = base;
        @field(changed, name) = switch (@FieldType(PackageRow, name)) {
            []const u8 => "changed",
            ?[]const u8 => "changed",
            i64 => 42,
            bool => true,
            []const []const u8 => &.{"changed"},
            else => @compileError("no changed value for " ++ name),
        };
        try testing.expect(lists.hash() != (PackageLists{ .Available = &.{changed}, .Installed = &.{base} }).hash());
    }
    try testing.expect(lists.hash() != (PackageLists{ .Available = &.{base}, .Installed = null }).hash());
    try testing.expect(lists.hash() != (PackageLists{ .Available = &.{base}, .Installed = &.{} }).hash());
}
