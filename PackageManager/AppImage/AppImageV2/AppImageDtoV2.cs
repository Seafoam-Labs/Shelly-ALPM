using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace PackageManager.AppImage.AppImageV2;

public partial record AppImageDtoV2
{
    public string Name { get; set; } = string.Empty;
    public string DesktopName { get; set; } = string.Empty;
    public string Version { get; set; } = string.Empty;
    public string IconName { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public long SizeOnDisk { get; set; } = 0;
    public string UpdateURl { get; set; } = string.Empty;
    public string RawUpdateInfo { get; set; } = string.Empty;
    public string? RepoOwner { get; set; }
    public string? RepoName { get; set; }
    public UpdateType UpdateType { get; set; } = UpdateType.None;
    
    public bool AllowPrerelease { get; set; } = false;
    public string? CommandLineArgs { get; set; }
    public string? Path { get; set; }
}


[JsonSourceGenerationOptions(WriteIndented = true)]
[JsonSerializable(typeof(List<AppImageDtoV2>))]
internal partial class AppImageJsonContextV2 : JsonSerializerContext
{
}