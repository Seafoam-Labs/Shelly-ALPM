using PackageManager.AppImage;
using PackageManager.AppImage.AppImageV2;
using Shelly_CLI.Configuration;
using Shelly_CLI.Utility;
using Shelly.Utilities;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.AppImage;

public class AppImageSyncMeta : AsyncCommand<AppImageSyncMetaSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, AppImageSyncMetaSettings settings)
    {
        var installDir = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
        if (!Directory.Exists(installDir))
        {
            AnsiConsole.MarkupLine($"[yellow]Info: {installDir} directory does not exist. No AppImages to sync.[/]");
            return 0;
        }

        var manager = new AppImageManagerV2(ConfigManager.ReadConfig().AppImageInstallPath ?? "");
        ;
        if (Program.IsUiMode)
        {
            manager.MessageEvent += (_, e) => UiFrames.Info(e.Message);
            manager.ErrorEvent += (_, e) => UiFrames.Error(e.Error);
        }
        else
        {
            manager.MessageEvent += (_, e) => AnsiConsole.MarkupLine($"[blue][[INFO]][/] {e.Message.EscapeMarkup()}");
            manager.ErrorEvent += (_, e) => AnsiConsole.MarkupLine($"[red][[ERROR]][/] {e.Error.EscapeMarkup()}");
        }

        if (!string.IsNullOrEmpty(settings.Query))
        {
            var appImages = await manager.GetAppImagesFromLocalDb();
            var matches = appImages.Select(x => x.Name)
                .Where(f => f.Contains(settings.Query, StringComparison.OrdinalIgnoreCase))
                .ToList();
            
            await manager.SyncAppImageMeta(matches);
        }
        else
        {
            var appImages = Directory.GetFiles(installDir, "*.AppImage", SearchOption.TopDirectoryOnly);
            var appImageNames = appImages.Select(Path.GetFileNameWithoutExtension).Cast<string>().ToList();
            await manager.SyncAppImageMeta(appImageNames);
        }

        return 0;
    }
}