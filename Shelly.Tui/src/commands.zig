const vaxis = @import("vaxis");

const std = @import("std");

pub const Id = enum {
    quit,
    interrupt,
    configure_updates,
    help,
    next_tab,
    previous_tab,
    previous,
    next,
    details,
    back,
    search,
    select,
    mark,
    clear_selection,
    toggle_wrap,
    categories,
    previous_catalog_page,
    next_catalog_page,
    previous_screenshot,
    next_screenshot,
    install,
    remove,
    preview,
    close,
    confirm,
    cancel,
    refresh,
    refresh_list,
    save_settings,
    filter,
    upgrade_all,
    upgrade_system,
    upgrade_aur,
    upgrade_flatpak,
    upgrade_appimage,
    approve,
    decline,
    page_up,
    page_down,
    half_page_up,
    half_page_down,
    narrow_view,
    widen_view,
    toggle_hidden,
    reset_binding,
    cancel_capture,
};

pub const Bindings = struct {
    configure_updates: vaxis.Key = .{ .codepoint = 'e' },
    quit: vaxis.Key = .{ .codepoint = 'c', .mods = .{ .ctrl = true } },
    interrupt: vaxis.Key = .{ .codepoint = 'c', .mods = .{ .ctrl = true } },
    help: vaxis.Key = .{ .codepoint = vaxis.Key.f1 },
    next_tab: vaxis.Key = .{ .codepoint = vaxis.Key.tab },
    previous_tab: vaxis.Key = .{ .codepoint = vaxis.Key.tab, .mods = .{ .shift = true } },
    previous: vaxis.Key = .{ .codepoint = vaxis.Key.up },
    next: vaxis.Key = .{ .codepoint = vaxis.Key.down },
    details: vaxis.Key = .{ .codepoint = vaxis.Key.right },
    back: vaxis.Key = .{ .codepoint = vaxis.Key.left },
    search: vaxis.Key = .{ .codepoint = '/' },
    select: vaxis.Key = .{ .codepoint = vaxis.Key.enter },
    mark: vaxis.Key = .{ .codepoint = vaxis.Key.space },
    previous_catalog_page: vaxis.Key = .{ .codepoint = '[' },
    next_catalog_page: vaxis.Key = .{ .codepoint = ']' },
    previous_screenshot: vaxis.Key = .{ .codepoint = '[' },
    next_screenshot: vaxis.Key = .{ .codepoint = ']' },
    categories: vaxis.Key = .{ .codepoint = 'g', .mods = .{ .ctrl = true } },
    toggle_wrap: vaxis.Key = .{ .codepoint = 'w' },
    clear_selection: vaxis.Key = .{ .codepoint = 'x', .mods = .{ .ctrl = true } },
    install: vaxis.Key = .{ .codepoint = 'i' },
    remove: vaxis.Key = .{ .codepoint = 'r' },
    preview: vaxis.Key = .{ .codepoint = 'p' },
    close: vaxis.Key = .{ .codepoint = 'q' },
    confirm: vaxis.Key = .{ .codepoint = vaxis.Key.enter },
    cancel: vaxis.Key = .{ .codepoint = 'q', .mods = .{ .ctrl = true } },
    refresh: vaxis.Key = .{ .codepoint = 'r' },
    save_settings: vaxis.Key = .{ .codepoint = 's', .mods = .{ .ctrl = true } },
    refresh_list: vaxis.Key = .{ .codepoint = 'r', .mods = .{ .ctrl = true } },
    filter: vaxis.Key = .{ .codepoint = 'l', .mods = .{ .ctrl = true } },
    upgrade_all: vaxis.Key = .{ .codepoint = 'g' },
    upgrade_system: vaxis.Key = .{ .codepoint = 'u' },
    upgrade_aur: vaxis.Key = .{ .codepoint = 'a' },
    upgrade_flatpak: vaxis.Key = .{ .codepoint = 'f' },
    upgrade_appimage: vaxis.Key = .{ .codepoint = 'i' },
    approve: vaxis.Key = .{ .codepoint = 'y' },
    decline: vaxis.Key = .{ .codepoint = 'n' },
    page_up: vaxis.Key = .{ .codepoint = vaxis.Key.page_up },
    page_down: vaxis.Key = .{ .codepoint = vaxis.Key.page_down },
    half_page_up: vaxis.Key = .{ .codepoint = 'u', .mods = .{ .ctrl = true } },
    half_page_down: vaxis.Key = .{ .codepoint = 'd', .mods = .{ .ctrl = true } },
    narrow_view: vaxis.Key = .{ .codepoint = vaxis.Key.left, .mods = .{ .ctrl = true } },
    toggle_hidden: vaxis.Key = .{ .codepoint = '.' },
    widen_view: vaxis.Key = .{ .codepoint = vaxis.Key.right, .mods = .{ .ctrl = true } },
    reset_binding: vaxis.Key = .{ .codepoint = vaxis.Key.delete },
    cancel_capture: vaxis.Key = .{ .codepoint = vaxis.Key.escape },
};

