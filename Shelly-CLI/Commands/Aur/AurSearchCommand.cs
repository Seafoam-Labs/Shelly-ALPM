using System.Diagnostics.CodeAnalysis;
using System.Text.Json;
using PackageManager.Aur;
using PackageManager.Wire;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Aur;

public class AurSearchCommand : AsyncCommand<AurSearchSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, AurSearchSettings settings)
    {
        var query = string.Join(" ", settings.Query);
        if (Program.IsUiMode)
        {
            return await HandleUiModeSearch(settings);
        }

        if (string.IsNullOrWhiteSpace(query))
        {
            AnsiConsole.MarkupLine("[red]Query cannot be empty.[/]");
            return 1;
        }

        if (query.Length < 2)
        {
            AnsiConsole.MarkupLine("[red]Error: Query must be at least 2 characters long[/]");
            return 1;
        }


        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize();

            var results = manager.SearchPackages(query).GetAwaiter().GetResult();

            if (settings.JsonOutput)
            {
                var json = JsonSerializer.Serialize(results, ShellyCLIJsonContext.Default.ListAurPackageDto);
                await using var stdout = Console.OpenStandardOutput();
                await using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
                await writer.WriteLineAsync(json);
                await writer.FlushAsync();
                return 0;
            }

            var table = new Table().Border(TableBorder.Rounded);
            table.AddColumn("Name");
            table.AddColumn("Version");
            table.AddColumn("Description");

            foreach (var pkg in results.Take(25))
            {
                table.AddRow(
                    pkg.Name.EscapeMarkup(),
                    pkg.Version.EscapeMarkup(),
                    (pkg.Description ?? "").EscapeMarkup().Truncate(60)
                );
            }

            AnsiConsole.Write(table);
            AnsiConsole.MarkupLine($"[blue]Total results:[/] {results.Count}");

            return 0;
        }
        catch (Exception ex)
        {
            AnsiConsole.MarkupLine($"[red]Search failed:[/] {ex.Message.EscapeMarkup()}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    private static async Task<int> HandleUiModeSearch(AurSearchSettings settings)
    {
        var query = string.Join(" ", settings.Query);
        if (string.IsNullOrWhiteSpace(query))
        {
            await Console.Error.WriteLineAsync("Error: Query cannot be empty.");
            return 1;
        }

        if (query.Length < 2)
        {
            await Console.Error.WriteLineAsync("Error: Query must be at least 2 characters long");
            return 1;
        }

        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize();

            var results = manager.SearchPackages(query).GetAwaiter().GetResult();

            if (settings.JsonOutput)
            {
                JsonPackFrame.WriteToStdout(results);
                return 0;
            }

            foreach (var pkg in results.Take(25))
            {
                Console.WriteLine($"{pkg.Name} {pkg.Version} - {pkg.Description ?? ""}");
            }

            await Console.Error.WriteLineAsync($"Total results: {results.Count}");

            return 0;
        }
        catch (Exception ex)
        {
            await Console.Error.WriteLineAsync($"Search failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }
}
