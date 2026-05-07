using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services.TrayServices;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.AppImage;
using Shelly.Gtk.UiModels.PackageManagerObjects;

// ReSharper disable UnusedParameter.Local
// ReSharper disable AccessToModifiedClosure
// ReSharper disable ConditionalAccessQualifierIsNonNullableAccordingToAPIContract

namespace Shelly.Gtk.Services;

public class UnprivilegedOperationService(ITrayDbus trayDbus, IPackageUpdateNotifier packageUpdateNotifier, IDirtyService dirtyService) : IUnprivilegedOperationService
{
    private readonly string _cliPath = CliPathResolver.FindCliPath();

    public async Task<List<FlatpakPackageDto>> ListFlatpakPackages()
    {
        var result = await ExecuteUnprivilegedCommandAsync("List packages", "flatpak list", "--json");

        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        try
        {
            var lines = result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            foreach (var line in lines)
            {
                var trimmedLine = StripBom(line.Trim());
                if (trimmedLine.StartsWith("[") && trimmedLine.EndsWith("]"))
                {
                    var updates = JsonSerializer.Deserialize(trimmedLine,
                        ShellyGtkJsonContext.Default.ListFlatpakPackageDto);
                    return updates ?? [];
                }
            }

            var allUpdates = JsonSerializer.Deserialize(StripBom(result.Output.Trim()),
                ShellyGtkJsonContext.Default.ListFlatpakPackageDto);
            return allUpdates ?? [];
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse updates JSON: {ex.Message}");
            return [];
        }
    }

    public async Task<List<FlatpakPackageDto>> ListFlatpakUpdates()
    {
        var result = await ExecuteUnprivilegedCommandAsync("List packages", "flatpak list-updates", "--json");

        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        try
        {
            var lines = result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            foreach (var line in lines)
            {
                var trimmedLine = StripBom(line.Trim());
                if (trimmedLine.StartsWith("[") && trimmedLine.EndsWith("]"))
                {
                    var updates = JsonSerializer.Deserialize(trimmedLine,
                        ShellyGtkJsonContext.Default.ListFlatpakPackageDto);
                    return updates ?? [];
                }
            }

            var allUpdates = JsonSerializer.Deserialize(StripBom(result.Output.Trim()),
                ShellyGtkJsonContext.Default.ListFlatpakPackageDto);
            return allUpdates ?? [];
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse updates JSON: {ex.Message}");
            return [];
        }
    }

    public async Task<UnprivilegedOperationResult> RemoveFlatpakPackage(IEnumerable<string> packages)
    {
        // dirty marked in the per-package overload
        var packageArgs = string.Join(" ", packages);
        return await ExecuteUnprivilegedCommandAsync("Remove packages", "flatpak remove", packageArgs);
    }

    public async Task<List<AppstreamApp>> ListAppstreamFlatpak(CancellationToken ct = default)
    {
        var result =
            await ExecuteUnprivilegedCommandAsync("Get local appstream", ct, "flatpak get-remote-appstream", "all",
                "--json");

        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        return await Task.Run(() =>
        {
            try
            {
                var lines = result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
                foreach (var line in lines)
                {
                    var trimmedLine = StripBom(line.Trim());
                    if (trimmedLine.StartsWith("[") && trimmedLine.EndsWith("]"))
                    {
                        var updates = JsonSerializer.Deserialize(trimmedLine,
                            ShellyGtkJsonContext.Default.ListAppstreamApp);
                        return updates ?? [];
                    }
                }

                var allUpdates = JsonSerializer.Deserialize(StripBom(result.Output.Trim()),
                    ShellyGtkJsonContext.Default.ListAppstreamApp);
                return allUpdates ?? [];
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Failed to parse updates JSON: {ex.Message}");
                return [];
            }
        }, ct);
    }


