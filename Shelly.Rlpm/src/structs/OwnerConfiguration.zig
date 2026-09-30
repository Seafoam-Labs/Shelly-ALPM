//! Borrowed configuration input. Owner copies all strings/lists; callback contexts
//! remain borrowed. Runtime effects are documented in options.md.
const std = @import("std");
const SignaturePolicy = @import("SignaturePolicy.zig");
const PackageRelation = @import("PackageRelation.zig");
const Callbacks = @import("Callbacks.zig");
const Backend = @import("Backend.zig");
const Verification = @import("Verification.zig");
const transport = @import("Shelly_Download");

const OwnerConfiguration = @This();

root: []const u8,
database_path: []const u8,
/// Create an absent/empty local database as libalpm does; read_only never writes.
local_database_mode: Backend.Mode = .create,
cache_directories: []const []const u8 = &.{},
/// null selects <root>/usr/share/libalpm/hooks; an empty list disables discovery.
hook_directories: ?[]const []const u8 = null,
gpg_directory: ?[]const u8 = null,
key_acquisition: Verification.KeyAcquisition = .{},
log_file: ?[]const u8 = null,
use_syslog: bool = false,
architectures: []const []const u8 = &.{},
ignore_packages: []const []const u8 = &.{},
ignore_groups: []const []const u8 = &.{},
assume_installed: []const PackageRelation = &.{},
no_upgrade: []const []const u8 = &.{},
no_extract: []const []const u8 = &.{},
overwrite_files: []const []const u8 = &.{},
database_extension: []const u8 = ".db",
check_space: bool = false,
/// libalpm handle defaults; pacman.conf policy is supplied by PackageManager.
default_signature_policy: SignaturePolicy = disabled_signatures,
local_file_signature_policy: ?SignaturePolicy = disabled_signatures,
remote_file_signature_policy: ?SignaturePolicy = disabled_signatures,
disable_download_timeout: bool = false,
parallel_downloads: u32 = 1,
address_family_policy: transport.AddressFamilyPolicy = .prefer_ipv4,
sandbox_user: ?[]const u8 = null,
/// Absolute executable implementing Workers.dispatch; null re-executes this process.
worker_executable: ?[]const u8 = null,
sandbox: Sandbox = .{},
callbacks: Callbacks = .{},

pub const disabled_signatures: SignaturePolicy = .{ .package = .disabled, .database = .disabled };

pub const StringList = enum {
    cache_directories,
    hook_directories,
    architectures,
    ignore_packages,
    ignore_groups,
    no_upgrade,
    no_extract,
    overwrite_files,
};

pub const Sandbox = struct {
    disable_filesystem: bool = false,
    disable_syscalls: bool = false,
    disable_network: bool = false,

    /// CachyOS's global setter changes all three independent switches.
    pub fn setDisabled(self: *Sandbox, disabled: bool) void {
        self.* = .{
            .disable_filesystem = disabled,
            .disable_syscalls = disabled,
            .disable_network = disabled,
        };
    }

    /// The pinned legacy aggregate getter counts filesystem/syscall only.
    pub fn legacyDisabledState(self: Sandbox) u2 {
        return @as(u2, @intFromBool(self.disable_filesystem)) + @as(u2, @intFromBool(self.disable_syscalls));
    }
};

pub fn effectiveLocalSignaturePolicy(self: OwnerConfiguration) SignaturePolicy {
    return self.local_file_signature_policy orelse self.default_signature_policy;
}

pub fn effectiveRemoteSignaturePolicy(self: OwnerConfiguration) SignaturePolicy {
    return self.remote_file_signature_policy orelse self.default_signature_policy;
}

pub fn list(self: OwnerConfiguration, comptime field: StringList) []const []const u8 {
    return if (field == .hook_directories)
        self.hook_directories orelse &.{}
    else
        @field(self, @tagName(field));
}

/// The allocator must be an enclosing arena; Owner uses a candidate arena so
/// failed copies never publish partial configuration or leak replaced options.
pub fn copy(self: OwnerConfiguration, allocator: std.mem.Allocator, io: std.Io) !OwnerConfiguration {
    if (self.parallel_downloads == 0) return error.InvalidOption;
    try validateString(self.database_extension, true);
    if (std.mem.indexOfScalar(u8, self.database_extension, '/') != null) return error.InvalidOption;
    var result = self;
    result.root = try existingDirectory(allocator, io, self.root);
    result.database_path = try existingDirectory(allocator, io, self.database_path);
    result.database_extension = try allocator.dupe(u8, self.database_extension);
    inline for (.{
        "cache_directories",
        "architectures",
        "ignore_packages",
        "ignore_groups",
        "no_upgrade",
        "no_extract",
        "overwrite_files",
    }) |field| {
        @field(result, field) = try copyStrings(
            allocator,
            @field(self, field),
            std.mem.eql(u8, field, "cache_directories"),
        );
    }
    result.hook_directories = if (self.hook_directories) |paths|
        try copyStrings(allocator, paths, true)
    else blk: {
        const paths = try allocator.alloc([]const u8, 1);
        paths[0] = try std.fmt.allocPrint(allocator, "{s}usr/share/libalpm/hooks/", .{result.root});
        break :blk paths;
    };
    result.gpg_directory = if (self.gpg_directory) |path| try directoryString(allocator, path) else null;
    result.key_acquisition.key_files = try copyStrings(allocator, self.key_acquisition.key_files, false);
    result.key_acquisition.keyserver = try copyOptional(allocator, self.key_acquisition.keyserver);
    result.log_file = try copyOptional(allocator, self.log_file);
    if (self.worker_executable) |path| {
        try validateString(path, false);
        if (!std.fs.path.isAbsolute(path)) return error.InvalidOption;
    }
    result.worker_executable = try copyOptional(allocator, self.worker_executable);
    result.sandbox_user = try copyOptional(allocator, self.sandbox_user);
    const assumed = try allocator.alloc(PackageRelation, self.assume_installed.len);
    for (self.assume_installed, assumed) |relation, *owned| {
        if (relation.constraint != .any and relation.constraint != .equal) return error.InvalidOption;
        try validateString(relation.name, true);
        owned.* = try relation.clone(allocator);
    }
    result.assume_installed = assumed;
    return result;
}

pub fn validateString(value: []const u8, allow_empty: bool) !void {
    if ((!allow_empty and value.len == 0) or std.mem.indexOfScalar(u8, value, 0) != null)
        return error.InvalidOption;
}

pub fn directoryString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    validateString(value, false) catch return error.InvalidPath;
    return if (std.mem.endsWith(u8, value, "/"))
        allocator.dupe(u8, value)
    else
        std.fmt.allocPrint(
            allocator,
            "{s}/",
            .{value},
        );
}

fn existingDirectory(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    validateString(path, false) catch return error.InvalidPath;
    var directory = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer directory.close(io);
    const resolved = try directory.realPathFileAlloc(io, ".", allocator);
    return directoryString(allocator, resolved);
}

fn copyOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |text| {
        try validateString(text, true);
        return try allocator.dupe(u8, text);
    }
    return null;
}

pub fn copyStrings(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    directories: bool,
) ![]const []const u8 {
    const owned = try allocator.alloc([]const u8, values.len);
    for (values, owned) |value, *item| {
        try validateString(value, !directories);
        item.* = if (directories) try directoryString(allocator, value) else try allocator.dupe(u8, value);
    }
    return owned;
}
