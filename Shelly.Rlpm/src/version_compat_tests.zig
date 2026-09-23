//! Opt-in differential tests. libalpm is linked only into this test executable.
const std = @import("std");
const Version = @import("structs/Version.zig");
const fixtures = @import("structs/fixtures/version_comparisons.zig");

extern "alpm" fn alpm_pkg_vercmp(a: [*:0]const u8, b: [*:0]const u8) c_int;
extern "alpm" fn alpm_version() [*:0]const u8;

const seed: u64 = 0x524c504d;
const generated_pairs = 20_000;

test "version comparison agrees with the libalpm oracle" {
    const oracle_version = std.mem.span(alpm_version());
    std.debug.print("\nversion oracle: libalpm {s}; seed: 0x{x}\n", .{ oracle_version, seed });
    // Updating the oracle requires reviewing and recording fixture provenance.
    try std.testing.expectEqualStrings("16.0.1", oracle_version);
    for (fixtures.cases) |case| {
        try std.testing.expectEqual(case.expected, oracle(case.left, case.right));
        try checkPair(case.left, case.right);
    }
    // Crossing the corpus catches interactions absent from the original pairs.
    for (fixtures.cases) |left| {
        for (fixtures.cases) |right| try checkPair(left.left, right.right);
    }

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    for (0..generated_pairs) |iteration| {
        var left_buffer: [256]u8 = undefined;
        var right_buffer: [256]u8 = undefined;
        const left = generateVersion(random, &left_buffer, iteration % 2 == 0);
        const right = if (iteration % 3 == 0) correlated: {
            @memcpy(right_buffer[0..left.len], left);
            if (left.len > 0) right_buffer[random.uintLessThan(usize, left.len)] = random.intRangeAtMost(u8, 1, 127);
            right_buffer[left.len] = 0;
            break :correlated right_buffer[0..left.len :0];
        } else generateVersion(random, &right_buffer, iteration % 2 == 0);
        checkPair(left, right) catch |err| {
            std.debug.print("generated iteration: {d}, seed: 0x{x}\n", .{ iteration, seed });
            return err;
        };
    }
    std.debug.print("checked {d} fixtures, {d} cross-corpus pairs, {d} generated pairs\n", .{
        fixtures.cases.len, fixtures.cases.len * fixtures.cases.len, generated_pairs,
    });
}

fn oracle(left: [:0]const u8, right: [:0]const u8) i8 {
    return @intCast(std.math.sign(alpm_pkg_vercmp(left, right)));
}

fn checkPair(left: [:0]const u8, right: [:0]const u8) !void {
    const expected = oracle(left, right);
    const actual = @intFromEnum(Version.compareStrings(left, right));
    errdefer std.debug.print("left bytes: {any}\nright bytes: {any}\nRLPM: {d}, libalpm: {d}\n", .{
        left, right, actual, expected,
    });
    try std.testing.expectEqual(expected, actual);
    try std.testing.expectEqual(-expected, oracle(right, left));
    try std.testing.expectEqual(-expected, @intFromEnum(Version.compareStrings(right, left)));
    try std.testing.expectEqual(.equal, Version.compareStrings(left, left));
    try std.testing.expectEqual(.equal, Version.compareStrings(right, right));
    Version.validate(left) catch return;
    Version.validate(right) catch return;
    var owned_left = try Version.init(left, std.testing.allocator);
    defer owned_left.deinit(std.testing.allocator);
    var owned_right = try Version.init(right, std.testing.allocator);
    defer owned_right.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected, @intFromEnum(Version.compareVersions(owned_left, owned_right)));
}

fn generateVersion(random: std.Random, buffer: *[256]u8, structured: bool) [:0]const u8 {
    if (!structured) {
        const len = random.intRangeAtMost(usize, 0, 128);
        for (buffer[0..len]) |*byte| byte.* = random.intRangeAtMost(u8, 1, 127);
        buffer[len] = 0;
        return buffer[0..len :0];
    }
    const epochs = [_][]const u8{
        "",                      "0:",                       "00:",                                                 "1:", "0001:", "2:", ":", "+1:", "1_0:", "alpha:",
        "18446744073709551616:", "00018446744073709551616:", "99999999999999999999999999999999999999999999999999:",
    };
    const versions = [_][]const u8{
        "",      "0",     "1",   "1.0", "01.00", "1..0", "1...",   "1a",                                     "1alpha", "1rc1", "1.A", "1.a",
        "1~rc1", "1+git", "1_0", "1:2", "::",    "-",    "1-beta", "1.999999999999999999999999999999999999",
    };
    const releases = [_][]const u8{ "", "-", "-1", "-2", "-01", "-a", "-1.2", "-2-3", "-999999999999999999999999999999" };
    return std.fmt.bufPrintZ(buffer, "{s}{s}{s}", .{
        epochs[random.uintLessThan(usize, epochs.len)],
        versions[random.uintLessThan(usize, versions.len)],
        releases[random.uintLessThan(usize, releases.len)],
    }) catch unreachable; // The longest combination fits comfortably in buffer.
}
