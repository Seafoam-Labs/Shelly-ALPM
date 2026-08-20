//! Package metadata helpers: pkgver validation, makepkg option merging, and
//! application of runtime-captured package metadata onto parsed PKGBUILDs.

const std = @import("std");
const package_metadata = @import("../../pkgbuild/package_metadata.zig");
const pkgbuild_parser = @import("../../pkgbuild/pkgbuild_parser.zig");
const PackageBuilder = @import("builder.zig").PackageBuilder;
const PackageBuild = pkgbuild_parser.Pkgbuild;

/// Mirrors makepkg's pkgver restrictions: the value must be non-empty ASCII
/// and cannot contain colons, slashes, hyphens, or whitespace.
pub fn validatePkgver(version: []const u8) !void {
    if (version.len == 0) return error.InvalidPackageVersion;
    for (version) |byte| {
        if (byte == 0 or !std.ascii.isAscii(byte) or std.ascii.isWhitespace(byte) or
            byte == ':' or byte == '/' or byte == '-')
        {
            return error.InvalidPackageVersion;
        }
    }
}

fn replaceOptionalString(
    allocator: std.mem.Allocator,
    destination: *?[]const u8,
    value: []const u8,
) !void {
    const owned = try allocator.dupe(u8, value);
    if (destination.*) |old| allocator.free(old);
    destination.* = owned;
}

fn replaceOptionalFileName(
    allocator: std.mem.Allocator,
    destination: *?[]const u8,
    value: []const u8,
) !void {
    if (value.len == 0) {
        if (destination.*) |old| allocator.free(old);
        destination.* = null;
        return;
    }
    try replaceOptionalString(allocator, destination, value);
}

pub fn reviewedAuxiliarySelectionMatches(
    approved: ?[]const u8,
    runtime: ?[]const u8,
) bool {
    const selected = runtime orelse return true;
    const expected = approved orelse return false;
    return std.mem.eql(u8, expected, selected);
}

fn updateOptionalStrings(
    allocator: std.mem.Allocator,
    destination: *?[][]const u8,
    values: []const []const u8,
    append: bool,
) !void {
    const old = if (append) destination.* orelse &.{} else &.{};
    const combined = try allocator.alloc([]const u8, old.len + values.len);
    var populated: usize = 0;
    errdefer {
        for (combined[0..populated]) |value| allocator.free(value);
        allocator.free(combined);
    }
    for (old) |value| {
        combined[populated] = try allocator.dupe(u8, value);
        populated += 1;
    }
    for (values) |value| {
        combined[populated] = try allocator.dupe(u8, value);
        populated += 1;
    }
    if (destination.*) |previous| {
        for (previous) |value| allocator.free(value);
        allocator.free(previous);
    }
    destination.* = combined;
}

pub fn freeOwnedStrings(allocator: std.mem.Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn duplicateOwnedStrings(allocator: std.mem.Allocator, values: []const []const u8) ![][]u8 {
    const duplicated = try allocator.alloc([]u8, values.len);
    var count: usize = 0;
    errdefer {
        for (duplicated[0..count]) |value| allocator.free(value);
        allocator.free(duplicated);
    }
    for (values, duplicated) |value, *destination| {
        destination.* = try allocator.dupe(u8, value);
        count += 1;
    }
    return duplicated;
}

fn optionName(value: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, value, "!")) value[1..] else value;
}

pub fn optionEnabled(options: []const []u8, name: []const u8) bool {
    for (options) |option| {
        if (!std.mem.eql(u8, optionName(option), name)) continue;
        return !std.mem.startsWith(u8, option, "!");
    }
    return false;
}

pub fn optionExplicitlyDisabled(options: []const []u8, name: []const u8) bool {
    for (options) |option| {
        if (std.mem.eql(u8, optionName(option), name))
            return std.mem.startsWith(u8, option, "!");
    }
    return false;
}

