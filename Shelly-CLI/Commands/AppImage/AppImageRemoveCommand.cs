using PackageManager.AppImage;
using PackageManager.AppImage.AppImageV2;
using Shelly_CLI.Configuration;
using Shelly_CLI.Utility;
using Shelly.Utilities;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.AppImage;

public class AppImageRemoveCommand : AsyncCommand<AppImageRemoveSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, AppImageRemoveSettings settings)
    {
        if (string.IsNullOrWhiteSpace(settings.Name))
        {
            if (Program.IsUiMode)
                UiFrames.Error("No AppImage name specified");
            else
                AnsiConsole.MarkupLine("[red]Error: No AppImage name specified[/]");

            return 1;
        }

        var manager = new AppImageManagerV2(ConfigManager.ReadConfig().AppImageInstallPath ?? "");

        var appImages = await manager.GetAppImagesFromLocalDb();

        var matches = appImages
            .Where(a => a.Name.Contains(settings.Name, StringComparison.OrdinalIgnoreCase))
            .ToList();

        if (matches.Count == 0)
        {
            AnsiConsole.MarkupLine($"[yellow]No AppImage matching \"{settings.Name}\" found in searched paths.[/]");
            return 0;
        }

        AppImageDtoV2 targetAppImage;
        if (matches.Count == 1)
        {
            targetAppImage = matches[0];
        }
        else
        {
            await Console.Error.WriteLineAsync("Multiple AppImages matched.");
            return 1;
        }

        if (!settings.NoConfirm &&
            !AnsiConsole.Confirm($"Are you sure you want to remove [red]{Path.GetFileName(targetAppImage.Name)}[/]?"))
        {
            return 0;
        }

        if (Program.IsUiMode)
        {
            manager.ErrorEvent += (_, args) => UiFrames.Error(args.Error);
            manager.MessageEvent += (_, args) => UiFrames.Info(args.Message);
            UiFrames.Info("Removing AppImage...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
        }
        else
        {
            manager.ErrorEvent += (_, args) => AnsiConsole.MarkupLine($"[red]{args.Error.EscapeMarkup()}[/]");
            manager.MessageEvent += (_, args) => AnsiConsole.MarkupLine($"[blue]{args.Message.EscapeMarkup()}[/]");
        }

        if (targetAppImage.Path == null)
        {
            await Console.Error.WriteLineAsync("AppImage path is null.");
            return 1;
        }

        var result = await manager.RemoveAppImage(targetAppImage.Path, settings.RemoveConfig);
        if (Program.IsUiMode)
            UiFrames.TxFinish(result == 0, "AppImage removed.", "Failed to remove AppImage.");
        return result;
    }
}