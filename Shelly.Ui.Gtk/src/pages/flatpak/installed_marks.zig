const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gio = bindings.gio;
const gobject = bindings.gobject;
const flatpak = @import("../../models/flatpak.zig");
const AppstreamAppObject = @import("../../g_objects/appstream_app_object.zig").AppstreamAppObject;

/// marks installed apps and has the drawn rows updated for those that changed.
/// changing the row in the list does not: gtk keeps the widget of the same item.
pub fn apply(alloc: std.mem.Allocator, model: *gio.ListStore, installed: []const flatpak.Flatpak, rows: anytype) error{OutOfMemory}!void {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(alloc);
    for (installed) |app| try names.put(alloc, app.Name, {});

    const list = model.as(gio.ListModel);
    var position: c_uint = 0;
    while (position < gio.ListModel.getNItems(list)) : (position += 1) {
        const item: *gobject.Object = @ptrCast(@alignCast(gio.ListModel.getItem(list, position) orelse continue));
        defer item.unref();
        const app = gobject.ext.cast(AppstreamAppObject, item) orelse continue;
        const now = names.contains(app.getName());
        if (app.isInstalled() == now) continue;
        app.setInstalled(now);
        rows.redraw(app);
    }
}

const TestRows = struct {
    count: usize = 0,
    last: ?*AppstreamAppObject = null,

    pub fn redraw(self: *TestRows, app: *AppstreamAppObject) void {
        self.count += 1;
        self.last = app;
    }
};

fn testModel(names: []const [:0]const u8) !*gio.ListStore {
    const model = gio.ListStore.new(AppstreamAppObject.getGObjectType());
    for (names) |name| {
        const object = try AppstreamAppObject.new(.{ .Id = name, .Name = name });
        defer object.as(gobject.Object).unref();
        gio.ListStore.append(model, object.as(gobject.Object));
    }
    return model;
}

fn testInstalled(model: *gio.ListStore, position: c_uint) bool {
    const item: *gobject.Object = @ptrCast(@alignCast(gio.ListModel.getItem(model.as(gio.ListModel), position).?));
    defer item.unref();
    return gobject.ext.cast(AppstreamAppObject, item).?.isInstalled();
}

test "installed marks follow installs and removals and redraw only changed rows" {
    const model = try testModel(&.{ "one", "two", "three" });
    defer model.as(gobject.Object).unref();
    var rows: TestRows = .{};

    try apply(std.testing.allocator, model, &.{.{ .Name = "two" }}, &rows);
    try std.testing.expect(!testInstalled(model, 0));
    try std.testing.expect(testInstalled(model, 1));
    try std.testing.expectEqual(@as(usize, 1), rows.count);
    try std.testing.expectEqualStrings("two", rows.last.?.getName());

    try apply(std.testing.allocator, model, &.{.{ .Name = "two" }}, &rows);
    try std.testing.expectEqual(@as(usize, 1), rows.count);

    try apply(std.testing.allocator, model, &.{.{ .Name = "three" }}, &rows);
    try std.testing.expect(!testInstalled(model, 1));
    try std.testing.expect(testInstalled(model, 2));
    try std.testing.expectEqual(@as(usize, 3), rows.count);
}
