const std = @import("std");

const versionString = @import("build.zig.zon").version;

const version = std.SemanticVersion.parse(versionString) catch @panic("Bad version");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    options.addOption(
        bool,
        "skip_background_services",
        b.option(
            bool,
            "skip-background-services",
            "Skip starting background services (icon download, tray); useful for Valgrind leak checks",
        ) orelse false,
    );
    const dev_css = b.option(
        bool,
        "dev-css",
        "Load CSS from src/themes and reload it after saves; intended for local UI development",
    ) orelse false;
    options.addOption(bool, "dev_css", dev_css);
    options.addOption(
        ?[]const u8,
        "dev_css_dir",
        if (dev_css) b.pathFromRoot("src/themes") else null,
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

    const blur_protocol = b.path("src/wayland/ext-background-effect-v1.xml");
    const blur_header_cmd = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    blur_header_cmd.addFileArg(blur_protocol);
    const blur_header = blur_header_cmd.addOutputFileArg("ext-background-effect-v1-client-protocol.h");

    const blur_code_cmd = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    blur_code_cmd.addFileArg(blur_protocol);
    const blur_code = blur_code_cmd.addOutputFileArg("ext-background-effect-v1-protocol.c");

    exe.root_module.addImport("ShellyHttp", shelly_http.module("ShellyHttp"));
    exe.root_module.addIncludePath(b.path("src/wayland"));
    exe.root_module.addIncludePath(blur_header.dirname());
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/wayland/blur_bridge.c"),
        .flags = &.{ "-Wall", "-Wextra", "-Werror" },
    });
    exe.root_module.addCSourceFile(.{ .file = blur_code });
    exe.root_module.linkSystemLibrary("gtk4-wayland", .{});
    b.installArtifact(exe);

    // Compile the gresource bundle to C source.
    const gresource = b.addSystemCommand(&.{"glib-compile-resources"});
    gresource.addArg("--generate-source");
    gresource.addArg("--sourcedir");
    gresource.addDirectoryArg(b.path("src"));
    gresource.addArg("--sourcedir");
    gresource.addDirectoryArg(b.path("../assets"));
    gresource.addArg("--target");
    const resources_c = gresource.addOutputFileArg("resources.c");
    gresource.addFileArg(b.path("src/gresource.xml"));

    gresource.addFileInput(b.path("src/themes/style.css"));
    gresource.addFileInput(b.path("src/themes/theme-midnight.css"));
    gresource.addFileInput(b.path("src/themes/theme-seafoam.css"));
    gresource.addFileInput(b.path("../assets/shellylogo.png"));
    gresource.addFileInput(b.path("src/assets/icons/flatpak-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/arch-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/update-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/star-filled-rounded-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/package-x-generic-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/settings-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/application-x-executable-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/software-update-available-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/shelly-window-minimize-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/shelly-window-maximize-symbolic.svg"));
    gresource.addFileInput(b.path("src/assets/icons/shelly-window-close-symbolic.svg"));
    gresource.addFileInput(b.path("src/ui/main_window.ui"));
    gresource.addFileInput(b.path("src/ui/settings_page.ui"));
    gresource.addFileInput(b.path("src/ui/utilities_page.ui"));
    gresource.addFileInput(b.path("src/ui/flatpak/flatpak_page.ui"));
    gresource.addFileInput(b.path("src/ui/appimage_page.ui"));
    gresource.addFileInput(b.path("src/ui/aur_page.ui"));
    gresource.addFileInput(b.path("src/ui/search_page.ui"));
    gresource.addFileInput(b.path("src/ui/package_page.ui"));
    gresource.addFileInput(b.path("src/ui/update_page.ui"));
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
    gresource.addFileInput(b.path("src/ui/welcome.ui"));
    // Link the generated resource C into the exe.
    exe.root_module.addCSourceFile(.{ .file = resources_c });
    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("gtk4", .{});

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const valgrind_cmd = b.addSystemCommand(&.{"valgrind"});
    valgrind_cmd.addArgs(&.{
        "--tool=memcheck",
        "--leak-check=full",
        "--show-leak-kinds=definite,indirect",
        "--track-origins=yes",
        "--num-callers=50",
        "--error-exitcode=42",
        "--log-file=valgrind-%p.log",
    });
    valgrind_cmd.addPrefixedFileArg("--suppressions=", b.path("valgrind/glib-gtk.supp"));
    valgrind_cmd.addArtifactArg(exe);
    if (b.args) |args| valgrind_cmd.addArgs(args);

    const valgrind_step = b.step("valgrind", "Run the app under Valgrind (memcheck) to check for memory leaks");
    valgrind_step.dependOn(&valgrind_cmd.step);

    const root_tests = b.addTest(.{ .root_module = shelly_ui_gtk });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });

    const sidebar_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sidebar.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "Shelly_Ui_Gtk", .module = shelly_ui_gtk }},
        }),
        .filters = &.{"sidebar root explicitly refuses horizontal expansion"},
    });
    sidebar_tests.root_module.linkSystemLibrary("gtk4", .{});

    const layout_style_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/themes/sidebar_style_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "Shelly_Ui_Gtk", .module = shelly_ui_gtk }},
        }),
    });
    layout_style_tests.root_module.linkSystemLibrary("gtk4", .{});

    const theme_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/theme_manager_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "Shelly_Ui_Gtk", .module = shelly_ui_gtk }},
        }),
        .filters = &.{"Seafoam"},
    });
    theme_tests.root_module.linkSystemLibrary("gtk4", .{});
    const theme_test_step = b.step("test-theme", "Run Seafoam theme tests");
    theme_test_step.dependOn(&b.addRunArtifact(theme_tests).step);

    const config_theme_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/config_theme_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const config_theme_test_step = b.step("test-config-theme", "Run theme persistence tests");
    config_theme_test_step.dependOn(&b.addRunArtifact(config_theme_tests).step);

    const settings_allocation_tests = b.addExecutable(.{
        .name = "settings-layout-allocation-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/settings_layout_allocation_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Shelly_Ui_Gtk", .module = shelly_ui_gtk },
                .{ .name = "options", .module = options.createModule() },
                .{ .name = "ShellyHttp", .module = shelly_http.module("ShellyHttp") },
            },
        }),
    });
    settings_allocation_tests.root_module.addIncludePath(b.path("src/wayland"));
    settings_allocation_tests.root_module.addIncludePath(blur_header.dirname());
    settings_allocation_tests.root_module.addCSourceFile(.{
        .file = b.path("src/wayland/blur_bridge.c"),
        .flags = &.{ "-Wall", "-Wextra", "-Werror" },
    });
    settings_allocation_tests.root_module.addCSourceFile(.{ .file = blur_code });
    settings_allocation_tests.root_module.addCSourceFile(.{ .file = resources_c });
    settings_allocation_tests.root_module.link_libc = true;
    settings_allocation_tests.root_module.linkSystemLibrary("gtk4-wayland", .{});
    settings_allocation_tests.root_module.linkSystemLibrary("gtk4", .{});

    const package_toolbar_tests = b.addExecutable(.{
        .name = "package-toolbar-layout-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/package_toolbar_layout_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Shelly_Ui_Gtk", .module = shelly_ui_gtk },
                .{ .name = "options", .module = options.createModule() },
                .{ .name = "ShellyHttp", .module = shelly_http.module("ShellyHttp") },
            },
        }),
    });
    package_toolbar_tests.root_module.addIncludePath(b.path("src/wayland"));
    package_toolbar_tests.root_module.addIncludePath(blur_header.dirname());
    package_toolbar_tests.root_module.addCSourceFile(.{
        .file = b.path("src/wayland/blur_bridge.c"),
        .flags = &.{ "-Wall", "-Wextra", "-Werror" },
    });
    package_toolbar_tests.root_module.addCSourceFile(.{ .file = blur_code });
    package_toolbar_tests.root_module.addCSourceFile(.{ .file = resources_c });
    package_toolbar_tests.root_module.link_libc = true;
    package_toolbar_tests.root_module.linkSystemLibrary("gtk4-wayland", .{});
    package_toolbar_tests.root_module.linkSystemLibrary("gtk4", .{});

    const update_page_tests = b.addExecutable(.{
        .name = "update-page-layout-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/update_page_layout_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Shelly_Ui_Gtk", .module = shelly_ui_gtk },
                .{ .name = "options", .module = options.createModule() },
                .{ .name = "ShellyHttp", .module = shelly_http.module("ShellyHttp") },
            },
        }),
    });
    update_page_tests.root_module.addIncludePath(b.path("src/wayland"));
    update_page_tests.root_module.addIncludePath(blur_header.dirname());
    update_page_tests.root_module.addCSourceFile(.{
        .file = b.path("src/wayland/blur_bridge.c"),
        .flags = &.{ "-Wall", "-Wextra", "-Werror" },
    });
    update_page_tests.root_module.addCSourceFile(.{ .file = blur_code });
    update_page_tests.root_module.addCSourceFile(.{ .file = resources_c });
    update_page_tests.root_module.link_libc = true;
    update_page_tests.root_module.linkSystemLibrary("gtk4-wayland", .{});
    update_page_tests.root_module.linkSystemLibrary("gtk4", .{});
    const update_page_test_step = b.step("test-update-row", "Run update row layout test");
    update_page_test_step.dependOn(&b.addRunArtifact(update_page_tests).step);

    const layout_test_step = b.step("test-layout", "Run UI layout tests");
    layout_test_step.dependOn(&b.addRunArtifact(sidebar_tests).step);
    layout_test_step.dependOn(&b.addRunArtifact(layout_style_tests).step);
    layout_test_step.dependOn(&b.addRunArtifact(settings_allocation_tests).step);
    layout_test_step.dependOn(&b.addRunArtifact(package_toolbar_tests).step);
    layout_test_step.dependOn(update_page_test_step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(root_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
