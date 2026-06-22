using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services.TrayServices;
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
    public async Task<List<FlatpakPackageDto>> ListFlatpakPackages()
    {
        return await ExecuteJsonCommandAsync<List<FlatpakPackageDto>>("list flatpak packages",
            () => RunShellyCommandAsync("flatpak", "list"));
    }

    public async Task<List<FlatpakPackageDto>> ListFlatpakUpdates()
    {
        return await ExecuteJsonCommandAsync<List<FlatpakPackageDto>>("list flatpak updates",
            () => RunShellyCommandAsync("flatpak", "list-updates"));
    }

    public async Task<List<AppstreamApp>> ListAppstreamFlatpak()
    {
        return await ExecuteJsonCommandAsync<List<AppstreamApp>>("list flatpak appstream",
            () => RunShellyCommandAsync("flatpak", "get-remote-appstream", "all"));
    }

    public async Task<UnprivilegedOperationResult> UpdateFlatpakPackage(string package)
    {
        var result = await RunShellyCommandAsync("flatpak", "update", package);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> RemoveFlatpakPackage(IEnumerable<string> packages)
    {
        var args = new List<string> { "flatpak", "remove" };
        args.AddRange(packages);
        return await RunShellyCommandAsync([.. args]);
    }

    public async Task<UnprivilegedOperationResult> RemoveFlatpakPackage(string package, bool removeConfig)
    {
        UnprivilegedOperationResult result;
        if (removeConfig)
            result = await RunShellyCommandAsync("flatpak", "uninstall", package, "-c");
        else
            result = await RunShellyCommandAsync("flatpak", "uninstall", package);

        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> InstallFlatpakPackage(string package, bool user, string remote,
        string branch, bool isRuntime = false)
    {
        var args = new List<string> { "flatpak", "install", package, "--remote", remote, "--branch", branch };
        if (user) args.Add("--user");
        if (isRuntime) args.Add("--runtime");

        var result = await RunShellyCommandAsync([.. args]);

        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> FlatpakUpgrade()
    {
        var result = await RunShellyCommandAsync("flatpak", "upgrade");
        SendDbusMessage(result);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> FlatpakRepair()
    {
        return await RunShellyCommandAsync("flatpak", "repair");
    }

    public async Task<List<FlatpakRemoteDto>> FlatpakListRemotes()
    {
        return await ExecuteJsonCommandAsync<List<FlatpakRemoteDto>>("list flatpak remotes",
            () => RunShellyCommandAsync("flatpak", "list-remotes"));
    }

    public async Task<UnprivilegedOperationResult> FlatpakSyncRemoteAppstream()
    {
        return await RunShellyCommandAsync("flatpak", "sync-remote-appstream");
    }

    public async Task<UnprivilegedOperationResult> FlatpakRemoveRemote(string remoteName, string scope)
    {
        if (scope == "user")
            return await RunShellyCommandAsync("flatpak", "remove-remotes", remoteName, "--system", "false");

        return await RunShellyCommandAsync("flatpak", "remove-remotes", remoteName, "--system", "true");
    }

    public async Task<UnprivilegedOperationResult> FlatpakInsallFromRef(string path, string scope)
    {
        UnprivilegedOperationResult result;
        if (scope == "user")
            result = await RunShellyCommandAsync("flatpak", "install-ref-file", path);
        else
            result = await RunShellyCommandAsync("flatpak", "install-ref-file", path, "--system", "true");

        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> FlatpakInstallFromBundle(string path)
    {
        var result = await RunShellyCommandAsync("flatpak", "install-bundle", path, "--user", "false");
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<UnprivilegedOperationResult> RunFlatpakName(string name)
    {
        return await RunShellyCommandAsync("flatpak", "run", name);
    }

    public async Task<UnprivilegedOperationResult> FlatpakAddRemote(string remoteName, string scope, string url)
    {
        if (scope == "user")
            return await RunShellyCommandAsync("flatpak", "add-remotes", remoteName, "--remote-url", url, "--system", "false");

        return await RunShellyCommandAsync("flatpak", "add-remotes", remoteName, "--remote-url", url, "--system", "true");
    }

    public async Task<FlatpakRemoteRefInfo> GetFlatpakAppDataAsync(string remote, string app, string arch)
    {
        return await ExecuteJsonCommandAsync<FlatpakRemoteRefInfo>("get flatpak remote info",
            () => RunShellyCommandAsync("flatpak", "app-remote-info", remote, app, arch));
    }

    public async Task<List<AppImageDto>> GetInstallAppImagesAsync()
    {
        return await ExecuteJsonCommandAsync<List<AppImageDto>>("list appimages",
            () => RunShellyCommandAsync("appimage", "list"));
    }

    public async Task<List<RssModel>> GetArchNewsAsync(bool all = false)
    {
        return await ExecuteJsonCommandAsync<List<RssModel>>("list archnews",
            () => all
                ? RunShellyCommandAsync("news", "--all")
                : RunShellyCommandAsync("news"));
    }

    public async Task<List<PacfileRecord>> GetPacFiles()
    {
        return await ExecuteJsonCommandAsync<List<PacfileRecord>>("list pacfiles",
            () => RunShellyCommandAsync("pacfile"));
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
            () => RunShellyCommandAsync("appimage", "list-updates"));
    }

    public async Task<List<AlpmPackageUpdateDto>> CheckForStandardApplicationUpdates(bool showHidden = false)
    {
        return await ExecuteJsonCommandAsync<List<AlpmPackageUpdateDto>>("list standard updates",
            () => showHidden
                ? RunShellyCommandAsync("list-updates", "--show-hidden")
                : RunShellyCommandAsync("list-updates"));
    }

    public async Task<UnprivilegedOperationResult> ExportSyncFile(string filePath, string name)
    {
        if (string.IsNullOrWhiteSpace(name))
            return await RunShellyCommandAsync("export", "-o", filePath);

        return await RunShellyCommandAsync("export", "-o", filePath, "-a", name);
    }

    public async Task<SyncModel> CheckForApplicationUpdates()
    {
        return await ExecuteJsonCommandAsync<SyncModel>("check application updates",
            () => RunShellyCommandAsync("check-updates", "-a", "-l"));
    }

    public async Task<List<FlatpakPackageDto>> SearchFlathubAsync(string query)
    {
        return await ExecuteJsonCommandAsync<List<FlatpakPackageDto>>("list flathub search ",
            () => RunShellyCommandAsync("flatpak", "search", query, "--limit", "100"));
    }

    public async Task<UnprivilegedOperationResult> AppImageInstallAsync(string filePath, string updateUrl = "",
        AppImageUpdateType updateType = AppImageUpdateType.None)
    {
        var args = new List<string> { "appimage", "install", filePath, "-n" };
        if (updateUrl != "" && updateType != AppImageUpdateType.None)
        {
            args.Add("-u");
            args.Add(updateUrl);
            args.Add("-t");
            args.Add(updateType.ToString().ToLower());
        }

        var result = await RunShellyCommandAsync([.. args]);

        if (result.Success) dirtyService.MarkDirty(DirtyScopes.AppImage);
        return result;
    }

    public async Task<UnprivilegedOperationResult> AppImageUpgradeAsync()
    {
        var result = await RunShellyCommandAsync("appimage", "upgrade", "-n");
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.AppImage);
        return result;
    }

    public async Task<UnprivilegedOperationResult> AppImageRemoveAsync(string name, bool removeConfig = false)
    {
        var args = new List<string> { "appimage", "remove", name, "-n" };
        if (removeConfig) args.Add("-c");
        var result = await RunShellyCommandAsync([.. args]);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.AppImage);
        return result;
    }

    public async Task<UnprivilegedOperationResult> AppImageConfigureUpdatesAsync(string url, string name,
        AppImageUpdateType updateType, bool allowPrerelease)
    {
        var args = new List<string> { "appimage", "configure-updates", name, url, updateType.ToString() };
        if (allowPrerelease) args.Add("-p");
        return await RunShellyCommandAsync([.. args]);
    }

    public async Task<UnprivilegedOperationResult> AppImageSyncApp(string name)
    {
        return await RunShellyCommandAsync("appimage", "sync-meta", name, "-n");
    }

    public async Task<UnprivilegedOperationResult> AppImageSyncAll()
    {
        return await RunShellyCommandAsync("appimage", "sync-meta");
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

    private async Task<UnprivilegedOperationResult> RunShellyCommandAsync(params string[] args)
    {
        var result = await processExecutor.RunShellyInteractiveCommandAsync(
            args,
            alpmEventService,
            lockoutService,
            genericQuestionService);

        return new UnprivilegedOperationResult
        {
            Success = result.Success,
            Output = result.Output,
            Error = result.Error,
            ExitCode = result.ExitCode
        };
    }
}