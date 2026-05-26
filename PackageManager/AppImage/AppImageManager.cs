using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using PackageManager.AppImage.Events.EventArgs;
using PackageManager.Utilities;
using Shelly.Utilities;

namespace PackageManager.AppImage;

public class AppImageManager
{
    private const string InstallDirectory = "/opt/shelly";

    public event EventHandler<AppImageErrorEventArgs>? ErrorEvent;
    public event EventHandler<AppImageMessageEventArgs>? MessageEvent;

    private void LogMessage(string message)
    {
        //Console.WriteLine(message);
        MessageEvent?.Invoke(this, new AppImageMessageEventArgs(message));
    }

    private void LogError(string error)
    {
        //Console.Error.WriteLine($"Error: {error}");
        ErrorEvent?.Invoke(this, new AppImageErrorEventArgs(error));
    }

    private void LogWarning(string message)
    {
        //Console.WriteLine($"Warning: {message}");
        MessageEvent?.Invoke(this, new AppImageMessageEventArgs($"Warning: {message}"));
    }

    public async Task<int> InstallAppImage(string location, string? updateUrlOverride = null)
    {
        var filePath = Path.GetFullPath(location);
        var appName = Path.GetFileNameWithoutExtension(filePath);
        var destAppImagePath = Path.Combine(InstallDirectory, $"{appName}.AppImage");
        
        if(!Directory.Exists(InstallDirectory))
            Directory.CreateDirectory(InstallDirectory);
        
        LogMessage($"Installing AppImage {appName}...");
        File.Copy(filePath, destAppImagePath, true);
        SetFilePermissions(destAppImagePath, "a+x");

        var appImageDto = await ExtractMetadata(destAppImagePath);
        if (appImageDto == null)
        {
            LogError("Failed to extract metadata during installation.");
            return 1;
        }

        if (!string.IsNullOrEmpty(updateUrlOverride))
        {
            UpdateFromUrl(appImageDto, updateUrlOverride);
        }

        await AddAppImageToLocalDb(appImageDto);

        return 0;
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

    public async Task<int> RemoveAppImage(string appImagePath)
    {
        var appName = Path.GetFileNameWithoutExtension(appImagePath);
        var cleanName = CleanInvalidNames(appName);
        var userDataHome = XdgPaths.DataHome();
        string[] desktopDirs = ["/usr/share/applications", Path.Combine(userDataHome, "applications")];

        try
        {
            await RemoveAppImageFromLocalDb(new AppImageDto { Name = appName });

            if (File.Exists(appImagePath))
            {
                File.Delete(appImagePath);
                LogMessage($"Removed AppImage: {appImagePath}");
            }

            foreach (var desktopDir in desktopDirs)
            {
                if (!Directory.Exists(desktopDir)) continue;

                var desktopFilePath = Path.Combine(desktopDir, $"{cleanName}.desktop");
                if (File.Exists(desktopFilePath))
                {
                    File.Delete(desktopFilePath);
                    LogMessage($"Removed desktop entry: {desktopFilePath}");
                    UpdateDesktopDatabase(desktopDir);
                }
                else
                {
                    var potentialDesktopFiles = Directory.GetFiles(desktopDir, "*.desktop")
                        .Where(f => Path.GetFileName(f).Contains(cleanName, StringComparison.OrdinalIgnoreCase))
                        .ToList();

                    foreach (var df in potentialDesktopFiles)
                    {
                        var content = await File.ReadAllLinesAsync(df);
                        if (!content.Any(l => l.StartsWith("Exec=") && (l.Contains(appImagePath) || l.Contains($"\"{appImagePath}\"")))) continue;
                        File.Delete(df);
                        LogMessage($"Removed desktop entry: {df}");
                        UpdateDesktopDatabase(desktopDir);
                        break;
                    }
                }
            }

            string[] iconDirs =
            [
                "/usr/share/icons/hicolor/scalable/apps",
                "/usr/share/icons/hicolor/256x256/apps",
                Path.Combine(userDataHome, "icons/hicolor/scalable/apps"),
                Path.Combine(userDataHome, "icons/hicolor/256x256/apps")
            ];

            foreach (var iconDir in iconDirs)
            {
                if (!Directory.Exists(iconDir)) continue;
                
                var potentialIcons = Directory.GetFiles(iconDir, $"{cleanName}.*");
                foreach (var icon in potentialIcons)
                {
                    File.Delete(icon);
                    LogMessage($"Removed icon: {icon}");
                }
            }
        }
        catch (Exception ex)
        {
            LogError($"Error during removal: {ex.Message}");
            return 1;
        }

        return 0;
    }

    public async Task<int> RunUpdate(AppImageUpdateDto update)
    {
        var appImages = await GetAppImagesFromLocalDb();
        var appImage = appImages.FirstOrDefault(a => string.Equals(a.Name, update.Name, StringComparison.OrdinalIgnoreCase));
        if (appImage == null)
        {
            LogError($"AppImage '{update.Name}' not found in local database.");
            return 1;
        }

        if (string.IsNullOrEmpty(update.DownloadUrl))
        {
            LogError($"No download URL found for {update.Name}.");
            return 1;
        }

        var currentPath = Path.Combine(InstallDirectory, $"{appImage.Name}.AppImage");
        if (!File.Exists(currentPath))
        {
            LogError($"Current AppImage not found at {currentPath}.");
            return 1;
        }

        var backupDir = XdgPaths.ShellyCache(update.Name);
        Directory.CreateDirectory(backupDir);
        var backupPath = Path.Combine(backupDir, $"{appImage.Name}-{appImage.Version}.AppImage.bak");
        var downloadPath = currentPath + ".rep";

        try
        {
            if (!Directory.Exists(backupDir)) Directory.CreateDirectory(backupDir);

            LogMessage($"Downloading update for {update.Name}...");
            using (var client = new HttpClient())
            {
                client.DefaultRequestHeaders.UserAgent.Add(Http.UserAgent);
                var response = await client.GetAsync(update.DownloadUrl);
                response.EnsureSuccessStatusCode();
                await using var fs = new FileStream(downloadPath, FileMode.Create, FileAccess.Write, FileShare.None);
                await response.Content.CopyToAsync(fs);
            }

            SetFilePermissions(downloadPath, "a+x");

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
                return 1;
            }

            appImage.Version = update.Version;
            appImage.UpdateVersion = update.Version;
            await AddAppImageToLocalDb(appImage);

            return 0;
        }
        catch (Exception ex)
        {
            LogError($"Error during update: {ex.Message}");
            if (File.Exists(downloadPath)) File.Delete(downloadPath);
            if (File.Exists(backupPath) && !File.Exists(currentPath))
            {
                File.Copy(backupPath, currentPath);
            }

            return 1;
        }
    }

