using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.AppImage;
using Shelly.Gtk.UiModels.PackageManagerObjects;


namespace Shelly.Gtk.Services;

public interface IUnprivilegedOperationService
{
    Task<UnprivilegedOperationResult> RemoveFlatpakPackage(IEnumerable<string> packages);
    Task<List<FlatpakPackageDto>> ListFlatpakPackages();

    Task<List<FlatpakPackageDto>> ListFlatpakUpdates();

    Task<List<AppstreamApp>> ListAppstreamFlatpak(CancellationToken ct = default);

    Task<UnprivilegedOperationResult> FlatpakUpgrade();

    Task<List<FlatpakRemoteDto>> FlatpakListRemotes();

    Task<UnprivilegedOperationResult> UpdateFlatpakPackage(string package);

    Task<UnprivilegedOperationResult> RemoveFlatpakPackage(string package, bool config);

    Task<UnprivilegedOperationResult> InstallFlatpakPackage(string package, bool user,
        string remote, string branch, bool isRuntime = false);

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

    Task<ulong> GetFlatpakAppDataAsync(string remote, string app, string arch);
    
    Task<List<AppImageDto>> GetInstallAppImagesAsync();
    
    Task<List<AppImageDto>> GetUpdatesAppImagesAsync();
    
    Task<List<RssModel>> GetArchNewsAsync(bool all = false);
    
    Task<List<PacfileRecord>> GetPacFiles();
    
    Task<OperationResult> AddSystemdServiceTray(string serviceContent, string service);
    Task<OperationResult> RemoveSystemdServiceTray(string service);
    
}

public class UnprivilegedOperationResult
{
    public bool Success { get; init; }
    public string Output { get; init; } = string.Empty;
    public string Error { get; init; } = string.Empty;
    public int ExitCode { get; init; }
}