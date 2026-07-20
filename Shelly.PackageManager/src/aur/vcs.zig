const std = @import("std");

pub const SourceEntry = struct {
    url: []u8,
    branch: []u8,
    protocols: [][]u8,
    commit_sha: []u8,

    pub fn deinit(self: *SourceEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.branch);
        for (self.protocols) |protocol| allocator.free(protocol);
        allocator.free(self.protocols);
        allocator.free(self.commit_sha);
        self.* = undefined;
    }

    pub fn clone(self: SourceEntry, allocator: std.mem.Allocator) !SourceEntry {
        const url = try allocator.dupe(u8, self.url);
        errdefer allocator.free(url);
        const branch = try allocator.dupe(u8, self.branch);
        errdefer allocator.free(branch);
        const commit = try allocator.dupe(u8, self.commit_sha);
        errdefer allocator.free(commit);
        var protocols: std.ArrayList([]u8) = .empty;
        errdefer {
            for (protocols.items) |protocol| allocator.free(protocol);
            protocols.deinit(allocator);
        }
        for (self.protocols) |protocol| try protocols.append(allocator, try allocator.dupe(u8, protocol));
        return .{
            .url = url,
            .branch = branch,
            .protocols = try protocols.toOwnedSlice(allocator),
            .commit_sha = commit,
        };
    }
};

pub fn parseSource(
    allocator: std.mem.Allocator,
    raw_source: []const u8,
    variables: ?*const std.StringHashMap([]const u8),
) !?SourceEntry {
    var source = std.mem.trim(u8, raw_source, " \t\r\n");
    if (source.len == 0) return null;
    if (std.mem.indexOf(u8, source, "::")) |separator| source = source[separator + 2 ..];

    const expanded = try expandVariables(allocator, source, variables);
    defer allocator.free(expanded);
    const scheme_end = std.mem.indexOf(u8, expanded, "://") orelse return null;
    const scheme = expanded[0..scheme_end];

    var protocols: std.ArrayList([]u8) = .empty;
    var protocols_transferred = false;
    defer if (!protocols_transferred) {
        for (protocols.items) |protocol| allocator.free(protocol);
        protocols.deinit(allocator);
    };
    var has_git = false;
    var protocol_iterator = std.mem.splitScalar(u8, scheme, '+');
    while (protocol_iterator.next()) |protocol| {
        if (protocol.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(protocol, "git")) {
            has_git = true;
        } else try protocols.append(allocator, try allocator.dupe(u8, protocol));
    }
    if (!has_git) return null;

    var url = expanded;
    if (url.len >= 4 and std.ascii.eqlIgnoreCase(url[0..4], "git+")) url = url[4..];
    var branch: []const u8 = "";
    if (std.mem.indexOfScalar(u8, url, '#')) |fragment_index| {
        const fragment = url[fragment_index + 1 ..];
        url = url[0..fragment_index];
        if (startsWithIgnoreCase(fragment, "commit=") or startsWithIgnoreCase(fragment, "tag=")) return null;
        if (startsWithIgnoreCase(fragment, "branch=")) {
            branch = std.mem.trim(u8, fragment["branch=".len..], " \t");
            if (branch.len == 0 or std.mem.indexOf(u8, branch, "${") != null or
                std.mem.indexOf(u8, branch, "$(") != null or branch[0] == '$') return null;
        }
    }
    if (std.mem.indexOfScalar(u8, url, '?')) |query| url = url[0..query];
    if (std.mem.indexOfScalar(u8, url, '$') != null) return null;

    const owned_url = try allocator.dupe(u8, url);
    errdefer allocator.free(owned_url);
    const owned_branch = try allocator.dupe(u8, branch);
    errdefer allocator.free(owned_branch);
    const owned_protocols = try protocols.toOwnedSlice(allocator);
    protocols_transferred = true;
    errdefer {
        for (owned_protocols) |protocol| allocator.free(protocol);
        allocator.free(owned_protocols);
    }
    return .{
        .url = owned_url,
        .branch = owned_branch,
        .protocols = owned_protocols,
        .commit_sha = try allocator.dupe(u8, ""),
    };
}

