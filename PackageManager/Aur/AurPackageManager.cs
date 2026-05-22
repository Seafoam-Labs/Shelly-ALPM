using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using PackageManager.Alpm;
using PackageManager.Alpm.Events.EventArgs;
using PackageManager.Aur.Models;
using PackageManager.Utilities;
using Shelly.Utilities;

#pragma warning disable CS8618 // Non-nullable field must contain a non-null value when exiting constructor. Consider adding the 'required' modifier or declaring as nullable.

namespace PackageManager.Aur;

public class PackageProgressEventArgs : EventArgs
{
    public required string PackageName { get; init; }
    public int CurrentIndex { get; init; }
    public int TotalCount { get; init; }
    public PackageProgressStatus Status { get; init; }
    public string? Message { get; init; }
}

public class PkgbuildDiffRequestEventArgs : EventArgs
{
    public required string PackageName { get; init; }
    public required string OldPkgbuild { get; init; }
    public required string NewPkgbuild { get; init; }
    public bool ProceedWithUpdate { get; set; } = true;
}

public class BuildOutputEventArgs : EventArgs
{
    public required string PackageName { get; init; }
    public required string Line { get; init; }
    public bool IsError { get; init; }
    public int? Percent { get; init; }
    public string? ProgressMessage { get; init; }
}

public enum PackageProgressStatus
{
    Downloading,
    Building,
    Installing,
    CleaningUp,
    Completed,
    Failed
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

