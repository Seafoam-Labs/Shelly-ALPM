const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gdk = bindings.gdk;
const gio = bindings.gio;
const glib = bindings.glib;
const AppTheme = @import("../models/shelly_config.zig").AppTheme;

pub const CLASSIC_CLASS: [:0]const u8 = "theme-classic";
pub const MIDNIGHT_CLASS: [:0]const u8 = "theme-midnight";
pub const SEAFOAM_CLASS: [:0]const u8 = "theme-seafoam";

const CssAsset = struct {
    file_name: []const u8,
    resource_path: [:0]const u8,
};

const css_assets = [_]CssAsset{
    .{
        .file_name = "style.css",
        .resource_path = "/com/shellyorg/shelly/themes/style.css",
    },
    .{
        .file_name = "theme-midnight.css",
        .resource_path = "/com/shellyorg/shelly/themes/theme-midnight.css",
    },
    .{
        .file_name = "theme-seafoam.css",
        .resource_path = "/com/shellyorg/shelly/themes/theme-seafoam.css",
    },
};

const DevCssState = struct {
    providers: [css_assets.len]*gtk.CssProvider,
    paths: [css_assets.len][:0]u8,
    monitor: *gio.FileMonitor,
};

var dev_css_state: ?DevCssState = null;

pub fn className(theme: AppTheme) [:0]const u8 {
    return switch (theme) {
        .classic => CLASSIC_CLASS,
        .midnight => MIDNIGHT_CLASS,
        .seafoam => SEAFOAM_CLASS,
    };
}

pub fn isDark(theme: AppTheme) bool {
    return theme != .classic;
}

