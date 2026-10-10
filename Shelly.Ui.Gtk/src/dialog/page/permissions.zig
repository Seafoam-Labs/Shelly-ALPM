const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const support = @import("../../pages/support.zig");
const translations = @import("../../helpers/translations.zig");
const flatpak = @import("../../models/flatpak.zig");

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

    /// Rows arrive already grouped, ranked and worded by the classifier in
    /// `Shelly.PackageManager`, through the CLI's JSON. Every string was copied
    /// into the holder's arena before this ran, so nothing here allocates.
    /// A null `permissions` means they could not be read.
    pub fn new(title: [:0]const u8, subtitle: [:0]const u8, permissions: ?[]const flatpak.PermissionDisplay, on_close_fn: CloseFn, ctx: ?*anyopaque) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const p = self.priv();
        gtk.Label.setLabel(p.title_label, title);
        gtk.Label.setLabel(p.subtitle_label, subtitle);
        p.on_close = on_close_fn;
        p.ctx = ctx;

        var shown: usize = 0;
        if (permissions) |rows| {
            for (rows) |row| {
                if (row.concern.len == 0) continue;
                gtk.ListBox.append(p.permissions_list, make_row(row));
                shown += 1;
            }
        }

        gtk.Stack.setVisibleChildName(p.permissions_stack, page_for(permissions, shown));
        return self;
    }

    /// A list that is missing, or that yielded no renderable row, means the
    /// permissions could not be read. Only a list that was read and holds
    /// nothing may claim the app requests no permissions.
    fn page_for(permissions: ?[]const flatpak.PermissionDisplay, shown: usize) [:0]const u8 {
        const rows = permissions orelse return "unavailable";
        if (shown > 0) return "list";
        return if (rows.len == 0) "empty" else "unavailable";
    }

    pub fn setButtons(self: *Self, close: [:0]const u8) void {
        gtk.Button.setLabel(self.priv().close_button, close);
    }

    /// One row per concern, so the titles are the English wording of
    /// `Concern.label` in `Shelly.PackageManager/src/flatpak/permissions.zig`,
    /// repeated as literals here because gettext can only extract those. Change
    /// one and change the other; the classifier's tests pin its side.
    ///
    /// An unknown tag falls through to "Other" rather than dropping the row, so
    /// a concern a newer CLI added still shows up instead of disappearing the
    /// way the six invented group names once did.
    fn title_for(row: flatpak.PermissionDisplay) [:0]const u8 {
        if (row.absent) return absence_for(row.concern);
        if (std.mem.eql(u8, row.concern, "files_system")) return translations._("System files");
        if (std.mem.eql(u8, row.concern, "files_paths")) return translations._("Other folders");
        if (std.mem.eql(u8, row.concern, "files_runtime")) return translations._("Running services");
        if (std.mem.eql(u8, row.concern, "files_config")) return translations._("Other apps' data");
        if (std.mem.eql(u8, row.concern, "files_home")) return translations._("Home folder");
        if (std.mem.eql(u8, row.concern, "files_user_dirs")) return translations._("User folders");
        if (std.mem.eql(u8, row.concern, "files_persistent")) return translations._("Persistent files");
        if (std.mem.eql(u8, row.concern, "devices")) return translations._("Devices");
        if (std.mem.eql(u8, row.concern, "session_bus")) return translations._("Session bus");
        if (std.mem.eql(u8, row.concern, "system_bus")) return translations._("System bus");
        if (std.mem.eql(u8, row.concern, "network")) return translations._("Network access");
        if (std.mem.eql(u8, row.concern, "display")) return translations._("Display server");
        if (std.mem.eql(u8, row.concern, "features")) return translations._("Sandbox features");
        if (std.mem.eql(u8, row.concern, "environment")) return translations._("Environment");
        if (std.mem.eql(u8, row.concern, "audio")) return translations._("Sound");
        if (std.mem.eql(u8, row.concern, "printing")) return translations._("Printing");
        if (std.mem.eql(u8, row.concern, "ipc")) return translations._("Inter-process communication");
        return translations._("Other");
    }

    /// The reassurances, stated the way the reference surfaces state them. Only
    /// the concerns the classifier answers for ever reach this.
    fn absence_for(concern: []const u8) [:0]const u8 {
        if (std.mem.eql(u8, concern, "network")) return translations._("No network access");
        if (std.mem.eql(u8, concern, "devices")) return translations._("No device access");
        if (std.mem.eql(u8, concern, "files_system")) return translations._("No access to system files");
        return translations._("Other");
    }

    fn icon_for(concern: []const u8) [:0]const u8 {
        if (std.mem.startsWith(u8, concern, "files_")) return "folder-symbolic";
        if (std.mem.eql(u8, concern, "devices")) return "drive-harddisk-symbolic";
        if (std.mem.eql(u8, concern, "session_bus") or std.mem.eql(u8, concern, "system_bus")) return "network-server-symbolic";
        if (std.mem.eql(u8, concern, "network")) return "network-transmit-receive-symbolic";
        if (std.mem.eql(u8, concern, "display")) return "video-display-symbolic";
        if (std.mem.eql(u8, concern, "features")) return "applications-system-symbolic";
        if (std.mem.eql(u8, concern, "environment")) return "utilities-terminal-symbolic";
        if (std.mem.eql(u8, concern, "audio")) return "audio-volume-high-symbolic";
        if (std.mem.eql(u8, concern, "printing")) return "printer-symbolic";
        if (std.mem.eql(u8, concern, "ipc")) return "emblem-shared-symbolic";
        return "dialog-information-symbolic";
    }

    /// Reuses the `.status-icon` rules already in style.css, which tint a
    /// symbolic icon by severity, so the ranking reads without adding a colour.
    fn tier_class(row: flatpak.PermissionDisplay) [:0]const u8 {
        if (row.absent) return "success";
        if (row.elevated()) return "error";
        if (row.middling()) return "warning";
        return "success";
    }

    fn make_row(row: flatpak.PermissionDisplay) *gtk.Widget {
        const list_row = gtk.ListBoxRow.new();
        const box = gtk.Box.new(.horizontal, 12);
        gtk.Widget.setMarginStart(box.as(gtk.Widget), 12);
        gtk.Widget.setMarginEnd(box.as(gtk.Widget), 12);
        gtk.Widget.setMarginTop(box.as(gtk.Widget), 8);
        gtk.Widget.setMarginBottom(box.as(gtk.Widget), 8);

        const icon = gtk.Image.newFromIconName(icon_for(row.concern));
        gtk.Widget.setValign(icon.as(gtk.Widget), .center);
        gtk.Widget.addCssClass(icon.as(gtk.Widget), "status-icon");
        gtk.Widget.addCssClass(icon.as(gtk.Widget), tier_class(row));
        gtk.Box.append(box, icon.as(gtk.Widget));

        const text = gtk.Box.new(.vertical, 2);
        gtk.Widget.setHexpand(text.as(gtk.Widget), 1);

        const title_label = gtk.Label.new(title_for(row).ptr);
        gtk.Label.setXalign(title_label, 0);
        gtk.Label.setWrap(title_label, 1);
        gtk.Widget.addCssClass(title_label.as(gtk.Widget), "heading");
        gtk.Box.append(text, title_label.as(gtk.Widget));

        // The detail line is data the app wrote: paths, folder names, service
        // names. It is selectable so it can be copied, and absent rows have none.
        if (row.detail.len > 0) {
            const detail_label = gtk.Label.new(row.detail.ptr);
            gtk.Label.setXalign(detail_label, 0);
            gtk.Label.setWrap(detail_label, 1);
            gtk.Label.setSelectable(detail_label, 1);
            gtk.Widget.addCssClass(detail_label.as(gtk.Widget), "dim-label");
            gtk.Widget.addCssClass(detail_label.as(gtk.Widget), "caption");
            gtk.Box.append(text, detail_label.as(gtk.Widget));
        }

        gtk.Box.append(box, text.as(gtk.Widget));
        gtk.ListBoxRow.setChild(list_row, box.as(gtk.Widget));
        return list_row.as(gtk.Widget);
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

const granted_row = flatpak.PermissionDisplay{
    .concern = "display",
    .tier = "high",
    .absent = false,
    .detail = "X11, Wayland",
};

test "permissions dialog separates unreadable from unrequested" {
    const one = [_]flatpak.PermissionDisplay{granted_row};
    const none = [_]flatpak.PermissionDisplay{};
    try std.testing.expectEqualStrings("list", PermissionsDialog.page_for(&one, 1));
    try std.testing.expectEqualStrings("empty", PermissionsDialog.page_for(&none, 0));
    try std.testing.expectEqualStrings("unavailable", PermissionsDialog.page_for(null, 0));
    try std.testing.expectEqualStrings("unavailable", PermissionsDialog.page_for(&one, 0));
}

test "permissions dialog words every concern the classifier emits" {
    // gettext is not initialised under test, so dgettext answers with the msgid:
    // these are exactly the English strings Concern.label carries.
    try std.testing.expectEqualStrings("Display server", PermissionsDialog.title_for(granted_row));
    try std.testing.expectEqualStrings(
        "No access to system files",
        PermissionsDialog.title_for(.{
            .concern = "files_system",
            .tier = "low",
            .absent = true,
            .detail = "",
        }),
    );
    // A concern from a newer classifier still gets a row, not silence.
    try std.testing.expectEqualStrings(
        "Other",
        PermissionsDialog.title_for(.{
            .concern = "future_concern",
            .tier = "low",
            .absent = false,
            .detail = "",
        }),
    );
}

test "permissions dialog tints the icon by tier" {
    try std.testing.expectEqualStrings("error", PermissionsDialog.tier_class(granted_row));
    try std.testing.expectEqualStrings(
        "warning",
        PermissionsDialog.tier_class(.{ .concern = "network", .tier = "medium", .detail = "" }),
    );
    try std.testing.expectEqualStrings(
        "success",
        PermissionsDialog.tier_class(.{ .concern = "network", .tier = "low", .absent = true, .detail = "" }),
    );
}
