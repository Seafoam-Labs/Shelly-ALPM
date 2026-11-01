pub const HeaderIcons = enum {
    none,
    nerd_font,
    ascii,

    pub fn next(self: HeaderIcons) HeaderIcons {
        return switch (self) {
            .none => .nerd_font,
            .nerd_font => .ascii,
            .ascii => .none,
        };
    }

    pub fn title(self: HeaderIcons) []const u8 {
        return switch (self) {
            .none => "Text only",
            .nerd_font => "Nerd Font",
            .ascii => "ASCII",
        };
    }
};

/// Frontend preferences, independent of CLI package policy and GTK settings.
pub const Settings = struct {
    aur_enabled: bool = false,
    flatpak_enabled: bool = false,
    header_icons: HeaderIcons = .none,

    pub fn eql(self: Settings, other: Settings) bool {
        return self.aur_enabled == other.aur_enabled and self.flatpak_enabled == other.flatpak_enabled and self.header_icons == other.header_icons;
    }
};
