const std = @import("std");
const convertInteger = @import("utils.zig").convertInteger;
const Endian = std.builtin.Endian;

pub const DBusWriter = struct {
    buffer: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    endian: Endian,
    body_start_offset: usize,

    pub fn init(buffer: *std.ArrayList(u8), gpa: std.mem.Allocator, endian: Endian) DBusWriter {
        return .{ .buffer = buffer, .gpa = gpa, .endian = endian, .body_start_offset = 0 };
    }

    pub fn padTo(self: *DBusWriter, @"align": usize) !void {
        if (@"align" <= 1) return;
        const abs_len = self.body_start_offset + self.buffer.items.len;
        const rem = abs_len % @"align";
        if (rem != 0) try self.buffer.appendNTimes(self.gpa, 0, @"align" - rem);
    }

    pub fn writeInt(self: *DBusWriter, comptime T: type, x: T) !void {
        const bytes = convertInteger(T, x, self.endian);
        try self.buffer.appendSlice(self.gpa, &bytes);
    }

    pub fn writeU32At(self: *DBusWriter, pos: usize, v: u32) void {
        var b: [4]u8 = convertInteger(u32, v, self.endian);
        @memcpy(self.buffer.items[pos .. pos + 4], &b);
    }

    pub fn writeSignatureOf(self: *DBusWriter, comptime T: type) !void {
        const sig_len = Value.reprLength(T);
        if (sig_len > 255) return error.SignatureTooLong;
        var sig: [sig_len]u8 = undefined;
        Value.getRepr(T, sig_len, 0, &sig);

        // 'g' encoding: u8 length (no NUL), bytes, NUL; 1-aligned
        try self.padTo(1);
        try self.buffer.append(self.gpa, @as(u8, @intCast(sig_len)));
        try self.buffer.appendSlice(self.gpa, &sig);
        try self.buffer.append(self.gpa, 0);
    }
};

pub fn dbusAlignOf(comptime T: type) usize {
    if (T == GStr or T == GPath) return 4; // 's','o'
    if (T == GSig) return 1; // 'g'
    if (T == GUFd) return 4; // 'h'

    return switch (@typeInfo(T)) {
        .int => |info| switch (info.bits) {
            8 => 1,
            16 => 2,
            32 => 4,
            64 => 8,
            else => @compileError("Unsupported integer width for D-Bus"),
        },
        .bool => 4, // 'b' => u32 on wire
        .float => |info| switch (info.bits) {
            64 => 8,
            else => @compileError("Only f64 on D-Bus"),
        },
        .@"struct" => {
            if (@hasDecl(T, "SIGNATURE")) {
                const sig = T.SIGNATURE;
                if (sig.len > 0 and sig[0] == 'a') return 4;
                if (sig.len > 0 and sig[0] == 'v') return 1;
            }
            return 8; // struct/dict-entry container
        },
        .@"union" => 1, // 'v'
        .array => 4, // 'a'
        .pointer => 4, // 'a' (slice is encoded as array)
        else => @compileError("Unsupported alignment type for D-Bus"),
    };
}

/// A wrapper for D-Bus string values.
pub const GStr = struct {
    s: [:0]const u8,
    /// Creates a new GStr from a null-terminated string.
    pub fn new(s: [:0]const u8) @This() {
        return .{ .s = s };
    }
};

/// A wrapper for D-Bus object path values.
pub const GPath = struct {
    s: [:0]const u8,
    /// Creates a new GPath from a null-terminated string.
    pub fn new(s: [:0]const u8) @This() {
        return .{ .s = s };
    }
};

/// A wrapper for D-Bus signature values.
pub const GSig = struct {
    s: [:0]const u8,
    /// Creates a new GSig from a null-terminated string.
    pub fn new(s: [:0]const u8) @This() {
        return .{ .s = s };
    }
};

/// A wrapper for D-Bus Unix file descriptor values.
pub const GUFd = struct {
    fd: u32,
    /// Creates a new GUFd from a file descriptor.
    pub fn new(fd: u32) @This() {
        return .{ .fd = fd };
    }
};

