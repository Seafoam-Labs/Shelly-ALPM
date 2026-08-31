const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;

pub fn stringSorter(comptime T: type, comptime getter: *const fn (*T) [:0]const u8) *gtk.Sorter {
    const cmp = struct {
        fn compare(a_ptr: ?*const anyopaque, b_ptr: ?*const anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            const pa: *T = @ptrCast(@alignCast(@constCast(a_ptr.?)));
            const pb: *T = @ptrCast(@alignCast(@constCast(b_ptr.?)));
            return switch (std.ascii.orderIgnoreCase(getter(pa), getter(pb))) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
        }
    };
    return gtk.CustomSorter.new(&cmp.compare, null, null).as(gtk.Sorter);
}

pub fn boolSorter(comptime T: type, comptime getter: anytype) *gtk.Sorter {
    const cmp = struct {
        fn compare(a_ptr: ?*const anyopaque, b_ptr: ?*const anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            const pa: *T = @ptrCast(@alignCast(@constCast(a_ptr.?)));
            const pb: *T = @ptrCast(@alignCast(@constCast(b_ptr.?)));
            const va = getter(pa);
            const vb = getter(pb);
            if (va == vb) return 0;
            return if (va) -1 else 1;
        }
    };
    return gtk.CustomSorter.new(&cmp.compare, null, null).as(gtk.Sorter);
}

pub fn numericSorter(comptime T: type, comptime getter: anytype) *gtk.Sorter {
    const cmp = struct {
        fn compare(a_ptr: ?*const anyopaque, b_ptr: ?*const anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            const pa: *T = @ptrCast(@alignCast(@constCast(a_ptr.?)));
            const pb: *T = @ptrCast(@alignCast(@constCast(b_ptr.?)));
            const va = getter(pa);
            const vb = getter(pb);
            if (va < vb) return -1;
            if (va > vb) return 1;
            return 0;
        }
    };
    return gtk.CustomSorter.new(&cmp.compare, null, null).as(gtk.Sorter);
}