pub fn loadProviders(dev_css_dir: ?[]const u8) bool {
    const display = gdk.Display.getDefault() orelse return false;

    if (dev_css_dir) |directory| {
        initDevCss(display, directory) catch |err| {
            std.log.err("theme: failed to start CSS reload mode: {t}", .{err});
            return false;
        };
        return true;
    }

    for (css_assets) |asset| {
        const provider = gtk.CssProvider.new();
        defer provider.unref();
        gtk.CssProvider.loadFromResource(provider, asset.resource_path);
        gtk.StyleContext.addProviderForDisplay(
            display,
            provider.as(gtk.StyleProvider),
            gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }

    return true;
}

fn initDevCss(display: *gdk.Display, directory: []const u8) !void {
    if (dev_css_state != null) return;

    var state: DevCssState = undefined;
    var path_count: usize = 0;
    var provider_count: usize = 0;
    errdefer {
        for (state.providers[0..provider_count]) |provider| {
            gtk.StyleContext.removeProviderForDisplay(
                display,
                provider.as(gtk.StyleProvider),
            );
            provider.unref();
        }
        for (state.paths[0..path_count]) |path| {
            std.heap.c_allocator.free(path);
        }
    }

    for (css_assets, 0..) |asset, index| {
        state.paths[index] = try std.fs.path.joinZ(
            std.heap.c_allocator,
            &.{ directory, asset.file_name },
        );
        path_count += 1;

        const provider = gtk.CssProvider.new();
        state.providers[index] = provider;
        provider_count += 1;
        gtk.CssProvider.loadFromPath(provider, state.paths[index]);
        gtk.StyleContext.addProviderForDisplay(
            display,
            provider.as(gtk.StyleProvider),
            gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }

    const directory_z = try std.heap.c_allocator.dupeZ(u8, directory);
    defer std.heap.c_allocator.free(directory_z);
    const directory_file = gio.File.newForPath(directory_z);
    defer directory_file.unref();

    state.monitor = gio.File.monitorDirectory(
        directory_file,
        .{ .watch_moves = true },
        null,
        null,
    ) orelse return error.CssMonitorUnavailable;
    state.monitor.setRateLimit(100);

    dev_css_state = state;
    const active_state = &dev_css_state.?;
    _ = gio.FileMonitor.signals.changed.connect(
        active_state.monitor,
        *DevCssState,
        &onCssChanged,
        active_state,
        .{},
    );
    std.log.info("theme: watching CSS files in {s}", .{directory});
}

fn onCssChanged(
    _: *gio.FileMonitor,
    file: *gio.File,
    other_file: ?*gio.File,
    event: gio.FileMonitorEvent,
    state: *DevCssState,
) callconv(.c) void {
    const file_basename_c = gio.File.getBasename(file) orelse return;
    defer glib.free(file_basename_c);
    const file_basename = std.mem.span(file_basename_c);

    const other_basename_c = if (other_file) |other|
        gio.File.getBasename(other)
    else
        null;
    defer if (other_basename_c) |basename| glib.free(basename);
    const other_basename = if (other_basename_c) |basename|
        std.mem.span(basename)
    else
        null;

    const index = reloadIndex(event, file_basename, other_basename) orelse return;
    gtk.CssProvider.loadFromPath(state.providers[index], state.paths[index]);
    std.log.info("theme: reloaded {s}", .{css_assets[index].file_name});
}

fn reloadIndex(
    event: gio.FileMonitorEvent,
    file_name: []const u8,
    other_name: ?[]const u8,
) ?usize {
    const candidate = switch (event) {
        .changes_done_hint, .created, .moved_in => file_name,
        .renamed => other_name orelse file_name,
        else => return null,
    };

    for (css_assets, 0..) |asset, index| {
        if (std.mem.eql(u8, candidate, asset.file_name)) return index;
    }
    return null;
}

pub fn deinit() void {
    if (dev_css_state) |*state| {
        _ = state.monitor.cancel();
        state.monitor.unref();

        const display = gdk.Display.getDefault();
        for (state.providers, state.paths) |provider, path| {
            if (display) |active_display| {
                gtk.StyleContext.removeProviderForDisplay(
                    active_display,
                    provider.as(gtk.StyleProvider),
                );
            }
            provider.unref();
            std.heap.c_allocator.free(path);
        }
        dev_css_state = null;
    }
}

pub fn apply(root: *gtk.Widget, theme: AppTheme) void {
    gtk.Widget.removeCssClass(root, CLASSIC_CLASS);
    gtk.Widget.removeCssClass(root, MIDNIGHT_CLASS);
    gtk.Widget.removeCssClass(root, SEAFOAM_CLASS);

    if (theme == .seafoam) {
        gtk.Widget.addCssClass(root, MIDNIGHT_CLASS);
    }
    gtk.Widget.addCssClass(root, className(theme));
}

pub fn inherit(root: *gtk.Widget, parent: *gtk.Widget) AppTheme {
    const theme: AppTheme = if (gtk.Widget.hasCssClass(parent, SEAFOAM_CLASS) != 0)
        .seafoam
    else if (gtk.Widget.hasCssClass(parent, MIDNIGHT_CLASS) != 0)
        .midnight
    else
        .classic;
    apply(root, theme);
    return theme;
}

test "Seafoam theme class names are stable" {
    try std.testing.expectEqualStrings("theme-classic", className(.classic));
    try std.testing.expectEqualStrings("theme-midnight", className(.midnight));
    try std.testing.expectEqualStrings("theme-seafoam", className(.seafoam));
}

test "Seafoam and Midnight share dark window behavior" {
    try std.testing.expect(!isDark(.classic));
    try std.testing.expect(isDark(.midnight));
    try std.testing.expect(isDark(.seafoam));
}

test "Seafoam layers its palette class over the Midnight structure" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const root = gtk.Box.new(.vertical, 0);
    _ = root.as(bindings.gobject.Object).refSink();
    defer root.as(bindings.gobject.Object).unref();

    apply(root.as(gtk.Widget), .seafoam);

    try std.testing.expect(gtk.Widget.hasCssClass(root.as(gtk.Widget), MIDNIGHT_CLASS) != 0);
    try std.testing.expect(gtk.Widget.hasCssClass(root.as(gtk.Widget), SEAFOAM_CLASS) != 0);
    try std.testing.expect(gtk.Widget.hasCssClass(root.as(gtk.Widget), CLASSIC_CLASS) == 0);
}

test "Seafoam child window inherits the active theme from its parent" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const parent = gtk.Box.new(.vertical, 0);
    const child = gtk.Box.new(.vertical, 0);
    _ = parent.as(bindings.gobject.Object).refSink();
    defer parent.as(bindings.gobject.Object).unref();
    _ = child.as(bindings.gobject.Object).refSink();
    defer child.as(bindings.gobject.Object).unref();

    apply(parent.as(gtk.Widget), .midnight);
    _ = inherit(child.as(gtk.Widget), parent.as(gtk.Widget));

    try std.testing.expect(gtk.Widget.hasCssClass(child.as(gtk.Widget), MIDNIGHT_CLASS) != 0);
    try std.testing.expect(gtk.Widget.hasCssClass(child.as(gtk.Widget), CLASSIC_CLASS) == 0);

    apply(parent.as(gtk.Widget), .classic);
    _ = inherit(child.as(gtk.Widget), parent.as(gtk.Widget));

    try std.testing.expect(gtk.Widget.hasCssClass(child.as(gtk.Widget), CLASSIC_CLASS) != 0);
    try std.testing.expect(gtk.Widget.hasCssClass(child.as(gtk.Widget), MIDNIGHT_CLASS) == 0);

    apply(parent.as(gtk.Widget), .seafoam);
    const inherited_theme = inherit(child.as(gtk.Widget), parent.as(gtk.Widget));

    try std.testing.expectEqual(AppTheme.seafoam, inherited_theme);
    try std.testing.expect(gtk.Widget.hasCssClass(child.as(gtk.Widget), SEAFOAM_CLASS) != 0);
    try std.testing.expect(gtk.Widget.hasCssClass(child.as(gtk.Widget), MIDNIGHT_CLASS) != 0);
    try std.testing.expect(gtk.Widget.hasCssClass(child.as(gtk.Widget), CLASSIC_CLASS) == 0);
}

