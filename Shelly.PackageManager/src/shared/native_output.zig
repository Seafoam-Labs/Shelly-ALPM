//! Presentation contract shared by native backends. The historical alpm.*
//! identifiers and numeric codes are UI protocol values; no libalpm is linked.
const std = @import("std");

pub const EventType = enum(u32) {
    // libalpm events (1–37)
    checkdeps_start = 1,
    checkdeps_done = 2,
    fileconflicts_start = 3,
    fileconflicts_done = 4,
    resolvedeps_start = 5,
    resolvedeps_done = 6,
    interconflicts_start = 7,
    interconflicts_done = 8,
    transaction_start = 9,
    transaction_done = 10,
    package_operation_start = 11,
    package_operation_done = 12,
    integrity_start = 13,
    integrity_done = 14,
    load_start = 15,
    load_done = 16,
    scriptlet_info = 17,
    db_retrieve_start = 18,
    db_retrieve_done = 19,
    db_retrieve_failed = 20,
    pkg_retrieve_start = 21,
    pkg_retrieve_done = 22,
    pkg_retrieve_failed = 23,
    diskspace_start = 24,
    diskspace_done = 25,
    optdep_removal = 26,
    database_missing = 27,
    keyring_start = 28,
    keyring_done = 29,
    key_download_start = 30,
    key_download_done = 31,
    pacnew_created = 32,
    pacsave_created = 33,
    hook_start = 34,
    hook_done = 35,
    hook_run_start = 36,
    hook_run_done = 37,

    // Application-defined events (100+)
    download_start = 100,
    download_complete = 101,
    download_failed = 102,
    extraction_start = 103,
    extraction_complete = 104,
    extraction_failed = 105,
    validation_start = 106,
    validation_complete = 107,
    validation_failed = 108,
    transaction_preparing = 109,
    transaction_committing = 110,
    rollback_start = 111,
    rollback_complete = 112,

    // Custom events
    failed_optional_dependency_operation = 200,
    package_explicit = 201,
    failed_add_local_package = 202,
    nothing_to_do = 203,

    pub fn from_libalpm(c_type: c_int) EventType {
        return @enumFromInt(@as(u32, @intCast(c_type)));
    }

    pub fn to_libalpm(self: EventType) c_int {
        return @intCast(@intFromEnum(self));
    }

    pub fn is_libalpm(self: EventType) bool {
        const val = @intFromEnum(self);
        return val >= 1 and val <= 37;
    }

    pub fn is_custom(self: EventType) bool {
        return @intFromEnum(self) >= 100;
    }
};

pub fn information(event_type: EventType) ?[]const u8 {
    return switch (event_type) {
        .checkdeps_start => "Checking dependencies...",
        .checkdeps_done => "Dependency check finished.",
        .fileconflicts_start => "Checking for file conflicts...",
        .fileconflicts_done => "File conflict check finished.",
        .resolvedeps_start => "Resolving dependencies...",
        .resolvedeps_done => "Dependency resolution finished.",
        .interconflicts_start => "Checking for package conflicts...",
        .interconflicts_done => "Package conflict check finished.",
        .transaction_start => "Starting transaction...",
        .transaction_done => "Transaction completed.",
        .package_operation_done => "Package operation completed.",
        .integrity_start => "Checking package integrity...",
        .integrity_done => "Package integrity check finished.",
        .load_start => "Loading packages...",
        .load_done => "Packages loaded.",
        .db_retrieve_start => "Retrieving database...",
        .db_retrieve_done => "Database retrieved.",
        .db_retrieve_failed => "Could not download the selected repository database.",
        .pkg_retrieve_start => "Retrieving package...",
        .pkg_retrieve_done => "Package retrieved.",
        .pkg_retrieve_failed => "Could not download the requested package.",
        .diskspace_start => "Checking disk space...",
        .diskspace_done => "Disk space check finished.",
        .optdep_removal => "Removing optional dependencies...",
        .database_missing => "The selected repository database is missing. Refresh the configured package databases and try again.",
        .keyring_start => "Checking keyring...",
        .keyring_done => "Keyring check finished.",
        .key_download_start => "Downloading key...",
        .key_download_done => "Key download finished.",
        .hook_start => "Running hooks...",
        .hook_done => "Finished running hooks.",
        .hook_run_done => "Finished running hook.",
        .scriptlet_info, .pacnew_created, .pacsave_created, .hook_run_start => null,
        .failed_optional_dependency_operation => "Could not remove the selected optional dependency.",
        .package_explicit => "Package marked as explicitly installed.",
        .failed_add_local_package => "Could not add the selected local package archive to the transaction.",
        else => null,
    };
}

pub const PackageAction = enum(i64) {
    install = 0,
    upgrade = 1,
    downgrade = 2,
    reinstall = 3,
    remove = 4,

    pub fn completionCode(self: PackageAction) []const u8 {
        return switch (self) {
            .install => "alpm.package_installed",
            .upgrade => "alpm.package_upgraded",
            .downgrade => "alpm.package_downgraded",
            .reinstall => "alpm.package_reinstalled",
            .remove => "alpm.package_removed",
        };
    }
};

pub fn packageMessage(allocator: std.mem.Allocator, action: PackageAction, name: []const u8, version: []const u8, old_version: ?[]const u8) ![]u8 {
    return switch (action) {
        .install => std.fmt.allocPrint(allocator, "Installing package: {s}-{s}", .{ name, version }),
        .upgrade => std.fmt.allocPrint(allocator, "Upgrading package: {s} {s} -> {s}", .{ name, old_version orelse "?", version }),
        .downgrade => std.fmt.allocPrint(allocator, "Downgrading package: {s} {s} -> {s}", .{ name, old_version orelse "?", version }),
        .reinstall => std.fmt.allocPrint(allocator, "Reinstalling package: {s}-{s}", .{ name, version }),
        .remove => std.fmt.allocPrint(allocator, "Removing package: {s}-{s}", .{ name, version }),
    };
}

pub fn hookMessage(buffer: []u8, name: ?[]const u8, description: ?[]const u8, position: usize, total: usize) []const u8 {
    const label = description orelse name orelse "Running hook...";
    return std.fmt.bufPrint(buffer, "({d}/{d}) {s}", .{ position, total, label }) catch label;
}

pub fn progressLabel(code: ?i64) ?[]const u8 {
    return switch (code orelse return null) {
        0 => "Installing",
        1 => "Upgrading",
        2 => "Downgrading",
        3 => "Reinstalling",
        4 => "Removing",
        5 => "Checking file conflicts",
        6 => "Checking disk space",
        7 => "Checking package integrity",
        8 => "Loading packages",
        9 => "Checking keyring",
        100 => "Downloading package",
        101 => "Downloading database",
        else => null,
    };
}
