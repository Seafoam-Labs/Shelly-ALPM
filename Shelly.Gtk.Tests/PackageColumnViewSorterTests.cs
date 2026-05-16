using Gtk;
using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;
using ListStore = Gio.ListStore;

namespace Shelly.Gtk.Tests;

[TestFixture]
public class PackageColumnViewSorterTests
{
    private static bool _gtkReady;

    [OneTimeSetUp]
    public void OneTimeSetUp()
    {
        try
        {
            Module.Initialize();
            _gtkReady = true;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"GTK initialization skipped: {ex.Message}");
            _gtkReady = false;
        }
    }

    [SetUp]
    public void SetUp()
    {
        if (!_gtkReady)
            Assert.Inconclusive("GTK runtime not available in this environment");
    }

    // ---- AlpmPackageDto (PackageInstall / PackageManagement) ----

    [Test]
    public void Sort_AlpmPackageBySizeAscending_OrdersCorrectly()
    {
        var pkgs = new List<AlpmPackageDto>
        {
            new() { Name = "zilla", InstalledSize = 500_000_000 },
            new() { Name = "nano", InstalledSize = 2_000_000 },
            new() { Name = "emacs", InstalledSize = 200_000_000 },
        };

        var items = new List<AlpmPackageGObject>();
        var store = ListStore.New(AlpmPackageGObject.GetGType());
        for (var i = 0; i < pkgs.Count; i++)
        {
            var obj = AlpmPackageGObject.NewWithProperties([]);
            obj.Index = i;
            items.Add(obj);
            store.Append(obj);
        }

        PackageColumnViewSorter.Sort(store, pkgs, items, PackageSortColumn.Size, SortType.Ascending);

        Assert.Multiple(() =>
        {
            Assert.That(pkgs[items[0].Index].Name, Is.EqualTo("nano"));
            Assert.That(pkgs[items[1].Index].Name, Is.EqualTo("emacs"));
            Assert.That(pkgs[items[2].Index].Name, Is.EqualTo("zilla"));
        });
    }

    [Test]
    public void Sort_AlpmPackageBySizeDescending_OrdersCorrectly()
    {
        var pkgs = new List<AlpmPackageDto>
        {
            new() { Name = "nano", InstalledSize = 2_000_000 },
            new() { Name = "emacs", InstalledSize = 200_000_000 },
            new() { Name = "zilla", InstalledSize = 500_000_000 },
        };

        var items = new List<AlpmPackageGObject>();
        var store = ListStore.New(AlpmPackageGObject.GetGType());
        for (var i = 0; i < pkgs.Count; i++)
        {
            var obj = AlpmPackageGObject.NewWithProperties([]);
            obj.Index = i;
            items.Add(obj);
            store.Append(obj);
        }

        PackageColumnViewSorter.Sort(store, pkgs, items, PackageSortColumn.Size, SortType.Descending);

        Assert.Multiple(() =>
        {
            Assert.That(pkgs[items[0].Index].Name, Is.EqualTo("zilla"));
            Assert.That(pkgs[items[1].Index].Name, Is.EqualTo("emacs"));
            Assert.That(pkgs[items[2].Index].Name, Is.EqualTo("nano"));
        });
    }

    [Test]
    public void Sort_AlpmPackageBySize_TiesPreserveRelativeOrder()
    {
        var pkgs = new List<AlpmPackageDto>
        {
            new() { Name = "first", InstalledSize = 1000 },
            new() { Name = "second", InstalledSize = 1000 },
            new() { Name = "third", InstalledSize = 1000 },
        };

        var items = new List<AlpmPackageGObject>();
        var store = ListStore.New(AlpmPackageGObject.GetGType());
        for (var i = 0; i < pkgs.Count; i++)
        {
            var obj = AlpmPackageGObject.NewWithProperties([]);
            obj.Index = i;
            items.Add(obj);
            store.Append(obj);
        }

        PackageColumnViewSorter.Sort(store, pkgs, items, PackageSortColumn.Size, SortType.Ascending);

        Assert.Multiple(() =>
        {
            Assert.That(pkgs[items[0].Index].Name, Is.EqualTo("first"));
            Assert.That(pkgs[items[1].Index].Name, Is.EqualTo("second"));
            Assert.That(pkgs[items[2].Index].Name, Is.EqualTo("third"));
        });
    }

    [Test]
    public void Sort_AlpmPackageBySize_EmptyList_DoesNotThrow()
    {
        var pkgs = new List<AlpmPackageDto>();
        var items = new List<AlpmPackageGObject>();
        var store = ListStore.New(AlpmPackageGObject.GetGType());

        Assert.DoesNotThrow(() =>
            PackageColumnViewSorter.Sort(store, pkgs, items, PackageSortColumn.Size, SortType.Ascending));
    }

    [Test]
    public void Sort_AlpmPackageBySize_SingleItem_DoesNotThrow()
    {
        var pkgs = new List<AlpmPackageDto>
        {
            new() { Name = "solo", InstalledSize = 42_000 },
        };

        var items = new List<AlpmPackageGObject>();
        var store = ListStore.New(AlpmPackageGObject.GetGType());
        var obj = AlpmPackageGObject.NewWithProperties([]);
        obj.Index = 0;
        items.Add(obj);
        store.Append(obj);

        Assert.DoesNotThrow(() =>
            PackageColumnViewSorter.Sort(store, pkgs, items, PackageSortColumn.Size, SortType.Ascending));
    }

    // ---- AlpmUpdateGObject (PackageUpdate) ----

    [Test]
    public void Sort_AlpmUpdateBySizeAscending_OrdersBySizeDifference()
    {
        var items = new List<AlpmUpdateGObject>();
        var store = ListStore.New(AlpmUpdateGObject.GetGType());

        var data = new[] { ("big-change", 50_000_000L), ("small-change", 1_000_000L), ("medium-change", 10_000_000L) };
        foreach (var (name, diff) in data)
        {
            var obj = AlpmUpdateGObject.NewWithProperties([]);
            obj.Package = new AlpmPackageUpdateDto { Name = name, SizeDifference = diff };
            items.Add(obj);
            store.Append(obj);
        }

        PackageColumnViewSorter.Sort(store, items, PackageSortColumn.Size, SortType.Ascending);

        Assert.Multiple(() =>
        {
            Assert.That(items[0].Package!.Name, Is.EqualTo("small-change"));
            Assert.That(items[1].Package!.Name, Is.EqualTo("medium-change"));
            Assert.That(items[2].Package!.Name, Is.EqualTo("big-change"));
        });
    }

    [Test]
    public void Sort_AlpmUpdateBySizeDescending_OrdersBySizeDifference()
    {
        var items = new List<AlpmUpdateGObject>();
        var store = ListStore.New(AlpmUpdateGObject.GetGType());

        var data = new[] { ("small-change", 1_000_000L), ("big-change", 50_000_000L), ("medium-change", 10_000_000L) };
        foreach (var (name, diff) in data)
        {
            var obj = AlpmUpdateGObject.NewWithProperties([]);
            obj.Package = new AlpmPackageUpdateDto { Name = name, SizeDifference = diff };
            items.Add(obj);
            store.Append(obj);
        }

        PackageColumnViewSorter.Sort(store, items, PackageSortColumn.Size, SortType.Descending);

        Assert.Multiple(() =>
        {
            Assert.That(items[0].Package!.Name, Is.EqualTo("big-change"));
            Assert.That(items[1].Package!.Name, Is.EqualTo("medium-change"));
            Assert.That(items[2].Package!.Name, Is.EqualTo("small-change"));
        });
    }

    [Test]
    public void Sort_AlpmUpdateBySize_NullPackage_DoesNotThrow()
    {
        var items = new List<AlpmUpdateGObject>();
        var store = ListStore.New(AlpmUpdateGObject.GetGType());

        var obj = AlpmUpdateGObject.NewWithProperties([]);
        obj.Package = null;
        items.Add(obj);
        store.Append(obj);

        Assert.DoesNotThrow(() =>
            PackageColumnViewSorter.Sort(store, items, PackageSortColumn.Size, SortType.Ascending));
    }

    [Test]
    public void Sort_AlpmUpdateBySize_EmptyList_DoesNotThrow()
    {
        var items = new List<AlpmUpdateGObject>();
        var store = ListStore.New(AlpmUpdateGObject.GetGType());

        Assert.DoesNotThrow(() =>
            PackageColumnViewSorter.Sort(store, items, PackageSortColumn.Size, SortType.Ascending));
    }

    [Test]
    public void Sort_AlpmUpdateBySize_NegativeSizeDifference_SortsCorrectly()
    {
        var items = new List<AlpmUpdateGObject>();
        var store = ListStore.New(AlpmUpdateGObject.GetGType());

        var data = new[] { ("grows", 100_000L), ("shrinks", -50_000L), ("same", 0L) };
        foreach (var (name, diff) in data)
        {
            var obj = AlpmUpdateGObject.NewWithProperties([]);
            obj.Package = new AlpmPackageUpdateDto { Name = name, SizeDifference = diff };
            items.Add(obj);
            store.Append(obj);
        }

        PackageColumnViewSorter.Sort(store, items, PackageSortColumn.Size, SortType.Ascending);

        Assert.Multiple(() =>
        {
            Assert.That(items[0].Package!.Name, Is.EqualTo("shrinks"));
            Assert.That(items[1].Package!.Name, Is.EqualTo("same"));
            Assert.That(items[2].Package!.Name, Is.EqualTo("grows"));
        });
    }
}
