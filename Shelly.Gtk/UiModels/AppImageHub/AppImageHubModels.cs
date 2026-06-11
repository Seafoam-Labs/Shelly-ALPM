using System.Net;
using System.Text.Json.Serialization;

namespace Shelly.Gtk.UiModels.AppImageHub;

public class AppImageHubFeed
{
    [JsonPropertyName("items")]
    public List<AppImageHubItem> Items { get; set; } = [];
}

public class AppImageHubItem
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("description")]
    public string? Description { get; set; }

    [JsonPropertyName("categories")]
    public List<string>? Categories { get; set; }

    [JsonPropertyName("authors")]
    public List<AppImageHubAuthor>? Authors { get; set; }

    [JsonPropertyName("license")]
    public string? License { get; set; }

    [JsonPropertyName("links")]
    public List<AppImageHubLink>? Links { get; set; }

    [JsonPropertyName("icons")]
    public List<string>? Icons { get; set; }

    [JsonPropertyName("screenshots")]
    public List<string>? Screenshots { get; set; }

    public string DisplayName => Name.Replace('_', ' ').Replace('-', ' ');

    public string? CleanDescription
    {
        get
        {
            if (string.IsNullOrEmpty(Description)) return Description;
            var sb = new System.Text.StringBuilder();
            var inTag = false;
            var lastWasSpace = true;
            foreach (var c in Description)
            {
                if (c == '<') { inTag = true; continue; }
                if (c == '>') { inTag = false; if (!lastWasSpace) { sb.Append(' '); lastWasSpace = true; } continue; }
                if (inTag) continue;
                if (char.IsWhiteSpace(c))
                {
                    if (!lastWasSpace) { sb.Append(' '); lastWasSpace = true; }
                    continue;
                }
                sb.Append(c);
                lastWasSpace = false;
            }
            return WebUtility.HtmlDecode(sb.ToString().Trim());
        }
    }

    public string? GitHubUrl
    {
        get
        {
            var link = Links?.FirstOrDefault(l =>
                l.Type.Equals("GitHub", StringComparison.OrdinalIgnoreCase));
            if (link == null) return null;
            var url = link.Url;
            if (!url.StartsWith("http", StringComparison.OrdinalIgnoreCase))
                url = "https://github.com/" + url;
            return url;
        }
    }

    public string? DirectDownloadUrl =>
        Links?.FirstOrDefault(l =>
            l.Type.Equals("Download", StringComparison.OrdinalIgnoreCase))?.Url;

    private string? GetForgeUrl(string type, string prefix) =>
        Links?.FirstOrDefault(l => l.Type.Equals(type, StringComparison.OrdinalIgnoreCase)) is { } link
            ? (link.Url.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? link.Url : prefix + link.Url)
            : null;

    public string? GitLabUrl => GetForgeUrl("GitLab", "https://gitlab.com/");
    public string? CodebergUrl => GetForgeUrl("Codeberg", "https://codeberg.org/");
    public string? ForgejoUrl => GetForgeUrl("Forgejo", "https://forgejo.org/");

    public bool HasDownload => GitHubUrl != null || DirectDownloadUrl != null
                               || GitLabUrl != null || CodebergUrl != null || ForgejoUrl != null;

    public string? IconUrl
    {
        get
        {
            const string prefix =
                "https://raw.githubusercontent.com/AppImage/appimage.github.io/master/database/";
            var icon = Icons?.FirstOrDefault();
            if (icon == null) return null;
            return icon.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? icon : prefix + icon;
        }
    }

}

public class AppImageHubLink
{
    [JsonPropertyName("type")]
    public string Type { get; set; } = string.Empty;

    [JsonPropertyName("url")]
    public string Url { get; set; } = string.Empty;
}

public class AppImageHubAuthor
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("url")]
    public string? Url { get; set; }
}