/// Live bindings shared by dispatch and help/footer rendering. Settings will
/// be capable of replacing this later.
pub var bindings: Bindings = .{};

/// Replace the live bindings table with a complete validated set.
pub fn apply(new_bindings: Bindings) void {
    bindings = new_bindings;
}

test "clearing selections does not shadow half-page scrolling" {
    const up: vaxis.Key = .{ .codepoint = 'u', .mods = .{ .ctrl = true } };
    const clear: vaxis.Key = .{ .codepoint = 'x', .mods = .{ .ctrl = true } };
    try std.testing.expect(matches(up, .half_page_up));
    try std.testing.expect(!matches(up, .clear_selection));
    try std.testing.expect(matches(clear, .clear_selection));
    try std.testing.expect(scrollKey(clear) == null);
    try std.testing.expectEqual(@as(u21, 'u'), scrollKey(up).?.codepoint);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Ctrl+X", try label(arena.allocator(), .clear_selection));
}

fn binding(id: Id) vaxis.Key {
    return switch (id) {
        inline else => |tag| @field(bindings, @tagName(tag)),
    };
}

pub fn matches(key: vaxis.Key, id: Id) bool {
    const configured = binding(id);
    return key.matches(configured.codepoint, configured.mods);
}

pub fn label(arena: std.mem.Allocator, id: Id) std.mem.Allocator.Error![]const u8 {
    return keyLabel(arena, binding(id));
}

pub fn keyLabel(arena: std.mem.Allocator, key: vaxis.Key) std.mem.Allocator.Error![]const u8 {
    const name = if (key.codepoint >= vaxis.Key.f1 and key.codepoint <= vaxis.Key.f35)
        try std.fmt.allocPrint(arena, "F{d}", .{key.codepoint - vaxis.Key.f1 + 1})
    else switch (key.codepoint) {
        vaxis.Key.escape => "Esc",
        vaxis.Key.enter => "Enter",
        vaxis.Key.tab => "Tab",
        vaxis.Key.up => "↑",
        vaxis.Key.down => "↓",
        vaxis.Key.left => "←",
        vaxis.Key.right => "→",
        vaxis.Key.space => "Space",
        vaxis.Key.backspace => "Backspace",
        vaxis.Key.delete => "Delete",
        vaxis.Key.home => "Home",
        vaxis.Key.end => "End",
        vaxis.Key.insert => "Insert",
        vaxis.Key.page_up => "PgUp",
        vaxis.Key.page_down => "PgDn",
        else => try std.fmt.allocPrint(arena, "{u}", .{if (key.codepoint <= 127) std.ascii.toUpper(@as(u8, @intCast(key.codepoint))) else key.codepoint}),
    };
    return std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{
        if (key.mods.ctrl) "Ctrl+" else "", if (key.mods.alt) "Alt+" else "", if (key.mods.shift) "Shift+" else "", name,
    });
}

pub fn scrollKey(key: vaxis.Key) ?vaxis.Key {
    if (vimNavigationKey(key)) |mapped| return mapped;
    if (matches(key, .previous)) return .{ .codepoint = vaxis.Key.up };
    if (matches(key, .next)) return .{ .codepoint = vaxis.Key.down };
    if (matches(key, .back)) return .{ .codepoint = vaxis.Key.left };
    if (matches(key, .details)) return .{ .codepoint = vaxis.Key.right };
    if (matches(key, .page_up)) return .{ .codepoint = vaxis.Key.page_up };
    if (matches(key, .page_down)) return .{ .codepoint = vaxis.Key.page_down };
    if (matches(key, .half_page_up)) return .{ .codepoint = 'u', .mods = .{ .ctrl = true } };
    if (matches(key, .half_page_down)) return .{ .codepoint = 'd', .mods = .{ .ctrl = true } };
    return null;
}

