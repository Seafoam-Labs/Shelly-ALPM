using System.Formats.Tar;
using System.IO.Compression;
using System.Net.Http.Json;
using Shelly.Gtk.UiModels;
using Shelly.Utilities;

namespace Shelly.Gtk.Services.Icons;

public class IconDownloadService : IIConDownloadService
{
    private readonly HttpClient _client = new();
    private const string ReleaseUrl = "https://api.github.com/repos/Seafoam-Labs/shelly-icon-stream/releases/latest";

    public IconDownloadService()
    {
        _client.DefaultRequestHeaders.UserAgent.Add(Http.UserAgent);
    }

    public async Task<bool> DownloadAndUnpackIcons()
    {
        try
        {
            var iconFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local/share/shelly-icons");
            var hashFile = Path.Combine(iconFolder, ".hash");
            
            if (!Directory.Exists(iconFolder))
            {
                Directory.CreateDirectory(iconFolder);
            }

            var latestRelease = await _client.GetFromJsonAsync(ReleaseUrl, ShellyGtkJsonContext.Default.GitHubRelease);
            if (latestRelease == null)
            {
                Console.WriteLine("[ERROR] Could not find latest release.");
                return false;
            }
            
            var asset = latestRelease.Assets.FirstOrDefault(a => a.Name.EndsWith(".tar.gz") && !string.IsNullOrEmpty(a.Digest));
     
            if (File.Exists(hashFile))
            {
                var currentHash = await File.ReadAllTextAsync(hashFile);
                if (currentHash.Trim() == asset?.Digest.Trim())
                {
                    return true;
                }
            }
            
            var downloadUrl = asset?.BrowserDownloadUrl ?? latestRelease.TarballUrl;
            if (string.IsNullOrEmpty(downloadUrl)) return false;

            using var response = await _client.GetAsync(downloadUrl, HttpCompletionOption.ResponseHeadersRead);
            response.EnsureSuccessStatusCode();

            await using var stream = await response.Content.ReadAsStreamAsync();
            await using var gzipStream = new GZipStream(stream, CompressionMode.Decompress);
            
            await TarFile.ExtractToDirectoryAsync(gzipStream, iconFolder, overwriteFiles: true);
            
            if (asset != null && !string.IsNullOrEmpty(asset.Digest))
            {
                await File.WriteAllTextAsync(hashFile, asset.Digest);
            }
            
            return true;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[ERROR] Failed to download or unpack icons: {ex.Message}");
            return false;
        }
    }
}