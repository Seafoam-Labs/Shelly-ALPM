using Gtk;
using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Windows.Dialog;

public static class GenericOverlay
{
    public static void ShowGenericOverlay(Overlay parentOverlay, Widget content, GenericDialogEventArgs e)
    {
        var dismissed = false;
        var backdrop = new Box();
        backdrop.SetOrientation(Orientation.Horizontal);
        backdrop.Hexpand = true;
        backdrop.Vexpand = true;
        backdrop.AddCssClass("lockout-overlay");

        var baseBox = new Box();
        baseBox.SetOrientation(Orientation.Vertical);
        baseBox.SetSpacing(12);
        baseBox.AddCssClass("dialog-overlay");
        
        baseBox.SetHalign(Align.Center);
        baseBox.SetValign(Align.Center);
        baseBox.SetSizeRequest(400, -1);
        baseBox.SetMarginTop(20);
        baseBox.SetMarginBottom(20);
        baseBox.SetMarginStart(20);
        baseBox.SetMarginEnd(20);

        var grid = new Grid();
        grid.Hexpand = true;

        var spacer = new Box();
        spacer.Hexpand = true;

        var closeButton = new Button();
        closeButton.SetHalign(Align.End);
        closeButton.SetIconName("window-close-symbolic");

        grid.Attach(spacer,      0, 0, 1, 1);
        grid.Attach(closeButton, 1, 0, 1, 1);
        grid.Attach(content,     0, 1, 2, 1);

        baseBox.Append(grid);

        closeButton.OnClicked += (_, _) => Dismiss();

        var gestureClick = GestureClick.New();
        gestureClick.OnReleased += (_,  args) =>
        {
            backdrop.TranslateCoordinates(baseBox, args.X, args.Y, out var x, out var y);

            var insideCard = x >= 0 && y >= 0
                           && x <= baseBox.GetAllocatedWidth()
                           && y <= baseBox.GetAllocatedHeight();

            if (!insideCard)
                Dismiss();
        };

        backdrop.AddController(gestureClick);
        backdrop.Append(baseBox);

        parentOverlay.AddOverlay(backdrop);
        _ = e.ResponseTask.ContinueWith(_ =>
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                Dismiss();
                return false;
            });
        });
        return;

        void Dismiss()
        {
            if (dismissed)
            {
                return;
            }

            dismissed = true;
            e.SetResponse(false);
            parentOverlay.RemoveOverlay(backdrop);
        }
    }
}