using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Shelly.Gtk.UiModels.PackageManagerObjects;

public record FlatpakPackageDto
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = string.Empty;

    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("version")]
    public string Version { get; set; } = string.Empty;

    [JsonPropertyName("arch")]
    public string Arch { get; set; } = string.Empty;

    [JsonPropertyName("branch")]
    public string Branch { get; set; } = string.Empty;

    [JsonPropertyName("latest_commit")]
    public string LatestCommit { get; set; } = string.Empty;

    [JsonPropertyName("summary")]
    public string Summary { get; set; } = string.Empty;

    [JsonPropertyName("kind")]
    public int Kind { get; init; }

    [JsonPropertyName("icon_path")]
    public string? IconPath { get; set; }

    [JsonPropertyName("description")]
    public string Description { get; set; } = string.Empty;
    
    [JsonPropertyName("remote")]
    public string remote { get; set; } = string.Empty;

    [JsonPropertyName("releases")]
    public List<AppstreamRelease> Releases { get; set; } = [];

    [JsonPropertyName("categories")] public List<string> Categories { get; set; }
}