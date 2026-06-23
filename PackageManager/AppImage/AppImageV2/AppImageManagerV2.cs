using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using PackageManager.AppImage.Events.EventArgs;
using Shelly.Utilities;
using Shelly.Utilities.Eventing;

namespace PackageManager.AppImage.AppImageV2;

public class AppImageManagerV2(string installDirectory = "")
{
    private readonly string _installDirectory =
        string.IsNullOrEmpty(installDirectory) ? XdgPaths.BinHome() : installDirectory;

    private static readonly string LocalDbPath =
        XdgPaths.ShellyCache("appimage-local-meta-store", "appimage-metadata-v2.db");

    public EventHandler<AppImageStatusEventArgs>? StatusEvent;
    public EventHandler<AppImageProgressEventArgs>? ProgressEvent;

    private void LogStatus(AppImageEvents severity, string message)
    {
        StatusEvent?.Invoke(this, new AppImageStatusEventArgs(severity, message));
    }

    private void LogMessage(string message)
    {
        LogStatus(AppImageEvents.Information, message);
    }

    private void LogError(string error)
    {
        LogStatus(AppImageEvents.Error, error);
    }

    private void LogWarning(string message)
    {
        LogStatus(AppImageEvents.Warning, message);
    }

    private void LogProgress(string appName, long? totalBytes, long downloadedBytes)
    {
        double? percentage = totalBytes.HasValue ? (double)downloadedBytes / totalBytes.Value * 100 : null;
        ProgressEvent?.Invoke(this, new AppImageProgressEventArgs(appName, totalBytes, downloadedBytes, percentage));
    }

    public async Task<bool> InstallAppImage(string location)
    {
        var filePath = Path.GetFullPath(location);
        var appName = Path.GetFileNameWithoutExtension(filePath);
        var destAppImagePath = Path.Combine(_installDirectory, $"{appName}.AppImage");

        if (!Directory.Exists(_installDirectory))
            Directory.CreateDirectory(_installDirectory);

        var newMetadata = await ExtractMetadata(filePath);
        newMetadata?.Path = destAppImagePath;

        var existingAppImages = await GetAppImagesFromLocalDb();

        AppImageDtoV2? existingAppImage = null;
        if (newMetadata != null)
        {
            existingAppImage = existingAppImages.FirstOrDefault(a =>
                string.Equals(a.Name, newMetadata.Name, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(a.DesktopName, newMetadata.DesktopName, StringComparison.OrdinalIgnoreCase));
        }
        else
        {
            existingAppImage =
                existingAppImages.FirstOrDefault(a =>
                    string.Equals(a.Name, appName, StringComparison.OrdinalIgnoreCase));
        }

        if (existingAppImage != null || File.Exists(destAppImagePath))
        {
            LogWarning($"AppImage {appName} already exists. Overwriting...");
            var oldName = existingAppImage?.Name ?? appName;
            var oldPath = existingAppImage?.Path ?? destAppImagePath;
            await CleanDesktopEntries(oldName, oldPath);
        }

        LogMessage($"Installing AppImage {appName}...");
        File.Copy(filePath, destAppImagePath, true);
        XdgPaths.FixOwnershipIfRoot(destAppImagePath);
        SetFilePermissions(destAppImagePath, "a+x");

        var appImageDto = newMetadata ?? await ExtractMetadata(destAppImagePath);
        if (appImageDto == null)
        {
            LogError("Failed to extract metadata during installation.");
            return false;
        }

        await AddAppImageToLocalDb(appImageDto);

        return true;
    }

    public async Task<bool> AppImageConfigureUpdates(string updateInfo, string name, UpdateType updateType,
        bool allowPrerelease = false)
    {
        LogMessage(
            $"Configuring updates for {name} {updateInfo}, type: {updateType}, allowPrerelease: {allowPrerelease}");
        var appImages = await GetAppImagesFromLocalDb();
        var appImage = appImages.FirstOrDefault(a => string.Equals(a.Name, name, StringComparison.OrdinalIgnoreCase));
        if (appImage == null) return false;
        await ConfigureUpdates(updateInfo, updateType, ref appImage, allowPrerelease);
        return await AddAppImageToLocalDb(appImage);
    }

    private Task ConfigureUpdates(string updateInfo, UpdateType updateType, ref AppImageDtoV2 appImage,
        bool allowPrerelease = false)
    {
        appImage.AllowPrerelease = allowPrerelease;
        switch (updateType)
        {
            case UpdateType.None:
                appImage.UpdateType = UpdateType.None;
                appImage.UpdateURl = string.Empty;
                appImage.RepoOwner = null;
                appImage.RepoName = null;
                break;
            case UpdateType.StaticUrl:
                appImage.UpdateType = UpdateType.StaticUrl;
                appImage.UpdateURl = updateInfo;
                appImage.UpdateType = updateType;
                break;
            case UpdateType.GitHub:
            case UpdateType.GitLab:
            case UpdateType.Codeberg:
            case UpdateType.Forgejo:
                if (updateInfo.Count(c => c == '/') == 1)
                {
                    appImage.RepoOwner = updateInfo.Split('/')[0];
                    appImage.RepoName = updateInfo.Split('/')[1];
                    appImage.UpdateType = updateType;
                }
                else
                {
                    LogWarning(
                        "Could not parse update info. Please use the format: <user>/<repo> (e.g., github.com/user/repo or gitlab.com/user/repo");
                }

                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(updateType), updateType, null);
        }

        return Task.CompletedTask;
    }

    private async Task<bool> AddAppImageToLocalDb(AppImageDtoV2 appImage)
    {
        try
        {
            var appImages = await GetAppImagesFromLocalDb();

            if (!string.IsNullOrEmpty(appImage.DesktopName))
            {
                appImages.RemoveAll(a =>
                    string.Equals(a.DesktopName, appImage.DesktopName, StringComparison.OrdinalIgnoreCase));
            }

            appImages.Add(appImage);

            await EnsureDbDirectoryExists();
            var json = JsonSerializer.Serialize(appImages, AppImageJsonContextV2.Default.ListAppImageDtoV2);
            await File.WriteAllTextAsync(LocalDbPath, json);
            return true;
        }
        catch (Exception ex)
        {
            LogError($"Error adding AppImage to local DB: {ex.Message}");
            return false;
        }
    }

    public async Task<List<AppImageDtoV2>> GetAppImagesFromLocalDb()
    {
        try
        {
            if (!File.Exists(LocalDbPath))
            {
                return [];
            }

            var json = await File.ReadAllTextAsync(LocalDbPath);
            return JsonSerializer.Deserialize(json, AppImageJsonContextV2.Default.ListAppImageDtoV2) ??
                   [];
        }
        catch (Exception ex)
        {
            LogError($"Error reading AppImage local DB: {ex.Message}");
            return [];
        }
    }

