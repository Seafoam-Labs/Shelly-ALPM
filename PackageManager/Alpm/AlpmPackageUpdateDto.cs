using System.Collections.Generic;

namespace PackageManager.Alpm;

public partial record AlpmPackageUpdateDto
{
    public string Name { get; init; } = string.Empty;
    public string CurrentVersion { get; init; } = string.Empty;
    public string NewVersion { get; init; } = string.Empty;
    public long DownloadSize { get; init; }
    public long SizeDifference { get; init; }
    public string Description { get; init; } = string.Empty;
    public string Url { get; init; } = string.Empty;
    public string Repository { get; init; } = string.Empty;
    public long InstalledSize { get; init; }
    public List<string> Depends { get; init; } = [];
    public List<string> OptDepends { get; init; } = [];
    public List<string> Licenses { get; init; } = [];
    public List<string> Provides { get; init; } = [];
    public List<string> Conflicts { get; init; } = [];
    public List<string> Groups { get; init; } = [];
}
