namespace Shelly.Gtk.UiModels;

public class CachedRssModel
{
    public List<RssModel> Rss { get; set; } = [];
    public DateTime? TimeCached { get; set; } 
}
