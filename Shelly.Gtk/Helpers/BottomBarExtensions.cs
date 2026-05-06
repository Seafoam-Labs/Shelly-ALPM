using Gtk;
using Microsoft.Extensions.DependencyInjection;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.Windows.Dialog;

namespace Shelly.Gtk.Helpers;

public static class BottomBarExtensions
{
    public static void SetupHistoryButton(
        MenuButton historyMenuButton,
        ListBox historyListBox,
        Label historyPopoverTitle,
        IServiceProvider serviceProvider,
        IGenericQuestionService genericQuestionService,
        Overlay mainOverlay)
    {
        LoadHistory();
        historyMenuButton.OnActivate += (_, _) => LoadHistory();
        return;

        void LoadHistory()
        {
            while (historyListBox.GetFirstChild() is { } ch)
                historyListBox.Remove(ch);
            var loadingRow = ListBoxRow.New();
            var loadingLabel = Label.New("Loading...");
            loadingLabel.Halign = Align.Center;
            loadingLabel.AddCssClass("dim-label");
            loadingLabel.MarginTop = 8;
            loadingLabel.MarginBottom = 8;
            loadingRow.SetActivatable(false);
            loadingRow.SetChild(loadingLabel);
            historyListBox.Append(loadingRow);

            Task.Run((Func<Task>)(async () =>
            {
                var opLogService = serviceProvider.GetRequiredService<IOperationLogService>();
                var entries = await opLogService.GetRecentOperationsAsync(8);
                GLib.Functions.IdleAdd(0, () =>
                {
                    historyPopoverTitle.SetText("Recent Operations");
                    historyMenuButton.SetLabel("History");

                    while (historyListBox.GetFirstChild() is { } child)
                        historyListBox.Remove(child);

                    if (entries.Count == 0)
                    {
                        var row = ListBoxRow.New();
                        var lbl = Label.New("No recent activity");
                        lbl.Halign = Align.Center;
                        lbl.AddCssClass("dim-label");
                        lbl.MarginTop = 8;
                        lbl.MarginBottom = 8;
                        row.SetActivatable(false);
                        row.SetChild(lbl);
                        historyListBox.Append(row);
                        return false;
                    }

                    var activatableEntries = entries;

                    historyListBox.OnRowActivated += (_, args) =>
                    {
                        historyMenuButton.Popdown();
                        var idx = args.Row.GetIndex();
                        if (idx < 0 || idx >= activatableEntries.Count) return;
                        var selectedEntry = activatableEntries[idx];
                        Task.Run(async () =>
                        {
                            var opLogSvc = serviceProvider.GetRequiredService<IOperationLogService>();
                            var logLines = await opLogSvc.GetSessionExcerptAsync(selectedEntry, 1024 * 1024);
                            if (logLines.Count == 0)
                            {
                                GLib.Functions.IdleAdd(0, () =>
                                {
                                    genericQuestionService.RaiseToastMessage(
                                        new ToastMessageEventArgs("Session log is too large to display"));
                                    return false;
                                });
                                return;
                            }
                            GLib.Functions.IdleAdd(0, () =>
                            {
                                var fullLogText = string.Join("\n", logLines);
                                var logBox = Box.New(Orientation.Vertical, 10);
                                logBox.SetMarginTop(10);
                                logBox.SetMarginBottom(10);
                                logBox.SetMarginStart(10);
                                logBox.SetMarginEnd(10);
                                var titleLabel = Label.New("Session Log");
                                titleLabel.AddCssClass("title-1");
                                titleLabel.Xalign = 0;
                                logBox.Append(titleLabel);
                                var textView = TextView.New();
                                textView.Editable = false;
                                textView.WrapMode = WrapMode.WordChar;
                                textView.Buffer?.SetText(fullLogText, -1);
                                var scrolledWindow = ScrolledWindow.New();
                                scrolledWindow.SetVexpand(true);
                                scrolledWindow.HscrollbarPolicy = PolicyType.Automatic;
                                scrolledWindow.SetChild(textView);
                                logBox.Append(scrolledWindow);
                                var copyButton = Button.NewWithLabel("Copy Log");
                                copyButton.Halign = Align.Start;
                                copyButton.OnClicked += (_, _) =>
                                {
                                    var clipboard = Gdk.Display.GetDefault()!.GetClipboard();
                                    clipboard.SetText(fullLogText);
                                    genericQuestionService.RaiseToastMessage(
                                        new ToastMessageEventArgs("Log copied to clipboard"));
                                };
                                logBox.Append(copyButton);
                                var dialogArgs = new GenericDialogEventArgs(logBox);
                                GenericOverlay.ShowGenericOverlay(mainOverlay, logBox, dialogArgs, 700, 500);
                                return false;
                            });
                        });
                    };

                    foreach (var entry in entries)
                    {
                        var row = ListBoxRow.New();
                        row.SetActivatable(true);

                        var horizontalBox = Box.New(Orientation.Horizontal, 10);
                        horizontalBox.MarginStart = 5;
                        horizontalBox.MarginEnd = 5;
                        horizontalBox.MarginTop = 4;
                        horizontalBox.MarginBottom = 4;

                        var icon = Image.NewFromIconName(GetHistoryIcon(entry.Command));
                        icon.SetPixelSize(16);
                        horizontalBox.Append(icon);

                        var cmdLabel = Label.New(entry.Command);
                        cmdLabel.SetXalign(0);
                        cmdLabel.Hexpand = true;
                        cmdLabel.Ellipsize = Pango.EllipsizeMode.End;
                        horizontalBox.Append(cmdLabel);

                        var timeLabel = Label.New(FormatHistoryTime(entry.Timestamp));
                        timeLabel.AddCssClass("dim-label");
                        timeLabel.AddCssClass("caption");
                        horizontalBox.Append(timeLabel);

                        if (entry.ExitCode.HasValue)
                        {
                            var statusIcon = Image.NewFromIconName(
                                entry.ExitCode == 0 ? "emblem-ok-symbolic" : "dialog-error-symbolic");
                            statusIcon.SetPixelSize(16);
                            horizontalBox.Append(statusIcon);
                        }
                        else
                        {
                            horizontalBox.Append(Label.New("⏳"));
                        }

                        row.SetChild(horizontalBox);
                        historyListBox.Append(row);
                    }

                    return false;
                });
            }));
        }
    }

