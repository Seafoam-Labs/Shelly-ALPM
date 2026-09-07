//! HTTP(S) Client implementation.
//!
//! Connections are opened in a thread-safe manner, but individual Requests are not.
//!
//! TLS support may be disabled via `std.options.http_disable_tls`.
//!
//! TODO all the lockUncancelable in this file should be changed to regular lock and
//! `error.Canceled` added to more error sets.
const Client = @This();

const builtin = @import("builtin");

// Vendored from Zig 0.16.0's std.http.Client. TLS is intentionally injected
// from the local compatibility client. Host names use Zig's native resolver
// and TCP connections use a curl-style Happy Eyeballs race.
const std = @import("std");
const TlsClient = @import("tls_client.zig");
const Io = std.Io;
const testing = std.testing;
const http = std.http;
const mem = std.mem;
const Uri = std.Uri;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const HostName = std.Io.net.HostName;
const resolver = @import("resolver.zig");
const IpAddress = std.Io.net.IpAddress;
const Socket = std.Io.net.Socket;
const Stream = std.Io.net.Stream;
const posix = std.posix;

pub const disable_tls = std.options.http_disable_tls;

// Proxy configuration is process-wide, just like the environment it mirrors.
// Executables register their stable environment map before starting HTTP work;
// individual clients then copy the relevant values into client-owned storage.
var default_proxy_environment = std.atomic.Value(usize).init(0);

/// Registers the environment used by clients that do not provide explicit
/// `http_proxy` or `https_proxy` values. `environ_map` must remain valid until
/// every client in the process has been deinitialized.
///
/// Call this during process startup, before starting HTTP worker threads.
pub fn setDefaultProxyEnvironment(environ_map: *const std.process.Environ.Map) void {
    default_proxy_environment.store(@intFromPtr(environ_map), .release);
}

fn defaultProxyEnvironment() ?*const std.process.Environ.Map {
    const address = default_proxy_environment.load(.acquire);
    return if (address == 0) null else @ptrFromInt(address);
}

/// Controls which resolved address families are eligible for new connections.
/// `happy_eyeballs` mirrors curl by preferring IPv6 while racing IPv4 shortly
/// afterwards. `prefer_ipv4` uses the same algorithm with IPv4 launched first.
pub const AddressFamilyPolicy = enum {
    happy_eyeballs,
    prefer_ipv4,
    ipv4_only,
    ipv6_only,
};

/// Used for all client allocations. Must be thread-safe.
allocator: Allocator,
/// Used for opening TCP connections.
io: Io,

/// Bounds DNS resolution and the address-family connection race. TLS and
/// response transfer deadlines remain the caller's responsibility.
connect_timeout: Io.Timeout = .none,

address_family_policy: AddressFamilyPolicy = .prefer_ipv4,

ca_bundle_lock: if (disable_tls) void else Io.RwLock = if (disable_tls) {} else .init,
ca_bundle: if (disable_tls) void else std.crypto.Certificate.Bundle = if (disable_tls) {} else .empty,
/// Used both for the reader and writer buffers.
tls_buffer_size: if (disable_tls) u0 else usize = if (disable_tls) 0 else TlsClient.min_buffer_len,
/// If non-null, ssl secrets are logged to a stream. Creating such a stream
/// allows other processes with access to that stream to decrypt all
/// traffic over connections created with this `Client`.
ssl_key_log: ?*TlsClient.SslKeyLog = null,

/// The time used to decide whether certificates are expired.
///
/// When this is `null`, the next time this client performs an HTTPS request,
/// it will first check the time and rescan the system for root certificates.
now: ?Io.Timestamp = null,

/// The pool of connections that can be reused (and currently in use).
connection_pool: ConnectionPool = .{},
/// Each `Connection` allocates this amount for the reader buffer.
///
/// If the entire HTTP header cannot fit in this amount of bytes,
/// `error.HttpHeadersOversize` will be returned from `Request.wait`.
read_buffer_size: usize = 8192,
/// Each `Connection` allocates this amount for the writer buffer.
write_buffer_size: usize = 1024,

/// If populated, all http traffic travels through this third party.
/// This field cannot be modified while the client has active connections.
/// Pointer to externally-owned memory.
http_proxy: ?*Proxy = null,
/// If populated, all https traffic travels through this third party.
/// This field cannot be modified while the client has active connections.
/// Pointer to externally-owned memory.
https_proxy: ?*Proxy = null,

/// Storage for proxies discovered from the process-default environment.
/// Explicitly supplied proxy pointers remain externally owned.
default_proxy_arena: ?std.heap.ArenaAllocator = null,
default_proxy_lock: Io.Mutex = .init,
default_proxies_initialized: std.atomic.Value(bool) = .init(false),

/// A Least-Recently-Used cache of open connections to be reused.
pub const ConnectionPool = struct {
    mutex: Io.Mutex = .init,
    /// Open connections that are currently in use.
    used: std.DoublyLinkedList = .{},
    /// Open connections that are not currently in use.
    free: std.DoublyLinkedList = .{},
    free_len: usize = 0,
    free_size: usize = 32,

    /// The criteria for a connection to be considered a match.
    pub const Criteria = struct {
        host: HostName,
        port: u16,
        protocol: Protocol,
    };

    /// Finds and acquires a connection from the connection pool matching the criteria.
    /// If no connection is found, null is returned.
    ///
    /// Threadsafe.
    pub fn findConnection(pool: *ConnectionPool, io: Io, criteria: Criteria) ?*Connection {
        pool.mutex.lockUncancelable(io);
        defer pool.mutex.unlock(io);

        var next = pool.free.last;
        while (next) |node| : (next = node.prev) {
            const connection: *Connection = @alignCast(@fieldParentPtr("pool_node", node));
            if (connection.protocol != criteria.protocol) continue;
            if (connection.port != criteria.port) continue;

            // Domain names are case-insensitive (RFC 5890, Section 2.3.2.4)
            if (!connection.host().eql(criteria.host)) continue;

            pool.acquireUnsafe(connection);
            return connection;
        }

        return null;
    }

    /// Acquires an existing connection from the connection pool. This function is not threadsafe.
    pub fn acquireUnsafe(pool: *ConnectionPool, connection: *Connection) void {
        pool.free.remove(&connection.pool_node);
        pool.free_len -= 1;

        pool.used.append(&connection.pool_node);
    }

    /// Acquires an existing connection from the connection pool. This function is threadsafe.
    pub fn acquire(pool: *ConnectionPool, io: Io, connection: *Connection) void {
        pool.mutex.lockUncancelable(io);
        defer pool.mutex.unlock(io);

        return pool.acquireUnsafe(connection);
    }

    /// Tries to release a connection back to the connection pool.
    /// If the connection is marked as closing, it will be closed instead.
    ///
    /// Threadsafe.
    pub fn release(pool: *ConnectionPool, connection: *Connection, io: Io) void {
        pool.mutex.lockUncancelable(io);
        defer pool.mutex.unlock(io);

        pool.used.remove(&connection.pool_node);

        if (connection.closing or pool.free_size == 0) return connection.destroy(io);

        if (pool.free_len >= pool.free_size) {
            const popped: *Connection = @alignCast(@fieldParentPtr("pool_node", pool.free.popFirst().?));
            pool.free_len -= 1;

            popped.destroy(io);
        }

        if (connection.proxied) {
            // proxied connections go to the end of the queue, always try direct connections first
            pool.free.prepend(&connection.pool_node);
        } else {
            pool.free.append(&connection.pool_node);
        }

        pool.free_len += 1;
    }

    /// Adds a newly created node to the pool of used connections. This function is threadsafe.
    pub fn addUsed(pool: *ConnectionPool, io: Io, connection: *Connection) void {
        pool.mutex.lockUncancelable(io);
        defer pool.mutex.unlock(io);

        pool.used.append(&connection.pool_node);
    }

    /// Removes a connection from the used list without closing its stream.
    /// This is used when an HTTP CONNECT transport is replaced by a TLS
    /// connection that owns the same stream.
    fn removeUsed(pool: *ConnectionPool, io: Io, connection: *Connection) void {
        pool.mutex.lockUncancelable(io);
        defer pool.mutex.unlock(io);

        pool.used.remove(&connection.pool_node);
    }

    /// Resizes the connection pool.
    ///
    /// If the new size is smaller than the current size, then idle connections will be closed until the pool is the new size.
    ///
    /// Threadsafe.
    pub fn resize(pool: *ConnectionPool, io: Io, allocator: Allocator, new_size: usize) void {
        pool.mutex.lockUncancelable(io);
        defer pool.mutex.unlock(io);

        const next = pool.free.first;
        _ = next;
        while (pool.free_len > new_size) {
            const popped = pool.free.popFirst() orelse unreachable;
            pool.free_len -= 1;

            popped.data.close(allocator);
            allocator.destroy(popped);
        }

        pool.free_size = new_size;
    }

    /// Frees the connection pool and closes all connections within.
    ///
    /// All future operations on the connection pool will deadlock.
    ///
    /// Threadsafe.
    pub fn deinit(pool: *ConnectionPool, io: Io) void {
        pool.mutex.lockUncancelable(io);

        var next = pool.free.first;
        while (next) |node| {
            const connection: *Connection = @alignCast(@fieldParentPtr("pool_node", node));
            next = node.next;
            connection.destroy(io);
        }

        next = pool.used.first;
        while (next) |node| {
            const connection: *Connection = @alignCast(@fieldParentPtr("pool_node", node));
            next = node.next;
            connection.destroy(io);
        }

        pool.* = undefined;
    }
};

pub const Protocol = enum {
    plain,
    tls,

    fn port(protocol: Protocol) u16 {
        return switch (protocol) {
            .plain => 80,
            .tls => 443,
        };
    }

    pub fn fromScheme(scheme: []const u8) ?Protocol {
        const protocol_map = std.StaticStringMap(Protocol).initComptime(.{
            .{ "http", .plain },
            .{ "ws", .plain },
            .{ "https", .tls },
            .{ "wss", .tls },
        });
        return protocol_map.get(scheme);
    }

    pub fn fromUri(uri: Uri) ?Protocol {
        return fromScheme(uri.scheme);
    }
};

pub const Connection = struct {
    client: *Client,
    stream_writer: Io.net.Stream.Writer,
    stream_reader: Io.net.Stream.Reader,
    /// Entry in `ConnectionPool.used` or `ConnectionPool.free`.
    pool_node: std.DoublyLinkedList.Node,
    port: u16,
    host_len: u8,
    proxied: bool,
    closing: bool,
    protocol: Protocol,

    const Plain = struct {
        connection: Connection,

        fn create(
            client: *Client,
            remote_host: HostName,
            port: u16,
            stream: Io.net.Stream,
        ) error{OutOfMemory}!*Plain {
            const io = client.io;
            const gpa = client.allocator;
            const alloc_len = allocLen(client, remote_host.bytes.len);
            const base = try gpa.alignedAlloc(u8, .of(Plain), alloc_len);
            errdefer gpa.free(base);
            const host_buffer = base[@sizeOf(Plain)..][0..remote_host.bytes.len];
            const socket_read_buffer = host_buffer.ptr[host_buffer.len..][0..client.read_buffer_size];
            const socket_write_buffer = socket_read_buffer.ptr[socket_read_buffer.len..][0..client.write_buffer_size];
            assert(base.ptr + alloc_len == socket_write_buffer.ptr + socket_write_buffer.len);
            @memcpy(host_buffer, remote_host.bytes);
            const plain: *Plain = @ptrCast(base);
            plain.* = .{
                .connection = .{
                    .client = client,
                    .stream_writer = stream.writer(io, socket_write_buffer),
                    .stream_reader = stream.reader(io, socket_read_buffer),
                    .pool_node = .{},
                    .port = port,
                    .host_len = @intCast(remote_host.bytes.len),
                    .proxied = false,
                    .closing = false,
                    .protocol = .plain,
                },
            };
            return plain;
        }

        fn destroy(plain: *Plain) void {
            const c = &plain.connection;
            const gpa = c.client.allocator;
            const base: [*]align(@alignOf(Plain)) u8 = @ptrCast(plain);
            gpa.free(base[0..allocLen(c.client, c.host_len)]);
        }

        fn allocLen(client: *Client, host_len: usize) usize {
            return @sizeOf(Plain) + host_len + client.read_buffer_size + client.write_buffer_size;
        }

        fn host(plain: *Plain) HostName {
            const base: [*]u8 = @ptrCast(plain);
            return .{ .bytes = base[@sizeOf(Plain)..][0..plain.connection.host_len] };
        }
    };

    const Tls = struct {
        client: TlsClient,
        connection: Connection,

        /// Requires the client's TLS trust state to be initialized.
        fn create(
            client: *Client,
            remote_host: HostName,
            port: u16,
            stream: Io.net.Stream,
        ) !*Tls {
            const io = client.io;
            const gpa = client.allocator;
            const realtime_now = client.now orelse return error.TlsInitializationFailed;
            const alloc_len = allocLen(client, remote_host.bytes.len);
            const base = try gpa.alignedAlloc(u8, .of(Tls), alloc_len);
            errdefer gpa.free(base);
            const host_buffer = base[@sizeOf(Tls)..][0..remote_host.bytes.len];
            // The TLS client wants enough buffer for the max encrypted frame
            // size, and the HTTP body reader wants enough buffer for the
            // entire HTTP header. This means we need a combined upper bound.
            const tls_read_buffer_len = client.tls_buffer_size + client.read_buffer_size;
            const tls_read_buffer = host_buffer.ptr[host_buffer.len..][0..tls_read_buffer_len];
            const tls_write_buffer = tls_read_buffer.ptr[tls_read_buffer.len..][0..client.tls_buffer_size];
            const socket_write_buffer = tls_write_buffer.ptr[tls_write_buffer.len..][0..client.write_buffer_size];
            const socket_read_buffer = socket_write_buffer.ptr[socket_write_buffer.len..][0..client.tls_buffer_size];
            assert(base.ptr + alloc_len == socket_read_buffer.ptr + socket_read_buffer.len);
            @memcpy(host_buffer, remote_host.bytes);
            const tls: *Tls = @ptrCast(base);
            var random_buffer: [TlsClient.Options.entropy_len]u8 = undefined;
            io.random(&random_buffer);
            tls.* = .{
                .connection = .{
                    .client = client,
                    .stream_writer = stream.writer(io, tls_write_buffer),
                    .stream_reader = stream.reader(io, socket_read_buffer),
                    .pool_node = .{},
                    .port = port,
                    .host_len = @intCast(remote_host.bytes.len),
                    .proxied = false,
                    .closing = false,
                    .protocol = .tls,
                },
                // TODO data race here on ca_bundle if the user sets `now` to null
                .client = TlsClient.init(
                    &tls.connection.stream_reader.interface,
                    &tls.connection.stream_writer.interface,
                    .{
                        .host = .{ .explicit = remote_host.bytes },
                        .ca = .{ .bundle = .{
                            .gpa = client.allocator,
                            .io = client.io,
                            .lock = &client.ca_bundle_lock,
                            .bundle = &client.ca_bundle,
                        } },
                        .ssl_key_log = client.ssl_key_log,
                        .read_buffer = tls_read_buffer,
                        .write_buffer = socket_write_buffer,
                        .entropy = &random_buffer,
                        .realtime_now = realtime_now,
                        // This is appropriate for HTTPS because the HTTP headers contain
                        // the content length which is used to detect truncation attacks.
                        .allow_truncation_attacks = true,
                    },
                ) catch |err| switch (err) {
                    error.WriteFailed => return tls.connection.stream_writer.err.?,
                    error.ReadFailed => return tls.connection.stream_reader.err.?,
                    else => |e| return e,
                },
            };
            return tls;
        }

        fn destroy(tls: *Tls) void {
            const c = &tls.connection;
            const gpa = c.client.allocator;
            const base: [*]align(@alignOf(Tls)) u8 = @ptrCast(tls);
            gpa.free(base[0..allocLen(c.client, c.host_len)]);
        }

        fn allocLen(client: *Client, host_len: usize) usize {
            const tls_read_buffer_len = client.tls_buffer_size + client.read_buffer_size;
            return @sizeOf(Tls) + host_len + tls_read_buffer_len + client.tls_buffer_size +
                client.write_buffer_size + client.tls_buffer_size;
        }

        fn host(tls: *Tls) HostName {
            const base: [*]u8 = @ptrCast(tls);
            return .{ .bytes = base[@sizeOf(Tls)..][0..tls.connection.host_len] };
        }
    };

    pub const ReadError = TlsClient.ReadError || Io.net.Stream.Reader.Error;

    pub fn getReadError(c: *const Connection) ?ReadError {
        return switch (c.protocol) {
            .tls => {
                if (disable_tls) unreachable;
                const tls: *const Tls = @alignCast(@fieldParentPtr("connection", c));
                return tls.client.read_err orelse c.stream_reader.err.?;
            },
            .plain => {
                return c.stream_reader.err.?;
            },
        };
    }

    fn getStream(c: *Connection) Io.net.Stream {
        return c.stream_reader.stream;
    }

    pub fn host(c: *Connection) HostName {
        return switch (c.protocol) {
            .tls => {
                if (disable_tls) unreachable;
                const tls: *Tls = @alignCast(@fieldParentPtr("connection", c));
                return tls.host();
            },
            .plain => {
                const plain: *Plain = @alignCast(@fieldParentPtr("connection", c));
                return plain.host();
            },
        };
    }

    /// If this is called without calling `flush` or `end`, data will be
    /// dropped unsent.
    pub fn destroy(c: *Connection, io: Io) void {
        c.stream_reader.stream.close(io);
        switch (c.protocol) {
            .tls => {
                if (disable_tls) unreachable;
                const tls: *Tls = @alignCast(@fieldParentPtr("connection", c));
                tls.destroy();
            },
            .plain => {
                const plain: *Plain = @alignCast(@fieldParentPtr("connection", c));
                plain.destroy();
            },
        }
    }

    /// HTTP protocol from client to server.
    /// This either goes directly to `stream_writer`, or to a TLS client.
    pub fn writer(c: *Connection) *Writer {
        return switch (c.protocol) {
            .tls => {
                if (disable_tls) unreachable;
                const tls: *Tls = @alignCast(@fieldParentPtr("connection", c));
                return &tls.client.writer;
            },
            .plain => &c.stream_writer.interface,
        };
    }

    /// HTTP protocol from server to client.
    /// This either comes directly from `stream_reader`, or from a TLS client.
    pub fn reader(c: *Connection) *Reader {
        return switch (c.protocol) {
            .tls => {
                if (disable_tls) unreachable;
                const tls: *Tls = @alignCast(@fieldParentPtr("connection", c));
                return &tls.client.reader;
            },
            .plain => &c.stream_reader.interface,
        };
    }

    pub fn flush(c: *Connection) Writer.Error!void {
        if (c.protocol == .tls) {
            if (disable_tls) unreachable;
            const tls: *Tls = @alignCast(@fieldParentPtr("connection", c));
            try tls.client.writer.flush();
        }
        try c.stream_writer.interface.flush();
    }

    /// If the connection is a TLS connection, sends the close_notify alert.
    ///
    /// Flushes all buffers.
    pub fn end(c: *Connection) Writer.Error!void {
        if (c.protocol == .tls) {
            if (disable_tls) unreachable;
            const tls: *Tls = @alignCast(@fieldParentPtr("connection", c));
            try tls.client.end();
        }
        try c.stream_writer.interface.flush();
    }
};

