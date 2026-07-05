const std = @import("std");
const net = std.Io.net;
const core = @import("core.zig");
const message = @import("message_utils.zig");
const common = @import("common.zig");
const dispatcher = @import("dispatcher.zig");
const xml_generator = @import("xml_generator.zig");
const Value = core.value.Value;
const GStr = core.value.GStr;
const DBusWriter = core.value.DBusWriter;

/// Specifies the type of D-Bus connection.
pub const BusType = enum {
    /// The session bus (user-specific).
    Session,
    /// The system bus.
    System,
    /// The accessibility bus (AT-SPI).
    Accessibility,
};

/// Represents a connection to a D-Bus bus (session or system).
/// Manages message sending, receiving, and object registration.
pub const Connection = struct {
    io: std.Io,
    __inner_sock: net.Stream,
    __allocator: std.mem.Allocator,
    __reader_buf: []u8,
    __reader: std.Io.net.Stream.Reader,
    serial_counter: u32 = 1,
    pending_messages: std.ArrayList(core.Message),
    signal_handlers: std.ArrayList(common.SignalHandler),
    registered_interfaces: std.ArrayList(common.InterfaceWrapper),

    fn auth(self: *Connection) !void {
        var io_reader = &self.__reader.interface;

        var writer_buffer: [2048]u8 = undefined;
        var writer = self.__inner_sock.writer(self.io, &writer_buffer);
        var io_writer = &writer.interface;

        const uid: u32 = std.os.linux.getuid();
        var uid_buf: [32]u8 = undefined;
        const uid_str = try std.fmt.bufPrint(&uid_buf, "{}", .{uid});

        var hex_buf: [64]u8 = undefined;
        var out_i: usize = 0;
        for (uid_str) |ch| {
            const hi = "0123456789ABCDEF"[(ch >> 4) & 0xF];
            const lo = "0123456789ABCDEF"[ch & 0xF];
            hex_buf[out_i] = hi;
            hex_buf[out_i + 1] = lo;
            out_i += 2;
        }

        const hex = hex_buf[0..out_i];

        try io_writer.writeByte(0);
        try io_writer.print("AUTH EXTERNAL {s}\r\n", .{hex});
        try io_writer.flush();

        const response = try io_reader.takeDelimiterInclusive('\n');
        if (!std.mem.startsWith(u8, response, "OK")) {
            return error.HandshakeFail;
        }

        try io_writer.print("BEGIN\r\n", .{});
        try io_writer.flush();
    }

    /// Initializes a new connection to the D-Bus bus.
    /// `bus_type`: The type of bus to connect to (.Session, .System, or .Accessibility).
    /// `io`: Mandatory [`std.Io`]
    /// `vars`: Environment variables provided from the entry point
    pub fn init(allocator: std.mem.Allocator, bus_type: BusType, io: std.Io, vars: *std.process.Environ.Map) !Connection {
        var socket_paths: SocketIterator = undefined;
        var unix_addr: net.UnixAddress = undefined;
        var allocated_path: ?[]u8 = null;
        defer if (allocated_path) |p| allocator.free(p);

        switch (bus_type) {
            .Session => {
                const bus_address = vars.get("DBUS_SESSION_BUS_ADDRESS") orelse
                    return error.EnvVarNotFound;
                socket_paths = .init(bus_address);
            },
            .System => {
                if (vars.get("DBUS_SYSTEM_BUS_ADDRESS")) |addr| {
                    socket_paths = .init(addr);
                } else {
                    socket_paths = .init("unix:path=/var/run/dbus/system_bus_socket");
                }
            },
            .Accessibility => {
                if (vars.get("AT_SPI_BUS_ADDRESS")) |addr| {
                    socket_paths = .init(addr);
                } else {
                    const uid = std.os.linux.getuid();
                    allocated_path = try std.fmt.allocPrint(allocator, "unix:path=/run/user/{d}/at-spi/bus_0", .{uid});
                    socket_paths = .init(allocated_path.?);
                }
            },
        }

        while (socket_paths.next()) |path| {
            unix_addr = net.UnixAddress.init(path) catch continue;
            break;
        } else {
            return error.NoValidAddressFound;
        }

        const reader_buf = try allocator.alloc(u8, 4096 * 10);
        errdefer allocator.free(reader_buf);

        const socket = try unix_addr.connect(io);

        var conn = Connection{
            .__inner_sock = socket,
            .__allocator = allocator,
            .__reader_buf = reader_buf,
            .io = io,
            .pending_messages = try std.ArrayList(core.Message).initCapacity(allocator, 10),
            .signal_handlers = try std.ArrayList(common.SignalHandler).initCapacity(allocator, 0),
            .registered_interfaces = try std.ArrayList(common.InterfaceWrapper).initCapacity(allocator, 0),
            .__reader = socket.reader(io, reader_buf),
        };

        try conn.auth();
        try conn.sayHello();

        return conn;
    }

    fn sayHello(self: *Connection) !void {
        const serial = self.serial_counter;
        defer self.serial_counter += 1;

        const header = core.MessageHeader{
            .message_type = core.MessageType.MethodCall,
            .flags = @intFromEnum(core.MessageFlag.__EMPTY),
            .proto_version = 1,
            .body_length = 0,
            .serial = serial,
            .header_fields = @constCast(&[_]core.HeaderField{
                .{ .code = core.HeaderFieldCode.Path, .value = .{ .Path = "/org/freedesktop/DBus" } },
                .{ .code = core.HeaderFieldCode.Destination, .value = .{ .Destination = "org.freedesktop.DBus" } },
                .{ .code = core.HeaderFieldCode.Interface, .value = .{ .Interface = "org.freedesktop.DBus" } },
                .{ .code = core.HeaderFieldCode.Member, .value = .{ .Member = "Hello" } },
            }),
        };

        const body = std.ArrayList(u8).empty;

        const msg = core.Message.new(header, body.items);
        var bytes = try msg.pack(self.__allocator);

        defer bytes.deinit(self.__allocator);
        var response = try self.call(bytes.items, serial);
        defer self.freeMessage(&response);
    }

    /// This function closes the underlined socket
    pub fn close(self: *Connection) void {
        for (self.pending_messages.items) |*msg| {
            self.freeMessage(msg);
        }
        self.pending_messages.deinit(self.__allocator);
        self.signal_handlers.deinit(self.__allocator);

        for (self.registered_interfaces.items) |*wrapper| {
            wrapper.destroy(wrapper, self.__allocator);
        }
        self.registered_interfaces.deinit(self.__allocator);

        self.__allocator.free(self.__reader_buf);
        self.__inner_sock.close(self.io);
    }

    const RequestNameFlags = enum(u32) {
        None = 0,
        AllowReplacement = 1,
        ReplaceExisting = 2,
        DoNotQueue = 4,
    };

    /// Requests a well-known name on the bus.
    pub fn requestName(self: *Connection, name: [:0]const u8) !void {
        const Str = Value.String();
        const U32 = Value.Uint32();

        const serial = self.serial_counter;
        defer self.serial_counter += 1;

        var body_arr = try std.ArrayList(u8).initCapacity(self.__allocator, 256);
        defer body_arr.deinit(self.__allocator);

        var dwriter = DBusWriter.init(&body_arr, self.__allocator, .little);

        const flags =
            @intFromEnum(RequestNameFlags.DoNotQueue) |
            @intFromEnum(RequestNameFlags.ReplaceExisting);

        try Str.new(name).ser(&dwriter);
        try U32.new(flags).ser(&dwriter);

        const header = core.MessageHeader{
            .message_type = core.MessageType.MethodCall,
            .flags = flags,
            .proto_version = 1,
            .body_length = @intCast(body_arr.items.len),
            .serial = serial,
            .header_fields = @constCast(&[_]core.HeaderField{
                .{ .code = core.HeaderFieldCode.Destination, .value = .{ .Destination = "org.freedesktop.DBus" } },
                .{ .code = core.HeaderFieldCode.Interface, .value = .{ .Interface = "org.freedesktop.DBus" } },
                .{ .code = core.HeaderFieldCode.Path, .value = .{ .Path = "/org/freedesktop/DBus" } },
                .{ .code = core.HeaderFieldCode.Member, .value = .{ .Member = "RequestName" } },
                .{ .code = core.HeaderFieldCode.Signature, .value = .{ .Signature = "su" } },
            }),
        };

        const msg = core.Message.new(header, body_arr.items);
        var bytes = try msg.pack(self.__allocator);

        defer bytes.deinit(self.__allocator);
        var response = try self.call(bytes.items, serial);
        defer self.freeMessage(&response);
        if (response.header.message_type == .Error) {
            for (response.header.header_fields) |f| {
                if (f.code == .ErrorName) {
                    std.debug.print("[goose] RequestName failed with ErrorName: {s}\n", .{f.value.ErrorName});
                }
            }
        }
    }

    /// Sends a D-Bus message over the connection.
    pub fn sendMessage(self: *Connection, msg: core.Message) !void {
        var bytes = try msg.pack(self.__allocator);
        defer bytes.deinit(self.__allocator);

        var writer_buffer: [2048]u8 = undefined;
        var writer = self.__inner_sock.writer(self.io, &writer_buffer);
        var io_writer = &writer.interface;

        try io_writer.writeAll(bytes.items);
        try io_writer.flush();
    }

    /// Registers an object (interface implementation) at a specific path.
    /// The struct T must have an `init` method.
    /// `bus_name`: The well-known name to request on the bus.
    /// `path`: The object path to export this interface at.
    pub fn registerObject(self: *Connection, comptime T: type, bus_name: [:0]const u8, path: [:0]const u8, userData: anytype) !usize {
        try self.requestName(bus_name);

        const interface_name = if (@hasDecl(T, "INTERFACE_NAME")) T.INTERFACE_NAME else if (@hasDecl(T, "REQUESTED_NAME")) T.REQUESTED_NAME else bus_name;

        // Instantiate
        var instance_ptr = try self.__allocator.create(T);
        // We assume init signature: fn init(conn: *Connection, userData: anytype) T
        instance_ptr.* = T.init(self, userData);

        // Bind signals
        // We iterate over fields. If a field is a Signal, we set its interface and path.
        inline for (std.meta.fields(T)) |field| {
            const FieldType = field.type;
            if (@typeInfo(FieldType) == .@"struct" and @hasDecl(FieldType, "__is_goose_signal")) {
                var sig = &@field(instance_ptr, field.name);
                sig.interface = interface_name;
                sig.path = path;
            }
        }

        // Generate Introspection XML
        const intro_xml = try xml_generator.generateIntrospectionXml(self.__allocator, T, interface_name);

        // Create wrapper
        const wrapper = common.InterfaceWrapper{
            .instance = @ptrCast(instance_ptr),
            .interface_name = interface_name,
            .path = path,
            .intro_xml = intro_xml,
            .destroy = struct {
                fn destroy(w: *const common.InterfaceWrapper, alloc: std.mem.Allocator) void {
                    const self_ptr = @as(*T, @ptrCast(@alignCast(w.instance)));
                    alloc.destroy(self_ptr);
                    alloc.free(w.intro_xml);
                }
            }.destroy,
            .dispatch = dispatcher.getDispatchFn(T),
        };

        try self.registered_interfaces.append(self.__allocator, wrapper);
        return self.registered_interfaces.items.len - 1;
    }

    /// Sends a reply to a method call.
    pub fn sendReply(self: *Connection, m: core.Message, enc: message.BodyEncoder) !void {
        var reply_fields = try std.ArrayList(core.HeaderField).initCapacity(self.__allocator, 3);
        defer {
            for (reply_fields.items) |f| {
                switch (f.value) {
                    .Destination, .Signature => |s| self.__allocator.free(s),
                    else => {},
                }
            }
            reply_fields.deinit(self.__allocator);
        }
        try reply_fields.append(self.__allocator, .{ .code = .ReplySerial, .value = .{ .ReplySerial = m.header.serial } });

        var dst: ?[:0]const u8 = null;
        for (m.header.header_fields) |f| if (f.code == .Sender) {
            dst = f.value.Sender;
        };
        if (dst) |d| {
            try reply_fields.append(self.__allocator, .{ .code = .Destination, .value = .{ .Destination = try self.__allocator.dupeZ(u8, d) } });
        } else {
            std.debug.print("WARN: No Sender in request, reply has no Destination!\n", .{});
        }
        try reply_fields.append(self.__allocator, .{ .code = .Signature, .value = .{ .Signature = try self.__allocator.dupeZ(u8, enc.signature()) } });

        const reply_h = core.MessageHeader{
            .message_type = .MethodReturn,
            .flags = 0,
            .proto_version = 1,
            .body_length = @intCast(enc.body().len),
            .serial = self.serial_counter,
            .header_fields = reply_fields.items,
        };
        self.serial_counter += 1;
        try self.sendMessage(core.Message.new(reply_h, enc.body()));
    }

    /// Sends an Error reply to a message.
    pub fn sendError(self: *Connection, m: core.Message, error_name: [:0]const u8, error_msg: [:0]const u8) !void {
        var reply_fields = try std.ArrayList(core.HeaderField).initCapacity(self.__allocator, 4);
        defer {
            for (reply_fields.items) |f| {
                switch (f.value) {
                    .Destination, .ErrorName, .Signature => |s| self.__allocator.free(s),
                    else => {},
                }
            }
            reply_fields.deinit(self.__allocator);
        }

        try reply_fields.append(self.__allocator, .{ .code = .ReplySerial, .value = .{ .ReplySerial = m.header.serial } });
        try reply_fields.append(self.__allocator, .{ .code = .ErrorName, .value = .{ .ErrorName = try self.__allocator.dupeZ(u8, error_name) } });

        var dst: ?[:0]const u8 = null;
        for (m.header.header_fields) |f| if (f.code == .Sender) {
            dst = f.value.Sender;
        };
        if (dst) |d| {
            try reply_fields.append(self.__allocator, .{ .code = .Destination, .value = .{ .Destination = try self.__allocator.dupeZ(u8, d) } });
        } else {
            std.debug.print("WARN: No Sender in request, error reply has no Destination!\n", .{});
        }

        var encoder = try message.BodyEncoder.encode(self.__allocator, GStr.new(error_msg));
        defer encoder.deinit();

        try reply_fields.append(self.__allocator, .{ .code = .Signature, .value = .{ .Signature = try self.__allocator.dupeZ(u8, encoder.signature()) } });

        const reply_h = core.MessageHeader{
            .message_type = .Error,
            .flags = 0,
            .proto_version = 1,
            .body_length = @intCast(encoder.body().len),
            .serial = self.serial_counter,
            .header_fields = reply_fields.items,
        };
        self.serial_counter += 1;
        try self.sendMessage(core.Message.new(reply_h, encoder.body()));
    }

    /// Runs the main loop, blocking and handling messages for the registered objects.
    pub fn waitOnHandle(self: *Connection, handle: usize) !void {
        if (handle >= self.registered_interfaces.items.len) return error.InvalidHandle;

        while (true) {
            var msg = try self.waitMessage();
            defer self.freeMessage(&msg);

            if (msg.header.message_type == .MethodCall) {
                // Check interface and path
                var iface: ?[]const u8 = null;
                var path: ?[]const u8 = null;
                var member: ?[]const u8 = null;
                for (msg.header.header_fields) |f| {
                    if (f.code == .Interface) iface = f.value.Interface;
                    if (f.code == .Path) path = f.value.Path;
                    if (f.code == .Member) member = f.value.Member;
                }

                if (path) |p| {
                    var handled = false;
                    for (self.registered_interfaces.items) |*w| {
                        // Check path first
                        if (std.mem.eql(u8, w.path, p)) {
                            // Then check interface or Introspectable
                            if (iface) |i| {
                                if (std.mem.eql(u8, w.interface_name, i) or
                                    std.mem.eql(u8, i, "org.freedesktop.DBus.Introspectable") or
                                    std.mem.eql(u8, i, "org.freedesktop.DBus.Properties"))
                                {
                                    // Dispatch
                                    try w.dispatch(w, self, msg);
                                    handled = true;
                                }
                            } else {
                                // Fallback dispatch
                                try w.dispatch(w, self, msg);
                                handled = true;
                            }
                        }
                    }

                    // Dynamic Introspection logic
                    if (!handled) {
                        if (member) |m| {
                            if (std.mem.eql(u8, m, "Introspect") and (iface == null or std.mem.eql(u8, iface.?, "org.freedesktop.DBus.Introspectable"))) {
                                // Check for children
                                var children_xml = try std.ArrayList(u8).initCapacity(self.__allocator, 256);
                                defer children_xml.deinit(self.__allocator);

                                // We need a set to avoid duplicates
                                var seen_children = std.StringHashMap(void).init(self.__allocator);
                                defer seen_children.deinit();

                                for (self.registered_interfaces.items) |*w| {
                                    if (std.mem.startsWith(u8, w.path, p)) {
                                        if (w.path.len > p.len) {
                                            var child_name: []const u8 = "";
                                            if (std.mem.eql(u8, p, "/")) {
                                                // Special case root
                                                if (w.path.len > 1) {
                                                    const sub = w.path[1..];
                                                    if (std.mem.indexOfScalar(u8, sub, '/')) |idx| {
                                                        child_name = sub[0..idx];
                                                    } else {
                                                        child_name = sub;
                                                    }
                                                }
                                            } else {
                                                // Check if w.path[p.len] == '/'
                                                if (w.path[p.len] == '/') {
                                                    const sub = w.path[p.len + 1 ..];
                                                    if (std.mem.indexOfScalar(u8, sub, '/')) |idx| {
                                                        child_name = sub[0..idx];
                                                    } else {
                                                        child_name = sub;
                                                    }
                                                }
                                            }

                                            if (child_name.len > 0) {
                                                if (seen_children.get(child_name) == null) {
                                                    try seen_children.put(child_name, {});
                                                    try children_xml.print(self.__allocator, "  <node name=\"{s}\"/>\n", .{child_name});
                                                }
                                            }
                                        }
                                    }
                                }

                                // Construct full XML
                                var full_xml = try std.ArrayList(u8).initCapacity(self.__allocator, 1024);
                                defer full_xml.deinit(self.__allocator);
                                try full_xml.appendSlice(self.__allocator, "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"");
                                try full_xml.appendSlice(self.__allocator, " \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n");
                                try full_xml.appendSlice(self.__allocator, "<node>\n");
                                try full_xml.appendSlice(self.__allocator, children_xml.items);
                                try full_xml.appendSlice(self.__allocator, "</node>\n");

                                // Send Reply
                                const xml_slice = try full_xml.toOwnedSliceSentinel(self.__allocator, 0);
                                defer self.__allocator.free(xml_slice);

                                var encoder = try message.BodyEncoder.encode(self.__allocator, GStr.new(xml_slice));
                                defer encoder.deinit();
                                try self.sendReply(msg, encoder);
                            }
                        }
                    }
                }
            }
        }
    }

    /// Registers interest in specific signals or messages using a D-Bus match rule.
    pub fn addMatch(self: *Connection, match: [:0]const u8) !void {
        var encoder = try message.BodyEncoder.encode(self.__allocator, GStr.new(match));
        defer encoder.deinit();
        // We don't care about the return value usually for AddMatch
        var reply = try self.methodCall(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "AddMatch",
            encoder.signature(),
            encoder.body(),
        );
        self.freeMessage(&reply);
    }

    /// Performs a synchronous D-Bus method call.
    pub fn methodCall(
        self: *Connection,
        dest: [:0]const u8,
        path: [:0]const u8,
        iface: [:0]const u8,
        member: [:0]const u8,
        signature: ?[:0]const u8,
        body: []const u8,
    ) !core.Message {
        const serial = self.serial_counter;
        defer self.serial_counter += 1;

        var fields_list = try std.ArrayList(core.HeaderField).initCapacity(self.__allocator, 5);
        defer fields_list.deinit(self.__allocator);

        try fields_list.append(self.__allocator, .{ .code = .Destination, .value = .{ .Destination = dest } });
        try fields_list.append(self.__allocator, .{ .code = .Path, .value = .{ .Path = path } });
        try fields_list.append(self.__allocator, .{ .code = .Interface, .value = .{ .Interface = iface } });
        try fields_list.append(self.__allocator, .{ .code = .Member, .value = .{ .Member = member } });

        if (signature) |sig| {
            try fields_list.append(self.__allocator, .{ .code = .Signature, .value = .{ .Signature = sig } });
        }

        const header = core.MessageHeader{
            .message_type = .MethodCall,
            .flags = 0,
            .proto_version = 1,
            .body_length = @intCast(body.len),
            .serial = serial,
            .header_fields = fields_list.items,
        };

        const msg = core.Message.new(header, body);
        var bytes = try msg.pack(self.__allocator);
        defer bytes.deinit(self.__allocator);

        return self.call(bytes.items, serial);
    }

    /// Frees resources associated with a message.
    pub fn freeMessage(self: *Connection, msg: *core.Message) void {
        self.__allocator.free(msg.body);
        for (msg.header.header_fields) |f| {
            switch (f.value) {
                .Path, .Interface, .Member, .ErrorName, .Destination, .Sender, .Signature => |s| {
                    self.__allocator.free(s);
                },
                else => {},
            }
        }
        self.__allocator.free(msg.header.header_fields);
    }

    /// Registers a callback for a specific D-Bus signal.
    pub fn registerSignalHandler(self: *Connection, interface: []const u8, member: []const u8, callback: *const fn (ctx: ?*anyopaque, msg: core.Message) void, ctx: ?*anyopaque) !void {
        try self.signal_handlers.append(self.__allocator, .{
            .interface = interface,
            .member = member,
            .callback = callback,
            .ctx = ctx,
        });
    }

    /// Blocks until a message is received and returns it.
    /// Signals that match a registered handler will be dispatched automatically and NOT returned.
    pub fn waitMessage(self: *Connection) !core.Message {
        while (true) {
            const msg = if (self.pending_messages.items.len > 0)
                self.pending_messages.orderedRemove(0)
            else
                try self.readNextMessage();

            if (msg.header.message_type == .Signal) {
                var dispatched = false;
                for (self.signal_handlers.items) |handler| {
                    if (msg.isSignal(handler.interface, handler.member)) {
                        handler.callback(handler.ctx, msg);
                        dispatched = true;
                    }
                }
                if (dispatched) {
                    self.freeMessage(@constCast(&msg));
                    continue;
                }
            }

            return msg;
        }
    }

    fn readNextMessage(self: *Connection) !core.Message {
        var header_buf: [16]u8 = undefined;

        var io_reader = &self.__reader.interface;
        try io_reader.readSliceAll(&header_buf);

        const endian: std.builtin.Endian = switch (header_buf[0]) {
            'l' => .little,
            'B' => .big,
            else => return error.BadEndianFlag,
        };
        const mtype: core.MessageType = @enumFromInt(header_buf[1]);
        const flags = header_buf[2];
        const version = header_buf[3];
        const body_len = std.mem.readInt(u32, header_buf[4..8], endian);
        const msg_serial = std.mem.readInt(u32, header_buf[8..12], endian);
        const fields_len = std.mem.readInt(u32, header_buf[12..16], endian);

        const fields_bytes = try self.__allocator.alloc(u8, fields_len);
        defer self.__allocator.free(fields_bytes);
        try io_reader.readSliceAll(fields_bytes);

        // Align stream to 8 bytes
        const current_pos = 16 + fields_len;
        const padding = (8 - (current_pos % 8)) % 8;
        if (padding > 0) {
            try io_reader.discardAll(padding);
        }

        // Read body
        const body = try self.__allocator.alloc(u8, body_len);
        errdefer self.__allocator.free(body);
        try io_reader.readSliceAll(body);

        // Parse fields
        var fields_list = try std.ArrayList(core.HeaderField).initCapacity(self.__allocator, 4);
        errdefer {
            for (fields_list.items) |f| {
                switch (f.value) {
                    .Path, .Interface, .Member, .ErrorName, .Destination, .Sender, .Signature => |s| self.__allocator.free(s),
                    else => {},
                }
            }
            fields_list.deinit(self.__allocator);
        }

        var freader: std.Io.Reader = .fixed(fields_bytes);

        while (freader.seek < fields_len) {
            const padding_f = (8 - (freader.seek % 8)) % 8;
            if (padding_f > 0) {
                try freader.discardAll(padding_f);
            }
            if (freader.seek >= fields_len) break;

            const code_u8 = try freader.takeByte();
            const code: core.HeaderFieldCode = if (code_u8 <= 9) @enumFromInt(code_u8) else .Invalid;

            // Variant signature (we assume standard fields have correct types)
            const sig_len = try freader.takeByte();
            try freader.discardAll(sig_len + 1); // sig + null

            switch (code) {
                .ReplySerial => {
                    const pad4 = (4 - (freader.seek % 4)) % 4;
                    try freader.discardAll(pad4);
                    const val = try freader.takeInt(u32, endian);
                    try fields_list.append(self.__allocator, .{ .code = .ReplySerial, .value = .{ .ReplySerial = val } });
                },
                .UnixFds => {
                    const pad4 = (4 - (freader.seek % 4)) % 4;
                    try freader.discardAll(pad4);
                    const val = try freader.takeInt(u32, endian);
                    try fields_list.append(self.__allocator, .{ .code = .UnixFds, .value = .{ .UnixFds = val } });
                },
                .Signature => {
                    const s_len = try freader.takeByte();
                    const s_owned = try self.__allocator.allocSentinel(u8, s_len, 0);
                    try freader.readSliceAll(s_owned);
                    try freader.discardAll(1); // null
                    try fields_list.append(self.__allocator, .{ .code = .Signature, .value = .{ .Signature = s_owned } });
                },
                .Path, .Interface, .Member, .ErrorName, .Destination, .Sender => |c| {
                    const pad4 = (4 - (freader.seek % 4)) % 4;
                    try freader.discardAll(pad4);
                    const s_len = try freader.takeInt(u32, endian);
                    const s_owned = try self.__allocator.allocSentinel(u8, s_len, 0);
                    try freader.readSliceAll(s_owned);
                    try freader.discardAll(1); // null

                    const hfv: core.HeaderFieldValue = switch (c) {
                        .Path => .{ .Path = s_owned },
                        .Interface => .{ .Interface = s_owned },
                        .Member => .{ .Member = s_owned },
                        .ErrorName => .{ .ErrorName = s_owned },
                        .Destination => .{ .Destination = s_owned },
                        .Sender => .{ .Sender = s_owned },
                        else => unreachable,
                    };
                    try fields_list.append(self.__allocator, .{ .code = c, .value = hfv });
                },
                else => {
                    // Unknown field, cannot safely skip without parsing signature.
                    // For now, assume it consumes nothing more or panic?
                    // We risk desync here.
                    std.debug.print("WARN: Unknown Header Field Code {d}\n", .{code_u8});
                    return error.UnknownHeaderField;
                },
            }
        }

        return core.Message{
            .header = .{
                .endianess = endian,
                .message_type = mtype,
                .flags = flags,
                .proto_version = version,
                .body_length = body_len,
                .serial = msg_serial,
                .header_fields = try fields_list.toOwnedSlice(self.__allocator),
            },
            .body = body,
        };
    }

    fn printData(data: []u8) void {
        for (data) |x| {
            if ((x >= 46 and x <= 57) or (x >= 65 and x <= 90) or (x >= 97 and x <= 122)) {
                std.debug.print("{c}", .{x});
            } else {
                std.debug.print("\\{o}", .{x});
            }
        }
        std.debug.print("\n", .{});
    }

    fn call(self: *Connection, data: []u8, serial: u32) !core.Message {
        var writer_buffer: [2048]u8 = undefined;
        var writer = self.__inner_sock.writer(self.io, &writer_buffer);
        var io_writer = &writer.interface;

        try io_writer.writeAll(data);
        try io_writer.flush();

        while (true) {
            // Check pending messages first
            for (self.pending_messages.items, 0..) |*msg, i| {
                if (msg.header.message_type == .MethodReturn or msg.header.message_type == .Error) {
                    for (msg.header.header_fields) |f| {
                        if (f.code == .ReplySerial and f.value.ReplySerial == serial) {
                            const found = self.pending_messages.orderedRemove(i);
                            return found;
                        }
                    }
                }
            }

            // Read new message
            const msg = try self.readNextMessage();

            // Check if it is the reply
            var is_reply = false;
            if (msg.header.message_type == .MethodReturn or msg.header.message_type == .Error) {
                for (msg.header.header_fields) |f| {
                    if (f.code == .ReplySerial and f.value.ReplySerial == serial) {
                        is_reply = true;
                        break;
                    }
                }
            }

            if (is_reply) {
                return msg;
            } else {
                if (msg.header.message_type == .Signal) {
                    var dispatched = false;
                    for (self.signal_handlers.items) |handler| {
                        if (msg.isSignal(handler.interface, handler.member)) {
                            handler.callback(handler.ctx, msg);
                            dispatched = true;
                        }
                    }
                    if (dispatched) {
                        self.freeMessage(@constCast(&msg));
                        continue;
                    }
                }
                try self.pending_messages.append(self.__allocator, msg);
            }
        }
    }
};

const SocketIterator = struct {
    inner: std.mem.TokenIterator(u8, .scalar),

    fn init(address: []const u8) SocketIterator {
        return .{ .inner = std.mem.tokenizeScalar(u8, address, ';') };
    }

    fn next(self: *SocketIterator) ?[]const u8 {
        const prefix = "unix:";
        const param = "path=";

        while (self.inner.next()) |token| {
            if (!std.mem.startsWith(u8, token, prefix))
                continue;

            var params = std.mem.tokenizeScalar(u8, token[prefix.len..], ',');
            while (params.next()) |pair| {
                if (std.mem.startsWith(u8, pair, param))
                    return pair[param.len..];
            }
        }

        return null;
    }
};