    public static void SetupUpdatesButton(
        MenuButton updatesMenuButton,
        ListBox updatesListBox,
        Label updatesPopoverTitle,
        IServiceProvider serviceProvider,
        IPackageUpdateNotifier packageUpdateNotifier)
    {
        LoadUpdates(showLoading: true);
        updatesMenuButton.OnActivate += (_, _) => LoadUpdates(showLoading: true);
        packageUpdateNotifier.PackagesUpdated += (_, _) => LoadUpdates(showLoading: false);

        var updateTimer = Task.Run(TimerFunction);
        GC.KeepAlive(updateTimer);
        return;

        async Task? TimerFunction()
        {
            while (true)
            {
                await Task.Delay(TimeSpan.FromMinutes(5));
                GLib.Functions.IdleAdd(0, () =>
                {
                    LoadUpdates(showLoading: false);
                    return false;
                });
            }
        }

        void LoadUpdates(bool showLoading = true)
        {
            if (showLoading)
            {
                while (updatesListBox.GetFirstChild() is { } ch)
                    updatesListBox.Remove(ch);
                var loadingRow = ListBoxRow.New();
                var loadingLabel = Label.New("Loading...");
                loadingLabel.Halign = Align.Center;
                loadingLabel.AddCssClass("dim-label");
                loadingLabel.MarginTop = 8;
                loadingLabel.MarginBottom = 8;
                loadingRow.SetActivatable(false);
                loadingRow.SetChild(loadingLabel);
                updatesListBox.Append(loadingRow);
            }

            Task.Run(async () =>
            {
                var unprivilegedOps = serviceProvider.GetRequiredService<IUnprivilegedOperationService>();
                var updates = await unprivilegedOps.CheckForApplicationUpdates();
                var count = updates.Packages.Count + updates.Aur.Count + updates.Flatpaks.Count;
                GLib.Functions.IdleAdd(0, () =>
                {
                    updatesPopoverTitle.SetText($"Available Updates ({count})");
                    updatesMenuButton.SetLabel($"Updates ({count})");

                    while (updatesListBox.GetFirstChild() is { } child)
                        updatesListBox.Remove(child);

                    foreach (var pkg in updates.Packages)
                    {
                        var row = ListBoxRow.New();
                        var label = Label.New($"{pkg.Name}: {pkg.OldVersion} → {pkg.Version}");
                        label.Halign = Align.Start;
                        label.Wrap = true;
                        label.MarginStart = 8;
                        label.MarginEnd = 8;
                        label.MarginTop = 4;
                        label.MarginBottom = 4;
                        row.SetChild(label);
                        updatesListBox.Append(row);
                    }

                    foreach (var pkg in updates.Aur)
                    {
                        var row = ListBoxRow.New();
                        var label = Label.New($"[AUR] {pkg.Name}: {pkg.OldVersion} → {pkg.Version}");
                        label.Halign = Align.Start;
                        label.Wrap = true;
                        label.MarginStart = 8;
                        label.MarginEnd = 8;
                        label.MarginTop = 4;
                        label.MarginBottom = 4;
                        row.SetChild(label);
                        updatesListBox.Append(row);
                    }

                    foreach (var pkg in updates.Flatpaks)
                    {
                        var row = ListBoxRow.New();
                        var label = Label.New($"[Flatpak] {pkg.Name ?? pkg.Id}: {pkg.Version}");
                        label.Halign = Align.Start;
                        label.Wrap = true;
                        label.MarginStart = 8;
                        label.MarginEnd = 8;
                        label.MarginTop = 4;
                        label.MarginBottom = 4;
                        row.SetChild(label);
                        updatesListBox.Append(row);
                    }

                    if (count != 0) return false;
                    {
                        var row = ListBoxRow.New();
                        var label = Label.New("All packages are up to date");
                        label.Halign = Align.Center;
                        label.AddCssClass("dim-label");
                        label.MarginTop = 8;
                        label.MarginBottom = 8;
                        row.SetChild(label);
                        updatesListBox.Append(row);
                    }

                    return false;
                });
            });
        }
    }

