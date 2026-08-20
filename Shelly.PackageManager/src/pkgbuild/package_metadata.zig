const std = @import("std");

/// Package fields that makepkg permits package()/package_<name>() to
/// override. Keep this schema in one place so parsing, runtime capture, and
/// validation cannot silently drift apart.
pub const scalar_fields = [_][]const u8{
    "pkgdesc",
    "url",
    "install",
    "changelog",
};

pub const array_fields = [_][]const u8{
    "arch",
    "license",
    "groups",
    "depends",
    "optdepends",
    "provides",
    "conflicts",
    "replaces",
    "backup",
    "options",
};

/// Package-scoped arrays for which makepkg also consumes the active
/// architecture suffix after the package function returns.
pub const architecture_array_fields = [_][]const u8{
    "depends",
    "optdepends",
    "provides",
    "conflicts",
    "replaces",
    "options",
};

pub const captured_field_count = scalar_fields.len + array_fields.len + architecture_array_fields.len;

const pkgbuild_array_fields = [_][]const u8{
    "arch",     "backup",      "checkdepends", "conflicts",  "depends",    "groups",
    "license",  "makedepends", "noextract",    "optdepends", "options",    "provides",
    "replaces", "source",      "validpgpkeys", "xdata",      "cksums",     "md5sums",
    "sha1sums", "sha224sums",  "sha256sums",   "sha384sums", "sha512sums", "b2sums",
};

const pkgbuild_scalar_fields = [_][]const u8{
    "changelog", "epoch", "install", "pkgbase", "pkgdesc", "pkgrel",
    "pkgver",    "url",
};

pub fn isScalarField(name: []const u8) bool {
    return contains(&scalar_fields, name);
}

pub fn isArrayField(name: []const u8) bool {
    return contains(&array_fields, name);
}

pub fn isPackageOverride(name: []const u8) bool {
    return isScalarField(name) or isArrayField(name);
}

pub fn isForbiddenPackageAssignment(name: []const u8, carch: []const u8) bool {
    if (contains(&pkgbuild_scalar_fields, name) or contains(&pkgbuild_array_fields, name))
        return !isPackageOverride(name);
    if (name.len <= carch.len + 1) return false;
    const suffix_start = name.len - carch.len;
    if (name[suffix_start - 1] != '_' or
        !std.mem.eql(u8, name[suffix_start..], carch)) return false;
    const base = name[0 .. suffix_start - 1];
    if (!contains(&pkgbuild_array_fields, base)) return false;
    return !contains(&architecture_array_fields, base);
}

pub fn architectureBase(name: []const u8, carch: []const u8) ?[]const u8 {
    if (name.len <= carch.len + 1) return null;
    const suffix_start = name.len - carch.len;
    if (name[suffix_start - 1] != '_' or
        !std.mem.eql(u8, name[suffix_start..], carch)) return null;
    const base = name[0 .. suffix_start - 1];
    return if (contains(&architecture_array_fields, base)) base else null;
}

fn contains(comptime fields: anytype, name: []const u8) bool {
    for (fields) |field| if (std.mem.eql(u8, field, name)) return true;
    return false;
}

pub const Value = union(enum) {
    scalar: []const u8,
    array: [][]const u8,
};

pub const Entry = struct {
    name: []const u8,
    value: Value,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        switch (self.value) {
            .scalar => |value| allocator.free(value),
            .array => |values| {
                for (values) |value| allocator.free(value);
                allocator.free(values);
            },
        }
        self.* = undefined;
    }
};

pub fn decode(allocator: std.mem.Allocator, encoded: []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var cursor: usize = 0;
    while (cursor < encoded.len) {
        const kind = try nextField(encoded, &cursor);
        const raw_name = try nextField(encoded, &cursor);
        for (entries.items) |entry|
            if (std.mem.eql(u8, entry.name, raw_name)) return error.InvalidPackageMetadata;
        const name = try allocator.dupe(u8, raw_name);
        errdefer allocator.free(name);

        if (std.mem.eql(u8, kind, "S")) {
            const value = try allocator.dupe(u8, try nextField(encoded, &cursor));
            errdefer allocator.free(value);
            try entries.append(allocator, .{ .name = name, .value = .{ .scalar = value } });
            continue;
        }
        if (!std.mem.eql(u8, kind, "A")) return error.InvalidPackageMetadata;

        const count_text = try nextField(encoded, &cursor);
        const count = std.fmt.parseInt(usize, count_text, 10) catch
            return error.InvalidPackageMetadata;
        const values = try allocator.alloc([]const u8, count);
        var populated: usize = 0;
        errdefer {
            for (values[0..populated]) |value| allocator.free(value);
            allocator.free(values);
        }
        while (populated < count) : (populated += 1)
            values[populated] = try allocator.dupe(u8, try nextField(encoded, &cursor));
        try entries.append(allocator, .{ .name = name, .value = .{ .array = values } });
    }
    return entries.toOwnedSlice(allocator);
}

