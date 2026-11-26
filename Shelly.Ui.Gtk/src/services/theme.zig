//! Applies Shelly's built-in Pearl-style theme, optionally with the desktop's
//! colors.
//!
//! It must render exactly as designed, so the desktop GTK theme is taken out
//! of the picture entirely instead of being layered under:
//!  - `gtk-theme-name` is pinned to the blank theme embedded in libgtk
//!    ("Empty", since GTK 4.0), so GTK's own theme slot loads nothing from
//!    the desktop selection;
//!  - a provider at THEME priority loads the version-matched base stylesheet
//!    that ships inside the running libgtk (GTK 4.23+ embeds it as the
//!    "Default" theme, older builds as "Adwaita"), restoring the stock
//!    structure the Pearl sheets are authored against.
//! If neither embedded base can be found the pin is dropped and the previous
//! layering behavior applies, logged as a warning.
//!
//! Each palette imports `shelly-components.css`. `@define-color` is
//! provider-global, so the provider reloads when the variant changes.
//!
//! Mirrors Pearl's appearance observer: root class + swappable provider, plus
//! a live watcher for the desktop dark/light preference.

const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gdk = bindings.gdk;
const gio = bindings.gio;
const glib = bindings.glib;
const gobject = bindings.gobject;
const runtime = @import("runtime.zig");
const translations = @import("../helpers/translations.zig");
const config_model = @import("../models/shelly_config.zig");
const desktop_palette = @import("desktop_palette.zig");

pub const ThemeMode = config_model.ThemeMode;
pub const ThemeVariant = config_model.ThemeVariant;

const dark_resource = "/com/shellyorg/shelly/themes/shelly-dark.css";
const light_resource = "/com/shellyorg/shelly/themes/shelly-light.css";

/// A base theme stylesheet embedded in the running libgtk resource bundle.
/// These travel with the GTK build, so they are always version-matched to
/// the widget internals; the pin is the theme name that resolves to the
/// same embedded file when GTK loads a theme by name.
const ThemeBase = struct {
    resource: [:0]const u8,
    /// Separate dark sheet for pre-4.16 builds, which predate the
    /// `@media (prefers-color-scheme)` block in the base stylesheet.
    dark_resource: ?[:0]const u8,
    pin: [:0]const u8,
};

/// GTK 4.23 renamed the embedded Adwaita base to "Default"; probe this one
/// first, then fall back to the classic name.
const default_base = ThemeBase{
    .resource = "/org/gtk/libgtk/theme/Default/gtk.css",
    .dark_resource = null,
    .pin = "Default",
};
const adwaita_base = ThemeBase{
    .resource = "/org/gtk/libgtk/theme/Adwaita/gtk.css",
    .dark_resource = "/org/gtk/libgtk/theme/Adwaita/gtk-dark.css",
    .pin = "Adwaita",
};
/// 28-byte placeholder theme GTK embeds for testing; pinning it makes
/// GTK's theme slot load a no-op stylesheet.
const empty_resource = "/org/gtk/libgtk/theme/Empty/gtk.css";
const empty_pin: [:0]const u8 = "Empty";

/// Above USER: desktops may install system-wide GTK overrides at USER
/// priority (e.g. Pearl's matugen Material palette in ~/.config/gtk-4.0),
/// which would otherwise repaint the built-in theme's surfaces with the
/// desktop's fixed dark palette. System colors load in a provider above it.
const themed_priority = gtk.STYLE_PROVIDER_PRIORITY_USER + 1;

var provider: ?*gtk.CssProvider = null;
var provider_added: bool = false;
var base_resolved: bool = false;
var base: ?ThemeBase = null;
var base_media_driven: bool = true;
var base_provider: ?*gtk.CssProvider = null;
var base_added: bool = false;
var pin_name: ?[:0]const u8 = null;
var headerbar: ?*gtk.HeaderBar = null;
/// Read from the configuration on first apply; a change applies at the next start.
var system_titlebar: ?bool = null;
var watched_window: ?*gtk.Window = null;
var current_mode: ThemeMode = .shelly;
var current_variant: ThemeVariant = .follow_system;
var resolved_dark: bool = true;
var gnome_settings: ?*gio.Settings = null;
var watchers_started: bool = false;
var watch_dummy: c_int = 0;

const desktop_priority = themed_priority + 1;
var desktop_provider: ?*gtk.CssProvider = null;
var desktop_added: bool = false;
/// keys are owned.
var watched_dirs: std.StringHashMapUnmanaged(*gio.FileMonitor) = .empty;
const max_watched_dirs = 16;
/// set while reading the user stylesheets, so their imports get watched.
var user_paths: ?*std.ArrayListUnmanaged([]const u8) = null;
var desktop_refresh_source: c_uint = 0;
var portal_connection: ?*gio.DBusConnection = null;
var portal_accent: ?desktop_palette.Rgb = null;
var portal_dark: ?bool = null;
var portal_high_contrast: bool = false;
var portal_read: bool = false;
var hint_dark: ?bool = null;
var hint_changing: bool = false;
/// read before the pin hides it; later changes come from the portal or
/// gsettings.
var desktop_theme_name: ?[:0]u8 = null;
var desktop_theme_forced: bool = false;
/// set by `GTK_THEME`: gtk then loads `gtk-<variant>.css`, or `gtk.css`,
/// whatever the desktop scheme.
var desktop_theme_variant: ?[]u8 = null;
var desktop_theme_read: bool = false;

