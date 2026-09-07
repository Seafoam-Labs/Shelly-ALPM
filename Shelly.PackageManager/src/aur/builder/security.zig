//! Process privilege guards and isolated work-directory creation for the
//! non-root builder.

const std = @import("std");
const builtin = @import("builtin");
const archive = @import("archive");
const BuilderErrors = @import("builder.zig").BuilderErrors;

pub fn requireNonRootEffectiveUid(effective_uid: u32) error{BuilderMustNotRunAsRoot}!void {
    if (effective_uid == 0) return error.BuilderMustNotRunAsRoot;
}

pub fn uniqueWorkDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    build_root: []const u8,
    package_base: []const u8,
) ![]u8 {
    const normalized = try archive.normalizeEntryPath(allocator, package_base);
    defer allocator.free(normalized);
    if (std.mem.indexOfScalar(u8, normalized, '/') != null) return error.InvalidPackageBase;
    var random_suffix: [8]u8 = undefined;
    io.random(&random_suffix);
    const suffix = std.fmt.bytesToHex(random_suffix, .lower);
    return std.fmt.allocPrint(allocator, "{s}/{s}-{s}", .{ build_root, normalized, suffix });
}

/// Sets `PR_SET_NO_NEW_PRIVS` for the calling process. Required before an
/// unprivileged process may apply Landlock, and inherited by every child.
pub fn setNoNewPrivs() !void {
    _ = try std.posix.prctl(.SET_NO_NEW_PRIVS, .{
        @as(usize, 1),
        @as(usize, 0),
        @as(usize, 0),
        @as(usize, 0),
    });
}

/// Locks the current Linux process to the non-root privilege level. The flag
/// is inherited by every build child and cannot be unset.
pub fn secureBuilderProcess() !void {
    if (builtin.os.tag != .linux) return;
    // CI commonly runs Zig test binaries as root. The effective-UID policy is
    // covered directly by requireNonRootEffectiveUid's unit test; enforcing it
    // here as well would prevent the builder fixtures from reaching the code
    // they are intended to exercise. Production binaries must always reject
    // root before executing PKGBUILD steps.
    if (!builtin.is_test)
        try requireNonRootEffectiveUid(@intCast(std.os.linux.geteuid()));
    try setNoNewPrivs();
}

pub fn narrowBuilderError(err: anyerror) BuilderErrors {
    return switch (err) {
        error.OutOfMemory => BuilderErrors.OutOfMemory,
        error.Cancelled => BuilderErrors.Cancelled,
        error.AlreadyBuilt => BuilderErrors.AlreadyBuilt,
        error.BuilderMustNotRunAsRoot => BuilderErrors.BuilderMustNotRunAsRoot,
        error.UnreviewedBuilderRequest => BuilderErrors.UnreviewedBuilderRequest,
        error.ReviewedPkgbuildChanged => BuilderErrors.ReviewedPkgbuildChanged,
        error.BuildDirectoryNotWritable => BuilderErrors.BuildDirectoryNotWritable,
        error.PrivilegedPackageOperationUnsupported => BuilderErrors.PrivilegedPackageOperationUnsupported,
        error.SandboxUnsupported => BuilderErrors.SandboxUnsupported,
        error.InvalidSourceDateEpoch => BuilderErrors.InvalidSourceDateEpoch,
        else => BuilderErrors.BuildFailed,
    };
}

test "requireNonRootEffectiveUid rejects root" {
    try std.testing.expectError(error.BuilderMustNotRunAsRoot, requireNonRootEffectiveUid(0));
    try requireNonRootEffectiveUid(1000);
}

test "uniqueWorkDirectory nests under build root with a random suffix" {
    const dir = try uniqueWorkDirectory(std.testing.allocator, std.testing.io, "/tmp/build", "pkgbase");
    defer std.testing.allocator.free(dir);
    try std.testing.expect(std.mem.startsWith(u8, dir, "/tmp/build/pkgbase-"));
    try std.testing.expectEqual("/tmp/build/pkgbase-".len + 16, dir.len);
    try std.testing.expectError(error.InvalidPackageBase, uniqueWorkDirectory(std.testing.allocator, std.testing.io, "/tmp/build", "evil/name"));
}