    private static HttpClient CreateAurHttpClient()
    {
        var client = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(20),
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Shelly/1.0 (+https://github.com/zoe-codez/Shelly-ALPM)");
        return client;
    }

    private readonly HashSet<string> _currentlyInstallingAurDeps = [];
    private bool _useChroot;
    private bool _noCheck = true;
    private string _chrootPath;
    private readonly VcsInfoStore _vcsInfoStore = new();

    public event EventHandler<PackageProgressEventArgs>? PackageProgress;
    public event EventHandler<PkgbuildDiffRequestEventArgs>? PkgbuildDiffRequest;
    public event EventHandler<AlpmQuestionEventArgs>? Question;
    public event EventHandler<AlpmProgressEventArgs>? Progress;
    public event EventHandler<BuildOutputEventArgs>? BuildOutput;
    public event EventHandler<AlpmPackageOperationEventArgs>? PackageOperation;
    public event EventHandler<AlpmScriptletEventArgs>? ScriptletInfo;
    public event EventHandler<AlpmHookEventArgs>? HookRun;
    public event EventHandler<AlpmReplacesEventArgs>? Replaces;
    public event EventHandler<AlpmPacnewEventArgs>? PacnewInfo;
    public event EventHandler<AlpmPacsaveEventArgs>? PacsaveInfo;
    public event EventHandler<AlpmErrorEventArgs>? ErrorEvent;

    public async Task Initialize(bool root = false, bool useTempPath = false, bool useChroot = false,
        string chrootPath = "/var/lib/shelly/chroot", string tempPath = "", bool showHiddenPackages = false,
        bool noCheck = true)
    {
        _alpm = configPath is null ? new AlpmManager() : new AlpmManager(configPath);
        _alpm.Initialize(root, useTempPath: useTempPath, tempPath: tempPath, showHiddenPackages: showHiddenPackages);
        _alpm.Question += (_, args) => Question?.Invoke(this, args);
        _alpm.Progress += (_, args) => Progress?.Invoke(this, args);
        _alpm.PackageOperation += (_, args) => PackageOperation?.Invoke(this, args);
        _alpm.ScriptletInfo += (_, args) => ScriptletInfo?.Invoke(this, args);
        _alpm.HookRun += (_, args) => HookRun?.Invoke(this, args);
        _alpm.Replaces += (_, args) => Replaces?.Invoke(this, args);
        _alpm.PacnewInfo += (_, args) => PacnewInfo?.Invoke(this, args);
        _alpm.PacsaveInfo += (_, args) => PacsaveInfo?.Invoke(this, args);
        _alpm.ErrorEvent += (_, args) => ErrorEvent?.Invoke(this, args);
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
                await Console.Error.WriteLineAsync($"Error checking version for {installedPkg.Name}: {ex.Message}");
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
        var packagesToUpdate = new List<string>();

        foreach (var packageName in packageNames)
        {
            // Check if there's an existing PKGBUILD (cached from previous install)
            var tempPath = XdgPaths.ShellyCache(packageName);
            var cachedPkgbuildPath = Path.Combine(tempPath, "PKGBUILD");
            string? oldPkgbuild = null;

            if (File.Exists(cachedPkgbuildPath))
            {
                oldPkgbuild = await File.ReadAllTextAsync(cachedPkgbuildPath);
            }

            // Fetch the new PKGBUILD from AUR
            var newPkgbuild = await FetchPkgbuildAsync(packageName);

            if (oldPkgbuild != null && newPkgbuild != null && PkgbuildDiffRequest != null)
            {
                var args = new PkgbuildDiffRequestEventArgs
                {
                    PackageName = packageName,
                    OldPkgbuild = oldPkgbuild,
                    NewPkgbuild = newPkgbuild,
                    ProceedWithUpdate = true
                };

                PkgbuildDiffRequest.Invoke(this, args);

                if (!args.ProceedWithUpdate)
                {
                    continue;
                }
            }

            packagesToUpdate.Add(packageName);
        }

        if (packagesToUpdate.Count > 0)
        {
            Console.WriteLine("Updating the following packages:");
            await InstallPackages(packagesToUpdate);
        }
    }

    public async Task<string?> FetchPkgbuildAsync(string packageName)
    {
        try
        {
            // Resolve pkgname -> pkgbase: split AUR packages live under their pkgbase repo
            var pkgbase = await _aurSearchManager.GetPackageBaseAsync(packageName);
            await Console.Error.WriteLineAsync($"pkgbase {pkgbase}");
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
        PackageProgress?.Invoke(this, new PackageProgressEventArgs
        {
            PackageName = packageName,
            CurrentIndex = 1,
            TotalCount = 1,
            Status = PackageProgressStatus.Downloading,
            Message = "Downloading PKGBUILD to analyze dependencies"
        });

        var success = await DownloadPackage(packageName);

        if (!success)
        {
            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = 1,
                TotalCount = 1,
                Status = PackageProgressStatus.Failed,
                Message = "Failed to download package"
            });
            return;
        }

        var pkgbase = await _aurSearchManager.GetPackageBaseAsync(packageName);
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
            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = 1,
                TotalCount = 1,
                Status = PackageProgressStatus.Completed,
                Message = "All dependencies are already installed"
            });
            return;
        }

        PackageProgress?.Invoke(this, new PackageProgressEventArgs
        {
            PackageName = packageName,
            CurrentIndex = 1,
            TotalCount = 1,
            Status = PackageProgressStatus.Installing,
            Message = $"Installing dependencies: {string.Join(", ", depsToInstall)}"
        });

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
            MakePkgAndInstallAurDependency(pkg);
        }


        PackageProgress?.Invoke(this, new PackageProgressEventArgs
        {
            PackageName = packageName,
            CurrentIndex = 1,
            TotalCount = 1,
            Status = PackageProgressStatus.Completed,
            Message = "Dependencies installed successfully"
        });
    }

    /// <summary>
    /// When true, suppresses the optional-dependency selection prompt for the current
    /// invocation. Used to prevent re-prompting during recursive AUR fallback installs
    /// triggered by previously selected opt-deps.
    /// </summary>
    private bool _skipOptDepsPrompt;

    public async Task InstallPackages(List<string> packageNames)
    {
        // Per-call map of selected optional dependencies (by top-level package).
        var selectedOptDepsByPkg = new Dictionary<string, List<string>>();

        var totalCount = packageNames.Count;
        for (var i = 0; i < packageNames.Count; i++)
        {
            var packageName = packageNames[i];

            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = i + 1,
                TotalCount = totalCount,
                Status = PackageProgressStatus.Downloading
            });
            var newPkgbuild = await FetchPkgbuildAsync(packageName);
            var args = new PkgbuildDiffRequestEventArgs
            {
                PackageName = packageName,
                OldPkgbuild = string.Empty,
                NewPkgbuild = newPkgbuild ?? string.Empty,
                ProceedWithUpdate = true
            };
            PkgbuildDiffRequest?.Invoke(this,args);

            if (!args.ProceedWithUpdate)
            {
                continue;
            }

            var success = await DownloadPackage(packageName);

            if (!success)
            {
                PackageProgress?.Invoke(this, new PackageProgressEventArgs
                {
                    PackageName = packageName,
                    CurrentIndex = i + 1,
                    TotalCount = totalCount,
                    Status = PackageProgressStatus.Failed,
                    Message = "Failed to download package"
                });
                continue;
            }

            // Build the package using makepkg
            var user = Environment.GetEnvironmentVariable("SUDO_USER") ?? Environment.UserName;
            var pkgbase = await _aurSearchManager.GetPackageBaseAsync(packageName);
            var tempPath = XdgPaths.ShellyCache(pkgbase);
            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = i + 1,
                TotalCount = totalCount,
                Status = PackageProgressStatus.Building,
                Message = "Building package with makepkg"
            });
            var pkgbuildInfo = PkgbuildParser.Parse(Path.Combine(tempPath, "PKGBUILD"));

            // Prompt the user for optional dependencies declared in the PKGBUILD. The selected
            // names are installed after the main AUR package is committed (see post-install
            // block). The prompt is suppressed when this call is itself a recursive AUR
            // fallback install triggered by an earlier opt-deps selection.
            if (!_skipOptDepsPrompt)
            {
                var selectedOptDeps = PromptAurOptionalDeps(packageName, pkgbuildInfo.OptDepends);
                if (selectedOptDeps.Count > 0)
                {
                    selectedOptDepsByPkg[packageName] = selectedOptDeps;
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
            await Console.Error.WriteLineAsync($"dependency count {allRepoPackages.Count + orderedAurPackages.Count}");
            InstallCollectedDependencies(allRepoPackages, orderedAurPackages, AlpmTransFlag.AllDeps);


            // Backup PKGBUILD to PreviousVersions folder
            var previousVersionsPath = Path.Combine(tempPath, "PreviousVersions");
            var pkgbuildPath = Path.Combine(tempPath, "PKGBUILD");
            if (File.Exists(pkgbuildPath))
            {
                // Create directory as the non-root user to avoid permission issues
                var mkdirProcess = new System.Diagnostics.Process
                {
                    StartInfo = new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "sudo",
                        Arguments = $"-u {user} mkdir -p {previousVersionsPath}",
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    }
                };
                mkdirProcess.Start();
                await mkdirProcess.WaitForExitAsync();

                var existingBackups = Directory.Exists(previousVersionsPath)
                    ? Directory.GetFiles(previousVersionsPath, "PKGBUILD.*")
                    : Array.Empty<string>();
                var nextNumber = existingBackups.Length + 1;
                var backupPath = Path.Combine(previousVersionsPath, $"PKGBUILD.{nextNumber}");

                var cpProcess = new System.Diagnostics.Process
                {
                    StartInfo = new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "sudo",
                        Arguments = $"-u {user} cp {pkgbuildPath} {backupPath}",
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    }
                };
                cpProcess.Start();
                await cpProcess.WaitForExitAsync();
            }

            // Remove any existing package files before building
            foreach (var oldPkgFile in Directory.GetFiles(tempPath, "*.pkg.tar.*"))
            {
                var rmPkgProcess = new System.Diagnostics.Process
                {
                    StartInfo = new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "sudo",
                        Arguments = $"-u {user} rm -f {oldPkgFile}",
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    }
                };
                rmPkgProcess.Start();
                await rmPkgProcess.WaitForExitAsync();
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

                BuildOutput?.Invoke(this, new BuildOutputEventArgs
                {
                    PackageName = packageName,
                    Line = e.Data,
                    IsError = false,
                    Percent = percent,
                    ProgressMessage = progressMessage
                });
            };

            buildProcess.ErrorDataReceived += (_, e) =>
            {
                if (string.IsNullOrEmpty(e.Data))
                {
                    return;
                }

                BuildOutput?.Invoke(this, new BuildOutputEventArgs
                {
                    PackageName = packageName,
                    Line = e.Data,
                    IsError = true
                });
            };

            buildProcess.Start();
            buildProcess.BeginOutputReadLine();
            buildProcess.BeginErrorReadLine();
            await buildProcess.WaitForExitAsync();

            if (buildProcess.ExitCode != 0)
            {
                PackageProgress?.Invoke(this, new PackageProgressEventArgs
                {
                    PackageName = packageName,
                    CurrentIndex = i + 1,
                    TotalCount = totalCount,
                    Status = PackageProgressStatus.Failed,
                    Message = "Failed to build package with makepkg"
                });
                continue;
            }

            var pkgFile = SelectBuiltPackageFile(tempPath, packageName);
            if (pkgFile is null)
            {
                PackageProgress?.Invoke(this, new PackageProgressEventArgs
                {
                    PackageName = packageName,
                    CurrentIndex = i + 1,
                    TotalCount = totalCount,
                    Status = PackageProgressStatus.Failed,
                    Message = $"No package file matching '{packageName}' produced by makepkg"
                });
                continue;
            }

            // Install using _alpm
            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = i + 1,
                TotalCount = totalCount,
                Status = PackageProgressStatus.Installing
            });

            try
            {
                _ = _alpm.InstallLocalPackage(pkgFile).Result;
                _alpm.Refresh();

                // Update VCS info store with current commit SHAs after successful install
                await UpdateVcsStoreForPackage(packageName, Path.Combine(tempPath, "PKGBUILD"));
            }
            catch (Exception ex)
            {
                PackageProgress?.Invoke(this, new PackageProgressEventArgs
                {
                    PackageName = packageName,
                    CurrentIndex = i + 1,
                    TotalCount = totalCount,
                    Status = PackageProgressStatus.Failed,
                    Message = $"Failed to install package: {ex.Message}"
                });
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
                    BuildOutput?.Invoke(this, new BuildOutputEventArgs
                    {
                        PackageName = packageName,
                        Line = $"[Shelly] Warning: failed to install some optional dependencies: {ex.Message}",
                        IsError = true
                    });
                }
            }

            // Remove build-only dependencies (makedepends/checkdepends) that were installed for this build
            if (buildOnlyDeps.Count > 0)
            {
                PackageProgress?.Invoke(this, new PackageProgressEventArgs
                {
                    PackageName = packageName,
                    CurrentIndex = i + 1,
                    TotalCount = totalCount,
                    Status = PackageProgressStatus.CleaningUp,
                    Message =
                        $"Removing {buildOnlyDeps.Count} build-only dependencies: {string.Join(", ", buildOnlyDeps)}"
                });
                foreach (var dep in buildOnlyDeps)
                {
                    BuildOutput?.Invoke(this, new BuildOutputEventArgs
                    {
                        PackageName = packageName,
                        Line = $"[Shelly] Removing build-only dependency: {dep}",
                        IsError = false
                    });
                }

                try
                {
                    await _alpm.RemovePackages(buildOnlyDeps);
                    _alpm.Refresh();
                }
                catch (Exception ex)
                {
                    PackageProgress?.Invoke(this, new PackageProgressEventArgs
                    {
                        PackageName = packageName,
                        CurrentIndex = i + 1,
                        TotalCount = totalCount,
                        Status = PackageProgressStatus.CleaningUp,
                        Message = $"Warning: Failed to remove some build dependencies: {ex.Message}"
                    });
                }
            }

            // Clean makepkg build artifacts (src/, pkg/) so a later fresh-clone recovery
            // isn't blocked by root-owned fakeroot-staged trees inside the cache dir.
            // Best-effort; failures are logged but never fail the install.
            await CleanBuildArtifactsAsync(user, tempPath);
            BuildOutput?.Invoke(this, new BuildOutputEventArgs
            {
                PackageName = packageName,
                Line = "[Shelly] Cleaned build artifacts (src/, pkg/)",
                IsError = false
            });

            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = i + 1,
                TotalCount = totalCount,
                Status = PackageProgressStatus.Completed
            });
        }
    }

    /// <summary>
    /// Raises a SelectOptionalDeps question through _alpm so the existing CLI prompt and Gtk
    /// dialog pipelines react identically to a sync-path prompt. Returns the bare optdep names
    /// (the part before the first ':') that the user selected.
    /// </summary>
    private List<string> PromptAurOptionalDeps(string pkgName, List<string> optDepends)
    {
        if (optDepends == null || optDepends.Count == 0)
            return new List<string>();

        var args = new AlpmQuestionEventArgs(
            AlpmQuestionType.SelectOptionalDeps,
            $"Select optional dependencies for {pkgName}",
            optDepends);
        _alpm.RaiseQuestion(args);
        args.WaitForResponse();

        return optDepends
            .Where((_, i) => (args.Response & (1L << i)) != 0)
            .Select(StripDepDecorations)
            .Where(n => !string.IsNullOrEmpty(n))
            .ToList();
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
            BuildOutput?.Invoke(this, new BuildOutputEventArgs
            {
                PackageName = parentPkg,
                Line = $"[Shelly] Installing optional dependencies from repo: {string.Join(", ", repoMatches)}",
                IsError = false
            });
            try
            {
                await _alpm.InstallPackages(repoMatches);
                _alpm.Refresh();
                MarkAsDepend(repoMatches);
            }
            catch (Exception ex)
            {
                BuildOutput?.Invoke(this, new BuildOutputEventArgs
                {
                    PackageName = parentPkg,
                    Line = $"[Shelly] Warning: failed to install repo optional dependencies: {ex.Message}",
                    IsError = true
                });
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
                        var qArgs = new AlpmQuestionEventArgs(
                            AlpmQuestionType.SelectProvider,
                            $"Multiple AUR providers for '{name}'",
                            providers,
                            name);
                        _alpm.RaiseQuestion(qArgs);
                        qArgs.WaitForResponse();
                        var idx = qArgs.Response;
                        chosen = idx >= 0 && idx < providers.Count ? providers[idx] : providers[0];
                    }

                    BuildOutput?.Invoke(this, new BuildOutputEventArgs
                    {
                        PackageName = parentPkg,
                        Line = string.Equals(chosen, name, StringComparison.Ordinal)
                            ? $"[Shelly] Attempting AUR install for optional dependency: {chosen}"
                            : $"[Shelly] Resolved AUR optdep '{name}' → '{chosen}'; attempting install",
                        IsError = false
                    });
                    try
                    {
                        await InstallPackages(new List<string> { chosen });
                        MarkAsDepend(new[] { chosen });
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

    public async Task RemovePackages(List<string> packageNames, AlpmTransFlag flags = AlpmTransFlag.None, bool removeOptionalDeps = false)
    {
        await _alpm.RemovePackages(packageNames, flags, removeOptionalDeps);
        foreach (var packageName in packageNames)
        {
            _vcsInfoStore.RemovePackage(packageName);
            // Clean up cache folder
            var user = Environment.GetEnvironmentVariable("SUDO_USER") ?? Environment.UserName;
            var cachePath = XdgPaths.ShellyCache(packageName);

            if (Directory.Exists(cachePath))
            {
                // Remove cache directory as the original user
                var rmProcess = new System.Diagnostics.Process
                {
                    StartInfo = new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "sudo",
                        Arguments = $"-u {user} rm -rf {cachePath}",
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    }
                };
                rmProcess.Start();
                await rmProcess.WaitForExitAsync();
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
        PackageProgress?.Invoke(this, new PackageProgressEventArgs
        {
            PackageName = packageName,
            CurrentIndex = 1,
            TotalCount = 1,
            Status = PackageProgressStatus.Downloading
        });

        var success = await DownloadPackageAtCommit(packageName, commit);

        if (!success)
        {
            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = 1,
                TotalCount = 1,
                Status = PackageProgressStatus.Failed,
                Message = "Failed to download package at specified commit"
            });
            throw new Exception($"Failed to download package {packageName} at commit {commit}");
        }

        var pkgbase = await _aurSearchManager.GetPackageBaseAsync(packageName);
        var tempPath = XdgPaths.ShellyCache(pkgbase);

        PackageProgress?.Invoke(this, new PackageProgressEventArgs
        {
            PackageName = packageName,
            CurrentIndex = 1,
            TotalCount = 1,
            Status = PackageProgressStatus.Building,
            Message = "Building package with makepkg"
        });

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
        InstallCollectedDependencies(allRepoPackages, orderedAurPackages);


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

            BuildOutput?.Invoke(this, new BuildOutputEventArgs
            {
                PackageName = packageName,
                Line = e.Data,
                IsError = false,
                Percent = percent,
                ProgressMessage = progressMessage
            });
        };

        buildProcess.ErrorDataReceived += (_, e) =>
        {
            if (string.IsNullOrEmpty(e.Data))
            {
                return;
            }

            BuildOutput?.Invoke(this, new BuildOutputEventArgs
            {
                PackageName = packageName,
                Line = e.Data,
                IsError = true
            });
        };
        buildProcess.Start();
        buildProcess.BeginOutputReadLine();
        buildProcess.BeginErrorReadLine();
        await buildProcess.WaitForExitAsync();


        if (buildProcess.ExitCode != 0)
        {
            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = 1,
                TotalCount = 1,
                Status = PackageProgressStatus.Failed,
                Message = "Failed to build package with makepkg"
            });
            throw new Exception($"Failed to build package {packageName}");
        }

        var pkgFile = SelectBuiltPackageFile(tempPath, packageName);
        if (pkgFile is null)
        {
            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = 1,
                TotalCount = 1,
                Status = PackageProgressStatus.Failed,
                Message = $"No package file matching '{packageName}' produced by makepkg"
            });
            throw new Exception($"No package file matching '{packageName}' produced by makepkg");
        }

        PackageProgress?.Invoke(this, new PackageProgressEventArgs
        {
            PackageName = packageName,
            CurrentIndex = 1,
            TotalCount = 1,
            Status = PackageProgressStatus.Installing
        });

        _ = _alpm.InstallLocalPackage(pkgFile).Result;
        _alpm.Refresh();

        // Remove build-only dependencies (makedepends/checkdepends) that were installed for this build
        if (buildOnlyDeps.Count > 0)
        {
            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = 1,
                TotalCount = 1,
                Status = PackageProgressStatus.CleaningUp,
                Message = $"Removing {buildOnlyDeps.Count} build-only dependencies: {string.Join(", ", buildOnlyDeps)}"
            });
            foreach (var dep in buildOnlyDeps)
            {
                BuildOutput?.Invoke(this, new BuildOutputEventArgs
                {
                    PackageName = packageName,
                    Line = $"[Shelly] Removing build-only dependency: {dep}",
                    IsError = false
                });
            }

            try
            {
                await _alpm.RemovePackages(buildOnlyDeps);
                _alpm.Refresh();
            }
            catch (Exception ex)
            {
                PackageProgress?.Invoke(this, new PackageProgressEventArgs
                {
                    PackageName = packageName,
                    CurrentIndex = 1,
                    TotalCount = 1,
                    Status = PackageProgressStatus.CleaningUp,
                    Message = $"Warning: Failed to remove some build dependencies: {ex.Message}"
                });
            }
        }

        PackageProgress?.Invoke(this, new PackageProgressEventArgs
        {
            PackageName = packageName,
            CurrentIndex = 1,
            TotalCount = 1,
            Status = PackageProgressStatus.Completed
        });
    }

    private static async Task<(int ExitCode, string StdOut, string StdErr)> RunProcessAsync(
        string fileName, string arguments, string? workingDirectory = null)
    {
        var process = new System.Diagnostics.Process
        {
            StartInfo = new System.Diagnostics.ProcessStartInfo
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

    /// <summary>
    /// Best-effort cleanup of makepkg build artifacts (<c>src/</c> and <c>pkg/</c>) inside
    /// the per-package cache dir. Mirrors the sudo→root fallback strategy in
    /// <see cref="RemoveCacheDirAsync"/> because <c>pkg/</c> commonly contains
    /// fakeroot-staged root-owned files. Never throws; cleanup failure is logged only.
    /// </summary>
    private static async Task CleanBuildArtifactsAsync(string user, string tempPath)
    {
        if (!Directory.Exists(tempPath)) return;

        foreach (var sub in new[] { "src", "pkg" })
        {
            var path = Path.Combine(tempPath, sub);
            if (!Directory.Exists(path)) continue;

            var (rc, _, rerr) = await RunProcessAsync(
                "sudo", $"-u {user} rm -rf {path}");
            if (rc == 0) continue;

            var (rc2, _, rerr2) = await RunProcessAsync("rm", $"-rf {path}");
            if (rc2 != 0)
            {
                await Console.Error.WriteLineAsync(
                    $"[Shelly] could not clean {path}: {rerr2.Trim()} / {rerr.Trim()}");
            }
        }
    }

    private static async Task<bool> RemoveCacheDirAsync(string user, string tempPath)
    {
        if (!Directory.Exists(tempPath))
        {
            return true;
        }

        var (rc, _, rerr) = await RunProcessAsync("sudo", $"-u {user} rm -rf {tempPath}");
        if (rc == 0)
        {
            return true;
        }

        var (rc2, _, rerr2) = await RunProcessAsync("rm", $"-rf {tempPath}");
        if (rc2 != 0)
        {
            await Console.Error.WriteLineAsync(
                $"[Shelly] could not clean cache dir {tempPath}: {rerr2.Trim()} / {rerr.Trim()}");
            return false;
        }

        return true;
    }

    private async Task<bool> DownloadPackageAtCommit(string packageName, string commit)
    {
        try
        {
            var user = Environment.GetEnvironmentVariable("SUDO_USER") ?? Environment.UserName;
            var pkgbase = await _aurSearchManager.GetPackageBaseAsync(packageName);
            var tempPath = XdgPaths.ShellyCache(pkgbase);
            var expectedRemote = $"https://aur.archlinux.org/{pkgbase}.git";

            if (!await RemoveCacheDirAsync(user, tempPath))
            {
                return false;
            }

            var (cc, _, cerr) = await RunProcessAsync(
                "sudo", $"-u {user} git clone {expectedRemote} {tempPath}");
            if (cc != 0)
            {
                await Console.Error.WriteLineAsync(
                    $"[Shelly] git clone failed for {pkgbase}: {cerr.Trim()}");
                return false;
            }

            var (xc, _, xerr) = await RunProcessAsync(
                "sudo", $"-u {user} git checkout {commit}", tempPath);
            if (xc != 0)
            {
                await Console.Error.WriteLineAsync(
                    $"[Shelly] git checkout {commit} failed for {pkgbase}: {xerr.Trim()}");
                return false;
            }

            var pkgbuildSource = Path.Combine(tempPath, "PKGBUILD");
            return File.Exists(pkgbuildSource);
        }
        catch (Exception ex)
        {
            await Console.Error.WriteLineAsync(
                $"[Shelly] DownloadPackageAtCommit failed for {packageName}: {ex.Message}");
            return false;
        }
    }

    private async Task<bool> DownloadPackage(string packageName)
    {
        try
        {
            var user = Environment.GetEnvironmentVariable("SUDO_USER") ?? Environment.UserName;
            var pkgbase = await _aurSearchManager.GetPackageBaseAsync(packageName);
            var tempPath = XdgPaths.ShellyCache(pkgbase);
            var expectedRemote = $"https://aur.archlinux.org/{pkgbase}.git";
            await Console.Error.WriteLineAsync($"Downloading {pkgbase} from AUR");

            var hasGit = Directory.Exists(Path.Combine(tempPath, ".git"));
            var remoteOk = false;
            if (hasGit)
            {
                var (rgc, rgout, _) = await RunProcessAsync(
                    "sudo", $"-u {user} git -C {tempPath} remote get-url origin");
                remoteOk = rgc == 0 && string.Equals(rgout.Trim(), expectedRemote, StringComparison.Ordinal);
            }

            var needsClone = false;

            if (hasGit && remoteOk)
            {
                var (pc, _, _) = await RunProcessAsync(
                    "sudo", $"-u {user} git -C {tempPath} pull --ff-only");
                if (pc != 0)
                {
                    await Console.Error.WriteLineAsync(
                        $"[Shelly] git pull failed for {pkgbase} (likely divergent history). Attempting fresh clone...");
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
                await CleanBuildArtifactsAsync(user, tempPath);

                if (!await RemoveCacheDirAsync(user, tempPath))
                {
                    return false;
                }

                var (cc, _, cerr) = await RunProcessAsync(
                    "sudo", $"-u {user} git clone {expectedRemote} {tempPath}");
                if (cc != 0)
                {
                    await Console.Error.WriteLineAsync(
                        $"[Shelly] git clone failed for {pkgbase}: {cerr.Trim()}");
                    return false;
                }
            }

            var pkgbuildSource = Path.Combine(tempPath, "PKGBUILD");
            return File.Exists(pkgbuildSource);
        }
        catch (Exception ex)
        {
            await Console.Error.WriteLineAsync(
                $"[Shelly] DownloadPackage failed for {packageName}: {ex.Message}");
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
            var user = Environment.GetEnvironmentVariable("SUDO_USER") ?? Environment.UserName;
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
                await ImportFromAurHelperCache(paruCachePath, shellyCachePath, foreignPackages, user);
            }

            // Import from yay cache
            if (Directory.Exists(yayCachePath))
            {
                await ImportFromAurHelperCache(yayCachePath, shellyCachePath, foreignPackages, user);
            }
        }
        catch (Exception ex)
        {
            // Log but don't fail initialization if cache import fails
            await Console.Error.WriteLineAsync($"Warning: Failed to import AUR helper caches: {ex.Message}");
        }
    }

    /// <summary>
    /// Imports package caches from a specific AUR helper's cache directory.
    /// </summary>
    private async Task ImportFromAurHelperCache(string sourceCachePath, string shellyCachePath,
        HashSet<string> foreignPackages, string user)
    {
        try
        {
            var packageDirs = Directory.GetDirectories(sourceCachePath);

            foreach (var packageDir in packageDirs)
            {
                var packageName = Path.GetFileName(packageDir);

                // Only import if the package is currently installed as a foreign package
                if (!foreignPackages.Contains(packageName))
                {
                    continue;
                }

                var shellyPackagePath = Path.Combine(shellyCachePath, packageName);

                // Skip if Shelly already has a cache for this package
                if (Directory.Exists(shellyPackagePath))
                {
                    continue;
                }

                // Check if source has a PKGBUILD
                var sourcePkgbuild = Path.Combine(packageDir, "PKGBUILD");
                if (!File.Exists(sourcePkgbuild))
                {
                    continue;
                }

                // Create Shelly cache directory for this package
                var mkdirProcess = new System.Diagnostics.Process
                {
                    StartInfo = new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "sudo",
                        Arguments = $"-u {user} mkdir -p {shellyPackagePath}",
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    }
                };
                mkdirProcess.Start();
                await mkdirProcess.WaitForExitAsync();

                // Copy the PKGBUILD and other relevant files
                var copyProcess = new System.Diagnostics.Process
                {
                    StartInfo = new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "sudo",
                        Arguments = $"-u {user} cp -r {packageDir}/. {shellyPackagePath}/",
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    }
                };
                copyProcess.Start();
                await copyProcess.WaitForExitAsync();

                // Remove any .git directory to save space (we don't need git history)
                var gitDir = Path.Combine(shellyPackagePath, ".git");
                if (Directory.Exists(gitDir))
                {
                    var rmGitProcess = new System.Diagnostics.Process
                    {
                        StartInfo = new System.Diagnostics.ProcessStartInfo
                        {
                            FileName = "sudo",
                            Arguments = $"-u {user} rm -rf {gitDir}",
                            RedirectStandardOutput = true,
                            RedirectStandardError = true,
                            UseShellExecute = false,
                            CreateNoWindow = true
                        }
                    };
                    rmGitProcess.Start();
                    await rmGitProcess.WaitForExitAsync();
                }
            }
        }
        catch (Exception ex)
        {
            await Console.Error.WriteLineAsync($"Warning: Failed to import from {sourceCachePath}: {ex.Message}");
        }
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
        Console.Error.WriteLine(
            $"[DEBUG] Total deps: {allDeps.Count}, Satisfied: {satisfiedDeps.Count}, To install: {depsToInstall.Count}");
        foreach (var dep in satisfiedDeps)
        {
            Console.Error.WriteLine($"[DEBUG] Already satisfied: {dep}");
        }

        var alpmPackages = new List<string>();
        var aurPackages = new List<ParsedDependency>();

        foreach (var dep in depsToInstall)
        {
            var repoName = _alpm.FindSatisfierInSyncDbs(dep.ToString());
            if (repoName != null)
            {
                Console.Error.WriteLine($"[DEBUG] Need: {dep} -> repo:{repoName}");
                alpmPackages.Add(repoName);
            }
            else
            {
                Console.Error.WriteLine($"[DEBUG] Need: {dep} -> AUR");
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

        Console.Error.WriteLine($"[DEBUG] {pkgbuildInfo.PkgName}: repo={repoPackages.Count}, aur={aurPackages.Count}");

        allRepoPackages.AddRange(repoPackages);

        foreach (var aurDep in aurPackages)
        {
            if (!visited.Add(aurDep.Name))
            {
                continue;
            }

            var success = DownloadPackage(aurDep.Name).Result;
            if (!success)
            {
                Console.Error.WriteLine($"[Shelly] Failed to download {aurDep.Name}");
                continue;
            }

            var tempPath = XdgPaths.ShellyCache(aurDep.Name);
            var depPkgbuildInfo = PkgbuildParser.Parse(Path.Combine(tempPath, "PKGBUILD"));

            if (aurDep.Operator != null)
            {
                var aurVersion = depPkgbuildInfo.GetFullVersion();
                if (!aurDep.IsSatisifiedBy(aurVersion))
                {
                    Console.Error.WriteLine(
                        $"[Shelly] AUR package {aurDep.Name} version {aurVersion} " +
                        $"does not satisfy {aurDep}. Skipping.");
                    continue;
                }
            }

            CollectDepsRecursive(depPkgbuildInfo, allRepoPackages, orderedAurPackages, visited);

            orderedAurPackages.Add(aurDep);
        }
    }

    private void BuildAndInstallAurPackage(ParsedDependency package)
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
            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = 1,
                TotalCount = 1,
                Status = PackageProgressStatus.Building,
                Message = "Building package with makepkg"
            });

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

                BuildOutput?.Invoke(this, new BuildOutputEventArgs
                {
                    PackageName = packageName,
                    Line = e.Data,
                    IsError = false,
                    Percent = percent,
                    ProgressMessage = progressMessage
                });
            };

            buildProcess.ErrorDataReceived += (_, e) =>
            {
                if (string.IsNullOrEmpty(e.Data))
                {
                    return;
                }

                BuildOutput?.Invoke(this, new BuildOutputEventArgs
                {
                    PackageName = packageName,
                    Line = e.Data,
                    IsError = true
                });
            };

            buildProcess.Start();
            buildProcess.BeginOutputReadLine();
            buildProcess.BeginErrorReadLine();
            buildProcess.WaitForExit();
            if (buildProcess.ExitCode != 0)
            {
                Console.Error.WriteLine(
                    $"[Shelly] Failed to build AUR dependency: {packageName} (exit code {buildProcess.ExitCode})");
                return;
            }

            var pkgFile = SelectBuiltPackageFile(tempPath, packageName);
            if (pkgFile is null)
            {
                Console.Error.WriteLine($"[Shelly] No package file matching '{packageName}' produced by makepkg");
                return;
            }

            _alpm.InstallLocalPackage(pkgFile, AlpmTransFlag.AllDeps);
            _alpm.Refresh();
        }
        finally
        {
            _currentlyInstallingAurDeps.Remove(packageName);
        }
    }

    private void InstallCollectedDependencies(
        List<string> allRepoPackages,
        List<ParsedDependency> orderedAurPackages,
        AlpmTransFlag flags = AlpmTransFlag.None)
    {
        Console.Error.WriteLine(
            $"[Shelly] Installing collected dependencies: {allRepoPackages.Count} repo, {orderedAurPackages.Count} AUR");
        if (allRepoPackages.Count > 0)
        {
            _alpm.Refresh();
            _alpm.InstallPackages(allRepoPackages, flags).Wait();
            _alpm.Refresh();
        }

        foreach (var aurDep in orderedAurPackages)
        {
            BuildAndInstallAurPackage(aurDep);
        }
    }

    private void MakePkgAndInstallAurDependency(ParsedDependency package)
    {
        var packageName = package.Name;
        if (!_currentlyInstallingAurDeps.Add(packageName))
        {
            Console.Error.WriteLine($"[Shelly] Skipping {packageName} - circular dependency detected");
            return;
        }

        try
        {
            var success = DownloadPackage(packageName).Result;
            if (!success)
            {
                PackageProgress?.Invoke(this, new PackageProgressEventArgs
                {
                    PackageName = packageName,
                    CurrentIndex = 1,
                    TotalCount = 1,
                    Status = PackageProgressStatus.Failed,
                    Message = "Failed to download package"
                });
                return;
            }

            var pkgbase = _aurSearchManager.GetPackageBaseAsync(packageName).GetAwaiter().GetResult();
            var tempPath = XdgPaths.ShellyCache(pkgbase);
            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = 1,
                TotalCount = 1,
                Status = PackageProgressStatus.Building,
                Message = "Building package with makepkg"
            });
            var pkgbuildInfo = PkgbuildParser.Parse(Path.Combine(tempPath, "PKGBUILD"));
            if (package.Operator != null)
            {
                var aurVersion = pkgbuildInfo.GetFullVersion();
                if (!package.IsSatisifiedBy(aurVersion))
                {
                    Console.Error.WriteLine(
                        $"[Shelly] AUR package {packageName} version {aurVersion} " +
                        $"does not satisfy {package}. Skipping build.");
                    PackageProgress?.Invoke(this, new PackageProgressEventArgs
                    {
                        PackageName = packageName,
                        CurrentIndex = 1,
                        TotalCount = 1,
                        Status = PackageProgressStatus.Failed,
                        Message = $"Version {aurVersion} does not satisfy {package}"
                    });
                    return;
                }
            }

            var (allRepoPackages, orderedAurPackages) = CollectAllDependencies(pkgbuildInfo);
            InstallCollectedDependencies(allRepoPackages, orderedAurPackages, AlpmTransFlag.AllDeps);

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

                BuildOutput?.Invoke(this, new BuildOutputEventArgs
                {
                    PackageName = packageName,
                    Line = e.Data,
                    IsError = false,
                    Percent = percent,
                    ProgressMessage = progressMessage
                });
            };

            buildProcess.ErrorDataReceived += (_, e) =>
            {
                if (string.IsNullOrEmpty(e.Data))
                {
                    return;
                }

                BuildOutput?.Invoke(this, new BuildOutputEventArgs
                {
                    PackageName = packageName,
                    Line = e.Data,
                    IsError = true
                });
            };

            buildProcess.Start();
            buildProcess.BeginOutputReadLine();
            buildProcess.BeginErrorReadLine();
            buildProcess.WaitForExit();
            if (buildProcess.ExitCode != 0)
            {
                Console.Error.WriteLine(
                    $"[Shelly] Failed to build AUR dependency: {packageName} (exit code {buildProcess.ExitCode})");
                return;
            }

            var pkgFile = SelectBuiltPackageFile(tempPath, packageName);
            if (pkgFile is null)
            {
                Console.Error.WriteLine($"[Shelly] No package file matching '{packageName}' produced by makepkg");
                return;
            }

            _alpm.InstallLocalPackage(pkgFile, AlpmTransFlag.AllDeps);
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

        var initProcess = new System.Diagnostics.Process
        {
            StartInfo = new System.Diagnostics.ProcessStartInfo
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
        var updateProcess = new System.Diagnostics.Process
        {
            StartInfo = new System.Diagnostics.ProcessStartInfo
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

    private System.Diagnostics.Process CreateBuildProcess(string tempPath,
        string? makepkgArgs = null)
    {
        makepkgArgs ??= "-f -c --noconfirm --skippgpcheck" + (_noCheck ? " --nocheck" : "");
        if (_useChroot)
        {
            return new System.Diagnostics.Process
            {
                StartInfo = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "makechrootpkg",
                    Arguments = $"-c -r {_chrootPath}",
                    WorkingDirectory = tempPath,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                }
            };
        }

        var user = Environment.GetEnvironmentVariable("SUDO_USER") ?? Environment.UserName;
        var path = Environment.GetEnvironmentVariable("PATH") ??
                   "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin";
        if (!path.Contains("core_perl"))
            path = $"/usr/bin/core_perl:/usr/bin/vendor_perl:/usr/bin/site_perl:{path}";

        var process = new System.Diagnostics.Process
        {
            StartInfo = new System.Diagnostics.ProcessStartInfo
            {
                FileName = "sudo",
                Arguments = $"--preserve-env=PATH -u {user} makepkg {makepkgArgs}",
                WorkingDirectory = tempPath,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            }
        };
        process.StartInfo.Environment["PATH"] = path;
        return process;
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
        var pkgbase = await _aurSearchManager.GetPackageBaseAsync(packageName);
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
    private static async Task<string?> GetRemoteCommitSha(string url, string branch, int timeoutSeconds = 15)
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds));
        try
        {
            var process = new System.Diagnostics.Process
            {
                StartInfo = new System.Diagnostics.ProcessStartInfo
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
            await Console.Error.WriteLineAsync($"Timeout checking git remote: {url}");
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
            await Console.Error.WriteLineAsync($"Warning: Failed to update VCS store for {packageName}: {ex.Message}");
        }
    }

    private static readonly string[] VcsSuffixes = ["-git", "-svn", "-hg", "-bzr", "-darcs", "-cvs"];

    private static bool IsVcsPackage(string packageName)
    {
        return VcsSuffixes.Any(suffix => packageName.EndsWith(suffix, StringComparison.OrdinalIgnoreCase));
    }
}