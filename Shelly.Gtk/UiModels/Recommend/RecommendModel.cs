using Shelly.Gtk.Enums;

namespace Shelly.Gtk.UiModels.Recommend;

public class RecommendModel
{
    public string Name { get; set; } = string.Empty;
    public List<string> Packages { get; set; } = [];
}

public class FlatRecommendModel
{
    public RecommendCategory Category { get; set; }
    public string Package { get; init; } = string.Empty;
    
    public string Description { get; init; } = string.Empty;
    
    public string Version { get; init; } = string.Empty;
    
    public string Repository { get; init; } = string.Empty;
    
    public bool IsInstalled { get; init; }
}