/// Reads the persisted configuration and applies it to `win`.
pub fn apply(win: *gtk.Window) void {
    var mode: ThemeMode = .shelly;
    var variant: ThemeVariant = .follow_system;
    if (runtime.config) |svc| {
        if (svc.get()) |cfg| {
            mode = cfg.ThemeMode;
            variant = cfg.ThemeVariant;
        } else |_| {}
    }
    applyWith(win, mode, variant);
}

/// Applies an explicit mode/variant (used by Settings for live preview before
/// the configuration is saved).
pub fn applyWith(win: *gtk.Window, mode: ThemeMode, variant: ThemeVariant) void {
    current_mode = mode;
    current_variant = variant;
    watched_window = win;

    const display = gdk.Display.getDefault() orelse return;
    const widget = win.as(gtk.Widget);
    readDesktopThemeName();
    if (!hasInterfaceColorScheme()) _ = settingsPrefersDark();

    var desktop_css: ?[:0]u8 = null;
    defer if (desktop_css) |css| std.heap.c_allocator.free(css);
    const dark = if (mode == .system) blk: {
        const result = buildDesktopPalette();
        desktop_css = result.css;
        break :blk result.dark orelse systemColorsScheme().dark;
    } else resolveDark(variant);
    resolved_dark = dark;

    resolveBaseTheme();
    applyThemePin();
    if (base != null) {
        const base_prov = ensureBaseProvider();
        loadBaseSheet(base_prov, dark);
        if (!base_added) {
            gtk.StyleContext.addProviderForDisplay(
                display,
                base_prov.as(gtk.StyleProvider),
                gtk.STYLE_PROVIDER_PRIORITY_THEME,
            );
            base_added = true;
        }
    }
    const prov = ensureProvider();
    loadSheet(prov, dark);
    if (!provider_added) {
        gtk.StyleContext.addProviderForDisplay(display, prov.as(gtk.StyleProvider), themed_priority);
        provider_added = true;
    }
    applyDesktopCss(display, desktop_css);
    gtk.Widget.addCssClass(widget, "shelly-root");
    applyCorners(widget);
    applyTitlebar(win);
    setDarkHint(dark);
    ensureWatchers();
    if (mode == .system) ensureDesktopWatchers();
    notifyChanged();
}

fn applyTitlebar(win: *gtk.Window) void {
    const enabled = system_titlebar orelse blk: {
        var value = false;
        if (runtime.config) |svc| {
            if (svc.get()) |cfg| {
                value = cfg.UseSystemTitlebar;
            } else |_| {}
        }
        system_titlebar = value;
        break :blk value;
    };
    // Without a custom titlebar GTK asks the compositor for server-side
    // decorations where it offers them (KDE, Hyprland), so window managers
    // that draw their own bars are not stacked on top of Shelly's. Elsewhere
    // GTK falls back to its default header bar, which follows the desktop's
    // button layout.
    gtk.Window.setTitlebar(win, if (enabled) null else ensureHeaderBar().as(gtk.Widget));
}

/// read on every apply, so the switch works without a restart.
pub fn applyCorners(widget: *gtk.Widget) void {
    var rounded = true;
    if (runtime.config) |svc| {
        if (svc.get()) |cfg| {
            rounded = cfg.RoundedWindowCorners;
        } else |_| {}
    }
    if (rounded) {
        gtk.Widget.removeCssClass(widget, "square-corners");
    } else {
        gtk.Widget.addCssClass(widget, "square-corners");
    }
}

const DesktopResult = struct {
    /// Owned by `std.heap.c_allocator`.
    css: ?[:0]u8,
    dark: ?bool,
};

fn userGtkCssPath(buf: []u8) ?[]const u8 {
    const config_dir = std.mem.span(glib.getUserConfigDir());
    return std.fmt.bufPrint(buf, "{s}/gtk-4.0/gtk.css", .{config_dir}) catch null;
}

fn readFile(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const path_z = arena.dupeSentinel(u8, path, 0) catch return null;
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    if (glib.fileGetContents(path_z, &contents, &len, null) == 0) return null;
    defer glib.free(contents);
    return arena.dupe(u8, contents[0..len]) catch null;
}

fn pathExists(arena: std.mem.Allocator, path: []const u8) bool {
    const path_z = arena.dupeSentinel(u8, path, 0) catch return false;
    return glib.fileTest(path_z, .{ .exists = true }) != 0;
}

/// runs before the first `applyThemePin`; a non-empty `GTK_THEME` wins, as in
/// gtk.
fn readDesktopThemeName() void {
    if (desktop_theme_read) return;
    desktop_theme_read = true;
    var name: []const u8 = "";
    var value = std.mem.zeroes(gobject.Value);
    _ = value.init(gobject.typeFromName("gchararray"));
    defer value.unset();
    if (std.c.getenv("GTK_THEME")) |env| {
        const forced = desktop_palette.splitThemeVariable(std.mem.span(env));
        if (forced.name.len > 0) {
            name = forced.name;
            desktop_theme_forced = true;
            desktop_theme_variant = std.heap.c_allocator.dupe(u8, forced.variant) catch null;
        }
    }
    if (name.len == 0) {
        if (gtk.Settings.getDefault()) |gtk_settings| {
            gtk_settings.as(gobject.Object).getProperty("gtk-theme-name", &value);
            if (value.getString()) |current| name = std.mem.span(current);
        }
    }
    if (name.len == 0) return;
    desktop_theme_name = std.heap.c_allocator.dupeSentinel(u8, name, 0) catch null;
}

fn setDesktopThemeName(name: []const u8) void {
    if (desktop_theme_forced) return;
    if (desktop_theme_name) |current| {
        if (std.mem.eql(u8, current, name)) return;
        std.heap.c_allocator.free(current);
    }
    desktop_theme_name = if (name.len == 0) null else std.heap.c_allocator.dupeSentinel(u8, name, 0) catch null;
    scheduleDesktopRefresh();
}

