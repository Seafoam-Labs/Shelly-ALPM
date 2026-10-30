const vaxis = @import("vaxis");

pub const Global = union(enum) {
    quit,
    next_tab,
    previous_tab,
    select_tab: usize,
};

/// Shared application shortcuts. Plain digits remain available to text inputs.
pub fn global(key: vaxis.Key, tab_count: usize) ?Global {
    if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) return .quit;
    if (key.matches(vaxis.Key.tab, .{ .shift = true })) return .previous_tab;
    if (key.matches(vaxis.Key.tab, .{})) return .next_tab;
    for (0..@min(tab_count, 9)) |index| {
        if (key.matches('1' + @as(u21, @intCast(index)), .{ .alt = true }))
            return .{ .select_tab = index };
    }
    return null;
}

pub const Detail = enum { close, install, remove, preview };

pub const PackageAction = enum { install, remove };
pub fn packageAction(key: vaxis.Key) ?PackageAction {
    if (key.matches('i', .{})) return .install;
    if (key.matches('r', .{})) return .remove;
    return null;
}

pub const PackageNavigation = enum { previous, next, details, search, select };
pub fn packageNavigation(key: vaxis.Key, searching: bool) ?PackageNavigation {
    if (key.matches(vaxis.Key.up, .{})) return .previous;
    if (key.matches(vaxis.Key.down, .{})) return .next;
    if (key.matches(vaxis.Key.enter, .{})) return .select;
    if (!searching) {
        if (key.matches(vaxis.Key.right, .{})) return .details;
        if (key.matches('/', .{})) return .search;
    }
    return null;
}

pub fn leavesPackageDetails(key: vaxis.Key) bool {
    return key.matches(vaxis.Key.left, .{}) or key.matches('q', .{});
}
pub fn detail(key: vaxis.Key) ?Detail {
    if (key.matches('q', .{})) return .close;
    if (key.matches('p', .{})) return .preview;
    if (key.matches('i', .{})) return .install;
    if (key.matches('r', .{})) return .remove;
    return null;
}

pub fn closesResult(key: vaxis.Key) bool {
    return key.matches(vaxis.Key.enter, .{}) or key.matches('q', .{});
}

pub fn refreshes(key: vaxis.Key) bool {
    return key.matches('r', .{});
}

pub fn detailsHint(installed: bool) []const u8 {
    return if (installed)
        "I: install/reinstall    R: remove    Q: close    Esc: quit"
    else
        "I: install    Q: close    Esc: quit";
}

pub const result_hint = "Enter/Q: close    Esc: quit";
pub const authentication_hint = "Enter: confirm and run with sudo    Esc: quit";

pub const Updates = enum { refresh, upgrade_all, upgrade_system, upgrade_aur, upgrade_flatpak };
pub fn updates(key: vaxis.Key) ?Updates {
    if (refreshes(key)) return .refresh;
    if (key.matches('g', .{})) return .upgrade_all;
    if (key.matches('u', .{})) return .upgrade_system;
    if (key.matches('a', .{})) return .upgrade_aur;
    if (key.matches('f', .{})) return .upgrade_flatpak;
    return null;
}
pub const updates_hint = "G: all    U: system    A: AUR    R: refresh";
pub const flatpak_updates_hint = "G: all    U: system    A: AUR    F: Flatpak    R: refresh";

pub fn closesPreview(key: vaxis.Key) bool {
    return key.matches('q', .{});
}

pub fn aurDetailsHint(installed: bool) []const u8 {
    return if (installed)
        "P: PKGBUILD    I: reinstall    R: remove    Q: close    Esc: quit"
    else
        "P: PKGBUILD    I: install    Q: close    Esc: quit";
}
pub const preview_hint = "↑↓/←→: scroll  Ctrl+D/U: page  R: retry  Q: back  Esc: quit";

pub const Review = enum { approve, decline };
pub fn review(key: vaxis.Key) ?Review {
    if (key.matches('y', .{})) return .approve;
    if (key.matches('n', .{}) or key.matches('q', .{})) return .decline;
    return null;
}
pub const review_hint = "↑↓/←→: scroll  Y: approve  N/Q: decline  Esc: quit";
pub const choice_hint = "Enter indices, comma-separated for multiple choices; Enter: send";

pub fn togglesInstalled(key: vaxis.Key) bool {
    return key.matches('l', .{ .ctrl = true });
}

pub fn refreshesList(key: vaxis.Key) bool {
    return key.matches('r', .{ .ctrl = true });
}

pub const confirmation_hint = "Enter: confirm and run    Q: back    Esc: quit";
pub const flatpak_catalog_hint = "I: install    Q: close    Esc: quit";
pub const flatpak_installed_hint = "R: remove    Q: close    Esc: quit";
pub const Choice = enum { previous, next, confirm, close };
pub fn choice(key: vaxis.Key) ?Choice {
    if (key.matches(vaxis.Key.up, .{})) return .previous;
    if (key.matches(vaxis.Key.down, .{})) return .next;
    if (key.matches(vaxis.Key.enter, .{})) return .confirm;
    if (key.matches('q', .{})) return .close;
    return null;
}
pub const flatpak_choice_hint = "↑↓: select remote/scope    Enter: confirm    Q: back";

pub const SettingsAction = enum { previous, next, toggle, reload };
pub fn settings(key: vaxis.Key) ?SettingsAction {
    if (key.matches(vaxis.Key.up, .{})) return .previous;
    if (key.matches(vaxis.Key.down, .{})) return .next;
    if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.space, .{})) return .toggle;
    if (key.matches('r', .{})) return .reload;
    return null;
}
pub const settings_hint = "↑↓: select    Enter/Space: toggle and save    R: reload    Esc: quit";

/// Scroll review/output without sending navigation keys to password input.
pub fn scrollsOperation(key: vaxis.Key) bool {
    return key.matches(vaxis.Key.up, .{}) or key.matches(vaxis.Key.down, .{}) or
        key.matches(vaxis.Key.page_up, .{}) or key.matches(vaxis.Key.page_down, .{}) or
        key.matches('d', .{ .ctrl = true }) or key.matches('u', .{ .ctrl = true });
}
