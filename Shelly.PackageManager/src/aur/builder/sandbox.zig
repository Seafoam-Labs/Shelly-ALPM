//! Landlock confinement for the untrusted PKGBUILD lifecycle steps.
//!
//! The builder wraps every lifecycle step through the CLI's `__sandbox-exec`
//! entry point, which applies a Landlock policy to the step process right
//! before exec'ing bash. Only the step children are confined: the
//! orchestrator keeps full access so source acquisition, package assembly,
//! and GPG signing stay unaffected and the keyring never enters the sandbox
//! allow-list.
//!
//! Landlock is a path-based deny-by-exception LSM. The policy lists every
//! path the steps may touch; anything not listed — the rest of `$HOME` in
//! particular — is denied. The confinement covers procfs, sysfs, and
//! devtmpfs too, so the base allow-list re-grants the nodes toolchains need;
//! networking is not restricted.

const std = @import("std");
const builtin = @import("builtin");

/// Reserved first argument that routes a re-executed `shelly` process into the
/// sandbox wrapper instead of the normal CLI dispatcher.
pub const wrapper_argument = "__sandbox-exec";

pub const SandboxError = error{
    /// The kernel lacks Landlock support (or the OS is not Linux). The
    /// builder hard-fails instead of running steps unprotected.
    SandboxUnsupported,
    /// A policy path could not be opened with O_PATH, for example a
    /// configured extra path that no longer exists.
    SandboxPathUnopenable,
    /// The Landlock ruleset could not be created or a rule could not be
    /// added.
    SandboxRuleFailed,
    /// `landlock_restrict_self` was rejected by the kernel.
    SandboxRestrictFailed,
};

// LANDLOCK_ACCESS_FS_* bits from include/uapi/linux/landlock.h.
pub const access_fs_execute: u64 = 1 << 0;
pub const access_fs_write_file: u64 = 1 << 1;
pub const access_fs_read_file: u64 = 1 << 2;
pub const access_fs_read_dir: u64 = 1 << 3;
pub const access_fs_remove_dir: u64 = 1 << 4;
pub const access_fs_remove_file: u64 = 1 << 5;
pub const access_fs_make_char: u64 = 1 << 6;
pub const access_fs_make_dir: u64 = 1 << 7;
pub const access_fs_make_reg: u64 = 1 << 8;
pub const access_fs_make_sock: u64 = 1 << 9;
pub const access_fs_make_fifo: u64 = 1 << 10;
pub const access_fs_make_block: u64 = 1 << 11;
pub const access_fs_make_sym: u64 = 1 << 12;
/// ABI version 2 (kernel 5.19).
pub const access_fs_refer: u64 = 1 << 13;
/// ABI version 3 (kernel 6.2).
pub const access_fs_truncate: u64 = 1 << 14;

const abi1_fs_mask = access_fs_execute |
    access_fs_write_file |
    access_fs_read_file |
    access_fs_read_dir |
    access_fs_remove_dir |
    access_fs_remove_file |
    access_fs_make_char |
    access_fs_make_dir |
    access_fs_make_reg |
    access_fs_make_sock |
    access_fs_make_fifo |
    access_fs_make_block |
    access_fs_make_sym;

/// Complete filesystem access mask for the given Landlock ABI version. Used
/// both as the ruleset's handled-access mask (everything listed is enforced,
/// everything unlisted is denied) and as the allowed access for read-write
/// paths.
pub fn fullAccessMaskForAbi(abi: u32) u64 {
    var mask: u64 = abi1_fs_mask;
    if (abi >= 2) mask |= access_fs_refer;
    if (abi >= 3) mask |= access_fs_truncate;
    return mask;
}

/// Allowed access for read-only policy paths: traverse, list, read, and
/// execute. Mutation rights are deliberately absent.
pub const read_only_access: u64 = access_fs_execute | access_fs_read_file | access_fs_read_dir;

/// File-scoped subset of the access bits. The kernel rejects path rules that
/// carry directory-scoped rights (READ_DIR and friends) for non-directory
/// targets such as device nodes.
const file_access_bits: u64 = access_fs_execute | access_fs_write_file | access_fs_read_file;

