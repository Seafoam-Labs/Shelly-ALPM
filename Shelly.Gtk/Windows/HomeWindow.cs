using System.Text;
using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.Services.Icons;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows;

public class HomeWindow(
    IPrivilegedOperationService privilegedOperationService,
    IUnprivilegedOperationService unprivilegedOperationService,
    IConfigService configService,
    ILockoutService lockoutService,
    IIconResolverService iconResolverService,
    IGenericQuestionService genericQuestionService,
    IArchNewsService archNewsService,
    MetaSearch metaSearch) : IShellyWindow
{
    private Box _box = null!;
    private readonly CancellationTokenSource _cts = new();
    private Revealer? _updatesRevealer;
    private ListBox? _updatesListBox;
    private Box? _archNewsContentBox;
    private Label? _archNewsPageLabel;
    private Button? _archNewsPrevButton;
    private Button? _archNewsNextButton;
    private List<RssModel> _archNewsItems = [];
    private int _archNewsCurrentIndex;
    private Label? _totalAurLabel;
    private Label? _percentAurLabel;
    private Label? _totalPackageLabel;
    private Label? _packagePercentLabel;
    private Label? _totalFlatpakLabel;
    private Label? _flatpakPercentLabel;

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/HomeWindow.ui"), -1);
        var overlay = (Overlay)builder.GetObject("HomeWindowOverlay")!;
        _box = (Box)builder.GetObject("HomeWindow")!;

        _updatesRevealer = (Revealer)builder.GetObject("UpdatesRevealer")!;
        _updatesListBox = (ListBox)builder.GetObject("UpdatesListBox")!;
        var showUpdatesButton = (ToggleButton)builder.GetObject("ShowUpdatesButton")!;

        var arrowImage = (Image)showUpdatesButton.GetFirstChild()!;
        showUpdatesButton.OnToggled += (sender, args) =>
        {
            _updatesRevealer.RevealChild = showUpdatesButton.Active;
            arrowImage.SetFromIconName(showUpdatesButton.Active
                ? "pan-end-symbolic"
                : "pan-start-symbolic");
            if (showUpdatesButton.Active && _updatesListBox is not null)
            {
                _ = LoadUpdatesPanel(_updatesListBox, _cts.Token);
            }
        };

        var homeSearchEntry = (SearchEntry)builder.GetObject("HomeSearchEntry")!;
        var metaSearchContainer = (Box)builder.GetObject("MetaSearchContainer")!;
        var searchPromptOverlay = (Box)builder.GetObject("SearchPromptOverlay")!;

        homeSearchEntry.OnActivate += (_, _) =>
        {
            var query = homeSearchEntry.GetText();
            if (string.IsNullOrWhiteSpace(query)) return;

            searchPromptOverlay.SetVisible(false);

            while (metaSearchContainer.GetFirstChild() is { } child)
                metaSearchContainer.Remove(child);

            var metaSearchWidget = metaSearch.CreateWindow(query);
            metaSearchContainer.Append(metaSearchWidget);
            homeSearchEntry.SetText(string.Empty);
        };

        _totalAurLabel = (Label)builder.GetObject("TotalAurLabel")!;
        _totalAurLabel.OnRealize += (sender, args) => { _ = LoadAurTotalData(_totalAurLabel, _cts.Token); };

        _percentAurLabel = (Label)builder.GetObject("AurPercentLabel")!;
        _percentAurLabel.OnRealize += (sender, args) => { _ = LoadAurPercentData(_percentAurLabel, _cts.Token); };

        _totalPackageLabel = (Label)builder.GetObject("TotalPackagesLabel")!;
        _totalPackageLabel.OnRealize += (sender, args) => { _ = LoadTotalPackageData(_totalPackageLabel, _cts.Token); };

        _packagePercentLabel = (Label)builder.GetObject("StandardPercent")!;
        _packagePercentLabel.OnRealize += (sender, args) =>
        {
            _ = LoadTotalPackagePercentData(_packagePercentLabel, _cts.Token);
        };

        _totalFlatpakLabel = (Label)builder.GetObject("TotalFlatpakLabel")!;
        _totalFlatpakLabel.OnRealize += (sender, args) => { _ = LoadTotalFlatpak(_totalFlatpakLabel, _cts.Token); };

        _flatpakPercentLabel = (Label)builder.GetObject("FlatpakPercent")!;
        _flatpakPercentLabel.OnRealize += (sender, args) =>
        {
            _ = LoadPercentFlatpak(_flatpakPercentLabel, _cts.Token);
        };

        var exportSyncButton = (Button)builder.GetObject("ExportSyncButton")!;
        exportSyncButton.OnClicked += (sender, args) => { _ = ExportSync(); };

        var upgradeAllButton = (Button)builder.GetObject("UpgradeAllButton")!;
        upgradeAllButton.OnClicked += (sender, args) => { _ = UpgradeAll(); };
        
        var config = configService.LoadConfig();
        var aurBox = (Box)builder.GetObject("AurBox")!;
        var flatpakBox = (Box)builder.GetObject("FlatpakBox")!;

        aurBox.Visible = config.AurEnabled;
        flatpakBox.Visible = config.FlatPackEnabled;

        configService.ConfigSaved += (sender, updatedConfig) =>
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                aurBox.Visible = updatedConfig.AurEnabled;
                flatpakBox.Visible = updatedConfig.FlatPackEnabled;
                return false;
            });
        };

        _archNewsContentBox = (Box)builder.GetObject("ArchNewsContentBox")!;
        _archNewsPageLabel = (Label)builder.GetObject("ArchNewsPageLabel")!;
        _archNewsPrevButton = (Button)builder.GetObject("ArchNewsPrevButton")!;
        _archNewsNextButton = (Button)builder.GetObject("ArchNewsNextButton")!;

        _archNewsPrevButton.OnClicked += (_, _) => ShowArchNewsItem(_archNewsCurrentIndex - 1);
        _archNewsNextButton.OnClicked += (_, _) => ShowArchNewsItem(_archNewsCurrentIndex + 1);

        _ = LoadArchNews(_cts.Token);

        return overlay;
    }

    private async Task UpgradeAll()
    {
        try
        {
            var packagesNeedingUpdate = await unprivilegedOperationService.CheckForApplicationUpdates();

            if (packagesNeedingUpdate.Aur.Count == 0 && packagesNeedingUpdate.Packages.Count == 0 &&
                packagesNeedingUpdate.Flatpaks.Count == 0)
            {
                var toastArgs = new ToastMessageEventArgs("No packages need to be upgraded");
                genericQuestionService.RaiseToastMessage(toastArgs);
                return;
            }
            
            var standardPackagesNeedingUpdate = packagesNeedingUpdate.Packages;
            if (standardPackagesNeedingUpdate.Count == 0)
            {
                var toastArgs = new ToastMessageEventArgs("Standard Packages is already up to date");
                genericQuestionService.RaiseToastMessage(toastArgs);
            }

            if (!configService.LoadConfig().NoConfirm)
            {
                var confirmArgs = new GenericQuestionEventArgs(
                    "Upgrade All Packages?",
                    BuildUpgradeConfirmationMessage(standardPackagesNeedingUpdate),
                    true
                );

                genericQuestionService.RaiseQuestion(confirmArgs);
                if (!await confirmArgs.ResponseTask)
                {
                    return;
                }
            }

            lockoutService.Show("Upgrading all packages...");
            
            var aurUpdates = packagesNeedingUpdate.Aur;
            if (aurUpdates.Count != 0)
            {
                var aurPackageNames = aurUpdates.Select(p => p.Name).ToList();
                var packageBuilds = await privilegedOperationService.GetAurPackageBuild(aurPackageNames);

                foreach (var pkgbuild in packageBuilds)
                {
                    if (pkgbuild.PkgBuild == null) continue;

                    var buildArgs = new PackageBuildEventArgs($"Displaying Package Build {pkgbuild.Name}",
                        pkgbuild.PkgBuild);
                    genericQuestionService.RaisePackageBuild(buildArgs);

                    if (!await buildArgs.ResponseTask)
                    {
                        return;
                    }
                }
            }

            await privilegedOperationService.UpgradeAllAsync();
            await ReloadHomePageData();
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }
        finally
        {
            lockoutService.Hide();
        }
    }

    private async Task ReloadHomePageData()
    {
        var tasks = new List<Task>();

        if (_totalAurLabel is not null)
            tasks.Add(LoadAurTotalData(_totalAurLabel, _cts.Token));
        if (_percentAurLabel is not null)
            tasks.Add(LoadAurPercentData(_percentAurLabel, _cts.Token));
        if (_totalPackageLabel is not null)
            tasks.Add(LoadTotalPackageData(_totalPackageLabel, _cts.Token));
        if (_packagePercentLabel is not null)
            tasks.Add(LoadTotalPackagePercentData(_packagePercentLabel, _cts.Token));
        if (_totalFlatpakLabel is not null)
            tasks.Add(LoadTotalFlatpak(_totalFlatpakLabel, _cts.Token));
        if (_flatpakPercentLabel is not null)
            tasks.Add(LoadPercentFlatpak(_flatpakPercentLabel, _cts.Token));
        if (_updatesListBox is not null)
            tasks.Add(LoadUpdatesPanel(_updatesListBox, _cts.Token));

        await Task.WhenAll(tasks);
    }

    private static string BuildUpgradeConfirmationMessage(IEnumerable<SyncPackageModel> packages)
    {
        var packageList = packages.ToList();
        if (packageList.Count == 0)
        {
            return string.Empty;
        }

        const int maxPackageColumnWidth = 28;
        var packageColumnWidth = Math.Min(
            maxPackageColumnWidth,
            packageList.Max(package => package.Name.Length));

        return string.Join(Environment.NewLine, packageList.Select(package =>
            $"{FormatPackageName(package.Name, packageColumnWidth)}  {package.Version} -> {package.OldVersion}"));
    }

    private static string FormatPackageName(string packageName, int width)
    {
        if (packageName.Length > width)
        {
            var truncatedWidth = Math.Max(1, width - 1);
            packageName = packageName[..truncatedWidth] + "…";
        }

        return packageName.PadRight(width);
    }

    private async Task ExportSync()
    {
        try
        {
            var suggestName = $"{DateTime.Now:yyyyMMddHHmmss}_shelly.sync";

            var dialog = FileDialog.New();
            dialog.SetTitle("Export Sync File");
            dialog.SetInitialName(suggestName);

            var filter = FileFilter.New();
            filter.SetName("Sync Files (*.sync)");
            filter.AddPattern("*.sync");

            var filters = Gio.ListStore.New(FileFilter.GetGType());
            filters.Append(filter);
            dialog.SetFilters(filters);

            var file = await dialog.SaveAsync((Window)_box.GetRoot()!);

            if (file is not null)
            {
                var path = file.GetPath()!;

                // Generate whatever content you want to save
                var packages = await privilegedOperationService.GetInstalledPackagesAsync();
                var stringBuilder = new StringBuilder();
                foreach (var pkg in packages)
                {
                    stringBuilder.AppendLine(
                        $"{pkg.Name} - {pkg.Version} : Depends: {string.Join(",", pkg.Depends)} OptDepends {string.Join(",", pkg.OptDepends)}");
                }

                await System.IO.File.WriteAllTextAsync(path, stringBuilder.ToString());
            }
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }
    }

    private async Task LoadPercentFlatpak(Label label, CancellationToken ct)
    {
        var packages = await unprivilegedOperationService.ListFlatpakPackages();
        ct.ThrowIfCancellationRequested();
        var updates = await unprivilegedOperationService.CheckForApplicationUpdates();
        ct.ThrowIfCancellationRequested();
        try
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                if (packages.Count == 0)
                {
                    label.SetText("N/A");
                    return false;
                }

                var ratio = (double)(packages.Count - updates.Flatpaks.Count) / packages.Count * 100;
                var labelText = $"{ratio:F2} %";
                label.SetText(labelText);
                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }
    }

    private async Task LoadTotalFlatpak(Label label, CancellationToken ct)
    {
        var packages = await unprivilegedOperationService.ListFlatpakPackages();
        ct.ThrowIfCancellationRequested();
        try
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                label.SetText(packages.Count.ToString());
                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }
    }

    private async Task LoadTotalPackagePercentData(Label label, CancellationToken ct)
    {
        var packages = await privilegedOperationService.GetInstalledPackagesAsync();

        PreLoadIcons(packages.Select(x => x.Name).ToList());
        
        ct.ThrowIfCancellationRequested();
        var updates = await unprivilegedOperationService.CheckForApplicationUpdates();
        ct.ThrowIfCancellationRequested();
        try
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                if (packages.Count == 0)
                {
                    label.SetText("N/A");
                    return false;
                }

                var ratio = (double)(packages.Count - updates.Packages.Count) / packages.Count * 100;
                var labelText = $"{ratio:F2} %";
                label.SetText(labelText);
                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }
    }

    private void PreLoadIcons(List<string> icons)
    {
        Task.Run(() =>
        {
            iconResolverService.PreloadIcons(icons);
            return Task.CompletedTask;
        });
    }

    private async Task LoadTotalPackageData(Label label, CancellationToken ct)
    {
        var packages = await privilegedOperationService.GetInstalledPackagesAsync();
        ct.ThrowIfCancellationRequested();
        try
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                PopulateTotalPackageLabel(label, packages);
                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }
    }

    private static void PopulateTotalPackageLabel(Label label, List<AlpmPackageDto> packages)
    {
        label.SetText(packages.Count.ToString());
    }

    private async Task LoadAurPercentData(Label label, CancellationToken ct)
    {
        var aurPackages = await privilegedOperationService.GetAurInstalledPackagesAsync();
        ct.ThrowIfCancellationRequested();
        var updates = await unprivilegedOperationService.CheckForApplicationUpdates();
        ct.ThrowIfCancellationRequested();
        try
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                PopulateAurPercentLabel(label, aurPackages, updates);
                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }
    }

    private static void PopulateAurPercentLabel(Label label, List<AurPackageDto> packages, SyncModel syncModel)
    {
        if (packages.Count == 0)
        {
            label.SetText("N/A");
            return;
        }

        var ratio = (double)(packages.Count - syncModel.Aur.Count) / packages.Count * 100;
        var labelText = $"{ratio:F2} %";
        label.SetText(labelText);
    }

    private async Task LoadAurTotalData(Label label, CancellationToken ct)
    {
        var aurPackages = await privilegedOperationService.GetAurInstalledPackagesAsync();
        ct.ThrowIfCancellationRequested();
        try
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                PopulateAurTotalLabel(label, aurPackages);
                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }
    }

    private static void PopulateAurTotalLabel(Label label, List<AurPackageDto> packages)
    {
        label.SetText(packages.Count.ToString());
    }


    private async Task LoadUpdatesPanel(ListBox listBox, CancellationToken ct)
    {
        try
        {
            var updates = await unprivilegedOperationService.CheckForApplicationUpdates();
            ct.ThrowIfCancellationRequested();

            GLib.Functions.IdleAdd(0, () =>
            {
                // Clear existing rows
                while (listBox.GetFirstChild() is { } child)
                    listBox.Remove(child);

                foreach (var pkg in updates.Packages)
                {
                    var row = new ListBoxRow();
                    var label = Label.New($"{pkg.Name}: {pkg.OldVersion} → {pkg.Version}");
                    label.Halign = Align.Start;
                    label.Wrap = true;
                    label.MarginStart = 8;
                    label.MarginEnd = 8;
                    label.MarginTop = 4;
                    label.MarginBottom = 4;
                    row.SetActivatable(false);
                    row.SetChild(label);
                    listBox.Append(row);
                }

                foreach (var pkg in updates.Aur)
                {
                    var row = new ListBoxRow();
                    var label = Label.New($"[AUR] {pkg.Name}: {pkg.OldVersion} → {pkg.Version}");
                    label.Halign = Align.Start;
                    label.Wrap = true;
                    label.MarginStart = 8;
                    label.MarginEnd = 8;
                    label.MarginTop = 4;
                    label.MarginBottom = 4;
                    row.SetActivatable(false);
                    row.SetChild(label);
                    listBox.Append(row);
                }

                foreach (var pkg in updates.Flatpaks)
                {
                    var row = new ListBoxRow();
                    var label = Label.New($"[Flatpak] {pkg.Name ?? pkg.Id}: {pkg.Version}");
                    label.Halign = Align.Start;
                    label.Wrap = true;
                    label.MarginStart = 8;
                    label.MarginEnd = 8;
                    label.MarginTop = 4;
                    label.MarginBottom = 4;
                    row.SetActivatable(false);
                    row.SetChild(label);
                    listBox.Append(row);
                }

                if (updates.Packages.Count == 0 && updates.Aur.Count == 0 && updates.Flatpaks.Count == 0)
                {
                    var row = new ListBoxRow();
                    var label = Label.New("All packages are up to date");
                    label.Halign = Align.Center;
                    label.AddCssClass("dim-label");
                    label.MarginTop = 8;
                    label.MarginBottom = 8;
                    row.SetActivatable(false);
                    row.SetChild(label);
                    listBox.Append(row);
                }

                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }
    }

    private async Task LoadArchNews(CancellationToken ct)
    {
        try
        {
            var items = await archNewsService.FetchNewsAsync(ct);
            ct.ThrowIfCancellationRequested();

            GLib.Functions.IdleAdd(0, () =>
            {
                _archNewsItems = items.Take(10).ToList();
                _archNewsCurrentIndex = 0;

                if (_archNewsItems.Count == 0)
                {
                    ShowArchNewsPlaceholder("Unable to load Arch News");
                }
                else
                {
                    ShowArchNewsItem(0);
                }

                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to load Arch News: {e.Message}");
        }
    }

    private void ShowArchNewsItem(int index)
    {
        if (_archNewsContentBox is null || _archNewsItems.Count == 0) return;

        _archNewsCurrentIndex = Math.Clamp(index, 0, _archNewsItems.Count - 1);
        var item = _archNewsItems[_archNewsCurrentIndex];

        while (_archNewsContentBox.GetFirstChild() is { } child)
            _archNewsContentBox.Remove(child);

        var titleLabel = Label.New(item.Title);
        titleLabel.AddCssClass("title-4");
        titleLabel.SetXalign(0);
        titleLabel.Wrap = true;
        titleLabel.MaxWidthChars = 20;

        var dateLabel = Label.New(item.PubDate ?? string.Empty);
        dateLabel.AddCssClass("caption");
        dateLabel.AddCssClass("dim-label");
        dateLabel.SetXalign(0);
        dateLabel.MaxWidthChars = 20;

        _archNewsContentBox.Append(titleLabel);
        _archNewsContentBox.Append(dateLabel);

        if (!string.IsNullOrEmpty(item.Link))
        {
            var linkButton = new Button();
            linkButton.SetLabel("Read more...");
            linkButton.AddCssClass("flat");
            linkButton.Halign = Align.Start;
            var link = item.Link;
            linkButton.OnClicked += (_, _) =>
            {
                try
                {
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = link,
                        UseShellExecute = true
                    });
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Failed to open link: {ex.Message}");
                }
            };
            _archNewsContentBox.Append(linkButton);
        }

        _archNewsPrevButton!.Sensitive = _archNewsCurrentIndex > 0;
        _archNewsNextButton!.Sensitive = _archNewsCurrentIndex < _archNewsItems.Count - 1;
        _archNewsPageLabel!.SetText($"{_archNewsCurrentIndex + 1} / {_archNewsItems.Count}");
    }

    private void ShowArchNewsPlaceholder(string message)
    {
        if (_archNewsContentBox is null) return;

        while (_archNewsContentBox.GetFirstChild() is { } child)
            _archNewsContentBox.Remove(child);

        var label = Label.New(message);
        label.Halign = Align.Center;
        label.AddCssClass("dim-label");
        _archNewsContentBox.Append(label);

        _archNewsPrevButton!.Sensitive = false;
        _archNewsNextButton!.Sensitive = false;
        _archNewsPageLabel!.SetText("0 / 0");
    }

    public void Dispose()
    {
        _cts.Cancel();
        _cts.Dispose();
    }
}