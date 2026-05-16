
namespace PackageManager.AppImage;

public partial record AppImageUpdateDto
{
    public string Name { get; set; } = string.Empty;
    public string Version { get; set; } = string.Empty;
    public string DownloadUrl { get; set; } = string.Empty;
    public bool IsUpdateAvailable { get; set; }
}