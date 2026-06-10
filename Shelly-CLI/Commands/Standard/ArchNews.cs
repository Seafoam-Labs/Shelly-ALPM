using System.Net;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using PackageManager.Wire;
using Shelly_CLI.Commands.Standard.Models;
using Shelly_CLI.Utility;
using Shelly.Utilities;
using Shelly.Utilities.Eventing;
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
                    await OutputFeed(feed);
                else
                    foreach (var item in feed)
                    {
                        AnsiConsole.MarkupLine($"[yellow]\n{item.Title.EscapeMarkup()}[/]");
                        AnsiConsole.MarkupLine($"[gray]{item.PubDate.EscapeMarkup()}[/]");
                        AnsiConsole.MarkupLine($"[blue]{item.Link.EscapeMarkup()}[/]");
                        AnsiConsole.MarkupLine($"[white]{item.Description.EscapeMarkup()}[/]");
                    }

                await CacheFeed(feed);
            }
            catch (Exception e)
            {
                if (Program.IsUiMode)
                    JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, e.Message));
                else
                    AnsiConsole.MarkupLine($"[red]{e.Message.EscapeMarkup()}[/]");
            }
        }
        else
        {
            var cachedFeed = await LoadCachedFeed();
            var feed = await GetRssFeedAsync(ArchlinuxFeed);

            var newFeed = feed.ExceptBy(cachedFeed.Select(model => model.Link), model => model.Link).ToList();

            if (settings.Json)
            {
                await OutputFeed(newFeed);
                if (newFeed.Count > 0) await CacheFeed(feed);
                return 0;
            }

            foreach (var item in newFeed)
            {
                AnsiConsole.MarkupLine($"[yellow]\n{item.Title.EscapeMarkup()}[/]");
                AnsiConsole.MarkupLine($"[gray]{item.PubDate.EscapeMarkup()}[/]");
                AnsiConsole.MarkupLine($"[blue]{item.Link.EscapeMarkup()}[/]");
                AnsiConsole.MarkupLine($"[white]{item.Description.EscapeMarkup()}[/]");
            }

            if (newFeed.Count > 0) await CacheFeed(feed);
            else AnsiConsole.MarkupLine("[green]No new news found[/]");
        }

        return 0;
    }

    private static async Task CacheFeed(List<RssModel> feed)
    {
        XdgPaths.EnsureDirectory(FeedFolder);

        var json = JsonSerializer.Serialize(feed, ShellyCLIJsonContext.Default.ListRssModel);
        await File.WriteAllTextAsync(FeedPath, json);
        XdgPaths.FixOwnershipIfRoot(FeedPath);
    }

    private static async Task<List<RssModel>> LoadCachedFeed()
    {
        if (!File.Exists(FeedPath)) return [];

        try
        {
            var json = await File.ReadAllTextAsync(FeedPath);
            return JsonSerializer.Deserialize(json, ShellyCLIJsonContext.Default.ListRssModel) ?? [];
        }
        catch
        {
            return [];
        }
    }

    private static async Task<List<RssModel>> GetRssFeedAsync(string url)
    {
        var xmlString = await CreateHttpClient().GetStringAsync(url);

        var xml = XDocument.Parse(xmlString);

        return xml.Descendants("item").Select(item => new RssModel
        {
            Title = item.Element("title")?.Value ?? "",
            Link = item.Element("link")?.Value ?? "",
            Description = HtmlToMarkdown.Convert(item.Element("description")?.Value ?? ""),
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
            await using var writer = new StreamWriter(stdout, Encoding.UTF8);
            await writer.WriteLineAsync(json);
            await writer.FlushAsync();
        }
    }

    private static HttpClient CreateHttpClient()
    {
        return new HttpClient(new SocketsHttpHandler
        {
            AutomaticDecompression = DecompressionMethods.All,
            AllowAutoRedirect = true,
            MaxAutomaticRedirections = 10,
            ConnectTimeout = TimeSpan.FromSeconds(30),
            EnableMultipleHttp2Connections = true,
            EnableMultipleHttp3Connections = true
        })
        {
            Timeout = TimeSpan.FromMinutes(1),
            DefaultRequestHeaders = { UserAgent = { Http.UserAgent } },
            DefaultRequestVersion = HttpVersion.Version11,
            DefaultVersionPolicy = HttpVersionPolicy.RequestVersionOrHigher
        };
    }
}