using GObject;

namespace Shelly.Gtk.UiModels.AppImageHub;

[Subclass<GObject.Object>]
public partial class AppImageHubGObject
{
    public AppImageHubItem? Item { get; set; }
}