    public async Task<List<AppImageUpdateDto>> CheckForAppImageUpdates()
    {
        var appImages = await GetAppImagesFromLocalDb();
        var updates = new List<AppImageUpdateDto>();

        foreach (var appImage in appImages)
        {
            var update = await CheckUpdate(appImage);
            if (update is { IsUpdateAvailable: true })
            {
                updates.Add(update);
            }
        }

        return updates;
    }

    public async Task<bool> AppImageConfigureUpdates(string url, string name, UpdateType updateType)
    {
        LogMessage($"Configuring updates for {name} {url}, type: {updateType}...");
        var appImages = await GetAppImagesFromLocalDb();
        var appImage = appImages.FirstOrDefault(a => string.Equals(a.Name, name, StringComparison.OrdinalIgnoreCase));
        if (appImage == null) return false;

        appImage.UpdateURl = url;
        appImage.UpdateType = updateType;
        appImage.UpdateVersion = await CheckUpdate(appImage).ContinueWith(t => t.Result?.Version) ?? "";

        return await AddAppImageToLocalDb(appImage);
    }

    public async Task<AppImageUpdateDto?> CheckUpdate(AppImageDto appImage)
    {
        return appImage.UpdateType switch
        {
            UpdateType.GitHub => await CheckGitHubUpdate(appImage.UpdateURl, appImage.Name, appImage.UpdateVersion),
            UpdateType.GitLab => await CheckGitLabUpdate(appImage.UpdateURl, appImage.Name, appImage.UpdateVersion),
            UpdateType.Codeberg => await CheckCodebergUpdate(appImage.UpdateURl, appImage.Name, appImage.UpdateVersion),
            UpdateType.Forgejo => await CheckForgejoUpdate(appImage.UpdateURl, appImage.Name, appImage.UpdateVersion),
            UpdateType.StaticUrl => await CheckStaticUrlUpdate(appImage.UpdateURl, appImage.Name,
                appImage.UpdateVersion),
            _ => null
        };
    }

    #region Github