/// Represent a dbus value
pub const Value = struct {
    fn doesImplementSer(comptime T: type) bool {
        if (std.meta.hasMethod(T, "ser")) {
            const Args = std.meta.ArgsTuple(@TypeOf(T.ser));
            const fx = std.meta.fields(Args);
            return (fx.len == 2 and fx[0].type == T and fx[1].type == *DBusWriter);
        }

        return false;
    }

    pub fn reprLength(comptime T: type) comptime_int {
        if (T == void) return 0;
        const info = @typeInfo(T);
        switch (info) {
            .@"struct", .@"union", .@"enum", .@"opaque" => {
                if (@hasDecl(T, "SIGNATURE")) {
                    return @field(T, "SIGNATURE").len;
                }
            },
            else => {},
        }
        if (T == GStr or T == GPath or T == GSig or T == GUFd) return 1;
        switch (info) {
            .int => return 1,
            .bool => return 1,
            .float => |f_info| {
                if (f_info.bits != 64) @compileError("Only f64 supported");
                return 1;
            },
            .@"struct" => |s_info| {
                const is_dict_entry = s_info.fields.len == 2 and (std.mem.eql(u8, s_info.fields[0].name, "key") and std.mem.eql(u8, s_info.fields[1].name, "value"));
                var len: usize = if (is_dict_entry or !s_info.is_tuple) 2 else 0;
                inline for (s_info.fields) |field| len += reprLength(field.type);
                return len;
            },
            .@"union" => return 1,
            .array => |a_info| return 1 + reprLength(a_info.child),
            .pointer => |p_info| {
                if (p_info.size == .slice) return 1 + reprLength(p_info.child);
                @compileError("Unsupported pointer type");
            },
            else => @compileError("Unsupported type for signature"),
        }
    }

    pub fn getRepr(comptime T: type, len: comptime_int, start: comptime_int, xs: *[len]u8) void {
        const info = @typeInfo(T);
        switch (info) {
            .@"struct", .@"union", .@"enum", .@"opaque" => {
                if (@hasDecl(T, "SIGNATURE")) {
                    const S = @field(T, "SIGNATURE");
                    @memcpy(xs[start..][0..S.len], S);
                    return;
                }
            },
            else => {},
        }
        var real_start: usize = start;

        if (T == GStr) {
            xs[real_start] = 's';
            return;
        } else if (T == GPath) {
            xs[real_start] = 'o';
            return;
        } else if (T == GSig) {
            xs[real_start] = 'g';
            return;
        } else if (T == GUFd) {
            xs[real_start] = 'h';
            return;
        }

        switch (info) {
            .int => |i_info| {
                xs[real_start] = switch (i_info.bits) {
                    8 => 'y',
                    16 => if (i_info.signedness == .signed) 'n' else 'q',
                    32 => if (i_info.signedness == .signed) 'i' else 'u',
                    64 => if (i_info.signedness == .signed) 'x' else 't',
                    else => @compileError("Unsupported int"),
                };
            },
            .float => xs[real_start] = 'd',
            .bool => xs[real_start] = 'b',
            .@"struct" => |s_info| {
                const is_dict_entry = s_info.fields.len == 2 and (std.mem.eql(u8, s_info.fields[0].name, "key") and std.mem.eql(u8, s_info.fields[1].name, "value"));
                if (is_dict_entry) {
                    xs[real_start] = '{';
                    real_start += 1;
                    xs[len - 1] = '}';
                } else if (!s_info.is_tuple) {
                    xs[real_start] = '(';
                    real_start += 1;
                    xs[len - 1] = ')';
                }
                inline for (s_info.fields) |field| {
                    const ll = reprLength(field.type);
                    getRepr(field.type, ll, 0, @as(*[ll]u8, @ptrCast(xs[real_start..][0..ll])));
                    real_start += ll;
                }
            },
            .array => |a_info| {
                xs[real_start] = 'a';
                const ll = reprLength(a_info.child);
                getRepr(a_info.child, ll, 0, @as(*[ll]u8, @ptrCast(xs[real_start + 1 ..][0..ll])));
            },
            .pointer => |p_info| {
                xs[real_start] = 'a';
                const ll = reprLength(p_info.child);
                getRepr(p_info.child, ll, 0, @as(*[ll]u8, @ptrCast(xs[real_start + 1 ..][0..ll])));
            },
            .@"union" => xs[real_start] = 'v',
            else => unreachable,
        }
    }

    /// Array
    pub fn Array(comptime T: type) type {
        // NOTE: using [1]T instead of []T because []T is considered to be a pointer value
        const inner_len = reprLength(T);
        const repr_len = 1 + inner_len;
        const rr = blk: {
            var res = [_]u8{0} ** (repr_len + 1);
            res[0] = 'a';
            getRepr(T, inner_len, 0, @as(*[inner_len]u8, @ptrCast(res[1..repr_len].ptr)));
            res[repr_len] = 0;
            break :blk res;
        };

        return struct {
            pub const SIGNATURE: [:0]const u8 = rr[0..repr_len :0];
            inner: []const T,
            repr: []const u8,
            const Self = @This();

            pub fn new(xs: []const T) Self {
                return Self{
                    .inner = xs,
                    .repr = &rr,
                };
            }

            pub fn ser(self: Self, w: *DBusWriter) !void {
                // 4-align for array container
                try w.padTo(4);

                // Reserve length (u32), patch later
                const len_pos = w.buffer.items.len;
                try w.buffer.appendNTimes(w.gpa, 0, 4);

                // Align element block to element alignment A
                const A = dbusAlignOf(T);
                try w.padTo(A);
                const start_elems = w.buffer.items.len;

                var i: usize = 0;
                while (i < self.inner.len) : (i += 1) {
                    // align per element for safety (especially composites)
                    try w.padTo(A);
                    try Serializer.trySerialize(T, self.inner[i], w);
                }

                // Patch array byte length
                const arr_bytes: usize = w.buffer.items.len - start_elems;
                if (arr_bytes > std.math.maxInt(u32)) return error.ArrayTooLarge;
                w.writeU32At(len_pos, @intCast(arr_bytes));
            }

            inline fn alignUp(value: usize, alignment: usize) usize {
                return (value + alignment - 1) & ~(alignment - 1);
            }
        };
    }

    /// Tuple is a set of element. The order of is important
    /// `ivv` -> `INT32` `VARIANT` `VARIANT`
    pub fn Tuple(comptime T: type) type {
        const info = @typeInfo(T);
        if (info != .@"struct" or !info.@"struct".is_tuple) @compileError("Tuple() expects a tuple struct");

        const repr_len = reprLength(T);
        var repr_arr = [_]u8{0} ** (repr_len);
        getRepr(T, repr_len, 0, &repr_arr);
        const rr = repr_arr;
        return struct {
            pub const SIGNATURE = &rr;
            inner: T,
            repr: []const u8,
            const Self = @This();

            pub fn new(structure: T) Self {
                return Self{
                    .inner = structure,
                    .repr = &rr,
                };
            }

            pub fn ser(self: Self, w: *DBusWriter) !void {
                inline for (info.@"struct".fields) |fld| {
                    try w.padTo(dbusAlignOf(fld.type));
                    try Serializer.trySerialize(fld.type, @field(self.inner, fld.name), w);
                }
            }
        };
    }

    /// **CONTAINER**
    /// Entry in a dict or map (array of key-value pairs). Type code 101 'e' is
    /// reserved for use in bindings and implementations to represent the general
    /// concept of a dict or dict-entry, and must not appear in signatures used on D-Bus.
    pub fn Dict(comptime K: type, comptime V: type, comptime M: type) type {
        const key_repr_len = reprLength(K);
        const value_repr_len = reprLength(V);

        const total_len = value_repr_len + key_repr_len + 3;
        const repr_arr = blk: {
            var rr = [_]u8{0} ** (total_len + 1);
            rr[0] = 'a';
            rr[1] = '{';
            rr[total_len - 1] = '}';
            rr[total_len] = 0;
            getRepr(K, key_repr_len, 0, @as(*[key_repr_len]u8, @ptrCast(rr[2 .. key_repr_len + 2].ptr)));
            getRepr(V, value_repr_len, 0, @as(*[value_repr_len]u8, @ptrCast(rr[key_repr_len + 2 .. (total_len - 1)].ptr)));
            break :blk rr;
        };

        return struct {
            pub const SIGNATURE: [:0]const u8 = repr_arr[0..total_len :0];
            inner: M,
            repr: []const u8,
            const Self = @This();

            pub fn init(allocator: std.mem.Allocator) Self {
                return Self{
                    .repr = &repr_arr,
                    .inner = M.init(allocator),
                };
            }

            pub fn new(inner: M) Self {
                return Self{
                    .repr = &repr_arr,
                    .inner = inner,
                };
            }

            pub fn ser(self: Self, w: *DBusWriter) !void {
                // This is precisely: Array of dict-entry
                // Array header (4-align)
                try w.padTo(4);
                const len_pos = w.buffer.items.len;
                try w.buffer.appendNTimes(w.gpa, 0, 4);

                // Elements block must start at 8 (dict-entry alignment)
                try w.padTo(8);
                const start_elems = w.buffer.items.len;

                // Iterate entries (supports std.StringHashMap and slices of {key,value})
                if (std.meta.hasMethod(@TypeOf(self.inner), "iterator")) {
                    var it = self.inner.iterator();
                    while (it.next()) |e| {
                        try w.padTo(8); // each dict-entry
                        try w.padTo(dbusAlignOf(K));
                        const key = e.key_ptr.*;
                        if (comptime K == GStr) {
                            try w.padTo(4);
                            try w.writeInt(u32, @intCast(key.len));
                            try w.buffer.appendSlice(w.gpa, key);
                            try w.buffer.append(w.gpa, 0);
                        } else {
                            try Serializer.trySerialize(K, key, w);
                        }
                        try w.padTo(dbusAlignOf(V));
                        try Serializer.trySerialize(V, e.value_ptr.*, w);
                    }
                } else switch (@typeInfo(@TypeOf(self.inner))) {
                    .pointer => |pi| {
                        if (pi.size != .slice) return error.UnsupportedDictBacking;
                        const Elem = pi.child;
                        const einfo = @typeInfo(Elem);
                        if (einfo != .@"struct") return error.UnsupportedDictBacking;
                        inline for (einfo.@"struct".fields) |_| {} // keep einfo constexpr
                        for (self.inner) |ev| {
                            try w.padTo(8);
                            const k = @field(ev, "key");
                            const v = @field(ev, "value");
                            try w.padTo(dbusAlignOf(K));
                            if (comptime K == GStr) {
                                try w.padTo(4);
                                try w.writeInt(u32, @intCast(k.s.len));
                                try w.buffer.appendSlice(w.gpa, k.s);
                                try w.buffer.append(w.gpa, 0);
                            } else {
                                try Serializer.trySerialize(K, k, w);
                            }
                            try w.padTo(dbusAlignOf(V));
                            try Serializer.trySerialize(V, v, w);
                        }
                    },
                    else => return error.UnsupportedDictBacking,
                }

                // Patch array byte length
                const arr_bytes: usize = w.buffer.items.len - start_elems;
                if (arr_bytes > std.math.maxInt(u32)) return error.ArrayTooLarge;
                w.writeU32At(len_pos, @intCast(arr_bytes));
            }
        };
    }

    /// **CONTAINER**
    /// Variant type (the type of the value is part of the value itself)
    /// Only unions are accepted
    pub fn Variant(comptime T: type) type {
        switch (@typeInfo(T)) {
            .@"union" => {
                return struct {
                    pub const SIGNATURE = "v";
                    inner: T,
                    repr: [:0]const u8,
                    const Self = @This();

                    pub fn new(any: T) Self {
                        return Self{
                            .inner = any,
                            .repr = "v",
                        };
                    }

                    pub fn ser(self: Self, w: *DBusWriter) anyerror!void {
                        // 1) write signature ('g'), 2) align to inner alignment, 3) write payload
                        switch (self.inner) {
                            inline else => |payload| {
                                const PT = @TypeOf(payload);
                                // signature (1-aligned)
                                try w.writeSignatureOf(PT);
                                // align & write payload
                                try w.padTo(dbusAlignOf(PT));
                                try Serializer.trySerialize(PT, payload, w);
                            },
                        }
                    }
                };
            },
            else => @compileError("expected union as variant argument but found " ++ @typeName(T)),
        }
    }

    /// **CONTAINER**
    /// **Struct** type code 114 'r' is reserved for use in bindings and implementations
    /// to represent the general concept of a struct, and must not appear in signatures used on D-Bus.
    pub fn Struct(comptime S: type) type {
        if (@typeInfo(S) != .@"struct") {
            @compileError("unexpected input type");
        }
        const repr_len = reprLength(S);
        var repr_arr = [_]u8{0} ** (repr_len);
        getRepr(S, repr_len, 0, &repr_arr);
        const rr = repr_arr;
        return struct {
            pub const SIGNATURE = &rr;
            inner: S,
            repr: []const u8,
            const Self = @This();

            pub fn new(structure: S) Self {
                return Self{
                    .inner = structure,
                    .repr = &rr,
                };
            }

            pub fn ser(self: Self, w: *DBusWriter) !void {
                try w.padTo(8);
                inline for (@typeInfo(S).@"struct".fields) |fld| {
                    try w.padTo(dbusAlignOf(fld.type));
                    try Serializer.trySerialize(fld.type, @field(self.inner, fld.name), w);
                }
            }
        };
    }

    fn BasicType(comptime T: type) type {
        const repr_len = reprLength(T);
        var repr_arr = [_]u8{0} ** repr_len;
        getRepr(T, repr_len, 0, &repr_arr);
        const rr = repr_arr;
        return struct {
            value: T,
            repr: []const u8,
            const Self = @This();

            pub fn new(value: T) Self {
                return Self{
                    .value = value,
                    .repr = &rr,
                };
            }

            pub fn ser(self: Self, w: *DBusWriter) !void {
                try w.padTo(dbusAlignOf(T));
                switch (@typeInfo(T)) {
                    .int => try w.writeInt(T, self.value),
                    .float => {
                        const bits: u64 = @bitCast(self.value); // f64
                        try w.writeInt(u64, bits);
                    },
                    else => unreachable,
                }
            }
        };
    }

    fn StringLike(r: u8) type {
        const repr_len = 1;
        return struct {
            value: [:0]const u8,
            repr: []const u8,
            const Self = @This();

            pub fn new(value: [:0]const u8) Self {
                var repr_arr = [_]u8{0} ** repr_len;
                repr_arr[0] = r;
                return Self{
                    .value = value,
                    .repr = &repr_arr,
                };
            }

            pub fn ser(self: Self, w: *DBusWriter) !void {
                switch (r) {
                    's', 'o' => {
                        try w.padTo(4);
                        const len_u32: u32 = @intCast(self.value.len); // not including NUL
                        try w.writeInt(u32, len_u32);
                        try w.buffer.appendSlice(w.gpa, self.value);
                        try w.buffer.append(w.gpa, 0);
                    },
                    'g' => {
                        try w.padTo(1);
                        const n = self.value.len;
                        if (n > 255) return error.SignatureTooLong;
                        try w.buffer.append(w.gpa, @as(u8, @intCast(n)));
                        try w.buffer.appendSlice(w.gpa, self.value);
                        try w.buffer.append(w.gpa, 0);
                    },
                    else => unreachable,
                }
            }
        };
    }

    /// Signed (two's complement) 16-bit integer
    pub fn Int16() type {
        return BasicType(i16);
    }

    /// Unsigned 16-bit integer
    pub fn Uint16() type {
        return BasicType(u16);
    }

    /// Signed (two's complement) 32-bit integer
    pub fn Int32() type {
        return BasicType(i32);
    }

    /// Unsigned 32-bit integer
    pub fn Uint32() type {
        return BasicType(u32);
    }

    /// Signed (two's complement) 64-bit integer (mnemonic: x and t are the first
    /// characters in "sixty" not already used for something more common)
    pub fn Int64() type {
        return BasicType(i64);
    }

    /// Unsigned 64-bit integer
    pub fn Uint64() type {
        return BasicType(u64);
    }

    /// IEEE 754 double-precision floating point
    pub fn Double() type {
        return BasicType(f64);
    }

    /// Unsigned 8-bit integer
    pub fn Byte() type {
        return BasicType(u8);
    }

    /// Boolean value: 0 is false, 1 is true, any other value allowed by the marshalling format is invalid
    /// It representation in the protocol is a `UINT32`
    pub fn Bool() type {
        const repr_len = reprLength(bool);
        var repr_arr = [_]u8{0} ** repr_len;
        getRepr(bool, repr_len, 0, &repr_arr);
        const rr = repr_arr;
        return struct {
            value: bool,
            repr: []const u8,
            const Self = @This();

            pub fn new(value: bool) Self {
                return Self{
                    .value = value,
                    .repr = &rr,
                };
            }

            pub fn ser(self: Self, w: *DBusWriter) !void {
                try w.padTo(dbusAlignOf(bool)); // 4
                try w.writeInt(u32, @intFromBool(self.value));
            }
        };
    }

    /// Unsigned 32-bit integer representing an index into an out-of-band array of
    /// file descriptors, transferred via some platform-specific mechanism (mnemonic: h for handle)
    pub fn UnixFd() type {
        const repr_len = reprLength(u32);
        return struct {
            handle: u32,
            repr: []const u8,
            const Self = @This();

            pub fn new(handle: u32) Self {
                var repr_arr = [_]u8{0} ** repr_len;
                repr_arr[0] = 'h';
                return Self{
                    .handle = handle,
                    .repr = &repr_arr,
                };
            }

            pub fn ser(self: Self, w: *DBusWriter) !void {
                try w.padTo(4);
                try w.writeInt(u32, self.handle);
            }
        };
    }

    /// String-like types all end with a single zero (NUL) byte
    /// UTF-8 string (must be valid UTF-8)
    /// _Validity constraints_: No extra constraints
    pub fn String() type {
        return StringLike('s');
    }

    /// String-like types all end with a single zero (NUL) byte
    /// Name of an object instance
    /// _Validity constraints_: Must be a [syntactically valid object path](https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-marshaling-object-path)
    pub fn ObjectPath() type {
        return StringLike('o');
    }

    /// String-like types all end with a single zero (NUL) byte
    /// A type signature
    /// _Validity constraints_: Zero or more [single complete types](https://dbus.freedesktop.org/doc/dbus-specification.html#term-single-complete-type)
    pub fn Signature() type {
        return StringLike('g');
    }
};

