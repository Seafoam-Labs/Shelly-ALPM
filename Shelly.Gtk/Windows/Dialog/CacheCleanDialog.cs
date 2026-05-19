using Gtk;
using static Shelly.GTK.Resources.Translations;

namespace Shelly.Gtk.Windows.Dialog;

public static class CacheCleanDialog
{
    private static readonly string[] PackageSuffixes =
        [".pkg.tar.zst", ".pkg.tar.xz", ".pkg.tar.gz", ".pkg.tar.bz2", ".pkg.tar"];

    public static Box BuildContent(
        string cacheDir,
        Action<int, bool> onClean,
        Action onCancel)
    {
        var container = Box.New(Orientation.Vertical, 10);
        container.SetMarginBottom(10);
        container.SetMarginEnd(10);
        container.SetMarginStart(10);
        container.SetMarginTop(10);

        var titleLabel = Label.New(T("Cache Cleaner"));
        titleLabel.AddCssClass("title-2");
        titleLabel.Xalign = 0;
        container.Append(titleLabel);

        var entries = ScanCache(cacheDir);
        var totalCacheSize = entries.Sum(e => e.FileSize);

        var infoLabel =
            Label.New(
                T("Cache directory: {0}\nTotal cached files: {1} ({2})", cacheDir, entries.Count, FormatSize(totalCacheSize)));
        infoLabel.Xalign = 0;
        infoLabel.Wrap = true;
        container.Append(infoLabel);

        var controlsBox = Box.New(Orientation.Horizontal, 10);
        controlsBox.SetValign(Align.Center);

        var keepLabel = Label.New(T("Keep versions:"));
        controlsBox.Append(keepLabel);

        var keepSpin = SpinButton.NewWithRange(0, 10, 1);
        keepSpin.Value = 3;
        controlsBox.Append(keepSpin);

        var uninstalledCheck = CheckButton.NewWithLabel(T("Uninstalled only"));
        controlsBox.Append(uninstalledCheck);

        container.Append(controlsBox);

        var candidateListBox = ListBox.New();
        candidateListBox.SetSelectionMode(SelectionMode.None);
        candidateListBox.AddCssClass("rich-list");

        var scrolledWindow = ScrolledWindow.New();
        scrolledWindow.SetVexpand(true);
        scrolledWindow.SetSizeRequest(-1, 250);
        scrolledWindow.HscrollbarPolicy = PolicyType.Never;
        scrolledWindow.SetChild(candidateListBox);
        container.Append(scrolledWindow);

        var summaryLabel = Label.New("");
        summaryLabel.Xalign = 0;
        summaryLabel.AddCssClass("dim-label");
        container.Append(summaryLabel);

        RefreshCandidates(entries, (int)keepSpin.Value, uninstalledCheck.Active, candidateListBox, summaryLabel);

        keepSpin.OnValueChanged += (_, _) =>
        {
            RefreshCandidates(entries, (int)keepSpin.Value, uninstalledCheck.Active, candidateListBox,
                summaryLabel);
        };

        uninstalledCheck.OnToggled += (_, _) =>
        {
            RefreshCandidates(entries, (int)keepSpin.Value, uninstalledCheck.Active, candidateListBox,
                summaryLabel);
        };

        var buttonBox = Box.New(Orientation.Horizontal, 10);
        buttonBox.SetHalign(Align.End);

        var cancelButton = Button.NewWithLabel(T("Cancel"));
        cancelButton.OnClicked += (_, _) => onCancel();
        buttonBox.Append(cancelButton);

        var cleanButton = Button.NewWithLabel(T("Clean"));
        cleanButton.AddCssClass("destructive-action");
        cleanButton.OnClicked += (_, _) => onClean((int)keepSpin.Value, uninstalledCheck.Active);
        buttonBox.Append(cleanButton);

        container.Append(buttonBox);

        return container;
    }

