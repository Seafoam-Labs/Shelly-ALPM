using GObject;

namespace Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;

[Subclass<GObject.Object>]
public partial class LocalPackageGObject
{
    public LocalPackageDto? Package { get; set; }
    public bool IsSelected { get; set; }

    public event EventHandler? OnSelectionToggled;

    public void ToggleSelection()
    {
        IsSelected = !IsSelected;
        OnSelectionToggled?.Invoke(this, EventArgs.Empty);
    }
}