pub const Response = struct {
    request: *Request,
    /// Pointers in this struct are invalidated when the response body stream
    /// is initialized.
    head: Head,

    pub const Head = struct {
        bytes: []const u8,
        version: http.Version,
        status: http.Status,
        reason: []const u8,
        location: ?[]const u8 = null,
        content_type: ?[]const u8 = null,
        content_disposition: ?[]const u8 = null,

        keep_alive: bool,

        /// If present, the number of bytes in the response body.
        content_length: ?u64 = null,

        transfer_encoding: http.TransferEncoding = .none,
        content_encoding: http.ContentEncoding = .identity,

        pub const ParseError = error{
            HttpConnectionHeaderUnsupported,
            HttpContentEncodingUnsupported,
            HttpHeaderContinuationsUnsupported,
            HttpHeadersInvalid,
            HttpTransferEncodingUnsupported,
            InvalidContentLength,
        };

        pub fn parse(bytes: []const u8) ParseError!Head {
            var res: Head = .{
                .bytes = bytes,
                .status = undefined,
                .reason = undefined,
                .version = undefined,
                .keep_alive = false,
            };
            var it = mem.splitSequence(u8, bytes, "\r\n");

            const first_line = it.first();
            if (first_line.len < 12) return error.HttpHeadersInvalid;

            const version: http.Version = switch (int64(first_line[0..8])) {
                int64("HTTP/1.0") => .@"HTTP/1.0",
                int64("HTTP/1.1") => .@"HTTP/1.1",
                else => return error.HttpHeadersInvalid,
            };
            if (first_line[8] != ' ') return error.HttpHeadersInvalid;
            const status: http.Status = @enumFromInt(parseInt3(first_line[9..12]));
            const reason = mem.trimStart(u8, first_line[12..], " ");

            res.version = version;
            res.status = status;
            res.reason = reason;
            res.keep_alive = switch (version) {
                .@"HTTP/1.0" => false,
                .@"HTTP/1.1" => true,
            };

            while (it.next()) |line| {
                if (line.len == 0) return res;
                switch (line[0]) {
                    ' ', '\t' => return error.HttpHeaderContinuationsUnsupported,
                    else => {},
                }

                var line_it = mem.splitScalar(u8, line, ':');
                const header_name = line_it.next().?;
                const header_value = mem.trim(u8, line_it.rest(), " \t");
                if (header_name.len == 0) return error.HttpHeadersInvalid;

                if (std.ascii.eqlIgnoreCase(header_name, "connection")) {
                    res.keep_alive = !std.ascii.eqlIgnoreCase(header_value, "close");
                } else if (std.ascii.eqlIgnoreCase(header_name, "content-type")) {
                    res.content_type = header_value;
                } else if (std.ascii.eqlIgnoreCase(header_name, "location")) {
                    res.location = header_value;
                } else if (std.ascii.eqlIgnoreCase(header_name, "content-disposition")) {
                    res.content_disposition = header_value;
                } else if (std.ascii.eqlIgnoreCase(header_name, "transfer-encoding")) {
                    // Transfer-Encoding: second, first
                    // Transfer-Encoding: deflate, chunked
                    var iter = mem.splitBackwardsScalar(u8, header_value, ',');

                    const first = iter.first();
                    const trimmed_first = mem.trim(u8, first, " ");

                    var next: ?[]const u8 = first;
                    if (std.meta.stringToEnum(http.TransferEncoding, trimmed_first)) |transfer| {
                        if (res.transfer_encoding != .none) return error.HttpHeadersInvalid; // we already have a transfer encoding
                        res.transfer_encoding = transfer;

                        next = iter.next();
                    }

                    if (next) |second| {
                        const trimmed_second = mem.trim(u8, second, " ");

                        if (http.ContentEncoding.fromString(trimmed_second)) |transfer| {
                            if (res.content_encoding != .identity) return error.HttpHeadersInvalid; // double compression is not supported
                            res.content_encoding = transfer;
                        } else {
                            return error.HttpTransferEncodingUnsupported;
                        }
                    }

                    if (iter.next()) |_| return error.HttpTransferEncodingUnsupported;
                } else if (std.ascii.eqlIgnoreCase(header_name, "content-length")) {
                    const content_length = std.fmt.parseInt(u64, header_value, 10) catch return error.InvalidContentLength;

                    if (res.content_length != null and res.content_length != content_length) return error.HttpHeadersInvalid;

                    res.content_length = content_length;
                } else if (std.ascii.eqlIgnoreCase(header_name, "content-encoding")) {
                    if (res.content_encoding != .identity) return error.HttpHeadersInvalid;

                    const trimmed = mem.trim(u8, header_value, " ");

                    if (http.ContentEncoding.fromString(trimmed)) |ce| {
                        res.content_encoding = ce;
                    } else {
                        return error.HttpContentEncodingUnsupported;
                    }
                }
            }
            return error.HttpHeadersInvalid; // missing empty line
        }

        test parse {
            const response_bytes = "HTTP/1.1 200 OK\r\n" ++
                "LOcation:url\r\n" ++
                "content-tYpe: text/plain\r\n" ++
                "content-disposition:attachment; filename=example.txt \r\n" ++
                "content-Length:10\r\n" ++
                "TRansfer-encoding:\tdeflate, chunked \r\n" ++
                "connectioN:\t keep-alive \r\n\r\n";

            const head = try Head.parse(response_bytes);

            try testing.expectEqual(.@"HTTP/1.1", head.version);
            try testing.expectEqualStrings("OK", head.reason);
            try testing.expectEqual(.ok, head.status);

            try testing.expectEqualStrings("url", head.location.?);
            try testing.expectEqualStrings("text/plain", head.content_type.?);
            try testing.expectEqualStrings("attachment; filename=example.txt", head.content_disposition.?);

            try testing.expectEqual(true, head.keep_alive);
            try testing.expectEqual(10, head.content_length.?);
            try testing.expectEqual(.chunked, head.transfer_encoding);
            try testing.expectEqual(.deflate, head.content_encoding);
        }

        pub fn iterateHeaders(h: Head) http.HeaderIterator {
            return .init(h.bytes);
        }

        test iterateHeaders {
            const response_bytes = "HTTP/1.1 200 OK\r\n" ++
                "LOcation:url\r\n" ++
                "content-tYpe: text/plain\r\n" ++
                "content-disposition:attachment; filename=example.txt \r\n" ++
                "content-Length:10\r\n" ++
                "TRansfer-encoding:\tdeflate, chunked \r\n" ++
                "connectioN:\t keep-alive \r\n\r\n";

            const head = try Head.parse(response_bytes);
            var it = head.iterateHeaders();
            {
                const header = it.next().?;
                try testing.expectEqualStrings("LOcation", header.name);
                try testing.expectEqualStrings("url", header.value);
                try testing.expect(!it.is_trailer);
            }
            {
                const header = it.next().?;
                try testing.expectEqualStrings("content-tYpe", header.name);
                try testing.expectEqualStrings("text/plain", header.value);
                try testing.expect(!it.is_trailer);
            }
            {
                const header = it.next().?;
                try testing.expectEqualStrings("content-disposition", header.name);
                try testing.expectEqualStrings("attachment; filename=example.txt", header.value);
                try testing.expect(!it.is_trailer);
            }
            {
                const header = it.next().?;
                try testing.expectEqualStrings("content-Length", header.name);
                try testing.expectEqualStrings("10", header.value);
                try testing.expect(!it.is_trailer);
            }
            {
                const header = it.next().?;
                try testing.expectEqualStrings("TRansfer-encoding", header.name);
                try testing.expectEqualStrings("deflate, chunked", header.value);
                try testing.expect(!it.is_trailer);
            }
            {
                const header = it.next().?;
                try testing.expectEqualStrings("connectioN", header.name);
                try testing.expectEqualStrings("keep-alive", header.value);
                try testing.expect(!it.is_trailer);
            }
            try testing.expectEqual(null, it.next());
        }

        inline fn int64(array: *const [8]u8) u64 {
            return @bitCast(array.*);
        }

        fn parseInt3(text: *const [3]u8) u10 {
            const nnn: @Vector(3, u8) = text.*;
            const zero: @Vector(3, u8) = .{ '0', '0', '0' };
            const mmm: @Vector(3, u10) = .{ 100, 10, 1 };
            return @reduce(.Add, (nnn -% zero) *% mmm);
        }

        test parseInt3 {
            const expectEqual = testing.expectEqual;
            try expectEqual(@as(u10, 0), parseInt3("000"));
            try expectEqual(@as(u10, 418), parseInt3("418"));
            try expectEqual(@as(u10, 999), parseInt3("999"));
        }

        /// Help the programmer avoid bugs by calling this when the string
        /// memory of `Head` becomes invalidated.
        fn invalidateStrings(h: *Head) void {
            h.bytes = undefined;
            h.reason = undefined;
            if (h.location) |*s| s.* = undefined;
            if (h.content_type) |*s| s.* = undefined;
            if (h.content_disposition) |*s| s.* = undefined;
        }
    };

    /// If compressed body has been negotiated this will return compressed bytes.
    ///
    /// If the returned `Reader` returns `error.ReadFailed` the error is
    /// available via `bodyErr`.
    ///
    /// Asserts that this function is only called once.
    ///
    /// See also:
    /// * `readerDecompressing`
    pub fn reader(response: *Response, transfer_buffer: []u8) *Reader {
        response.head.invalidateStrings();
        const req = response.request;
        if (!req.method.responseHasBody()) return .ending;
        const head = &response.head;
        return req.reader.bodyReader(transfer_buffer, head.transfer_encoding, head.content_length);
    }

    /// If compressed body has been negotiated this will return decompressed bytes.
    ///
    /// If the returned `Reader` returns `error.ReadFailed` the error is
    /// available via `bodyErr`.
    ///
    /// Asserts that this function is only called once.
    ///
    /// See also:
    /// * `reader`
    pub fn readerDecompressing(
        response: *Response,
        transfer_buffer: []u8,
        decompress: *http.Decompress,
        decompress_buffer: []u8,
    ) *Reader {
        response.head.invalidateStrings();
        const head = &response.head;
        return response.request.reader.bodyReaderDecompressing(
            transfer_buffer,
            head.transfer_encoding,
            head.content_length,
            head.content_encoding,
            decompress,
            decompress_buffer,
        );
    }

    /// After receiving `error.ReadFailed` from the `Reader` returned by
    /// `reader` or `readerDecompressing`, this function accesses the
    /// more specific error code.
    pub fn bodyErr(response: *const Response) ?http.Reader.BodyError {
        return response.request.reader.body_err;
    }

    pub fn iterateTrailers(response: *const Response) http.HeaderIterator {
        const r = &response.request.reader;
        assert(r.state == .ready);
        return .{
            .bytes = r.trailers,
            .index = 0,
            .is_trailer = true,
        };
    }
};

