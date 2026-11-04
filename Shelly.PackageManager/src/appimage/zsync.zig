const std = @import("std");
const appimage = @import("bindings.zig").appimage;

/// Parsed representation of the AppImage embedded update information
/// (AppImageSpec "Update Information"). Payload slices borrow from the input
/// string and stay valid as long as it does.
pub const UpdateInfo = union(enum) {
    /// `zsync|<url of the .zsync control file>`
    zsync_url: []const u8,
    /// `gh-releases-zsync|<owner>|<repo>|<tag>|<filename pattern>`
    github_releases: GithubReleases,
    /// Any other scheme (for example `bintray-zsync`). The payload is the
    /// scheme name so callers can explain why the source is unusable.
    unsupported: []const u8,

    pub const GithubReleases = struct {
        owner: []const u8,
        repo: []const u8,
        /// Release tag selector, usually `latest`.
        tag: []const u8,
        /// Filename glob which may contain `*`. May be empty.
        pattern: []const u8,
    };
};

/// Parses an embedded update-information string such as the output of
/// `<app> --appimage-updateinfo`. Returns null when the string is empty or
/// has no recognizable `scheme|payload` structure.
pub fn parseUpdateInfo(raw: []const u8) ?UpdateInfo {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    const separator = std.mem.indexOfScalar(u8, trimmed, '|') orelse return null;
    const scheme = trimmed[0..separator];
    const payload = trimmed[separator + 1 ..];
    if (scheme.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(scheme, "zsync")) {
        const url = std.mem.trim(u8, payload, &std.ascii.whitespace);
        if (url.len == 0 or !isHttpUrl(url)) return null;
        return .{ .zsync_url = url };
    }
    if (std.ascii.eqlIgnoreCase(scheme, "gh-releases-zsync")) {
        var fields: [4][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, payload, '|');
        while (it.next()) |field| {
            if (count == fields.len) return null;
            fields[count] = field;
            count += 1;
        }
        if (count != fields.len) return null;
        if (fields[0].len == 0 or fields[1].len == 0 or fields[2].len == 0) return null;
        return .{ .github_releases = .{
            .owner = fields[0],
            .repo = fields[1],
            .tag = fields[2],
            .pattern = fields[3],
        } };
    }
    return .{ .unsupported = scheme };
}

/// Returns the control-file URL when the update information is a plain
/// `zsync|<url>` string. Payload slices borrow from `raw`.
pub fn stripZsyncScheme(raw: []const u8) ?[]const u8 {
    const info = parseUpdateInfo(raw) orelse return null;
    return switch (info) {
        .zsync_url => |url| url,
        else => null,
    };
}

/// Returns the filename glob embedded in `gh-releases-zsync` update
/// information, or null when absent or empty. Payload slices borrow from
/// `raw_update_info`.
pub fn githubAssetPattern(raw_update_info: []const u8) ?[]const u8 {
    const info = parseUpdateInfo(raw_update_info) orelse return null;
    return switch (info) {
        .github_releases => |gh| if (gh.pattern.len > 0) gh.pattern else null,
        else => null,
    };
}

/// Applies the embedded update information of an AppImage to its update
/// configuration fields. The stored values borrow from `app.raw_update_info`,
/// so the string must stay alive as long as the configuration is used (the
/// local database clones every field on persist). Returns false when the
/// information is missing, unparseable, or uses an unsupported scheme.
pub fn configureFromEmbeddedInfo(app: *appimage.AppImage) bool {
    const info = parseUpdateInfo(app.raw_update_info) orelse return false;
    switch (info) {
        .zsync_url => |url| {
            app.update_type = .zsync;
            app.update_url = url;
            app.repo_owner = null;
            app.repo_name = null;
        },
        .github_releases => |gh| {
            app.update_type = .github;
            app.update_url = "";
            app.repo_owner = gh.owner;
            app.repo_name = gh.repo;
        },
        .unsupported => return false,
    }
    return true;
}

/// The plain-text header section of a zsync control file. Values borrow from
/// the parsed input.
pub const ControlHeaders = struct {
    /// Target filename as published by the server (`Filename:` header).
    filename: ?[]const u8 = null,
    /// Last-modified timestamp of the target file (`MTime:` header). Used as
    /// the remote version token because zsync has no semantic version.
    mtime: ?[]const u8 = null,
    /// Byte length of the target file (`Length:` header).
    length: ?u64 = null,
    /// First `URL:` header. May be relative to the control-file URL.
    url: ?[]const u8 = null,
};

