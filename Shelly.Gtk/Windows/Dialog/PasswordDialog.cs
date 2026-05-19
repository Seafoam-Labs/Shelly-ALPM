using Shelly.Gtk.Services;
using Gtk;
using static Shelly.GTK.Resources.Translations;

namespace Shelly.Gtk.Windows.Dialog;

public class PasswordDialog(ICredentialManager credentialManager)
{
    public void ShowPasswordDialog(Overlay parentOverlay, string reason)
    {
        var background = Box.New(Orientation.Vertical, 0);
        background.AddCssClass("lockout-overlay");
        background.SetHalign(Align.Fill);
        background.SetValign(Align.Fill);

        var baseFrame = Frame.New(null);
        baseFrame.SetHalign(Align.Center);
        baseFrame.SetValign(Align.Center);
        baseFrame.SetHexpand(true);
        baseFrame.SetVexpand(true);
        baseFrame.SetSizeRequest(400, -1);
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

        var titleLabel = Label.New(T("Authentication Required"));
        titleLabel.AddCssClass("title-4");
        box.Append(titleLabel);

        var label = Label.New(T("Password needed to execute: {0}.", reason));
        label.SetWrap(true);
        box.Append(label);

        var errorLabel = Label.New("");
        errorLabel.AddCssClass("error-label");

        var passwordEntry = PasswordEntry.New();
        passwordEntry.SetShowPeekIcon(true);
        box.Append(passwordEntry);
        box.Append(errorLabel);

        var buttonBox = Box.New(Orientation.Horizontal, 8);
        buttonBox.SetHalign(Align.End);

        var cancelButton = Button.NewWithLabel(T("Cancel"));
        var submitButton = Button.NewWithLabel(T("Authenticate"));
        submitButton.AddCssClass("suggested-action");

        cancelButton.OnClicked += async (_,_) =>
        {
            await credentialManager.CompleteCredentialRequestAsync(false);
            parentOverlay.RemoveOverlay(background);
        };

        submitButton.OnClicked += async (_,_) =>
        {
            var password = passwordEntry.GetText();
            credentialManager.StorePassword(password);
            await credentialManager.CompleteCredentialRequestAsync(true);

            if (credentialManager.IsValidated)
            {
                parentOverlay.RemoveOverlay(background);
            }
            else
            {
                errorLabel.SetText(T("Incorrect password. Try again."));
                passwordEntry.SetText("");
            }
        };

        // Allow Enter key to submit
        passwordEntry.OnActivate += (_,_) => submitButton.Activate();

        buttonBox.Append(cancelButton);
        buttonBox.Append(submitButton);
        box.Append(buttonBox);

        parentOverlay.AddOverlay(background);
        passwordEntry.GrabFocus();
    }
}