const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("Shelly_Download", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "ShellyHttp", .module = b.dependency("shelly_http", .{ .target = target, .optimize = optimize }).module("ShellyHttp") },
            .{ .name = "diagnostics", .module = b.dependency("shelly_diagnostics", .{ .target = target, .optimize = optimize }).module("diagnostics") },
        },
    });
    mod.linkSystemLibrary("curl", .{});
    _ = b.addModule("Shelly_Download_Worker", .{
        .root_source_file = b.path("src/worker.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "Shelly_Download", .module = mod }},
    });
    b.step("test", "Test shared transport and bounded download queue").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    const sandbox = b.createModule(.{ .root_source_file = b.path("src/Sandbox.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const fixture = b.addExecutable(.{ .name = "download-sandbox-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sandbox_fixture.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "Sandbox", .module = sandbox }},
    }) });
    const options = b.addOptions();
    options.addOptionPath("path", fixture.getEmittedBin());
    const sandbox_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests/sandbox.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    sandbox_tests.root_module.addOptions("sandbox_fixture", options);
    const run_sandbox = b.addRunArtifact(sandbox_tests);
    run_sandbox.has_side_effects = true;
    b.step("test-sandbox", "Test native Landlock/seccomp in disposable children; requires kernel support, no root").dependOn(&run_sandbox.step);
    b.step("check-sandbox", "Compile the isolated sandbox integration fixture").dependOn(&sandbox_tests.step);
}
