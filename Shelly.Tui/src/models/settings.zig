/// Frontend preferences, independent of CLI package policy and GTK settings.
pub const Settings = struct {
    aur_enabled: bool = false,
    flatpak_enabled: bool = false,

    pub fn eql(self: Settings, other: Settings) bool {
        return self.aur_enabled == other.aur_enabled and self.flatpak_enabled == other.flatpak_enabled;
    }
};
