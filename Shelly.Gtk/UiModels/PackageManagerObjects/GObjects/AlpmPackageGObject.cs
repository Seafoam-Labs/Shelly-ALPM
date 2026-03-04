using GObject;


namespace Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;

[Subclass<GObject.Object>]
public partial class AlpmPackageGObject
{
    public AlpmPackageDto? Package { get; set; }
}