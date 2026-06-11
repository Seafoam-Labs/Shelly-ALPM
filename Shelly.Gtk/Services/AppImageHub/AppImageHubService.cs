using System.Net;
using System.Text.Json;
using Shelly.Gtk.UiModels.AppImageHub;
using Shelly.Utilities;

namespace Shelly.Gtk.Services.AppImageHub;

public class AppImageHubService : IAppImageHubService
{
    private const string CatalogUrl = "https://appimage.github.io/feed.json";

    private readonly HttpClient _httpClient = new(new SocketsHttpHandler
    {
        AutomaticDecompression = DecompressionMethods.All,
        AllowAutoRedirect = true,
        MaxAutomaticRedirections = 10,
        ConnectTimeout = TimeSpan.FromSeconds(30),
        EnableMultipleHttp2Connections = true,
        EnableMultipleHttp3Connections = true
    })
    {
        Timeout = TimeSpan.FromMinutes(2),
        DefaultRequestHeaders = { UserAgent = { Http.UserAgent } },
        DefaultRequestVersion = new Version(1, 1),
    };

    private List<AppImageHubItem>? _cache;

    public async Task<List<AppImageHubItem>> GetCatalogAsync(CancellationToken ct = default)
    {
        if (_cache != null) return _cache;

        var response = await _httpClient.GetAsync(CatalogUrl, ct);
        response.EnsureSuccessStatusCode();
        var json = await response.Content.ReadAsStringAsync(ct);

        var feed = JsonSerializer.Deserialize(json, ShellyGtkJsonContext.Default.AppImageHubFeed);
        _cache = feed?.Items ?? [];
        return _cache;
    }

    public void InvalidateCache() => _cache = null;
}
