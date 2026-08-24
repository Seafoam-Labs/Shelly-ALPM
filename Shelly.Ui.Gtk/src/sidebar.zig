const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;

pub const Sidebar = struct {
    root: *gtk.Box,
    brand: *gtk.Box,
    primary: *gtk.Box,
    primary_scroll: *gtk.ScrolledWindow,
    bottom: *gtk.Box,
    brand_name: *gtk.Revealer,
    logo: *gtk.Image,
    collapse_button: *gtk.Button,
    collapse_image: *gtk.Image,

    pub fn init(collapsed: bool) Sidebar {
        const root = gtk.Box.new(.vertical, 0);
        gtk.Widget.addCssClass(root.as(gtk.Widget), "nav-rail");
        gtk.Widget.addCssClass(root.as(gtk.Widget), "app-sidebar");
        gtk.Widget.setHexpand(root.as(gtk.Widget), 0);
        gtk.Widget.setVexpand(root.as(gtk.Widget), 1);

        const brand = gtk.Box.new(.horizontal, 0);
        gtk.Widget.addCssClass(brand.as(gtk.Widget), "sidebar-brand");

        const collapse_button = gtk.Button.new();
        gtk.Widget.addCssClass(collapse_button.as(gtk.Widget), "flat");
        gtk.Widget.addCssClass(collapse_button.as(gtk.Widget), "sidebar-collapse-button");
        gtk.Widget.setTooltipText(collapse_button.as(gtk.Widget), "Collapse sidebar");
        const collapse_image = gtk.Image.newFromIconName("sidebar-show-symbolic");
        gtk.Image.setIconSize(collapse_image, .normal);
        gtk.Button.setChild(collapse_button, collapse_image.as(gtk.Widget));

        const logo = gtk.Image.newFromIconName("shelly");
        gtk.Image.setIconSize(logo, .large);
        gtk.Widget.addCssClass(logo.as(gtk.Widget), "sidebar-logo");
        gtk.Widget.setHalign(logo.as(gtk.Widget), .center);
        gtk.Box.append(brand, logo.as(gtk.Widget));

        const name = gtk.Label.new("Shelly");
        gtk.Widget.addCssClass(name.as(gtk.Widget), "sidebar-brand-name");
        gtk.Widget.setHalign(name.as(gtk.Widget), .start);

        const brand_name = gtk.Revealer.new();
        gtk.Revealer.setTransitionType(brand_name, .slide_right);
        gtk.Revealer.setTransitionDuration(brand_name, 180);
        gtk.Revealer.setChild(brand_name, name.as(gtk.Widget));
        gtk.Box.append(brand, brand_name.as(gtk.Widget));

        const brand_drag_region = gtk.WindowHandle.new();
        gtk.WindowHandle.setChild(brand_drag_region, brand.as(gtk.Widget));
        gtk.Widget.setHalign(brand_drag_region.as(gtk.Widget), .fill);
        gtk.Widget.setHexpand(brand_drag_region.as(gtk.Widget), 1);
        gtk.Box.append(root, brand_drag_region.as(gtk.Widget));

        const primary = gtk.Box.new(.vertical, 0);
        gtk.Widget.addCssClass(primary.as(gtk.Widget), "sidebar-primary");

        const primary_scroll = gtk.ScrolledWindow.new();
        gtk.ScrolledWindow.setPolicy(primary_scroll, .never, .automatic);
        gtk.ScrolledWindow.setChild(primary_scroll, primary.as(gtk.Widget));
        gtk.Widget.setVexpand(primary_scroll.as(gtk.Widget), 1);
        gtk.Widget.addCssClass(primary_scroll.as(gtk.Widget), "sidebar-primary-scroll");
        gtk.Box.append(root, primary_scroll.as(gtk.Widget));

        const separator = gtk.Separator.new(.horizontal);
        gtk.Widget.addCssClass(separator.as(gtk.Widget), "sidebar-separator");
        gtk.Box.append(root, separator.as(gtk.Widget));

        const bottom = gtk.Box.new(.vertical, 0);
        gtk.Widget.addCssClass(bottom.as(gtk.Widget), "sidebar-bottom");
        gtk.Box.append(root, bottom.as(gtk.Widget));

        var sidebar = Sidebar{
            .root = root,
            .brand = brand,
            .primary = primary,
            .primary_scroll = primary_scroll,
            .bottom = bottom,
            .brand_name = brand_name,
            .logo = logo,
            .collapse_button = collapse_button,
            .collapse_image = collapse_image,
        };
        sidebar.setCollapsed(collapsed);
        return sidebar;
    }

    pub fn setCollapsed(self: Sidebar, collapsed: bool) void {
        gtk.Widget.removeCssClass(self.root.as(gtk.Widget), if (collapsed) "sidebar-expanded" else "sidebar-collapsed");
        gtk.Widget.addCssClass(self.root.as(gtk.Widget), if (collapsed) "sidebar-collapsed" else "sidebar-expanded");
        gtk.Widget.setHalign(self.brand.as(gtk.Widget), if (collapsed) .center else .fill);
        gtk.Revealer.setRevealChild(self.brand_name, @intFromBool(!collapsed));
        gtk.Image.setFromIconName(self.collapse_image, "sidebar-show-symbolic");
        gtk.Widget.setTooltipText(
            self.collapse_button.as(gtk.Widget),
            if (collapsed) "Expand sidebar" else "Collapse sidebar",
        );
    }

    pub fn appendPrimary(self: Sidebar, child: *gtk.Widget) void {
        gtk.Box.append(self.primary, child);
    }

    pub fn appendBottom(self: Sidebar, child: *gtk.Widget) void {
        gtk.Box.append(self.bottom, child);
    }
};

