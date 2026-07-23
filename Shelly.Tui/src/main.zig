const std = @import("std");
const zz = @import("zigzag");
const Shelly_Tui = @import("Shelly_Tui");
const Model = Shelly_Tui.model.Model;

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    var program = zz.Program(Model).init(init.gpa, init.io, init.environ_map);
    defer program.deinit();

    try program.run();
}
