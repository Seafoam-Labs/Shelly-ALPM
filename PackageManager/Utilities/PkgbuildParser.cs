using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace PackageManager.Utilities;

/// <summary>
/// Parser for Arch Linux PKGBUILD files.
/// </summary>
public static class PkgbuildParser
{
    /// <summary>
    /// Parses a PKGBUILD file from a file path and returns its metadata.
    /// </summary>
    /// <param name="pkgbuildPath">The path to the PKGBUILD file.</param>
    /// <returns>A PkgbuildInfo object containing the parsed data.</returns>
    public static PkgbuildInfo Parse(string pkgbuildPath)
    {
        var pkgbuildContent = File.ReadAllText(pkgbuildPath);
        return ParseContent(pkgbuildContent);
    }

    /// <summary>
    /// Parses PKGBUILD content and returns its metadata.
    /// </summary>
    /// <param name="pkgbuildContent">The content of the PKGBUILD file.</param>
    /// <returns>A PkgbuildInfo object containing the parsed data.</returns>
    public static PkgbuildInfo ParseContent(string pkgbuildContent)
    {
        return new PkgbuildInfo
        {
            PkgName = ParseVariable(pkgbuildContent, "pkgname"),
            PkgVer = ParseVariable(pkgbuildContent, "pkgver"),
            PkgRel = ParseVariable(pkgbuildContent, "pkgrel"),
            Epoch = ParseVariable(pkgbuildContent, "epoch"),
            PkgDesc = ParseVariable(pkgbuildContent, "pkgdesc"),
            Url = ParseVariable(pkgbuildContent, "url"),
            License = ParseArray(pkgbuildContent, "license"),
            Arch = ParseArray(pkgbuildContent, "arch"),
            Depends = ParseArray(pkgbuildContent, "depends"),
            MakeDepends = ParseArray(pkgbuildContent, "makedepends"),
            CheckDepends = ParseArray(pkgbuildContent, "checkdepends"),
            OptDepends = ParseArray(pkgbuildContent, "optdepends"),
            Provides = ParseArray(pkgbuildContent, "provides"),
            Conflicts = ParseArray(pkgbuildContent, "conflicts"),
            Replaces = ParseArray(pkgbuildContent, "replaces"),
            Source = ParseArray(pkgbuildContent, "source"),
            Sha256Sums = ParseArray(pkgbuildContent, "sha256sums"),
            Sha512Sums = ParseArray(pkgbuildContent, "sha512sums"),
            Md5Sums = ParseArray(pkgbuildContent, "md5sums"),
        };
    }

    /// <summary>
    /// Parses a single variable from PKGBUILD content.
    /// </summary>
    private static string? ParseVariable(string content, string variableName)
    {
        // Match: varname="value" or varname='value' or varname=value
        var pattern = $@"^{variableName}=(?:""([^""]*)""|'([^']*)'|(\S+))";
        var match = Regex.Match(content, pattern, RegexOptions.Multiline);
        
        if (match.Success)
        {
            return match.Groups[1].Success ? match.Groups[1].Value :
                   match.Groups[2].Success ? match.Groups[2].Value :
                   match.Groups[3].Value;
        }
        
        return null;
    }

    /// <summary>
    /// Parses an array variable from PKGBUILD content.
    /// </summary>
    private static List<string> ParseArray(string content, string variableName)
    {
        var result = new List<string>();
        
        // Match: varname=(...)
        var pattern = $@"^{variableName}=\(([^)]*)\)";
        var match = Regex.Match(content, pattern, RegexOptions.Multiline | RegexOptions.Singleline);
        
        if (!match.Success)
            return result;

        var arrayContent = match.Groups[1].Value;
        
        // Strip comments (from # to end of line), respecting quoted strings
        var lines = arrayContent.Split('\n');
        var cleanedContent = string.Join("\n", lines.Select(line =>
        {
            var inSingleQ = false;
            var inDoubleQ = false;
            for (var ci = 0; ci < line.Length; ci++)
            {
                var c = line[ci];
                if (c == '"' && !inSingleQ) inDoubleQ = !inDoubleQ;
                else if (c == '\'' && !inDoubleQ) inSingleQ = !inSingleQ;
                else if (c == '#' && !inSingleQ && !inDoubleQ)
                    return line.Substring(0, ci);
            }
            return line;
        }));
        
        // Extract quoted strings and unquoted words
        // Matches: "string" or 'string' or unquoted_word
        var itemPattern = @"""([^""]*)""|'([^']*)'|(\S+)";
        var itemMatches = Regex.Matches(cleanedContent, itemPattern);
        
        foreach (Match itemMatch in itemMatches)
        {
            var value = itemMatch.Groups[1].Success ? itemMatch.Groups[1].Value :
                        itemMatch.Groups[2].Success ? itemMatch.Groups[2].Value :
                        itemMatch.Groups[3].Value;
            
            result.Add(value);
        }
        
        return result;
    }
}

/// <summary>
/// Represents parsed PKGBUILD metadata.
/// </summary>
public class PkgbuildInfo
{
    public string? PkgName { get; set; }
    public string? PkgVer { get; set; }
    public string? PkgRel { get; set; }
    public string? Epoch { get; set; }
    public string? PkgDesc { get; set; }
    public string? Url { get; set; }
    public List<string> License { get; set; } = new();
    public List<string> Arch { get; set; } = new();
    public List<string> Depends { get; set; } = new();
    public List<string> MakeDepends { get; set; } = new();
    public List<string> CheckDepends { get; set; } = new();
    public List<string> OptDepends { get; set; } = new();
    public List<string> Provides { get; set; } = new();
    public List<string> Conflicts { get; set; } = new();
    public List<string> Replaces { get; set; } = new();
    public List<string> Source { get; set; } = new();
    public List<string> Sha256Sums { get; set; } = new();
    public List<string> Sha512Sums { get; set; } = new();
    public List<string> Md5Sums { get; set; } = new();

    /// <summary>
    /// Gets all build-time dependencies (depends + makedepends + checkdepends).
    /// </summary>
    public List<string> GetAllBuildDependencies()
    {
        return Depends.Concat(MakeDepends).Concat(CheckDepends).Distinct().ToList();
    }

    /// <summary>
    /// Gets the full version string (epoch:pkgver-pkgrel).
    /// </summary>
    public string GetFullVersion()
    {
        var version = PkgVer ?? "0";
        if (!string.IsNullOrEmpty(PkgRel))
            version += $"-{PkgRel}";
        if (!string.IsNullOrEmpty(Epoch))
            version = $"{Epoch}:{version}";
        return version;
    }
}
