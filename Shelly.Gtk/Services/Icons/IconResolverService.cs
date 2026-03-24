using System.Collections.Concurrent;

namespace Shelly.Gtk.Services.Icons;

public class IconResolverService : IIconResolverService
{
    private static readonly string[] Repos = ["archlinux-arch-extra", "archlinux-arch-core", "archlinux-arch-multilib"];
    private static readonly string[] Sizes = ["128x128", "64x64", "48x48"];

    private static readonly string[] ThemeSizes = ["128x128", "96x96", "64x64", "48x48", "32x32", "scalable"];
    private static readonly string[] IconExtensions = ["*.png", "*.svg"];

    private const string IconPath = "/usr/share/swcatalog";
    private const string LegacyIconPath = "/usr/share/app-info";

    private readonly ConcurrentDictionary<string, string> _iconMap = [];

    //Commenting out extra methods and plan to add them back in after futher optimizations
    public string? GetIconPath(string packageName)
    {
        if (_iconMap.TryGetValue(packageName, out var iconPath))
        {
            return iconPath;
        }

        var swcatalogResult = GetSwcatalogIcon(packageName);
        _iconMap.TryAdd(packageName, swcatalogResult ?? "");
        return swcatalogResult ??
               null;
    }

    public void PreloadIcons(IEnumerable<string> packageNames)
    {
        foreach (var packageName in packageNames)
        {
            _ = GetIconPath(packageName);
        }
    }

    private string? GetSwcatalogIcon(string packageName)
    {
        var path = GetBasePath();
        if (string.IsNullOrEmpty(path))
            return null;

        return (from repo in Repos
                from size in Sizes
                select Path.Combine(path, "icons", repo, size)
                into dir
                where Directory.Exists(dir)
                select Directory.EnumerateFiles(dir, $"{packageName}_*.png").FirstOrDefault())
            .FirstOrDefault(x => x != null);
    }

    private string? GetIconFromTheme(string packageName)
    {
        var themeName = GetCurrentIconTheme();
        if (string.IsNullOrEmpty(themeName))
            return null;

        var iconName = GetDesktopIconName(packageName) ?? packageName;

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string[] themeBasePaths =
        [
            Path.Combine(home, ".local", "share", "icons"),
            "/usr/share/icons"
        ];

        foreach (var basePath in themeBasePaths)
        {
            var themePath = Path.Combine(basePath, themeName);
            if (!Directory.Exists(themePath))
                continue;

            foreach (var size in ThemeSizes)
            {
                var appsDir = Path.Combine(themePath, size, "apps");
                if (!Directory.Exists(appsDir))
                    continue;

                foreach (var ext in IconExtensions)
                {
                    var match = Directory.EnumerateFiles(appsDir, $"{iconName}{Path.GetExtension(ext)}")
                        .FirstOrDefault();
                    if (match != null)
                        return match;
                }
            }

            var altAppsDir = Path.Combine(themePath, "apps", "scalable");
            if (Directory.Exists(altAppsDir))
            {
                foreach (var ext in IconExtensions)
                {
                    var match = Directory.EnumerateFiles(altAppsDir, $"{iconName}{Path.GetExtension(ext)}")
                        .FirstOrDefault();
                    if (match != null)
                        return match;
                }
            }
        }

        return null;
    }

    private static string? GetPixmapIcon(string packageName)
    {
        const string pixmapsPath = "/usr/share/pixmaps";
        if (!Directory.Exists(pixmapsPath))
            return null;

        var iconName = GetDesktopIconName(packageName) ?? packageName;

        return IconExtensions
            .SelectMany(ext => Directory.EnumerateFiles(pixmapsPath, $"{iconName}{Path.GetExtension(ext)}"))
            .FirstOrDefault();
    }

    private static string? GetDesktopIconName(string packageName)
    {
        var desktopFile = $"/usr/share/applications/{packageName}.desktop";
        if (!File.Exists(desktopFile))
            return null;

        var iconLine = File.ReadLines(desktopFile)
            .FirstOrDefault(l => l.StartsWith("Icon=", StringComparison.OrdinalIgnoreCase));

        return iconLine?.Split('=', 2).ElementAtOrDefault(1)?.Trim();
    }

    private static string? GetCurrentIconTheme()
    {
        try
        {
            var configDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".config");

            var gtk3Settings = Path.Combine(configDir, "gtk-3.0", "settings.ini");
            if (File.Exists(gtk3Settings))
            {
                var themeLine = File.ReadLines(gtk3Settings)
                    .FirstOrDefault(l => l.StartsWith("gtk-icon-theme-name", StringComparison.OrdinalIgnoreCase));
                if (themeLine != null)
                {
                    var value = themeLine.Split('=', 2).ElementAtOrDefault(1)?.Trim();
                    if (!string.IsNullOrEmpty(value))
                        return value;
                }
            }

            var gtk4Settings = Path.Combine(configDir, "gtk-4.0", "settings.ini");
            if (File.Exists(gtk4Settings))
            {
                var themeLine = File.ReadLines(gtk4Settings)
                    .FirstOrDefault(l => l.StartsWith("gtk-icon-theme-name", StringComparison.OrdinalIgnoreCase));
                if (themeLine != null)
                {
                    var value = themeLine.Split('=', 2).ElementAtOrDefault(1)?.Trim();
                    if (!string.IsNullOrEmpty(value))
                        return value;
                }
            }

            return "hicolor";
        }
        catch
        {
            return "hicolor";
        }
    }

    private string? GetBasePath() => Directory.Exists("/usr/share/swcatalog") ? IconPath :
        Directory.Exists(LegacyIconPath) ? LegacyIconPath : null;
}