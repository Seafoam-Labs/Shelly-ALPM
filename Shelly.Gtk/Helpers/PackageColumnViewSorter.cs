using Gtk;
using Gio;
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
        SortType order)
    {
        Comparison<AlpmPackageGObject> comparison =
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