pub const header_styles = [_]HeaderIcons{ .none, .nerd_font, .ascii };
pub const header_style_start: usize = 2;
pub const screenshots_index: usize = header_style_start + header_styles.len;
pub const save_index: usize = screenshots_index + 1;

pub const HeaderIcons = enum {
    none,
    nerd_font,
    ascii,

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
    show_flatpak_screenshots: bool = true,

    pub fn eql(self: Settings, other: Settings) bool {
        return self.aur_enabled == other.aur_enabled and self.flatpak_enabled == other.flatpak_enabled and self.header_icons == other.header_icons and self.show_flatpak_screenshots == other.show_flatpak_screenshots;
    }
};
