using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using PackageManager.Alpm.Events.EventArgs;

namespace PackageManager.Alpm;

public interface IAlpmManager
{
    event EventHandler<AlpmProgressEventArgs>? Progress;
    event EventHandler<AlpmPackageOperationEventArgs>? PackageOperation;
    event EventHandler<AlpmQuestionEventArgs>? Question;
    event EventHandler<AlpmReplacesEventArgs>? Replaces;

    event EventHandler<AlpmScriptletEventArgs>? ScriptletInfo;
    event EventHandler<AlpmHookEventArgs>? HookRun;

    event EventHandler<AlpmPacnewEventArgs>? PacnewInfo;
    event EventHandler<AlpmPacsaveEventArgs>? PacsaveInfo;

    event EventHandler<AlpmErrorEventArgs>? ErrorEvent;

    void IntializeWithSync();

    void Initialize(bool root = false, int parallelDownloads = 1, bool useTempPath = false, string tempPath = "",
        bool showHiddenPackages = false);

    void Sync(bool force = false);
    List<AlpmPackageDto> GetInstalledPackages();
    List<AlpmPackageDto> GetAvailablePackages();
    List<AlpmPackageUpdateDto> GetPackagesNeedingUpdate();

    Task<bool> InstallPackages(List<string> packageNames,
        AlpmTransFlag flags = AlpmTransFlag.None);

    Task<bool> RemovePackages(List<string> packageNames,
        AlpmTransFlag flags = AlpmTransFlag.None, bool removeOptionalDeps = false);

    Task<bool> UpdatePackages(List<string> packageNames,
        AlpmTransFlag flags = AlpmTransFlag.None);

    Task<bool> SyncSystemUpdate(AlpmTransFlag flags = AlpmTransFlag.None);

    Task<bool> InstallLocalPackage(string path, AlpmTransFlag flags = AlpmTransFlag.None);

    /// <summary>
    /// Raises the Question event from outside the AlpmManager so other layers (e.g., the AUR
    /// package manager) can reuse the existing question/response pipeline (CLI prompts and
    /// Gtk dialogs) without duplicating the event surface.
    /// </summary>
    void RaiseQuestion(AlpmQuestionEventArgs args);

    /// <summary>
    /// This installs the first package that provides a given dependency.
    /// </summary>
    string GetPackageNameFromProvides(string provides, AlpmTransFlag flags = AlpmTransFlag.None);

    /// <summary>
    /// This installs package dependencies only for a given package.
    /// </summary>
    /// <param name="packageName">Name of the package that dependencies are being installed for</param>
    /// <param name="includeMakeDeps"></param>
    /// <param name="flags">Flags that should be used for the installation</param>
    Task<bool> InstallDependenciesOnly(string packageName, bool includeMakeDeps = false,
        AlpmTransFlag flags = AlpmTransFlag.None);

    /// <summary>
    /// Checks if a dependency is satisfied by any installed package, including via "provides" relationships.
    /// </summary>
    /// <param name="dependency">The dependency string to check (e.g., "dotnetsdk", "python>=3.10")</param>
    /// <returns>True if the dependency is satisfied by an installed package, false otherwise</returns>
    bool IsDependencySatisfiedByInstalled(string dependency);

    /// <summary>
    /// Checks if a depdency is satified by any package in the sync db
    /// </summary>
    /// <param name="depdency"></param>
    /// <returns></returns>
    bool IsDepdencySatisfiedBySyncDbs(string depdency);

    /// <summary>
    /// Finds the package name in sync databases that satisfies the given dependency string.
    /// </summary>
    /// <param name="dependency">The dependency string (e.g., "python>=3.10", "libgl")</param>
    /// <returns>The package name that satisfies the dependency, or null if not found</returns>
    string? FindSatisfierInSyncDbs(string dependency);

    void Refresh();

    /// <summary>
    /// Compares two package version strings using libalpm's vercmp.
    /// Returns negative if a &lt; b, 0 if equal, positive if a &gt; b.
    /// </summary>
    static int VersionCompare(string a, string b) => AlpmReference.PkgVerCmp(a, b);

    /// <summary>
    /// Removes corrupted packages from the sync database.
    /// </summary>
    /// <returns>Names of corrupted pkgs removed</returns>
    List<string> RemoveCorruptedPackages(bool dryRun = false);
    
    /// <summary>
    /// Checks if a package is installed
    /// </summary>
    /// <param name="packageName"></param>
    /// <returns></returns>
    bool IsPackageInstalled(string packageName);
    
    
}