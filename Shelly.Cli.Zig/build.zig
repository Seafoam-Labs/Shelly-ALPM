const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigalpm_dependency = b.dependency("zigalpm", .{
        .target = target,
        .optimize = optimize,
    });
    const zigalpm = zigalpm_dependency.module("Zigalpm");

    const cli = b.addModule("Shelly_Cli_Zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli.addImport("Zigalpm", zigalpm);

    const executable_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    executable_module.addImport("Shelly_Cli_Zig", cli);
    executable_module.addImport("Zigalpm", zigalpm);

    const executable = b.addExecutable(.{
        .name = "shelly",
        .root_module = executable_module,
    });
    b.installArtifact(executable);

    const run_command = b.addRunArtifact(executable);
    run_command.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_command.addArgs(args);

    const run_step = b.step("run", "Run Shelly");
    run_step.dependOn(&run_command.step);

    const module_tests = b.addTest(.{
        .root_module = cli,
    });
    const run_module_tests = b.addRunArtifact(module_tests);

    const executable_tests = b.addTest(.{
        .root_module = executable_module,
    });
    const run_executable_tests = b.addRunArtifact(executable_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_executable_tests.step);

    const native_check_step = b.step("native-check", "Build and test the self-contained native Zig CLI");
    native_check_step.dependOn(b.getInstallStep());
    native_check_step.dependOn(&run_module_tests.step);
    native_check_step.dependOn(&run_executable_tests.step);
}
