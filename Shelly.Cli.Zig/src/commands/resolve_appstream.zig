const std = @import("std");
const pm = @import("PackageManager");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const output = @import("../output/config.zig");

pub fn dispatch(context: *runtime.RuntimeContext, invocation: *const parser.Invocation) !u8 {
    var arena = std.heap.ArenaAllocator.init(context.allocator);
    defer arena.deinit();
    var include_flatpak = true;
    for (invocation.options) |option| if (std.mem.eql(u8, option.name, "--no-flatpak")) {
        include_flatpak = false;
    };
    const result = try pm.appstream_resolver.resolve(arena.allocator(), context.io, context.environ, .{ .config_path = context.config_path }, invocation.positionals[0], include_flatpak);
    var payload: std.Io.Writer.Allocating = .init(context.allocator);
    defer payload.deinit();
    try std.json.Stringify.value(result, .{}, &payload.writer);
    if (invocation.globals.ui_mode) {
        try output.writeFrame(context, payload.writer.buffered());
    } else {
        try context.stdout.writeAll(payload.writer.buffered());
        try context.stdout.writeByte('\n');
        try context.stdout.flush();
    }
    return 0;
}

test "AppStream CLI distinguishes component resolution from package-base resolution" {
    const spec = @import("../cli/spec.zig");
    var tc: @import("test_support.zig").TestContext = undefined;
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{ "resolve", "appstream", "chromium.desktop", "--no-flatpak", "--ui-mode" });
    try std.testing.expectEqualStrings("shelly resolve appstream", outcome.dispatch.command.path);
    try std.testing.expectEqualStrings("chromium.desktop", outcome.dispatch.positionals[0]);
    try std.testing.expect(outcome.dispatch.globals.ui_mode);
}
