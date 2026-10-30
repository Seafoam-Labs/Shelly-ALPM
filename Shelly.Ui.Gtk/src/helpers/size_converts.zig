const std = @import("std");

pub const SizeConverter = struct {
    pub fn convert_null_term(buf: []u8, bytes: i64) [:0]const u8 {
        const suffixes = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };

        const neg = bytes < 0;
        const abs: u64 = @intCast(if (neg) -%bytes else bytes);

        if (abs < 1024) {
            return std.fmt.bufPrintSentinel(buf, "{d} B", .{bytes}, 0) catch "?";
        }

        const bits = 63 - @clz(abs);
        var i: usize = @intCast(bits / 10);
        if (i >= suffixes.len) i = suffixes.len - 1;

        const shift: u6 = @intCast(i * 10);
        const whole = abs >> shift;
        const rem = abs & ((@as(u64, 1) << shift) - 1);
        const frac = (rem * 100) >> shift;

        const sign: []const u8 = if (neg) "-" else "";
        return std.fmt.bufPrintSentinel(buf, "{s}{d}.{d:0>2} {s}", .{ sign, whole, frac, suffixes[i] }, 0) catch "?";
    }
};
