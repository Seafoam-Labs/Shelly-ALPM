const std = @import("std");

pub const Context = struct {
    operation: []const u8 = "the package operation",
    action: []const u8 = "manage packages",
    subject: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    path: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    stage: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    native_code: ?i64 = null,
};

pub const flatpak_missing = "Flatpak support is not installed. Install flatpak and shelly-flatpak-backend, then try again.";
pub const flatpak_incompatible = "Shelly and its Flatpak backend have incompatible versions. Upgrade shelly and shelly-flatpak-backend together, then try again.";
pub const authorization_denied = "Permission to manage packages was not granted. Try again and approve the authorization request to continue.";
pub const unknown_cause = "Shelly did not provide a more specific reason. Include the technical details when reporting this problem.";
pub const allocation_failure = "Could not complete the operation. Shelly could not allocate memory for the error details.";

pub fn isCancellation(err: anyerror) bool {
    return err == error.Cancelled or err == error.Canceled or err == error.PkgbuildReviewDeclined or err == error.PgpKeyImportDeclined;
}

/// Only generic summaries are replaceable. Specific backend diagnostics remain
/// authoritative even when the transport reduces their code to OperationFailed.
pub fn isGenericDetail(detail: []const u8) bool {
    const text = std.mem.trim(u8, detail, " .\t\r\n");
    for ([_][]const u8{
        "ALPM operation failed",                    "AUR operation failed",                      "Flatpak operation failed",
        "AppImage operation failed",                "Package-cache operation failed",            "AUR HTTP operation failed",
        "Flatpak transaction failed",               "Operation failed",                          "Transaction failed",
        "Build failed",                             "Failed to build",                           "Failed to build package",
        "Installation failed",                      "Removal failed",                            "Update failed",
        "Upgrade failed",                           "Could not complete the package operation",  "Could not complete the AUR operation",
        "Could not complete the Flatpak operation", "Could not complete the AppImage operation", "Could not build the requested package",
    }) |generic| if (std.ascii.eqlIgnoreCase(text, generic)) return true;
    return text.len == 0;
}

/// Human output only: callers retain the original error and machine-readable code.
/// Prefer a backend's contextual explanation over guessing from a generic error.
pub fn format(allocator: std.mem.Allocator, err: anyerror, context: Context) ![]u8 {
    if (isCancellation(err)) return allocator.dupe(u8, switch (err) {
        error.PkgbuildReviewDeclined => "Operation cancelled because the required PKGBUILD review was declined.",
        error.PgpKeyImportDeclined => "Operation cancelled because the source-signing key import was declined.",
        else => "Operation cancelled.",
    });
    const explanation = if (context.detail) |detail| blk: {
        if (!isGenericDetail(detail) and !std.mem.eql(u8, detail, @errorName(err)))
            break :blk try allocator.dupe(u8, detail);
        break :blk try explain(allocator, err, context);
    } else try explain(allocator, err, context);
    defer allocator.free(explanation);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll(explanation);
    if (context.subject) |subject| if (subject.len > 0 and std.mem.indexOf(u8, explanation, subject) == null)
        try out.writer.print("\nPackage: {s}", .{subject});
    if (context.path) |path| try out.writer.print("\nPath: {s}", .{path});
    if (context.scope) |scope| try out.writer.print("\nInstallation: {s}", .{scope});
    if (context.stage) |stage| try out.writer.print("\nStage: {s}", .{stage});
    if (std.mem.indexOf(u8, explanation, "Technical details:") == null)
        try out.writer.print("\n\nTechnical details: {s}", .{@errorName(err)});
    if (context.domain) |domain| try out.writer.print("\nBackend: {s}", .{domain});
    if (context.native_code) |code| try out.writer.print("\nNative code: {d}", .{code});
    return sanitizeAlloc(allocator, out.written());
}

