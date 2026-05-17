
namespace PackageManager.Aur.Models;

public partial class AurUpdateDto
{
    public string Name { get; set; } = string.Empty;
    public string Version { get; set; } = string.Empty;
    public string NewVersion { get; set; } = string.Empty;
    public long DownloadSize { get; set; } = 0;
    public string Url { get; set; } = string.Empty;
    public string PackageBase { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    
    public override string ToString()
    {
        return $"{Name}: {Version} -> {NewVersion} ({DownloadSize} bytes)";
    }
}