pub const Request = struct {
    /// This field is provided so that clients can observe redirected URIs.
    ///
    /// Its backing memory is externally provided by API users when creating a
    /// request, and then again provided externally via `redirect_buffer` to
    /// `receiveHead`.
    uri: Uri,
    client: *Client,
    /// This is null when the connection is released.
    connection: ?*Connection,
    /// Protects connection replacement during redirects from a concurrent
    /// timeout interrupt. Individual requests are otherwise single-threaded.
    connection_mutex: Io.Mutex = .init,
    reader: http.Reader,
    keep_alive: bool,

    method: http.Method,
    version: http.Version = .@"HTTP/1.1",
    transfer_encoding: TransferEncoding,
    redirect_behavior: RedirectBehavior,
    accept_encoding: @TypeOf(default_accept_encoding) = default_accept_encoding,

    /// Whether the request should handle a 100-continue response before sending the request body.
    handle_continue: bool,

    /// Standard headers that have default, but overridable, behavior.
    headers: Headers,

    /// Populated in `receiveHead`; used in `deinit` to determine whether to
    /// discard the body to reuse the connection.
    response_content_length: ?u64 = null,
    /// Populated in `receiveHead`; used in `deinit` to determine whether to
    /// discard the body to reuse the connection.
    response_transfer_encoding: http.TransferEncoding = .none,

    /// These headers are kept including when following a redirect to a
    /// different domain.
    /// Externally-owned; must outlive the Request.
    extra_headers: []const http.Header,

    /// These headers are stripped when following a redirect to a different
    /// domain.
    /// Externally-owned; must outlive the Request.
    privileged_headers: []const http.Header,

    pub const default_accept_encoding: [@typeInfo(http.ContentEncoding).@"enum".fields.len]bool = b: {
        var result: [@typeInfo(http.ContentEncoding).@"enum".fields.len]bool = @splat(false);
        result[@intFromEnum(http.ContentEncoding.gzip)] = true;
        result[@intFromEnum(http.ContentEncoding.deflate)] = true;
        result[@intFromEnum(http.ContentEncoding.identity)] = true;
        break :b result;
    };

    pub const TransferEncoding = union(enum) {
        content_length: u64,
        chunked: void,
        none: void,
    };

    pub const Headers = struct {
        host: Value = .default,
        authorization: Value = .default,
        user_agent: Value = .default,
        connection: Value = .default,
        accept_encoding: Value = .default,
        content_type: Value = .default,

        pub const Value = union(enum) {
            default,
            omit,
            override: []const u8,
        };
    };

    /// Any value other than `not_allowed` or `unhandled` means that integer represents
    /// how many remaining redirects are allowed.
    pub const RedirectBehavior = enum(u16) {
        /// The next redirect will cause an error.
        not_allowed = 0,
        /// Redirects are passed to the client to analyze the redirect response
        /// directly.
        unhandled = std.math.maxInt(u16),
        _,

        pub fn init(n: u16) RedirectBehavior {
            assert(n != std.math.maxInt(u16));
            return @enumFromInt(n);
        }

        pub fn subtractOne(rb: *RedirectBehavior) void {
            switch (rb.*) {
                .not_allowed => unreachable,
                .unhandled => unreachable,
                _ => rb.* = @enumFromInt(@intFromEnum(rb.*) - 1),
            }
        }

        pub fn remaining(rb: RedirectBehavior) u16 {
            assert(rb != .unhandled);
            return @intFromEnum(rb);
        }
    };

    /// Returns the request's `Connection` back to the pool of the `Client`.
    pub fn deinit(r: *Request) void {
        const io = r.client.io;
        if (r.connection) |connection| {
            // Once an interrupted or explicitly rejected connection is marked
            // closing, do not block cleanup trying to drain a body solely for
            // reuse. Healthy connections still discard any unread body before
            // returning to the shared pool.
            if (!connection.closing) {
                connection.closing = switch (r.reader.state) {
                    .ready => false,
                    .received_head => c: {
                        if (r.method.requestHasBody()) break :c true;
                        if (!r.method.responseHasBody()) break :c false;
                        const reader = r.reader.bodyReader(&.{}, r.response_transfer_encoding, r.response_content_length);
                        _ = reader.discardRemaining() catch |err| switch (err) {
                            error.ReadFailed => break :c true,
                        };
                        break :c r.reader.state != .ready;
                    },
                    else => true,
                };
            }
            r.client.connection_pool.release(connection, io);
        }
        r.* = undefined;
    }

    /// Interrupts any blocking socket I/O associated with this request.
    ///
    /// Timeout callers must still wait for their in-flight task to finish
    /// before deinitializing the request. The mutex only protects the
    /// connection pointer while redirects replace and release it.
    pub fn interrupt(r: *Request) void {
        const io = r.client.io;
        r.connection_mutex.lockUncancelable(io);
        defer r.connection_mutex.unlock(io);
        const connection = r.connection orelse return;
        connection.getStream().shutdown(io, .both) catch {};
    }

    /// Marks the current connection unusable after an interrupted task has
    /// stopped touching it.
    pub fn markConnectionClosing(r: *Request) void {
        if (r.connection) |connection| connection.closing = true;
    }

    /// Sends and flushes a complete request as only HTTP head, no body.
    pub fn sendBodiless(r: *Request) Writer.Error!void {
        try sendBodilessUnflushed(r);
        try r.connection.?.flush();
    }

    /// Sends but does not flush a complete request as only HTTP head, no body.
    pub fn sendBodilessUnflushed(r: *Request) Writer.Error!void {
        assert(r.transfer_encoding == .none);
        assert(!r.method.requestHasBody());
        try sendHead(r);
    }

    /// Transfers the HTTP head over the connection and flushes.
    ///
    /// See also:
    /// * `sendBodyUnflushed`
    pub fn sendBody(r: *Request, buffer: []u8) Writer.Error!http.BodyWriter {
        const result = try sendBodyUnflushed(r, buffer);
        try r.connection.?.flush();
        return result;
    }

    /// Transfers the HTTP head and body over the connection and flushes.
    pub fn sendBodyComplete(r: *Request, body: []u8) Writer.Error!void {
        r.transfer_encoding = .{ .content_length = body.len };
        var bw = try sendBodyUnflushed(r, body);
        bw.writer.end = body.len;
        try bw.end();
        try r.connection.?.flush();
    }

    /// Transfers the HTTP head over the connection, which is not flushed until
    /// `BodyWriter.flush` or `BodyWriter.end` is called.
    ///
    /// See also:
    /// * `sendBody`
    pub fn sendBodyUnflushed(r: *Request, buffer: []u8) Writer.Error!http.BodyWriter {
        assert(r.method.requestHasBody());
        try sendHead(r);
        const http_protocol_output = r.connection.?.writer();
        return switch (r.transfer_encoding) {
            .chunked => .{
                .http_protocol_output = http_protocol_output,
                .state = .init_chunked,
                .writer = .{
                    .buffer = buffer,
                    .vtable = &.{
                        .drain = http.BodyWriter.chunkedDrain,
                        .sendFile = http.BodyWriter.chunkedSendFile,
                    },
                },
            },
            .content_length => |len| .{
                .http_protocol_output = http_protocol_output,
                .state = .{ .content_length = len },
                .writer = .{
                    .buffer = buffer,
                    .vtable = &.{
                        .drain = http.BodyWriter.contentLengthDrain,
                        .sendFile = http.BodyWriter.contentLengthSendFile,
                    },
                },
            },
            .none => .{
                .http_protocol_output = http_protocol_output,
                .state = .none,
                .writer = .{
                    .buffer = buffer,
                    .vtable = &.{
                        .drain = http.BodyWriter.noneDrain,
                        .sendFile = http.BodyWriter.noneSendFile,
                    },
                },
            },
        };
    }

    /// Sends HTTP headers without flushing.
    fn sendHead(r: *Request) Writer.Error!void {
        const uri = r.uri;
        const connection = r.connection.?;
        const w = connection.writer();

        try w.writeAll(@tagName(r.method));
        try w.writeByte(' ');

        if (r.method == .CONNECT) {
            try uri.writeToStream(w, .{ .authority = true });
        } else {
            try uri.writeToStream(w, .{
                .scheme = connection.proxied,
                .authentication = connection.proxied,
                .authority = connection.proxied,
                .path = true,
                .query = true,
            });
        }
        try w.writeByte(' ');
        try w.writeAll(@tagName(r.version));
        try w.writeAll("\r\n");

        if (try emitOverridableHeader("host: ", r.headers.host, w)) {
            try w.writeAll("host: ");
            try uri.writeToStream(w, .{ .authority = true });
            try w.writeAll("\r\n");
        }

        if (try emitOverridableHeader("authorization: ", r.headers.authorization, w)) {
            if (uri.user != null or uri.password != null) {
                try w.writeAll("authorization: ");
                try basic_authorization.write(uri, w);
                try w.writeAll("\r\n");
            }
        }

        if (try emitOverridableHeader("user-agent: ", r.headers.user_agent, w)) {
            try w.writeAll("user-agent: zig/");
            try w.writeAll(builtin.zig_version_string);
            try w.writeAll(" (std.http)\r\n");
        }

        if (try emitOverridableHeader("connection: ", r.headers.connection, w)) {
            if (r.keep_alive) {
                try w.writeAll("connection: keep-alive\r\n");
            } else {
                try w.writeAll("connection: close\r\n");
            }
        }

        if (try emitOverridableHeader("accept-encoding: ", r.headers.accept_encoding, w)) {
            try w.writeAll("accept-encoding: ");
            for (r.accept_encoding, 0..) |enabled, i| {
                if (!enabled) continue;
                const tag: http.ContentEncoding = @enumFromInt(i);
                if (tag == .identity) continue;
                const tag_name = @tagName(tag);
                try w.ensureUnusedCapacity(tag_name.len + 2);
                try w.writeAll(tag_name);
                try w.writeAll(", ");
            }
            w.undo(2);
            try w.writeAll("\r\n");
        }

        switch (r.transfer_encoding) {
            .chunked => try w.writeAll("transfer-encoding: chunked\r\n"),
            .content_length => |len| try w.print("content-length: {d}\r\n", .{len}),
            .none => {},
        }

        if (try emitOverridableHeader("content-type: ", r.headers.content_type, w)) {
            // The default is to omit content-type if not provided because
            // "application/octet-stream" is redundant.
        }

        for (r.extra_headers) |header| {
            assert(header.name.len != 0);

            try w.writeAll(header.name);
            try w.writeAll(": ");
            try w.writeAll(header.value);
            try w.writeAll("\r\n");
        }

        if (connection.proxied) proxy: {
            const proxy = switch (connection.protocol) {
                .plain => r.client.http_proxy,
                .tls => r.client.https_proxy,
            } orelse break :proxy;

            const authorization = proxy.authorization orelse break :proxy;
            try w.writeAll("proxy-authorization: ");
            try w.writeAll(authorization);
            try w.writeAll("\r\n");
        }

        try w.writeAll("\r\n");
    }

    pub const ReceiveHeadError = http.Reader.HeadError || ConnectError || error{
        /// Server sent headers that did not conform to the HTTP protocol.
        ///
        /// To find out more detailed diagnostics, `http.Reader.head_buffer` can be
        /// passed directly to `Request.Head.parse`.
        HttpHeadersInvalid,
        TooManyHttpRedirects,
        /// This can be avoided by calling `receiveHead` before sending the
        /// request body.
        RedirectRequiresResend,
        HttpRedirectLocationMissing,
        HttpRedirectLocationOversize,
        HttpRedirectLocationInvalid,
        HttpContentEncodingUnsupported,
        HttpChunkInvalid,
        HttpChunkTruncated,
        HttpHeadersOversize,
        UnsupportedUriScheme,

        /// Sending the request failed. Error code can be found on the
        /// `Connection` object.
        WriteFailed,
    };

    /// If handling redirects and the request has no payload, then this
    /// function will automatically follow redirects.
    ///
    /// If a request payload is present, then this function will error with
    /// `error.RedirectRequiresResend`.
    ///
    /// This function takes an auxiliary buffer to store the arbitrarily large
    /// URI which may need to be merged with the previous URI, and that data
    /// needs to survive across different connections, which is where the input
    /// buffer lives.
    ///
    /// `redirect_buffer` must outlive accesses to `Request.uri`. If this
    /// buffer capacity would be exceeded, `error.HttpRedirectLocationOversize`
    /// is returned instead. This buffer may be empty if no redirects are to be
    /// handled. RFC 9110 recommends making this at least 8000 bytes.
    ///
    /// If this fails with `error.ReadFailed` then the `Connection.getReadError`
    /// method of `r.connection` can be used to get more detailed information.
    pub fn receiveHead(r: *Request, redirect_buffer: []u8) ReceiveHeadError!Response {
        var aux_buf = redirect_buffer;
        while (true) {
            // This while loop is for handling redirects, which means the request's
            // connection may be different than the previous iteration. However, it
            // is still guaranteed to be non-null with each iteration of this loop.
            const connection = r.connection.?;

            const head_buffer = r.reader.receiveHead() catch |err| {
                // Failure here means the connection can no longer be reused.
                connection.closing = true;
                return err;
            };
            const response: Response = .{
                .request = r,
                .head = Response.Head.parse(head_buffer) catch return error.HttpHeadersInvalid,
            };
            const head = &response.head;

            if (head.status == .@"continue") {
                if (r.handle_continue) continue;
                r.response_transfer_encoding = head.transfer_encoding;
                r.response_content_length = head.content_length;
                return response; // we're not handling the 100-continue
            }

            if (r.method == .CONNECT and head.status.class() == .success) {
                // This connection is no longer doing HTTP.
                connection.closing = false;
                r.response_transfer_encoding = head.transfer_encoding;
                r.response_content_length = head.content_length;
                return response;
            }

            connection.closing = !head.keep_alive or !r.keep_alive;

            if (head.status.class() == .redirect and head.status != .not_modified and
                r.redirect_behavior != .unhandled)
            {
                if (r.redirect_behavior == .not_allowed) {
                    // Connection can still be reused by skipping the body.
                    if (r.method != .HEAD) {
                        const reader = r.reader.bodyReader(&.{}, head.transfer_encoding, head.content_length);
                        _ = reader.discardRemaining() catch |err| switch (err) {
                            error.ReadFailed => connection.closing = true,
                        };
                    }
                    return error.TooManyHttpRedirects;
                }
                try r.redirect(head, &aux_buf);
                try r.sendBodiless();
                continue;
            }

            // Any response to a HEAD request and any response with a 1xx
            // (Informational), 204 (No Content), or 304 (Not Modified) status
            // code is always terminated by the first empty line after the
            // header fields, regardless of the header fields present in the
            // message.
            if (r.method == .HEAD or head.status.class() == .informational or
                head.status == .no_content or head.status == .not_modified)
            {
                // Content-Length on these responses describes the selected
                // representation, not bytes following this header block.
                // Normalize the framing so request cleanup can safely reuse
                // the connection instead of waiting for a nonexistent body.
                r.response_transfer_encoding = .none;
                r.response_content_length = 0;
                return response;
            }

            if (!r.accept_encoding[@intFromEnum(head.content_encoding)])
                return error.HttpContentEncodingUnsupported;

            r.response_transfer_encoding = head.transfer_encoding;
            r.response_content_length = head.content_length;
            return response;
        }
    }

    /// This function takes an auxiliary buffer to store the arbitrarily large
    /// URI which may need to be merged with the previous URI, and that data
    /// needs to survive across different connections, which is where the input
    /// buffer lives.
    ///
    /// `aux_buf` must outlive accesses to `Request.uri`.
    fn redirect(r: *Request, head: *const Response.Head, aux_buf: *[]u8) !void {
        const io = r.client.io;
        const new_location = head.location orelse return error.HttpRedirectLocationMissing;
        if (new_location.len > aux_buf.*.len) return error.HttpRedirectLocationOversize;
        const location = aux_buf.*[0..new_location.len];
        @memcpy(location, new_location);
        if (r.method != .HEAD) {
            // HEAD responses have no body, even when Content-Length is present.
            // Skip the body of the redirect response to leave the connection in
            // the correct state. This causes `new_location` to be invalidated.
            const reader = r.reader.bodyReader(&.{}, head.transfer_encoding, head.content_length);
            _ = reader.discardRemaining() catch |err| switch (err) {
                error.ReadFailed => return r.reader.body_err.?,
            };
        }
        const new_uri = r.uri.resolveInPlace(location.len, aux_buf) catch |err| switch (err) {
            error.UnexpectedCharacter => return error.HttpRedirectLocationInvalid,
            error.InvalidFormat => return error.HttpRedirectLocationInvalid,
            error.InvalidPort => return error.HttpRedirectLocationInvalid,
            error.InvalidHostName => return error.HttpRedirectLocationInvalid,
            error.NoSpaceLeft => return error.HttpRedirectLocationOversize,
        };

        const protocol = Protocol.fromUri(new_uri) orelse return error.UnsupportedUriScheme;
        var new_host_name_buffer: [HostName.max_len]u8 = undefined;
        const new_host = try new_uri.getHost(&new_host_name_buffer);
        r.connection_mutex.lockUncancelable(io);
        const old_connection = r.connection.?;
        const keep_privileged_headers =
            std.ascii.eqlIgnoreCase(r.uri.scheme, new_uri.scheme) and
            old_connection.host().sameParentDomain(new_host);
        r.connection = null;
        r.connection_mutex.unlock(io);
        r.client.connection_pool.release(old_connection, io);

        if (!keep_privileged_headers) {
            // When redirecting to a different domain, strip privileged headers.
            r.privileged_headers = &.{};
        }

        if (switch (head.status) {
            .see_other => r.method != .HEAD,
            .moved_permanently, .found => r.method == .POST,
            else => false,
        }) {
            // A redirect to a GET must change the method and remove the body.
            r.method = .GET;
            r.transfer_encoding = .none;
            r.headers.content_type = .omit;
        }

        if (r.transfer_encoding != .none) {
            // The request body has already been sent. The request is
            // still in a valid state, but the redirect must be handled
            // manually.
            return error.RedirectRequiresResend;
        }

        const new_connection = try r.client.connect(new_host, uriPort(new_uri, protocol), protocol);
        r.uri = new_uri;
        r.connection_mutex.lockUncancelable(io);
        r.connection = new_connection;
        r.connection_mutex.unlock(io);
        r.reader = .{
            .in = new_connection.reader(),
            .state = .ready,
            // Populated when `http.Reader.bodyReader` is called.
            .interface = undefined,
            .max_head_len = r.client.read_buffer_size,
        };
        r.redirect_behavior.subtractOne();
    }

    /// Returns true if the default behavior is required, otherwise handles
    /// writing (or not writing) the header.
    fn emitOverridableHeader(prefix: []const u8, v: Headers.Value, bw: *Writer) Writer.Error!bool {
        switch (v) {
            .default => return true,
            .omit => return false,
            .override => |x| {
                var vecs: [3][]const u8 = .{ prefix, x, "\r\n" };
                try bw.writeVecAll(&vecs);
                return false;
            },
        }
    }
};

