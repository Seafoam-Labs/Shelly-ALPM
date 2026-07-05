const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("goose", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "goose-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "goose", .module = mod },
            },
        }),
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("test-app", "Run the test app");
    run_step.dependOn(&run_cmd.step);

    const server_exe = b.addExecutable(.{
        .name = "goose-server-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/server_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "goose", .module = mod },
            },
        }),
    });

    const run_server = b.addRunArtifact(server_exe);
    if (b.args) |args| {
        run_server.addArgs(args);
    }
    const server_step = b.step("test-server", "Run the server test app");
    server_step.dependOn(&run_server.step);

    const client_exe = b.addExecutable(.{
        .name = "goose-client-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/client_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "goose", .module = mod },
            },
        }),
    });

    const run_client = b.addRunArtifact(client_exe);
    if (b.args) |args| {
        run_client.addArgs(args);
    }
    const client_step = b.step("test-client", "Run the client test app");
    client_step.dependOn(&run_client.step);

    const intro_exe = b.addExecutable(.{
        .name = "goose-introspection",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/introspector.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "goose", .module = mod },
            },
        }),
    });
    b.installArtifact(intro_exe);
    const run_intro = b.addRunArtifact(intro_exe);
    if (b.args) |args| {
        run_intro.addArgs(args);
    }
    const intro_step = b.step("introspection", "Run the introspection demo");
    intro_step.dependOn(&run_intro.step);

    const gen_exe = b.addExecutable(.{
        .name = "goose-generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/generate_proxy.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "goose", .module = mod },
            },
        }),
    });
    b.installArtifact(gen_exe);

    const run_gen = b.addRunArtifact(gen_exe);
    if (b.args) |args| {
        run_gen.addArgs(args);
    }
    const gen_step = b.step("generate", "Generate Zig proxy from D-Bus introspection");
    gen_step.dependOn(&run_gen.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
}
