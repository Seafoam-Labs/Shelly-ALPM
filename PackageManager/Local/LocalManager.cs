using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Formats.Tar;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using PackageManager.Zstd;

namespace PackageManager.Local;

public sealed partial class LocalManager
{
    public const string InstallDir = "/opt/shelly";
    private const string DesktopDir = "/usr/share/applications";

    public event EventHandler<LocalManagerMessageEventArgs>? Message;

    [GeneratedRegex(@"(\d+)x?\d*")]
    private static partial Regex ImageSizeRegex();

    public async Task<bool> InstallBinariesPackage(string filePath)
    {
        OnInfo($"Installing local binary package: {filePath}");

        try
        {
            var extension = Path.GetExtension(filePath);

            var packageName = Path.GetFileName(filePath)
                .Replace(".pkg.tar" + extension, "")
                .Replace(".tar" + extension, "");
            var installDir = Path.Combine(InstallDir, packageName);
            Directory.CreateDirectory(installDir);

            var installedBinaries = new List<string>();
            var foundIcons = new SortedDictionary<string, string>();

            await using var fileStream = File.OpenRead(filePath);
            await using Stream decompressedStream = extension switch
            {
                ".gz" => new GZipStream(fileStream, CompressionMode.Decompress),
                ".zst" => new ZstdDecompressStream(fileStream),
                _ => throw new NotSupportedException($"Unsupported compression: {extension}")
            };

            await using (var tarReader = new TarReader(decompressedStream))
            {
                while (await tarReader.GetNextEntryAsync() is { } entry)
                {
                    var destPath = Path.Combine(installDir, entry.Name);

                    switch (entry.EntryType)
                    {
                        case TarEntryType.Directory:
                        {
                            Directory.CreateDirectory(destPath);
                            break;
                        }
                        case TarEntryType.RegularFile:
                        {
                            Directory.CreateDirectory(Path.GetDirectoryName(destPath)!);
                            await entry.ExtractToFileAsync(destPath, true);

                            var ext = Path.GetExtension(destPath).ToLowerInvariant();
                            if (IsIcon(ext))
                            {
                                var iconFileName = Path.GetFileNameWithoutExtension(destPath).ToLowerInvariant();
                                foundIcons[iconFileName] = destPath;
                            }

                            await using var fs = File.OpenRead(destPath);
                            if (string.IsNullOrWhiteSpace(Path.GetExtension(destPath)) && await IsElfBinary(fs))
                            {
                                var binaryName = Path.GetFileName(destPath);
                                var linkPath = Path.Combine("/usr/bin", binaryName);
                                if (File.Exists(linkPath)) File.Delete(linkPath);

                                File.CreateSymbolicLink(linkPath, destPath);
                                installedBinaries.Add(binaryName);

                                OnInfo($"Installed binary symlink: {linkPath} -> {destPath}");
                            }

                            break;
                        }
                    }
                }
            }

            OnInfo($"Extracted to {installDir}");

            foreach (var binaryName in installedBinaries)
            {
                var iconName = "application-x-executable";

                if (!CleanInvalidNames(packageName)
                        .Contains(binaryName, StringComparison.OrdinalIgnoreCase))
                    continue;

                if (foundIcons.Count > 0)
                {
                    var icon = foundIcons.First();
                    var installedIconName = await InstallIcon(icon.Value, binaryName);

                    if (!string.IsNullOrWhiteSpace(installedIconName)) iconName = installedIconName;
                }
                else
                {
                    OnWarning($"No icon found for {binaryName}, using default");
                }

                OnInfo("Creating desktop entry...");
                CreateDesktopEntry(
                    binaryName,
                    binaryName,
                    $"{binaryName} - Installed from {packageName}",
                    iconName);
            }

            if (installedBinaries.Count == 0) OnWarning("No executable ELF binaries were found in the archive.");

            OnSuccess("Successfully installed binary package!");
            return true;
        }
        catch (Exception ex)
        {
            OnError($"Failed to install binary package: {ex.Message}");
            return false;
        }
    }

