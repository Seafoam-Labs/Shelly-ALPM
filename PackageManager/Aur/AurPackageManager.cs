using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using PackageManager.Alpm;
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

public enum PackageProgressStatus
{
    Downloading,
    Building,
    Installing,
    Completed,
    Failed
}

/// <summary>
/// This is a manager for Arch universal repositories. It relies on <see cref="AlpmManager"/> to handle downloading and
/// installation of packages from the Arch User Repository (AUR).
/// </summary>
public class AurPackageManager(string? configPath = null, bool verbose = false, bool uiMode = false)
    : IAurPackageManager
{
    private AlpmManager _alpm;
    private AurSearchManager _aurSearchManager;
    private HttpClient _httpClient = new HttpClient();
    private bool _verbose = verbose;
    private bool _uiMode = uiMode;
    private List<string> _availablePackages = [];
    private readonly HashSet<string> _currentlyInstallingAurDeps = new();

    public event EventHandler<PackageProgressEventArgs>? PackageProgress;
    public event EventHandler<PkgbuildDiffRequestEventArgs>? PkgbuildDiffRequest;
    public event EventHandler<AlpmQuestionEventArgs>? Question;
    public event EventHandler<AlpmProgressEventArgs>? Progress;

    public async Task Initialize(bool root = false, bool useTempPath = false, string tempPath = "")
    {
        _alpm = configPath is null ? new AlpmManager() : new AlpmManager(_verbose, _uiMode, configPath);
        _alpm.Initialize(root, useTempPath, tempPath);
        _alpm.Question += (sender, args) => Question?.Invoke(this, args);
        _alpm.Progress += (sender, args) => Progress?.Invoke(this, args);
        _aurSearchManager = new AurSearchManager(_httpClient);
        _availablePackages = _alpm.GetAvailablePackages().Select(x => x.Name).ToList();
        // Import caches from other AUR helpers (paru, yay) for installed foreign packages
        await ImportOtherAurHelperCaches();
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
        var suggestResponse = await _aurSearchManager.SuggestAsync(query);
        var suggestByBaseNameResponse = await _aurSearchManager.SuggestByPackageBaseNamesAsync(query);
        //this might fail if AUR is down.
        return searchResponse.Results.Concat(suggestResponse.Results)
            .Concat(suggestByBaseNameResponse.Results)
            .DistinctBy(x => x.Name)
            .ToList();
    }

    public async Task<List<AurUpdateDto>> GetPackagesNeedingUpdate()
    {
        List<AurUpdateDto> packagesToUpdate = [];
        var packages = _alpm.GetForeignPackages();
        var response = await _aurSearchManager.GetInfoAsync(packages.Select(x => x.Name).ToList());
        foreach (var pkg in response.Results)
        {
            var installedPkg = packages.FirstOrDefault(x => x.Name == pkg.Name);
            if (installedPkg is null) continue;
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
            }
        }

        return packagesToUpdate;
    }

    public async Task UpdatePackages(List<string> packageNames)
    {
        var packagesToUpdate = new List<string>();

        foreach (var packageName in packageNames)
        {
            // Check if there's an existing PKGBUILD (cached from previous install)
            var user = Environment.GetEnvironmentVariable("SUDO_USER") ?? Environment.UserName;
            var home = $"/home/{user}";
            var tempPath = System.IO.Path.Combine(home, ".cache", "Shelly", packageName);
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
            var url = $"https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h={packageName}";
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

        var user = Environment.GetEnvironmentVariable("SUDO_USER") ?? Environment.UserName;
        var home = $"/home/{user}";
        var tempPath = System.IO.Path.Combine(home, ".cache", "Shelly", packageName);
        var pkgbuildInfo = PkgbuildParser.Parse(System.IO.Path.Combine(tempPath, "PKGBUILD"));

        var depends = pkgbuildInfo.Depends.Select(x => x.Trim()).ToList();
        var depsToConsider = depends.ToList();

        if (includeMakeDeps)
        {
            var makeDepends = pkgbuildInfo.MakeDepends.Select(x => x.Trim()).ToList();
            depsToConsider = depsToConsider.Concat(makeDepends).Distinct().ToList();
        }

        var depsToInstall = depsToConsider.Where(x => !_alpm.IsDependencySatisfiedByInstalled(x)).ToList();

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

        var alpmPackages = _availablePackages.Where(x => depsToInstall.Contains(x)).ToList();
        var aurPackages = depsToInstall.Where(x => !alpmPackages.Contains(x)).ToList();
        if (alpmPackages.Count > 0)
        {
            _alpm.InstallPackages(alpmPackages);
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
            
            var home = $"/home/{user}";
            var tempPath = System.IO.Path.Combine(home, ".cache", "Shelly", packageName);
            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = i + 1,
                TotalCount = totalCount,
                Status = PackageProgressStatus.Building,
                Message = "Building package with makepkg"
            });
            var pkgbuildInfo = PkgbuildParser.Parse(System.IO.Path.Combine(tempPath, "PKGBUILD"));
            var depends = pkgbuildInfo.Depends.Select(x => x.Trim()).ToList();
            var makeDepends = pkgbuildInfo.MakeDepends.Select(x => x.Trim()).ToList();
            var allDeps = depends.Concat(makeDepends).Distinct().ToList();
            var depsToInstall = allDeps.Where(x => !_alpm.IsDependencySatisfiedByInstalled(x)).ToList();
            Console.Error.WriteLine($"dependency count {depsToInstall.Count}");
            var alpmPackages = _availablePackages.Where(x => depsToInstall.Contains(x)).ToList();
            var aurPackages = depsToInstall.Where(x => !alpmPackages.Contains(x)).ToList();
            if (alpmPackages.Count > 0)
            {
                _alpm.InstallPackages(alpmPackages);
            }

            foreach (var pkg in aurPackages)
            {
                MakePkgAndInstallAurDependency(pkg);
            }


            // Backup PKGBUILD to PreviousVersions folder
            var previousVersionsPath = System.IO.Path.Combine(tempPath, "PreviousVersions");
            System.IO.Directory.CreateDirectory(previousVersionsPath);
            var pkgbuildPath = System.IO.Path.Combine(tempPath, "PKGBUILD");
            if (System.IO.File.Exists(pkgbuildPath))
            {
                var existingBackups = System.IO.Directory.GetFiles(previousVersionsPath, "PKGBUILD.*");
                var nextNumber = existingBackups.Length + 1;
                var backupPath = System.IO.Path.Combine(previousVersionsPath, $"PKGBUILD.{nextNumber}");
                System.IO.File.Copy(pkgbuildPath, backupPath, overwrite: true);
            }

            // Remove any existing package files before building
            foreach (var oldPkgFile in System.IO.Directory.GetFiles(tempPath, "*.pkg.tar.*"))
            {
                System.IO.File.Delete(oldPkgFile);
            }

            var buildProcess = new System.Diagnostics.Process
            {
                StartInfo = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "sudo",
                    Arguments = $"-u {user} makepkg -f --noconfirm --skippgpcheck",
                    WorkingDirectory = tempPath,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                }
            };
            buildProcess.OutputDataReceived += (sender, e) =>
            {
                if (e.Data?.Contains('%') == true)
                {
                    var match = Regex.Match(e.Data, @"\[\s*(?<percent>\d+)%\]\s+(?<message>.+)");

                    if (!match.Success) return;
                    var percent = match.Groups["percent"].Value;
                    var message = match.Groups["message"].Value;
                    if (!string.IsNullOrEmpty(e.Data))
                        Console.Error.WriteLine($"[AUR_PROGRESS]Percent: {percent}% Message: {message}");
                }
                else
                {
                    if (!string.IsNullOrEmpty(e.Data))
                        Console.Error.WriteLine($"[Shelly] makepkg: {e.Data}");
                }
            };

            buildProcess.ErrorDataReceived += (sender, e) =>
            {
                if (!string.IsNullOrEmpty(e.Data))
                    Console.Error.WriteLine($"[Shelly] makepkg error: {e.Data}");
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

            // Find the built package file
            var pkgFiles = System.IO.Directory.GetFiles(tempPath, "*.pkg.tar.*");
            if (pkgFiles.Length == 0)
            {
                PackageProgress?.Invoke(this, new PackageProgressEventArgs
                {
                    PackageName = packageName,
                    CurrentIndex = i + 1,
                    TotalCount = totalCount,
                    Status = PackageProgressStatus.Failed,
                    Message = "No package file found after build"
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
                _alpm.InstallLocalPackage(pkgFiles[0]);
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

            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = i + 1,
                TotalCount = totalCount,
                Status = PackageProgressStatus.Completed
            });
        }
    }

    public async Task RemovePackages(List<string> packageNames)
    {
        foreach (var packageName in packageNames)
        {
            // Remove package via ALPM
            _alpm.RemovePackage(packageName);

            // Clean up cache folder
            var user = Environment.GetEnvironmentVariable("SUDO_USER") ?? Environment.UserName;
            var home = $"/home/{user}";
            var cachePath = System.IO.Path.Combine(home, ".cache", "Shelly", packageName);

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
    }

    public void Dispose()
    {
        _httpClient?.Dispose();
        _aurSearchManager?.Dispose();
        _alpm?.Dispose();
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
        var home = $"/home/{user}";
        var tempPath = System.IO.Path.Combine(home, ".cache", "Shelly", packageName);

        PackageProgress?.Invoke(this, new PackageProgressEventArgs
        {
            PackageName = packageName,
            CurrentIndex = 1,
            TotalCount = 1,
            Status = PackageProgressStatus.Building,
            Message = "Building package with makepkg"
        });

        var pkgbuildInfo = PkgbuildParser.Parse(System.IO.Path.Combine(tempPath, "PKGBUILD"));
        var depends = pkgbuildInfo.Depends.Select(x => x.Trim()).ToList();
        var makeDepends = pkgbuildInfo.MakeDepends.Select(x => x.Trim()).ToList();
        var allDeps = depends.Concat(makeDepends).Distinct().ToList();
        var depsToInstall = allDeps.Where(x => !_alpm.IsDependencySatisfiedByInstalled(x)).ToList();
        var availablePackages = _alpm.GetAvailablePackages();
        var alpmPackages = availablePackages.Where(x => depsToInstall.Contains(x.Name)).Select(x => x.Name).ToList();
        var aurPackages = depsToInstall.Where(x => !alpmPackages.Contains(x)).ToList();
        if (alpmPackages.Count > 0)
        {
            _alpm.InstallPackages(alpmPackages);
        }

        foreach (var pkg in aurPackages)
        {
            MakePkgAndInstallAurDependency(pkg);
        }


        var buildProcess = new System.Diagnostics.Process
        {
            StartInfo = new System.Diagnostics.ProcessStartInfo
            {
                FileName = "sudo",
                Arguments = $"-u {user} makepkg --noconfirm",
                WorkingDirectory = tempPath,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            }
        };
        buildProcess.OutputDataReceived += (sender, e) =>
        {
            if (!string.IsNullOrEmpty(e.Data))
                Console.Error.WriteLine($"[Shelly] makepkg: {e.Data}");
        };

        buildProcess.ErrorDataReceived += (sender, e) =>
        {
            if (!string.IsNullOrEmpty(e.Data))
                Console.Error.WriteLine($"[Shelly] makepkg error: {e.Data}");
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

        var pkgFiles = System.IO.Directory.GetFiles(tempPath, "*.pkg.tar.*");
        if (pkgFiles.Length == 0)
        {
            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = 1,
                TotalCount = 1,
                Status = PackageProgressStatus.Failed,
                Message = "No package file found after build"
            });
            throw new Exception($"No package file found after building {packageName}");
        }

        PackageProgress?.Invoke(this, new PackageProgressEventArgs
        {
            PackageName = packageName,
            CurrentIndex = 1,
            TotalCount = 1,
            Status = PackageProgressStatus.Installing
        });

        _alpm.InstallLocalPackage(pkgFiles[0]);

        PackageProgress?.Invoke(this, new PackageProgressEventArgs
        {
            PackageName = packageName,
            CurrentIndex = 1,
            TotalCount = 1,
            Status = PackageProgressStatus.Completed
        });
    }

    private async Task<bool> DownloadPackageAtCommit(string packageName, string commit)
    {
        try
        {
            var user = Environment.GetEnvironmentVariable("SUDO_USER") ?? Environment.UserName;
            var home = $"/home/{user}";
            var tempPath = System.IO.Path.Combine(home, ".cache", "Shelly", packageName);

            // Remove existing directory if it exists
            if (System.IO.Directory.Exists(tempPath))
            {
                var rmProcess = new System.Diagnostics.Process
                {
                    StartInfo = new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "rm",
                        Arguments = $"-rf {tempPath}",
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    }
                };
                rmProcess.Start();
                await rmProcess.WaitForExitAsync();
            }

            // Clone the AUR git repository
            var cloneProcess = new System.Diagnostics.Process
            {
                StartInfo = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "sudo",
                    Arguments = $"-u {user} git clone https://aur.archlinux.org/{packageName}.git {tempPath}",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                }
            };
            cloneProcess.Start();
            await cloneProcess.WaitForExitAsync();

            if (cloneProcess.ExitCode != 0)
            {
                return false;
            }

            // Checkout the specific commit
            var checkoutProcess = new System.Diagnostics.Process
            {
                StartInfo = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "sudo",
                    Arguments = $"-u {user} git checkout {commit}",
                    WorkingDirectory = tempPath,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                }
            };
            checkoutProcess.Start();
            await checkoutProcess.WaitForExitAsync();

            if (checkoutProcess.ExitCode != 0)
            {
                return false;
            }

            // Verify PKGBUILD exists
            var pkgbuildSource = System.IO.Path.Combine(tempPath, "PKGBUILD");
            return System.IO.File.Exists(pkgbuildSource);
        }
        catch
        {
            return false;
        }
    }

    private async Task<bool> DownloadPackage(string packageName)
    {
        try
        {
            var url = $"https://aur.archlinux.org/cgit/aur.git/snapshot/{packageName}.tar.gz";
            var user = Environment.GetEnvironmentVariable("SUDO_USER") ?? Environment.UserName;
            var home = $"/home/{user}";
            var tempPath = System.IO.Path.Combine(home, ".cache", "Shelly", packageName);

            // Download the package tarball
            var response = await _httpClient.GetAsync(url);
            if (!response.IsSuccessStatusCode)
            {
                return false;
            }

            // Create temp directory if it doesn't exist (run as non-root user)
            if (!System.IO.Directory.Exists(tempPath))
            {
                var mkdirProcess = new System.Diagnostics.Process
                {
                    StartInfo = new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "sudo",
                        Arguments = $"-u {user} mkdir -p {tempPath}",
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    }
                };
                mkdirProcess.Start();
                await mkdirProcess.WaitForExitAsync();
            }

            // Save the tarball
            var tarballPath = System.IO.Path.Combine(tempPath, $"{packageName}.tar.gz");
            await using (var fileStream = System.IO.File.Create(tarballPath))
            {
                await response.Content.CopyToAsync(fileStream);
            }

            // Extract the tarball (run as non-root user)
            var extractProcess = new System.Diagnostics.Process
            {
                StartInfo = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "sudo",
                    Arguments = $"-u {user} tar -xzf {tarballPath} -C {tempPath} --strip-components=1",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                }
            };
            extractProcess.Start();
            await extractProcess.WaitForExitAsync();

            if (extractProcess.ExitCode != 0)
            {
                return false;
            }

            // Verify PKGBUILD exists
            var pkgbuildSource = System.IO.Path.Combine(tempPath, "PKGBUILD");
            return System.IO.File.Exists(pkgbuildSource);
        }
        catch
        {
            return false;
        }
    }

    private static bool IsDependencySatisfied(string dependency, Dictionary<string, string> installedPackages)
    {
        // Parse dependency: "package>=1.0", "package>2.0", "package=1.5", etc.
        var match = Regex.Match(dependency, @"^([a-zA-Z0-9@._+-]+)(>=|<=|>|<|=)?(.+)?$");
        if (!match.Success) return false;

        var pkgName = match.Groups[1].Value;
        var op = match.Groups[2].Value;
        var requiredVersion = match.Groups[3].Value;

        if (!installedPackages.TryGetValue(pkgName, out var installedVersion))
            return false; // Not installed

        if (string.IsNullOrEmpty(op))
            return true; // No version constraint, just needs to be installed

        var cmp = VersionComparer.Compare(installedVersion, requiredVersion);

        return op switch
        {
            ">=" => cmp >= 0,
            "<=" => cmp <= 0,
            ">" => cmp > 0,
            "<" => cmp < 0,
            "=" => cmp == 0,
            _ => true
        };
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
            var home = $"/home/{user}";
            var shellyCachePath = System.IO.Path.Combine(home, ".cache", "Shelly");

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
                    continue;

                var shellyPackagePath = System.IO.Path.Combine(shellyCachePath, packageName);

                // Skip if Shelly already has a cache for this package
                if (System.IO.Directory.Exists(shellyPackagePath))
                    continue;

                // Check if source has a PKGBUILD
                var sourcePkgbuild = System.IO.Path.Combine(packageDir, "PKGBUILD");
                if (!System.IO.File.Exists(sourcePkgbuild))
                    continue;

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

    private void MakePkgAndInstallAurDependency(string packageName)
    {
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

            var user = Environment.GetEnvironmentVariable("SUDO_USER") ?? Environment.UserName;
            var home = $"/home/{user}";
            var tempPath = System.IO.Path.Combine(home, ".cache", "Shelly", packageName);
            PackageProgress?.Invoke(this, new PackageProgressEventArgs
            {
                PackageName = packageName,
                CurrentIndex = 1,
                TotalCount = 1,
                Status = PackageProgressStatus.Building,
                Message = "Building package with makepkg"
            });
            var pkgbuildInfo = PkgbuildParser.Parse(System.IO.Path.Combine(tempPath, "PKGBUILD"));
            var depends = pkgbuildInfo.Depends.Select(x => x.Trim()).ToList();
            var makeDepends = pkgbuildInfo.MakeDepends.Select(x => x.Trim()).ToList();
            var allDeps = depends.Concat(makeDepends).Distinct().ToList();
            var depsToInstall = allDeps.Where(x => !_alpm.IsDependencySatisfiedByInstalled(x)).ToList();
            var alpmPackages = _availablePackages.Where(x => depsToInstall.Contains(x)).ToList();
            var aurPackages = depsToInstall.Where(x => !alpmPackages.Contains(x)).ToList();
            if (alpmPackages.Count > 0)
            {
                _alpm.InstallPackages(alpmPackages);
            }

            foreach (var pkg in aurPackages)
            {
                MakePkgAndInstallAurDependency(pkg);
            }

            var buildProcess = new System.Diagnostics.Process
            {
                StartInfo = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "sudo",
                    Arguments = $"-u {user} makepkg -f --noconfirm --skippgpcheck",
                    WorkingDirectory = tempPath,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                }
            };
            buildProcess.OutputDataReceived += (sender, e) =>
            {
                if (e.Data?.Contains('%') == true)
                {
                    var match = Regex.Match(e.Data, @"\[\s*(?<percent>\d+)%\]\s+(?<message>.+)");

                    if (!match.Success) return;
                    var percent = match.Groups["percent"].Value;
                    var message = match.Groups["message"].Value;
                    if (!string.IsNullOrEmpty(e.Data))
                        Console.Error.WriteLine($"[AUR_PROGRESS]Percent: {percent}% Message: {message}");
                }
                else
                {
                    if (!string.IsNullOrEmpty(e.Data))
                        Console.Error.WriteLine($"[Shelly] makepkg: {e.Data}");
                }
            };

            buildProcess.ErrorDataReceived += (sender, e) =>
            {
                if (!string.IsNullOrEmpty(e.Data))
                    Console.Error.WriteLine($"[Shelly] makepkg error: {e.Data}");
            };

            buildProcess.Start();
            buildProcess.BeginOutputReadLine();
            buildProcess.BeginErrorReadLine();
            buildProcess.WaitForExit();
            if (buildProcess.ExitCode != 0)
            {
                Console.Error.WriteLine($"[Shelly] Failed to build AUR dependency: {packageName} (exit code {buildProcess.ExitCode})");
                return;
            }

            var pkgFiles = System.IO.Directory.GetFiles(tempPath, "*.pkg.tar.*");
            if (pkgFiles.Length == 0)
            {
                Console.Error.WriteLine($"[Shelly] No package file found after building: {packageName}");
                return;
            }
            _alpm.InstallLocalPackage(pkgFiles[0]);
            _alpm.Refresh();
            alpmPackages = _alpm.GetAvailablePackages().Select(x => x.Name).ToList();
        }
        finally

        {
            _currentlyInstallingAurDeps.Remove(packageName);
        }
    }
}