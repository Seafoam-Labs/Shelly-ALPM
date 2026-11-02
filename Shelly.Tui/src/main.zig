const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Shelly_Tui = @import("Shelly_Tui");
const Model = Shelly_Tui.model.Model;

pub fn main(init: std.process.Init) !void {
    if (init.environ_map.get(Shelly_Tui.sudo_askpass.socket_environment)) |socket_path| {
        Shelly_Tui.sudo_askpass.respond(init.io, socket_path) catch std.process.exit(1);
        return;
    }
    // ShellyCli reads io and the environment map from the runtime globals.
    Shelly_Tui.runtime.setup(init);

    const model = try Model.init(init.gpa);
    defer model.deinit();
    model.loadSettings(init.io, init.environ_map);

    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(init.io, init.gpa, init.environ_map, &buffer);
    defer app.deinit();

    Shelly_Tui.runtime.terminal = &app;
    defer Shelly_Tui.runtime.terminal = null;
    try app.run(model.widget(), .{});
}
