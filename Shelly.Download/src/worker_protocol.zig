pub const Request = struct {
    url: []const u8,
    path: []const u8,
    directory: []const u8,
    user: []const u8,
    filesystem: bool,
    syscalls: bool,
    force: bool,
    timeout: u32,
    maximum: ?u64,
    mtime: ?i128,
    partial: ?[]const u8,
};
pub const Result = enum(u8) { success, unchanged, not_found, cancelled, size, file, timeout, url, tls, network, sandbox, host_not_found };