    public async Task<UnprivilegedOperationResult> UpdateFlatpakPackage(string package)
    {
        var result = await ExecuteUnprivilegedCommandAsync("Update package", "flatpak update", package);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> RemoveFlatpakPackage(string package, bool removeConfig)
    {
        UnprivilegedOperationResult result;
        if (removeConfig)
        {
            result = await ExecuteUnprivilegedCommandAsync("Remove package", "flatpak uninstall", package, "-c");
        }
        else
        {
            result = await ExecuteUnprivilegedCommandAsync("Remove package", "flatpak uninstall", package);
        }
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> InstallFlatpakPackage(string package, bool user, string remote,
        string branch, bool isRuntime = false)
    {
        UnprivilegedOperationResult result;
        if (user)
        {
            result = await ExecuteUnprivilegedCommandAsync("Install package", "flatpak install", package, "--user",
                "--remote", remote, "--branch", branch, isRuntime ? "--runtime" : "");
        }
        else
        {
            result = await ExecuteUnprivilegedCommandAsync("Install package", "flatpak install", package, "--remote", remote,
                "--branch", branch, isRuntime ? "--runtime" : "");
        }
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> FlatpakUpgrade()
    {
        var result = await ExecuteUnprivilegedCommandAsync("Upgrade flatpak", "flatpak upgrade");
        SendDbusMessage(result);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<List<FlatpakRemoteDto>> FlatpakListRemotes()
    {
        var result = await ExecuteUnprivilegedCommandAsync("flatpak list remotes", "flatpak list-remotes", "-j");
        var json = StripBom(result.Output.Trim());
        return JsonSerializer.Deserialize<List<FlatpakRemoteDto>>(json,
            ShellyGtkJsonContext.Default.ListFlatpakRemoteDto) ?? [];
    }

    public async Task<UnprivilegedOperationResult> FlatpakSyncRemoteAppstream()
    {
        return await ExecuteUnprivilegedCommandAsync("Sync remote", "flatpak sync-remote-appstream");
    }

    public async Task<UnprivilegedOperationResult> FlatpakRemoveRemote(string remoteName, string scope)
    {
        if (scope == "user")
        {
            return await ExecuteUnprivilegedCommandAsync("Remove Remote", "flatpak remove-remotes", remoteName,
                "--system", "false");
        }

        return await ExecuteUnprivilegedCommandAsync("Remove Remote", "flatpak remove-remotes", remoteName, "--system",
            "true");
    }

    public async Task<UnprivilegedOperationResult> FlatpakInsallFromRef(string path, string scope)
    {
        UnprivilegedOperationResult result;
        if (scope == "user")
        {
            result = await ExecuteUnprivilegedCommandAsync("Remove Remote", "flatpak install-ref-file", path);
        }
        else
        {
            result = await ExecuteUnprivilegedCommandAsync("Remove Remote", "flatpak install-ref-file", path, "--system",
                "true");
        }
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> FlatpakInstallFromBundle(string path)
    {
        var result = await ExecuteUnprivilegedCommandAsync("Install Flatpak Bundle", "flatpak install-bundle", path,
            "--user",
            "false");
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> RunFlatpakName(string name)
    {
        return await ExecuteUnprivilegedCommandAsync("Remove Remote", "flatpak run", name);
    }

    public async Task<UnprivilegedOperationResult> FlatpakAddRemote(string remoteName, string scope, string url)
    {
        if (scope == "user")
        {
            return await ExecuteUnprivilegedCommandAsync("Remove Remote", "flatpak add-remotes", remoteName,
                "--remote-url", url, "--system", "false");
        }

        return await ExecuteUnprivilegedCommandAsync("Remove Remote", "flatpak add-remotes", remoteName, "--remote-url",
            url, "--system", "true");
    }

    public async Task<ulong> GetFlatpakAppDataAsync(string remote, string app, string arch)
    {
        try
        {
            var result =
                await ExecuteUnprivilegedCommandAsync("Sync remote", "flatpak app-remote-info", remote, app, arch,
                    "-j");
            var json = StripBom(result.Output.Trim());
            var remoteInfo =
                JsonSerializer.Deserialize<FlatpakRemoteRefInfo>(json,
                    ShellyGtkJsonContext.Default.FlatpakRemoteRefInfo);
            return remoteInfo!.DownloadSize;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to get remote info: {ex.Message}");
        }

        return 0;
    }

    public async Task<List<AppImageDto>> GetInstallAppImagesAsync()
    {
        var result = await ExecuteUnprivilegedCommandAsync("Get Installed AppImages", "appimage list --json");
        try
        {
            var lines = result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            foreach (var line in lines)
            {
                var trimmedLine = StripBom(line.Trim());
                if (trimmedLine.StartsWith("[") && trimmedLine.EndsWith("]"))
                {
                    var apps = JsonSerializer.Deserialize(trimmedLine,
                        ShellyGtkJsonContext.Default.ListAppImageDto);
                    return apps ?? [];
                }
            }

            return [];
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse installed AppImages JSON: {ex.Message}");
            return [];
        }
    }

    public async Task<List<RssModel>> GetArchNewsAsync(bool all = false)
    {
        var args = all ? "news" + " --json" + " --all" : "news" + " --json";
        var result = await ExecuteUnprivilegedCommandAsync("Fetch Arch News", args, "--ui-mode");
        if (!result.Success || string.IsNullOrEmpty(result.Output))
        {
            return [];
        }

        try
        {
            var lines = result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            foreach (var line in lines)
            {
                var trimmedLine = StripBom(line.Trim());
                if (trimmedLine.StartsWith("[") && trimmedLine.EndsWith("]"))
                {
                    var apps = JsonSerializer.Deserialize(trimmedLine,
                        ShellyGtkJsonContext.Default.ListRssModel);
                    return apps ?? [];
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error deserializing Arch News: {ex.Message}");
        }

        return [];
    }

    public async Task<List<PacfileRecord>> GetPacFiles()
    {
         var result = await ExecuteUnprivilegedCommandAsync("Fetch Pac files", "pacfile --json");
        if (!result.Success || string.IsNullOrEmpty(result.Output))
        {
            return [];
        }

        try
        {
            var lines = result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            foreach (var line in lines)
            {
                var trimmedLine = StripBom(line.Trim());
                if (trimmedLine.StartsWith("[") && trimmedLine.EndsWith("]"))
                {
                    var pacFiles = JsonSerializer.Deserialize(trimmedLine,
                        ShellyGtkJsonContext.Default.ListPacfileRecord);
                    return pacFiles ?? [];
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error deserializing Arch News: {ex.Message}");
        }

        return [];
    }


    public async Task<List<AppImageDto>> GetUpdatesAppImagesAsync()
    {
        var result = await ExecuteUnprivilegedCommandAsync("Get AppImage Updates", "appimage list-updates --json");
        try
        {
            var lines = result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            foreach (var line in lines)
            {
                var trimmedLine = StripBom(line.Trim());
                if (trimmedLine.StartsWith("[") && trimmedLine.EndsWith("]"))
                {
                    var updates = JsonSerializer.Deserialize(trimmedLine,
                        ShellyGtkJsonContext.Default.ListAppImageUpdateDto);
                    return updates?.Select(u => new AppImageDto
                    {
                        Name = u.Name,
                        Version = u.Version,
                        UpdateVersion = u.Version,
                        UpdateURl = u.DownloadUrl,
                        UpdateType = AppImageUpdateType.StaticUrl // Default or map if possible
                    }).ToList() ?? [];
                }
            }

            return [];
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse AppImage updates JSON: {ex.Message}");
            return [];
        }
    }

    public async Task<List<AlpmPackageUpdateDto>> CheckForStandardApplicationUpdates(bool showHidden = false)
    {
        var args = showHidden ? "list-updates --json --show-hidden" : "list-updates --json";
        var result = await ExecuteUnprivilegedCommandAsync("Get Available Updates", args);

        try
        {
            var lines = result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            foreach (var line in lines)
            {
                var trimmedLine = StripBom(line.Trim());
                if (trimmedLine.StartsWith("{") && trimmedLine.EndsWith("}"))
                {
                    var updates =
                        JsonSerializer.Deserialize(trimmedLine,
                            ShellyGtkJsonContext.Default.ListAlpmPackageUpdateDto);
                    return updates ?? [];
                }
            }

            var allUpdates = JsonSerializer.Deserialize(StripBom(result.Output.Trim()),
                ShellyGtkJsonContext.Default.ListAlpmPackageUpdateDto);
            return allUpdates ?? [];
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse updates JSON: {ex.Message}");
            return [];
        }
    }

    public async Task<UnprivilegedOperationResult> ExportSyncFile(string filePath, string name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return await ExecuteUnprivilegedCommandAsync("Export Sync", "utility export -o", filePath);
        }

        return await ExecuteUnprivilegedCommandAsync("Export Sync", "utility export -o", filePath, "-n", name);
    }

    public async Task<SyncModel> CheckForApplicationUpdates()
    {
        var result = await ExecuteUnprivilegedCommandAsync("Get Available Updates", "utility updates -a -l --json");
        //SendDbusMessage(result);
        try
        {
            var lines = result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            foreach (var line in lines)
            {
                var trimmedLine = StripBom(line.Trim());
                if (trimmedLine.StartsWith("{") && trimmedLine.EndsWith("}"))
                {
                    var updates =
                        JsonSerializer.Deserialize(trimmedLine,
                            ShellyGtkJsonContext.Default.SyncModel);
                    return updates ?? new SyncModel();
                }
            }

            var allUpdates = JsonSerializer.Deserialize(StripBom(result.Output.Trim()),
                ShellyGtkJsonContext.Default.SyncModel);
            return allUpdates ?? new SyncModel();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse updates JSON: {ex.Message}");
            return new SyncModel();
        }
    }

    public async Task<List<FlatpakPackageDto>> SearchFlathubAsync(string query)
    {
        var result =
            await ExecuteUnprivilegedCommandAsync("Search Flathub", "flatpak search", query, "--json", "--limit",
                "100");

        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        try
        {
            var trimmedOutput = StripBom(result.Output.Trim());

            if (trimmedOutput.StartsWith("{"))
            {
                var response = JsonSerializer.Deserialize(trimmedOutput,
                    ShellyGtkJsonContext.Default.FlathubSearchResponse);

                if (response?.Hits == null) return [];

                return response.Hits.Select(hit => new FlatpakPackageDto
                {
                    Id = hit.AppId ?? hit.Id ?? string.Empty,
                    Name = hit.Name ?? string.Empty,
                    Summary = hit.Summary ?? string.Empty,
                    Description = hit.Description ?? string.Empty,
                    IconPath = hit.Icon
                }).ToList();
            }

            return [];
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse Flathub search JSON: {ex.Message}");
            return [];
        }
    }

    private async Task<UnprivilegedOperationResult> ExecuteUnprivilegedCommandAsync(string operationDescription,
        params string[] args)
    {
        return await ExecuteUnprivilegedCommandAsync(operationDescription, CancellationToken.None, args);
    }

    private async Task<UnprivilegedOperationResult> ExecuteUnprivilegedCommandAsync(string operationDescription,
        CancellationToken ct, params string[] args)
    {
        var arguments = string.Join(" ", args);
        var fullCommand = $"{_cliPath} {arguments}";

        Console.WriteLine($"Executing privileged command: {fullCommand}");

        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = _cliPath,
                Arguments = arguments,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                CreateNoWindow = true
            }
        };

        var outputBuilder = new StringBuilder();
        var errorBuilder = new StringBuilder();
        StreamWriter? stdinWriter = null;

        process.OutputDataReceived += (sender, e) =>
        {
            if (e.Data != null)
            {
                outputBuilder.AppendLine(e.Data);
                Console.WriteLine(e.Data);
            }
        };

        process.ErrorDataReceived += async (sender, e) =>
        {
            if (e.Data != null)
            {
                // Filter out the password prompt from sudo

                // Check for ALPM question (with Shelly prefix)
                if (e.Data.StartsWith("[Shelly][ALPM_QUESTION]"))
                {
                    var questionText = e.Data.Substring("[Shelly][ALPM_QUESTION]".Length);
                    Console.Error.WriteLine($"[Shelly]Question received: {questionText}");

                    // Send response to CLI via stdin
                    if (stdinWriter != null)
                    {
                        //await stdinWriter.WriteLineAsync(response ? "y" : "n");
                        await stdinWriter.WriteLineAsync("y");
                        await stdinWriter.FlushAsync();
                    }
                }
                else
                {
                    errorBuilder.AppendLine(e.Data);
                    Console.Error.WriteLine(e.Data);
                }
            }
        };

        try
        {
            process.Start();
            stdinWriter = process.StandardInput;
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            try
            {
                await process.WaitForExitAsync(ct);
            }
            catch (OperationCanceledException)
            {
                if (!process.HasExited)
                    process.Kill(true);
                throw;
            }

            // Close stdin after process exits
            stdinWriter?.Close();

            var success = process.ExitCode == 0;

            return new UnprivilegedOperationResult
            {
                Success = success,
                Output = outputBuilder.ToString(),
                Error = errorBuilder.ToString(),
                ExitCode = process.ExitCode
            };
        }
        catch (Exception ex)
        {
            return new UnprivilegedOperationResult
            {
                Success = false,
                Output = string.Empty,
                Error = ex.Message,
                ExitCode = -1
            };
        }
    }

    private static string StripBom(string input)
    {
        if (string.IsNullOrEmpty(input))
            return input;

        // UTF-8 BOM is 0xEF 0xBB 0xBF which appears as \uFEFF in .NET strings
        return input.TrimStart('\uFEFF');
    }

    private void SendDbusMessage(UnprivilegedOperationResult result)
    {
        if (result.Success)
        {
            _ = Task.Run(trayDbus.UpdatesMadeInUiAsync);
            packageUpdateNotifier.NotifyPackagesUpdated();
        }
    }
}