pub const Serializer = struct {
    pub fn trySerialize(comptime T: type, data: T, w: *DBusWriter) !void {
        if (comptime Value.doesImplementSer(T)) {
            try data.ser(w);
            return;
        }

        if (T == GStr) {
            try Value.String().new(data.s).ser(w);
            return;
        } else if (T == GPath) {
            try Value.ObjectPath().new(data.s).ser(w);
            return;
        } else if (T == GSig) {
            try Value.Signature().new(data.s).ser(w);
            return;
        } else if (T == GUFd) {
            try Value.UnixFd().new(data.fd).ser(w);
            return;
        }

        switch (@typeInfo(T)) {
            .int => |info| {
                if (info.bits == 8 and info.signedness == .signed) return error.I8CannotBeSerialized;
                if (info.bits == 8) try Value.Byte().new(@as(u8, data)).ser(w) else if (info.bits == 16) if (info.signedness == .signed)
                    try Value.Int16().new(@as(i16, data)).ser(w)
                else
                    try Value.Uint16().new(@as(u16, data)).ser(w) else if (info.bits == 32) if (info.signedness == .signed)
                    try Value.Int32().new(@as(i32, data)).ser(w)
                else
                    try Value.Uint32().new(@as(u32, data)).ser(w) else if (info.bits == 64) if (info.signedness == .signed)
                    try Value.Int64().new(@as(i64, data)).ser(w)
                else
                    try Value.Uint64().new(@as(u64, data)).ser(w) else return error.UnsupportedIntWidth;
            },
            .float => |info| {
                if (info.bits != 64) return error.F32CannotBeSerialized;
                try Value.Double().new(@as(f64, data)).ser(w);
            },
            .bool => {
                try Value.Bool().new(data).ser(w);
            },
            .array => |ai| {
                const Elem = ai.child;
                const slice_view = data[0..];
                try Value.Array(Elem).new(slice_view).ser(w);
            },
            .pointer => |pi| {
                if (pi.size == .slice) {
                    const Elem = pi.child;
                    try Value.Array(Elem).new(data).ser(w);
                } else return error.UnsupportedTypeForNow;
            },
            .@"struct" => |sinfo| {
                if (sinfo.is_tuple) {
                    try Value.Tuple(T).new(data).ser(w);
                } else {
                    try Value.Struct(T).new(data).ser(w);
                }
            },
            .@"union" => {
                try Value.Variant(T).new(data).ser(w);
            },
            else => return error.UnsupportedTypeForNow,
        }
    }
};

