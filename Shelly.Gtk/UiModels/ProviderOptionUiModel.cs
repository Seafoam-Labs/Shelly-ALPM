namespace Shelly.Gtk.UiModels;

public record ProviderOptionUiModel(
    string Name,
    string? Description,
    bool IsInstalled,
    bool IsSelected = false);