/// Parses the header section of a zsync control file. Headers are
/// `Key: value` lines terminated by the first blank line; everything after
/// that is binary checksum data and is ignored. Header names are matched
/// case-insensitively and only the first occurrence of each is kept.
pub fn parseControlHeaders(data: []const u8) ControlHeaders {
    var result: ControlHeaders = .{};
    var rest = data;
    while (rest.len > 0) {
        const newline = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        var line = rest[0..newline];
        rest = if (newline < rest.len) rest[newline + 1 ..] else rest[rest.len..];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], &std.ascii.whitespace);
        const value = std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);
        if (value.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(key, "filename")) {
            if (result.filename == null) result.filename = value;
        } else if (std.ascii.eqlIgnoreCase(key, "mtime")) {
            if (result.mtime == null) result.mtime = value;
        } else if (std.ascii.eqlIgnoreCase(key, "length")) {
            if (result.length == null) result.length = std.fmt.parseInt(u64, value, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(key, "url")) {
            if (result.url == null) result.url = value;
        }
    }
    return result;
}

/// Derives the AppImage download URL for a zsync control file. Prefers the
/// `URL:` header (resolved against the control-file URL when relative) and
/// falls back to stripping the `.zsync` suffix, which is how publishers
/// covered by the AppImage spec place the target next to the control file.
/// Returns an owned absolute http(s) URL, or null when none can be derived.
pub fn resolveTargetUrl(allocator: std.mem.Allocator, control_url: []const u8, reference: ?[]const u8) !?[]u8 {
    if (reference) |raw_reference| {
        const trimmed_reference = std.mem.trim(u8, raw_reference, &std.ascii.whitespace);
        if (trimmed_reference.len > 0) {
            if (isHttpUrl(trimmed_reference)) return try allocator.dupe(u8, trimmed_reference);
            return resolveRelative(allocator, control_url, trimmed_reference);
        }
    }
    return stripZsyncSuffix(allocator, control_url);
}

/// Case-insensitive glob match supporting `*` (any run) and `?` (one
/// character), used for AppImageSpec release filename patterns such as
/// `Subsurface-*x86_64.AppImage.zsync`.
pub fn globMatchIgnoreCase(pattern: []const u8, value: []const u8) bool {
    var pattern_index: usize = 0;
    var value_index: usize = 0;
    var star_pattern: usize = std.math.maxInt(usize);
    var star_value: usize = 0;
    while (value_index < value.len) {
        if (pattern_index < pattern.len and
            (pattern[pattern_index] == '?' or
                std.ascii.toLower(pattern[pattern_index]) == std.ascii.toLower(value[value_index])))
        {
            pattern_index += 1;
            value_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_pattern = pattern_index;
            star_value = value_index;
            pattern_index += 1;
        } else if (star_pattern != std.math.maxInt(usize)) {
            pattern_index = star_pattern + 1;
            star_value += 1;
            value_index = star_value;
        } else return false;
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

fn stripZsyncSuffix(allocator: std.mem.Allocator, url: []const u8) !?[]u8 {
    const suffix = ".zsync";
    if (url.len > suffix.len and endsWithIgnoreCase(url, suffix)) {
        return try allocator.dupe(u8, url[0 .. url.len - suffix.len]);
    }
    return null;
}

fn resolveRelative(allocator: std.mem.Allocator, base_url: []const u8, reference: []const u8) !?[]u8 {
    // A reference carrying its own non-HTTP scheme (for example `ftp://`) is
    // not a usable mirror; relative references parse with an empty scheme.
    if (std.Uri.parse(reference)) |reference_uri| {
        if (reference_uri.scheme.len > 0 and
            !std.ascii.eqlIgnoreCase(reference_uri.scheme, "http") and
            !std.ascii.eqlIgnoreCase(reference_uri.scheme, "https")) return null;
    } else |_| {}

    const base = std.Uri.parse(base_url) catch return null;
    if (!std.ascii.eqlIgnoreCase(base.scheme, "http") and !std.ascii.eqlIgnoreCase(base.scheme, "https")) return null;
    const host = base.host orelse return null;
    const host_text = componentText(host);
    if (host_text.len == 0) return null;

    var origin: std.ArrayList(u8) = .empty;
    errdefer origin.deinit(allocator);
    try origin.appendSlice(allocator, base.scheme);
    try origin.appendSlice(allocator, "://");
    try origin.appendSlice(allocator, host_text);
    if (base.port) |port| {
        try origin.append(allocator, ':');
        var port_buffer: [8]u8 = undefined;
        const port_text = std.fmt.bufPrint(&port_buffer, "{d}", .{port}) catch return null;
        try origin.appendSlice(allocator, port_text);
    }

    var base_path = componentText(base.path);
    if (base_path.len == 0 or base_path[0] != '/') base_path = "/";

    const resolved_path = if (reference[0] == '/')
        try normalizePath(allocator, reference)
    else blk: {
        const last_slash = std.mem.lastIndexOfScalar(u8, base_path, '/') orelse 0;
        const directory = base_path[0 .. last_slash + 1];
        const joined = try std.mem.concat(allocator, u8, &.{ directory, reference });
        defer allocator.free(joined);
        break :blk try normalizePath(allocator, joined);
    };
    defer allocator.free(resolved_path);

    try origin.appendSlice(allocator, resolved_path);
    return try origin.toOwnedSlice(allocator);
}

/// Collapses `.` and `..` segments and guarantees a leading slash. The
/// result is owned; query and fragment components are not expected in zsync
/// URL headers and are treated as ordinary path text.
fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);

    var it = std.mem.splitScalar(u8, path, '/');
    _ = it.next();
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            _ = segments.pop();
            continue;
        }
        try segments.append(allocator, segment);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '/');
    for (segments.items, 0..) |segment, index| {
        if (index > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, segment);
    }
    return try out.toOwnedSlice(allocator);
}