pub const Proxy = struct {
    protocol: Protocol,
    host: HostName,
    authorization: ?[]const u8,
    port: u16,
    supports_connect: bool,
};

/// Release all associated resources with the client.
///
/// All pending requests must be de-initialized and all active connections released
/// before calling this function.
pub fn deinit(client: *Client) void {
    const io = client.io;
    assert(client.connection_pool.used.first == null); // There are still active requests.

    client.connection_pool.deinit(io);
    if (!disable_tls) client.ca_bundle.deinit(client.allocator);
    if (client.default_proxy_arena) |*arena| arena.deinit();

    client.* = undefined;
}

fn ensureDefaultProxies(client: *Client) error{ OutOfMemory, InvalidProxyConfiguration }!void {
    if (client.default_proxies_initialized.load(.acquire)) return;

    const io = client.io;
    client.default_proxy_lock.lockUncancelable(io);
    defer client.default_proxy_lock.unlock(io);

    if (client.default_proxies_initialized.load(.monotonic)) return;
    const environ_map = defaultProxyEnvironment() orelse {
        client.default_proxies_initialized.store(true, .release);
        return;
    };

    var arena = std.heap.ArenaAllocator.init(client.allocator);
    errdefer arena.deinit();
    initDefaultProxies(client, arena.allocator(), environ_map) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProxyConfiguration,
    };
    client.default_proxy_arena = arena;
    client.default_proxies_initialized.store(true, .release);
}

/// Populates `http_proxy` and `https_proxy` via standard proxy environment variables.
/// Asserts the client has no active connections.
/// Uses `arena` for a few small allocations that must outlive the client, or
/// at least until those fields are set to different values.
pub fn initDefaultProxies(client: *Client, arena: Allocator, environ_map: *const std.process.Environ.Map) !void {
    const io = client.io;

    // Prevent any new connections from being created.
    client.connection_pool.mutex.lockUncancelable(io);
    defer client.connection_pool.mutex.unlock(io);

    assert(client.connection_pool.used.first == null); // There are active requests.

    if (client.http_proxy == null) {
        client.http_proxy = try createProxyFromEnvVar(arena, environ_map, &.{
            "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY",
        });
    }

    if (client.https_proxy == null) {
        client.https_proxy = try createProxyFromEnvVar(arena, environ_map, &.{
            "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY",
        });
    }
}

fn createProxyFromEnvVar(
    arena: Allocator,
    environ_map: *const std.process.Environ.Map,
    env_var_names: []const []const u8,
) !?*Proxy {
    const content = for (env_var_names) |name| {
        const content = environ_map.get(name) orelse continue;
        if (content.len == 0) continue;
        break content;
    } else return null;

    const uri = Uri.parse(content) catch try Uri.parseAfterScheme("http", content);
    const protocol = Protocol.fromUri(uri) orelse return null;
    const raw_host = try uri.getHostAlloc(arena);

    const authorization: ?[]const u8 = if (uri.user != null or uri.password != null) a: {
        const authorization = try arena.alloc(u8, basic_authorization.valueLengthFromUri(uri));
        assert(basic_authorization.value(uri, authorization).len == authorization.len);
        break :a authorization;
    } else null;

    const proxy = try arena.create(Proxy);
    proxy.* = .{
        .protocol = protocol,
        .host = raw_host,
        .authorization = authorization,
        .port = uriPort(uri, protocol),
        .supports_connect = true,
    };
    return proxy;
}

test "ordinary client lazily owns proxies from the process environment" {
    const previous_environment = default_proxy_environment.load(.acquire);
    defer default_proxy_environment.store(previous_environment, .release);

    var environment = std.process.Environ.Map.init(testing.allocator);
    defer environment.deinit();
    try environment.put("http_proxy", "http://lower-proxy.example:8080/");
    try environment.put("HTTP_PROXY", "http://uppercase-proxy.example:8081/");
    try environment.put("ALL_PROXY", "http://fallback-proxy.example:3128/");
    setDefaultProxyEnvironment(&environment);

    var client: Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    try client.ensureDefaultProxies();

    try testing.expect(client.default_proxy_arena != null);
    try testing.expectEqualStrings("lower-proxy.example", client.http_proxy.?.host.bytes);
    try testing.expectEqual(@as(u16, 8080), client.http_proxy.?.port);
    try testing.expectEqualStrings("fallback-proxy.example", client.https_proxy.?.host.bytes);
    try testing.expectEqual(@as(u16, 3128), client.https_proxy.?.port);
}

test "explicit client proxy is not replaced by process defaults" {
    const previous_environment = default_proxy_environment.load(.acquire);
    defer default_proxy_environment.store(previous_environment, .release);

    var environment = std.process.Environ.Map.init(testing.allocator);
    defer environment.deinit();
    try environment.put("http_proxy", "http://environment-proxy.example:8080/");
    setDefaultProxyEnvironment(&environment);

    var explicit_proxy: Proxy = .{
        .protocol = .plain,
        .host = .{ .bytes = "explicit-proxy.example" },
        .authorization = null,
        .port = 9000,
        .supports_connect = true,
    };
    var client: Client = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .http_proxy = &explicit_proxy,
    };
    defer client.deinit();
    try client.ensureDefaultProxies();

    try testing.expect(client.http_proxy == &explicit_proxy);
    try testing.expectEqualStrings("explicit-proxy.example", client.http_proxy.?.host.bytes);
}

const ConnectTlsProbe = struct {
    io: Io,
    server: Io.net.Server,
    saw_connect: bool = false,
    saw_authorization: bool = false,
    saw_tls_client_hello: bool = false,

    fn init(io: Io) !ConnectTlsProbe {
        var address: IpAddress = .{ .ip4 = .loopback(0) };
        return .{ .io = io, .server = try address.listen(io, .{ .reuse_address = true }) };
    }

    fn deinit(probe: *ConnectTlsProbe) void {
        probe.server.deinit(probe.io);
    }

    fn serve(probe: *ConnectTlsProbe) !void {
        var stream = try probe.server.accept(probe.io);
        defer stream.close(probe.io);

        var read_buffer: [4096]u8 = undefined;
        var stream_reader = stream.reader(probe.io, &read_buffer);
        var first_line = true;
        while (true) {
            const line = (try stream_reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;
            if (first_line) {
                probe.saw_connect = std.mem.eql(u8, line, "CONNECT destination.example:443 HTTP/1.1\r");
                first_line = false;
            }
            if (std.mem.eql(u8, line, "proxy-authorization: Basic dXNlcjpwYXNzd29yZA==\r"))
                probe.saw_authorization = true;
            if (std.mem.eql(u8, line, "\r")) break;
        }

        var write_buffer: [256]u8 = undefined;
        var stream_writer = stream.writer(probe.io, &write_buffer);
        try stream_writer.interface.writeAll("HTTP/1.1 200 Connection Established\r\n\r\n");
        try stream_writer.interface.flush();

        var tls_prefix: [3]u8 = undefined;
        var received: usize = 0;
        while (received < tls_prefix.len) {
            const amount = try stream_reader.interface.readSliceShort(tls_prefix[received..]);
            if (amount == 0) break;
            received += amount;
        }
        probe.saw_tls_client_hello = received == tls_prefix.len and
            tls_prefix[0] == 0x16 and tls_prefix[1] == 0x03;
    }
};

test "HTTPS proxy sends authenticated CONNECT then starts destination TLS" {
    if (disable_tls) return error.SkipZigTest;

    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var probe = try ConnectTlsProbe.init(io);
    defer probe.deinit();
    var server_future = try io.concurrent(ConnectTlsProbe.serve, .{&probe});
    defer _ = server_future.cancel(io) catch {};

    var environment = std.process.Environ.Map.init(testing.allocator);
    defer environment.deinit();
    const proxy_url = try std.fmt.allocPrint(
        testing.allocator,
        "http://user:password@127.0.0.1:{d}/",
        .{probe.server.socket.address.getPort()},
    );
    defer testing.allocator.free(proxy_url);
    try environment.put("https_proxy", proxy_url);
    const previous_environment = default_proxy_environment.load(.acquire);
    defer default_proxy_environment.store(previous_environment, .release);
    setDefaultProxyEnvironment(&environment);

    var client: Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    if (client.request(.GET, try Uri.parse("https://destination.example/package"), .{})) |request_value| {
        var unexpected_request = request_value;
        unexpected_request.deinit();
        return error.ExpectedTlsHandshakeFailure;
    } else |_| {}

    try server_future.await(io);
    try testing.expect(probe.saw_connect);
    try testing.expect(probe.saw_authorization);
    try testing.expect(probe.saw_tls_client_hello);
}

pub const basic_authorization = struct {
    pub const max_user_len = 255;
    pub const max_password_len = 255;
    pub const max_value_len = valueLength(max_user_len, max_password_len);

    pub fn valueLength(user_len: usize, password_len: usize) usize {
        return "Basic ".len + std.base64.standard.Encoder.calcSize(user_len + 1 + password_len);
    }

    pub fn valueLengthFromUri(uri: Uri) usize {
        const user: Uri.Component = uri.user orelse .empty;
        const password: Uri.Component = uri.password orelse .empty;

        var dw: Writer.Discarding = .init(&.{});
        user.formatUser(&dw.writer) catch unreachable; // discarding
        const user_len = dw.count + dw.writer.end;

        dw.count = 0;
        dw.writer.end = 0;
        password.formatPassword(&dw.writer) catch unreachable; // discarding
        const password_len = dw.count + dw.writer.end;

        return valueLength(@intCast(user_len), @intCast(password_len));
    }

    pub fn value(uri: Uri, out: []u8) []u8 {
        var bw: Writer = .fixed(out);
        write(uri, &bw) catch unreachable;
        return bw.buffered();
    }

    pub fn write(uri: Uri, out: *Writer) Writer.Error!void {
        var buf: [max_user_len + 1 + max_password_len]u8 = undefined;
        var w: Writer = .fixed(&buf);
        const user: Uri.Component = uri.user orelse .empty;
        const password: Uri.Component = uri.password orelse .empty;
        user.formatUser(&w) catch unreachable;
        w.writeByte(':') catch unreachable;
        password.formatPassword(&w) catch unreachable;
        try out.print("Basic {b64}", .{w.buffered()});
    }
};

const TlsInitializationError = error{
    TlsInitializationFailed,
    CertificateBundleLoadFailure,
} || Io.Cancelable;

fn ensureTlsInitialized(client: *Client) TlsInitializationError!void {
    if (disable_tls) return error.TlsInitializationFailed;

    const io = client.io;
    {
        try client.ca_bundle_lock.lockShared(io);
        const loaded = client.now != null;
        client.ca_bundle_lock.unlockShared(io);
        if (loaded) return;
    }

    // Only the first TLS connection scans the system trust store. Concurrent
    // callers wait here and observe the populated bundle after acquiring the
    // lock.
    try client.ca_bundle_lock.lock(io);
    defer client.ca_bundle_lock.unlock(io);
    if (client.now != null) return;

    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(client.allocator);
    const now = Io.Clock.real.now(io);
    bundle.rescan(client.allocator, io, now) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return error.CertificateBundleLoadFailure,
    };
    client.now = now;
    std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
}

pub const ConnectTcpError = TlsInitializationError || Allocator.Error || HostName.ConnectError;

/// Reuses a `Connection` if one matching `host` and `port` is already open.
///
/// Threadsafe.
pub fn connectTcp(
    client: *Client,
    host: HostName,
    port: u16,
    protocol: Protocol,
) ConnectTcpError!*Connection {
    return connectTcpOptions(client, .{
        .host = host,
        .port = port,
        .protocol = protocol,
    });
}

pub const ConnectTcpOptions = struct {
    host: HostName,
    port: u16,
    protocol: Protocol,

    proxied_host: ?HostName = null,
    proxied_port: ?u16 = null,
    /// Overrides `Client.connect_timeout` for this connection.
    timeout: ?Io.Timeout = null,
};

pub fn connectTcpOptions(client: *Client, options: ConnectTcpOptions) ConnectTcpError!*Connection {
    const io = client.io;
    const host = options.host;
    const port = options.port;
    const protocol = options.protocol;

    const proxied_host = options.proxied_host orelse host;
    const proxied_port = options.proxied_port orelse port;

    if (protocol == .tls) try ensureTlsInitialized(client);

    if (client.connection_pool.findConnection(io, .{
        .host = proxied_host,
        .port = proxied_port,
        .protocol = protocol,
    })) |conn| return conn;

    var stream = try connectHost(host, io, port, client.address_family_policy, .{
        .mode = .stream,
        .timeout = options.timeout orelse client.connect_timeout,
    });
    errdefer stream.close(io);

    switch (protocol) {
        .tls => {
            if (disable_tls) return error.TlsInitializationFailed;
            const tc = Connection.Tls.create(client, proxied_host, proxied_port, stream) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.Unexpected => |e| return e,
                error.Canceled => |e| return e,
                else => return error.TlsInitializationFailed,
            };
            client.connection_pool.addUsed(io, &tc.connection);
            return &tc.connection;
        },
        .plain => {
            const pc = try Connection.Plain.create(client, proxied_host, proxied_port, stream);
            client.connection_pool.addUsed(io, &pc.connection);
            return &pc.connection;
        },
    }
}

