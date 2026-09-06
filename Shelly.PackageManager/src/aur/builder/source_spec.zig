//! Source entry parsing and classification for the PKGBUILD source= array.
//! Covers makepkg source URLs (local/http/git), rename prefixes, git references,
//! detached signature pairing, and archive-name safety checks.

const std = @import("std");

pub const SourceKind = enum { local, http, git };

pub const GitReferenceKind = enum { branch, tag, commit };

pub const GitReference = struct {
    kind: GitReferenceKind,
    value: []u8,

    pub fn deinit(self: GitReference, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

pub const ParsedSource = struct {
    name: []u8,
    location: []u8,
    kind: SourceKind,
    reference: ?GitReference = null,
    signed: bool = false,

    pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !ParsedSource {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidSource;
        const rename_separator = std.mem.indexOf(u8, trimmed, "::");
        const explicit_name = if (rename_separator) |separator| trimmed[0..separator] else null;
        const raw_location = if (rename_separator) |separator| trimmed[separator + 2 ..] else trimmed;
        if (raw_location.len == 0) return error.InvalidSource;

        const fragment_start = std.mem.indexOfScalar(u8, raw_location, '#');
        const query_start = std.mem.indexOfScalar(u8, raw_location, '?');
        const first_suffix = @min(fragment_start orelse raw_location.len, query_start orelse raw_location.len);
        const git_location = raw_location[0..first_suffix];
        const location_without_fragment = if (fragment_start) |index| raw_location[0..index] else raw_location;
        const has_git_prefix = std.ascii.startsWithIgnoreCase(git_location, "git+");
        const is_git = has_git_prefix or std.ascii.startsWithIgnoreCase(git_location, "git://");
        const kind: SourceKind = if (is_git)
            .git
        else if (std.ascii.startsWithIgnoreCase(location_without_fragment, "https://") or
            std.ascii.startsWithIgnoreCase(location_without_fragment, "http://") or
            std.ascii.startsWithIgnoreCase(location_without_fragment, "file://"))
            .http
        else if (std.mem.indexOf(u8, location_without_fragment, "://") != null)
            return error.UnsupportedSourceProtocol
        else
            .local;

        const effective_location = if (has_git_prefix)
            git_location["git+".len..]
        else if (is_git)
            git_location
        else if (kind == .http)
            location_without_fragment
        else
            raw_location;
        if (effective_location.len == 0) return error.InvalidSource;

        const inferred_name = if (explicit_name) |name|
            name
        else
            sourceBasename(effective_location, is_git);
        try validateSourceName(inferred_name);

        var reference: ?GitReference = null;
        errdefer if (reference) |value| value.deinit(allocator);
        if (fragment_start) |index| {
            if (!is_git) return error.UnsupportedSourceFragment;
            const fragment_end = if (query_start) |query| if (query > index) query else raw_location.len else raw_location.len;
            const fragment = raw_location[index + 1 .. fragment_end];
            const equals = std.mem.indexOfScalar(u8, fragment, '=') orelse return error.UnsupportedSourceFragment;
            const key = fragment[0..equals];
            const value = fragment[equals + 1 ..];
            if (value.len == 0) return error.InvalidSourceReference;
            const reference_kind: GitReferenceKind = if (std.ascii.eqlIgnoreCase(key, "branch"))
                .branch
            else if (std.ascii.eqlIgnoreCase(key, "tag"))
                .tag
            else if (std.ascii.eqlIgnoreCase(key, "commit"))
                .commit
            else
                return error.UnsupportedSourceFragment;
            reference = .{ .kind = reference_kind, .value = try allocator.dupe(u8, value) };
        }

        var signed = false;
        if (query_start) |index| {
            if (!is_git) {
                if (fragment_start != null and index > fragment_start.?) return error.UnsupportedSourceFragment;
            } else {
                const query_end = if (fragment_start) |fragment| if (fragment > index) fragment else raw_location.len else raw_location.len;
                const query = raw_location[index + 1 .. query_end];
                if (!std.mem.eql(u8, query, "signed")) return error.UnsupportedSourceQuery;
                signed = true;
            }
        }

        const name = try allocator.dupe(u8, inferred_name);
        errdefer allocator.free(name);
        const location = try allocator.dupe(u8, effective_location);
        errdefer allocator.free(location);
        return .{
            .name = name,
            .location = location,
            .kind = kind,
            .reference = reference,
            .signed = signed,
        };
    }

    pub fn deinit(self: *ParsedSource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.location);
        if (self.reference) |reference| reference.deinit(allocator);
        self.* = undefined;
    }
};

pub const PreparedSource = struct {
    source: ParsedSource,
    destination: []u8,
    index: usize,

    pub fn deinit(self: *PreparedSource, allocator: std.mem.Allocator) void {
        self.source.deinit(allocator);
        allocator.free(self.destination);
        self.* = undefined;
    }
};

pub const SignatureCompression = enum {
    gz,
    bz2,
    xz,
    lrz,
    lzo,
    compress,
    zst,

    fn suffix(self: SignatureCompression) []const u8 {
        return switch (self) {
            .gz => ".gz",
            .bz2 => ".bz2",
            .xz => ".xz",
            .lrz => ".lrz",
            .lzo => ".lzo",
            .compress => ".Z",
            .zst => ".zst",
        };
    }
};

pub const DetachedPayload = struct {
    source: *const PreparedSource,
    compression: ?SignatureCompression,
};

fn detachedSignatureBase(name: []const u8) ?[]const u8 {
    for ([_][]const u8{ ".sig", ".sign", ".asc" }) |extension| {
        if (std.mem.endsWith(u8, name, extension)) return name[0 .. name.len - extension.len];
    }
    return null;
}

pub fn isDetachedSignatureName(name: []const u8) bool {
    return detachedSignatureBase(name) != null;
}

pub fn findDetachedPayload(
    prepared: []const PreparedSource,
    signature: *const PreparedSource,
) !DetachedPayload {
    const base = detachedSignatureBase(signature.source.name) orelse return error.InvalidSignatureSource;
    var exact: ?*const PreparedSource = null;
    for (prepared) |*candidate| {
        if (candidate.index == signature.index or isDetachedSignatureName(candidate.source.name)) continue;
        if (!std.mem.eql(u8, candidate.source.name, base)) continue;
        if (exact != null) return error.AmbiguousSignedSource;
        exact = candidate;
    }
    if (exact) |source| return .{ .source = source, .compression = null };

    // makepkg tries compressed variants in this fixed order and stops at the
    // first one it finds. An uncompressed source above always wins.
    for (std.meta.tags(SignatureCompression)) |kind| {
        var match: ?*const PreparedSource = null;
        for (prepared) |*candidate| {
            if (candidate.index == signature.index or isDetachedSignatureName(candidate.source.name)) continue;
            if (candidate.source.name.len != base.len + kind.suffix().len or
                !std.mem.startsWith(u8, candidate.source.name, base) or
                !std.mem.endsWith(u8, candidate.source.name, kind.suffix())) continue;
            if (match != null) return error.AmbiguousSignedSource;
            match = candidate;
        }
        if (match) |source| return .{ .source = source, .compression = kind };
    }
    return error.MissingSignedSource;
}

fn sourceBasename(location: []const u8, strip_git_suffix: bool) []const u8 {
    const query_start = std.mem.indexOfScalar(u8, location, '?') orelse location.len;
    const without_query = std.mem.trimEnd(u8, location[0..query_start], "/");
    const basename = std.fs.path.basename(without_query);
    if (strip_git_suffix and std.mem.endsWith(u8, basename, ".git")) return basename[0 .. basename.len - ".git".len];
    return basename;
}

fn validateSourceName(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.fs.path.isAbsolute(name) or std.mem.indexOfAny(u8, name, "/\\\r\n\x00") != null)
        return error.InvalidSourceName;
}