fn isHttpUrl(value: []const u8) bool {
    const uri = std.Uri.parse(value) catch return false;
    return (std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        std.ascii.eqlIgnoreCase(uri.scheme, "https")) and uri.host != null;
}

fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    const tail = haystack[haystack.len - needle.len ..];
    return std.ascii.eqlIgnoreCase(tail, needle);
}

fn componentText(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
}

test "zsync parseUpdateInfo: parses a plain zsync control-file URL" {
    const info = parseUpdateInfo("zsync|https://nightly.example.dev/latest/Eden-Linux.AppImage.zsync").?;
    try std.testing.expectEqual(.zsync_url, std.meta.activeTag(info));
    try std.testing.expectEqualStrings("https://nightly.example.dev/latest/Eden-Linux.AppImage.zsync", info.zsync_url);
}

test "zsync parseUpdateInfo: parses gh-releases-zsync into owner, repo, tag and pattern" {
    const info = parseUpdateInfo("gh-releases-zsync|subsurface|subsurface|latest|Subsurface-*x86_64.AppImage.zsync").?;
    try std.testing.expectEqual(.github_releases, std.meta.activeTag(info));
    try std.testing.expectEqualStrings("subsurface", info.github_releases.owner);
    try std.testing.expectEqualStrings("subsurface", info.github_releases.repo);
    try std.testing.expectEqualStrings("latest", info.github_releases.tag);
    try std.testing.expectEqualStrings("Subsurface-*x86_64.AppImage.zsync", info.github_releases.pattern);
}

test "zsync parseUpdateInfo: tolerates surrounding whitespace" {
    const info = parseUpdateInfo("  zsync|https://example.com/App.AppImage.zsync \n").?;
    try std.testing.expectEqualStrings("https://example.com/App.AppImage.zsync", info.zsync_url);
}

test "zsync parseUpdateInfo: reports unsupported schemes instead of dropping them" {
    const info = parseUpdateInfo("bintray-zsync|owner|repo|package|pattern").?;
    try std.testing.expectEqual(.unsupported, std.meta.activeTag(info));
    try std.testing.expectEqualStrings("bintray-zsync", info.unsupported);
}

test "zsync parseUpdateInfo: rejects malformed inputs" {
    try std.testing.expect(parseUpdateInfo("") == null);
    try std.testing.expect(parseUpdateInfo("https://example.com/App.AppImage") == null);
    try std.testing.expect(parseUpdateInfo("zsync|") == null);
    try std.testing.expect(parseUpdateInfo("zsync|ftp://example.com/App.zsync") == null);
    try std.testing.expect(parseUpdateInfo("|https://example.com/App.zsync") == null);
    try std.testing.expect(parseUpdateInfo("gh-releases-zsync|owner|repo|latest") == null);
    try std.testing.expect(parseUpdateInfo("gh-releases-zsync|owner|repo|latest|a|b") == null);
    try std.testing.expect(parseUpdateInfo("gh-releases-zsync||repo|latest|pattern") == null);
}

