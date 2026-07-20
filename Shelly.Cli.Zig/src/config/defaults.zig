// Authoritative defaults for the native Zig CLI. Keep this schema stable so
// existing configuration files can be overlaid without migration tooling.
pub const json =
    \\{
    \\  "FileSizeDisplay": "Megabytes",
    \\  "DefaultExecution": "UpgradeAll",
    \\  "ParallelDownloadCount": 10,
    \\  "Culture": null,
    \\  "AurEnabled": false,
    \\  "ShellySearchEnabled": false,
    \\  "AurWarningConfirmed": false,
    \\  "FlatPackEnabled": false,
    \\  "WindowWidth": 800,
    \\  "WindowHeight": 600,
    \\  "DefaultView": "HomeScreen",
    \\  "UseOldMenu": false,
    \\  "TrayEnabled": true,
    \\  "TrayCheckIntervalHours": 72,
    \\  "NoConfirm": false,
    \\  "NewInstall": true,
    \\  "CurrentVersion": "0.0.0.0",
    \\  "UseWeeklySchedule": false,
    \\  "DaysOfWeek": [],
    \\  "Time": null,
    \\  "ShellyIconsEnabled": true,
    \\  "AppImageEnabled": false,
    \\  "NewInstallInitSettings": false,
    \\  "UseSymbolicTray": true,
    \\  "RemoveCache": false,
    \\  "TrayIconPath": null,
    \\  "TrayUpdatesIconPath": null,
    \\  "DefaultPageDropDown": "Packages",
    \\  "RecommendedEnabled": true,
    \\  "ProgressBarStyle": "Blocks",
    \\  "ProgressBarFps": 7,
    \\  "ProgressBarWidth": 24,
    \\  "OutputMode": "singlepane",
    \\  "SinglePaneMaxStickies": 6,
    \\  "TrayAutoStart": false,
    \\  "PackageDowngradeEnabled": false,
    \\  "PackageManagementCascadeDelete": true,
    \\  "PackageManagementRemoveConfigs": false,
    \\  "PackageManagementRemoveOptionalDeps": true,
    \\  "PackageManagementShowHidden": false,
    \\  "PackageInstallUpgrade": false,
    \\  "PackageInstallShowHidden": false,
    \\  "PackageUpdateShowHidden": false,
    \\  "AurInstallUseChroot": false,
    \\  "AurInstallRunChecks": false,
    \\  "AurRemoveCascadeDelete": true,
    \\  "AurRemoveShowHidden": false,
    \\  "AurUpdateRunChecks": false,
    \\  "AurUpdateShowHidden": false,
    \\  "AppImageInstallPath": null,
    \\  "StarFishEnabled": false,
    \\  "PackageInstallView": "List",
    \\  "PackageUpdateView": "List",
    \\  "PackageManageView": "List"
    \\}
;

test "native defaults remain valid JSON" {
    const std = @import("std");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqual(@as(i64, 10), parsed.value.object.get("ParallelDownloadCount").?.integer);
}
