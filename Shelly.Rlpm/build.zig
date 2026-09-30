const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shelly_key = b.dependency("shelly_key", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("Shelly_Rlpm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const action_protocol = b.addModule("Shelly_Rlpm_Action_Protocol", .{
        .root_source_file = b.path("src/actions/protocol.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("action_protocol", action_protocol);
    const action_worker = b.addModule("Shelly_Rlpm_Action_Worker", .{
        .root_source_file = b.path("src/actions/worker.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    action_worker.addImport("action_protocol", action_protocol);
    const download = b.dependency("shelly_download", .{ .target = target, .optimize = optimize });
    const workers = b.addModule("Shelly_Rlpm_Workers", .{
        .root_source_file = b.path("src/workers.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "download_worker", .module = download.module("Shelly_Download_Worker") },
            .{ .name = "action_worker", .module = action_worker },
        },
    });
    mod.addImport("workers", workers);
    mod.addImport("Shelly_Download", download.module("Shelly_Download"));
    // Only test consumers request this artifact; it is never installed.
    const worker_fixture = b.addExecutable(.{
        .name = "rlpm-worker-fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/worker_fixture.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "workers", .module = workers }},
        }),
    });
    const worker_fixture_options = b.addOptions();
    b.addNamedLazyPath("worker_fixture", worker_fixture.getEmittedBin());
    worker_fixture_options.addOptionPath("path", worker_fixture.getEmittedBin());
    mod.addImport("Shelly_Key", shelly_key.module("Shelly_Key"));
    mod.linkSystemLibrary("archive", .{});
    mod.linkSystemLibrary("sqlite3", .{});
    mod.addCSourceFile(.{ .file = b.path("src/native/regex.c"), .flags = &.{"-std=c11"} });
    mod.addCSourceFile(.{ .file = b.path("src/native/publication.c"), .flags = &.{"-std=c11"} });
    mod.addCSourceFile(.{ .file = b.path("src/native/lock.c"), .flags = &.{"-std=c11"} });

    const exe = b.addExecutable(.{
        .name = "Shelly_Rlpm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Read local metadata (arguments: ROOT DBPATH)").dependOn(&run.step);

    const unit = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run hermetic tests, public API checks, and reference ledger validation");
    test_step.dependOn(&b.addRunArtifact(unit).step);
    // Compile the real read-only example too, rather than an empty test runner.
    test_step.dependOn(&exe.step);

    const self_execution = b.addExecutable(.{
        .name = "rlpm-self-execution-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/self_execution.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
        }),
    });
    const run_self_execution = b.addRunArtifact(self_execution);
    test_step.dependOn(&run_self_execution.step);
    b.step("test-self-execution", "Exercise actions after replacing the embedding executable").dependOn(&run_self_execution.step);

    const public_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/public_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    public_tests.root_module.addOptions("worker_fixture", worker_fixture_options);
    const run_public = b.addRunArtifact(public_tests);
    public_tests.root_module.addCSourceFile(
        .{
            .file = b.path("src/tests/lock_process.c"),
            .flags = &.{"-std=c11"},
        },
    );
    test_step.dependOn(&run_public.step);
    b.step("test-public-api", "Exercise the exported API from a separate importing module").dependOn(
        &run_public.step,
    );

    const metadata_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/metadata.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    b.step("test-metadata", "Run metadata, archive, relation and reference fixtures").dependOn(
        &b.addRunArtifact(metadata_tests).step,
    );

    const database_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/database.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    b.step("test-database", "Run local, tar/SQLite, query, reload and allocation fixtures").dependOn(
        &b.addRunArtifact(database_tests).step,
    );

    const verification_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/verification.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    b.step("test-verification", "Run integrity, trust, status, import and immutable-file fixtures").dependOn(
        &b.addRunArtifact(verification_tests).step,
    );

    const resolver_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/resolver.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    b.step("test-resolver", "Run resolution, removal, system-upgrade and reference fixtures").dependOn(
        &b.addRunArtifact(resolver_tests).step,
    );

    const executor_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/executor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    executor_tests.root_module.addOptions("worker_fixture", worker_fixture_options);
    const run_executor_tests = b.addRunArtifact(executor_tests);
    b.step("test-executor", "Run disposable-root payload and database transactions").dependOn(
        &run_executor_tests.step,
    );
    test_step.dependOn(&run_executor_tests.step);
    const hook_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/hooks.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    hook_tests.root_module.addOptions("worker_fixture", worker_fixture_options);
    b.step("test-hooks", "Run hermetic hook parser, discovery, matching and ownership fixtures").dependOn(
        &b.addRunArtifact(hook_tests).step,
    );
    const preflight_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/preflight.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    b.step("test-preflight", "Run private-root archive, conflict, backup and space fixtures").dependOn(
        &b.addRunArtifact(preflight_tests).step,
    );
    const sandbox_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/download_sandbox.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    sandbox_tests.root_module.addOptions("worker_fixture", worker_fixture_options);
    const sandbox_run = b.addRunArtifact(sandbox_tests);
    sandbox_run.has_side_effects = true;
    b.step("test-download-sandbox", "Opt-in root-only sandbox integration, private /tmp roots").dependOn(
        &sandbox_run.step,
    );
    b.step("check-download-sandbox", "Compile the root-only integration fixture").dependOn(
        &sandbox_tests.step,
    );
    const download_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/download.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    b.step("test-download", "Run private-cache, acquisition, refresh and DOWNLOADONLY fixtures").dependOn(
        &b.addRunArtifact(download_tests).step,
    );
    const transaction_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/transaction.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    transaction_tests.root_module.addCSourceFile(
        .{
            .file = b.path("src/tests/lock_process.c"),
            .flags = &.{"-std=c11"},
        },
    );
    b.step(
        "test-transaction",
        "Run private-root lifecycle, lock, ownership, cancellation and reference fixtures",
    ).dependOn(
        &b.addRunArtifact(transaction_tests).step,
    );

    const ledger_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/compatibility.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_ledger = b.addRunArtifact(ledger_tests);
    test_step.dependOn(&run_ledger.step);
    b.step(
        "test-compatibility",
        "Validate the pinned API inventory and coverage ledger (not full behavioral parity)",
    ).dependOn(
        &run_ledger.step,
    );

    const version_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/structs/Version.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test-version", "Run hermetic version tests").dependOn(&b.addRunArtifact(version_tests).step);

    const package_mod = b.createModule(.{
        .root_source_file = b.path("src/structs/Package.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    package_mod.linkSystemLibrary("archive", .{});
    const package_tests = b.addTest(.{ .root_module = package_mod });
    b.step("test-package", "Run hermetic package archive tests").dependOn(
        &b.addRunArtifact(package_tests).step,
    );

    // Native integrations are opt-in and always rerun. Their output includes
    // subprocess diagnostics/previews, which require the terminal test runner.
    const terminal_runner: std.Build.Step.Compile.TestRunner = .{
        .path = .{
            .cwd_relative = b.pathJoin(
                &.{
                    b.graph.zig_lib_directory.path.?,
                    "compiler/test_runner.zig",
                },
            ),
        },
        .mode = .simple,
    };
    const payload_benchmark = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/payload_benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }), .test_runner = terminal_runner });
    payload_benchmark.root_module.addOptions("worker_fixture", worker_fixture_options);
    const run_payload_benchmark = b.addRunArtifact(payload_benchmark);
    run_payload_benchmark.stdio = .inherit;
    run_payload_benchmark.has_side_effects = true;
    b.step(
        "bench-payload",
        "Compare payload durability policies in disposable roots (RLPM_PAYLOAD_BENCH_* settings)",
    ).dependOn(
        &run_payload_benchmark.step,
    );
    const executor_driver = b.addExecutable(.{ .name = "rlpm-executor-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/executor_driver.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    const interop = b.addSystemCommand(&.{ "unshare", "--user", "--map-root-user", "--mount", "python3" });
    interop.addFileArg(b.path("src/tests/reference/check_executor_interop.py"));
    interop.addArg("--driver");
    interop.addArtifactArg(executor_driver);
    interop.stdio = .inherit;
    interop.has_side_effects = true;
    b.step(
        "test-executor-interop",
        "Alternate RLPM and pinned native libalpm against private databases",
    ).dependOn(
        &interop.step,
    );
    const executor_integration = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/executor_integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }), .test_runner = terminal_runner });
    executor_integration.root_module.addOptions("worker_fixture", worker_fixture_options);
    const run_executor = b.addSystemCommand(&.{ "unshare", "--user", "--map-root-user", "--mount" });
    run_executor.addArtifactArg(executor_integration);
    run_executor.stdio = .inherit;
    run_executor.has_side_effects = true;
    b.step(
        "test-executor-integration",
        "Run full executor processes and attributes in disposable roots",
    ).dependOn(
        &run_executor.step,
    );
    const action_filter = b.addExecutable(.{ .name = "rlpm-action-filter-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/action_filter.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    action_filter.root_module.addOptions("worker_fixture", worker_fixture_options);
    action_filter.root_module.addImport("workers", workers);
    const action_probe = b.addExecutable(.{ .name = "rlpm-action-probe-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/action_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const action_fixture_options = b.addOptions();
    action_fixture_options.addOptionPath("filter", action_filter.getEmittedBin());
    action_fixture_options.addOptionPath("probe", action_probe.getEmittedBin());
    const action_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/actions.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }), .test_runner = terminal_runner });
    action_tests.root_module.addOptions("worker_fixture", worker_fixture_options);
    action_tests.root_module.addOptions("action_fixtures", action_fixture_options);
    const run_actions = b.addSystemCommand(
        &.{
            "unshare",
            "--user",
            "--map-root-user",
            "--mount",
            "env",
            "BASH_ENV=/injected-startup",
            "SHLVL=7",
        },
    );
    run_actions.addArtifactArg(action_tests);
    run_actions.stdio = .inherit;
    run_actions.has_side_effects = true;
    b.step("test-actions", "Run real actions in disposable chroots under a user namespace").dependOn(
        &run_actions.step,
    );
    b.step("check-actions", "Compile action integration tests without executing them").dependOn(
        &action_tests.step,
    );
    const signature_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/signature.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
        }),
        .test_runner = terminal_runner,
    });
    const run_signature = b.addRunArtifact(signature_tests);
    run_signature.stdio = .inherit;
    run_signature.has_side_effects = true;
    b.step("test-signature", "Run real GPG integration; unavailable tools/agent are failures").dependOn(
        &run_signature.step,
    );

    const host_mod = b.createModule(.{
        .root_source_file = b.path("src/host_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "Shelly_Key", .module = shelly_key.module("Shelly_Key") }},
    });
    host_mod.addCSourceFile(.{ .file = b.path("src/native/publication.c"), .flags = &.{"-std=c11"} });
    host_mod.linkSystemLibrary("archive", .{});
    host_mod.linkSystemLibrary("sqlite3", .{});
    const host_tests = b.addTest(.{
        .root_module = host_mod,
        .filters = &.{"host-readonly:"},
        .test_runner = terminal_runner,
    });
    const run_host = b.addRunArtifact(host_tests);
    run_host.stdio = .inherit;
    run_host.has_side_effects = true;
    b.step("test-host-readonly", "Opt in to reading /var/lib/pacman; never a release parity gate").dependOn(
        &run_host.step,
    );
}