pub fn effectivePackageOptions(
    allocator: std.mem.Allocator,
    configured: []const []const u8,
    overrides: []const []const u8,
) ![][]u8 {
    var options = try duplicateOwnedStrings(allocator, configured);
    errdefer freeOwnedStrings(allocator, options);
    for (overrides) |override| {
        if (override.len == 0 or std.mem.eql(u8, override, "!")) continue;
        var replaced = false;
        for (options) |*current| {
            if (!std.mem.eql(u8, optionName(current.*), optionName(override))) continue;
            const owned = try allocator.dupe(u8, override);
            allocator.free(current.*);
            current.* = owned;
            replaced = true;
            break;
        }
        if (!replaced) {
            const owned = try allocator.dupe(u8, override);
            errdefer allocator.free(owned);
            const resized = try allocator.realloc(options, options.len + 1);
            options = resized;
            options[options.len - 1] = owned;
        }
    }
    return options;
}

pub fn applyPackageMetadata(
    self: *PackageBuilder,
    package_name: []const u8,
    encoded: []const u8,
) !void {
    const package_build = for (self.package_builds) |*candidate| {
        const name = candidate.pkg_name orelse continue;
        if (std.mem.eql(u8, name, package_name)) break candidate;
    } else return error.MissingPackageName;

    const entries = try package_metadata.decode(self.allocator, encoded);
    defer package_metadata.deinitEntries(self.allocator, entries);
    if (entries.len != package_metadata.captured_field_count)
        return error.InvalidPackageMetadata;

    // Base values are authoritative first. Architecture-specific values
    // are appended in a second pass, matching makepkg's merge_arch_attrs.
    for (entries) |entry| {
        if (package_metadata.architectureBase(entry.name, self.shellybuild_config.build.carch) != null)
            continue;
        try applyPackageMetadataEntry(self, package_build, entry, false);
    }
    for (entries) |entry| {
        const base = package_metadata.architectureBase(entry.name, self.shellybuild_config.build.carch) orelse
            continue;
        var effective = entry;
        effective.name = base;
        try applyPackageMetadataEntry(self, package_build, effective, true);
    }
}

fn applyPackageMetadataEntry(
    self: *PackageBuilder,
    package_build: *PackageBuild,
    entry: package_metadata.Entry,
    append: bool,
) !void {
    if (package_metadata.isScalarField(entry.name)) {
        if (append) return error.InvalidPackageMetadata;
        const value = switch (entry.value) {
            .scalar => |scalar| scalar,
            .array => return error.InvalidPackageMetadata,
        };
        if (std.mem.eql(u8, entry.name, "pkgdesc"))
            try replaceOptionalString(self.allocator, &package_build.pkg_desc, value)
        else if (std.mem.eql(u8, entry.name, "url"))
            try replaceOptionalString(self.allocator, &package_build.url, value)
        else if (std.mem.eql(u8, entry.name, "install"))
            try replaceOptionalFileName(self.allocator, &package_build.install_file, value)
        else if (std.mem.eql(u8, entry.name, "changelog"))
            try replaceOptionalFileName(self.allocator, &package_build.changelog_file, value)
        else
            return error.InvalidPackageMetadata;
        return;
    }

    if (!package_metadata.isArrayField(entry.name)) return error.InvalidPackageMetadata;
    const values = switch (entry.value) {
        .array => |array| array,
        .scalar => return error.InvalidPackageMetadata,
    };
    if (std.mem.eql(u8, entry.name, "license"))
        try updateOptionalStrings(self.allocator, &package_build.license, values, append)
    else if (std.mem.eql(u8, entry.name, "groups"))
        try updateOptionalStrings(self.allocator, &package_build.groups, values, append)
    else if (std.mem.eql(u8, entry.name, "arch") and !append and values.len == 0)
        return
    else if (std.mem.eql(u8, entry.name, "arch"))
        try updateOptionalStrings(self.allocator, &package_build.arch, values, append)
    else if (std.mem.eql(u8, entry.name, "depends")) {
        try updateOptionalStrings(self.allocator, &package_build.depends, values, append);
        if (package_build.parsed_depends) |dependencies| {
            for (dependencies) |dependency| dependency.deinit(self.allocator);
            self.allocator.free(dependencies);
        }
        package_build.parsed_depends = null;
    } else if (std.mem.eql(u8, entry.name, "optdepends"))
        try updateOptionalStrings(self.allocator, &package_build.opt_depends, values, append)
    else if (std.mem.eql(u8, entry.name, "provides"))
        try updateOptionalStrings(self.allocator, &package_build.provides, values, append)
    else if (std.mem.eql(u8, entry.name, "conflicts"))
        try updateOptionalStrings(self.allocator, &package_build.conflicts, values, append)
    else if (std.mem.eql(u8, entry.name, "replaces"))
        try updateOptionalStrings(self.allocator, &package_build.replaces, values, append)
    else if (std.mem.eql(u8, entry.name, "backup"))
        try updateOptionalStrings(self.allocator, &package_build.backup, values, append)
    else if (std.mem.eql(u8, entry.name, "options"))
        try updateOptionalStrings(self.allocator, &package_build.options, values, append)
    else
        return error.InvalidPackageMetadata;
}

