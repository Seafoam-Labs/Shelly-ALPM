using Gtk;
using Pango;
using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Windows.Dialog;

public static class GenericQuestionDialog
{
    public static void ShowGenericQuestionDialog(Overlay parentOverlay, GenericQuestionEventArgs e)
    {
        var box = Box.New(Orientation.Vertical, 12);
        box.SetHalign(Align.Center);
        box.SetValign(Align.Center);
        box.SetSizeRequest(400, -1);
        box.SetMarginTop(20);
        box.SetMarginBottom(20);
        box.SetMarginStart(20);
        box.SetMarginEnd(20);
        box.AddCssClass("dialog-overlay");

        var titleLabel = Label.New(e.Title);
        titleLabel.AddCssClass("title-4");
        box.Append(titleLabel);

        Widget messageWidget;

        if (e.UseMonospaceMessage)
        {
            var messageBox = Box.New(Orientation.Vertical, 2);
            messageBox.SetHalign(Align.Fill);
            messageBox.SetHexpand(true);

            foreach (var line in e.Message.Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries))
            {
                var lineLabel = Label.New(string.Empty);
                lineLabel.SetHalign(Align.Fill);
                lineLabel.SetHexpand(true);
                lineLabel.SetXalign(0);
                lineLabel.SetJustify(Justification.Left);
                lineLabel.SetEllipsize(EllipsizeMode.End);
                lineLabel.SetMarkup($"<tt>{GLib.Markup.EscapeText(line)}</tt>");
                messageBox.Append(lineLabel);
            }

            messageWidget = messageBox;
        }
        else
        {
            var messageLabel = Label.New(e.Message);
            messageLabel.SetHalign(Align.Start);
            messageLabel.SetXalign(0);
            messageLabel.SetJustify(Justification.Left);
            messageLabel.SetWrap(true);
            messageWidget = messageLabel;
        }

        var scrolledWindow = new ScrolledWindow();
        scrolledWindow.SetPolicy(PolicyType.Never, PolicyType.Automatic);
        scrolledWindow.SetMaxContentHeight(300);
        scrolledWindow.SetPropagateNaturalHeight(true);
        scrolledWindow.SetChild(messageWidget);
        box.Append(scrolledWindow);

        var buttonBox = Box.New(Orientation.Horizontal, 8);
        buttonBox.SetHalign(Align.End);

        var noButton = Button.NewWithLabel("No");
        var yesButton = Button.NewWithLabel("Yes");
        yesButton.AddCssClass("suggested-action");

        noButton.OnClicked += (s, args) =>
        {
            e.SetResponse(false);
            parentOverlay.RemoveOverlay(box);
        };

        yesButton.OnClicked += (s, args) =>
        {
            e.SetResponse(true);
            parentOverlay.RemoveOverlay(box);
        };

        buttonBox.Append(yesButton);
        buttonBox.Append(noButton);
        box.Append(buttonBox);

        parentOverlay.AddOverlay(box);
    }
}
