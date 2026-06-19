using Shelly.Gtk.Enums;

namespace Shelly.Gtk.UiModels.AppImage;

public partial class AppImageDto
{
 
        public string Name { get; set; } = string.Empty;
        public string DesktopName { get; set; } = string.Empty;
        public string Version { get; set; } = string.Empty;
        public string IconName { get; set; } = string.Empty;
        public string Description { get; set; } = string.Empty;
        public long SizeOnDisk { get; set; } = 0;
        public string UpdateURl { get; set; } = string.Empty;
        public string RawUpdateInfo { get; set; } = string.Empty;
        public string? RepoOwner { get; set; }
        public string? RepoName { get; set; }
        public AppImageUpdateType UpdateType { get; set; } = AppImageUpdateType.None;
    
        public bool AllowPrerelease { get; set; } = false;
        public string? CommandLineArgs { get; set; }
        public string? Path { get; set; }
    

 
}