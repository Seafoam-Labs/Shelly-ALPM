const std = @import("std");
const native_defaults = @import("defaults.zig");
const aur_url = @import("aur_url.zig");

pub const Config = struct {
    values: std.json.ObjectMap,

    pub fn defaults(allocator: std.mem.Allocator) !Config {
        const parsed = try std.json.parseFromSliceLeaky(
            std.json.Value,
            allocator,
            native_defaults.json,
            .{},
        );
        if (parsed != .object) return error.InvalidConfigDefaults;
        var values: std.json.ObjectMap = .empty;
        var iterator = parsed.object.iterator();
        while (iterator.next()) |entry|
            try values.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        return .{ .values = values };
    }

    pub fn overlay(self: *Config, object: std.json.ObjectMap) !void {
        var iterator = self.values.iterator();
        while (iterator.next()) |entry| {
            const incoming = object.get(entry.key_ptr.*) orelse continue;
            if (!compatible(entry.key_ptr.*, entry.value_ptr.*, incoming))
                return error.InvalidConfig;
            entry.value_ptr.* = incoming;
        }
        if (self.values.getPtr("OutputMode")) |output_mode| {
            if (output_mode.* != .string or !std.mem.eql(u8, output_mode.string, "singlepane"))
                output_mode.* = .{ .string = "singlepane" };
        }
    }

    pub fn findCanonicalKey(self: *const Config, requested: []const u8) ?[]const u8 {
        for (self.values.keys()) |key| {
            if (std.ascii.eqlIgnoreCase(key, requested)) return key;
        }
        return null;
    }

    pub fn getDisplay(
        self: *const Config,
        allocator: std.mem.Allocator,
        requested: []const u8,
    ) !?[]const u8 {
        const key = self.findCanonicalKey(requested) orelse return null;
        return displayValue(allocator, key, self.values.get(key).?);
    }

    pub fn set(
        self: *Config,
        allocator: std.mem.Allocator,
        requested: []const u8,
        text: []const u8,
    ) !bool {
        const key = self.findCanonicalKey(requested) orelse return false;
        const current = self.values.get(key).?;
        const converted = convertValue(allocator, key, current, text) catch return false;
        try self.values.put(allocator, key, converted);
        return true;
    }
};

fn compatible(key: []const u8, default: std.json.Value, incoming: std.json.Value) bool {
    if (incoming == .null) return nullableString(key) or std.mem.eql(u8, key, "Time");
    return switch (default) {
        .null => incoming == .string,
        .bool => incoming == .bool,
        .integer => incoming == .integer or incoming == .float,
        .float => incoming == .integer or incoming == .float,
        .string => incoming == .string,
        .array => incoming == .array,
        else => false,
    };
}

fn convertValue(
    allocator: std.mem.Allocator,
    key: []const u8,
    current: std.json.Value,
    text: []const u8,
) !std.json.Value {
    if (std.mem.eql(u8, key, "DaysOfWeek"))
        return .{ .array = try parseDays(allocator, text) };
    if (std.mem.eql(u8, key, "AurUrl")) {
        if (!aur_url.isValidBase(text)) return error.InvalidValue;
        return .{ .string = text };
    }
    if (std.mem.eql(u8, key, "Time")) {
        if (text.len == 0 or std.ascii.eqlIgnoreCase(text, "null")) return .null;
        return .{ .string = try parseTime(allocator, text) };
    }
    if (enumChoices(key)) |choices| {
        const canonical = canonicalChoice(choices, text) orelse return error.InvalidValue;
        return .{ .string = canonical };
    }

    return switch (current) {
        .bool => .{ .bool = parseBool(text) orelse return error.InvalidValue },
        .integer => if (floatProperty(key))
            .{ .float = try std.fmt.parseFloat(f64, text) }
        else
            .{ .integer = try std.fmt.parseInt(i64, text, 10) },
        .float => .{ .float = try std.fmt.parseFloat(f64, text) },
        .string => .{ .string = text },
        .null => .{ .string = text },
        else => error.InvalidValue,
    };
}

fn displayValue(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: std.json.Value,
) !?[]const u8 {
    return switch (value) {
        .null => null,
        .bool => |boolean| if (boolean) "True" else "False",
        .integer => |integer| try std.fmt.allocPrint(allocator, "{d}", .{integer}),
        .float => |float| try std.fmt.allocPrint(allocator, "{d}", .{float}),
        .number_string => |number| number,
        .string => |string| string,
        .array => |array| if (std.mem.eql(u8, key, "DaysOfWeek"))
            try displayDays(allocator, array.items)
        else
            "",
        else => null,
    };
}

fn parseBool(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "true")) return true;
    if (std.ascii.eqlIgnoreCase(text, "false")) return false;
    return null;
}

const days = [_][]const u8{
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
};

fn parseDays(allocator: std.mem.Allocator, text: []const u8) !std.json.Array {
    var result = std.json.Array.init(allocator);
    if (text.len == 0 or std.mem.eql(u8, text, "[]")) return result;
    var tokens = std.mem.splitScalar(u8, text, ',');
    while (tokens.next()) |token| {
        const name = std.mem.trim(u8, token, " \t\r\n");
        if (name.len == 0) continue;
        var found: ?usize = null;
        for (days, 0..) |day, index| {
            if (std.ascii.eqlIgnoreCase(day, name)) {
                found = index;
                break;
            }
        }
        try result.append(.{ .integer = @intCast(found orelse return error.InvalidValue) });
    }
    return result;
}

