const std = @import("std");
const file_inspector = @import("../local/file_inspector.zig");
const pkgbuild = @import("pkgbuild_parser.zig");
const shared_validator = @import("shared_validtor.zig");

pub const LocalSourceValidator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn validate(
        self: LocalSourceValidator,
        pkg_build: pkgbuild.Pkgbuild,
        base_directory: ?[]const u8,
    ) !shared_validator.ValidationResult {
        var result = shared_validator.ValidationResult{
            .has_findings = false,
            .findings = std.ArrayList(shared_validator.ValidationFinding).empty,
        };

        const base = base_directory orelse return result;
        const files = pkg_build.local_source_files orelse return result;

        for (files) |file_name| {
            const path = try std.fs.path.join(self.allocator, &.{ base, file_name });
            defer self.allocator.free(path);

            const magic = read_magic(self.io, path) catch continue;
            defer std.heap.page_allocator.free(magic);
            const is_elf = file_inspector.isElfBytes(magic);
            const is_binary = is_elf or has_binary_bytes(magic);
            if (!is_binary) continue;

            const kind: []const u8 = if (is_elf) "ELF executable" else "binary";
            const hook = try std.fmt.allocPrint(self.allocator, "source: {s}", .{file_name});
            const matched_line = try self.allocator.dupe(u8, file_name);
            const message = try std.fmt.allocPrint(
                self.allocator,
                "Local source file '{s}' is an {s} that cannot be reviewed as text — it may contain malicious code.",
                .{ file_name, kind },
            );

            try result.findings.append(self.allocator, .{
                .tool = "<local-binary>",
                .severity = .critical,
                .hook = hook,
                .matched_line = matched_line,
                .message = message,
            });
            result.has_findings = true;
        }

        return result;
    }

    fn read_magic(io: std.Io, path: []const u8) ![]u8 {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var magic: [64]u8 = undefined;
        const amount = try file.readPositionalAll(io, magic[0..], 0);
        return try std.heap.page_allocator.dupe(u8, magic[0..amount]);
    }

    fn has_binary_bytes(bytes: []const u8) bool {
        if (!std.unicode.utf8ValidateSlice(bytes)) return true;
        for (bytes) |byte| {
            if (byte == 0) return true;
            if (std.ascii.isControl(byte) and byte != '\n' and byte != '\r' and byte != '\t' and byte != 0x0b and byte != 0x0c) return true;
        }
        return false;
    }
};

test "local source validator flags ELF and binary files but not text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tool", .data = "\x7fELFpayload" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data.bin", .data = "abc\x00def" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "script.sh", .data = "#!/bin/sh\necho ok\n" });

    const files = try std.testing.allocator.alloc([]const u8, 3);
    defer std.testing.allocator.free(files);
    files[0] = try std.testing.allocator.dupe(u8, "tool");
    defer std.testing.allocator.free(files[0]);
    files[1] = try std.testing.allocator.dupe(u8, "data.bin");
    defer std.testing.allocator.free(files[1]);
    files[2] = try std.testing.allocator.dupe(u8, "script.sh");
    defer std.testing.allocator.free(files[2]);

    var variables = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer variables.deinit();
    var local_source_contents = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer local_source_contents.deinit();

    const info = pkgbuild.Pkgbuild{
        .variables = variables,
        .local_source_files = files,
        .local_source_contents = local_source_contents,
    };

    const validator = LocalSourceValidator{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
    };
    var result = try validator.validate(info, base);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(@as(usize, 2), result.findings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, result.findings.items[0].message, "ELF executable") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.findings.items[1].message, "binary") != null);
    try std.testing.expectEqualStrings("<local-binary>", result.findings.items[0].tool);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, result.findings.items[0].severity);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, result.findings.items[1].severity);
}