fn onGnomeThemeChanged(settings: *gio.Settings, _: [*:0]const u8, _: *c_int) callconv(.c) void {
    const theme = settings.getString("gtk-theme");
    defer glib.free(theme);
    setDesktopThemeName(std.mem.span(theme));
}

fn desktopScheme() desktop_palette.Scheme {
    const dark = systemPrefersDark();
    return .{ .dark = dark, .high_contrast = portal_high_contrast };
}

/// a `GTK_THEME` variant decides both for the theme, as in gtk.
fn systemColorsScheme() desktop_palette.Scheme {
    // the accent comes from the portal even when `GTK_THEME` decides the rest.
    readPortal();
    if (desktop_theme_variant) |variant| return .{
        .dark = std.mem.indexOf(u8, variant, "dark") != null,
        .high_contrast = std.mem.indexOf(u8, variant, "hc") != null,
    };
    return desktopScheme();
}

/// the file gtk would load, or null for its built-in themes. like gtk, a
/// missing `gtk-dark.css` does not fall back to `gtk.css`.
fn desktopThemeFile(arena: std.mem.Allocator, scheme: desktop_palette.Scheme) ?[]const u8 {
    const name = desktop_theme_name orelse return null;
    const resource = std.fmt.allocPrintSentinel(arena, "/org/gtk/libgtk/theme/{s}/gtk.css", .{name}, 0) catch return null;
    if (resourceExists(resource)) return null;
    // gtk's order: user data, ~/.themes, then the system data dirs.
    var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    const user_dir = std.fs.path.join(arena, &.{ std.mem.span(glib.getUserDataDir()), "themes" }) catch return null;
    const home_dir = std.fs.path.join(arena, &.{ std.mem.span(glib.getHomeDir()), ".themes" }) catch return null;
    dirs.appendSlice(arena, &.{ user_dir, home_dir }) catch return null;
    const system_dirs: [*:null]const ?[*:0]const u8 = @ptrCast(glib.getSystemDataDirs());
    var i: usize = 0;
    while (system_dirs[i]) |dir| : (i += 1) {
        const themes = std.fs.path.join(arena, &.{ std.mem.span(dir), "themes" }) catch return null;
        dirs.append(arena, themes) catch return null;
    }
    const variant: []const u8 = desktop_theme_variant orelse
        if (scheme.high_contrast) (if (scheme.dark) "hc-dark" else "hc") else if (scheme.dark) "dark" else "";
    const file = if (variant.len == 0) "gtk.css" else std.fmt.allocPrint(arena, "gtk-{s}.css", .{variant}) catch return null;
    return desktop_palette.findThemeFile(arena, dirs.items, name, file, gtk.getMinorVersion(), &pathExists) catch null;
}

fn readUserFile(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const text = readFile(arena, path) orelse return null;
    if (user_paths) |list| list.append(arena, path) catch {};
    return text;
}

fn watchDir(dir: []const u8) void {
    if (watched_dirs.contains(dir) or watched_dirs.count() >= max_watched_dirs) return;
    const dir_z = std.heap.c_allocator.dupeSentinel(u8, dir, 0) catch return;
    const file = gio.File.newForPath(dir_z.ptr);
    defer file.as(gobject.Object).unref();
    var err: ?*glib.Error = null;
    const monitor = gio.File.monitorDirectory(file, .{}, null, &err);
    if (err) |e| glib.Error.free(e);
    const created = monitor orelse {
        std.heap.c_allocator.free(dir_z);
        return;
    };
    watched_dirs.put(std.heap.c_allocator, dir_z, created) catch {
        created.as(gobject.Object).unref();
        std.heap.c_allocator.free(dir_z);
        return;
    };
    _ = gio.FileMonitor.signals.changed.connect(created, *c_int, &onDesktopFilesChanged, &watch_dummy, .{});
}

/// imports can live outside `gtk-4.0` (pywal uses `~/.cache/wal`), and a
/// symlink changes where its target lives.
fn watchUserFiles(arena: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| {
        if (std.fs.path.dirname(path)) |dir| watchDir(dir);
        const path_z = arena.dupeSentinel(u8, path, 0) catch continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.c.realpath(path_z, &buf)) |real| {
            if (std.fs.path.dirname(std.mem.span(real))) |dir| watchDir(dir);
        }
    }
}

fn buildDesktopPalette() DesktopResult {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const scheme = systemColorsScheme();
    // like gtk, a `GTK_THEME` variant does not reach the user stylesheet.
    const user_scheme = if (desktop_theme_variant != null) desktopScheme() else scheme;
    // the theme first, so user colors override it, as in gtk.
    var defines: desktop_palette.Defines = .empty;
    if (desktopThemeFile(arena, scheme)) |path| {
        desktop_palette.collectFile(arena, &defines, path, &readFile, scheme, 0) catch {};
    }
    var user_defines: desktop_palette.Defines = .empty;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var read_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    if (userGtkCssPath(&path_buf)) |path| {
        user_paths = &read_paths;
        defer user_paths = null;
        desktop_palette.collectFile(arena, &user_defines, path, &readUserFile, user_scheme, 0) catch {};
    }
    watchUserFiles(arena, read_paths.items);
    var it = user_defines.iterator();
    while (it.next()) |entry| defines.put(arena, entry.key_ptr.*, entry.value_ptr.*) catch {};

    var rejection: desktop_palette.Rejection = .none;
    const palette = desktop_palette.build(arena, &defines, &user_defines, portal_accent, scheme.dark, &rejection) catch {
        return .{ .css = null, .dark = null };
    };
    switch (rejection) {
        .none => {},
        .missing => std.log.info("System colors: the desktop GTK 4 stylesheet defines no background and text colors; using the Shelly palette.", .{}),
        .low_contrast => std.log.warn("System colors: the desktop text and background colors are too close to read; using the Shelly palette.", .{}),
    }
    if (palette.css.len == 0) return .{ .css = null, .dark = palette.dark };
    const css = std.heap.c_allocator.dupeSentinel(u8, palette.css, 0) catch return .{ .css = null, .dark = palette.dark };
    return .{ .css = css, .dark = palette.dark };
}

