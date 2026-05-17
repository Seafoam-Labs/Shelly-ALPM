using Gtk;
using Pango;
using Shelly.Gtk.UiModels;
using static Shelly.GTK.Resources.Translations;

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

        var baseFrame = Frame.New(null);
        baseFrame.SetHalign(Align.Center);
        baseFrame.SetValign(Align.Center);
        baseFrame.SetSizeRequest(e.UseMonospaceMessage ? 720 : 400, -1);
        baseFrame.SetMarginTop(20);
        baseFrame.SetMarginBottom(20);
        baseFrame.SetMarginStart(20);
        baseFrame.SetMarginEnd(20);
        baseFrame.AddCssClass("background");
        baseFrame.AddCssClass("dialog-overlay");
        baseFrame.SetOverflow(Overflow.Hidden);
        background.Append(baseFrame);

        var box = Box.New(Orientation.Vertical, 12);
        baseFrame.SetChild(box);

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

        var scrolledWindow = ScrolledWindow.New();
        scrolledWindow.SetPolicy(PolicyType.Never, PolicyType.Automatic);
        scrolledWindow.SetMaxContentHeight(300);
        scrolledWindow.SetPropagateNaturalHeight(true);
        scrolledWindow.SetHexpand(true);
        scrolledWindow.SetChild(messageWidget);
        box.Append(scrolledWindow);

        var buttonBox = Box.New(Orientation.Horizontal, 8);
        buttonBox.SetHalign(Align.End);

        var noButton = Button.NewWithLabel(T("No"));
        var yesButton = Button.NewWithLabel(T("Yes"));
        yesButton.AddCssClass("suggested-action");

        noButton.OnClicked += (_,_) => CloseAndRespond(false);
        yesButton.OnClicked += (_,_) => CloseAndRespond(true);

        var shortcutController = ShortcutController.New();
        shortcutController.Scope = ShortcutScope.Global;
        shortcutController.PropagationPhase = PropagationPhase.Capture;
        
        foreach (var triggerStr in new[] { "Return", "KP_Enter", "space" })
        {
            var action = CallbackAction.New((_, _) =>
            {
                CloseAndRespond(true);
                return true;
            });
            shortcutController.AddShortcut(Shortcut.New(ShortcutTrigger.ParseString(triggerStr), action));
        }
        
        {
            var action = CallbackAction.New((_, _) =>
            {
                CloseAndRespond(false);
                return true;
            });
            shortcutController.AddShortcut(Shortcut.New(ShortcutTrigger.ParseString("Escape"), action));
        }

        background.AddController(shortcutController);

        buttonBox.Append(yesButton);
        buttonBox.Append(noButton);
        box.Append(buttonBox);

        parentOverlay.AddOverlay(background);
        return;

        void CloseAndRespond(bool response)
        {
            e.SetResponse(response);
            parentOverlay.RemoveOverlay(background);
        }
    }
}
