const vaxis = @import("vaxis");

const std = @import("std");

pub const Id = enum {
    quit,
    interrupt,
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
    install,
    remove,
    preview,
    close,
    confirm,
    cancel,
    erase,
    refresh,
    refresh_list,
    filter,
    upgrade_all,
    upgrade_system,
    upgrade_aur,
    upgrade_flatpak,
    approve,
    decline,
    page_up,
    page_down,
    half_page_up,
    half_page_down,
};

pub const Bindings = struct {
    quit: vaxis.Key = .{ .codepoint = vaxis.Key.escape },
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
    toggle_wrap: vaxis.Key = .{ .codepoint = 'w' },
    clear_selection: vaxis.Key = .{ .codepoint = 'u', .mods = .{ .ctrl = true } },
    install: vaxis.Key = .{ .codepoint = 'i' },
    remove: vaxis.Key = .{ .codepoint = 'r' },
    preview: vaxis.Key = .{ .codepoint = 'p' },
    close: vaxis.Key = .{ .codepoint = 'q' },
    confirm: vaxis.Key = .{ .codepoint = vaxis.Key.enter },
    cancel: vaxis.Key = .{ .codepoint = 'q', .mods = .{ .ctrl = true } },
    erase: vaxis.Key = .{ .codepoint = vaxis.Key.backspace },
    refresh: vaxis.Key = .{ .codepoint = 'r' },
    refresh_list: vaxis.Key = .{ .codepoint = 'r', .mods = .{ .ctrl = true } },
    filter: vaxis.Key = .{ .codepoint = 'l', .mods = .{ .ctrl = true } },
    upgrade_all: vaxis.Key = .{ .codepoint = 'g' },
    upgrade_system: vaxis.Key = .{ .codepoint = 'u' },
    upgrade_aur: vaxis.Key = .{ .codepoint = 'a' },
    upgrade_flatpak: vaxis.Key = .{ .codepoint = 'f' },
    approve: vaxis.Key = .{ .codepoint = 'y' },
    decline: vaxis.Key = .{ .codepoint = 'n' },
    page_up: vaxis.Key = .{ .codepoint = vaxis.Key.page_up },
    page_down: vaxis.Key = .{ .codepoint = vaxis.Key.page_down },
    half_page_up: vaxis.Key = .{ .codepoint = 'u', .mods = .{ .ctrl = true } },
    half_page_down: vaxis.Key = .{ .codepoint = 'd', .mods = .{ .ctrl = true } },
};

/// Live bindings shared by dispatch and help/footer rendering. Settings will
/// be capable of replacing this later.
pub var bindings: Bindings = .{};

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
    const key = binding(id);
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
pub fn packageNavigation(key: vaxis.Key, searching: bool) ?PackageNavigation {
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
    if (matches(key, .upgrade_all)) return .upgrade_all;
    if (matches(key, .upgrade_system)) return .upgrade_system;
    if (matches(key, .upgrade_aur)) return .upgrade_aur;
    if (matches(key, .upgrade_flatpak)) return .upgrade_flatpak;
    return null;
}
pub const updates_hint = "G: all    U: system    A: AUR    R: refresh";
pub const flatpak_updates_hint = "G: all    U: system    A: AUR    F: Flatpak    R: refresh";

pub fn closesPreview(key: vaxis.Key) bool {
    return matches(key, .close);
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
    if (matches(key, .approve)) return .approve;
    if (matches(key, .decline) or matches(key, .close)) return .decline;
    return null;
}
pub const review_hint = "↑↓/←→: scroll  Y: approve  N/Q: decline  Esc: quit";
pub const choice_hint = "Enter indices, comma-separated for multiple choices; Enter: send";

pub fn togglesInstalled(key: vaxis.Key) bool {
    return matches(key, .filter);
}

pub fn refreshesList(key: vaxis.Key) bool {
    return matches(key, .refresh_list);
}

