using Shelly.Gtk.Services;
using Gtk;

namespace Shelly.Gtk.Windows.Dialog;

public class PasswordDialog(ICredentialManager credentialManager)
{
    public void ShowPasswordDialog(Overlay parentOverlay, string reason)
    {
        var background = Box.New(Orientation.Vertical, 0);
        background.AddCssClass("lockout-overlay");
        background.SetHalign(Align.Fill);
        background.SetValign(Align.Fill);

        var box = Box.New(Orientation.Vertical, 12);
        box.SetHalign(Align.Center);
        box.SetValign(Align.Center);
        box.SetHexpand(true);
        box.SetVexpand(true);
        box.SetSizeRequest(400, -1);
        box.SetMarginTop(20);
        box.SetMarginBottom(20);
        box.SetMarginStart(20);
        box.SetMarginEnd(20);
        box.AddCssClass("dialog-overlay");
        background.Append(box);

        var titleLabel = Label.New("Authentication Required");
        titleLabel.AddCssClass("title-4");
        box.Append(titleLabel);

        var label = Label.New($"Password needed to execute: {reason}.");
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

        var cancelButton = Button.NewWithLabel("Cancel");
        var submitButton = Button.NewWithLabel("Authenticate");
        submitButton.AddCssClass("suggested-action");

        cancelButton.OnClicked += async (s, e) =>
        {
            await credentialManager.CompleteCredentialRequestAsync(false);
            parentOverlay.RemoveOverlay(background);
        };

        submitButton.OnClicked += async (s, e) =>
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
                errorLabel.SetText("Incorrect password. Try again.");
                passwordEntry.SetText("");
            }
        };

        // Allow Enter key to submit
        passwordEntry.OnActivate += (s, e) => submitButton.Activate();

        buttonBox.Append(cancelButton);
        buttonBox.Append(submitButton);
        box.Append(buttonBox);

        parentOverlay.AddOverlay(background);
        passwordEntry.GrabFocus();
    }
}