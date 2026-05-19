using System.Text.Json;
using PackageManager.Aur;
using PackageManager.Aur.Models;
using PackageManager.Wire;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Aur;

public class AurListInstalledCommand : AsyncCommand<AlpmListSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, AlpmListSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiModeListInstalled(settings);
        }

        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(showHiddenPackages: settings.ShowHidden);

            var packages = await manager.GetInstalledPackages();

            // Apply filter if specified
            if (!string.IsNullOrWhiteSpace(settings.Filter))
            {
                packages = ApplyFilter(packages, settings.Filter);
            }

            // Apply sorting based on settings
            // Note: Size sorts by name as there is no size data available for AUR packages
            var sortedPackages = settings.Sort switch
            {
                SortOption.Popularity => settings.Order == SortDirection.Ascending
                    ? packages.OrderBy(p => p.Popularity)
                    : packages.OrderByDescending(p => p.Popularity),
                SortOption.Size => settings.Order == SortDirection.Ascending
                    ? packages.OrderBy(p => p.Name)
                    : packages.OrderByDescending(p => p.Name),
                _ => settings.Order == SortDirection.Ascending
                    ? packages.OrderBy(p => p.Name)
                    : packages.OrderByDescending(p => p.Name)
            };

            if (settings.JsonOutput)
            {
                var sortedList = sortedPackages.ToList();
                var json = JsonSerializer.Serialize(sortedList, ShellyCLIJsonContext.Default.ListAurPackageDto);
                await using var stdout = Console.OpenStandardOutput();
                await using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
                await writer.WriteLineAsync(json);
                await writer.FlushAsync();
                return 0;
            }

            var table = new Table().Border(TableBorder.Rounded);
            table.AddColumn("Name");
            table.AddColumn("Version");
            table.AddColumn("Description");

            var skip = (settings.Page - 1) * settings.Take;
            var displayPackages = sortedPackages.Skip(skip).Take(settings.Take).ToList();

            foreach (var pkg in displayPackages)
            {
                table.AddRow(
                    pkg.Name.EscapeMarkup(),
                    pkg.Version.EscapeMarkup(),
                    (pkg.Description ?? "").EscapeMarkup().Truncate(60)
                );
            }

            AnsiConsole.Write(table);
            AnsiConsole.MarkupLine($"[blue]Total:[/] {packages.Count} AUR packages installed");

            return 0;
        }
        catch (Exception ex)
        {
            AnsiConsole.MarkupLine($"[red]Failed to list packages:[/] {ex.Message.EscapeMarkup()}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    private static async Task<int> HandleUiModeListInstalled(AlpmListSettings settings)
    {
        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(showHiddenPackages: settings.ShowHidden);

            var packages = await manager.GetInstalledPackages();

            // Apply filter if specified
            if (!string.IsNullOrWhiteSpace(settings.Filter))
            {
                packages = ApplyFilter(packages, settings.Filter);
            }

            // Apply sorting based on settings
            var sortedPackages = settings.Sort switch
            {
                SortOption.Popularity => settings.Order == SortDirection.Ascending
                    ? packages.OrderBy(p => p.Popularity)
                    : packages.OrderByDescending(p => p.Popularity),
                SortOption.Size => settings.Order == SortDirection.Ascending
                    ? packages.OrderBy(p => p.Name)
                    : packages.OrderByDescending(p => p.Name),
                _ => settings.Order == SortDirection.Ascending
                    ? packages.OrderBy(p => p.Name)
                    : packages.OrderByDescending(p => p.Name)
            };

            if (settings.JsonOutput)
            {
                var sortedList = sortedPackages.ToList();
                JsonPackFrame.WriteToStdout(sortedList);
                return 0;
            }

            var skip = (settings.Page - 1) * settings.Take;
            var displayPackages = sortedPackages.Skip(skip).Take(settings.Take).ToList();

            foreach (var pkg in displayPackages)
            {
                Console.WriteLine($"{pkg.Name} {pkg.Version} - {pkg.Description ?? ""}");
            }

            await Console.Error.WriteLineAsync($"Total: {packages.Count} AUR packages installed");

            return 0;
        }
        catch (Exception ex)
        {
            await Console.Error.WriteLineAsync($"Failed to list packages: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    private static List<AurPackageDto> ApplyFilter(List<AurPackageDto> packages, string filter)
    {
        return packages
            .Select(x => new { Package = x, Score = StringMatching.PartialRatio(filter, x.Name) })
            .Where(x => x.Score >= 90)
            .Select(x => x.Package)
            .ToList();
    }
}