fn applyDesktopCss(display: *gdk.Display, css: ?[:0]u8) void {
    if (css) |text| {
        const prov = desktop_provider orelse blk: {
            const created = gtk.CssProvider.new();
            desktop_provider = created;
            break :blk created;
        };
        gtk.CssProvider.loadFromString(prov, text.ptr);
        if (!desktop_added) {
            gtk.StyleContext.addProviderForDisplay(display, prov.as(gtk.StyleProvider), desktop_priority);
            desktop_added = true;
        }
    } else if (desktop_added) {
        gtk.StyleContext.removeProviderForDisplay(display, desktop_provider.?.as(gtk.StyleProvider));
        desktop_added = false;
    }
}

fn portalBus() ?*gio.DBusConnection {
    if (portal_connection) |conn| return conn;
    var err: ?*glib.Error = null;
    const conn = gio.busGetSync(.session, null, &err);
    if (err) |e| {
        glib.Error.free(e);
        return null;
    }
    portal_connection = conn;
    return conn;
}

fn portalReadAllParams() *glib.Variant {
    const namespaces = [_:null]?[*:0]const u8{"org.freedesktop.appearance"};
    return glib.Variant.new("(^as)", &namespaces);
}

/// Reads the portal accent, color scheme, and contrast once, waiting at most
/// 250 ms; a failed read retries in the background. Later changes arrive
/// through SettingChanged.
fn readPortal() void {
    if (portal_read) return;
    portal_read = true;
    const conn = portalBus() orelse return;
    const reply_type = glib.VariantType.new("(a{sa{sv}})");
    defer reply_type.free();
    var err: ?*glib.Error = null;
    const result = conn.callSync(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.Settings",
        "ReadAll",
        portalReadAllParams(),
        reply_type,
        .{},
        250,
        null,
        &err,
    );
    if (err) |e| {
        glib.Error.free(e);
        // a portal that is still starting answers later.
        conn.call(
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.Settings",
            "ReadAll",
            portalReadAllParams(),
            reply_type,
            .{},
            -1,
            null,
            &onPortalReadAll,
            null,
        );
        return;
    }
    const res = result orelse return;
    defer res.unref();
    applyPortalReply(res);
}

fn onPortalReadAll(source: ?*gobject.Object, res: *gio.AsyncResult, _: ?*anyopaque) callconv(.c) void {
    const conn: *gio.DBusConnection = @ptrCast(source orelse return);
    var err: ?*glib.Error = null;
    const reply = conn.callFinish(res, &err);
    if (err) |e| {
        glib.Error.free(e);
        return;
    }
    const value = reply orelse return;
    defer value.unref();
    applyPortalReply(value);
    scheduleDesktopRefresh();
}

fn applyPortalReply(res: *glib.Variant) void {
    const all = res.getChildValue(0);
    defer all.unref();
    for (0..all.nChildren()) |idx| {
        const entry = all.getChildValue(idx);
        defer entry.unref();
        const name = entry.getChildValue(0);
        defer name.unref();
        if (!std.mem.eql(u8, std.mem.span(name.getString(null)), "org.freedesktop.appearance")) continue;
        const settings = entry.getChildValue(1);
        defer settings.unref();
        const vd = glib.VariantDict.new(settings);
        defer vd.unref();
        if (vd.lookupValue("accent-color", null)) |value| {
            defer value.unref();
            portal_accent = accentFromVariant(value);
        }
        if (vd.lookupValue("color-scheme", null)) |value| {
            defer value.unref();
            portal_dark = schemeFromVariant(value);
        }
        if (vd.lookupValue("contrast", null)) |value| {
            defer value.unref();
            portal_high_contrast = contrastFromVariant(value);
        }
    }
}

/// The portal sends 1 for dark, 2 for light, and 0 for no preference.
fn schemeFromVariant(value: *glib.Variant) ?bool {
    if (!std.mem.eql(u8, std.mem.span(value.getTypeString()), "u")) return null;
    return switch (value.getUint32()) {
        1 => true,
        2 => false,
        else => null,
    };
}

/// the portal sends 1 for higher contrast and 0 for no preference.
fn contrastFromVariant(value: *glib.Variant) bool {
    if (!std.mem.eql(u8, std.mem.span(value.getTypeString()), "u")) return false;
    return value.getUint32() == 1;
}

/// The portal sends `(ddd)` in 0..1; values outside that range mean unset.
fn accentFromVariant(value: *glib.Variant) ?desktop_palette.Rgb {
    if (!std.mem.eql(u8, std.mem.span(value.getTypeString()), "(ddd)")) return null;
    var channels: [3]f64 = undefined;
    for (&channels, 0..) |*ch, idx| {
        const child = value.getChildValue(idx);
        defer child.unref();
        ch.* = child.getDouble();
        if (ch.* < 0 or ch.* > 1) return null;
    }
    return .{ .r = channels[0], .g = channels[1], .b = channels[2] };
}

