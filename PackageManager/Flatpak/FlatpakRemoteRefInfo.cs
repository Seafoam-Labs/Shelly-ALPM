
namespace PackageManager.Flatpak;

public partial record FlatpakRemoteRefInfo
{
    public ulong DownloadSize { get; set; }
    public ulong InstalledSize { get; set; }
}