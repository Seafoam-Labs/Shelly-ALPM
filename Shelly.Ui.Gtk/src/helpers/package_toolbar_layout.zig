const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;

fn horizontalMinimum(box: *gtk.Box) c_int {
    var minimum_width: c_int = 0;
    var visible_children: c_int = 0;
    var child = gtk.Widget.getFirstChild(box.as(gtk.Widget));
    while (child) |current| : (child = gtk.Widget.getNextSibling(current)) {
        if (gtk.Widget.getVisible(current) == 0) continue;

        var child_minimum: c_int = 0;
        gtk.Widget.measure(current, .horizontal, -1, &child_minimum, null, null, null);
        minimum_width += child_minimum;
        visible_children += 1;
    }

    if (visible_children > 1) {
        minimum_width += gtk.Box.getSpacing(box) * (visible_children - 1);
    }
    return minimum_width;
}

fn fitBox(box: *gtk.Box, available_width: c_int) void {
    gtk.Orientable.setOrientation(
        box.as(gtk.Orientable),
        if (horizontalMinimum(box) <= available_width) .horizontal else .vertical,
    );
}

pub fn apply(
    toolbar: *gtk.Box,
    filters: *gtk.Box,
    actions: *gtk.Box,
    spacer: *gtk.Box,
    available_width: c_int,
) void {
    if (available_width <= 0) return;

    // Keep enough room for the toolbar's horizontal CSS margins and spacing.
    const content_width = @max(available_width - 24, 1);
    fitBox(filters, content_width);
    fitBox(actions, content_width);

    const fits_single_row = horizontalMinimum(toolbar) <= content_width;
    gtk.Widget.setVisible(spacer.as(gtk.Widget), @intFromBool(fits_single_row));
    gtk.Orientable.setOrientation(
        toolbar.as(gtk.Orientable),
        if (fits_single_row) .horizontal else .vertical,
    );
}
