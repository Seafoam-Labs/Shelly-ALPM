using System.Text.Json;
using PackageManager.Alpm;
namespace Shelly.Commands.StandardCommands;

internal static class ListAvailableCommands
{
    internal static int ListAvailableUiMode(bool verbose, string? filter, string sort, string order, int page, int take, bool json, bool sync)
    {
        try
        {
            using var manager = new AlpmManager(verbose, true, Configuration.GetConfigurationFilePath());
            if (sync)
                manager.InitializeWithSync();
            else
                manager.Initialize();

            var packages = manager.GetAvailablePackages();

            if (!string.IsNullOrWhiteSpace(filter))
            {
                var nameRes = packages.Where(p => p.Name.Contains(filter, StringComparison.OrdinalIgnoreCase)).ToList();
                var descRes = packages.Where(p => p.Description.Contains(filter, StringComparison.OrdinalIgnoreCase)).ToList();
                packages = nameRes.Concat(descRes).DistinctBy(p => p.Name).ToList();
            }

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
                Console.WriteLine($"{pkg.Name} {pkg.Version} {pkg.Repository} - {pkg.Description}");
            }
            Console.Error.WriteLine($"Showing {take} of {packages.Count} available packages");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[ERROR] Exception: {ex.Message}");
            Console.Error.WriteLine($"[ERROR] Stack trace: {ex.StackTrace}");
            return 1;
        }
    }

    internal static int ListAvailableConsoleMode(bool verbose, string? filter, string sort, string order, int page, int take, bool json, bool sync)
    {
        try
        {
            using var manager = new AlpmManager(verbose, false, Configuration.GetConfigurationFilePath());
            if (sync)
            {
                Console.WriteLine("Initializing and syncing ALPM...");
                manager.InitializeWithSync();
            }
            else
            {
                Console.WriteLine("Initializing ALPM...");
                manager.Initialize();
            }

            var packages = manager.GetAvailablePackages();

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
                Console.WriteLine($"{pkg.Name,-30} {pkg.Version,-20} {pkg.Repository,-15} {Truncate(pkg.Description, 50)}");
            }
            Console.WriteLine($"Showing {take} of {packages.Count} available packages");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[ERROR] Exception: {ex.Message}");
            Console.Error.WriteLine($"[ERROR] Stack trace: {ex.StackTrace}");
            return 1;
        }
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

    private static string Truncate(string value, int maxLength)
    {
        return value.Length <= maxLength ? value : value[..maxLength] + "...";
    }
}
