using System.Xml.Linq;
using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Services;


public class ArchNewsService : IArchNewsService
{
    private static readonly HttpClient HttpClient = new() { Timeout = TimeSpan.FromSeconds(10) };
    private CachedRssModel? _cache;
    private static readonly TimeSpan CacheDuration = TimeSpan.FromMinutes(30);

    public async Task<List<RssModel>> FetchNewsAsync(CancellationToken ct)
    {
        if (_cache is not null && _cache.TimeCached.HasValue &&
            DateTime.Now - _cache.TimeCached.Value < CacheDuration)
        {
            return _cache.Rss;
        }

        try
        {
            var response = await HttpClient.GetStringAsync("https://archlinux.org/feeds/news/", ct);
            var doc = XDocument.Parse(response);
            var items = doc.Descendants("item")
                .Select(item => new RssModel
                {
                    Title = item.Element("title")?.Value,
                    Link = item.Element("link")?.Value,
                    Description = item.Element("description")?.Value,
                    PubDate = item.Element("pubDate")?.Value
                })
                .ToList();

            _cache = new CachedRssModel
            {
                Rss = items,
                TimeCached = DateTime.Now
            };

            return items;
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to fetch Arch News: {e.Message}");
            return _cache?.Rss ?? [];
        }
    }
}
