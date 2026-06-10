using PackageManager.AppImage;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.AppImage;

public class AppImageInstallCommand : AsyncCommand<AppImageSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, AppImageSettings settings)
    {
        if (settings.PackageLocation == null)
        {
            if (Program.IsUiMode)
                UiFrames.Error("No package specified");
            else
                AnsiConsole.MarkupLine("[red]Error: No package specified[/]");

            return 1;
        }

        if (!File.Exists(settings.PackageLocation))
        {
            if (Program.IsUiMode)
                UiFrames.Error("Specified file does not exist.");
            else
                AnsiConsole.MarkupLine("[red]Error: Specified file does not exist.[/]");

            return 1;
        }

        RootElevator.EnsureRootExectuion();
        if (await AppImageManager.IsAppImage(settings.PackageLocation))
        {
            var manager = new AppImageManager();
            if (Program.IsUiMode)
            {
                manager.ErrorEvent += (_, args) => UiFrames.Error(args.Error);
                manager.MessageEvent += (_, args) => UiFrames.Info(args.Message);
                UiFrames.Info("Installing AppImage...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
            }
            else
            {
                manager.ErrorEvent += (_, args) => AnsiConsole.MarkupLine($"[red]{args.Error.EscapeMarkup()}[/]");
                manager.MessageEvent += (_, args) => AnsiConsole.MarkupLine($"[blue]{args.Message.EscapeMarkup()}[/]");
            }

            var result = await manager.InstallAppImage(settings.PackageLocation, settings.UpdateUrl);

            if (settings.UpdateUrl is { Length: > 0 } && settings.UpdateType != UpdateType.None)
            {
                var appName = Path.GetFileNameWithoutExtension(settings.PackageLocation);
                var appImages = await manager.GetAppImagesFromLocalDb();
                var appImage = appImages.FirstOrDefault(a => a.Name == appName);
                if (appImage != null)
                {
                    await manager.AppImageConfigureUpdates(settings.UpdateUrl, appImage.Name, settings.UpdateType);
                }
            }

            if (Program.IsUiMode)
                UiFrames.TxFinish(result == 0, "Successfully installed appimage.", "Failed to install appimage.");
            else
                AnsiConsole.MarkupLine(result == 0
                    ? "[green]Successfully installed appimage.[/]"
                    : "[red]Failled to install appimage.[/]");

            return result;
        }

        return 0;
    }
}