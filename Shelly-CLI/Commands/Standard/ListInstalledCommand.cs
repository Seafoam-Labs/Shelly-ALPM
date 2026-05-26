using System.Text.Json;
using PackageManager.Alpm;
using PackageManager.Wire;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class ListInstalledCommand : Command<AlpmListSettings>
{
    public override int Execute(CommandContext context, AlpmListSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeListInstalled(settings);
        }

        using var manager = new AlpmManager();

        if (!settings.JsonOutput)
        {
            AnsiConsole.Status()
                .Spinner(Spinner.Known.Dots)
                .Start("Initializing ALPM...",
                    _ => { manager.Initialize(true, showHiddenPackages: settings.ShowHidden); });
        }
        else
        {
            manager.Initialize(true, showHiddenPackages: settings.ShowHidden);
        }

        var packages = manager.GetInstalledPackages();

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
                ? packages.OrderBy(p => p.InstalledSize)
                : packages.OrderByDescending(p => p.InstalledSize),
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
        table.AddColumn("Size");
        table.AddColumn("Description");

        var skip = (settings.Page - 1) * settings.Take;
        var displayPackages = sortedPackages.Skip(skip).Take(settings.Take).ToList();

        foreach (var pkg in displayPackages)
        {
            table.AddRow(
                pkg.Name,
                pkg.Version,
                FormatSize(pkg.InstalledSize),
                pkg.Description.EscapeMarkup().Truncate(50)
            );
        }

        AnsiConsole.Write(table);
        AnsiConsole.MarkupLine($"[blue]Total: {displayPackages.Count} packages[/]");
        return 0;
    }

    private static string FormatSize(long bytes)
    {
        string[] sizes = ["B", "KB", "MB", "GB"];
        var order = 0;
        double size = bytes;
        while (size >= 1024 && order < sizes.Length - 1)
        {
            order++;
            size /= 1024;
        }

        return $"{size:0.##} {sizes[order]}";
    }

    private static int HandleUiModeListInstalled(AlpmListSettings settings)
    {
        using var manager = new AlpmManager();
        manager.Initialize(true, showHiddenPackages: settings.ShowHidden);

        var packages = manager.GetInstalledPackages();

        // Apply filter if specified
        if (!string.IsNullOrWhiteSpace(settings.Filter))
        {
            packages = ApplyFilter(packages, settings.Filter);
        }

        // Apply sorting based on settings
        var sortedPackages = settings.Sort switch
        {
            SortOption.Size => settings.Order == SortDirection.Ascending
                ? packages.OrderBy(p => p.InstalledSize)
                : packages.OrderByDescending(p => p.InstalledSize),
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
            JsonPackFrame.WriteToStdout(sortedList);
            return 0;
        }

        var skip = (settings.Page - 1) * settings.Take;
        var displayPackages = sortedPackages.Skip(skip).Take(settings.Take).ToList();

        foreach (var pkg in displayPackages)
        {
            Console.WriteLine($"{pkg.Name} {pkg.Version} {FormatSize(pkg.InstalledSize)} - {pkg.Description}");
        }

        Console.Error.WriteLine($"Total: {displayPackages.Count} packages");
        return 0;
    }

    private static List<AlpmPackageDto> ApplyFilter(List<AlpmPackageDto> packages, string filter)
    {
        return packages
            .Select(x => new { Package = x, Score = StringMatching.PartialRatio(filter, x.Name) })
            .Where(x => x.Score >= 90)
            .Select(x => x.Package)
            .ToList();
    }
}