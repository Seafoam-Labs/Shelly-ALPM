using Shelly.Gtk.Enums;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.AppImage;
using Shelly.Gtk.UiModels.PackageManagerObjects;

namespace Shelly.Gtk.Services;

public interface IUnprivilegedOperationService
{
    Task<List<AlpmPackageDto>> SearchPackagesAsync(string query);

    Task<List<AlpmPackageDto>> GetAvailablePackagesAsync(bool showHidden = false);

    Task<List<AlpmPackageDto>> GetInstalledPackagesAsync(bool showHidden = false);

    Task<List<LocalPackageDto>> GetLocalInstalledPackagesAsync();

    Task<List<AurPackageDto>> GetAurInstalledPackagesAsync(bool showHidden = false);

    Task<List<AurUpdateDto>> GetAurUpdatePackagesAsync(bool showHidden = false);

    Task<List<AurPackageDto>> SearchAurPackagesAsync(string query);

    Task<bool> IsPackageInstalledOnMachine(string packageName);

    Task<List<DowngradeOptionDto>> GetDowngradeOptionsAsync(string packageName);

    Task<UnprivilegedOperationResult> RemoveFlatpakPackage(IEnumerable<string> packages);

    Task<UnprivilegedOperationResult> RemoveFlatpakPackage(string package, bool removeConfig);

    Task<List<FlatpakPackageDto>> ListFlatpakPackages();

    Task<List<FlatpakPackageDto>> ListFlatpakUpdates();

    Task<List<AppstreamApp>> ListAppstreamFlatpak();

    Task<UnprivilegedOperationResult> FlatpakUpgrade();

    Task<UnprivilegedOperationResult> FlatpakRepair();

    Task<List<FlatpakRemoteDto>> FlatpakListRemotes();

    Task<UnprivilegedOperationResult> UpdateFlatpakPackage(string package);

    Task<UnprivilegedOperationResult> InstallFlatpakPackage(string package, bool user, string remote,
        string branch, bool isRuntime = false);

    Task<UnprivilegedOperationResult> FlatpakSyncRemoteAppstream();

    Task<UnprivilegedOperationResult> FlatpakRemoveRemote(string remoteName, string scope);

    Task<UnprivilegedOperationResult> FlatpakAddRemote(string remoteName, string scope, string url);

    Task<UnprivilegedOperationResult> RunFlatpakName(string name);

    Task<UnprivilegedOperationResult> FlatpakInsallFromRef(string path, string scope);

    Task<UnprivilegedOperationResult> FlatpakInstallFromBundle(string path);

    Task<SyncModel> CheckForApplicationUpdates();

    Task<List<AlpmPackageUpdateDto>> CheckForStandardApplicationUpdates(bool showHidden = false);

    Task<UnprivilegedOperationResult> ExportSyncFile(string filePath, string name);

    Task<List<FlatpakPackageDto>> SearchFlathubAsync(string query);

    Task<FlatpakRemoteRefInfo> GetFlatpakAppDataAsync(string remote, string app, string arch);

    Task<List<AppImageDto>> GetInstallAppImagesAsync();

    Task<List<AppImageDto>> GetUpdatesAppImagesAsync();

    Task<List<RssModel>> GetArchNewsAsync(bool all = false);

    Task<List<PacfileRecord>> GetPacFiles();

    Task<OperationResult> AddSystemdServiceTray(string serviceContent, string service);

    Task<OperationResult> RemoveSystemdServiceTray(string service);

    Task<UnprivilegedOperationResult> AppImageInstallAsync(string filePath, string updateUrl = "",
        AppImageUpdateType updateType = AppImageUpdateType.None);

    Task<UnprivilegedOperationResult> AppImageUpgradeAsync();

    Task<UnprivilegedOperationResult> AppImageRemoveAsync(string name, bool removeConfig = false);

    Task<UnprivilegedOperationResult> AppImageConfigureUpdatesAsync(string url, string name, AppImageUpdateType updateType,
        bool allowPrerelease);

    Task<UnprivilegedOperationResult> AppImageSyncApp(string name);

    Task<UnprivilegedOperationResult> AppImageSyncAll();
}

public class UnprivilegedOperationResult
{
    public bool Success { get; init; }
    public string Output { get; init; } = string.Empty;
    public string Error { get; init; } = string.Empty;
    public int ExitCode { get; init; }
}