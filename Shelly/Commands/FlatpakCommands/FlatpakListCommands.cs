using System.Text.Json;
using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakListCommands
{
    internal static int ListUiMode(bool json)
    {
        var manager = new FlatpakManager();
        var packages = manager.SearchInstalled();
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
            Console.WriteLine($"{pkg.Name} {pkg.Id} {pkg.Version} {pkg.Arch} {pkg.Version} - {pkg.Summary}");
        }
        Console.Error.WriteLine("Total: packages");
        return 0;
    }
    internal static int ListConsoleMode(bool json)
    {
        var manager = new FlatpakManager();
        var packages = manager.SearchInstalled();
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
            Console.WriteLine($"{pkg.Name,-30} {pkg.Id,-40} {pkg.Version,-15} {pkg.Arch,-10} {pkg.Branch,-10} {Truncate(pkg.Summary, 50),-50} {pkg.remote}");
        }
        Console.WriteLine($"Total: {packages.Count} packages");
        return 0;
    }
    private static string Truncate(string value, int maxLength)
    {
        if (string.IsNullOrEmpty(value)) return value;
        return value.Length <= maxLength ? value : value[..maxLength] + "...";
    }
}