pub fn deinitEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |*entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn nextField(encoded: []const u8, cursor: *usize) ![]const u8 {
    if (cursor.* >= encoded.len) return error.InvalidPackageMetadata;
    const end = std.mem.indexOfScalarPos(u8, encoded, cursor.*, 0) orelse
        return error.InvalidPackageMetadata;
    const field = encoded[cursor.*..end];
    cursor.* = end + 1;
    return field;
}

/// Writes every supported field after a package function. Missing variables
/// are encoded as empty values so `unset` overrides inherited metadata rather
/// than being mistaken for "leave unchanged". A type mismatch emits X and is
/// rejected by decode().
pub const shell_capture_prelude =
    \\__shelly_capture_scalar() {
    \\  local name="$1" declaration
    \\  if declaration=$(declare -p "$name" 2>/dev/null); then
    \\    case "$declaration" in declare\ -a*|declare\ -A*) printf 'X\0%s\0' "$name"; return;; esac
    \\  fi
    \\  printf 'S\0%s\0%s\0' "$name" "${!name-}"
    \\}
    \\__shelly_capture_array() {
    \\  local name="$1" declaration
    \\  if ! declaration=$(declare -p "$name" 2>/dev/null); then
    \\    printf 'A\0%s\0%s\0' "$name" 0
    \\    return
    \\  fi
    \\  case "$declaration" in declare\ -a*) ;; *) printf 'X\0%s\0' "$name"; return;; esac
    \\  local -n values="$name"
    \\  printf 'A\0%s\0%s\0' "$name" "${#values[@]}"
    \\  if ((${#values[@]})); then printf '%s\0' "${values[@]}"; fi
    \\}
    \\__shelly_capture_metadata() {
    \\  local name
    \\  for name in pkgdesc url install changelog; do __shelly_capture_scalar "$name"; done
    \\  for name in arch license groups depends optdepends provides conflicts replaces backup options; do
    \\    __shelly_capture_array "$name"
    \\  done
    \\  for name in depends optdepends provides conflicts replaces options; do
    \\    __shelly_capture_array "${name}_${CARCH}"
    \\  done
    \\}
    \\readonly -f __shelly_capture_scalar __shelly_capture_array __shelly_capture_metadata
;

test "package metadata schema matches makepkg package overrides" {
    try std.testing.expect(isScalarField("install"));
    try std.testing.expect(isArrayField("backup"));
    try std.testing.expect(isPackageOverride("groups"));
    try std.testing.expect(!isPackageOverride("pkgver"));
    try std.testing.expect(isForbiddenPackageAssignment("pkgver", "x86_64"));
    try std.testing.expect(isForbiddenPackageAssignment("license_x86_64", "x86_64"));
    try std.testing.expect(!isForbiddenPackageAssignment("depends_x86_64", "x86_64"));
    try std.testing.expectEqualStrings("depends", architectureBase("depends_x86_64", "x86_64").?);
    try std.testing.expect(architectureBase("license_x86_64", "x86_64") == null);
}

test "package metadata decoder preserves empty and multiline values" {
    const encoded = "S\x00pkgdesc\x00line one\nline two\x00A\x00depends\x002\x00\x00glibc\x00";
    const entries = try decode(std.testing.allocator, encoded);
    defer deinitEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("line one\nline two", entries[0].value.scalar);
    try std.testing.expectEqualStrings("", entries[1].value.array[0]);
    try std.testing.expectEqualStrings("glibc", entries[1].value.array[1]);
}

test "package metadata decoder rejects type mismatch records" {
    try std.testing.expectError(
        error.InvalidPackageMetadata,
        decode(std.testing.allocator, "X\x00depends\x00"),
    );
}
