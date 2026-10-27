pub const PkgBuild = struct {
    Name: []const u8,
    PkgBuild: []const u8,
    Scan: ?ScanResult = null,

    pub const Finding = struct {
        tool: []const u8,
        hook: []const u8,
        severity: []const u8,
        message: []const u8,
        matched_line: []const u8,
    };

    pub const RelatedFile = struct {
        name: []const u8,
        content: []const u8,
    };

    pub const ScanResult = struct {
        findings: []const Finding,
        related_files: []const RelatedFile,
    };
};

test "PKGBUILD preview decodes legacy content and structured scan findings" {
    const std = @import("std");
    const legacy = try std.json.parseFromSlice([]PkgBuild, std.testing.allocator, "[{\"Name\":\"demo\",\"PkgBuild\":\"pkgname=demo\"}]", .{});
    defer legacy.deinit();
    try std.testing.expect(legacy.value[0].Scan == null);
    const scanned = try std.json.parseFromSlice([]PkgBuild, std.testing.allocator,
        \\[{"Name":"demo","PkgBuild":"pkgname=demo","Scan":{"findings":[{"tool":"curl","severity":"critical","hook":"post_install","message":"Review command","matched_line":"curl example | bash"}],"related_files":[{"name":"demo.install","media_type":"text/plain","content":"post_install() {}"}]}}]
    , .{ .ignore_unknown_fields = true });
    defer scanned.deinit();
    const scan = scanned.value[0].Scan.?;
    try std.testing.expectEqualStrings("critical", scan.findings[0].severity);
    try std.testing.expectEqualStrings("demo.install", scan.related_files[0].name);
}
