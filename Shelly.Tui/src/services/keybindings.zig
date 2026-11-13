//! Persistable shortcut overrides. This service never mutates live bindings.
const std = @import("std");
const vaxis = @import("vaxis");
const commands = @import("../commands.zig");
const Allocator = std.mem.Allocator;

pub const editable = [_]commands.Id{
    .quit,              .help,                .next_tab,        .previous_tab,
    .install,           .remove,              .preview,         .refresh,
    .refresh_list,      .filter,              .upgrade_all,     .upgrade_system,
    .upgrade_aur,       .upgrade_flatpak,     .categories,      .previous_catalog_page,
    .next_catalog_page, .previous_screenshot, .next_screenshot, .clear_selection,
    .toggle_wrap,       .narrow_view,         .widen_view,      .toggle_hidden,
};

fn indexOf(id: commands.Id) ?usize {
    for (editable, 0..) |candidate, index| if (candidate == id) return index;
    return null;
}

pub const Config = struct {
    overrides: [editable.len]?vaxis.Key = @splat(null),

    pub fn get(self: Config, id: commands.Id) vaxis.Key {
        if (indexOf(id)) |index| if (self.overrides[index]) |key| return key;
        return defaultKey(id);
    }

    pub fn withBinding(self: Config, id: commands.Id, key: vaxis.Key) !Config {
        const index = indexOf(id) orelse return error.FixedCommand;
        var candidate = self;
        candidate.overrides[index] = if (same(key, defaultKey(id))) null else key;
        try candidate.validate();
        return candidate;
    }

    pub fn eql(self: Config, other: Config) bool {
        for (editable) |id| if (!same(self.get(id), other.get(id))) return false;
        return true;
    }

    /// Resolve defaults without consulting commands.bindings.
    pub fn resolve(self: Config) commands.Bindings {
        var result: commands.Bindings = .{};
        inline for (editable) |id| @field(result, @tagName(id)) = self.get(id);
        result.interrupt = result.quit;
        return result;
    }

    pub fn validate(self: Config) !void {
        const defaults: commands.Bindings = .{};
        for (editable, 0..) |id, index| {
            const key = self.get(id);
            try validateKey(key);
            // Shortcuts active in text fields must not consume ordinary text.
            if ((scope(id) == all or scope(id) & searches != 0) and key.codepoint >= 32 and key.codepoint <= 126 and !key.mods.ctrl and !key.mods.alt)
                return error.TextInputConflict;
            // Preserve fixed navigation aliases, direct tab selection, and sudo.
            for ([_]u21{ vaxis.Key.escape, vaxis.Key.backspace, vaxis.Key.delete, vaxis.Key.home, vaxis.Key.end, vaxis.Key.insert }) |fixed|
                if (key.matches(fixed, .{})) return error.ReservedBinding;
            for ("hjkl") |letter| if (key.matches(letter, .{})) return error.ReservedBinding;
            for ("123456789") |digit| if (key.matches(digit, .{ .alt = true })) return error.ReservedBinding;
            for ("auwednpbfkijmh[") |letter| if (key.matches(letter, .{ .ctrl = true })) return error.ReservedBinding;
            inline for (@typeInfo(commands.Bindings).@"struct".field_names) |name| {
                const fixed = comptime @field(commands.Id, name);
                if (comptime indexOf(fixed) == null and fixed != .interrupt) {
                    if (same(key, @field(defaults, name))) return error.ReservedBinding;
                }
            }
            for (editable[0..index]) |other| {
                if (scope(id) & scope(other) != 0 and same(key, self.get(other))) return error.ConflictingBinding;
            }
        }
    }
};

fn defaultKey(id: commands.Id) vaxis.Key {
    const defaults: commands.Bindings = .{};
    return switch (id) {
        inline else => |tag| @field(defaults, @tagName(tag)),
    };
}

fn same(a: vaxis.Key, b: vaxis.Key) bool {
    return a.codepoint == b.codepoint and a.mods.eql(b.mods);
}

