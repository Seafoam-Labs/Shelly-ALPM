const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
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

pub fn install(headerbar: *gtk.HeaderBar) void {
    gtk.HeaderBar.setShowTitleButtons(headerbar, 0);
    gtk.HeaderBar.packEnd(headerbar, build().as(gtk.Widget));
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

test "install replaces the standard title buttons with custom controls" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const headerbar = gtk.HeaderBar.new();
    _ = headerbar.as(gobject.Object).refSink();
    defer headerbar.as(gobject.Object).unref();
    gtk.HeaderBar.setShowTitleButtons(headerbar, 1);

    install(headerbar);

    try std.testing.expectEqual(@as(c_int, 0), gtk.HeaderBar.getShowTitleButtons(headerbar));
}
