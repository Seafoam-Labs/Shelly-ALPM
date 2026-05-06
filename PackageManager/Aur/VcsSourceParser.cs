using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using PackageManager.Aur.Models;

namespace PackageManager.Aur;

public static class VcsSourceParser
{
    public static VcsSourceEntry? ParseSource(string sourceEntry)
        => ParseSource(sourceEntry, null);

    public static VcsSourceEntry? ParseSource(string sourceEntry, IReadOnlyDictionary<string, string>? vars)
    {
        if (string.IsNullOrWhiteSpace(sourceEntry))
            return null;

        var entry = sourceEntry.Trim();

        var colonColonIndex = entry.IndexOf("::", StringComparison.Ordinal);
        if (colonColonIndex >= 0)
        {
            entry = entry[(colonColonIndex + 2)..];
        }

        entry = ExpandVariables(entry, vars);

        var protocols = new List<string>();
        var url = entry;

        var schemeEnd = entry.IndexOf("://", StringComparison.Ordinal);
        if (schemeEnd < 0)
            return null;

        var schemePart = entry[..schemeEnd];
        url = entry;

        protocols.AddRange(schemePart.Split('+', StringSplitOptions.RemoveEmptyEntries));

        if (!protocols.Contains("git", StringComparer.OrdinalIgnoreCase))
            return null;

        if (url.StartsWith("git+", StringComparison.OrdinalIgnoreCase))
        {
            url = url[4..];
        }

        string? branch = null;
        var fragmentIndex = url.IndexOf('#');
        if (fragmentIndex >= 0)
        {
            var fragment = url[(fragmentIndex + 1)..];
            url = url[..fragmentIndex];

            if (fragment.StartsWith("commit=", StringComparison.OrdinalIgnoreCase) ||
                fragment.StartsWith("tag=", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            if (fragment.StartsWith("branch=", StringComparison.OrdinalIgnoreCase))
            {
                var raw = fragment.Split('=', 2)[1];
                raw = ExpandVariables(raw, vars);

                if (string.IsNullOrWhiteSpace(raw) ||
                    raw.Contains("${", StringComparison.Ordinal) ||
                    raw.Contains("$(", StringComparison.Ordinal) ||
                    (raw.StartsWith('$') && raw.Length > 1))
                {
                    return null;
                }

                branch = raw;
            }
        }

        var queryIndex = url.IndexOf('?');
        if (queryIndex >= 0)
        {
            url = url[..queryIndex];
        }

        if (url.Contains('$'))
            return null;

        return new VcsSourceEntry
        {
            Url = url,
            Branch = branch ?? string.Empty,
            Protocols = protocols.Where(p => !p.Equals("git", StringComparison.OrdinalIgnoreCase)).ToList(),
            CommitSha = string.Empty
        };
    }

    public static List<VcsSourceEntry> ParseSources(IEnumerable<string> sources)
        => ParseSources(sources, null);

    public static List<VcsSourceEntry> ParseSources(IEnumerable<string> sources, IReadOnlyDictionary<string, string>? vars)
    {
        var results = new List<VcsSourceEntry>();
        foreach (var source in sources)
        {
            var parsed = ParseSource(source, vars);
            if (parsed != null)
                results.Add(parsed);
        }

        return results;
    }

    private static string ExpandVariables(string input, IReadOnlyDictionary<string, string>? vars)
    {
        if (vars == null || vars.Count == 0 || string.IsNullOrEmpty(input) || !input.Contains('$'))
            return input;

        var current = input;
        for (var pass = 0; pass < 10; pass++)
        {
            var replaced = Regex.Replace(current, @"\$\{(\w+)\}|\$(\w+)", m =>
            {
                var name = m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value;
                return vars.TryGetValue(name, out var v) ? v : m.Value;
            });

            if (replaced == current)
                break;
            current = replaced;
        }

        return current;
    }
}