pub fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

/// Returns the target text that may safely be materialized in the extraction
/// tree. The caller owns the returned slice. Archive-absolute targets are
/// interpreted relative to the archive root and rewritten as relative links
/// so they can never resolve into the host filesystem.
pub fn archiveLinkTarget(
    allocator: std.mem.Allocator,
    entry_path: []const u8,
    target: []const u8,
) ![]u8 {
    if (target.len == 0 or std.mem.indexOfAny(u8, target, "\\\r\n\x00") != null)
        return error.UnsafeSourceArchiveLink;

    var entry_depth: usize = 0;
    if (entry_path.len == 0 or
        std.fs.path.isAbsolute(entry_path) or
        std.mem.indexOfAny(u8, entry_path, "\\\r\n\x00") != null)
        return error.UnsafeSourceArchiveLink;
    var entry_components = std.mem.splitScalar(u8, entry_path, '/');
    while (entry_components.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return error.UnsafeSourceArchiveLink;
        entry_depth += 1;
    }
    if (entry_depth == 0) return error.UnsafeSourceArchiveLink;
    const parent_depth = entry_depth - 1;

    if (!std.fs.path.isAbsolute(target)) {
        // Relative targets are interpreted from the link's parent. Track
        // lexical depth so ordinary links such as bin/tool -> ../lib/tool are
        // accepted while traversal above the archive root remains impossible.
        var depth = parent_depth;
        var components = std.mem.splitScalar(u8, target, '/');
        while (components.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
            if (!std.mem.eql(u8, component, "..")) {
                depth += 1;
                continue;
            }
            if (depth == 0) return error.UnsafeSourceArchiveLink;
            depth -= 1;
        }
        return allocator.dupe(u8, target);
    }

    // Absolute targets in package source archives describe paths inside the
    // archive's eventual filesystem root. Canonicalize that rooted path, then
    // express it relative to the link entry before creating it in staging.
    var rooted_components: std.ArrayList([]const u8) = .empty;
    defer rooted_components.deinit(allocator);
    var components = std.mem.splitScalar(u8, target, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (rooted_components.items.len == 0) return error.UnsafeSourceArchiveLink;
            _ = rooted_components.pop();
            continue;
        }
        try rooted_components.append(allocator, component);
    }

    var rewritten: std.ArrayList(u8) = .empty;
    errdefer rewritten.deinit(allocator);
    for (0..parent_depth) |_| try appendArchiveLinkComponent(&rewritten, allocator, "..");
    for (rooted_components.items) |component| try appendArchiveLinkComponent(&rewritten, allocator, component);
    if (rewritten.items.len == 0) try rewritten.append(allocator, '.');
    return rewritten.toOwnedSlice(allocator);
}

