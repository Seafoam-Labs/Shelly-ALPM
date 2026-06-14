using PackageManager.AppImage;
using PackageManager.AppImage.AppImageV2;
using Shelly_CLI.Configuration;
using Shelly_CLI.Utility;
using Shelly.Utilities;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.AppImage;

public class AppImageUpdateCommand : AsyncCommand<AppImageUpdateSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, AppImageUpdateSettings settings)
    {
        var installPath = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
        var manager = new AppImageManagerV2(installPath);

        if (Program.IsUiMode)
        {
            var config = ConfigManager.ReadConfig();
            manager.MessageEvent += (_, e) => UiFrames.Info(e.Message);
            manager.ErrorEvent += (_, e) => UiFrames.Error(e.Error);
            manager.ProgressEvent += (sender, e) =>
            {
                var sizeDisplay = Enum.TryParse<SizeDisplay>(config.FileSizeDisplay, true, out var parsed) ? parsed : SizeDisplay.Bytes;

                var totalStr = e.TotalBytes.HasValue ? FormatSize(sizeDisplay, e.TotalBytes.Value) : "unknown";
                var downloadedStr = FormatSize(sizeDisplay, e.DownloadedBytes);
                var progressStr = e.ProgressPercentage.HasValue ? $"{e.ProgressPercentage.Value:F0}%" : "N/A";

                UiFrames.Info($"Updating {e.AppName}: {progressStr} ({downloadedStr}/{totalStr})");
            };
        }
        else
        {
            manager.MessageEvent += (_, e) => AnsiConsole.MarkupLine($"[blue][[INFO]][/] {e.Message.EscapeMarkup()}");
            manager.ErrorEvent += (_, e) => AnsiConsole.MarkupLine($"[red][[ERROR]][/] {e.Error.EscapeMarkup()}");
            //not sub to progress events because cli rewrite.
        }

        var updates = await manager.CheckForAppImageUpdates();

        if (updates.Count == 0)
        {
            AnsiConsole.MarkupLine("[yellow]No updates available for any AppImage.[/]");
            return 0;
        }

        if (!string.IsNullOrEmpty(settings.Name))
        {
            var update = updates.FirstOrDefault(u => u.Name.Equals(settings.Name, StringComparison.OrdinalIgnoreCase));
            if (update == null)
            {
                AnsiConsole.MarkupLine($"[yellow]No update available for AppImage '{settings.Name}'.[/]");
                return 0;
            }

            return await PerformUpdate(manager, update);
        }


        var exitCode = 0;
        foreach (var update in updates)
        {
            if (!settings.NoConfirm)
            {
                if (!AnsiConsole.Confirm($"Update {update.Name} to {update.Version}?"))
                {
                    continue;
                }
            }

            var result = await PerformUpdate(manager, update);
            if (result != 0) exitCode = result;
        }

        return exitCode;
    }

    private static async Task<int> PerformUpdate(AppImageManagerV2 managerV2, AppImageUpdateDto update)
    {
        return await managerV2.RunUpdate(update);
    }
    
    private static  string FormatSize(SizeDisplay size, double bytes)
    {
        return size switch
        {
            SizeDisplay.Bytes => $"{bytes:0} B",
            SizeDisplay.Megabytes => $"{bytes / 1048576.0:F2} MiB",
            SizeDisplay.Gigabytes => $"{bytes / 1073741824.0:F2} GiB",
            _ => $"{bytes:0} B"
        };
    }
}