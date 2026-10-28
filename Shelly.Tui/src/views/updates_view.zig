const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Allocator = std.mem.Allocator;

// The Updates tab has no data or operation yet.
pub fn appendContent(_: vxfw.DrawContext, _: *std.ArrayList(vxfw.SubSurface)) Allocator.Error!void {}

pub fn statusText() []const u8 {
    return "Not implemented yet";
}
