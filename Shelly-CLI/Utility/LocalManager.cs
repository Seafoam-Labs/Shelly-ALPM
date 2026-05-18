using System.Diagnostics;
using System.Formats.Tar;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using PackageManager.Local;
using PackageManager.Zstd;
using Spectre.Console;

namespace Shelly_CLI.Utility;

// TODO: Move to PackageManager #771
public static partial class LocalManager
{
    public const string InstallDir = "/opt/shelly";
    private const string DesktopDir = "/usr/share/applications";

    [GeneratedRegex(@"(\d+)x?\d*")]
    private static partial Regex ImageSizeRegex();

    public static async Task<int> InstallBinariesPackage(string filePath, bool uiMode)
    {
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
                                if (File.Exists(linkPath))
                                {
                                    File.Delete(linkPath);
                                }

                                File.CreateSymbolicLink(linkPath, destPath);
                                installedBinaries.Add(binaryName);

                                await WriteInfoAsync($"Installed binary symlink: {linkPath} -> {destPath}", uiMode);
                            }

                            break;
                        }
                    }
                }
            }

            await WriteInfoAsync($"Extracted to {installDir}", uiMode);

            foreach (var binaryName in installedBinaries)
            {
                var iconName = "application-x-executable";

                if (!CleanInvalidNames(packageName)
                        .Contains(binaryName, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                if (foundIcons.Count > 0)
                {
                    var icon = foundIcons.FirstOrDefault();
                    var installedIconName = await InstallIcon(icon.Value, binaryName, uiMode);
                    if (string.IsNullOrWhiteSpace(installedIconName))
                    {
                        iconName = installedIconName;
                    }
                }
                else
                {
                    await WriteWarningAsync($"No icon found for {binaryName}, using default", uiMode);
                }

                await WriteInfoAsync("Creating desktop entry...", uiMode);
                CreateDesktopEntry(
                    binaryName,
                    binaryName,
                    uiMode,
                    $"{binaryName} - Installed from {packageName}",
                    iconName,
                    false,
                    "Utility;"
                );
            }

            if (installedBinaries.Count == 0)
            {
                await WriteWarningAsync("No executable ELF binaries were found in the archive.", uiMode);
            }

            return 0;
        }
        catch (Exception ex)
        {
            await WriteErrorAsync($"Failed to install binary package: {ex.Message}", uiMode);
            return 1;
        }
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

    private static List<string> ListDirectories(string path)
    {
        if (!Directory.Exists(path)) return [];
        return Directory.GetDirectories(path)
            .Select(Path.GetFullPath)
            .ToList();
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
                {
                    if (entry.Name.Contains("PKGINFO", StringComparison.InvariantCultureIgnoreCase))
                    {
                        return true;
                    }
                }

                break;
            }
            case ".gz":
            {
                await using var gzStream = new GZipStream(fileStream, CompressionMode.Decompress);
                await using var gzTarReader = new TarReader(gzStream);
                while (await gzTarReader.GetNextEntryAsync() is { } entry)
                {
                    if (entry.Name.Contains("PKGINFO", StringComparison.InvariantCultureIgnoreCase))
                    {
                        return true;
                    }
                }

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

    public static async Task<bool> RemoveBinaryPackages(List<string> packageList, bool uiMode)
    {
        try
        {
            var dirs = packageList
                .Select(path => new DirectoryInfo(path))
                .Where(dir => dir.FullName.StartsWith(InstallDir + '/') && dir.Exists);

            foreach (var dir in dirs)
            {
                var pkgInfos = dir
                    .EnumerateFiles("*", SearchOption.AllDirectories)
                    .ToList();

                List<FileInfo> pkgBins = [];
                foreach (var info in pkgInfos)
                {
                    await using var fs = File.OpenRead(info.FullName);
                    if (await IsElfBinary(fs))
                    {
                        pkgBins.Add(info);
                    }
                }

                List<string> desktopBins = [];

                foreach (var pkgBin in pkgBins)
                {
                    var usrBin = new FileInfo(Path.Combine("/usr/bin", pkgBin.Name));
                    var canDelete = pkgBin.FullName.Equals(usrBin.LinkTarget);
                    if (!canDelete)
                    {
                        continue;
                    }

                    await WriteInfoAsync($"Removing {pkgBin.Name} from {usrBin.FullName}", uiMode);
                    File.Delete(usrBin.FullName);

                    if (!CleanInvalidNames(dir.Name)
                            .Contains(pkgBin.Name, StringComparison.InvariantCultureIgnoreCase))
                    {
                        continue;
                    }

                    var desktopFilePath =
                        Path.Combine(DesktopDir, $"{Path.GetFileNameWithoutExtension(pkgBin.Name)}.desktop");

                    if (File.Exists(desktopFilePath))
                    {
                        await WriteInfoAsync($"Removing {desktopFilePath}", uiMode);
                        File.Delete(desktopFilePath);
                    }

                    desktopBins.Add(pkgBin.Name);
                }

                var iconInfos = pkgInfos
                    .Where(info => IsIcon(info.Extension.ToLowerInvariant()))
                    .OrderBy(info => info.Name)
                    .ToList();

                foreach (var desktopBin in desktopBins)
                {
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
                        if (!File.Exists(destPath))
                        {
                            continue;
                        }

                        await WriteInfoAsync($"Removing icon {destPath}", uiMode);
                        File.Delete(destPath);
                    }
                }

                await WriteInfoAsync($"Removing package directory {dir.FullName}", uiMode);
                dir.Delete(true);
            }

            return true;
        }
        catch (Exception ex)
        {
            await WriteErrorAsync($"Failed to remove binary package(s): {ex.Message}", uiMode);
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

    private static void CreateDesktopEntry(
        string appName,
        string executablePath,
        bool uiMode,
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
            SetFilePermissions(desktopFilePath, "644", uiMode);
            UpdateDesktopDatabase(DesktopDir, uiMode);

            WriteInfo($"Desktop entry created: {desktopFilePath}", uiMode);
        }
        catch (Exception ex)
        {
            WriteWarning($"Warning: Could not create desktop entry: {ex.Message}", uiMode);
        }
    }

    private static string CleanInvalidNames(string name)
    {
        return name.ToLower()
            .Replace(" ", "-")
            .Replace("/", "-")
            .Replace("\\", "-");
    }

    private static void SetFilePermissions(string filePath, string permissions, bool uiMode)
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
            WriteWarning($"Warning: Could not set file permissions: {ex.Message}", uiMode);
        }
    }

    private static void UpdateDesktopDatabase(string desktopDir, bool uiMode)
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
            WriteWarning($"Warning: Could not set desktop database: {ex.Message}", uiMode);
        }
    }

    private static async Task<string> InstallIcon(string iconPath, string appName, bool uiMode)
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
            await WriteInfoAsync($"Installed icon: {iconPath}", uiMode);

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
                await WriteWarningAsync($"Warning: Failed to update icon cache: {ex.Message}", uiMode);
            }

            return appName.ToLower();
        }
        catch (Exception ex)
        {
            await WriteWarningAsync($"Warning: Could not install icon: {ex.Message}", uiMode);
            return string.Empty;
        }
    }

    private static async Task WriteInfoAsync(string message, bool uiMode)
    {
        if (uiMode)
        {
            await Console.Error.WriteLineAsync(message);
            return;
        }

        AnsiConsole.MarkupLine($"[cyan]{message.EscapeMarkup()}[/]");
    }

    private static async Task WriteWarningAsync(string message, bool uiMode)
    {
        if (uiMode)
        {
            await Console.Error.WriteLineAsync(message);
            return;
        }

        AnsiConsole.MarkupLine($"[yellow]{message.EscapeMarkup()}[/]");
    }

    private static async Task WriteErrorAsync(string message, bool uiMode)
    {
        if (uiMode)
        {
            await Console.Error.WriteLineAsync(message);
            return;
        }

        AnsiConsole.MarkupLine($"[red]{message.EscapeMarkup()}[/]");
    }

    private static async Task WriteSuccessAsync(string message, bool uiMode)
    {
        if (uiMode)
        {
            await Console.Error.WriteLineAsync(message);
            return;
        }

        AnsiConsole.MarkupLine($"[green]{message.EscapeMarkup()}[/]");
    }

    private static void WriteWarning(string message, bool uiMode)
    {
        if (uiMode)
        {
            Console.Error.WriteLine(message);
            return;
        }

        AnsiConsole.MarkupLine($"[yellow]{message.EscapeMarkup()}[/]");
    }

    private static void WriteInfo(string message, bool uiMode)
    {
        if (uiMode)
        {
            Console.Error.WriteLine(message);
            return;
        }

        AnsiConsole.MarkupLine($"[cyan]{message.EscapeMarkup()}[/]");
    }
}