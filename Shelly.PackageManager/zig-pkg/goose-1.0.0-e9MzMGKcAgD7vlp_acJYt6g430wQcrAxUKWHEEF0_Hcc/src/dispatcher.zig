const std = @import("std");
const core = @import("core.zig");
const message = @import("message_utils.zig");
const common = @import("common.zig");
const Connection = @import("connection.zig").Connection;
const Value = core.value.Value;
const GStr = core.value.GStr;
const dbusAlignOf = core.value.dbusAlignOf;

pub fn getDispatchFn(comptime T: type) fn (*const common.InterfaceWrapper, *Connection, core.Message) anyerror!void {
    return struct {
        fn dispatch(w: *const common.InterfaceWrapper, conn: *Connection, msg: core.Message) anyerror!void {
            const self_obj = @as(*T, @ptrCast(@alignCast(w.instance)));

            var member_name: ?[]const u8 = null;
            var iface_name: ?[]const u8 = null;
            for (msg.header.header_fields) |f| {
                switch (f.value) {
                    .Member => |m| member_name = m,
                    .Interface => |i| iface_name = i,
                    else => {},
                }
            }
            const member = member_name orelse return;

            // PropUnion Generation
            const PropUnion = blk: {
                comptime var union_fields_name: []const [:0]const u8 = &.{};
                comptime var union_fields_type: []const type = &.{};

                comptime var enum_fields_value: []const u16 = &.{};
                comptime var enum_fields_name: []const [:0]const u8 = &.{};
                comptime var count: usize = 0;

                const struct_info = @typeInfo(T).@"struct";
                inline for (struct_info.fields) |f| {
                    const FType = f.type;
                    const type_info = @typeInfo(FType);
                    const DataType = if (type_info == .@"struct" and @hasDecl(FType, "__is_goose_property")) FType.DataType else FType;
                    const is_prop = if (type_info == .@"struct" and @hasDecl(FType, "__is_goose_property")) true else pblk: {
                        const is_signal = (type_info == .@"struct" and @hasDecl(FType, "__is_goose_signal"));
                        const is_conn = std.mem.eql(u8, f.name, "conn");
                        const is_ptr = (type_info == .pointer and type_info.pointer.size != .slice);
                        break :pblk !is_signal and !is_conn and !is_ptr;
                    };

                    if (is_prop) {
                        union_fields_name = union_fields_name ++ &[_][:0]const u8{f.name};
                        union_fields_type = union_fields_type ++ &[_]type{DataType};
                        enum_fields_name = enum_fields_name ++ &[_][:0]const u8{f.name};
                        enum_fields_value = enum_fields_value ++ &[_]u16{count};
                        count += 1;
                    }
                }

                if (count == 0) break :blk union { _dummy: void };

                const c = count;

                const TagType = @Enum(u16, .exhaustive, enum_fields_name[0..c], enum_fields_value[0..c]);

                break :blk @Union(
                    .auto,
                    TagType,
                    union_fields_name[0..c],
                    union_fields_type[0..c],
                    &@splat(.{}),
                );
            };

            if (iface_name != null and std.mem.eql(u8, iface_name.?, "org.freedesktop.DBus.Properties")) {
                if (std.mem.eql(u8, member, "GetAll")) {
                    var decoder = message.BodyDecoder.fromMessage(conn.__allocator, msg);
                    const requested_iface = decoder.decode(GStr) catch {
                        try conn.sendError(msg, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid interface argument");
                        return;
                    };
                    if (std.mem.eql(u8, requested_iface.s, w.interface_name)) {
                        const VariantType = Value.Variant(PropUnion);
                        var dict = std.StringHashMap(VariantType).init(conn.__allocator);
                        defer dict.deinit();

                        const struct_info = @typeInfo(T).@"struct";
                        inline for (struct_info.fields) |f| {
                            const FType = f.type;
                            const type_info = @typeInfo(FType);
                            const is_wrapped = type_info == .@"struct" and @hasDecl(FType, "__is_goose_property");
                            const is_prop = is_wrapped or blk: {
                                const is_signal = (type_info == .@"struct" and @hasDecl(FType, "__is_goose_signal"));
                                const is_conn = f.type == *Connection; //std.mem.eql(u8, f.name, "conn");
                                const is_ptr = (type_info == .pointer and type_info.pointer.size != .slice);
                                break :blk !is_signal and !is_conn and !is_ptr;
                            };
                            const readable = if (is_wrapped) FType.AccessMode != .Write else true;

                            if (is_prop and readable) {
                                const val_field = @field(self_obj, f.name);
                                const val = if (is_wrapped) val_field.value else val_field;
                                try dict.put(f.name, VariantType.new(@unionInit(PropUnion, f.name, val)));
                            }
                        }

                        var encoder = try message.BodyEncoder.encode(conn.__allocator, Value.Dict(GStr, VariantType, std.StringHashMap(VariantType)).new(dict));
                        defer encoder.deinit();
                        try conn.sendReply(msg, encoder);
                    } else {
                        const VariantType = Value.Variant(PropUnion);
                        var dict = std.StringHashMap(VariantType).init(conn.__allocator);
                        defer dict.deinit();
                        var encoder = try message.BodyEncoder.encode(conn.__allocator, Value.Dict(GStr, VariantType, std.StringHashMap(VariantType)).new(dict));
                        defer encoder.deinit();
                        try conn.sendReply(msg, encoder);
                    }
                    return;
                } else if (std.mem.eql(u8, member, "Get")) {
                    var decoder = message.BodyDecoder.fromMessage(conn.__allocator, msg);
                    const requested_iface = decoder.decode(GStr) catch {
                        try conn.sendError(msg, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid interface argument");
                        return;
                    };
                    const prop_name = decoder.decode(GStr) catch {
                        try conn.sendError(msg, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid property name argument");
                        return;
                    };

                    if (std.mem.eql(u8, requested_iface.s, w.interface_name)) {
                        const VariantType = Value.Variant(PropUnion);
                        var found = false;
                        var val_variant: VariantType = undefined;

                        const struct_info = @typeInfo(T).@"struct";
                        inline for (struct_info.fields) |f| {
                            if (!found and std.mem.eql(u8, f.name, prop_name.s)) {
                                const FType = f.type;
                                const type_info = @typeInfo(FType);
                                const is_wrapped = type_info == .@"struct" and @hasDecl(FType, "__is_goose_property");
                                const is_prop = is_wrapped or blk: {
                                    const is_signal = (type_info == .@"struct" and @hasDecl(FType, "__is_goose_signal"));
                                    const is_conn = std.mem.eql(u8, f.name, "conn");
                                    const is_ptr = (type_info == .pointer and type_info.pointer.size != .slice);
                                    break :blk !is_signal and !is_conn and !is_ptr;
                                };
                                const readable = if (is_wrapped) FType.AccessMode != .Write else true;

                                if (is_prop) {
                                    if (readable) {
                                        const val_field = @field(self_obj, f.name);
                                        const val = if (is_wrapped) val_field.value else val_field;
                                        val_variant = VariantType.new(@unionInit(PropUnion, f.name, val));
                                        found = true;
                                    }
                                }
                            }
                        }

                        if (found) {
                            var encoder = try message.BodyEncoder.encode(conn.__allocator, val_variant);
                            defer encoder.deinit();
                            try conn.sendReply(msg, encoder);
                        }
                    }
                    return;
                } else if (std.mem.eql(u8, member, "Set")) {
                    var decoder = message.BodyDecoder.fromMessage(conn.__allocator, msg);
                    const requested_iface = decoder.decode(GStr) catch {
                        try conn.sendError(msg, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid interface argument");
                        return;
                    };
                    const prop_name = decoder.decode(GStr) catch {
                        try conn.sendError(msg, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid property name argument");
                        return;
                    };
                    const val_union = decoder.decode(PropUnion) catch {
                        try conn.sendError(msg, "org.freedesktop.DBus.Error.InvalidSignature", "Property value signature mismatch");
                        return;
                    };

                    if (std.mem.eql(u8, requested_iface.s, w.interface_name)) {
                        var found = false;
                        const struct_info = @typeInfo(T).@"struct";
                        inline for (struct_info.fields) |f| {
                            if (!found and std.mem.eql(u8, f.name, prop_name.s)) {
                                const FType = f.type;
                                const type_info = @typeInfo(FType);
                                const is_wrapped = type_info == .@"struct" and @hasDecl(FType, "__is_goose_property");
                                const is_prop = is_wrapped or blk: {
                                    const is_signal = (type_info == .@"struct" and @hasDecl(FType, "__is_goose_signal"));
                                    const is_conn = std.mem.eql(u8, f.name, "conn");
                                    const is_ptr = (type_info == .pointer and type_info.pointer.size != .slice);
                                    break :blk !is_signal and !is_conn and !is_ptr;
                                };
                                const writable = if (is_wrapped) FType.AccessMode != .Read else false;

                                if (is_prop) {
                                    if (writable) {
                                        if (std.meta.activeTag(val_union) == std.meta.stringToEnum(std.meta.Tag(PropUnion), f.name)) {
                                            const new_val = @field(val_union, f.name);
                                            if (is_wrapped) {
                                                @field(self_obj, f.name).value = new_val;
                                            } else {
                                                @field(self_obj, f.name) = new_val;
                                            }
                                            found = true;

                                            // Emit PropertiesChanged signal
                                            {
                                                const VariantType = Value.Variant(PropUnion);
                                                var dict = std.StringHashMap(VariantType).init(conn.__allocator);
                                                defer dict.deinit();

                                                try dict.put(f.name, VariantType.new(@unionInit(PropUnion, f.name, new_val)));

                                                const empty_strs = [_]GStr{};
                                                const args = .{ GStr.new(w.interface_name), Value.Dict(GStr, VariantType, std.StringHashMap(VariantType)).new(dict), Value.Array(GStr).new(&empty_strs) };

                                                var sig_encoder = try message.BodyEncoder.encode(conn.__allocator, args);
                                                defer sig_encoder.deinit();

                                                const serial = conn.serial_counter;
                                                conn.serial_counter += 1;

                                                const sig_header = core.MessageHeader{
                                                    .message_type = .Signal,
                                                    .flags = 0,
                                                    .proto_version = 1,
                                                    .body_length = @intCast(sig_encoder.body().len),
                                                    .serial = serial,
                                                    .header_fields = @constCast(&[_]core.HeaderField{
                                                        .{ .code = .Path, .value = .{ .Path = w.path } },
                                                        .{ .code = .Interface, .value = .{ .Interface = "org.freedesktop.DBus.Properties" } },
                                                        .{ .code = .Member, .value = .{ .Member = "PropertiesChanged" } },
                                                        .{ .code = .Signature, .value = .{ .Signature = sig_encoder.signature() } },
                                                    }),
                                                };

                                                const sig_msg = core.Message.new(sig_header, sig_encoder.body());
                                                try conn.sendMessage(sig_msg);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if (found) {
                            var encoder = try message.BodyEncoder.encode(conn.__allocator, .{}); // Void return;
                            defer encoder.deinit();
                            try conn.sendReply(msg, encoder);
                        }
                    }
                    return;
                }
            }

            // Handle Introspect
            if (iface_name) |iface| {
                if (std.mem.eql(u8, iface, "org.freedesktop.DBus.Introspectable") and std.mem.eql(u8, member, "Introspect")) {
                    // Return XML
                    var encoder = try message.BodyEncoder.encode(conn.__allocator, GStr.new(w.intro_xml));
                    defer encoder.deinit();
                    try conn.sendReply(msg, encoder);
                    return;
                }
            }

            // Dispatch to method
            inline for (@typeInfo(T).@"struct".decls) |decl| {
                const field_val = @field(T, decl.name);
                const field_type = @TypeOf(field_val);

                if (@typeInfo(field_type) == .@"fn") {
                    if (!std.mem.eql(u8, decl.name, "init")) {
                        const fn_info = @typeInfo(field_type).@"fn";
                        if (fn_info.params.len > 0 and fn_info.params[0].type == *T) {
                            if (std.mem.eql(u8, member, decl.name)) {
                                var decoder = message.BodyDecoder.fromMessage(conn.__allocator, msg);
                                const ArgsType = std.meta.ArgsTuple(field_type);
                                var args: ArgsType = undefined;
                                args[0] = self_obj;

                                inline for (fn_info.params[1..], 1..) |param, i| {
                                    args[i] = try decoder.decode(param.type.?);
                                }

                                const result = try @call(.auto, field_val, args);
                                var encoder = try message.BodyEncoder.encode(conn.__allocator, result);
                                defer encoder.deinit();
                                try conn.sendReply(msg, encoder);
                                return;
                            }
                        }
                    }
                }
            }
        }
    }.dispatch;
}