fn explain(allocator: std.mem.Allocator, err: anyerror, context: Context) ![]u8 {
    return switch (err) {
        error.FlatpakBackendUnavailable => allocator.dupe(u8, flatpak_missing),
        error.FlatpakBackendIncompatible => allocator.dupe(u8, flatpak_incompatible),
        error.AuthorizationDenied => std.fmt.allocPrint(allocator, "Permission to {s} was not granted. Try again and approve the authorization request to continue.", .{context.action}),
        error.AccessDenied, error.PermissionDenied => std.fmt.allocPrint(allocator, "Could not complete {s} because access was denied. Check that you have permission to access the required files and directories.", .{context.operation}),
        error.PackageNotFound, error.PkgNotFound, error.NoPackageFound, error.FlatpakNotFound => missingPackage(allocator, context.subject orelse "the requested package"),
        error.NoSpaceLeft, error.DiskQuota => allocator.dupe(u8, cause(err)),
        error.BadPgpSignature, error.PgpVerificationFailed => std.fmt.allocPrint(allocator, "Could not verify the signature of \"{s}\". Refresh the package signing keys and download the package again. If verification still fails, contact the package source.", .{context.subject orelse "the requested package"}),
        error.MissingPgpKey => allocator.dupe(u8, "Could not verify the source signature because its signing key is missing. Review and import the package source's signing key, then try again."),
        error.RevokedPgpKey => allocator.dupe(u8, "Could not verify the source signature because its signing key has been revoked. Contact the package source for an updated signature."),
        error.SourceChecksumMismatch => allocator.dupe(u8, "The downloaded source does not match its expected checksum. Download it again. If verification still fails, contact the package source."),
        error.StepFailed, error.BuildFailed => std.fmt.allocPrint(allocator, "Could not build \"{s}\". Open the build details to see the cause.", .{context.subject orelse "the requested package"}),
        else => std.fmt.allocPrint(allocator, "Could not complete {s}. {s}", .{ context.operation, cause(err) }),
    };
}

pub fn formatEvent(allocator: std.mem.Allocator, failure: anytype) ![]u8 {
    return format(allocator, failure.err, .{
        .operation = operationDescription(failure.envelope.kind),
        .action = operationAction(failure.envelope.kind),
        .subject = failure.envelope.subject,
        .detail = failure.message,
        .domain = failure.domain orelse @tagName(failure.envelope.backend),
        .native_code = failure.native_code,
    });
}

pub fn operationDescription(kind: anytype) []const u8 {
    return switch (kind) {
        .install => "package installation",
        .remove => "package removal",
        .update => "the package update",
        .sync => "package synchronization",
        .search => "the package search",
        .download => "the download",
        .build => "the package build",
        .cleanup => "package cleanup",
        .inspect => "the package query",
        .configure => "package configuration",
        .launch => "the application launch",
    };
}

pub fn operationAction(kind: anytype) []const u8 {
    return switch (kind) {
        .install => "install packages",
        .remove => "remove packages",
        .update => "update packages",
        .sync => "synchronize packages",
        .search => "search for packages",
        .download => "download files",
        .build => "build packages",
        .cleanup => "clean up packages",
        .inspect => "query packages",
        .configure => "configure packages",
        .launch => "launch the application",
    };
}

/// Context for direct command errors without an operation event.
pub fn alloc(allocator: std.mem.Allocator, err: anyerror, comptime fmt: []const u8, args: anytype) ![]u8 {
    const detail = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(detail);
    return format(allocator, err, .{ .detail = detail });
}

pub const SafeText = struct {
    text: []const u8,
    pub fn format(self: SafeText, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var i: usize = 0;
        while (i < self.text.len) {
            // A diagnostic needs the server identity, never URL credentials,
            // query tokens, or private path components.
            if (std.mem.startsWith(u8, self.text[i..], "http://") or std.mem.startsWith(u8, self.text[i..], "https://") or
                std.mem.startsWith(u8, self.text[i..], "socks4://") or std.mem.startsWith(u8, self.text[i..], "socks5://") or std.mem.startsWith(u8, self.text[i..], "socks5h://"))
            {
                const end = i + (std.mem.indexOfAny(u8, self.text[i..], " \t\r\n\"'<>}") orelse self.text.len - i);
                const url = self.text[i..end];
                const authority_start = std.mem.indexOf(u8, url, "://").? + 3;
                const authority_end = authority_start + (std.mem.indexOfAny(u8, url[authority_start..], "/?#") orelse url.len - authority_start);
                const authority = url[authority_start..authority_end];
                const host_start = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| at + 1 else 0;
                try writer.writeAll(url[0..authority_start]);
                // Redact even malformed URLs: failed URI parsing must never
                // fall back to printing a password or query token.
                if (host_start == authority.len) try writer.writeAll("(invalid host)");
                for (authority[host_start..]) |byte| try writeSafeByte(writer, byte);
                try writer.writeAll("/…");
                i = end;
                continue;
            }
            const byte = self.text[i];
            try writeSafeByte(writer, byte);
            i += 1;
        }
    }
};

