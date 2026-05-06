using System.Diagnostics.CodeAnalysis;
using System.Text.Json;
using PackageManager.Aur;
using PackageManager.Utilities;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Aur;

public class AurListUpdatesCommand : AsyncCommand<ListSettings>
{
    public override async Task<int> ExecuteAsync([NotNull] CommandContext context, [NotNull] ListSettings settings)
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
            await manager.Initialize(showHiddenPackages: settings.ShowHidden, tempPath:dbPath, useTempPath:true);

            var updates = await manager.GetPackagesNeedingUpdate();

            // Apply filter if specified
            if (!string.IsNullOrWhiteSpace(settings.Filter))
            {
                updates = updates.Where(p => p.Name.Contains(settings.Filter, StringComparison.OrdinalIgnoreCase)).ToList();
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
                await using var stdout = System.Console.OpenStandardOutput();
                await using var writer = new System.IO.StreamWriter(stdout, System.Text.Encoding.UTF8);
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
                    (pkg.Description ?? "No Description Available").EscapeMarkup().Truncate(50)
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

    private static async Task<int> HandleUiModeListUpdates(ListSettings settings)
    {
        var dbPath = XdgPaths.ShellyCache("db");
        XdgPaths.EnsureDirectory(dbPath);
        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(showHiddenPackages: settings.ShowHidden, tempPath:dbPath, useTempPath:true);

            var updates = await manager.GetPackagesNeedingUpdate();

            // Apply filter if specified
            if (!string.IsNullOrWhiteSpace(settings.Filter))
            {
                updates = updates.Where(p => p.Name.Contains(settings.Filter, StringComparison.OrdinalIgnoreCase)).ToList();
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
                var json = JsonSerializer.Serialize(sortedList, ShellyCLIJsonContext.Default.ListAurUpdateDto);
                await using var stdout = Console.OpenStandardOutput();
                await using var writer = new System.IO.StreamWriter(stdout, System.Text.Encoding.UTF8);
                await writer.WriteLineAsync(json);
                await writer.FlushAsync();
                return 0;
            }

            if (updates.Count == 0)
            {
                Console.Error.WriteLine("All AUR packages are up to date.");
                return 0;
            }

            var skip = (settings.Page - 1) * settings.Take;
            var displayPackages = sortedUpdates.Skip(skip).Take(settings.Take).ToList();

            foreach (var pkg in displayPackages)
            {
                Console.WriteLine($"{pkg.Name} {pkg.Version} -> {pkg.NewVersion} - {pkg.Description ?? "No Description Available"}");
            }

            Console.Error.WriteLine($"Total: {displayPackages.Count} packages need updates");

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to check updates: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }
}
