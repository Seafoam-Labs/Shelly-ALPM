//! Installed AppImage loading and browsing state. The UI polls worker completion.
const std = @import("std");
const AppImage = @import("appimage.zig").AppImage;
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const Allocator = std.mem.Allocator;

const LoadState = struct {
    result: ?std.json.Parsed([]AppImage) = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
};

pub const State = struct {
    parsed: ?std.json.Parsed([]AppImage) = null,
    cursor: usize = 0,
    details_active: bool = false,
    checked: bool = false,
    failure: ?anyerror = null,
    load: ?*LoadState = null,
    load_thread: ?std.Thread = null,
    refresh_pending: bool = false,

    pub fn items(self: *const State) []const AppImage {
        return if (self.parsed) |parsed| parsed.value else &.{};
    }

    pub fn selected(self: *const State) ?*const AppImage {
        const apps = self.items();
        return if (self.cursor < apps.len) &apps[self.cursor] else null;
    }

    pub fn deinit(self: *State, allocator: Allocator) void {
        if (self.load_thread) |thread| thread.join();
        if (self.load) |load| {
            if (load.result) |result| result.deinit();
            allocator.destroy(load);
        }
        if (self.parsed) |parsed| parsed.deinit();
        self.* = .{};
    }

    pub fn refresh(self: *State, allocator: Allocator) !void {
        if (self.load != null) {
            self.refresh_pending = true;
            return;
        }
        const load = try allocator.create(LoadState);
        errdefer allocator.destroy(load);
        load.* = .{};
        self.load_thread = try std.Thread.spawn(.{}, loadInstalled, .{load});
        self.load = load;
        self.failure = null;
    }

    pub fn poll(self: *State, allocator: Allocator) !bool {
        const load = self.load orelse return false;
        if (!load.done.load(.acquire)) return false;
        if (self.load_thread) |thread| thread.join();
        self.load_thread = null;
        self.load = null;
        defer allocator.destroy(load);
        self.checked = true;
        self.failure = load.failure;
        if (load.result) |result| {
            var cursor = @min(self.cursor, result.value.len -| 1);
            if (self.selected()) |previous| for (result.value, 0..) |app, index| {
                const matches = if (previous.Path) |path|
                    if (app.Path) |candidate| std.mem.eql(u8, path, candidate) else false
                else
                    std.mem.eql(u8, previous.Name, app.Name);
                if (matches) {
                    cursor = index;
                    break;
                }
            };
            if (self.parsed) |parsed| parsed.deinit();
            self.parsed = result;
            self.cursor = cursor;
            if (result.value.len == 0) self.details_active = false;
        }
        if (self.refresh_pending) {
            self.refresh_pending = false;
            try self.refresh(allocator);
        }
        return true;
    }
};

fn loadInstalled(load: *LoadState) void {
    const allocator = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const cli: ShellyCli = .{ .allocator = allocator, .io = threaded.io() };
    load.result = cli.get_installed_appimages() catch |err| {
        load.failure = err;
        load.done.store(true, .release);
        return;
    };
    load.done.store(true, .release);
}

test "refresh results preserve identity and failures retain owned data" {
    const allocator = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(allocator);
    state.parsed = try std.json.parseFromSlice([]AppImage, allocator, "[{\"Name\":\"Editor\",\"Path\":\"/apps/editor\"}]", .{ .allocate = .alloc_always });
    state.details_active = true;
    const load = try allocator.create(LoadState);
    load.* = .{ .result = try std.json.parseFromSlice([]AppImage, allocator, "[{\"Name\":\"Other\"},{\"Name\":\"Renamed\",\"Path\":\"/apps/editor\"}]", .{ .allocate = .alloc_always }), .done = .init(true) };
    state.load = load;
    try std.testing.expect(try state.poll(allocator));
    try std.testing.expectEqual(@as(usize, 1), state.cursor);
    try std.testing.expect(state.details_active);
    const failed = try allocator.create(LoadState);
    failed.* = .{ .failure = error.CommandFailed, .done = .init(true) };
    state.load = failed;
    try std.testing.expect(try state.poll(allocator));
    try std.testing.expectEqual(error.CommandFailed, state.failure.?);
    try std.testing.expectEqualStrings("Renamed", state.selected().?.Name);
    try std.testing.expect(!try state.poll(allocator));
}

test "refresh requests coalesce and completed empty results clear details" {
    const allocator = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(allocator);
    const load = try allocator.create(LoadState);
    load.* = .{};
    state.load = load;
    try state.refresh(allocator);
    try state.refresh(allocator);
    try std.testing.expect(state.load == load);
    try std.testing.expect(state.refresh_pending);
    try std.testing.expect(!try state.poll(allocator));
    state.refresh_pending = false;
    state.details_active = true;
    state.cursor = 10;
    load.result = try std.json.parseFromSlice([]AppImage, allocator, "[]", .{});
    load.done.store(true, .release);
    try std.testing.expect(try state.poll(allocator));
    try std.testing.expect(state.checked);
    try std.testing.expect(state.selected() == null);
    try std.testing.expect(!state.details_active);
    try std.testing.expectEqual(@as(usize, 0), state.cursor);
}
