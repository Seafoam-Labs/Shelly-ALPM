//! Zig adapter for protocols/proxies outside Shelly.Http's supported set.
//! libcurl supplies protocol implementations; ownership and file I/O stay here.
const std = @import("std");
const c = @cImport({
    @cInclude("curl/curl.h");
});

pub const Error = error{ NetworkError, FileError, NotModified, NotFound, Cancelled, SizeExceeded, Timeout, InvalidUrl, SslError, HostNotFound };
pub const Options = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    url: [:0]const u8,
    path: [:0]const u8,
    timeout: u32,
    maximum: ?u64,
    resumable: bool,
    verify_ssl: bool,
    mtime: i64,
    cancelled: *const fn (?*anyopaque) callconv(.c) c_int,
    progress: *const fn (?*anyopaque, u64, u64) callconv(.c) void,
    context: ?*anyopaque,
    effective_url: *?[]u8,
};

const Transfer = struct {
    options: *const Options,
    file: std.Io.File,
    size: u64,
    initial: u64,
    failure: ?Error = null,

    fn write(data: [*c]u8, size: usize, count: usize, ctx: ?*anyopaque) callconv(.c) usize {
        const self: *Transfer = @ptrCast(@alignCast(ctx.?));
        const length = std.math.mul(usize, size, count) catch {
            self.failure = error.SizeExceeded;
            return 0;
        };
        if (self.options.maximum) |maximum| if (self.size > maximum or length > maximum - self.size) {
            self.failure = error.SizeExceeded;
            return 0;
        };
        self.file.writePositionalAll(self.options.io, data[0..length], self.size) catch {
            self.failure = error.FileError;
            return 0;
        };
        self.size = std.math.add(u64, self.size, length) catch {
            self.failure = error.SizeExceeded;
            return 0;
        };
        return length;
    }

    fn progress(ctx: ?*anyopaque, total: c.curl_off_t, now: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
        const self: *Transfer = @ptrCast(@alignCast(ctx.?));
        if (self.options.cancelled(self.options.context) != 0) return 1;
        self.options.progress(self.options.context, self.initial +| @as(u64, @intCast(@max(0, now))), if (total > 0) self.initial +| @as(u64, @intCast(total)) else 0);
        return 0;
    }
};

fn set(handle: *c.CURL, option: c.CURLoption, value: anytype) Error!void {
    if (c.curl_easy_setopt(handle, option, value) != c.CURLE_OK) return error.NetworkError;
}

pub fn download(options: Options) Error!void {
    const handle = c.curl_easy_init() orelse return error.NetworkError;
    defer c.curl_easy_cleanup(handle);
    const fd = std.c.open(options.path, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true, .EXCL = !options.resumable }, @as(std.c.mode_t, 0o666));
    if (fd < 0) return error.FileError;
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(options.io);
    const stat = file.stat(options.io) catch return error.FileError;
    if (stat.kind != .file) return error.FileError;
    var initial = if (options.resumable) stat.size else 0;
    if (options.maximum) |maximum| if (initial >= maximum) {
        file.setLength(options.io, 0) catch return error.FileError;
        initial = 0;
    };
    var transfer: Transfer = .{ .options = &options, .file = file, .size = initial, .initial = initial };
    try set(handle, c.CURLOPT_URL, options.url.ptr);
    try set(handle, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, if (options.verify_ssl) 1 else 0));
    try set(handle, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, if (options.verify_ssl) 2 else 0));
    try set(handle, c.CURLOPT_FILETIME, @as(c_long, 1));
    if (initial != 0) {
        try set(handle, c.CURLOPT_RESUME_FROM_LARGE, std.math.cast(c.curl_off_t, initial) orelse return error.SizeExceeded);
    } else if (options.mtime >= 0) {
        try set(handle, c.CURLOPT_TIMECONDITION, @as(c_long, c.CURL_TIMECOND_IFMODSINCE));
        try set(handle, c.CURLOPT_TIMEVALUE_LARGE, @as(c.curl_off_t, options.mtime));
    }
    try set(handle, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
    try set(handle, c.CURLOPT_FAILONERROR, @as(c_long, 1));
    try set(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    try set(handle, c.CURLOPT_MAXREDIRS, @as(c_long, 10));
    try set(handle, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, options.timeout));
    try set(handle, c.CURLOPT_LOW_SPEED_LIMIT, @as(c_long, if (options.timeout != 0) 1 else 0));
    try set(handle, c.CURLOPT_LOW_SPEED_TIME, @as(c_long, options.timeout));
    try set(handle, c.CURLOPT_WRITEFUNCTION, &Transfer.write);
    try set(handle, c.CURLOPT_WRITEDATA, &transfer);
    try set(handle, c.CURLOPT_XFERINFOFUNCTION, &Transfer.progress);
    try set(handle, c.CURLOPT_XFERINFODATA, &transfer);
    try set(handle, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
    var code = c.curl_easy_perform(handle);
    if (initial != 0 and (code == c.CURLE_RANGE_ERROR or code == c.CURLE_BAD_DOWNLOAD_RESUME)) {
        file.setLength(options.io, 0) catch return error.FileError;
        transfer.size = 0;
        transfer.initial = 0;
        transfer.failure = null;
        try set(handle, c.CURLOPT_RESUME_FROM_LARGE, @as(c.curl_off_t, 0));
        code = c.curl_easy_perform(handle);
    }
    var status: c_long = 0;
    var condition_unmet: c_long = 0;
    var modified: c.curl_off_t = -1;
    var effective: [*c]const u8 = null;
    if (c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status) != c.CURLE_OK or
        c.curl_easy_getinfo(handle, c.CURLINFO_CONDITION_UNMET, &condition_unmet) != c.CURLE_OK or
        c.curl_easy_getinfo(handle, c.CURLINFO_FILETIME_T, &modified) != c.CURLE_OK or
        c.curl_easy_getinfo(handle, c.CURLINFO_EFFECTIVE_URL, &effective) != c.CURLE_OK) return error.NetworkError;
    if (effective != null) {
        const owned = options.allocator.dupe(u8, std.mem.span(effective)) catch return error.FileError;
        if (options.effective_url.*) |previous| options.allocator.free(previous);
        options.effective_url.* = owned;
    }
    if (transfer.failure) |failure| return failure;
    if (code == c.CURLE_OK and (status == 304 or condition_unmet != 0)) return error.NotModified;
    switch (code) {
        c.CURLE_OK => {},
        c.CURLE_COULDNT_RESOLVE_HOST => return error.HostNotFound,
        c.CURLE_ABORTED_BY_CALLBACK => return error.Cancelled,
        c.CURLE_OPERATION_TIMEDOUT => return error.Timeout,
        c.CURLE_REMOTE_FILE_NOT_FOUND => return error.NotFound,
        c.CURLE_UNSUPPORTED_PROTOCOL, c.CURLE_URL_MALFORMAT => return error.InvalidUrl,
        c.CURLE_PEER_FAILED_VERIFICATION, c.CURLE_SSL_CONNECT_ERROR => return error.SslError,
        else => return if (status == 404) error.NotFound else error.NetworkError,
    }
    if (modified >= 0) file.setTimestamps(options.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, modified) * std.time.ns_per_s } } }) catch return error.FileError;
    file.sync(options.io) catch return error.FileError;
}

pub fn supportsProtocol(protocol: []const u8) bool {
    const info = c.curl_version_info(c.CURLVERSION_NOW);
    if (info == null) return false;
    var index: usize = 0;
    while (info.*.protocols[index] != null) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(protocol, std.mem.span(info.*.protocols[index]))) return true;
    }
    return false;
}
