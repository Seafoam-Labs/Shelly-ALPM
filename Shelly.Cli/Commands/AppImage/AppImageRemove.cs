using System.CommandLine;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Utilities;

namespace Shelly.Cli.Commands.AppImage;

public partial class AppImageRemove : GlobalSettingsCommand
{
    public required string AppImage { get; set; }

    private bool RemoveConfig { get; set; }

    public static Command Create()
    {
        var appImage = new Argument<string>("appimage") { Description = "Name of the AppImage" };
        var removeConfig = new Option<bool>("--remove-config", "-c") { Description = "Remove Config" };

        var command = new Command("remove", "Remove an AppImage") { appImage, removeConfig };

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new AppImageRemove
            {
                AppImage = parseResult.GetValue(appImage)!,
                RemoveConfig = parseResult.GetValue(removeConfig)
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        var config = ConfigManager.ReadConfig();
        var installDir = config.AppImageInstallPath ?? XdgPaths.BinHome();
        var oldDefaultPath = XdgPaths.BinHome();

        var searchPaths = new List<string> { installDir };
        if (installDir != oldDefaultPath)
        {
            searchPaths.Add(oldDefaultPath);
        }

        var matches = new List<string>();
        foreach (var appImages in from path in searchPaths
                 where Directory.Exists(path)
                 select Directory.GetFiles(path, "*.AppImage", SearchOption.TopDirectoryOnly))
        {
            matches.AddRange(appImages.Where(f =>
                Path.GetFileName(f).Contains(AppImage, StringComparison.OrdinalIgnoreCase)));
        }

        if (matches.Count == 0)
        {
            console.WriteLine(AnsiUtilities.Colorize($"No AppImage matching \"{AppImage}\" found in searched paths.",
                ConsoleColor.Red));
            return;
        }

        string targetAppImage;
        if (matches.Count == 1)
        {
            targetAppImage = matches[0];
        }
        else
        {
            console.WriteLine(AnsiUtilities.Colorize(
                $"Multiple matches found, please refine your input to match a singular installed AppImage.",
                ConsoleColor.Red));
            return;
        }

        if (NoConfirm &&
            !Confirm.Execute($"Are you sure you want to remove [red]{Path.GetFileName(targetAppImage)}[/]?"))
        {
            return;
        }

        var manager = new AppImageManagerV2(ConfigManager.ReadConfig().AppImageInstallPath ?? "");
        if (UiMode)
        {
            manager.ErrorEvent += (_, args) => UiFrames.Error(args.Error);
            manager.MessageEvent += (_, args) => UiFrames.Info(args.Message);
            UiFrames.Info("Removing AppImage...", Utilities.Eventing.AlpmEvents.TransactionStart);
        }
        else
        {
            manager.ErrorEvent += (_, args) => console.WriteLine(AnsiUtilities.Colorize($"{args.Error}", ConsoleColor.Red));
            manager.MessageEvent += (_, args) =>
                console.WriteLine(AnsiUtilities.Colorize($"{args.Message}", ConsoleColor.Blue));
        }

        var result = await manager.RemoveAppImage(targetAppImage, RemoveConfig);
        if (UiMode)
            UiFrames.TxFinish(result == 0, "AppImage removed.", "Failed to remove AppImage.");
    }

    public override ValueTask ExecuteUiMode()
    {
        throw new NotImplementedException();
    }
}