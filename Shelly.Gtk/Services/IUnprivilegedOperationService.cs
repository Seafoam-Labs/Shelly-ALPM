using Shelly.Gtk.UiModels;
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
    
    Task<UnprivilegedOperationResult> FlatpakInsallFromRef(string path, string scope);

    Task<SyncModel> CheckForApplicationUpdates();

    Task<List<AlpmPackageUpdateDto>> CheckForStandardApplicationUpdates();

    Task<UnprivilegedOperationResult> ExportSyncFile(string filePath, string name);

    Task<List<FlatpakPackageDto>> SearchFlathubAsync(string query);
    
    Task<ulong>  GetFlatpakAppDataAsync(string remote, string app, string arch);
}

public class UnprivilegedOperationResult
{
    public bool Success { get; init; }
    public string Output { get; init; } = string.Empty;
    public string Error { get; init; } = string.Empty;
    public int ExitCode { get; init; }
}