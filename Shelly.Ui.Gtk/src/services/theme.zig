//! Applies Shelly's built-in Pearl-style theme, or falls back to the system
//! GTK theme.
//!
//! While the built-in theme is active it must render exactly as designed, so
//! the desktop GTK theme is taken out of the picture entirely instead of
//! being layered under:
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
//! The built-in theme itself lives in two resource stylesheets (dark/light).
//! Each sheet redefines the GTK named colors consumed by `style.css` and adds
//! component rules scoped under the `shelly-root` window class, so removing
//! the providers and the class restores the legacy system-theme rendering
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
/// desktop's fixed dark palette. System mode removes this provider, so the
/// desktop override applies again there.
const themed_priority = gtk.STYLE_PROVIDER_PRIORITY_USER + 1;

var provider: ?*gtk.CssProvider = null;
var provider_added: bool = false;
var base_resolved: bool = false;
var base: ?ThemeBase = null;
var base_media_driven: bool = true;
var base_provider: ?*gtk.CssProvider = null;
var base_added: bool = false;
var pin_name: ?[:0]const u8 = null;
var pin_applied: bool = false;
var dark_hint_applied: bool = false;
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
        gtk.Widget.addCssClass(widget, "shelly-root");
        gtk.Window.setTitlebar(win, ensureHeaderBar().as(gtk.Widget));
        setScopedVisible(widget, true);
        setDarkHint(dark);
    } else {
        if (provider_added) {
            gtk.StyleContext.removeProviderForDisplay(display, provider.?.as(gtk.StyleProvider));
            provider_added = false;
        }
        if (base_added) {
            gtk.StyleContext.removeProviderForDisplay(display, base_provider.?.as(gtk.StyleProvider));
            base_added = false;
        }
        restoreThemeName();
        restoreColorScheme();
        gtk.Widget.removeCssClass(widget, "shelly-root");
        gtk.Window.setTitlebar(win, null);
        setScopedVisible(widget, false);
        setupGnomeThemePreference();
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
/// when the desktop re-applies its theme; that is also why leaving Shelly
/// mode must go through `gtk_settings_reset_property` rather than writing a
/// value back — resetting hands the property to the settings backends again,
/// so GTK mode immediately follows the user's current theme and later
/// changes to it.
fn applyThemePin() void {
    const pin = pin_name orelse return;
    if (themeNameIs(pin)) {
        pin_applied = true;
        return;
    }
    setThemeName(pin);
    pin_applied = true;
}

fn restoreThemeName() void {
    if (!pin_applied) return;
    pin_applied = false;
    if (gtk.Settings.getDefault()) |gtk_settings| {
        gtk.Settings.resetProperty(gtk_settings, "gtk-theme-name");
    }
}

/// Like the theme-name pin, the color-scheme property is shielded from the
/// settings backends once Shelly mode sets it. Reset it when returning to the
/// desktop theme so system mode follows the desktop dark/light preference
/// instead of the value Shelly last pinned. The stored variant is a Shelly-mode
/// preference and is deliberately not applied in system mode.
fn restoreColorScheme() void {
    if (!dark_hint_applied) return;
    dark_hint_applied = false;
    if (gtk.Settings.getDefault()) |gtk_settings| {
        const property: [:0]const u8 = if (hasInterfaceColorScheme()) "gtk-interface-color-scheme" else "gtk-application-prefer-dark-theme";
        gtk.Settings.resetProperty(gtk_settings, property);
    }
}

fn loadSheet(prov: *gtk.CssProvider, dark: bool) void {
    gtk.CssProvider.loadFromResource(prov, if (dark) dark_resource else light_resource);
}

fn ensureHeaderBar() *gtk.HeaderBar {
    if (headerbar) |bar| return bar;
    const bar = gtk.HeaderBar.new();
    // Own a reference: the window sinks the floating ref while the bar is the
    // titlebar and drops it again in system mode (setTitlebar(null)); without
    // this ref the cached bar would be finalized and switching back to the
    // built-in theme would re-attach freed memory.
    _ = bar.as(gobject.Object).ref();
    gtk.Widget.addCssClass(bar.as(gtk.Widget), "shelly-headerbar");

    const brand = gtk.Box.new(.horizontal, 9);
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
    dark_hint_applied = true;
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
    refreshFollowSystem();
}

/// Desktop theme changes arrive as `gtk-theme-name` updates. Settings
/// backends stop pushing once the application has set the property, but
/// other channels (e.g. xsettings broadcasts) may still deliver updates
/// while the built-in theme is active; re-assert the pin for those.
fn onThemeNameNotify(_: *gobject.Object, _: *gobject.ParamSpec, _: *c_int) callconv(.c) void {
    if (current_mode != .shelly) return;
    applyThemePin();
}

fn refreshFollowSystem() void {
    if (current_mode != .shelly or current_variant != .follow_system) return;
    if (watched_window == null) return;
    const dark = desktopPrefersDark();
    if (dark == resolved_dark) return;
    resolved_dark = dark;
    loadSheet(ensureProvider(), dark);
    if (base_added) loadBaseSheet(base_provider.?, dark);
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