    private static void RefreshCandidates(
        List<CacheFileEntry> allEntries,
        int keep,
        bool uninstalledOnly,
        ListBox listBox,
        Label summaryLabel)
    {
        while (listBox.GetFirstChild() is { } child)
            listBox.Remove(child);

        var candidates = ComputeCandidates(allEntries, keep, uninstalledOnly);

        if (candidates.Count == 0)
        {
            summaryLabel.SetText(T("No candidates for removal."));
            return;
        }

        foreach (var entry in candidates)
        {
            var row = ListBoxRow.New();
            var hbox = Box.New(Orientation.Horizontal, 10);
            hbox.MarginStart = 10;
            hbox.MarginEnd = 10;
            hbox.MarginTop = 5;
            hbox.MarginBottom = 5;

            var nameLabel = Label.New($"{entry.Name} {entry.Version} ({entry.Arch})");
            nameLabel.Xalign = 0;
            nameLabel.Hexpand = true;
            nameLabel.Ellipsize = Pango.EllipsizeMode.End;
            hbox.Append(nameLabel);

            var sizeLabel = Label.New(FormatSize(entry.FileSize));
            sizeLabel.AddCssClass("dim-label");
            hbox.Append(sizeLabel);

            row.SetChild(hbox);
            listBox.Append(row);
        }

        var totalSize = candidates.Sum(c => c.FileSize);
        summaryLabel.SetText(T("{0} files, {1} would be freed", candidates.Count, FormatSize(totalSize)));
    }

    private static List<CacheFileEntry> ComputeCandidates(
        List<CacheFileEntry> allEntries,
        int keep,
        bool uninstalledOnly)
    {
        var grouped = allEntries.GroupBy(e => e.Name).ToDictionary(g => g.Key, g => g.ToList());
        var candidates = new List<CacheFileEntry>();

        foreach (var (_, pkgEntries) in grouped)
        {
            pkgEntries.Sort((a, b) => string.Compare(a.Version, b.Version, StringComparison.Ordinal));
            candidates.AddRange(pkgEntries.Take(Math.Max(0, pkgEntries.Count - keep)));
        }

        if (!uninstalledOnly) return candidates;
        var installedNames = GetInstalledPackageNames();
        candidates = candidates.Where(c => !installedNames.Contains(c.Name)).ToList();

        return candidates;
    }

    private static HashSet<string> GetInstalledPackageNames()
    {
        var localDbPath = "/var/lib/pacman/local";
        if (!Directory.Exists(localDbPath))
            return [];

        return Directory.GetDirectories(localDbPath)
            .Select(Path.GetFileName)
            .Where(name => name != null && name != "ALPM_DB_VERSION")
            .Select(name => ExtractPackageNameFromDir(name!))
            .Where(name => !string.IsNullOrEmpty(name))
            .ToHashSet();
    }

    private static string ExtractPackageNameFromDir(string dirName)
    {
        var parts = dirName.Split('-');
        if (parts.Length < 3) return dirName;

        var nameEndIndex = parts.Length - 2;
        for (var i = parts.Length - 1; i >= 1; i--)
        {
            if (parts[i].Length > 0 && char.IsDigit(parts[i][0]))
            {
                nameEndIndex = i;
                break;
            }
        }

        return string.Join("-", parts.Take(nameEndIndex));
    }

    private static List<CacheFileEntry> ScanCache(string cacheDir)
    {
        if (!Directory.Exists(cacheDir))
            return [];

        return Directory.EnumerateFiles(cacheDir)
            .Select(ParsePackageFilename)
            .Where(e => e != null)
            .Cast<CacheFileEntry>()
            .ToList();
    }

    private static CacheFileEntry? ParsePackageFilename(string filePath)
    {
        var fileName = Path.GetFileName(filePath);
        string? baseName = null;

        foreach (var suffix in PackageSuffixes)
        {
            if (fileName.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
            {
                baseName = fileName[..^suffix.Length];
                break;
            }
        }

        if (baseName == null)
            return null;

        var parts = baseName.Split('-');
        if (parts.Length < 4)
            return null;

        var arch = parts[^1];
        var pkgrel = parts[^2];
        var pkgver = parts[^3];
        var name = string.Join("-", parts[..^3]);

        if (string.IsNullOrEmpty(name))
            return null;

        var version = $"{pkgver}-{pkgrel}";
        var fileSize = new FileInfo(filePath).Length;

        return new CacheFileEntry(name, version, arch, fileSize);
    }

    private static string FormatSize(long bytes) => bytes switch
    {
        >= 1L << 30 => $"{bytes / (1024.0 * 1024.0 * 1024.0):F2} GiB",
        >= 1L << 20 => $"{bytes / (1024.0 * 1024.0):F2} MiB",
        >= 1L << 10 => $"{bytes / 1024.0:F2} KiB",
        _ => $"{bytes} B"
    };

    private record CacheFileEntry(string Name, string Version, string Arch, long FileSize);
}