/// Watches the folder because Plasma rewrites `colors.css`.
fn ensureDesktopWatchers() void {
    {
        const config_dir = std.mem.span(glib.getUserConfigDir());
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/gtk-4.0", .{config_dir})) |dir| watchDir(dir) else |_| {}
    }
    if (portal_connection == null) _ = portalBus();
    if (portal_connection) |conn| {
        const subscribed = struct {
            var done = false;
        };
        if (!subscribed.done) {
            subscribed.done = true;
            _ = conn.signalSubscribe(
                "org.freedesktop.portal.Desktop",
                "org.freedesktop.portal.Settings",
                "SettingChanged",
                "/org/freedesktop/portal/desktop",
                null,
                .{},
                &onPortalSettingChanged,
                null,
                null,
            );
        }
    }
}

fn onDesktopFilesChanged(_: *gio.FileMonitor, _: *gio.File, _: ?*gio.File, _: gio.FileMonitorEvent, _: *c_int) callconv(.c) void {
    scheduleDesktopRefresh();
}

fn onPortalSettingChanged(
    _: *gio.DBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    params: *glib.Variant,
    _: ?*anyopaque,
) callconv(.c) void {
    if (!std.mem.eql(u8, std.mem.span(params.getTypeString()), "(ssv)")) return;
    const namespace = params.getChildValue(0);
    defer namespace.unref();
    const ns = std.mem.span(namespace.getString(null));
    const key = params.getChildValue(1);
    defer key.unref();
    const name = std.mem.span(key.getString(null));
    // gtk reads the theme name from this namespace on wayland.
    if (std.mem.eql(u8, ns, "org.gnome.desktop.interface")) {
        if (!std.mem.eql(u8, name, "gtk-theme")) return;
        const boxed = params.getChildValue(2);
        defer boxed.unref();
        const value = boxed.getVariant();
        defer value.unref();
        if (std.mem.eql(u8, std.mem.span(value.getTypeString()), "s")) setDesktopThemeName(std.mem.span(value.getString(null)));
        return;
    }
    if (!std.mem.eql(u8, ns, "org.freedesktop.appearance")) return;
    const is_accent = std.mem.eql(u8, name, "accent-color");
    const is_scheme = std.mem.eql(u8, name, "color-scheme");
    if (!is_accent and !is_scheme and !std.mem.eql(u8, name, "contrast")) return;
    readPortal();
    const boxed = params.getChildValue(2);
    defer boxed.unref();
    const value = boxed.getVariant();
    defer value.unref();
    if (is_accent) {
        portal_accent = accentFromVariant(value);
    } else if (is_scheme) {
        portal_dark = schemeFromVariant(value);
    } else {
        portal_high_contrast = contrastFromVariant(value);
    }
    scheduleDesktopRefresh();
}

/// Palette tools write several files at once.
fn scheduleDesktopRefresh() void {
    if (desktop_refresh_source != 0) return;
    desktop_refresh_source = glib.timeoutAdd(100, &onDesktopRefresh, null);
}

/// reloads only the desktop colors unless dark or light flips.
fn onDesktopRefresh(_: ?*anyopaque) callconv(.c) c_int {
    desktop_refresh_source = 0;
    if (current_mode != .system) return 0;
    const win = watched_window orelse return 0;
    const display = gdk.Display.getDefault() orelse return 0;
    const result = buildDesktopPalette();
    defer if (result.css) |css| std.heap.c_allocator.free(css);
    const dark = result.dark orelse systemColorsScheme().dark;
    if (!provider_added or dark != resolved_dark) {
        applyWith(win, current_mode, current_variant);
        return 0;
    }
    applyDesktopCss(display, result.css);
    notifyChanged();
    return 0;
}

fn ensureProvider() *gtk.CssProvider {
    if (provider) |prov| return prov;
    const prov = gtk.CssProvider.new();
    provider = prov;
    return prov;
}

fn resourceExists(path: [:0]const u8) bool {
    return gio.resourcesGetInfo(path, .{}, null, null, null) != 0;
}

/// Picks the embedded base theme and the name to pin `gtk-theme-name` to.
/// Runs once; GTK's resource set does not change during a session.
fn resolveBaseTheme() void {
    if (base_resolved) return;
    base_resolved = true;

    if (resourceExists(default_base.resource)) {
        base = default_base;
        base_media_driven = true;
    } else if (resourceExists(adwaita_base.resource)) {
        base = adwaita_base;
        // Adwaita moved light/dark selection into a `prefers-color-scheme`
        // media block in GTK 4.16; older builds keep separate light and dark
        // stylesheets that must be swapped explicitly on variant changes.
        const major = gtk.getMajorVersion();
        const minor = gtk.getMinorVersion();
        base_media_driven = major > 4 or (major == 4 and minor >= 16);
    } else {
        base = null;
        base_media_driven = true;
    }

    if (base) |chosen| {
        // The blank embedded theme empties GTK's own theme slot entirely.
        // Without it, pin the same base we load ourselves: GTK then resolves
        // that name (possibly to a user-overlaid copy), but this provider is
        // added after GTK's theme provider at the same priority and still
        // wins every conflict.
        pin_name = if (resourceExists(empty_resource)) empty_pin else chosen.pin;
    } else {
        pin_name = null;
        std.log.warn(
            "Could not find a built-in base theme inside the GTK resources. The built-in theme may pick up colors from the desktop GTK theme.",
            .{},
        );
    }
}

fn ensureBaseProvider() *gtk.CssProvider {
    if (base_provider) |prov| return prov;
    const prov = gtk.CssProvider.new();
    base_provider = prov;
    return prov;
}

