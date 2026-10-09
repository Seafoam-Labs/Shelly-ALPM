const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const support = @import("../../pages/support.zig");
const translations = @import("../../helpers/translations.zig");

pub const PermissionsDialog = extern struct {
    parent_instance: Parent,
    const Self = @This();
    pub const Parent = gtk.Box;
    const resource_path = "/com/shellyorg/shelly/dialog/ui/permissions.ui";

    pub const CloseFn = *const fn (ctx: ?*anyopaque) void;

    const Private = struct {
        title_label: *gtk.Label,
        subtitle_label: *gtk.Label,
        permissions_stack: *gtk.Stack,
        permissions_list: *gtk.ListBox,
        close_button: *gtk.Button,
        on_close: ?CloseFn,
        ctx: ?*anyopaque,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyPermissionsDialog",
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
        p.on_close = null;
        p.ctx = null;
    }

    /// Borrows `permissions`; strings are copied into labels before returning,
    /// The only current caller of this holds its strings in an arena, so they wont be free'd until that arena has been free'd
    /// A null `permissions` means they could not be read.
    pub fn new(title: [:0]const u8, subtitle: [:0]const u8, permissions: ?[]const [:0]const u8, on_close_fn: CloseFn, ctx: ?*anyopaque) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const p = self.priv();
        gtk.Label.setLabel(p.title_label, title);
        gtk.Label.setLabel(p.subtitle_label, subtitle);
        p.on_close = on_close_fn;
        p.ctx = ctx;

        var shown: usize = 0;
        if (permissions) |granted| {
            for (granted) |perm| {
                const parsed = parse_permission(perm) orelse continue;
                gtk.ListBox.append(p.permissions_list, make_row(parsed));
                shown += 1;
            }
        }

        gtk.Stack.setVisibleChildName(p.permissions_stack, page_for(permissions, shown));
        return self;
    }

    /// A list that is missing, or that yielded no renderable row, means the
    /// permissions could not be read. Only a list that was read and holds
    /// nothing may claim the app requests no permissions.
    fn page_for(permissions: ?[]const [:0]const u8, shown: usize) [:0]const u8 {
        const granted = permissions orelse return "unavailable";
        if (shown > 0) return "list";
        return if (granted.len == 0) "empty" else "unavailable";
    }

    pub fn setButtons(self: *Self, close: [:0]const u8) void {
        gtk.Button.setLabel(self.priv().close_button, close);
    }

    const Permission = struct {
        category: []const u8,
        value: []const u8,
    };

    fn parse_permission(raw: []const u8) ?Permission {
        const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return null;
        const rest = raw[eq + 1 ..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
        const category = rest[0..colon];
        const value = rest[colon + 1 ..];
        if (category.len == 0 or value.len == 0) return null;
        return .{ .category = category, .value = value };
    }

    fn icon_for_category(category: []const u8) [:0]const u8 {
        if (std.mem.eql(u8, category, "filesystems")) return "folder-symbolic";
        if (std.mem.eql(u8, category, "devices")) return "drive-harddisk-symbolic";
        if (std.mem.eql(u8, category, "sockets")) return "network-transmit-receive-symbolic";
        if (std.mem.eql(u8, category, "shared")) return "emblem-shared-symbolic";
        if (std.mem.eql(u8, category, "unset-environment")) return "utilities-terminal-symbolic";
        if (std.mem.eql(u8, category, "session-bus")) return "network-server-symbolic";
        if (std.mem.eql(u8, category, "system-bus")) return "network-server-symbolic";
        return "dialog-information-symbolic";
    }

    fn label_for_category(category: []const u8) [:0]const u8 {
        if (std.mem.eql(u8, category, "filesystems")) return translations._("Filesystem");
        if (std.mem.eql(u8, category, "devices")) return translations._("Devices");
        if (std.mem.eql(u8, category, "sockets")) return translations._("Sockets");
        if (std.mem.eql(u8, category, "shared")) return translations._("Shared");
        if (std.mem.eql(u8, category, "unset-environment")) return translations._("Environment");
        if (std.mem.eql(u8, category, "session-bus")) return translations._("Session bus");
        if (std.mem.eql(u8, category, "system-bus")) return translations._("System bus");
        return translations._("Other");
    }

    fn make_row(perm: Permission) *gtk.Widget {
        const row = gtk.ListBoxRow.new();
        const box = gtk.Box.new(.horizontal, 12);
        gtk.Widget.setMarginStart(box.as(gtk.Widget), 12);
        gtk.Widget.setMarginEnd(box.as(gtk.Widget), 12);
        gtk.Widget.setMarginTop(box.as(gtk.Widget), 8);
        gtk.Widget.setMarginBottom(box.as(gtk.Widget), 8);

        const icon = gtk.Image.newFromIconName(icon_for_category(perm.category));
        gtk.Widget.setValign(icon.as(gtk.Widget), .center);
        gtk.Box.append(box, icon.as(gtk.Widget));

        const text = gtk.Box.new(.vertical, 2);
        gtk.Widget.setHexpand(text.as(gtk.Widget), 1);

        var value_buffer: [512]u8 = undefined;
        const value_z = std.fmt.bufPrintZ(&value_buffer, "{s}", .{perm.value}) catch "";
        const value_label = gtk.Label.new(value_z);
        gtk.Label.setXalign(value_label, 0);
        gtk.Label.setWrap(value_label, 1);
        gtk.Label.setSelectable(value_label, 1);
        gtk.Widget.addCssClass(value_label.as(gtk.Widget), "heading");
        gtk.Box.append(text, value_label.as(gtk.Widget));

        const category_label = gtk.Label.new(label_for_category(perm.category));
        gtk.Label.setXalign(category_label, 0);
        gtk.Widget.addCssClass(category_label.as(gtk.Widget), "dim-label");
        gtk.Widget.addCssClass(category_label.as(gtk.Widget), "caption");
        gtk.Box.append(text, category_label.as(gtk.Widget));

        gtk.Box.append(box, text.as(gtk.Widget));
        gtk.ListBoxRow.setChild(row, box.as(gtk.Widget));
        return row.as(gtk.Widget);
    }

    fn on_close(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.on_close) |cb| cb(p.ctx);
    }

    const template_children = .{
        .{ "title_label", @offsetOf(Private, "title_label") },
        .{ "subtitle_label", @offsetOf(Private, "subtitle_label") },
        .{ "permissions_stack", @offsetOf(Private, "permissions_stack") },
        .{ "permissions_list", @offsetOf(Private, "permissions_list") },
        .{ "close_button", @offsetOf(Private, "close_button") },
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
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_close", @ptrCast(&on_close));
        }
    };
};

test "permissions dialog separates unreadable from unrequested" {
    const one = [_][:0]const u8{"Context=shared:network"};
    const none = [_][:0]const u8{};
    try std.testing.expectEqualStrings("list", PermissionsDialog.page_for(&one, 1));
    try std.testing.expectEqualStrings("empty", PermissionsDialog.page_for(&none, 0));
    try std.testing.expectEqualStrings("unavailable", PermissionsDialog.page_for(null, 0));
    try std.testing.expectEqualStrings("unavailable", PermissionsDialog.page_for(&one, 0));
}
