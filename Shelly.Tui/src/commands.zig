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

pub const Detail = enum { close, install, remove };
pub fn detail(key: vaxis.Key) ?Detail {
    if (key.matches('q', .{})) return .close;
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
