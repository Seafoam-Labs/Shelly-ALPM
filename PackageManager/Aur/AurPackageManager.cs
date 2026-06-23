using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using PackageManager.Alpm;
using PackageManager.Alpm.Events.EventArgs;
using PackageManager.Alpm.Questions;
using PackageManager.Alpm.Utilities;
using PackageManager.Aur.Models;
using PackageManager.Utilities;
using PackageManager.Utilities.PkgBuild;
using Shelly.Utilities;

#pragma warning disable CS8618 // Non-nullable field must contain a non-null value when exiting constructor. Consider adding the 'required' modifier or declaring as nullable.

namespace PackageManager.Aur;

public class PkgbuildDiffRequestEventArgs : EventArgs
{
    public required string PackageName { get; init; }
    public required string OldPkgbuild { get; init; }
    public required string NewPkgbuild { get; init; }
    public bool ProceedWithUpdate { get; set; } = true;


    public List<ValidationFinding> Warnings { get; init; } = [];
}

/// <summary>
/// This is a manager for Arch universal repositories. It relies on <see cref="AlpmManager"/> to handle downloading and
/// installation of packages from the Arch User Repository (AUR).
/// </summary>
public sealed class AurPackageManager(string? configPath = null)
    : IAurPackageManager
{
    private AlpmManager _alpm;
    private AurSearchManager _aurSearchManager;
    private readonly HttpClient _httpClient = CreateAurHttpClient();
    private readonly Dictionary<string, string> _pkgbaseCache = new(StringComparer.Ordinal);

    private static HttpClient CreateAurHttpClient()
    {
        var client = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(20),
        };
        client.DefaultRequestHeaders.UserAgent.Add(Http.UserAgent);
        return client;
    }

    private readonly HashSet<string> _currentlyInstallingAurDeps = [];
    private bool _useChroot;
    private bool _noCheck = true;
    private string _chrootPath;
    private readonly VcsInfoStore _vcsInfoStore = new();

    public event EventHandler<PkgbuildDiffRequestEventArgs>? PkgbuildDiffRequest;
    public event EventHandler<AlpmQuestionEventArgs>? Question;
    public event EventHandler<AlpmProgressEventArgs>? Progress;
    public event EventHandler<AlpmScriptletEventArgs>? ScriptletInfo;
    public event EventHandler<AlpmHookEventArgs>? HookRun;
    public event EventHandler<AlpmReplacesEventArgs>? Replaces;
    public event EventHandler<AlpmPacnewEventArgs>? PacnewInfo;
    public event EventHandler<AlpmPacsaveEventArgs>? PacsaveInfo;
    public event EventHandler<AlpmErrorEventArgs>? ErrorEvent;

    public event EventHandler<InformationalEventArgs>? InformationalEvent;

    // Helpers replacing the legacy PackageProgress / BuildOutput public events.
    // PackageProgress -> InformationalEvent (discrete labeled stage with queue counter).
    private void RaisePkgProgress(AlpmEventType eventType, string packageName, int currentIndex, int totalCount,
        string? message = null)
    {
        InformationalEvent?.Invoke(this, new InformationalEventArgs(
            eventType,
            message ?? string.Empty,
            packageName,
            currentIndex,
            totalCount));
    }

    // BuildOutput raw line -> InformationalEvent (AurBuildOutput/AurBuildError) with the line as Message.
    private void RaiseBuildLine(string packageName, string line, bool isError)
    {
        InformationalEvent?.Invoke(this, new InformationalEventArgs(
            isError ? AlpmEventType.AurBuildError : AlpmEventType.AurBuildOutput,
            line,
            packageName));
    }

    // BuildOutput tick with a percent -> Progress (continuous %), carrying makepkg's free-text label.
    private void RaiseBuildProgress(string packageName, int percent, string? progressMessage)
    {
        Progress?.Invoke(this, new AlpmProgressEventArgs(
            AlpmProgressType.MakepkgBuild,
            packageName,
            percent,
            null,
            null,
            progressMessage));
    }

    public async Task Initialize(bool root = false, bool useTempPath = false, bool useChroot = false,
        string chrootPath = "/var/lib/shelly/chroot", string tempPath = "", bool showHiddenPackages = false,
        bool noCheck = true)
    {
        _alpm = configPath is null ? new AlpmManager() : new AlpmManager(configPath);
        _alpm.Initialize(root, useTempPath: useTempPath, tempPath: tempPath, showHiddenPackages: showHiddenPackages);
        _alpm.Question += (_, args) => Question?.Invoke(this, args);
        _alpm.Progress += (_, args) => Progress?.Invoke(this, args);
        _alpm.ScriptletInfo += (_, args) => ScriptletInfo?.Invoke(this, args);
        _alpm.HookRun += (_, args) => HookRun?.Invoke(this, args);
        _alpm.Replaces += (_, args) => Replaces?.Invoke(this, args);
        _alpm.PacnewInfo += (_, args) => PacnewInfo?.Invoke(this, args);
        _alpm.PacsaveInfo += (_, args) => PacsaveInfo?.Invoke(this, args);
        _alpm.ErrorEvent += (_, args) => ErrorEvent?.Invoke(this, args);
        _alpm.InformationalEvent += (_, args) => InformationalEvent?.Invoke(this, args);
        _aurSearchManager = new AurSearchManager(_httpClient);
        _useChroot = useChroot;
        _chrootPath = chrootPath;
        _noCheck = noCheck;
        // Import caches from other AUR helpers (paru, yay) for installed foreign packages
        await ImportOtherAurHelperCaches();
        await _vcsInfoStore.Load();
    }

    public async Task<List<AurPackageDto>> GetInstalledPackages()
    {
        var foreignPackages = _alpm.GetForeignPackages();
        var response = await _aurSearchManager.GetInfoAsync(foreignPackages.Select(x => x.Name).ToList());
        return response.Results;
    }

    public async Task<List<AurPackageDto>> SearchPackages(string query)
    {
        var searchResponse = await _aurSearchManager.SearchAsync(query);
        var results = searchResponse.Results;

        // top 100 sorted by pop to avoid ddos AUR with.
        var topResults = results
            .OrderByDescending(x => x.Popularity)
            .Take(100)
            .ToList();

        if (topResults.Count == 0)
        {
            return [];
        }

        // get meta data for those 100
        var infoResponse = await _aurSearchManager.GetInfoAsync(topResults.Select(x => x.Name));
        return infoResponse.Results;
    }

    public async Task<List<AurUpdateDto>> GetPackagesNeedingUpdate(bool checkDevel = true)
    {
        List<AurUpdateDto> packagesToUpdate = [];
        var packages = _alpm.GetForeignPackages();
        var response = await _aurSearchManager.GetInfoAsync(packages.Select(x => x.Name).ToList());

        var aurUpdateNames = new HashSet<string>();

        foreach (var pkg in response.Results)
        {
            var installedPkg = packages.FirstOrDefault(x => x.Name == pkg.Name);
            if (installedPkg is null)
            {
                continue;
            }

            if (VersionComparer.IsNewer(pkg.Version, installedPkg.Version))
            {
                packagesToUpdate.Add(new AurUpdateDto
                {
                    Name = pkg.Name,
                    Version = installedPkg.Version,
                    NewVersion = pkg.Version,
                    Url = pkg.Url ?? string.Empty,
                    PackageBase = pkg.PackageBase,
                    Description = pkg.Description ?? string.Empty
                });
                aurUpdateNames.Add(pkg.Name);
            }
        }

        if (!checkDevel)
        {
            return packagesToUpdate;
        }

        var vcsPackages = packages.Where(p => IsVcsPackage(p.Name) && !aurUpdateNames.Contains(p.Name)).ToList();
        var semaphore = new SemaphoreSlim(15);
        var vcsResults = await Task.WhenAll(vcsPackages.Select(async installedPkg =>
        {
            await semaphore.WaitAsync();
            try
            {
                var needsUpdate = await CheckVcsPackageNeedsUpdate(installedPkg.Name);
                if (!needsUpdate)
                    return null;

                var aurInfo = response.Results.FirstOrDefault(x => x.Name == installedPkg.Name);
                return new AurUpdateDto
                {
                    Name = installedPkg.Name,
                    Version = installedPkg.Version,
                    NewVersion = "latest-commit",
                    Url = aurInfo?.Url ?? string.Empty,
                    PackageBase = aurInfo?.PackageBase ?? installedPkg.Name,
                    Description = aurInfo?.Description ?? string.Empty
                };
            }
            catch (Exception ex)
            {
                InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.DebugOutput,
                    $"Error checking version for {installedPkg.Name}: {ex.Message}"));
                InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.TraceOutput,
                    ex.StackTrace ?? "No stack trace available"));
                return null;
            }
            finally
            {
                semaphore.Release();
            }
        }));

        packagesToUpdate.AddRange(vcsResults.Where(r => r != null)!);
        return packagesToUpdate;
    }

    public async Task UpdatePackages(List<string> packageNames)
    {
        InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
            $"Updating {packageNames.Count} packages: {string.Join(", ", packageNames)}"));
        await InstallPackages(packageNames);
    }

    public async Task<string?> FetchPkgbuildAsync(string packageName)
    {
        try
        {
            // Resolve pkgname -> pkgbase: split AUR packages live under their pkgbase repo
            var pkgbase = await ResolvePkgbaseAsync(packageName);
            InformationalEvent?.Invoke(this,
                new InformationalEventArgs(AlpmEventType.InformationalOutput,
                    $"Fetching PKGBUILD for {packageName} ({pkgbase})"));
            var url = $"https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h={pkgbase}";
            var response = await _httpClient.GetAsync(url);
            if (response.IsSuccessStatusCode)
            {
                return await response.Content.ReadAsStringAsync();
            }
        }
        catch
        {
            // Ignore errors fetching PKGBUILD
        }

        return null;
    }

    public async Task InstallDependenciesOnly(string packageName, bool includeMakeDeps = false)
    {
        RaisePkgProgress(AlpmEventType.AurDownloadStart, packageName, 1, 1,
            "Downloading PKGBUILD to analyze dependencies");

        var success = await DownloadPackage(packageName);

        if (!success)
        {
            RaisePkgProgress(AlpmEventType.AurPackageFailed, packageName, 1, 1, "Failed to download package");
            return;
        }

        var pkgbase = await ResolvePkgbaseAsync(packageName);
        var tempPath = XdgPaths.ShellyCache(pkgbase);
        var pkgbuildInfo = PkgbuildParser.Parse(Path.Combine(tempPath, "PKGBUILD"));

        var depends = pkgbuildInfo.ParsedDepends;
        var depsToConsider = depends.ToList();

        if (includeMakeDeps)
        {
            var makeDepends = pkgbuildInfo.ParsedMakeDepends.ToList();
            depsToConsider = depsToConsider.Concat(makeDepends).Distinct().ToList();
        }

        var depsToInstall = depsToConsider.Where(x => !_alpm.IsDependencySatisfiedByInstalled(x.ToString())).ToList();

        if (depsToInstall.Count == 0)
        {
            RaisePkgProgress(AlpmEventType.AurPackageCompleted, packageName, 1, 1,
                "All dependencies are already installed");
            return;
        }

        RaisePkgProgress(AlpmEventType.AurInstallStart, packageName, 1, 1,
            $"Installing dependencies: {string.Join(", ", depsToInstall)}");

        var alpmPackages = new List<string>();
        var aurPackages = new List<ParsedDependency>();

        foreach (var dep in depsToInstall)
        {
            var repoName = _alpm.FindSatisfierInSyncDbs(dep.ToString());
            if (repoName != null)
            {
                alpmPackages.Add(repoName);
            }
            else
            {
                aurPackages.Add(dep);
            }
        }

        if (alpmPackages.Count > 0)
        {
            await _alpm.InstallPackages(alpmPackages);
            _alpm.Refresh();
        }

        foreach (var pkg in aurPackages)
        {
            await MakePkgAndInstallAurDependency(pkg);
        }


        RaisePkgProgress(AlpmEventType.AurPackageCompleted, packageName, 1, 1, "Dependencies installed successfully");
    }

    /// <summary>
    /// When true, suppresses the optional-dependency selection prompt for the current
    /// invocation. Used to prevent re-prompting during recursive AUR fallback installs
    /// triggered by previously selected opt-deps.
    /// </summary>
    private bool _skipOptDepsPrompt;

    public async Task InstallPackages(List<string> packageNames)
    {
        // Ensure sync DBs are current before resolving dependencies, so that
        // real repo packages aren't misrouted to the AUR resolver due to a
        // stale sync DB on the alpm handle. See issue #880 follow-up.
        _alpm.Refresh();

        // Per-call map of selected optional dependencies (by top-level package).
        var selectedOptDepsByPkg = new Dictionary<string, List<string>>();

        var totalCount = packageNames.Count;
        for (var i = 0; i < packageNames.Count; i++)
        {
            var packageName = packageNames[i];

            RaisePkgProgress(AlpmEventType.AurDownloadStart, packageName, i + 1, totalCount);

            var proceed = await ShouldProceedWithPkgbuildAsync(packageName);
            if (!proceed) continue;

            var success = await DownloadPackage(packageName);
            if (!success)
            {
                RaisePkgProgress(AlpmEventType.AurPackageFailed, packageName, i + 1, totalCount,
                    "Failed to download package");
                continue;
            }

            // Build the package using makepkg
            var pkgbase = await ResolvePkgbaseAsync(packageName);
            var tempPath = XdgPaths.ShellyCache(pkgbase);
            RaisePkgProgress(AlpmEventType.AurBuildStart, packageName, i + 1, totalCount,
                "Building package with makepkg");
            var pkgbuildInfo = PkgbuildParser.Parse(Path.Combine(tempPath, "PKGBUILD"));

            // Prompt the user for optional dependencies declared in the PKGBUILD. The selected
            // names are installed after the main AUR package is committed (see post-install
            // block). The prompt is suppressed when this call is itself a recursive AUR
            // fallback install triggered by an earlier opt-deps selection.
            if (!_skipOptDepsPrompt)
            {
                List<ProviderOption> optDepends = [];
                foreach (var pkg in pkgbuildInfo.OptDepends)
                {
                    var name = StripDepDecorations(pkg);
                    if (string.IsNullOrEmpty(name)) continue;

                    if (!Regex.IsMatch(name, @"^[a-zA-Z0-9@._+][a-zA-Z0-9@._+\-]*$"))
                    {
                        await Console.Error.WriteLineAsync(
                            $"[Shelly] Ignoring malformed optdepend token from PKGBUILD: '{pkg}' (parsed name='{name}')");
                        continue;
                    }

                    // PKGBUILD optdepends are typically "name: description" — preserve the
                    // description for the UI tooltip/label while keeping Name to the bare
                    // package name so downstream installers can resolve it.
                    var colonIdx = pkg.IndexOf(':');
                    var description = colonIdx >= 0 && colonIdx + 1 < pkg.Length
                        ? pkg[(colonIdx + 1)..].Trim()
                        : string.Empty;
                    if (string.IsNullOrEmpty(description)) description = "No description found";
                    var isPackageInstalled = _alpm.IsPackageInstalled(name);
                    optDepends.Add(new ProviderOption(name, description, isPackageInstalled));
                }

                if (optDepends.Count > 0)
                {
                    var optQuestion = new AlpmQuestionEventArgs(
                        AlpmQuestionType.SelectOptionalDeps,
                        $"Select optional dependencies for {pkgbuildInfo.PkgName}",
                        optDepends);
                    _alpm.RaiseQuestion(optQuestion);
                    optQuestion.WaitForResponse();
                    if (optQuestion.Response.ProviderOptions is not null)
                    {
                        foreach (var optDep in optQuestion.Response.ProviderOptions)
                        {
                            if (optDep is not { IsSelected: true, IsInstalled: false }) continue;
                            if (selectedOptDepsByPkg.ContainsKey(pkgbuildInfo.PkgName!))
                            {
                                selectedOptDepsByPkg[pkgbuildInfo.PkgName!].Add(optDep.Name);
                            }
                            else
                            {
                                selectedOptDepsByPkg.Add(pkgbuildInfo.PkgName!, [optDep.Name]);
                            }
                        }
                    }
                }
            }

            // Track makedepends (and checkdepends) that are not runtime deps and not yet installed
            var runtimeDepNames = pkgbuildInfo.ParsedDepends.Select(d => d.Name).ToHashSet();
            var buildOnlyDeps = pkgbuildInfo.ParsedMakeDepends
                .Concat(_noCheck ? [] : pkgbuildInfo.ParsedCheckDepends)
                .Where(d => !runtimeDepNames.Contains(d.Name))
                .Where(d => !_alpm.IsDependencySatisfiedByInstalled(d.ToString()))
                .Select(d => _alpm.FindSatisfierInSyncDbs(d.ToString()) ?? d.Name)
                .Distinct()
                .ToList();

            var (allRepoPackages, orderedAurPackages) = CollectAllDependencies(pkgbuildInfo);
            InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                $"Collected {allRepoPackages.Count + orderedAurPackages.Count} dependencies for {packageName}"));
            await InstallCollectedDependencies(allRepoPackages, orderedAurPackages, AlpmTransFlag.AllDeps);


            // Backup PKGBUILD to PreviousVersions folder
            var previousVersionsPath = Path.Combine(tempPath, "PreviousVersions");
            var pkgbuildPath = Path.Combine(tempPath, "PKGBUILD");
            if (File.Exists(pkgbuildPath))
            {
                // Create directory as the non-root user to avoid permission issues
                _ = await RunAsInvokingUserAsync("mkdir", ["-p", previousVersionsPath]);

                var existingBackups = Directory.Exists(previousVersionsPath)
                    ? Directory.GetFiles(previousVersionsPath, "PKGBUILD.*")
                    : Array.Empty<string>();
                var nextNumber = existingBackups.Length + 1;
                var backupPath = Path.Combine(previousVersionsPath, $"PKGBUILD.{nextNumber}");

                _ = await RunAsInvokingUserAsync("cp", [pkgbuildPath, backupPath]);
            }

            // Remove any existing package files before building
            foreach (var oldPkgFile in Directory.GetFiles(tempPath, "*.pkg.tar.*"))
            {
                _ = await RunAsInvokingUserAsync("rm", ["-f", oldPkgFile]);
            }

            if (_useChroot)
            {
                EnsureChrootExists();
            }

            var buildProcess = CreateBuildProcess(tempPath);
            buildProcess.OutputDataReceived += (_, e) =>
            {
                if (string.IsNullOrEmpty(e.Data))
                {
                    return;
                }

                int? percent = null;
                string? progressMessage = null;
                if (e.Data.Contains('%'))
                {
                    var match = Regex.Match(e.Data, @"\[\s*(?<percent>\d+)%\]\s+(?<message>.+)");
                    if (match.Success)
                    {
                        percent = int.Parse(match.Groups["percent"].Value);
                        progressMessage = match.Groups["message"].Value;
                    }
                }

                RaiseBuildLine(packageName, e.Data, false);
                if (percent.HasValue) RaiseBuildProgress(packageName, percent.Value, progressMessage);
            };

            buildProcess.ErrorDataReceived += (_, e) =>
            {
                if (string.IsNullOrEmpty(e.Data))
                {
                    return;
                }

                RaiseBuildLine(packageName, e.Data, true);
            };

            buildProcess.Start();
            buildProcess.BeginOutputReadLine();
            buildProcess.BeginErrorReadLine();
            await buildProcess.WaitForExitAsync();

            if (buildProcess.ExitCode != 0)
            {
                RaisePkgProgress(AlpmEventType.AurPackageFailed, packageName, i + 1, totalCount,
                    "Failed to build package with makepkg");
                continue;
            }

            var pkgFile = SelectBuiltPackageFile(tempPath, packageName);
            if (pkgFile is null)
            {
                RaisePkgProgress(AlpmEventType.AurPackageFailed, packageName, i + 1, totalCount,
                    $"No package file matching '{packageName}' produced by makepkg");
                continue;
            }

            // Install using _alpm
            RaisePkgProgress(AlpmEventType.AurInstallStart, packageName, i + 1, totalCount);

            try
            {
                _ = await _alpm.InstallLocalPackage(pkgFile);
                _alpm.Refresh();

                // Update VCS info store with current commit SHAs after successful install
                await UpdateVcsStoreForPackage(packageName, Path.Combine(tempPath, "PKGBUILD"));
            }
            catch (Exception ex)
            {
                RaisePkgProgress(AlpmEventType.AurPackageFailed, packageName, i + 1, totalCount,
                    $"Failed to install package: {ex.Message}");
                continue;
            }

            // Post-install: install any user-selected optional dependencies. Repo-resolvable
            // names go through _alpm.InstallPackages; the rest are attempted as a recursive AUR
            // install (with the prompt suppressed to avoid re-prompting). Truly missing names
            // produce a warning and do NOT fail the main install.
            if (selectedOptDepsByPkg.TryGetValue(packageName, out var optDeps) && optDeps.Count > 0)
            {
                try
                {
                    await InstallSelectedOptDeps(packageName, optDeps);
                }
                catch (Exception ex)
                {
                    RaiseBuildLine(packageName,
                        $"[Shelly] Warning: failed to install some optional dependencies: {ex.Message}", true);
                }
            }

            // Remove build-only dependencies (makedepends/checkdepends) that were installed for this build
            if (buildOnlyDeps.Count > 0)
            {
                RaisePkgProgress(AlpmEventType.AurCleanupStart, packageName, i + 1, totalCount,
                    $"Removing {buildOnlyDeps.Count} build-only dependencies: {string.Join(", ", buildOnlyDeps)}");
                foreach (var dep in buildOnlyDeps)
                {
                    RaiseBuildLine(packageName, $"[Shelly] Removing build-only dependency: {dep}", false);
                }

                try
                {
                    await _alpm.RemovePackages(buildOnlyDeps);
                    _alpm.Refresh();
                }
                catch (Exception ex)
                {
                    RaisePkgProgress(AlpmEventType.AurCleanupStart, packageName, i + 1, totalCount,
                        $"Warning: Failed to remove some build dependencies: {ex.Message}");
                }
            }

            // Clean makepkg build artifacts (src/, pkg/) so a later fresh-clone recovery
            // isn't blocked by root-owned fakeroot-staged trees inside the cache dir.
            // Best-effort; failures are logged but never fail the install.
            await CleanBuildArtifactsAsync(tempPath);
            RaiseBuildLine(packageName, "[Shelly] Cleaned build artifacts (src/, pkg/)", false);

            RaisePkgProgress(AlpmEventType.AurPackageCompleted, packageName, i + 1, totalCount);
        }
    }

    private static readonly char[] _depVersionOps = ['>', '<', '='];

    /// <summary>
    /// Strips a pacman-style optdepends token down to its bare package name. Accepts
    /// inputs of the form <c>name[op version][: description]</c> where <c>op</c> is
    /// one of <c>&gt;=</c>, <c>&lt;=</c>, <c>=</c>, <c>&gt;</c>, <c>&lt;</c>.
    /// </summary>
    private static string StripDepDecorations(string raw)
    {
        if (string.IsNullOrEmpty(raw)) return string.Empty;
        var name = raw.Split(':', 2)[0].Trim();
        var cut = name.IndexOfAny(_depVersionOps);
        if (cut >= 0) name = name[..cut];
        return name.Trim();
    }

    /// <summary>
    /// Splits selected optional-dependency names into (repo-resolvable, AUR-fallback) buckets
    /// using the existing sync-DB lookup. A name that is satisfied by any sync DB (directly or
    /// via provides) is treated as repo; everything else is treated as AUR-fallback.
    /// </summary>
    private (List<string> repo, List<string> aur) PartitionByRepoAvailability(IEnumerable<string> names)
    {
        var repo = new List<string>();
        var aur = new List<string>();
        foreach (var name in names.Distinct())
        {
            if (_alpm.IsDepdencySatisfiedBySyncDbs(name))
            {
                repo.Add(_alpm.FindSatisfierInSyncDbs(name) ?? name);
            }
            else
            {
                aur.Add(name);
            }
        }

        return (repo, aur);
    }

    /// <summary>
    /// Marks the given packages with AlpmPkgReason.Depend in the local DB, mirroring the
    /// post-commit reason loop on the sync install path. Failures are logged but never
    /// propagated.
    /// </summary>
    private void MarkAsDepend(IEnumerable<string> names)
    {
        foreach (var name in names)
        {
            _alpm.MarkPackageAsDepend(name);
        }
    }

    /// <summary>
    /// Installs the user-selected optional dependencies for an AUR package. Repo names go
    /// through the sync install path; AUR-only names are installed via a recursive AUR build
    /// with the opt-deps prompt suppressed. Unresolvable names emit a warning and are skipped.
    /// </summary>
    private async Task InstallSelectedOptDeps(string parentPkg, List<string> selectedNames)
    {
        var cleaned = selectedNames
            .Select(StripDepDecorations)
            .Where(n => !string.IsNullOrEmpty(n))
            .ToList();
        var (repoMatches, aurFallbacks) = PartitionByRepoAvailability(cleaned);

        if (repoMatches.Count > 0)
        {
            RaiseBuildLine(parentPkg,
                $"[Shelly] Installing optional dependencies from repo: {string.Join(", ", repoMatches)}", false);
            try
            {
                await _alpm.InstallPackages(repoMatches);
                _alpm.Refresh();
                MarkAsDepend(repoMatches);
            }
            catch (Exception ex)
            {
                RaiseBuildLine(parentPkg,
                    $"[Shelly] Warning: failed to install repo optional dependencies: {ex.Message}", true);
            }
        }

        if (aurFallbacks.Count > 0)
        {
            var previous = _skipOptDepsPrompt;
            _skipOptDepsPrompt = true;
            try
            {
                foreach (var name in aurFallbacks)
                {
                    // AUR opt-deps frequently refer to *provides* names (e.g.
                    // 'mcpelauncher-msa-ui-qt' is provided by 'mcpelauncher-msa-ui-qt-git').
                    // Resolve the name to one or more real AUR package names before clone.
                    var providers = await _aurSearchManager.FindProvidersAsync(name);

                    string? chosen;
                    if (providers.Count == 0)
                    {
                        ErrorEvent?.Invoke(this, new AlpmErrorEventArgs(
                            $"Optional dependency '{name}' not found in sync DBs or AUR (no provider)."));
                        continue;
                    }

                    if (providers.Count == 1)
                    {
                        chosen = providers[0];
                    }
                    else
                    {
                        List<ProviderOption> availableProviders = [];
                        foreach (var provider in providers)
                        {
                            var isInstalled = _alpm.IsPackageInstalled(provider);
                            availableProviders.Add(new ProviderOption(provider, "No Description", isInstalled));
                        }

                        var qArgs = new AlpmQuestionEventArgs(
                            AlpmQuestionType.SelectProvider,
                            $"Multiple AUR providers for '{name}'",
                            availableProviders,
                            name);
                        _alpm.RaiseQuestion(qArgs);
                        qArgs.WaitForResponse();
                        var idx = qArgs.Response;
                        chosen = idx.ProviderOptions?.Where(x => x is { IsInstalled: true, IsSelected: true })
                            .Select(x => x.Name).FirstOrDefault() ?? null;
                        if (chosen is null)
                        {
                            ErrorEvent?.Invoke(this, new AlpmErrorEventArgs(
                                $"Optional dependency '{name}' not found in sync DBs or AUR (no provider selected)."));
                            continue;
                        }
                    }

                    RaiseBuildLine(parentPkg, string.Equals(chosen, name, StringComparison.Ordinal)
                        ? $"[Shelly] Attempting AUR install for optional dependency: {chosen}"
                        : $"[Shelly] Resolved AUR optdep '{name}' → '{chosen}'; attempting install", false);
                    try
                    {
                        await InstallPackages(new List<string> { chosen });
                        MarkAsDepend([chosen]);
                    }
                    catch (Exception ex)
                    {
                        ErrorEvent?.Invoke(this, new AlpmErrorEventArgs(
                            $"Optional dependency '{name}' (provider '{chosen}') failed to install: {ex.Message}"));
                    }
                }
            }
            finally
            {
                _skipOptDepsPrompt = previous;
            }
        }
    }

    public async Task RemovePackages(List<string> packageNames, AlpmTransFlag flags = AlpmTransFlag.None,
        bool removeOptionalDeps = false)
    {
        await _alpm.RemovePackages(packageNames, flags, removeOptionalDeps);
        foreach (var packageName in packageNames)
        {
            _vcsInfoStore.RemovePackage(packageName);
            // Clean up cache folder
            var pkgbase = await ResolvePkgbaseAsync(packageName);
            var cachePath = XdgPaths.ShellyCache(pkgbase);

            if (Directory.Exists(cachePath))
            {
                // Remove cache directory as the original invoking user.
                _ = await RunAsInvokingUserAsync("rm", ["-rf", cachePath]);
            }
        }

        await _vcsInfoStore.Save();
    }

    public void Dispose()
    {
        _httpClient.Dispose();
        _aurSearchManager.Dispose();
        _alpm.Dispose();
    }

    private static string? SelectBuiltPackageFile(string tempPath, string packageName)
    {
        if (!Directory.Exists(tempPath))
        {
            return null;
        }

        var allPkgFiles = Directory.GetFiles(tempPath, "*.pkg.tar.*")
            .Where(p => !p.EndsWith(".sig", StringComparison.Ordinal))
            .ToList();

        if (allPkgFiles.Count == 0)
        {
            return null;
        }

        var prefix = packageName + "-";
        var match = allPkgFiles.FirstOrDefault(p =>
            Path.GetFileName(p).StartsWith(prefix, StringComparison.Ordinal));

        if (match is not null)
        {
            return match;
        }

        return allPkgFiles.Count == 1 ? allPkgFiles[0] : null;
    }

    public async Task InstallPackageVersion(string packageName, string commit)
    {
        RaisePkgProgress(AlpmEventType.AurDownloadStart, packageName, 1, 1);

        var success = await DownloadPackageAtCommit(packageName, commit);

        if (!success)
        {
            RaisePkgProgress(AlpmEventType.AurPackageFailed, packageName, 1, 1,
                "Failed to download package at specified commit");
            throw new Exception($"Failed to download package {packageName} at commit {commit}");
        }

        var pkgbase = await ResolvePkgbaseAsync(packageName);
        var tempPath = XdgPaths.ShellyCache(pkgbase);

        RaisePkgProgress(AlpmEventType.AurBuildStart, packageName, 1, 1, "Building package with makepkg");

        var pkgbuildInfo = PkgbuildParser.Parse(Path.Combine(tempPath, "PKGBUILD"));

        // Track makedepends (and checkdepends) that are not runtime deps and not yet installed
        var runtimeDepNames = pkgbuildInfo.ParsedDepends.Select(d => d.Name).ToHashSet();
        var buildOnlyDeps = pkgbuildInfo.ParsedMakeDepends
            .Concat(_noCheck ? [] : pkgbuildInfo.ParsedCheckDepends)
            .Where(d => !runtimeDepNames.Contains(d.Name))
            .Where(d => !_alpm.IsDependencySatisfiedByInstalled(d.ToString()))
            .Select(d => _alpm.FindSatisfierInSyncDbs(d.ToString()) ?? d.Name)
            .Distinct()
            .ToList();

        var (allRepoPackages, orderedAurPackages) = CollectAllDependencies(pkgbuildInfo);
        await InstallCollectedDependencies(allRepoPackages, orderedAurPackages);


        if (_useChroot)
        {
            EnsureChrootExists();
        }

        var buildProcess = CreateBuildProcess(tempPath, "--noconfirm" + (_noCheck ? " --nocheck" : ""));
        buildProcess.OutputDataReceived += (_, e) =>
        {
            if (string.IsNullOrEmpty(e.Data))
            {
                return;
            }

            int? percent = null;
            string? progressMessage = null;
            if (e.Data.Contains('%'))
            {
                var match = Regex.Match(e.Data, @"\[\s*(?<percent>\d+)%\]\s+(?<message>.+)");
                if (match.Success)
                {
                    percent = int.Parse(match.Groups["percent"].Value);
                    progressMessage = match.Groups["message"].Value;
                }
            }

            RaiseBuildLine(packageName, e.Data, false);
            if (percent.HasValue) RaiseBuildProgress(packageName, percent.Value, progressMessage);
        };

        buildProcess.ErrorDataReceived += (_, e) =>
        {
            if (string.IsNullOrEmpty(e.Data))
            {
                return;
            }

            RaiseBuildLine(packageName, e.Data, true);
        };
        buildProcess.Start();
        buildProcess.BeginOutputReadLine();
        buildProcess.BeginErrorReadLine();
        await buildProcess.WaitForExitAsync();


        if (buildProcess.ExitCode != 0)
        {
            RaisePkgProgress(AlpmEventType.AurPackageFailed, packageName, 1, 1, "Failed to build package with makepkg");
            throw new Exception($"Failed to build package {packageName}");
        }

        var pkgFile = SelectBuiltPackageFile(tempPath, packageName);
        if (pkgFile is null)
        {
            RaisePkgProgress(AlpmEventType.AurPackageFailed, packageName, 1, 1,
                $"No package file matching '{packageName}' produced by makepkg");
            throw new Exception($"No package file matching '{packageName}' produced by makepkg");
        }

        RaisePkgProgress(AlpmEventType.AurInstallStart, packageName, 1, 1);

        _ = await _alpm.InstallLocalPackage(pkgFile);
        _alpm.Refresh();

        // Remove build-only dependencies (makedepends/checkdepends) that were installed for this build
        if (buildOnlyDeps.Count > 0)
        {
            RaisePkgProgress(AlpmEventType.AurCleanupStart, packageName, 1, 1,
                $"Removing {buildOnlyDeps.Count} build-only dependencies: {string.Join(", ", buildOnlyDeps)}");
            foreach (var dep in buildOnlyDeps)
            {
                RaiseBuildLine(packageName, $"[Shelly] Removing build-only dependency: {dep}", false);
            }

            try
            {
                await _alpm.RemovePackages(buildOnlyDeps);
                _alpm.Refresh();
            }
            catch (Exception ex)
            {
                RaisePkgProgress(AlpmEventType.AurCleanupStart, packageName, 1, 1,
                    $"Warning: Failed to remove some build dependencies: {ex.Message}");
            }
        }

        RaisePkgProgress(AlpmEventType.AurPackageCompleted, packageName, 1, 1);
    }

    private static async Task<(int ExitCode, string StdOut, string StdErr)> RunProcessAsync(
        string fileName, string arguments, string? workingDirectory = null)
    {
        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                WorkingDirectory = workingDirectory ?? string.Empty,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            }
        };
        process.Start();
        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        return (process.ExitCode, await stdoutTask, await stderrTask);
    }

    private static async Task<(int ExitCode, string StdOut, string StdErr)> RunProcessAsync(
        ProcessStartInfo startInfo)
    {
        var process = new Process
        {
            StartInfo = startInfo
        };
        process.Start();
        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        return (process.ExitCode, await stdoutTask, await stderrTask);
    }

    private static string BuildExecutionPath()
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin";
        if (!path.Contains("core_perl", StringComparison.Ordinal))
            path = $"/usr/bin/core_perl:/usr/bin/vendor_perl:/usr/bin/site_perl:{path}";

        return path;
    }

    private static string ResolveUsernameForUid(string uid)
    {
        if (string.IsNullOrEmpty(uid)) return uid;
        try
        {
            foreach (var line in File.ReadLines("/etc/passwd"))
            {
                if (string.IsNullOrWhiteSpace(line) || line.StartsWith('#')) continue;

                var parts = line.Split(':');
                if (parts.Length >= 3 && string.Equals(parts[2], uid, StringComparison.Ordinal)) return parts[0];
            }
        }
        catch
        {
            // Best-effort lookup; fall back to the raw UID
        }

        return uid;
    }

    private static ProcessStartInfo CreateAsInvokingUserStartInfo(
        string command,
        IEnumerable<string> commandArgs,
        string? workingDirectory = null)
    {
        var sudoUser = Environment.GetEnvironmentVariable("SUDO_USER");
        var pkexecUid = Environment.GetEnvironmentVariable("PKEXEC_UID");
        var pkexecUser = ResolveUsernameForUid(pkexecUid ?? string.Empty);
        var startInfo = new ProcessStartInfo
        {
            WorkingDirectory = workingDirectory ?? string.Empty,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        if (!string.IsNullOrWhiteSpace(sudoUser))
        {
            startInfo.FileName = "sudo";
            startInfo.ArgumentList.Add("--preserve-env=PATH");
            startInfo.ArgumentList.Add("-u");
            startInfo.ArgumentList.Add(sudoUser);
            startInfo.ArgumentList.Add(command);
        }
        else if (!string.IsNullOrWhiteSpace(pkexecUser))
        {
            startInfo.FileName = "runuser";
            startInfo.ArgumentList.Add("-u");
            startInfo.ArgumentList.Add(pkexecUser);
            startInfo.ArgumentList.Add("-w");
            startInfo.ArgumentList.Add("PATH");
            startInfo.ArgumentList.Add("--");
            startInfo.ArgumentList.Add(command);
        }
        else
        {
            startInfo.FileName = command;
        }

        foreach (var arg in commandArgs) startInfo.ArgumentList.Add(arg);

        startInfo.Environment["PATH"] = BuildExecutionPath();
        return startInfo;
    }

    private static Task<(int ExitCode, string StdOut, string StdErr)> RunAsInvokingUserAsync(
        string command,
        IEnumerable<string> commandArgs,
        string? workingDirectory = null)
    {
        var startInfo = CreateAsInvokingUserStartInfo(command, commandArgs, workingDirectory);
        return RunProcessAsync(startInfo);
    }

    /// <summary>
    /// Best-effort cleanup of makepkg build artifacts (<c>src/</c> and <c>pkg/</c>) inside
    /// the per-package cache dir. Mirrors the invoking-user→root fallback strategy in
    /// <see cref="RemoveCacheDirAsync"/> because <c>pkg/</c> commonly contains
    /// fakeroot-staged root-owned files. Never throws; cleanup failure is logged only.
    /// </summary>
    private async Task CleanBuildArtifactsAsync(string tempPath)
    {
        if (!Directory.Exists(tempPath)) return;

        foreach (var sub in new[] { "src", "pkg" })
        {
            var path = Path.Combine(tempPath, sub);
            if (!Directory.Exists(path)) continue;

            var (rc, _, rerr) = await RunAsInvokingUserAsync("rm", ["-rf", path]);
            if (rc == 0) continue;

            var (rc2, _, rerr2) = await RunProcessAsync("rm", $"-rf {path}");
            if (rc2 != 0)
            {
                InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.DebugOutput,
                    $"Failed to clean up {path}: {rerr2.Trim()} / {rerr.Trim()}"));
            }
        }
    }

    private async Task<bool> RemoveCacheDirAsync(string tempPath)
    {
        if (!Directory.Exists(tempPath))
        {
            return true;
        }

        var (rc, _, rerr) = await RunAsInvokingUserAsync("rm", ["-rf", tempPath]);
        if (rc == 0)
        {
            return true;
        }

        var (rc2, _, rerr2) = await RunProcessAsync("rm", $"-rf {tempPath}");
        if (rc2 == 0) return true;
        InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.DebugOutput,
            $"Failed to remove cache dir {tempPath}: {rerr2.Trim()} / {rerr.Trim()}"));
        return false;
    }

    private async Task<bool> DownloadPackageAtCommit(string packageName, string commit)
    {
        try
        {
            var pkgbase = await _aurSearchManager.GetPackageBaseAsync(packageName);
            var tempPath = XdgPaths.ShellyCache(pkgbase);
            var expectedRemote = $"https://aur.archlinux.org/{pkgbase}.git";

            if (!await RemoveCacheDirAsync(tempPath))
            {
                return false;
            }

            var (cc, _, cerr) = await RunProcessAsync(
                CreateAsInvokingUserStartInfo("git", ["clone", expectedRemote, tempPath]));
            if (cc != 0)
            {
                InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                    $"Failed to clone package {packageName} with pkgbase {pkgbase} from AUR: {cerr.Trim()}"));

                return false;
            }

            var (xc, _, xerr) = await RunProcessAsync(
                CreateAsInvokingUserStartInfo("git", ["checkout", commit], tempPath));
            if (xc != 0)
            {
                InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                    $"Failed to checkout package {packageName} with pkgbase {pkgbase} at commit {commit}: {xerr.Trim()}"));
                return false;
            }

            var pkgbuildSource = Path.Combine(tempPath, "PKGBUILD");
            return File.Exists(pkgbuildSource);
        }
        catch (Exception ex)
        {
            InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.DebugOutput,
                $"Failed to download package {packageName} at commit {commit}: {ex.Message}"));
            InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.TraceOutput,
                ex.StackTrace ?? "No stack trace available"));
            return false;
        }
    }

    private async Task<bool> DownloadPackage(string packageName)
    {
        try
        {
            var pkgbase = await ResolvePkgbaseAsync(packageName);
            var tempPath = XdgPaths.ShellyCache(pkgbase);
            var expectedRemote = $"https://aur.archlinux.org/{pkgbase}.git";
            InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                $"Downloading package {packageName} with pkgbase {pkgbase} from AUR: {expectedRemote}"));
            var hasGit = Directory.Exists(Path.Combine(tempPath, ".git"));
            var remoteOk = false;
            if (hasGit)
            {
                var (rgc, rgout, _) = await RunProcessAsync(
                    CreateAsInvokingUserStartInfo("git", ["-C", tempPath, "remote", "get-url", "origin"]));
                remoteOk = rgc == 0 && string.Equals(rgout.Trim(), expectedRemote, StringComparison.Ordinal);
            }

            var needsClone = false;

            if (hasGit && remoteOk)
            {
                var (pc, _, _) = await RunProcessAsync(
                    CreateAsInvokingUserStartInfo("git", ["-C", tempPath, "pull", "--ff-only"]));
                if (pc != 0)
                {
                    InformationalEvent?.Invoke(this,
                        new InformationalEventArgs(AlpmEventType.InformationalOutput,
                            $"Git pull failed for {pkgbase} (likely divergent history). Attempting fresh clone..."));
                    needsClone = true;
                }
            }
            else
            {
                needsClone = true;
            }

            if (needsClone)
            {
                // Strip root-owned src/ and pkg/ first so the subsequent user-level
                // rm -rf on the cache dir isn't blocked by fakeroot-staged artifacts.
                await CleanBuildArtifactsAsync(tempPath);

                if (!await RemoveCacheDirAsync(tempPath))
                {
                    return false;
                }

                var (cc, _, cerr) = await RunProcessAsync(CreateAsInvokingUserStartInfo("git", ["clone", expectedRemote, tempPath]));
                if (cc != 0)
                {
                    InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                        $"Failed to clone package {packageName} with pkgbase {pkgbase} from AUR: {cerr.Trim()}"));
                    return false;
                }
            }

            var pkgbuildSource = Path.Combine(tempPath, "PKGBUILD");
            return File.Exists(pkgbuildSource);
        }
        catch (Exception ex)
        {
            InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                $"Failed to download package {packageName} from AUR: {ex.Message}"));
            InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.TraceOutput,
                ex.StackTrace ?? "No stack trace available"));
            return false;
        }
    }

    /// <summary>
    /// Imports cached AUR package data from other AUR helpers (paru and yay) into Shelly's cache.
    /// This allows Shelly to show PKGBUILD diffs for packages that were originally installed via paru or yay.
    /// </summary>
    private async Task ImportOtherAurHelperCaches()
    {
        try
        {
            var home = XdgPaths.InvokingUserHome();
            var shellyCachePath = XdgPaths.ShellyCache();

            // Get list of installed foreign (AUR) packages
            var foreignPackages = _alpm.GetForeignPackages().Select(p => p.Name).ToHashSet();

            // Define cache locations for other AUR helpers
            var paruCachePath = Path.Combine(home, ".cache", "paru", "clone");
            var yayCachePath = Path.Combine(home, ".cache", "yay");

            // Import from paru cache
            if (Directory.Exists(paruCachePath))
            {
                await ImportFromAurHelperCache(paruCachePath, shellyCachePath, foreignPackages);
            }

            // Import from yay cache
            if (Directory.Exists(yayCachePath))
            {
                await ImportFromAurHelperCache(yayCachePath, shellyCachePath, foreignPackages);
            }
        }
        catch (Exception ex)
        {
            // Log but don't fail initialization if cache import fails
            InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.DebugOutput,
                $"Failed to import foreign AUR package data: {ex.Message}"));
            InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.TraceOutput,
                ex.StackTrace ?? "No stack trace available"));
        }
    }

    /// <summary>
    /// Imports package caches from a specific AUR helper's cache directory.
    /// Paru/yay clone by pkgbase, so the clone directory name is the pkgbase,
    /// not necessarily an installed pkgname. We resolve the real pkgbase from
    /// the clone and only import when an installed foreign package maps to it.
    /// </summary>
    private async Task ImportFromAurHelperCache(string sourceCachePath, string shellyCachePath, HashSet<string> foreignPackages)
    {
        try
        {
            var packageDirs = Directory.GetDirectories(sourceCachePath);

            foreach (var packageDir in packageDirs)
            {
                var sourcePkgbuild = Path.Combine(packageDir, "PKGBUILD");
                if (!File.Exists(sourcePkgbuild))
                    continue;


                var (pkgbase, memberNames) = await ResolveCloneIdentityAsync(packageDir);
                if (pkgbase is null)
                    continue;


                var isInstalled = foreignPackages.Contains(pkgbase) ||
                                  memberNames.Any(foreignPackages.Contains);
                if (!isInstalled)
                    continue;

                var shellyPackagePath = Path.Combine(shellyCachePath, pkgbase);


                if (Directory.Exists(shellyPackagePath))
                    continue;


                _ = await RunAsInvokingUserAsync("mkdir", ["-p", shellyPackagePath]);


                _ = await RunAsInvokingUserAsync("cp", ["-r", $"{packageDir}/.", $"{shellyPackagePath}/"]);


                var gitDir = Path.Combine(shellyPackagePath, ".git");
                if (Directory.Exists(gitDir))
                {
                    _ = await RunAsInvokingUserAsync("rm", ["-rf", gitDir]);
                }
            }
        }
        catch (Exception ex)
        {
            InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.DebugOutput,
                $"Failed to import foreign AUR package data from {sourceCachePath}: {ex.Message}"));
            InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.TraceOutput,
                ex.StackTrace ?? "No stack trace available"));
        }
    }

    private static async Task<(string? pkgbase, HashSet<string> pkgnames)> ResolveCloneIdentityAsync(string cloneDir)
    {
        var srcinfo = Path.Combine(cloneDir, ".SRCINFO");
        if (File.Exists(srcinfo))
        {
            try
            {
                var (pkgbase, names) = await ParseSrcinfoAsync(srcinfo);
                if (pkgbase is not null)
                    return (pkgbase, names);
            }
            catch
            {
                // fall through
            }
        }


        if (Directory.Exists(Path.Combine(cloneDir, ".git")))
        {
            try
            {
                var (code, stdout, _) = await RunProcessAsync(
                    CreateAsInvokingUserStartInfo("git", ["-C", cloneDir, "remote", "get-url", "origin"]));
                if (code == 0)
                {
                    const string prefix = "https://aur.archlinux.org/";
                    var url = stdout.Trim();
                    if (url.StartsWith(prefix, StringComparison.Ordinal))
                    {
                        var pkgbase = url[prefix.Length..];
                        if (pkgbase.EndsWith(".git", StringComparison.Ordinal))
                            pkgbase = pkgbase[..^4];
                        pkgbase = pkgbase.Trim('/').Trim();
                        if (!string.IsNullOrEmpty(pkgbase))
                            return (pkgbase, new HashSet<string>(StringComparer.Ordinal));
                    }
                }
            }
            catch
            {
                // fall through
            }
        }


        var dirName = Path.GetFileName(cloneDir.TrimEnd(Path.DirectorySeparatorChar));
        return string.IsNullOrEmpty(dirName)
            ? (null, new HashSet<string>(StringComparer.Ordinal))
            : (dirName, new HashSet<string>(StringComparer.Ordinal));
    }

    private (List<string> alpmPackages, List<ParsedDependency> aurPackages) ResolveDependencies(
        PkgbuildInfo pkgbuildInfo)
    {
        var allDeps = pkgbuildInfo.ParsedDepends
            .Concat(pkgbuildInfo.ParsedMakeDepends)
            .Concat(_noCheck ? [] : pkgbuildInfo.ParsedCheckDepends)
            .Distinct()
            .ToList();
        var depsToInstall = allDeps.Where(x => !_alpm.IsDependencySatisfiedByInstalled(x.ToString())).ToList();
        var satisfiedDeps = allDeps.Where(x => _alpm.IsDependencySatisfiedByInstalled(x.ToString())).ToList();
        InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
            $"Total dependencies: {allDeps.Count}, satisfied: {satisfiedDeps.Count}, to install: {depsToInstall.Count}"));

        foreach (var dep in satisfiedDeps)
        {
            InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                $"Dependency satisfied (skipping install): {dep}"));
        }

        var alpmPackages = new List<string>();
        var aurPackages = new List<ParsedDependency>();

        foreach (var dep in depsToInstall)
        {
            var match = _alpm.FindSatisfierInSyncDbsEx(dep.ToString());
            if (match is { } m)
            {
                InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                    m.ViaProvides
                        ? $"Need: {dep} from {m.RealName} (matched via provides=)"
                        : $"Need: {dep} from {m.RealName}"));
                alpmPackages.Add(m.RealName);
            }
            else
            {
                InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                    $"Need: {dep} from AUR (no repo satisfier)"));
                aurPackages.Add(dep);
            }
        }

        return (alpmPackages, aurPackages);
    }

    private (List<string> allRepoPackages, List<ParsedDependency> orderedAurPackages)
        CollectAllDependencies(PkgbuildInfo pkgbuildInfo)
    {
        var allRepoPackages = new List<string>();
        var orderedAurPackages = new List<ParsedDependency>();
        var visited = new HashSet<string>();

        CollectDepsRecursive(pkgbuildInfo, allRepoPackages, orderedAurPackages, visited);

        allRepoPackages = allRepoPackages.Distinct().ToList();
        return (allRepoPackages, orderedAurPackages);
    }

    private void CollectDepsRecursive(
        PkgbuildInfo pkgbuildInfo,
        List<string> allRepoPackages,
        List<ParsedDependency> orderedAurPackages,
        HashSet<string> visited)
    {
        var (repoPackages, aurPackages) = ResolveDependencies(pkgbuildInfo);

        InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.DebugOutput,
            $"{pkgbuildInfo.PkgName}: repo={repoPackages.Count}, aur={aurPackages.Count}"));

        allRepoPackages.AddRange(repoPackages);

        foreach (var originalAurDep in aurPackages)
        {
            var aurDep = originalAurDep;
            if (!visited.Add(aurDep.Name))
            {
                continue;
            }

            var success = DownloadPackage(aurDep.Name).Result;
            if (!success)
            {
                // The literal dep name doesn't exist as an AUR package; try to
                // resolve it through `provides=` to honor virtual/renamed deps
                // (e.g. `python-trayer` → `python-trayer-git`). See issue #880.
                var providers = _aurSearchManager.FindProvidersAsync(aurDep.Name).GetAwaiter().GetResult();
                string? chosenProvider = null;
                if (providers.Count == 1)
                {
                    chosenProvider = providers[0];
                }
                else if (providers.Count > 1)
                {
                    List<ProviderOption> availableProviders = [];
                    foreach (var provider in providers)
                    {
                        var isInstalled = _alpm.IsPackageInstalled(provider);
                        availableProviders.Add(new ProviderOption(provider, "No Description", isInstalled));
                    }

                    var qArgs = new AlpmQuestionEventArgs(
                        AlpmQuestionType.SelectProvider,
                        $"Multiple AUR providers for '{aurDep.Name}'",
                        availableProviders,
                        aurDep.Name);
                    _alpm.RaiseQuestion(qArgs);
                    qArgs.WaitForResponse();
                    chosenProvider = qArgs.Response.ProviderOptions?
                        .Where(x => x.IsSelected)
                        .Select(x => x.Name)
                        .FirstOrDefault() ?? providers[0];
                }

                if (chosenProvider == null || string.Equals(chosenProvider, aurDep.Name, StringComparison.Ordinal))
                {
                    InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                        $"Failed to download {aurDep.Name} from AUR"));
                    continue;
                }

                InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                    $"Resolved virtual AUR dep '{aurDep.Name}' via provider '{chosenProvider}'"));

                if (!visited.Add(chosenProvider))
                {
                    continue;
                }

                success = DownloadPackage(chosenProvider).Result;
                if (!success)
                {
                    InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                        $"Failed to download provider {chosenProvider} from AUR"));
                    continue;
                }

                // Remap the dep to the real provider package so downstream build/install
                // operates on the actual AUR package name.
                aurDep = new ParsedDependency(chosenProvider, aurDep.Operator, aurDep.Version);
            }

            var tempPath = XdgPaths.ShellyCache(aurDep.Name);
            var depPkgbuildInfo = PkgbuildParser.Parse(Path.Combine(tempPath, "PKGBUILD"));

            if (aurDep.Operator != null)
            {
                var aurVersion = depPkgbuildInfo.GetFullVersion();
                if (!aurDep.IsSatisifiedBy(aurVersion))
                {
                    InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                        $"AUR dependency {aurDep.Name} is not satisfied by {aurVersion} Skipping..."));
                    continue;
                }
            }

            CollectDepsRecursive(depPkgbuildInfo, allRepoPackages, orderedAurPackages, visited);

            orderedAurPackages.Add(aurDep);
        }
    }

    private async Task BuildAndInstallAurPackage(ParsedDependency package)
    {
        var packageName = package.Name;
        if (!_currentlyInstallingAurDeps.Add(packageName))
        {
            return;
        }

        try
        {
            var pkgbase = _aurSearchManager.GetPackageBaseAsync(packageName).GetAwaiter().GetResult();
            var tempPath = XdgPaths.ShellyCache(pkgbase);
            RaisePkgProgress(AlpmEventType.AurBuildStart, packageName, 1, 1, "Building package with makepkg");

            if (_useChroot)
            {
                EnsureChrootExists();
            }

            var buildProcess = CreateBuildProcess(tempPath);
            buildProcess.OutputDataReceived += (_, e) =>
            {
                if (string.IsNullOrEmpty(e.Data))
                {
                    return;
                }

                int? percent = null;
                string? progressMessage = null;
                if (e.Data.Contains('%'))
                {
                    var match = Regex.Match(e.Data, @"\[\s*(?<percent>\d+)%\]\s+(?<message>.+)");
                    if (match.Success)
                    {
                        percent = int.Parse(match.Groups["percent"].Value);
                        progressMessage = match.Groups["message"].Value;
                    }
                }

                RaiseBuildLine(packageName, e.Data, false);
                if (percent.HasValue) RaiseBuildProgress(packageName, percent.Value, progressMessage);
            };

            buildProcess.ErrorDataReceived += (_, e) =>
            {
                if (string.IsNullOrEmpty(e.Data))
                {
                    return;
                }

                RaiseBuildLine(packageName, e.Data, true);
            };

            buildProcess.Start();
            buildProcess.BeginOutputReadLine();
            buildProcess.BeginErrorReadLine();
            buildProcess.WaitForExit();
            if (buildProcess.ExitCode != 0)
            {
                InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                    $"Failed to build {packageName} with makepkg: {buildProcess.StandardError.ReadToEnd()}"));
                return;
            }

            var pkgFile = SelectBuiltPackageFile(tempPath, packageName);
            if (pkgFile is null)
            {
                InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                    $"No package file found for {packageName} in {tempPath} produced by makepkg"));
                return;
            }

            await _alpm.InstallLocalPackage(pkgFile, AlpmTransFlag.AllDeps);
            _alpm.Refresh();
        }
        finally
        {
            _currentlyInstallingAurDeps.Remove(packageName);
        }
    }

    private async Task InstallCollectedDependencies(
        List<string> allRepoPackages,
        List<ParsedDependency> orderedAurPackages,
        AlpmTransFlag flags = AlpmTransFlag.None)
    {
        InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
            $"Installing collected dependencies: {allRepoPackages.Count} repo packages, {orderedAurPackages.Count} AUR packages"));
        if (allRepoPackages.Count > 0)
        {
            _alpm.Refresh();
            _alpm.InstallPackages(allRepoPackages, flags).Wait();
            _alpm.Refresh();
        }

        foreach (var aurDep in orderedAurPackages)
        {
            await BuildAndInstallAurPackage(aurDep);
        }
    }

    private async Task MakePkgAndInstallAurDependency(ParsedDependency package)
    {
        var packageName = package.Name;
        if (!_currentlyInstallingAurDeps.Add(packageName))
        {
            InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.DebugOutput,
                $"Skipping {packageName} - circular dependency detected"));
            return;
        }

        try
        {
            var success = DownloadPackage(packageName).Result;
            if (!success)
            {
                RaisePkgProgress(AlpmEventType.AurPackageFailed, packageName, 1, 1, "Failed to download package");
                return;
            }

            var pkgbase = _aurSearchManager.GetPackageBaseAsync(packageName).GetAwaiter().GetResult();
            var tempPath = XdgPaths.ShellyCache(pkgbase);
            RaisePkgProgress(AlpmEventType.AurBuildStart, packageName, 1, 1, "Building package with makepkg");
            var pkgbuildInfo = PkgbuildParser.Parse(Path.Combine(tempPath, "PKGBUILD"));
            if (package.Operator != null)
            {
                var aurVersion = pkgbuildInfo.GetFullVersion();
                if (!package.IsSatisifiedBy(aurVersion))
                {
                    InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.DebugOutput,
                        $"AUR dependency {packageName} is not satisfied by {aurVersion} Skipping..."));
                    RaisePkgProgress(AlpmEventType.AurPackageFailed, packageName, 1, 1,
                        $"Version {aurVersion} does not satisfy {package}");
                    return;
                }
            }

            // Refresh sync DBs before resolving recursive AUR dep tree, otherwise
            // a stale local sync DB can cause real repo deps to be misrouted to AUR.
            _alpm.Refresh();
            var (allRepoPackages, orderedAurPackages) = CollectAllDependencies(pkgbuildInfo);
            await InstallCollectedDependencies(allRepoPackages, orderedAurPackages, AlpmTransFlag.AllDeps);

            if (_useChroot)
            {
                EnsureChrootExists();
            }

            var buildProcess = CreateBuildProcess(tempPath);
            buildProcess.OutputDataReceived += (_, e) =>
            {
                if (string.IsNullOrEmpty(e.Data))
                {
                    return;
                }

                int? percent = null;
                string? progressMessage = null;
                if (e.Data.Contains('%'))
                {
                    var match = Regex.Match(e.Data, @"\[\s*(?<percent>\d+)%\]\s+(?<message>.+)");
                    if (match.Success)
                    {
                        percent = int.Parse(match.Groups["percent"].Value);
                        progressMessage = match.Groups["message"].Value;
                    }
                }

                RaiseBuildLine(packageName, e.Data, false);
                if (percent.HasValue) RaiseBuildProgress(packageName, percent.Value, progressMessage);
            };

            buildProcess.ErrorDataReceived += (_, e) =>
            {
                if (string.IsNullOrEmpty(e.Data))
                {
                    return;
                }

                RaiseBuildLine(packageName, e.Data, true);
            };

            buildProcess.Start();
            buildProcess.BeginOutputReadLine();
            buildProcess.BeginErrorReadLine();
            buildProcess.WaitForExit();
            if (buildProcess.ExitCode != 0)
            {
                InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                    $"Failed to build {packageName} with makepkg exit code: {buildProcess.ExitCode}"));
                return;
            }

            var pkgFile = SelectBuiltPackageFile(tempPath, packageName);
            if (pkgFile is null)
            {
                InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                    $"No package file found for {packageName} in {tempPath} produced by makepkg"));
                return;
            }

            await _alpm.InstallLocalPackage(pkgFile, AlpmTransFlag.AllDeps);
            _alpm.Refresh();
        }
        finally
        {
            _currentlyInstallingAurDeps.Remove(packageName);
        }
    }

    private void EnsureChrootExists()
    {
        var chrootRoot = Path.Combine(_chrootPath, "root");
        if (Directory.Exists(chrootRoot))
        {
            UpdateChroot();
            CopyMakepkgConfToChroot();
            return;
        }

        Directory.CreateDirectory(_chrootPath);

        var initProcess = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "mkarchroot",
                Arguments = $"{chrootRoot} base-devel",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            }
        };
        initProcess.Start();
        initProcess.WaitForExit();

        if (initProcess.ExitCode != 0)
        {
            throw new Exception("Failed to initialize chroot environment");
        }

        CopyMakepkgConfToChroot();
    }

    private void UpdateChroot()
    {
        var chrootRoot = Path.Combine(_chrootPath, "root");
        var updateProcess = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "arch-nspawn",
                Arguments = $"{chrootRoot} shelly upgrade -n",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            }
        };
        updateProcess.Start();
        updateProcess.WaitForExit();
    }

    private void CopyMakepkgConfToChroot()
    {
        var destination = Path.Combine(_chrootPath, "root", "etc", "makepkg.conf");
        File.Copy("/etc/makepkg.conf", destination, overwrite: true);
    }

    private Process CreateBuildProcess(string tempPath, string? makepkgArgs = null)
    {
        // Use `-s --needed` as defense-in-depth: if Shelly's resolver ever misses a repo dep,
        // makepkg itself will install it via pacman instead of aborting with
        // "could not resolve all dependencies". `--needed` makes this a no-op when Shelly
        // already installed everything. See issue #880 follow-up.
        makepkgArgs ??= "-f -c -s --noconfirm --needed --skippgpcheck" + (_noCheck ? " --nocheck" : "");

        if (_useChroot)
            return new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "makechrootpkg",
                    Arguments = $"-c -r {_chrootPath}",
                    WorkingDirectory = tempPath,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                }
            };

        var makepkgArgList = makepkgArgs.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return new Process
        {
            StartInfo = CreateAsInvokingUserStartInfo("makepkg", makepkgArgList, tempPath)
        };
    }

    /// <summary>
    /// Checks if a VCS package needs an update by comparing stored commit SHAs
    /// with remote SHAs via git ls-remote.
    /// </summary>
    private async Task<bool> CheckVcsPackageNeedsUpdate(string packageName)
    {
        var storedEntries = _vcsInfoStore.GetEntries(packageName);

        // If we have no stored entries, we need to populate them first from the PKGBUILD
        if (storedEntries.Count == 0)
        {
            var entries = await GetVcsSourceEntriesForPackage(packageName);
            if (entries == null || entries.Count == 0)
                return false;

            // Populate the store with current remote SHAs so next check can compare
            foreach (var entry in entries)
            {
                var sha = await GetRemoteCommitSha(entry.Url, entry.Branch);
                if (sha != null)
                    entry.CommitSha = sha;
            }

            _vcsInfoStore.SetEntries(packageName, entries);
            await _vcsInfoStore.Save();
            return false; // First time seeing this package, don't flag as update
        }

        // Compare stored SHAs with remote SHAs
        foreach (var entry in storedEntries)
        {
            if (string.IsNullOrEmpty(entry.CommitSha))
                continue;

            var remoteSha = await GetRemoteCommitSha(entry.Url, entry.Branch);
            if (remoteSha != null && remoteSha != entry.CommitSha)
                return true;
        }

        return false;
    }

    /// <summary>
    /// Parses the PKGBUILD for a package and returns its trackable git source entries.
    /// </summary>
    private async Task<List<VcsSourceEntry>?> GetVcsSourceEntriesForPackage(string packageName)
    {
        var pkgbase = await ResolvePkgbaseAsync(packageName);
        var cachePath = XdgPaths.ShellyCache(pkgbase);
        var pkgbuildPath = Path.Combine(cachePath, "PKGBUILD");

        if (!File.Exists(pkgbuildPath))
        {
            var success = await DownloadPackage(packageName);
            if (!success)
                return null;
        }

        var pkgbuildContent = await File.ReadAllTextAsync(pkgbuildPath);
        var pkgbuildInfo = PkgbuildParser.ParseContent(pkgbuildContent);
        var entries = VcsSourceParser.ParseSources(pkgbuildInfo.Source, pkgbuildInfo.Variables);
        return entries.Count > 0 ? entries : null;
    }

    /// <summary>
    /// Runs git ls-remote to get the current commit SHA for a given URL and branch.
    /// </summary>
    private async Task<string?> GetRemoteCommitSha(string url, string branch, int timeoutSeconds = 15)
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds));
        try
        {
            var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "git",
                    Arguments = $"ls-remote {url} {(string.IsNullOrEmpty(branch) ? "" : branch)}",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                }
            };
            process.Start();

            var output = await process.StandardOutput.ReadToEndAsync(cts.Token);
            await process.WaitForExitAsync(cts.Token);

            if (process.ExitCode != 0)
                return null;

            // Output format: "<sha>\t<ref>\n"
            var line = output.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
            if (line == null)
                return null;

            var sha = line.Split('\t', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
            return string.IsNullOrWhiteSpace(sha) ? null : sha.Trim();
        }
        catch (OperationCanceledException)
        {
            InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.DebugOutput,
                $"Timeout checking git remove {url}"));
            return null;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// Updates the VCS info store after a successful package build/install.
    /// Parses sources and captures current remote commit SHAs.
    /// </summary>
    private async Task UpdateVcsStoreForPackage(string packageName, string pkgbuildPath)
    {
        if (!IsVcsPackage(packageName))
            return;

        try
        {
            var pkgbuildContent = await File.ReadAllTextAsync(pkgbuildPath);
            var pkgbuildInfo = PkgbuildParser.ParseContent(pkgbuildContent);
            var entries = VcsSourceParser.ParseSources(pkgbuildInfo.Source, pkgbuildInfo.Variables);

            if (entries.Count == 0)
                return;

            foreach (var entry in entries)
            {
                var sha = await GetRemoteCommitSha(entry.Url, entry.Branch);
                if (sha != null)
                    entry.CommitSha = sha;
            }

            _vcsInfoStore.SetEntries(packageName, entries);
            await _vcsInfoStore.Save();
        }
        catch (Exception ex)
        {
            InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                $"Failed to update VCS info store for {packageName}: {ex.Message}"));
        }
    }

    private static readonly string[] VcsSuffixes = ["-git", "-svn", "-hg", "-bzr", "-darcs", "-cvs"];

    private static bool IsVcsPackage(string packageName)
    {
        return VcsSuffixes.Any(suffix => packageName.EndsWith(suffix, StringComparison.OrdinalIgnoreCase));
    }

    private async Task<string?> ReadCachedPkgbuildAsync(string packageName)
    {
        var pkgbase = await ResolvePkgbaseAsync(packageName);

        var primary = Path.Combine(XdgPaths.ShellyCache(pkgbase), "PKGBUILD");
        if (File.Exists(primary))
            return await File.ReadAllTextAsync(primary);

        // Fallback: legacy cache keyed by pkgname
        var legacy = Path.Combine(XdgPaths.ShellyCache(packageName), "PKGBUILD");
        if (File.Exists(legacy))
            return await File.ReadAllTextAsync(legacy);

        return null;
    }

    private async Task<string> ResolvePkgbaseAsync(string pkgname)
    {
        if (string.IsNullOrWhiteSpace(pkgname)) return pkgname;
        if (_pkgbaseCache.TryGetValue(pkgname, out var cached)) return cached;


        var fromSrcinfo = await TryResolveFromSrcinfoAsync(pkgname);
        if (fromSrcinfo is not null) return Cache(pkgname, fromSrcinfo);


        var fromRemote = await TryResolveFromGitRemoteAsync(pkgname);
        if (fromRemote is not null) return Cache(pkgname, fromRemote);


        var fromRpc = await _aurSearchManager.GetPackageBaseAsync(pkgname);
        if (!string.Equals(fromRpc, pkgname, StringComparison.Ordinal))
            return Cache(pkgname, fromRpc);


        InformationalEvent?.Invoke(this, new InformationalEventArgs(
            AlpmEventType.DebugOutput,
            $"pkgbase resolution fell back to pkgname for '{pkgname}' " +
            "(.SRCINFO, git remote, and AUR RPC all failed)"));
        return pkgname;
    }

    private string Cache(string pkgname, string pkgbase)
    {
        _pkgbaseCache[pkgname] = pkgbase;
        return pkgbase;
    }

    private bool RequestPkgbuildApproval(string packageName, string? oldPkgbuild, string? newPkgbuild,
        string? baseDir = null)
    {
        var warnings = ValidatePkgbuild(newPkgbuild, baseDir);

        if (PkgbuildDiffRequest is null) return true;

        var args = new PkgbuildDiffRequestEventArgs
        {
            PackageName = packageName,
            OldPkgbuild = oldPkgbuild ?? string.Empty,
            NewPkgbuild = newPkgbuild ?? string.Empty,
            Warnings = warnings,
            ProceedWithUpdate = true
        };

        PkgbuildDiffRequest.Invoke(this, args);
        return args.ProceedWithUpdate;
    }

    private List<ValidationFinding> ValidatePkgbuild(string? newPkgbuild, string? baseDir)
    {
        if (string.IsNullOrWhiteSpace(newPkgbuild))
            return [];

        try
        {
            var info = PkgbuildParser.ParseContent(newPkgbuild, baseDir);
            var findings = new PostInstallValidator().Validate(info).Findings;
            findings.AddRange(new HomographValidator().Validate(info).Findings);
            return findings;
        }
        catch (Exception ex)
        {
            InformationalEvent?.Invoke(this, new InformationalEventArgs(AlpmEventType.InformationalOutput,
                $"Failed to validate PKGBUILD scriptlets: {ex.Message}"));
            return [];
        }
    }

    private async Task<bool> ShouldProceedWithPkgbuildAsync(string packageName)
    {
        var oldPkgbuild = await ReadCachedPkgbuildAsync(packageName);
        var newPkgbuild = await FetchPkgbuildAsync(packageName);

        var pkgbase = await _aurSearchManager.GetPackageBaseAsync(packageName);
        var baseDir = XdgPaths.ShellyCache(pkgbase);

        return RequestPkgbuildApproval(packageName, oldPkgbuild, newPkgbuild, baseDir);
    }

    private async Task<string?> TryResolveFromSrcinfoAsync(string pkgname)
    {
        try
        {
            // Fast path: the common non-split case where dir name == pkgname == pkgbase.
            var direct = Path.Combine(XdgPaths.ShellyCache(pkgname), ".SRCINFO");
            if (File.Exists(direct))
            {
                var (pkgbase, names) = await ParseSrcinfoAsync(direct);
                if (pkgbase is not null &&
                    (string.Equals(pkgbase, pkgname, StringComparison.Ordinal) ||
                     names.Contains(pkgname)))
                {
                    return pkgbase;
                }
            }

            // Full scan: walk every cache dir and match pkgname against its members.
            var cacheRoot = XdgPaths.ShellyCache();
            if (!Directory.Exists(cacheRoot))
                return null;

            foreach (var dir in Directory.EnumerateDirectories(cacheRoot))
            {
                var srcinfo = Path.Combine(dir, ".SRCINFO");
                if (!File.Exists(srcinfo))
                    continue;

                var (pkgbase, names) = await ParseSrcinfoAsync(srcinfo);
                if (pkgbase is null)
                    continue;

                if (string.Equals(pkgbase, pkgname, StringComparison.Ordinal) ||
                    names.Contains(pkgname))
                {
                    return pkgbase;
                }
            }
        }
        catch (Exception ex)
        {
            // Non-fatal: fall through to the next resolver.
            InformationalEvent?.Invoke(this, new InformationalEventArgs(
                AlpmEventType.TraceOutput,
                $".SRCINFO pkgbase resolution failed for '{pkgname}': {ex.Message}"));
        }

        return null;
    }

    private static async Task<(string? pkgbase, HashSet<string> pkgnames)> ParseSrcinfoAsync(string path)
    {
        string? pkgbase = null;
        var pkgnames = new HashSet<string>(StringComparer.Ordinal);

        foreach (var raw in await File.ReadAllLinesAsync(path))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#'))
                continue;

            var eq = line.IndexOf('=');
            if (eq < 0)
                continue;

            var key = line[..eq].Trim();
            var value = line[(eq + 1)..].Trim();
            if (value.Length == 0)
                continue;

            if (key == "pkgbase")
                pkgbase = value;
            else if (key == "pkgname")
                pkgnames.Add(value);
        }

        return (pkgbase, pkgnames);
    }

    private async Task<string?> TryResolveFromGitRemoteAsync(string pkgname)
    {
        try
        {
            // We can only guess a clone dir by name, so this resolves the
            // common case where the working-tree dir is named after pkgname.
            var dir = XdgPaths.ShellyCache(pkgname);
            if (!Directory.Exists(Path.Combine(dir, ".git")))
                return null;

            var (code, stdout, _) = await RunProcessAsync(
                CreateAsInvokingUserStartInfo("git", ["-C", dir, "remote", "get-url", "origin"]));

            if (code != 0)
                return null;

            var url = stdout.Trim();

            // Expected form: https://aur.archlinux.org/<pkgbase>.git
            const string prefix = "https://aur.archlinux.org/";
            if (!url.StartsWith(prefix, StringComparison.Ordinal))
                return null;

            var pkgbase = url[prefix.Length..];
            if (pkgbase.EndsWith(".git", StringComparison.Ordinal))
                pkgbase = pkgbase[..^4];

            pkgbase = pkgbase.Trim('/').Trim();

            return string.IsNullOrEmpty(pkgbase) ? null : pkgbase;
        }
        catch (Exception ex)
        {
            // Non-fatal: fall through to the AUR RPC resolver.
            InformationalEvent?.Invoke(this, new InformationalEventArgs(
                AlpmEventType.TraceOutput,
                $"git-remote pkgbase resolution failed for '{pkgname}': {ex.Message}"));
            return null;
        }
    }
}