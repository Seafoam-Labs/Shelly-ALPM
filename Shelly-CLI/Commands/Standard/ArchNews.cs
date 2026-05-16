using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using PackageManager.Utilities;
using PackageManager.Wire;
using Shelly_CLI.Commands.Standard.Models;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class ArchNews : AsyncCommand<ArchNewsSettings>
{
    private const string ArchlinuxFeed = "https://archlinux.org/feeds/news/";

    private static readonly string FeedFolder = XdgPaths.ShellyCache("archNewsFeed");
    private static readonly string FeedPath = Path.Combine(FeedFolder, "Feed.json");

    public override async Task<int> ExecuteAsync(CommandContext context, ArchNewsSettings settings)
    {
        if (settings.All)
        {
            try
            {
                var feed = await GetRssFeedAsync(ArchlinuxFeed);
                if (settings.Json)
                {
                    await OutputFeed(feed);
                }
                else
                {
                    foreach (var item in feed)
                    {
                        AnsiConsole.MarkupLine($"[yellow]\n{item.Title.EscapeMarkup()}[/]");
                        AnsiConsole.MarkupLine($"[gray]{item.PubDate.EscapeMarkup()}[/]");
                        AnsiConsole.MarkupLine($"[blue]{item.Link.EscapeMarkup()}[/]");
                        AnsiConsole.MarkupLine($"[white]{item.Description.EscapeMarkup()}[/]");
                    }
                }

                CacheFeed(feed);
            }
            catch (Exception e)
            {
                Console.WriteLine(e);
            }
        }
        else
        {
            var cachedFeed = LoadCachedFeed();
            var feed = await GetRssFeedAsync(ArchlinuxFeed);

            var newFeed = feed.Except(cachedFeed).ToList();

            if (settings.Json)
            {
                await OutputFeed(newFeed);
                if (newFeed.Count > 0) CacheFeed(feed);
                return 0;
            }

            foreach (var item in newFeed)
            {
                AnsiConsole.MarkupLine($"[yellow]\n{item.Title.EscapeMarkup()}[/]");
                AnsiConsole.MarkupLine($"[gray]{item.PubDate.EscapeMarkup()}[/]");
                AnsiConsole.MarkupLine($"[blue]{item.Link.EscapeMarkup()}[/]");
                AnsiConsole.MarkupLine($"[white]{item.Description.EscapeMarkup()}[/]");
            }

            if (newFeed.Count > 0) CacheFeed(feed);
            else AnsiConsole.MarkupLine("[green]No new news found[/]");
        }

        return 0;
    }

    private static void CacheFeed(List<RssModel> feed)
    {
        XdgPaths.EnsureDirectory(FeedFolder);

        var json = JsonSerializer.Serialize(feed, ShellyCLIJsonContext.Default.ListRssModel);
        File.WriteAllText(FeedPath, json);
        XdgPaths.FixOwnershipIfRoot(FeedPath);
    }

    private static List<RssModel> LoadCachedFeed()
    {
        if (!File.Exists(FeedPath)) return [];

        try
        {
            var json = File.ReadAllText(FeedPath);
            return JsonSerializer.Deserialize(json, ShellyCLIJsonContext.Default.ListRssModel) ?? [];
        }
        catch
        {
            return [];
        }
    }

    private static async Task<List<RssModel>> GetRssFeedAsync(string url)
    {
        using var client = new HttpClient();
        var xmlString = await client.GetStringAsync(url);

        var xml = XDocument.Parse(xmlString);

        return xml.Descendants("item").Select(item => new RssModel
        {
            Title = item.Element("title")?.Value ?? "", Link = item.Element("link")?.Value ?? "",
            Description = Regex.Replace(item.Element("description")?.Value ?? "", "<.*?>", string.Empty),
            PubDate = item.Element("pubDate")?.Value ?? ""
        }).Reverse().ToList();
    }

    private static async Task OutputFeed(List<RssModel> feed)
    {
        if (Program.IsUiMode)
        {
            JsonPackFrame.WriteToStdout(feed);
        }
        else
        {
            var json = JsonSerializer.Serialize(feed, ShellyCLIJsonContext.Default.ListRssModel);
            await using var stdout = Console.OpenStandardOutput();
            await using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            await writer.WriteLineAsync(json);
            await writer.FlushAsync();
        }
    }
}