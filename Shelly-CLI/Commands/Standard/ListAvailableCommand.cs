using System.Text.Json;
using PackageManager.Alpm;
using PackageManager.Wire;
using Shelly.Utilities.Eventing;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class ListAvailableCommand : Command<AlpmListSettings>
{
    public override int Execute(CommandContext context, AlpmListSettings settings)
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
                        .Start("Initializing and syncing ALPM...",
                            _ => { manager.IntializeWithSync(); });
                }
                else
                {
                    AnsiConsole.Status()
                        .Spinner(Spinner.Known.Dots)
                        .Start("Initializing ALPM...",
                            _ => { manager.Initialize(showHiddenPackages: settings.ShowHidden); });
                }
            }
            else if (settings.Sync)
            {
                manager.IntializeWithSync();
            }
            else
            {
                manager.Initialize(showHiddenPackages: settings.ShowHidden);
            }

            var packages = manager.GetAvailablePackages();

            // Apply filter if specified
            if (!string.IsNullOrWhiteSpace(settings.Filter))
            {
                packages = ApplyFilter(packages, settings.Filter);
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
                using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
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

    private static int HandleUiModeListAvailable(AlpmListSettings settings)
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
                manager.Initialize(showHiddenPackages: settings.ShowHidden);
            }

            var packages = manager.GetAvailablePackages();

            // Apply filter if specified
            if (!string.IsNullOrWhiteSpace(settings.Filter))
            {
                packages = ApplyFilter(packages, settings.Filter);
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

            var sortedList = sortedPackages.ToList();
            JsonPackFrame.WriteToStdout(sortedList);
            JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                AlpmEvents.InformationalOutput, $"Showing {sortedList.Count} of {packages.Count} available packages"));
            return 0;
        }
        catch (Exception ex)
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, ex.Message));
            return 1;
        }
    }

    private static List<AlpmPackageDto> ApplyFilter(List<AlpmPackageDto> packages, string filter)
    {
        return packages
            .Select(x => new { Package = x, Score = MatchObject(filter, x.Name, x.Description) })
            .Where(x => x.Score >= 75)
            .Select(x => x.Package)
            .ToList();
    }

    private static int MatchObject(string query, string name, string description)
    {
        var nameScore = StringMatching.PartialRatio(query, name);
        var descScore = StringMatching.PartialRatio(query, description);

        return (int)(nameScore * 0.7 + descScore * 0.3);
    }
}