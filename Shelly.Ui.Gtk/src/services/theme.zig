//! Applies Shelly's built-in Pearl-style theme, or falls back to the system
//! GTK theme.
//!
//! The built-in theme lives in two resource stylesheets (dark/light). Each
//! sheet redefines the GTK named colors consumed by `style.css` and adds
//! component rules scoped under the `shelly-root` window class, so removing
//! the provider and the class restores the legacy system-theme rendering
//! exactly. `@define-color` is provider-global (not selector-scoped), hence
//! one sheet per variant and a provider reload when the variant changes.
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

pub const ThemeMode = config_model.ThemeMode;
pub const ThemeVariant = config_model.ThemeVariant;

const dark_resource = "/com/shellyorg/shelly/themes/shelly-dark.css";
const light_resource = "/com/shellyorg/shelly/themes/shelly-light.css";

/// Above USER: desktops may install system-wide GTK overrides at USER
/// priority (e.g. Pearl's matugen Material palette in ~/.config/gtk-4.0),
/// which would otherwise repaint the built-in theme's surfaces with the
/// desktop's fixed dark palette. System mode removes this provider, so the
/// desktop override applies again there.
const themed_priority = gtk.STYLE_PROVIDER_PRIORITY_USER + 1;

var provider: ?*gtk.CssProvider = null;
var provider_added: bool = false;
var headerbar: ?*gtk.HeaderBar = null;
var watched_window: ?*gtk.Window = null;
var current_mode: ThemeMode = .shelly;
var current_variant: ThemeVariant = .follow_system;
var resolved_dark: bool = true;
var gnome_settings: ?*gio.Settings = null;
var watchers_started: bool = false;
var watch_dummy: c_int = 0;

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
    const dark = resolveDark(variant);
    resolved_dark = dark;

    if (mode == .shelly) {
        const prov = ensureProvider();
        loadSheet(prov, dark);
        if (!provider_added) {
            gtk.StyleContext.addProviderForDisplay(display, prov.as(gtk.StyleProvider), themed_priority);
            provider_added = true;
        }
        gtk.Widget.addCssClass(widget, "shelly-root");
        gtk.Window.setTitlebar(win, ensureHeaderBar().as(gtk.Widget));
        setScopedVisible(widget, true);
        setDarkHint(dark);
    } else {
        if (provider_added) {
            gtk.StyleContext.removeProviderForDisplay(display, provider.?.as(gtk.StyleProvider));
            provider_added = false;
        }
        gtk.Widget.removeCssClass(widget, "shelly-root");
        gtk.Window.setTitlebar(win, null);
        setScopedVisible(widget, false);
        setupGnomeThemePreference();
        if (variant != .follow_system) setDarkHint(variant == .dark);
    }
    ensureWatchers();
}

pub fn isThemed() bool {
    return current_mode == .shelly;
}

fn ensureProvider() *gtk.CssProvider {
    if (provider) |prov| return prov;
    const prov = gtk.CssProvider.new();
    provider = prov;
    return prov;
}

fn loadSheet(prov: *gtk.CssProvider, dark: bool) void {
    gtk.CssProvider.loadFromResource(prov, if (dark) dark_resource else light_resource);
}

fn ensureHeaderBar() *gtk.HeaderBar {
    if (headerbar) |bar| return bar;
    const bar = gtk.HeaderBar.new();
    gtk.Widget.addCssClass(bar.as(gtk.Widget), "shelly-headerbar");

    const brand = gtk.Box.new(.horizontal, 9);
    gtk.Widget.addCssClass(brand.as(gtk.Widget), "shelly-brand");
    // Fill the headerbar's center allocation so the brand sits left, like
    // Pearl's titlebar, instead of being centered by GtkHeaderBar.
    gtk.Widget.setHexpand(brand.as(gtk.Widget), 1);
    gtk.Widget.setHalign(brand.as(gtk.Widget), .start);
    const dot = gtk.Box.new(.horizontal, 0);
    gtk.Widget.addCssClass(dot.as(gtk.Widget), "shelly-brand-dot");
    gtk.Widget.setSizeRequest(dot.as(gtk.Widget), 15, 15);
    gtk.Box.append(brand, dot.as(gtk.Widget));
    const label = gtk.Label.new(translations._("Shelly"));
    gtk.Widget.addCssClass(label.as(gtk.Widget), "shelly-brand-label");
    gtk.Box.append(brand, label.as(gtk.Widget));

    gtk.HeaderBar.setTitleWidget(bar, brand.as(gtk.Widget));
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
    const gtk_settings = gtk.Settings.getDefault() orelse return;
    const obj = gtk_settings.as(gobject.Object);
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

/// Shows/hides the widgets that only exist for the built-in theme (added page
/// headers and sidebar group labels) so system mode keeps the legacy layout.
fn setScopedVisible(root: *gtk.Widget, visible: bool) void {
    if (gtk.Widget.hasCssClass(root, "page-head-added") != 0 or gtk.Widget.hasCssClass(root, "nav-group") != 0) {
        gtk.Widget.setVisible(root, @intFromBool(visible));
    }
    // Settings cards fill the content width in the built-in theme (mockup);
    // system mode keeps the legacy centered 600px column.
    if (gtk.Widget.hasCssClass(root, "settings-card") != 0) {
        gtk.Widget.setSizeRequest(root, if (visible) -1 else 600, -1);
    }
    var child = gtk.Widget.getFirstChild(root);
    while (child) |c| : (child = gtk.Widget.getNextSibling(c)) {
        setScopedVisible(c, visible);
    }
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
    }
}

fn onGnomeSchemeChanged(_: *gio.Settings, _: [*:0]const u8, _: *c_int) callconv(.c) void {
    refreshFollowSystem();
}

fn onPreferDarkNotify(_: *gobject.Object, _: *gobject.ParamSpec, _: *c_int) callconv(.c) void {
    refreshFollowSystem();
}

fn refreshFollowSystem() void {
    if (current_mode != .shelly or current_variant != .follow_system) return;
    if (watched_window == null) return;
    const dark = desktopPrefersDark();
    if (dark == resolved_dark) return;
    resolved_dark = dark;
    loadSheet(ensureProvider(), dark);
}

/// Mirrors the desktop's dark preference into GTK at startup. Moved verbatim
/// from main.zig so system mode keeps the historical behavior.
pub fn setupGnomeThemePreference() void {
    const desktop = runtime.environ_map.get("XDG_CURRENT_DESKTOP") orelse return;

    if (!std.mem.containsAtLeast(u8, desktop, 1, "GNOME")) {
        return;
    }

    const settings = gio.Settings.new("org.gnome.desktop.interface");

    const scheme = settings.getString("color-scheme");

    const prefer_dark = std.mem.eql(u8, std.mem.span(scheme), "prefer-dark");

    if (prefer_dark) {
        const gtk_settings = gtk.Settings.getDefault() orelse {
            std.debug.print("Could not read the desktop theme settings. Shelly will use the available theme defaults.\n", .{});
            return;
        };
        const base_object = @as(*gobject.Object, @ptrCast(@alignCast(gtk_settings)));
        var value = std.mem.zeroes(gobject.Value);
        const bool_type = gobject.typeFromName("gboolean");
        _ = value.init(bool_type);
        value.setBoolean(1);
        base_object.setProperty("gtk-application-prefer-dark-theme", &value);
    }

    _ = glib.setenv(
        "GTK_APPLICATION_PREFER_DARK_THEME",
        if (prefer_dark) "1" else "0",
        1,
    );
}
