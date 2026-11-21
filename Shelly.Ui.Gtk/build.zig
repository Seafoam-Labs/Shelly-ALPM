const std = @import("std");

const versionString = @import("build.zig.zon").version;

const version = std.SemanticVersion.parse(versionString) catch @panic("Bad version");

pub const AurBackend = enum { aur, atoll, both, none };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const diagnostics = b.dependency("shelly_diagnostics", .{ .target = target, .optimize = optimize }).module("diagnostics");

    const gobject = b.dependency("gobject", .{
        .target = target,
        .optimize = optimize,
    });
    const shelly_http = b.dependency("shelly_http", .{
        .target = target,
        .optimize = optimize,
    });

    const shelly_ui_gtk = b.addModule("Shelly_Ui_Gtk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    shelly_ui_gtk.addImport("diagnostics", diagnostics);
    shelly_ui_gtk.addImport("glib2", gobject.module("glib2"));
    shelly_ui_gtk.addImport("gobject2", gobject.module("gobject2"));
    shelly_ui_gtk.addImport("gio2", gobject.module("gio2"));
    shelly_ui_gtk.addImport("pango1", gobject.module("pango1"));
    shelly_ui_gtk.addImport("gtk4", gobject.module("gtk4"));
    shelly_ui_gtk.addImport("gdk4", gobject.module("gdk4"));
    shelly_ui_gtk.addImport("ShellyHttp", shelly_http.module("ShellyHttp"));

    const options = b.addOptions();
    options.addOption(std.SemanticVersion, "version", version);
    options.addOption(
        []const u8,
        "flatpak_backend_package",
        b.option(
            []const u8,
            "flatpak-backend-package",
            "Package containing the Flatpak backend for this Shelly build",
        ) orelse "shelly-flatpak-backend",
    );
    // Optionally Allows for a Devario Based build
    // This will contain long term items to support further enrichment to pkg's
    options.addOption(
        bool,
        "devario",
        b.option(
            bool,
            "devario",
            "Build the Devario variant",
        ) orelse false,
    );
    options.addOption(
        bool,
        "exclude_flatpak",
        b.option(
            bool,
            "exclude-flatpak",
            "Compile out the Flatpak page and its settings row",
        ) orelse false,
    );
    options.addOption(
        bool,
        "exclude_fwupd",
        b.option(
            bool,
            "exclude-fwupd",
            "Compile out the Firmware page and its settings row",
        ) orelse false,
    );
    options.addOption(
        AurBackend,
        "aur_backend",
        b.option(
            AurBackend,
            "aur-backend",
            "Which AUR provider to build: aur, atoll, both, or none",
        ) orelse .both,
    );
    options.addOption(
        bool,
        "exclude_recommend",
        b.option(
            bool,
            "exclude-recommend",
            "Compile out the Recommended page and its settings row",
        ) orelse false,
    );
    options.addOption(
        bool,
        "exclude_appimage",
        b.option(
            bool,
            "exclude-appimage",
            "Compile out the AppImage page and its settings rows",
        ) orelse false,
    );
    options.addOption(
        bool,
        "exclude_shelly_search",
        b.option(
            bool,
            "exclude-shelly-search",
            "Compile out the Shelly Search page and its settings row",
        ) orelse false,
    );
    options.addOption(
        bool,
        "skip_background_services",
        b.option(
            bool,
            "skip-background-services",
            "Skip starting background services (icon download, tray); useful for Valgrind leak checks",
        ) orelse false,
    );

    const exe = b.addExecutable(.{
        .name = "Shelly_Ui_Gtk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Shelly_Ui_Gtk", .module = shelly_ui_gtk },
                .{ .name = "options", .module = options.createModule() },
            },
        }),
    });
    exe.root_module.addImport("diagnostics", diagnostics);

    exe.root_module.addImport("ShellyHttp", shelly_http.module("ShellyHttp"));
    // Preserve GModule's --export-dynamic requirement explicitly.
    exe.rdynamic = true;
    b.installArtifact(exe);

    // Compile the gresource bundle to C source.
    const gresource = b.addSystemCommand(&.{"glib-compile-resources"});
    gresource.addArg("--generate-source");
    gresource.addArg("--sourcedir");
    gresource.addDirectoryArg(b.path("src"));
    gresource.addArg("--target");
    const resources_c = gresource.addOutputFileArg("resources.c");
    gresource.addFileArg(b.path("src/gresource.xml"));

    gresource.addFileInput(b.path("src/style.css"));
    gresource.addFileInput(b.path("src/themes/shelly-components.css"));
    gresource.addFileInput(b.path("src/themes/shelly-dark.css"));
    gresource.addFileInput(b.path("src/themes/shelly-light.css"));
    gresource.addFileInput(b.path("src/assets/icons/flatpak-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/funnel-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/arch-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/atoll-shark-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/update-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/star-filled-rounded-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/package-x-generic-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/settings-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/application-x-executable-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/software-update-available-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/firmware-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/checkmark-small-symbolic.svg"));
    gresource.addFileInput(b.path("src/ui/main_window.ui"));
    gresource.addFileInput(b.path("src/ui/settings_page.ui"));
    gresource.addFileInput(b.path("src/ui/utilities_page.ui"));
    gresource.addFileInput(b.path("src/ui/flatpak/flatpak_page.ui"));
    gresource.addFileInput(b.path("src/ui/appimage_page.ui"));
    gresource.addFileInput(b.path("src/ui/aur_page.ui"));
    gresource.addFileInput(b.path("src/ui/atoll_aur_page.ui"));
    gresource.addFileInput(b.path("src/ui/search_page.ui"));
    gresource.addFileInput(b.path("src/ui/package_page.ui"));
    gresource.addFileInput(b.path("src/ui/update_page.ui"));
    gresource.addFileInput(b.path("src/ui/firmware_page.ui"));
    gresource.addFileInput(b.path("src/dialog/ui/yn.ui"));
    gresource.addFileInput(b.path("src/dialog/ui/flatpak_remove.ui"));
    gresource.addFileInput(b.path("src/dialog/ui/multiselect.ui"));
    gresource.addFileInput(b.path("src/ui/package_detail.ui"));
    gresource.addFileInput(b.path("src/ui/aur_package_detail.ui"));
    gresource.addFileInput(b.path("src/ui/flatpak_package_detail.ui"));
    gresource.addFileInput(b.path("src/ui/transaction_page.ui"));
    gresource.addFileInput(b.path("src/dialog/ui/provider.ui"));
    gresource.addFileInput(b.path("src/ui/recommend_page.ui"));
    gresource.addFileInput(b.path("src/ui/flatpak/flatpak_install_view.ui"));
    gresource.addFileInput(b.path("src/ui/flatpak/flatpak_remove_view.ui"));
    gresource.addFileInput(b.path("src/ui/flatpak/flatpak_remotes_view.ui"));
    gresource.addFileInput(b.path("src/ui/flatpak/flatpak_install_local.ui"));
    gresource.addFileInput(b.path("src/dialog/ui/version_history.ui"));
    gresource.addFileInput(b.path("src/dialog/ui/permissions.ui"));
    gresource.addFileInput(b.path("src/dialog/ui/addons.ui"));
    gresource.addFileInput(b.path("src/dialog/ui/pkg_build.ui"));
    gresource.addFileInput(b.path("src/dialog/ui/plan_dialog.ui"));
    gresource.addFileInput(b.path("src/dialog/ui/preview_pkgbuild.ui"));
    gresource.addFileInput(b.path("src/dialog/ui/polkit_warning.ui"));
    gresource.addFileInput(b.path("src/dialog/ui/aur_warning.ui"));
    gresource.addFileInput(b.path("src/ui/welcome.ui"));
    gresource.addFileInput(b.path("src/devario/package_page.ui"));
    // Link the generated resource C into the exe.
    exe.root_module.addCSourceFile(.{ .file = resources_c });
    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("gtk4", .{});

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const valgrind_extra = b.option(
        []const u8,
        "valgrind-args",
        "Extra valgrind flags, whitespace-separated (e.g. \"-s\" or \"--show-leak-kinds=all\")",
    ) orelse "";
    // Whitespace splitting only, no shell quoting: fine for flags, not for
    // values containing spaces.
    var valgrind_extra_args: std.ArrayList([]const u8) = .empty;
    var extra_it = std.mem.tokenizeScalar(u8, valgrind_extra, ' ');
    while (extra_it.next()) |arg| valgrind_extra_args.append(b.allocator, arg) catch @panic("OOM");

    if (optimize == .debug) {
        // Frame pointers give more Zig frames file:line in valgrind stacks.
        // Debug only, so packaging builds (safe/small) are untouched.
        exe.root_module.omit_frame_pointer = false;
    }

    const valgrind_cmd = addValgrindCommand(b, target, exe, "valgrind-%p.log", valgrind_extra_args.items);
    valgrind_cmd.addPassthruArgs();

    const valgrind_step = b.step("valgrind", "Run the app under Valgrind (memcheck) to check for memory leaks");
    valgrind_step.dependOn(&valgrind_cmd.step);

    const test_filters = b.option([]const []const u8, "test-filter", "Run tests whose names contain this text") orelse &.{};
    const root_tests = b.addTest(.{ .root_module = shelly_ui_gtk, .filters = test_filters });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module, .filters = test_filters });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(root_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // No addPassthruArgs here: the test runner rejects unknown arguments
    // (filtering is compile-time only, via -Dtest-filter).
    const valgrind_test_cmd = addValgrindCommand(b, target, exe_tests, "valgrind-test-%p.log", valgrind_extra_args.items);
    const valgrind_test_step = b.step("valgrind-test", "Run the test suite under Valgrind (memcheck)");
    valgrind_test_step.dependOn(&valgrind_test_cmd.step);
}

