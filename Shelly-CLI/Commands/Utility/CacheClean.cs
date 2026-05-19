using PackageManager.Alpm;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Utility;

public class CacheClean : AsyncCommand<CacheCleanSettings>
{
    public override Task<int> ExecuteAsync(CommandContext context, CacheCleanSettings settings)
    {
        
        var cacheDir = settings.CacheDir ?? "/var/cache/pacman/pkg";

        if (!Directory.Exists(cacheDir))
        {
            AnsiConsole.MarkupLine($"[red]Cache directory does not exist: {cacheDir.EscapeMarkup()}[/]");
            return Task.FromResult(1);
        }

        var entries = Directory.EnumerateFiles(cacheDir)
            .Select(CacheCleanHelper.ParsePackageFilename)
            .Where(e => e != null)
            .Cast<CacheEntry>()
            .ToList();

        if (entries.Count == 0)
        {
            AnsiConsole.MarkupLine("[yellow]No package files found in cache directory.[/]");
            return Task.FromResult(0);
        }
        
        var grouped = entries.GroupBy(e => e.Name).ToDictionary(g => g.Key, g => g.ToList());

        var candidates = new List<CacheEntry>();
        foreach (var (name, pkgEntries) in grouped)
        {
            pkgEntries.Sort((a, b) => AlpmManager.VersionCompare(a.Version, b.Version));
            var toRemove = pkgEntries.Take(Math.Max(0, pkgEntries.Count - settings.Keep));
            candidates.AddRange(toRemove);
        }

        if (settings.Uninstalled)
        {
            using var manager = new AlpmManager();
            var installedNames = manager.GetInstalledPackages().Select(p => p.Name).ToHashSet();
            candidates = candidates.Where(c => !installedNames.Contains(c.Name)).ToList();
        }
        
        if (candidates.Count == 0)
        {
            AnsiConsole.MarkupLine("[green]No candidate packages to remove.[/]");
            return Task.FromResult(0);
        }

        var totalSize = candidates.Sum(c => c.FileSize);
        
        if (settings.DryRun)
        {
            AnsiConsole.MarkupLine("[blue]Dry run — the following files would be removed:[/]");
            foreach (var entry in candidates)
            {
                AnsiConsole.MarkupLine($"  {entry.FullPath.EscapeMarkup()} [dim]({CacheCleanHelper.FormatSize(entry.FileSize)})[/]");
            }
            AnsiConsole.MarkupLine($"\n[blue]Total: {candidates.Count} files, {CacheCleanHelper.FormatSize(totalSize)}[/]");
            return Task.FromResult(0);
        }
        
        if (settings.Packages.Length > 0)
        {
            RootElevator.EnsureRootExectuion();
            
            var matchedEntries = entries
                .Where(entry =>
                    settings.Packages.Any(package =>
                        entry.Name.StartsWith(
                            package,
                            StringComparison.Ordinal)))
                .ToList();
            
            var matchedSize = matchedEntries.Sum(x => x.FileSize);
            
            if (matchedEntries.Count == 0)
            {
                AnsiConsole.MarkupLine(
                    "[yellow]No matching cache entries found.[/]");

                return Task.FromResult(0);
            }
            
            AnsiConsole.MarkupLine(
                $"[blue]The following cache entries will be removed " +
                $"({CacheCleanHelper.FormatSize(matchedSize)}):[/]");
            
            foreach (var entry in matchedEntries)
            {
                AnsiConsole.MarkupLine(
                    $"  {Markup.Escape(entry.FullPath)} [dim]({CacheCleanHelper.FormatSize(entry.FileSize)})[/]");
                
                var sigPath = $"{entry.FullPath}.sig";

                if (File.Exists(sigPath))
                {
                    AnsiConsole.MarkupLine(
                        $"  {Markup.Escape(sigPath)} [dim](signature)[/]");
                }

            }
            
            if (!settings.NoConfirm)
            {
                var confirmed = AnsiConsole.Confirm(
                    "[yellow]Do you want to continue?[/]");

                if (!confirmed)
                {
                    AnsiConsole.MarkupLine(
                        "[grey]Operation cancelled.[/]");

                    return Task.FromResult(0);
                }

            }
            
            foreach (var entry in matchedEntries)
            {
                try
                {
                    File.Delete(entry.FullPath);

                    AnsiConsole.MarkupLine(
                        $"[green]Removed:[/] {Markup.Escape(entry.FullPath)}");

                    var sigPath = $"{entry.FullPath}.sig";

                    if (File.Exists(sigPath))
                    {
                        File.Delete(sigPath);
                        AnsiConsole.MarkupLine(
                            $"[green]Removed:[/] {Markup.Escape(sigPath)}");
                    }

                }
                catch (Exception ex)
                {
                    AnsiConsole.MarkupLine(
                        $"[red]Failed:[/] {Markup.Escape(entry.FullPath)}");

                    AnsiConsole.MarkupLine(
                        $"[grey]{Markup.Escape(ex.Message)}[/]");
                }
            }

            return Task.FromResult(0);
        }
        
        if (settings.Remove)
        {
            RootElevator.EnsureRootExectuion();

            foreach (var entry in candidates)
            {
                File.Delete(entry.FullPath);
            }

            AnsiConsole.MarkupLine($"[green]Removed {candidates.Count} files, freed {CacheCleanHelper.FormatSize(totalSize)}[/]");
            return Task.FromResult(0);
        }

        // Default: list candidates
        AnsiConsole.MarkupLine("[blue]Candidates for removal:[/]");
        foreach (var entry in candidates)
        {
            AnsiConsole.MarkupLine($"  {entry.FullPath.EscapeMarkup()} [dim]({CacheCleanHelper.FormatSize(entry.FileSize)})[/]");
        }
        AnsiConsole.MarkupLine($"\n[blue]Total: {candidates.Count} files, {CacheCleanHelper.FormatSize(totalSize)}[/]");
        AnsiConsole.MarkupLine("[dim]Use -r/--remove to delete these files, or -d/--dry-run to preview.[/]");

        return Task.FromResult(0);
    }
}
