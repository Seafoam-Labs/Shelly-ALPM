const std = @import("std");

pub const ValidationSeverity = enum(i32) { info, warning, critical };

pub const ValidationFinding = struct {
    tool: []const u8,
    severity: ValidationSeverity,
    hook: []const u8,
    matched_line: []const u8,
    message: []const u8,
};

pub const ValidationResult = struct {
    has_findings: bool,
    findings: std.ArrayList(ValidationFinding),

    pub fn deinit(self: *ValidationResult, allocator: std.mem.Allocator) void {
        for (self.findings.items) |finding| {
            allocator.free(finding.hook);
            allocator.free(finding.matched_line);
            allocator.free(finding.message);
        }
        self.findings.deinit(allocator);
    }
};
