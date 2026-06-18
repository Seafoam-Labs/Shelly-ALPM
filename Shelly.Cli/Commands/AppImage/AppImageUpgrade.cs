using System.CommandLine;
using PackageManager.AppImage;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Utilities;
using Shelly.Utilities.Enums;

namespace Shelly.Cli.Commands.AppImage;

public partial class AppImageUpgrade : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("upgrade", "Upgrades all AppImages");

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new AppImageUpgrade();
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        var installPath = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
        var manager = new AppImageManagerV2(installPath);

        if (UiMode)
        {
            var config = ConfigManager.ReadConfig();
            manager.MessageEvent += (_, e) => UiFrames.Info(e.Message);
            manager.ErrorEvent += (_, e) => UiFrames.Error(e.Error);
            manager.ProgressEvent += (sender, e) =>
            {
                var sizeDisplay = Enum.TryParse<SizeDisplay>(config.FileSizeDisplay, true, out var parsed)
                    ? parsed
                    : SizeDisplay.Bytes;

                var totalStr = e.TotalBytes.HasValue
                    ? SizeUtilities.FormatSize(sizeDisplay, e.TotalBytes.Value)
                    : "unknown";
                var downloadedStr = SizeUtilities.FormatSize(sizeDisplay, e.DownloadedBytes);
                var progressStr = e.ProgressPercentage.HasValue ? $"{e.ProgressPercentage.Value:F0}%" : "N/A";

                UiFrames.Info($"Updating {e.AppName}: {progressStr} ({downloadedStr}/{totalStr})");
            };
        }
        else
        {
            manager.MessageEvent += (_, e) =>
                console.WriteLine(AnsiUtilities.Colorize($"[INFO]{e.Message}", ConsoleColor.Blue));
            manager.ErrorEvent += (_, e) => console.WriteLine(AnsiUtilities.Colorize($"[ERROR] {e.Error}", ConsoleColor.Red));
            //not sub to progress events because cli rewrite.
        }

        var updates = await manager.CheckForAppImageUpdates();

        if (updates.Count == 0)
        {
            console.WriteLine(AnsiUtilities.Colorize("No updates available for any AppImage.", ConsoleColor.Yellow));
            return;
        }

        foreach (var update in updates)
        {
            console.WriteLine(AnsiUtilities.Colorize($"Updating {update.Name} to {update.Version}", ConsoleColor.Green));
            await manager.RunUpdate(update);
        }
    }

    public async override ValueTask ExecuteUiMode()
    {
        //Not Implemented
    }
}