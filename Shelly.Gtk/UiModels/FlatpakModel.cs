namespace Shelly.Gtk.UiModels;

public class FlatpakModel
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Version { get; set; } = string.Empty;
    public string Arch { get; set; } = string.Empty;
    public string Branch { get; set; } = string.Empty;
    public string LatestCommit {get; set;} = string.Empty;
    public string Summary { get; set; }  = string.Empty;
    public string IconPath { get; set; } = string.Empty;
    public string Kind { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public List<string> Categories { get; set; } = [];
}