test "zsync stripZsyncScheme: extracts only from zsync strings" {
    try std.testing.expectEqualStrings(
        "https://example.com/App.AppImage.zsync",
        stripZsyncScheme("zsync|https://example.com/App.AppImage.zsync").?,
    );
    try std.testing.expect(stripZsyncScheme("gh-releases-zsync|a|b|latest|c") == null);
    try std.testing.expect(stripZsyncScheme("https://example.com/App.AppImage.zsync") == null);
}

test "zsync githubAssetPattern: returns the embedded glob when present" {
    try std.testing.expectEqualStrings(
        "Subsurface-*x86_64.AppImage.zsync",
        githubAssetPattern("gh-releases-zsync|subsurface|subsurface|latest|Subsurface-*x86_64.AppImage.zsync").?,
    );
    try std.testing.expect(githubAssetPattern("gh-releases-zsync|owner|repo|latest|") == null);
    try std.testing.expect(githubAssetPattern("zsync|https://example.com/App.zsync") == null);
    try std.testing.expect(githubAssetPattern("") == null);
}

test "zsync configureFromEmbeddedInfo: configures a zsync control-file URL" {
    var app = appimage.AppImage{
        .name = "Eden",
        .raw_update_info = "zsync|https://nightly.example.dev/latest/Eden.AppImage.zsync",
    };
    try std.testing.expect(configureFromEmbeddedInfo(&app));
    try std.testing.expectEqual(appimage.UpdateType.zsync, app.update_type);
    try std.testing.expectEqualStrings("https://nightly.example.dev/latest/Eden.AppImage.zsync", app.update_url);
    try std.testing.expect(app.repo_owner == null);
    try std.testing.expect(app.repo_name == null);
}

test "zsync configureFromEmbeddedInfo: maps gh-releases-zsync onto the GitHub provider" {
    var app = appimage.AppImage{
        .name = "Subsurface",
        .raw_update_info = "gh-releases-zsync|subsurface|subsurface|latest|Subsurface-*x86_64.AppImage.zsync",
    };
    try std.testing.expect(configureFromEmbeddedInfo(&app));
    try std.testing.expectEqual(appimage.UpdateType.github, app.update_type);
    try std.testing.expectEqualStrings("subsurface", app.repo_owner.?);
    try std.testing.expectEqualStrings("subsurface", app.repo_name.?);
}

test "zsync configureFromEmbeddedInfo: leaves unusable information alone" {
    var app = appimage.AppImage{ .name = "Other", .raw_update_info = "bintray-zsync|a|b|c|d" };
    try std.testing.expect(!configureFromEmbeddedInfo(&app));
    try std.testing.expectEqual(appimage.UpdateType.none, app.update_type);

    app.raw_update_info = "";
    try std.testing.expect(!configureFromEmbeddedInfo(&app));
}

test "zsync parseControlHeaders: reads the header section and ignores checksum data" {
    const data =
        \\zsync: 0.6.2
        \\Filename: Eden-Linux.AppImage
        \\MTime: Sat, 21 Jun 2026 01:02:03 +0000
        \\Blocksize: 4096
        \\Length: 104857600
        \\Hash-Lengths: 4, 4, 4
        \\URL: Eden-Linux.AppImage
        \\URL: https://mirror.example.dev/Eden-Linux.AppImage
        \\
        \\binary-checksum-data-follows
    ;
    const headers = parseControlHeaders(data);
    try std.testing.expectEqualStrings("Eden-Linux.AppImage", headers.filename.?);
    try std.testing.expectEqualStrings("Sat, 21 Jun 2026 01:02:03 +0000", headers.mtime.?);
    try std.testing.expectEqual(@as(u64, 104857600), headers.length.?);
    // The first URL header wins; later mirrors are fallbacks Shelly does not
    // need because the primary sits next to the control file.
    try std.testing.expectEqualStrings("Eden-Linux.AppImage", headers.url.?);
}

