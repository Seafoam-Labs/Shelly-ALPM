using System.Text.RegularExpressions;
using System.Xml.Linq;
using GObject.Internal;
using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;

namespace Shelly.Gtk.Windows;

public class HomeWindow(
    IPrivilegedOperationService privilegedOperationService,
    IUnprivilegedOperationService unprivilegedOperationService) : IShellyWindow
{
    private Box _box = null!;
    private readonly CancellationTokenSource _cts = new();

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromFile("UiFiles/HomeWindow.ui");
        _box = (Box)builder.GetObject("HomeWindow")!;

        var listBox = (ListBox)builder.GetObject("NewsListBox")!;
        listBox.OnRealize += (sender, args) => { _ = LoadFeedAsync(listBox, _cts.Token); };

        var listView = (ListView)builder.GetObject("InstalledPackagesView")!;
        listView.OnRealize += (sender, args) => { _ = LoadPackagesAsync(listView, _cts.Token); };

        var totalAurLabel = (Label)builder.GetObject("TotalAurLabel")!;
        totalAurLabel.OnRealize += (sender, args) => { _ = LoadAurTotalData(totalAurLabel, _cts.Token); };

        var percentAurLabel = (Label)builder.GetObject("AurPercentLabel")!;
        percentAurLabel.OnRealize += (sender, args) => { _ = LoadAurPercentData(percentAurLabel, _cts.Token); };

        var totalPackageLabel = (Label)builder.GetObject("TotalPackagesLabel")!;
        totalPackageLabel.OnRealize += (sender, args) => { _ = LoadTotalPackageData(totalPackageLabel, _cts.Token); };

        var packagePercentLabel = (Label)builder.GetObject("StandardPercent")!;
        packagePercentLabel.OnRealize += (sender, args) => { _ = LoadTotalPackagePercentData(packagePercentLabel, _cts.Token); };

        var totalFlatpakLabel = (Label)builder.GetObject("TotalFlatpakLabel")!;
        totalFlatpakLabel.OnRealize += (sender, args) => { _ = LoadTotalFlatpak(totalFlatpakLabel, _cts.Token); };

        var flatpakPercentLabel = (Label)builder.GetObject("FlatpakPercent")!;
        flatpakPercentLabel.OnRealize += (sender, args) => { _ = LoadPercentFlatpak(flatpakPercentLabel, _cts.Token); };

        var exportSyncButton = (Button)builder.GetObject("ExportSyncButton")!;
        exportSyncButton.OnClicked += (sender, args) => { _ = ExportSync(); };
        return _box;
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


            await dialog.SaveAsync((Window)_box.GetRoot()!);
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
        ct.ThrowIfCancellationRequested();
        var updates = await unprivilegedOperationService.CheckForApplicationUpdates();
        ct.ThrowIfCancellationRequested();
        try
        {
            GLib.Functions.IdleAdd(0, () =>
            {
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

    private async Task LoadPackagesAsync(ListView listView, CancellationToken ct)
    {
        var packages = await privilegedOperationService.GetInstalledPackagesAsync();
        ct.ThrowIfCancellationRequested();
        try
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                PopulateInstalledPackages(listView, packages);
                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }
    }

    private static void PopulateInstalledPackages(ListView listView, List<AlpmPackageDto> packages)
    {
        var store = Gio.ListStore.New(AlpmPackageGObject.GetGType());
        foreach (var pkg in packages)
            store.Append(new AlpmPackageGObject() { Package = pkg });

        var factory = SignalListItemFactory.New();

        factory.OnSetup += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            listItem.SetChild(BuildRow());
        };

        factory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            var pkg = ((AlpmPackageGObject)listItem.GetItem()!).Package!;
            var grid = (Grid)listItem.GetChild()!;

            FindLabel(grid, "name").SetMarkup($"<b>{GLib.Markup.EscapeText(pkg.Name)}</b>");
            FindLabel(grid, "version").SetText(pkg.Version);
            FindLabel(grid, "size").SetText(SizeHelpers.FormatSize(pkg.InstalledSize));
            FindLabel(grid, "reason").SetText(pkg.InstallReason);
            FindLabel(grid, "date").SetText(pkg.InstallDate.ToString() ?? string.Empty);
        };

        listView.SetModel(NoSelection.New(store));
        listView.SetFactory(factory);
    }
    
    private static Label FindLabel(Grid grid, string name)
    {
        var child = grid.GetFirstChild();
        while (child != null)
        {
            if (child is Label label && label.Name == name)
                return label;
            child = child.GetNextSibling();
        }
        throw new Exception($"Label '{name}' not found");
    }

    private static Grid BuildRow()
    {
        var grid = Grid.New();
        grid.MarginStart = 6;
        grid.MarginEnd = 8;
        grid.MarginTop = 2;
        grid.MarginBottom = 2;

        var name = Label.New("");
        name.Name = "name";
        name.Halign = Align.Start;
        name.Hexpand = true;
        name.Wrap = true;

        var version = Label.New("");
        version.Name = "version";
        version.Halign = Align.Start;
        version.AddCssClass("dim-label");

        var size = Label.New("");
        size.Name = "size";
        size.Halign = Align.Start;
        size.AddCssClass("dim-label");

        var reason = Label.New("");
        reason.Name = "reason";
        reason.Halign = Align.End;
        reason.AddCssClass("dim-label");

        var date = Label.New("");
        date.Name = "date";
        date.Halign = Align.End;
        date.AddCssClass("dim-label");

        grid.Attach(name,    0, 0, 2, 1);
        grid.Attach(reason,  1, 1, 1, 1);
        grid.Attach(version, 0, 1, 1, 1);
        grid.Attach(date,    1, 2, 1, 1);
        grid.Attach(size,    0, 2, 1, 1);

        return grid;
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

            row.SetChild(vbox);
            listBox.Append(row);
        }
    }

    // Port these from HomeViewModel or reference them from a shared service
    private static async Task<List<RssModel>> GetRssFeedAsync(string url, CancellationToken ct = default)
    {
        var items = new List<RssModel>();
        using var client = new HttpClient();
        var xmlString = await client.GetStringAsync(url, ct);
        var xml = XDocument.Parse(xmlString);

        foreach (var item in xml.Descendants("item"))
        {
            items.Add(new RssModel
            {
                Title = item.Element("title")?.Value ?? "",
                Link = item.Element("link")?.Value ?? "",
                Description = Regex.Replace(item.Element("description")?.Value ?? "", "<.*?>", string.Empty),
                PubDate = item.Element("pubDate")?.Value ?? ""
            });
        }

        return items;
    }

    public void Dispose()
    {
        _cts.Cancel();
        _cts.Dispose();
    }
}