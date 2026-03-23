using System.Text.Json;
using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakListUpdatesCommands
{
    internal static int ListUpdatesUiMode(bool json)
    {
        var manager = new FlatpakManager();
        var packages = manager.GetPackagesWithUpdates();
        if (json)
        {
            var jsonStr = JsonSerializer.Serialize(packages, FlatpakDtoJsonContext.Default.ListFlatpakPackageDto);
            using var stdout = Console.OpenStandardOutput();
            using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            writer.WriteLine(jsonStr);
            writer.Flush();
            return 0;
        }
        foreach (var pkg in packages.OrderBy(p => p.Id))
        {
            Console.WriteLine($"{pkg.Name} {pkg.Id} {pkg.Version}");
        }
        Console.Error.WriteLine("Total: packages");
        return 0;
    }
    internal static int ListUpdatesConsoleMode(bool json)
    {
        var manager = new FlatpakManager();
        var packages = manager.GetPackagesWithUpdates();
        if (json)
        {
            var jsonStr = JsonSerializer.Serialize(packages, FlatpakDtoJsonContext.Default.ListFlatpakPackageDto);
            using var stdout = Console.OpenStandardOutput();
            using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            writer.WriteLine(jsonStr);
            writer.Flush();
            return 0;
        }
        foreach (var pkg in packages.OrderBy(p => p.Id))
        {
            Console.WriteLine($"{pkg.Name,-30} {pkg.Id,-40} {pkg.Version}");
        }
        Console.WriteLine($"Total: {packages.Count} packages");
        return 0;
    }
}
