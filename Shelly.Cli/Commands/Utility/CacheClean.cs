using System.CommandLine;
using PackageManager.Alpm;
using Pastel;
using Shelly.Cli.Commands.Utility.Helpers;
using Shelly.Cli.Interactions;
using Shelly.Utilities;
using Shelly.Utilities.Enums;

namespace Shelly.Cli.Commands.Utility;

public partial class CacheClean : GlobalSettingsCommand
{
    private int Keep { get; set; } = 3;

    private bool TargetUninstalled { get; set; } = false;

    private bool DryRun { get; set; } = false;

    private string? CacheDir { get; set; } = "/var/cache/pacman/pkg";

    private string[] TargetPackages { get; set; } = Array.Empty<string>();

    public static Command Create()
    {
        var keep = new Option<int>("--keep", "-k") { Description = "Keep the specified number of versions in the cache. Defaults to 3.", DefaultValueFactory = _ => 3 };
        var uninstalled = new Option<bool>("--uninstalled", "-i") { Description = "Remove only uninstalled packages from the cache." };
        var dryRun = new Option<bool>("--dry-run", "-d") { Description = "Show what would be removed." };
        var cacheDir = new Option<string?>("--cache-dir", "-c") { Description = "Path to the cache directory.", DefaultValueFactory = _ => "/var/cache/pacman/pkg" };
        var target = new Option<string[]>("--target", "-t") { Description = "Remove only the specified packages from the cache.", AllowMultipleArgumentsPerToken = true };

        var command = new Command("cache-clean", "Clean the local cache") { keep, uninstalled, dryRun, cacheDir, target };

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new CacheClean
            {
                Keep = parseResult.GetValue(keep),
                TargetUninstalled = parseResult.GetValue(uninstalled),
                DryRun = parseResult.GetValue(dryRun),
                CacheDir = parseResult.GetValue(cacheDir),
                TargetPackages = parseResult.GetValue(target) ?? Array.Empty<string>()
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        if (!DryRun)
        {
            RootElevator.EnsureRootExectuion();
        }

        var isAnsiSupported = AnsiUtilities.SupportsAnsi;
        var message = "";
        if (!Directory.Exists(CacheDir))
        {
            message = isAnsiSupported
                ? $"Cache directory does not exist: {CacheDir}".Pastel(ConsoleColor.Red)
                : $"Cache directory does not exist: {CacheDir}";
            console.WriteLine(message);
            return;
        }

        var entries = Directory.EnumerateFiles(CacheDir)
            .Select(CacheCleanHelper.ParsePackageFilename)
            .Where(e => e != null)
            .Cast<CacheEntry>()
            .ToList();
        if (entries.Count == 0)
        {
            message = isAnsiSupported
                ? "No package files found in cache directory.".Pastel(ConsoleColor.Yellow)
                : "No package files found in cache directory.";
            console.WriteLine(message);
            return;
        }

        var grouped = entries.GroupBy(e => e.Name).ToDictionary(g => g.Key, g => g.ToList());
        var candidates = new List<CacheEntry>();
        foreach (var (name, pkgEntries) in grouped)
        {
            pkgEntries.Sort((a, b) => AlpmManager.VersionCompare(a.Version, b.Version));
            var toRemove = pkgEntries.Take(Math.Max(0, pkgEntries.Count - Keep));
            candidates.AddRange(toRemove);
        }

        if (TargetUninstalled)
        {
            using var manager = new AlpmManager();
            var installedNames = manager.GetInstalledPackages().Select(p => p.Name).ToHashSet();
            candidates = candidates.Where(e => !installedNames.Contains(e.Name)).ToList();
        }

        if (TargetPackages.Length > 0)
        {
            candidates = candidates.Where(e =>
                TargetPackages.Any(package => e.Name.StartsWith(package, StringComparison.OrdinalIgnoreCase))).ToList();
        }

        if (candidates.Count == 0)
        {
            message = isAnsiSupported
                ? $"No candidate packages to remove.".Pastel(ConsoleColor.Green)
                : "No candidate packages to remove.";
            console.WriteLine(message);
            return;
        }

        var totalSize = candidates.Sum(c => c.FileSize);
        var config = ConfigManager.ReadConfig();
        var parsedSize = Enum.Parse<SizeDisplay>(config.FileSizeDisplay);
        var sizedTotalSize = SizeUtilities.FormatSize(parsedSize, totalSize);
        if (DryRun)
        {
            message = isAnsiSupported
                ? $"Dry run: {candidates.Count} packages would be removed. Removing a total size amount {sizedTotalSize}."
                    .Pastel(ConsoleColor.Yellow)
                : $"Dry run: {candidates.Count} packages would be removed. Removing a total size amount {sizedTotalSize}.";
            console.WriteLine(message);
            BasicTable.Execute(["Package", "Version", "Size"], candidates, c => c.Name,
                c => c.Version,
                c => SizeUtilities.FormatSize(parsedSize, c.FileSize));
            return;
        }

        List<string> sigFiles = [];
        sigFiles.AddRange(candidates.Select(candidate => $"{candidate.FullPath}.sig")
            .Where(File.Exists));
        message = isAnsiSupported
            ? $"Removing {candidates.Count} packages. Removing a total size amount {sizedTotalSize}.".Pastel(
                ConsoleColor.Yellow)
            : $"Removing {candidates.Count} packages. Removing a total size amount {sizedTotalSize}.";
        console.WriteLine(message);

        if (Verbose)
        {
            BasicTable.Execute(["Package", "Version", "Size"], candidates, c => c.Name,
                c => c.Version,
                c => SizeUtilities.FormatSize(parsedSize, c.FileSize));
        }

        foreach (var sig in sigFiles)
        {
            if (Verbose)
            {
                message = isAnsiSupported
                    ? $"Removing signature file: {sig}".Pastel(ConsoleColor.Yellow)
                    : $"Removing signature file: {sig}";
                console.WriteLine(message);
            }

            File.Delete(sig);
        }

        foreach (var candidate in candidates)
        {
            try
            {
                if (Verbose)
                {
                    message = isAnsiSupported
                        ? $"Removing package file: {candidate.FullPath}".Pastel(ConsoleColor.Yellow)
                        : $"Removing package file: {candidate.FullPath}";
                    console.WriteLine(message);
                }

                File.Delete(candidate.FullPath);
                var sigPath = $"{candidate.FullPath}.sig";
                if (Verbose)
                {
                    message = isAnsiSupported
                        ? $"Removing signature file: {sigPath}".Pastel(ConsoleColor.Yellow)
                        : $"Removing signature file: {sigPath}";
                    console.WriteLine(message);
                }

                if (File.Exists(sigPath))
                {
                    File.Delete(sigPath);
                }
            }
            catch (Exception e)
            {
                message = isAnsiSupported
                    ? $"Failed to remove package file: {candidate.FullPath}".Pastel(ConsoleColor.Red)
                    : $"Failed to remove package file: {candidate.FullPath}";
                console.WriteLine(message);
                if (Verbose)
                {
                    console.WriteLine(e.Message.Pastel(ConsoleColor.Red));
                    console.WriteLine(e.StackTrace ?? (isAnsiSupported
                        ? "No stack trace available.".Pastel(ConsoleColor.Red)
                        : "No stack trace available."));
                }
            }
        }
    }


    public override async ValueTask ExecuteUiMode()
    {
        
        throw new NotImplementedException();
    }
}