    private static string GetHistoryIcon(string command)
    {
        if (command.Contains("sync", StringComparison.OrdinalIgnoreCase))
            return "emblem-synchronizing-symbolic";
        if (command.Contains("install", StringComparison.OrdinalIgnoreCase))
            return "list-add-symbolic";
        if (command.Contains("remove", StringComparison.OrdinalIgnoreCase))
            return "list-remove-symbolic";
        if (command.Contains("upgrade", StringComparison.OrdinalIgnoreCase) ||
            command.Contains("update", StringComparison.OrdinalIgnoreCase))
            return "software-update-available-symbolic";
        return "utilities-terminal-symbolic";
    }

    private static string FormatHistoryTime(DateTime timestamp)
    {
        var diff = DateTime.Now - timestamp;
        switch (diff.TotalMinutes)
        {
            case < 1:
                return "just now";
            case < 60:
                return $"{(int)diff.TotalMinutes} min ago";
        }

        if (diff.TotalHours < 24) return $"{(int)diff.TotalHours}h ago";
        
        return diff.TotalDays switch
        {
            < 2 => "yesterday",
            < 30 => $"{(int)diff.TotalDays}d ago",
            _ => timestamp.ToString("MMM d")
        };
    }

    public static string BuildUpgradeConfirmationMessage(SyncModel packages)
    {
        if (packages.TotalPackageCount == 0)
            return string.Empty;
        
        const int maxPackageColumnWidth = 28;
        var allNames = packages.Packages.Select(p => p.Name)
            .Concat(packages.Aur.Select(p => p.Name))
            .Concat(packages.Flatpaks.Select(p => p.Name ?? p.Id));
        var packageColumnWidth = Math.Min(maxPackageColumnWidth, allNames.Max(n => n.Length));

        var lines = packages.Packages
            .Select(p => $"{FormatPackageName(p.Name, packageColumnWidth)}  {p.OldVersion} -> {p.Version}")
            .Concat(packages.Aur
                .Select(p => $"{FormatPackageName(p.Name, packageColumnWidth)}  {p.OldVersion} -> {p.Version}"))
            .Concat(packages.Flatpaks
                .Select(p => $"{FormatPackageName(p.Name ?? p.Id, packageColumnWidth)}  {p.Version}"));

        return string.Join(Environment.NewLine, lines);
    }

    private static string FormatPackageName(string packageName, int width)
    {
        if (packageName.Length <= width) return packageName.PadRight(width);
        var truncatedWidth = Math.Max(1, width - 1);
        packageName = packageName[..truncatedWidth] + "…";

        return packageName.PadRight(width);
    }
}
