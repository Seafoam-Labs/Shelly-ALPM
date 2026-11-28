//! GitHub, community, and sponsor link icons. The navigation shows them on
//! non-Devario builds; Settings shows them on Devario builds.
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;

const translations = @import("translations.zig");
const a11y = @import("a11y.zig");

const Link = struct { icon: [:0]const u8, label: [:0]const u8, uri: [:0]const u8 };
const links = [_]Link{
    .{ .icon = "github-symbolic", .label = "GitHub", .uri = "https://github.com/Seafoam-Labs/Shelly-ALPM" },
    .{ .icon = "community-symbolic", .label = "Community fluxer", .uri = "https://fluxer.gg/vOjrMXcE" },
    .{ .icon = "heart-symbolic", .label = "Sponsor", .uri = "https://www.patreon.com/cw/SeafoamLabs" },
};

pub fn build(orientation: gtk.Orientation) *gtk.Box {
    const box = gtk.Box.new(orientation, 8);
    gtk.Widget.addCssClass(box.as(gtk.Widget), "project-links");
    gtk.Widget.setHalign(box.as(gtk.Widget), .center);
    gtk.Widget.setValign(box.as(gtk.Widget), .center);
    for (links) |link| {
        const button = gtk.LinkButton.new(link.uri);
        const image = gtk.Image.newFromIconName(link.icon);
        gtk.Image.setPixelSize(image, 20);
        gtk.Button.setChild(button.as(gtk.Button), image.as(gtk.Widget));
        const label = translations._(link.label);
        a11y.setName(button.as(gtk.Widget), label);
        gtk.Widget.setTooltipText(button.as(gtk.Widget), label);
        gtk.Box.append(box, button.as(gtk.Widget));
    }
    return box;
}