fn appendArchiveLinkComponent(
    target: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    component: []const u8,
) !void {
    if (target.items.len != 0) try target.append(allocator, '/');
    try target.appendSlice(allocator, component);
}

test "signed Git source parser accepts query before or after fragment" {
    for ([_][]const u8{
        "git+https://example.invalid/demo.git?signed#tag=v1",
        "git+https://example.invalid/demo.git#tag=v1?signed",
    }) |raw| {
        var source = try ParsedSource.parse(std.testing.allocator, raw);
        defer source.deinit(std.testing.allocator);
        try std.testing.expect(source.signed);
        try std.testing.expectEqual(SourceKind.git, source.kind);
        try std.testing.expectEqualStrings("https://example.invalid/demo.git", source.location);
        try std.testing.expectEqual(GitReferenceKind.tag, source.reference.?.kind);
        try std.testing.expectEqualStrings("v1", source.reference.?.value);
    }
}

test "bare Git protocol source parser preserves location and supports metadata" {
    var plain = try ParsedSource.parse(std.testing.allocator, "git://example.invalid/demo.git");
    defer plain.deinit(std.testing.allocator);
    try std.testing.expectEqual(SourceKind.git, plain.kind);
    try std.testing.expectEqualStrings("git://example.invalid/demo.git", plain.location);
    try std.testing.expectEqualStrings("demo", plain.name);
    try std.testing.expectEqual(@as(?GitReference, null), plain.reference);
    try std.testing.expect(!plain.signed);

    var annotated = try ParsedSource.parse(
        std.testing.allocator,
        "renamed::git://example.invalid/demo.git?signed#commit=0123456789abcdef",
    );
    defer annotated.deinit(std.testing.allocator);
    try std.testing.expectEqual(SourceKind.git, annotated.kind);
    try std.testing.expectEqualStrings("git://example.invalid/demo.git", annotated.location);
    try std.testing.expectEqualStrings("renamed", annotated.name);
    try std.testing.expectEqual(GitReferenceKind.commit, annotated.reference.?.kind);
    try std.testing.expectEqualStrings("0123456789abcdef", annotated.reference.?.value);
    try std.testing.expect(annotated.signed);
}

