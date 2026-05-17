using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace PackageManager.AppImage;

public partial record AppImageDto
{
    public string Name { get; set; } = string.Empty;
    public string DesktopName { get; set; } = string.Empty;
    public string Version { get; set; } = string.Empty;
    public string UpdateVersion { get; set; } = string.Empty;
    public string IconName { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public long SizeOnDisk { get; set; } = 0;
    public string UpdateURl { get; set; } = string.Empty;
    public string RawUpdateInfo { get; set; } = string.Empty;
    public UpdateType UpdateType { get; set; } = UpdateType.StaticUrl;
}

[JsonSourceGenerationOptions(WriteIndented = true)]
[JsonSerializable(typeof(List<AppImageDto>))]
internal partial class AppImageJsonContext : JsonSerializerContext
{
}