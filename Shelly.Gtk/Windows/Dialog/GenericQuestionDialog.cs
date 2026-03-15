using Gtk;
using Pango;
using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Windows.Dialog;

public static class GenericQuestionDialog
{
    public static void ShowGenericQuestionDialog(Overlay parentOverlay, GenericQuestionEventArgs e)
    {
        var background = Box.New(Orientation.Horizontal, 0);
        background.AddCssClass("lockout-overlay");
        background.SetHalign(Align.Fill);
        background.SetValign(Align.Fill);
        background.SetHexpand(true);
        background.SetVexpand(true);

        var box = Box.New(Orientation.Vertical, 12);
        box.SetHalign(Align.Center);
        box.SetValign(Align.Center);
        box.SetSizeRequest(e.UseMonospaceMessage ? 720 : 400, -1);
        box.SetMarginTop(20);
        box.SetMarginBottom(20);
        box.SetMarginStart(20);
        box.SetMarginEnd(20);
        box.AddCssClass("dialog-overlay");
        background.Append(box);

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
        scrolledWindow.SetHexpand(true);
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
            parentOverlay.RemoveOverlay(background);
        };

        yesButton.OnClicked += (s, args) =>
        {
            e.SetResponse(true);
            parentOverlay.RemoveOverlay(background);
        };

        buttonBox.Append(yesButton);
        buttonBox.Append(noButton);
        box.Append(buttonBox);

        parentOverlay.AddOverlay(background);
    }
}
