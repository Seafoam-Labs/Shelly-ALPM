using System.CommandLine;
using System.Net;
using System.Text.Json;
using System.Xml.Linq;
using Shelly.Cli.Models.Standard;
using Shelly.Utilities;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Standard;

public class ArchNews : GlobalSettingsCommand
{
    private const string ArchlinuxFeed = "https://archlinux.org/feeds/news/";

    private static readonly string FeedFolder = XdgPaths.ShellyCache("archNewsFeed");

    private static readonly string FeedPath = Path.Combine(FeedFolder, "Feed.json");

    private bool All { get; set; }

    public static Command Create()
    {
        var all = new Option<bool>("--all", "-a") { Description = "Show all news, not just news you haven't seen before." };

        var command = new Command("news", "Show ArchLinux news") { all };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new ArchNews { All = parseResult.GetValue(all) };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        try
        {
            var fullFeed = await GetRssFeedAsync(ArchlinuxFeed);
            if (All)
            {
                if (JsonOutput) console.WriteLine(JsonSerializer.Serialize(fullFeed, ShellyCliJsonContext.Default.ListPackageInfo));
                else DisplayFeed(console, fullFeed);
                await CacheFeed(fullFeed);
            }
            else
            {
                var cachedFeed = await LoadCachedFeed();
                var unseenFeed = fullFeed.ExceptBy(cachedFeed.Select(model => model.Link), model => model.Link).ToList();
                if (JsonOutput)
                {
                    console.WriteLine(JsonSerializer.Serialize(unseenFeed, ShellyCliJsonContext.Default.ListPackageInfo));
                }
                else
                {
                    DisplayFeed(console, unseenFeed);
                    if (unseenFeed.Count == 0) console.WriteLine(Colorize("No new news found", ConsoleColor.Green));
                }

                if (unseenFeed.Count > 0) await CacheFeed(fullFeed);
            }
        }
        catch (Exception e)
        {
            console.WriteLine(Colorize($"Error fetching ArchLinux news: {e.Message}", ConsoleColor.Red));
            if (Verbose) console.WriteLine(Colorize($"Stack trace: {e.StackTrace}", ConsoleColor.Red));
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        try
        {
            var fullFeed = await GetRssFeedAsync(ArchlinuxFeed);
            if (All)
            {
                UiFrames.Frame(fullFeed);
                await CacheFeed(fullFeed);
            }
            else
            {
                var cachedFeed = await LoadCachedFeed();
                var unseenFeed = fullFeed.ExceptBy(cachedFeed.Select(model => model.Link), model => model.Link).ToList();
                UiFrames.Frame(unseenFeed);
                if (unseenFeed.Count > 0) await CacheFeed(fullFeed);
            }
        }
        catch (Exception e)
        {
            UiFrames.Error(e.Message);
        }
    }

    private static void DisplayFeed(IShellyConsole console, List<RssModel> feed)
    {
        foreach (var item in feed)
        {
            console.WriteLine();
            console.WriteLine(Colorize(item.Title, ConsoleColor.Yellow));
            console.WriteLine(Colorize(item.PubDate, ConsoleColor.Gray));
            console.WriteLine(Colorize(item.Link, ConsoleColor.Blue));
            console.WriteLine(Colorize(item.Description, ConsoleColor.White));
            console.WriteLine();
        }
    }

    private static async Task CacheFeed(List<RssModel> feed)
    {
        XdgPaths.EnsureDirectory(FeedFolder);
        await File.WriteAllTextAsync(FeedPath, JsonSerializer.Serialize(feed, ShellyCliJsonContext.Default.ListRssModel));
        XdgPaths.FixOwnershipIfRoot(FeedPath);
    }

    private static async Task<List<RssModel>> LoadCachedFeed()
    {
        if (!File.Exists(FeedPath)) return [];

        try
        {
            return JsonSerializer.Deserialize(await File.ReadAllTextAsync(FeedPath), ShellyCliJsonContext.Default.ListRssModel) ?? [];
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

        return xml.Descendants("item")
            .Select(item => new RssModel(
                item.Element("title")?.Value ?? "",
                item.Element("link")?.Value ?? "",
                HtmlToMarkdown.Convert(item.Element("description")?.Value ?? ""),
                item.Element("pubDate")?.Value ?? ""))
            .Reverse()
            .ToList();
    }

    private static HttpClient CreateHttpClient()
    {
        return new HttpClient(new SocketsHttpHandler
        {
            AutomaticDecompression = DecompressionMethods.All,
            AllowAutoRedirect = true,
            MaxAutomaticRedirections = 10,
            ConnectTimeout = TimeSpan.FromSeconds(10),
            EnableMultipleHttp2Connections = true,
            EnableMultipleHttp3Connections = true
        })
        {
            Timeout = TimeSpan.FromSeconds(10),
            DefaultRequestHeaders = { UserAgent = { Http.UserAgent } },
            DefaultRequestVersion = HttpVersion.Version11,
            DefaultVersionPolicy = HttpVersionPolicy.RequestVersionOrHigher
        };
    }
}