fn loadBaseSheet(prov: *gtk.CssProvider, dark: bool) void {
    const chosen = base orelse return;
    if (!base_media_driven and dark) {
        if (chosen.dark_resource) |base_dark_resource| {
            gtk.CssProvider.loadFromResource(prov, base_dark_resource);
            return;
        }
    }
    gtk.CssProvider.loadFromResource(prov, chosen.resource);
}

fn themeNameIs(name: [*:0]const u8) bool {
    const gtk_settings = gtk.Settings.getDefault() orelse return false;
    var value = std.mem.zeroes(gobject.Value);
    _ = value.init(gobject.typeFromName("gchararray"));
    // The GValue owns a strdup'd copy of the property string.
    defer value.unset();
    gtk_settings.as(gobject.Object).getProperty("gtk-theme-name", &value);
    const current = value.getString() orelse return false;
    return std.mem.eql(u8, std.mem.span(current), std.mem.span(name));
}

fn setThemeName(name: [*:0]const u8) void {
    const gtk_settings = gtk.Settings.getDefault() orelse return;
    var value = std.mem.zeroes(gobject.Value);
    _ = value.init(gobject.typeFromName("gchararray"));
    defer value.unset();
    value.setString(name);
    gtk_settings.as(gobject.Object).setProperty("gtk-theme-name", &value);
}

/// Points `gtk-theme-name` at the embedded blank theme while the built-in
/// theme is active. Once set by the application GtkSettings shields the
/// property from further settings-backend pushes, which keeps the pin stable
/// when the desktop re-applies its theme.
fn applyThemePin() void {
    const pin = pin_name orelse return;
    if (themeNameIs(pin)) return;
    setThemeName(pin);
}

fn loadSheet(prov: *gtk.CssProvider, dark: bool) void {
    gtk.CssProvider.loadFromResource(prov, if (dark) dark_resource else light_resource);
}

fn ensureHeaderBar() *gtk.HeaderBar {
    if (headerbar) |bar| return bar;
    const bar = gtk.HeaderBar.new();
    // Keep a ref: each theme apply calls setTitlebar, which drops the
    // window's ref to the current titlebar first.
    _ = bar.as(gobject.Object).ref();
    gtk.Widget.addCssClass(bar.as(gtk.Widget), "shelly-headerbar");

    const brand = gtk.Box.new(.horizontal, 8);
    gtk.Widget.addCssClass(brand.as(gtk.Widget), "shelly-brand");
    // Pack at start (not setTitleWidget, which GtkHeaderBar centers) so the
    // brand sits left like Pearl's titlebar; valign keeps the dot circular
    // instead of stretching to the headerbar height.
    gtk.Widget.setHexpand(brand.as(gtk.Widget), 1);
    gtk.Widget.setHalign(brand.as(gtk.Widget), .start);
    gtk.Widget.setValign(brand.as(gtk.Widget), .center);
    const dot = gtk.Box.new(.horizontal, 0);
    gtk.Widget.addCssClass(dot.as(gtk.Widget), "shelly-brand-dot");
    gtk.Widget.setSizeRequest(dot.as(gtk.Widget), 15, 15);
    gtk.Widget.setValign(dot.as(gtk.Widget), .center);
    gtk.Box.append(brand, dot.as(gtk.Widget));
    const label = gtk.Label.new(translations._("Shelly"));
    gtk.Widget.addCssClass(label.as(gtk.Widget), "shelly-brand-label");
    gtk.Box.append(brand, label.as(gtk.Widget));

    gtk.HeaderBar.packStart(bar, brand.as(gtk.Widget));
    // Without a title widget GtkHeaderBar falls back to rendering the window
    // title centered; an empty widget suppresses it so the start-packed brand
    // is the only title.
    const title_spacer = gtk.Box.new(.horizontal, 0);
    gtk.HeaderBar.setTitleWidget(bar, title_spacer.as(gtk.Widget));
    // Keep the native window controls: WM behavior and accessibility come for
    // free; the themed sheet paints them as circles. Pin the layout so the
    // mockup's three buttons show even when the desktop layout hides them.
    gtk.HeaderBar.setShowTitleButtons(bar, 1);
    gtk.HeaderBar.setDecorationLayout(bar, ":minimize,maximize,close");
    headerbar = bar;
    return bar;
}

fn resolveDark(variant: ThemeVariant) bool {
    return switch (variant) {
        .dark => true,
        .light => false,
        .follow_system => desktopPrefersDark(),
    };
}

/// GTK >= 4.23 exposes the portal-driven system preference as
/// GtkSettings:gtk-interface-color-scheme; older GTK needs legacy sources.
fn hasInterfaceColorScheme() bool {
    const major = gtk.getMajorVersion();
    return major > 4 or (major == 4 and gtk.getMinorVersion() >= 23);
}

fn desktopPrefersDark() bool {
    if (hasInterfaceColorScheme()) {
        if (gtk.Settings.getDefault()) |settings| {
            var value = std.mem.zeroes(gobject.Value);
            _ = value.init(gobject.typeFromName("GtkInterfaceColorScheme"));
            settings.as(gobject.Object).getProperty("gtk-interface-color-scheme", &value);
            const scheme = value.getEnum();
            if (scheme == @backingInt(gtk.InterfaceColorScheme.dark)) return true;
            if (scheme == @backingInt(gtk.InterfaceColorScheme.light)) return false;
        }
    }
    return legacyPrefersDark();
}

/// System colors pin the scheme too, so read the desktop value from the
/// portal instead of gtk-interface-color-scheme.
fn systemPrefersDark() bool {
    readPortal();
    return portal_dark orelse legacyPrefersDark();
}

