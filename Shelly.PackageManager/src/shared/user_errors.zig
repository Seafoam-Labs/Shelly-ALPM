const std = @import("std");

pub const Context = struct {
    operation: []const u8 = "the package operation",
    subject: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

pub const flatpak_missing = "Flatpak support is not installed. Install flatpak and shelly-flatpak-backend, then try again.";
pub const flatpak_incompatible = "Shelly and its Flatpak backend have incompatible versions. Upgrade shelly and shelly-flatpak-backend together, then try again.";
pub const authorization_denied = "Permission to install packages was not granted. Try again and approve the authorization request to continue.";

/// Human output only: callers retain the original error and machine-readable code.
/// Prefer a backend's contextual explanation over guessing from a generic error.
pub fn format(allocator: std.mem.Allocator, err: anyerror, context: Context) ![]u8 {
    if (err == error.Cancelled) return allocator.dupe(u8, "Operation cancelled.");
    const explanation = if (context.detail) |detail| blk: {
        if (detail.len > 0 and !std.mem.eql(u8, detail, @errorName(err)))
            break :blk try allocator.dupe(u8, detail);
        break :blk try explain(allocator, err, context);
    } else try explain(allocator, err, context);
    defer allocator.free(explanation);
    if (std.mem.indexOf(u8, explanation, "Technical details:") != null)
        return allocator.dupe(u8, explanation);
    return std.fmt.allocPrint(allocator, "{s}\n\nTechnical details: {s}", .{ explanation, @errorName(err) });
}

fn explain(allocator: std.mem.Allocator, err: anyerror, context: Context) ![]u8 {
    return switch (err) {
        error.FlatpakBackendUnavailable => allocator.dupe(u8, flatpak_missing),
        error.FlatpakBackendIncompatible => allocator.dupe(u8, flatpak_incompatible),
        error.AuthorizationDenied => allocator.dupe(u8, authorization_denied),
        error.AccessDenied, error.PermissionDenied => std.fmt.allocPrint(allocator, "Could not complete {s} because access was denied. Check that you have permission to access the required files and directories.", .{context.operation}),
        error.PackageNotFound, error.PkgNotFound, error.NoPackageFound, error.FlatpakNotFound => missingPackage(allocator, context.subject orelse "the requested package"),
        error.NoSpaceLeft, error.DiskQuota => allocator.dupe(u8, "There is not enough free space to continue. Free up space on the destination filesystem, then try again."),
        error.NetworkError,
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.Timeout,
        error.ConnectTimeout,
        error.HeaderTimeout,
        error.BodyTimeout,
        error.UnknownHostName,
        => std.fmt.allocPrint(allocator, "Could not complete {s} because the server could not be reached. Check your internet connection and try again. If the problem continues, the server may be unavailable.", .{context.operation}),
        error.BadPgpSignature, error.PgpVerificationFailed => std.fmt.allocPrint(allocator, "Could not verify the signature of \"{s}\". Refresh the package signing keys and download the package again. If verification still fails, contact the package source.", .{context.subject orelse "the requested package"}),
        error.MissingPgpKey => allocator.dupe(u8, "Could not verify the source signature because its signing key is missing. Review and import the package source's signing key, then try again."),
        error.RevokedPgpKey => allocator.dupe(u8, "Could not verify the source signature because its signing key has been revoked. Contact the package source for an updated signature."),
        error.SourceChecksumMismatch => allocator.dupe(u8, "The downloaded source does not match its expected checksum. Download it again. If verification still fails, contact the package source."),
        error.StepFailed, error.BuildFailed => std.fmt.allocPrint(allocator, "Could not build \"{s}\". Open the build details to see the cause.", .{context.subject orelse "the requested package"}),
        else => std.fmt.allocPrint(allocator, "Could not complete {s}. Shelly encountered an unexpected error. Include the technical details below when reporting this problem.", .{context.operation}),
    };
}

pub fn missingPackage(allocator: std.mem.Allocator, package: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Could not find \"{s}\" in the selected package sources. Check the package name or search for it in another source.", .{package});
}

pub fn databaseLocked(allocator: std.mem.Allocator, database_path: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ database_path, "db.lck" });
    defer allocator.free(path);
    var command: std.Io.Writer.Allocating = .init(allocator);
    defer command.deinit();
    // Quote the configured path as one shell argument, including embedded quotes.
    try command.writer.writeAll("sudo rm -- '");
    for (path) |byte| {
        if (byte == '\'') try command.writer.writeAll("'\\''") else try command.writer.writeByte(byte);
    }
    try command.writer.writeByte('\'');
    return std.fmt.allocPrint(allocator, "Could not start the package operation because the package database is locked.\n\n" ++
        "Lock file: {s}\n\n" ++
        "Wait for any running package manager to finish. If no package manager is running, remove the leftover lock file, then try again:\n{s}", .{ path, command.written() });
}

pub fn buildFailed(allocator: std.mem.Allocator, package: []const u8, stage: []const u8, exit_code: u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Could not build \"{s}\". The build failed during {s}. Open the build details to see the cause.\n\nTechnical details: build step exited with code {d}.", .{ package, stage, exit_code });
}

test "lock instructions use and shell quote the configured database path" {
    const message = try databaseLocked(std.testing.allocator, "/tmp/Shelly's database/");
    defer std.testing.allocator.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "Lock file: /tmp/Shelly's database/db.lck") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "sudo rm -- '/tmp/Shelly'\\''s database/db.lck'") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "If no package manager is running") != null);
}

test "unknown failures preserve diagnostics without inventing a cause" {
    const message = try format(std.testing.allocator, error.InitFailed, .{});
    defer std.testing.allocator.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "unexpected error") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Technical details: InitFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "locked") == null);
}

test "contextual backend messages survive formatting and cancellation has no diagnostic" {
    const message = try format(std.testing.allocator, error.CommitFailed, .{ .detail = "Could not install foo because /etc/foo exists." });
    defer std.testing.allocator.free(message);
    try std.testing.expect(std.mem.startsWith(u8, message, "Could not install foo because /etc/foo exists."));
    const cancelled = try format(std.testing.allocator, error.Cancelled, .{});
    defer std.testing.allocator.free(cancelled);
    try std.testing.expectEqualStrings("Operation cancelled.", cancelled);
}
