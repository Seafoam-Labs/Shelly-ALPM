//! CachyOS's physical-architecture query, pinned to cpu_capabilities.c. This is
//! runtime CPU/OS probing; the binary's compilation target is not the host ISA.
const std = @import("std");
const builtin = @import("builtin");

// Feature-selection rules adapted from CachyOS pacman cpu_capabilities.c,
// copyright 2022-2023 Vladislav Nepogodin, GPL-2.0-or-later.
// Pinned source and license: ../tests/reference/downstream-source-tests.tar.gz
// and ../tests/reference/COPYING.
const PhysicalArchitectures = @This();

arena: std.heap.ArenaAllocator,
names: []const []const u8,

const Probe = struct {
    machine: []const u8,
    leaf1_ecx: u32 = 0,
    leaf7_ebx: u32 = 0,
    xcr0: u32 = 0,
};

pub fn init(allocator: std.mem.Allocator) !PhysicalArchitectures {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    var info: std.c.utsname = undefined;
    if (std.c.uname(&info) != 0) return error.SystemInformationUnavailable;
    var probe: Probe = .{ .machine = std.mem.sliceTo(&info.machine, 0) };
    if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) {
        const max_leaf = cpuid(0).eax;
        if (max_leaf >= 1) probe.leaf1_ecx = cpuid(1).ecx;
        if (max_leaf >= 7) probe.leaf7_ebx = cpuid(7).ebx;
        if (probe.leaf1_ecx & (@as(u32, 1) << 27) != 0) {
            probe.xcr0 = asm volatile ("xgetbv"
                : [_] "={eax}" (-> u32),
                : [_] "{ecx}" (@as(u32, 0)),
                : .{ .edx = true });
        }
    }
    return fromProbe(allocator, probe);
}

fn cpuid(leaf: u32) struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
} {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf),
          [_] "{ecx}" (@as(u32, 0)),
    );
    return .{
        .eax = eax,
        .ebx = ebx,
        .ecx = ecx,
    };
}

fn fromProbe(allocator: std.mem.Allocator, probe: Probe) !PhysicalArchitectures {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    try names.append(owned, try owned.dupe(u8, probe.machine));
    if (!std.mem.eql(u8, probe.machine, "aarch64")) {
        // The pinned CachyOS source labels ECX bit 0 as SSSE3. Preserve that
        // observed test, rather than substituting a different ISA-level policy.
        const v2_bits: u32 = (1 << 0) | (1 << 19) | (1 << 20);
        const v3_bits: u32 = (1 << 27) | (1 << 28);
        const v4_bits: u32 = (1 << 16) | (1 << 17) | (1 << 28) | (1 << 30) | (1 << 31);
        const v2 = probe.leaf1_ecx & v2_bits == v2_bits;
        const v3 = v2 and probe.leaf1_ecx & v3_bits == v3_bits and probe.xcr0 & 6 == 6 and
            probe.leaf7_ebx & (1 << 5) != 0;
        const v4 = v3 and probe.xcr0 & 224 == 224 and probe.leaf7_ebx & v4_bits == v4_bits;
        if (v2) try names.append(owned, "x86_64_v2");
        if (v3) try names.append(owned, "x86_64_v3");
        if (v4) try names.append(owned, "x86_64_v4");
    }
    return .{ .arena = arena, .names = try names.toOwnedSlice(owned) };
}

pub fn deinit(self: *PhysicalArchitectures) void {
    self.arena.deinit();
    self.* = undefined;
}

test "CachyOS architecture levels follow CPU bits and OS-enabled vector state" {
    const cases = [_]struct {
        probe: Probe,
        count: usize,
    }{
        .{
            .probe = .{
                .machine = "aarch64",
                .leaf1_ecx = 0xffffffff,
                .leaf7_ebx = 0xffffffff,
                .xcr0 = 0xffffffff,
            },
            .count = 1,
        },
        .{ .probe = .{ .machine = "x86_64" }, .count = 1 },
        .{ .probe = .{ .machine = "x86_64", .leaf1_ecx = (1 << 0) | (1 << 19) | (1 << 20) }, .count = 2 },
        .{ .probe = .{
            .machine = "x86_64",
            .leaf1_ecx = 0xffffffff,
            .leaf7_ebx = 0xffffffff,
        }, .count = 2 },
        .{
            .probe = .{
                .machine = "x86_64",
                .leaf1_ecx = 0xffffffff,
                .leaf7_ebx = 0xffffffff,
                .xcr0 = 6,
            },
            .count = 3,
        },
        .{
            .probe = .{
                .machine = "x86_64",
                .leaf1_ecx = 0xffffffff,
                .leaf7_ebx = 0xffffffff,
                .xcr0 = 230,
            },
            .count = 4,
        },
        .{
            .probe = .{
                .machine = "x86_64",
                .leaf1_ecx = 0xffffffff,
                .leaf7_ebx = 0xffffffff & ~@as(u32, 1 << 17),
                .xcr0 = 230,
            },
            .count = 3,
        },
        .{
            .probe = .{
                .machine = "x86_64",
                .leaf1_ecx = 0xffffffff & ~@as(u32, 1),
                .leaf7_ebx = 0xffffffff,
                .xcr0 = 230,
            },
            .count = 1,
        },
    };
    for (cases) |case| {
        var result = try fromProbe(std.testing.allocator, case.probe);
        defer result.deinit();
        try std.testing.expectEqual(case.count, result.names.len);
        try std.testing.expectEqualStrings(case.probe.machine, result.names[0]);
        const suffixes = [_][]const u8{ "x86_64_v2", "x86_64_v3", "x86_64_v4" };
        for (result.names[1..], 0..) |name, i|
            try std.testing.expectEqualStrings(suffixes[i], name);
    }
}

test "physical architecture result cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var result = try fromProbe(
                allocator,
                .{
                    .machine = "x86_64",
                    .leaf1_ecx = 0xffffffff,
                    .leaf7_ebx = 0xffffffff,
                    .xcr0 = 230,
                },
            );
            defer result.deinit();
        }
    }.run, .{});
}
