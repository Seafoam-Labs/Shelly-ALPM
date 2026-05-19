using System.Diagnostics;
using Gtk;
using static Shelly.GTK.Resources.Translations;

namespace Shelly.Gtk.Windows.Dialog;

public static class FingerprintFixDialog
{
    public static void Show(Window parent)
    {
        var dialog = Window.New();
        dialog.SetTitle(T("Fingerprint Disable Instructions"));
        dialog.SetTransientFor(parent);
        dialog.SetModal(true);
        dialog.SetDefaultSize(720, 620);

        var outer = Box.New(Orientation.Vertical, 12);
        outer.SetMarginTop(16);
        outer.SetMarginBottom(16);
        outer.SetMarginStart(16);
        outer.SetMarginEnd(16);

        var heading = Label.New(T("Disable fingerprint authentication for sudo"));
        heading.SetXalign(0);
        heading.AddCssClass("title-3");
        outer.Append(heading);
        
        outer.Append(MakeSnippet(T("1. Inspect"),
            "grep -n pam_fprintd /etc/pam.d/sudo /etc/pam.d/sudo-i 2>/dev/null"));

        outer.Append(MakeSnippet(T("2. Disable for sudo"),
            "sudo cp /etc/pam.d/sudo /etc/pam.d/sudo.bak\n" +
            "sudo sed -i 's|^\\s*\\(auth.*pam_fprintd\\.so.*\\)$|# \\1|' /etc/pam.d/sudo\n" +
            "sudo -k\n" +
            "sudo -v"));

        outer.Append(MakeSnippet(T("3. Re-enable later"),
            "sudo mv /etc/pam.d/sudo.bak /etc/pam.d/sudo"));

        var buttonBox = Box.New(Orientation.Horizontal, 8);
        buttonBox.SetHalign(Align.End);

        var close = Button.NewWithLabel(T("Close"));
        close.OnClicked += (_, _) => dialog.Close();
        buttonBox.Append(close);

        outer.Append(buttonBox);

        var scroll = ScrolledWindow.New();
        scroll.SetChild(outer);
        scroll.SetVexpand(true);
        scroll.SetHexpand(true);
        dialog.SetChild(scroll);
        dialog.Present();
    }

    private static Widget MakeSnippet(string title, string command)
    {
        var box = Box.New(Orientation.Vertical, 6);
        var label = Label.New(title);
        label.SetXalign(0);
        label.AddCssClass("heading");
        box.Append(label);

        var view = TextView.New();
        view.SetEditable(false);
        view.SetMonospace(true);
        view.SetWrapMode(WrapMode.None);
        view.SetCursorVisible(false);
        view.GetBuffer().SetText(command, command.Length);

        var frame = Frame.New(null);
        frame.SetChild(view);
        box.Append(frame);

        var copy = Button.NewWithLabel(T("Copy"));
        copy.SetHalign(Align.End);
        copy.OnClicked += (_, _) =>
        {
            var display = Gdk.Display.GetDefault();
            display?.GetClipboard().SetText(command);
        };
        box.Append(copy);

        return box;
    }
}