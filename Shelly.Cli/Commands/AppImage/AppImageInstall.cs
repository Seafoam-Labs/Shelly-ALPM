using System.CommandLine;
using PackageManager.AppImage;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Utilities;

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
        if (!File.Exists(AppImageLocation))
        {
            if (UiMode)
                UiFrames.Error("Specified file does not exist.");
            else
                console.WriteLine(AnsiUtilities.Colorize("Error: Specified file does not exist.", ConsoleColor.Red));
            return;
        }

        if (await AppImageManagerV2.IsAppImage(AppImageLocation))
        {
            var installPath = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
            var manager = new AppImageManagerV2(installPath);
            if (UiMode)
            {
                manager.ErrorEvent += (_, args) => UiFrames.Error(args.Error);
                manager.MessageEvent += (_, args) => UiFrames.Info(args.Message);
            }
            else
            {
                manager.ErrorEvent += (_, args) =>
                    console.WriteLine(AnsiUtilities.Colorize($"{args.Error}", ConsoleColor.Red));
                manager.MessageEvent += (_, args) =>
                    console.WriteLine(AnsiUtilities.Colorize($"{args.Message}", ConsoleColor.Red));
            }

            var result = await manager.InstallAppImage(AppImageLocation);

            if (UiMode)
                UiFrames.TxFinish(result, "Successfully installed appimage.", "Failed to install appimage.");
            else if (result)
            {
                console.WriteLine(AnsiUtilities.Colorize("Successfully installed appimage.", ConsoleColor.Green));
            }

            console.WriteLine(AnsiUtilities.Colorize("Failled to install appimage.", ConsoleColor.Red));
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        //Not Implemented.
    }
}