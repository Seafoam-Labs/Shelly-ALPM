const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gdk = bindings.gdk;
const AppTheme = @import("../models/shelly_config.zig").AppTheme;

pub const CLASSIC_CLASS: [:0]const u8 = "theme-classic";
pub const MIDNIGHT_CLASS: [:0]const u8 = "theme-midnight";

pub fn className(theme: AppTheme) [:0]const u8 {
    return switch (theme) {
        .classic => CLASSIC_CLASS,
        .midnight => MIDNIGHT_CLASS,
    };
}

pub fn loadProviders() bool {
    const display = gdk.Display.getDefault() orelse return false;

    inline for (.{
        "/com/shellyorg/shelly/style.css",
        "/com/shellyorg/shelly/theme-midnight.css",
    }) |resource| {
        const provider = gtk.CssProvider.new();
        defer provider.unref();
        gtk.CssProvider.loadFromResource(provider, resource);
        gtk.StyleContext.addProviderForDisplay(
            display,
            provider.as(gtk.StyleProvider),
            gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }

    return true;
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
