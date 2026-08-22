const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gdk = bindings.gdk;
const gio = bindings.gio;
const glib = bindings.glib;
const AppTheme = @import("../models/shelly_config.zig").AppTheme;

pub const CLASSIC_CLASS: [:0]const u8 = "theme-classic";
pub const MIDNIGHT_CLASS: [:0]const u8 = "theme-midnight";

const CssAsset = struct {
    file_name: []const u8,
    resource_path: [:0]const u8,
};

const css_assets = [_]CssAsset{
    .{
        .file_name = "style.css",
        .resource_path = "/com/shellyorg/shelly/style.css",
    },
    .{
        .file_name = "theme-midnight.css",
        .resource_path = "/com/shellyorg/shelly/theme-midnight.css",
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
    };
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
    gtk.Widget.addCssClass(root, className(theme));
}

test "theme class names are stable" {
    try std.testing.expectEqualStrings("theme-classic", className(.classic));
    try std.testing.expectEqualStrings("theme-midnight", className(.midnight));
}

test "completed CSS write selects the matching provider" {
    try std.testing.expectEqual(
        @as(?usize, 0),
        reloadIndex(.changes_done_hint, "style.css", null),
    );
    try std.testing.expectEqual(
        @as(?usize, 1),
        reloadIndex(.changes_done_hint, "theme-midnight.css", null),
    );
}

test "atomic CSS save selects the renamed destination" {
    try std.testing.expectEqual(
        @as(?usize, 1),
        reloadIndex(.renamed, ".theme-midnight.css.tmp", "theme-midnight.css"),
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
