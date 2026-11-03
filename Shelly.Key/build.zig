const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const path_profile = b.option([]const u8, "path-profile", "Distribution path defaults: pacman or devario") orelse "pacman";
    const paths = b.dependency("shelly_paths", .{ .target = target, .optimize = optimize, .@"path-profile" = path_profile }).module("paths");
    const diagnostics = b.dependency("shelly_diagnostics", .{ .target = target, .optimize = optimize }).module("diagnostics");

    const mod = b.addModule("Shelly_Key", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addImport("diagnostics", diagnostics);
    mod.addImport("paths", paths);

    const exe = b.addExecutable(.{
        .name = "shelly-key",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Shelly_Key", .module = mod },
            },
        }),
    });
    exe.root_module.addImport("diagnostics", diagnostics);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