pub const Global = union(enum) {
    quit,
    next_tab,
    previous_tab,
    select_tab: usize,
};

/// Shared application shortcuts. Plain digits remain available to text inputs.
pub fn global(key: vaxis.Key, tab_count: usize) ?Global {
    if (matches(key, .quit) or matches(key, .interrupt)) return .quit;
    if (matches(key, .previous_tab)) return .previous_tab;
    if (matches(key, .next_tab)) return .next_tab;
    for (0..@min(tab_count, 9)) |index| {
        if (key.matches('1' + @as(u21, @intCast(index)), .{ .alt = true }))
            return .{ .select_tab = index };
    }
    return null;
}

pub const Detail = enum { close, install, remove, preview };

pub const PackageAction = enum { install, remove };
pub fn packageAction(key: vaxis.Key) ?PackageAction {
    if (matches(key, .install)) return .install;
    if (matches(key, .remove)) return .remove;
    return null;
}

pub const PackageNavigation = enum { previous, next, details, search, select };
/// Only call outside editable inputs; never alias letters globally in matches().
pub fn vimNavigationKey(key: vaxis.Key) ?vaxis.Key {
    const aliases = .{ .{ 'h', vaxis.Key.left }, .{ 'j', vaxis.Key.down }, .{ 'k', vaxis.Key.up }, .{ 'l', vaxis.Key.right } };
    inline for (aliases) |alias| {
        if (key.matches(alias[0], .{})) return .{ .codepoint = alias[1] };
    }
    return null;
}

test "vim aliases preserve search text and modified shortcuts" {
    try std.testing.expect(global(.{ .codepoint = vaxis.Key.escape }, 3) == null);
    try std.testing.expectEqual(Global.quit, global(.{ .codepoint = 'c', .mods = .{ .ctrl = true } }, 3).?);
    try std.testing.expectEqual(PackageNavigation.next, packageNavigation(.{ .codepoint = 'j' }, false).?);
    try std.testing.expectEqual(PackageNavigation.previous, packageNavigation(.{ .codepoint = 'k' }, false).?);
    try std.testing.expectEqual(PackageNavigation.details, packageNavigation(.{ .codepoint = 'l' }, false).?);
    try std.testing.expect(leavesPackageDetails(.{ .codepoint = 'h' }));
    for ("hjkl") |letter| {
        try std.testing.expect(packageNavigation(.{ .codepoint = letter }, true) == null);
        try std.testing.expect(vimNavigationKey(.{ .codepoint = letter, .mods = .{ .ctrl = true } }) == null);
        try std.testing.expect(vimNavigationKey(.{ .codepoint = letter, .mods = .{ .alt = true } }) == null);
    }
    try std.testing.expectEqual(vaxis.Key.down, scrollKey(.{ .codepoint = 'j' }).?.codepoint);
    try std.testing.expectEqual(vaxis.Key.up, scrollKey(.{ .codepoint = 'k' }).?.codepoint);
}

pub fn packageNavigation(key: vaxis.Key, searching: bool) ?PackageNavigation {
    if (!searching) if (vimNavigationKey(key)) |mapped| return packageNavigation(mapped, false);
    if (matches(key, .previous)) return .previous;
    if (matches(key, .next)) return .next;
    if (matches(key, .select)) return .select;
    if (!searching) {
        if (matches(key, .details)) return .details;
        if (matches(key, .search)) return .search;
    }
    return null;
}

pub fn leavesPackageDetails(key: vaxis.Key) bool {
    if (key.matches('h', .{})) return true;
    return matches(key, .back) or matches(key, .close);
}
pub fn detail(key: vaxis.Key) ?Detail {
    if (matches(key, .close)) return .close;
    if (matches(key, .preview)) return .preview;
    if (matches(key, .install)) return .install;
    if (matches(key, .remove)) return .remove;
    return null;
}

pub fn closesResult(key: vaxis.Key) bool {
    return matches(key, .confirm) or matches(key, .close);
}

pub fn refreshes(key: vaxis.Key) bool {
    return matches(key, .refresh);
}

