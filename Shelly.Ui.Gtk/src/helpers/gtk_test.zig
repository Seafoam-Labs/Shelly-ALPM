const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");

/// Call on the test runner thread before constructing any GTK widget.
pub fn requireDisplay() error{SkipZigTest}!void {
    // GTK can report initialized on a later initCheck() call even when the
    // first call failed to open a display. Widget construction still needs one.
    if (bindings.gtk.initCheck() == 0 or bindings.gdk.Display.getDefault() == null)
        return error.SkipZigTest;
}

test "GTK display guard remains safe across repeated initialization" {
    // Exercise GTK's actual process-global initialization state, including the
    // second call after a failed display connection in headless test runs.
    const first = requireDisplay();
    const second = requireDisplay();
    if (bindings.gdk.Display.getDefault() == null) {
        try std.testing.expectError(error.SkipZigTest, first);
        try std.testing.expectError(error.SkipZigTest, second);
    } else {
        try first;
        try second;
    }
}