const max_resolved_addresses_per_family = 32;
const happy_eyeballs_event_capacity = max_resolved_addresses_per_family * 2 + 16;
const happy_eyeballs_max_active_attempts = 6;
const happy_eyeballs_resolution_delay_ms = 50;
const happy_eyeballs_connection_delay_ms = 200;
const happy_eyeballs_poll_interval_ms = 25;

const AddressFamily = IpAddress.Family;
const ConnectionResult = IpAddress.ConnectError!Stream;

const TimerKind = enum {
    alternate_lookup,
    pace,
    deadline,
};

const HappyEyeballsEvent = union(enum) {
    address: IpAddress,
    lookup_done: struct {
        family: AddressFamily,
        err: ?HostName.LookupError,
    },
    connection: struct {
        id: u64,
        result: ConnectionResult,
    },
    timer: struct {
        kind: TimerKind,
        generation: u64,
    },
};

const EventQueue = Io.Queue(HappyEyeballsEvent);
const VoidFuture = Io.Future(void);

const ResolutionBackend = struct {
    context: ?*anyopaque = null,
    resolveFn: *const fn (
        context: ?*anyopaque,
        host: HostName,
        io: Io,
        port: u16,
        family: AddressFamily,
        events: *EventQueue,
    ) void = resolveProduction,

    fn resolve(
        backend: ResolutionBackend,
        host: HostName,
        io: Io,
        port: u16,
        family: AddressFamily,
        events: *EventQueue,
    ) void {
        backend.resolveFn(backend.context, host, io, port, family, events);
    }

    fn resolveProduction(
        context: ?*anyopaque,
        host: HostName,
        io: Io,
        port: u16,
        family: AddressFamily,
        events: *EventQueue,
    ) void {
        _ = context;
        resolveFamily(host, io, port, family, events);
    }
};

const ConnectionBackend = struct {
    context: ?*anyopaque = null,
    connectFn: *const fn (
        context: ?*anyopaque,
        address: IpAddress,
        io: Io,
        options: IpAddress.ConnectOptions,
    ) IpAddress.ConnectError!Stream = connectProduction,

    fn connect(
        backend: ConnectionBackend,
        address: IpAddress,
        io: Io,
        options: IpAddress.ConnectOptions,
    ) IpAddress.ConnectError!Stream {
        return backend.connectFn(backend.context, address, io, options);
    }

    fn connectProduction(
        context: ?*anyopaque,
        address: IpAddress,
        io: Io,
        options: IpAddress.ConnectOptions,
    ) IpAddress.ConnectError!Stream {
        _ = context;
        return connectAddressNonBlocking(address, io, options);
    }
};

const AddressList = struct {
    items: [max_resolved_addresses_per_family]IpAddress = undefined,
    next: usize = 0,
    len: usize = 0,

    fn append(list: *AddressList, address: IpAddress) void {
        if (list.len == list.items.len) return;
        list.items[list.len] = address;
        list.len += 1;
    }

    fn hasPending(list: *const AddressList) bool {
        return list.next < list.len;
    }

    fn pop(list: *AddressList) ?IpAddress {
        if (!list.hasPending()) return null;
        defer list.next += 1;
        return list.items[list.next];
    }

    fn pendingSlice(list: *const AddressList) []const IpAddress {
        return list.items[list.next..list.len];
    }
};

const ResolvedAddresses = struct {
    ip4: AddressList = .{},
    ip6: AddressList = .{},

    fn ip4Slice(resolved: *const ResolvedAddresses) []const IpAddress {
        return resolved.ip4.pendingSlice();
    }

    fn ip6Slice(resolved: *const ResolvedAddresses) []const IpAddress {
        return resolved.ip6.pendingSlice();
    }

    fn append(resolved: *ResolvedAddresses, address: IpAddress) void {
        switch (address) {
            .ip4 => resolved.ip4.append(address),
            .ip6 => resolved.ip6.append(address),
        }
    }

    fn hasPending(resolved: *const ResolvedAddresses) bool {
        return resolved.ip4.hasPending() or resolved.ip6.hasPending();
    }

    fn hasFamily(resolved: *const ResolvedAddresses, family: AddressFamily) bool {
        return switch (family) {
            .ip4 => resolved.ip4.hasPending(),
            .ip6 => resolved.ip6.hasPending(),
        };
    }

    /// Preserves resolver order within each family while alternating families.
    /// If the desired family has no address yet, the alternate is used without
    /// changing the desired family so a late result gets the next opportunity.
    fn popNext(resolved: *ResolvedAddresses, desired: *AddressFamily) ?IpAddress {
        if (resolved.popFamily(desired.*)) |address| {
            desired.* = otherFamily(desired.*);
            return address;
        }
        return resolved.popFamily(otherFamily(desired.*));
    }

    fn popFamily(resolved: *ResolvedAddresses, family: AddressFamily) ?IpAddress {
        return switch (family) {
            .ip4 => resolved.ip4.pop(),
            .ip6 => resolved.ip6.pop(),
        };
    }
};

const ActiveAttempt = struct {
    id: u64,
    order: u64,
    future: VoidFuture,
};

const HappyEyeballsState = struct {
    io: Io,
    events: *EventQueue,
    policy: AddressFamilyPolicy,
    connection_backend: ConnectionBackend,
    resolution_backend: ResolutionBackend,
    connect_options: IpAddress.ConnectOptions,
    overall_timeout: Io.Timeout,

    addresses: ResolvedAddresses = .{},
    next_family: AddressFamily,
    lookup_ip4_done: bool,
    lookup_ip6_done: bool,
    last_lookup_error: ?HostName.LookupError = null,
    last_connect_error: ?IpAddress.ConnectError = null,

    lookup_ip4_future: ?VoidFuture = null,
    lookup_ip6_future: ?VoidFuture = null,
    alternate_lookup_timer: ?VoidFuture = null,
    pace_timer: ?VoidFuture = null,
    deadline_timer: ?VoidFuture = null,
    alternate_lookup_generation: u64 = 0,
    pace_generation: u64 = 0,
    deadline_generation: u64 = 0,
    alternate_lookup_delay_elapsed: bool = false,

    active: [happy_eyeballs_max_active_attempts]?ActiveAttempt = @splat(null),
    active_count: usize = 0,
    next_attempt_id: u64 = 1,
    next_attempt_order: u64 = 1,
    started: bool = false,
    immediate_next: bool = false,
    next_launch: ?Io.Timestamp = null,

    fn init(
        io: Io,
        events: *EventQueue,
        policy: AddressFamilyPolicy,
        options: IpAddress.ConnectOptions,
    ) HappyEyeballsState {
        return initWithBackend(io, events, policy, options, .{});
    }

    fn initWithBackend(
        io: Io,
        events: *EventQueue,
        policy: AddressFamilyPolicy,
        options: IpAddress.ConnectOptions,
        connection_backend: ConnectionBackend,
    ) HappyEyeballsState {
        return initWithBackends(io, events, policy, options, connection_backend, .{});
    }

    fn initWithBackends(
        io: Io,
        events: *EventQueue,
        policy: AddressFamilyPolicy,
        options: IpAddress.ConnectOptions,
        connection_backend: ConnectionBackend,
        resolution_backend: ResolutionBackend,
    ) HappyEyeballsState {
        var connect_options = options;
        connect_options.timeout = .none;
        return .{
            .io = io,
            .events = events,
            .policy = policy,
            .connection_backend = connection_backend,
            .resolution_backend = resolution_backend,
            .connect_options = connect_options,
            .overall_timeout = options.timeout,
            .next_family = preferredFamily(policy),
            .lookup_ip4_done = policy == .ipv6_only,
            .lookup_ip6_done = policy == .ipv4_only,
        };
    }

    fn deinit(state: *HappyEyeballsState) void {
        cancelVoidFuture(&state.alternate_lookup_timer, state.io);
        cancelVoidFuture(&state.pace_timer, state.io);
        cancelVoidFuture(&state.deadline_timer, state.io);
        for (&state.active) |*maybe_attempt| {
            if (maybe_attempt.*) |*attempt| attempt.future.cancel(state.io);
            maybe_attempt.* = null;
        }
        state.active_count = 0;
        cancelVoidFuture(&state.lookup_ip4_future, state.io);
        cancelVoidFuture(&state.lookup_ip6_future, state.io);

        state.events.close(state.io);
        while (state.events.getOneUncancelable(state.io)) |event| {
            closeEventStream(state.io, event);
        } else |err| switch (err) {
            error.Closed => {},
        }
    }

    fn allLookupsDone(state: *const HappyEyeballsState) bool {
        return state.lookup_ip4_done and state.lookup_ip6_done;
    }

    fn lookupDone(state: *const HappyEyeballsState, family: AddressFamily) bool {
        return switch (family) {
            .ip4 => state.lookup_ip4_done,
            .ip6 => state.lookup_ip6_done,
        };
    }

    fn lookupFuture(state: *HappyEyeballsState, family: AddressFamily) *?VoidFuture {
        return switch (family) {
            .ip4 => &state.lookup_ip4_future,
            .ip6 => &state.lookup_ip6_future,
        };
    }

    fn lookupStarted(state: *const HappyEyeballsState, family: AddressFamily) bool {
        return state.lookupDone(family) or switch (family) {
            .ip4 => state.lookup_ip4_future != null,
            .ip6 => state.lookup_ip6_future != null,
        };
    }

    fn startLookup(
        state: *HappyEyeballsState,
        host: HostName,
        port: u16,
        family: AddressFamily,
    ) error{SystemResources}!bool {
        if (state.lookupStarted(family)) return false;
        // These workers publish into a queue consumed by this coordinator.
        // `Io.async` may execute inline when its worker pool is saturated,
        // which would block the consumer behind a DNS or timer deadline.
        state.lookupFuture(family).* = state.io.concurrent(runResolution, .{
            state.resolution_backend,
            host,
            state.io,
            port,
            family,
            state.events,
        }) catch return error.SystemResources;
        return true;
    }

    fn startAlternateLookup(
        state: *HappyEyeballsState,
        host: HostName,
        port: u16,
    ) error{SystemResources}!bool {
        if (!usesBothFamilies(state.policy)) return false;
        const alternate = otherFamily(preferredFamily(state.policy));
        if (state.lookupStarted(alternate)) return false;
        cancelVoidFuture(&state.alternate_lookup_timer, state.io);
        return state.startLookup(host, port, alternate);
    }

    fn maybeStartAlternateLookup(
        state: *HappyEyeballsState,
        host: HostName,
        port: u16,
    ) error{SystemResources}!void {
        if (!usesBothFamilies(state.policy)) return;
        const preferred = preferredFamily(state.policy);
        const preferred_exhausted = state.lookupDone(preferred) and
            !state.addresses.hasFamily(preferred) and state.active_count == 0;
        if (state.alternate_lookup_delay_elapsed or preferred_exhausted) {
            _ = try state.startAlternateLookup(host, port);
        }
    }

    fn finishLookup(state: *HappyEyeballsState, family: AddressFamily, lookup_error: ?HostName.LookupError) void {
        switch (family) {
            .ip4 => {
                if (state.lookup_ip4_done) return;
                finishVoidFuture(&state.lookup_ip4_future, state.io);
                state.lookup_ip4_done = true;
            },
            .ip6 => {
                if (state.lookup_ip6_done) return;
                finishVoidFuture(&state.lookup_ip6_future, state.io);
                state.lookup_ip6_done = true;
            },
        }
        if (lookup_error) |err| state.last_lookup_error = err;
    }

    fn finishAttempt(state: *HappyEyeballsState, id: u64) bool {
        for (&state.active) |*maybe_attempt| {
            const attempt = maybe_attempt.* orelse continue;
            if (attempt.id != id) continue;
            var future = attempt.future;
            maybe_attempt.* = null;
            state.active_count -= 1;
            future.await(state.io);
            return true;
        }
        return false;
    }

    fn discardOldestAttempt(state: *HappyEyeballsState) void {
        var oldest_index: ?usize = null;
        var oldest_order: u64 = std.math.maxInt(u64);
        for (state.active, 0..) |maybe_attempt, index| {
            const attempt = maybe_attempt orelse continue;
            if (attempt.order < oldest_order) {
                oldest_order = attempt.order;
                oldest_index = index;
            }
        }
        const index = oldest_index orelse return;
        var attempt = state.active[index].?;
        state.active[index] = null;
        state.active_count -= 1;
        attempt.future.cancel(state.io);
    }

    fn scheduleTimer(
        state: *HappyEyeballsState,
        future: *?VoidFuture,
        generation: *u64,
        kind: TimerKind,
        timeout: Io.Timeout,
    ) error{SystemResources}!void {
        cancelVoidFuture(future, state.io);
        generation.* +%= 1;
        future.* = state.io.concurrent(publishTimer, .{
            state.io,
            state.events,
            kind,
            generation.*,
            timeout,
        }) catch return error.SystemResources;
    }

    fn consumeTimer(state: *HappyEyeballsState, kind: TimerKind, generation: u64) bool {
        switch (kind) {
            .alternate_lookup => {
                if (generation != state.alternate_lookup_generation) return false;
                finishVoidFuture(&state.alternate_lookup_timer, state.io);
            },
            .pace => {
                if (generation != state.pace_generation) return false;
                finishVoidFuture(&state.pace_timer, state.io);
            },
            .deadline => {
                if (generation != state.deadline_generation) return false;
                finishVoidFuture(&state.deadline_timer, state.io);
            },
        }
        return true;
    }

    fn launchNext(state: *HappyEyeballsState) error{SystemResources}!bool {
        const address = state.addresses.popNext(&state.next_family) orelse return false;
        cancelVoidFuture(&state.pace_timer, state.io);

        if (state.active_count == happy_eyeballs_max_active_attempts) state.discardOldestAttempt();

        const id = state.next_attempt_id;
        state.next_attempt_id +%= 1;
        const order = state.next_attempt_order;
        state.next_attempt_order +%= 1;
        const future = state.io.concurrent(runConnectionAttempt, .{
            state.io,
            state.events,
            id,
            address,
            state.connect_options,
            state.connection_backend,
        }) catch return error.SystemResources;
        for (&state.active) |*maybe_attempt| {
            if (maybe_attempt.* != null) continue;
            maybe_attempt.* = .{ .id = id, .order = order, .future = future };
            state.active_count += 1;
            break;
        } else unreachable;

        if (!state.started) {
            state.started = true;
        }

        state.immediate_next = false;
        const now = Io.Timestamp.now(state.io, .awake);
        const next_launch = now.addDuration(Io.Duration.fromMilliseconds(happy_eyeballs_connection_delay_ms));
        state.next_launch = next_launch;
        if (state.addresses.hasPending()) {
            try state.scheduleTimer(
                &state.pace_timer,
                &state.pace_generation,
                .pace,
                .{ .deadline = next_launch.withClock(.awake) },
            );
        }
        return true;
    }

    /// Advances scheduling until another resolver, timer, or connection event
    /// is needed. A definitive connection failure sets `immediate_next`, while
    /// unanswered attempts remain open and are paced 200 ms apart.
    fn drive(state: *HappyEyeballsState) error{SystemResources}!void {
        if (!state.started) {
            const preferred = preferredFamily(state.policy);
            if (state.addresses.hasFamily(preferred)) {
                _ = try state.launchNext();
                return;
            }

            const alternate = otherFamily(preferred);
            if (!state.addresses.hasFamily(alternate)) return;
            if (state.lookupDone(preferred) or state.alternate_lookup_delay_elapsed) {
                _ = try state.launchNext();
            }
            return;
        }

        if (!state.addresses.hasPending()) {
            cancelVoidFuture(&state.pace_timer, state.io);
            return;
        }
        if (state.immediate_next or state.active_count == 0) {
            _ = try state.launchNext();
            return;
        }

        const next_launch = state.next_launch orelse unreachable;
        const now = Io.Timestamp.now(state.io, .awake);
        if (now.nanoseconds >= next_launch.nanoseconds) {
            _ = try state.launchNext();
            return;
        }
        if (state.pace_timer == null) {
            try state.scheduleTimer(
                &state.pace_timer,
                &state.pace_generation,
                .pace,
                .{ .deadline = next_launch.withClock(.awake) },
            );
        }
    }

    fn terminalError(state: *const HappyEyeballsState) ?HostName.ConnectError {
        if (!state.allLookupsDone() or state.addresses.hasPending() or state.active_count != 0) return null;
        if (state.last_connect_error) |err| return err;
        if (state.last_lookup_error) |err| return err;
        return error.NoAddressReturned;
    }
};

