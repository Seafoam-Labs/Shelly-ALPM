
using System.Net.Http.Json;
using Shelly.Gtk.UiModels;
using Shelly.Utilities;

namespace Shelly.Gtk.Services;

public class GitHubUpdateService : IUpdateService
{
    private readonly HttpClient _httpClient = new();
    private const string RepoOwner = "ZoeyErinBauer";
    private const string RepoName = "Shelly-ALPM";
    private const string Url = $"https://api.github.com/repos/{RepoOwner}/{RepoName}/releases/latest";
    private const string Url2 = $"https://api.github.com/repos/ZC-Development/Shelly/releases/latest";
    private GitHubRelease? _latestRelease;

    public GitHubUpdateService()
    {
        _httpClient.DefaultRequestHeaders.UserAgent.Add(Http.UserAgent);
    }


    public async Task<string> PullReleaseNotesAsync()
    {
        try
        {
            await Console.Error.WriteLineAsync("[DEBUG] Checking for updates...");
            await Console.Error.WriteLineAsync($"[DEBUG] URL: {Url}");
            _latestRelease = await _httpClient.GetFromJsonAsync(Url, ShellyGtkJsonContext.Default.GitHubRelease) ??
                             await _httpClient.GetFromJsonAsync(Url2, ShellyGtkJsonContext.Default.GitHubRelease);
            await Console.Error.WriteLineAsync($"[DEBUG] Latest release: {_latestRelease?.TagName}");

            return _latestRelease?.Body ?? string.Empty;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error checking for updates: {ex.Message}");
        }

        return string.Empty;
    }
}