//! source= array handling: local file discovery and content review.
const std = @import("std");
const file_inspector = @import("../../local/file_inspector.zig");
const types = @import("types.zig");
const PkgbuildParser = @import("parser.zig").PkgbuildParser;

const split_entry = types.split_entry;

fn is_remote_source(location: []const u8) !bool {
    if (std.ascii.indexOfIgnoreCase(location, "://") != null) return true else return false;
}

const max_local_source_size = 32 * 1024 * 1024;

pub fn extract_local_source_files(self: PkgbuildParser, source: [][]const u8) ![][]const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(self.allocator);

    for (source) |line| {
        const entry = split_source_entry(line);
        if (try is_remote_source(entry.location)) continue;

        const name = if (entry.file_name.len == 0) entry.location else entry.file_name;
        if (name.len == 0) continue;

        var already_have = false;
        for (files.items) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                already_have = true;
                break;
            }
        }
        if (!already_have) {
            try files.append(self.allocator, try self.allocator.dupe(u8, name));
        }
    }

    return files.toOwnedSlice(self.allocator);
}

pub fn resolve_local_source_contents(self: PkgbuildParser, local_source_files: [][]const u8, base_dir: ?[]const u8) !std.StringHashMap([]const u8) {
    var contents: std.StringHashMap([]const u8) = .init(self.allocator);

    for (local_source_files) |file| {
        const resolved = try resolve_local_file(self, file, base_dir);
        if (resolved) |content| {
            defer self.allocator.free(content);
            const key_owned = try self.allocator.dupe(u8, file);
            const display = try self.allocator.dupe(u8, reviewable_local_source_content(content));
            try contents.put(key_owned, display);
        }
    }
    return contents;
}

fn reviewable_local_source_content(content: []const u8) []const u8 {
    if (file_inspector.isElfBytes(content)) {
        return "ELF executable binary (content is not displayed). Review the file's source and checksum before proceeding.";
    }
    if (!std.unicode.utf8ValidateSlice(content)) {
        return "Binary file (content is not displayed). Review the file's source and checksum before proceeding.";
    }
    return content;
}

fn resolve_local_file(self: PkgbuildParser, file_name: []const u8, base_dir: ?[]const u8) !?[]const u8 {
    for (file_name) |c| {
        if (std.ascii.isWhitespace(c)) return null;
    }

    const path = if (base_dir) |dir|
        try std.fs.path.join(self.allocator, &.{ dir, file_name })
    else
        file_name;
    defer if (base_dir != null) self.allocator.free(path);

    const exists = blk: {
        std.Io.Dir.cwd().access(self.io, path, .{}) catch break :blk false;
        break :blk true;
    };
    if (!exists) return null;

    return try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(max_local_source_size));
}

fn split_source_entry(entry: []const u8) split_entry {
    const idx = find_source_rename_delimiter(entry);
    if (idx) |i| {
        return split_entry{ .file_name = entry[0..i], .location = entry[i + 2 ..] };
    } else {
        return split_entry{ .file_name = "", .location = entry };
    }
}

fn find_source_rename_delimiter(entry: []const u8) ?usize {
    var parameter_depth: usize = 0;
    var pos: usize = 0;
    while (pos + 1 < entry.len) {
        if (entry[pos] == '\\') {
            pos += @min(@as(usize, 2), entry.len - pos);
            continue;
        }
        if (entry[pos] == '$' and entry[pos + 1] == '{') {
            parameter_depth += 1;
            pos += 2;
            continue;
        }
        if (parameter_depth > 0) {
            if (entry[pos] == '}') parameter_depth -= 1;
            pos += 1;
            continue;
        }
        if (entry[pos] == ':' and entry[pos + 1] == ':') return pos;
        pos += 1;
    }
    return null;
}

test "resolve_local_file: file name containing whitespace returns null" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try resolve_local_file(parser, "my source.tar.gz", null);
    try std.testing.expect(result == null);
}

test "resolve_local_file: nonexistent file returns null" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try resolve_local_file(parser, "definitely_not_a_file.txt", null);
    try std.testing.expect(result == null);
}

