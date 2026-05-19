using PackageManager.AppImage;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.AppImage;

public class AppImageSyncMeta : AsyncCommand<AppImageSyncMetaSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, AppImageSyncMetaSettings settings)
    {
        RootElevator.EnsureRootExectuion();

        const string installDir = "/opt/shelly";
        if (!Directory.Exists(installDir))
        {
            AnsiConsole.MarkupLine("[yellow]Info: /opt/shelly directory does not exist. No AppImages to sync.[/]");
            return 0;
        }

        var manager = new AppImageManager();
        manager.ErrorEvent += (_, args) => { AnsiConsole.MarkupLine($"[red]{args.Error.EscapeMarkup()}[/]"); };

        manager.MessageEvent += (_, args) => { AnsiConsole.MarkupLine($"[blue]{args.Message.EscapeMarkup()}[/]"); };
        if (!string.IsNullOrEmpty(settings.Query))
        {
            var appImages = Directory.GetFiles(installDir, "*.AppImage", SearchOption.TopDirectoryOnly);
            var matches = appImages
                .Where(f => Path.GetFileName(f).Contains(settings.Query, StringComparison.OrdinalIgnoreCase))
                .ToList();

            if (matches.Count == 0)
            {
                AnsiConsole.MarkupLine($"[yellow]No AppImage matching \"{settings.Query}\" found in {installDir}[/]");
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
                            .Title("Multiple AppImages matched. Which one do you want to [green]sync[/]?")
                            .AddChoices(matches.Select(Path.GetFileName).Cast<string>())
                    );
                    targetAppImage = matches.First(m => Path.GetFileName(m) == targetAppImage);
                }
            }

            var package = new List<string> { Path.GetFileNameWithoutExtension(targetAppImage) };
            await manager.SyncAppImageMeta(package);
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