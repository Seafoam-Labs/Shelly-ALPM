const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("ShellyHttp", .{
        .root_source_file = b.path("http_client.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = module });
    const test_step = b.step("test", "Run compatibility HTTP client tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
