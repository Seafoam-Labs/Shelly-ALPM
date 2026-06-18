using System.CommandLine;
using PackageManager.Alpm;
using Shelly.Cli.Interactions;
using Shelly.Utilities;
using Shelly.Utilities.Enums;
using Shelly.Utilities.Eventing;
using static Shelly.Cli.Interactions.AnsiUtilities;
using static Shelly.Utilities.SizeUtilities;

namespace Shelly.Cli.Commands.Standard;

public class ListUpdates : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("list-updates", "List standard packages that have available updates");

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new ListUpdates();
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        var updates = GetUpdates();

        if (JsonOutput)
        {
            JsonPackFrame.WriteToStdout(updates);
            return;
        }

        if (updates.Count == 0)
        {
            console.WriteLine(Colorize("All packages are up to date!", ConsoleColor.Green));
            return;
        }

        var config = ConfigManager.ReadConfig();
        var size = Enum.Parse<SizeDisplay>(config.FileSizeDisplay);

        var headers = new[] { "Name", "Current Version", "New Version", "Download Size", "Size Difference" };
        var table = BasicTable.Execute(headers, updates.OrderBy(p => p.Name).ToList(),
            p => p.Name,
            p => p.CurrentVersion,
            p => p.NewVersion,
            p => FormatSize(size, p.DownloadSize),
            p => FormatSize(size, p.SizeDifference));
        console.Write(table);
        console.WriteLine();
        console.WriteLine(Colorize($"{updates.Count} packages can be updated", ConsoleColor.Yellow));
    }

    public override ValueTask ExecuteUiMode()
    {
        var updates = GetUpdates();
        JsonPackFrame.WriteToStdout(updates);
        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            AlpmEvents.InformationalOutput,
            updates.Count == 0 ? "All packages are up to date!" : $"{updates.Count} packages can be updated"));
        return ValueTask.CompletedTask;
    }

    private static List<AlpmPackageUpdateDto> GetUpdates()
    {
        var dbPath = XdgPaths.ShellyCache("db");
        Directory.CreateDirectory(dbPath);

        using var manager = new AlpmManager();
        manager.Initialize(useTempPath: true, tempPath: dbPath);
        manager.Sync();
        return manager.GetPackagesNeedingUpdate();
    }
}
