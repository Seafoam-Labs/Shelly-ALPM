using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
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
    MetaSearch metaSearch) : IShellyWindow
{
    private Box _box = null!;
    private readonly CancellationTokenSource _cts = new();
    private ListBox? _listBox;
    private Label? _totalAurLabel;
    private Label? _percentAurLabel;
    private Label? _totalPackageLabel;
    private Label? _packagePercentLabel;
    private Label? _totalFlatpakLabel;
    private Label? _flatpakPercentLabel;

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/HomeWindow.ui"), -1);
        _box = (Box)builder.GetObject("HomeWindow")!;

        var listBox = (ListBox)builder.GetObject("NewsListBox")!;
        _listBox = listBox;
        listBox.OnRealize += (sender, args) => { _ = LoadFeedAsync(listBox, _cts.Token); };

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

        return _box;
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
        if (_listBox is not null)
            tasks.Add(LoadFeedAsync(_listBox, _cts.Token));

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


    private static async Task LoadFeedAsync(ListBox listBox, CancellationToken ct)
    {
        var feedItems = new List<RssModel>();

        // Fetch from network
        try
        {
            var feed = await GetRssFeedAsync("https://archlinux.org/feeds/news/", ct);
            ct.ThrowIfCancellationRequested();
            feedItems.AddRange(feed);

            // Marshal back to GTK main thread to update UI
            GLib.Functions.IdleAdd(0, () =>
            {
                PopulateListBox(listBox, feedItems);
                return false; // run once
            });

            // Cache the result
            var cachedFeed = new CachedRssModel
            {
                TimeCached = DateTime.Now,
                Rss = feedItems
            };
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }
    }

    private static void PopulateListBox(ListBox listBox, List<RssModel> items)
    {
        // Clear existing rows
        while (listBox.GetFirstChild() is { } child)
            listBox.Remove(child);

        foreach (var item in items)
        {
            var row = new ListBoxRow();
            var vbox = Box.New(Orientation.Vertical, 4);
            vbox.MarginStart = 8;
            vbox.MarginEnd = 8;
            vbox.MarginTop = 4;
            vbox.MarginBottom = 4;

            var title = Label.New(item.Title);
            title.Halign = Align.Start;
            title.Wrap = true;
            title.AddCssClass("heading");

            var date = Label.New(item.PubDate);
            date.Halign = Align.Start;
            date.AddCssClass("dim-label");

            var desc = Label.New(item.Description);
            desc.Halign = Align.Start;
            desc.Wrap = true;

            vbox.Append(title);
            vbox.Append(date);
            vbox.Append(desc);

            row.SetActivatable(false);
            row.SetChild(vbox);
            listBox.Append(row);
        }
    }

    // Port these from HomeViewModel or reference them from a shared service
    private static async Task<List<RssModel>> GetRssFeedAsync(string url, CancellationToken ct = default)
    {
        using var client = new HttpClient();
        var xmlString = await client.GetStringAsync(url, ct);
        var xml = XDocument.Parse(xmlString);

        return xml.Descendants("item").Select(item => new RssModel
        {
            Title = item.Element("title")?.Value ?? "", Link = item.Element("link")?.Value ?? "",
            Description = Regex.Replace(item.Element("description")?.Value ?? "", "<.*?>", string.Empty),
            PubDate = item.Element("pubDate")?.Value ?? ""
        }).ToList();
    }

    public void Dispose()
    {
        _cts.Cancel();
        _cts.Dispose();
    }
}