fn writeSafeByte(writer: *std.Io.Writer, byte: u8) std.Io.Writer.Error!void {
    if ((byte < 0x20 and byte != '\n' and byte != '\t') or byte == 0x7f)
        try writer.print("\\x{x:0>2}", .{byte})
    else
        try writer.writeByte(byte);
}

pub const ShellArgument = struct {
    text: []const u8,
    pub fn format(self: ShellArgument, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeByte('\'');
        for (self.text) |byte| {
            if (byte == '\'') try writer.writeAll("'\\''") else try writeSafeByte(writer, byte);
        }
        try writer.writeByte('\'');
    }
};

pub fn shellQuote(text: []const u8) ShellArgument {
    return .{ .text = text };
}

pub fn safe(text: anytype) SafeText {
    return .{ .text = switch (@typeInfo(@TypeOf(text))) {
        .pointer => |pointer| if (pointer.size == .c or (pointer.size == .many and pointer.sentinel_ptr != null)) std.mem.span(text) else text,
        else => text,
    } };
}

pub fn sanitizeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{safe(text)});
}

/// Allocation-free explanations for logs, startup failures and command wrappers.
/// The caller retains the exact code in technical/structured details. Deliberately
/// do not infer what a missing path represents or what a bounded buffer contains.
pub fn cause(err: anyerror) []const u8 {
    return switch (err) {
        error.Cancelled, error.Canceled => "Operation cancelled.",
        error.PkgbuildReviewDeclined => "The required PKGBUILD review was declined.",
        error.PgpKeyImportDeclined => "The source-signing key import was declined.",
        error.OutOfMemory => "Shelly ran out of memory. Close other applications and try again.",
        error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "The operating system could not provide the resources needed for this operation. Close unused applications and retry; include the technical details if it persists.",
        error.AuthorizationDenied => authorization_denied,
        error.ElevationFailed => "Could not request administrator privileges. Review the authorization helper output before retrying.",
        error.ElevationRequired => "Administrator privileges are required. Run Shelly from your regular user session and approve authorization when requested.",
        error.NoElevator => "No authorization helper was found. Install or configure sudo, doas, or pkexec.",
        error.InvokingUserUnavailable, error.CannotBuildAsRoot => "Could not identify a regular user to run the build. Start Shelly from your regular user session and approve authorization when requested.",
        error.AccessDenied, error.PermissionDenied => "Access was denied. Check that the invoking user has the required permissions for the selected files and directories.",
        error.NoSpaceLeft => "The destination has insufficient capacity. Check the filesystem space or the reported buffer limit before retrying.",
        error.DiskQuota => "The destination filesystem quota was exceeded. Free space or adjust the applicable quota before retrying.",
        error.FileNotFound, error.PathNotFound => "The required file, directory, or executable was not found. Check the reported path and required tools.",
        error.NotDir => "The selected path is not a directory. Select an existing directory.",
        error.IsDir => "The selected path is a directory. Select a file instead.",
        error.PathAlreadyExists => "The destination already exists. Review it before choosing a different destination or replacing it.",
        error.ReadOnlyFileSystem => "The destination filesystem is read-only. Choose a writable destination or correct its mount configuration.",
        error.InputOutput => "The operating system could not read or write the required data. Check the affected storage and system diagnostics.",
        error.NetworkError, error.ConnectionRefused, error.ConnectionTimedOut, error.Timeout, error.ConnectTimeout, error.HeaderTimeout, error.BodyTimeout => "The request could not complete. Check your connection and retry; if it persists, check the configured server.",
        error.UnknownHostName, error.NameServerFailure, error.NoAddressReturned => "The server name could not be resolved. Check the configured hostname and network/DNS connection.",
        error.SslError, error.CertificateBundleError, error.CertificateBundleLoadFailure, error.TlsCertificateNotVerified => "Could not establish a verified secure connection. Check your system clock and trusted certificates; do not disable certificate verification.",
        error.TlsConnectionTruncated, error.EndOfStream => "The connection or input ended before the response was complete. Check the source and retry.",
        error.TlsInitializationFailed, error.TlsAlert, error.TlsUnexpectedMessage, error.TlsIllegalParameter, error.TlsBadRecordMac, error.TlsRecordOverflow, error.TlsDecryptError, error.TlsDecryptFailure, error.TlsBadSignatureScheme => "The secure connection failed. Review the TLS details and configured server; do not disable verification.",
        error.InvalidProxyConfiguration, error.UnsupportedProxyScheme, error.ProxyTunnelFailed, error.ProxyTunnelRejected, error.TunnelNotSupported => "Could not connect through the configured proxy. Check the proxy configuration and response details.",
        error.HttpHeadersInvalid, error.HttpContentEncodingUnsupported, error.HttpTransferEncodingUnsupported, error.InvalidContentLength, error.HttpRedirectLocationMissing, error.HttpRedirectLocationInvalid, error.HttpRedirectLocationOversize, error.TooManyHttpRedirects => "The server returned a response Shelly could not use. Check the configured source; if it persists, report the technical details.",
        error.InvalidUrl, error.InvalidAurUrl, error.UnsupportedUriScheme => "The source URL is invalid or unsupported. Check the configured source address and URL scheme.",
        error.StreamTooLong, error.InvalidMessageSize => "The request or response exceeded its size limit. Check the selected input and reported limit; report the details if it persists.",
        error.PackageNotFound, error.PkgNotFound, error.NoPackageFound, error.FlatpakNotFound => "The requested package was not found in the selected source or installation. Check its name and selected source.",
        error.AurPackageNotFound => "The requested package is not available from the configured AUR service. Check the package name or select another source.",
        error.AurRpcLookupFailed, error.InvalidAurResponse => "The configured AUR service did not return a valid, complete response. Check the service and retry; package availability could not be confirmed.",
        error.AurHttpStatus => "The configured AUR service returned an unsuccessful HTTP status. Check the service and response details.",
        error.InvalidAurPackageBase => "The AUR package base is invalid. Check the selected package name.",
        error.AurGitCheckoutFailed, error.InvalidAurCheckout => "Could not prepare the AUR checkout. Review the Git output and selected revision.",
        error.AurPkgbuildMissing => "The selected AUR checkout contains no PKGBUILD. Check the package base and revision.",
        error.ReviewedPkgbuildChanged, error.ReviewedCheckoutChanged => "The reviewed package inputs changed before the build started. Review the current checkout and source files again, then restart the build.",
        error.MissingPkgbuildReviewHandler, error.UnreviewedBuilderRequest => "The required PKGBUILD review was not completed. Use a supported review interface and review the package before building.",
        error.InvalidPkgbuildPath, error.InvalidStartDirectory => "The selected build path is invalid. Select an existing build directory and PKGBUILD.",
        error.MissingPackageName => "The PKGBUILD does not declare the required package name. Review pkgname and the selected package.",
        error.MissingExecutionSteps => "The PKGBUILD has no executable build steps for the selected package. Review its package function.",
        error.InvalidPackageFunctionVariable => "A package function contains an invalid metadata assignment. Review the PKGBUILD package metadata.",
        error.ExtraSplitPackageFunction => "The split PKGBUILD also declares a generic package() function. Use the matching package-specific functions.",
        error.MissingSplitPackageFunction => "The split PKGBUILD is missing a package-specific function. Provide a function for each selected package.",
        error.ConflictingPackageFunctions => "The PKGBUILD declares conflicting generic and package-specific functions. Review which function should package the selected output.",
        error.MissingPackageFunction => "The PKGBUILD is missing its package() function. Review the package definition.",
        error.InvalidDynamicScalarOutput, error.InvalidDynamicArrayOutput, error.InvalidDynamicShellOptionOutput => "The metadata subprocess returned invalid output. Review the dynamic metadata and build details.",
        error.UnresolvedPkgbuildVariable => "The PKGBUILD contains an expression Shelly could not resolve. Review the reported field and source location.",
        error.MissingPkgbuildSourceFile => "A local source referenced by the PKGBUILD is missing. Restore the source or correct its path.",
        error.UnsafePkgbuildSourcePath => "A local source is not a regular file inside the package directory. Review the reported source path.",
        error.IsolatedSigningUnsupported => "The requested signing configuration is not supported for isolated builds. Choose a supported signing setup before retrying.",
        error.IsolatedAurDependencyUnsupported => "An AUR dependency step is not supported in this isolated build. Review the isolated-build dependency requirements.",
        error.IsolatedSourcePgpKeyPreparationFailed => "Source-signing key preparation in the invoking user's session failed. Review the key preparation output.",
        error.ChrootFailed => "Could not prepare the isolated build root. Review the bootstrap command and its output.",
        error.SandboxUnsupported => "The configured build sandbox is unavailable on this system. Use a system with supported Landlock sandboxing for this build.",
        error.SandboxPathUnopenable => "The sandbox could not open a configured path. Check that it exists and is accessible to the build user.",
        error.SandboxRuleFailed, error.SandboxRestrictFailed => "Could not apply the configured build sandbox restrictions. Review the sandbox configuration and technical details.",
        error.BuildDirectoryNotWritable => "The build user cannot write to the build directory. Check its ownership and permissions before retrying.",
        error.PrivilegedPackageOperationUnsupported => "A package build step requested an operation the non-root builder does not support. Review the command in the build details.",
        error.BuildLogWriteFailed => "Could not write the build log. Check its destination permissions and available space; build details may be incomplete.",
        error.BuildFailed, error.StepFailed => "The package build did not complete successfully. See the build details for the failed stage and command output.",
        error.ArtifactValidationFailed => "The generated package archive failed validation. Check the expected package metadata and build output.",
        error.UnexpectedBuildArtifact => "The build produced an unexpected package archive. Check the selected package names and build output.",
        error.DuplicateBuildArtifact => "The build produced duplicate package archives. Review the expected package names and output directory.",
        error.MissingBuildArtifact, error.NoBuiltPackages => "The build produced no matching package archive. Check the package() output and expected package names.",
        error.BadPgpSignature, error.PgpVerificationFailed => "The signature could not be verified. Check the signing keys and obtain a valid signature from the source before retrying.",
        error.MissingPgpKey => "The source-signing key is missing. Review and import the required key before retrying.",
        error.RevokedPgpKey => "The source-signing key has been revoked. Contact the package source for an updated signature.",
        error.SourceChecksumMismatch => "The downloaded source does not match its expected checksum. Download it again; if verification still fails, contact the package source.",
        error.GpgFailed => "GPG reported a failure. Review its output and the selected keyring.",
        error.NoSecretKey => "The selected keyring has no secret signing key. Initialize the intended keyring before retrying.",
        error.FlatpakBackendUnavailable => flatpak_missing,
        error.FlatpakBackendIncompatible => flatpak_incompatible,
        error.FlatpakBackendInvalid => "The installed Flatpak backend library is invalid. Check or reinstall the matching shelly-flatpak-backend package.",
        error.FlatpakBackendCreateFailed => "Could not start the Flatpak backend. Review the backend details and retry the operation.",
        error.FlatpakBackendTransportFailed => "Could not communicate with the Flatpak backend. Review the backend details and retry the operation.",
        error.FlatpakProtocolInvalid, error.FlatpakProtocolMismatch, error.UnknownMethod, error.UnsupportedSchema => "Shelly and its Flatpak backend returned an invalid or incompatible protocol message. Upgrade shelly and shelly-flatpak-backend together; report the details if it persists.",
        error.FlatpakProtocolMessageTooLarge => "The Flatpak request or response exceeded the protocol size limit. Try a smaller selection; report the details if it persists.",
        error.FlatpakRemoteNotFound, error.RemoteNotFound => "The Flatpak remote was not found. Check its name and selected installation scope.",
        error.FlatpakCatalogNotFound, error.CatalogNotFound => "The Flatpak remote's AppStream catalog was not found. Refresh the remote metadata and retry.",
        error.FlatpakOriginMissing => "The installed Flatpak has no origin remote. Restore its remote or select a supported replacement source.",
        error.FlatpakScopeUnknown => "Could not identify the Flatpak installation scope. Check both user and system installed-application lists.",
        error.AmbiguousAppImage => "More than one installed AppImage matches the query. Select an exact application.",
        error.AppImageNotFound => "No installed AppImage matches the query. Check its name and installation location.",
        error.InvalidEnvironmentName => "An environment variable name is invalid. Names must start with a letter or underscore and contain only letters, digits, or underscores.",
        error.InvalidEnvironmentValue => "An environment variable value contains unsupported characters. Remove newlines, carriage returns, and NUL characters.",
        error.DuplicateEnvironmentName => "An environment variable name appears more than once. Use unique KEY=value entries.",
        error.EnvironmentObjectRequired, error.EnvironmentStringRequired => "AppImage environment settings must be a JSON object with string values. Correct the settings and retry.",
        error.InvalidDesktopExec, error.UnsupportedDesktopExec => "The application's desktop launch command is invalid or unsupported. Correct or regenerate the desktop entry before retrying.",
        error.InvalidConfig, error.InvalidValue => "The configuration value or file is invalid. Check the selected setting and its accepted values.",
        error.InvalidConfigDefaults => "Shelly's built-in settings are invalid. Report the technical details; this cannot be repaired by changing your settings.",
        error.MissingBackupSection => "The backup is missing a required package section. Select a complete Shelly backup.",
        error.InvalidBackupSection, error.UnknownBackupSection => "The backup contains an invalid or unsupported section. Correct the file or select a valid Shelly backup.",
        error.DuplicateBackupSection => "The backup declares the same section more than once. Remove the duplicate section or select a valid Shelly backup.",
        error.InvalidBackupString, error.InvalidBackupEscape, error.UnterminatedArray => "The backup contains invalid text, escaping, or an unterminated array. Correct the file or select a valid Shelly backup.",
        error.BackupPackageInstallFailed => "Some packages from the backup could not be installed. Review the individual installation errors; successful installations have not been rolled back.",
        else => unknown_cause,
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
    try std.testing.expect(std.mem.indexOf(u8, message, "more specific reason") != null);
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

test "generic failures use the actual cause and retain operation identity" {
    const allocator = std.testing.allocator;
    const message = try format(allocator, error.AccessDenied, .{
        .operation = "package installation",
        .subject = "example",
        .detail = "ALPM operation failed",
        .path = "/custom/db",
        .scope = "system",
        .stage = "prepare",
        .domain = "alpm",
        .native_code = 42,
    });
    defer allocator.free(message);
    for ([_][]const u8{ "access was denied", "Package: example", "Path: /custom/db", "Installation: system", "Stage: prepare", "Technical details: AccessDenied", "Backend: alpm", "Native code: 42" }) |text|
        try std.testing.expect(std.mem.indexOf(u8, message, text) != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "internet") == null);
}

test "safe text strips URL secrets and escapes control bytes including native strings" {
    const input: [*:0]const u8 = "https://user:password@host.example/private?token=secret\x1b[31m http://bad\x1bhost/private";
    const message = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{safe(input)});
    defer std.testing.allocator.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "host.example/…") != null);
    for ([_][]const u8{ "user", "password", "private", "token", "secret", "\x1b" }) |secret|
        try std.testing.expect(std.mem.indexOf(u8, message, secret) == null);
    const control = try sanitizeAlloc(std.testing.allocator, "filename\x1b[31m\r\x00\x7f");
    defer std.testing.allocator.free(control);
    try std.testing.expectEqualStrings("filename\\x1b[31m\\x0d\\x00\\x7f", control);
}