pub const confirmation_hint = "Enter: confirm and run    Q: back    Esc: quit";
pub const flatpak_catalog_hint = "I: install    Q: close    Esc: quit";
pub const flatpak_installed_hint = "R: remove    Q: close    Esc: quit";
pub const Choice = enum { previous, next, confirm, close };
pub fn choice(key: vaxis.Key) ?Choice {
    if (matches(key, .previous)) return .previous;
    if (matches(key, .next)) return .next;
    if (matches(key, .confirm)) return .confirm;
    if (matches(key, .close)) return .close;
    return null;
}
pub const flatpak_choice_hint = "↑↓: select remote/scope    Enter: confirm    Q: back";

pub const SettingsAction = enum { previous, next, toggle, reload };
pub fn settings(key: vaxis.Key) ?SettingsAction {
    if (matches(key, .previous)) return .previous;
    if (matches(key, .next)) return .next;
    if (matches(key, .confirm) or matches(key, .mark)) return .toggle;
    if (matches(key, .refresh)) return .reload;
    return null;
}
pub const settings_hint = "↑↓: select    Enter/Space: toggle and save    R: reload    Esc: quit";

/// Scroll review/output without sending navigation keys to password input.
pub fn scrollsOperation(key: vaxis.Key) bool {
    return scrollKey(key) != null;
}

