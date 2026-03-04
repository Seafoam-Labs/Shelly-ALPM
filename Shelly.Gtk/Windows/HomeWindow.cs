using System.Text.RegularExpressions;
using System.Xml.Linq;
using GObject.Internal;
using Gtk;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;

namespace Shelly.Gtk.Windows;

public class HomeWindow(
    IPrivilegedOperationService privilegedOperationService,
    IUnprivilegedOperationService unprivilegedOperationService) : IShellyWindow
{
    private List<AlpmPackageDto> _packages = [];

    public Box CreateWindow()
    {
        var builder = Builder.NewFromFile("UiFiles/HomeWindow.ui");
        var box = (Box)builder.GetObject("HomeWindow")!;

        var listBox = (ListBox)builder.GetObject("NewsListBox")!;
        listBox.OnRealize += (sender, args) => { _ = LoadFeedAsync(listBox); };

        var columnView = (ColumnView)builder.GetObject("InstalledPackagesView")!;
        columnView.OnRealize += (sender, args) => { _ = LoadPackagesAsync(columnView); };
        return box;
    }

    private async Task LoadPackagesAsync(ColumnView columnView)
    {
        try
        {
            _packages = await privilegedOperationService.GetInstalledPackagesAsync();
            GLib.Functions.IdleAdd(0, () =>
            {
                PopulateInstalledPackages(columnView, _packages);
                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }
    }

    private static void PopulateInstalledPackages(ColumnView columnView, List<AlpmPackageDto> packages)
    {
        var store = Gio.ListStore.New(AlpmPackageGObject.GetGType());
        foreach (var pkg in packages)
        {
            store.Append(new AlpmPackageGObject() { Package = pkg });
        }

        var viewModel = NoSelection.New(store);
        columnView.SetModel(viewModel);
        // Just append columns directly — no need to remove if none exist yet
        columnView.AppendColumn(CreateColumn("Name", obj => obj.Package?.Name ?? ""));
        columnView.AppendColumn(CreateColumn("Version", obj => obj.Package?.Version ?? ""));
        columnView.AppendColumn(CreateColumn("Description", obj => obj.Package?.Description ?? ""));
    }

    private static ColumnViewColumn CreateColumn(string title, Func<AlpmPackageGObject, string> getText)
    {
        var factory = SignalListItemFactory.New();

        factory.OnSetup += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            var label = Label.New("");
            label.Halign = Align.Start;
            label.Ellipsize = Pango.EllipsizeMode.End;
            listItem.SetChild(label);
        };

        factory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            var item = (AlpmPackageGObject)listItem.GetItem()!;
            var label = (Label)listItem.GetChild()!;
            label.SetText(getText(item));
        };

        var column = ColumnViewColumn.New(title, factory);
        column.SetResizable(true);
        column.SetExpand(title == "Description"); // let Description expand
        return column;
    }

    private static async Task LoadFeedAsync(ListBox listBox)
    {
        var feedItems = new List<RssModel>();

        // Fetch from network
        try
        {
            var feed = await GetRssFeedAsync("https://archlinux.org/feeds/news/");
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
            title.AddCssClass("heading");

            var date = Label.New(item.PubDate);
            date.Halign = Align.Start;
            date.AddCssClass("dim-label");

            var desc = Label.New(item.Description);
            desc.Halign = Align.Start;
            desc.Wrap = true;
            desc.SetMaxWidthChars(80);

            vbox.Append(title);
            vbox.Append(date);
            vbox.Append(desc);

            row.SetChild(vbox);
            listBox.Append(row);
        }
    }

    // Port these from HomeViewModel or reference them from a shared service
    private static async Task<List<RssModel>> GetRssFeedAsync(string url)
    {
        var items = new List<RssModel>();
        using var client = new HttpClient();
        var xmlString = await client.GetStringAsync(url);
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
}