test "Seafoam completed CSS write selects the matching provider" {
    try std.testing.expectEqual(
        @as(?usize, 0),
        reloadIndex(.changes_done_hint, "style.css", null),
    );
    try std.testing.expectEqual(
        @as(?usize, 1),
        reloadIndex(.changes_done_hint, "theme-midnight.css", null),
    );
    try std.testing.expectEqual(
        @as(?usize, 2),
        reloadIndex(.changes_done_hint, "theme-seafoam.css", null),
    );
}

test "Seafoam atomic CSS save selects the renamed destination" {
    try std.testing.expectEqual(
        @as(?usize, 1),
        reloadIndex(.renamed, ".theme-midnight.css.tmp", "theme-midnight.css"),
    );
    try std.testing.expectEqual(
        @as(?usize, 2),
        reloadIndex(.renamed, ".theme-seafoam.css.tmp", "theme-seafoam.css"),
    );
}

test "incomplete and unrelated file events do not reload CSS" {
    try std.testing.expectEqual(
        @as(?usize, null),
        reloadIndex(.changed, "style.css", null),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        reloadIndex(.changes_done_hint, "main_window.ui", null),
    );
}

test "Seafoam palette is scoped and accepted by GTK" {
    const seafoam_css = @embedFile("../themes/theme-seafoam.css");

    try std.testing.expect(std.mem.indexOf(u8, seafoam_css, "@define-color seafoam_window_bg #0f172a;") != null);
    try std.testing.expect(std.mem.indexOf(u8, seafoam_css, "@define-color seafoam_accent #2dd4a8;") != null);
    try std.testing.expect(std.mem.indexOf(u8, seafoam_css, "@define-color seafoam_text #f8fafc;") != null);
    try std.testing.expect(std.mem.indexOf(u8, seafoam_css, ".theme-seafoam .app-main-column") != null);
    try std.testing.expect(std.mem.indexOf(u8, seafoam_css, ".theme-midnight") == null);

    if (gtk.initCheck() == 0) return error.SkipZigTest;
    const display = gdk.Display.getDefault() orelse return error.SkipZigTest;
    const provider = gtk.CssProvider.new();
    defer provider.unref();
    gtk.CssProvider.loadFromString(provider, seafoam_css);
    gtk.StyleContext.addProviderForDisplay(
        display,
        provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    defer gtk.StyleContext.removeProviderForDisplay(
        display,
        provider.as(gtk.StyleProvider),
    );

    const root = gtk.Box.new(.vertical, 0);
    _ = root.as(bindings.gobject.Object).refSink();
    defer root.as(bindings.gobject.Object).unref();
    apply(root.as(gtk.Widget), .seafoam);

    var accent: gdk.RGBA = undefined;
    const context = gtk.Widget.getStyleContext(root.as(gtk.Widget));
    try std.testing.expect(gtk.StyleContext.lookupColor(context, "seafoam_accent", &accent) != 0);
    try std.testing.expectApproxEqAbs(@as(f32, 45.0 / 255.0), accent.f_red, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 212.0 / 255.0), accent.f_green, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 168.0 / 255.0), accent.f_blue, 0.001);
}

test "Seafoam palette is bundled as an application resource" {
    const resources = @embedFile("../gresource.xml");
    try std.testing.expect(std.mem.indexOf(u8, resources, "<file>themes/theme-seafoam.css</file>") != null);
}