test "detached source pairing handles exact renamed and compressed payload names" {
    const names = [_][]const u8{ "release.tar.xz", "release.tar.sign" };
    var prepared: [2]PreparedSource = undefined;
    var initialized: usize = 0;
    defer for (prepared[0..initialized]) |*source| source.deinit(std.testing.allocator);
    for (names, &prepared, 0..) |name, *source, index| {
        source.* = .{
            .source = .{
                .name = try std.testing.allocator.dupe(u8, name),
                .location = try std.testing.allocator.dupe(u8, name),
                .kind = .local,
            },
            .destination = try std.testing.allocator.dupe(u8, name),
            .index = index,
        };
        initialized += 1;
    }
    const pairing = try findDetachedPayload(&prepared, &prepared[1]);
    try std.testing.expectEqual(@as(usize, 0), pairing.source.index);
    try std.testing.expectEqual(SignatureCompression.xz, pairing.compression.?);

    const exact_source: PreparedSource = blk: {
        const name = try std.testing.allocator.dupe(u8, "release.tar");
        errdefer std.testing.allocator.free(name);
        const location = try std.testing.allocator.dupe(u8, "release.tar");
        errdefer std.testing.allocator.free(location);
        const destination = try std.testing.allocator.dupe(u8, "release.tar");
        errdefer std.testing.allocator.free(destination);
        break :blk .{
            .source = .{ .name = name, .location = location, .kind = .local },
            .destination = destination,
            .index = 2,
        };
    };
    var with_exact = [_]PreparedSource{ prepared[0], prepared[1], exact_source };
    defer with_exact[2].deinit(std.testing.allocator);
    const exact_pairing = try findDetachedPayload(&with_exact, &with_exact[1]);
    try std.testing.expectEqual(@as(usize, 2), exact_pairing.source.index);
    try std.testing.expectEqual(@as(?SignatureCompression, null), exact_pairing.compression);
}

test "sourceBasename strips query, trailing slash, and git suffix" {
    try std.testing.expectEqualStrings("pkg-1.0.tar.gz", sourceBasename("https://example.invalid/dir/pkg-1.0.tar.gz?v=1", false));
    try std.testing.expectEqualStrings("repo", sourceBasename("https://example.invalid/repo.git/", true));
    try std.testing.expectEqualStrings("repo.git", sourceBasename("https://example.invalid/repo.git", false));
    try std.testing.expectEqualStrings("local.patch", sourceBasename("local.patch", false));
}

test "validateSourceName rejects unsafe names" {
    try std.testing.expectError(error.InvalidSourceName, validateSourceName(""));
    try std.testing.expectError(error.InvalidSourceName, validateSourceName("."));
    try std.testing.expectError(error.InvalidSourceName, validateSourceName(".."));
    try std.testing.expectError(error.InvalidSourceName, validateSourceName("/absolute/path"));
    try std.testing.expectError(error.InvalidSourceName, validateSourceName("dir/file"));
    try std.testing.expectError(error.InvalidSourceName, validateSourceName("back\\slash"));
    try validateSourceName("valid-name.tar.gz");
}