pub const Updates = enum { refresh, upgrade_all, upgrade_system, upgrade_aur, upgrade_flatpak, upgrade_appimage };
pub fn updates(key: vaxis.Key) ?Updates {
    if (refreshes(key)) return .refresh;
    if (matches(key, .upgrade_all)) return .upgrade_all;
    if (matches(key, .upgrade_system)) return .upgrade_system;
    if (matches(key, .upgrade_aur)) return .upgrade_aur;
    if (matches(key, .upgrade_flatpak)) return .upgrade_flatpak;
    if (matches(key, .upgrade_appimage)) return .upgrade_appimage;
    return null;
}

pub fn closesPreview(key: vaxis.Key) bool {
    return matches(key, .close);
}

pub const Review = enum { approve, decline };
pub fn review(key: vaxis.Key) ?Review {
    if (matches(key, .approve)) return .approve;
    if (matches(key, .decline) or matches(key, .close)) return .decline;
    return null;
}

pub fn togglesInstalled(key: vaxis.Key) bool {
    return matches(key, .filter);
}

pub fn refreshesList(key: vaxis.Key) bool {
    return matches(key, .refresh_list);
}

pub const Choice = enum { previous, next, confirm, close };
pub fn choice(key: vaxis.Key) ?Choice {
    if (matches(key, .previous)) return .previous;
    if (matches(key, .next)) return .next;
    if (matches(key, .confirm)) return .confirm;
    if (matches(key, .close)) return .close;
    return null;
}

pub const SettingsAction = enum { previous, next, toggle, save, reload };
pub fn settings(key: vaxis.Key) ?SettingsAction {
    if (matches(key, .save_settings)) return .save;
    if (matches(key, .previous)) return .previous;
    if (matches(key, .next)) return .next;
    if (matches(key, .confirm) or matches(key, .mark)) return .toggle;
    if (matches(key, .refresh)) return .reload;
    return null;
}

/// Scroll review/output without sending navigation keys to password input.
pub fn scrollsOperation(key: vaxis.Key) bool {
    return scrollKey(key) != null;
}

pub const Mode = enum { appimage, search, packages, details, aur, flatpak, updates, settings, authentication, confirmation, running, result, review, preview_document, answers, choice, help };
pub const Context = struct {
    appimage_source: bool = false,
    appimage_configure_selected: bool = false,
    appimage_path: bool = false,
    appimage_path_editing: bool = false,
    hidden_files: bool = false,
    authenticating: bool = false,
    quit_blocked: bool = false,
    source_wrap: bool = true,
    settings_save_selected: bool = false,
    settings_cycle_selected: bool = false,
    settings_header_open: bool = false,
    settings_discard_selected: bool = false,
    settings_keybindings: bool = false,
    settings_keybindings_button: bool = false,
    settings_binding_selected: bool = false,
    settings_capture: bool = false,
    multiple_choices: bool = false,
    preview_button: bool = false,
    mode: Mode = .search,
    installed_only: bool = false,
    browsing_list: bool = false,
    categories_available: bool = false,
    catalog_available: bool = false,
    catalog_previous: bool = false,
    catalog_next: bool = false,
    screenshots_navigable: bool = false,
    screenshot_retry: bool = false,
    category_choice: bool = false,
    installable: bool = false,
    removable: bool = false,
    preview: bool = false,
    split_details: bool = false,
    scrollable: bool = false,
    upgrade_system: bool = false,
    upgrade_aur: bool = false,
    upgrade_flatpak: bool = false,
    upgrade_appimage: bool = false,
    upgrade_all: bool = false,
    selected_count: usize = 0,
    selected_installed: usize = 0,
    tab_count: usize = 0,
};

pub const Entry = struct { id: Id, short: []const u8, description: []const u8 };
fn add(arena: std.mem.Allocator, list: *std.ArrayList(Entry), id: Id, short: []const u8, description: []const u8) !void {
    try list.append(arena, .{ .id = id, .short = short, .description = description });
}

