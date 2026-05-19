using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace PackageManager.Local;

public static partial class XdgIntegration
{
    private const string DesktopDir = "/usr/share/applications";

    [GeneratedRegex(@"(\d+)x?\d*")]
    private static partial Regex ImageSizeRegex();

    public static async Task CreateDesktopEntry(
        string appName,
        string desktopFileName,
        string executablePath,
        string? comment = null,
        string icon = "application-x-executable",
        bool terminal = false,
        string categories = "Utility;")
    {
        var desktopFilePath = Path.Combine(DesktopDir, $"{desktopFileName}.desktop");

        var content = new StringBuilder();
        content.AppendLine("[Desktop Entry]");
        content.AppendLine("Version=1.0");
        content.AppendLine("Type=Application");
        content.AppendLine($"Name={appName}");
        content.AppendLine($"Comment={comment ?? $"{appName} application"}");
        content.AppendLine($"Exec={executablePath}");
        content.AppendLine($"Icon={icon}");
        content.AppendLine($"Terminal={terminal.ToString().ToLower()}");
        content.AppendLine($"Categories={categories}");
        content.AppendLine("StartupNotify=true");

        Directory.CreateDirectory(DesktopDir);
        await File.WriteAllTextAsync(desktopFilePath, content.ToString());
        await SetFilePermissions(desktopFilePath, "644");
        await UpdateDesktopDatabase(DesktopDir);
    }

    public static bool RemoveDesktopEntry(string binName)
    {
        var desktopFilePath = Path.Combine(DesktopDir, $"{Path.GetFileNameWithoutExtension(binName)}.desktop");

        if (!File.Exists(desktopFilePath)) return false;

        File.Delete(desktopFilePath);
        return true;
    }

    private static async Task SetFilePermissions(string filePath, string permissions)
    {
        var process = Process.Start(new ProcessStartInfo
        {
            FileName = "chmod",
            Arguments = $"{permissions} \"{filePath}\"",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        });
        if (process == null)
            throw new InvalidOperationException("Unable to start chmod process.");
        await process.WaitForExitAsync();
    }

    private static async Task UpdateDesktopDatabase(string desktopDir)
    {
        var process = Process.Start(new ProcessStartInfo
        {
            FileName = "update-desktop-database",
            Arguments = $"\"{desktopDir}\"",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        });
        if (process == null)
            throw new InvalidOperationException("Unable to start update-desktop-database process.");
        await process.WaitForExitAsync();
    }

    public static async Task<string> InstallIcon(string iconPath, string appName)
    {
        var iconName = appName.ToLower();
        var extension = Path.GetExtension(iconPath);
        string destDir;
        if (extension == ".svg")
        {
            destDir = "/usr/share/icons/hicolor/scalable/apps";
        }
        else
        {
            var sizeMatch = ImageSizeRegex().Match(Path.GetFileName(iconPath));
            var size = sizeMatch.Success && int.TryParse(sizeMatch.Groups[1].Value, out var s)
                ? s
                : 256;
            destDir = $"/usr/share/icons/hicolor/{size}x{size}/apps";
        }

        Directory.CreateDirectory(destDir);
        var destPath = Path.Combine(destDir, $"{iconName}{extension}");

        File.Copy(iconPath, destPath, true);

        await UpdateIconCache();

        return iconName;
    }

    public static bool RemoveIcon(string desktopBin, FileInfo icon)
    {
        var extension = icon.Extension.ToLowerInvariant();
        string destDir;
        if (extension == ".svg")
        {
            destDir = "/usr/share/icons/hicolor/scalable/apps";
        }
        else
        {
            var sizeMatch = ImageSizeRegex().Match(icon.Name);
            var size = sizeMatch.Success && int.TryParse(sizeMatch.Groups[1].Value, out var s) ? s : 256;
            destDir = $"/usr/share/icons/hicolor/{size}x{size}/apps";
        }

        var destPath = Path.Combine(destDir, $"{desktopBin}{extension}");
        if (!File.Exists(destPath)) return false;

        File.Delete(destPath);
        return true;
    }

    private static async Task UpdateIconCache()
    {
        var process = Process.Start(new ProcessStartInfo
        {
            FileName = "gtk-update-icon-cache",
            Arguments = "-f -t /usr/share/icons/hicolor",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        });
        if (process == null)
            throw new InvalidOperationException("Unable to start gtk-update-icon-cache process.");

        await process.WaitForExitAsync();
    }
}