test "specific child explanation keeps one details block and original native code" {
    const message = try format(std.testing.allocator, error.CommitFailed, .{
        .detail = "Could not install foo: a conflicting file exists.\n\nTechnical details: /etc/foo",
        .domain = "alpm",
        .native_code = 47,
    });
    defer std.testing.allocator.free(message);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, message, "Technical details:"));
    try std.testing.expect(std.mem.indexOf(u8, message, "/etc/foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Native code: 47") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "more specific reason") == null);
}

test "cause selection distinguishes failed lookup from confirmed missing package and signature failures" {
    try std.testing.expect(std.mem.indexOf(u8, cause(error.AurRpcLookupFailed), "availability could not be confirmed") != null);
    try std.testing.expect(std.mem.indexOf(u8, cause(error.AurPackageNotFound), "not available") != null);
    try std.testing.expect(std.mem.indexOf(u8, cause(error.MissingPgpKey), "missing") != null);
    try std.testing.expectEqualStrings(unknown_cause, cause(error.UnmappedTestError));
    for ([_]anyerror{ error.Cancelled, error.PkgbuildReviewDeclined, error.PgpKeyImportDeclined }) |err| {
        const message = try format(std.testing.allocator, err, .{});
        defer std.testing.allocator.free(message);
        try std.testing.expect(std.mem.indexOf(u8, message, "cancelled") != null);
        try std.testing.expect(std.mem.indexOf(u8, message, "Technical details:") == null);
    }
}

test "shell commands quote selected paths as one argument" {
    const message = try std.fmt.allocPrint(std.testing.allocator, "shelly-key --init {f}", .{shellQuote("/tmp/Zoey's keyring")});
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("shelly-key --init '/tmp/Zoey'\\''s keyring'", message);
}

test "allocation failure leaves an allocation-free explanation available" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const message = format(failing.allocator(), error.AccessDenied, .{ .operation = "package installation" }) catch allocation_failure;
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqualStrings(allocation_failure, message);
}