    private static string GithubToReleasesApi(string url)
    {
        if (url.Contains("github.com") && !url.Contains("api.github.com"))
        {
            url = url.Replace("https://github.com/", "https://api.github.com/repos/");
        }

        url = url.TrimEnd('/');

        if (url.EndsWith("/releases"))
            return url;

        if (!url.Contains("/releases"))
            return url + "/releases";

        return url;
    }

    private static async Task<AppImageUpdateDto?> CheckGitHubUpdate(string repo, string appName, string currentVersion)
    {
        try
        {
            var url = GithubToReleasesApi(repo);
            using var client = new HttpClient();
            client.DefaultRequestHeaders.UserAgent.Add(Http.UserAgent);
            var response = await client.GetAsync(url + "/latest");
            if (!response.IsSuccessStatusCode) return null;

            var json = await response.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var latestVersion = root.GetProperty("tag_name").GetString() ?? "";

            string? downloadUrl = null;
            if (root.TryGetProperty("assets", out var assets))
            {
                foreach (var asset in assets.EnumerateArray())
                {
                    var assetName = asset.GetProperty("name").GetString() ?? "";
                    if (assetName.EndsWith(".AppImage", StringComparison.OrdinalIgnoreCase))
                    {
                        downloadUrl = asset.GetProperty("browser_download_url").GetString();
                        break;
                    }
                }
            }

            return new AppImageUpdateDto
            {
                Name = appName,
                Version = latestVersion,
                DownloadUrl = downloadUrl ?? "",
                IsUpdateAvailable = latestVersion != currentVersion
            };
        }
        catch
        {
            return null;
        }
    }

    #endregion

    #region GitLab

    private static string GitLabToReleasesApi(string url)
    {
        if (url.Contains("gitlab.com") && !url.Contains("/api/v4/projects/"))
        {
            var uri = new Uri(url);
            var path = uri.AbsolutePath.Trim('/');
            if (path.EndsWith("/-/releases")) path = path.Substring(0, path.Length - 11);

            var encodedPath = Uri.EscapeDataString(path);
            url = $"https://gitlab.com/api/v4/projects/{encodedPath}/releases/permalink/latest";
        }

        return url;
    }

    private static async Task<AppImageUpdateDto?> CheckGitLabUpdate(string repo, string appName, string currentVersion)
    {
        try
        {
            var url = GitLabToReleasesApi(repo);
            using var client = new HttpClient();
            client.DefaultRequestHeaders.UserAgent.Add(Http.UserAgent);
            var response = await client.GetAsync(url);
            if (!response.IsSuccessStatusCode) return null;

            var json = await response.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var latestVersion = root.GetProperty("tag_name").GetString() ?? "";

            string? downloadUrl = null;
            if (root.TryGetProperty("assets", out var assets))
            {
                if (assets.TryGetProperty("links", out var links))
                {
                    foreach (var link in links.EnumerateArray())
                    {
                        var linkName = link.GetProperty("name").GetString() ?? "";
                        if (linkName.EndsWith(".AppImage", StringComparison.OrdinalIgnoreCase))
                        {
                            downloadUrl = link.GetProperty("url").GetString();
                            break;
                        }
                    }
                }
            }

            return new AppImageUpdateDto
            {
                Name = appName,
                Version = latestVersion,
                DownloadUrl = downloadUrl ?? "",
                IsUpdateAvailable = latestVersion != currentVersion
            };
        }
        catch
        {
            return null;
        }
    }

    #endregion

    #region Codeberg / Forgejo

    private static string GiteaToReleasesApi(string url, string domain)
    {
        if (url.Contains(domain) && !url.Contains("/api/v1/repos/"))
        {
            var uri = new Uri(url);
            var path = uri.AbsolutePath.Trim('/');
            if (path.EndsWith("/releases")) path = path.Substring(0, path.Length - 9);

            url = $"https://{domain}/api/v1/repos/{path}/releases/latest";
        }

        return url;
    }

