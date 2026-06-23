using System.CommandLine;
using PackageManager.AppImage.AppImageV2;
using Pastel;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;
using Shelly.Utilities;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli.Commands.AppImage;

public partial class AppImageSyncMeta : GlobalSettingsCommand
{
    private string? Package { get; set; }

    public static Command Create()
    {
        var package = new Argument<string?>("package")
            { Description = "The search query for the AppImage", Arity = ArgumentArity.ZeroOrOne };

        var command = new Command("sync-meta", "Syncs meta data for an AppImage") { package };

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new AppImageSyncMeta
            {
                Package = parseResult.GetValue(package)
            };
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

        var installDir = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
        if (!Directory.Exists(installDir))
        {
            console.WriteLine(AnsiUtilities.Colorize(
                $"Info: {installDir} directory does not exist. No AppImages to sync.", ConsoleColor.Yellow));
            return;
        }

        var manager = new AppImageManagerV2(ConfigManager.ReadConfig().AppImageInstallPath ?? "");

        if (!string.IsNullOrEmpty(Package))
        {
            var appImages = Directory.GetFiles(installDir, "*.AppImage", SearchOption.TopDirectoryOnly);
            var matches = appImages
                .Where(f => Path.GetFileName(f).Contains(Package, StringComparison.OrdinalIgnoreCase))
                .ToList();

            if (matches.Count == 0)
            {
                console.WriteLine(AnsiUtilities.Colorize($"No AppImage matching \"{Package}\" found in {installDir}",
                    ConsoleColor.Yellow));
                return;
            }

            await AppImageSinglePaneOutput.Output(console, manager, x => x.SyncAppImageMeta([
                Path.GetFileNameWithoutExtension(matches.First())
            ]));
        }
        else
        {
            await AppImageSinglePaneOutput.Output(console, manager,
                x => x.SyncAppImageMeta(Directory.GetFiles(installDir, "*.AppImage", SearchOption.TopDirectoryOnly)
                    .Select(Path.GetFileNameWithoutExtension).Cast<string>().ToList()));
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        var installDir = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
        if (!Directory.Exists(installDir))
        {
            UiFrames.Error($"Info: {installDir} directory does not exist. No AppImages to sync.");
            return;
        }

        var manager = new AppImageManagerV2(ConfigManager.ReadConfig().AppImageInstallPath ?? "");

        if (!string.IsNullOrEmpty(Package))
        {
            var appImages = Directory.GetFiles(installDir, "*.AppImage", SearchOption.TopDirectoryOnly);
            var matches = appImages
                .Where(f => Path.GetFileName(f).Contains(Package, StringComparison.OrdinalIgnoreCase))
                .ToList();

            if (matches.Count == 0)
            {
                UiFrames.Info($"No AppImage matching \"{Package}\" found in {installDir}");
                return;
            }

            await UiModeOutput.Run(manager,
                x => x.SyncAppImageMeta([Path.GetFileNameWithoutExtension(matches.First())]));
        }
        else
        {
            await UiModeOutput.Run(manager, x => x.SyncAppImageMeta(Directory
                .GetFiles(installDir, "*.AppImage", SearchOption.TopDirectoryOnly)
                .Select(Path.GetFileNameWithoutExtension).Cast<string>().ToList()));
        }
    }
}