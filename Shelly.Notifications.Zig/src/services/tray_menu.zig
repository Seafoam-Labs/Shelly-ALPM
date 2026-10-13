const std = @import("std");
const zeit = @import("zeit");

const zsn = @import("zsn");
const MenuItem = zsn.MenuItem;
const ItemType = zsn.ItemType;
const Tree = zsn.Tree;

const update_model = @import("../models/update.zig");
const Updates = @import("update_store.zig").Updates;
const runtime = @import("../runtime.zig");
const translations = @import("translations.zig");
const trans = translations._;

const Repo = update_model.CheckUpdatesPackage;
const Aur = update_model.CheckUpdatesAur;
const Flatpak = update_model.CheckUpdatesFlatpak;

pub const Ids = struct {
    open_shelly: i32 = 0,
    run_updates: i32 = 0,
    check_updates: i32 = 0,
    quit: i32 = 0,
};

pub var ids: Ids = .{};

var next_id: i32 = 0;
var generation_seen: u64 = 0;
var generation_start: i32 = 0;

pub fn build(ctx: ?*anyopaque, arena: std.mem.Allocator) !Tree {
    const updates: *Updates = @ptrCast(@alignCast(ctx.?));

    updates.mutex.lockUncancelable(updates.io);
    defer updates.mutex.unlock(updates.io);

    beginBuild(updates.menu_generation);

    var items = std.ArrayList(MenuItem).empty;

    ids.open_shelly = try addItem(arena, &items, trans("Open Shelly"), true, true, .normal);
    ids.run_updates = try addItem(arena, &items, trans("Update Packages"), true, true, .normal);
    ids.check_updates = try addItem(arena, &items, trans("Check for updates"), true, true, .normal);
    _ = try addItem(arena, &items, "", false, true, .separator);

    const last_check = if (updates.last_check == 0)
        try arena.dupe(u8, trans("Last Check: Never"))
    else
        try formatCheckTime(arena, updates.last_check);
    _ = try addItem(arena, &items, last_check, false, true, .normal);
    _ = try addItem(arena, &items, "", false, true, .separator);

    if (updates.totalLocked() == 0) {
        _ = try addItem(arena, &items, trans("No updates"), false, true, .normal);
    } else {
        try addSubmenu(Repo, arena, &items, "Standard", updates.repo.items, repoLabel);
        try addSubmenu(Aur, arena, &items, "AUR", updates.aur.items, aurLabel);
        try addSubmenu(Flatpak, arena, &items, "Flatpak", updates.flatpak.items, flatpakLabel);
    }

    _ = try addItem(arena, &items, "", true, true, .separator);
    ids.quit = try addItem(arena, &items, trans("Exit"), true, true, .normal);

    return .{ .root = .{ .id = 0, .children = try items.toOwnedSlice(arena) } };
}

fn beginBuild(menu_generation: u64) void {
    if (generation_seen != menu_generation) {
        generation_seen = menu_generation;
        generation_start = next_id;
    } else {
        next_id = generation_start;
    }
}

fn takeId() i32 {
    next_id = if (next_id == std.math.maxInt(i32)) 1 else next_id + 1;
    return next_id;
}

fn addItem(
    arena: std.mem.Allocator,
    items: *std.ArrayList(MenuItem),
    label: []const u8,
    enabled: bool,
    visible: bool,
    itype: ItemType,
) !i32 {
    const id = takeId();
    try items.append(arena, .{
        .id = id,
        .label = label,
        .enabled = enabled,
        .visible = visible,
        .type = itype,
    });
    return id;
}

fn addSubmenu(
    comptime T: type,
    arena: std.mem.Allocator,
    items: *std.ArrayList(MenuItem),
    label: []const u8,
    source: []const T,
    labelFn: fn (std.mem.Allocator, T) anyerror![]const u8,
) !void {
    if (source.len == 0) return;

    var children = std.ArrayList(MenuItem).empty;
    defer children.deinit(arena);

    const parent_id = takeId();

    for (source) |pkg| {
        const child_label = try labelFn(arena, pkg);
        try children.append(arena, .{ .id = takeId(), .label = child_label });
    }

    try items.append(arena, .{
        .id = parent_id,
        .type = .normal,
        .children = try children.toOwnedSlice(arena),
        .label = label,
    });
}

fn repoLabel(arena: std.mem.Allocator, pkg: Repo) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}  {s} -> {s}", .{
        pkg.Name, pkg.CurrentVersion, pkg.NewVersion,
    });
}

fn aurLabel(arena: std.mem.Allocator, pkg: Aur) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}  {s} -> {s}", .{
        pkg.Name, pkg.Version, pkg.NewVersion,
    });
}

fn flatpakLabel(arena: std.mem.Allocator, pkg: Flatpak) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}  {s}", .{
        pkg.Name, pkg.Version,
    });
}

fn formatCheckTime(arena: std.mem.Allocator, ts: i64) ![]const u8 {
    if (ts == 0) return arena.dupe(u8, trans("Last Check: never"));

    var local = zeit.local(arena, runtime.io, .{}) catch {
        return arena.dupe(u8, "Last Check: unknown");
    };
    defer local.deinit();

    const inst = zeit.instant(.{ .unix_timestamp = ts }, &local);
    const dt = inst.time();

    return std.fmt.allocPrint(arena, "{s} {d:0>2}:{d:0>2} {d:0>2}/{d:0>2}", .{
        trans("Last Check:"),
        dt.hour,
        dt.minute,
        dt.day,
        dt.month,
    });
}
