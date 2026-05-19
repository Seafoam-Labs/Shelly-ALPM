using System.Text.Json.Serialization;

namespace Shelly_CLI;

public partial class SyncModel
{
    public SyncMetaData MetaData { get; set; } = new();
    public List<SyncPackageModel> Packages { get; set; } = [];
    public List<SyncAurModel> Aur { get; set; } = [];
    public List<SyncFlatpakModel> Flatpaks { get; set; } = [];
}

public partial class SyncPackageModel
{
    public string Name { get; set; } = string.Empty;

    public string Version { get; set; } = string.Empty;

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? OldVersion { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? DownloadSize { get; set; }
}

public partial class SyncAurModel
{
    public string Name { get; set; } = string.Empty;

    public string Version { get; set; } = string.Empty;

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? OldVersion { get; set; }
}

public partial class SyncFlatpakModel
{
    public string Id { get; set; } = string.Empty;

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Name { get; set; }

    public string Version { get; set; } = string.Empty;
}

public partial class SyncMetaData
{
    public string Version { get; set; } ="v1";
    
    public string Date { get; set; } = string.Empty;

    public long Time { get; set; } = 0;
}