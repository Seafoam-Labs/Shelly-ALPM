using System;
using System.Diagnostics.CodeAnalysis;
using System.Linq;
using System.Text.Json;
using PackageManager.Alpm;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class ListAvailableCommand : Command<ListSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] ListSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeListAvailable(settings);
        }
        try
        {
            using var manager = new AlpmManager();

            if (!settings.JsonOutput)
            {
                if (settings.Sync)
                {
                    AnsiConsole.Status()
                        .Spinner(Spinner.Known.Dots)
                        .Start("Initializing and syncing ALPM...", ctx => { manager.IntializeWithSync(); });
                }
                else
                {
                    AnsiConsole.Status()
                        .Spinner(Spinner.Known.Dots)
                        .Start("Initializing ALPM...", ctx => { manager.Initialize(); });
                }
            }
            else if (settings.Sync)
            {
                manager.IntializeWithSync();
            }
            else
            {
                manager.Initialize();
            }


            var packages = manager.GetAvailablePackages();

            // Apply filter if specified
            if (!string.IsNullOrWhiteSpace(settings.Filter))
            {
                packages = packages.Where(p => p.Name.Contains(settings.Filter, StringComparison.OrdinalIgnoreCase)).ToList();
            }

            // Apply sorting based on settings
            // Note: Popularity sorts by name as there is no popularity data available for standard packages
            var sortedPackages = settings.Sort switch
            {
                SortOption.Size => settings.Order == SortDirection.Ascending
                    ? packages.OrderBy(p => p.Size)
                    : packages.OrderByDescending(p => p.Size),
                SortOption.Popularity => settings.Order == SortDirection.Ascending
                    ? packages.OrderBy(p => p.Name)
                    : packages.OrderByDescending(p => p.Name),
                _ => settings.Order == SortDirection.Ascending
                    ? packages.OrderBy(p => p.Name)
                    : packages.OrderByDescending(p => p.Name)
            };

            if (settings.JsonOutput)
            {
                var sortedList = sortedPackages.ToList();
                var json = JsonSerializer.Serialize(sortedList, ShellyCLIJsonContext.Default.ListAlpmPackageDto);
                // Write directly to stdout stream to bypass Spectre.Console redirection
                using var stdout = Console.OpenStandardOutput();
                using var writer = new System.IO.StreamWriter(stdout, System.Text.Encoding.UTF8);
                writer.WriteLine(json);
                writer.Flush();
                return 0;
            }

            var table = new Table();
            table.AddColumn("Name");
            table.AddColumn("Version");
            table.AddColumn("Repository");
            table.AddColumn("Description");
            
            var skip = (settings.Page - 1) * settings.Take;
            var displayPackages = sortedPackages.Skip(skip).Take(settings.Take).ToList();

            foreach (var pkg in displayPackages)
            {
                table.AddRow(
                    pkg.Name,
                    pkg.Version,
                    pkg.Repository,
                    pkg.Description.EscapeMarkup().Truncate(50)
                );
            }

            AnsiConsole.Write(table);
            AnsiConsole.MarkupLine($"[blue]Showing {settings.Take} of {packages.Count} available packages[/]");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[ERROR] Exception: {ex.Message}");
            Console.Error.WriteLine($"[ERROR] Stack trace: {ex.StackTrace}");
            return 1;
        }
    }

    private static int HandleUiModeListAvailable(ListSettings settings)
    {
        try
        {
            using var manager = new AlpmManager();

            if (settings.Sync)
            {
                manager.IntializeWithSync();
            }
            else
            {
                manager.Initialize();
            }

            var packages = manager.GetAvailablePackages();

            // Apply filter if specified
            if (!string.IsNullOrWhiteSpace(settings.Filter))
            {
                var nameRes = packages.Where(p => p.Name.Contains(settings.Filter, StringComparison.OrdinalIgnoreCase)).ToList();
                var descRes= packages.Where(p => p.Description.Contains(settings.Filter, StringComparison.OrdinalIgnoreCase)).ToList();
                packages = nameRes.Concat(descRes).DistinctBy(p => p.Name).ToList();
            }

            // Apply sorting based on settings
            var sortedPackages = settings.Sort switch
            {
                SortOption.Size => settings.Order == SortDirection.Ascending
                    ? packages.OrderBy(p => p.Size)
                    : packages.OrderByDescending(p => p.Size),
                SortOption.Popularity => settings.Order == SortDirection.Ascending
                    ? packages.OrderBy(p => p.Name)
                    : packages.OrderByDescending(p => p.Name),
                _ => settings.Order == SortDirection.Ascending
                    ? packages.OrderBy(p => p.Name)
                    : packages.OrderByDescending(p => p.Name)
            };

            if (settings.JsonOutput)
            {
                var sortedList = sortedPackages.ToList();
                var json = JsonSerializer.Serialize(sortedList, ShellyCLIJsonContext.Default.ListAlpmPackageDto);
                using var stdout = Console.OpenStandardOutput();
                using var writer = new System.IO.StreamWriter(stdout, System.Text.Encoding.UTF8);
                writer.WriteLine(json);
                writer.Flush();
                return 0;
            }

            var skip = (settings.Page - 1) * settings.Take;
            var displayPackages = sortedPackages.Skip(skip).Take(settings.Take).ToList();

            foreach (var pkg in displayPackages)
            {
                Console.WriteLine($"{pkg.Name} {pkg.Version} {pkg.Repository} - {pkg.Description}");
            }

            Console.Error.WriteLine($"Showing {settings.Take} of {packages.Count} available packages");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[ERROR] Exception: {ex.Message}");
            Console.Error.WriteLine($"[ERROR] Stack trace: {ex.StackTrace}");
            return 1;
        }
    }
}
