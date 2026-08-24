const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gdk = bindings.gdk;

const c = @cImport({
    @cInclude("blur_bridge.h");
});

pub const Region = struct {
    width: c_int,
    height: c_int,
};

pub fn hasBlurCapability(flags: u32) bool {
    return c.shelly_wayland_blur_has_capability(flags) != 0;
}

pub fn regionFor(enabled: bool, width: c_int, height: c_int) ?Region {
    if (!enabled or width <= 0 or height <= 0) return null;
    return .{ .width = width, .height = height };
}

pub const Blur = struct {
    handle: *c.ShellyWaylandBlur,

    pub fn init(display: *gdk.Display, surface: *gdk.Surface) ?*Blur {
        const handle = c.shelly_wayland_blur_new(display, surface) orelse return null;
        const self = std.heap.c_allocator.create(Blur) catch {
            c.shelly_wayland_blur_free(handle);
            return null;
        };
        self.* = .{ .handle = handle };
        return self;
    }

    pub fn update(self: *Blur, enabled: bool, width: c_int, height: c_int) void {
        if (regionFor(enabled, width, height)) |region| {
            c.shelly_wayland_blur_set_region(self.handle, region.width, region.height);
        } else {
            c.shelly_wayland_blur_clear_region(self.handle);
        }
    }

    pub fn deinit(self: *Blur) void {
        c.shelly_wayland_blur_free(self.handle);
        std.heap.c_allocator.destroy(self);
    }
};

test "blur capability is detected from compositor flags" {
    try std.testing.expect(!hasBlurCapability(0));
    try std.testing.expect(hasBlurCapability(1));
    try std.testing.expect(hasBlurCapability(5));
}

test "blur region follows the visible sidebar geometry" {
    try std.testing.expect(regionFor(false, 208, 900) == null);
    try std.testing.expect(regionFor(true, 0, 900) == null);
    try std.testing.expect(regionFor(true, 208, 0) == null);

    const region = regionFor(true, 208, 900) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(c_int, 208), region.width);
    try std.testing.expectEqual(@as(c_int, 900), region.height);
}
