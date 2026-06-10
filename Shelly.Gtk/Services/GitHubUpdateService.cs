using System.Net;
using System.Net.Http.Json;
using Shelly.Utilities;

namespace Shelly.Gtk.Services;

public class GitHubUpdateService : IUpdateService
{
    private const string RepoOwner = "Seafoam-Labs";
    private const string RepoName = "Shelly-ALPM";
    private const string Url = $"https://api.github.com/repos/{RepoOwner}/{RepoName}/releases/latest";

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
        Timeout = TimeSpan.FromMinutes(1),
        DefaultRequestHeaders = { UserAgent = { Http.UserAgent } },
        DefaultRequestVersion = HttpVersion.Version11,
        DefaultVersionPolicy = HttpVersionPolicy.RequestVersionOrHigher
    };

    public async Task<string> PullReleaseNotesAsync()
    {
        try
        {
            await Console.Error.WriteLineAsync("[DEBUG] Checking for updates...");
            await Console.Error.WriteLineAsync($"[DEBUG] URL: {Url}");
            var latestRelease = await _httpClient.GetFromJsonAsync(Url, ShellyGtkJsonContext.Default.GitHubRelease);
            await Console.Error.WriteLineAsync($"[DEBUG] Latest release: {latestRelease?.TagName}");

            return latestRelease?.Body ?? string.Empty;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error checking for updates: {ex.Message}");
        }

        return string.Empty;
    }
}