test "archiveLinkTarget contains relative traversal and rebases absolute targets" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { entry: []const u8, target: []const u8, expected: []const u8 }{
        .{ .entry = "bin/tool", .target = "../lib/tool", .expected = "../lib/tool" },
        .{ .entry = "usr/bin/tool", .target = "../../lib/tool", .expected = "../../lib/tool" },
        .{ .entry = "bin/tool", .target = "./sub/../target", .expected = "./sub/../target" },
        .{ .entry = "tool", .target = ".", .expected = "." },
        .{ .entry = "usr/bin/zoom", .target = "/opt/zoom/ZoomLauncher", .expected = "../../opt/zoom/ZoomLauncher" },
        .{ .entry = "zoom", .target = "/opt/zoom/ZoomLauncher", .expected = "opt/zoom/ZoomLauncher" },
        .{ .entry = "usr/bin/root", .target = "/", .expected = "../.." },
        .{ .entry = "usr/bin/tool", .target = "/opt/../lib/tool", .expected = "../../lib/tool" },
    };
    for (cases) |case| {
        const actual = try archiveLinkTarget(allocator, case.entry, case.target);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }

    try std.testing.expectError(error.UnsafeSourceArchiveLink, archiveLinkTarget(allocator, "bin/tool", "../../escape"));
    try std.testing.expectError(error.UnsafeSourceArchiveLink, archiveLinkTarget(allocator, "tool", "../escape"));
    try std.testing.expectError(error.UnsafeSourceArchiveLink, archiveLinkTarget(allocator, "bin/tool", "/../../etc/passwd"));
    try std.testing.expectError(error.UnsafeSourceArchiveLink, archiveLinkTarget(allocator, "bin/tool", "a\\b"));
    try std.testing.expectError(error.UnsafeSourceArchiveLink, archiveLinkTarget(allocator, "bin/tool", "line\nbreak"));
    try std.testing.expectError(error.UnsafeSourceArchiveLink, archiveLinkTarget(allocator, "bin/tool", ""));
}

test "detached signature naming" {
    try std.testing.expect(isDetachedSignatureName("pkg.tar.gz.sig"));
    try std.testing.expect(isDetachedSignatureName("pkg.asc"));
    try std.testing.expect(isDetachedSignatureName("pkg.sign"));
    try std.testing.expect(!isDetachedSignatureName("pkg.tar.gz"));
    try std.testing.expectEqualStrings("pkg.tar.gz", detachedSignatureBase("pkg.tar.gz.sig").?);
    try std.testing.expect(detachedSignatureBase("pkg.tar.gz") == null);
}

test "source parser classifies http and local sources and rejects unknown protocols" {
    var http = try ParsedSource.parse(std.testing.allocator, "https://example.invalid/files/pkg-1.0.tar.gz");
    defer http.deinit(std.testing.allocator);
    try std.testing.expectEqual(SourceKind.http, http.kind);
    try std.testing.expectEqualStrings("pkg-1.0.tar.gz", http.name);
    try std.testing.expectEqualStrings("https://example.invalid/files/pkg-1.0.tar.gz", http.location);
    try std.testing.expect(!http.signed);

    var local = try ParsedSource.parse(std.testing.allocator, "renamed::local-file.patch");
    defer local.deinit(std.testing.allocator);
    try std.testing.expectEqual(SourceKind.local, local.kind);
    try std.testing.expectEqualStrings("renamed", local.name);
    try std.testing.expectEqualStrings("local-file.patch", local.location);

    try std.testing.expectError(error.UnsupportedSourceProtocol, ParsedSource.parse(std.testing.allocator, "ftp://example.invalid/x"));
}
