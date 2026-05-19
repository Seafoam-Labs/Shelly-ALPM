using Gtk;
using Pango;
using Shelly.Gtk.UiModels;
using static Shelly.GTK.Resources.Translations;

namespace Shelly.Gtk.Windows.Dialog;

public static class PackageBuildDialog
{
    public static void ShowPackageBuildDialog(Overlay parentOverlay, PackageBuildEventArgs e)
    {
        var baseFrame = Frame.New(null);
        baseFrame.SetHalign(Align.Center);
        baseFrame.SetValign(Align.Center);
        baseFrame.SetSizeRequest(600, 500);
        baseFrame.SetMarginTop(20);
        baseFrame.SetMarginBottom(20);
        baseFrame.SetMarginStart(20);
        baseFrame.SetMarginEnd(20);
        baseFrame.AddCssClass("background");
        baseFrame.AddCssClass("dialog-overlay");
        baseFrame.SetOverflow(Overflow.Hidden);

        var box = Box.New(Orientation.Vertical, 12);
        baseFrame.SetChild(box);

        var titleLabel = Label.New(e.Title);
        titleLabel.AddCssClass("title-4");
        box.Append(titleLabel);


        var messageBox = Box.New(Orientation.Vertical, 2);
        messageBox.SetHalign(Align.Fill);
        messageBox.SetHexpand(true);

        foreach (var line in e.PkgBuild.Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries))
        {
            var lineLabel = Label.New(string.Empty);
            lineLabel.SetHalign(Align.Fill);
            lineLabel.SetHexpand(true);
            lineLabel.SetXalign(0);
            lineLabel.SetJustify(Justification.Left);
            lineLabel.SetMarkup($"<tt>{GLib.Markup.EscapeText(line)}</tt>");
            messageBox.Append(lineLabel);
        }


        var scrolledWindow = ScrolledWindow.New();
        scrolledWindow.SetPolicy(PolicyType.Automatic, PolicyType.Automatic);
        scrolledWindow.SetVexpand(true);
        scrolledWindow.SetChild(messageBox);
        box.Append(scrolledWindow);

        var buttonBox = Box.New(Orientation.Horizontal, 8);
        buttonBox.SetHalign(Align.End);

        var cancelButton = Button.NewWithLabel(T("Cancel"));
        var confirmButton = Button.NewWithLabel(T("Confirm"));
        confirmButton.AddCssClass("suggested-action");

        cancelButton.OnClicked += (_, _) =>
        {
            e.SetResponse(false);
            parentOverlay.RemoveOverlay(baseFrame);
        };

        confirmButton.OnClicked += (_, _) =>
        {
            e.SetResponse(true);
            parentOverlay.RemoveOverlay(baseFrame);
        };

        buttonBox.Append(confirmButton);
        buttonBox.Append(cancelButton);
        box.Append(buttonBox);

        parentOverlay.AddOverlay(baseFrame);
    }
}