/// Starts the preferred Zig-native DNS query immediately, delays the alternate
/// family query by 50 ms unless the preferred family is exhausted first, and
/// applies libcurl's per-address Happy Eyeballs connection pacing.
fn connectHost(
    host: HostName,
    io: Io,
    port: u16,
    policy: AddressFamilyPolicy,
    options: IpAddress.ConnectOptions,
) HostName.ConnectError!Stream {
    return connectHostWithBackend(host, io, port, policy, options, .{});
}

fn connectHostWithBackend(
    host: HostName,
    io: Io,
    port: u16,
    policy: AddressFamilyPolicy,
    options: IpAddress.ConnectOptions,
    connection_backend: ConnectionBackend,
) HostName.ConnectError!Stream {
    return connectHostWithBackends(host, io, port, policy, options, connection_backend, .{});
}

fn connectHostWithBackends(
    host: HostName,
    io: Io,
    port: u16,
    policy: AddressFamilyPolicy,
    options: IpAddress.ConnectOptions,
    connection_backend: ConnectionBackend,
    resolution_backend: ResolutionBackend,
) HostName.ConnectError!Stream {
    var event_buffer: [happy_eyeballs_event_capacity]HappyEyeballsEvent = undefined;
    var events: EventQueue = .init(&event_buffer);
    var state: HappyEyeballsState = .initWithBackends(
        io,
        &events,
        policy,
        options,
        connection_backend,
        resolution_backend,
    );
    defer state.deinit();

    // The connection timeout covers DNS as well as socket establishment.
    // Starting it only after the first address arrives leaves a failed or
    // stalled resolver unbounded and can make callers look permanently hung.
    if (state.overall_timeout != .none) {
        try state.scheduleTimer(
            &state.deadline_timer,
            &state.deadline_generation,
            .deadline,
            state.overall_timeout.toDeadline(state.io),
        );
    }

    _ = try state.startLookup(host, port, preferredFamily(policy));
    if (usesBothFamilies(policy)) {
        try state.scheduleTimer(
            &state.alternate_lookup_timer,
            &state.alternate_lookup_generation,
            .alternate_lookup,
            .{ .duration = .{
                .raw = Io.Duration.fromMilliseconds(happy_eyeballs_resolution_delay_ms),
                .clock = .awake,
            } },
        );
    }

    while (true) {
        const event = events.getOne(io) catch |err| switch (err) {
            error.Canceled => |canceled| return canceled,
            error.Closed => return error.Unexpected,
        };
        switch (event) {
            .address => |address| state.addresses.append(address),
            .lookup_done => |done| state.finishLookup(done.family, done.err),
            .connection => |connection| {
                if (!state.finishAttempt(connection.id)) {
                    closeConnectionResult(io, connection.result);
                    continue;
                }
                if (connection.result) |stream| {
                    return stream;
                } else |err| {
                    if (isFatalConnectError(err)) return err;
                    state.last_connect_error = err;
                    state.immediate_next = true;
                }
            },
            .timer => |timer| {
                if (!state.consumeTimer(timer.kind, timer.generation)) continue;
                switch (timer.kind) {
                    .alternate_lookup => state.alternate_lookup_delay_elapsed = true,
                    .pace => {},
                    .deadline => return error.Timeout,
                }
            },
        }

        try state.maybeStartAlternateLookup(host, port);
        try state.drive();
        if (state.terminalError()) |err| return err;
    }
}

fn preferredFamily(policy: AddressFamilyPolicy) AddressFamily {
    return switch (policy) {
        .happy_eyeballs, .ipv6_only => .ip6,
        .prefer_ipv4, .ipv4_only => .ip4,
    };
}

fn otherFamily(family: AddressFamily) AddressFamily {
    return switch (family) {
        .ip4 => .ip6,
        .ip6 => .ip4,
    };
}

fn usesBothFamilies(policy: AddressFamilyPolicy) bool {
    return policy == .happy_eyeballs or policy == .prefer_ipv4;
}

fn cancelVoidFuture(maybe_future: *?VoidFuture, io: Io) void {
    if (maybe_future.*) |*future| future.cancel(io);
    maybe_future.* = null;
}

fn finishVoidFuture(maybe_future: *?VoidFuture, io: Io) void {
    if (maybe_future.*) |*future| future.await(io);
    maybe_future.* = null;
}

fn publishTimer(
    io: Io,
    events: *EventQueue,
    kind: TimerKind,
    generation: u64,
    timeout: Io.Timeout,
) void {
    timeout.sleep(io) catch return;
    events.putOne(io, .{ .timer = .{ .kind = kind, .generation = generation } }) catch {};
}

fn runResolution(
    backend: ResolutionBackend,
    host: HostName,
    io: Io,
    port: u16,
    family: AddressFamily,
    events: *EventQueue,
) void {
    backend.resolve(host, io, port, family, events);
}

fn resolveFamily(
    host: HostName,
    io: Io,
    port: u16,
    family: AddressFamily,
    events: *EventQueue,
) void {
    var canonical_name_buffer: [HostName.max_len]u8 = undefined;
    var lookup_buffer: [max_resolved_addresses_per_family]HostName.LookupResult = undefined;
    var lookup_queue: Io.Queue(HostName.LookupResult) = .init(&lookup_buffer);
    // resolver.lookup produces into lookup_queue, so its consumer must be able
    // to run concurrently even when the ordinary async worker limit is full.
    var lookup_future = io.concurrent(resolver.lookup, .{ host, io, &lookup_queue, .{
        .port = port,
        .family = family,
        .canonical_name_buffer = &canonical_name_buffer,
    } }) catch {
        events.putOne(io, .{ .lookup_done = .{
            .family = family,
            .err = error.SystemResources,
        } }) catch {};
        return;
    };
    defer lookup_future.cancel(io) catch {};

    while (lookup_queue.getOne(io)) |result| switch (result) {
        .address => |address| events.putOne(io, .{ .address = address }) catch return,
        .canonical_name => {},
    } else |err| switch (err) {
        error.Canceled => return,
        error.Closed => {},
    }

    lookup_future.await(io) catch |err| {
        if (err == error.Canceled) return;
        events.putOne(io, .{ .lookup_done = .{ .family = family, .err = err } }) catch {};
        return;
    };
    events.putOne(io, .{ .lookup_done = .{ .family = family, .err = null } }) catch {};
}

fn runConnectionAttempt(
    io: Io,
    events: *EventQueue,
    id: u64,
    address: IpAddress,
    options: IpAddress.ConnectOptions,
    connection_backend: ConnectionBackend,
) void {
    const stream = connection_backend.connect(address, io, options) catch |err| {
        if (err == error.Canceled) return;
        const result: ConnectionResult = err;
        events.putOne(io, .{ .connection = .{ .id = id, .result = result } }) catch {};
        return;
    };
    const result: ConnectionResult = stream;
    events.putOne(io, .{ .connection = .{ .id = id, .result = result } }) catch {
        stream.close(io);
    };
}

fn closeEventStream(io: Io, event: HappyEyeballsEvent) void {
    switch (event) {
        .connection => |connection| closeConnectionResult(io, connection.result),
        else => {},
    }
}

fn closeConnectionResult(io: Io, result: ConnectionResult) void {
    if (result) |stream| stream.close(io) else |_| {}
}

fn isFatalConnectError(err: IpAddress.ConnectError) bool {
    return switch (err) {
        error.SystemResources,
        error.OptionUnsupported,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.ProtocolUnsupportedBySystem,
        error.SocketModeUnsupported,
        error.Unexpected,
        => true,
        else => false,
    };
}

/// The production downloader uses `Io.Threaded` on Linux. Owning a
/// nonblocking descriptor per attempt lets the scheduler cancel losers without
/// waiting for a kernel TCP timeout. Other targets retain Zig's portable
/// connector while using the same Happy Eyeballs coordinator.
fn connectAddressNonBlocking(
    address: IpAddress,
    io: Io,
    options: IpAddress.ConnectOptions,
) IpAddress.ConnectError!Stream {
    if (comptime builtin.os.tag == .linux) return connectAddressPosix(address, io, options);
    return address.connect(io, options);
}

