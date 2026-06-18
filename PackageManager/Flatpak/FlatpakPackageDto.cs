using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace PackageManager.Flatpak;

public partial class FlatpakPackageDto
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Version { get; set; } = string.Empty;
    public string Arch { get; set; } = string.Empty;
    public string Branch { get; set; } = string.Empty;
    public string LatestCommit {get; set;} = string.Empty;
    public string Summary { get; set; }  = string.Empty;
    public int Kind { get; init; }
    public string? IconPath { get; set; }
    public string Description { get; set; } = string.Empty;
    public List<AppstreamRelease> Releases { get; set; } = [];
    
    public List<string> Categories { get; set; } = [];
    
    public string Remote { get; set; } = string.Empty;
    
    public InstallLevel InstallLevel { get; set; }

    public List<string> Permissions { get; set; } = [];
    
    public string Ref =>
        $"{GetKindString()}/{Id}/{Arch}/{Branch}";

    public string FullRef =>
        $"{Remote}:{Ref}";

    private string GetKindString()
    {
        return Kind == 0
            ? "app"
            : "runtime";
    }

}
