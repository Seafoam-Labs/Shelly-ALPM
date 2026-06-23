using System.CommandLine;
using PackageManager.AppImage;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;
using Shelly.Utilities;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli.Commands.AppImage;

public partial class AppImageInstall : GlobalSettingsCommand
{
    public required string AppImageLocation { get; set; }

    public static Command Create()
    {
        var appImageLocation = new Argument<string>("location") { Description = "Location of the AppImage" };

        var command = new Command("install", "Install an AppImage") { appImageLocation };

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new AppImageInstall
            {
                AppImageLocation = parseResult.GetValue(appImageLocation)!
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

        if (!File.Exists(AppImageLocation))
        {
            console.WriteLine(AnsiUtilities.Colorize("Error: Specified file does not exist.", ConsoleColor.Red));
        }

        if (await AppImageManagerV2.IsAppImage(AppImageLocation))
        {
            var installPath = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
            var manager = new AppImageManagerV2(installPath);

            var result =
                await AppImageSinglePaneOutput.Output(console, manager, x => x.InstallAppImage(AppImageLocation));

            console.WriteLine(result
                ? AnsiUtilities.Colorize("Successfully installed appimage.", ConsoleColor.Green)
                : AnsiUtilities.Colorize("Failled to install appimage.", ConsoleColor.Red));
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (!File.Exists(AppImageLocation))
        {
            UiFrames.Error("Specified file does not exist.");
        }

        if (await AppImageManagerV2.IsAppImage(AppImageLocation))
        {
            var installPath = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
            var manager = new AppImageManagerV2(installPath);
            var result = await UiModeOutput.Run(manager, x => x.InstallAppImage(AppImageLocation));
            UiFrames.TxFinish(result, "Successfully installed appimage.", "Failed to install appimage.");
        }
    }
}