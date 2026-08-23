const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gdk = bindings.gdk;
const gobject = bindings.gobject;

pub fn build() *gtk.Box {
    const controls = gtk.Box.new(.horizontal, 0);
    gtk.Widget.addCssClass(controls.as(gtk.Widget), "app-window-controls");

    const minimize = newButton(
        "shelly-window-minimize-symbolic",
        "window.minimize",
        "window-control-minimize",
    );
    const maximize = newButton(
        "shelly-window-maximize-symbolic",
        "window.toggle-maximized",
        "window-control-maximize",
    );
    const close = newButton(
        "shelly-window-close-symbolic",
        "window.close",
        "window-control-close",
    );

    gtk.Box.append(controls, minimize.as(gtk.Widget));
    gtk.Box.append(controls, maximize.as(gtk.Widget));
    gtk.Box.append(controls, close.as(gtk.Widget));
    return controls;
}

pub fn buildChromeRow(toggle: *gtk.Button) *gtk.Box {
    const chrome = gtk.Box.new(.horizontal, 0);
    gtk.Widget.addCssClass(chrome.as(gtk.Widget), "app-window-chrome-row");
    gtk.Widget.setValign(toggle.as(gtk.Widget), .center);
    gtk.Box.append(chrome, toggle.as(gtk.Widget));

    const drag_region = buildDragRegion();
    gtk.Box.append(chrome, drag_region.as(gtk.Widget));
    return chrome;
}

pub fn installOverlay(overlay: *gtk.Overlay) void {
    const controls = build();
    gtk.Widget.addCssClass(controls.as(gtk.Widget), "app-window-controls-overlay");
    gtk.Widget.setHalign(controls.as(gtk.Widget), .end);
    gtk.Widget.setValign(controls.as(gtk.Widget), .start);

    installResizeHandles(overlay);
    gtk.Overlay.addOverlay(overlay, controls.as(gtk.Widget));
    gtk.Overlay.setMeasureOverlay(overlay, controls.as(gtk.Widget), 0);
}

fn buildDragRegion() *gtk.WindowHandle {
    const drag_region = gtk.WindowHandle.new();
    const hitbox = gtk.Box.new(.horizontal, 0);
    gtk.WindowHandle.setChild(drag_region, hitbox.as(gtk.Widget));
    gtk.Widget.addCssClass(drag_region.as(gtk.Widget), "app-window-drag-region");
    gtk.Widget.setHalign(drag_region.as(gtk.Widget), .fill);
    gtk.Widget.setValign(drag_region.as(gtk.Widget), .fill);
    gtk.Widget.setHexpand(drag_region.as(gtk.Widget), 1);
    gtk.Widget.setVexpand(drag_region.as(gtk.Widget), 0);
    return drag_region;
}

const ResizeHandle = struct {
    edge: gdk.SurfaceEdge,
    css_class: [:0]const u8,
    cursor: [:0]const u8,
    halign: gtk.Align,
    valign: gtk.Align,
    hexpand: c_int = 0,
    vexpand: c_int = 0,
};

const resize_handles = [_]ResizeHandle{
    .{ .edge = .north, .css_class = "window-resize-north", .cursor = "n-resize", .halign = .fill, .valign = .start, .hexpand = 1 },
    .{ .edge = .north_east, .css_class = "window-resize-north-east", .cursor = "ne-resize", .halign = .end, .valign = .start },
    .{ .edge = .east, .css_class = "window-resize-east", .cursor = "e-resize", .halign = .end, .valign = .fill, .vexpand = 1 },
    .{ .edge = .south_east, .css_class = "window-resize-south-east", .cursor = "se-resize", .halign = .end, .valign = .end },
    .{ .edge = .south, .css_class = "window-resize-south", .cursor = "s-resize", .halign = .fill, .valign = .end, .hexpand = 1 },
    .{ .edge = .south_west, .css_class = "window-resize-south-west", .cursor = "sw-resize", .halign = .start, .valign = .end },
    .{ .edge = .west, .css_class = "window-resize-west", .cursor = "w-resize", .halign = .start, .valign = .fill, .vexpand = 1 },
    .{ .edge = .north_west, .css_class = "window-resize-north-west", .cursor = "nw-resize", .halign = .start, .valign = .start },
};

fn installResizeHandles(overlay: *gtk.Overlay) void {
    for (resize_handles) |handle_config| {
        const handle = gtk.Box.new(.horizontal, 0);
        const widget = handle.as(gtk.Widget);
        gtk.Widget.addCssClass(widget, "app-window-resize-handle");
        gtk.Widget.addCssClass(widget, handle_config.css_class);
        gtk.Widget.setCursorFromName(widget, handle_config.cursor);
        gtk.Widget.setHalign(widget, handle_config.halign);
        gtk.Widget.setValign(widget, handle_config.valign);
        gtk.Widget.setHexpand(widget, handle_config.hexpand);
        gtk.Widget.setVexpand(widget, handle_config.vexpand);

        const click = gtk.GestureClick.new();
        gtk.GestureSingle.setButton(click.as(gtk.GestureSingle), 1);
        _ = gtk.GestureClick.signals.pressed.connect(click, ?*anyopaque, &onResizePressed, null, .{});
        gtk.Widget.addController(widget, click.as(gtk.EventController));

        gtk.Overlay.addOverlay(overlay, widget);
        gtk.Overlay.setMeasureOverlay(overlay, widget, 0);
    }
}

