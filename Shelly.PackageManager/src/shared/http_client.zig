const std = @import("std");
const http = std.http;

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    io: std.Io,
    user_agent: ?[:0]const u8,
    timeout_seconds: u32,
    verify_ssl: bool = false,

    pub fn init(self: *HttpClient, allocator: std.mem.Allocator, userAgent: ?[:0]const u8, timeout_seconds: u32, verify_ssl: bool) !void {
        self.client = http.Client{ .allocator = allocator };
        self.io = self.client.io;
        self.user_agent = userAgent;
        self.timeout_seconds = timeout_seconds;
        self.verify_ssl = verify_ssl;
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    pub fn get(self: *HttpClient, url: []const u8, progress_callback: ?ProgressCallback) DownloadResponse {
        const user_agent = self.user_agent;
        var headers = [_]std.http.Header{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "User-Agent", .value = user_agent },
        };
        const options = .{ .arena = self.allocator, .uri = std.Uri.parse(url), .method = http.Method.GET, .headers = &headers };
        const request = self.client.fetch(options);
        defer request.deinit();

        var response_buffer: []u8 = undefined;
        const response = try request.start();
        defer response.deinit();

        //const status = response.status;
        _ = progress_callback;
        _ = try response.readAll(&response_buffer, self.allocator);
    }
};

pub const ProgressCallback = *const fn (bytes_downloaded: u64, bytes_total: ?u64) void;

pub const DownloadResponse = struct {
    status_code: u16,
    content_length: ?u64,
    content_type: ?[:0]const u8,
    body: []u8, // Owned by caller
    deinit: *const fn (self: *DownloadResponse) void,
};
