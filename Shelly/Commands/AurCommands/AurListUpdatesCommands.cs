using System.Text.Json;
using PackageManager.Aur;
using PackageManager.Aur.Models;

namespace Shelly.Commands.AurCommands;

internal static class AurListUpdatesCommands
{
    internal static async Task<int> ListUpdatesUiMode()
    {
        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager(Configuration.GetConfigurationFilePath());
            await manager.Initialize();

            var updates = await manager.GetPackagesNeedingUpdate();

            var jsonStr = JsonSerializer.Serialize(updates, ShellyJsonContext.Default.ListAurUpdateDto);
            await using var stdout = Console.OpenStandardOutput();
            await using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            await writer.WriteLineAsync(jsonStr);
            await writer.FlushAsync();

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to check for AUR updates: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    internal static async Task<int> ListUpdatesConsoleMode()
    {
        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager(Configuration.GetConfigurationFilePath());
            await manager.Initialize();

            var updates = await manager.GetPackagesNeedingUpdate();

            if (updates.Count == 0)
            {
                Console.WriteLine("All AUR packages are up to date.");
                return 0;
            }

            Console.WriteLine("AUR packages with available updates:");
            foreach (var pkg in updates)
            {
                Console.WriteLine($"  {pkg.Name} {pkg.Version} -> {pkg.NewVersion}");
            }

            Console.WriteLine($"\nTotal: {updates.Count} updates available.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to check for AUR updates: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }
}
