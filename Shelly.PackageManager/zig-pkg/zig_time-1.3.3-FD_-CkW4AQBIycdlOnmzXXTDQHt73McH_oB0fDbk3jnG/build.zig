const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const mod = b.addModule("zig-time", .{
        .root_source_file = b.path("src/time.zig"),
        .target = target,
    });

    // -Dtest-filter="..."
    const test_filter = b.option([]const []const u8, "test-filter", "Filter for tests to run");

    // zig build unit_test
    const unit_tests = b.addTest(.{
        .root_module = mod,
    });
    if (test_filter) |t| unit_tests.filters = t;

    // zig build [install]
    b.installArtifact(unit_tests);

    // zig build -Dtest-filter="..." test
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_test_step = b.step("test", "Run unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);
}
