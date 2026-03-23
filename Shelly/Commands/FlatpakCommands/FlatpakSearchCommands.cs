using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakSearchCommands
{
    internal static async Task<int> SearchUiMode(string query, bool json, int limit, int page)
    {
        if (string.IsNullOrWhiteSpace(query))
        {
            Console.Error.WriteLine("Error: Query cannot be empty.");
            return 1;
        }
        try
        {
            var manager = new FlatpakManager();
            if (json)
            {
                var results = await manager.SearchFlathubJsonAsync(
                    query, page: page, limit: limit, ct: CancellationToken.None);
                await using var stdout = Console.OpenStandardOutput();
                await using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
                await writer.WriteLineAsync(results);
                await writer.FlushAsync();
                return 0;
            }
            else
            {
                var results = await manager.SearchFlathubAsync(
                    query, page: page, limit: limit, ct: CancellationToken.None);
                var count = 0;
                if (results.hits is not null)
                {
                    foreach (var item in results.hits)
                    {
                        if (count++ >= limit) break;
                        Console.WriteLine($"{item.name} {item.app_id} - {item.summary}");
                    }
                }
                Console.Error.WriteLine(
                    $"Shown: {Math.Min(limit, results?.hits?.Count ?? 0)} / Total Pages: {results?.totalPages ?? 0} / Current Page: {results?.page ?? 0} / Total hits: {results?.totalHits ?? 0}");
            }
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Search failed: {ex.Message}");
            return 1;
        }
    }
    internal static async Task<int> SearchConsoleMode(string query, bool json, int limit, int page)
    {
        if (string.IsNullOrWhiteSpace(query))
        {
            Console.WriteLine("Error: Query cannot be empty.");
            return 1;
        }
        try
        {
            var manager = new FlatpakManager();
            if (json)
            {
                var results = await manager.SearchFlathubJsonAsync(
                    query, page: page, limit: limit, ct: CancellationToken.None);
                await using var stdout = Console.OpenStandardOutput();
                await using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
                await writer.WriteLineAsync(results);
                await writer.FlushAsync();
                return 0;
            }
            else
            {
                var results = SearchAllRepos(manager, query);
                foreach (var item in results.Take(limit))
                {
                    Console.WriteLine($"{item.Name,-30} {item.AppId,-40} {item.Summary,-50} {item.Remote}");
                }
                Console.WriteLine($"Total: {results.Count} results");
            }
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Search failed: {ex.Message}");
            return 1;
        }
    }
    private static List<SearchResult> SearchAllRepos(FlatpakManager manager, string query)
    {
        var remotes = manager.ListRemotesWithDetails();
        var appsList = new List<SearchResult>();
        foreach (var remote in remotes)
        {
            var apps = manager.GetAvailableAppsFromAppstream(remote.Name);
            if (apps is not [])
            {
                apps = apps.Where(x => x.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                                       x.Id.Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();
                appsList.AddRange(apps.Select(y => new SearchResult(y.Name, y.Id, y.Summary, remote.Name)));
            }
            else
            {
                var remoteApps = manager.GetAvailableAppsFromRemote(remote.Name);
                remoteApps = remoteApps.Where(x =>
                    x.Id.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                    x.Name.Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();
                appsList.AddRange(remoteApps.Select(y => new SearchResult(y.Name, y.Id, y.Summary, remote.Name)));
            }
        }
        return appsList;
    }
    private record SearchResult(string Name, string AppId, string Summary, string Remote);
}