/// System directories every step needs. `/usr` covers the merged-usr
/// `/bin`, `/lib`, and `/sbin` symlinks on Arch. `/proc` and `/sys` stay
/// readable because toolchains probe them (CPU/memory detection, `/proc/self`).
/// `/dev/null` and `/dev/zero` are granted because shell redirection and
/// build tools open them constantly.
pub const base_read_only_paths: []const []const u8 = &.{
    "/usr",
    "/etc",
    "/opt",
    "/proc",
    "/sys",
    "/dev/null",
    "/dev/zero",
    "/dev/urandom",
    "/dev/random",
};
/// Shared scratch space for build tools; Landlock cannot mount a private
/// tmpfs, so this remains host-visible. `/dev/null` is writable as well so
/// `> /dev/null` redirection works.
pub const base_read_write_paths: []const []const u8 = &.{ "/tmp", "/dev/null" };

const RulesetAttr = extern struct {
    handled_access_fs: u64,
};

const PathBeneathAttr = extern struct {
    allowed_access: u64,
    parent_fd: i32,
};

const rule_type_path_beneath = 1;
/// `LANDLOCK_CREATE_RULESET_VERSION`: query the supported ABI version
/// without creating a ruleset. Required for the version query; a bare
/// `attr=NULL, size=0, flags=0` call is rejected with EFAULT.
const create_ruleset_version_flag = 1;

/// Probes the kernel for the highest supported Landlock ABI version.
/// Returns 0 when Landlock is unavailable (non-Linux OS, syscall absent, or
/// the LSM disabled at runtime).
pub fn abiVersion() u32 {
    if (builtin.os.tag != .linux) return 0;
    const rc = std.os.linux.syscall3(.landlock_create_ruleset, 0, 0, create_ruleset_version_flag);
    if (std.os.linux.errno(@intCast(rc)) != .SUCCESS) return 0;
    return @intCast(rc);
}

pub const Policy = struct {
    read_write_paths: []const []const u8,
    read_only_paths: []const []const u8,
};

/// Applies the Landlock policy to the calling process. Irreversible and
/// inherited by every child across fork and exec. Requires
/// `PR_SET_NO_NEW_PRIVS`, which the wrapper sets beforehand.
pub fn applyPolicy(allocator: std.mem.Allocator, policy: Policy) (SandboxError || error{OutOfMemory})!void {
    if (builtin.os.tag != .linux) return error.SandboxUnsupported;
    const abi = abiVersion();
    if (abi < 1) return error.SandboxUnsupported;
    const full_mask = fullAccessMaskForAbi(abi);

    var ruleset_attr = RulesetAttr{ .handled_access_fs = full_mask };
    const ruleset_rc = std.os.linux.syscall3(
        .landlock_create_ruleset,
        @intFromPtr(&ruleset_attr),
        @sizeOf(RulesetAttr),
        0,
    );
    if (std.os.linux.errno(@intCast(ruleset_rc)) != .SUCCESS) return error.SandboxRuleFailed;
    const ruleset_fd: i32 = @intCast(ruleset_rc);
    defer _ = std.os.linux.close(ruleset_fd);

    for (policy.read_write_paths) |path|
        try addPathRule(allocator, ruleset_fd, full_mask, path);
    for (policy.read_only_paths) |path|
        try addPathRule(allocator, ruleset_fd, read_only_access, path);

    const restrict_rc = std.os.linux.syscall2(.landlock_restrict_self, @intCast(ruleset_fd), 0);
    if (std.os.linux.errno(@intCast(restrict_rc)) != .SUCCESS) return error.SandboxRestrictFailed;
}

