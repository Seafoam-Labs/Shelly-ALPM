using GObject;
using Shelly.Gtk.UiModels.PackageManagerObjects;

namespace Shelly.Gtk.UiModels.AUR.GObjects;

[Subclass<GObject.Object>]
public partial class AurPackageGObject
{
    public int Index { get; set; } = -1;
    public bool IsSelected { get; set; }

    public event EventHandler? OnSelectionToggled;

    public void ToggleSelection()
    {
        IsSelected = !IsSelected;
        OnSelectionToggled?.Invoke(this, EventArgs.Empty);
    }
}