fn addValgrindCommand(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    artifact: *std.Build.Step.Compile,
    log_file: []const u8,
    extra_args: []const []const u8,
) *std.Build.Step.Run {
    const cmd = b.addSystemCommand(&.{"valgrind"});
    cmd.addArgs(&.{
        "--tool=memcheck",
        "--leak-check=full",
        "--show-leak-kinds=definite,possible", // memcheck default; indirect only on deep dives
        "--errors-for-leak-kinds=definite", // the gate: definite leaks only
        "--track-origins=yes",
        "--num-callers=50",
        "--gen-suppressions=all",
        "--error-exitcode=42",
    });
    cmd.addArg(b.fmt("--log-file={s}", .{log_file}));
    cmd.addPrefixedFileArg("--suppressions=", b.path("valgrind/glib-gtk.supp"));
    cmd.addArgs(extra_args);
    cmd.addArtifactArg(artifact);
    if (target.result.cpu.has(.x86, .avx512f)) {
        // Valgrind 3.25.1 has no EVEX decoder; AVX-512 codegen in compiler_rt
        // SIGILLs under memcheck. Attached to the valgrind command only, so
        // plain build/run/test with the native target are unaffected.
        const fail = b.addFail(
            "valgrind cannot decode AVX-512 (EVEX): rerun with -Dcpu=x86_64_v3 or lower",
        );
        cmd.step.dependOn(&fail.step);
    }
    return cmd;
}
