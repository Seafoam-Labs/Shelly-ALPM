using System.CommandLine;
using PackageManager.Flatpak;
using Shelly.Cli.Interactions;

namespace Shelly.Cli.Commands.Flatpak;

public class Search : GlobalSettingsCommand
{
    private string Query { get; set; } = string.Empty;
    private int Limit { get; set; }
    private int Page { get; set; }

    public static Command Create()
    {
        var query = new Argument<string>("query") { Description = "Search term to find Flatpak applications on Flathub" };
        var limit = new Option<int>("--limit", "-l") { Description = "Maximum number of search results to display per page", DefaultValueFactory = _ => 21 };
        var page = new Option<int>("--page", "-p") { Description = "Page number for paginated results (starts at 1)", DefaultValueFactory = _ => 1 };

        var command = new Command("search", "Search flatpak")
        {
            query, limit, page
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Search
            {
                Query = parseResult.GetValue(query) ?? string.Empty,
                Limit = parseResult.GetValue(limit),
                Page = parseResult.GetValue(page)
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        if (string.IsNullOrWhiteSpace(Query))
        {
            if (UiMode)
                UiFrames.Error("Query cannot be empty.");
            else
                console.WriteLine(AnsiUtilities.Colorize("Query cannot be empty.", ConsoleColor.Red));
            return;
        }

        var manager = new FlatpakManager();

        try
        {
            if (JsonOutput)
            {
                var json = await manager.SearchFlathubJsonAsync(Query, page: Page, limit: Limit, ct: CancellationToken.None);
                console.WriteLine(json);
                return;
            }

            if (UiMode)
            {
                var search = await manager.SearchFlathubAsync(Query, page: Page, limit: Limit, ct: CancellationToken.None);
                UiFrames.Info(
                    $"Shown: {Math.Min(Limit, search?.hits?.Count ?? 0)} / Total Pages: {search?.totalPages ?? 0} / Current Page: {search?.page ?? 0} / Total hits: {search?.totalHits ?? 0}");
                return;
            }

            var results = SearchAllRepos(manager, Query);
            console.WriteLine(BasicTable.Execute(
                ["Name", "AppId", "Summary", "Remote"], results.Take(Limit).ToList(),
                item => item.Name,
                item => item.AppId,
                item => Truncate(item.Summary, 70),
                item => item.Remote));
        }
        catch (Exception ex)
        {
            if (UiMode)
                UiFrames.Error($"Search failed: {ex.Message}");
            else
                console.WriteLine(AnsiUtilities.Colorize($"Search failed: {ex.Message}", ConsoleColor.Red));
        }
    }

    public override ValueTask ExecuteUiMode() => ValueTask.CompletedTask;

    private static List<Apps> SearchAllRepos(FlatpakManager manager, string query)
    {
        var remotes = manager.ListRemotesWithDetails();
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

    private static string Truncate(string value, int max) =>
        value.Length <= max ? value : value[..max];

    private record Apps(string Name, string AppId, string Summary, string Remote);
}
