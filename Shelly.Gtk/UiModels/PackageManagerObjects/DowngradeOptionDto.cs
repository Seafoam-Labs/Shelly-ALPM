namespace Shelly.Gtk.UiModels.PackageManagerObjects;

public record struct DowngradeOptionDto(
    string Name,
    string Filename,
    string Location,
    bool IsInstalled
);