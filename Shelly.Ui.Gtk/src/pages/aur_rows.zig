const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const gobject = bindings.gobject;
const AurPackageObject = @import("../g_objects/aur_package_object.zig").AurPackageObject;
const AurPackage = @import("../models/aur_package.zig").AurPackage;

/// puts a new answer in place of the rows on screen. rows that are picked for
/// install, and the one whose details are open, stay so while they are listed.
pub fn update(store: *gio.ListStore, selection: *gtk.SingleSelection, packages: []const AurPackage) void {
    const alloc = std.heap.c_allocator;
    const model = store.as(gio.ListModel);
    const old_len = gio.ListModel.getNItems(model);
    if (unchanged(model, old_len, packages)) return;

    var picked: std.StringHashMapUnmanaged(void) = .empty;
    defer picked.deinit(alloc);
    var i: c_uint = 0;
    while (i < old_len) : (i += 1) {
        const object = gio.ListModel.getObject(model, i) orelse continue;
        defer object.unref();
        const pkg = gobject.ext.cast(AurPackageObject, object) orelse continue;
        // the old rows own these names until the splice.
        if (pkg.isSelected()) picked.put(alloc, pkg.getName(), {}) catch {};
    }
    var shown: ?[:0]u8 = null;
    defer if (shown) |name| alloc.free(name);
    if (gtk.SingleSelection.getSelectedItem(selection)) |item| {
        if (gobject.ext.cast(AurPackageObject, item)) |pkg| shown = alloc.dupeSentinel(u8, pkg.getName(), 0) catch null;
    }

    var objects: std.ArrayListUnmanaged(*gobject.Object) = .empty;
    defer objects.deinit(alloc);
    objects.ensureTotalCapacity(alloc, packages.len) catch return;
    for (packages) |package| {
        const pkg = AurPackageObject.new(package) catch continue;
        pkg.setSelected(picked.contains(pkg.getName()));
        objects.appendAssumeCapacity(pkg.as(gobject.Object));
    }
    gio.ListStore.splice(store, 0, old_len, objects.items.ptr, @intCast(objects.items.len));
    for (objects.items) |object| object.unref();

    if (shown) |name| {
        if (gtk.SingleSelection.getSelectedItem(selection) == null) select(selection, name);
    }
}

fn unchanged(model: *gio.ListModel, len: c_uint, packages: []const AurPackage) bool {
    if (len != packages.len) return false;
    for (packages, 0..) |package, i| {
        const object = gio.ListModel.getObject(model, @intCast(i)) orelse return false;
        defer object.unref();
        const pkg = gobject.ext.cast(AurPackageObject, object) orelse return false;
        if (!pkg.matches(package)) return false;
    }
    return true;
}

fn select(selection: *gtk.SingleSelection, name: []const u8) void {
    const model = selection.as(gio.ListModel);
    const n = gio.ListModel.getNItems(model);
    var i: c_uint = 0;
    while (i < n) : (i += 1) {
        const object = gio.ListModel.getObject(model, i) orelse continue;
        defer object.unref();
        const pkg = gobject.ext.cast(AurPackageObject, object) orelse continue;
        if (!std.mem.eql(u8, pkg.getName(), name)) continue;
        _ = gtk.SelectionModel.selectItem(selection.as(gtk.SelectionModel), i, 1);
        return;
    }
}
