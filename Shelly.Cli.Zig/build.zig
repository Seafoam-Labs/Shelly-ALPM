const std = @import("std");
const package_manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const flatpak_backend_path = b.option(
        []const u8,
        "flatpak-backend-path",
        "Absolute path to the Shelly Flatpak backend shared library",
    ) orelse "/usr/lib/shelly/libshelly-flatpak-backend.so.1";

    const zigalpm_dependency = b.dependency("zigalpm", .{
        .target = target,
        .optimize = optimize,
        .@"flatpak-backend-path" = flatpak_backend_path,
    });
    const zigalpm = zigalpm_dependency.module("Zigalpm");

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", package_manifest.version);

    const cli = b.addModule("Shelly_Cli_Zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli.addImport("Zigalpm", zigalpm);
    cli.addOptions("build_options", build_options);

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

    const builder_test_module = b.createModule(.{
        .root_source_file = b.path("src/builder_command_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    builder_test_module.addImport("Zigalpm", zigalpm);
    builder_test_module.addOptions("build_options", build_options);
    const builder_tests = b.addTest(.{
        .name = "builder-command-test",
        .root_module = builder_test_module,
        .filters = &.{
            "makesrcinfo emits clean stdout and never runs lifecycle functions",
            "isolated source key",
            "isolated source public keys",
            "isolated child arguments",
        },
    });
    const run_builder_tests = b.addRunArtifact(builder_tests);
    test_step.dependOn(&run_builder_tests.step);
    const source_key_test_step = b.step("isolated-source-keys-test", "Test isolated source key approval, transport, and signature verification");
    source_key_test_step.dependOn(&run_builder_tests.step);

    const isolated_test_module = b.createModule(.{
        .root_source_file = b.path("src/commands/isolated_build.zig"),
        .target = target,
        .optimize = optimize,
    });
    isolated_test_module.addImport("Zigalpm", zigalpm);
    const isolated_tests = b.addTest(.{
        .name = "isolated-build-test",
        .root_module = isolated_test_module,
        .filters = &.{
            "reviewed input paths cannot escape the staged source root",
            "reviewed inputs are materialized with exact bytes and permissions",
            "staged reviewed inputs preserve the host digest and reject real changes",
            "isolated public source key bundle is readable under restrictive umasks",
        },
    });
    const isolated_test_step = b.step("isolated-build-test", "Test reviewed staging and integrity under restrictive umasks");
    for ([_][]const u8{ "0022", "0007", "0077" }) |mask| {
        // Each runner inherits its own umask; never mutate it in concurrent Zig tests.
        const run_isolated_tests = b.addSystemCommand(&.{
            "bash", "-c", "umask \"$1\"; exec \"$2\"", "isolated-build-test", mask,
        });
        run_isolated_tests.addArtifactArg(isolated_tests);
        run_isolated_tests.has_side_effects = true;
        isolated_test_step.dependOn(&run_isolated_tests.step);
    }
    test_step.dependOn(isolated_test_step);
    source_key_test_step.dependOn(isolated_test_step);

    const native_check_step = b.step("native-check", "Build and test the self-contained native Zig CLI");
    native_check_step.dependOn(b.getInstallStep());
    native_check_step.dependOn(&run_module_tests.step);
    native_check_step.dependOn(&run_executable_tests.step);
}
