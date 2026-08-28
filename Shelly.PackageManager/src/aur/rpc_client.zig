const std = @import("std");
const models = @import("models.zig");
const endpoints = @import("endpoints.zig");
const operation_api = @import("operation_context");
const HttpClient = @import("ShellyHttp");

pub const default_rpc_url = endpoints.official_rpc_url;
pub const default_cgit_url = "https://aur.archlinux.org/cgit/aur.git/plain";
const max_response_size = 32 * 1024 * 1024;
const connect_timeout_seconds = 15;

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    http: HttpClient,
    rpc_url: []const u8,
    cgit_url: []const u8 = default_cgit_url,
    operation_context: ?*operation_api.OperationContext = null,
    parent_operation: ?*const operation_api.Operation = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, rpc_url: []const u8) !Client {
        return .{
            .allocator = allocator,
            .io = io,
            .rpc_url = try allocator.dupe(u8, rpc_url),
            .http = .{
                .allocator = allocator,
                .io = io,
                .connect_timeout = .{ .duration = .{
                    .raw = std.Io.Duration.fromSeconds(connect_timeout_seconds),
                    .clock = .awake,
                } },
            },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
        self.allocator.free(self.rpc_url);
        self.* = undefined;
    }

    pub fn setOperationContext(self: *Client, context: ?*operation_api.OperationContext) void {
        self.operation_context = context;
    }

    pub fn setParentOperation(self: *Client, operation: ?*const operation_api.Operation) void {
        self.parent_operation = operation;
        if (operation) |parent| self.operation_context = parent.context;
    }

    pub fn search(self: *Client, query: []const u8) !models.Response {
        const url = try buildSearchUrl(self.allocator, self.rpc_url, query, "name-desc");
        defer self.allocator.free(url);
        const payload = try self.get(url);
        defer self.allocator.free(payload);
        return models.Response.parse(self.allocator, payload);
    }

    pub fn suggest(self: *Client, query: []const u8) ![][]u8 {
        return self.suggestType("suggest", query);
    }

    pub fn suggestPackageBases(self: *Client, query: []const u8) ![][]u8 {
        return self.suggestType("suggest-pkgbase", query);
    }

    fn suggestType(self: *Client, request_type: []const u8, query: []const u8) ![][]u8 {
        const encoded = try percentEncode(self.allocator, query);
        defer self.allocator.free(encoded);
        const url = try std.fmt.allocPrint(self.allocator, "{s}?v=5&type={s}&arg={s}", .{ self.rpc_url, request_type, encoded });
        defer self.allocator.free(url);
        const payload = try self.get(url);
        defer self.allocator.free(payload);
        return parseSuggestions(self.allocator, payload);
    }

    pub fn getInfo(self: *Client, package_names: []const []const u8) !models.Response {
        if (package_names.len == 0) return emptyResponse(self.allocator, "info");

        var all_packages: std.ArrayList(models.Package) = .empty;
        errdefer {
            for (all_packages.items) |*package| package.deinit(self.allocator);
            all_packages.deinit(self.allocator);
        }
        var response_type = try self.allocator.dupe(u8, "info");
        errdefer self.allocator.free(response_type);

        var offset: usize = 0;
        while (offset < package_names.len) : (offset += 100) {
            const end = @min(offset + 100, package_names.len);
            const body = try buildInfoFormBody(self.allocator, package_names[offset..end]);
            defer self.allocator.free(body);
            const payload = self.postForm(self.rpc_url, body) catch |err|
                return self.partialInfoError(&all_packages, response_type, err);
            defer self.allocator.free(payload);
            var response = models.Response.parse(self.allocator, payload) catch |err|
                return self.partialInfoError(&all_packages, response_type, err);

            if (std.mem.eql(u8, response.response_type, "error")) {
                for (all_packages.items) |*package| package.deinit(self.allocator);
                all_packages.deinit(self.allocator);
                self.allocator.free(response_type);
                return response;
            }

            all_packages.appendSlice(self.allocator, response.results) catch |err| {
                response.deinit(self.allocator);
                return err;
            };
            self.allocator.free(response.results);
            self.allocator.free(response_type);
            response_type = response.response_type;
            if (response.error_message) |message| self.allocator.free(message);
        }

        return .{
            .version = 5,
            .response_type = response_type,
            .result_count = all_packages.items.len,
            .results = try all_packages.toOwnedSlice(self.allocator),
        };
    }

    fn partialInfoError(
        self: *Client,
        all_packages: *std.ArrayList(models.Package),
        response_type: []u8,
        err: anyerror,
    ) !models.Response {
        const error_type = try self.allocator.dupe(u8, "error");
        errdefer self.allocator.free(error_type);
        const message = try self.allocator.dupe(u8, @errorName(err));
        errdefer self.allocator.free(message);
        const results = try all_packages.toOwnedSlice(self.allocator);
        self.allocator.free(response_type);
        return .{
            .version = 5,
            .response_type = error_type,
            .result_count = results.len,
            .results = results,
            .error_message = message,
        };
    }

    pub fn getPackageBase(self: *Client, package_name: []const u8) ![]u8 {
        if (std.mem.trim(u8, package_name, " \t\r\n").len == 0)
            return self.allocator.dupe(u8, package_name);
        var response = self.getInfo(&.{package_name}) catch
            return self.allocator.dupe(u8, package_name);
        defer response.deinit(self.allocator);
        if (response.results.len > 0 and response.results[0].package_base.len != 0)
            return self.allocator.dupe(u8, response.results[0].package_base);
        return self.allocator.dupe(u8, package_name);
    }

    pub fn findProviders(self: *Client, dependency_name: []const u8) ![][]u8 {
        if (std.mem.trim(u8, dependency_name, " \t\r\n").len == 0)
            return self.allocator.alloc([]u8, 0);

        if (self.getInfo(&.{dependency_name})) |direct_value| {
            var direct = direct_value;
            defer direct.deinit(self.allocator);
            if (direct.results.len > 0 and direct.results[0].name.len != 0) {
                const result = try self.allocator.alloc([]u8, 1);
                errdefer self.allocator.free(result);
                result[0] = try self.allocator.dupe(u8, direct.results[0].name);
                return result;
            }
        } else |_| {}

        const url = try buildSearchUrl(self.allocator, self.rpc_url, dependency_name, "provides");
        defer self.allocator.free(url);
        const payload = self.get(url) catch return self.allocator.alloc([]u8, 0);
        defer self.allocator.free(payload);
        var response = models.Response.parse(self.allocator, payload) catch return self.allocator.alloc([]u8, 0);
        defer response.deinit(self.allocator);

        var names: std.ArrayList([]u8) = .empty;
        errdefer deinitStrings(self.allocator, names.items);
        for (response.results) |package| {
            var duplicate = false;
            for (names.items) |name| {
                if (std.mem.eql(u8, name, package.name)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) try names.append(self.allocator, try self.allocator.dupe(u8, package.name));
        }
        return names.toOwnedSlice(self.allocator);
    }

    pub fn fetchPkgbuild(self: *Client, package_base: []const u8) ![]u8 {
        const encoded = try percentEncode(self.allocator, package_base);
        defer self.allocator.free(encoded);
        const url = try std.fmt.allocPrint(self.allocator, "{s}/PKGBUILD?h={s}", .{ self.cgit_url, encoded });
        defer self.allocator.free(url);
        return self.get(url);
    }

    pub fn fetchSourceFile(self: *Client, package_base: []const u8, file_name: []const u8) ![]u8 {
        const encoded_base = try percentEncode(self.allocator, package_base);
        defer self.allocator.free(encoded_base);
        const encoded_file = try percentEncode(self.allocator, file_name);
        defer self.allocator.free(encoded_file);
        const url = try std.fmt.allocPrint(self.allocator, "{s}/{s}?h={s}", .{ self.cgit_url, encoded_file, encoded_base });
        defer self.allocator.free(url);
        return self.get(url);
    }

    fn get(self: *Client, url: []const u8) ![]u8 {
        var operation_scope = HttpOperationScope.init(self, url);
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try operation_scope.checkCancelled();
        const uri = try std.Uri.parse(url);
        var request = try self.http.request(.GET, uri, .{
            .headers = .{
                .user_agent = .{ .override = "Shelly-ALPM/3" },
                .accept_encoding = .{ .override = "identity" },
            },
            .redirect_behavior = .init(10),
        });
        defer request.deinit();
        request.accept_encoding[@intFromEnum(std.http.ContentEncoding.gzip)] = false;
        request.accept_encoding[@intFromEnum(std.http.ContentEncoding.deflate)] = false;
        try request.sendBodiless();
        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        if (response.head.status.class() != .success) {
            return error.AurHttpStatus;
        }
        var transfer_buffer: [8 * 1024]u8 = undefined;
        return self.readResponse(response.reader(&transfer_buffer), response.head.content_length, &operation_scope);
    }

    fn postForm(self: *Client, url: []const u8, body: []u8) ![]u8 {
        var operation_scope = HttpOperationScope.init(self, url);
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try operation_scope.checkCancelled();
        const uri = try std.Uri.parse(url);
        const headers = [_]std.http.Header{.{
            .name = "content-type",
            .value = "application/x-www-form-urlencoded",
        }};
        var request = try self.http.request(.POST, uri, .{
            .headers = .{
                .user_agent = .{ .override = "Shelly-ALPM/3" },
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = &headers,
            .redirect_behavior = .init(10),
        });
        defer request.deinit();
        request.accept_encoding[@intFromEnum(std.http.ContentEncoding.gzip)] = false;
        request.accept_encoding[@intFromEnum(std.http.ContentEncoding.deflate)] = false;
        try request.sendBodyComplete(body);
        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        if (response.head.status.class() != .success) {
            return error.AurHttpStatus;
        }
        var transfer_buffer: [8 * 1024]u8 = undefined;
        return self.readResponse(response.reader(&transfer_buffer), response.head.content_length, &operation_scope);
    }

    fn readResponse(
        self: *Client,
        reader: *std.Io.Reader,
        total: ?u64,
        operation_scope: *HttpOperationScope,
    ) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);
        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            try operation_scope.checkCancelled();
            const amount = try reader.readSliceShort(&buffer);
            if (amount == 0) break;
            if (result.items.len + amount > max_response_size) return error.StreamTooLong;
            try result.appendSlice(self.allocator, buffer[0..amount]);
            operation_scope.progress(result.items.len, total);
        }
        return result.toOwnedSlice(self.allocator);
    }
};