fn connectAddressPosix(
    address: IpAddress,
    io: Io,
    options: IpAddress.ConnectOptions,
) IpAddress.ConnectError!Stream {
    try io.checkCancel();
    const family = Io.Threaded.posixAddressFamily(&address);
    const mode, const protocol = try Io.Threaded.posixSocketModeProtocol(family, options.mode, options.protocol);
    const flags: u32 = mode | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;

    const socket_fd: posix.socket_t = while (true) {
        const rc = posix.system.socket(family, flags, protocol);
        switch (posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => {
                try io.checkCancel();
                continue;
            },
            .ACCES, .PERM => return error.AccessDenied,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .INVAL => return error.ProtocolUnsupportedBySystem,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
            .PROTOTYPE => return error.SocketModeUnsupported,
            else => return error.Unexpected,
        }
    };
    errdefer closeSocketFd(io, socket_fd, address);

    var storage: Io.Threaded.PosixAddress = undefined;
    const address_len = Io.Threaded.addressToPosix(&address, &storage);
    connect: while (true) {
        try io.checkCancel();
        switch (posix.errno(posix.system.connect(socket_fd, &storage.any, address_len))) {
            .SUCCESS, .ISCONN => break :connect,
            .INTR => continue,
            .AGAIN, .INPROGRESS, .ALREADY => {},
            else => |err| return mapConnectErrno(err),
        }

        var poll_fd: posix.pollfd = .{
            .fd = socket_fd,
            .events = posix.POLL.OUT | posix.POLL.ERR | posix.POLL.HUP,
            .revents = 0,
        };
        while (true) {
            try io.checkCancel();
            poll_fd.revents = 0;
            const poll_rc = posix.system.poll(@ptrCast(&poll_fd), 1, happy_eyeballs_poll_interval_ms);
            switch (posix.errno(poll_rc)) {
                .SUCCESS => if (poll_rc == 0) continue,
                .INTR => continue,
                .NOMEM => return error.SystemResources,
                else => return error.Unexpected,
            }
            if ((poll_fd.revents & posix.POLL.NVAL) != 0) return error.Unexpected;
            break;
        }

        var socket_error: c_int = 0;
        var socket_error_len: posix.socklen_t = @sizeOf(c_int);
        while (true) {
            try io.checkCancel();
            const rc = posix.system.getsockopt(
                socket_fd,
                posix.SOL.SOCKET,
                posix.SO.ERROR,
                @ptrCast(&socket_error),
                &socket_error_len,
            );
            switch (posix.errno(rc)) {
                .SUCCESS => break,
                .INTR => continue,
                else => return error.Unexpected,
            }
        }
        const connect_error: posix.E = @enumFromInt(socket_error);
        switch (connect_error) {
            .SUCCESS, .ISCONN => break :connect,
            .INPROGRESS, .ALREADY => continue :connect,
            else => return mapConnectErrno(connect_error),
        }
    }

    try setSocketBlocking(io, socket_fd);
    var local_storage: Io.Threaded.PosixAddress = undefined;
    var local_len: posix.socklen_t = @sizeOf(Io.Threaded.PosixAddress);
    while (true) {
        try io.checkCancel();
        switch (posix.errno(posix.system.getsockname(socket_fd, &local_storage.any, &local_len))) {
            .SUCCESS => break,
            .INTR => continue,
            .NOBUFS => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
    return .{ .socket = .{
        .handle = socket_fd,
        .address = Io.Threaded.addressFromPosix(&local_storage),
    } };
}

fn setSocketBlocking(io: Io, socket_fd: posix.socket_t) IpAddress.ConnectError!void {
    var file_flags: usize = while (true) {
        try io.checkCancel();
        const rc = posix.system.fcntl(socket_fd, posix.F.GETFL, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            else => return error.Unexpected,
        }
    };
    file_flags &= ~(@as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK"));
    while (true) {
        try io.checkCancel();
        switch (posix.errno(posix.system.fcntl(socket_fd, posix.F.SETFL, file_flags))) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

fn closeSocketFd(io: Io, socket_fd: posix.socket_t, address: IpAddress) void {
    const socket: Socket = .{ .handle = socket_fd, .address = address };
    socket.close(io);
}

fn mapConnectErrno(err: posix.E) IpAddress.ConnectError {
    return switch (err) {
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .AGAIN, .INPROGRESS => error.WouldBlock,
        .ALREADY => error.ConnectionPending,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .TIMEDOUT => error.Timeout,
        .ACCES, .PERM => error.AccessDenied,
        .NETDOWN => error.NetworkDown,
        .NOBUFS, .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

pub const ConnectUnixError = Allocator.Error || std.posix.SocketError || error{NameTooLong} || std.posix.ConnectError;

/// Connect to `path` as a unix domain socket. This will reuse a connection if one is already open.
///
/// This function is threadsafe.
pub fn connectUnix(client: *Client, path: []const u8) ConnectUnixError!*Connection {
    const io = client.io;

    if (client.connection_pool.findConnection(io, .{
        .host = path,
        .port = 0,
        .protocol = .plain,
    })) |node|
        return node;

    const conn = try client.allocator.create(ConnectionPool.Node);
    errdefer client.allocator.destroy(conn);
    conn.* = .{ .data = undefined };

    const stream = try Io.net.connectUnixSocket(path);
    errdefer stream.close(io);

    conn.data = .{
        .stream = stream,
        .tls_client = undefined,
        .protocol = .plain,

        .host = try client.allocator.dupe(u8, path),
        .port = 0,
    };
    errdefer client.allocator.free(conn.data.host);

    client.connection_pool.addUsed(conn);

    return &conn.data;
}

/// Connect to `proxied_host:proxied_port` using the specified proxy with HTTP
/// CONNECT. This will reuse a connection if one is already open.
///
/// This function is threadsafe.
pub fn connectProxied(
    client: *Client,
    proxy: *Proxy,
    proxied_host: HostName,
    proxied_port: u16,
) ConnectError!*Connection {
    const io = client.io;
    if (!proxy.supports_connect) return error.TunnelNotSupported;
    // TLS to the proxy followed by TLS inside the CONNECT tunnel requires a
    // nested TLS transport. The compatibility client does not implement that
    // transport yet; fail closed rather than sending destination traffic with
    // the wrong protocol.
    if (proxy.protocol != .plain) return error.UnsupportedProxyScheme;

    if (client.connection_pool.findConnection(io, .{
        .host = proxied_host,
        .port = proxied_port,
        .protocol = .tls,
    })) |node| return node;

    try ensureTlsInitialized(client);

    const connection = try client.connectTcp(proxy.host, proxy.port, .plain);
    // CONNECT itself uses authority-form and carries its authorization header
    // explicitly below. Do not let forward-proxy request formatting add a
    // second, potentially unrelated proxy authorization header.
    connection.proxied = false;
    var release_connection = true;
    errdefer if (release_connection) {
        connection.closing = true;
        client.connection_pool.release(connection, io);
    };

    var proxy_header: [1]http.Header = undefined;
    const proxy_headers: []const http.Header = if (proxy.authorization) |authorization| headers: {
        proxy_header[0] = .{ .name = "proxy-authorization", .value = authorization };
        break :headers &proxy_header;
    } else &.{};
    var req = client.request(.CONNECT, .{
        .scheme = "http",
        .host = .{ .raw = proxied_host.bytes },
        .port = proxied_port,
    }, .{
        .redirect_behavior = .unhandled,
        .connection = connection,
        .extra_headers = proxy_headers,
    }) catch return error.ProxyTunnelFailed;
    release_connection = false;
    defer req.deinit();
    errdefer {
        if (req.connection) |failed_connection| failed_connection.closing = true;
    }

    req.sendBodiless() catch return error.ProxyTunnelFailed;
    const response = req.receiveHead(&.{}) catch return error.ProxyTunnelFailed;
    if (response.head.status.class() != .success) {
        connection.closing = true;
        return error.ProxyTunnelRejected;
    }

    // The CONNECT request no longer owns this stream. Replace its temporary
    // plain HTTP connection with a TLS connection for the destination.
    req.connection = null;
    const stream = connection.getStream();
    client.connection_pool.removeUsed(io, connection);
    const plain: *Connection.Plain = @alignCast(@fieldParentPtr("connection", connection));
    plain.destroy();

    var stream_owned = true;
    errdefer if (stream_owned) stream.close(io);
    const tls = Connection.Tls.create(client, proxied_host, proxied_port, stream) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Unexpected => |e| return e,
        error.Canceled => |e| return e,
        else => return error.TlsInitializationFailed,
    };
    stream_owned = false;
    client.connection_pool.addUsed(io, &tls.connection);
    return &tls.connection;
}

pub const ConnectError = ConnectTcpError || RequestError;

/// Connect to `host:port` using the specified protocol. This will reuse a
/// connection if one is already open.
///
/// If a proxy is configured for the client, then the proxy will be used to
/// connect to the host.
///
/// This function is threadsafe.
pub fn connect(
    client: *Client,
    host: HostName,
    port: u16,
    protocol: Protocol,
) ConnectError!*Connection {
    try client.ensureDefaultProxies();

    const proxy = switch (protocol) {
        .plain => client.http_proxy,
        .tls => client.https_proxy,
    } orelse return client.connectTcp(host, port, protocol);

    // Prevent proxying through itself.
    if (proxy.host.eql(host) and proxy.port == port and proxy.protocol == protocol) {
        return client.connectTcp(host, port, protocol);
    }
    if (proxy.protocol != .plain) return error.UnsupportedProxyScheme;

    if (protocol == .tls) return connectProxied(client, proxy, host, port);

    // Plain HTTP uses the proxy as a normal forward proxy. Request.sendHead
    // emits an absolute-form target whenever `proxied` is true.
    const connection = try client.connectTcp(proxy.host, proxy.port, proxy.protocol);
    connection.proxied = true;
    return connection;
}

pub const RequestError = ConnectTcpError || error{
    UnsupportedUriScheme,
    UriMissingHost,
    CertificateBundleLoadFailure,
    InvalidProxyConfiguration,
    UnsupportedProxyScheme,
    TunnelNotSupported,
    ProxyTunnelRejected,
    ProxyTunnelFailed,
};

pub const RequestOptions = struct {
    version: http.Version = .@"HTTP/1.1",

    /// Automatically ignore 100 Continue responses. This assumes you don't
    /// care, and will have sent the body before you wait for the response.
    ///
    /// If this is not the case AND you know the server will send a 100
    /// Continue, set this to false and wait for a response before sending the
    /// body. If you wait AND the server does not send a 100 Continue before
    /// you finish the request, then the request *will* deadlock.
    handle_continue: bool = true,

    /// If false, close the connection after the one request. If true,
    /// participate in the client connection pool.
    keep_alive: bool = true,

    /// This field specifies whether to automatically follow redirects, and if
    /// so, how many redirects to follow before returning an error.
    ///
    /// This will only follow redirects for repeatable requests (ie. with no
    /// payload or the server has acknowledged the payload).
    redirect_behavior: Request.RedirectBehavior = @enumFromInt(3),

    /// Must be an already acquired connection.
    connection: ?*Connection = null,

    /// Standard headers that have default, but overridable, behavior.
    headers: Request.Headers = .{},
    /// These headers are kept including when following a redirect to a
    /// different domain.
    /// Externally-owned; must outlive the Request.
    extra_headers: []const http.Header = &.{},
    /// These headers are stripped when following a redirect to a different
    /// domain.
    /// Externally-owned; must outlive the Request.
    privileged_headers: []const http.Header = &.{},
};

fn uriPort(uri: Uri, protocol: Protocol) u16 {
    return uri.port orelse protocol.port();
}

/// Open a connection to the host specified by `uri` and prepare to send a HTTP request.
///
/// The caller is responsible for calling `deinit()` on the `Request`.
/// This function is threadsafe.
///
/// Asserts that "\r\n" does not occur in any header name or value.
pub fn request(
    client: *Client,
    method: http.Method,
    uri: Uri,
    options: RequestOptions,
) RequestError!Request {
    if (std.debug.runtime_safety) {
        for (options.extra_headers) |header| {
            assert(header.name.len != 0);
            assert(std.mem.findScalar(u8, header.name, ':') == null);
            assert(std.mem.findPosLinear(u8, header.name, 0, "\r\n") == null);
            assert(std.mem.findPosLinear(u8, header.value, 0, "\r\n") == null);
        }
        for (options.privileged_headers) |header| {
            assert(header.name.len != 0);
            assert(std.mem.findPosLinear(u8, header.name, 0, "\r\n") == null);
            assert(std.mem.findPosLinear(u8, header.value, 0, "\r\n") == null);
        }
    }

    const protocol = Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;

    const connection = options.connection orelse c: {
        var host_name_buffer: [HostName.max_len]u8 = undefined;
        const host_name = try uri.getHost(&host_name_buffer);
        break :c try client.connect(host_name, uriPort(uri, protocol), protocol);
    };

    return .{
        .uri = uri,
        .client = client,
        .connection = connection,
        .reader = .{
            .in = connection.reader(),
            .state = .ready,
            // Populated when `http.Reader.bodyReader` is called.
            .interface = undefined,
            .max_head_len = client.read_buffer_size,
        },
        .keep_alive = options.keep_alive,
        .method = method,
        .version = options.version,
        .transfer_encoding = .none,
        .redirect_behavior = options.redirect_behavior,
        .handle_continue = options.handle_continue,
        .headers = options.headers,
        .extra_headers = options.extra_headers,
        .privileged_headers = options.privileged_headers,
    };
}

pub const FetchOptions = struct {
    /// `null` means it will be heap-allocated. RFC 9110 recommends at least
    /// 8000 bytes.
    redirect_buffer: ?[]u8 = null,
    /// `null` means it will be heap-allocated.
    decompress_buffer: ?[]u8 = null,
    redirect_behavior: ?Request.RedirectBehavior = null,
    /// If the server sends a body, it will be written here.
    response_writer: ?*Writer = null,

    location: Location,
    method: ?http.Method = null,
    payload: ?[]const u8 = null,
    raw_uri: bool = false,
    keep_alive: bool = true,

    /// Standard headers that have default, but overridable, behavior.
    headers: Request.Headers = .{},
    /// These headers are kept including when following a redirect to a
    /// different domain.
    /// Externally-owned; must outlive the Request.
    extra_headers: []const http.Header = &.{},
    /// These headers are stripped when following a redirect to a different
    /// domain.
    /// Externally-owned; must outlive the Request.
    privileged_headers: []const http.Header = &.{},

    pub const Location = union(enum) {
        url: []const u8,
        uri: Uri,
    };
};

pub const FetchResult = struct {
    status: http.Status,
};

pub const FetchError = Uri.ParseError || RequestError || Request.ReceiveHeadError || error{
    StreamTooLong,
    /// TODO provide optional diagnostics when this occurs or break into more error codes
    WriteFailed,
    UnsupportedCompressionMethod,
};

/// Perform a one-shot HTTP request with the provided options.
///
/// This function is threadsafe.
pub fn fetch(client: *Client, options: FetchOptions) FetchError!FetchResult {
    const uri = switch (options.location) {
        .url => |u| try Uri.parse(u),
        .uri => |u| u,
    };
    const method: http.Method = options.method orelse
        if (options.payload != null) .POST else .GET;

    const redirect_behavior: Request.RedirectBehavior = options.redirect_behavior orelse
        if (options.payload == null) @enumFromInt(3) else .unhandled;

    var req = try request(client, method, uri, .{
        .redirect_behavior = redirect_behavior,
        .headers = options.headers,
        .extra_headers = options.extra_headers,
        .privileged_headers = options.privileged_headers,
        .keep_alive = options.keep_alive,
    });
    defer req.deinit();

    if (options.payload) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(payload);
        try body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    const redirect_buffer: []u8 = if (redirect_behavior == .unhandled) &.{} else options.redirect_buffer orelse
        try client.allocator.alloc(u8, 8 * 1024);
    defer if (options.redirect_buffer == null) client.allocator.free(redirect_buffer);

    var response = try req.receiveHead(redirect_buffer);

    const response_writer = options.response_writer orelse {
        const reader = response.reader(&.{});
        _ = reader.discardRemaining() catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
        };
        return .{ .status = response.head.status };
    };

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => options.decompress_buffer orelse try client.allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => options.decompress_buffer orelse try client.allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (options.decompress_buffer == null) client.allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    _ = reader.streamRemaining(response_writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };

    return .{ .status = response.head.status };
}

test {
    _ = Response;
}

fn consumeTestRequestHead(reader: *Io.Reader) !void {
    while (true) {
        const line = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
        if (std.mem.eql(u8, line, "\r")) return;
    }
}

const HttpToTlsRedirectTestServer = struct {
    io: Io,
    server: Io.net.Server,

    fn init(io: Io) !HttpToTlsRedirectTestServer {
        var address: IpAddress = .{ .ip4 = .loopback(0) };
        return .{
            .io = io,
            .server = try address.listen(io, .{ .reuse_address = true }),
        };
    }

    fn deinit(server: *HttpToTlsRedirectTestServer) void {
        server.server.deinit(server.io);
    }

    fn url(server: *const HttpToTlsRedirectTestServer, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "http://127.0.0.1:{d}/source",
            .{server.server.socket.address.getPort()},
        );
    }

    fn serve(server: *HttpToTlsRedirectTestServer) !void {
        {
            var stream = try server.server.accept(server.io);
            defer stream.close(server.io);

            var read_buffer: [2048]u8 = undefined;
            var stream_reader = stream.reader(server.io, &read_buffer);
            try consumeTestRequestHead(&stream_reader.interface);

            var write_buffer: [512]u8 = undefined;
            var stream_writer = stream.writer(server.io, &write_buffer);
            try stream_writer.interface.print(
                "HTTP/1.1 301 Moved Permanently\r\n" ++
                    "Location: https://127.0.0.1:{d}/source\r\n" ++
                    "Content-Length: 0\r\n" ++
                    "Connection: close\r\n\r\n",
                .{server.server.socket.address.getPort()},
            );
            try stream_writer.interface.flush();
        }

        // Accept the redirected TLS connection, then close it without a
        // handshake. The client must return a typed TLS error rather than
        // reaching Tls.create with uninitialized trust state.
        var stream = try server.server.accept(server.io);
        stream.close(server.io);
    }
};

test "HTTP to HTTPS redirect initializes TLS before connecting" {
    if (disable_tls) return error.SkipZigTest;

    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try HttpToTlsRedirectTestServer.init(io);
    defer server.deinit();
    var server_future = try io.concurrent(HttpToTlsRedirectTestServer.serve, .{&server});
    defer _ = server_future.cancel(io) catch {};

    const url = try server.url(testing.allocator);
    defer testing.allocator.free(url);
    var client: Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();

    var request_value = try client.request(.GET, try Uri.parse(url), .{
        .redirect_behavior = .init(1),
    });
    defer request_value.deinit();
    try request_value.sendBodiless();

    var redirect_buffer: [1024]u8 = undefined;
    try testing.expectError(
        error.TlsInitializationFailed,
        request_value.receiveHead(&redirect_buffer),
    );
    try testing.expect(client.now != null);
    try server_future.await(io);
}

test "direct TLS connection initializes trust state before handshake" {
    if (disable_tls) return error.SkipZigTest;

    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listen_address: IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen_address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var server_future = try io.concurrent(acceptOneTestConnection, .{ &server, io });
    defer _ = server_future.cancel(io) catch {};

    var client: Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    const host = try HostName.init("127.0.0.1");
    try testing.expectError(
        error.TlsInitializationFailed,
        client.connectTcp(host, server.socket.address.getPort(), .tls),
    );
    try testing.expect(client.now != null);
    try server_future.await(io);
}

test "concurrent TLS initialization loads one stable trust state" {
    if (disable_tls) return error.SkipZigTest;

    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var client: Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();

    var first = try io.concurrent(ensureTlsInitialized, .{&client});
    defer _ = first.cancel(io) catch {};
    var second = try io.concurrent(ensureTlsInitialized, .{&client});
    defer _ = second.cancel(io) catch {};
    try first.await(io);
    try second.await(io);

    const initialized_at = client.now orelse return error.ExpectedTlsInitialization;
    const bundle_ptr = client.ca_bundle.bytes.items.ptr;
    const bundle_len = client.ca_bundle.bytes.items.len;
    try ensureTlsInitialized(&client);

    try testing.expectEqual(initialized_at.nanoseconds, client.now.?.nanoseconds);
    try testing.expect(bundle_ptr == client.ca_bundle.bytes.items.ptr);
    try testing.expectEqual(bundle_len, client.ca_bundle.bytes.items.len);
}

test "Zig resolver uses the host database for an IPv4 query" {
    const host = try HostName.init("localhost");
    var event_buffer: [happy_eyeballs_event_capacity]HappyEyeballsEvent = undefined;
    var events: EventQueue = .init(&event_buffer);
    defer events.close(testing.io);

    resolveFamily(host, testing.io, 443, .ip4, &events);
    var drained: [happy_eyeballs_event_capacity]HappyEyeballsEvent = undefined;
    const count = try events.get(testing.io, &drained, 0);
    var address_count: usize = 0;
    var lookup_completed = false;
    for (drained[0..count]) |event| switch (event) {
        .address => |address| {
            try testing.expect(address == .ip4);
            try testing.expectEqual(@as(u16, 443), address.getPort());
            address_count += 1;
        },
        .lookup_done => |done| {
            try testing.expectEqual(AddressFamily.ip4, done.family);
            try testing.expectEqual(@as(?HostName.LookupError, null), done.err);
            lookup_completed = true;
        },
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(address_count > 0);
    try testing.expect(lookup_completed);
}

test "resolved addresses alternate in curl Happy Eyeballs order" {
    var resolved: ResolvedAddresses = .{};
    resolved.append(try IpAddress.parse("::1", 80));
    resolved.append(try IpAddress.parse("::2", 80));
    resolved.append(try IpAddress.parse("127.0.0.1", 80));
    resolved.append(try IpAddress.parse("127.0.0.2", 80));

    var next_family: AddressFamily = .ip6;
    try testing.expect((resolved.popNext(&next_family) orelse return error.TestUnexpectedResult) == .ip6);
    try testing.expect((resolved.popNext(&next_family) orelse return error.TestUnexpectedResult) == .ip4);
    try testing.expect((resolved.popNext(&next_family) orelse return error.TestUnexpectedResult) == .ip6);
    try testing.expect((resolved.popNext(&next_family) orelse return error.TestUnexpectedResult) == .ip4);
    try testing.expect(resolved.popNext(&next_family) == null);
}

const BlackholeTestContext = struct {
    ip6_started_ms: std.atomic.Value(i64) = .init(-1),
    ip4_started_ms: std.atomic.Value(i64) = .init(-1),
    ip6_canceled: std.atomic.Value(bool) = .init(false),
};

const FastPreferredResolutionContext = struct {
    ip4_started: std.atomic.Value(u32) = .init(0),
    ip6_started: std.atomic.Value(u32) = .init(0),
};

fn resolveFastPreferredIpv4(
    raw_context: ?*anyopaque,
    host: HostName,
    io: Io,
    port: u16,
    family: AddressFamily,
    events: *EventQueue,
) void {
    _ = host;
    const context: *FastPreferredResolutionContext = @ptrCast(@alignCast(raw_context.?));
    switch (family) {
        .ip4 => {
            _ = context.ip4_started.fetchAdd(1, .acq_rel);
            events.putOne(io, .{ .address = .{ .ip4 = .loopback(port) } }) catch return;
        },
        .ip6 => _ = context.ip6_started.fetchAdd(1, .acq_rel),
    }
    events.putOne(io, .{ .lookup_done = .{ .family = family, .err = null } }) catch {};
}

const DelayedAlternateResolutionContext = struct {
    ip6_started_ms: std.atomic.Value(i64) = .init(-1),
    ip4_started_ms: std.atomic.Value(i64) = .init(-1),
    ip6_canceled: std.atomic.Value(bool) = .init(false),
};

fn resolveAfterStalledIpv6(
    raw_context: ?*anyopaque,
    host: HostName,
    io: Io,
    port: u16,
    family: AddressFamily,
    events: *EventQueue,
) void {
    _ = host;
    const context: *DelayedAlternateResolutionContext = @ptrCast(@alignCast(raw_context.?));
    const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
    switch (family) {
        .ip6 => {
            context.ip6_started_ms.store(now_ms, .release);
            io.sleep(Io.Duration.fromSeconds(10), .awake) catch |err| {
                if (err == error.Canceled) context.ip6_canceled.store(true, .release);
                return;
            };
        },
        .ip4 => {
            context.ip4_started_ms.store(now_ms, .release);
            events.putOne(io, .{ .address = .{ .ip4 = .loopback(port) } }) catch return;
        },
    }
    events.putOne(io, .{ .lookup_done = .{ .family = family, .err = null } }) catch {};
}

fn pendingTestResolution(
    raw_context: ?*anyopaque,
    host: HostName,
    io: Io,
    port: u16,
    family: AddressFamily,
    events: *EventQueue,
) void {
    _ = raw_context;
    _ = host;
    _ = port;
    _ = family;
    _ = events;
    io.sleep(Io.Duration.fromSeconds(10), .awake) catch {};
}

fn blackholeIp6TestConnect(
    raw_context: ?*anyopaque,
    address: IpAddress,
    io: Io,
    options: IpAddress.ConnectOptions,
) IpAddress.ConnectError!Stream {
    const context: *BlackholeTestContext = @ptrCast(@alignCast(raw_context.?));
    const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
    switch (address) {
        .ip4 => {
            context.ip4_started_ms.store(now_ms, .release);
            return connectAddressNonBlocking(address, io, options);
        },
        .ip6 => {
            context.ip6_started_ms.store(now_ms, .release);
            io.sleep(Io.Duration.fromSeconds(10), .awake) catch |err| {
                if (err == error.Canceled) context.ip6_canceled.store(true, .release);
                return err;
            };
            return error.Timeout;
        },
    }
}

const PendingConnectTestContext = struct {
    canceled: std.atomic.Value(u32) = .init(0),
};

fn pendingTestConnect(
    raw_context: ?*anyopaque,
    address: IpAddress,
    io: Io,
    options: IpAddress.ConnectOptions,
) IpAddress.ConnectError!Stream {
    _ = address;
    _ = options;
    const context: *PendingConnectTestContext = @ptrCast(@alignCast(raw_context.?));
    io.sleep(Io.Duration.fromSeconds(10), .awake) catch |err| {
        if (err == error.Canceled) _ = context.canceled.fetchAdd(1, .acq_rel);
        return err;
    };
    return error.Timeout;
}

test "Happy Eyeballs connection deadline includes DNS resolution" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const host = try HostName.init("stalled-resolution.test");
    const started = Io.Timestamp.now(io, .awake);
    try testing.expectError(error.Timeout, connectHostWithBackends(
        host,
        io,
        443,
        .ipv4_only,
        .{
            .mode = .stream,
            .timeout = .{ .duration = .{
                .raw = Io.Duration.fromMilliseconds(50),
                .clock = .awake,
            } },
        },
        .{},
        .{ .resolveFn = pendingTestResolution },
    ));
    const elapsed = started.durationTo(Io.Timestamp.now(io, .awake));
    try testing.expect(elapsed.nanoseconds < Io.Duration.fromSeconds(1).nanoseconds);
}

test "Happy Eyeballs keeps at most six connection attempts active" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var event_buffer: [happy_eyeballs_event_capacity]HappyEyeballsEvent = undefined;
    var events: EventQueue = .init(&event_buffer);
    var context: PendingConnectTestContext = .{};
    var state: HappyEyeballsState = .initWithBackend(io, &events, .ipv6_only, .{
        .mode = .stream,
    }, .{
        .context = &context,
        .connectFn = pendingTestConnect,
    });
    defer state.deinit();

    inline for (.{ "2001:db8::1", "2001:db8::2", "2001:db8::3", "2001:db8::4", "2001:db8::5", "2001:db8::6", "2001:db8::7" }) |text| {
        state.addresses.append(try IpAddress.parse(text, 443));
    }
    for (0..7) |_| try testing.expect(try state.launchNext());

    try testing.expectEqual(@as(usize, happy_eyeballs_max_active_attempts), state.active_count);
    try testing.expectEqual(@as(u32, 1), context.canceled.load(.acquire));
}

fn acceptOneTestConnection(server: *Io.net.Server, io: Io) Io.net.Server.AcceptError!void {
    var stream = try server.accept(io);
    defer stream.close(io);
}

test "Prefer IPv4 skips the AAAA lookup when IPv4 connects within the DNS delay" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // With no async workers, any correctness-critical use of `Io.async`
    // executes inline. The connection must still beat its one-second deadline.
    var threaded: Io.Threaded = .init(testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();

    var listen_address = try IpAddress.parse("127.0.0.1", 0);
    var server = try listen_address.listen(io, .{});
    defer server.deinit(io);
    var accept_future = try io.concurrent(acceptOneTestConnection, .{ &server, io });
    defer _ = accept_future.cancel(io) catch {};

    var context: FastPreferredResolutionContext = .{};
    const host = try HostName.init("fast-preferred.test");
    const started = Io.Timestamp.now(io, .awake);
    var stream = try connectHostWithBackends(host, io, server.socket.address.getPort(), .prefer_ipv4, .{
        .mode = .stream,
        .timeout = .{ .duration = .{
            .raw = Io.Duration.fromSeconds(1),
            .clock = .awake,
        } },
    }, .{}, .{
        .context = &context,
        .resolveFn = resolveFastPreferredIpv4,
    });
    const elapsed = started.durationTo(Io.Timestamp.now(io, .awake));
    stream.close(io);
    try accept_future.await(io);

    try testing.expect(elapsed.nanoseconds < Io.Duration.fromMilliseconds(500).nanoseconds);
    try testing.expectEqual(@as(u32, 1), context.ip4_started.load(.acquire));
    try testing.expectEqual(@as(u32, 0), context.ip6_started.load(.acquire));
}

test "Happy Eyeballs starts alternate DNS after the resolution delay" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listen_address = try IpAddress.parse("127.0.0.1", 0);
    var server = try listen_address.listen(io, .{});
    defer server.deinit(io);
    var accept_future = io.async(acceptOneTestConnection, .{ &server, io });
    defer accept_future.cancel(io) catch {};

    var context: DelayedAlternateResolutionContext = .{};
    const host = try HostName.init("delayed-alternate.test");
    var stream = try connectHostWithBackends(host, io, server.socket.address.getPort(), .happy_eyeballs, .{
        .mode = .stream,
        .timeout = .{ .duration = .{
            .raw = Io.Duration.fromSeconds(1),
            .clock = .awake,
        } },
    }, .{}, .{
        .context = &context,
        .resolveFn = resolveAfterStalledIpv6,
    });
    stream.close(io);
    try accept_future.await(io);

    const ip6_started_ms = context.ip6_started_ms.load(.acquire);
    const ip4_started_ms = context.ip4_started_ms.load(.acquire);
    try testing.expect(ip6_started_ms >= 0);
    try testing.expect(ip4_started_ms >= 0);
    const lookup_delay_ms = ip4_started_ms - ip6_started_ms;
    try testing.expect(lookup_delay_ms >= 40);
    try testing.expect(lookup_delay_ms < 500);
    try testing.expect(context.ip6_canceled.load(.acquire));
}

test "Happy Eyeballs starts alternate DNS immediately when the preferred family is exhausted" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var event_buffer: [happy_eyeballs_event_capacity]HappyEyeballsEvent = undefined;
    var events: EventQueue = .init(&event_buffer);
    var state: HappyEyeballsState = .initWithBackends(io, &events, .happy_eyeballs, .{
        .mode = .stream,
    }, .{}, .{
        .resolveFn = pendingTestResolution,
    });
    defer state.deinit();

    state.lookup_ip6_done = true;
    const host = try HostName.init("preferred-exhausted.test");
    try state.maybeStartAlternateLookup(host, 443);
    try testing.expect(state.lookup_ip4_future != null);
}

test "Happy Eyeballs reaches an IPv4 localhost server through the configured resolver" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listen_address = try IpAddress.parse("127.0.0.1", 0);
    var server = try listen_address.listen(io, .{});
    defer server.deinit(io);

    var accept_future = io.async(acceptOneTestConnection, .{ &server, io });
    defer accept_future.cancel(io) catch {};

    const host = try HostName.init("localhost");
    var stream = try connectHost(host, io, server.socket.address.getPort(), .happy_eyeballs, .{
        .mode = .stream,
        .timeout = .{ .duration = .{
            .raw = Io.Duration.fromSeconds(1),
            .clock = .awake,
        } },
    });
    stream.close(io);
    try accept_future.await(io);
}

