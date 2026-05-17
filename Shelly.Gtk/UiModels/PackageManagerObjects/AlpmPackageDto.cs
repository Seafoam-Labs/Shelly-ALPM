
namespace Shelly.Gtk.UiModels.PackageManagerObjects;

public partial record AlpmPackageDto
{
    public string Name { get; init; } = string.Empty;

    public string Version { get; init; } = string.Empty;

    public long Size { get; init; }

    public string Description { get; init; } = string.Empty;

    public string Url { get; init; } = string.Empty;

    public string Repository { get; init; } = string.Empty;

    public List<string> Replaces { get; init; } = [];

    public List<string> Licenses { get; init; } = [];

    public List<string> Groups { get; init; } = [];

    public List<string> Provides { get; init; } = [];

    public List<string> Depends { get; init; } = [];

    public List<string> OptDepends { get; init; } = [];

    public List<string> Conflicts { get; init; } = [];

    public AlpmPackageTreeDto? PackageFile { get; init; }

    public string InstallReason { get; init; } = string.Empty;

    public DateTime BuildDate { get; init; } = DateTime.MinValue;

    public DateTime? InstallDate { get; init; }

    public long DownloadSize { get; init; }

    public long InstalledSize { get; init; }

    public List<string> RequiredBy { get; init; } = [];

    public List<string> OptionalFor { get; init; } = [];
}
