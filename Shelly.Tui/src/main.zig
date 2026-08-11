const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Shelly_Tui = @import("Shelly_Tui");
const Model = Shelly_Tui.model.Model;

pub fn main(init: std.process.Init) !void {
    // ShellyCli reads io and the environment map from the runtime globals.
    Shelly_Tui.runtime.setup(init);

    const model = try Model.init(init.gpa);
    defer model.deinit();

    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(init.io, init.gpa, init.environ_map, &buffer);
    defer app.deinit();

    try app.run(model.widget(), .{});
}