    public static async Task<bool> IsArchPackage(string filePath)
    {
        await using var fileStream = File.OpenRead(filePath);
        switch (Path.GetExtension(filePath))
        {
            case ".zst":
            {
                await using var zStdStream = new ZstdDecompressStream(fileStream);
                await using var zstTarReader = new TarReader(zStdStream);
                while (await zstTarReader.GetNextEntryAsync() is { } entry)
                    if (entry.Name.Contains("PKGINFO", StringComparison.OrdinalIgnoreCase))
                        return true;

                break;
            }
            case ".gz":
            {
                await using var gzStream = new GZipStream(fileStream, CompressionMode.Decompress);
                await using var gzTarReader = new TarReader(gzStream);
                while (await gzTarReader.GetNextEntryAsync() is { } entry)
                    if (entry.Name.Contains("PKGINFO", StringComparison.OrdinalIgnoreCase))
                        return true;

                break;
            }
        }

        return false;
    }

    public static async Task<bool> IsBinariesPackage(string filePath)
    {
        await using var fileStream = File.OpenRead(filePath);
        await using Stream decompressedStream = Path.GetExtension(filePath) switch
        {
            ".gz" => new GZipStream(fileStream, CompressionMode.Decompress),
            ".zst" => new ZstdDecompressStream(fileStream),
            _ => throw new NotSupportedException("Unsupported file extension")
        };
        await using var tarReader = new TarReader(decompressedStream);
        while (await tarReader.GetNextEntryAsync() is { } entry)
        {
            if (entry.EntryType != TarEntryType.RegularFile || entry.DataStream is null) continue;
            if (await IsElfBinary(entry.DataStream)) return true;
        }

        return false;
    }

    public static List<LocalPackageDto> GetInstalledBinaryPackages()
    {
        var dirs = ListDirectories(InstallDir);
        return dirs
            .Select(dir =>
            {
                var dirInfo = new DirectoryInfo(dir);
                var size = dirInfo
                    .EnumerateFiles("*", SearchOption.AllDirectories)
                    .Sum(f => f.Length);

                return new LocalPackageDto(dir, size);
            })
            .ToList();
    }

    private static List<string> GetValidPackages(List<string> packages)
    {
        return packages
            .Where(p => p.StartsWith(InstallDir, StringComparison.OrdinalIgnoreCase))
            .Where(p => !p.TrimEnd('/').Equals(InstallDir, StringComparison.OrdinalIgnoreCase))
            .ToList();
    }

    public async Task<bool> RemoveBinaryPackages(List<string> packages)
    {
        var pkgs = GetValidPackages(packages);
        if (pkgs.Count == 0)
        {
            OnError($"No valid packages specified for removal: {packages}");
            return false;
        }

        OnInfo($"Removing package(s): {string.Join(", ", pkgs)}");
        try
        {
            var dirs = pkgs
                .Select(path => new DirectoryInfo(path))
                .Where(dir => dir.FullName.StartsWith(InstallDir + '/') && dir.Exists);

            foreach (var dir in dirs)
            {
                var pkgInfos = dir.EnumerateFiles("*", SearchOption.AllDirectories).ToList();
                List<FileInfo> pkgBins = [];

                foreach (var info in pkgInfos)
                {
                    await using var fs = File.OpenRead(info.FullName);
                    if (await IsElfBinary(fs)) pkgBins.Add(info);
                }

                List<string> desktopBins = [];

                foreach (var pkgBin in pkgBins)
                {
                    var usrBin = new FileInfo(Path.Combine("/usr/bin", pkgBin.Name));
                    var canDelete = pkgBin.FullName.Equals(usrBin.LinkTarget);
                    if (!canDelete) continue;

                    OnInfo($"Removing {pkgBin.Name} from {usrBin.FullName}");
                    File.Delete(usrBin.FullName);

                    if (!CleanInvalidNames(dir.Name)
                            .Contains(pkgBin.Name, StringComparison.InvariantCultureIgnoreCase))
                        continue;

                    var desktopFilePath =
                        Path.Combine(DesktopDir, $"{Path.GetFileNameWithoutExtension(pkgBin.Name)}.desktop");

                    if (File.Exists(desktopFilePath))
                    {
                        OnInfo($"Removing {desktopFilePath}");
                        File.Delete(desktopFilePath);
                    }

                    desktopBins.Add(pkgBin.Name);
                }

                var iconInfos = pkgInfos
                    .Where(info => IsIcon(info.Extension.ToLowerInvariant()))
                    .OrderBy(info => info.Name)
                    .ToList();

                foreach (var desktopBin in desktopBins)
                foreach (var icon in iconInfos)
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
                        var size = sizeMatch.Success && int.TryParse(sizeMatch.Groups[1].Value, out var s)
                            ? s
                            : 256;
                        destDir = $"/usr/share/icons/hicolor/{size}x{size}/apps";
                    }

                    var destPath = Path.Combine(destDir, $"{desktopBin}{extension}");
                    if (!File.Exists(destPath)) continue;

                    OnInfo($"Removing icon {destPath}");
                    File.Delete(destPath);
                }

                OnInfo($"Removing package directory {dir.FullName}");
                dir.Delete(true);
            }