    private async Task<bool> RemoveAppImageFromLocalDb(string appName)
    {
        try
        {
            var appImages = await GetAppImagesFromLocalDb();
            var initialCount = appImages.Count;
            appImages.RemoveAll(a => string.Equals(a.Name, appName, StringComparison.OrdinalIgnoreCase));

            if (appImages.Count == initialCount) return true;
            await EnsureDbDirectoryExists();
            var json = JsonSerializer.Serialize(appImages, AppImageJsonContextV2.Default.ListAppImageDtoV2);
            await File.WriteAllTextAsync(LocalDbPath, json);

            return true;
        }
        catch (Exception ex)
        {
            LogError($"Error removing AppImage from local DB: {ex.Message}");
            return false;
        }
    }

    public async Task<bool> RemoveAppImage(string appImagePath, bool removeConfigFiles = false)
    {
        var appName = Path.GetFileNameWithoutExtension(appImagePath);
        var cleanName = CleanInvalidNames(appName);
        var userDataHome = XdgPaths.DataHome();

        try
        {
            await RemoveAppImageFromLocalDb(appName);

            if (File.Exists(appImagePath))
            {
                File.Delete(appImagePath);
                LogMessage($"Removed AppImage: {appImagePath}");
            }

            var desktopAppName = await CleanDesktopEntries(appName, appImagePath);

            string[] iconDirs =
            [
                Path.Combine(userDataHome, "icons/hicolor/scalable/apps"),
                Path.Combine(userDataHome, "icons/hicolor/256x256/apps")
            ];

            foreach (var iconDir in iconDirs)
            {
                if (!Directory.Exists(iconDir)) continue;

                var potentialIcons = Directory.GetFiles(iconDir)
                    .Where(f => Path.GetFileNameWithoutExtension(f)
                        .Equals(cleanName, StringComparison.OrdinalIgnoreCase));
                foreach (var icon in potentialIcons)
                {
                    File.Delete(icon);
                    LogMessage($"Removed icon: {icon}");
                }
            }

            if (removeConfigFiles)
            {
                RemoveAppConfigDirectories(desktopAppName);
            }
        }
        catch (Exception ex)
        {
            LogError($"Error during removal: {ex.Message}");
            return false;
        }

        return true;
    }

    private async Task<string?> CleanDesktopEntries(string appName, string appPath)
    {
        var cleanName = CleanInvalidNames(appName);
        var userDataHome = XdgPaths.DataHome();
        string[] desktopDirs = [Path.Combine(userDataHome, "applications")];
        string? desktopAppName = null;

        foreach (var desktopDir in desktopDirs)
        {
            if (!Directory.Exists(desktopDir)) continue;

            var desktopFiles = Directory.GetFiles(desktopDir, "*.desktop");
            foreach (var df in desktopFiles)
            {
                var fileName = Path.GetFileName(df);
                var isCleanNameMatch = fileName.Equals($"{cleanName}.desktop", StringComparison.OrdinalIgnoreCase);

                var content = await File.ReadAllLinesAsync(df);
                var isExecMatch = content.Any(l =>
                    l.StartsWith("Exec=") &&
                    (l.Contains(appPath) || l.Contains($"\"{appPath}\"")));

                if (!isCleanNameMatch && !isExecMatch) continue;
                {
                    desktopAppName ??= content.FirstOrDefault(l => l.StartsWith("Name="))?.Substring(5).Trim();
                    try
                    {
                        File.Delete(df);
                        LogMessage($"Removed desktop entry: {df}");
                        UpdateDesktopDatabase(desktopDir, true);
                    }
                    catch (Exception ex)
                    {
                        LogWarning($"Failed to remove desktop entry {df}: {ex.Message}");
                    }
                }
            }
        }

        return desktopAppName;
    }

    private void RemoveAppConfigDirectories(string? desktopAppName = null)
    {
        if (string.IsNullOrWhiteSpace(desktopAppName))
        {
            LogMessage("No desktop app name available; skipping config directory removal.");
            return;
        }

        var normalizedKey = Normalize(desktopAppName);

        var searchRoots = new[]
        {
            XdgPaths.ConfigHome(),
            XdgPaths.DataHome(),
            XdgPaths.CacheHome(),
            XdgPaths.StateHome(),
        };

        foreach (var root in searchRoots)
        {
            if (!Directory.Exists(root)) continue;

            try
            {
                foreach (var subDir in Directory.GetDirectories(root))
                {
                    if (Normalize(Path.GetFileName(subDir)) == normalizedKey)
                        TryDeleteDirectory(subDir);
                }
            }
            catch
            {
                /* ignore enumeration errors */
            }
        }
    }

    private static string Normalize(string name) =>
        name.ToLowerInvariant().Replace("-", "").Replace("_", "").Replace(" ", "");

    private void TryDeleteDirectory(string dir)
    {
        LogMessage($"Checking {dir}");
        try
        {
            Directory.Delete(dir, true);
            LogMessage($"Removed config directory: {dir}");
        }
        catch (Exception ex)
        {
            LogWarning($"Could not remove config directory {dir}: {ex.Message}");
        }
    }

    public async Task<bool> SyncAppImageMeta(List<string> appImageNames)
    {
        try
        {
            var appImagesInDb = await GetAppImagesFromLocalDb();
            var success = true;

            foreach (var appName in appImageNames)
            {
                var existing = appImagesInDb.FirstOrDefault(a =>
                    string.Equals(a.Name, appName, StringComparison.OrdinalIgnoreCase));

                var appImagePath = Path.Combine(_installDirectory, $"{appName}.AppImage");

                if (!File.Exists(appImagePath))
                {
                    if (existing != null && !string.IsNullOrEmpty(existing.Path) && File.Exists(existing.Path))
                    {
                        LogMessage($"AppImage found at {existing.Path}. Moving to {_installDirectory}...");
                        try
                        {
                            if (!Directory.Exists(_installDirectory))
                                Directory.CreateDirectory(_installDirectory);

                            File.Move(existing.Path, appImagePath, true);
                            XdgPaths.FixOwnershipIfRoot(appImagePath);
                            LogMessage($"Moved {appName} to {appImagePath}");
                        }
                        catch (Exception ex)
                        {
                            LogError($"Failed to move AppImage from {existing.Path} to {appImagePath}: {ex.Message}");
                            success = false;
                            continue;
                        }
                    }
                    else
                    {
                        LogWarning($"AppImage not found at {appImagePath}");
                        success = false;
                        continue;
                    }
                }

                LogMessage($"Syncing metadata for {appName}...");
                var appImageDto = await ExtractMetadata(appImagePath);
                if (appImageDto == null)
                {
                    LogError($"Failed to extract metadata for {appName}");
                    success = false;
                    continue;
                }

                if (existing != null)
                {
                    if (!string.IsNullOrEmpty(existing.UpdateURl))
                    {
                        appImageDto.UpdateURl = existing.UpdateURl;
                        appImageDto.UpdateType = existing.UpdateType;
                    }

                    if (!string.IsNullOrEmpty(existing.RawUpdateInfo) &&
                        string.IsNullOrEmpty(appImageDto.RawUpdateInfo))
                    {
                        appImageDto.RawUpdateInfo = existing.RawUpdateInfo;
                    }

                    appImageDto.RepoOwner = existing.RepoOwner;
                    appImageDto.RepoName = existing.RepoName;
                    appImageDto.UpdateType = existing.UpdateType;
                    appImageDto.AllowPrerelease = existing.AllowPrerelease;
                }
                else
                {
                    if (!string.IsNullOrEmpty(appImageDto.RawUpdateInfo) && string.IsNullOrEmpty(appImageDto.UpdateURl))
                    {
                        appImageDto.UpdateType = UpdateType.StaticUrl;
                    }
                }

                await AddAppImageToLocalDb(appImageDto);
                await MigrateDesktopEntry(appImageDto);
            }

            return success;
        }
        catch (Exception ex)
        {
            LogError($"Error syncing AppImage metadata: {ex.Message}");
            return false;
        }
    }