pub fn parseSources(
    allocator: std.mem.Allocator,
    sources: []const []const u8,
    variables: ?*const std.StringHashMap([]const u8),
) ![]SourceEntry {
    var entries: std.ArrayList(SourceEntry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    for (sources) |source| {
        if (try parseSource(allocator, source, variables)) |entry| try entries.append(allocator, entry);
    }
    return entries.toOwnedSlice(allocator);
}

pub fn deinitEntries(allocator: std.mem.Allocator, entries: []SourceEntry) void {
    for (entries) |*entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn expandVariables(
    allocator: std.mem.Allocator,
    input: []const u8,
    variables: ?*const std.StringHashMap([]const u8),
) ![]u8 {
    const vars = variables orelse return allocator.dupe(u8, input);
    var current = try allocator.dupe(u8, input);
    errdefer allocator.free(current);
    for (0..10) |_| {
        const next = try expandOnce(allocator, current, vars);
        if (std.mem.eql(u8, next, current)) {
            allocator.free(current);
            return next;
        }
        allocator.free(current);
        current = next;
    }
    return current;
}

fn expandOnce(allocator: std.mem.Allocator, input: []const u8, variables: *const std.StringHashMap([]const u8)) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] != '$' or index + 1 >= input.len) {
            try output.writer.writeByte(input[index]);
            index += 1;
            continue;
        }

        const start = index;
        index += 1;
        var name_start = index;
        var name_end = index;
        var close_brace = false;
        if (input[index] == '{') {
            close_brace = true;
            name_start = index + 1;
            name_end = name_start;
            while (name_end < input.len and isWord(input[name_end])) name_end += 1;
            if (name_end >= input.len or input[name_end] != '}') {
                try output.writer.writeByte('$');
                continue;
            }
        } else {
            while (name_end < input.len and isWord(input[name_end])) name_end += 1;
        }
        if (name_end == name_start) {
            try output.writer.writeByte('$');
            continue;
        }

        if (variables.get(input[name_start..name_end])) |value| {
            try output.writer.writeAll(value);
        } else {
            const end = name_end + @intFromBool(close_brace);
            try output.writer.writeAll(input[start..end]);
        }
        index = name_end + @intFromBool(close_brace);
    }
    return output.toOwnedSlice();
}