const HttpOperationScope = struct {
    operation: ?operation_api.Operation = null,

    fn init(client: *Client, subject: []const u8) HttpOperationScope {
        if (client.parent_operation) |parent| return .{ .operation = parent.child(.{
            .backend = .download,
            .kind = .download,
            .subject = subject,
        }) };
        if (client.operation_context) |context| return .{ .operation = context.begin(.{
            .backend = .download,
            .kind = .download,
            .subject = subject,
        }) };
        return .{};
    }

    fn checkCancelled(self: *const HttpOperationScope) error{Cancelled}!void {
        if (self.operation) |*operation| try operation.checkCancelled();
    }

    fn progress(self: *const HttpOperationScope, completed: usize, total: ?u64) void {
        if (self.operation) |*operation| operation.progress(.{
            .stage = "aur-http",
            .completed = @intCast(completed),
            .total = total,
            .percentage = if (total) |value| if (value == 0) 100 else @as(f64, @floatFromInt(completed)) * 100.0 / @as(f64, @floatFromInt(value)) else null,
            .bytes_completed = @intCast(completed),
            .bytes_total = total,
        });
    }

    fn fail(self: *HttpOperationScope) void {
        if (self.operation) |*operation| operation.reportError(
            if (operation.isCancelled()) error.Cancelled else error.AurHttpOperationFailed,
            if (operation.isCancelled()) "AUR HTTP operation cancelled" else "AUR HTTP operation failed",
            "aur-http",
            null,
            false,
        );
        const status: operation_api.CompletionStatus = if (self.operation) |*operation|
            if (operation.isCancelled()) .cancelled else .failed
        else
            .failed;
        self.finish(status);
    }

    fn finish(self: *HttpOperationScope, status: operation_api.CompletionStatus) void {
        if (self.operation) |*operation| operation.finish(status);
    }
};

