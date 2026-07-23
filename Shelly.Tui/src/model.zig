const std = @import("std");
const zz = @import("zigzag");
const RunResult = std.process.RunResult;
const builtin = std.builtin;
const runtime = @import("runtime.zig");
const shelly_cli = @import("shelly_cli.zig");
const ShellyCli = shelly_cli.ShellyCli;

pub const Model = struct {
    group: zz.TabGroup,
    package_grid: zz.DataTable,
    aur_grid: zz.DataTable,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
    };

    pub fn init(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        _ = self;
        _ = ctx;
        return .none;
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        const body = self.group.viewWithContent(ctx.allocator, "No active route") catch "render error";

        var hint_style = zz.Style{};
        hint_style = hint_style.fg(zz.Color.gray(12));
        hint_style = hint_style.inline_style(true);
        const help = hint_style.render(ctx.allocator, "q: quit | ←/→: switch | 1..9: jump | +/- or ↑/↓: counter actions") catch "";

        return std.fmt.allocPrint(ctx.allocator, "{s}\n\n{s}", .{ body, help }) catch body;
    }

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| {
                switch (k.key) {
                    .char => |c| if (c == 'q') return .quit,
                    .escape => return .quit,
                    else => {},
                }
                _ = self.group.handleKeyAndRoute(k);
            },
        }
        return .none;
    }

    fn run(self: ShellyCli, args: []const []const u8) !RunResult {
        const shelly_bin = if (builtin.mode == .Debug)
            "../Shelly.Cli.Zig/zig-out/bin/shelly"
        else
            "shelly";

        var argv = try self.allocator.alloc([]const u8, args.len + 2);
        defer self.allocator.free(argv);
        argv[0] = shelly_bin;
        @memcpy(argv[1 .. 1 + args.len], args);
        argv[argv.len - 1] = "--ui-mode";

        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .environ_map = runtime.environ_map,
        });
        errdefer self.allocator.free(result.stdout);
        errdefer self.allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("failed: term={any} stderr='{s}' stdout='{s}'\n", .{
                result.term, result.stderr, result.stdout[0..@min(500, result.stdout.len)],
            });
            return error.CommandFailed;
        }

        return result;
    }
};