    private async Task<AppImageDtoV2?> ExtractMetadata(string filePath)
    {
        var appName = Path.GetFileNameWithoutExtension(filePath);

        //handle Temp Update files
        if (filePath.EndsWith(".rep", StringComparison.OrdinalIgnoreCase))
        {
            appName = Path.GetFileNameWithoutExtension(appName);
        }

        var cleanName = CleanInvalidNames(appName);
        var execPath = filePath.EndsWith(".rep", StringComparison.OrdinalIgnoreCase)
            ? filePath[..^4]
            : filePath;

        var desktopDir = Path.Combine(XdgPaths.DataHome(), "applications");
        if (Directory.Exists(desktopDir))
        {
            //Clean Bad desktop entries.
            try
            {
                var badDesktopFiles = Directory.GetFiles(desktopDir, "*.desktop", SearchOption.TopDirectoryOnly)
                    .Where(f => f.EndsWith(".AppImage.desktop", StringComparison.OrdinalIgnoreCase));
                foreach (var badDesktopPath in badDesktopFiles)
                {
                    try
                    {
                        File.Delete(badDesktopPath);
                        LogMessage($"Cleaned up invalid desktop entry: {badDesktopPath}");
                    }
                    catch (Exception ex)
                    {
                        LogWarning($"Failed to delete invalid desktop entry {badDesktopPath}: {ex.Message}");
                    }
                }
            }
            catch (Exception ex)
            {
                LogWarning($"Error while searching for invalid desktop entries: {ex.Message}");
            }
        }

        var workingDir = Path.Combine(Path.GetTempPath(), $"Shelly-{Environment.UserName}",
            $"sync-{appName}-{Guid.NewGuid().ToString("N")[..8]}");
        var appImageVersion = "Unknown";
        var desktopName = "";
        var destIconName = "";
        var description = "";
        var commandLineArgs = "";

        try
        {
            if (Directory.Exists(workingDir)) Directory.Delete(workingDir, true);
            Directory.CreateDirectory(workingDir);

            SetFilePermissions(filePath, "a+x");

            var squashfsRoot = Path.Combine(workingDir, "squashfs-root");

            try
            {
                using var extractProcess = new Process
                {
                    StartInfo = new ProcessStartInfo
                    {
                        FileName = filePath,
                        Arguments = "--appimage-extract",
                        WorkingDirectory = workingDir,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    }
                };
                extractProcess.Start();
                _ = extractProcess.StandardOutput.ReadToEndAsync();
                _ = extractProcess.StandardError.ReadToEndAsync();
                await extractProcess.WaitForExitAsync();
            }
            catch (Exception ex)
            {
                LogWarning($"Could not execute AppImage directly: {ex.Message}.");
                return null;
            }

            var desktopFile = Directory.GetFiles(squashfsRoot, "*.desktop", SearchOption.TopDirectoryOnly)
                .FirstOrDefault();
            string? iconName = null;
            if (desktopFile != null)
            {
                var lines = await File.ReadAllLinesAsync(desktopFile);
                var iconLine = lines.FirstOrDefault(l => l.StartsWith("Icon="));
                if (iconLine != null)
                {
                    iconName = iconLine.Split('=', 2)[1].Trim();
                }
            }

            string? iconPath = null;
            if (!string.IsNullOrEmpty(iconName))
            {
                iconPath = SafeGetFiles(squashfsRoot, $"{iconName}.*").FirstOrDefault();
            }

            if (iconPath == null)
            {
                iconPath = Path.Combine(squashfsRoot, ".DirIcon");
                if (!File.Exists(iconPath)) iconPath = null;
            }

            var finalIconPath = "application-x-executable";
            if (iconPath != null)
            {
                var extension = Path.GetExtension(iconPath).ToLower();
                if (string.IsNullOrEmpty(extension) || extension == ".diricon")
                {
                    extension = ".png";
                }

                var iconSubDir = extension == ".svg" ? "icons/hicolor/scalable/apps" : "icons/hicolor/256x256/apps";
                var userIconDir = Path.Combine(XdgPaths.DataHome(), iconSubDir);

                destIconName = $"{CleanInvalidNames(appName).ToLower()}{extension}";

                try
                {
                    Directory.CreateDirectory(userIconDir);
                    var destIconPath = Path.Combine(userIconDir, destIconName);
                    File.Copy(iconPath, destIconPath, true);
                    XdgPaths.FixOwnershipIfRoot(destIconPath);
                    finalIconPath = CleanInvalidNames(appName).ToLower();
                    LogMessage($"Updated icon: {destIconPath}");
                }
                catch (Exception ex)
                {
                    LogWarning($"Could not copy icon to {userIconDir}: {ex.Message}");
                }

                var themeDir = Path.Combine(XdgPaths.DataHome(), "icons/hicolor");
                if (Directory.Exists(themeDir))
                    UpdateIconCache(themeDir);
            }

            if (desktopFile != null)
            {
                try
                {
                    var desktopLines = await File.ReadAllLinesAsync(desktopFile);
                    var patchedContent = new StringBuilder();
                    foreach (var line in desktopLines)
                    {
                        if (line.StartsWith("Exec="))
                        {
                            // Preserve %u, %U, %f, %F and other field codes from the original Exec line
                            var execValue = line["Exec=".Length..].Trim();
                            var fieldCodes = "";
                            foreach (var token in execValue.Split(' ').Skip(1))
                            {
                                if (!token.StartsWith('%')) continue;
                                fieldCodes = $" {token}";
                                commandLineArgs += $" {token}";
                                break;
                            }

                            patchedContent.AppendLine($"Exec=\"{execPath}\"{fieldCodes}");
                        }
                        else if (line.StartsWith("TryExec="))
                        {
                            //do nothing 
                        }
                        else if (line.StartsWith("Icon="))
                        {
                            patchedContent.AppendLine($"Icon={finalIconPath}");
                        }
                        else if (line.StartsWith("X-AppImage-Version="))
                        {
                            appImageVersion = line.Split('=')[1];
                            patchedContent.AppendLine(line);
                        }
                        else if (line.StartsWith("Name="))
                        {
                            if (string.IsNullOrEmpty(desktopName)) desktopName = line.Split('=')[1];
                            patchedContent.AppendLine(line);
                        }
                        else if (line.StartsWith("Comment="))
                        {
                            if (string.IsNullOrEmpty(description)) description = line.Split('=')[1];
                            patchedContent.AppendLine(line);
                        }
                        else
                        {
                            patchedContent.AppendLine(line);
                        }
                    }

                    var desktopFileName = $"{cleanName}.desktop";
                    var desktopContent = patchedContent.ToString();

                    try
                    {
                        Directory.CreateDirectory(desktopDir);
                        var desktopFilePath = Path.Combine(desktopDir, desktopFileName);
                        await File.WriteAllTextAsync(desktopFilePath, desktopContent);
                        XdgPaths.FixOwnershipIfRoot(desktopFilePath);
                        SetFilePermissions(desktopFilePath, "644");
                        UpdateDesktopDatabase(desktopDir, true);
                        LogMessage($"Updated desktop entry: {desktopFilePath}");
                    }
                    catch (Exception ex)
                    {
                        LogWarning($"Could not update desktop entry in {desktopDir}: {ex.Message}");
                    }
                }
                catch (Exception ex)
                {
                    LogWarning($"Could not update any desktop entry: {ex.Message}");
                    CreateDesktopEntry(appName, execPath, icon: finalIconPath);
                }
            }
            else
            {
                LogMessage($"No desktop file found in AppImage, creating default one.");
                CreateDesktopEntry(appName, execPath, icon: finalIconPath);
            }

            var updateInfo = await GetAppImageUpdateInfo(filePath);

            var appImageDto = new AppImageDtoV2
            {
                Name = appName,
                Version = appImageVersion,
                RawUpdateInfo = updateInfo,
                IconName = Path.GetFileNameWithoutExtension(destIconName),
                Description = description,
                DesktopName = string.IsNullOrEmpty(desktopName) ? appName : desktopName,
                SizeOnDisk = new FileInfo(filePath).Length,
                CommandLineArgs = commandLineArgs,
                Path = execPath,
            };

            return appImageDto;
        }
        catch (Exception ex)
        {
            LogError($"Error extracting metadata for {appName}: {ex.Message}");
            return null;
        }
        finally
        {
            try
            {
                if (Directory.Exists(workingDir)) Directory.Delete(workingDir, true);
            }
            catch (Exception ex)
            {
                LogWarning($"Could not delete working directory {workingDir}: {ex.Message}");
            }
        }
    }

