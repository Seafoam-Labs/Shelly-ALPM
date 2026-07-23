const std = @import("std");

pub const Package = struct {
    id: i64 = 0,
    name: []u8,
    package_base_id: i64 = 0,
    package_base: []u8,
    version: []u8,
    description: ?[]u8 = null,
    url: ?[]u8 = null,
    num_votes: i64 = 0,
    popularity: f64 = 0,
    out_of_date: ?i64 = null,
    maintainer: ?[]u8 = null,
    first_submitted: i64 = 0,
    last_modified: i64 = 0,
    url_path: ?[]u8 = null,
    depends: ?[][]u8 = null,
    make_depends: ?[][]u8 = null,
    opt_depends: ?[][]u8 = null,
    check_depends: ?[][]u8 = null,
    conflicts: ?[][]u8 = null,
    provides: ?[][]u8 = null,
    replaces: ?[][]u8 = null,
    groups: ?[][]u8 = null,
    licenses: ?[][]u8 = null,
    keywords: ?[][]u8 = null,
    explicit: bool = false,

    pub fn deinit(self: *Package, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.package_base);
        allocator.free(self.version);
        freeOptional(allocator, self.description);
        freeOptional(allocator, self.url);
        freeOptional(allocator, self.maintainer);
        freeOptional(allocator, self.url_path);
        freeStringList(allocator, self.depends);
        freeStringList(allocator, self.make_depends);
        freeStringList(allocator, self.opt_depends);
        freeStringList(allocator, self.check_depends);
        freeStringList(allocator, self.conflicts);
        freeStringList(allocator, self.provides);
        freeStringList(allocator, self.replaces);
        freeStringList(allocator, self.groups);
        freeStringList(allocator, self.licenses);
        freeStringList(allocator, self.keywords);
        self.* = undefined;
    }

    pub fn deinitSlice(allocator: std.mem.Allocator, packages: []Package) void {
        for (packages) |*package| package.deinit(allocator);
        allocator.free(packages);
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !Package {
        if (value != .object) return error.InvalidAurResponse;
        const object = value.object;

        const name = try dupeRequired(allocator, object, "Name");
        errdefer allocator.free(name);
        const package_base = try dupeRequired(allocator, object, "PackageBase");
        errdefer allocator.free(package_base);
        const package_version = try dupeRequired(allocator, object, "Version");
        errdefer allocator.free(package_version);

        var result = Package{
            .id = getInt(object, "ID") orelse 0,
            .name = name,
            .package_base_id = getInt(object, "PackageBaseID") orelse 0,
            .package_base = package_base,
            .version = package_version,
            .num_votes = getInt(object, "NumVotes") orelse 0,
            .popularity = getFloat(object, "Popularity") orelse 0,
            .out_of_date = getInt(object, "OutOfDate"),
            .first_submitted = getInt(object, "FirstSubmitted") orelse 0,
            .last_modified = getInt(object, "LastModified") orelse 0,
        };
        errdefer result.deinit(allocator);

        result.description = try dupeOptional(allocator, object, "Description");
        result.url = try dupeOptional(allocator, object, "URL");
        result.maintainer = try dupeOptional(allocator, object, "Maintainer");
        result.url_path = try dupeOptional(allocator, object, "URLPath");
        result.depends = try dupeStringList(allocator, object, "Depends");
        result.make_depends = try dupeStringList(allocator, object, "MakeDepends");
        result.opt_depends = try dupeStringList(allocator, object, "OptDepends");
        result.check_depends = try dupeStringList(allocator, object, "CheckDepends");
        result.conflicts = try dupeStringList(allocator, object, "Conflicts");
        result.provides = try dupeStringList(allocator, object, "Provides");
        result.replaces = try dupeStringList(allocator, object, "Replaces");
        result.groups = try dupeStringList(allocator, object, "Groups");
        result.licenses = try dupeStringList(allocator, object, "License");
        result.keywords = try dupeStringList(allocator, object, "Keywords");
        return result;
    }
};

pub const Response = struct {
    version: i64 = 0,
    response_type: []u8,
    result_count: usize = 0,
    results: []Package,
    error_message: ?[]u8 = null,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.response_type);
        Package.deinitSlice(allocator, self.results);
        freeOptional(allocator, self.error_message);
        self.* = undefined;
    }

    pub fn parse(allocator: std.mem.Allocator, payload: []const u8) !Response {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidAurResponse;
        const object = parsed.value.object;

        const response_type = try dupeRequired(allocator, object, "type");
        errdefer allocator.free(response_type);
        const error_message = try dupeOptional(allocator, object, "error");
        errdefer freeOptional(allocator, error_message);

        var packages: std.ArrayList(Package) = .empty;
        errdefer {
            for (packages.items) |*package| package.deinit(allocator);
            packages.deinit(allocator);
        }
        if (object.get("results")) |results| {
            if (results != .array) return error.InvalidAurResponse;
            for (results.array.items) |item| {
                var package = try Package.fromJson(allocator, item);
                packages.append(allocator, package) catch |err| {
                    package.deinit(allocator);
                    return err;
                };
            }
        }

        return .{
            .version = getInt(object, "version") orelse 0,
            .response_type = response_type,
            .result_count = @intCast(getInt(object, "resultcount") orelse @as(i64, @intCast(packages.items.len))),
            .results = try packages.toOwnedSlice(allocator),
            .error_message = error_message,
        };
    }
};

