using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Shelly.Models;

public class SyncModel
{
    public SyncMetaData MetaData { get; set; } = new();
    public List<SyncPackageModel> Packages { get; set; } = [];
    public List<SyncAurModel> Aur { get; set; } = [];
    public List<SyncFlatpakModel> Flatpaks { get; set; } = [];
}

public class SyncPackageModel
{
    public string Name { get; set; } = string.Empty;

    public string Version { get; set; } = string.Empty;

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? OldVersion { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? DownloadSize { get; set; }
}

public class SyncAurModel
{
    public string Name { get; set; } = string.Empty;

    public string Version { get; set; } = string.Empty;

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? OldVersion { get; set; }
}

public class SyncFlatpakModel
{
    public string Id { get; set; } = string.Empty;

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Name { get; set; }

    public string Version { get; set; } = string.Empty;
}

public class SyncMetaData
{
    public string Version { get; set; } ="v1";
    
    public string Date { get; set; } = string.Empty;

    public long Time { get; set; } = 0;
}