test "Midnight sidebar visuals stay scoped without forcing navigation width" {
    const classic_css = @embedFile("../themes/style.css");
    const midnight_css = @embedFile("../themes/theme-midnight.css");

    try std.testing.expect(std.mem.indexOf(u8, classic_css, "\n.app-sidebar {\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, classic_css, "\n.app-sidebar .nav-btn {\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, midnight_css, ".theme-midnight .app-sidebar.sidebar-expanded {\n  min-width: 13em;\n}") != null);
    try std.testing.expect(std.mem.indexOf(u8, midnight_css, "\n.theme-midnight .app-sidebar .nav-btn {\n") != null);
}

test "Midnight sidebar keeps a visible gap between navigation items" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const display = gdk.Display.getDefault() orelse return error.SkipZigTest;
    const provider = gtk.CssProvider.new();
    defer provider.unref();
    gtk.CssProvider.loadFromString(
        provider,
        @embedFile("../themes/theme-midnight.css") ++
            "\n.test-sidebar-primary { border-spacing: 0.25em; }\n",
    );
    gtk.StyleContext.addProviderForDisplay(
        display,
        provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    defer gtk.StyleContext.removeProviderForDisplay(
        display,
        provider.as(gtk.StyleProvider),
    );

    const root = gtk.Box.new(.vertical, 0);
    _ = root.as(bindings.gobject.Object).refSink();
    defer root.as(bindings.gobject.Object).unref();
    gtk.Widget.addCssClass(root.as(gtk.Widget), MIDNIGHT_CLASS);

    const sidebar = gtk.Box.new(.vertical, 0);
    gtk.Widget.addCssClass(sidebar.as(gtk.Widget), "app-sidebar");
    gtk.Box.append(root, sidebar.as(gtk.Widget));

    const Gap = struct {
        fn measure(parent: *gtk.Box, class_name: [:0]const u8) c_int {
            const single_item = gtk.Box.new(.vertical, 0);
            gtk.Widget.addCssClass(single_item.as(gtk.Widget), class_name);
            gtk.Box.append(parent, single_item.as(gtk.Widget));
            const single_button = gtk.Button.new();
            gtk.Widget.addCssClass(single_button.as(gtk.Widget), "nav-btn");
            gtk.Box.append(single_item, single_button.as(gtk.Widget));

            const two_items = gtk.Box.new(.vertical, 0);
            gtk.Widget.addCssClass(two_items.as(gtk.Widget), class_name);
            gtk.Box.append(parent, two_items.as(gtk.Widget));
            const first_button = gtk.Button.new();
            gtk.Widget.addCssClass(first_button.as(gtk.Widget), "nav-btn");
            gtk.Box.append(two_items, first_button.as(gtk.Widget));
            const second_button = gtk.Button.new();
            gtk.Widget.addCssClass(second_button.as(gtk.Widget), "nav-btn");
            gtk.Box.append(two_items, second_button.as(gtk.Widget));

            var single_height: c_int = 0;
            var two_items_height: c_int = 0;
            var second_button_height: c_int = 0;
            gtk.Widget.measure(single_item.as(gtk.Widget), .vertical, -1, null, &single_height, null, null);
            gtk.Widget.measure(two_items.as(gtk.Widget), .vertical, -1, null, &two_items_height, null, null);
            gtk.Widget.measure(second_button.as(gtk.Widget), .vertical, -1, null, &second_button_height, null, null);
            return two_items_height - single_height - second_button_height;
        }
    };

    const actual_gap = Gap.measure(sidebar, "sidebar-primary");
    const expected_gap = Gap.measure(sidebar, "test-sidebar-primary");
    try std.testing.expect(actual_gap >= expected_gap);
}

test "Midnight Flatpak navigation surface stays transparent" {
    const midnight_css = @embedFile("../themes/theme-midnight.css");
    const transparent_surface =
        ".theme-midnight .flatpak-page list.flatpak-nav,\n" ++
        ".theme-midnight .flatpak-page scrolledwindow,\n" ++
        ".theme-midnight .flatpak-page scrolledwindow > viewport {\n" ++
        "  background-color: transparent;\n";

    try std.testing.expect(std.mem.indexOf(u8, midnight_css, transparent_surface) != null);
}

test "Midnight close control reaches the right window edge" {
    const midnight_css = @embedFile("../themes/theme-midnight.css");
    const edge_aligned_controls =
        ".theme-midnight .app-window-controls-overlay {\n" ++
        "  margin-right: 0;\n";

    try std.testing.expect(std.mem.indexOf(u8, midnight_css, edge_aligned_controls) != null);
}

test "Midnight collapsed brand removes the hidden label gap" {
    const midnight_css = @embedFile("../themes/theme-midnight.css");
    const centered_brand =
        ".theme-midnight .app-sidebar.sidebar-collapsed .sidebar-brand {\n" ++
        "  padding-left: 0.45em;\n" ++
        "  padding-right: 0.45em;\n" ++
        "  border-spacing: 0;\n";

    try std.testing.expect(std.mem.indexOf(u8, midnight_css, centered_brand) != null);
}

test "Midnight lockout content starts below the window controls" {
    const classic_css = @embedFile("../themes/style.css");
    const midnight_css = @embedFile("../themes/theme-midnight.css");
    const main_window_ui = @embedFile("../ui/main_window.ui");
    const reserved_chrome_space =
        ".theme-midnight .lockout-content {\n" ++
        "  padding-top: 2em;\n";

    try std.testing.expect(std.mem.indexOf(u8, main_window_ui, "<class name=\"lockout-content\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, midnight_css, reserved_chrome_space) != null);
    try std.testing.expect(std.mem.indexOf(u8, classic_css, ".lockout-content") == null);
}

test "Midnight lockout surface hides the underlying application chrome" {
    const midnight_css = @embedFile("../themes/theme-midnight.css");
    const opaque_lockout =
        ".theme-midnight .lockout-content {\n" ++
        "  padding-top: 2em;\n" ++
        "  background-color: @midnight_window_bg;\n";

    try std.testing.expect(std.mem.indexOf(u8, midnight_css, opaque_lockout) != null);
}

test "Midnight overlay dialogs render only the inner card border" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const display = gdk.Display.getDefault() orelse return error.SkipZigTest;
    const provider = gtk.CssProvider.new();
    defer provider.unref();
    gtk.CssProvider.loadFromString(provider, @embedFile("../themes/theme-midnight.css"));
    gtk.StyleContext.addProviderForDisplay(
        display,
        provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    defer gtk.StyleContext.removeProviderForDisplay(display, provider.as(gtk.StyleProvider));

    const window = gtk.Window.new();
    const dialog_surface = gtk.Box.new(.vertical, 0);
    const card = gtk.Frame.new(null);
    defer gtk.Window.destroy(window);

    gtk.Widget.addCssClass(window.as(gtk.Widget), MIDNIGHT_CLASS);
    gtk.Widget.addCssClass(dialog_surface.as(gtk.Widget), "dialog-surface");
    gtk.Widget.addCssClass(card.as(gtk.Widget), "lockout-card");
    gtk.Box.append(dialog_surface, card.as(gtk.Widget));
    gtk.Window.setChild(window, dialog_surface.as(gtk.Widget));
    gtk.Window.present(window);
    while (glib.MainContext.iteration(null, 0) != 0) {}

    var outer_border: gtk.Border = undefined;
    var card_border: gtk.Border = undefined;
    gtk.StyleContext.getBorder(gtk.Widget.getStyleContext(dialog_surface.as(gtk.Widget)), &outer_border);
    gtk.StyleContext.getBorder(gtk.Widget.getStyleContext(card.as(gtk.Widget)), &card_border);

    try std.testing.expectEqual(@as(i16, 0), outer_border.f_left);
    try std.testing.expectEqual(@as(i16, 1), card_border.f_left);
}

test "transaction questions render only the inner dialog border" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const display = gdk.Display.getDefault() orelse return error.SkipZigTest;
    const classic_provider = gtk.CssProvider.new();
    defer classic_provider.unref();
    gtk.CssProvider.loadFromString(classic_provider, @embedFile("../themes/style.css"));
    gtk.StyleContext.addProviderForDisplay(
        display,
        classic_provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    defer gtk.StyleContext.removeProviderForDisplay(display, classic_provider.as(gtk.StyleProvider));

    const midnight_provider = gtk.CssProvider.new();
    defer midnight_provider.unref();
    gtk.CssProvider.loadFromString(midnight_provider, @embedFile("../themes/theme-midnight.css"));
    gtk.StyleContext.addProviderForDisplay(
        display,
        midnight_provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    defer gtk.StyleContext.removeProviderForDisplay(display, midnight_provider.as(gtk.StyleProvider));

    const window = gtk.Window.new();
    const question_layer = gtk.Box.new(.vertical, 0);
    const dialog_card = gtk.Frame.new(null);
    defer gtk.Window.destroy(window);

    gtk.Widget.addCssClass(window.as(gtk.Widget), MIDNIGHT_CLASS);
    gtk.Widget.addCssClass(question_layer.as(gtk.Widget), "question-layer");
    gtk.Widget.addCssClass(dialog_card.as(gtk.Widget), "lockout-card");
    gtk.Box.append(question_layer, dialog_card.as(gtk.Widget));
    gtk.Window.setChild(window, question_layer.as(gtk.Widget));
    gtk.Window.present(window);
    while (glib.MainContext.iteration(null, 0) != 0) {}

    var layer_border: gtk.Border = undefined;
    var dialog_border: gtk.Border = undefined;
    gtk.StyleContext.getBorder(gtk.Widget.getStyleContext(question_layer.as(gtk.Widget)), &layer_border);
    gtk.StyleContext.getBorder(gtk.Widget.getStyleContext(dialog_card.as(gtk.Widget)), &dialog_border);

    try std.testing.expectEqual(@as(i16, 0), layer_border.f_left);
    try std.testing.expectEqual(@as(i16, 1), dialog_border.f_left);
}

test "welcome cards have no visible outer surface in any theme" {
    const classic_css = @embedFile("../themes/style.css");
    const midnight_css = @embedFile("../themes/theme-midnight.css");
    const frameless_card =
        ".welcome-card {\n" ++
        "  margin: 1em;\n" ++
        "  padding: 1.5em;\n" ++
        "  border: 0;\n" ++
        "  border-radius: 0;\n" ++
        "  border-spacing: 0.8em;\n" ++
        "  background-color: transparent;\n";
    const transparent_midnight_card =
        ".theme-midnight .welcome-card {\n" ++
        "  color: @midnight_text;\n" ++
        "  background-color: transparent;\n" ++
        "  background-image: none;\n";

    try std.testing.expect(std.mem.indexOf(u8, classic_css, frameless_card) != null);
    try std.testing.expect(std.mem.indexOf(u8, midnight_css, transparent_midnight_card) != null);
    try std.testing.expect(std.mem.indexOf(u8, classic_css, "box-shadow: 0 0.75em 2em") == null);
    try std.testing.expect(std.mem.indexOf(u8, midnight_css, "border-color: alpha(white, 0.12)") == null);
    try std.testing.expect(std.mem.indexOf(u8, midnight_css, "box-shadow: 0 1em 2.5em") == null);
}

test "settings use viewport-safe centered columns with hoverable rows" {
    const settings_ui = @embedFile("../ui/settings_page.ui");
    const utilities_ui = @embedFile("../ui/utilities_page.ui");
    const classic_css = @embedFile("../themes/style.css");
    const midnight_css = @embedFile("../themes/theme-midnight.css");
    const utilities_sized_settings_section =
        "<property name=\"orientation\">vertical</property>\n" ++
        "                                <property name=\"spacing\">12</property>\n" ++
        "                                <property name=\"halign\">center</property>\n" ++
        "                                <property name=\"hexpand\">false</property>\n" ++
        "                                <style><class name=\"settings-section\"/></style>";
    const utilities_sized_utilities_section =
        "<property name=\"orientation\">vertical</property>\n" ++
        "                        <property name=\"spacing\">12</property>\n" ++
        "                        <property name=\"halign\">center</property>\n" ++
        "                        <property name=\"hexpand\">false</property>\n" ++
        "                        <style><class name=\"settings-section\"/></style>";
    const centered_viewport_wrapper =
        "<object class=\"GtkCenterBox\">\n" ++
        "                            <property name=\"hexpand\">true</property>\n" ++
        "                            <property name=\"vexpand\">true</property>\n" ++
        "                            <child type=\"center\">";

    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, settings_ui, centered_viewport_wrapper));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, utilities_ui, "<object class=\"GtkCenterBox\">"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, settings_ui, utilities_sized_settings_section));
    try std.testing.expect(std.mem.indexOf(u8, utilities_ui, utilities_sized_utilities_section) != null);
    try std.testing.expect(std.mem.indexOf(u8, classic_css, ".settings-section > box:hover {\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, classic_css, ".settings-section.settings-section-wide {\n  min-width: 52.25em;\n}") != null);
    try std.testing.expect(std.mem.indexOf(u8, midnight_css, ".theme-midnight .settings-section > box:hover {\n") != null);
}
