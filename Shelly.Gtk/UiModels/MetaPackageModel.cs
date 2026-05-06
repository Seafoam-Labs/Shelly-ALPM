namespace Shelly.Gtk.UiModels;

public class MetaPackageModel(
    string id,
    string name,
    string version,
    string description,
    PackageType packageType,
    string summary,
    string repository,
    bool isInstalled,
    long? lastUpdated = null
)
{
    public string Id { get; init; } = id;

    public string Name { get; init; } = name;

    public string Version { get; init; } = version;

    public string Description { get; init; } = description;

    public PackageType PackageType { get; init; } = packageType;

    public string Summary { get; init; } = summary;

    public string Repository { get; init; } = repository;

    public bool IsInstalled { get; set; } = isInstalled;

    public long? LastUpdated { get; init; } = lastUpdated;
}