test "validatePkgver enforces makepkg character rules" {
    try validatePkgver("1.2.3.r4.g5abc6de");
    try std.testing.expectError(error.InvalidPackageVersion, validatePkgver(""));
    try std.testing.expectError(error.InvalidPackageVersion, validatePkgver("1:2"));
    try std.testing.expectError(error.InvalidPackageVersion, validatePkgver("1-2"));
    try std.testing.expectError(error.InvalidPackageVersion, validatePkgver("1/2"));
    try std.testing.expectError(error.InvalidPackageVersion, validatePkgver("1 2"));
}

test "option helpers honor bang-prefixed disables" {
    const strip = try std.testing.allocator.dupe(u8, "strip");
    defer std.testing.allocator.free(strip);
    const docs = try std.testing.allocator.dupe(u8, "!docs");
    defer std.testing.allocator.free(docs);
    const staticlibs = try std.testing.allocator.dupe(u8, "staticlibs");
    defer std.testing.allocator.free(staticlibs);
    var options = [_][]u8{ strip, docs, staticlibs };
    try std.testing.expect(optionEnabled(&options, "strip"));
    try std.testing.expect(!optionEnabled(&options, "docs"));
    try std.testing.expect(!optionEnabled(&options, "missing"));
    try std.testing.expect(optionExplicitlyDisabled(&options, "docs"));
    try std.testing.expect(!optionExplicitlyDisabled(&options, "strip"));
    try std.testing.expect(!optionExplicitlyDisabled(&options, "missing"));
}

test "effectivePackageOptions overrides configured values and appends new ones" {
    const configured = [_][]const u8{ "strip", "docs" };
    const overrides = [_][]const u8{ "!strip", "lto" };
    const effective = try effectivePackageOptions(std.testing.allocator, &configured, &overrides);
    defer freeOwnedStrings(std.testing.allocator, effective);
    try std.testing.expectEqual(@as(usize, 3), effective.len);
    try std.testing.expectEqualStrings("!strip", effective[0]);
    try std.testing.expectEqualStrings("docs", effective[1]);
    try std.testing.expectEqualStrings("lto", effective[2]);
}

test "reviewedAuxiliarySelectionMatches truth table" {
    try std.testing.expect(reviewedAuxiliarySelectionMatches(null, null));
    try std.testing.expect(reviewedAuxiliarySelectionMatches("a.install", "a.install"));
    try std.testing.expect(!reviewedAuxiliarySelectionMatches("a.install", "b.install"));
    try std.testing.expect(!reviewedAuxiliarySelectionMatches(null, "b.install"));
    try std.testing.expect(reviewedAuxiliarySelectionMatches("a.install", null));
}

test "updateOptionalStrings replaces and appends" {
    var target: ?[][]const u8 = null;
    try updateOptionalStrings(std.testing.allocator, &target, &.{"one"}, false);
    try updateOptionalStrings(std.testing.allocator, &target, &.{"two"}, true);
    try std.testing.expectEqual(@as(usize, 2), target.?.len);
    try std.testing.expectEqualStrings("one", target.?[0]);
    try std.testing.expectEqualStrings("two", target.?[1]);
    try updateOptionalStrings(std.testing.allocator, &target, &.{"only"}, false);
    try std.testing.expectEqual(@as(usize, 1), target.?.len);
    try std.testing.expectEqualStrings("only", target.?[0]);
    if (target) |values| {
        for (values) |value| std.testing.allocator.free(value);
        std.testing.allocator.free(values);
    }
}