const all: u16 = 0xffff;
const package_lists: u16 = 1;
const aur_list: u16 = 2;
const flatpak_list: u16 = 4;
const package_details: u16 = 8;
const aur_details: u16 = 16;
const flatpak_details: u16 = 32;
const searches: u16 = 64;
const updates: u16 = 128;
const settings: u16 = 256;
const preview: u16 = 512;
const review: u16 = 1024;
const lists = package_lists | aur_list | flatpak_list;
const details = package_details | aur_details | flatpak_details;

/// Conservative overlap groups, including handlers active in search fields.
/// Shared defaults such as Remove/Refresh and catalog/image paging are disjoint.
fn scope(id: commands.Id) u16 {
    return switch (id) {
        .quit, .help, .next_tab, .previous_tab => all,
        .install, .remove => lists | details,
        .preview => aur_list | aur_details,
        .refresh => updates | settings | preview,
        .refresh_list => aur_list | flatpak_list | searches | flatpak_details,
        .filter => lists | searches,
        .upgrade_all, .upgrade_system, .upgrade_aur, .upgrade_flatpak => updates,
        .categories => flatpak_list | flatpak_details | searches,
        .previous_catalog_page, .next_catalog_page => aur_list,
        .previous_screenshot, .next_screenshot => flatpak_details,
        .clear_selection => package_lists | aur_list,
        .toggle_wrap => preview | review,
        .toggle_hidden => 2048, // File browser, outside path editing.
        .narrow_view, .widen_view => lists | details | searches | settings,
        else => unreachable,
    };
}

const NamedKey = struct { name: []const u8, codepoint: u21 };
const named_keys = [_]NamedKey{
    .{ .name = "Escape", .codepoint = vaxis.Key.escape },
    .{ .name = "Enter", .codepoint = vaxis.Key.enter },
    .{ .name = "Tab", .codepoint = vaxis.Key.tab },
    .{ .name = "Space", .codepoint = vaxis.Key.space },
    .{ .name = "Backspace", .codepoint = vaxis.Key.backspace },
    .{ .name = "Delete", .codepoint = vaxis.Key.delete },
    .{ .name = "Insert", .codepoint = vaxis.Key.insert },
    .{ .name = "Home", .codepoint = vaxis.Key.home },
    .{ .name = "End", .codepoint = vaxis.Key.end },
    .{ .name = "Up", .codepoint = vaxis.Key.up },
    .{ .name = "Down", .codepoint = vaxis.Key.down },
    .{ .name = "Left", .codepoint = vaxis.Key.left },
    .{ .name = "Right", .codepoint = vaxis.Key.right },
    .{ .name = "PageUp", .codepoint = vaxis.Key.page_up },
    .{ .name = "PageDown", .codepoint = vaxis.Key.page_down },
    .{ .name = "Plus", .codepoint = '+' },
};

pub fn parse(text: []const u8) !vaxis.Key {
    var parts = std.mem.splitScalar(u8, text, '+');
    var mods: vaxis.Key.Modifiers = .{};
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidKey;
        if (parts.peek() != null) {
            if (std.ascii.eqlIgnoreCase(part, "Ctrl") and !mods.ctrl) mods.ctrl = true else if (std.ascii.eqlIgnoreCase(part, "Alt") and !mods.alt) mods.alt = true else if (std.ascii.eqlIgnoreCase(part, "Shift") and !mods.shift) mods.shift = true else return error.InvalidKey;
            continue;
        }
        var codepoint: ?u21 = null;
        for (named_keys) |named| if (std.ascii.eqlIgnoreCase(part, named.name)) {
            codepoint = named.codepoint;
            break;
        };
        if (codepoint == null and part.len >= 2 and (part[0] == 'F' or part[0] == 'f')) {
            const number = std.fmt.parseInt(u8, part[1..], 10) catch return error.InvalidKey;
            if (number < 1 or number > 35) return error.InvalidKey;
            codepoint = vaxis.Key.f1 + @as(u21, number) - 1;
        }
        if (codepoint == null and part.len == 1 and part[0] >= 33 and part[0] <= 126)
            codepoint = std.ascii.toLower(part[0]);
        const key: vaxis.Key = .{ .codepoint = codepoint orelse return error.InvalidKey, .mods = mods };
        try validateKey(key);
        return key;
    }
    return error.InvalidKey;
}

