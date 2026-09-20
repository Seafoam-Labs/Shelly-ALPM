const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.addModule("diagnostics", .{
        .root_source_file = b.path("src/errors.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Test contextual error messages and diagnostic sanitization")
        .dependOn(&b.addRunArtifact(tests).step);
}