fn isWord(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_';
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap([]SourceEntry),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator, .entries = std.StringHashMap([]SourceEntry).init(allocator) };
    }

    pub fn deinit(self: *Store) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            deinitEntries(self.allocator, entry.value_ptr.*);
        }
        self.entries.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const Store, package_name: []const u8) []const SourceEntry {
        return self.entries.get(package_name) orelse &.{};
    }

    pub fn set(self: *Store, package_name: []const u8, source_entries: []const SourceEntry) !void {
        var cloned: std.ArrayList(SourceEntry) = .empty;
        errdefer {
            for (cloned.items) |*entry| entry.deinit(self.allocator);
            cloned.deinit(self.allocator);
        }
        for (source_entries) |entry| try cloned.append(self.allocator, try entry.clone(self.allocator));
        const owned_entries = try cloned.toOwnedSlice(self.allocator);
        errdefer deinitEntries(self.allocator, owned_entries);

        if (self.entries.getPtr(package_name)) |old| {
            deinitEntries(self.allocator, old.*);
            old.* = owned_entries;
            return;
        }
        const key = try self.allocator.dupe(u8, package_name);
        errdefer self.allocator.free(key);
        try self.entries.put(key, owned_entries);
    }

    pub fn remove(self: *Store, package_name: []const u8) void {
        if (self.entries.fetchRemove(package_name)) |removed| {
            self.allocator.free(removed.key);
            deinitEntries(self.allocator, removed.value);
        }
    }

    pub fn clean(self: *Store, installed_names: []const []const u8) void {
        var remove_names: std.ArrayList([]const u8) = .empty;
        defer remove_names.deinit(self.allocator);
        var iterator = self.entries.keyIterator();
        while (iterator.next()) |stored| {
            var installed = false;
            for (installed_names) |name| {
                if (std.mem.eql(u8, stored.*, name)) {
                    installed = true;
                    break;
                }
            }
            if (!installed) remove_names.append(self.allocator, stored.*) catch return;
        }
        for (remove_names.items) |name| self.remove(name);
    }

    pub fn loadPayload(self: *Store, payload: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidVcsStore;
        var package_iterator = parsed.value.object.iterator();
        while (package_iterator.next()) |package| {
            if (package.value_ptr.* != .array) return error.InvalidVcsStore;
            var source_entries: std.ArrayList(SourceEntry) = .empty;
            defer {
                for (source_entries.items) |*entry| entry.deinit(self.allocator);
                source_entries.deinit(self.allocator);
            }
            for (package.value_ptr.array.items) |value| {
                if (value != .object) return error.InvalidVcsStore;
                const object = value.object;
                const url_value = object.get("Url") orelse return error.InvalidVcsStore;
                const branch_value = object.get("Branch") orelse return error.InvalidVcsStore;
                const commit_value = object.get("CommitSha") orelse return error.InvalidVcsStore;
                if (url_value != .string or branch_value != .string or commit_value != .string) return error.InvalidVcsStore;
                var protocols: std.ArrayList([]u8) = .empty;
                errdefer {
                    for (protocols.items) |protocol| self.allocator.free(protocol);
                    protocols.deinit(self.allocator);
                }
                if (object.get("Protocols")) |protocol_values| {
                    if (protocol_values != .array) return error.InvalidVcsStore;
                    for (protocol_values.array.items) |protocol| {
                        if (protocol != .string) return error.InvalidVcsStore;
                        try protocols.append(self.allocator, try self.allocator.dupe(u8, protocol.string));
                    }
                }
                try source_entries.append(self.allocator, .{
                    .url = try self.allocator.dupe(u8, url_value.string),
                    .branch = try self.allocator.dupe(u8, branch_value.string),
                    .protocols = try protocols.toOwnedSlice(self.allocator),
                    .commit_sha = try self.allocator.dupe(u8, commit_value.string),
                });
            }
            try self.set(package.key_ptr.*, source_entries.items);
        }
    }

    pub fn serialize(self: *const Store) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{ .whitespace = .indent_2 } };
        try json.beginObject();
        var iterator = self.entries.iterator();
        while (iterator.next()) |package| {
            try json.objectField(package.key_ptr.*);
            try json.beginArray();
            for (package.value_ptr.*) |entry| {
                try json.beginObject();
                try json.objectField("Url");
                try json.write(entry.url);
                try json.objectField("Branch");
                try json.write(entry.branch);
                try json.objectField("Protocols");
                try json.write(entry.protocols);
                try json.objectField("CommitSha");
                try json.write(entry.commit_sha);
                try json.endObject();
            }
            try json.endArray();
        }
        try json.endObject();
        return output.toOwnedSlice();
    }

    pub fn loadFile(self: *Store, io: std.Io, path: []const u8) !void {
        const payload = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(payload);
        try self.loadPayload(payload);
    }

    pub fn saveFile(self: *const Store, io: std.Io, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |directory| try std.Io.Dir.cwd().createDirPath(io, directory);
        const payload = try self.serialize();
        defer self.allocator.free(payload);
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, payload);
    }
};

test "VCS source parser replicates git source filtering and variable expansion" {
    var variables = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer variables.deinit();
    try variables.put("repo", "example/project");
    try variables.put("branch", "stable");

    var entry = (try parseSource(
        std.testing.allocator,
        "project::git+https://github.com/$repo.git#branch=${branch}",
        &variables,
    )).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("https://github.com/example/project.git", entry.url);
    try std.testing.expectEqualStrings("stable", entry.branch);
    try std.testing.expectEqualStrings("https", entry.protocols[0]);

    try std.testing.expect((try parseSource(std.testing.allocator, "https://example.invalid/archive.tar.gz", null)) == null);
    try std.testing.expect((try parseSource(std.testing.allocator, "git+https://example.invalid/repo.git#commit=abc", null)) == null);
}

test "VCS store round trips the C# compatible JSON shape and cleans orphans" {
    var source = (try parseSource(std.testing.allocator, "git+https://example.invalid/demo.git#branch=main", null)).?;
    defer source.deinit(std.testing.allocator);
    const sources = [_]SourceEntry{source};

    var original = Store.init(std.testing.allocator);
    defer original.deinit();
    try original.set("demo-git", &sources);
    try original.set("orphan-git", &sources);
    const payload = try original.serialize();
    defer std.testing.allocator.free(payload);

    var loaded = Store.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadPayload(payload);
    try std.testing.expectEqualStrings("main", loaded.get("demo-git")[0].branch);
    loaded.clean(&.{"demo-git"});
    try std.testing.expectEqual(@as(usize, 0), loaded.get("orphan-git").len);
}
