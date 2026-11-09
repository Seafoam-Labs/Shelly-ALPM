const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Shelly_Tui = @import("Shelly_Tui");
const Model = Shelly_Tui.model.Model;

pub const panic = std.debug.FullPanic(panicWithTerminalRestore);

fn panicWithTerminalRestore(message: []const u8, return_address: ?usize) noreturn {
    vaxis.recover();
    std.debug.defaultPanic(message, return_address);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const session = Shelly_Tui.sudo_session;
    if (args.len > 1 and std.mem.eql(u8, args[1], session.flag)) {
        try session.launch(init, args);
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
