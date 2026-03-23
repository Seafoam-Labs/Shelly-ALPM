using System.Text.Json;
using PackageManager.Alpm;
namespace Shelly.Commands.StandardCommands;

internal static class ListInstalledCommands
{
    internal static int ListInstalledUiMode(bool verbose, string? filter, string sort, string order, int page, int take, bool json)
    {
        using var manager = new AlpmManager(verbose, true, Configuration.GetConfigurationFilePath());
        manager.Initialize(true);
        var packages = manager.GetInstalledPackages();

        if (!string.IsNullOrWhiteSpace(filter))
            packages = packages.Where(p => p.Name.Contains(filter, StringComparison.OrdinalIgnoreCase)).ToList();

        var sortedPackages = SortPackages(packages, sort, order);

        if (json)
        {
            var sortedList = sortedPackages.ToList();
            var jsonStr = JsonSerializer.Serialize(sortedList, ShellyJsonContext.Default.ListAlpmPackageDto);
            using var stdout = Console.OpenStandardOutput();
            using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            writer.WriteLine(jsonStr);
            writer.Flush();
            return 0;
        }

        var skip = (page - 1) * take;
        var displayPackages = sortedPackages.Skip(skip).Take(take).ToList();
        foreach (var pkg in displayPackages)
        {
            Console.WriteLine($"{pkg.Name} {pkg.Version} {FormatSize(pkg.Size)} - {pkg.Description}");
        }
        Console.Error.WriteLine($"Total: {displayPackages.Count} packages");
        return 0;
    }

    internal static int ListInstalledConsoleMode(bool verbose, string? filter, string sort, string order, int page, int take, bool json)
    {
        using var manager = new AlpmManager(verbose, false, Configuration.GetConfigurationFilePath());
        Console.WriteLine("Initializing ALPM...");
        manager.Initialize(true);
        var packages = manager.GetInstalledPackages();

        if (!string.IsNullOrWhiteSpace(filter))
            packages = packages.Where(p => p.Name.Contains(filter, StringComparison.OrdinalIgnoreCase)).ToList();

        var sortedPackages = SortPackages(packages, sort, order);

        if (json)
        {
            var sortedList = sortedPackages.ToList();
            var jsonStr = JsonSerializer.Serialize(sortedList, ShellyJsonContext.Default.ListAlpmPackageDto);
            using var stdout = Console.OpenStandardOutput();
            using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            writer.WriteLine(jsonStr);
            writer.Flush();
            return 0;
        }

        var skip = (page - 1) * take;
        var displayPackages = sortedPackages.Skip(skip).Take(take).ToList();
        foreach (var pkg in displayPackages)
        {
            Console.WriteLine($"{pkg.Name,-30} {pkg.Version,-20} {FormatSize(pkg.Size),-10} {Truncate(pkg.Description, 50)}");
        }
        Console.WriteLine($"Total: {displayPackages.Count} packages");
        return 0;
    }

    private static IEnumerable<AlpmPackageDto> SortPackages(List<AlpmPackageDto> packages, string sort, string order)
    {
        var ascending = order.Equals("ascending", StringComparison.OrdinalIgnoreCase);
        return sort.ToLowerInvariant() switch
        {
            "size" => ascending ? packages.OrderBy(p => p.Size) : packages.OrderByDescending(p => p.Size),
            _ => ascending ? packages.OrderBy(p => p.Name) : packages.OrderByDescending(p => p.Name)
        };
    }

    private static string FormatSize(long bytes)
    {
        string[] sizes = ["B", "KB", "MB", "GB"];
        int order = 0;
        double size = bytes;
        while (size >= 1024 && order < sizes.Length - 1)
        {
            order++;
            size /= 1024;
        }
        return $"{size:0.##} {sizes[order]}";
    }

    private static string Truncate(string value, int maxLength)
    {
        return value.Length <= maxLength ? value : value[..maxLength] + "...";
    }
}
