//! Endpoint derivation for AUR-compatible services.

const std = @import("std");

pub const official_aur_base = "https://aur.archlinux.org";
pub const official_rpc_url = "https://aur.archlinux.org/rpc/";

/// Normalizes an AUR base URL by trimming whitespace and trailing slashes.
pub fn normalizeBase(allocator: std.mem.Allocator, base: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, base, " \t\r\n");
    const without_slashes = std.mem.trimEnd(u8, trimmed, "/");
    if (without_slashes.len == 0) return error.EmptyAurBaseUrl;
    return allocator.dupe(u8, without_slashes);
}

/// Derives the RPC endpoint URL from a normalized base.
pub fn rpcUrl(allocator: std.mem.Allocator, normalized_base: []const u8) ![]u8 {
    if (isOfficialBase(normalized_base)) return allocator.dupe(u8, official_rpc_url);
    return std.fmt.allocPrint(allocator, "{s}/rpc", .{normalized_base});
}

/// Derives the Git clone remote URL for a package base.
pub fn gitRemoteUrl(
    allocator: std.mem.Allocator,
    normalized_base: []const u8,
    package_base: []const u8,
) ![]u8 {
    if (!isValidPackageBase(package_base)) return error.InvalidAurPackageBase;
    return std.fmt.allocPrint(allocator, "{s}/{s}.git", .{ normalized_base, package_base });
}

/// Validates package base names against path traversal and special characters.
pub fn isValidPackageBase(package_base: []const u8) bool {
    if (package_base.len == 0 or package_base[0] == '.' or package_base[0] == '-') return false;
    for (package_base) |character| {
        if (std.ascii.isAlphanumeric(character)) continue;
        switch (character) {
            '@', '.', '_', '+', '-' => {},
            else => return false,
        }
    }
    return true;
}

/// Returns true if the base is the official AUR.
pub fn isOfficialBase(normalized_base: []const u8) bool {
    return std.mem.eql(u8, normalized_base, official_aur_base);
}

test "base normalization trims separators and rejects empty values" {
    const allocator = std.testing.allocator;

    const atoll = try normalizeBase(allocator, "https://atoll.seafoam-labs.org/");
    defer allocator.free(atoll);
    try std.testing.expectEqualStrings("https://atoll.seafoam-labs.org", atoll);

    const prefixed = try normalizeBase(allocator, " https://host/atoll/ ");
    defer allocator.free(prefixed);
    try std.testing.expectEqualStrings("https://host/atoll", prefixed);

    const local_root = try normalizeBase(allocator, "/tmp/fixture-remotes/");
    defer allocator.free(local_root);
    try std.testing.expectEqualStrings("/tmp/fixture-remotes", local_root);

    try std.testing.expectError(error.EmptyAurBaseUrl, normalizeBase(allocator, ""));
    try std.testing.expectError(error.EmptyAurBaseUrl, normalizeBase(allocator, "///"));
}

test "official base preserves the historical RPC endpoint and custom bases use /rpc" {
    const allocator = std.testing.allocator;

    const official = try normalizeBase(allocator, official_aur_base);
    defer allocator.free(official);
    const official_rpc = try rpcUrl(allocator, official);
    defer allocator.free(official_rpc);
    try std.testing.expectEqualStrings("https://aur.archlinux.org/rpc/", official_rpc);
    try std.testing.expect(isOfficialBase(official));

    const atoll = try normalizeBase(allocator, "https://atoll.seafoam-labs.org");
    defer allocator.free(atoll);
    const atoll_rpc = try rpcUrl(allocator, atoll);
    defer allocator.free(atoll_rpc);
    try std.testing.expectEqualStrings("https://atoll.seafoam-labs.org/rpc", atoll_rpc);
    try std.testing.expect(!isOfficialBase(atoll));

    const prefixed = try normalizeBase(allocator, "https://host/atoll");
    defer allocator.free(prefixed);
    const prefixed_rpc = try rpcUrl(allocator, prefixed);
    defer allocator.free(prefixed_rpc);
    try std.testing.expectEqualStrings("https://host/atoll/rpc", prefixed_rpc);

    const ported = try normalizeBase(allocator, "http://host:8080/");
    defer allocator.free(ported);
    const ported_rpc = try rpcUrl(allocator, ported);
    defer allocator.free(ported_rpc);
    try std.testing.expectEqualStrings("http://host:8080/rpc", ported_rpc);
}

test "git remote derivation appends only safe package bases" {
    const allocator = std.testing.allocator;
    const remote = try gitRemoteUrl(allocator, "https://host/atoll", "demo-suite+git@1");
    defer allocator.free(remote);
    try std.testing.expectEqualStrings("https://host/atoll/demo-suite+git@1.git", remote);

    try std.testing.expectError(error.InvalidAurPackageBase, gitRemoteUrl(allocator, "https://host/atoll", ""));
    try std.testing.expectError(error.InvalidAurPackageBase, gitRemoteUrl(allocator, "https://host/atoll", ".."));
    try std.testing.expectError(error.InvalidAurPackageBase, gitRemoteUrl(allocator, "https://host/atoll", ".git"));
    try std.testing.expectError(error.InvalidAurPackageBase, gitRemoteUrl(allocator, "https://host/atoll", ".hidden"));
    try std.testing.expectError(error.InvalidAurPackageBase, gitRemoteUrl(allocator, "https://host/atoll", "-option"));
    try std.testing.expectError(error.InvalidAurPackageBase, gitRemoteUrl(allocator, "https://host/atoll", "../outside"));
    try std.testing.expectError(error.InvalidAurPackageBase, gitRemoteUrl(allocator, "https://host/atoll", "/absolute"));
    try std.testing.expectError(error.InvalidAurPackageBase, gitRemoteUrl(allocator, "https://host/atoll", "nested/path"));
    try std.testing.expectError(error.InvalidAurPackageBase, gitRemoteUrl(allocator, "https://host/atoll", "nested\\path"));
}
