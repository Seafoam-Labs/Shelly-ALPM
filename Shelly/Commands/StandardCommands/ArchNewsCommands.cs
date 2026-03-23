using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;
namespace Shelly.Commands.StandardCommands;

internal static class ArchNewsCommands
{
    private static readonly string? Username = Environment.GetEnvironmentVariable("USER");
    private static readonly string FeedFolder = Path.Combine("/home", Username ?? throw new InvalidOperationException(), ".cache", "Shelly", "archNewsFeed");
    private static readonly string FeedPath = Path.Combine(FeedFolder, "Feed.json");

    internal static async Task<int> ShowArchNews(bool verbose, bool all)
    {
        if (all)
        {
            try
            {
                var feed = await GetRssFeedAsync("https://archlinux.org/feeds/news/");
                foreach (var item in feed)
                {
                    Console.WriteLine($"\n{item.Title}");
                    Console.WriteLine(item.PubDate);
                    Console.WriteLine(item.Link);
                    Console.WriteLine(item.Description);
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
            var feed = await GetRssFeedAsync("https://archlinux.org/feeds/news/");
            var newFeed = feed.Except(cachedFeed).ToList();
            foreach (var item in newFeed)
            {
                Console.WriteLine($"\n{item.Title}");
                Console.WriteLine(item.PubDate);
                Console.WriteLine(item.Link);
                Console.WriteLine(item.Description);
            }
            if (newFeed.Count > 0) CacheFeed(feed);
            else Console.WriteLine("No new news found");
        }
        return 0;
    }

    private static void CacheFeed(List<RssModel> feed)
    {
        if (!Directory.Exists(FeedFolder)) Directory.CreateDirectory(FeedFolder);
        var json = JsonSerializer.Serialize(feed, ShellyJsonContext.Default.ListRssModel);
        File.WriteAllText(FeedPath, json);
    }

    private static List<RssModel> LoadCachedFeed()
    {
        if (!File.Exists(FeedPath)) return [];
        try
        {
            var json = File.ReadAllText(FeedPath);
            return JsonSerializer.Deserialize(json, ShellyJsonContext.Default.ListRssModel) ?? [];
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
            Title = item.Element("title")?.Value ?? "",
            Link = item.Element("link")?.Value ?? "",
            Description = Regex.Replace(item.Element("description")?.Value ?? "", "<.*?>", string.Empty),
            PubDate = item.Element("pubDate")?.Value ?? ""
        }).Reverse().ToList();
    }

    public record RssModel
    {
        public string? Title { get; init; }
        public string? Link { get; init; }
        public string? Description { get; init; }
        public string? PubDate { get; init; }
    }
}
