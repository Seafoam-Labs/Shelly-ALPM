using GObject;

namespace Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;

[Subclass<GObject.Object>]
public partial class FlatpakRemoteGObject
{
    public FlatpakRemoteDto? Remote { get; set; }
}