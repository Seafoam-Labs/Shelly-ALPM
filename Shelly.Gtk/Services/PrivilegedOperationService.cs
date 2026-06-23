using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services.TrayServices;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;

namespace Shelly.Gtk.Services;

public class PrivilegedOperationService(
    IProcessExecutor processExecutor,
    IConfigService configService,
    ITrayDbus trayDbus,
    IPackageUpdateNotifier packageUpdateNotifier,
    IDirtyService dirtyService) : IPrivilegedOperationService
{
    private readonly bool _noConfirm = configService.LoadConfig().NoConfirm;

    public async Task<OperationResult> SyncDatabasesAsync()
    {
        var args = new[] { "sync" };
        return await processExecutor.RunPrivilegedShellyCommandAsync("Synchronize package databases", args);
    }

    public async Task<OperationResult> InstallPackagesAsync(IEnumerable<string> packages, bool upgrade = false)
    {
        var args = new List<string> { "install" };
        args.AddRange(packages);
        if (upgrade) args.Add("-u");
        if (_noConfirm) args.Add("--no-confirm");

        var result = await processExecutor.RunPrivilegedShellyCommandAsync("Install packages", args.ToArray());
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Native);
        return result;
    }

    public async Task<OperationResult> InstallLocalPackageAsync(string filePath)
    {
        var args = new List<string> { "install", $"\"{filePath}\"" };
        if (_noConfirm) args.Add("--no-confirm");

        var result = await processExecutor.RunPrivilegedShellyCommandAsync("Install local package", args.ToArray());
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Native);
        return result;
    }

    public async Task<OperationResult> RemovePackagesAsync(IEnumerable<string> packages, bool isCascade, bool isCleanup,
        bool removeOptionalDeps, bool removePackageFromCache = false)
    {
        var args = new List<string> { "remove" };
        args.AddRange(packages);
        args.Add($"-c={isCascade}");
        if (isCleanup) args.Add("-r");
        if (removeOptionalDeps) args.Add("-o");
        if (_noConfirm) args.Add("--no-confirm");

        var result = await processExecutor.RunPrivilegedShellyCommandAsync("Remove packages", args.ToArray());
        if (result.Success && removePackageFromCache) _ = await RemovePackageCacheAsync(packages);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Native);
        return result;
    }

    public async Task<OperationResult> RemoveLocalPackagesAsync(IEnumerable<string> packages)
    {
        var args = new List<string> { "remove" };
        args.AddRange(packages.Select(p => $"\"{p}\""));
        if (_noConfirm) args.Add("--no-confirm");

        var result = await processExecutor.RunPrivilegedShellyCommandAsync("Remove local packages", args.ToArray());
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Native);
        return result;
    }

    public async Task<OperationResult> UpdatePackagesAsync(IEnumerable<string> packages)
    {
        var args = new List<string> { "update" };
        args.AddRange(packages);
        if (_noConfirm) args.Add("--no-confirm");

        var result = await processExecutor.RunPrivilegedShellyCommandAsync("Update packages", args.ToArray());
        SendDbusMessage(result);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Native);
        return result;
    }

    public async Task<OperationResult> UpgradeSystemAsync()
    {
        var args = new List<string> { "upgrade" };
        if (_noConfirm) args.Add("--no-confirm");

        var result = await processExecutor.RunPrivilegedShellyCommandAsync("Upgrade system", args.ToArray());
        SendDbusMessage(result);
        return result;
    }

    public async Task<OperationResult> UpgradeAllAsync()
    {
        var args = new List<string> { "upgrade-all" };
        if (_noConfirm) args.Add("--no-confirm");

        var result = await processExecutor.RunPrivilegedShellyCommandAsync("Upgrade all", args.ToArray());
        if (!result.Success) _ = Task.Run(trayDbus.UpdatesMadeInUiAsync);
        SendDbusMessage(result);
        return result;
    }

    public async Task<OperationResult> ForceSyncDatabaseAsync()
    {
        var args = new[] { "sync", "--force" };
        return await processExecutor.RunPrivilegedShellyCommandAsync("Force synchronize package databases", args);
    }

    public async Task<OperationResult> RemoveDbLockAsync()
    {
        return await processExecutor.RunPrivilegedSystemCommandAsync(
            "Removing database lock", ["rm", "-f", "/var/lib/pacman/db.lck"]);
    }

    public async Task<OperationResult> InstallAurPackagesAsync(IEnumerable<string> packages, bool useChroot = false,
        bool runChecks = false)
    {
        var args = new List<string> { "aur", "install" };
        args.AddRange(packages);
        if (useChroot) args.Add("-c");
        if (runChecks) args.Add("--check");
        if (_noConfirm) args.Add("--no-confirm");

        var result = await processExecutor.RunPrivilegedShellyCommandAsync("Install AUR packages", args.ToArray());
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Aur);
        return result;
    }

    public async Task<OperationResult> RemoveAurPackagesAsync(IEnumerable<string> packages, bool isCascade = false)
    {
        var args = new List<string> { "aur", "remove" };
        args.AddRange(packages);
        args.Add($"-c={isCascade}");
        if (_noConfirm) args.Add("--no-confirm");

        var result = await processExecutor.RunPrivilegedShellyCommandAsync("Remove AUR packages", args.ToArray());
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Aur);
        return result;
    }

    public async Task<OperationResult> UpdateAurPackagesAsync(IEnumerable<string> packages, bool runChecks = false)
    {
        var args = new List<string> { "aur", "update" };
        args.AddRange(packages);
        if (runChecks) args.Add("--check");
        if (_noConfirm) args.Add("--no-confirm");

        var result = await processExecutor.RunPrivilegedShellyCommandAsync("Update AUR packages", args.ToArray());
        SendDbusMessage(result);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Aur);
        return result;
    }

    public async Task<List<PackageBuild>> GetAurPackageBuild(IEnumerable<string> packages)
    {
        var args = new List<string> { "aur", "search-pkgbuild" };
        args.AddRange(packages);
        if (_noConfirm) args.Add("--no-confirm");

        return await ExecuteJsonCommandAsync<PackageBuild>("AUR package builds",
            () => processExecutor.RunPrivilegedShellyCommandAsync("Get Package Builds", args.ToArray()));
    }

    public async Task<List<AlpmPackageUpdateDto>> GetPackagesNeedingUpdateAsync()
    {
        return await ExecuteJsonCommandAsync<AlpmPackageUpdateDto>("updates",
            () => processExecutor.RunPrivilegedShellyCommandAsync("Check for Updates", ["list-updates"]));
    }

    public async Task<List<AlpmPackageDto>> SearchPackagesAsync(string query)
    {
        return await ExecuteJsonCommandAsync<AlpmPackageDto>("search packages",
            () => processExecutor.RunShellyCommandAsync(["query", "--available", $"\"{query}\"", "--no-confirm"]));
    }

    public async Task<List<AlpmPackageDto>> GetAvailablePackagesAsync(bool showHidden = false)
    {
        var args = new List<string> { "query", "--available" };
        if (showHidden) args.Add("--show-hidden");

        return await ExecuteJsonCommandAsync<AlpmPackageDto>("available packages",
            () => processExecutor.RunShellyCommandAsync(args.ToArray()));
    }

    public async Task<List<AlpmPackageDto>> GetInstalledPackagesAsync(bool showHidden = false)
    {
        var args = new List<string> { "query", "--installed" };
        if (showHidden) args.Add("--show-hidden");

        return await ExecuteJsonCommandAsync<AlpmPackageDto>("installed packages",
            () => processExecutor.RunShellyCommandAsync(args.ToArray()));
    }

    public async Task<List<LocalPackageDto>> GetLocalInstalledPackagesAsync()
    {
        return await ExecuteJsonCommandAsync<LocalPackageDto>("local installed packages",
            () => processExecutor.RunShellyCommandAsync(["query", "--local"]));
    }

    public async Task<List<AurPackageDto>> GetAurInstalledPackagesAsync(bool showHidden = false)
    {
        var args = new List<string> { "aur", "list" };
        if (showHidden) args.Add("--show-hidden");

        return await ExecuteJsonCommandAsync<AurPackageDto>("AUR installed packages",
            () => processExecutor.RunShellyCommandAsync(args.ToArray()));
    }

    public async Task<List<AurUpdateDto>> GetAurUpdatePackagesAsync(bool showHidden = false)
    {
        var args = new List<string> { "aur", "list-updates" };
        if (showHidden) args.Add("--show-hidden");

        return await ExecuteJsonCommandAsync<AurUpdateDto>("AUR updates",
            () => processExecutor.RunShellyCommandAsync(args.ToArray()));
    }

    public async Task<List<AurPackageDto>> SearchAurPackagesAsync(string query)
    {
        return await ExecuteJsonCommandAsync<AurPackageDto>("AUR search",
            () => processExecutor.RunShellyCommandAsync(["aur", "search", query]));
    }

    public async Task<List<DowngradeOptionDto>> GetDowngradeOptionsAsync(string packageName)
    {
        return await ExecuteJsonCommandAsync<DowngradeOptionDto>("downgrade options",
            () => processExecutor.RunShellyCommandAsync(["downgrade", packageName, "--list-options"]));
    }

    public async Task<bool> IsPackageInstalledOnMachine(string packageName)
    {
        var standardPackages = await GetInstalledPackagesAsync();
        return standardPackages.Any(x => x.Name.Contains(packageName));
    }

    public async Task<OperationResult> RunCacheCleanAsync(int keep, bool uninstalledOnly)
    {
        var args = new List<string> { "cache-clean", "-k", keep.ToString() };
        if (uninstalledOnly) args.Add("-i");
        return await processExecutor.RunPrivilegedShellyCommandAsync("Clean package cache", args.ToArray());
    }


    public async Task<OperationResult> PurifyCorruptionAsync()
    {
        var args = new[] { "purify" };
        return await processExecutor.RunPrivilegedShellyCommandAsync("Delete corrupted packages", args);
    }

    public async Task<OperationResult> FixXdgPermissionsAsync()
    {
        var args = new[] { "fix-permissions" };
        return await processExecutor.RunPrivilegedShellyCommandAsync("Fix Shelly folder ownership", args);
    }

    public async Task<OperationResult> FlatpakInstallFromBundle(string path)
    {
        var args = new[] { "flatpak", "install-bundle", path, "--system", "true" };
        var result = await processExecutor.RunPrivilegedShellyCommandAsync("Install Flatpak Bundle", args);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<OperationResult> DowngradePackageAsync(string packageName, string filename, bool addIgnore)
    {
        var args = new List<string> { "downgrade", packageName, "--target", $"\"{filename}\"", "--no-confirm" };
        if (addIgnore) args.Add("--ignore");

        var result = await processExecutor.RunPrivilegedShellyCommandAsync("Downgrade package", args.ToArray());
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.NativeInstalled);
        return result;
    }

    public async Task<OperationResult> MigrateAppImagesAsync()
    {
        var args = new[] { "appimage", "migrate-manager" };
        return await processExecutor.RunPrivilegedShellyCommandAsync("Migrate AppImages", args);
    }

    private static async Task<List<T>> ExecuteJsonCommandAsync<T>(string operationName, Func<Task<OperationResult>> executeCommand)
    {
        var result = await executeCommand();
        if (!result.Success) return [];

        if (JsonPackFrame.TryDecode<List<T>>(result.Output, out var framed) && framed is not null)
            return framed;

        Console.WriteLine($"Failed to decode {operationName}");
        return [];
    }

    private async Task<OperationResult> RemovePackageCacheAsync(IEnumerable<string> packages)
    {
        var targetArgs = packages
            .SelectMany(x => new[] { "-t", x })
            .ToArray();

        string[] args = ["cache-clean", "--no-confirm", .. targetArgs];
        return await processExecutor.RunPrivilegedShellyCommandAsync("Removing package from cache", args);
    }

    private void SendDbusMessage(OperationResult result)
    {
        if (!result.Success) return;
        _ = Task.Run(trayDbus.UpdatesMadeInUiAsync);
        packageUpdateNotifier.NotifyPackagesUpdated();
    }
}