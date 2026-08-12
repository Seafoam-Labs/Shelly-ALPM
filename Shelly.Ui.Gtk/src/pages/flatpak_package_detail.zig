const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const c_string = @import("../helpers/c_string.zig");
const translations = @import("../helpers/translations.zig");
const support = @import("support.zig");
const Hit = @import("../models/flatpak.zig").Hit;
const SizeConverter = @import("../helpers/size_converts.zig").SizeConverter;

pub const FlatpakPackageDetail = extern struct {
    parent_instance: Parent,
    const Self = @This();
    pub const Parent = gtk.Box;
    const resource_path = "/com/shellyorg/shelly/ui/flatpak_package_detail.ui";

    const Private = struct {
        content_box: *gtk.Box,
        name_label: *gtk.Label,
        summary_label: *gtk.Label,
        spec_box: *gtk.Box,
        about_header: *gtk.Label,
        about_label: *gtk.Label,

        arena: ?*std.heap.ArenaAllocator,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyFlatpakPackageDetail",
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
        p.arena = null;
    }

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn showHit(self: *Self, hit: *const Hit) void {
        const p = self.priv();

        if (p.arena) |old| {
            old.deinit();
            std.heap.c_allocator.destroy(old);
        }

        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        p.arena = arena_ptr;

        self.populate(hit.*);
    }

    fn populate(self: *Self, hit: Hit) void {
        const p = self.priv();
        var buf: [512]u8 = undefined;
        var size_buf: [64]u8 = undefined;

        const display_name = if (hit.name.len > 0) hit.name else hit.id;
        gtk.Label.setLabel(p.name_label, c_string.cstr(&buf, display_name));
        p.name_label.setSelectable(1);
        gtk.Label.setLabel(p.summary_label, c_string.cstr(&buf, hit.summary));

        clear_box(p.spec_box);

        add_spec_row(p.spec_box, translations._("App ID"), c_string.cstr(&buf, hit.id));
        add_spec_row(p.spec_box, translations._("Remote"), c_string.cstr(&buf, hit.remote));
        if (hit.developer_name.len > 0)
            add_spec_row(p.spec_box, translations._("Developer"), c_string.cstr(&buf, hit.developer_name));
        if (hit.project_license.len > 0)
            add_spec_row(p.spec_box, translations._("License"), c_string.cstr(&buf, hit.project_license));
        if (hit.type.len > 0)
            add_spec_row(p.spec_box, translations._("Type"), c_string.cstr(&buf, hit.type));
        if (hit.download_size > 0)
            add_spec_row(p.spec_box, translations._("Download Size"), SizeConverter.convert_null_term(&size_buf, hit.download_size));
        if (hit.installed_size > 0)
            add_spec_row(p.spec_box, translations._("Installed Size"), SizeConverter.convert_null_term(&size_buf, hit.installed_size));
        add_spec_row(p.spec_box, translations._("Verified"), if (hit.verification_verified) translations._("Yes") else translations._("No"));

        const allocator = (p.arena orelse return).allocator();
        add_spec_list(p.spec_box, allocator, translations._("Categories"), hit.main_categories);
        add_spec_list(p.spec_box, allocator, translations._("Keywords"), hit.keywords);

        if (std.ascii.eqlIgnoreCase(hit.remote, "flathub")) {
            const combined = std.mem.concat(allocator, u8, &.{ "https://flathub.org/apps/", hit.id }) catch "";
            add_url_spec_row(p.spec_box, translations._("Flathub"), c_string.cstr(&buf, combined));
        }

        const has_about = hit.description.len > 0;
        gtk.Widget.setVisible(p.about_header.as(gtk.Widget), @intFromBool(has_about));
        gtk.Widget.setVisible(p.about_label.as(gtk.Widget), @intFromBool(has_about));
        if (has_about) {
            const about = formatDescription(allocator, hit.description) catch "";
            gtk.Label.setLabel(p.about_label, about);
        }
    }

    pub fn formatDescription(allocator: std.mem.Allocator, raw: []const u8) ![:0]u8 {
        var stripped: std.ArrayListUnmanaged(u8) = .empty;
        defer stripped.deinit(allocator);

        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '<') {
                const end = std.mem.indexOfScalarPos(u8, raw, i + 1, '>') orelse {
                    try stripped.appendSlice(allocator, raw[i..]);
                    break;
                };
                try emitTag(&stripped, allocator, raw[i + 1 .. end]);
                i = end + 1;
                continue;
            }
            if (c == '&') {
                if (entityText(raw, i)) |entity| {
                    try stripped.appendSlice(allocator, entity.text);
                    i = entity.end;
                    continue;
                }
            }
            try stripped.append(allocator, c);
            i += 1;
        }

        return normalizeWhitespace(allocator, stripped.items);
    }

    fn emitTag(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, tag: []const u8) !void {
        var name = std.mem.trim(u8, tag, " \t\r\n");
        var closing = false;
        if (std.mem.startsWith(u8, name, "/")) {
            closing = true;
            name = std.mem.trim(u8, name[1..], " \t\r\n");
        }

        var name_len: usize = 0;
        while (name_len < name.len) {
            const ch = name[name_len];
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == '/') break;
            name_len += 1;
        }
        const element = name[0..name_len];
        if (element.len == 0) return;

        if (std.ascii.eqlIgnoreCase(element, "br")) {
            try out.append(allocator, '\n');
            return;
        }
        if (std.ascii.eqlIgnoreCase(element, "li")) {
            if (!closing) try out.appendSlice(allocator, "\n\u{2022} ");
            return;
        }
        const blocks = [_][]const u8{ "p", "div", "ul", "ol", "table", "blockquote", "section", "article", "pre", "h1", "h2", "h3", "h4", "h5", "h6" };
        for (blocks) |block| {
            if (std.ascii.eqlIgnoreCase(element, block)) {
                try out.appendSlice(allocator, "\n\n");
                return;
            }
        }
    }

    const Entity = struct {
        text: []const u8,
        end: usize,
    };

    fn entityText(raw: []const u8, start: usize) ?Entity {
        const semi = std.mem.indexOfScalarPos(u8, raw, start + 1, ';') orelse return null;
        const body = raw[start + 1 .. semi];
        const end = semi + 1;
        const known = [_]struct { name: []const u8, text: []const u8 }{
            .{ .name = "amp", .text = "&" },
            .{ .name = "lt", .text = "<" },
            .{ .name = "gt", .text = ">" },
            .{ .name = "quot", .text = "\"" },
            .{ .name = "apos", .text = "'" },
            .{ .name = "nbsp", .text = " " },
            .{ .name = "ndash", .text = "\u{2013}" },
            .{ .name = "mdash", .text = "\u{2014}" },
            .{ .name = "hellip", .text = "\u{2026}" },
            .{ .name = "lsquo", .text = "'" },
            .{ .name = "rsquo", .text = "'" },
            .{ .name = "ldquo", .text = "\"" },
            .{ .name = "rdquo", .text = "\"" },
        };
        for (known) |entry| {
            if (std.mem.eql(u8, body, entry.name)) return .{ .text = entry.text, .end = end };
        }
        return null;
    }

    fn normalizeWhitespace(allocator: std.mem.Allocator, text: []const u8) ![:0]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        var i: usize = 0;
        var newline_run: usize = 0;
        var space_pending = false;

        while (i < text.len) {
            const c = text[i];
            i += 1;
            if (c == '\n' or c == '\r') {
                newline_run += 1;
                space_pending = false;
                continue;
            }
            if (c == ' ' or c == '\t') {
                if (newline_run == 0 and out.items.len > 0) space_pending = true;
                continue;
            }
            if (newline_run > 0) {
                if (out.items.len > 0) {
                    const breaks: usize = if (newline_run >= 2) 2 else 1;
                    var b: usize = 0;
                    while (b < breaks) : (b += 1) try out.append(allocator, '\n');
                }
                newline_run = 0;
            } else if (space_pending) {
                try out.append(allocator, ' ');
            }
            space_pending = false;
            try out.append(allocator, c);
        }

        try out.append(allocator, 0);
        return out.items[0 .. out.items.len - 1 :0];
    }

    fn add_spec_row(box: *gtk.Box, label: []const u8, value: [:0]const u8) void {
        var lbuf: [64]u8 = undefined;
        const row = gtk.Box.new(.horizontal, 8);
        gtk.Widget.setMarginTop(row.as(gtk.Widget), 10);
        gtk.Widget.setMarginBottom(row.as(gtk.Widget), 10);
        gtk.Widget.addCssClass(row.as(gtk.Widget), "spec-row");
        const key = gtk.Label.new(c_string.cstr(&lbuf, label));
        gtk.Widget.setHalign(key.as(gtk.Widget), .start);
        gtk.Label.setXalign(key, 0);
        gtk.Widget.addCssClass(key.as(gtk.Widget), "dim-label");
        gtk.Box.append(row, key.as(gtk.Widget));
        const val = gtk.Label.new(value);
        gtk.Widget.setHalign(val.as(gtk.Widget), .end);
        gtk.Widget.setHexpand(val.as(gtk.Widget), 1);
        gtk.Label.setXalign(val, 1);
        gtk.Label.setEllipsize(val, .end);
        gtk.Widget.addCssClass(val.as(gtk.Widget), "spec-value");
        gtk.Box.append(row, val.as(gtk.Widget));
        gtk.Box.append(box, row.as(gtk.Widget));
    }

    fn add_url_spec_row(box: *gtk.Box, label: []const u8, value: [:0]const u8) void {
        var lbuf: [64]u8 = undefined;
        const row = gtk.Box.new(.horizontal, 8);
        gtk.Widget.setMarginTop(row.as(gtk.Widget), 10);
        gtk.Widget.setMarginBottom(row.as(gtk.Widget), 10);
        gtk.Widget.addCssClass(row.as(gtk.Widget), "spec-row");
        const key = gtk.Label.new(c_string.cstr(&lbuf, label));
        gtk.Widget.setHalign(key.as(gtk.Widget), .start);
        gtk.Label.setXalign(key, 0);
        gtk.Widget.addCssClass(key.as(gtk.Widget), "dim-label");
        gtk.Box.append(row, key.as(gtk.Widget));

        var mbuf: [256]u8 = undefined;
        const markup = std.fmt.bufPrintZ(&mbuf, "<a href=\"{s}\">{s}</a>", .{ value, value }) catch value;
        const val = gtk.Label.new(null);
        gtk.Label.setMarkup(val, markup);
        gtk.Widget.setHalign(val.as(gtk.Widget), .end);
        gtk.Widget.setHexpand(val.as(gtk.Widget), 1);
        gtk.Label.setXalign(val, 1);
        gtk.Label.setEllipsize(val, .end);

        gtk.Box.append(row, val.as(gtk.Widget));

        gtk.Box.append(box, row.as(gtk.Widget));
    }

    fn add_spec_list(box: *gtk.Box, allocator: std.mem.Allocator, label: []const u8, items: []const []const u8) void {
        if (items.len == 0) return;
        var joined: std.ArrayListUnmanaged(u8) = .empty;
        defer joined.deinit(allocator);
        for (items, 0..) |item, i| {
            if (i > 0) joined.appendSlice(allocator, ", ") catch return;
            joined.appendSlice(allocator, item) catch return;
        }
        joined.append(allocator, 0) catch return;
        const value: [:0]const u8 = joined.items[0 .. joined.items.len - 1 :0];
        add_spec_row_raw(box, label, value);
    }

    fn add_spec_row_raw(box: *gtk.Box, label: []const u8, value: [:0]const u8) void {
        var lbuf: [64]u8 = undefined;
        const row = gtk.Box.new(.horizontal, 8);
        gtk.Widget.setMarginTop(row.as(gtk.Widget), 10);
        gtk.Widget.setMarginBottom(row.as(gtk.Widget), 10);
        gtk.Widget.addCssClass(row.as(gtk.Widget), "spec-row");
        const key = gtk.Label.new(c_string.cstr(&lbuf, label));
        gtk.Widget.setHalign(key.as(gtk.Widget), .start);
        gtk.Widget.setValign(key.as(gtk.Widget), .start);
        gtk.Label.setXalign(key, 0);
        gtk.Widget.addCssClass(key.as(gtk.Widget), "dim-label");
        gtk.Box.append(row, key.as(gtk.Widget));
        const val = gtk.Label.new(value);
        gtk.Widget.setHalign(val.as(gtk.Widget), .end);
        gtk.Widget.setHexpand(val.as(gtk.Widget), 1);
        gtk.Label.setXalign(val, 1);
        gtk.Label.setWrap(val, 1);
        gtk.Label.setJustify(val, .right);
        gtk.Widget.addCssClass(val.as(gtk.Widget), "spec-value");
        gtk.Box.append(row, val.as(gtk.Widget));
        gtk.Box.append(box, row.as(gtk.Widget));
    }

    fn clear_box(box: *gtk.Box) void {
        while (gtk.Widget.getFirstChild(box.as(gtk.Widget))) |child| {
            gtk.Box.remove(box, child);
        }
    }

    fn finalize(self: *Self) callconv(.c) void {
        const p = self.priv();

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }
        const parent_class: *gobject.Object.Class = @ptrCast(Class.parent);
        gobject.Object.virtual_methods.finalize.call(parent_class, self.as(gobject.Object));
    }

    const template_children = .{
        .{ "content_box", @offsetOf(Private, "content_box") },
        .{ "name_label", @offsetOf(Private, "name_label") },
        .{ "summary_label", @offsetOf(Private, "summary_label") },
        .{ "spec_box", @offsetOf(Private, "spec_box") },
        .{ "about_header", @offsetOf(Private, "about_header") },
        .{ "about_label", @offsetOf(Private, "about_label") },
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
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};

test "formatDescription converts markup to paragraphs and bullets" {
    const raw = "<p>Firefox is a fast &amp; private browser.</p><p>Features:</p><ul><li>Speed</li><li>Privacy</li></ul>";
    const out = try FlatpakPackageDetail.formatDescription(std.testing.allocator, raw);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Firefox is a fast & private browser.\n\nFeatures:\n\n\u{2022} Speed\n\u{2022} Privacy", out);
}

test "formatDescription preserves plain text paragraphs" {
    const raw = "Line one.\n\nLine two\nwrapped.";
    const out = try FlatpakPackageDetail.formatDescription(std.testing.allocator, raw);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Line one.\n\nLine two\nwrapped.", out);
}

test "formatDescription strips inline tags and decodes entities" {
    const raw = "An <em>emphasized</em> app &mdash; with <a href=\"https://example.org\">links</a&gt; inside.";
    const out = try FlatpakPackageDetail.formatDescription(std.testing.allocator, raw);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("An emphasized app \u{2014} with links inside.", out);
}

test "formatDescription trims leading and trailing whitespace" {
    const raw = "\n\n  <p>Hello</p>  \n\n";
    const out = try FlatpakPackageDetail.formatDescription(std.testing.allocator, raw);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Hello", out);
}
