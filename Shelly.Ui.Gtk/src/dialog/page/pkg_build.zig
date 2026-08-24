const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const glib = bindings.glib;
const gobject = bindings.gobject;
const support = @import("../../pages/support.zig");
const translations = @import("../../helpers/translations.zig");
const theme_manager = @import("../../services/theme_manager.zig");
const window_controls = @import("../../window_controls.zig");

pub const PkgbuildReviewDialog = extern struct {
    parent_instance: Parent,
    const Self = @This();
    pub const Parent = gtk.Window;
    const resource_path = "/com/shellyorg/shelly/dialog/ui/pkg_build.ui";

    pub const ResponseFn = *const fn (ctx: ?*anyopaque, confirmed: bool) void;

    const changes_page: c_int = 0;

    pub const Warning = struct {
        tool: [:0]const u8 = "",
        hook: [:0]const u8 = "",
        severity: [:0]const u8 = "",
        message: [:0]const u8 = "",
        matched_line: [:0]const u8 = "",
    };

    pub const SourceFile = struct {
        name: [:0]const u8 = "",
        content: [:0]const u8 = "",
    };

    const Private = struct {
        root_overlay: *gtk.Overlay,
        drag_region: *gtk.WindowHandle,
        heading_label: *gtk.Label,
        notebook: *gtk.Notebook,
        diff_box: *gtk.Box,
        warnings_page: *gtk.ScrolledWindow,
        warnings_box: *gtk.Box,
        sources_page: *gtk.ScrolledWindow,
        sources_box: *gtk.Box,
        scan_icon: *gtk.Image,
        scan_label: *gtk.Label,
        cancel_button: *gtk.Button,
        proceed_button: *gtk.Button,

        on_response: ?ResponseFn,
        ctx: ?*anyopaque,
        changes_reviewed: bool,
        responded: bool,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyPkgbuildReviewDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    fn priv(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const p = self.priv();
        p.on_response = null;
        p.ctx = null;
        p.changes_reviewed = false;
        p.responded = false;
        window_controls.installOverlay(p.root_overlay);
        _ = gtk.Notebook.signals.switch_page.connect(p.notebook, *Self, &on_switch_page, self, .{});
    }

    /// Takes ownership of `diff_lines`, `warnings`, `source_files` and all their
    /// strings; copies into widgets and frees them before returning.
    pub fn new(
        package_name: [:0]const u8,
        diff_lines: []const [:0]const u8,
        warnings: []const Warning,
        source_files: []const SourceFile,
        on_response: ResponseFn,
        ctx: ?*anyopaque,
    ) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const p = self.priv();
        p.on_response = on_response;
        p.ctx = ctx;

        var heading_buffer: [512]u8 = undefined;
        const heading = std.fmt.bufPrintZ(&heading_buffer, "{s} {s}", .{ translations._("Review PKGBUILD changes for"), package_name }) catch translations._("Review PKGBUILD changes");
        gtk.Label.setLabel(p.heading_label, heading);

        const diff_view = gtk.TextView.new();
        gtk.TextView.setEditable(diff_view, 0);
        gtk.TextView.setMonospace(diff_view, 1);
        gtk.TextView.setWrapMode(diff_view, .word_char);
        gtk.TextView.setCursorVisible(diff_view, 0);
        const diff_buffer = gtk.TextView.getBuffer(diff_view);

        var diff_iter: gtk.TextIter = undefined;
        gtk.TextBuffer.getEndIter(diff_buffer, &diff_iter);
        for (diff_lines, 0..) |raw, i| {
            if (i > 0) {
                gtk.TextBuffer.insert(diff_buffer, &diff_iter, "\n", 1);
            }

            const parsed = parse_diff_line(raw);
            const escaped = glib.markupEscapeText(@ptrCast(parsed.text.ptr), @intCast(parsed.text.len));
            defer glib.free(escaped);

            var markup_buffer: [4096]u8 = undefined;
            const markup = if (pango_color(parsed.color orelse "")) |hex|
                std.fmt.bufPrintZ(
                    &markup_buffer,
                    "<tt><span foreground=\"{s}\">{s}</span></tt>",
                    .{ hex, escaped },
                ) catch null
            else
                std.fmt.bufPrintZ(&markup_buffer, "<tt>{s}</tt>", .{escaped}) catch null;

            if (markup) |m| {
                gtk.TextBuffer.insertMarkup(diff_buffer, &diff_iter, m, -1);
            } else {
                gtk.TextBuffer.insert(diff_buffer, &diff_iter, raw, @intCast(raw.len));
            }
        }
        gtk.Box.append(p.diff_box, diff_view.as(gtk.Widget));

        const has_warnings = warnings.len > 0;
        if (has_warnings) {
            gtk.Box.append(p.warnings_box, make_warnings_view(warnings));
        }
        gtk.Widget.setVisible(p.warnings_page.as(gtk.Widget), @intFromBool(has_warnings));

        for (source_files) |file| {
            gtk.Box.append(p.sources_box, make_source_row(file));
        }
        gtk.Widget.setVisible(p.sources_page.as(gtk.Widget), @intFromBool(source_files.len > 0));

        set_scan_banner(p, has_warnings, warnings.len);

        p.changes_reviewed = !has_warnings;
        if (has_warnings) {
            gtk.Button.setLabel(p.proceed_button, translations._("Review Changes"));
        }

        return self;
    }

    pub fn present(self: *Self) void {
        const p = self.priv();
        const theme = if (gtk.Window.getTransientFor(self.as(gtk.Window))) |parent| blk: {
            self.applyAvailableSize(
                gtk.Widget.getWidth(parent.as(gtk.Widget)),
                gtk.Widget.getHeight(parent.as(gtk.Widget)),
            );
            break :blk theme_manager.inherit(self.as(gtk.Widget), parent.as(gtk.Widget));
        } else blk: {
            theme_manager.apply(self.as(gtk.Widget), .classic);
            break :blk .classic;
        };
        window_controls.configureChildWindow(
            self.as(gtk.Window),
            p.root_overlay,
            p.drag_region.as(gtk.Widget),
            theme_manager.isDark(theme),
        );
        gtk.Window.present(self.as(gtk.Window));
        if (p.changes_reviewed) {
            _ = gtk.Widget.grabFocus(p.proceed_button.as(gtk.Widget));
        } else {
            _ = gtk.Widget.grabFocus(p.cancel_button.as(gtk.Widget));
        }
    }

    pub fn applyAvailableSize(self: *Self, available_width: c_int, available_height: c_int) void {
        if (available_width <= 0 or available_height <= 0) return;
        gtk.Window.setDefaultSize(
            self.as(gtk.Window),
            @divTrunc(available_width * 3, 4),
            @divTrunc(available_height * 3, 4),
        );
    }

    fn set_scan_banner(p: *Private, has_warnings: bool, count: usize) void {
        if (has_warnings) {
            gtk.Image.setFromIconName(p.scan_icon, "dialog-warning-symbolic");
            var buffer: [128]u8 = undefined;
            const text = std.fmt.bufPrintZ(
                &buffer,
                "{s} {d} {s}",
                .{ translations._("Security scan completed -"), count, translations._("warning(s) found.") },
            ) catch translations._("Security scan completed - warnings found.");
            gtk.Label.setLabel(p.scan_label, text);
            gtk.Widget.removeCssClass(p.scan_label.as(gtk.Widget), "success");
            gtk.Widget.addCssClass(p.scan_label.as(gtk.Widget), "warning");
        } else {
            gtk.Image.setFromIconName(p.scan_icon, "security-high-symbolic");
            gtk.Label.setLabel(p.scan_label, translations._("Security scan completed - no issues found."));
        }
    }

    fn make_source_row(file: SourceFile) *gtk.Widget {
        const box = gtk.Box.new(.vertical, 6);
        gtk.Widget.setMarginTop(box.as(gtk.Widget), 6);

        const title = gtk.Label.new(file.name);
        gtk.Label.setXalign(title, 0);
        gtk.Widget.addCssClass(title.as(gtk.Widget), "heading");
        gtk.Box.append(box, title.as(gtk.Widget));

        const view = gtk.TextView.new();
        gtk.TextView.setEditable(view, 0);
        gtk.TextView.setMonospace(view, 1);
        gtk.TextView.setWrapMode(view, .word_char);
        gtk.TextView.setCursorVisible(view, 0);
        const buffer = gtk.TextView.getBuffer(view);
        gtk.TextBuffer.setText(buffer, file.content, @intCast(file.content.len));

        const scroll = gtk.ScrolledWindow.new();
        gtk.ScrolledWindow.setPolicy(scroll, .automatic, .automatic);
        gtk.ScrolledWindow.setMinContentHeight(scroll, 160);
        gtk.ScrolledWindow.setChild(scroll, view.as(gtk.Widget));

        const frame = gtk.Frame.new(null);
        gtk.Frame.setChild(frame, scroll.as(gtk.Widget));
        gtk.Box.append(box, frame.as(gtk.Widget));

        return box.as(gtk.Widget);
    }

    fn make_warnings_view(warnings: []const Warning) *gtk.Widget {
        const view = gtk.TextView.new();
        gtk.TextView.setEditable(view, 0);
        gtk.TextView.setMonospace(view, 1);
        gtk.TextView.setWrapMode(view, .word_char);
        gtk.TextView.setCursorVisible(view, 0);
        const buffer = gtk.TextView.getBuffer(view);

        var iter: gtk.TextIter = undefined;
        gtk.TextBuffer.getEndIter(buffer, &iter);

        const used_in = translations._("used in");
        for (warnings, 0..) |warning, i| {
            if (i > 0) {
                gtk.TextBuffer.insert(buffer, &iter, "\n", 1);
            }

            const escaped_tool = glib.markupEscapeText(warning.tool, -1);
            defer glib.free(escaped_tool);
            const escaped_hook = glib.markupEscapeText(warning.hook, -1);
            defer glib.free(escaped_hook);

            var title_buffer: [512]u8 = undefined;
            const severity_color = if (std.mem.eql(u8, warning.severity, "Critical")) "#c01c28" else "#e5a50a";
            const title_markup = std.fmt.bufPrintZ(
                &title_buffer,
                "<b><span foreground=\"{s}\">{s} {s} {s}</span></b>",
                .{ severity_color, escaped_tool, used_in, escaped_hook },
            ) catch null;

            if (title_markup) |markup| {
                gtk.TextBuffer.insertMarkup(buffer, &iter, markup, -1);
            } else {
                gtk.TextBuffer.insert(buffer, &iter, warning.tool, @intCast(warning.tool.len));
                gtk.TextBuffer.insert(buffer, &iter, " ", 1);
                gtk.TextBuffer.insert(buffer, &iter, used_in, @intCast(used_in.len));
                gtk.TextBuffer.insert(buffer, &iter, " ", 1);
                gtk.TextBuffer.insert(buffer, &iter, warning.hook, @intCast(warning.hook.len));
            }

            if (warning.message.len > 0) {
                gtk.TextBuffer.insert(buffer, &iter, "\n", 1);
                gtk.TextBuffer.insert(buffer, &iter, warning.message, @intCast(warning.message.len));
            }

            if (warning.matched_line.len > 0) {
                gtk.TextBuffer.insert(buffer, &iter, "\n", 1);
                gtk.TextBuffer.insert(buffer, &iter, warning.matched_line, @intCast(warning.matched_line.len));
            }
        }

        return view.as(gtk.Widget);
    }

    const DiffLine = struct {
        color: ?[]const u8,
        text: []const u8,
    };

    /// "[green]+ foo[/]" -> { "green", "+ foo" }
    /// Unrecognized shapes come back with a null color and the raw text.
    fn parse_diff_line(raw: []const u8) DiffLine {
        if (raw.len == 0 or raw[0] != '[') return .{ .color = null, .text = raw };
        const close = std.mem.indexOfScalar(u8, raw, ']') orelse return .{ .color = null, .text = raw };
        const tag = raw[1..close];
        if (tag.len == 0) return .{ .color = null, .text = raw };

        var text = raw[close + 1 ..];
        if (std.mem.endsWith(u8, text, "[/]")) {
            text = text[0 .. text.len - 3];
        }
        return .{ .color = tag, .text = text };
    }

    fn pango_color(tag: []const u8) ?[:0]const u8 {
        if (std.mem.eql(u8, tag, "green")) return "#26a269";
        if (std.mem.eql(u8, tag, "red")) return "#c01c28";
        if (std.mem.eql(u8, tag, "yellow")) return "#e5a50a";
        if (std.mem.eql(u8, tag, "white")) return null;
        return null;
    }

    fn mark_changes_reviewed(self: *Self) void {
        const p = self.priv();
        if (p.changes_reviewed) return;
        p.changes_reviewed = true;
        gtk.Widget.removeCssClass(p.proceed_button.as(gtk.Widget), "suggested-action");
        gtk.Widget.addCssClass(p.proceed_button.as(gtk.Widget), "destructive-action");
        gtk.Button.setLabel(p.proceed_button, translations._("Install Anyway"));
    }

    fn respond(self: *Self, confirmed: bool) void {
        const p = self.priv();
        if (p.responded) return;
        p.responded = true;
        if (p.on_response) |cb| cb(p.ctx, confirmed);
        gtk.Window.close(self.as(gtk.Window));
    }

    fn on_switch_page(_: *gtk.Notebook, _: *gtk.Widget, page_num: c_uint, self: *Self) callconv(.c) void {
        if (page_num == changes_page) self.mark_changes_reviewed();
    }

    fn on_proceed(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (!p.changes_reviewed) {
            gtk.Notebook.setCurrentPage(p.notebook, changes_page);
            self.mark_changes_reviewed();
            return;
        }
        self.respond(true);
    }

    fn on_cancel(self: *Self) callconv(.c) void {
        self.respond(false);
    }

    fn on_close_request(self: *Self) callconv(.c) c_int {
        self.respond(false);
        return 0;
    }

    const template_children = .{
        .{ "root_overlay", @offsetOf(Private, "root_overlay") },
        .{ "drag_region", @offsetOf(Private, "drag_region") },
        .{ "heading_label", @offsetOf(Private, "heading_label") },
        .{ "notebook", @offsetOf(Private, "notebook") },
        .{ "diff_box", @offsetOf(Private, "diff_box") },
        .{ "warnings_page", @offsetOf(Private, "warnings_page") },
        .{ "warnings_box", @offsetOf(Private, "warnings_box") },
        .{ "sources_page", @offsetOf(Private, "sources_page") },
        .{ "sources_box", @offsetOf(Private, "sources_box") },
        .{ "scan_icon", @offsetOf(Private, "scan_icon") },
        .{ "scan_label", @offsetOf(Private, "scan_label") },
        .{ "cancel_button", @offsetOf(Private, "cancel_button") },
        .{ "proceed_button", @offsetOf(Private, "proceed_button") },
    };

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            const wc = gobject.ext.as(gtk.Widget.Class, class);
            gtk.Widget.Class.setTemplateFromResource(wc, resource_path);
            inline for (template_children) |c| {
                support.bindChild(class, Private.offset, c[0], c[1]);
            }
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_proceed", @ptrCast(&on_proceed));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_cancel", @ptrCast(&on_cancel));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_close_request", @ptrCast(&on_close_request));
        }
    };
};

test "PKGBUILD review window uses shared client-side chrome" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const dialog = gobject.ext.newInstance(PkgbuildReviewDialog, .{});
    _ = dialog.as(gobject.Object).refSink();
    defer dialog.as(gobject.Object).unref();

    const root = gtk.Widget.getFirstChild(dialog.as(gtk.Widget)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(gobject.ext.cast(gtk.Overlay, root) != null);

    const Find = struct {
        fn css(widget: *gtk.Widget, class_name: [:0]const u8) bool {
            if (gtk.Widget.hasCssClass(widget, class_name) != 0) return true;
            var child = gtk.Widget.getFirstChild(widget);
            while (child) |current| : (child = gtk.Widget.getNextSibling(current)) {
                if (css(current, class_name)) return true;
            }
            return false;
        }
    };

    try std.testing.expect(Find.css(root, "app-window-drag-region"));
    try std.testing.expect(Find.css(root, "app-window-controls-overlay"));
    try std.testing.expect(gtk.Widget.hasCssClass(dialog.as(gtk.Widget), "pkgbuild-window") != 0);
}
