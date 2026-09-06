// Authoritative defaults for the native Zig CLI. Keep this schema stable so
// existing configuration files can be overlaid without migration tooling.
pub const json =
    \\{
    \\  "FileSizeDisplay": "Megabytes",
    \\  "ParallelDownloadCount": 10,
    \\  "DownloadAddressFamilyPolicy": "PreferIPv4",
    \\  "ProgressBarStyle": "Blocks",
    \\  "ProgressBarWidth": 24,
    \\  "OutputMode": "singlepane",
    \\  "AppImageInstallPath": null,
    \\  "AutoConfirmCacheClean": false,
    \\  "DisableCacheClean": false,
    \\  "AurUrl": "https://aur.archlinux.org"
    \\}
;

test "native defaults remain valid JSON" {
    const std = @import("std");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqual(@as(i64, 10), parsed.value.object.get("ParallelDownloadCount").?.integer);
    try std.testing.expectEqualStrings(
        "PreferIPv4",
        parsed.value.object.get("DownloadAddressFamilyPolicy").?.string,
    );
    try std.testing.expect(!parsed.value.object.get("AutoConfirmCacheClean").?.bool);
    try std.testing.expect(!parsed.value.object.get("DisableCacheClean").?.bool);
}
