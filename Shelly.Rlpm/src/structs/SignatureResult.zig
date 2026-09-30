//! GnuPG's machine-readable status protocol. Crypto validity, key status, trust,
//! and process failures remain independent; every signature must pass policy.
const std = @import("std");
const SignaturePolicy = @import("SignaturePolicy.zig");

const SignatureResult = @This();

pub const Status = enum {
    valid,
    key_expired,
    signature_expired,
    key_unknown,
    key_disabled,
    key_revoked,
    invalid,
};

pub const Trust = enum { full, marginal, unknown, never };

pub const KeyOperation = struct {
    termination: std.process.Child.Term,
    status_output: []const u8,
    diagnostics: []const u8,
};

pub const Signature = struct {
    status: Status = .invalid,
    trust: Trust = .unknown,
    cryptographically_valid: bool = false,
    key_id: ?[]const u8 = null,
    fingerprint: ?[]const u8 = null,
    primary_fingerprint: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    user_name: ?[]const u8 = null,
    email: ?[]const u8 = null,
    key_created: ?u64 = null,
    key_expires: ?u64 = null,
    key_length: ?u32 = null,
    key_revoked: bool = false,
    created: ?u64 = null,
    expires: ?u64 = null,
    public_key_algorithm: ?u16 = null,
    hash_algorithm: ?u16 = null,
    error_code: ?u32 = null,
    primary_status_seen: bool = false,

    pub fn accepted(self: Signature, policy: SignaturePolicy.Trust) bool {
        if (!self.cryptographically_valid) return false;
        // The pinned libalpm deliberately accepts KEY_EXPIRED subject to trust.
        if (self.status != .valid and self.status != .key_expired) return false;
        return switch (self.trust) {
            .full => true,
            .marginal => policy.allow_marginal,
            .unknown => policy.allow_unknown,
            .never => false,
        };
    }
};
arena: std.heap.ArenaAllocator,
signatures: []Signature,
termination: std.process.Child.Term,
status_output: []const u8,
diagnostics: []const u8,
process_failure: bool = false,
malformed_status: bool = false,
no_data: bool = false,
key_operations: std.ArrayList(KeyOperation) = .empty,

pub fn recordKeyOperation(self: *SignatureResult, operation: KeyOperation) !void {
    const owned = self.arena.allocator();
    try self.key_operations.append(
        owned,
        .{
            .termination = operation.termination,
            .status_output = try owned.dupe(u8, operation.status_output),
            .diagnostics = try owned.dupe(u8, operation.diagnostics),
        },
    );
}

pub fn deinit(self: *SignatureResult) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn check(self: *const SignatureResult, trust: SignaturePolicy.Trust) !void {
    if (self.process_failure) return error.GpgFailed;
    if (self.malformed_status or self.no_data or self.signatures.len == 0) return error.InvalidSignature;
    for (self.signatures) |signature|
        if (!signature.accepted(trust)) return error.InvalidSignature;
}

pub fn parse(
    allocator: std.mem.Allocator,
    status: []const u8,
    diagnostics: []const u8,
    term: std.process.Child.Term,
) !SignatureResult {
    var result: SignatureResult = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .signatures = &.{},
        .termination = term,
        .status_output = undefined,
        .diagnostics = undefined,
    };
    errdefer result.deinit();
    const owned = result.arena.allocator();
    result.status_output = try owned.dupe(u8, status);
    result.diagnostics = try owned.dupe(u8, diagnostics);
    var signatures: std.ArrayList(Signature) = .empty;
    var current: ?Signature = null;
    var lines = std.mem.splitScalar(u8, result.status_output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, "[GNUPG:] ")) continue;
        const body = line[9..];
        const end = std.mem.indexOfScalar(u8, body, ' ') orelse body.len;
        const name = body[0..end];
        const args = if (end == body.len) "" else body[end + 1 ..];
        if (std.mem.eql(u8, name, "NEWSIG")) {
            if (current) |signature| try signatures.append(owned, signature);
            current = .{};
            continue;
        }
        if (std.mem.eql(u8, name, "NODATA")) {
            result.no_data = true;
            continue;
        }
        if (std.mem.eql(u8, name, "FAILURE") or std.mem.eql(u8, name, "ERROR")) {
            // gpg-exit is a summary of ordinary bad/missing-key signatures.
            if (!std.mem.startsWith(u8, args, "gpg-exit ")) result.process_failure = true;
            continue;
        }
        if (std.mem.eql(u8, name, "GOODSIG") or std.mem.eql(u8, name, "BADSIG") or
            std.mem.eql(u8, name, "EXPSIG") or
            std.mem.eql(u8, name, "EXPKEYSIG") or
            std.mem.eql(u8, name, "REVKEYSIG") or
            std.mem.eql(u8, name, "ERRSIG"))
        {
            if (current == null) current = .{};
            if (current.?.primary_status_seen) result.malformed_status = true;
            current.?.primary_status_seen = true;
            parsePrimary(owned, &current.?, name, args) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => result.malformed_status = true,
            };
            continue;
        }
        if (std.mem.eql(u8, name, "VALIDSIG")) {
            if (current == null) current = .{};
            parseValid(&current.?, args) catch {
                result.malformed_status = true;
            };
        } else if (std.mem.eql(u8, name, "NO_PUBKEY")) {
            if (current == null) current = .{};
            current.?.status = .key_unknown;
            if (current.?.key_id == null and validIdentifier(args)) current.?.key_id = args;
        } else if (std.mem.startsWith(u8, name, "TRUST_")) {
            if (current == null) {
                result.malformed_status = true;
                continue;
            }
            current.?.trust = if (std.mem.eql(u8, name, "TRUST_FULLY") or
                std.mem.eql(u8, name, "TRUST_ULTIMATE"))
                .full
            else if (std.mem.eql(u8, name, "TRUST_MARGINAL"))
                .marginal
            else if (std.mem.eql(u8, name, "TRUST_NEVER"))
                .never
            else
                .unknown;
        }
    }
    if (current) |signature| try signatures.append(owned, signature);
    result.signatures = try signatures.toOwnedSlice(owned);
    switch (term) {
        .exited => |code| {
            // Nonzero is expected for BADSIG/ERRSIG etc, but an otherwise good
            // result must never conceal a process failure.
            if (code != 0) {
                var explained = result.no_data;
                for (result.signatures) |signature| {
                    if (signature.primary_status_seen and signature.status != .valid and
                        signature.status != .key_expired)
                        explained = true;
                }
                if (!explained) result.process_failure = true;
            }
        },
        else => result.process_failure = true,
    }
    for (result.signatures) |signature|
        if (!signature.primary_status_seen) {
            result.malformed_status = true;
        };
    return result;
}