    private void SetFilePermissions(string filePath, string permissions)
    {
        try
        {
            var process = Process.Start(new ProcessStartInfo
            {
                FileName = "chmod",
                Arguments = $"{permissions} \"{filePath}\"",
                RedirectStandardOutput = false,
                RedirectStandardError = false,
                UseShellExecute = false,
                CreateNoWindow = true
            });
            process?.WaitForExit();
        }
        catch (Exception ex)
        {
            LogWarning($"Could not set file permissions: {ex.Message}");
        }
    }

    private static Task EnsureDbDirectoryExists()
    {
        try
        {
            var directory = Path.GetDirectoryName(LocalDbPath);
            if (!string.IsNullOrEmpty(directory) && !Directory.Exists(directory))
            {
                Directory.CreateDirectory(directory);
            }

            return Task.CompletedTask;
        }
        catch (Exception exception)
        {
            return Task.FromException(exception);
        }
    }

    private static List<string> SafeGetFiles(string rootDir, string searchPattern)
    {
        var results = new List<string>();
        try
        {
            results.AddRange(Directory.GetFiles(rootDir, searchPattern, SearchOption.TopDirectoryOnly));
        }
        catch
        {
            /* ignore access errors */
        }

        try
        {
            foreach (var dir in Directory.GetDirectories(rootDir))
            {
                var dirInfo = new DirectoryInfo(dir);
                if (dirInfo.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
                results.AddRange(SafeGetFiles(dir, searchPattern));
            }
        }
        catch
        {
            /* ignore access errors */
        }

        return results;
    }

    private static string CleanInvalidNames(string name)
    {
        return name.ToLower()
            .Replace(" ", "-")
            .Replace("/", "-")
            .Replace("\\", "-");
    }

    private void UpdateIconCache(string iconThemeDir)
    {
        try
        {
            var process = Process.Start(new ProcessStartInfo
            {
                FileName = "gtk-update-icon-cache",
                Arguments = $"-f -t \"{iconThemeDir}\"",
                RedirectStandardOutput = false,
                RedirectStandardError = false,
                UseShellExecute = false,
                CreateNoWindow = true
            });
            process?.WaitForExit();
        }
        catch (Exception ex)
        {
            LogWarning($"Could not update icon cache for {iconThemeDir}: {ex.Message}");
        }
    }

    private void UpdateDesktopDatabase(string desktopDir, bool local = false)
    {
        try
        {
            if (local)
            {
                XdgPaths.FixOwnershipIfRoot($"{desktopDir}/mimeinfo.cache");
            }
            var process = Process.Start(new ProcessStartInfo
            {
                FileName = "update-desktop-database",
                Arguments = $"\"{desktopDir}\"",
                RedirectStandardOutput = false,
                RedirectStandardError = false,
                UseShellExecute = false,
                CreateNoWindow = true
            });
            process?.WaitForExit();
        }
        catch (Exception ex)
        {
            LogWarning($"Could not set desktop database: {ex.Message}");
        }
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
        var desktopFileName = $"{cleanName}.desktop";

        var content = new StringBuilder();
        content.AppendLine("[Desktop Entry]");
        content.AppendLine("Version=1.0");
        content.AppendLine("Type=Application");
        content.AppendLine($"Name={appName}");
        content.AppendLine($"Comment={comment ?? $"{appName} application"}");
        content.AppendLine($"Exec=\"{executablePath}\"");
        content.AppendLine($"Icon={icon}");
        content.AppendLine($"Terminal={terminal.ToString().ToLower()}");
        content.AppendLine($"Categories={categories}");
        content.AppendLine("StartupNotify=true");

        var desktopDir = Path.Combine(XdgPaths.DataHome(), "applications");
        try
        {
            Directory.CreateDirectory(desktopDir);
            var desktopFilePath = Path.Combine(desktopDir, desktopFileName);
            File.WriteAllText(desktopFilePath, content.ToString());
            XdgPaths.FixOwnershipIfRoot(desktopFilePath);
            SetFilePermissions(desktopFilePath, "644");
            UpdateDesktopDatabase(desktopDir, true);

            LogMessage($"Desktop entry created: {desktopFilePath}");
        }
        catch (Exception ex)
        {
            LogWarning($"Could not create desktop entry in {desktopDir}: {ex.Message}");
        }
    }

    public async Task<string> GetAppImageUpdateInfo(string appImagePath)
    {
        try
        {
            var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = appImagePath,
                    Arguments = "--appimage-updateinfo",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                }
            };

            process.Start();
            var output = await process.StandardOutput.ReadToEndAsync();
            var error = await process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync();

            if (process.ExitCode != 0)
            {
                LogError($"Failed to get update info for {appImagePath}: {error}");
                return string.Empty;
            }

            return output.Trim();
        }
        catch (Exception ex)
        {
            LogError($"Could not get update info for {appImagePath}: {ex.Message}");
            return string.Empty;
        }
    }


    public async Task<List<AppImageUpdateDto>> CheckForAppImageUpdates()
    {
        var updates = new List<AppImageUpdateDto>();
        var installedAppImages = await GetAppImagesFromLocalDb();

        foreach (var appImage in installedAppImages)
        {
            var update = await CheckUpdate(appImage);
            if (update != null && update.IsUpdateAvailable)
            {
                updates.Add(update);
            }
        }

        return updates;
    }

    public async Task<AppImageUpdateDto?> CheckUpdate(AppImageDtoV2 appImage)
    {
        return appImage.UpdateType switch
        {
            UpdateType.GitHub => appImage is { RepoOwner: not null, RepoName: not null }
                ? await CheckGitHubUpdate(appImage.RepoOwner, appImage.RepoName, appImage.Name, appImage.Version,
                    appImage.AllowPrerelease)
                : null,
            UpdateType.GitLab => appImage is { RepoOwner: not null, RepoName: not null }
                ? await CheckGitLabUpdate(appImage.RepoOwner, appImage.RepoName, appImage.Name, appImage.Version,
                    appImage.AllowPrerelease)
                : null,
            UpdateType.Codeberg => appImage is { RepoOwner: not null, RepoName: not null }
                ? await CheckCodebergUpdate(appImage.RepoName, appImage.RepoOwner, appImage.Name, appImage.Version,
                    appImage.AllowPrerelease)
                : null,
            UpdateType.Forgejo => appImage.RepoOwner != null && appImage.RepoName != null
                ? await CheckForgejoUpdate(appImage.RepoName, appImage.Name, appImage.RepoOwner, appImage.Version,
                    appImage.AllowPrerelease)
                : null,
            UpdateType.StaticUrl => await CheckStaticUrlUpdate(appImage.UpdateURl, appImage.Name,
                appImage.Version),
            _ => null
        };
    }

    private static async Task<AppImageUpdateDto?> CheckStaticUrlUpdate(string url, string appName,
        string currentVersion)
    {
        try
        {
            using var client = new HttpClient();
            client.DefaultRequestHeaders.UserAgent.Add(Http.UserAgent);
            var request = new HttpRequestMessage(HttpMethod.Head, url);
            var response = await client.SendAsync(request);
            if (!response.IsSuccessStatusCode) return null;

            var lastModified = response.Content.Headers.LastModified?.ToString() ?? "";
            var etag = response.Headers.ETag?.Tag ?? "";
            var version = !string.IsNullOrEmpty(etag) ? etag : lastModified;
            version = version.Replace("\"", "");

            return new AppImageUpdateDto
            {
                Name = appName,
                Version = version,
                DownloadUrl = url,
                IsUpdateAvailable = IsVersionUnknownOrDifferent(currentVersion, version)
            };
        }
        catch
        {
            return null;
        }
    }

    private static string GetSystemArchitecture()
    {
        return RuntimeInformation.OSArchitecture switch
        {
            Architecture.X64 => "x86_64",
            Architecture.Arm64 => "aarch64",
            Architecture.X86 => "i386",
            Architecture.Arm => "arm",
            _ => "x86_64"
        };
    }

    private static bool IsVersionUnknownOrDifferent(string currentVersion, string latestVersion)
    {
        if (string.IsNullOrEmpty(currentVersion) ||
            string.Equals(currentVersion, "Unknown", StringComparison.OrdinalIgnoreCase))
            return true;

        return latestVersion != currentVersion;
    }

    public static Task<bool> IsAppImage(string filePath)
    {
        var extension = Path.GetExtension(filePath);
        return Task.FromResult(string.Equals(extension, ".AppImage", StringComparison.OrdinalIgnoreCase));
    }

    private static bool IsCorrectArchitecture(string assetName)
    {
        var systemArch = GetSystemArchitecture();
        var lowerName = assetName.ToLowerInvariant();

        string[] x8664Aliases = ["x86_64", "amd64", "x64"];
        string[] aarch64Aliases = ["aarch64", "arm64", "armv8"];
        string[] i386Aliases = ["i386", "i686", "x86"];
        string[] armhfAliases = ["armhf", "armv7l", "arm"];

        var targetAliases = systemArch switch
        {
            "x86_64" => x8664Aliases,
            "aarch64" => aarch64Aliases,
            "i386" => i386Aliases,
            "arm" => armhfAliases,
            _ => [systemArch]
        };

        if (targetAliases.Any(lowerName.Contains))
        {
            return true;
        }

        var allOtherAliases = x8664Aliases.Concat(aarch64Aliases).Concat(i386Aliases).Concat(armhfAliases)
            .Where(a => !targetAliases.Contains(a));

        return !allOtherAliases.Any(lowerName.Contains);
    }

    public async Task<bool> RunUpdate(AppImageUpdateDto update)
    {
        var appImages = await GetAppImagesFromLocalDb();
        var appImage =
            appImages.FirstOrDefault(a => string.Equals(a.Name, update.Name, StringComparison.OrdinalIgnoreCase));

        if (appImage == null)
        {
            LogError($"AppImage '{update.Name}' not found in local database.");
            return false;
        }

        LogMessage($"Updating {appImage.Name}");

        if (string.IsNullOrEmpty(update.DownloadUrl))
        {
            LogError($"No download URL found for {update.Name}.");
            return false;
        }

        var currentPath = Path.Combine(_installDirectory, $"{appImage.Name}.AppImage");
        if (!File.Exists(currentPath))
        {
            LogError($"Current AppImage not found at {currentPath}.");
            return false;
        }

        var backupDir = XdgPaths.ShellyCache(update.Name);
        var backupPath = Path.Combine(backupDir, $"{appImage.Name}-{appImage.Version}.AppImage.bak");
        var downloadPath = currentPath + ".rep";

        try
        {
            if (!Directory.Exists(backupDir)) Directory.CreateDirectory(backupDir);

            LogMessage($"Downloading update for {update.Name}...");
            using (var client = new HttpClient())
            {
                client.Timeout = TimeSpan.FromMinutes(5);
                client.DefaultRequestHeaders.UserAgent.Add(Http.UserAgent);

                using var response =
                    await client.GetAsync(update.DownloadUrl, HttpCompletionOption.ResponseHeadersRead);
                response.EnsureSuccessStatusCode();

                var totalBytes = response.Content.Headers.ContentLength;
                await using var fs = new FileStream(downloadPath, FileMode.Create, FileAccess.Write, FileShare.None);
                await using var contentStream = await response.Content.ReadAsStreamAsync();

                var buffer = new byte[81920];
                long totalDownloadedBytes = 0;
                int bytesRead;
                var lastReportedProgress = -1;

                while ((bytesRead = await contentStream.ReadAsync(buffer)) != 0)
                {
                    await fs.WriteAsync(buffer.AsMemory(0, bytesRead));
                    totalDownloadedBytes += bytesRead;

                    if (totalBytes.HasValue)
                    {
                        var currentProgress = (int)((double)totalDownloadedBytes / totalBytes.Value * 100);
                        if (currentProgress <= lastReportedProgress) continue;
                        LogProgress(update.Name, totalBytes, totalDownloadedBytes);
                        lastReportedProgress = currentProgress;
                    }
                    else
                    {
                        LogProgress(update.Name, totalBytes, totalDownloadedBytes);
                    }
                }
            }

            SetFilePermissions(downloadPath, "a+x");

            var newMetadata = await ExtractMetadata(downloadPath);
            if (newMetadata == null)
            {
                LogError("Failed to verify downloaded AppImage metadata.");
                if (File.Exists(downloadPath)) File.Delete(downloadPath);
                return false;
            }

            if (!IsCorrectArchitecture(Path.GetFileName(update.DownloadUrl) ?? ""))
            {
                LogWarning(
                    $"The downloaded AppImage might not match your system architecture.");
            }

            LogMessage($"Backing up current version to {backupPath}...");
            File.Copy(currentPath, backupPath, true);

            try
            {
                LogMessage("Installing new version...");
                File.Move(downloadPath, currentPath, true);
            }
            catch (Exception ex)
            {
                LogError($"Error installing new version: {ex.Message}. Rolling back...");
                File.Copy(backupPath, currentPath, true);
                return false;
            }

            appImage.Version = update.Version;
            appImage.Description = newMetadata.Description;
            appImage.IconName = newMetadata.IconName;

            await AddAppImageToLocalDb(appImage);

            return true;
        }
        catch (Exception ex)
        {
            LogError($"Error during update: {ex.Message}");
            if (File.Exists(downloadPath)) File.Delete(downloadPath);
            if (File.Exists(backupPath) && !File.Exists(currentPath))
            {
                File.Copy(backupPath, currentPath);
            }

            return false;
        }
    }

    //Bob Ross said we make happy little accidents
    //Bob never saw me make the decisions around AppImages
    public async Task<bool> MigrateAppImages()
    {
        const string installDir = "/opt/shelly";

        var localDbDir = XdgPaths.ShellyCache("appimage-local-meta-store", "appimage-metadata.db");

        if (Directory.Exists(installDir))
        {
            LogMessage($"Creating install directory: {_installDirectory}");
            Directory.CreateDirectory(_installDirectory);
            XdgPaths.FixOwnershipIfRoot(_installDirectory);
            var files = Directory.GetFiles(installDir);
            LogMessage($"Found {files.Length} AppImage(s) in {installDir} to migrate.");
            foreach (var file in files)
            {
                var destFile = Path.Combine(_installDirectory, Path.GetFileName(file));
                LogMessage($"Copying {Path.GetFileName(file)} to {_installDirectory}...");
                File.Copy(file, destFile, true);
                XdgPaths.FixOwnershipIfRoot(destFile);
                File.Delete(file);
                LogMessage($"Removed original: {file}");
            }
        }
        else
        {
            LogMessage($"No legacy install directory found at {installDir}, skipping file migration.");
        }


        if (!File.Exists(localDbDir))
        {
            LogMessage("No legacy metadata database found, migration complete.");
            return true;
        }

        LogMessage($"Reading legacy metadata from {localDbDir}...");

        try
        {
            var json = await File.ReadAllTextAsync(localDbDir);
            var appImages = JsonSerializer.Deserialize(json, AppImageJsonContext.Default.ListAppImageDto) ?? [];

            var existingApps = await GetAppImagesFromLocalDb();

            foreach (var app in appImages)
            {
                try
                {
                    var cleanName = CleanInvalidNames(app.Name);
                    var userDataHome = XdgPaths.DataHome();

                    // Fix sin of desktop entry ownership
                    var desktopDir = Path.Combine(userDataHome, "applications");
                    if (Directory.Exists(desktopDir))
                    {
                        var desktopFilePath = Path.Combine(desktopDir, $"{cleanName}.desktop");
                        if (File.Exists(desktopFilePath))
                        {
                            XdgPaths.FixOwnershipIfRoot(desktopFilePath);
                        }
                        else
                        {
                            var potentialDesktopFiles = Directory.GetFiles(desktopDir, "*.desktop")
                                .Where(f => Path.GetFileName(f).Contains(cleanName, StringComparison.OrdinalIgnoreCase))
                                .ToList();

                            foreach (var df in potentialDesktopFiles)
                            {
                                var content = await File.ReadAllLinesAsync(df);
                                if (!content.Any(l =>
                                        l.StartsWith("Exec=") &&
                                        (l.Contains(app.Name + ".AppImage") || l.Contains($"\"{app.Name}.AppImage\""))))
                                    continue;
                                XdgPaths.FixOwnershipIfRoot(df);
                                break;
                            }
                        }
                    }

                    // Fix sin of icon ownership
                    string[] iconDirs =
                    [
                        Path.Combine(userDataHome, "icons/hicolor/scalable/apps"),
                        Path.Combine(userDataHome, "icons/hicolor/256x256/apps")
                    ];

                    foreach (var iconDir in iconDirs)
                    {
                        if (!Directory.Exists(iconDir)) continue;
                        XdgPaths.FixOwnershipIfRoot(iconDir);
                        var potentialIcons = Directory.GetFiles(iconDir, $"{cleanName}.*");
                        foreach (var icon in potentialIcons)
                        {
                            XdgPaths.FixOwnershipIfRoot(icon);
                        }
                    }

                    // Cleanse myself of old sys desktops
                    const string sysDesktopDir = "/usr/share/applications";
                    var sysDesktopFilePath = Path.Combine(sysDesktopDir, $"{cleanName}.desktop");
                    if (File.Exists(sysDesktopFilePath))
                    {
                        try
                        {
                            File.Delete(sysDesktopFilePath);
                            LogMessage($"Removed old system desktop entry: {sysDesktopFilePath}");
                            UpdateDesktopDatabase(sysDesktopDir);
                        }
                        catch (Exception ex)
                        {
                            LogWarning($"Could not remove system desktop entry {sysDesktopFilePath}: {ex.Message}");
                        }
                    }

                    // Cleanse myself of old sys icons
                    if (string.IsNullOrEmpty(app.IconName)) continue;
                    {
                        var extensions = new[] { ".png", ".svg" };
                        foreach (var ext in extensions)
                        {
                            var sysIconDirs = new[]
                            {
                                "/usr/share/icons/hicolor/scalable/apps",
                                "/usr/share/icons/hicolor/256x256/apps"
                            };

                            foreach (var sysIconDir in sysIconDirs)
                            {
                                var sysIconPath = Path.Combine(sysIconDir, $"{app.IconName}{ext}");
                                if (!File.Exists(sysIconPath)) continue;
                                try
                                {
                                    File.Delete(sysIconPath);
                                    LogMessage($"Removed old system icon: {sysIconPath}");
                                    UpdateIconCache(Path.GetDirectoryName(sysIconDir)!);
                                }
                                catch (Exception ex)
                                {
                                    LogWarning($"Could not remove system icon {sysIconPath}: {ex.Message}");
                                }
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    LogWarning($"Error during pre-dedupe cleanup for {app.Name}: {ex.Message}");
                }
            }

            var uniqueItems = appImages
                .GroupBy(item => item.DesktopName, StringComparer.OrdinalIgnoreCase)
                .Select(group => group.Last())
                .Where(newApp =>
                {
                    if (string.IsNullOrEmpty(newApp.DesktopName)) return true;
                    return !existingApps.Any(e =>
                        string.Equals(e.DesktopName, newApp.DesktopName, StringComparison.OrdinalIgnoreCase));
                })
                .ToList();

            foreach (var newApp in uniqueItems.Select(apps => new AppImageDtoV2()
                     {
                         Name = apps.Name,
                         Version = apps.Version,
                         Description = apps.Description,
                         IconName = apps.IconName,
                         UpdateType = apps.UpdateType,
                         AllowPrerelease = false,
                         DesktopName = apps.DesktopName,
                         RawUpdateInfo = apps.RawUpdateInfo,
                         UpdateURl = apps.UpdateURl,
                         RepoOwner = apps.UpdateType switch
                         {
                             UpdateType.GitHub or UpdateType.GitLab or UpdateType.Codeberg or UpdateType.Forgejo
                                 when apps.UpdateURl.Contains('/') => apps.UpdateURl.Split('/')[0],
                             _ => null
                         },
                         RepoName = apps.UpdateType switch
                         {
                             UpdateType.GitHub or UpdateType.GitLab or UpdateType.Codeberg or UpdateType.Forgejo
                                 when apps.UpdateURl.Contains('/') => apps.UpdateURl.Split('/')[1],
                             _ => null
                         },
                         SizeOnDisk = apps.SizeOnDisk,
                         Path = Path.Combine(_installDirectory, $"{apps.Name}.AppImage")
                     }))
            {
                try
                {
                    LogMessage("Migrating AppImage: " + newApp.Name);
                    await AddAppImageToLocalDb(newApp);
                    LogMessage($"Added {newApp.Name} to new metadata database.");

                    await MigrateDesktopEntry(newApp);

                    LogMessage($"Finished migrating {newApp.Name}.");
                }
                catch (Exception ex)
                {
                    LogError($"Error migrating AppImage {newApp.Name}: {ex.Message}");
                }
            }
        }
        catch (Exception ex)
        {
            LogError($"Error reading AppImage local DB: {ex.Message}");
        }

        LogMessage($"Removing legacy metadata database: {localDbDir}");
        File.Delete(localDbDir);

        LogMessage("Fixing ownership of new metadata database...");
        var dbDirectory = Path.GetDirectoryName(LocalDbPath);
        if (!string.IsNullOrEmpty(dbDirectory))
            XdgPaths.FixOwnershipIfRoot(dbDirectory);
        XdgPaths.FixOwnershipIfRoot(LocalDbPath);

        LogMessage("Migration completed successfully.");
        return true;
    }

    private async Task MigrateDesktopEntry(AppImageDtoV2 appImage)
    {
        var cleanName = CleanInvalidNames(appImage.Name);
        var desktopFileName = $"{cleanName}.desktop";
        var newExecPath = Path.Combine(_installDirectory, $"{appImage.Name}.AppImage");

        var desktopDir = Path.Combine(XdgPaths.DataHome(), "applications");
        var desktopFilePath = Path.Combine(desktopDir, desktopFileName);
        if (File.Exists(desktopFilePath))
        {
            try
            {
                LogMessage($"Updating desktop entry: {desktopFilePath}");
                var lines = await File.ReadAllLinesAsync(desktopFilePath);
                var updated = false;
                for (var i = 0; i < lines.Length; i++)
                {
                    if (!lines[i].StartsWith("Exec=")) continue;
                    var currentExec = lines[i]["Exec=".Length..].Trim();

                    if (currentExec.Contains(newExecPath)) continue;
                    var fieldCodes = "";
                    foreach (var token in currentExec.Split(' '))
                    {
                        if (!token.StartsWith('%')) continue;
                        fieldCodes = $" {token}";
                        break;
                    }

                    lines[i] = $"Exec=\"{newExecPath}\"{fieldCodes}";
                    updated = true;
                }

                if (updated)
                {
                    await File.WriteAllLinesAsync(desktopFilePath, lines);
                    LogMessage($"Desktop entry updated with new path.");
                }

                XdgPaths.FixOwnershipIfRoot(desktopFilePath);
                UpdateDesktopDatabase(desktopDir, true);
            }
            catch (Exception ex)
            {
                LogWarning($"Could not migrate desktop entry {desktopFilePath}: {ex.Message}");
            }
        }

        if (!string.IsNullOrEmpty(appImage.IconName))
        {
            foreach (var extension in new[] { ".png", ".svg" })
            {
                var iconSubDir = extension == ".svg" ? "icons/hicolor/scalable/apps" : "icons/hicolor/256x256/apps";
                var baseDir = XdgPaths.DataHome();

                var iconPath = Path.Combine(baseDir, iconSubDir, $"{appImage.IconName}{extension}");
                if (!File.Exists(iconPath)) continue;
                LogMessage($"Fixing ownership of icon: {iconPath}");
                XdgPaths.FixOwnershipIfRoot(iconPath);
                UpdateIconCache(Path.Combine(baseDir, "icons/hicolor"));
            }
        }
    }

    #region Github

    private static async Task<AppImageUpdateDto?> CheckGitHubUpdate(string owner, string repo, string appName,
        string currentVersion, bool allowPrerelease = false)
    {
        try
        {
            var url = GithubToReleasesApi(owner, repo);
            using var client = new HttpClient();
            client.DefaultRequestHeaders.UserAgent.Add(Http.UserAgent);

            var response = await client.GetAsync(url);
            if (!response.IsSuccessStatusCode) return null;

            var json = await response.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            if (root.ValueKind != JsonValueKind.Array || root.GetArrayLength() == 0) return null;

            var release = root.EnumerateArray()
                .FirstOrDefault(r => allowPrerelease || !r.GetProperty("prerelease").GetBoolean());

            if (release.ValueKind == JsonValueKind.Undefined) return null;

            var latestVersion = release.GetProperty("tag_name").GetString() ?? "";

            string? downloadUrl = null;
            if (!release.TryGetProperty("assets", out var assets))
                return new AppImageUpdateDto
                {
                    Name = appName,
                    Version = latestVersion,
                    DownloadUrl = downloadUrl ?? "",
                    IsUpdateAvailable = IsVersionUnknownOrDifferent(currentVersion, latestVersion)
                };

            var appImageAssets = assets.EnumerateArray()
                .Where(asset =>
                    (asset.GetProperty("name").GetString() ?? "").EndsWith(".AppImage",
                        StringComparison.OrdinalIgnoreCase))
                .ToList();

            switch (appImageAssets.Count)
            {
                case 1:
                    downloadUrl = appImageAssets[0].GetProperty("browser_download_url").GetString();
                    break;
                case > 1:
                    downloadUrl = appImageAssets
                        .Where(asset => IsCorrectArchitecture(asset.GetProperty("name").GetString() ?? ""))
                        .Select(asset => asset.GetProperty("browser_download_url").GetString())
                        .FirstOrDefault();

                    downloadUrl ??= appImageAssets[0].GetProperty("browser_download_url").GetString();
                    break;
            }

            return new AppImageUpdateDto
            {
                Name = appName,
                Version = latestVersion,
                DownloadUrl = downloadUrl ?? "",
                IsUpdateAvailable = IsVersionUnknownOrDifferent(currentVersion, latestVersion)
            };
        }
        catch
        {
            return null;
        }
    }

    private static string GithubToReleasesApi(string owner, string repo) =>
        $"https://api.github.com/repos/{owner}/{repo}/releases";

    #endregion

    #region GitLab

    private static async Task<AppImageUpdateDto?> CheckGitLabUpdate(string owner, string repo, string appName,
        string currentVersion, bool allowPrerelease = false)
    {
        try
        {
            var url = GitLabToReleasesApi(owner, repo);
            using var client = new HttpClient();
            client.DefaultRequestHeaders.UserAgent.Add(Http.UserAgent);
            var response = await client.GetAsync(url);
            if (!response.IsSuccessStatusCode) return null;

            var json = await response.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(json);

            if (doc.RootElement.ValueKind != JsonValueKind.Array || doc.RootElement.GetArrayLength() == 0)
                return null;


            var releases = doc.RootElement.EnumerateArray();
            var release = releases.FirstOrDefault(r =>
                allowPrerelease ||
                (!r.TryGetProperty("upcoming_release", out var upcoming) || !upcoming.GetBoolean()));

            if (release.ValueKind == JsonValueKind.Undefined) return null;

            var latestVersion = release.GetProperty("tag_name").GetString() ?? "";

            string? downloadUrl = null;
            if (!release.TryGetProperty("assets", out var assets) || !assets.TryGetProperty("links", out var links))
            {
                return new AppImageUpdateDto
                {
                    Name = appName,
                    Version = latestVersion,
                    DownloadUrl = "",
                    IsUpdateAvailable = IsVersionUnknownOrDifferent(currentVersion, latestVersion)
                };
            }

            var appImageLinks = links.EnumerateArray()
                .Where(link =>
                    (link.GetProperty("name").GetString() ?? "").EndsWith(".AppImage",
                        StringComparison.OrdinalIgnoreCase))
                .ToList();

            switch (appImageLinks.Count)
            {
                case 1:
                    downloadUrl = appImageLinks[0].GetProperty("url").GetString();
                    break;
                case > 1:
                    downloadUrl = appImageLinks
                        .Where(link => IsCorrectArchitecture(link.GetProperty("name").GetString() ?? ""))
                        .Select(link => link.GetProperty("url").GetString())
                        .FirstOrDefault();

                    downloadUrl ??= appImageLinks[0].GetProperty("url").GetString();
                    break;
            }

            return new AppImageUpdateDto
            {
                Name = appName,
                Version = latestVersion,
                DownloadUrl = downloadUrl ?? "",
                IsUpdateAvailable = IsVersionUnknownOrDifferent(currentVersion, latestVersion)
            };
        }
        catch
        {
            return null;
        }
    }

    private static string GitLabToReleasesApi(string owner, string repo)
    {
        var encodedPath = Uri.EscapeDataString($"{owner}/{repo}");
        return $"https://gitlab.com/api/v4/projects/{encodedPath}/releases";
    }

    #endregion

    #region Codeberg / Forgejo

    private static async Task<AppImageUpdateDto?> CheckGiteaUpdate(string owner, string repo, string appName,
        string currentVersion,
        string domain, bool allowPrerelease = false)
    {
        try
        {
            var url = GiteaToReleasesApi(domain, owner, repo);
            using var client = new HttpClient();
            client.DefaultRequestHeaders.UserAgent.Add(Http.UserAgent);
            var response = await client.GetAsync(url);
            if (!response.IsSuccessStatusCode) return null;

            var json = await response.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(json);

            if (doc.RootElement.ValueKind != JsonValueKind.Array || doc.RootElement.GetArrayLength() == 0)
                return null;

            var release = doc.RootElement.EnumerateArray()
                .FirstOrDefault(r => allowPrerelease || !r.GetProperty("prerelease").GetBoolean());

            if (release.ValueKind == JsonValueKind.Undefined) return null;

            var latestVersion = release.GetProperty("tag_name").GetString() ?? "";

            string? downloadUrl = null;
            if (!release.TryGetProperty("assets", out var assets))
                return new AppImageUpdateDto
                {
                    Name = appName,
                    Version = latestVersion,
                    DownloadUrl = downloadUrl ?? "",
                    IsUpdateAvailable = IsVersionUnknownOrDifferent(currentVersion, latestVersion)
                };
            var appImageAssets = assets.EnumerateArray()
                .Where(asset =>
                    (asset.GetProperty("name").GetString() ?? "").EndsWith(".AppImage",
                        StringComparison.OrdinalIgnoreCase))
                .ToList();

            switch (appImageAssets.Count)
            {
                case 1:
                    downloadUrl = appImageAssets[0].GetProperty("browser_download_url").GetString();
                    break;
                case > 1:
                    downloadUrl = appImageAssets
                        .Where(asset => IsCorrectArchitecture(asset.GetProperty("name").GetString() ?? ""))
                        .Select(asset => asset.GetProperty("browser_download_url").GetString())
                        .FirstOrDefault();

                    downloadUrl ??= appImageAssets[0].GetProperty("browser_download_url").GetString();
                    break;
            }

            return new AppImageUpdateDto
            {
                Name = appName,
                Version = latestVersion,
                DownloadUrl = downloadUrl ?? "",
                IsUpdateAvailable = IsVersionUnknownOrDifferent(currentVersion, latestVersion)
            };
        }
        catch
        {
            return null;
        }
    }

    private static string GiteaToReleasesApi(string domain, string owner, string repo)
        => $"https://{domain}/api/v1/repos/{owner}/{repo}/releases";

    private static async Task<AppImageUpdateDto?> CheckCodebergUpdate(string repo, string owner, string appName,
        string currentVersion, bool allowPrerelease = false)
    {
        return await CheckGiteaUpdate(owner, repo, appName, currentVersion, "codeberg.org", allowPrerelease);
    }

    private static async Task<AppImageUpdateDto?> CheckForgejoUpdate(string repo, string appName, string owner,
        string currentVersion, bool allowPrerelease = false)
    {
        var uri = new Uri(repo);
        return await CheckGiteaUpdate(owner, repo, appName, currentVersion, uri.Host, allowPrerelease);
    }

    #endregion
}