using System.Collections.Generic;
using System.Threading.Tasks;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;


namespace Shelly.Gtk.Services;

public interface IUnprivilegedOperationService
{
    Task<UnprivilegedOperationResult> RemoveFlatpakPackage(IEnumerable<string> packages);
    Task<List<FlatpakPackageDto>> ListFlatpakPackages();

    Task<List<FlatpakPackageDto>> ListFlatpakUpdates();

    Task<List<AppstreamApp>> ListAppstreamFlatpak();

    Task<UnprivilegedOperationResult> FlatpakUpgrade();
    
    Task<List<FlatpakRemoteDto>> FlatpakListRemotes();

    Task<UnprivilegedOperationResult> UpdateFlatpakPackage(string package);

    Task<UnprivilegedOperationResult> RemoveFlatpakPackage(string package);

    Task<UnprivilegedOperationResult> InstallFlatpakPackage(string package, bool user,
        string remote, string branch);

    Task<UnprivilegedOperationResult> FlatpakSyncRemoteAppstream();
    
    Task<UnprivilegedOperationResult> FlatpakRemoveRemote(string remoteName, string scope);
    
    Task<UnprivilegedOperationResult> FlatpakAddRemote(string remoteName, string scope, string url);

    Task<SyncModel> CheckForApplicationUpdates();

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