fn addPathRule(
    allocator: std.mem.Allocator,
    ruleset_fd: i32,
    allowed_access: u64,
    path: []const u8,
) (SandboxError || error{OutOfMemory})!void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd_rc = std.os.linux.open(path_z.ptr, .{ .PATH = true, .CLOEXEC = true }, 0);
    if (std.os.linux.errno(@intCast(fd_rc)) != .SUCCESS) return error.SandboxPathUnopenable;
    const parent_fd: i32 = @intCast(fd_rc);
    defer _ = std.os.linux.close(parent_fd);
    var rule = PathBeneathAttr{
        .allowed_access = allowed_access,
        .parent_fd = parent_fd,
    };
    var rc = std.os.linux.syscall4(
        .landlock_add_rule,
        @intCast(ruleset_fd),
        rule_type_path_beneath,
        @intFromPtr(&rule),
        0,
    );
    if (std.os.linux.errno(@intCast(rc)) == .INVAL) {
        // Non-directory target: directory-scoped rights are rejected. Retry
        // with the file-scoped subset (covers device nodes like /dev/null).
        rule.allowed_access = allowed_access & file_access_bits;
        if (rule.allowed_access == 0) return error.SandboxRuleFailed;
        rc = std.os.linux.syscall4(
            .landlock_add_rule,
            @intCast(ruleset_fd),
            rule_type_path_beneath,
            @intFromPtr(&rule),
            0,
        );
    }
    if (std.os.linux.errno(@intCast(rc)) != .SUCCESS) return error.SandboxRuleFailed;
}

pub const ParsedWrapper = struct {
    read_write_paths: []const []const u8,
    read_only_paths: []const []const u8,
    child_argv: []const []const u8,
};

pub const WrapperParseError = error{
    MissingWrapperSeparator,
    MissingWrapperPath,
    UnknownWrapperOption,
    EmptyWrapperChildCommand,
    OutOfMemory,
};

/// Parses the wrapper protocol: repeated `--rw <path>` and `--ro <path>`
/// entries, then `--`, then the child argv. Returned slices are allocated
/// from `allocator`; the path and argv elements borrow from `args`.
pub fn parseWrapperArguments(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) WrapperParseError!ParsedWrapper {
    var separator: ?usize = null;
    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--")) {
            separator = index;
            break;
        }
    }
    const separator_index = separator orelse return error.MissingWrapperSeparator;
    const child_argv = args[separator_index + 1 ..];
    if (child_argv.len == 0) return error.EmptyWrapperChildCommand;

    var read_write_count: usize = 0;
    var read_only_count: usize = 0;
    var index: usize = 0;
    while (index < separator_index) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--rw")) {
            index += 1;
            if (index >= separator_index) return error.MissingWrapperPath;
            read_write_count += 1;
        } else if (std.mem.eql(u8, args[index], "--ro")) {
            index += 1;
            if (index >= separator_index) return error.MissingWrapperPath;
            read_only_count += 1;
        } else return error.UnknownWrapperOption;
    }

    const read_write_paths = try allocator.alloc([]const u8, read_write_count);
    errdefer allocator.free(read_write_paths);
    const read_only_paths = try allocator.alloc([]const u8, read_only_count);
    errdefer allocator.free(read_only_paths);

    var read_write_index: usize = 0;
    var read_only_index: usize = 0;
    index = 0;
    while (index < separator_index) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--rw")) {
            index += 1;
            read_write_paths[read_write_index] = args[index];
            read_write_index += 1;
        } else if (std.mem.eql(u8, args[index], "--ro")) {
            index += 1;
            read_only_paths[read_only_index] = args[index];
            read_only_index += 1;
        }
    }

    return .{
        .read_write_paths = read_write_paths,
        .read_only_paths = read_only_paths,
        .child_argv = child_argv,
    };
}

