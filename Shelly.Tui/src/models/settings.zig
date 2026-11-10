const keybindings = @import("../services/keybindings.zig");

pub const header_styles = [_]HeaderIcons{ .none, .nerd_font, .ascii };
pub const header_style_start: usize = 2;
pub const screenshots_index: usize = header_style_start + header_styles.len;
pub const atoll_index: usize = screenshots_index + 1;
pub const keybindings_index: usize = atoll_index + 1;
pub const save_index: usize = keybindings_index + 1;

pub fn aurUrl(atoll: bool) []const u8 {
    return if (atoll) "https://atoll.seafoam-labs.org" else "https://aur.archlinux.org";
}

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

pub fn isAtollUrl(url: []const u8) bool {
    const base = @import("std").mem.trimEnd(u8, @import("std").mem.trim(u8, url, " \t\r\n"), "/");
    return @import("std").ascii.eqlIgnoreCase(base, aurUrl(true));
}

/// Frontend preferences and the current shared CLI AUR source.
pub const Settings = struct {
    keybindings: keybindings.Config = .{},
    aur_enabled: bool = false,
    atoll_aur_enabled: bool = false,
    flatpak_enabled: bool = false,
    header_icons: HeaderIcons = .none,
    show_flatpak_screenshots: bool = true,

    pub fn eql(self: Settings, other: Settings) bool {
        return self.keybindings.eql(other.keybindings) and self.atoll_aur_enabled == other.atoll_aur_enabled and self.aur_enabled == other.aur_enabled and self.flatpak_enabled == other.flatpak_enabled and self.header_icons == other.header_icons and self.show_flatpak_screenshots == other.show_flatpak_screenshots;
    }
};

test "Atoll detection checks the configured source rather than a hostname substring" {
    const std = @import("std");
    try std.testing.expect(isAtollUrl("https://atoll.seafoam-labs.org///"));
    try std.testing.expect(!isAtollUrl("https://aur.archlinux.org"));
    try std.testing.expect(!isAtollUrl("https://atoll.seafoam-labs.org.example.invalid"));
    try std.testing.expect(!isAtollUrl("https://example.invalid/atoll.seafoam-labs.org"));
}
