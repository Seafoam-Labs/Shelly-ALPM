const std = @import("std");
const core = @import("core.zig");
const Value = core.value.Value;
const DBusWriter = core.value.DBusWriter;
const Serializer = core.value.Serializer;
const dbusAlignOf = core.value.dbusAlignOf;

/// Helper to encode a set of values into a D-Bus message body.
pub const BodyEncoder = struct {
    allocator: std.mem.Allocator,
    body_list: std.ArrayList(u8),
    signature_list: std.ArrayList(u8),
    endian: std.builtin.Endian,

    /// Encodes a single value or a tuple of values into a new BodyEncoder.
    pub fn encode(allocator: std.mem.Allocator, values: anytype) !BodyEncoder {
        var self = BodyEncoder{
            .allocator = allocator,
            .body_list = try std.ArrayList(u8).initCapacity(allocator, 256),
            .signature_list = try std.ArrayList(u8).initCapacity(allocator, 32),
            .endian = .little,
        };
        errdefer self.deinit();

        const T = @TypeOf(values);
        const type_info = @typeInfo(T);

        if (type_info == .@"struct" and type_info.@"struct".is_tuple) {
            inline for (values) |v| {
                try self.appendValue(v);
            }
        } else {
            try self.appendValue(values);
        }

        // Ensure signature is null-terminated
        try self.signature_list.append(allocator, 0);

        return self;
    }

    /// Releases resources used by the encoder.
    pub fn deinit(self: *BodyEncoder) void {
        self.body_list.deinit(self.allocator);
        self.signature_list.deinit(self.allocator);
    }

    fn appendValue(self: *BodyEncoder, value: anytype) !void {
        const T = @TypeOf(value);
        if (T == void) return;
        const sig_len = Value.reprLength(T);
        var sig_buf: [256]u8 = undefined;
        Value.getRepr(T, sig_len, 0, sig_buf[0..sig_len]);
        try self.signature_list.appendSlice(self.allocator, sig_buf[0..sig_len]);

        var writer = DBusWriter.init(&self.body_list, self.allocator, self.endian);
        try writer.padTo(dbusAlignOf(T));
        try Serializer.trySerialize(T, value, &writer);
    }

    /// Returns the encoded body bytes.
    pub fn body(self: BodyEncoder) []const u8 {
        return self.body_list.items;
    }

    /// Returns the generated signature string.
    pub fn signature(self: BodyEncoder) [:0]const u8 {
        return self.signature_list.items[0 .. self.signature_list.items.len - 1 :0];
    }
};

