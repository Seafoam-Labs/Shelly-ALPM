//! Owned, structured preparation errors shared by review, CLI JSON and logs.
const std = @import("std");
const word = @import("word.zig");
const functions = @import("function_body.zig");

pub const Diagnostic = struct {
    arena: std.heap.ArenaAllocator,
    code: []const u8,
    package_name: []const u8,
    pkgbuild_path: []const u8,
    field: []const u8,
    expression: []const u8,
    resolved_filename: ?[]const u8,
    line: ?usize,
    message: []const u8,

    pub fn deinit(self: *Diagnostic) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn init(backing: std.mem.Allocator, content: []const u8, path: []const u8, package: []const u8, field: []const u8, filename: ?[]const u8, err: anyerror) !Diagnostic {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        var expression: []const u8 = "";
        var offset: ?usize = null;
        var assignments = word.Assignments{ .input = content };
        while (assignments.next(allocator) catch null) |assignment| {
            if (std.mem.eql(u8, assignment.name, field)) {
                expression = assignment.raw;
                offset = assignment.offset;
            }
        }
        const function_name = try std.fmt.allocPrint(allocator, "package_{s}", .{package});
        const body = (functions.extract_function_body(content, function_name) catch null) orelse
            (functions.extract_function_body(content, "package") catch null);
        if (body) |scoped| {
            assignments = .{ .input = scoped };
            while (assignments.next(allocator) catch null) |assignment| {
                if (std.mem.eql(u8, assignment.name, field)) {
                    expression = assignment.raw;
                    offset = @intFromPtr(scoped.ptr) - @intFromPtr(content.ptr) + assignment.offset;
                }
            }
        }
        const line = if (offset) |pos| 1 + std.mem.count(u8, content[0..pos], "\n") else null;
        const owned_package = try allocator.dupe(u8, package);
        const owned_path = try allocator.dupe(u8, path);
        const owned_field = try allocator.dupe(u8, field);
        const owned_expression = try allocator.dupe(u8, expression);
        const owned_filename = if (filename) |name| try allocator.dupe(u8, name) else null;
        // JSON string escaping makes control characters safe in terminals and
        // one-line logs while retaining exact bytes in the structured fields.
        const message = try std.fmt.allocPrint(allocator, "{s}: {s}:{d}: {s}={s}; selected file {s}: {s} [{s}] (preparation)", .{
            try std.json.Stringify.valueAlloc(allocator, package, .{}),
            try std.json.Stringify.valueAlloc(allocator, path, .{}),
            line orelse 0,
            field,
            try std.json.Stringify.valueAlloc(allocator, expression, .{}),
            try std.json.Stringify.valueAlloc(allocator, filename, .{}),
            switch (err) {
                error.MissingPkgbuildSourceFile => "the selected local file was not found",
                error.UnsafePkgbuildSourcePath => "the selected path is not a regular file inside the package directory",
                error.UnresolvedPkgbuildVariable => "the selection requires unresolved shell evaluation",
                else => "the selected local file could not be reviewed",
            },
            @errorName(err),
        });
        return .{ .arena = arena, .code = @errorName(err), .package_name = owned_package, .pkgbuild_path = owned_path, .field = owned_field, .expression = owned_expression, .resolved_filename = owned_filename, .line = line, .message = message };
    }
};
