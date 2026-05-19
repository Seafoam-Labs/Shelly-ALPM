using GObject;
using Gtk;
using static Shelly.GTK.Resources.Translations;

namespace Shelly.Gtk.Helpers;


internal static class PackageSearch
{

    public static bool MatchesNameOrDescription(string? name, string? description, string? search)
    {
        if (string.IsNullOrWhiteSpace(search))
            return true;

        const StringComparison cmp = StringComparison.OrdinalIgnoreCase;
        return (name ?? string.Empty).Contains(search, cmp)
               || (description ?? string.Empty).Contains(search, cmp);
    }

    public static bool MatchesName(string? name, string? search)
    {
        if (string.IsNullOrWhiteSpace(search))
            return true;

        return (name ?? string.Empty)
            .Contains(search, StringComparison.OrdinalIgnoreCase);
    }


    public static bool MatchesGroup(IEnumerable<string>? groups, string? selectedGroup)
    {
        if (string.IsNullOrEmpty(selectedGroup) || selectedGroup == "Any" || selectedGroup == T("Any"))
            return true;

        return groups is not null && groups.Contains(selectedGroup);
    }


    public static CustomFilter CreateSafeFilter(Func<GObject.Object, bool> predicate)
    {
        return CustomFilter.New(obj =>
        {
            try
            {
                return predicate(obj);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[Shelly] FilterPackage threw, hiding row: {ex}");
                return false;
            }
        });
    }
}
