using System;
using System.Collections.Generic;
using System.IO;

namespace PackageManager.Alpm.DistributionHooks;

public static class OsRelease
{
    public static string? PrettyName => GetPrettyName("/etc/os-release", "/usr/lib/os-release");

    public static string? GetPrettyName(params string[] candidatePaths)
    {
        try
        {
            var path = ResolvePath(candidatePaths);
            if (path is null)
                return null;

            return ParsePrettyName(File.ReadAllLines(path));
        }
        catch
        {
            return null;
        }
    }

    private static string? ResolvePath(IEnumerable<string> candidatePaths)
    {
        foreach (var candidate in candidatePaths)
        {
            if (File.Exists(candidate))
                return candidate;
        }

        return null;
    }

    public static string? ParsePrettyName(IEnumerable<string> lines)
    {
        string? name = null;
        foreach (var line in lines)
        {
            var trimmed = line.Trim();
            var separator = trimmed.IndexOf('=');
            if (separator <= 0)
                continue;

            var key = trimmed[..separator].Trim();
            var value = trimmed[(separator + 1)..].Trim().Trim('"', '\'');

            if (key.Equals("PRETTY_NAME", StringComparison.Ordinal))
                return value;

            if (key.Equals("NAME", StringComparison.Ordinal))
                name = value;
        }

        return name;
    }
}
