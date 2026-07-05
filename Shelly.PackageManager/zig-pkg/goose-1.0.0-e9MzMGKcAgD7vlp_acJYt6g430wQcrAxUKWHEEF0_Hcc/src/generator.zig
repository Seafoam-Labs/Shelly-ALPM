const std = @import("std");
const introspection = @import("introspection.zig");

/// Generates Zig Proxy source code from a D-Bus Node tree.
pub fn generate(allocator: std.mem.Allocator, node: introspection.Node, dest: ?[]const u8, path: ?[]const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 2048);
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "const goose = @import(\"goose\");\n");
    try out.appendSlice(allocator, "const proxy = goose.proxy;\n");
    try out.appendSlice(allocator, "const GStr = goose.core.value.GStr;\n\n");

    for (node.interfaces) |iface| {
        // Simple name cleaning (e.g. org.freedesktop.DBus -> DBus)
        var short_name = iface.name;
        if (std.mem.lastIndexOfScalar(u8, iface.name, '.')) |pos| {
            short_name = iface.name[pos + 1 ..];
        }

        try out.appendSlice(allocator, "pub const ");
        try out.appendSlice(allocator, short_name);
        try out.appendSlice(allocator, "Proxy = struct {\n");
        try out.appendSlice(allocator, "    inner: proxy.Proxy,\n\n");

        try out.appendSlice(allocator, "    pub fn init(conn: *goose.Connection");
        if (dest == null) try out.appendSlice(allocator, ", dest: [:0]const u8");
        if (path == null) try out.appendSlice(allocator, ", path: [:0]const u8");
        try out.appendSlice(allocator, ") ");
        try out.appendSlice(allocator, short_name);
        try out.appendSlice(allocator, "Proxy {\n");
        try out.appendSlice(allocator, "        return .{ .inner = proxy.Proxy.init(conn, ");
        if (dest) |d| {
            try out.print(allocator, "\"{s}\"", .{d});
        } else {
            try out.appendSlice(allocator, "dest");
        }
        try out.appendSlice(allocator, ", ");
        if (path) |p| {
            try out.print(allocator, "\"{s}\"", .{p});
        } else {
            try out.appendSlice(allocator, "path");
        }
        try out.appendSlice(allocator, ", \"");
        try out.appendSlice(allocator, iface.name);
        try out.appendSlice(allocator, "\") };\n");
        try out.appendSlice(allocator, "    }\n\n");

        for (iface.methods) |method| {
            try out.appendSlice(allocator, "    pub fn ");
            try out.appendSlice(allocator, method.name);
            try out.appendSlice(allocator, "(self: ");
            try out.appendSlice(allocator, short_name);
            try out.appendSlice(allocator, "Proxy");

            // Generate In args
            var in_idx: usize = 0;
            for (method.args) |arg| {
                if (std.mem.eql(u8, arg.direction, "in")) {
                    try out.appendSlice(allocator, ", ");
                    if (arg.name.len > 0) {
                        try out.appendSlice(allocator, arg.name);
                    } else {
                        try out.print(allocator, "arg{d}", .{in_idx});
                    }
                    try out.appendSlice(allocator, ": ");
                    try out.appendSlice(allocator, try dbusTypeToZig(arg.type, true));
                    in_idx += 1;
                }
            }

            // Return type
            var out_sig: ?[]const u8 = null;
            for (method.args) |arg| {
                if (std.mem.eql(u8, arg.direction, "out")) {
                    out_sig = arg.type;
                    break;
                }
            }

            const out_type = if (out_sig) |s| try dbusTypeToZig(s, false) else "void";
            const is_method_result = std.mem.eql(u8, out_type, "proxy.MethodResult");

            try out.appendSlice(allocator, ") !");
            try out.appendSlice(allocator, out_type);
            try out.appendSlice(allocator, " {\n");

            if (is_method_result) {
                try out.appendSlice(allocator, "        const res = try self.inner.call(\"");
            } else {
                try out.appendSlice(allocator, "        var res = try self.inner.call(\"");
            }
            try out.appendSlice(allocator, method.name);
            try out.appendSlice(allocator, "\", .{");

            var call_idx: usize = 0;
            var first = true;
            for (method.args) |arg| {
                if (std.mem.eql(u8, arg.direction, "in")) {
                    if (!first) try out.appendSlice(allocator, ", ");
                    if (arg.name.len > 0) {
                        try out.appendSlice(allocator, arg.name);
                    } else {
                        try out.print(allocator, "arg{d}", .{call_idx});
                    }
                    first = false;
                    call_idx += 1;
                }
            }
            try out.appendSlice(allocator, "});\n");

            if (std.mem.eql(u8, out_type, "void")) {
                try out.appendSlice(allocator, "        res.deinit();\n");
            } else if (is_method_result) {
                try out.appendSlice(allocator, "        return res;\n");
            } else {
                try out.appendSlice(allocator, "        return res.expect(");
                try out.appendSlice(allocator, out_type);
                try out.appendSlice(allocator, ");\n");
            }
            try out.appendSlice(allocator, "    }\n");
        }

        try out.appendSlice(allocator, "};\n\n");
    }

    return out.toOwnedSlice(allocator);
}

fn dbusTypeToZig(sig: []const u8, is_param: bool) ![]const u8 {
    if (std.mem.eql(u8, sig, "s")) return "GStr";
    if (std.mem.eql(u8, sig, "u")) return "u32";
    if (std.mem.eql(u8, sig, "b")) return "bool";
    if (std.mem.eql(u8, sig, "as")) return "[]const GStr";
    if (std.mem.eql(u8, sig, "i")) return "i32";
    if (std.mem.eql(u8, sig, "x")) return "i64";
    if (std.mem.eql(u8, sig, "t")) return "u64";
    if (std.mem.eql(u8, sig, "d")) return "f64";

    if (is_param) return "anytype";
    return "proxy.MethodResult";
}
