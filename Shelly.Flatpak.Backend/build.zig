const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const protocol = b.addModule("Shelly_Flatpak_Protocol", .{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    const generated_flatpak = b.createModule(.{
        .root_source_file = b.path("src/flatpak/flatpak.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const operation_context = b.createModule(.{
        .root_source_file = b.path("src/operation_context.zig"),
        .target = target,
        .optimize = optimize,
    });
    const backend_module = b.createModule(.{
        .root_source_file = b.path("src/exports.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    backend_module.addImport("flatpak", generated_flatpak);
    backend_module.addImport("operation_context", operation_context);
    backend_module.addImport("Shelly_Flatpak_Protocol", protocol);
    backend_module.linkSystemLibrary("flatpak", .{
        .use_pkg_config = .force,
    });

    const backend = b.addLibrary(.{
        .name = "shelly-flatpak-backend",
        .linkage = .dynamic,
        .root_module = backend_module,
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
    });
    b.installArtifact(backend);

    const protocol_tests = b.addTest(.{
        .name = "flatpak-protocol-test",
        .root_module = protocol,
    });
    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    const test_step = b.step("test", "Run backend protocol tests");
    test_step.dependOn(&run_protocol_tests.step);

    const fake_backend_module = b.createModule(.{
        .root_source_file = b.path("src/testing/fake_backend.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fake_backend_module.addImport("Shelly_Flatpak_Protocol", protocol);
    const fake_backend = b.addLibrary(.{
        .name = "shelly-flatpak-backend-fake",
        .linkage = .dynamic,
        .root_module = fake_backend_module,
    });

    const missing_backend = b.addLibrary(.{
        .name = "shelly-flatpak-backend-missing-entry",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/missing_backend.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const incompatible_backend_module = b.createModule(.{
        .root_source_file = b.path("src/testing/incompatible_backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    incompatible_backend_module.addImport("Shelly_Flatpak_Protocol", protocol);
    const incompatible_backend = b.addLibrary(.{
        .name = "shelly-flatpak-backend-incompatible",
        .linkage = .dynamic,
        .root_module = incompatible_backend_module,
    });

    const short_backend_module = b.createModule(.{
        .root_source_file = b.path("src/testing/short_backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    short_backend_module.addImport("Shelly_Flatpak_Protocol", protocol);
    const short_backend = b.addLibrary(.{
        .name = "shelly-flatpak-backend-short",
        .linkage = .dynamic,
        .root_module = short_backend_module,
    });

    const null_backend_module = b.createModule(.{
        .root_source_file = b.path("src/testing/null_backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    null_backend_module.addImport("Shelly_Flatpak_Protocol", protocol);
    const null_backend = b.addLibrary(.{
        .name = "shelly-flatpak-backend-null",
        .linkage = .dynamic,
        .root_module = null_backend_module,
    });

    const abi_test_options = b.addOptions();
    abi_test_options.addOptionPath("real_backend_path", backend.getEmittedBin());
    abi_test_options.addOptionPath("fake_backend_path", fake_backend.getEmittedBin());
    abi_test_options.addOptionPath("missing_backend_path", missing_backend.getEmittedBin());
    abi_test_options.addOptionPath(
        "incompatible_backend_path",
        incompatible_backend.getEmittedBin(),
    );
    abi_test_options.addOptionPath("short_backend_path", short_backend.getEmittedBin());
    abi_test_options.addOptionPath("null_backend_path", null_backend.getEmittedBin());

    const abi_test_module = b.createModule(.{
        .root_source_file = b.path("src/testing/abi_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_test_module.addImport("Shelly_Flatpak_Protocol", protocol);
    abi_test_module.addOptions("abi_test_options", abi_test_options);
    const abi_tests = b.addTest(.{
        .name = "flatpak-abi-test",
        .root_module = abi_test_module,
    });
    const run_abi_tests = b.addRunArtifact(abi_tests);

    const abi_step = b.step("abi-test", "Run versioned backend ABI tests");
    abi_step.dependOn(&run_abi_tests.step);

    const parity_tests = b.addTest(.{
        .name = "flatpak-backend-parity-test",
        .root_module = backend_module,
        .filters = &.{
            "installed Flatpak resolution matches IDs and friendly names",
            "Flatpak manager exposes strict-parity operations",
            "shared cancellation propagates to GLib cancellables",
            "cancellation unsubscribe drain protects borrowed callback state",
            "Flatpak dispatcher forwards typed status and progress",
            "native Flatpak remote manager exposes backend parity operations",
            "native Flatpak AppStream manager exposes backend parity operations",
        },
    });
    const run_parity_tests = b.addRunArtifact(parity_tests);
    const parity_step = b.step(
        "parity-test",
        "Run safe native Flatpak implementation parity tests",
    );
    parity_step.dependOn(&run_parity_tests.step);

    const live_tests = b.addTest(.{
        .name = "flatpak-backend-live-test",
        .root_module = backend_module,
        .filters = &.{
            "test installFlatpak",
            "test listFlatpak",
            "test laucnhFlatpak",
            "test searchremoteref",
            "test getAllFlatpaksFromRemotes",
            "test getRemoteRefInfo",
        },
    });
    const run_live_tests = b.addRunArtifact(live_tests);
    const live_step = b.step(
        "live-test",
        "Run opt-in tests against the current user's live Flatpak state",
    );
    live_step.dependOn(&run_live_tests.step);

    const integration_step = b.step(
        "integration-test",
        "Run safe backend protocol and ABI tests",
    );
    integration_step.dependOn(&run_protocol_tests.step);
    integration_step.dependOn(&run_abi_tests.step);
    integration_step.dependOn(&run_parity_tests.step);
}