test "resolve_local_file: existing file with no base_dir returns content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const expected = "hello world\nthis is my file content";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "test.txt", .data = expected });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "test.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try resolve_local_file(parser, path, null);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings(expected, result.?);
}

test "resolve_local_file: joins base_dir and file_name correctly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const expected = "data in a subdir";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data.txt", .data = expected });

    const base_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_dir);

    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try resolve_local_file(parser, "data.txt", base_dir);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings(expected, result.?);
}

test "resolve_local_source_contents: empty file list returns empty map" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const files: [][]const u8 = &.{};
    var result = try resolve_local_source_contents(parser, files, ".");
    defer {
        var it = result.valueIterator();
        while (it.next()) |value| {
            std.testing.allocator.free(value.*);
        }
        result.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), result.count());
}

test "resolve_local_source_contents: single existing file" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "content a" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    var files = [_][]const u8{"a.txt"};
    var result = try resolve_local_source_contents(parser, files[0..], base);
    defer {
        var it = result.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        result.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), result.count());
    try std.testing.expect(result.get("a.txt") != null);
    try std.testing.expectEqualStrings("content a", result.get("a.txt").?);
}

test "resolve_local_source_contents: multiple existing files" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "alpha" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.txt", .data = "beta" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    var files = [_][]const u8{ "a.txt", "b.txt" };
    var result = try resolve_local_source_contents(parser, files[0..], base);
    defer {
        var it = result.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        result.deinit();
    }
    try std.testing.expectEqual(@as(usize, 2), result.count());
    try std.testing.expectEqualStrings("alpha", result.get("a.txt").?);
    try std.testing.expectEqualStrings("beta", result.get("b.txt").?);
}

test "resolve_local_source_contents: skips nonexistent files" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "exists.txt", .data = "here" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    var files = [_][]const u8{ "exists.txt", "missing.txt" };
    var result = try resolve_local_source_contents(parser, files[0..], base);
    defer {
        var it = result.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        result.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), result.count());
    try std.testing.expect(result.get("missing.txt") == null);
    try std.testing.expectEqualStrings("here", result.get("exists.txt").?);
}

test "resolve_local_source_contents: skips files with whitespace in name" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "good.txt", .data = "ok" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    var files = [_][]const u8{ "good.txt", "bad file.txt" };
    var result = try resolve_local_source_contents(parser, files[0..], base);

    defer {
        var it = result.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        result.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), result.count());
    try std.testing.expect(result.get("bad file.txt") == null);
    try std.testing.expectEqualStrings("ok", result.get("good.txt").?);
}

test "resolve_local_source_contents: all files missing returns empty map" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    var files = [_][]const u8{ "no1.txt", "no2.txt" };
    var result = try resolve_local_source_contents(parser, files[0..], base);
    defer {
        var it = result.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        result.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), result.count());
}

test "is_remote_source true" {
    try std.testing.expect(try is_remote_source("https://example.com"));
}

test "is_remote_source false" {
    try std.testing.expect(!try is_remote_source("67.com"));
}

test "split_source_entry: normal case" {
    const result = split_source_entry("archive.tar.gz::https://example.com/archive.tar.gz");
    try std.testing.expectEqualStrings("archive.tar.gz", result.file_name);
    try std.testing.expectEqualStrings("https://example.com/archive.tar.gz", result.location);
}

test "split_source_entry: no separator" {
    const result = split_source_entry("https://example.com/file.tar.gz");
    try std.testing.expectEqualStrings("", result.file_name);
    try std.testing.expectEqualStrings("https://example.com/file.tar.gz", result.location);
}

test "split_source_entry: separator at start" {
    const result = split_source_entry("::https://example.com");
    try std.testing.expectEqualStrings("", result.file_name);
    try std.testing.expectEqualStrings("https://example.com", result.location);
}

test "split_source_entry: separator at end" {
    const result = split_source_entry("file.tar.gz::");
    try std.testing.expectEqualStrings("file.tar.gz", result.file_name);
    try std.testing.expectEqualStrings("", result.location);
}

