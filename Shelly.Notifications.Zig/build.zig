const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native_translation = b.addTranslateC(.{
        .root_source_file = b.path("src/native_bindings.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const native_bindings = native_translation.createModule();

    const diagnostics = b.dependency("shelly_diagnostics", .{ .target = target, .optimize = optimize }).module("diagnostics");

    const zsn_dep = b.dependency("conch", .{
        .target = target,
        .optimize = optimize,
    });
    const zsn_mod = zsn_dep.module("conch");

    const zeit_dep = b.dependency("zeit", .{ .target = target, .optimize = optimize });
    const zeit_mod = zeit_dep.module("zeit");

    const exe = b.addExecutable(.{
        .name = "shelly-notifications",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsn", .module = zsn_mod },
                .{ .name = "zeit", .module = zeit_mod },
            },
        }),
    });
    exe.root_module.addImport("gettext_c", native_bindings);
    exe.root_module.addImport("diagnostics", diagnostics);
    b.installArtifact(exe);
    exe.root_module.link_libc = true;

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