test "Signature Generation test" {
    const testing = std.testing;
    const allocator = std.testing.allocator;
    const eql = std.mem.eql;

    const Speed = struct {
        vel: f64,
        acc: u64,
        stopped: bool,
    };

    const Coord = struct {
        x: f64,
        y: f64,
        speed: Speed,
    };

    const TTag = enum { oneValue, twoValue, threeValue };
    const MulTup = union(TTag) {
        oneValue: std.meta.Tuple(&[_]type{i32}),
        twoValue: std.meta.Tuple(&[_]type{ i32, i32 }),
        threeValue: std.meta.Tuple(&[_]type{ i32, i32, i32 }),
    };

    const a = Value.Bool().new(false);
    try testing.expect(eql(u8, a.repr, "b"));

    const xs = Value.Array(i64).new(&[_]i64{ 1, 2, 3 });
    try testing.expect(eql(u8, xs.repr, "ax"));

    const c = Value.Double().new(3.0);
    try testing.expect(eql(u8, c.repr, "d"));

    const coord = Coord{
        .x = 98,
        .y = 199,
        .speed = .{
            .acc = 23,
            .stopped = false,
            .vel = 455,
        },
    };

    const t = Value.Struct(Coord).new(coord);
    try testing.expect(eql(u8, t.repr, "(dd(dtb))"));

    const cx = Value.Array(Coord).new(&[_]Coord{coord});
    try testing.expect(eql(u8, cx.repr, "a(dd(dtb))"));

    const tup = Value.Tuple(std.meta.Tuple(&[_]type{ f64, f64, f64 })).new(.{ 4, 4, 4 });
    try testing.expect(eql(u8, tup.repr, "ddd"));

    const va = Value.Variant(MulTup).new(.{ .threeValue = .{ 4, 4, 4 } });
    try testing.expect(eql(u8, va.repr, "v"));

    const dico = Value.Dict([:0]const u8, f64, std.StringHashMap(f64)).init(allocator);
    try testing.expect(eql(u8, dico.repr, "{sd}"));
}
