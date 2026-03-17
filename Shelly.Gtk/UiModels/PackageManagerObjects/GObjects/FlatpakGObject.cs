using GObject;

namespace Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;

[Subclass<GObject.Object>]
public partial class FlatpakGObject
{
    public AppstreamApp? Package { get; set; }
}