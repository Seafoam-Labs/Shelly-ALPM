using System.Collections.Generic;
using System.Threading.Tasks;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;

namespace Shelly.Gtk.Services;

public interface IPrivilegedOperationService
{
    Task<OperationResult> SyncDatabasesAsync();
    Task<List<AlpmPackageDto>> SearchPackagesAsync(string query);
    Task<OperationResult> InstallPackagesAsync(IEnumerable<string> packages);
    Task<OperationResult> InstallLocalPackageAsync(string filePath);
    Task<OperationResult> InstallAppImageAsync(string filePath);
    Task<OperationResult> RemovePackagesAsync(IEnumerable<string> packages, bool isCascade, bool isCleanup);
    Task<OperationResult> UpdatePackagesAsync(IEnumerable<string> packages);
    Task<OperationResult> UpgradeSystemAsync();
    Task<OperationResult> ForceSyncDatabaseAsync();
    Task<OperationResult> RemoveDbLockAsync();
    Task<OperationResult> InstallAurPackagesAsync(IEnumerable<string> packages);
    Task<OperationResult> RemoveAurPackagesAsync(IEnumerable<string> packages);
    Task<OperationResult> UpdateAurPackagesAsync(IEnumerable<string> packages);
    Task<List<PackageBuild>> GetAurPackageBuild(IEnumerable<string> packages);
    Task<List<AlpmPackageUpdateDto>> GetPackagesNeedingUpdateAsync();
    Task<List<AlpmPackageDto>> GetAvailablePackagesAsync();
    Task<List<AlpmPackageDto>> GetInstalledPackagesAsync();
    Task<List<AurPackageDto>> GetAurInstalledPackagesAsync();
    Task<List<AurUpdateDto>> GetAurUpdatePackagesAsync();
    Task<List<AurPackageDto>> SearchAurPackagesAsync(string query);
    Task<bool> IsPackageInstalledOnMachine(string packageName);
}

public class OperationResult
{
    public bool Success { get; init; }
    public string Output { get; init; } = string.Empty;
    public string Error { get; init; } = string.Empty;
    public int ExitCode { get; init; }
}