pub const Update = struct {
    name: []u8,
    version: []u8,
    new_version: []u8,
    download_size: i64 = 0,
    url: []u8,
    package_base: []u8,
    description: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        version: []const u8,
        new_version: []const u8,
        url: []const u8,
        package_base: []const u8,
        description: []const u8,
    ) !Update {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_version = try allocator.dupe(u8, version);
        errdefer allocator.free(owned_version);
        const owned_new = try allocator.dupe(u8, new_version);
        errdefer allocator.free(owned_new);
        const owned_url = try allocator.dupe(u8, url);
        errdefer allocator.free(owned_url);
        const owned_base = try allocator.dupe(u8, package_base);
        errdefer allocator.free(owned_base);
        return .{
            .name = owned_name,
            .version = owned_version,
            .new_version = owned_new,
            .url = owned_url,
            .package_base = owned_base,
            .description = try allocator.dupe(u8, description),
        };
    }

    pub fn deinit(self: *Update, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.new_version);
        allocator.free(self.url);
        allocator.free(self.package_base);
        allocator.free(self.description);
        self.* = undefined;
    }

    pub fn deinitSlice(allocator: std.mem.Allocator, updates: []Update) void {
        for (updates) |*update| update.deinit(allocator);
        allocator.free(updates);
    }
};

fn dupeRequired(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidAurResponse;
    if (value != .string) return error.InvalidAurResponse;
    return allocator.dupe(u8, value.string);
}

fn dupeOptional(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => |string| try allocator.dupe(u8, string),
        else => error.InvalidAurResponse,
    };
}

fn dupeStringList(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?[][]u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .array) return error.InvalidAurResponse;
    var strings: std.ArrayList([]u8) = .empty;
    errdefer {
        for (strings.items) |string| allocator.free(string);
        strings.deinit(allocator);
    }
    for (value.array.items) |item| {
        if (item != .string) return error.InvalidAurResponse;
        try strings.append(allocator, try allocator.dupe(u8, item.string));
    }
    return try strings.toOwnedSlice(allocator);
}

fn getInt(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

fn getFloat(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .float => |float| float,
        .integer => |integer| @floatFromInt(integer),
        else => null,
    };
}

fn freeOptional(allocator: std.mem.Allocator, value: ?[]u8) void {
    if (value) |owned| allocator.free(owned);
}

fn freeStringList(allocator: std.mem.Allocator, list: ?[][]u8) void {
    if (list) |items| {
        for (items) |item| allocator.free(item);
        allocator.free(items);
    }
}

test "AUR response parser owns the complete package DTO" {
    const payload =
        \\{"version":5,"type":"info","resultcount":1,"results":[{
        \\  "ID":42,"Name":"demo-git","PackageBaseID":40,"PackageBase":"demo",
        \\  "Version":"1:2.0-1","Description":"demo package","URL":"https://example.invalid",
        \\  "NumVotes":7,"Popularity":1.5,"OutOfDate":null,"Maintainer":"zoey",
        \\  "FirstSubmitted":10,"LastModified":20,"URLPath":"/cgit/demo",
        \\  "Depends":["glibc"],"MakeDepends":["zig"],"OptDepends":["docs: documentation"],
        \\  "CheckDepends":[],"Conflicts":null,"Provides":["demo"],"Replaces":[],
        \\  "Groups":["tools"],"License":["MIT"],"Keywords":["demo"]
        \\}]}
    ;
    var response = try Response.parse(std.testing.allocator, payload);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), response.results.len);
    const package = response.results[0];
    try std.testing.expectEqualStrings("demo-git", package.name);
    try std.testing.expectEqualStrings("demo", package.package_base);
    try std.testing.expectEqualStrings("glibc", package.depends.?[0]);
    try std.testing.expectEqualStrings("MIT", package.licenses.?[0]);
}

test "AUR response parser preserves RPC errors" {
    var response = try Response.parse(std.testing.allocator,
        \\{"version":5,"type":"error","resultcount":0,"results":[],"error":"bad request"}
    );
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("error", response.response_type);
    try std.testing.expectEqualStrings("bad request", response.error_message.?);
}