fn validateKey(key: vaxis.Key) !void {
    if (key.text != null or key.shifted_codepoint != null or key.base_layout_codepoint != null) return error.InvalidKey;
    if (key.mods.super or key.mods.hyper or key.mods.meta or key.mods.caps_lock or key.mods.num_lock) return error.InvalidKey;
    if (key.mods.shift and key.codepoint >= 33 and key.codepoint <= 126) return error.InvalidKey;
    if (key.codepoint >= vaxis.Key.f1 and key.codepoint <= vaxis.Key.f35) return;
    for (named_keys) |named| if (key.codepoint == named.codepoint) return;
    if (key.codepoint >= 33 and key.codepoint <= 126 and !std.ascii.isUpper(@intCast(key.codepoint))) {
        return;
    }
    return error.InvalidKey;
}

pub fn format(allocator: Allocator, key: vaxis.Key) ![]const u8 {
    try validateKey(key);
    var buffer: [16]u8 = undefined;
    const name = blk: {
        for (named_keys) |named| if (named.codepoint == key.codepoint) break :blk named.name;
        if (key.codepoint >= vaxis.Key.f1 and key.codepoint <= vaxis.Key.f35)
            break :blk try std.fmt.bufPrint(&buffer, "F{d}", .{key.codepoint - vaxis.Key.f1 + 1});
        break :blk try std.fmt.bufPrint(&buffer, "{u}", .{key.codepoint});
    };
    return std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{
        if (key.mods.ctrl) "Ctrl+" else "", if (key.mods.alt) "Alt+" else "", if (key.mods.shift) "Shift+" else "", name,
    });
}

pub fn decode(value: std.json.Value) !Config {
    if (value != .object) return error.InvalidKeybindings;
    var result: Config = .{};
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        const id = std.meta.stringToEnum(commands.Id, entry.key_ptr.*) orelse return error.UnknownCommand;
        const index = indexOf(id) orelse return error.FixedCommand;
        if (entry.value_ptr.* != .string) return error.InvalidKeybindings;
        const key = try parse(entry.value_ptr.string);
        result.overrides[index] = if (same(key, defaultKey(id))) null else key;
    }
    try result.validate();
    return result;
}

pub fn encode(allocator: Allocator, config: Config) !std.json.Value {
    try config.validate();
    var object: std.json.ObjectMap = .empty;
    for (editable) |id| {
        const key = config.get(id);
        try object.put(allocator, @tagName(id), .{ .string = try format(allocator, key) });
    }
    return .{ .object = object };
}

test "defaults remain valid and independent of live bindings" {
    const original = commands.bindings;
    defer commands.bindings = original;
    commands.bindings.help = .{ .codepoint = vaxis.Key.f9 };
    const config: Config = .{};
    try config.validate();
    try std.testing.expectEqual(vaxis.Key.f1, config.get(.help).codepoint);
    const changed = try config.withBinding(.quit, try parse("Ctrl+Z"));
    const resolved = changed.resolve();
    try std.testing.expect(same(resolved.quit, resolved.interrupt));
    try std.testing.expectEqual(@as(u21, 'z'), resolved.quit.codepoint);
    try std.testing.expectEqual(vaxis.Key.f9, commands.bindings.help.codepoint);
}