/// Builds the wrapped step argv: the wrapper prefix, the policy paths, the
/// `--` separator, and the original child argv. The returned slice is owned
/// by the caller; every element is borrowed.
pub fn buildWrappedCommand(
    allocator: std.mem.Allocator,
    wrapper_prefix: []const []const u8,
    read_write_paths: []const []const u8,
    read_only_paths: []const []const u8,
    child_argv: []const []const u8,
) error{OutOfMemory}![][]const u8 {
    const total = wrapper_prefix.len +
        read_write_paths.len * 2 +
        read_only_paths.len * 2 +
        1 +
        child_argv.len;
    const argv = try allocator.alloc([]const u8, total);
    var index: usize = 0;
    for (wrapper_prefix) |entry| {
        argv[index] = entry;
        index += 1;
    }
    for (read_write_paths) |path| {
        argv[index] = "--rw";
        argv[index + 1] = path;
        index += 2;
    }
    for (read_only_paths) |path| {
        argv[index] = "--ro";
        argv[index + 1] = path;
        index += 2;
    }
    argv[index] = "--";
    index += 1;
    for (child_argv) |entry| {
        argv[index] = entry;
        index += 1;
    }
    return argv;
}

test "fullAccessMaskForAbi grows with the ABI version" {
    const abi1 = fullAccessMaskForAbi(1);
    try std.testing.expect(abi1 & access_fs_execute != 0);
    try std.testing.expect(abi1 & access_fs_make_sym != 0);
    try std.testing.expect(abi1 & access_fs_refer == 0);
    try std.testing.expect(abi1 & access_fs_truncate == 0);

    const abi2 = fullAccessMaskForAbi(2);
    try std.testing.expect(abi2 & access_fs_refer != 0);
    try std.testing.expect(abi2 & access_fs_truncate == 0);

    const abi3 = fullAccessMaskForAbi(3);
    try std.testing.expect(abi3 & access_fs_refer != 0);
    try std.testing.expect(abi3 & access_fs_truncate != 0);
}

test "parseWrapperArguments splits policy paths and child argv" {
    const parsed = try parseWrapperArguments(
        std.testing.allocator,
        &.{ "--rw", "/work", "--ro", "/extra", "--rw", "/other", "--", "/bin/bash", "-e", "-c", "true" },
    );
    defer {
        std.testing.allocator.free(parsed.read_write_paths);
        std.testing.allocator.free(parsed.read_only_paths);
    }
    try std.testing.expectEqual(@as(usize, 2), parsed.read_write_paths.len);
    try std.testing.expectEqualStrings("/work", parsed.read_write_paths[0]);
    try std.testing.expectEqualStrings("/other", parsed.read_write_paths[1]);
    try std.testing.expectEqual(@as(usize, 1), parsed.read_only_paths.len);
    try std.testing.expectEqualStrings("/extra", parsed.read_only_paths[0]);
    try std.testing.expectEqual(@as(usize, 4), parsed.child_argv.len);
    try std.testing.expectEqualStrings("/bin/bash", parsed.child_argv[0]);
}

test "parseWrapperArguments rejects malformed wrapper input" {
    try std.testing.expectError(
        error.MissingWrapperSeparator,
        parseWrapperArguments(std.testing.allocator, &.{ "--rw", "/work", "/bin/bash" }),
    );
    try std.testing.expectError(
        error.MissingWrapperPath,
        parseWrapperArguments(std.testing.allocator, &.{ "--rw", "--", "/bin/bash" }),
    );
    try std.testing.expectError(
        error.UnknownWrapperOption,
        parseWrapperArguments(std.testing.allocator, &.{ "--no", "/work", "--", "/bin/bash" }),
    );
    try std.testing.expectError(
        error.EmptyWrapperChildCommand,
        parseWrapperArguments(std.testing.allocator, &.{ "--rw", "/work", "--" }),
    );
}

test "buildWrappedCommand interleaves policy paths before the child argv" {
    const argv = try buildWrappedCommand(
        std.testing.allocator,
        &.{ "shelly", wrapper_argument },
        &.{"/work"},
        &.{"/extra"},
        &.{ "/bin/bash", "-c", "true" },
    );
    defer std.testing.allocator.free(argv);
    const expected = [_][]const u8{
        "shelly", wrapper_argument,
        "--rw",   "/work",
        "--ro",   "/extra",
        "--",     "/bin/bash",
        "-c",     "true",
    };
    try std.testing.expectEqualSlices([]const u8, &expected, argv);
}
