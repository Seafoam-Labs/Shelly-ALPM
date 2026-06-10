using GObject;
using Gtk;
using static Shelly.GTK.Resources.Translations;

namespace Shelly.Gtk.Helpers;


internal static class PackageSearch
{

    public static int Score(string? name, string? description, string? search)
    {
        if (string.IsNullOrWhiteSpace(search))
            return 1;

        const StringComparison cmp = StringComparison.OrdinalIgnoreCase;
        var n = name ?? string.Empty;
        var d = description ?? string.Empty;
        var s = search.Trim();

        if (n.Equals(s, cmp)) return 1000;
        if (n.StartsWith(s, cmp)) return 800;
        if (ContainsWord(n, s, cmp)) return 600;
        if (n.Contains(s, cmp)) return 400;

        if (d.StartsWith(s, cmp)) return 200;
        if (ContainsWord(d, s, cmp)) return 150;
        if (d.Contains(s, cmp)) return 100;

        return 0;
    }

    public static bool Matches(string? name, string? description, string? search)
        => Score(name, description, search) > 0;

    public static bool MatchesNameOrDescription(string? name, string? description, string? search)
        => Matches(name, description, search);

    private static bool ContainsWord(string haystack, string needle, StringComparison cmp)
    {
        int i = 0;
        while ((i = haystack.IndexOf(needle, i, cmp)) >= 0)
        {
            bool leftOk = i == 0 || !char.IsLetterOrDigit(haystack[i - 1]);
            bool rightOk = i + needle.Length == haystack.Length
                           || !char.IsLetterOrDigit(haystack[i + needle.Length]);
            if (leftOk && rightOk) return true;
            i += needle.Length;
        }
        return false;
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
