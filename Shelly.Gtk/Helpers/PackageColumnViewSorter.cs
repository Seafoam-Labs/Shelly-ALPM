using Gtk;
using Shelly.Gtk.Enums;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;

namespace Shelly.Gtk.Helpers;

public static class PackageColumnViewSorter
{
    public static void Sort(
        Gio.ListStore listStore,
        List<AlpmPackageDto> packageData,
        List<AlpmPackageGObject> items,
        PackageSortColumn column,
        SortType order,
        string? searchText = null)
    {
        Comparison<AlpmPackageGObject> baseComparison =
            column switch
            {
                PackageSortColumn.Name =>
                    (a, b) => Compare(
                        packageData[a.Index].Name,
                        packageData[b.Index].Name
                    ),

                PackageSortColumn.Repo =>
                    (a, b) => Compare(
                        packageData[a.Index].Repository,
                        packageData[b.Index].Repository
                    ),

                PackageSortColumn.Version =>
                    (a, b) => Compare(
                        packageData[a.Index].Version,
                        packageData[b.Index].Version
                    ),

                PackageSortColumn.Size =>
                    (a, b) => Compare(
                        packageData[a.Index].InstalledSize,
                        packageData[b.Index].InstalledSize
                    ),

                _ => (_, _) => 0
            };

        if (order == SortType.Descending)
        {
            var b0 = baseComparison;
            baseComparison = (a, b) => -b0(a, b);
        }

        Comparison<AlpmPackageGObject> comparison;
        if (!string.IsNullOrWhiteSpace(searchText))
        {
            var s = searchText;
            comparison = (a, b) =>
            {
                var sa = PackageSearch.Score(packageData[a.Index].Name, packageData[a.Index].Description, s);
                var sb = PackageSearch.Score(packageData[b.Index].Name, packageData[b.Index].Description, s);
                if (sa != sb) return sb - sa;
                return baseComparison(a, b);
            };
        }
        else
        {
            comparison = baseComparison;
        }

        SortInternalOriented(
            listStore,
            items,
            comparison
        );
    }

    /*
     * Legacy path for AlpmUpdateGObject
     */

    public static void Sort(
        Gio.ListStore listStore,
        List<AlpmUpdateGObject> items,
        PackageSortColumn column,
        SortType order)
    {
        Comparison<AlpmUpdateGObject> comparison =
            column switch
            {
                PackageSortColumn.Name =>
                    (a, b) => Compare(
                        a.Package?.Name,
                        b.Package?.Name
                    ),

                PackageSortColumn.Repo =>
                    (a, b) => Compare(
                        a.Package?.Repository,
                        b.Package?.Repository
                    ),
                
                PackageSortColumn.Size =>
                    (a, b) => Compare(
                        a.Package?.SizeDifference,
                        b.Package?.SizeDifference
                    ),

                PackageSortColumn.Size =>
                    (a, b) => Compare(
                        a.Package?.SizeDifference ?? 0,
                        b.Package?.SizeDifference ?? 0
                    ),

                _ => (_, _) => 0
            };

        SortInternal(
            listStore,
            items,
            comparison,
            order
        );
        
    }

    /*
     * Shared implementation
     */

    private static void SortInternal<T>(
        Gio.ListStore listStore,
        List<T> items,
        Comparison<T> comparison,
        SortType order)
        where T : GObject.Object
    {
        if (order == SortType.Descending)
        {
            var baseComp = comparison;

            comparison = (a, b) =>
                -baseComp(a, b);
        }

        items.Sort(comparison);
        
        SpliceReplace(
            listStore,
            items
        );
    }

    private static void SortInternalOriented<T>(
        Gio.ListStore listStore,
        List<T> items,
        Comparison<T> comparison)
        where T : GObject.Object
    {
        items.Sort(comparison);
        SpliceReplace(listStore, items);
    }

    private static int Compare(long? a, long? b)
    {
        return Nullable.Compare(a, b);
    }

    private static int Compare(
        string? a,
        string? b)
    {
        return string.Compare(
            a,
            b,
            StringComparison.OrdinalIgnoreCase
        );
    }

    private static int Compare(long a, long b)
    {
        return a.CompareTo(b);
    }

    private static void SpliceReplace<T>(
        Gio.ListStore listStore,
        List<T> items)
        where T : GObject.Object
    {
        var array = new GObject.Object[items.Count];

        for (int i = 0; i < items.Count; i++)
        {
            array[i] = items[i];
        }

        listStore.Splice(
            0,
            listStore.GetNItems(),
            array,
            (uint)array.Length
        );
    }
}