using System.Text.Json;
using PackageManager.Aur;
using PackageManager.Aur.Models;

namespace Shelly.Commands.AurCommands;

internal static class AurListInstalledCommands
{
    internal static async Task<int> ListInstalledUiMode()
    {
        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager(Configuration.GetConfigurationFilePath());
            await manager.Initialize();

            var packages = await manager.GetInstalledPackages();
            var sorted = packages.OrderBy(x => x.Name).ToList();

            var jsonStr = JsonSerializer.Serialize(sorted, ShellyJsonContext.Default.ListAurPackageDto);
            await using var stdout = Console.OpenStandardOutput();
            await using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            await writer.WriteLineAsync(jsonStr);
            await writer.FlushAsync();

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to list installed AUR packages: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    internal static async Task<int> ListInstalledConsoleMode()
    {
        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager(Configuration.GetConfigurationFilePath());
            await manager.Initialize();

            var packages = await manager.GetInstalledPackages();
            var sorted = packages.OrderBy(x => x.Name).ToList();

            if (sorted.Count == 0)
            {
                Console.WriteLine("No AUR packages installed.");
                return 0;
            }

            foreach (var pkg in sorted)
            {
                Console.WriteLine($"{pkg.Name} {pkg.Version}");
            }

            Console.WriteLine($"\nTotal: {sorted.Count} AUR packages installed.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to list installed AUR packages: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }
}
