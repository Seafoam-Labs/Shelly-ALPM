
namespace PackageManager.Flatpak;

public partial class FlatpakInstanceDto
{
    public string Name { get; set; } = string.Empty;
    public string AppId { get; set; } = string.Empty;
    public int Pid { get; set; }
}