test "sidebar keeps brand and navigation regions while labels collapse" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const sidebar = Sidebar.init(false);
    _ = sidebar.root.as(gobject.Object).refSink();
    defer sidebar.root.as(gobject.Object).unref();

    try std.testing.expect(gtk.Widget.hasCssClass(sidebar.root.as(gtk.Widget), "app-sidebar") != 0);
    try std.testing.expect(gtk.Widget.hasCssClass(sidebar.primary.as(gtk.Widget), "sidebar-primary") != 0);
    try std.testing.expect(
        gtk.Widget.getAncestor(sidebar.primary.as(gtk.Widget), gtk.ScrolledWindow.getGObjectType()) ==
            sidebar.primary_scroll.as(gtk.Widget),
    );
    try std.testing.expectEqual(@as(c_int, 1), gtk.Widget.getVexpand(sidebar.primary_scroll.as(gtk.Widget)));
    try std.testing.expect(gtk.Widget.hasCssClass(sidebar.bottom.as(gtk.Widget), "sidebar-bottom") != 0);
    try std.testing.expectEqual(@as(c_int, 1), gtk.Revealer.getRevealChild(sidebar.brand_name));

    sidebar.setCollapsed(true);

    try std.testing.expect(gtk.Widget.hasCssClass(sidebar.root.as(gtk.Widget), "sidebar-collapsed") != 0);
    try std.testing.expectEqual(@as(c_int, 0), gtk.Revealer.getRevealChild(sidebar.brand_name));
    try std.testing.expect(gtk.Widget.getParent(sidebar.logo.as(gtk.Widget)) != null);
    try std.testing.expect(gtk.Widget.getParent(sidebar.collapse_button.as(gtk.Widget)) == null);
}

test "sidebar places primary navigation and settings in separate regions" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const sidebar = Sidebar.init(false);
    _ = sidebar.root.as(gobject.Object).refSink();
    defer sidebar.root.as(gobject.Object).unref();

    const packages = gtk.Button.new();
    const settings = gtk.Button.new();
    sidebar.appendPrimary(packages.as(gtk.Widget));
    sidebar.appendBottom(settings.as(gtk.Widget));

    try std.testing.expect(gtk.Widget.getParent(packages.as(gtk.Widget)) == sidebar.primary.as(gtk.Widget));
    try std.testing.expect(gtk.Widget.getParent(settings.as(gtk.Widget)) == sidebar.bottom.as(gtk.Widget));
}