pub const Mode = enum { search, packages, details, aur, flatpak, updates, settings, authentication, confirmation, running, result, review, preview_document, answers, choice, help };
pub const Context = struct {
    source_wrap: bool = true,
    multiple_choices: bool = false,
    preview_button: bool = false,
    mode: Mode = .search,
    installed_only: bool = false,
    browsing_list: bool = false,
    installable: bool = false,
    removable: bool = false,
    preview: bool = false,
    split_details: bool = false,
    scrollable: bool = false,
    upgrade_system: bool = false,
    upgrade_aur: bool = false,
    upgrade_flatpak: bool = false,
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
    switch (context.mode) {
        .search, .packages => {
            if (context.mode == .packages and context.selected_count > 0)
                try add(arena, &list, .clear_selection, "Clear", "Clear all package selections, including entries hidden by filters");
            if (context.mode == .search) {
                try add(arena, &list, .previous, "Browse", "Move from search into the package list");
                try add(arena, &list, .next, "Browse", "Move from search into the package list");
            }
            try add(arena, &list, .select, "Select", "Toggle selection of the highlighted package");
            if (context.installable) try add(arena, &list, .install, "Install", "Install/reinstall selection, or the highlighted package (list focus)");
            if (context.removable) try add(arena, &list, .remove, "Remove", "Remove installed selections, or the highlighted installed package (list focus)");
            if (context.mode == .packages) {
                try add(arena, &list, .previous, "Previous", "Previous package; at the first row, return to search");
                try add(arena, &list, .next, "Next", "Next package");
                try add(arena, &list, .details, "Details", "Focus package details");
                try add(arena, &list, .search, "Search", "Return to editing the search field");
                try add(arena, &list, .mark, "Select", "Toggle selection (alternative to Enter)");
            }
            try add(arena, &list, .filter, if (context.installed_only) "All" else "Installed", "Toggle all / installed packages; selection survives filtering");
        },
        .details => {
            if (context.preview_button) try add(arena, &list, .confirm, "View PKGBUILD", "Activate the PKGBUILD preview button");
            if (context.scrollable) {
                try add(arena, &list, .previous, "Scroll up", "Scroll package details up");
                try add(arena, &list, .next, "Scroll down", "Scroll package details down");
            }
            if (context.installable) try add(arena, &list, .install, "Install", "Install/reinstall selection, or the displayed package");
            if (context.removable) try add(arena, &list, .remove, "Remove", "Remove installed selections, or the displayed installed package");
            if (context.preview) try add(arena, &list, .preview, "PKGBUILD", "Preview the PKGBUILD and supplied related files");
            if (context.split_details) try add(arena, &list, .back, "Packages", "Return to the selected package");
            try add(arena, &list, .close, "Back", "Close details and return to browsing");
        },
        .aur, .flatpak => {
            try add(arena, &list, .confirm, if (context.mode == .aur and !context.installed_only and !context.browsing_list) "Search" else "Details", if (context.mode == .aur and !context.installed_only and !context.browsing_list) "Submit the AUR search; Enter on an unchanged query opens details" else "Open details of the highlighted entry");
            if (context.mode == .aur and context.browsing_list) {
                if (context.installable) try add(arena, &list, .install, "Install", "Install/reinstall the highlighted AUR package");
                if (context.removable) try add(arena, &list, .remove, "Remove", "Remove the highlighted installed AUR package");
                if (context.preview) try add(arena, &list, .preview, "PKGBUILD", "Preview source in the details pane");
                try add(arena, &list, .details, "Details", "Focus AUR package details");
                try add(arena, &list, .search, "Search", "Return to editing the AUR query");
            }
            try add(arena, &list, .previous, "Previous", "Previous result");
            try add(arena, &list, .next, "Next", "Next result");
            try add(arena, &list, .filter, if (context.installed_only) "All" else "Installed", "Toggle browsing / installed packages");
            if (context.mode == .flatpak or context.installed_only) try add(arena, &list, .refresh_list, "Refresh", "Refresh the current package list");
        },
        .updates => {
            if (context.upgrade_all) try add(arena, &list, .upgrade_all, "Update all", "Upgrade all enabled sources; AppImages excluded");
            if (context.upgrade_system) try add(arena, &list, .upgrade_system, "System", "Upgrade native system packages");
            if (context.upgrade_aur) try add(arena, &list, .upgrade_aur, "AUR", "Upgrade AUR packages with PKGBUILD review");
            if (context.upgrade_flatpak) try add(arena, &list, .upgrade_flatpak, "Flatpak", "Upgrade system and user Flatpaks");
            try add(arena, &list, .refresh, "Refresh", "Check for updates again");
            try add(arena, &list, .previous, "Previous", "Previous update");
            try add(arena, &list, .next, "Next", "Next update");
        },
        .settings => {
            try add(arena, &list, .previous, "Previous", "Previous preference");
            try add(arena, &list, .next, "Next", "Next preference");
            try add(arena, &list, .confirm, "Toggle", "Toggle the selected preference and save");
            try add(arena, &list, .mark, "Toggle", "Toggle the selected preference and save (alternative)");
            try add(arena, &list, .refresh, "Reload", "Reload preferences from disk");
        },
        .authentication, .confirmation => {
            try add(arena, &list, .confirm, "Run", "Confirm and run the operation");
            try add(arena, &list, .cancel, "Back", "Dismiss confirmation without starting the operation");
            if (context.mode == .confirmation) try add(arena, &list, .close, "Back", "Dismiss confirmation without starting the operation");
            if (context.mode == .authentication) try add(arena, &list, .erase, "Erase", "Remove the last password character; ordinary text enters the password");
        },
        .running => {},
        .result => {
            try add(arena, &list, .confirm, "Close", "Dismiss the operation result");
            try add(arena, &list, .close, "Close", "Dismiss the operation result");
        },
        .review => {
            try add(arena, &list, .toggle_wrap, "Wrap", "Toggle source wrapping (enabled by default)");
            try add(arena, &list, .approve, "Approve", "Approve the current transaction or PKGBUILD review");
            try add(arena, &list, .decline, "Decline", "Decline the current review");
            try add(arena, &list, .close, "Decline", "Decline the current review (alternative)");
        },
        .preview_document => {
            try add(arena, &list, .toggle_wrap, "Wrap", "Toggle source wrapping (enabled by default)");
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
            try add(arena, &list, .confirm, "Submit", "Submit checked dependencies or the highlighted provider");
        },
        .choice => {
            try add(arena, &list, .previous, "Previous", "Previous choice");
            try add(arena, &list, .next, "Next", "Next choice");
            try add(arena, &list, .confirm, "Confirm", "Confirm the chosen remote and scope");
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
