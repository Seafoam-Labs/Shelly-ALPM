using System.Text;
using System.Text.Json;
using PackageManager.Local;
using PackageManager.Wire;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class ListLocalInstalledCommand : Command<ListSettings>
{
    public override int Execute(CommandContext context, ListSettings settings)
    {
        if (Program.IsUiMode) return HandleUiModeListInstalled(settings);

        var packages = LocalManager.GetInstalledBinaryPackages();

        if (!string.IsNullOrWhiteSpace(settings.Filter)) packages = ApplyFilter(packages, settings.Filter);

        var sortedPackages = settings.Sort switch
        {
            SortOption.Size => settings.Order == SortDirection.Ascending
                ? packages.OrderBy(p => p.Size)
                : packages.OrderByDescending(p => p.Size),
            _ => settings.Order == SortDirection.Ascending
                ? packages.OrderBy(p => p.Name)
                : packages.OrderByDescending(p => p.Name)
        };

        if (settings.JsonOutput)
        {
            var sortedList = sortedPackages.ToList();
            var json = JsonSerializer.Serialize(sortedList, ShellyCLIJsonContext.Default.ListLocalPackageDto);
            // Write directly to stdout stream to bypass Spectre.Console redirection
            using var stdout = Console.OpenStandardOutput();
            using var writer = new StreamWriter(stdout, Encoding.UTF8);
            writer.WriteLine(json);
            writer.Flush();
            return 0;
        }

        var table = new Table();
        table.AddColumn("Name");
        table.AddColumn("Size");

        var skip = (settings.Page - 1) * settings.Take;
        var displayPackages = sortedPackages.Skip(skip).Take(settings.Take).ToList();

        foreach (var pkg in displayPackages) table.AddRow(pkg.Name, FormatSize(pkg.Size));

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

    private static int HandleUiModeListInstalled(ListSettings settings)
    {
        var packages = LocalManager.GetInstalledBinaryPackages();

        if (!string.IsNullOrWhiteSpace(settings.Filter)) packages = ApplyFilter(packages, settings.Filter);

        var sortedPackages = settings.Sort switch
        {
            SortOption.Size => settings.Order == SortDirection.Ascending
                ? packages.OrderBy(p => p.Size)
                : packages.OrderByDescending(p => p.Size),
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

        foreach (var pkg in displayPackages) Console.WriteLine($"{pkg.Name} {FormatSize(pkg.Size)}");

        Console.Error.WriteLine($"Total: {displayPackages.Count} packages");
        return 0;
    }

    private static List<LocalPackageDto> ApplyFilter(List<LocalPackageDto> packages, string filter)
    {
        return packages
            .Select(x => new { Package = x, Score = StringMatching.PartialRatio(filter, x.Name) })
            .Where(x => x.Score >= 90)
            .Select(x => x.Package)
            .ToList();
    }
}