const std = @import("std");

pub const ListDictionary = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(std.ArrayList([]const u8)),

    pub fn init(allocator: std.mem.Allocator) ListDictionary {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        };
    }

    pub fn deinit(self: *ListDictionary) void {
        var it = self.map.valueIterator();
        while (it.next()) |list_ptr| {
            list_ptr.*.deinit(self.allocator);
        }
        self.map.deinit();
    }

    pub fn add(self: *ListDictionary, key: []const u8, value: []const u8) !void {
        const gop = try self.map.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.allocator, value);
    }

    pub fn get(self: *ListDictionary, key: []const u8) ?*std.ArrayList([]const u8) {
        return self.map.getPtr(key);
    }

    pub fn contains(self: *ListDictionary, key: []const u8) bool {
        return self.map.contains(key);
    }

    pub fn remove(self: *ListDictionary, key: []const u8) bool {
        if (self.map.getPtr(key)) |list_ptr| {
            list_ptr.*.deinit(self.allocator);
        }
        return self.map.remove(key);
    }
};

// --- Tests ---

test "ListDictionary add and get" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var dict = ListDictionary.init(allocator);
    defer dict.deinit();

    try dict.add("fruits", "apple");
    try dict.add("fruits", "banana");
    try dict.add("veggies", "carrot");

    // Get fruits
    const fruits_list = dict.get("fruits");
    try std.testing.expect(fruits_list != null);
    if (fruits_list) |list| {
        try std.testing.expectEqual(@as(usize, 2), list.items.len);
        try std.testing.expect(std.mem.eql(u8, list.items[0], "apple"));
        try std.testing.expect(std.mem.eql(u8, list.items[1], "banana"));
    }

    // Get veggies
    const veggies_list = dict.get("veggies");
    try std.testing.expect(veggies_list != null);
    if (veggies_list) |list| {
        try std.testing.expectEqual(@as(usize, 1), list.items.len);
        try std.testing.expect(std.mem.eql(u8, list.items[0], "carrot"));
    }

    // Get non-existing key
    const missing_list = dict.get("missing");
    try std.testing.expect(missing_list == null);
}

test "ListDictionary contains" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var dict = ListDictionary.init(allocator);
    defer dict.deinit();

    try dict.add("fruits", "apple");

    try std.testing.expect(dict.contains("fruits"));
    try std.testing.expect(!dict.contains("veggies"));
}

test "ListDictionary remove" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var dict = ListDictionary.init(allocator);
    defer dict.deinit();

    try dict.add("fruits", "apple");

    // Remove existing key
    try std.testing.expect(dict.remove("fruits"));
    try std.testing.expect(!dict.contains("fruits"));
    try std.testing.expect(dict.get("fruits") == null);

    // Remove non-existing key
    try std.testing.expect(!dict.remove("veggies"));
}

test "ListDictionary add multiple values to same key" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var dict = ListDictionary.init(allocator);
    defer dict.deinit();

    try dict.add("items", "first");
    try dict.add("items", "second");
    try dict.add("items", "third");

    const list = dict.get("items");
    try std.testing.expect(list != null);
    if (list) |l| {
        try std.testing.expectEqual(@as(usize, 3), l.items.len);
        try std.testing.expect(std.mem.eql(u8, l.items[0], "first"));
        try std.testing.expect(std.mem.eql(u8, l.items[1], "second"));
        try std.testing.expect(std.mem.eql(u8, l.items[2], "third"));
    }
}

// Uses testing.allocator directly (no arena) so leaks are detected.
test "ListDictionary is leak-free across add, remove, and re-add" {
    const allocator = std.testing.allocator;

    var dict = ListDictionary.init(allocator);
    defer dict.deinit();

    try dict.add("a", "one");
    try dict.add("a", "two");
    try dict.add("b", "three");

    // Removing must free the inner list's backing memory.
    try std.testing.expect(dict.remove("a"));
    try std.testing.expect(!dict.contains("a"));

    // Re-adding a previously removed key should start a fresh list.
    try dict.add("a", "four");
    const list = dict.get("a");
    try std.testing.expect(list != null);
    if (list) |l| {
        try std.testing.expectEqual(@as(usize, 1), l.items.len);
        try std.testing.expect(std.mem.eql(u8, l.items[0], "four"));
    }
}

test "ListDictionary get returns a mutable pointer to the internal list" {
    const allocator = std.testing.allocator;

    var dict = ListDictionary.init(allocator);
    defer dict.deinit();

    try dict.add("key", "value");

    // Mutating through the returned pointer should be reflected in the map.
    const list_ptr = dict.get("key").?;
    try list_ptr.append(allocator, "value2");

    const reread = dict.get("key").?;
    try std.testing.expectEqual(@as(usize, 2), reread.items.len);
    try std.testing.expect(std.mem.eql(u8, reread.items[1], "value2"));
}