fn displayDays(allocator: std.mem.Allocator, values: []const std.json.Value) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (values, 0..) |value, index| {
        if (index > 0) try result.append(allocator, ',');
        switch (value) {
            .integer => |day| {
                if (day < 0 or day >= days.len) return error.InvalidConfig;
                try result.appendSlice(allocator, days[@intCast(day)]);
            },
            .string => |day| {
                const canonical = canonicalChoice(&days, day) orelse return error.InvalidConfig;
                try result.appendSlice(allocator, canonical);
            },
            else => return error.InvalidConfig,
        }
    }
    return result.toOwnedSlice(allocator);
}

fn parseTime(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var pieces = std.mem.splitScalar(u8, text, ':');
    const hour = try std.fmt.parseInt(u8, pieces.next() orelse return error.InvalidValue, 10);
    const minute = try std.fmt.parseInt(u8, pieces.next() orelse return error.InvalidValue, 10);
    const second_text = pieces.next();
    if (pieces.next() != null or hour > 23 or minute > 59) return error.InvalidValue;
    const second = if (second_text) |value|
        try std.fmt.parseInt(u8, value, 10)
    else
        0;
    if (second > 59) return error.InvalidValue;
    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second });
}

fn canonicalChoice(choices: []const []const u8, text: []const u8) ?[]const u8 {
    for (choices) |choice| if (std.ascii.eqlIgnoreCase(choice, text)) return choice;
    return null;
}

fn enumChoices(key: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, key, "FileSizeDisplay")) return &.{ "Bytes", "Megabytes", "Gigabytes" };
    if (std.mem.eql(u8, key, "DefaultExecution")) return &.{
        "UpgradeStandard",
        "UpgradeFlatpak",
        "UpgradeAur",
        "UpgradeAll",
        "Sync",
        "SyncForce",
        "ListInstalled",
    };
    if (std.mem.eql(u8, key, "ProgressBarStyle")) return &.{ "Blocks", "Pacman" };
    if (std.mem.eql(u8, key, "DownloadAddressFamilyPolicy")) return &.{
        "PreferIPv4",
        "PreferIPv6",
        "IPv4Only",
        "IPv6Only",
    };
    if (std.mem.eql(u8, key, "DefaultPageDropDown")) return &.{
        "Packages",
        "Aur",
        "Flatpak",
        "AppImage",
        "ShellySearch",
        "Recommend",
    };
    if (std.mem.eql(u8, key, "PackageInstallView") or
        std.mem.eql(u8, key, "PackageUpdateView") or
        std.mem.eql(u8, key, "PackageManageView")) return &.{ "Grid", "List" };
    return null;
}

fn nullableString(key: []const u8) bool {
    return std.mem.eql(u8, key, "Culture") or
        std.mem.eql(u8, key, "TrayIconPath") or
        std.mem.eql(u8, key, "TrayUpdatesIconPath") or
        std.mem.eql(u8, key, "AppImageInstallPath");
}

fn floatProperty(key: []const u8) bool {
    return std.mem.eql(u8, key, "WindowWidth") or std.mem.eql(u8, key, "WindowHeight");
}

test "defaults preserve reflection order and display conventions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try Config.defaults(arena.allocator());
    try std.testing.expectEqual(@as(usize, 10), config.values.count());
    try std.testing.expectEqualStrings("FileSizeDisplay", config.values.keys()[0]);
    try std.testing.expectEqualStrings(
        "False",
        (try config.getDisplay(arena.allocator(), "AutoConfirmCacheClean")).?,
    );
    try std.testing.expectEqualStrings(
        "https://aur.archlinux.org",
        (try config.getDisplay(arena.allocator(), "AurUrl")).?,
    );
}

test "updates typed and enumerated values case-insensitively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var config = try Config.defaults(arena.allocator());
    try std.testing.expect(try config.set(arena.allocator(), "parallelDOWNLOADcount", "18"));
    try std.testing.expectEqualStrings("18", (try config.getDisplay(arena.allocator(), "ParallelDownloadCount")).?);
    try std.testing.expect(try config.set(arena.allocator(), "ProgressBarStyle", "pacman"));
    try std.testing.expectEqualStrings("Pacman", (try config.getDisplay(arena.allocator(), "ProgressBarStyle")).?);
    try std.testing.expect(!try config.set(arena.allocator(), "ProgressBarStyle", "dots"));
    try std.testing.expect(try config.set(arena.allocator(), "DownloadAddressFamilyPolicy", "preferipv6"));
    try std.testing.expectEqualStrings(
        "PreferIPv6",
        (try config.getDisplay(arena.allocator(), "DownloadAddressFamilyPolicy")).?,
    );
    try std.testing.expect(!try config.set(arena.allocator(), "DownloadAddressFamilyPolicy", "automatic"));
    try std.testing.expect(try config.set(arena.allocator(), "autoconfirmcacheclean", "TrUe"));
    try std.testing.expectEqualStrings(
        "True",
        (try config.getDisplay(arena.allocator(), "AutoConfirmCacheClean")).?,
    );
    try std.testing.expect(!try config.set(arena.allocator(), "AutoConfirmCacheClean", "yes"));
}

test "older configs default to enabled cache cleaning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var config = try Config.defaults(arena.allocator());
    var older: std.json.ObjectMap = .empty;
    try older.put(arena.allocator(), "AutoConfirmCacheClean", .{ .bool = true });
    try config.overlay(older);
    try std.testing.expectEqualStrings("False", (try config.getDisplay(arena.allocator(), "DisableCacheClean")).?);
    try older.put(arena.allocator(), "DisableCacheClean", .{ .string = "true" });
    try std.testing.expectError(error.InvalidConfig, config.overlay(older));
}
