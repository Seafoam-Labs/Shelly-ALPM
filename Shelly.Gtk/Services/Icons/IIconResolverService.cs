namespace Shelly.Gtk.Services.Icons;

/// <summary>
/// Gets Icons for packages inside standard packages.
/// </summary>
public interface IIconResolverService
{
    public string? GetIconPath(string packageName);
    
    public void PreloadIcons(IEnumerable<string> packageNames);
}