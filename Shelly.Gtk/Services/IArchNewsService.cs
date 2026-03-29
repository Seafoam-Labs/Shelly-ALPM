using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Services;

public interface IArchNewsService
{
    Task<List<RssModel>> FetchNewsAsync(CancellationToken ct);
}