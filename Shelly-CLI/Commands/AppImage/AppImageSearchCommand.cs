using PackageManager.AppImage;
using PackageManager.Wire;
using Shelly_CLI.Commands.Standard;
using Shelly.Utilities;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.AppImage;

public class AppImageSearchCommand : AsyncCommand<AppImageSearchSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, AppImageSearchSettings settings)
    {
        var manager = new AppImageManager();
        manager.ErrorEvent += (_, args) => { AnsiConsole.MarkupLine($"[red]{args.Error.EscapeMarkup()}[/]"); };

        manager.MessageEvent += (_, args) => { AnsiConsole.MarkupLine($"[blue]{args.Message.EscapeMarkup()}[/]"); };

        var appImages = await manager.GetAppImagesFromLocalDb();
        List<AppImageDto> results;

        if (!string.IsNullOrWhiteSpace(settings.Query))
        {
            var query = settings.Query.ToLowerInvariant();
            results = appImages
                .Where(a => a.Name.Contains(query, StringComparison.InvariantCultureIgnoreCase) ||
                            a.DesktopName.Contains(query, StringComparison.InvariantCultureIgnoreCase))
                .ToList();
        }
        else
        {
            results = appImages;
        }


        if (settings.Json)
        {
            if (Program.IsUiMode)
            {
                JsonPackFrame.WriteToStdout(results);
            }
            else
            {
                var json = System.Text.Json.JsonSerializer.Serialize(results,
                    ShellyCLIJsonContext.Default.ListAppImageDto);
                await using var stdout = Console.OpenStandardOutput();
                await using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
                await writer.WriteLineAsync(json);
                await writer.FlushAsync();
            }
        }
        else
        {
            if (results.Count == 0)
            {
                AnsiConsole.MarkupLine("[yellow]No matching AppImages found in local database.[/]");

                return 0;
            }

            var table = new Table();
            table.AddColumn("Name");
            table.AddColumn("Version");
            table.AddColumn("Size");
            table.AddColumn("Update URL");

            foreach (var app in results)
            {
                table.AddRow(
                    app.Name,
                    app.Version,
                    SizeHelper.FormatSize(app.SizeOnDisk),
                    app.UpdateURl
                );
            }

            AnsiConsole.Write(table);
        }

        return 0;
    }
}