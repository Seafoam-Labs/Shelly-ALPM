using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;

namespace Shelly.Gtk.Services;

public interface IPrivilegedOperationService
{
    Task<OperationResult> SyncDatabasesAsync();
    Task<OperationResult> InstallPackagesAsync(IEnumerable<string> packages, bool upgrade = false);
    Task<OperationResult> InstallLocalPackageAsync(string filePath);

    Task<OperationResult> RemovePackagesAsync(IEnumerable<string> packages, bool isCascade, bool isCleanup, bool removeOptionalDeps,
        bool removePackageFromCache = false);

    Task<OperationResult> RemoveLocalPackagesAsync(IEnumerable<string> packages);
    Task<OperationResult> UpdatePackagesAsync(IEnumerable<string> packages);
    Task<OperationResult> UpgradeSystemAsync();
    Task<OperationResult> UpgradeAllAsync();
    Task<OperationResult> ForceSyncDatabaseAsync();
    Task<OperationResult> RemoveDbLockAsync();

    Task<OperationResult> InstallAurPackagesAsync(IEnumerable<string> packages, bool useChroot = false,
        bool runChecks = false);

    Task<OperationResult> RemoveAurPackagesAsync(IEnumerable<string> packages, bool isCascade = false);
    Task<OperationResult> UpdateAurPackagesAsync(IEnumerable<string> packages, bool runChecks = false);
    Task<List<PackageBuild>> GetAurPackageBuild(IEnumerable<string> packages);
    Task<List<AlpmPackageUpdateDto>> GetPackagesNeedingUpdateAsync();
    Task<OperationResult> RunCacheCleanAsync(int keep, bool uninstalledOnly);
    Task<OperationResult> PurifyCorruptionAsync();
    Task<OperationResult> FixXdgPermissionsAsync();
    Task<OperationResult> FlatpakInstallFromBundle(string path);
    Task<OperationResult> DowngradePackageAsync(string packageName, string filename, bool addIgnore);
    Task<OperationResult> MigrateAppImagesAsync();
}

public class OperationResult
{
    public bool Success { get; init; }
    public string Output { get; init; } = string.Empty;
    public string Error { get; init; } = string.Empty;
    public int ExitCode { get; init; }
    public bool NeedsReboot { get; set; }
    public List<(string Service, string Error)> FailedServiceRestarts { get; set; } = [];
}