test "portable key syntax round trips and rejects malformed combinations" {
    for ([_][]const u8{ "Ctrl+Z", "Alt+i", "F2", "Ctrl+Alt+F35", "Shift+Tab", "Plus", "Ctrl+PageDown" }) |text| {
        const key = try parse(text);
        const encoded = try format(std.testing.allocator, key);
        defer std.testing.allocator.free(encoded);
        try std.testing.expect(same(key, try parse(encoded)));
    }
    for ([_][]const u8{ "", "Ctrl+", "Ctrl+Ctrl+i", "Super+i", "i+j", "F0", "F36", "Unknown", "++", "Shift+i", "界", "\n" }) |text| {
        try std.testing.expectError(error.InvalidKey, parse(text));
    }
}

test "validation rejects conflicts and protects fixed keys without rejecting shared defaults" {
    const config: Config = .{};
    try std.testing.expectError(error.FixedCommand, config.withBinding(.approve, try parse("F2")));
    try std.testing.expectError(error.ConflictingBinding, config.withBinding(.install, config.get(.remove)));
    const custom = try config.withBinding(.install, try parse("F3"));
    try std.testing.expectError(error.ConflictingBinding, custom.withBinding(.help, try parse("F3")));
    try std.testing.expectError(error.TextInputConflict, config.withBinding(.help, try parse("x")));
    try std.testing.expectError(error.TextInputConflict, config.withBinding(.filter, try parse("x")));
    try std.testing.expectError(error.ReservedBinding, config.withBinding(.help, try parse("Backspace")));
    try std.testing.expectError(error.ReservedBinding, config.withBinding(.install, try parse("Enter")));
    try std.testing.expectError(error.ReservedBinding, config.withBinding(.install, try parse("j")));
    try std.testing.expectError(error.ReservedBinding, config.withBinding(.help, try parse("Alt+1")));
    try std.testing.expectError(error.ReservedBinding, config.withBinding(.install, try parse("Ctrl+U")));
    try std.testing.expectError(error.ConflictingBinding, config.withBinding(.install, try parse("F1")));
    // Install and system upgrade are not active in the same page context.
    _ = try config.withBinding(.install, try parse("u"));
    const changed = try config.withBinding(.install, try parse("F2"));
    try std.testing.expect(!changed.eql(config));
    try std.testing.expect((try changed.withBinding(.install, defaultKey(.install))).eql(config));
}

test "JSON decoding validates complete configurations and writes every editable binding" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const document = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"help":"F2","install":"F1","remove":"r"}
    , .{});
    const config = try decode(document.value);
    const encoded = try encode(allocator, config);
    try std.testing.expectEqual(editable.len, encoded.object.count());
    try std.testing.expectEqualStrings("r", encoded.object.get("remove").?.string);
    try std.testing.expect(config.eql(try decode(encoded)));
    try std.testing.expectEqual(editable.len, (try encode(allocator, .{})).object.count());
    const invalid = [_]struct { json: []const u8, err: anyerror }{
        .{ .json = "[]", .err = error.InvalidKeybindings },
        .{ .json = "{\"help\":false}", .err = error.InvalidKeybindings },
        .{ .json = "{\"typo\":\"F2\"}", .err = error.UnknownCommand },
        .{ .json = "{\"confirm\":\"F2\"}", .err = error.FixedCommand },
        .{ .json = "{\"install\":\"r\"}", .err = error.ConflictingBinding },
    };
    for (invalid) |item| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, item.json, .{});
        try std.testing.expectError(item.err, decode(parsed.value));
    }
}

test "settings reload and panel resizing cannot share a binding" {
    const config: Config = .{};
    try std.testing.expectError(error.ConflictingBinding, config.withBinding(.refresh, config.get(.widen_view)));
    try std.testing.expectError(error.ConflictingBinding, config.withBinding(.refresh, config.get(.narrow_view)));
    const changed = try config.withBinding(.refresh, try parse("F3"));
    try std.testing.expectError(error.ConflictingBinding, changed.withBinding(.widen_view, try parse("F3")));
    try std.testing.expectError(error.ConflictingBinding, changed.withBinding(.narrow_view, try parse("F3")));
}
