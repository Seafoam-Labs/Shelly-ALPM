using System.Text.Json;
using PackageManager.Alpm;
namespace Shelly.Commands.StandardCommands;

internal static class ListUpdatesCommands
{
    internal static int ListUpdatesUiMode(bool verbose, bool json)
    {
        using var manager = new AlpmManager(verbose, true, Configuration.GetConfigurationFilePath());
        manager.InitializeWithSync();
        var updates = manager.GetPackagesNeedingUpdate();

        if (json)
        {
            var jsonStr = JsonSerializer.Serialize(updates, ShellyJsonContext.Default.ListAlpmPackageUpdateDto);
            using var stdout = Console.OpenStandardOutput();
            using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            writer.WriteLine(jsonStr);
            writer.Flush();
            return 0;
        }

        if (updates.Count == 0)
        {
            Console.Error.WriteLine("All packages are up to date!");
            return 0;
        }

        foreach (var pkg in updates.OrderBy(p => p.Name))
        {
            Console.WriteLine($"{pkg.Name} {pkg.CurrentVersion} -> {pkg.NewVersion} ({FormatSize(pkg.DownloadSize)})");
        }
        Console.Error.WriteLine($"{updates.Count} packages can be updated");
        return 0;
    }

    internal static int ListUpdatesConsoleMode(bool verbose, bool json)
    {
        using var manager = new AlpmManager(verbose, false, Configuration.GetConfigurationFilePath());
        Console.WriteLine("Initializing and syncing ALPM...");
        manager.InitializeWithSync();
        var updates = manager.GetPackagesNeedingUpdate();

        if (json)
        {
            var jsonStr = JsonSerializer.Serialize(updates, ShellyJsonContext.Default.ListAlpmPackageUpdateDto);
            using var stdout = Console.OpenStandardOutput();
            using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            writer.WriteLine(jsonStr);
            writer.Flush();
            return 0;
        }

        if (updates.Count == 0)
        {
            Console.WriteLine("All packages are up to date!");
            return 0;
        }

        foreach (var pkg in updates.OrderBy(p => p.Name))
        {
            Console.WriteLine($"{pkg.Name,-30} {pkg.CurrentVersion,-20} -> {pkg.NewVersion,-20} {FormatSize(pkg.DownloadSize),-10} {FormatSize(pkg.SizeDifference)}");
        }
        Console.WriteLine($"{updates.Count} packages can be updated");
        return 0;
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
}
