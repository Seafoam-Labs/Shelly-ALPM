
namespace Shelly.Gtk.UiModels.PackageManagerObjects;

public partial record AurPackageDto
{
    public int Id { get; set; }

    public string Name { get; set; } = string.Empty;

    public int PackageBaseId { get; set; }

    public string PackageBase { get; set; } = string.Empty;

    public string Version { get; set; } = string.Empty;

    public string? Description { get; set; }

    public string? Url { get; set; }

    public int NumVotes { get; set; }

    public double Popularity { get; set; }

    public long? OutOfDate { get; set; }

    public string? Maintainer { get; set; }

    public long FirstSubmitted { get; set; }

    public long LastModified { get; set; }

    public string? UrlPath { get; set; }

    public List<string>? Depends { get; set; }

    public List<string>? MakeDepends { get; set; }

    public List<string>? OptDepends { get; set; }

    public List<string>? CheckDepends { get; set; }

    public List<string>? Conflicts { get; set; }

    public List<string>? Provides { get; set; }

    public List<string>? Replaces { get; set; }

    public List<string>? Groups { get; set; }

    public List<string>? License { get; set; }

    public List<string>? Keywords { get; set; }
}