/// Context and live bindings are evaluated on every render, including while an
/// operation completes in the background.
pub fn entries(arena: std.mem.Allocator, context: Context) std.mem.Allocator.Error![]const Entry {
    var list: std.ArrayList(Entry) = .empty;
    if (context.appimage_source) {
        try add(arena, &list, .previous, "Previous", "Previous update-source control");
        try add(arena, &list, .next, "Next", "Next update-source control");
        try add(arena, &list, .confirm, "Select", "Change the selected update-source control");
        try add(arena, &list, .cancel_capture, "Cancel", "Discard the update-source draft");
        return list.toOwnedSlice(arena);
    }
    if (context.appimage_path) {
        if (!context.appimage_path_editing) try add(arena, &list, .toggle_hidden, if (context.hidden_files) "Hide hidden" else "Show hidden", "Toggle hidden files and folders in the AppImage browser");
        try add(arena, &list, .confirm, "Open/Install", "Open a folder or review AppImage installation");
        try add(arena, &list, .cancel_capture, "Cancel", "Return to installed AppImages");
        return list.toOwnedSlice(arena);
    }
    if (context.mode == .search or context.mode == .packages or context.mode == .aur or context.mode == .flatpak or context.mode == .appimage or context.mode == .settings or (context.mode == .details and context.split_details)) {
        try add(arena, &list, .narrow_view, "Narrow panel", "Reduce left panel width (package pages and Settings)");
        try add(arena, &list, .widen_view, "Widen panel", "Increase left panel width (package pages and Settings)");
    }
    if (context.categories_available) try add(arena, &list, .categories, "Categories", "Choose a Flatpak category; All categories clears the filter");
    if (context.screenshots_navigable) {
        try add(arena, &list, .previous_screenshot, "Previous image", "Show the previous Flatpak screenshot");
        try add(arena, &list, .next_screenshot, "Next image", "Show the next Flatpak screenshot");
    }
    if (context.screenshot_retry) try add(arena, &list, .refresh_list, "Retry image", "Retry loading the Flatpak screenshot");
    switch (context.mode) {
        .search, .packages => {
            if (context.mode == .packages and context.selected_count > 0)
                try add(arena, &list, .clear_selection, "Clear", "Clear all package selections, including entries hidden by filters");
            if (context.mode == .search) {
                try add(arena, &list, .previous, "Browse", "Move from search into the package list");
                try add(arena, &list, .next, "Browse", "Move from search into the package list (also Esc)");
            }
            try add(arena, &list, .select, "Select", "Toggle selection of the highlighted package");
            if (context.installable) try add(arena, &list, .install, "Install", "Install/reinstall selection, or the highlighted package (list focus)");
            if (context.removable) try add(arena, &list, .remove, "Remove", "Remove installed selections, or the highlighted installed package (list focus)");
            if (context.mode == .packages) {
                try add(arena, &list, .previous, "Previous", "Previous package (also k); at the first row, return to search");
                try add(arena, &list, .next, "Next", "Next package (also j)");
                try add(arena, &list, .details, "Details", "Focus package details (also l); h returns to the list");
                try add(arena, &list, .search, "Search", "Return to editing the search field");
                try add(arena, &list, .mark, "Select", "Toggle selection (alternative to Enter)");
            }
            try add(arena, &list, .filter, if (context.installed_only) "All" else "Installed", "Toggle all / installed packages; selection survives filtering");
        },
        .details => {
            if (context.preview_button) try add(arena, &list, .confirm, "View PKGBUILD", "Activate the PKGBUILD preview button");
            if (context.scrollable) {
                try add(arena, &list, .previous, "Scroll up", "Scroll package details up (also k)");
                try add(arena, &list, .next, "Scroll down", "Scroll package details down (also j)");
            }
            if (context.installable) try add(arena, &list, .install, "Install", "Install/reinstall selection, or the displayed package");
            if (context.removable) try add(arena, &list, .remove, "Remove", "Remove installed selections, or the displayed installed package");
            if (context.preview) try add(arena, &list, .preview, "PKGBUILD", "Preview the PKGBUILD and supplied related files");
            if (context.split_details) try add(arena, &list, .back, "Packages", "Return to the selected package");
            try add(arena, &list, .close, "Back", "Close details and return to browsing");
        },
        .aur, .flatpak => {
            try add(arena, &list, .confirm, if (context.mode == .aur and context.browsing_list) "Select" else if (context.mode == .aur and !context.installed_only and !context.browsing_list) "Search" else "Details", if (context.mode == .aur and context.browsing_list) "Toggle selection of the highlighted AUR package" else if (context.mode == .aur and !context.installed_only and !context.browsing_list) "Submit the AUR search; Enter on an unchanged query opens details" else "Open details of the highlighted entry");
            if (context.mode == .aur and context.browsing_list) {
                if (context.selected_count > 0) try add(arena, &list, .clear_selection, "Clear", "Clear all AUR selections, including other search results");
                try add(arena, &list, .mark, "Select", "Toggle selection (alternative to Enter)");
                if (context.installable) try add(arena, &list, .install, "Install", "Install/reinstall selected AUR packages, or the highlighted package");
                if (context.removable) try add(arena, &list, .remove, "Remove", "Remove installed AUR selections, or the highlighted installed package");
                if (context.preview) try add(arena, &list, .preview, "PKGBUILD", "Preview source in the details pane");
                try add(arena, &list, .details, "Details", "Focus AUR package details");
                try add(arena, &list, .search, "Search", "Return to editing the AUR query");
            }
            if (context.mode == .flatpak and context.browsing_list) {
                try add(arena, &list, .details, "Details", "Focus Flatpak details");
                try add(arena, &list, .search, "Search", "Return to editing the filter");
                if (context.installable) try add(arena, &list, .install, "Install", "Choose a remote and installation scope");
                if (context.removable) try add(arena, &list, .remove, "Remove", "Remove the highlighted Flatpak");
            }
            if (context.catalog_available and context.browsing_list) {
                if (context.catalog_previous) try add(arena, &list, .previous_catalog_page, "Previous page", "Load the previous AUR catalog page");
                if (context.catalog_next) try add(arena, &list, .next_catalog_page, "Next page", "Load the next AUR catalog page");
            }
            try add(arena, &list, .previous, "Previous", "Previous result");
            try add(arena, &list, .next, "Next", "Next result");
            try add(arena, &list, .filter, if (context.installed_only) "All" else "Installed", "Toggle browsing / installed packages");
            if (context.mode == .flatpak or context.installed_only or context.catalog_available) try add(arena, &list, .refresh_list, "Refresh", "Refresh the current package list");
        },
        .updates => {
            if (context.upgrade_all) try add(arena, &list, .upgrade_all, "Update all", "Upgrade all enabled package sources");
            if (context.upgrade_system) try add(arena, &list, .upgrade_system, "System", "Upgrade native system packages");
            if (context.upgrade_aur) try add(arena, &list, .upgrade_aur, "AUR", "Upgrade AUR packages with PKGBUILD review");
            if (context.upgrade_flatpak) try add(arena, &list, .upgrade_flatpak, "Flatpak", "Upgrade system and user Flatpaks");
            if (context.upgrade_appimage) try add(arena, &list, .upgrade_appimage, "AppImages", "Upgrade all configured AppImages with available updates");
            try add(arena, &list, .refresh, "Refresh", "Check for updates again");
            try add(arena, &list, .previous, "Up", "Scroll updates up");
            try add(arena, &list, .next, "Down", "Scroll updates down");
            try add(arena, &list, .page_up, "Page up", "Scroll updates up half a page");
            try add(arena, &list, .page_down, "Page down", "Scroll updates down half a page");
        },
        .appimage => {
            if (context.appimage_configure_selected) try add(arena, &list, .confirm, "Configure", "Configure the selected AppImage update source");
            if (context.removable) try add(arena, &list, .configure_updates, "Configure updates", "Edit the selected AppImage update source");
            try add(arena, &list, .install, "Install", "Install an AppImage from a local path");
            if (context.removable) try add(arena, &list, .remove, "Remove", "Remove the selected AppImage");
            try add(arena, &list, .previous, "Up", "Previous AppImage or scroll up");
            try add(arena, &list, .next, "Down", "Next AppImage or scroll down");
            try add(arena, &list, if (context.split_details) .back else .details, if (context.split_details) "Back" else "Details", "Move between the list and details");
            try add(arena, &list, .refresh_list, "Refresh", "Reload installed AppImages");
        },
        .settings => {
            if (context.settings_capture) {
                try add(arena, &list, .cancel_capture, "Cancel", "Cancel key capture without changing the binding");
            } else if (context.settings_header_open) {
                try add(arena, &list, .previous, "Previous", "Previous header style");
                try add(arena, &list, .next, "Next", "Next header style");
                try add(arena, &list, .confirm, "Select", "Use this header style in the pending settings");
                try add(arena, &list, .cancel_capture, "Back", "Close the dropdown without changing the style");
            } else {
                try add(arena, &list, .previous, "Previous", "Previous setting or command");
                try add(arena, &list, .next, "Next", "Next setting or command");
                if (!context.settings_keybindings and (context.settings_keybindings_button or context.settings_cycle_selected)) {
                    try add(arena, &list, .details, "Edit", "Focus the expanded editor (also l); Left or h returns to settings");
                }
                const action = if (context.settings_save_selected) "Save" else if (context.settings_discard_selected) "Discard" else if (context.settings_keybindings or context.settings_keybindings_button or context.settings_cycle_selected) "Select" else "Toggle";
                try add(arena, &list, .confirm, action, if (context.settings_keybindings) "Capture a replacement key" else "Activate the selected preference or action");
                try add(arena, &list, .mark, action, "Activate the selected setting or action (alternative)");
                if (context.settings_binding_selected) try add(arena, &list, .reset_binding, "Default", "Restore the selected command's default binding without saving");
                if (context.settings_keybindings) try add(arena, &list, .close, "Back", "Return to preferences, keeping pending edits");
                try add(arena, &list, .save_settings, "Save", "Save and apply pending settings");
                try add(arena, &list, .refresh, "Reload", "Discard pending edits and reload saved preferences");
            }
        },
        .authentication, .confirmation => {
            try add(arena, &list, .confirm, "Run", "Confirm and run the operation");
            try add(arena, &list, .cancel, "Back", "Dismiss confirmation without starting the operation");
            if (context.mode == .confirmation) try add(arena, &list, .close, "Back", "Dismiss confirmation without starting the operation");
        },
        .running => {
            if (context.authenticating) try add(arena, &list, .cancel, "Cancel auth", "Interrupt sudo authentication; typed credentials are sent without echo");
        },
        .result => {
            try add(arena, &list, .confirm, "Close", "Dismiss the operation result");
            try add(arena, &list, .close, "Close", "Dismiss the operation result");
        },
        .review => {
            try add(arena, &list, .approve, "Approve", "Approve the current transaction or PKGBUILD review");
            try add(arena, &list, .decline, "Decline", "Decline the current review");
            try add(arena, &list, .close, "Decline", "Decline the current review (alternative)");
            try add(arena, &list, .toggle_wrap, if (context.source_wrap) "Unwrap" else "Wrap", "Toggle source wrapping (enabled by default)");
        },
        .preview_document => {
            try add(arena, &list, .toggle_wrap, if (context.source_wrap) "Unwrap" else "Wrap", "Toggle source wrapping (enabled by default)");
            if (!context.source_wrap) {
                try add(arena, &list, .back, "Left", "Scroll source horizontally left");
                try add(arena, &list, .details, "Right", "Scroll source horizontally right");
            }
            try add(arena, &list, .refresh, "Retry", "Fetch the PKGBUILD preview again");
            try add(arena, &list, .close, "Back", "Return to package details");
        },
        .answers => {
            try add(arena, &list, .previous, "Previous", "Highlight the previous dependency");
            try add(arena, &list, .next, "Next", "Highlight the next dependency");
            if (context.multiple_choices) try add(arena, &list, .mark, "Toggle", "Check or uncheck an optional dependency");
            try add(arena, &list, .confirm, "Submit", if (context.multiple_choices) "Submit checked dependencies; leave all unchecked to install none" else "Submit the highlighted provider");
        },
        .choice => {
            try add(arena, &list, .previous, "Previous", "Previous choice");
            try add(arena, &list, .next, "Next", "Next choice");
            try add(arena, &list, .confirm, "Confirm", if (context.category_choice) "Apply the highlighted category" else "Confirm the chosen remote and scope");
            try add(arena, &list, .close, "Back", "Return without confirming");
        },
        .help => {},
    }
    if (context.mode == .help or context.scrollable or context.mode == .review) {
        try add(arena, &list, .page_up, "Page up", "Scroll up by a page");
        try add(arena, &list, .page_down, "Page down", "Scroll down by a page");
        if (context.mode != .details and context.mode != .answers) {
            try add(arena, &list, .previous, "Scroll up", "Scroll review/output up");
            try add(arena, &list, .next, "Scroll down", "Scroll review/output down");
        }
    }
    return list.toOwnedSlice(arena);
}

test "catalog shortcuts are limited to available Atoll pages in list focus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]Context{
        .{ .mode = .aur, .browsing_list = true, .catalog_available = true, .catalog_next = true },
        .{ .mode = .aur, .browsing_list = true },
        .{ .mode = .aur, .catalog_available = true, .catalog_next = true },
    }, 0..) |context, index| {
        var found = false;
        for (try entries(arena.allocator(), context)) |entry| {
            if (entry.id == .next_catalog_page) found = true;
            try std.testing.expect(entry.id != .previous_catalog_page);
        }
        try std.testing.expectEqual(index == 0, found);
    }
}