pub fn validIdentifier(value: []const u8) bool {
    if (value.len != 16 and value.len != 32 and value.len != 40 and value.len != 64) return false;
    for (value) |byte|
        if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn parsePrimary(
    allocator: std.mem.Allocator,
    signature: *Signature,
    name: []const u8,
    args: []const u8,
) !void {
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    const id = words.next() orelse return error.InvalidStatus;
    if (!validIdentifier(id)) return error.InvalidStatus;
    signature.key_id = id;
    signature.status = if (std.mem.eql(u8, name, "GOODSIG"))
        .valid
    else if (std.mem.eql(u8, name, "EXPSIG"))
        .signature_expired
    else if (std.mem.eql(u8, name, "EXPKEYSIG"))
        .key_expired
    else if (std.mem.eql(u8, name, "REVKEYSIG"))
        .key_revoked
    else
        .invalid;
    if (std.mem.eql(u8, name, "ERRSIG")) {
        signature.public_key_algorithm = try std.fmt.parseInt(
            u16,
            words.next() orelse
                return error.InvalidStatus,
            10,
        );
        signature.hash_algorithm = try std.fmt.parseInt(
            u16,
            words.next() orelse return error.InvalidStatus,
            10,
        );
        _ = words.next() orelse return error.InvalidStatus;
        signature.created = try std.fmt.parseInt(u64, words.next() orelse return error.InvalidStatus, 10);
        signature.error_code = try std.fmt.parseInt(u32, words.next() orelse return error.InvalidStatus, 10);
        if (signature.error_code == 9) signature.status = .key_unknown;
        if (words.next()) |fpr|
            if (!std.mem.eql(u8, fpr, "-")) {
                if (!validIdentifier(fpr)) return error.InvalidStatus;
                signature.fingerprint = fpr;
            };
    } else {
        const username = std.mem.trimStart(u8, args[id.len..], " ");
        var decoded: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < username.len) : (i += 1) {
            if (username[i] == '%') {
                if (i + 3 > username.len) return error.InvalidStatus;
                try decoded.append(allocator, try std.fmt.parseInt(u8, username[i + 1 ..][0..2], 16));
                i += 2;
            } else try decoded.append(allocator, username[i]);
        }
        signature.user_id = try decoded.toOwnedSlice(allocator);
        const uid = signature.user_id.?;
        const name_end = std.mem.indexOfAny(u8, uid, "(<") orelse uid.len;
        signature.user_name = std.mem.trim(u8, uid[0..name_end], " \t");
        if (std.mem.indexOfScalar(u8, uid, '<')) |start|
            if (std.mem.indexOfScalarPos(u8, uid, start + 1, '>')) |finish| {
                signature.email = uid[start + 1 .. finish];
            };
    }
}

fn parseValid(signature: *Signature, args: []const u8) !void {
    if (signature.cryptographically_valid) return error.InvalidStatus;
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    const fpr = words.next() orelse return error.InvalidStatus;
    if (!validIdentifier(fpr) or fpr.len == 16) return error.InvalidStatus;
    signature.fingerprint = fpr;
    _ = words.next() orelse return error.InvalidStatus;
    signature.created = try std.fmt.parseInt(u64, words.next() orelse return error.InvalidStatus, 10);
    signature.expires = try std.fmt.parseInt(u64, words.next() orelse return error.InvalidStatus, 10);
    _ = words.next() orelse return error.InvalidStatus;
    _ = words.next() orelse return error.InvalidStatus;
    signature.public_key_algorithm = try std.fmt.parseInt(
        u16,
        words.next() orelse return error.InvalidStatus,
        10,
    );
    signature.hash_algorithm = try std.fmt.parseInt(u16, words.next() orelse return error.InvalidStatus, 10);
    _ = words.next() orelse return error.InvalidStatus;
    signature.primary_fingerprint = words.next() orelse fpr;
    if (!validIdentifier(signature.primary_fingerprint.?)) return error.InvalidStatus;
    signature.cryptographically_valid = true;
}
