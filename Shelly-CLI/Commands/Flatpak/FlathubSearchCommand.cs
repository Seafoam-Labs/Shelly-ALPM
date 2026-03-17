using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlathubSearchCommand : AsyncCommand<FlathubSearchSettings>
{
    public override async Task<int> ExecuteAsync([NotNull] CommandContext context,
        [NotNull] FlathubSearchSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiModeSearch(settings);
        }

        if (string.IsNullOrWhiteSpace(settings.Query))
        {
            AnsiConsole.MarkupLine("[red]Query cannot be empty.[/]");
            return 1;
        }

        try
        {
            var manager = new FlatpakManager();
            if (settings.JsonOutput)
            {
            }
            else
            {
                List<Apps> results = SearchAllRepos(manager, query: settings.Query);
                Render(results, settings.Limit);
            }

            return 0;
        }
        catch (Exception ex)
        {
            AnsiConsole.MarkupLine($"[red]Search failed:[/] {ex.Message.EscapeMarkup()}");
            return 1;
        }
    }

    private static void Render(List<Apps> root, int limit)
    {
        var table = new Table().Border(TableBorder.Rounded);
        table.AddColumn("Name");
        table.AddColumn("AppId");
        table.AddColumn("Summary");
        table.AddColumn("Remote");

        foreach (var item in root)
        {
            table.AddRow(
                item.name.EscapeMarkup(),
                item.app_id.EscapeMarkup(),
                item.summary.EscapeMarkup().Truncate(70),
                item.remote
            );
        }

        AnsiConsole.Write(table);
    }

    private static async Task<int> HandleUiModeSearch(FlathubSearchSettings settings)
    {
        if (string.IsNullOrWhiteSpace(settings.Query))
        {
            Console.Error.WriteLine("Error: Query cannot be empty.");
            return 1;
        }

        try
        {
            var manager = new FlatpakManager();
            if (settings.JsonOutput)
            {
                var results = await manager.SearchFlathubJsonAsync(
                    settings.Query, page: settings.Page,
                    limit: settings.Limit, ct: CancellationToken.None);
                await using var stdout = System.Console.OpenStandardOutput();
                await using var writer = new System.IO.StreamWriter(stdout, System.Text.Encoding.UTF8);
                await writer.WriteLineAsync(results);
                await writer.FlushAsync();
                return 0;
            }
            else
            {
                var results = await manager.SearchFlathubAsync(
                    settings.Query,
                    page: settings.Page,
                    limit: settings.Limit,
                    ct: CancellationToken.None);

                var count = 0;
                if (results.hits is not null)
                {
                    foreach (var item in results.hits)
                    {
                        if (count++ >= settings.Limit) break;
                        Console.WriteLine($"{item.name} {item.app_id} - {item.summary}");
                    }
                }

                Console.Error.WriteLine(
                    $"Shown: {Math.Min(settings.Limit, results?.hits?.Count ?? 0)} / Total Pages: {results?.totalPages ?? 0} / Current Page: {results?.page ?? 0} / Total hits: {results?.totalHits ?? 0}");
            }

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Search failed: {ex.Message}");
            return 1;
        }
    }

    private List<Apps> SearchAllRepos(FlatpakManager manager, string query = "")
    {
        var remotes = manager.ListRemotesWithDetails();
        
        Console.WriteLine("Remotes: " + string.Join(", ", remotes));
        
        var appsList = new List<Apps>();
        foreach (var remote in remotes)
        {
            var apps = manager.GetAvailableAppsFromAppstream(remote.Name);
            if (apps is not [])
            {
                apps = apps.Where(x => x.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                                       x.Id.Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();
                appsList.AddRange(apps.Select(y => new Apps(y.Name, y.Id, y.Summary, remote.Name)));
            }
            else
            {
                var remoteApps = manager.GetAvailableAppsFromRemote(remote.Name);
                remoteApps = remoteApps.Where(x =>
                    x.Id.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                    x.Name.Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();
                appsList.AddRange(remoteApps.Select(y => new Apps(y.Name, y.Id, y.Summary, remote.Name)));
            }
        }

        return appsList;
    }

    private record Apps(string name, string app_id, string summary, string remote);
}