pub fn buildSearchUrl(allocator: std.mem.Allocator, base_url: []const u8, query: []const u8, by: []const u8) ![]u8 {
    const encoded = try percentEncode(allocator, query);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "{s}?v=5&type=search&arg={s}&by={s}", .{ base_url, encoded, by });
}

pub fn buildInfoFormBody(allocator: std.mem.Allocator, package_names: []const []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("v=5&type=info");
    for (package_names) |name| {
        const encoded = try percentEncode(allocator, name);
        defer allocator.free(encoded);
        try output.writer.print("&arg%5B%5D={s}", .{encoded});
    }
    return output.toOwnedSlice();
}

pub fn percentEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (input) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or char == '~') {
            try output.writer.writeByte(char);
        } else {
            try output.writer.writeAll(&.{ '%', hex[char >> 4], hex[char & 0x0f] });
        }
    }
    return output.toOwnedSlice();
}

pub fn parseSuggestions(allocator: std.mem.Allocator, payload: []const u8) ![][]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidAurResponse;
    var suggestions: std.ArrayList([]u8) = .empty;
    errdefer {
        for (suggestions.items) |suggestion| allocator.free(suggestion);
        suggestions.deinit(allocator);
    }
    for (parsed.value.array.items) |item| {
        if (item != .string) return error.InvalidAurResponse;
        try suggestions.append(allocator, try allocator.dupe(u8, item.string));
    }
    return suggestions.toOwnedSlice(allocator);
}

