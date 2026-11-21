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
pub const OperationLogFontSize = config_model.OperationLogFontSize;

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
var watched_window: ?*gtk.Window = null;
var current_mode: ThemeMode = .shelly;
var current_variant: ThemeVariant = .follow_system;
var resolved_dark: bool = true;
var gnome_settings: ?*gio.Settings = null;
var watchers_started: bool = false;
var watch_dummy: c_int = 0;

const desktop_priority = themed_priority + 1;
const operation_log_font_size_priority = desktop_priority + 1;
var desktop_provider: ?*gtk.CssProvider = null;
var desktop_added: bool = false;
var operation_log_font_size_provider: ?*gtk.CssProvider = null;
var operation_log_font_size_provider_added: bool = false;
var desktop_monitor: ?*gio.FileMonitor = null;
var desktop_refresh_source: c_uint = 0;
var portal_connection: ?*gio.DBusConnection = null;
var portal_accent: ?desktop_palette.Rgb = null;
var portal_dark: ?bool = null;
var portal_read: bool = false;
var hint_dark: ?bool = null;
var hint_changing: bool = false;

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

pub fn applyOperationLogFontSize(display: *gdk.Display, size: OperationLogFontSize) void {
    const prov = operation_log_font_size_provider orelse blk: {
        const created = gtk.CssProvider.new();
        operation_log_font_size_provider = created;
        break :blk created;
    };
    const css = switch (size) {
        .px_14 => ".shelly-root .terminal-output { font-size: 14px; }",
        .px_16 => ".shelly-root .terminal-output { font-size: 16px; }",
        .px_18 => ".shelly-root .terminal-output { font-size: 18px; }",
        .px_20 => ".shelly-root .terminal-output { font-size: 20px; }",
        .px_24 => ".shelly-root .terminal-output { font-size: 24px; }",
    };
    gtk.CssProvider.loadFromString(prov, css.ptr);
    if (!operation_log_font_size_provider_added) {
        gtk.StyleContext.addProviderForDisplay(display, prov.as(gtk.StyleProvider), operation_log_font_size_priority);
        operation_log_font_size_provider_added = true;
    }
}

/// Applies an explicit mode/variant (used by Settings for live preview before
/// the configuration is saved).
pub fn applyWith(win: *gtk.Window, mode: ThemeMode, variant: ThemeVariant) void {
    current_mode = mode;
    current_variant = variant;
    watched_window = win;

    const display = gdk.Display.getDefault() orelse return;
    const widget = win.as(gtk.Widget);

    var desktop_css: ?[:0]u8 = null;
    defer if (desktop_css) |css| std.heap.c_allocator.free(css);
    const dark = if (mode == .system) blk: {
        const result = buildDesktopPalette();
        desktop_css = result.css;
        break :blk result.dark orelse systemPrefersDark();
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
    gtk.Window.setTitlebar(win, ensureHeaderBar().as(gtk.Widget));
    setDarkHint(dark);
    ensureWatchers();
    if (mode == .system) ensureDesktopWatchers();
    notifyChanged();
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

fn buildDesktopPalette() DesktopResult {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var defines: desktop_palette.Defines = .empty;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (userGtkCssPath(&path_buf)) |path| {
        desktop_palette.collectFile(arena, &defines, path, &readFile, 0) catch {};
    }

    var rejection: desktop_palette.Rejection = .none;
    const prefers_dark = systemPrefersDark();
    const palette = desktop_palette.build(arena, &defines, portal_accent, prefers_dark, &rejection) catch {
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

/// Reads the portal accent and color scheme once; later changes arrive
/// through SettingChanged.
fn readPortal() void {
    if (portal_read) return;
    portal_read = true;
    const conn = portalBus() orelse return;
    const namespaces = [_:null]?[*:0]const u8{"org.freedesktop.appearance"};
    const params = glib.Variant.new("(^as)", &namespaces);
    const reply_type = glib.VariantType.new("(a{sa{sv}})");
    defer reply_type.free();
    var err: ?*glib.Error = null;
    const result = conn.callSync(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.Settings",
        "ReadAll",
        params,
        reply_type,
        .{},
        500,
        null,
        &err,
    );
    if (err) |e| {
        glib.Error.free(e);
        return;
    }
    const res = result orelse return;
    defer res.unref();
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
    if (desktop_monitor == null) {
        const config_dir = std.mem.span(glib.getUserConfigDir());
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&buf, "{s}/gtk-4.0", .{config_dir}, 0)) |dir| {
            const file = gio.File.newForPath(dir.ptr);
            defer file.as(gobject.Object).unref();
            var err: ?*glib.Error = null;
            if (gio.File.monitorDirectory(file, .{}, null, &err)) |monitor| {
                desktop_monitor = monitor;
                _ = gio.FileMonitor.signals.changed.connect(monitor, *c_int, &onDesktopFilesChanged, &watch_dummy, .{});
            }
            if (err) |e| glib.Error.free(e);
        } else |_| {}
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
                "org.freedesktop.appearance",
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
    const key = params.getChildValue(1);
    defer key.unref();
    const name = std.mem.span(key.getString(null));
    const is_accent = std.mem.eql(u8, name, "accent-color");
    if (!is_accent and !std.mem.eql(u8, name, "color-scheme")) return;
    readPortal();
    const boxed = params.getChildValue(2);
    defer boxed.unref();
    const value = boxed.getVariant();
    defer value.unref();
    if (is_accent) portal_accent = accentFromVariant(value) else portal_dark = schemeFromVariant(value);
    scheduleDesktopRefresh();
}

/// Palette tools write several files at once.
fn scheduleDesktopRefresh() void {
    if (desktop_refresh_source != 0) return;
    desktop_refresh_source = glib.timeoutAdd(100, &onDesktopRefresh, null);
}

fn onDesktopRefresh(_: ?*anyopaque) callconv(.c) c_int {
    desktop_refresh_source = 0;
    if (current_mode != .system) return 0;
    const win = watched_window orelse return 0;
    applyWith(win, current_mode, current_variant);
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

fn legacyPrefersDark() bool {
    if (gnomeInterfaceSettings()) |settings| {
        const scheme = settings.getString("color-scheme");
        return std.mem.eql(u8, std.mem.span(scheme), "prefer-dark");
    }
    const gtk_settings = gtk.Settings.getDefault() orelse return true;
    var value = std.mem.zeroes(gobject.Value);
    _ = value.init(gobject.typeFromName("gboolean"));
    gtk_settings.as(gobject.Object).getProperty("gtk-application-prefer-dark-theme", &value);
    return value.getBoolean() != 0;
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
