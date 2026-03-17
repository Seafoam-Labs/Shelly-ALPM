using System.Text.Json.Serialization;

namespace Shelly.Gtk.UiModels;

public class FlatpakRemoteRefInfo
{
    public ulong DownloadSize { get; set; }
    public ulong InstalledSize { get; set; }
}