using Gtk;
using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Windows.Dialog;

public static class StandardInstallFailureDialog
{
    public static GenericDialogEventArgs Create(
        IReadOnlyCollection<string> packages,
        string failureSummary,
        Func<Task<bool>> exportLogsAsync)
    {
        var packageLabel = packages.Count == 1 ? "package" : "packages";
        var content = Box.New(Orientation.Vertical, 12);
        content.SetSizeRequest(560, -1);

        var titleLabel = Label.New("Package installation failed");
        titleLabel.AddCssClass("title-4");
        titleLabel.SetHalign(Align.Start);
        titleLabel.SetXalign(0);
        content.Append(titleLabel);

        var descriptionLabel = Label.New(
            $"Shelly couldn't finish building or installing the selected {packageLabel}. Export the logs and attach them to your report so the team can check whether the issue came from the PKGBUILD or from Shelly.");
        descriptionLabel.SetWrap(true);
        descriptionLabel.SetHalign(Align.Start);
        descriptionLabel.SetXalign(0);
        content.Append(descriptionLabel);

        var packagesLabel = Label.New($"Packages: {string.Join(", ", packages)}");
        packagesLabel.SetWrap(true);
        packagesLabel.SetHalign(Align.Start);
        packagesLabel.SetXalign(0);
        packagesLabel.AddCssClass("dim-label");
        content.Append(packagesLabel);

        if (!string.IsNullOrWhiteSpace(failureSummary))
        {
            var summaryHeading = Label.New("Recent output");
            summaryHeading.AddCssClass("heading");
            summaryHeading.SetHalign(Align.Start);
            summaryHeading.SetXalign(0);
            content.Append(summaryHeading);

            var summaryLabel = Label.New(failureSummary);
            summaryLabel.AddCssClass("monospace");
            summaryLabel.SetWrap(true);
            summaryLabel.SetSelectable(true);
            summaryLabel.SetHalign(Align.Fill);
            summaryLabel.SetXalign(0);

            var scrolledWindow = new ScrolledWindow();
            scrolledWindow.SetPolicy(PolicyType.Never, PolicyType.Automatic);
            scrolledWindow.SetMaxContentHeight(180);
            scrolledWindow.SetPropagateNaturalHeight(true);
            scrolledWindow.SetChild(summaryLabel);
            content.Append(scrolledWindow);
        }

        var dialogArgs = new GenericDialogEventArgs(content);

        var buttonBox = Box.New(Orientation.Horizontal, 8);
        buttonBox.SetHalign(Align.End);

        var closeButton = Button.NewWithLabel("Close");
        closeButton.OnClicked += (_, _) => dialogArgs.SetResponse(false);

        var exportButton = Button.NewWithLabel("Export Logs");
        exportButton.AddCssClass("suggested-action");
        exportButton.OnClicked += async (_, _) =>
        {
            if (await exportLogsAsync())
            {
                dialogArgs.SetResponse(true);
            }
        };

        buttonBox.Append(closeButton);
        buttonBox.Append(exportButton);
        content.Append(buttonBox);

        return dialogArgs;
    }
}