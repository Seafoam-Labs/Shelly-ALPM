using System.CommandLine;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;
using Shelly.Utilities;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli.Commands.AppImage;

public partial class AppImageUpdateManagerVersion : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("migrate-manager", "Updates the AppImage manager version");

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new AppImageUpdateManagerVersion();
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        RootElevator.EnsureRootExectuion();

        var installPath = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
        var manager = new AppImageManagerV2(installPath);

        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }
        
        var result = await AppImageSinglePaneOutput.Output(console, manager, x => x.MigrateAppImages());

        console.WriteLine(result
            ? AnsiUtilities.Colorize("AppImage manager version updated successfully.", ConsoleColor.Green)
            : AnsiUtilities.Colorize("AppImage manager version updated unsuccessfully.", ConsoleColor.Red));
    }

    public override async ValueTask ExecuteUiMode()
    {
        var installPath = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
        var manager = new AppImageManagerV2(installPath);
        var result = await UiModeOutput.Run(manager, x => x.MigrateAppImages());
        UiFrames.TxFinish(result, "AppImage manager version updated successfully.",
            "AppImage manager version updated unsuccessfully.");
    }
}