/// Helper to decode values from a D-Bus message body according to its signature.
pub const BodyDecoder = struct {
    allocator: std.mem.Allocator,
    body: []const u8,
    signature: []const u8,
    pos: usize,
    sig_pos: usize,
    endian: std.builtin.Endian,

    /// Initializes a decoder with raw body and signature.
    pub fn init(allocator: std.mem.Allocator, body: []const u8, signature: []const u8, endian: std.builtin.Endian) BodyDecoder {
        return .{
            .allocator = allocator,
            .body = body,
            .signature = signature,
            .pos = 0,
            .sig_pos = 0,
            .endian = endian,
        };
    }

    /// Initializes a decoder from a Message, extracting the signature from header fields.
    pub fn fromMessage(allocator: std.mem.Allocator, msg: core.Message) BodyDecoder {
        var sig: []const u8 = "";
        for (msg.header.header_fields) |field| {
            if (field.code == .Signature) {
                sig = field.value.Signature;
                break;
            }
        }

        return .{
            .allocator = allocator,
            .body = msg.body,
            .signature = sig,
            .pos = 0,
            .sig_pos = 0,
            .endian = msg.header.endianess,
        };
    }

    fn alignTo(self: *BodyDecoder, alignment: usize) void {
        const rem = self.pos % alignment;
        if (rem != 0) {
            self.pos += (alignment - rem);
        }
    }

    /// Decodes the next value of type T from the body.
    /// Returns error.SignatureMismatch if the body signature doesn't match T's D-Bus representation.
    pub fn decode(self: *BodyDecoder, comptime T: type) anyerror!T {
        const sig_len = Value.reprLength(T);
        var expected_sig: [256]u8 = undefined;
        Value.getRepr(T, sig_len, 0, expected_sig[0..sig_len]);

        if (self.sig_pos + sig_len > self.signature.len) return error.SignatureEnd;
        if (!std.mem.eql(u8, self.signature[self.sig_pos .. self.sig_pos + sig_len], expected_sig[0..sig_len])) {
            return error.SignatureMismatch;
        }
        self.sig_pos += sig_len;

        self.alignTo(dbusAlignOf(T));

        return self.readVal(T, false);
    }

    /// Decodes the next value of type T and allocates memory for it (recursive deep-copy).
    /// This allows the returned value to outlive the decoder and the message body.
    pub fn decodeAlloc(self: *BodyDecoder, comptime T: type) anyerror!T {
        const sig_len = Value.reprLength(T);
        var expected_sig: [256]u8 = undefined;
        Value.getRepr(T, sig_len, 0, expected_sig[0..sig_len]);

        if (self.sig_pos + sig_len > self.signature.len) return error.SignatureEnd;
        if (!std.mem.eql(u8, self.signature[self.sig_pos .. self.sig_pos + sig_len], expected_sig[0..sig_len])) {
            return error.SignatureMismatch;
        }
        self.sig_pos += sig_len;

        self.alignTo(dbusAlignOf(T));

        return self.readVal(T, true);
    }

    fn readVal(self: *BodyDecoder, comptime T: type, comptime deep_copy: bool) anyerror!T {
        switch (@typeInfo(T)) {
            .int => |info| {
                const size = info.bits / 8;
                if (self.pos + size > self.body.len) return error.EndOfBody;
                const val = std.mem.readInt(T, self.body[self.pos..][0..size], self.endian);
                self.pos += size;
                return val;
            },
            .bool => {
                // Boolean is 4 bytes (u32)
                if (self.pos + 4 > self.body.len) return error.EndOfBody;
                const val = std.mem.readInt(u32, self.body[self.pos..][0..4], self.endian);
                self.pos += 4;
                return val != 0;
            },
            .float => {
                if (self.pos + 8 > self.body.len) return error.EndOfBody;
                const val_bits = std.mem.readInt(u64, self.body[self.pos..][0..8], self.endian);
                self.pos += 8;
                return @bitCast(val_bits);
            },
            .@"struct" => |info| {
                if (T == core.value.GStr or T == core.value.GPath) {
                    // String reading: u32 len, bytes, null
                    if (self.pos + 4 > self.body.len) return error.EndOfBody;
                    const len = std.mem.readInt(u32, self.body[self.pos..][0..4], self.endian);
                    self.pos += 4;

                    if (self.pos + len + 1 > self.body.len) return error.EndOfBody;
                    // Verify null terminator
                    if (self.body[self.pos + len] != 0) return error.MissingNullTerminator;

                    const s = self.body[self.pos .. self.pos + len :0];
                    self.pos += len + 1;

                    if (deep_copy) {
                        const new_s = try self.allocator.allocSentinel(u8, s.len, 0);
                        @memcpy(new_s, s);
                        return T.new(new_s);
                    } else {
                        return T.new(s);
                    }
                } else if (T == core.value.GSig) {
                    // Signature reading: u8 len, bytes, null
                    if (self.pos + 1 > self.body.len) return error.EndOfBody;
                    const len = self.body[self.pos];
                    self.pos += 1;

                    if (self.pos + len + 1 > self.body.len) return error.EndOfBody;
                    if (self.body[self.pos + len] != 0) return error.MissingNullTerminator;

                    const s = self.body[self.pos .. self.pos + len :0];
                    self.pos += len + 1;

                    if (deep_copy) {
                        const new_s = try self.allocator.allocSentinel(u8, s.len, 0);
                        @memcpy(new_s, s);
                        return T.new(new_s);
                    } else {
                        return T.new(s);
                    }
                }

                // Generic struct/tuple/dict-entry support
                // DBus aligns structs and dict-entries to 8.
                var result: T = undefined;
                inline for (info.fields) |fld| {
                    self.alignTo(dbusAlignOf(fld.type));
                    @field(result, fld.name) = try self.readVal(fld.type, deep_copy);
                }
                return result;
            },
            .pointer => |info| {
                if (info.size != .slice) return error.UnsupportedType;
                const Elem = info.child;

                // Read byte length (u32)
                const byte_len = try self.readVal(u32, false); // No need to deep copy length

                // Align to element boundary
                self.alignTo(dbusAlignOf(Elem));

                const start_pos = self.pos;
                if (self.pos + byte_len > self.body.len) return error.EndOfBody;

                var list = try std.ArrayList(Elem).initCapacity(self.allocator, 0);
                errdefer list.deinit(self.allocator);

                while (self.pos - start_pos < byte_len) {
                    self.alignTo(dbusAlignOf(Elem));
                    try list.append(self.allocator, try self.readVal(Elem, deep_copy));
                }
                return try list.toOwnedSlice(self.allocator);
            },
            .@"union" => |info| {
                // Variants on wire: signature ('g'), then aligned value.
                const GSig = core.value.GSig;
                const inner_sig_struct = try self.readVal(GSig, false); // Signature borrowed is fine here for comparison
                const inner_sig = inner_sig_struct.s;

                inline for (info.fields) |fld| {
                    const fld_sig_len = Value.reprLength(fld.type);
                    var fld_sig_buf: [256]u8 = undefined;
                    Value.getRepr(fld.type, fld_sig_len, 0, fld_sig_buf[0..fld_sig_len]);

                    if (std.mem.eql(u8, inner_sig, fld_sig_buf[0..fld_sig_len])) {
                        self.alignTo(dbusAlignOf(fld.type));
                        return @unionInit(T, fld.name, try self.readVal(fld.type, deep_copy));
                    }
                }
                return error.NoMatchingUnionField;
            },
            else => return error.UnsupportedType,
        }
    }
};