            OnSuccess("Package(s) removed successfully!");
            return true;
        }
        catch (Exception ex)
        {
            OnError($"Failed to remove binary package(s): {ex.Message}");
            return false;
        }
    }

    private static bool IsIcon(string i)
    {
        return i is ".png" or ".svg";
    }

    private static async Task<bool> IsElfBinary(Stream stream)
    {
        if (stream.CanSeek) stream.Seek(0, SeekOrigin.Begin);

        var magic = new byte[4];
        var bytesRead = await stream.ReadAsync(magic);

        return bytesRead >= 4 &&
               magic[0] == 0x7F && magic[1] == 0x45 &&
               magic[2] == 0x4C && magic[3] == 0x46;
    }

    private static List<string> ListDirectories(string path)
    {
        if (!Directory.Exists(path)) return [];
        return Directory.GetDirectories(path)
            .Select(Path.GetFullPath)
            .ToList();
    }

    private void CreateDesktopEntry(
        string appName,
        string executablePath,
        string? comment = null,
        string icon = "application-x-executable",
        bool terminal = false,
        string categories = "Utility;")
    {
        var cleanName = CleanInvalidNames(appName);
        var desktopFilePath = Path.Combine(DesktopDir, $"{cleanName}.desktop");

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

        try
        {
            Directory.CreateDirectory(DesktopDir);
            File.WriteAllText(desktopFilePath, content.ToString());
            SetFilePermissions(desktopFilePath, "644");
            UpdateDesktopDatabase(DesktopDir);

            OnInfo($"Desktop entry created: {desktopFilePath}");
        }
        catch (Exception ex)
        {
            OnWarning($"Could not create desktop entry: {ex.Message}");
        }
    }

    private static string CleanInvalidNames(string name)
    {
        return name.ToLower()
            .Replace(" ", "-")
            .Replace("/", "-")
            .Replace("\\", "-");
    }

    private void SetFilePermissions(string filePath, string permissions)
    {
        try
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
            process?.WaitForExit();
        }
        catch (Exception ex)
        {
            OnWarning($"Could not set file permissions: {ex.Message}");
        }
    }

    private void UpdateDesktopDatabase(string desktopDir)
    {
        try
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
            process?.WaitForExit();
        }
        catch (Exception ex)
        {
            OnWarning($"Could not update desktop database: {ex.Message}");
        }
    }

    private async Task<string> InstallIcon(string iconPath, string appName)
    {
        try
        {
            var extension = Path.GetExtension(iconPath);
            var iconName = $"{appName.ToLower()}{extension}";
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
            var destPath = Path.Combine(destDir, iconName);

            File.Copy(iconPath, destPath, true);
            OnInfo($"Installed icon: {iconPath}");

            try
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
            catch (Exception ex)
            {
                OnWarning($"Failed to update icon cache: {ex.Message}");
            }

            return appName.ToLower();
        }
        catch (Exception ex)
        {
            OnWarning($"Could not install icon: {ex.Message}");
            return string.Empty;
        }
    }

    private void OnMessage(LocalManagerMessageLevel level, string message)
    {
        Message?.Invoke(this, new LocalManagerMessageEventArgs(level, message));
    }

    private void OnInfo(string message)
    {
        OnMessage(LocalManagerMessageLevel.Info, message);
    }

    private void OnWarning(string message)
    {
        OnMessage(LocalManagerMessageLevel.Warning, message);
    }

    private void OnError(string message)
    {
        OnMessage(LocalManagerMessageLevel.Error, message);
    }

    private void OnSuccess(string message)
    {
        OnMessage(LocalManagerMessageLevel.Success, message);
    }
}