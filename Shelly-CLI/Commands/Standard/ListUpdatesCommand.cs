using System.Text.Json;
using PackageManager.Alpm;
using PackageManager.Utilities;
using PackageManager.Wire;
using Shelly_CLI.Configuration;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class ListUpdatesCommand : Command<ListSettings>
{
    public override int Execute(CommandContext context, ListSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeListUpdates(settings);
        }

        using var manager = new AlpmManager();
        var dbPath = XdgPaths.ShellyCache("db");
        XdgPaths.EnsureDirectory(dbPath);
        if (!settings.JsonOutput)
        {
            AnsiConsole.Status()
                .Spinner(Spinner.Known.Dots)
                .Start("Initializing and syncing ALPM...", _ =>
                {
                    manager.Initialize(false, int.Parse(ConfigManager.GetConfigValue("ParallelDownloadCount")!), true,
                        dbPath);
                    manager.Sync();
                });
        }
        else
        {
            manager.Initialize(false, int.Parse(ConfigManager.GetConfigValue("ParallelDownloadCount")!), true, dbPath);
            manager.Sync();
        }

        var updates = manager.GetPackagesNeedingUpdate();

        if (settings.JsonOutput)
        {
            var json = JsonSerializer.Serialize(updates, ShellyCLIJsonContext.Default.ListAlpmPackageUpdateDto);
            // Write directly to stdout stream to bypass Spectre.Console redirection
            using var stdout = Console.OpenStandardOutput();
            using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            writer.WriteLine(json);
            writer.Flush();
            return 0;
        }

        if (updates.Count == 0)
        {
            AnsiConsole.MarkupLine("[green]All packages are up to date![/]");
            return 0;
        }

        var table = new Table();
        table.AddColumn("Name");
        table.AddColumn("Current Version");
        table.AddColumn("New Version");
        table.AddColumn("Download Size");
        table.AddColumn("Size Difference");

        foreach (var pkg in updates.OrderBy(p => p.Name))
        {
            table.AddRow(
                pkg.Name,
                pkg.CurrentVersion,
                pkg.NewVersion,
                FormatSize(pkg.DownloadSize),
                FormatSize(pkg.SizeDifference)
            );
        }

        AnsiConsole.Write(table);
        AnsiConsole.MarkupLine($"[yellow]{updates.Count} packages can be updated[/]");
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

    private static int HandleUiModeListUpdates(ListSettings settings)
    {
        using var manager = new AlpmManager();
        var dbPath = XdgPaths.ShellyCache("db");
        XdgPaths.EnsureDirectory(dbPath);
        manager.Initialize(false, int.Parse(ConfigManager.GetConfigValue("ParallelDownloadCount")!), true, dbPath);
        manager.Sync();
        var updates = manager.GetPackagesNeedingUpdate();

        if (settings.JsonOutput)
        {
            JsonPackFrame.WriteToStdout(updates);
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
}