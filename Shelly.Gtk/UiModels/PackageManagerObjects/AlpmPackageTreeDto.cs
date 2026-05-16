
namespace Shelly.Gtk.UiModels.PackageManagerObjects;

public partial record AlpmPackageTreeDto(string Name)
{
    public List<AlpmPackageTreeDto> Files { get; init; } = [];
}
