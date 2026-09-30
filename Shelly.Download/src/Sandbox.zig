//! Linux download confinement, applied in the fresh worker before transport starts.
//! Deny list follows pacman sandbox_syscalls.c, Copyright 2021–2025 Pacman
//! Development Team, GPL-2.0-or-later; see ../COPYING.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const bpf = linux.BPF;
const seccomp = linux.SECCOMP;
pub const Error = error{ DownloadSandboxFailed, UnsupportedSandboxArchitecture };
extern "c" fn setgroups(usize, [*]const std.c.gid_t) c_int;

pub fn apply(user: [:0]const u8, directory: [:0]const u8, filesystem: bool, syscalls: bool) Error!void {
    if (std.c.getuid() != 0) return error.DownloadSandboxFailed;
    // Resolve NSS identities before Landlock or seccomp restricts the worker.
    const account = std.c.getpwnam(user) orelse return error.DownloadSandboxFailed;
    const uid = account.uid;
    const gid = account.gid;
    try noNewPrivileges();
    if (filesystem) try restrictFilesystem(directory);
    if (syscalls) try restrictSyscalls();
    // libc's credential wrappers coordinate all threads, unlike raw setuid.
    if (std.c.setgid(gid) != 0 or setgroups(0, &.{}) != 0 or std.c.setuid(uid) != 0) return error.DownloadSandboxFailed;
}

pub fn noNewPrivileges() Error!void {
    if (linux.errno(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS) return error.DownloadSandboxFailed;
}

const Ruleset = extern struct { handled_access_fs: u64 };
const PathRule = extern struct { allowed_access: u64, parent_fd: i32 };
const access = struct {
    const execute: u64 = 1 << 0;
    const write_file: u64 = 1 << 1;
    const read_file: u64 = 1 << 2;
    const read_dir: u64 = 1 << 3;
    const read: u64 = read_file | read_dir;
    const write: u64 = write_file | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 7) | (1 << 8) | (1 << 9) | (1 << 10) | (1 << 11) | (1 << 12);
    const refer: u64 = 1 << 13;
    const truncate: u64 = 1 << 14;
};

fn checkedFd(result: usize) Error!linux.fd_t {
    if (linux.errno(result) != .SUCCESS) return error.DownloadSandboxFailed;
    return @intCast(result);
}
fn addPathRule(ruleset: linux.fd_t, path: [:0]const u8, allowed: u64) Error!void {
    const directory = try checkedFd(linux.open(path, .{ .PATH = true, .CLOEXEC = true }, 0));
    defer _ = linux.close(directory);
    const rule: PathRule = .{ .allowed_access = allowed, .parent_fd = directory };
    if (linux.errno(linux.syscall4(.landlock_add_rule, @intCast(ruleset), 1, @intFromPtr(&rule), 0)) != .SUCCESS) return error.DownloadSandboxFailed;
}
pub fn restrictFilesystem(directory: [:0]const u8) Error!void {
    const abi = linux.syscall3(.landlock_create_ruleset, 0, 0, 1);
    if (linux.errno(abi) != .SUCCESS or abi < 1) return error.DownloadSandboxFailed;
    const write = access.write | (if (abi >= 3) access.truncate else @as(u64, 0));
    const attributes: Ruleset = .{ .handled_access_fs = access.read | write | access.execute | (if (abi >= 2) access.refer else @as(u64, 0)) };
    const ruleset = try checkedFd(linux.syscall3(.landlock_create_ruleset, @intFromPtr(&attributes), @sizeOf(Ruleset), 0));
    defer _ = linux.close(ruleset);
    try addPathRule(ruleset, "/", access.read);
    try addPathRule(ruleset, directory, access.read | write);
    try addPathRule(ruleset, "/dev/null", access.read_file | access.write_file);
    if (linux.errno(linux.syscall2(.landlock_restrict_self, @intCast(ruleset), 0)) != .SUCCESS) return error.DownloadSandboxFailed;
}

const Instruction = extern struct {
    code: u16,
    yes: u8 = 0,
    no: u8 = 0,
    value: u32,
};
const Program = extern struct { length: u16, filter: [*]const Instruction };

const denied_syscalls = .{
    "delete_module", "finit_module",  "init_module",     "chroot",        "fsconfig",        "fsmount",           "fsopen",      "fspick",       "mount",            "mount_setattr",  "move_mount",      "open_tree",       "pivot_root", "umount",          "umount2",
    "add_key",       "keyctl",        "request_key",     "modify_ldt",    "subpage_prot",    "switch_endian",     "vm86",        "vm86old",      "kcmp",             "lookup_dcookie", "perf_event_open", "pidfd_getfd",     "ptrace",     "rtas",            "sys_debug_setcontext",
    "adjtimex",      "clock_adjtime", "clock_adjtime64", "clock_settime", "clock_settime64", "settimeofday",      "ioperm",      "iopl",         "pciconfig_iobase", "pciconfig_read", "pciconfig_write", "kexec_file_load", "kexec_load", "reboot",          "acct",
    "bpf",           "capset",        "fanotify_init",   "fanotify_mark", "nfsservctl",      "open_by_handle_at", "personality", "_sysctl",      "afs_syscall",      "bdflush",        "break",           "create_module",   "ftime",      "get_kernel_syms", "getpmsg",
    "gtty",          "idle",          "lock",            "mpx",           "prof",            "profil",            "putpmsg",     "query_module", "security",         "sgetmask",       "ssetmask",        "stime",           "stty",       "sysfs",           "tuxcall",
    "ulimit",        "uselib",        "ustat",           "vserver",       "swapon",          "swapoff",
};

