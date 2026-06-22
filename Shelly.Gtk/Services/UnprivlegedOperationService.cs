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

namespace Shelly.Gtk.Services;

public class UnprivilegedOperationService(
    ITrayDbus trayDbus,
    IPackageUpdateNotifier packageUpdateNotifier,
    IDirtyService dirtyService,
    IAlpmEventService alpmEventService,
    ILockoutService lockoutService,
    IGenericQuestionService genericQuestionService)
    : IUnprivilegedOperationService
{
    private readonly string _cliPath = CliPathResolver.FindCliPath();

    public async Task<List<FlatpakPackageDto>> ListFlatpakPackages()
    {
        var result = await ExecuteUnprivilegedCommandAsync("flatpak list");

        if (!result.Success) return [];

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
        var result = await ExecuteUnprivilegedCommandAsync("flatpak list-updates");

        if (!result.Success) return [];

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

    public async Task<List<AppstreamApp>> ListAppstreamFlatpak()
    {
        var result = await ExecuteUnprivilegedCommandAsync("flatpak get-remote-appstream", "all");

        if (!result.Success) return [];

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
    }


    public async Task<UnprivilegedOperationResult> UpdateFlatpakPackage(string package)
    {
        var result = await ExecuteUnprivilegedCommandAsync("flatpak update", package);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> RemoveFlatpakPackage(IEnumerable<string> packages)
    {
        var packageArgs = string.Join(" ", packages);
        return await ExecuteUnprivilegedCommandAsync("flatpak remove", packageArgs);
    }

    public async Task<UnprivilegedOperationResult> RemoveFlatpakPackage(string package, bool removeConfig)
    {
        UnprivilegedOperationResult result;
        if (removeConfig)
            result = await ExecuteUnprivilegedCommandAsync("flatpak uninstall", package, "-c");
        else
            result = await ExecuteUnprivilegedCommandAsync("flatpak uninstall", package);

        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> InstallFlatpakPackage(string package, bool user, string remote,
        string branch, bool isRuntime = false)
    {
        UnprivilegedOperationResult result;
        if (user)
            result = await ExecuteUnprivilegedCommandAsync("flatpak install", package, "--user", "--remote", remote, "--branch", branch,
                isRuntime ? "--runtime" : "");
        else
            result = await ExecuteUnprivilegedCommandAsync("flatpak install", package, "--remote", remote, "--branch", branch,
                isRuntime ? "--runtime" : "");

        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> FlatpakUpgrade()
    {
        var result = await ExecuteUnprivilegedCommandAsync("flatpak upgrade");
        SendDbusMessage(result);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> FlatpakRepair()
    {
        var result = await ExecuteUnprivilegedCommandAsync("flatpak repair");
        return result;
    }

    public async Task<List<FlatpakRemoteDto>> FlatpakListRemotes()
    {
        var result = await ExecuteUnprivilegedCommandAsync("flatpak list-remotes");
        if (!result.Success) return [];
        JsonPackFrame.TryDecode<List<FlatpakRemoteDto>>(result.Output, out var framed);
        return framed ?? [];
    }

    public async Task<UnprivilegedOperationResult> FlatpakSyncRemoteAppstream()
    {
        return await ExecuteUnprivilegedCommandAsync("flatpak sync-remote-appstream");
    }

    public async Task<UnprivilegedOperationResult> FlatpakRemoveRemote(string remoteName, string scope)
    {
        if (scope == "user")
            return await ExecuteUnprivilegedCommandAsync("flatpak remove-remotes", remoteName, "--system", "false");

        return await ExecuteUnprivilegedCommandAsync("flatpak remove-remotes", remoteName, "--system", "true");
    }

    public async Task<UnprivilegedOperationResult> FlatpakInsallFromRef(string path, string scope)
    {
        UnprivilegedOperationResult result;
        if (scope == "user")
            result = await ExecuteUnprivilegedCommandAsync("flatpak install-ref-file", path);
        else
            result = await ExecuteUnprivilegedCommandAsync("flatpak install-ref-file", path, "--system", "true");

        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> FlatpakInstallFromBundle(string path)
    {
        var result = await ExecuteUnprivilegedCommandAsync("flatpak install-bundle", path, "--user", "false");
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> RunFlatpakName(string name)
    {
        return await ExecuteUnprivilegedCommandAsync("flatpak run", name);
    }

    public async Task<UnprivilegedOperationResult> FlatpakAddRemote(string remoteName, string scope, string url)
    {
        if (scope == "user")
            return await ExecuteUnprivilegedCommandAsync("flatpak add-remotes", remoteName, "--remote-url", url, "--system", "false");

        return await ExecuteUnprivilegedCommandAsync("flatpak add-remotes", remoteName, "--remote-url", url, "--system", "true");
    }

    public async Task<FlatpakRemoteRefInfo> GetFlatpakAppDataAsync(string remote, string app, string arch)
    {
        try
        {
            var result = await ExecuteUnprivilegedCommandAsync("flatpak app-remote-info", remote, app, arch);
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
        var result = await ExecuteUnprivilegedCommandAsync("appimage list");
        try
        {
            if (!result.Success) return [];
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
        var args = all ? "news --all" : "news";
        var result = await ExecuteUnprivilegedCommandAsync(args);
        if (!result.Success) return [];

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
        var result = await ExecuteUnprivilegedCommandAsync("pacfile");
        if (!result.Success) return [];

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
        var dir = $"{XdgPaths.ConfigHome()}/systemd/user";
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, $"{service}.service"), serviceContent);

        _ = ExecuteNonShellyUnprivilegedCommandAsync("systemctl", "--user daemon-reload");
        _ = ExecuteNonShellyUnprivilegedCommandAsync("systemctl", $"--user enable --now {service}");

        return Task.FromResult(new OperationResult());
    }

    public Task<OperationResult> RemoveSystemdServiceTray(string service)
    {
        var dir = $"{XdgPaths.ConfigHome()}/systemd/user";

        _ = ExecuteNonShellyUnprivilegedCommandAsync("systemctl", $"--user disable --now {service}");

        File.Delete($"{dir}/{service}.service");

        _ = ExecuteNonShellyUnprivilegedCommandAsync("systemctl", "--user daemon-reload");

        return Task.FromResult(new OperationResult());
    }


    public async Task<List<AppImageDto>> GetUpdatesAppImagesAsync()
    {
        var result = await ExecuteUnprivilegedCommandAsync("appimage list-updates");
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
        var args = showHidden ? "list-updates --show-hidden" : "list-updates";
        var result = await ExecuteUnprivilegedCommandAsync(args);

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
            return await ExecuteUnprivilegedCommandAsync("export -o", filePath);

        return await ExecuteUnprivilegedCommandAsync("export -o", filePath, "-a", name);
    }

    public async Task<SyncModel> CheckForApplicationUpdates()
    {
        var result = await ExecuteUnprivilegedCommandAsync("check-updates -a -l");
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
        var result = await ExecuteUnprivilegedCommandAsync("flatpak search", query, "--limit", "100");

        if (!result.Success) return [];

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
            result = await ExecuteUnprivilegedCommandAsync("appimage", "install", $"\"{filePath}\"", "-u", updateUrl, "-t",
                updateType.ToString().ToLower(), "-n");
        else
            result = await ExecuteUnprivilegedCommandAsync("appimage", "install", $"\"{filePath}\"", "-n");

        if (result.Success) dirtyService.MarkDirty(DirtyScopes.AppImage);
        return result;
    }

    public async Task<UnprivilegedOperationResult> AppImageUpgradeAsync()
    {
        var result = await ExecuteUnprivilegedCommandAsync("appimage", "upgrade", "-n");
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.AppImage);
        return result;
    }

    public async Task<UnprivilegedOperationResult> AppImageRemoveAsync(string name, bool removeConfig = false)
    {
        var args = new List<string> { "appimage", "remove", $"\"{name}\"", "-n" };
        if (removeConfig) args.Add("-c");
        var result = await ExecuteUnprivilegedCommandAsync([.. args]);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.AppImage);
        return result;
    }

    public async Task<UnprivilegedOperationResult> AppImageConfigureUpdatesAsync(string url, string name,
        AppImageUpdateType updateType, bool allowPrerelease)
    {
        return await ExecuteUnprivilegedCommandAsync("appimage", "configure-updates", $"\"{name}\"", url, updateType.ToString(),
            allowPrerelease ? "-p" : "");
    }

    public async Task<UnprivilegedOperationResult> AppImageSyncApp(string name)
    {
        return await ExecuteUnprivilegedCommandAsync("appimage", "sync-meta", name, "-n");
    }

    public async Task<UnprivilegedOperationResult> AppImageSyncAll()
    {
        return await ExecuteUnprivilegedCommandAsync("appimage", "sync-meta");
    }

    private void SendDbusMessage(UnprivilegedOperationResult result)
    {
        if (!result.Success) return;
        _ = Task.Run(trayDbus.UpdatesMadeInUiAsync);
        packageUpdateNotifier.NotifyPackagesUpdated();
    }

    private async Task<UnprivilegedOperationResult> ExecuteUnprivilegedCommandAsync(params string[] args)
    {
        var arguments = string.Join(" ", args);
        arguments += " --ui-mode";
        var fullCommand = $"{_cliPath} {arguments}";

        Console.WriteLine($"Executing command: {fullCommand}");

        using var process = new Process();
        process.StartInfo = new ProcessStartInfo(_cliPath)
        {
            Arguments = arguments,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            CreateNoWindow = true
        };

        var outputBuilder = new StringBuilder();
        var errorBuilder = new StringBuilder();
        StreamWriter? stdinWriter = null;

        var eventRouter = new EventRouter(alpmEventService, lockoutService);

        process.OutputDataReceived += async (_, e) =>
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
                    }, genericQuestionService, alpmEventService);
                }
                catch (Exception ex)
                {
                    await Console.Error.WriteLineAsync($"QuestionRouter error: {ex.Message}");
                }

                return;
            }

            Console.WriteLine(e.Data);
        };

        process.ErrorDataReceived += async (_, e) =>
        {
            if (e.Data == null) return;
            errorBuilder.AppendLine(e.Data);
            await Console.Error.WriteLineAsync(e.Data);
        };

        try
        {
            process.Start();
            stdinWriter = process.StandardInput;
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            await process.WaitForExitAsync();
            stdinWriter.Close();

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

    private static async Task<UnprivilegedOperationResult> ExecuteNonShellyUnprivilegedCommandAsync(string command, params string[] args)
    {
        var arguments = string.Join(" ", args);

        Console.WriteLine($"Executing command: {command}");

        using var process = new Process();
        process.StartInfo = new ProcessStartInfo(command)
        {
            Arguments = arguments,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            CreateNoWindow = true
        };

        try
        {
            process.Start();
            await process.WaitForExitAsync();

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
}