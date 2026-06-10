using Gtk;

namespace Shelly.Gtk.Helpers;

public static class OverlayHelper
{
    public static void ShowLoading(Box overlay, Spinner spinner, Label? errorLabel = null)
    {
        GLib.Functions.IdleAdd(0, () =>
        {
            spinner.SetVisible(true);
            spinner.SetSpinning(true);
            overlay.SetVisible(true);
            errorLabel?.SetVisible(false);
            return false;
        });
    }

    public static void HideLoading(Box overlay, Spinner spinner)
    {
        GLib.Functions.IdleAdd(0, () =>
        {
            spinner.SetSpinning(false);
            spinner.SetVisible(false);
            overlay.SetVisible(false);
            return false;
        });
    }

    public static bool HasActiveOverlay(Widget widget)
    {
        var current = widget;
        while (current != null)
        {
            if (current is Overlay overlay)
            {
                if (overlay.GetFirstChild()?.GetNextSibling() != null)
                {
                    return true;
                }
            }
            current = current.GetParent();
        }
        return false;
    }
}
