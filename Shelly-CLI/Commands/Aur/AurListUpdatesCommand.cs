using System.Text.Json;
using PackageManager.Aur;
using PackageManager.Aur.Models;
using PackageManager.Utilities;
using PackageManager.Wire;
using Shelly.Utilities;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Aur;

public class AurListUpdatesCommand : AsyncCommand<AlpmListSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, AlpmListSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiModeListUpdates(settings);
        }

        var dbPath = XdgPaths.ShellyCache("db");
        XdgPaths.EnsureDirectory(dbPath);
        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(showHiddenPackages: settings.ShowHidden, tempPath: dbPath, useTempPath: true);

            var updates = await manager.GetPackagesNeedingUpdate();

            // Apply filter if specified
            if (!string.IsNullOrWhiteSpace(settings.Filter))
            {
                updates = ApplyFilter(updates, settings.Filter);
            }

            // Apply sorting based on settings
            // Note: Popularity sorts by name as there is no popularity data available for AUR updates
            var sortedUpdates = settings.Sort switch
            {
                SortOption.Size => settings.Order == SortDirection.Ascending
                    ? updates.OrderBy(p => p.DownloadSize)
                    : updates.OrderByDescending(p => p.DownloadSize),
                SortOption.Popularity => settings.Order == SortDirection.Ascending
                    ? updates.OrderBy(p => p.Name)
                    : updates.OrderByDescending(p => p.Name),
                _ => settings.Order == SortDirection.Ascending
                    ? updates.OrderBy(p => p.Name)
                    : updates.OrderByDescending(p => p.Name)
            };

            if (settings.JsonOutput)
            {
                var sortedList = sortedUpdates.ToList();
                var json = JsonSerializer.Serialize(sortedList, ShellyCLIJsonContext.Default.ListAurUpdateDto);
                await using var stdout = Console.OpenStandardOutput();
                await using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
                await writer.WriteLineAsync(json);
                await writer.FlushAsync();
                return 0;
            }

            if (updates.Count == 0)
            {
                AnsiConsole.MarkupLine("[green]All AUR packages are up to date.[/]");
                return 0;
            }

            var table = new Table().Border(TableBorder.Rounded);
            table.AddColumn("Name");
            table.AddColumn("Installed");
            table.AddColumn("Available");
            table.AddColumn("Description");

            var skip = (settings.Page - 1) * settings.Take;
            var displayPackages = sortedUpdates.Skip(skip).Take(settings.Take).ToList();

            foreach (var pkg in
                     displayPackages)
            {
                table.AddRow(
                    pkg.Name.EscapeMarkup(),
                    pkg.Version.EscapeMarkup(),
                    pkg.NewVersion.EscapeMarkup(),
                    GetDefaultDescription(pkg.Description).EscapeMarkup().Truncate(50)
                );
            }

            AnsiConsole.Write(table);
            AnsiConsole.MarkupLine($"[blue]Total:[/] {displayPackages.Count} packages need updates");

            return 0;
        }
        catch (Exception ex)
        {
            AnsiConsole.MarkupLine($"[red]Failed to check updates:[/] {ex.Message.EscapeMarkup()}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    private static async Task<int> HandleUiModeListUpdates(AlpmListSettings settings)
    {
        var dbPath = XdgPaths.ShellyCache("db");
        XdgPaths.EnsureDirectory(dbPath);
        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(showHiddenPackages: settings.ShowHidden, tempPath: dbPath, useTempPath: true);

            var updates = await manager.GetPackagesNeedingUpdate();

            // Apply filter if specified
            if (!string.IsNullOrWhiteSpace(settings.Filter))
            {
                updates = ApplyFilter(updates, settings.Filter);
            }

            // Apply sorting based on settings
            var sortedUpdates = settings.Sort switch
            {
                SortOption.Size => settings.Order == SortDirection.Ascending
                    ? updates.OrderBy(p => p.DownloadSize)
                    : updates.OrderByDescending(p => p.DownloadSize),
                SortOption.Popularity => settings.Order == SortDirection.Ascending
                    ? updates.OrderBy(p => p.Name)
                    : updates.OrderByDescending(p => p.Name),
                _ => settings.Order == SortDirection.Ascending
                    ? updates.OrderBy(p => p.Name)
                    : updates.OrderByDescending(p => p.Name)
            };

            if (settings.JsonOutput)
            {
                var sortedList = sortedUpdates.ToList();
                JsonPackFrame.WriteToStdout(sortedList);
                return 0;
            }

            if (updates.Count == 0)
            {
                await Console.Error.WriteLineAsync("All AUR packages are up to date.");
                return 0;
            }

            var skip = (settings.Page - 1) * settings.Take;
            var displayPackages = sortedUpdates.Skip(skip).Take(settings.Take).ToList();

            foreach (var pkg in displayPackages)
            {
                Console.WriteLine(
                    $"{pkg.Name} {pkg.Version} -> {pkg.NewVersion} - {GetDefaultDescription(pkg.Description)}"
                );
            }

            await Console.Error.WriteLineAsync($"Total: {displayPackages.Count} packages need updates");

            return 0;
        }
        catch (Exception ex)
        {
            await Console.Error.WriteLineAsync($"Failed to check updates: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    private static string GetDefaultDescription(string description)
    {
        return string.IsNullOrWhiteSpace(description) ? "No Description Available" : description;
    }

    private static List<AurUpdateDto> ApplyFilter(List<AurUpdateDto> packages, string filter)
    {
        return packages
            .Select(x => new { Package = x, Score = StringMatching.PartialRatio(filter, x.Name) })
            .Where(x => x.Score >= 90)
            .Select(x => x.Package)
            .ToList();
    }
}