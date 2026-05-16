using Shelly.Gtk.Enums;

namespace Shelly.Gtk.UiModels.AppImage;

public partial class AppImageDto
{
    public string Name { get; set; } = string.Empty;
    public string DesktopName { get; set; } = string.Empty;
    public string Version { get; set; } = string.Empty;
    public string UpdateVersion { get; set; } = string.Empty;
    public string IconName { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public long SizeOnDisk { get; set; } = 0;

    public string UpdateURl { get; set; } = string.Empty;
    public string RawUpdateInfo { get; set; } = string.Empty;

    public AppImageUpdateType UpdateType { get; set; } = AppImageUpdateType.StaticUrl;
}