test "split_source_entry: multiple separators" {
    const result = split_source_entry("file::key::value");
    try std.testing.expectEqualStrings("file", result.file_name);
    try std.testing.expectEqualStrings("key::value", result.location);
}

test "split_source_entry: ignores separator inside parameter expansion" {
    const source = "https://files.pythonhosted.org/packages/source/${_name::1}/${_name}/archive.tar.gz";
    const result = split_source_entry(source);
    try std.testing.expectEqualStrings("", result.file_name);
    try std.testing.expectEqualStrings(source, result.location);
}

test "split_source_entry: finds outer separator before parameter expansion" {
    const location = "https://example.com/${name::1}/archive.tar.gz";
    const result = split_source_entry("renamed.tar.gz::" ++ location);
    try std.testing.expectEqualStrings("renamed.tar.gz", result.file_name);
    try std.testing.expectEqualStrings(location, result.location);
}

test "split_source_entry: ignores separator inside nested parameter expansions" {
    const source = "https://example.com/${outer:-${inner::1}}/archive.tar.gz";
    const result = split_source_entry(source);
    try std.testing.expectEqualStrings("", result.file_name);
    try std.testing.expectEqualStrings(source, result.location);
}

test "split_source_entry: case insensitive separator" {
    // :: has no alphabetic characters, so case doesn't matter,
    // but this confirms the function handles the input as-is
    const result = split_source_entry("pkg::url");
    try std.testing.expectEqualStrings("pkg", result.file_name);
    try std.testing.expectEqualStrings("url", result.location);
}

test "extract_local_source_files: keeps every local source, including extensionless binaries" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var source = [_][]const u8{
        "install.sh",
        "fix.patch",
        "readme.md",
        "updater",
    };
    const result = try extract_local_source_files(parser, source[0..]);
    defer {
        for (result) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("install.sh", result[0]);
    try std.testing.expectEqualStrings("fix.patch", result[1]);
    try std.testing.expectEqualStrings("readme.md", result[2]);
    try std.testing.expectEqualStrings("updater", result[3]);
}

test "extract_local_source_files: excludes remote sources" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var source = [_][]const u8{
        "https://example.com/archive.tar.gz",
        "renamed.sh::https://example.com/script.sh",
        "local.conf",
    };
    const result = try extract_local_source_files(parser, source[0..]);
    defer {
        for (result) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(result);
    }

    // "renamed.sh::https://..." has a local file_name but remote location —
    // confirm expected behavior here depends on how is_remote_source/split_source_entry
    // handle the "::" form for your implementation.
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("local.conf", result[0]);
}

test "extract_local_source_files: dedupes repeated file names" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var source = [_][]const u8{
        "install.sh",
        "install.sh",
        "install.sh",
    };
    const result = try extract_local_source_files(parser, source[0..]);
    defer {
        for (result) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("install.sh", result[0]);
}

test "extract_local_source_files: empty source returns empty slice" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var source = [_][]const u8{};
    const result = try extract_local_source_files(parser, source[0..]);
    defer {
        for (result) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "extract_local_source_files: keeps source names regardless of filename casing" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var source = [_][]const u8{
        "SETUP.SH",
    };
    const result = try extract_local_source_files(parser, source[0..]);
    defer {
        for (result) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("SETUP.SH", result[0]);
}

test "reviewable local source content marks ELF and non-text binaries without changing text" {
    try std.testing.expectEqualStrings(
        "ELF executable binary (content is not displayed). Review the file's source and checksum before proceeding.",
        reviewable_local_source_content("\x7fELFpayload"),
    );
    try std.testing.expectEqualStrings(
        "Binary file (content is not displayed). Review the file's source and checksum before proceeding.",
        reviewable_local_source_content(&.{ 0, 159, 146, 150 }),
    );
    try std.testing.expectEqualStrings("#!/bin/sh\nexit 0", reviewable_local_source_content("#!/bin/sh\nexit 0"));
}
