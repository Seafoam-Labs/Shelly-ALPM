const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const support = @import("support.zig");

/// Placeholder for the fwupd-backed Firmware page. The device list, detail
/// pane and install flow land in a later phase; this stub keeps the feature
/// gate, navigation and enablement independently compilable.
pub const FirmwarePage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "Firmware";
    pub const icon_name: [:0]const u8 = "software-update-available-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/firmware_page.ui";

    const Private = struct {
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyFirmwarePage",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        support.connectLifecycle(Self, self);
    }

    pub fn onMap(self: *Self) void {
        _ = self;
    }

    pub fn onUnmap(self: *Self) void {
        _ = self;
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            const wc = gobject.ext.as(gtk.Widget.Class, class);
            gtk.Widget.Class.setTemplateFromResource(wc, resource_path);
        }
    };
};