const Filter = struct {
    instructions: [8 + denied_syscalls.len * 2]Instruction = undefined,
    length: u16 = 0,
    fn append(self: *Filter, instruction: Instruction) void {
        self.instructions[self.length] = instruction;
        self.length += 1;
    }
};
fn auditArchitecture() ?u32 {
    // Zig 0.16's AUDIT.ARCH references a missing elf.EM.FRV member. Construct
    // the Linux UAPI value directly until that standard-library enum is fixed.
    const machine: std.elf.EM = switch (builtin.cpu.arch) {
        .x86 => .@"386",
        .x86_64 => .X86_64,
        .aarch64, .aarch64_be => .AARCH64,
        .arm, .armeb, .thumb, .thumbeb => .ARM,
        .riscv32, .riscv64 => .RISCV,
        .loongarch32, .loongarch64 => .LOONGARCH,
        .powerpc, .powerpcle => .PPC,
        .powerpc64, .powerpc64le => .PPC64,
        .s390x => .S390,
        .mips, .mipsel, .mips64, .mips64el => .MIPS,
        else => return null,
    };
    const wide: u32 = switch (builtin.cpu.arch) {
        .x86_64, .aarch64, .aarch64_be, .riscv64, .loongarch64, .powerpc64, .powerpc64le, .s390x, .mips64, .mips64el => 0x80000000,
        else => 0,
    };
    const little: u32 = if (builtin.cpu.arch.endian() == .little) 0x40000000 else 0;
    const n32: u32 = if (builtin.abi == .gnuabin32 or builtin.abi == .muslabin32) 0x20000000 else 0;
    return @as(u32, @intFromEnum(machine)) | wide | little | n32;
}
fn compileFilter() Error!Filter {
    var filter: Filter = .{};
    // Reject alternate syscall ABIs; their numbers must not bypass this list.
    filter.append(.{ .code = bpf.LD | bpf.W | bpf.ABS, .value = @offsetOf(seccomp.data, "arch") });
    filter.append(.{ .code = bpf.JMP | bpf.JEQ | bpf.K, .yes = 1, .value = auditArchitecture() orelse return error.UnsupportedSandboxArchitecture });
    filter.append(.{ .code = bpf.RET | bpf.K, .value = seccomp.RET.KILL_PROCESS });
    filter.append(.{ .code = bpf.LD | bpf.W | bpf.ABS, .value = @offsetOf(seccomp.data, "nr") });
    if (builtin.cpu.arch == .x86_64) {
        const x32 = builtin.abi == .gnux32 or builtin.abi == .muslx32;
        filter.append(.{ .code = bpf.JMP | bpf.JSET | bpf.K, .yes = if (x32) 1 else 0, .no = if (x32) 0 else 1, .value = 0x40000000 });
        filter.append(.{ .code = bpf.RET | bpf.K, .value = seccomp.RET.KILL_PROCESS });
    }
    inline for (denied_syscalls) |name| {
        if (@hasField(linux.SYS, name)) {
            filter.append(.{ .code = bpf.JMP | bpf.JEQ | bpf.K, .no = 1, .value = @intFromEnum(@field(linux.SYS, name)) });
            filter.append(.{ .code = bpf.RET | bpf.K, .value = seccomp.RET.ERRNO | @as(u32, @intFromEnum(linux.E.PERM)) });
        }
    }
    filter.append(.{ .code = bpf.RET | bpf.K, .value = seccomp.RET.ALLOW });
    return filter;
}
pub fn restrictSyscalls() Error!void {
    const filter = try compileFilter();
    const program: Program = .{ .length = filter.length, .filter = &filter.instructions };
    if (linux.errno(linux.seccomp(seccomp.SET_MODE_FILTER, 0, &program)) != .SUCCESS) return error.DownloadSandboxFailed;
}

// Evaluate the generated cBPF decision tree without confining the test runner.
fn decision(filter: Filter, architecture: u32, number: u32) u32 {
    var accumulator: u32 = 0;
    var index: usize = 0;
    while (index < filter.length) : (index += 1) {
        const instruction = filter.instructions[index];
        switch (instruction.code) {
            bpf.LD | bpf.W | bpf.ABS => accumulator = if (instruction.value == @offsetOf(seccomp.data, "arch")) architecture else number,
            bpf.JMP | bpf.JEQ | bpf.K => index += if (accumulator == instruction.value) instruction.yes else instruction.no,
            bpf.JMP | bpf.JSET | bpf.K => index += if (accumulator & instruction.value != 0) instruction.yes else instruction.no,
            bpf.RET | bpf.K => return instruction.value,
            else => unreachable,
        }
    }
    unreachable;
}
test "sandbox filters deny privileged syscalls and reject alternate ABIs" {
    const filter = try compileFilter();
    const architecture = auditArchitecture().?;
    for ([_]linux.SYS{ .read, .write, .openat, .socket, .connect, .setuid, .setgid, .setgroups }) |number|
        try std.testing.expectEqual(seccomp.RET.ALLOW, decision(filter, architecture, @intCast(@intFromEnum(number))));
    inline for (denied_syscalls) |name| if (@hasField(linux.SYS, name)) {
        try std.testing.expectEqual(seccomp.RET.ERRNO | @as(u32, @intFromEnum(linux.E.PERM)), decision(filter, architecture, @intFromEnum(@field(linux.SYS, name))));
    };
    try std.testing.expectEqual(seccomp.RET.KILL_PROCESS, decision(filter, architecture ^ 1, @intFromEnum(linux.SYS.read)));
    if (builtin.cpu.arch == .x86_64) try std.testing.expectEqual(seccomp.RET.KILL_PROCESS, decision(filter, architecture, @intFromEnum(linux.SYS.read) ^ 0x40000000));
}
