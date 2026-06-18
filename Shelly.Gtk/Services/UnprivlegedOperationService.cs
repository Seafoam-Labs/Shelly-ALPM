using System.Diagnostics;
using System.Text;
using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services.TrayServices;
using Shelly.Gtk.Services.Wire;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.AppImage;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Utilities;

// ReSharper disable UnusedParameter.Local
// ReSharper disable AccessToModifiedClosure
// ReSharper disable ConditionalAccessQualifierIsNonNullableAccordingToAPIContract

namespace Shelly.Gtk.Services;

public class UnprivilegedOperationService(
    ITrayDbus trayDbus,
    IPackageUpdateNotifier packageUpdateNotifier,
    IDirtyService dirtyService,
    IAlpmEventService alpmEventService,
    ILockoutService lockoutService,
    IGenericQuestionService genericQuestionService) : IUnprivilegedOperationService
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
            JsonPackFrame.TryDecode<List<FlatpakPackageDto>>(result.Output, out var framed);
            return framed ?? [];
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
            JsonPackFrame.TryDecode<List<FlatpakPackageDto>>(result.Output, out var framed);
            return framed ?? [];
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
                JsonPackFrame.TryDecode<List<AppstreamApp>>(result.Output, out var framed);
                return framed ?? [];
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
            result = await ExecuteUnprivilegedCommandAsync("Install package", "flatpak install", package, "--remote",
                remote,
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

    public async Task<UnprivilegedOperationResult> FlatpakRepair()
    {
        var result = await ExecuteUnprivilegedCommandAsync("Flatpak repair", "flatpak repair");
        return result;
    }

    public async Task<List<FlatpakRemoteDto>> FlatpakListRemotes()
    {
        var result = await ExecuteUnprivilegedCommandAsync("flatpak list remotes", "flatpak list-remotes", "-j");
        if (!result.Success) return [];
        JsonPackFrame.TryDecode<List<FlatpakRemoteDto>>(result.Output, out var framed);
        return framed ?? [];
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
            result = await ExecuteUnprivilegedCommandAsync("Remove Remote", "flatpak install-ref-file", path,
                "--system",
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

    public async Task<FlatpakRemoteRefInfo> GetFlatpakAppDataAsync(string remote, string app, string arch)
    {
        try
        {
            var result =
                await ExecuteUnprivilegedCommandAsync("Sync remote", "flatpak app-remote-info", remote, app, arch,
                    "-j");
            if (!result.Success) return new FlatpakRemoteRefInfo();
            JsonPackFrame.TryDecode<FlatpakRemoteRefInfo>(result.Output, out var framed);
            return framed ?? new FlatpakRemoteRefInfo();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to get remote info: {ex.Message}");
        }

        return new FlatpakRemoteRefInfo();
    }

    public async Task<List<AppImageDto>> GetInstallAppImagesAsync()
    {
        var result = await ExecuteUnprivilegedCommandAsync("Get Installed AppImages", "appimage list --json --ui-mode");
        try
        {
            if (!result.Success || string.IsNullOrEmpty(result.Output)) return [];
            JsonPackFrame.TryDecode<List<AppImageDto>>(result.Output, out var framed);
            return framed ?? [];
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
        var result = await ExecuteUnprivilegedCommandAsync("Fetch Arch News", args);
        if (!result.Success || string.IsNullOrEmpty(result.Output))
        {
            return [];
        }

        try
        {
            JsonPackFrame.TryDecode<List<RssModel>>(result.Output, out var framed);
            return framed ?? [];
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
            JsonPackFrame.TryDecode<List<PacfileRecord>>(result.Output, out var framed);
            return framed ?? [];
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error deserializing Arch News: {ex.Message}");
        }

        return [];
    }

    public Task<OperationResult> AddSystemdServiceTray(string serviceContent, string service)
    {
        var dir = XdgPaths.ConfigHome() + "/systemd/user";
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, $"{service}.service"), serviceContent);

        _ = ExecuteNonShellyUnprivilegedCommandAsync("Systemctl", "systemctl", CancellationToken.None,
            "--user daemon-reload");
        _ = ExecuteNonShellyUnprivilegedCommandAsync("Systemctl", "systemctl", CancellationToken.None,
            $"--user enable --now {service}");

        return Task.FromResult(new OperationResult());
    }

    public Task<OperationResult> RemoveSystemdServiceTray(string service)
    {
        var dir = XdgPaths.ConfigHome() + "/systemd/user";

        _ = ExecuteNonShellyUnprivilegedCommandAsync("Systemctl", "systemctl", CancellationToken.None,
            $"--user disable --now {service}");

        File.Delete($"{dir}/{service}.service");

        _ = ExecuteNonShellyUnprivilegedCommandAsync("Systemctl", "systemctl", CancellationToken.None,
            "--user daemon-reload");

        return Task.FromResult(new OperationResult());
    }


    public async Task<List<AppImageDto>> GetUpdatesAppImagesAsync()
    {
        var result = await ExecuteUnprivilegedCommandAsync("Get AppImage Updates", "appimage list-updates --json --ui-mode");
        try
        {
            JsonPackFrame.TryDecode<List<AppImageDto>>(result.Output, out var framed);
            return framed ?? [];
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
            JsonPackFrame.TryDecode<List<AlpmPackageUpdateDto>>(result.Output, out var framed);
            return framed ?? [];
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
            return await ExecuteUnprivilegedCommandAsync("Export Sync", "export -o", filePath);
        }

        return await ExecuteUnprivilegedCommandAsync("Export Sync", "export -o", filePath, "-a", name);
    }

    public async Task<SyncModel> CheckForApplicationUpdates()
    {
        var result =
            await ExecuteUnprivilegedCommandAsync("Get Available Updates", "check-updates -a -l --json --ui-mode");
        //SendDbusMessage(result);
        try
        {
            if (!result.Success) return new SyncModel();
            JsonPackFrame.TryDecodeLast<SyncModel>(result.Output, out var framed);
            return framed ?? new SyncModel();
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
            JsonPackFrame.TryDecode<List<FlatpakPackageDto>>(result.Output, out var framed);
            return framed ?? [];
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse Flathub search JSON: {ex.Message}");
            return [];
        }
    }

    public async Task<UnprivilegedOperationResult> AppImageInstallAsync(string filePath, string updateUrl = "",
        AppImageUpdateType updateType = AppImageUpdateType.None)
    {
        UnprivilegedOperationResult result;
        if (updateUrl != "" && updateType != AppImageUpdateType.None)
        {
            result = await ExecuteUnprivilegedCommandAsync("Install AppImage", "appimage", "install", "-l",
                $"\"{filePath}\"", "-u",
                updateUrl, "-t", updateType.ToString().ToLowerInvariant(), "-n");
        }
        else
        {
            result = await ExecuteUnprivilegedCommandAsync("Install AppImage", "appimage", "install", "-l",
                $"\"{filePath}\"", "-n");
        }

        if (result.Success) dirtyService.MarkDirty(DirtyScopes.AppImage);
        return result;
    }

    public async Task<UnprivilegedOperationResult> AppImageUpgradeAsync()
    {
        var result = await ExecuteUnprivilegedCommandAsync("Upgrade AppImage's", "appimage", "upgrade", "-n");
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.AppImage);
        return result;
    }

    public async Task<UnprivilegedOperationResult> AppImageRemoveAsync(string name, bool removeConfig = false)
    {
        var args = new List<string> { "appimage", "remove", $"\"{name}\"", "-n" };
        if (removeConfig) args.Add("-c");
        var result = await ExecuteUnprivilegedCommandAsync("Remove AppImage's", [.. args]);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.AppImage);
        return result;
    }

    public async Task<UnprivilegedOperationResult> AppImageConfigureUpdatesAsync(string url, string name,
        AppImageUpdateType updateType, bool allowPrerelease)
    {
        return await ExecuteUnprivilegedCommandAsync("Set AppImage's Update Config", "appimage", "configure-updates",
            $"\"{name}\"", "-u", url, "-t", updateType.ToString().ToLowerInvariant(), allowPrerelease ? "-p" : "");
    }

    public async Task<UnprivilegedOperationResult> AppImageSyncApp(string name)
    {
        return await ExecuteUnprivilegedCommandAsync("Set AppImage's Update Config", "appimage", "sync-meta", name,
            "-n");
    }

    public async Task<UnprivilegedOperationResult> AppImageSyncAll()
    {
        return await ExecuteUnprivilegedCommandAsync("Set AppImage's Update Config", "appimage", "sync-meta");
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
        arguments += " --ui-mode";
        var fullCommand = $"{_cliPath} {arguments}";

        Console.WriteLine($"Executing unprivileged command: {fullCommand}");

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

        var eventRouter = new EventRouter(alpmEventService, lockoutService);

        process.OutputDataReceived += async (sender, e) =>
        {
            if (e.Data == null) return;
            outputBuilder.Append(e.Data).Append('\n');

            if (JsonPackFrame.TryExtractPayload(e.Data, out var b64))
            {
                if (eventRouter.TryDispatch(b64)) return;
                try
                {
                    await QuestionRouter.TryDispatchAsync(b64, async value =>
                    {
                        if (stdinWriter != null)
                        {
                            await stdinWriter.WriteLineAsync(value);
                            await stdinWriter.FlushAsync();
                        }
                    }, genericQuestionService);
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"QuestionRouter error: {ex.Message}");
                }

                return;
            }

            Console.WriteLine(e.Data);
        };

        process.ErrorDataReceived += async (sender, e) =>
        {
            if (e.Data != null)
            {
                // Filter out the password prompt from sudo

                // Check for ALPM question (with Shelly prefix)
                if (e.Data.StartsWith("[ALPM_QUESTION]"))
                {
                    var questionText = e.Data.Substring("[ALPM_QUESTION]".Length);
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

    private async Task<UnprivilegedOperationResult> ExecuteNonShellyUnprivilegedCommandAsync(
        string operationDescription, string command,
        CancellationToken ct, params string[] args)
    {
        var arguments = string.Join(" ", args);

        Console.WriteLine($"Executing unprivileged command: {command}");

        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = command,
                Arguments = arguments,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                CreateNoWindow = true
            }
        };


        try
        {
            process.Start();
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

            var success = process.ExitCode == 0;

            return new UnprivilegedOperationResult
            {
                Success = success,
                Output = "",
                Error = "",
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

    private void SendDbusMessage(UnprivilegedOperationResult result)
    {
        if (result.Success)
        {
            _ = Task.Run(trayDbus.UpdatesMadeInUiAsync);
            packageUpdateNotifier.NotifyPackagesUpdated();
        }
    }
}