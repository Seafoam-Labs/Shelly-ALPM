const std = @import("std");
const install_script = @import("install_script.zig");
const script_validator = @import("post_install_validator.zig");
const shared_validator = @import("shared_validtor.zig");

/// Scans the complete byte stream that libalpm will source. This includes all
/// six recognized hooks, helper functions, duplicate definitions, and commands
/// at top level; it never sources or otherwise executes the script.
pub const InstallScriptScanner = struct {
    allocator: std.mem.Allocator,

    pub fn validate(
        self: InstallScriptScanner,
        script: *const install_script.Script,
    ) !shared_validator.ValidationResult {
        var result = shared_validator.ValidationResult{
            .has_findings = false,
            .findings = .empty,
        };
        errdefer result.deinit(self.allocator);

        const validator = script_validator.PostInstallValidator{ .allocator = self.allocator };
        var offset: usize = 0;
        while (offset < script.contents.len) {
            const newline = std.mem.indexOfScalarPos(u8, script.contents, offset, '\n') orelse script.contents.len;
            const line = script.contents[offset..newline];
            const label = try self.scopeLabel(script, offset);
            defer self.allocator.free(label);
            try validator.scan_hook(line, label, &result);
            offset = if (newline < script.contents.len) newline + 1 else script.contents.len;
        }
        return result;
    }

    fn scopeLabel(
        self: InstallScriptScanner,
        script: *const install_script.Script,
        offset: usize,
    ) ![]u8 {
        return switch (script.scopeAt(offset)) {
            .top_level => std.fmt.allocPrint(self.allocator, "install:{s}:top-level", .{script.file_name}),
            .helper => |name| std.fmt.allocPrint(self.allocator, "install:{s}:helper:{s}", .{ script.file_name, name }),
            .hook => |hook| std.fmt.allocPrint(self.allocator, "install:{s}:{s}", .{ script.file_name, hook.name() }),
        };
    }
};

test "install script scanner covers top-level helpers and hooks" {
    const source =
        "curl https://example.invalid/top\n" ++
        "helper() { sudo true; }\n" ++
        "pre_upgrade() { eval echo bad; }\n";
    var script = try install_script.Script.init(std.testing.allocator, "demo.install", source);
    defer script.deinit(std.testing.allocator);
    var result = try (InstallScriptScanner{ .allocator = std.testing.allocator }).validate(&script);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.findings.items.len);
    try std.testing.expectEqualStrings("install:demo.install:top-level", result.findings.items[0].hook);
    try std.testing.expectEqualStrings("install:demo.install:helper:helper", result.findings.items[1].hook);
    try std.testing.expectEqualStrings("install:demo.install:pre_upgrade", result.findings.items[2].hook);
}