    private static async Task<AppImageUpdateDto?> CheckGiteaUpdate(string repo, string appName, string currentVersion,
        string domain)
    {
        try
        {
            var url = GiteaToReleasesApi(repo, domain);
            using var client = new HttpClient();
            client.DefaultRequestHeaders.UserAgent.Add(Http.UserAgent);
            var response = await client.GetAsync(url);
            if (!response.IsSuccessStatusCode) return null;

            var json = await response.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var latestVersion = root.GetProperty("tag_name").GetString() ?? "";

            string? downloadUrl = null;
            if (root.TryGetProperty("assets", out var assets))
            {
                foreach (var asset in assets.EnumerateArray())
                {
                    var assetName = asset.GetProperty("name").GetString() ?? "";
                    if (assetName.EndsWith(".AppImage", StringComparison.OrdinalIgnoreCase))
                    {
                        downloadUrl = asset.GetProperty("browser_download_url").GetString();
                        break;
                    }
                }
            }

            return new AppImageUpdateDto
            {
                Name = appName,
                Version = latestVersion,
                DownloadUrl = downloadUrl ?? "",
                IsUpdateAvailable = latestVersion != currentVersion
            };
        }
        catch
        {
            return null;
        }
    }

    private static async Task<AppImageUpdateDto?> CheckCodebergUpdate(string repo, string appName,
        string currentVersion)
    {
        return await CheckGiteaUpdate(repo, appName, currentVersion, "codeberg.org");
    }

    private static async Task<AppImageUpdateDto?> CheckForgejoUpdate(string repo, string appName, string currentVersion)
    {
        var uri = new Uri(repo);
        return await CheckGiteaUpdate(repo, appName, currentVersion, uri.Host);
    }

    #endregion

    public async Task<bool> SyncAppImageMeta(List<string> appImageNames)
    {
        try
        {
            var appImagesInDb = await GetAppImagesFromLocalDb();
            var success = true;

            foreach (var appName in appImageNames)
            {
                var appImagePath = Path.Combine(InstallDirectory, $"{appName}.AppImage");
                if (!File.Exists(appImagePath))
                {
                    LogWarning($"AppImage not found at {appImagePath}");
                    success = false;
                    continue;
                }

                LogMessage($"Syncing metadata for {appName}...");
                var appImageDto = await ExtractMetadata(appImagePath);
                if (appImageDto == null)
                {
                    LogError($"Failed to extract metadata for {appName}");
                    success = false;
                    continue;
                }

                var existing = appImagesInDb.FirstOrDefault(a => string.Equals(a.Name, appName, StringComparison.OrdinalIgnoreCase));
                if (existing != null)
                {
                    if (!string.IsNullOrEmpty(existing.UpdateURl))
                    {
                        appImageDto.UpdateURl = existing.UpdateURl;
                        appImageDto.UpdateType = existing.UpdateType;
                    }

                    if (!string.IsNullOrEmpty(existing.RawUpdateInfo) && string.IsNullOrEmpty(appImageDto.RawUpdateInfo))
                    {
                        appImageDto.RawUpdateInfo = existing.RawUpdateInfo;
                    }

                    if (!string.IsNullOrEmpty(existing.UpdateVersion))
                    {
                        appImageDto.UpdateVersion = existing.UpdateVersion;
                    }
                }
                else
                {
                    if (!string.IsNullOrEmpty(appImageDto.RawUpdateInfo) && string.IsNullOrEmpty(appImageDto.UpdateURl))
                    {
                        appImageDto.UpdateType = UpdateType.StaticUrl;
                    }
                }

                await AddAppImageToLocalDb(appImageDto);
            }

            return success;
        }
        catch (Exception ex)
        {
            LogError($"Error syncing AppImage metadata: {ex.Message}");
            return false;
        }
    }