test "Happy Eyeballs starts IPv4 after 200 ms when IPv6 blackholes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listen_address = try IpAddress.parse("127.0.0.1", 0);
    var server = try listen_address.listen(io, .{});
    defer server.deinit(io);

    var accept_future = io.async(acceptOneTestConnection, .{ &server, io });
    defer accept_future.cancel(io) catch {};

    var context: BlackholeTestContext = .{};
    const host = try HostName.init("localhost");
    var stream = try connectHostWithBackend(host, io, server.socket.address.getPort(), .happy_eyeballs, .{
        .mode = .stream,
        .timeout = .{ .duration = .{
            .raw = Io.Duration.fromSeconds(1),
            .clock = .awake,
        } },
    }, .{
        .context = &context,
        .connectFn = blackholeIp6TestConnect,
    });
    stream.close(io);
    try accept_future.await(io);

    const ip6_started_ms = context.ip6_started_ms.load(.acquire);
    const ip4_started_ms = context.ip4_started_ms.load(.acquire);
    try testing.expect(ip6_started_ms >= 0);
    try testing.expect(ip4_started_ms >= 0);
    const fallback_delay_ms = ip4_started_ms - ip6_started_ms;
    try testing.expect(fallback_delay_ms >= 150);
    try testing.expect(fallback_delay_ms < 900);
    try testing.expect(context.ip6_canceled.load(.acquire));
}

test "resolved addresses remain partitioned by family" {
    var resolved: ResolvedAddresses = .{};
    resolved.append(try IpAddress.parse("127.0.0.1", 80));
    resolved.append(try IpAddress.parse("::1", 80));

    try testing.expectEqual(@as(usize, 1), resolved.ip4.len);
    try testing.expectEqual(@as(usize, 1), resolved.ip6.len);
    try testing.expect(resolved.ip4Slice()[0] == .ip4);
    try testing.expect(resolved.ip6Slice()[0] == .ip6);
}

const HeadRedirectTestServer = struct {
    io: Io,
    server: *Io.net.Server,
    responses: []const []const u8,

    fn serve(self: HeadRedirectTestServer) !void {
        for (self.responses) |response| {
            var stream = try self.server.accept(self.io);
            defer stream.close(self.io);
            var read_buffer: [2048]u8 = undefined;
            var reader = stream.reader(self.io, &read_buffer);
            const line = (try reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;
            try testing.expect(std.mem.startsWith(u8, line, "HEAD /"));
            try consumeTestRequestHead(&reader.interface);
            var write_buffer: [1024]u8 = undefined;
            var writer = stream.writer(self.io, &write_buffer);
            try writer.interface.writeAll(response);
            try writer.interface.flush();
        }
    }
};

fn testHeadRedirects(behavior: Request.RedirectBehavior, responses: []const []const u8, expected_status: ?http.Status) !void {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var address: IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var future = try io.concurrent(HeadRedirectTestServer.serve, .{HeadRedirectTestServer{
        .io = io,
        .server = &server,
        .responses = responses,
    }});
    defer _ = future.cancel(io) catch {};
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/source", .{server.socket.address.getPort()});
    defer testing.allocator.free(url);
    var client: Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    var req = try client.request(.HEAD, try Uri.parse(url), .{ .redirect_behavior = behavior });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buffer: [4096]u8 = undefined;
    if (expected_status) |status| {
        const response = try req.receiveHead(&redirect_buffer);
        try testing.expectEqual(status, response.head.status);
        try testing.expectEqual(@as(?u64, 12345), response.head.content_length);
        try testing.expectEqual(@as(?u64, 0), req.response_content_length);
        if (status == .ok) {
            var headers = response.head.iterateHeaders();
            var found_etag = false;
            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "etag")) {
                    try testing.expectEqualStrings("\"new-release\"", header.value);
                    found_etag = true;
                }
            }
            try testing.expect(found_etag);
        }
    } else {
        try testing.expectError(error.TooManyHttpRedirects, req.receiveHead(&redirect_buffer));
    }
    try future.await(io);
}

const head_redirect_response = "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 12345\r\nConnection: close\r\n\r\n";

test "HEAD follows redirect chains without reading bodies and preserves HEAD for 303" {
    try testHeadRedirects(.init(5), &.{
        "HTTP/1.1 301 Moved Permanently\r\nLocation: /first\r\nContent-Length: 12345\r\nConnection: close\r\n\r\n",
        head_redirect_response,
        "HTTP/1.1 303 See Other\r\nLocation: /third\r\nContent-Length: 12345\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 307 Temporary Redirect\r\nLocation: /fourth\r\nContent-Length: 12345\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 308 Permanent Redirect\r\nLocation: /final\r\nContent-Length: 12345\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 12345\r\nETag: \"new-release\"\r\nConnection: close\r\n\r\n",
    }, .ok);
}

test "HEAD leaves redirects unhandled when requested" {
    try testHeadRedirects(.unhandled, &.{head_redirect_response}, .found);
}

test "HEAD enforces redirect limit without reading a nonexistent body" {
    try testHeadRedirects(.init(1), &.{ head_redirect_response, head_redirect_response }, null);
}

test "HEAD returns 304 without treating it as a redirect" {
    try testHeadRedirects(.init(1), &.{"HTTP/1.1 304 Not Modified\r\nContent-Length: 12345\r\nConnection: close\r\n\r\n"}, .not_modified);
}
