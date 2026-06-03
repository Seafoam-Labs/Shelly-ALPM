using Gtk;
using Shelly.Gtk.UiModels;
using Functions = GLib.Functions;

namespace Shelly.Gtk.Windows.Dialog;

public static class GenericOverlay
{
    public static void ShowGenericOverlay(
        Overlay parentOverlay,
        Widget content,
        GenericDialogEventArgs e,
        int width = 400,
        int height = -1)
    {
        var backdrop = Box.New(Orientation.Horizontal, 0);
        backdrop.Hexpand = true;
        backdrop.Vexpand = true;
        backdrop.AddCssClass("lockout-overlay");

        var baseFrame = Frame.New(null);
        baseFrame.SetHalign(Align.Center);
        baseFrame.SetValign(Align.Center);
        baseFrame.SetSizeRequest(width, height);
        baseFrame.AddCssClass("background");
        baseFrame.AddCssClass("dialog-overlay");
        baseFrame.SetOverflow(Overflow.Hidden);

        var baseBox = Box.New(Orientation.Vertical, 0);
        baseFrame.SetChild(baseBox);

        var contentOverlay = Overlay.New();
        contentOverlay.Hexpand = true;

        var closeButton = Button.New();
        closeButton.SetHalign(Align.End);
        closeButton.SetValign(Align.Start);
        closeButton.SetIconName("window-close-symbolic");
        closeButton.SetCssClasses(["circular"]);

        contentOverlay.SetChild(content);
        contentOverlay.AddOverlay(closeButton);

        baseBox.Append(contentOverlay);

        closeButton.OnClicked += (_, _) => Dismiss();

        var gestureClick = GestureClick.New();
        gestureClick.OnReleased += (_, args) =>
        {
            backdrop.TranslateCoordinates(baseFrame, args.X, args.Y, out var x, out var y);

            var insideCard =
                x >= 0 && y >= 0 && x <= baseFrame.GetAllocatedWidth() && y <= baseFrame.GetAllocatedHeight();

            if (!insideCard)
                Dismiss();
        };

        backdrop.AddController(gestureClick);
        backdrop.Append(baseFrame);

        parentOverlay.AddOverlay(backdrop);
        _ = e.ResponseTask.ContinueWith(_ =>
        {
            Functions.IdleAdd(0, () =>
            {
                Dismiss();
                return false;
            });
        });
        return;

        void Dismiss()
        {
            if (e.ResponseTask.IsCompleted)
            {
                if (backdrop.Parent != null) parentOverlay.RemoveOverlay(backdrop);

                return;
            }

            e.SetResponse(false);
            if (backdrop.Parent != null) parentOverlay.RemoveOverlay(backdrop);
        }
    }
}