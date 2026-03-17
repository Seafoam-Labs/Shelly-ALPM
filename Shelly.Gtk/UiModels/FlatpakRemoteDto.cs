using System.Text.Json.Serialization;

namespace Shelly.Gtk.UiModels;

public class FlatpakRemoteDto
{
    public string Name { get; set; } = string.Empty;
   
    public string Scope { get; set; } = string.Empty;
    
    public string Url { get; set; } = string.Empty;
}
