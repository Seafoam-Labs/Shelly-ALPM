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
    public bool ShowDiff { get; set; }
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
public class AurPackageManager(string? configPath = null)
    : IAurPackageManager
{
    private AlpmManager _alpm;
    private AurSearchManager _aurSearchManager;
    private HttpClient _httpClient = CreateAurHttpClient();

    private static HttpClient CreateAurHttpClient()
    {
        var client = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(20),
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Shelly/1.0 (+https://github.com/zoe-codez/Shelly-ALPM)");
        return client;
    }
    private List<string> _availablePackages = [];
    private readonly HashSet<string> _currentlyInstallingAurDeps = new();
    private bool _useChroot = false;
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
        _alpm.Question += (sender, args) => Question?.Invoke(this, args);
        _alpm.Progress += (sender, args) => Progress?.Invoke(this, args);
        _alpm.PackageOperation += (sender, args) => PackageOperation?.Invoke(this, args);
        _alpm.ScriptletInfo += (sender, args) => ScriptletInfo?.Invoke(this, args);
        _alpm.HookRun += (sender, args) => HookRun?.Invoke(this, args);
        _alpm.Replaces += (sender, args) => Replaces?.Invoke(this, args);
        _alpm.PacnewInfo += (sender, args) => PacnewInfo?.Invoke(this, args);
        _alpm.PacsaveInfo += (sender, args) => PacsaveInfo?.Invoke(this, args);
        _alpm.ErrorEvent += (sender, args) => ErrorEvent?.Invoke(this, args);
        _aurSearchManager = new AurSearchManager(_httpClient);
        _availablePackages = _alpm.GetAvailablePackages().Select(x => x.Name).ToList();
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
        var results = searchResponse.Results ?? [];

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
        return infoResponse.Results ?? [];
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
            var cachedPkgbuildPath = System.IO.Path.Combine(tempPath, "PKGBUILD");
            string? oldPkgbuild = null;

            if (System.IO.File.Exists(cachedPkgbuildPath))
            {
                oldPkgbuild = await System.IO.File.ReadAllTextAsync(cachedPkgbuildPath);
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
                    ShowDiff = false,
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
            await InstallPackages(packagesToUpdate);
        }
    }

    public async Task<string?> FetchPkgbuildAsync(string packageName)
    {
        try
        {
            // Resolve pkgname -> pkgbase: split AUR packages live under their pkgbase repo
            var pkgbase = await _aurSearchManager.GetPackageBaseAsync(packageName);
            Console.Error.WriteLine($"pkgbase {pkgbase}");
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
        var pkgbuildInfo = PkgbuildParser.Parse(System.IO.Path.Combine(tempPath, "PKGBUILD"));

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

    public async Task InstallPackages(List<string> packageNames)
    {
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
            PkgbuildDiffRequest?.Invoke(this,new PkgbuildDiffRequestEventArgs()
            {
                PackageName = packageName,
                OldPkgbuild = string.Empty,
                NewPkgbuild = newPkgbuild,
                ShowDiff = false,
                ProceedWithUpdate = true
            });

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
            var pkgbuildInfo = PkgbuildParser.Parse(System.IO.Path.Combine(tempPath, "PKGBUILD"));

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
            Console.Error.WriteLine($"dependency count {allRepoPackages.Count + orderedAurPackages.Count}");
            InstallCollectedDependencies(allRepoPackages, orderedAurPackages, AlpmTransFlag.AllDeps);


            // Backup PKGBUILD to PreviousVersions folder
            var previousVersionsPath = System.IO.Path.Combine(tempPath, "PreviousVersions");
            var pkgbuildPath = System.IO.Path.Combine(tempPath, "PKGBUILD");
            if (System.IO.File.Exists(pkgbuildPath))
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

                var existingBackups = System.IO.Directory.Exists(previousVersionsPath)
                    ? System.IO.Directory.GetFiles(previousVersionsPath, "PKGBUILD.*")
                    : Array.Empty<string>();
                var nextNumber = existingBackups.Length + 1;
                var backupPath = System.IO.Path.Combine(previousVersionsPath, $"PKGBUILD.{nextNumber}");

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
            foreach (var oldPkgFile in System.IO.Directory.GetFiles(tempPath, "*.pkg.tar.*"))
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
            buildProcess.OutputDataReceived += (sender, e) =>
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

            buildProcess.ErrorDataReceived += (sender, e) =>
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
                await UpdateVcsStoreForPackage(packageName, System.IO.Path.Combine(tempPath, "PKGBUILD"));
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
                    _alpm.RemovePackages(buildOnlyDeps, AlpmTransFlag.None);
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

            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = i + 1,
                TotalCount = totalCount,
                Status = PackageProgressStatus.Completed
            });
        }
    }

    public async Task RemovePackages(List<string> packageNames, AlpmTransFlag flags = AlpmTransFlag.None)
    {
        _alpm.RemovePackages(packageNames, flags);
        foreach (var packageName in packageNames)
        {
            _vcsInfoStore.RemovePackage(packageName);
            // Clean up cache folder
            var user = Environment.GetEnvironmentVariable("SUDO_USER") ?? Environment.UserName;
            var cachePath = XdgPaths.ShellyCache(packageName);

            if (System.IO.Directory.Exists(cachePath))
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
        _httpClient?.Dispose();
        _aurSearchManager?.Dispose();
        _alpm?.Dispose();
    }

    private static string? SelectBuiltPackageFile(string tempPath, string packageName)
    {
        if (!System.IO.Directory.Exists(tempPath))
        {
            return null;
        }

        var allPkgFiles = System.IO.Directory.GetFiles(tempPath, "*.pkg.tar.*")
            .Where(p => !p.EndsWith(".sig", StringComparison.Ordinal))
            .ToList();

        if (allPkgFiles.Count == 0)
        {
            return null;
        }

        var prefix = packageName + "-";
        var match = allPkgFiles.FirstOrDefault(p =>
            System.IO.Path.GetFileName(p).StartsWith(prefix, StringComparison.Ordinal));

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

        var user = Environment.GetEnvironmentVariable("SUDO_USER") ?? Environment.UserName;
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

        var pkgbuildInfo = PkgbuildParser.Parse(System.IO.Path.Combine(tempPath, "PKGBUILD"));

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
        buildProcess.OutputDataReceived += (sender, e) =>
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

        buildProcess.ErrorDataReceived += (sender, e) =>
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
                _alpm.RemovePackages(buildOnlyDeps, AlpmTransFlag.None);
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

    private static async Task<bool> RemoveCacheDirAsync(string user, string tempPath)
    {
        if (!System.IO.Directory.Exists(tempPath))
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

            var pkgbuildSource = System.IO.Path.Combine(tempPath, "PKGBUILD");
            return System.IO.File.Exists(pkgbuildSource);
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
            Console.Error.WriteLine($"Downloading {pkgbase} from AUR");

            var hasGit = System.IO.Directory.Exists(System.IO.Path.Combine(tempPath, ".git"));
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
                var (pc, _, perr) = await RunProcessAsync(
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

            var pkgbuildSource = System.IO.Path.Combine(tempPath, "PKGBUILD");
            return System.IO.File.Exists(pkgbuildSource);
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
            var paruCachePath = System.IO.Path.Combine(home, ".cache", "paru", "clone");
            var yayCachePath = System.IO.Path.Combine(home, ".cache", "yay");

            // Import from paru cache
            if (System.IO.Directory.Exists(paruCachePath))
            {
                await ImportFromAurHelperCache(paruCachePath, shellyCachePath, foreignPackages, user);
            }

            // Import from yay cache
            if (System.IO.Directory.Exists(yayCachePath))
            {
                await ImportFromAurHelperCache(yayCachePath, shellyCachePath, foreignPackages, user);
            }
        }
        catch (Exception ex)
        {
            // Log but don't fail initialization if cache import fails
            Console.Error.WriteLine($"Warning: Failed to import AUR helper caches: {ex.Message}");
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
            var packageDirs = System.IO.Directory.GetDirectories(sourceCachePath);

            foreach (var packageDir in packageDirs)
            {
                var packageName = System.IO.Path.GetFileName(packageDir);

                // Only import if the package is currently installed as a foreign package
                if (!foreignPackages.Contains(packageName))
                {
                    continue;
                }

                var shellyPackagePath = System.IO.Path.Combine(shellyCachePath, packageName);

                // Skip if Shelly already has a cache for this package
                if (System.IO.Directory.Exists(shellyPackagePath))
                {
                    continue;
                }

                // Check if source has a PKGBUILD
                var sourcePkgbuild = System.IO.Path.Combine(packageDir, "PKGBUILD");
                if (!System.IO.File.Exists(sourcePkgbuild))
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
                var gitDir = System.IO.Path.Combine(shellyPackagePath, ".git");
                if (System.IO.Directory.Exists(gitDir))
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
            Console.Error.WriteLine($"Warning: Failed to import from {sourceCachePath}: {ex.Message}");
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
            var depPkgbuildInfo = PkgbuildParser.Parse(System.IO.Path.Combine(tempPath, "PKGBUILD"));

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
            buildProcess.OutputDataReceived += (sender, e) =>
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

            buildProcess.ErrorDataReceived += (sender, e) =>
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
            _availablePackages = _alpm.GetAvailablePackages().Select(x => x.Name).ToList();
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
            _availablePackages = _alpm.GetAvailablePackages().Select(x => x.Name).ToList();
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
            var pkgbuildInfo = PkgbuildParser.Parse(System.IO.Path.Combine(tempPath, "PKGBUILD"));
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
            buildProcess.OutputDataReceived += (sender, e) =>
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

            buildProcess.ErrorDataReceived += (sender, e) =>
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
            _availablePackages = _alpm.GetAvailablePackages().Select(x => x.Name).ToList();
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
        if (storedEntries == null || storedEntries.Count == 0)
        {
            var entries = await GetVcsSourceEntriesForPackage(packageName);
            if (entries == null || entries.Count == 0)
                return false;

            // Populate the store with current remote SHAs so next check can compare
            foreach (var entry in entries)
            {
                if (string.IsNullOrEmpty(entry.Branch))
                    continue;
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
            if (string.IsNullOrEmpty(entry.Branch))
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
        if (string.IsNullOrEmpty(branch))
            return null;

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
                if (string.IsNullOrEmpty(entry.Branch))
                    continue;
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