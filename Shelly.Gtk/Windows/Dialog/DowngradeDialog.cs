using Gtk;
using Shelly.GTK.Resources;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;

namespace Shelly.Gtk.Windows.Dialog;

public static class DowngradeDialog
{
    public static GenericDialogEventArgs<(string? Filename, bool AddIgnore)> BuildDowngradeDialog(
        string packageName,
        List<DowngradeOptionDto> options)
    {
        var box = Box.New(Orientation.Vertical, 12);
        box.MarginTop = 8;
        box.MarginBottom = 8;
        box.MarginStart = 12;
        box.MarginEnd = 12;

        var titleLabel = Label.New(Translations.T("Downgrade: {0}", packageName));
        titleLabel.AddCssClass("heading");
        titleLabel.Halign = Align.Start;
        box.Append(titleLabel);

        var versionLabel = Label.New(Translations.T("Select version:"));
        versionLabel.Halign = Align.Start;
        box.Append(versionLabel);

        var versionStrings = options
            .Select(o => $"{o.Filename} [{o.Location}]{(o.IsInstalled ? $" - {Translations.T("Installed")}" : "")}")
            .ToArray();
        var stringList = StringList.New(versionStrings);
        var dropDown = DropDown.New(stringList, null);
        dropDown.EnableSearch = true;
        box.Append(dropDown);

        var ignoreCheck = CheckButton.New();
        ignoreCheck.Label = Translations.T("Add to IgnorePkg list");
        ignoreCheck.MarginTop = 4;
        box.Append(ignoreCheck);

        var buttonBox = Box.New(Orientation.Horizontal, 0);
        buttonBox.Homogeneous = true;
        buttonBox.Spacing = 5;
        buttonBox.MarginTop = 8;

        var dialogArgs = new GenericDialogEventArgs<(string? Filename, bool AddIgnore)>(box);

        var confirmButton = Button.NewWithLabel(Translations.T("Downgrade"));
        confirmButton.AddCssClass("destructive-action");
        confirmButton.OnClicked += (_, _) =>
        {
            var index = (int)dropDown.GetSelected();
            dialogArgs.SetResponse((options[index].Filename, ignoreCheck.Active));
        };

        var cancelButton = Button.NewWithLabel(Translations.T("Cancel"));
        cancelButton.OnClicked += (_, _) => dialogArgs.SetResponse((null, false));

        buttonBox.Append(confirmButton);
        buttonBox.Append(cancelButton);
        box.Append(buttonBox);

        return dialogArgs;
    }
}