fn onResizePressed(gesture: *gtk.GestureClick, _: c_int, _: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
    const controller = gesture.as(gtk.EventController);
    const widget = gtk.EventController.getWidget(controller) orelse return;
    const edge = resizeEdgeForWidget(widget) orelse return;
    const event = gtk.EventController.getCurrentEvent(controller) orelse return;
    const device = gtk.EventController.getCurrentEventDevice(controller) orelse return;
    const native = gtk.Widget.getNative(widget) orelse return;
    const surface = gtk.Native.getSurface(native) orelse return;
    const toplevel = gobject.ext.cast(gdk.Toplevel, surface) orelse return;

    var surface_x: f64 = 0;
    var surface_y: f64 = 0;
    if (gdk.Event.getPosition(event, &surface_x, &surface_y) == 0) return;

    gdk.Toplevel.beginResize(
        toplevel,
        edge,
        device,
        @intCast(gtk.GestureSingle.getCurrentButton(gesture.as(gtk.GestureSingle))),
        surface_x,
        surface_y,
        gtk.EventController.getCurrentEventTime(controller),
    );
}

fn resizeEdgeForWidget(widget: *gtk.Widget) ?gdk.SurfaceEdge {
    for (resize_handles) |handle_config| {
        if (gtk.Widget.hasCssClass(widget, handle_config.css_class) != 0) return handle_config.edge;
    }
    return null;
}

fn newButton(icon_name: [:0]const u8, action_name: [:0]const u8, css_class: [:0]const u8) *gtk.Button {
    const button = gtk.Button.newFromIconName(icon_name);
    gtk.Actionable.setActionName(button.as(gtk.Actionable), action_name);
    gtk.Widget.addCssClass(button.as(gtk.Widget), "flat");
    gtk.Widget.addCssClass(button.as(gtk.Widget), "app-window-control");
    gtk.Widget.addCssClass(button.as(gtk.Widget), css_class);
    return button;
}

test "window controls expose the native window actions in visual order" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const controls = build();
    _ = controls.as(gobject.Object).refSink();
    defer controls.as(gobject.Object).unref();

    const expected_actions = [_][:0]const u8{
        "window.minimize",
        "window.toggle-maximized",
        "window.close",
    };
    const expected_classes = [_][:0]const u8{
        "window-control-minimize",
        "window-control-maximize",
        "window-control-close",
    };

    var child = gtk.Widget.getFirstChild(controls.as(gtk.Widget));
    for (expected_actions, expected_classes) |expected_action, expected_class| {
        const current = child orelse return error.TestExpectedEqual;
        const button = gobject.ext.cast(gtk.Button, current) orelse return error.TestExpectedEqual;
        try std.testing.expectEqualStrings(
            expected_action,
            std.mem.span(gtk.Actionable.getActionName(button.as(gtk.Actionable)).?),
        );
        try std.testing.expect(gtk.Widget.hasCssClass(current, expected_class) != 0);
        child = gtk.Widget.getNextSibling(current);
    }
    try std.testing.expect(child == null);
}

test "overlay keeps window controls separate from the content chrome row" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const overlay = gtk.Overlay.new();
    _ = overlay.as(gobject.Object).refSink();
    defer overlay.as(gobject.Object).unref();
    const content = gtk.Box.new(.horizontal, 0);
    gtk.Overlay.setChild(overlay, content.as(gtk.Widget));

    installOverlay(overlay);

    var has_drag_region = false;
    var has_controls = false;
    var child = gtk.Widget.getFirstChild(overlay.as(gtk.Widget));
    while (child) |current| : (child = gtk.Widget.getNextSibling(current)) {
        has_drag_region = has_drag_region or gtk.Widget.hasCssClass(current, "app-window-drag-region") != 0;
        has_controls = has_controls or gtk.Widget.hasCssClass(current, "app-window-controls-overlay") != 0;
    }

    try std.testing.expect(!has_drag_region);
    try std.testing.expect(has_controls);
    try std.testing.expect(gtk.Widget.hasCssClass(content.as(gtk.Widget), "app-window-content") == 0);
}

test "chrome row keeps the sidebar toggle outside a vertically fixed drag area" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const toggle = gtk.Button.new();
    const chrome = buildChromeRow(toggle);
    _ = chrome.as(gobject.Object).refSink();
    defer chrome.as(gobject.Object).unref();

    const toggle_widget = toggle.as(gtk.Widget);
    try std.testing.expect(gtk.Widget.getFirstChild(chrome.as(gtk.Widget)) == toggle_widget);
    try std.testing.expectEqual(gtk.Align.center, gtk.Widget.getValign(toggle_widget));

    const drag_region = gtk.Widget.getNextSibling(toggle_widget) orelse return error.TestUnexpectedResult;
    try std.testing.expect(gtk.Widget.hasCssClass(drag_region, "app-window-drag-region") != 0);
    try std.testing.expectEqual(@as(c_int, 1), gtk.Widget.getHexpand(drag_region));
    try std.testing.expectEqual(@as(c_int, 0), gtk.Widget.getVexpand(drag_region));
    try std.testing.expectEqual(gtk.Align.fill, gtk.Widget.getValign(drag_region));
}

test "overlay chrome exposes resize handles for every edge and corner" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const overlay = gtk.Overlay.new();
    _ = overlay.as(gobject.Object).refSink();
    defer overlay.as(gobject.Object).unref();

    installOverlay(overlay);

    const expected_classes = [_][:0]const u8{
        "window-resize-north",
        "window-resize-north-east",
        "window-resize-east",
        "window-resize-south-east",
        "window-resize-south",
        "window-resize-south-west",
        "window-resize-west",
        "window-resize-north-west",
    };
    for (expected_classes) |expected_class| {
        var found = false;
        var child = gtk.Widget.getFirstChild(overlay.as(gtk.Widget));
        while (child) |current| : (child = gtk.Widget.getNextSibling(current)) {
            found = found or gtk.Widget.hasCssClass(current, expected_class) != 0;
        }
        try std.testing.expect(found);
    }
}
