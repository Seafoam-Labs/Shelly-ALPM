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

    exe.root_module.addImport("ShellyHttp", shelly_http.module("ShellyHttp"));
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
    gresource.addFileInput(b.path("src/ui/main_window.ui"));
    gresource.addFileInput(b.path("src/ui/settings_page.ui"));
    gresource.addFileInput(b.path("src/ui/flatpak/flatpak_page.ui"));
    gresource.addFileInput(b.path("src/ui/appimage_page.ui"));
    gresource.addFileInput(b.path("src/ui/aur_page.ui"));
    gresource.addFileInput(b.path("src/ui/package_page.ui"));
    gresource.addFileInput(b.path("src/ui/update_page.ui"));
    gresource.addFileInput(b.path("src/dialog/ui/yn.ui"));
    gresource.addFileInput(b.path("src/dialog/ui/multiselect.ui"));
    gresource.addFileInput(b.path("src/ui/package_detail.ui"));
    gresource.addFileInput(b.path("src/ui/transaction_page.ui"));
    gresource.addFileInput(b.path("src/ui/flatpak/flatpak_install_view.ui"));
    gresource.addFileInput(b.path("src/ui/flatpak/flatpak_remove_view.ui"));
    gresource.addFileInput(b.path("src/ui/flatpak/flatpak_remotes_view.ui"));
    gresource.addFileInput(b.path("src/ui/flatpak/flatpak_install_local.ui"));

    // Link the generated resource C into the exe.
    exe.root_module.addCSourceFile(.{ .file = resources_c });
    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("gtk4", .{});

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const root_tests = b.addTest(.{ .root_module = shelly_ui_gtk });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(root_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