pub fn deinitStrings(allocator: std.mem.Allocator, strings: []const []u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

fn emptyResponse(allocator: std.mem.Allocator, response_type: []const u8) !models.Response {
    const owned_type = try allocator.dupe(u8, response_type);
    errdefer allocator.free(owned_type);
    return .{
        .response_type = owned_type,
        .results = try allocator.alloc(models.Package, 0),
    };
}

test "AUR RPC URL and form encoding matches the C# requests" {
    const allocator = std.testing.allocator;
    const search_url = try buildSearchUrl(allocator, default_rpc_url, "foo bar+git", "name-desc");
    defer allocator.free(search_url);
    try std.testing.expectEqualStrings(
        "https://aur.archlinux.org/rpc/?v=5&type=search&arg=foo%20bar%2Bgit&by=name-desc",
        search_url,
    );

    const form = try buildInfoFormBody(allocator, &.{ "one", "split package" });
    defer allocator.free(form);
    try std.testing.expectEqualStrings("v=5&type=info&arg%5B%5D=one&arg%5B%5D=split%20package", form);
}

test "AUR suggestions are returned as owned strings" {
    const suggestions = try parseSuggestions(std.testing.allocator, "[\"yay\",\"yay-bin\"]");
    defer deinitStrings(std.testing.allocator, suggestions);
    try std.testing.expectEqual(@as(usize, 2), suggestions.len);
    try std.testing.expectEqualStrings("yay-bin", suggestions[1]);
}

test "RPC client keeps an owned copy of its configured endpoint" {
    const allocator = std.testing.allocator;
    var temporary: [64]u8 = undefined;
    @memcpy(temporary[0.."https://atoll.seafoam-labs.org/rpc".len], "https://atoll.seafoam-labs.org/rpc");
    var client = try Client.init(allocator, std.testing.io, temporary[0.."https://atoll.seafoam-labs.org/rpc".len]);
    defer client.deinit();
    // Releasing or reusing the caller's storage must not affect the client.
    @memset(&temporary, 0);
    try std.testing.expectEqualStrings("https://atoll.seafoam-labs.org/rpc", client.rpc_url);

    var official = try Client.init(allocator, std.testing.io, default_rpc_url);
    defer official.deinit();
    const url = try buildSearchUrl(allocator, official.rpc_url, "demo", "name-desc");
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://aur.archlinux.org/rpc/?v=5&type=search&arg=demo&by=name-desc",
        url,
    );
}

test "partial info failures preserve packages returned by earlier chunks" {
    const allocator = std.testing.allocator;
    const parsed = try models.Response.parse(allocator,
        \\{"version":5,"type":"info","resultcount":1,"results":[
        \\{"Name":"first","PackageBase":"first","Version":"1.0-1"}
        \\]}
    );
    var packages: std.ArrayList(models.Package) = .empty;
    try packages.appendSlice(allocator, parsed.results);
    allocator.free(parsed.results);
    allocator.free(parsed.response_type);
    if (parsed.error_message) |message| allocator.free(message);

    var client = try Client.init(allocator, std.testing.io, default_rpc_url);
    defer client.deinit();
    const response_type = try allocator.dupe(u8, "info");
    var partial = try client.partialInfoError(&packages, response_type, error.Timeout);
    defer partial.deinit(allocator);
    try std.testing.expectEqualStrings("error", partial.response_type);
    try std.testing.expectEqualStrings("Timeout", partial.error_message.?);
    try std.testing.expectEqual(@as(usize, 1), partial.results.len);
    try std.testing.expectEqualStrings("first", partial.results[0].name);
}
