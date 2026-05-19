namespace Shelly_CLI.Commands.Utility;

public record CacheEntry(string Name, string Version, string Arch, string FullPath, long FileSize);

public static class CacheCleanHelper
{
    private static readonly string[] Suffixes =
        [".pkg.tar.zst", ".pkg.tar.xz", ".pkg.tar.gz", ".pkg.tar.bz2", ".pkg.tar"];

    public static CacheEntry? ParsePackageFilename(string filePath)
    {
        var fileName = Path.GetFileName(filePath);

        string? matchedSuffix = null;
        foreach (var suffix in Suffixes)
        {
            if (fileName.EndsWith(suffix, StringComparison.Ordinal))
            {
                matchedSuffix = suffix;
                break;
            }
        }

        if (matchedSuffix == null)
            return null;

        var baseName = fileName[..^matchedSuffix.Length];

        // Parse right-to-left: {pkgname}-{pkgver}-{pkgrel}-{arch}
        var parts = baseName.Split('-');
        if (parts.Length < 4)
            return null;

        var arch = parts[^1];
        var pkgrel = parts[^2];
        var pkgver = parts[^3];
        var pkgname = string.Join('-', parts[..^3]);

        if (string.IsNullOrEmpty(pkgname))
            return null;

        var version = $"{pkgver}-{pkgrel}";
        var fileSize = new FileInfo(filePath).Length;

        return new CacheEntry(pkgname, version, arch, filePath, fileSize);
    }

    public static string FormatSize(long bytes) => bytes switch
    {
        >= 1L << 30 => $"{bytes / (1024.0 * 1024.0 * 1024.0):F2} GiB",
        >= 1L << 20 => $"{bytes / (1024.0 * 1024.0):F2} MiB",
        >= 1L << 10 => $"{bytes / 1024.0:F2} KiB",
        _ => $"{bytes} B"
    };
}