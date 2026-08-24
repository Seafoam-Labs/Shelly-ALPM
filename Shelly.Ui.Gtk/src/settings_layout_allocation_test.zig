const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gdk = bindings.gdk;
const gobject = bindings.gobject;
const gtk = bindings.gtk;
const SettingsPage = @import("pages/settings_page.zig").SettingsPage;
const UtilitiesPage = @import("pages/utilities_page.zig").UtilitiesPage;

fn expectUsesParentSizeAllocate(comptime Page: type) !void {
    const raw_class = gobject.TypeClass.ref(Page.getGObjectType());
    defer raw_class.unref();

    const widget_class: *gtk.Widget.Class = @ptrCast(@alignCast(raw_class));
    const raw_parent_class = gobject.TypeClass.peekParent(raw_class);
    const parent_widget_class: *gtk.Widget.Class = @ptrCast(@alignCast(raw_parent_class));

    if (widget_class.f_size_allocate != parent_widget_class.f_size_allocate) {
        return error.LayoutManagedWidgetOverridesSizeAllocation;
    }
}

fn findSettingsSection(widget: *gtk.Widget) ?*gtk.Widget {
    if (gtk.Widget.hasCssClass(widget, "settings-section") != 0) return widget;

    var child = gtk.Widget.getFirstChild(widget);
    while (child) |current| : (child = gtk.Widget.getNextSibling(current)) {
        if (findSettingsSection(current)) |section| return section;
    }
    return null;
}

fn collectSettingsSections(widget: *gtk.Widget, sections: *[3]*gtk.Widget, count: *usize) void {
    if (gtk.Widget.hasCssClass(widget, "settings-section") != 0) {
        if (count.* < sections.len) {
            sections[count.*] = widget;
            count.* += 1;
        }
        return;
    }

    var child = gtk.Widget.getFirstChild(widget);
    while (child) |current| : (child = gtk.Widget.getNextSibling(current)) {
        collectSettingsSections(current, sections, count);
    }
}

fn expectSettingsMatchesUtilitiesWidth() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;
    const display = gdk.Display.getDefault() orelse return error.GtkUnavailable;

    const provider = gtk.CssProvider.new();
    defer provider.unref();
    gtk.CssProvider.loadFromString(provider, @embedFile("themes/style.css"));
    gtk.StyleContext.addProviderForDisplay(
        display,
        provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    defer gtk.StyleContext.removeProviderForDisplay(display, provider.as(gtk.StyleProvider));

    const root = gtk.Box.new(.horizontal, 0);
    _ = root.as(gobject.Object).refSink();
    defer root.as(gobject.Object).unref();

    const settings_page = SettingsPage.new();
    var settings_sections: [3]*gtk.Widget = undefined;
    var section_count: usize = 0;
    collectSettingsSections(settings_page.as(gtk.Widget), &settings_sections, &section_count);
    if (section_count != settings_sections.len) return error.SettingsSectionMissing;
    for (settings_sections) |section| {
        gtk.Widget.addCssClass(section, "settings-section-wide");
    }
    gtk.Box.append(root, settings_page.as(gtk.Widget));

    const utilities_page = UtilitiesPage.new();
    const utilities_section = findSettingsSection(utilities_page.as(gtk.Widget)) orelse return error.SettingsSectionMissing;
    gtk.Widget.addCssClass(utilities_section, "settings-section-wide");
    gtk.Box.append(root, utilities_page.as(gtk.Widget));

    var utilities_width: c_int = 0;
    gtk.Widget.measure(utilities_section, .horizontal, -1, &utilities_width, null, null, null);
    for (settings_sections, 0..) |section, index| {
        var settings_width: c_int = 0;
        gtk.Widget.measure(section, .horizontal, -1, &settings_width, null, null, null);
        if (settings_width != utilities_width) {
            std.debug.print("settings width mismatch: section={d}, settings={d}, utilities={d}\n", .{
                index,
                settings_width,
                utilities_width,
            });
            return error.SettingsSectionDoesNotMatchUtilities;
        }
    }
}

pub fn main() !void {
    try expectUsesParentSizeAllocate(SettingsPage);
    try expectUsesParentSizeAllocate(UtilitiesPage);
    try expectSettingsMatchesUtilitiesWidth();
}
