//! POSIX extended, case-insensitive, newline-aware search, as in libalpm.
const std = @import("std");
const Package = @import("Package.zig");

const DatabaseSearch = @This();
const c = @cImport({
    @cInclude("regex.h");
});
extern fn rlpm_regex_create(pattern: [*:0]const u8, out: *?*c.regex_t) c_int;
extern fn rlpm_regex_destroy(regex: *c.regex_t) void;

const Pattern = struct {
    text: [:0]u8,
    regex: *c.regex_t,
};
allocator: std.mem.Allocator,
patterns: []Pattern,

pub fn init(allocator: std.mem.Allocator, needles: []const []const u8) !DatabaseSearch {
    const patterns = try allocator.alloc(Pattern, needles.len);
    var initialized: usize = 0;
    errdefer {
        for (patterns[0..initialized]) |*pattern| {
            rlpm_regex_destroy(pattern.regex);
            allocator.free(pattern.text);
        }
        allocator.free(patterns);
    }
    for (needles, patterns) |needle, *pattern| {
        if (std.mem.indexOfScalar(u8, needle, 0) != null) return error.InvalidRegex;
        pattern.text = try allocator.dupeSentinel(u8, needle, 0);
        errdefer allocator.free(pattern.text);
        var regex: ?*c.regex_t = null;
        const status = rlpm_regex_create(pattern.text, &regex);
        if (status != 0) return if (status == c.REG_ESPACE) error.OutOfMemory else error.InvalidRegex;
        pattern.regex = regex.?;
        initialized += 1;
    }
    return .{ .allocator = allocator, .patterns = patterns };
}

pub fn deinit(self: *DatabaseSearch) void {
    for (self.patterns) |*pattern| {
        rlpm_regex_destroy(pattern.regex);
        self.allocator.free(pattern.text);
    }
    self.allocator.free(self.patterns);
}

fn regexMatches(self: *const DatabaseSearch, regex: *const c.regex_t, value: []const u8) !bool {
    const sentinel = try self.allocator.dupeSentinel(u8, value, 0);
    defer self.allocator.free(sentinel);
    const status = c.regexec(regex, sentinel.ptr, 0, null, 0);
    if (status == c.REG_ESPACE) return error.OutOfMemory;
    return status == 0;
}

pub fn matches(self: *const DatabaseSearch, package: *const Package) !bool {
    // The pinned alpm_db_search returns an empty result for an empty needle list.
    if (self.patterns.len == 0) return false;
    for (self.patterns) |*pattern| {
        if (try self.regexMatches(pattern.regex, package.name) or
            std.mem.indexOf(
                u8,
                package.name,
                pattern.text,
            ) != null)
            continue;
        if (package.description) |description|
            if (try self.regexMatches(pattern.regex, description)) {
                continue;
            };
        const matched = blk: {
            for (package.provides) |relation|
                if (try self.regexMatches(pattern.regex, relation.name)) {
                    break :blk true;
                };
            for (package.groups) |group|
                if (try self.regexMatches(pattern.regex, group)) {
                    break :blk true;
                };
            break :blk false;
        };
        if (!matched) return false;
    }
    return true;
}
