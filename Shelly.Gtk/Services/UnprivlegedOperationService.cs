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
    IProcessExecutor processExecutor,
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
        return await ExecuteJsonCommandAsync<List<FlatpakPackageDto>>("list flatpak packages",
            () => ExecuteUnprivilegedCommandAsync("flatpak", "list"));
    }

    public async Task<List<FlatpakPackageDto>> ListFlatpakUpdates()
    {
        return await ExecuteJsonCommandAsync<List<FlatpakPackageDto>>("list flatpak updates",
            () => ExecuteUnprivilegedCommandAsync("flatpak", "list-updates"));
    }

    public async Task<List<AppstreamApp>> ListAppstreamFlatpak()
    {
        return await ExecuteJsonCommandAsync<List<AppstreamApp>>("list flatpak appstream",
            () => ExecuteUnprivilegedCommandAsync("flatpak", "get-remote-appstream", "all"));
    }

    public async Task<UnprivilegedOperationResult> UpdateFlatpakPackage(string package)
    {
        var result = await ExecuteUnprivilegedCommandAsync("flatpak", "update", package);
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
            result = await ExecuteUnprivilegedCommandAsync("flatpak", "uninstall", package, "-c");
        else
            result = await ExecuteUnprivilegedCommandAsync("flatpak", "uninstall", package);

        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> InstallFlatpakPackage(string package, bool user, string remote,
        string branch, bool isRuntime = false)
    {
        UnprivilegedOperationResult result;
        if (user)
            result = await ExecuteUnprivilegedCommandAsync("flatpak", "install", package, "--user", "--remote", remote, "--branch", branch,
                isRuntime ? "--runtime" : "");
        else
            result = await ExecuteUnprivilegedCommandAsync("flatpak", "install", package, "--remote", remote, "--branch", branch,
                isRuntime ? "--runtime" : "");

        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> FlatpakUpgrade()
    {
        var result = await ExecuteUnprivilegedCommandAsync("flatpak", "upgrade");
        SendDbusMessage(result);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> FlatpakRepair()
    {
        return await ExecuteUnprivilegedCommandAsync("flatpak", "repair");
    }

    public async Task<List<FlatpakRemoteDto>> FlatpakListRemotes()
    {
        return await ExecuteJsonCommandAsync<List<FlatpakRemoteDto>>("list flatpak remotes",
            () => ExecuteUnprivilegedCommandAsync("flatpak", "list-remotes"));
    }

    public async Task<UnprivilegedOperationResult> FlatpakSyncRemoteAppstream()
    {
        return await ExecuteUnprivilegedCommandAsync("flatpak", "sync-remote-appstream");
    }

    public async Task<UnprivilegedOperationResult> FlatpakRemoveRemote(string remoteName, string scope)
    {
        if (scope == "user")
            return await ExecuteUnprivilegedCommandAsync("flatpak", "remove-remotes", remoteName, "--system", "false");

        return await ExecuteUnprivilegedCommandAsync("flatpak", "remove-remotes", remoteName, "--system", "true");
    }

    public async Task<UnprivilegedOperationResult> FlatpakInsallFromRef(string path, string scope)
    {
        UnprivilegedOperationResult result;
        if (scope == "user")
            result = await ExecuteUnprivilegedCommandAsync("flatpak", "install-ref-file", path);
        else
            result = await ExecuteUnprivilegedCommandAsync("flatpak", "install-ref-file", path, "--system", "true");

        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> FlatpakInstallFromBundle(string path)
    {
        var result = await ExecuteUnprivilegedCommandAsync("flatpak", "install-bundle", path, "--user", "false");
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> RunFlatpakName(string name)
    {
        return await ExecuteUnprivilegedCommandAsync("flatpak", "run", name);
    }

    public async Task<UnprivilegedOperationResult> FlatpakAddRemote(string remoteName, string scope, string url)
    {
        if (scope == "user")
            return await ExecuteUnprivilegedCommandAsync("flatpak", "add-remotes", remoteName, "--remote-url", url, "--system", "false");

        return await ExecuteUnprivilegedCommandAsync("flatpak", "add-remotes", remoteName, "--remote-url", url, "--system", "true");
    }

    public async Task<FlatpakRemoteRefInfo> GetFlatpakAppDataAsync(string remote, string app, string arch)
    {
        return await ExecuteJsonCommandAsync<FlatpakRemoteRefInfo>("get flatpak remote info",
            () => ExecuteUnprivilegedCommandAsync("flatpak", "app-remote-info", remote, app, arch));
    }

    public async Task<List<AppImageDto>> GetInstallAppImagesAsync()
    {
        return await ExecuteJsonCommandAsync<List<AppImageDto>>("list appimages",
            () => ExecuteUnprivilegedCommandAsync("appimage", "list"));
    }

    public async Task<List<RssModel>> GetArchNewsAsync(bool all = false)
    {
        var args = all ? "news --all" : "news";
        return await ExecuteJsonCommandAsync<List<RssModel>>("list archnews",
            () => ExecuteUnprivilegedCommandAsync(args));
    }

    public async Task<List<PacfileRecord>> GetPacFiles()
    {
        return await ExecuteJsonCommandAsync<List<PacfileRecord>>("list pacfiles",
            () => ExecuteUnprivilegedCommandAsync("pacfile"));
    }

    public async Task<OperationResult> AddSystemdServiceTray(string serviceContent, string service)
    {
        var dir = $"{XdgPaths.ConfigHome()}/systemd/user";
        Directory.CreateDirectory(dir);
        await File.WriteAllTextAsync(Path.Combine(dir, $"{service}.service"), serviceContent);
        await processExecutor.RunSystemCommandAsync("systemctl", ["--user", "daemon-reload"]);
        await processExecutor.RunSystemCommandAsync("systemctl", ["--user", "enable", "--now", service]);

        return new OperationResult { Success = true };
    }

    public async Task<OperationResult> RemoveSystemdServiceTray(string service)
    {
        var dir = $"{XdgPaths.ConfigHome()}/systemd/user";
        await processExecutor.RunSystemCommandAsync("systemctl", ["--user", "disable", "--now", service]);
        File.Delete($"{dir}/{service}.service");
        await processExecutor.RunSystemCommandAsync("systemctl", ["--user", "daemon-reload"]);

        return new OperationResult { Success = true };
    }

    public async Task<List<AppImageDto>> GetUpdatesAppImagesAsync()
    {
        return await ExecuteJsonCommandAsync<List<AppImageDto>>("list appimage updates",
            () => ExecuteUnprivilegedCommandAsync("appimage", "list-updates"));
    }

    public async Task<List<AlpmPackageUpdateDto>> CheckForStandardApplicationUpdates(bool showHidden = false)
    {
        var args = showHidden ? "list-updates --show-hidden" : "list-updates";
        return await ExecuteJsonCommandAsync<List<AlpmPackageUpdateDto>>("list standard updates",
            () => ExecuteUnprivilegedCommandAsync(args));
    }

    public async Task<UnprivilegedOperationResult> ExportSyncFile(string filePath, string name)
    {
        if (string.IsNullOrWhiteSpace(name))
            return await ExecuteUnprivilegedCommandAsync("export", "-o", filePath);

        return await ExecuteUnprivilegedCommandAsync("export", "-o", filePath, "-a", name);
    }

    public async Task<SyncModel> CheckForApplicationUpdates()
    {
        return await ExecuteJsonCommandAsync<SyncModel>("check application updates",
            () => ExecuteUnprivilegedCommandAsync("check-updates", "-a", "-l"));
    }

    public async Task<List<FlatpakPackageDto>> SearchFlathubAsync(string query)
    {
        return await ExecuteJsonCommandAsync<List<FlatpakPackageDto>>("list flathub search ",
            () => ExecuteUnprivilegedCommandAsync("flatpak", "search", query, "--limit", "100"));
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

    private static async Task<T> ExecuteJsonCommandAsync<T>(
        string operationName,
        Func<Task<UnprivilegedOperationResult>> executeCommand) where T : new()
    {
        var result = await executeCommand();
        if (!result.Success) return new T();

        if (JsonPackFrame.TryDecode<T>(result.Output, out var framed) && framed is not null)
            return framed;

        Console.WriteLine($"Failed to decode {operationName}");
        return new T();
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
}