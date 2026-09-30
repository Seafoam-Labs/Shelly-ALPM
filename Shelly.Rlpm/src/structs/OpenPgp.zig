//! Bounded binary OpenPGP v4 signature inspection, not cryptographic validation.
const std = @import("std");

pub const max_signature_size = 16384;

pub fn decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const length = try decoder.calcSizeForSlice(encoded);
    if (length > max_signature_size) return error.SignatureTooLarge;
    const bytes = try allocator.alloc(u8, length);
    errdefer allocator.free(bytes);
    try decoder.decode(bytes, encoded);
    return bytes;
}

pub fn readDetached(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    const sigpath = try std.fmt.allocPrint(allocator, "{s}.sig", .{path});
    defer allocator.free(sigpath);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, sigpath, allocator, .limited(max_signature_size + 1)) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.StreamTooLong => return error.SignatureTooLarge,
        else => return err,
    };
    if (bytes.len > max_signature_size) {
        allocator.free(bytes);
        return error.SignatureTooLarge;
    }
    return bytes;
}

test "detached signatures accept the size boundary and reject larger files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "package" });
    defer a.free(path);
    const bytes = [_]u8{0} ** (max_signature_size + 1);
    try temporary.dir.writeFile(io, .{ .sub_path = "package.sig", .data = bytes[0..max_signature_size] });
    const accepted = (try readDetached(a, io, path)).?;
    defer a.free(accepted);
    try std.testing.expectEqual(max_signature_size, accepted.len);
    try temporary.dir.writeFile(io, .{ .sub_path = "package.sig", .data = &bytes });
    try std.testing.expectError(error.SignatureTooLarge, readDetached(a, io, path));
}

pub const Issuers = struct {
    arena: std.heap.ArenaAllocator,
    key_ids: []const []const u8,
    fingerprints: []const []const u8,

    pub fn deinit(self: *Issuers) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Cursor = struct {
    bytes: []const u8,

    fn take(self: *Cursor, n: usize) ![]const u8 {
        if (n > self.bytes.len) return error.InvalidSignaturePacket;
        defer self.bytes = self.bytes[n..];
        return self.bytes[0..n];
    }

    fn byte(self: *Cursor) !u8 {
        return (try self.take(1))[0];
    }

    fn number(self: *Cursor, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .big);
    }

    fn length(self: *Cursor) !usize {
        const first = try self.byte();
        return switch (first) {
            0...191 => first,
            192...223 => (@as(usize, first) - 192) * 256 + @as(usize, try self.byte()) + 192,
            255 => try self.number(u32),
            else => error.UnsupportedSignaturePacket,
        };
    }
};

fn subpackets(
    allocator: std.mem.Allocator,
    data: []const u8,
    ids: *std.ArrayList([]const u8),
    fingerprints: *std.ArrayList([]const u8),
) !void {
    var cursor: Cursor = .{ .bytes = data };
    var found_id = false;
    while (cursor.bytes.len != 0) {
        const packet = try cursor.take(try cursor.length());
        if (packet.len == 0) return error.InvalidSignaturePacket;
        switch (packet[0] & 0x7f) {
            16 => {
                if (packet.len != 9) return error.InvalidSignaturePacket;
                if (!found_id)
                    try ids.append(
                        allocator,
                        try std.fmt.allocPrint(
                            allocator,
                            "{X}",
                            .{packet[1..]},
                        ),
                    );
                found_id = true;
            },
            33 => {
                if (packet.len != 22 or packet[1] != 4) return error.UnsupportedSignaturePacket;
                try fingerprints.append(allocator, try std.fmt.allocPrint(allocator, "{X}", .{packet[2..]}));
            },
            else => {},
        }
    }
}

/// Key IDs follow the reference's issuer subpackets (including ordered duplicates
/// across hashed/unhashed sections). Fingerprints expose issuer-fingerprint data.
pub fn extractIssuers(allocator: std.mem.Allocator, bytes: []const u8) !Issuers {
    if (bytes.len > max_signature_size) return error.SignatureTooLarge;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    var ids: std.ArrayList([]const u8) = .empty;
    var fingerprints: std.ArrayList([]const u8) = .empty;
    var cursor: Cursor = .{ .bytes = bytes };
    if (bytes.len == 0) return error.InvalidSignaturePacket;
    while (cursor.bytes.len != 0) {
        const header = try cursor.byte();
        if (header & 0x80 == 0) return error.InvalidSignaturePacket;
        const tag = if (header & 0x40 != 0) header & 0x3f else (header >> 2) & 0xf;
        if (tag != 2) return error.UnsupportedSignaturePacket;
        const length = if (header & 0x40 != 0) try cursor.length() else switch (header & 3) {
            0 => @as(usize, try cursor.byte()),
            1 => @as(usize, try cursor.number(u16)),
            2 => @as(usize, try cursor.number(u32)),
            else => return error.UnsupportedSignaturePacket,
        };
        var packet: Cursor = .{ .bytes = try cursor.take(length) };
        if (try packet.byte() != 4 or try packet.byte() != 0) return error.UnsupportedSignaturePacket;
        _ = try packet.take(2); // Public-key and digest algorithms.
        try subpackets(owned, try packet.take(try packet.number(u16)), &ids, &fingerprints);
        try subpackets(owned, try packet.take(try packet.number(u16)), &ids, &fingerprints);
        _ = try packet.take(2); // Digest prefix; MPI verification belongs to GPG.
        if (packet.bytes.len == 0) return error.InvalidSignaturePacket;
    }
    return .{
        .arena = arena,
        .key_ids = try ids.toOwnedSlice(owned),
        .fingerprints = try fingerprints.toOwnedSlice(owned),
    };
}