    private async Task<AppImageDto?> ExtractMetadata(string filePath)
    {
        var appName = Path.GetFileNameWithoutExtension(filePath);
        var workingDir = Path.Combine(Path.GetTempPath(), "Shelly", $"sync-{appName}");
        var appImageVersion = "Unknown";
        var desktopName = "";
        var destIconName = "";
        var description = "";

        try
        {
            if (Directory.Exists(workingDir)) Directory.Delete(workingDir, true);
            Directory.CreateDirectory(workingDir);

            SetFilePermissions(filePath, "a+x");

            var squashfsRoot = Path.Combine(workingDir, "squashfs-root");

            try
            {
                var extractProcess = Process.Start(new ProcessStartInfo
                {
                    FileName = filePath,
                    Arguments = "--appimage-extract",
                    WorkingDirectory = workingDir,
                    RedirectStandardOutput = false,
                    RedirectStandardError = false,
                    UseShellExecute = false,
                    CreateNoWindow = true
                });
                await extractProcess!.WaitForExitAsync();
            }
            catch (Exception ex)
            {
                LogWarning($"Could not execute AppImage directly: {ex.Message}.");
                return null;
            }

            var desktopFile = Directory.GetFiles(squashfsRoot, "*.desktop", SearchOption.TopDirectoryOnly).FirstOrDefault();
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
                var systemIconDir = Path.Combine("/usr/share", iconSubDir);
                var userIconDir = Path.Combine(XdgPaths.DataHome(), iconSubDir);

                destIconName = $"{CleanInvalidNames(appName).ToLower()}{extension}";

                foreach (var iconDir in new[] { systemIconDir, userIconDir })
                {
                    try
                    {
                        Directory.CreateDirectory(iconDir);
                        var destIconPath = Path.Combine(iconDir, destIconName);
                        File.Copy(iconPath, destIconPath, true);
                        finalIconPath = CleanInvalidNames(appName).ToLower();
                        LogMessage($"Updated icon: {destIconPath}");
                    }
                    catch (Exception ex)
                    {
                        LogWarning($"Could not copy icon to {iconDir}: {ex.Message}");
                    }
                }

                foreach (var themeDir in new[] { "/usr/share/icons/hicolor", Path.Combine(XdgPaths.DataHome(), "icons/hicolor") })
                {
                    if (Directory.Exists(themeDir))
                        UpdateIconCache(themeDir);
                }
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
                                break;
                            }
                            patchedContent.AppendLine($"Exec=\"{filePath}\"{fieldCodes}");
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

                    var cleanName = CleanInvalidNames(appName);
                    var desktopFileName = $"{cleanName}.desktop";
                    var desktopContent = patchedContent.ToString();

                    foreach (var desktopDir in new[] { "/usr/share/applications", Path.Combine(XdgPaths.DataHome(), "applications") })
                    {
                        try
                        {
                            Directory.CreateDirectory(desktopDir);
                            var desktopFilePath = Path.Combine(desktopDir, desktopFileName);
                            await File.WriteAllTextAsync(desktopFilePath, desktopContent);
                            SetFilePermissions(desktopFilePath, "644");
                            UpdateDesktopDatabase(desktopDir);
                            LogMessage($"Updated desktop entry: {desktopFilePath}");
                        }
                        catch (Exception ex)
                        {
                            LogWarning($"Could not update desktop entry in {desktopDir}: {ex.Message}");
                        }
                    }
                }
                catch (Exception ex)
                {
                    LogWarning($"Could not update any desktop entry: {ex.Message}");
                    CreateDesktopEntry(appName, filePath, icon: finalIconPath);
                }
            }
            else
            {
                LogMessage($"No desktop file found in AppImage, creating default one.");
                CreateDesktopEntry(appName, filePath, icon: finalIconPath);
            }

            var updateInfo = await GetAppImageUpdateInfo(filePath);

            var appImageDto = new AppImageDto
            {
                Name = appName,
                Version = appImageVersion,
                RawUpdateInfo = updateInfo,
                IconName = Path.GetFileNameWithoutExtension(destIconName),
                Description = description,
                DesktopName = string.IsNullOrEmpty(desktopName) ? appName : desktopName,
                SizeOnDisk = new FileInfo(filePath).Length,
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
            catch { /* ignore */ }
        }
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
            //Console.WriteLine($"Version: {version}, Current: {currentVersion}, App: {appName}, URL: {url}");

            return new AppImageUpdateDto
            {
                Name = appName,
                Version = version,
                DownloadUrl = url,
                IsUpdateAvailable = version != currentVersion
            };
        }
        catch
        {
            return null;
        }
    }

    public static Task<bool> IsAppImage(string filePath)
    {
        var extension = Path.GetExtension(filePath);
        return Task.FromResult(string.Equals(extension, ".AppImage", StringComparison.OrdinalIgnoreCase));
    }

    private static List<string> SafeGetFiles(string rootDir, string searchPattern)
    {
        var results = new List<string>();
        try
        {
            results.AddRange(Directory.GetFiles(rootDir, searchPattern, SearchOption.TopDirectoryOnly));
        }
        catch { /* ignore access errors */ }

        try
        {
            foreach (var dir in Directory.GetDirectories(rootDir))
            {
                var dirInfo = new DirectoryInfo(dir);
                if (dirInfo.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
                results.AddRange(SafeGetFiles(dir, searchPattern));
            }
        }
        catch { /* ignore access errors */ }

        return results;
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

        foreach (var desktopDir in new[] { "/usr/share/applications", Path.Combine(XdgPaths.DataHome(), "applications") })
        {
            try
            {
                Directory.CreateDirectory(desktopDir);
                var desktopFilePath = Path.Combine(desktopDir, desktopFileName);
                File.WriteAllText(desktopFilePath, content.ToString());
                SetFilePermissions(desktopFilePath, "644");
                UpdateDesktopDatabase(desktopDir);

                LogMessage($"Desktop entry created: {desktopFilePath}");
            }
            catch (Exception ex)
            {
                LogWarning($"Could not create desktop entry in {desktopDir}: {ex.Message}");
            }
        }
    }

    private void UpdateFromUrl(AppImageDto appImage, string url)
    {
        var uri = new Uri(url);
        var host = uri.Host.ToLower();
        var path = uri.AbsolutePath.Trim('/');

        if (host.Contains("github.com"))
        {
            appImage.UpdateType = UpdateType.GitHub;
            var parts = path.Split('/');
            if (parts.Length >= 2)
            {
                appImage.UpdateURl = $"{parts[0]}/{parts[1]}";
            }
        }
        else if (host.Contains("gitlab.com"))
        {
            appImage.UpdateType = UpdateType.GitLab;
            var parts = path.Split('/');
            if (parts.Length >= 2)
            {
                appImage.UpdateURl = $"{parts[0]}/{parts[1]}";
            }
        }
        else if (host.Contains("codeberg.org"))
        {
            appImage.UpdateType = UpdateType.Codeberg;
            var parts = path.Split('/');
            if (parts.Length >= 2)
            {
                appImage.UpdateURl = $"{parts[0]}/{parts[1]}";
            }
        }
        else
        {
            appImage.UpdateType = UpdateType.StaticUrl;
            appImage.UpdateURl = url;
        }
    }

    private static string CleanInvalidNames(string name)
    {
        return name.ToLower()
            .Replace(" ", "-")
            .Replace("/", "-")
            .Replace("\\", "-");
    }

    private void UpdateDesktopDatabase(string desktopDir)
    {
        try
        {
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

    private static string GetUserHomePath() => XdgPaths.InvokingUserHome();

    private static readonly string LocalDbPath = XdgPaths.ShellyCache("appimage-local-meta-store", "appimage-metadata.db");

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

    private async Task<bool> AddAppImageToLocalDb(AppImageDto appImage)
    {
        try
        {
            var appImages = await GetAppImagesFromLocalDb();
            if (appImages.Any(a => string.Equals(a.Name, appImage.Name, StringComparison.OrdinalIgnoreCase)))
            {
                appImages.RemoveAll(a => string.Equals(a.Name, appImage.Name, StringComparison.OrdinalIgnoreCase));
            }

            appImages.Add(appImage);

            await EnsureDbDirectoryExists();
            var json = JsonSerializer.Serialize(appImages, AppImageJsonContext.Default.ListAppImageDto);
            await File.WriteAllTextAsync(LocalDbPath, json);
            return true;
        }
        catch (Exception ex)
        {
            LogError($"Error adding AppImage to local DB: {ex.Message}");
            return false;
        }
    }

    private async Task<bool> RemoveAppImageFromLocalDb(AppImageDto appImage)
    {
        try
        {
            var appImages = await GetAppImagesFromLocalDb();
            var initialCount = appImages.Count;
            appImages.RemoveAll(a => string.Equals(a.Name, appImage.Name, StringComparison.OrdinalIgnoreCase));

            if (appImages.Count != initialCount)
            {
                await EnsureDbDirectoryExists();
                var json = JsonSerializer.Serialize(appImages, AppImageJsonContext.Default.ListAppImageDto);
                await File.WriteAllTextAsync(LocalDbPath, json);
            }

            return true;
        }
        catch (Exception ex)
        {
            LogError($"Error removing AppImage from local DB: {ex.Message}");
            return false;
        }
    }

    public async Task<List<AppImageDto>> GetAppImagesFromLocalDb()
    {
        try
        {
            if (!File.Exists(LocalDbPath))
            {
                return new List<AppImageDto>();
            }

            var json = await File.ReadAllTextAsync(LocalDbPath);
            return JsonSerializer.Deserialize(json, AppImageJsonContext.Default.ListAppImageDto) ??
                   [];
        }
        catch (Exception ex)
        {
            LogError($"Error reading AppImage local DB: {ex.Message}");
            return [];
        }
    }
}