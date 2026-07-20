const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // libflatpak is exposed via a committed, statically generated binding
    // (`src/flatpak/flatpak.zig`) rather than a build-time translate-c step.
    // Zig 0.16's arocc-based translate-c cannot yet handle GLib/GObject headers
    // (the `_Pragma`/`__builtin_constant_p` macros), so `flatpak.zig` was
    // generated once and checked in. See `src/flatpak/flatpak_include.h` for the
    // regeneration command and `flatpak.zig`'s header for the manual fixups.
    // Actual linking of the system library happens on the consuming module below.
    const flatpak_mod = b.createModule(.{
        .root_source_file = b.path("src/flatpak/flatpak.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // libalpm is exposed via a committed, statically generated binding
    // (`src/alpm/alpm.zig`), same approach as flatpak. Regenerate from the
    // src/alpm directory with:
    //   zig translate-c -lc $(pkg-config --cflags libalpm) alpm_include.h > alpm.zig
    // Actual linking of the system library happens on the consuming module below.
    const alpm_c = b.createModule(.{
        .root_source_file = b.path("src/alpm/alpm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const operation_context_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/operation_context.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("Zigalpm", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("alpm_c", alpm_c);
    mod.addImport("operation_context", operation_context_mod);
    mod.linkSystemLibrary("alpm", .{});
    mod.addImport("flatpak", flatpak_mod);
    mod.linkSystemLibrary("flatpak", .{});
    mod.linkSystemLibrary("archive", .{});

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "Zigalpm",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "Zigalpm" is the name you will use in your source code to
                // import this module (e.g. `@import("Zigalpm")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "Zigalpm", .module = mod },
            },
        }),
    });

    const zig_time_dep = b.dependency("zig-time", .{});
    exe.root_module.addImport("zig-time", zig_time_dep.module("zig-time"));
    mod.addImport("zig-time", zig_time_dep.module("zig-time"));

    const goose_dep = b.dependency("goose", .{});
    exe.root_module.addImport("goose", goose_dep.module("goose"));

    const xml_dep = b.dependency("zig-xml", .{});
    exe.root_module.addImport("zig-xml", xml_dep.module("xml"));
    mod.addImport("zig-xml", xml_dep.module("xml"));

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);
    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Local package tests are isolated from the package manager's live-system
    // integration tests and use only temporary configured roots.
    const local_test_module = b.createModule(.{
        .root_source_file = b.path("src/local/manager.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    local_test_module.addImport("operation_context", operation_context_mod);
    local_test_module.linkSystemLibrary("archive", .{});
    const local_tests = b.addTest(.{ .root_module = local_test_module });
    const run_local_tests = b.addRunArtifact(local_tests);
    const local_test_step = b.step("local-test", "Run safe local package tests");
    local_test_step.dependOn(&run_local_tests.step);

    const operation_tests = b.addTest(.{
        .name = "operation-test",
        .root_module = mod,
        .filters = &.{
            "operation context emits correlated parent and child events",
            "operation context supports immediate and deferred question responses",
            "structured reviews preserve findings and default to rejection without a handler",
            "cancellation notifies adapters and cancels operations",
            "subscription identifiers remain stable after removals",
        },
    });
    const run_operation_tests = b.addRunArtifact(operation_tests);
    const adapter_tests = b.addTest(.{
        .name = "operation-adapter-test",
        .root_module = mod,
        .filters = &.{
            "backend dispatchers share one operation event stream",
            "ALPM and AUR questions use the shared response hook",
        },
    });
    const run_adapter_tests = b.addRunArtifact(adapter_tests);
    const operation_test_step = b.step("operation-test", "Run shared operation context and backend-adapter tests");
    operation_test_step.dependOn(&run_operation_tests.step);
    operation_test_step.dependOn(&run_adapter_tests.step);

    const pkgbuild_review_tests = b.addTest(.{
        .name = "pkgbuild-review-test",
        .root_module = mod,
        .filters = &.{
            "PKGBUILD validation combines post-install and homograph findings",
            "review digest covers exact local source contents and missing sources fail closed",
            "fixture checkout cannot invoke fake makepkg before review and integrity gates pass",
            "embedded whitespace does not bypass homograph analysis",
            "risky tool in local_source_contents produces finding",
        },
    });
    const run_pkgbuild_review_tests = b.addRunArtifact(pkgbuild_review_tests);
    const pkgbuild_review_test_step = b.step(
        "pkgbuild-review-test",
        "Run fail-closed PKGBUILD analysis and reviewed-input tests",
    );
    pkgbuild_review_test_step.dependOn(&run_pkgbuild_review_tests.step);

    const downloader_test_module = b.createModule(.{
        .root_source_file = b.path("src/shared/downloader.zig"),
        .target = target,
        .optimize = optimize,
    });
    downloader_test_module.addImport("operation_context", operation_context_mod);
    const downloader_tests = b.addTest(.{ .name = "downloader-test", .root_module = downloader_test_module });
    const run_downloader_tests = b.addRunArtifact(downloader_tests);
    const downloader_test_step = b.step("downloader-test", "Run safe downloader and cancellation tests");
    downloader_test_step.dependOn(&run_downloader_tests.step);

    const cache_test_module = b.createModule(.{
        .root_source_file = b.path("src/alpm/cache_manager.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cache_test_module.addImport("alpm_c", alpm_c);
    cache_test_module.addImport("operation_context", operation_context_mod);
    cache_test_module.linkSystemLibrary("alpm", .{});
    const cache_tests = b.addTest(.{ .name = "cache-test", .root_module = cache_test_module });
    const run_cache_tests = b.addRunArtifact(cache_tests);
    const cache_test_step = b.step("cache-test", "Run safe package-cache tests");
    cache_test_step.dependOn(&run_cache_tests.step);

    const archive_tests = b.addTest(.{
        .name = "archive-test",
        .root_module = mod,
        .filters = &.{
            "archive endpoints include Arch and selected CachyOS variants",
            "archive listing parses package filenames",
            "local cache lookup returns owned matching candidates",
            "target resolution accepts exact version-release or filename",
            "prepare_candidate retains local cache files",
            "archive installation API delegates through the ALPM manager",
            "archive downloads honor shared cancellation",
        },
    });
    const run_archive_tests = b.addRunArtifact(archive_tests);
    const archive_test_step = b.step("archive-test", "Run safe ALPM downgrade archive tests");
    archive_test_step.dependOn(&run_archive_tests.step);

    const alpm_query_tests = b.addTest(.{
        .name = "alpm-query-test",
        .root_module = mod,
        .filters = &.{
            "public ALPM query helpers expose typed results",
            "compare_package_versions uses libalpm ordering",
            "dependencyName strips constraints",
            "is_cachyos exposes the detected manager state",
            "get_required_packages returns NoHandle when the handle is null",
            "get_required_packages rejects empty package and database names",
            "get_required_packages returns owned local reverse dependencies",
            "get_required_packages returns an empty result for an unknown package",
            "get_required_packages rejects an unknown sync database",
            "get_required_packages resolves a named sync database",
            "fetchCallback accepts prepared cache entries and rejects missing artifacts",
            "parses repositories, servers, siglevel and usage",
            "hold package mutations rewrite HoldPkg and preserve shelly",
            "Manager hold APIs mutate HoldPkg while retaining shelly",
            "dependency query APIs resolve exact, versioned, and virtual remote packages",
            "install_packages predownloads prepared repository packages before commit",
            "install_local_packages installs multiple archives in a DB-only transaction",
            "Manager.init applies configured libalpm options and callback contexts",
            "ALPM queries honor shared cancellation",
            "single-server repositories receive a thirty second setup timeout",
            "zero-server and multi-mirror repositories retain fast failover",
        },
    });
    const run_alpm_query_tests = b.addRunArtifact(alpm_query_tests);
    const alpm_query_test_step = b.step("alpm-query-test", "Run safe ALPM configuration and query API tests");
    alpm_query_test_step.dependOn(&run_alpm_query_tests.step);

    const required_packages_tests = b.addTest(.{
        .name = "required-packages-test",
        .root_module = mod,
        .filters = &.{"get_required_packages"},
    });
    const run_required_packages_tests = b.addRunArtifact(required_packages_tests);
    const required_packages_test_step = b.step(
        "required-packages-test",
        "Run isolated ALPM reverse-dependency query tests",
    );
    required_packages_test_step.dependOn(&run_required_packages_tests.step);

    const alpm_sync_tests = b.addTest(.{
        .name = "alpm-sync-test",
        .root_module = mod,
        .filters = &.{
            "database signature downloads are reserved for required signatures",
            "Manager.sync downloads the configured database into DBPath/sync",
            "Manager.sync exposes cancellable logical database downloads during mirror failover",
        },
    });
    const run_alpm_sync_tests = b.addRunArtifact(alpm_sync_tests);
    const alpm_sync_test_step = b.step("alpm-sync-test", "Run the isolated ALPM database sync test");
    alpm_sync_test_step.dependOn(&run_alpm_sync_tests.step);

    const restart_tests = b.addTest(.{
        .name = "restart-test",
        .root_module = mod,
        .filters = &.{
            "restart parsing identifies deleted shared libraries and system services",
            "restart report detects kernels and records structured service results",
        },
    });
    const run_restart_tests = b.addRunArtifact(restart_tests);
    const restart_test_step = b.step("restart-test", "Run safe post-upgrade restart detection tests");
    restart_test_step.dependOn(&run_restart_tests.step);

    const flatpak_tests = b.addTest(.{
        .name = "flatpak-test",
        .root_module = mod,
        .filters = &.{
            "Flatpak dispatcher forwards typed status and progress",
            "parseStream parses a full component with description, icons, screenshots, releases, urls and verification",
            "parseComponent falls back to <developer><name> when developer_name is absent",
            "streaming parser skips localized payloads and associates addons by id",
            "parseFile reads gzip-compressed AppStream catalogs",
            "AppStream manager returns an owned typed catalog",
            "installed Flatpak resolution matches IDs and friendly names",
            "Flatpak manager exposes strict-parity operations",
            "shared cancellation propagates to GLib cancellables",
            "AppStream manager exposes one and all remote catalog retrieval",
            "Flatpak remote operations honor shared cancellation",
            "Flatpak remote operation-hooked public APIs compile",
            "Flatpak AppStream operations honor shared cancellation",
            "Flatpak AppStream operation-hooked public APIs compile",
        },
    });
    const run_flatpak_tests = b.addRunArtifact(flatpak_tests);
    const flatpak_test_step = b.step("flatpak-test", "Run safe Flatpak parity tests");
    flatpak_test_step.dependOn(&run_flatpak_tests.step);

    const aur_tests = b.addTest(.{
        .name = "aur-test",
        .root_module = mod,
        .filters = &.{
            "AUR dispatcher forwards package stages and build progress",
            "AUR dispatcher returns provider selections",
            "AUR handlers can be removed through the manager-facing dispatcher",
            "AUR RPC URL and form encoding matches the C# requests",
            "AUR suggestions are returned as owned strings",
            "partial info failures preserve packages returned by earlier chunks",
            "PKGBUILD validation combines post-install and homograph findings",
            "installed AUR metadata uses local version and install reason",
            "AUR update projection compares remote and installed versions",
            "AUR git remote and VCS suffix parsing mirror the C# manager",
            "helper cache identity recognizes installed split-package members",
            "all requested PKGBUILDs are reviewed before the first build",
            "AUR operation-hooked public APIs compile",
            "build progress parser recognizes makepkg percentage lines",
            "streaming process execution forwards stdout stderr and a final unterminated line",
            "streaming process execution delivers output before the child exits",
            "streaming process execution terminates when the shared operation is cancelled",
        },
    });
    const run_aur_tests = b.addRunArtifact(aur_tests);
    const aur_test_step = b.step("aur-test", "Run safe AUR manager and event tests");
    aur_test_step.dependOn(&run_aur_tests.step);

    const appimage_tests = b.addTest(.{
        .name = "appimage-test",
        .root_module = mod,
        .filters = &.{
            "AppImage dispatcher forwards typed status and download progress",
            "AppImage classification is case insensitive and extension based",
            "test isAppImage",
            "get_update returns optional owned results for configured providers",
            "get_updates returns an owned update list",
            "AppImage update manager forwards downloader progress",
            "AppImage updates honor shared cancellation",
            "update: returns false when app not found in db",
            "getAppImagesFromLocalDb maps C# AppImage V2 fields",
            "getAppImagesFromLocalDb normalizes nullable C# strings",
            "getAppImagesFromLocalDb maps every C# update type",
            "getAppImagesFromLocalDb rejects unsupported C# update type",
            "getAppImagesFromLocalDb migrates C# database and second load is native",
            "getAppImagesFromLocalDb leaves native database unchanged",
            "getAppImagesFromLocalDb leaves malformed C# database unchanged",
        },
    });
    const run_appimage_tests = b.addRunArtifact(appimage_tests);
    const appimage_test_step = b.step("appimage-test", "Run safe AppImage parity tests");
    appimage_test_step.dependOn(&run_appimage_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
