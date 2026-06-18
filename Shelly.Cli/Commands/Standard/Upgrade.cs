using System.CommandLine;
using PackageManager.Alpm;
using PackageManager.Utilities;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;
using Shelly.Utilities.Enums;
using static System.Enum;
using static Shelly.Cli.Interactions.AnsiUtilities;
using static Shelly.Utilities.SizeUtilities;

namespace Shelly.Cli.Commands.Standard;

public class Upgrade : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("upgrade", "Perform a full system upgrade");

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Upgrade();
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

        RootElevator.EnsureRootExectuion();
        var archNews = new ArchNews();
        await archNews.ExecuteAsync(console);

        console.WriteLine(Colorize("Performing full system upgrade...", ConsoleColor.Yellow));
        console.WriteLine(Colorize("Initializing and syncing repositories...", ConsoleColor.Yellow));

        var manager = new AlpmManager();
        manager.Initialize(true);
        manager.Sync();

        var packagesNeedingUpdate = manager.GetPackagesNeedingUpdate();
        if (packagesNeedingUpdate.Count == 0)
        {
            console.WriteLine(Colorize("Standard Packages are up to date!", ConsoleColor.Green));
            return;
        }

        var config = ConfigManager.ReadConfig();
        var size = Parse<SizeDisplay>(config.FileSizeDisplay);

        var headers = new[] { "Repository", "Package", "Old Version", "New Version", "Net Change", "Download Size" };
        var table = BasicTable.Execute(headers, packagesNeedingUpdate, p => p.Repository,
            p => Colorize(p.Name, ConsoleColor.Cyan),
            p => Colorize(p.CurrentVersion, ConsoleColor.Cyan),
            p => Colorize(p.NewVersion, ConsoleColor.Cyan),
            p => Colorize(FormatSize(size, p.SizeDifference), ConsoleColor.Cyan),
            p => Colorize(FormatSize(size, p.DownloadSize), ConsoleColor.Cyan));
        console.Write(table);
        console.WriteLine();
        var downloadSize = FormatSize(size, packagesNeedingUpdate.Sum(p => p.DownloadSize));
        console.WriteLine(Colorize($"Total Download Size: {downloadSize}", ConsoleColor.DarkGreen));
        var upgradeSize = FormatSize(size, packagesNeedingUpdate.Sum(p => p.SizeDifference));
        console.WriteLine(Colorize($"Net Upgrade Size: {upgradeSize}", ConsoleColor.DarkGreen));
        console.WriteLine();

        var result = Confirm.Execute("Proceed with upgrade?", false);
        if (!result)
        {
            console.WriteLine(Colorize("Upgrade cancelled.", ConsoleColor.Red));
            return;
        }

        console.WriteLine(Colorize("Starting System Upgrade...", ConsoleColor.Green));
        var upgradeResult = await StandardSinglePaneOutput.Output(console, manager, x => x.SyncSystemUpdate(), NoConfirm);
        manager.Dispose();

        console.WriteLine(upgradeResult
            ? Colorize("System upgrade complete.", ConsoleColor.Green)
            : Colorize("System upgrade failed.", ConsoleColor.Red));
    }

    public override async ValueTask ExecuteUiMode()
    {
        UiFrames.Info("Performing full system upgrade...");

        using var manager = new AlpmManager();
        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);

        UiFrames.Info("Initializing and syncing repositories...");
        manager.IntializeWithSync();
        var packagesNeedingUpdate = manager.GetPackagesNeedingUpdate();
        if (packagesNeedingUpdate.Count == 0)
        {
            UiFrames.Info("Standard Packages are up to date!");
            return;
        }

        UiFrames.TxStart($"Upgrading {packagesNeedingUpdate.Count} packages...");
        var ok = await UiModeOutput.Run(manager, m => m.SyncSystemUpdate());
        UiFrames.TxFinish(ok, "System upgraded successfully!", "System upgrade failed.");

        var (needsReboot, services) = RestartManager.CheckForRequiredRestarts();
        if (needsReboot)
        {
            UiFrames.Info("[RESTART_REQUIRED]reboot");
        }
        else if (services.Count > 0)
        {
            var failures = await RestartManager.RestartServicesAsync(services);
            foreach (var (svc, error) in failures)
                UiFrames.Error($"[RESTART_FAILED]service:{svc}|{error}");
        }
    }
}