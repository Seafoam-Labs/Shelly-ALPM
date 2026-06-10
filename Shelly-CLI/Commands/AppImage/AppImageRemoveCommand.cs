using PackageManager.AppImage;
using Shelly_CLI.Utility;
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

        RootElevator.EnsureRootExectuion();

        const string installDir = "/opt/shelly";
        if (!Directory.Exists(installDir))
        {
            AnsiConsole.MarkupLine("[yellow]Info: /opt/shelly directory does not exist. No AppImages to remove.[/]");
            return 0;
        }

        var appImages = Directory.GetFiles(installDir, "*.AppImage", SearchOption.TopDirectoryOnly);
        var matches = appImages
            .Where(f => Path.GetFileName(f).Contains(settings.Name, StringComparison.OrdinalIgnoreCase))
            .ToList();

        if (matches.Count == 0)
        {
            AnsiConsole.MarkupLine($"[yellow]No AppImage matching \"{settings.Name}\" found in {installDir}[/]");
            return 0;
        }

        string targetAppImage;
        if (matches.Count == 1)
        {
            targetAppImage = matches[0];
        }
        else
        {
            if (settings.NoConfirm)
            {
                targetAppImage = matches[0];
                AnsiConsole.MarkupLine(
                    $"[yellow]Multiple matches found, picking first one due to --no-confirm: {Path.GetFileName(targetAppImage)}[/]");
            }
            else
            {
                targetAppImage = AnsiConsole.Prompt(
                    new SelectionPrompt<string>()
                        .Title("Multiple AppImages matched. Which one do you want to [red]remove[/]?")
                        .AddChoices(matches.Select(Path.GetFileName).Cast<string>())
                );
                targetAppImage = matches.First(m => Path.GetFileName(m) == targetAppImage);
            }
        }

        if (!settings.NoConfirm &&
            !AnsiConsole.Confirm($"Are you sure you want to remove [red]{Path.GetFileName(targetAppImage)}[/]?"))
        {
            return 0;
        }

        var manager = new AppImageManager();
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

        var result = await manager.RemoveAppImage(targetAppImage);
        if (Program.IsUiMode)
            UiFrames.TxFinish(result == 0, "AppImage removed.", "Failed to remove AppImage.");
        return result;
    }
}