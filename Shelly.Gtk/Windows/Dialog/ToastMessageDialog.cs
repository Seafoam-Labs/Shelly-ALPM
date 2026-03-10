using Gtk;
using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Windows.Dialog;

public static class ToastMessageDialog
{
    public static void ShowToastMessage(Overlay parentOverlay, ToastMessageEventArgs e)
    {
        GLib.Functions.IdleAdd(0, () =>
        {
            var toastBox = Box.New(Orientation.Horizontal, 8);
            toastBox.AddCssClass("toast-message");
            toastBox.SetHalign(Align.Center);
            toastBox.SetValign(Align.End);
            toastBox.SetMarginBottom(40);

            var label = Label.New(e.Title);
            label.SetMarginTop(5);
            label.SetMarginBottom(5);
            label.SetMarginStart(5);
            label.SetMarginEnd(5);

            toastBox.Append(label);

            parentOverlay.AddOverlay(toastBox);

            GLib.Functions.TimeoutAdd(0, (uint)3000, () =>
            {
                parentOverlay.RemoveOverlay(toastBox);
                return false;
            });

            return false;
        });
    }
}