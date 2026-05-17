using GObject;

namespace Shelly.Gtk.UiModels.Recommend.GObjects;

[Subclass<GObject.Object>]
public partial class RecommendGObject
{
    public int Index { get; set; } = -1;
    public string PackageName { get; set; } = string.Empty;
    public bool IsSelected { get; set; }
    public bool IsInstalled { get; set; }

    public event EventHandler? OnSelectionToggled;

    public void ToggleSelection()
    {
        IsSelected = !IsSelected;
        OnSelectionToggled?.Invoke(this, EventArgs.Empty);
    }
}