/// gnome's `default` means no preference, so a `settings.ini` prefer-dark
/// (wayfire and similar) still applies.
fn legacyPrefersDark() bool {
    if (gnomeInterfaceSettings()) |settings| {
        const scheme = settings.getString("color-scheme");
        defer glib.free(scheme);
        const value = std.mem.span(scheme);
        if (std.mem.eql(u8, value, "prefer-dark")) return true;
        if (std.mem.eql(u8, value, "prefer-light")) return false;
    }
    return settingsPrefersDark();
}

/// before gtk 4.23 `setDarkHint` writes this property, so the desktop value
/// is kept from before the first write.
var settings_prefer_dark: ?bool = null;

fn settingsPrefersDark() bool {
    if (settings_prefer_dark) |cached| return cached;
    const gtk_settings = gtk.Settings.getDefault() orelse return true;
    var value = std.mem.zeroes(gobject.Value);
    _ = value.init(gobject.typeFromName("gboolean"));
    gtk_settings.as(gobject.Object).getProperty("gtk-application-prefer-dark-theme", &value);
    const dark = value.getBoolean() != 0;
    if (!hasInterfaceColorScheme()) settings_prefer_dark = dark;
    return dark;
}

/// Returns the GNOME interface settings only when the schema is installed;
/// `gio.Settings.new` aborts on missing schemas.
fn gnomeInterfaceSettings() ?*gio.Settings {
    if (gnome_settings) |settings| return settings;
    const source = gio.SettingsSchemaSource.getDefault() orelse return null;
    const schema = source.lookup("org.gnome.desktop.interface", 1) orelse return null;
    schema.unref();
    const settings = gio.Settings.new("org.gnome.desktop.interface");
    gnome_settings = settings;
    return settings;
}

fn setDarkHint(dark: bool) void {
    if (hint_dark == dark) return;
    const gtk_settings = gtk.Settings.getDefault() orelse return;
    const obj = gtk_settings.as(gobject.Object);
    hint_dark = dark;
    // GTK notifies on every set; ignore our own notify.
    hint_changing = true;
    defer hint_changing = false;
    if (hasInterfaceColorScheme()) {
        var value = std.mem.zeroes(gobject.Value);
        _ = value.init(gobject.typeFromName("GtkInterfaceColorScheme"));
        value.setEnum(@backingInt(if (dark) gtk.InterfaceColorScheme.dark else gtk.InterfaceColorScheme.light));
        obj.setProperty("gtk-interface-color-scheme", &value);
        return;
    }
    var value = std.mem.zeroes(gobject.Value);
    _ = value.init(gobject.typeFromName("gboolean"));
    value.setBoolean(@intFromBool(dark));
    obj.setProperty("gtk-application-prefer-dark-theme", &value);
}

fn ensureWatchers() void {
    if (watchers_started) return;
    watchers_started = true;
    if (gnomeInterfaceSettings()) |settings| {
        _ = gio.Settings.signals.changed.connect(
            settings,
            *c_int,
            &onGnomeSchemeChanged,
            &watch_dummy,
            .{ .detail = "color-scheme" },
        );
        _ = gio.Settings.signals.changed.connect(
            settings,
            *c_int,
            &onGnomeThemeChanged,
            &watch_dummy,
            .{ .detail = "gtk-theme" },
        );
    }
    if (gtk.Settings.getDefault()) |gtk_settings| {
        _ = gobject.Object.signals.notify.connect(
            gtk_settings.as(gobject.Object),
            *c_int,
            &onPreferDarkNotify,
            &watch_dummy,
            .{ .detail = if (hasInterfaceColorScheme()) "gtk-interface-color-scheme" else "gtk-application-prefer-dark-theme" },
        );
        _ = gobject.Object.signals.notify.connect(
            gtk_settings.as(gobject.Object),
            *c_int,
            &onThemeNameNotify,
            &watch_dummy,
            .{ .detail = "gtk-theme-name" },
        );
    }
}

fn onGnomeSchemeChanged(_: *gio.Settings, _: [*:0]const u8, _: *c_int) callconv(.c) void {
    refreshFollowSystem();
}

fn onPreferDarkNotify(_: *gobject.Object, _: *gobject.ParamSpec, _: *c_int) callconv(.c) void {
    if (hint_changing) return;
    refreshFollowSystem();
}

/// Desktop theme changes arrive as `gtk-theme-name` updates. Settings
/// backends stop pushing once the application has set the property, but
/// other channels (e.g. xsettings broadcasts) may still deliver updates
/// while the built-in theme is active; re-assert the pin for those.
fn onThemeNameNotify(_: *gobject.Object, _: *gobject.ParamSpec, _: *c_int) callconv(.c) void {
    applyThemePin();
}

fn refreshFollowSystem() void {
    if (current_mode == .system) {
        scheduleDesktopRefresh();
        return;
    }
    if (current_variant != .follow_system) return;
    if (watched_window == null) return;
    const dark = desktopPrefersDark();
    if (dark == resolved_dark) return;
    resolved_dark = dark;
    loadSheet(ensureProvider(), dark);
    if (base_added) loadBaseSheet(base_provider.?, dark);
    notifyChanged();
}

const ChangeHook = struct {
    func: *const fn (?*anyopaque) void,
    data: ?*anyopaque,
};

var change_hooks: std.ArrayListUnmanaged(ChangeHook) = .empty;

/// Calls `func(data)` after each palette change, so colors copied out of
/// CSS with `roleColor` can be refreshed.
pub fn addChangeHook(func: *const fn (?*anyopaque) void, data: ?*anyopaque) void {
    change_hooks.append(std.heap.c_allocator, .{ .func = func, .data = data }) catch {};
}