test "sidebar brand stays at the top while the collapse toggle remains external" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const sidebar = Sidebar.init(false);
    _ = sidebar.root.as(gobject.Object).refSink();
    defer sidebar.root.as(gobject.Object).unref();

    try std.testing.expect(
        gtk.Widget.getFirstChild(sidebar.brand.as(gtk.Widget)) ==
            sidebar.logo.as(gtk.Widget),
    );
    try std.testing.expect(gtk.Widget.getParent(sidebar.collapse_button.as(gtk.Widget)) == null);
    try std.testing.expectEqual(gtk.Orientation.horizontal, gtk.Orientable.getOrientation(sidebar.brand.as(gtk.Orientable)));

    sidebar.setCollapsed(true);

    try std.testing.expectEqual(gtk.Orientation.horizontal, gtk.Orientable.getOrientation(sidebar.brand.as(gtk.Orientable)));
    try std.testing.expect(
        gtk.Widget.getFirstChild(sidebar.brand.as(gtk.Widget)) ==
            sidebar.logo.as(gtk.Widget),
    );
}

test "sidebar brand is a full-width native window drag region" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const sidebar = Sidebar.init(false);
    _ = sidebar.root.as(gobject.Object).refSink();
    defer sidebar.root.as(gobject.Object).unref();

    const brand_parent = gtk.Widget.getParent(sidebar.brand.as(gtk.Widget)) orelse
        return error.TestUnexpectedResult;
    const drag_region = gobject.ext.cast(gtk.WindowHandle, brand_parent) orelse
        return error.TestUnexpectedResult;

    try std.testing.expect(gtk.Widget.getFirstChild(sidebar.root.as(gtk.Widget)) == brand_parent);
    try std.testing.expect(gtk.WindowHandle.getChild(drag_region) == sidebar.brand.as(gtk.Widget));
    try std.testing.expectEqual(@as(c_int, 1), gtk.Widget.getHexpand(brand_parent));
    try std.testing.expectEqual(gtk.Align.fill, gtk.Widget.getHalign(brand_parent));
}

test "sidebar root explicitly refuses horizontal expansion" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const sidebar = Sidebar.init(false);
    _ = sidebar.root.as(gobject.Object).refSink();
    defer sidebar.root.as(gobject.Object).unref();

    try std.testing.expectEqual(@as(c_int, 1), gtk.Widget.getHexpandSet(sidebar.root.as(gtk.Widget)));
    try std.testing.expectEqual(@as(c_int, 0), gtk.Widget.getHexpand(sidebar.root.as(gtk.Widget)));
    try std.testing.expectEqual(@as(c_int, 0), gtk.Widget.computeExpand(sidebar.root.as(gtk.Widget), .horizontal));
}

test "collapsed sidebar centers the brand without requesting extra width" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const sidebar = Sidebar.init(false);
    _ = sidebar.root.as(gobject.Object).refSink();
    defer sidebar.root.as(gobject.Object).unref();

    try std.testing.expectEqual(@as(c_int, 0), gtk.Widget.getHexpand(sidebar.logo.as(gtk.Widget)));
    try std.testing.expectEqual(gtk.Align.fill, gtk.Widget.getHalign(sidebar.brand.as(gtk.Widget)));

    sidebar.setCollapsed(true);
    try std.testing.expectEqual(@as(c_int, 0), gtk.Widget.getHexpand(sidebar.logo.as(gtk.Widget)));
    try std.testing.expectEqual(gtk.Align.center, gtk.Widget.getHalign(sidebar.brand.as(gtk.Widget)));

    sidebar.setCollapsed(false);
    try std.testing.expectEqual(@as(c_int, 0), gtk.Widget.getHexpand(sidebar.logo.as(gtk.Widget)));
    try std.testing.expectEqual(gtk.Align.fill, gtk.Widget.getHalign(sidebar.brand.as(gtk.Widget)));
}
