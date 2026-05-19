using System;
using System.Collections.Generic;
using System.Formats.Tar;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Threading.Tasks;
using PackageManager.Zstd;

namespace PackageManager.Local;

public sealed class LocalManager
{
    public const string InstallDir = "/opt/shelly";

    public event EventHandler<LocalManagerMessageEventArgs>? Message;


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
                            if (FileInspector.IsIcon(ext))
                            {
                                var iconFileName = Path.GetFileNameWithoutExtension(destPath).ToLowerInvariant();
                                foundIcons[iconFileName] = destPath;
                            }

                            await using var fs = File.OpenRead(destPath);
                            if (string.IsNullOrWhiteSpace(Path.GetExtension(destPath)) &&
                                await FileInspector.IsElfBinary(fs))
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
                    try
                    {
                        iconName = await XdgIntegration.InstallIcon(icon.Value, binaryName);
                        OnInfo($"Installed icon: {icon.Value} as {iconName}");
                    }
                    catch (Exception ex)
                    {
                        OnWarning($"Could not install icon: {ex.Message}");
                    }
                }
                else
                {
                    OnWarning($"No icon found for {binaryName}, using default");
                }

                try
                {
                    var desktopFileName = CleanInvalidNames(binaryName);
                    await XdgIntegration.CreateDesktopEntry(
                        binaryName,
                        desktopFileName,
                        binaryName,
                        $"{binaryName} - Installed from {packageName}",
                        iconName);
                    OnInfo($"Desktop entry created: {desktopFileName}");
                }
                catch (Exception ex)
                {
                    OnWarning($"Could not create desktop entry: {ex.Message}");
                }
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
                await RemoveBinaryPackageAssets(dir, pkgInfos);

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

    private async Task RemoveBinaryPackageAssets(DirectoryInfo dir, List<FileInfo> pkgInfos)
    {
        var pkgBins = await FileInspector.FindElfBinaries(pkgInfos);
        var desktopBins = new List<string>();

        foreach (var pkgBin in pkgBins)
        {
            var usrBin = new FileInfo(Path.Combine("/usr/bin", pkgBin.Name));
            if (!pkgBin.FullName.Equals(usrBin.LinkTarget)) continue;

            OnInfo($"Removing {pkgBin.Name} from {usrBin.FullName}");
            File.Delete(usrBin.FullName);

            if (!CleanInvalidNames(dir.Name).Contains(pkgBin.Name, StringComparison.InvariantCultureIgnoreCase))
                continue;

            if (XdgIntegration.RemoveDesktopEntry(pkgBin.Name))
                OnInfo($"Removed desktop entry for {pkgBin.Name}");
            desktopBins.Add(pkgBin.Name);
        }

        var iconInfos = pkgInfos
            .Where(info => FileInspector.IsIcon(info.Extension.ToLowerInvariant()))
            .OrderBy(info => info.Name)
            .ToList();

        foreach (var desktopBin in desktopBins)
        foreach (var icon in iconInfos)
            if (XdgIntegration.RemoveIcon(desktopBin, icon))
                OnInfo($"Removed icon for {desktopBin}: {icon.Name}");
    }

    private static List<string> ListDirectories(string path)
    {
        if (!Directory.Exists(path)) return [];
        return Directory.GetDirectories(path)
            .Select(Path.GetFullPath)
            .ToList();
    }

    private static string CleanInvalidNames(string name)
    {
        return name.ToLower()
            .Replace(" ", "-")
            .Replace("/", "-")
            .Replace("\\", "-");
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