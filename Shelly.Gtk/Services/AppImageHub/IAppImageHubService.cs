using Shelly.Gtk.UiModels.AppImageHub;

namespace Shelly.Gtk.Services.AppImageHub;

public interface IAppImageHubService
{
    Task<List<AppImageHubItem>> GetCatalogAsync(CancellationToken ct = default);
    void InvalidateCache();
}
