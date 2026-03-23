using System.Text.Json;
using PackageManager.Aur;
using PackageManager.Aur.Models;

namespace Shelly.Commands.AurCommands;

internal static class AurSearchCommands
{
    internal static async Task<int> SearchUiMode(string query, bool json = false)
    {
        if (string.IsNullOrWhiteSpace(query))
        {
            Console.Error.WriteLine("Error: Query cannot be empty.");
            return 1;
        }

        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager(Configuration.GetConfigurationFilePath());
            await manager.Initialize();

            var results = await manager.SearchPackages(query);

            if (json)
            {
                var jsonStr = JsonSerializer.Serialize(results, ShellyJsonContext.Default.ListAurPackageDto);
                await using var stdout = Console.OpenStandardOutput();
                await using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
                await writer.WriteLineAsync(jsonStr);
                await writer.FlushAsync();
                return 0;
            }

            foreach (var pkg in results.Take(25))
            {
                Console.WriteLine($"{pkg.Name} {pkg.Version} - {pkg.Description ?? ""}");
            }

            Console.Error.WriteLine($"Total results: {results.Count}");

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Search failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    internal static async Task<int> SearchConsoleMode(string query, bool json = false)
    {
        if (string.IsNullOrWhiteSpace(query))
        {
            Console.WriteLine("Query cannot be empty.");
            return 1;
        }

        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager(Configuration.GetConfigurationFilePath());
            await manager.Initialize();

            var results = await manager.SearchPackages(query);

            if (json)
            {
                var jsonStr = JsonSerializer.Serialize(results, ShellyJsonContext.Default.ListAurPackageDto);
                await using var stdout = Console.OpenStandardOutput();
                await using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
                await writer.WriteLineAsync(jsonStr);
                await writer.FlushAsync();
                return 0;
            }

            foreach (var pkg in results.Take(25))
            {
                Console.WriteLine($"{pkg.Name} {pkg.Version} - {pkg.Description ?? ""}");
            }

            Console.WriteLine($"Total results: {results.Count}");

            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Search failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }
}
