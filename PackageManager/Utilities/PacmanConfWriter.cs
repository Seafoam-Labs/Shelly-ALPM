using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace PackageManager.Utilities;

internal static partial class PacmanConfWriter
{
    [GeneratedRegex(@"^\s*\[(?<name>[^\]]+)\]\s*$")]
    private static partial Regex SectionRegex();

    [GeneratedRegex(@"^\s*#?\s*IgnorePkg\s*=\s*(?<value>.*)$")]
    private static partial Regex IgnorePkgRegex();

    internal static void AddIgnorePkg(PacmanConf conf, string packageName, string path = "/etc/pacman.conf")
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(packageName);

        if (conf.IgnorePkg.Contains(packageName, StringComparer.Ordinal)) return;

        conf.IgnorePkg.Add(packageName);
        RewriteIgnorePkg(path, conf);
    }

    internal static void RemoveIgnorePkg(PacmanConf conf, string packageName, string path = "/etc/pacman.conf")
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(packageName);

        if (!conf.IgnorePkg.Contains(packageName, StringComparer.Ordinal)) return;

        conf.IgnorePkg.RemoveAll(x => string.Equals(x, packageName, StringComparison.Ordinal));
        RewriteIgnorePkg(path, conf);
    }

    private static void RewriteIgnorePkg(string path, PacmanConf conf)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        ArgumentNullException.ThrowIfNull(path);
        
        var normalized = conf.IgnorePkg
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Select(x => x.Trim())
            .Distinct(StringComparer.Ordinal)
            .ToList();

        if (normalized.Count == 0) return;

        var ignorePkgLine = $"IgnorePkg = {string.Join(' ', normalized)}";

        var configLines = File.Exists(path)
            ? File.ReadAllLines(path).ToList()
            : throw new FileNotFoundException("pacman.conf not found.", path);

        var (optionsStart, optionsEnd) = FindOptionsSectionBounds(configLines);

        if (optionsStart == -1)
        {
            configLines.Add("[options]");
            configLines.Add(ignorePkgLine);
            WriteConfigToFile(path, configLines);
            return;
        }

        var ignorePkgIndices = FindIgnoreLineIndices(optionsStart, optionsEnd, configLines);

        if (ignorePkgIndices.Count == 0)
            configLines.Insert(optionsStart + 1, ignorePkgLine);
        else
            ReplaceIgnorePkgLine(ignorePkgIndices, configLines, ignorePkgLine);

        WriteConfigToFile(path, configLines);
    }

    private static (int, int) FindOptionsSectionBounds(List<string> configLines)
    {
        var optionsStart = -1;
        var optionsEnd = configLines.Count;

        for (var i = 0; i < configLines.Count; i++)
        {
            var match = SectionRegex().Match(configLines[i]);
            if (!match.Success)
                continue;

            var sectionName = match.Groups["name"].Value.Trim();
            if (!string.Equals(sectionName, "options", StringComparison.OrdinalIgnoreCase)) continue;

            optionsStart = i;

            for (var j = i + 1; j < configLines.Count; j++)
                if (SectionRegex().IsMatch(configLines[j]))
                {
                    optionsEnd = j;
                    break;
                }

            break;
        }

        return (optionsStart, optionsEnd);
    }

    private static void ReplaceIgnorePkgLine(List<int> ignorePkgIndices, List<string> configLines,
        string ignorePkgLine)
    {
        var firstIndex = ignorePkgIndices[0];

        configLines[firstIndex] = ignorePkgLine;

        for (var i = ignorePkgIndices.Count - 1; i >= 1; i--)
            configLines.RemoveAt(ignorePkgIndices[i]);
    }

    private static List<int> FindIgnoreLineIndices(int optionsStart, int optionsEnd, List<string> lines)
    {
        var ignoreLineIndexes = new List<int>();

        for (var i = optionsStart + 1; i < optionsEnd; i++)
            if (IgnorePkgRegex().IsMatch(lines[i]))
                ignoreLineIndexes.Add(i);

        return ignoreLineIndexes;
    }

    private static void WriteConfigToFile(string path, List<string> configLines)
    {
        File.WriteAllText(path, string.Join(Environment.NewLine, configLines) + Environment.NewLine,
            new UTF8Encoding(false));
    }
}