pub fn removeChangeHook(func: *const fn (?*anyopaque) void, data: ?*anyopaque) void {
    for (change_hooks.items, 0..) |hook, index| {
        if (hook.func == func and hook.data == data) {
            _ = change_hooks.swapRemove(index);
            return;
        }
    }
}

fn notifyChanged() void {
    for (change_hooks.items) |hook| hook.func(hook.data);
}

pub const Role = enum { text, muted, accent, success, warning, @"error", surface };

/// Hex color for `role`, for Pango markup and text tags, which cannot use
/// CSS colors.
pub fn roleColor(widget: *gtk.Widget, role: Role, buf: *[8]u8) [:0]const u8 {
    const class: [:0]const u8 = switch (role) {
        .text => "role-text",
        .muted => "role-muted",
        .accent => "role-accent",
        .success => "status-success",
        .warning => "status-warning",
        .@"error" => "status-error",
        .surface => "role-surface",
    };
    const had_class = gtk.Widget.hasCssClass(widget, class) != 0;
    if (!had_class) gtk.Widget.addCssClass(widget, class);
    var rgba: gdk.RGBA = undefined;
    gtk.Widget.getColor(widget, &rgba);
    if (!had_class) gtk.Widget.removeCssClass(widget, class);
    return std.fmt.bufPrintSentinel(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ channel(rgba.f_red), channel(rgba.f_green), channel(rgba.f_blue) }, 0) catch "#808080";
}

/// Text tag in `view`'s buffer colored with `role`. Unlike a color baked
/// into markup, it is recolored after each palette change while `view`
/// lives.
pub fn roleTag(view: *gtk.TextView, role: Role) *gtk.TextTag {
    const buffer = gtk.TextView.getBuffer(view);
    const table = gtk.TextBuffer.getTagTable(buffer);
    if (gtk.TextTagTable.lookup(table, roleTagName(role))) |tag| return tag;
    if (!hasRoleTags(table)) {
        addChangeHook(&refreshRoleTags, view);
        _ = gtk.Widget.signals.destroy.connect(view.as(gtk.Widget), *gtk.TextView, &onRoleTagViewDestroy, view, .{});
    }
    const tag = gtk.TextBuffer.createTag(buffer, roleTagName(role), null);
    colorRoleTag(view, tag, role);
    return tag;
}

/// Applies `roleTag` from `start_offset` to `end`.
pub fn applyRoleTag(view: *gtk.TextView, role: Role, start_offset: c_int, end: *const gtk.TextIter) void {
    const buffer = gtk.TextView.getBuffer(view);
    var start: gtk.TextIter = undefined;
    gtk.TextBuffer.getIterAtOffset(buffer, &start, start_offset);
    gtk.TextBuffer.applyTag(buffer, roleTag(view, role), &start, end);
}

fn roleTagName(role: Role) [:0]const u8 {
    return switch (role) {
        inline else => |tag| "shelly-role-" ++ @tagName(tag),
    };
}

fn hasRoleTags(table: *gtk.TextTagTable) bool {
    inline for (@typeInfo(Role).@"enum".field_names) |name| {
        if (gtk.TextTagTable.lookup(table, "shelly-role-" ++ name) != null) return true;
    }
    return false;
}

fn colorRoleTag(view: *gtk.TextView, tag: *gtk.TextTag, role: Role) void {
    var hex: [8]u8 = undefined;
    var value = gobject.ext.Value.newFrom(@as(?[*:0]const u8, roleColor(view.as(gtk.Widget), role, &hex).ptr));
    defer value.unset();
    gobject.Object.setProperty(tag.as(gobject.Object), "foreground", &value);
}

fn refreshRoleTags(data: ?*anyopaque) void {
    const view: *gtk.TextView = @ptrCast(@alignCast(data.?));
    const table = gtk.TextBuffer.getTagTable(gtk.TextView.getBuffer(view));
    inline for (@typeInfo(Role).@"enum".field_names) |name| {
        if (gtk.TextTagTable.lookup(table, "shelly-role-" ++ name)) |tag| {
            colorRoleTag(view, tag, @field(Role, name));
        }
    }
}

fn onRoleTagViewDestroy(_: *gtk.Widget, view: *gtk.TextView) callconv(.c) void {
    removeChangeHook(&refreshRoleTags, view);
}

fn channel(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

test "role tags color text and drop their theme hook with the view" {
    try @import("../helpers/gtk_test.zig").requireDisplay();
    const hooks_before = change_hooks.items.len;
    const view = gtk.TextView.new();
    _ = view.as(gobject.Object).refSink();
    const buffer = gtk.TextView.getBuffer(view);
    var iter: gtk.TextIter = undefined;
    gtk.TextBuffer.getEndIter(buffer, &iter);
    gtk.TextBuffer.insert(buffer, &iter, "warning", -1);
    applyRoleTag(view, .warning, 0, &iter);
    applyRoleTag(view, .@"error", 0, &iter);

    const table = gtk.TextBuffer.getTagTable(buffer);
    const tag = gtk.TextTagTable.lookup(table, "shelly-role-warning").?;
    var start: gtk.TextIter = undefined;
    gtk.TextBuffer.getStartIter(buffer, &start);
    try std.testing.expect(gtk.TextIter.hasTag(&start, tag) != 0);
    // One hook per view, however many roles it uses.
    try std.testing.expectEqual(hooks_before + 1, change_hooks.items.len);

    refreshRoleTags(view);
    gtk.Widget.unrealize(view.as(gtk.Widget));
    view.as(gobject.Object).runDispose();
    try std.testing.expectEqual(hooks_before, change_hooks.items.len);
    view.as(gobject.Object).unref();
}