test "zsync parseControlHeaders: tolerates CRLF, casing and junk lines" {
    const data = "ZSYNC: 0.6.2\r\nFILENAME: App.AppImage\r\nnonsense without colon\r\nmtime: Mon, 01 Jan 2024 00:00:00 +0000\r\n\r\nignored: yes\r\n";
    const headers = parseControlHeaders(data);
    try std.testing.expectEqualStrings("App.AppImage", headers.filename.?);
    try std.testing.expectEqualStrings("Mon, 01 Jan 2024 00:00:00 +0000", headers.mtime.?);
    try std.testing.expect(headers.url == null);
}

test "zsync parseControlHeaders: empty input yields empty headers" {
    const headers = parseControlHeaders("");
    try std.testing.expect(headers.filename == null);
    try std.testing.expect(headers.mtime == null);
    try std.testing.expect(headers.length == null);
    try std.testing.expect(headers.url == null);
}

test "zsync resolveTargetUrl: prefers an absolute URL header" {
    const url = (try resolveTargetUrl(
        std.testing.allocator,
        "https://example.com/latest/App.AppImage.zsync",
        "https://cdn.example.com/App.AppImage",
    )).?;
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://cdn.example.com/App.AppImage", url);
}

test "zsync resolveTargetUrl: resolves relative URL headers against the control file" {
    const cases = [_]struct { reference: []const u8, expected: []const u8 }{
        .{ .reference = "App.AppImage", .expected = "https://example.com/latest/App.AppImage" },
        .{ .reference = "../stable/App.AppImage", .expected = "https://example.com/stable/App.AppImage" },
        .{ .reference = "/downloads/App.AppImage", .expected = "https://example.com/downloads/App.AppImage" },
        .{ .reference = "./App.AppImage", .expected = "https://example.com/latest/App.AppImage" },
    };
    for (cases) |case| {
        const url = (try resolveTargetUrl(
            std.testing.allocator,
            "https://example.com/latest/App.AppImage.zsync",
            case.reference,
        )).?;
        defer std.testing.allocator.free(url);
        try std.testing.expectEqualStrings(case.expected, url);
    }
}

test "zsync resolveTargetUrl: keeps host and port for relative references" {
    const url = (try resolveTargetUrl(
        std.testing.allocator,
        "http://builds.example.dev:8080/nightly/App.AppImage.zsync",
        "App.AppImage",
    )).?;
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://builds.example.dev:8080/nightly/App.AppImage", url);
}

test "zsync resolveTargetUrl: falls back to stripping the .zsync suffix" {
    const url = (try resolveTargetUrl(
        std.testing.allocator,
        "https://example.com/latest/App.AppImage.zsync",
        null,
    )).?;
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://example.com/latest/App.AppImage", url);

    // An empty URL header behaves like a missing one.
    const fallback = (try resolveTargetUrl(
        std.testing.allocator,
        "https://example.com/latest/App.AppImage.zsync",
        "   ",
    )).?;
    defer std.testing.allocator.free(fallback);
    try std.testing.expectEqualStrings("https://example.com/latest/App.AppImage", fallback);
}

test "zsync resolveTargetUrl: returns null when no target can be derived" {
    try std.testing.expect(try resolveTargetUrl(
        std.testing.allocator,
        "https://example.com/latest/control",
        null,
    ) == null);
    try std.testing.expect(try resolveTargetUrl(
        std.testing.allocator,
        "https://example.com/latest/control.zsync",
        "ftp://example.com/App.AppImage",
    ) == null);
}

test "zsync globMatchIgnoreCase: matches AppImageSpec filename patterns" {
    try std.testing.expect(globMatchIgnoreCase("Subsurface-*x86_64.AppImage.zsync", "Subsurface-5.0.10-x86_64.AppImage.zsync"));
    try std.testing.expect(globMatchIgnoreCase("subsurface-*x86_64.appimage.zsync", "Subsurface-5.0.10-x86_64.AppImage.zsync"));
    try std.testing.expect(globMatchIgnoreCase("App-*.AppImage", "App-1.2.3-x86_64.AppImage"));
    try std.testing.expect(globMatchIgnoreCase("*.AppImage", "App.AppImage"));
    try std.testing.expect(globMatchIgnoreCase("App?.AppImage", "App1.AppImage"));
    try std.testing.expect(!globMatchIgnoreCase("Subsurface-*x86_64.AppImage.zsync", "Subsurface-5.0.10-aarch64.AppImage.zsync"));
    try std.testing.expect(!globMatchIgnoreCase("App-*.AppImage", "Other-1.0.AppImage"));
    try std.testing.expect(!globMatchIgnoreCase("App?.AppImage", "App12.AppImage"));
}
