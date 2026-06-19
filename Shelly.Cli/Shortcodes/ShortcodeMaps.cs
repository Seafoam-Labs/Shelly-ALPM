namespace Shelly.Cli.Shortcodes;

internal static class ShortcodeMaps
{
    public static readonly IReadOnlyDictionary<char, string> Types = new Dictionary<char, string>
    {
        ['I'] = "appimage",
        ['A'] = "aur",
        ['C'] = "config",
        ['F'] = "flatpak",
        ['K'] = "keyring",
        ['S'] = "",
        ['U'] = ""
    };

    public static readonly IReadOnlyDictionary<(char, char), string> Actions = new Dictionary<(char, char), string>
    {
        [('S', 'I')] = "install",
        [('S', 'R')] = "remove",
        [('S', 'Q')] = "query",
        [('S', 'M')] = "mark",
        [('S', 'Y')] = "sync",
        [('S', 'P')] = "purify",
        [('S', 'N')] = "news",
        [('S', 'D')] = "downgrade",
        [('S', 'G')] = "ignore",
        [('S', 'U')] = "upgrade",
        [('S', 'T')] = "update",

        [('U', 'C')] = "cache-clean",
        [('U', 'K')] = "check-updates",
        [('U', 'E')] = "export",
        [('U', 'F')] = "fix-permissions",

        [('A', 'I')] = "install",
        [('A', 'V')] = "install-version",
        [('A', 'R')] = "remove",
        [('A', 'T')] = "update",
        [('A', 'U')] = "upgrade",
        [('A', 'L')] = "list",
        [('A', 'P')] = "list-updates",
        [('A', 'S')] = "search",
        [('A', 'B')] = "search-pkgbuild",

        [('F', 'I')] = "install",
        [('F', 'T')] = "update",
        [('F', 'U')] = "upgrade",
        [('F', 'L')] = "list",
        [('F', 'P')] = "list-updates",
        [('F', 'R')] = "uninstall",
        [('F', 'N')] = "running",
        [('F', 'X')] = "run",
        [('F', 'K')] = "kill",
        [('F', 'S')] = "search",
        [('F', 'H')] = "repair",
        [('F', 'M')] = "list-remotes",
        [('F', 'A')] = "add-remotes",
        [('F', 'D')] = "remove-remotes",
        [('F', 'E')] = "install-ref-file",
        [('F', 'B')] = "install-bundle",
        [('F', 'Y')] = "sync-remote-appstream",
        [('F', 'G')] = "get-remote-appstream",
        [('F', 'O')] = "app-remote-info",

        [('I', 'I')] = "install",
        [('I', 'R')] = "remove",
        [('I', 'L')] = "list",
        [('I', 'U')] = "upgrade",
        [('I', 'P')] = "list-updates",
        [('I', 'S')] = "sync-meta",
        [('I', 'C')] = "configure-updates",
        [('I', 'M')] = "migrate-manager",

        [('C', 'G')] = "get",
        [('C', 'S')] = "set",
        [('C', 'L')] = "list",
        [('C', 'R')] = "reset",
        [('C', 'P')] = "parallel"
    };

    public static readonly IReadOnlyDictionary<(char, char), IReadOnlySet<char>> Modifiers =
        new Dictionary<(char, char), IReadOnlySet<char>>
        {
            [('S', 'I')] = new HashSet<char> { 'b', 'm', 'd', 'u' },
            [('S', 'R')] = new HashSet<char> { 'c', 'o', 'i', 'r', 'l' },
            [('S', 'Q')] = new HashSet<char> { 'r', 'a', 'i', 'l', 't', 'p', 'w', 'd' },
            [('S', 'M')] = new HashSet<char> { 'e', 'd' },
            [('S', 'Y')] = new HashSet<char> { 'f' },
            [('S', 'P')] = new HashSet<char> { 'd', 'o' },
            [('S', 'N')] = new HashSet<char> { 'a' },
            [('S', 'D')] = new HashSet<char> { 'o', 'i', 'l', 't' },
            [('S', 'G')] = new HashSet<char> { 'l', 'a', 'r', 'c' },
            [('S', 'U')] = new HashSet<char>(),
            [('S', 'T')] = new HashSet<char>(),

            [('U', 'C')] = new HashSet<char> { 'k', 'i', 'd', 'c', 't' },
            [('U', 'K')] = new HashSet<char> { 'a', 'l', 'c' },
            [('U', 'E')] = new HashSet<char> { 'a', 'o' },
            [('U', 'F')] = new HashSet<char>(),

            [('A', 'I')] = new HashSet<char> { 'o', 'm', 'c' },
            [('A', 'V')] = new HashSet<char>(),
            [('A', 'R')] = new HashSet<char> { 'c', 'o', 'i' },
            [('A', 'T')] = new HashSet<char>(),
            [('A', 'U')] = new HashSet<char>(),
            [('A', 'L')] = new HashSet<char>(),
            [('A', 'P')] = new HashSet<char>(),
            [('A', 'S')] = new HashSet<char>(),
            [('A', 'B')] = new HashSet<char>(),

            [('F', 'I')] = new HashSet<char> { 'r', 'b' },
            [('F', 'T')] = new HashSet<char>(),
            [('F', 'U')] = new HashSet<char>(),
            [('F', 'L')] = new HashSet<char>(),
            [('F', 'P')] = new HashSet<char>(),
            [('F', 'R')] = new HashSet<char> { 'r', 'c' },
            [('F', 'N')] = new HashSet<char>(),
            [('F', 'X')] = new HashSet<char>(),
            [('F', 'K')] = new HashSet<char>(),
            [('F', 'S')] = new HashSet<char> { 'l', 'p' },
            [('F', 'H')] = new HashSet<char>(),
            [('F', 'M')] = new HashSet<char>(),
            [('F', 'A')] = new HashSet<char> { 'u', 's', 'g' },
            [('F', 'D')] = new HashSet<char> { 's' },
            [('F', 'E')] = new HashSet<char> { 's' },
            [('F', 'B')] = new HashSet<char> { 's' },
            [('F', 'Y')] = new HashSet<char>(),
            [('F', 'G')] = new HashSet<char>(),
            [('F', 'O')] = new HashSet<char>(),

            [('I', 'I')] = new HashSet<char>(),
            [('I', 'R')] = new HashSet<char> { 'c' },
            [('I', 'L')] = new HashSet<char>(),
            [('I', 'U')] = new HashSet<char>(),
            [('I', 'P')] = new HashSet<char>(),
            [('I', 'S')] = new HashSet<char>(),
            [('I', 'C')] = new HashSet<char> { 'p' },
            [('I', 'M')] = new HashSet<char>(),

            [('C', 'G')] = new HashSet<char>(),
            [('C', 'S')] = new HashSet<char>(),
            [('C', 'L')] = new HashSet<char>(),
            [('C', 'R')] = new HashSet<char>(),
            [('C', 'P')] = new HashSet<char>()
        };

    public static readonly IReadOnlyDictionary<char, string> KeyringActions = new Dictionary<char, string>
    {
        ['I'] = "init",
        ['L'] = "list",
        ['R'] = "refresh",
        ['S'] = "lsign",
        ['P'] = "populate",
        ['V'] = "recv"
    };
}
