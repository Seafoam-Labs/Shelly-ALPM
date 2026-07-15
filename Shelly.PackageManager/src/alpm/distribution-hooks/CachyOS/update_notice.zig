const std = @import("std");
const bindings = @import("../../bindings.zig");
const events = @import("../../events.zig");
const xdg_paths = @import("../../../shared/xdg_paths.zig").xdg_paths;

const notice_url = "https://iso-stats.cachyos.org/api/v2/last_update_notice";
const no_notice = "No notice found";
const notice_file_name = "CACHY_UPDATE_NOTICE";
const cache_directory_name = "shelly";
const max_notice_size = 1024 * 1024;

const NoticeDto = struct {
    id: []const u8,
    body: []const u8,
};

pub const UpdateNotice = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) UpdateNotice {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    /// Checks for a CachyOS update notice and asks the user whether the update
    /// should proceed. Notice-service and state-file failures are best-effort
    /// and therefore do not prevent an update. Accepted notice IDs are stored
    /// under `$XDG_CACHE_HOME/shelly` (or `$HOME/.cache/shelly`).
    pub fn check(
        self: UpdateNotice,
        environ: std.process.Environ,
        dispatcher: *events.Dispatcher,
    ) bool {
        const payload = self.fetchNotice() catch return true;
        defer self.allocator.free(payload);

        return self.handlePayload(environ, dispatcher, payload);
    }

    fn fetchNotice(self: UpdateNotice) ![]u8 {
        var client: std.http.Client = .{
            .allocator = self.allocator,
            .io = self.io,
        };
        defer client.deinit();

        const uri = try std.Uri.parse(notice_url);
        var request = try client.request(.GET, uri, .{
            .headers = .{
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
        if (response.head.status.class() != .success) return error.HttpStatus;

        var transfer_buffer: [4 * 1024]u8 = undefined;
        return response.reader(&transfer_buffer).allocRemaining(self.allocator, .limited(max_notice_size));
    }

    fn handlePayload(
        self: UpdateNotice,
        environ: std.process.Environ,
        dispatcher: *events.Dispatcher,
        raw_payload: []const u8,
    ) bool {
        const cache_home = xdg_paths.xdgCacheHome(self.allocator, environ) catch return true;
        defer self.allocator.free(cache_home);

        return self.handlePayloadAtCacheHome(cache_home, dispatcher, raw_payload);
    }

    fn handlePayloadAtCacheHome(
        self: UpdateNotice,
        cache_home: []const u8,
        dispatcher: *events.Dispatcher,
        raw_payload: []const u8,
    ) bool {
        const payload = std.mem.trim(u8, raw_payload, " \t\r\n");
        if (payload.len == 0 or std.mem.eql(u8, payload, no_notice)) return true;

        const parsed = std.json.parseFromSlice(NoticeDto, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch return true;
        defer parsed.deinit();

        const notice = parsed.value;
        if (std.mem.trim(u8, notice.body, " \t\r\n").len == 0) return true;

        const state_path = std.fs.path.join(self.allocator, &.{ cache_home, cache_directory_name, notice_file_name }) catch return true;
        defer self.allocator.free(state_path);

        if (std.Io.Dir.cwd().readFileAlloc(self.io, state_path, self.allocator, .limited(max_notice_size))) |saved_id| {
            defer self.allocator.free(saved_id);
            if (std.mem.eql(u8, std.mem.trim(u8, saved_id, " \t\r\n"), notice.id)) return true;
        } else |_| {}

        const yes_no = [_][]const u8{ "yes", "no" };
        const response = dispatcher.raiseQuestion(self.io, .{
            .question = notice.body,
            .question_type = @intFromEnum(bindings.libalpm.QuestionType.update_notice),
            .options = &yes_no,
        });
        if (response.answer != 1) return false;

        self.saveNoticeId(state_path, notice.id);
        return true;
    }

    fn saveNoticeId(self: UpdateNotice, state_path: []const u8, id: []const u8) void {
        const parent = std.fs.path.dirname(state_path) orelse return;
        std.Io.Dir.cwd().createDirPath(self.io, parent) catch return;

        var file = std.Io.Dir.cwd().createFile(self.io, state_path, .{}) catch return;
        defer file.close(self.io);
        file.writeStreamingAll(self.io, id) catch {};
    }
};

const testing = std.testing;

const QuestionCapture = struct {
    dispatcher: *events.Dispatcher,
    io: std.Io,
    answer: c_int,
    calls: usize = 0,
    question_type: c_int = 0,
    question_buffer: [128]u8 = undefined,
    question_len: usize = 0,

    fn question(self: *const QuestionCapture) []const u8 {
        return self.question_buffer[0..self.question_len];
    }

    fn respond(data: ?*anyopaque, args: events.QuestionArgs) void {
        const self: *QuestionCapture = @ptrCast(@alignCast(data.?));
        self.calls += 1;
        self.question_type = args.question_type;
        const text = args.question orelse "";
        self.question_len = @min(text.len, self.question_buffer.len);
        @memcpy(self.question_buffer[0..self.question_len], text[0..self.question_len]);
        self.dispatcher.respond(self.io, .{ .answer = self.answer });
    }
};

fn temporaryPath(tmp: *testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(testing.io, buffer);
    return buffer[0..len];
}

test "handlePayload accepts a notice and remembers its id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cache_home = try temporaryPath(&tmp, &path_buffer);

    var dispatcher = events.Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    var capture = QuestionCapture{
        .dispatcher = &dispatcher,
        .io = testing.io,
        .answer = 1,
    };
    _ = try dispatcher.addQuestionHandler(.{ .function = QuestionCapture.respond, .data = &capture });

    const hook = UpdateNotice.init(testing.allocator, testing.io);
    try testing.expect(hook.handlePayloadAtCacheHome(cache_home, &dispatcher, "{\"id\":\"notice-1\",\"body\":\"Important update\"}"));
    try testing.expectEqual(@as(usize, 1), capture.calls);
    try testing.expectEqual(@as(c_int, @intFromEnum(bindings.libalpm.QuestionType.update_notice)), capture.question_type);
    try testing.expectEqualStrings("Important update", capture.question());

    const state_path = try std.fs.path.join(testing.allocator, &.{ cache_home, cache_directory_name, notice_file_name });
    defer testing.allocator.free(state_path);
    const saved_id = try std.Io.Dir.cwd().readFileAlloc(testing.io, state_path, testing.allocator, .unlimited);
    defer testing.allocator.free(saved_id);
    try testing.expectEqualStrings("notice-1", saved_id);

    try testing.expect(hook.handlePayloadAtCacheHome(cache_home, &dispatcher, "{\"id\":\"notice-1\",\"body\":\"Important update\"}"));
    try testing.expectEqual(@as(usize, 1), capture.calls);
}

test "handlePayload rejects a notice without remembering it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cache_home = try temporaryPath(&tmp, &path_buffer);

    var dispatcher = events.Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    var capture = QuestionCapture{
        .dispatcher = &dispatcher,
        .io = testing.io,
        .answer = 0,
    };
    _ = try dispatcher.addQuestionHandler(.{ .function = QuestionCapture.respond, .data = &capture });

    const hook = UpdateNotice.init(testing.allocator, testing.io);
    try testing.expect(!hook.handlePayloadAtCacheHome(cache_home, &dispatcher, "{\"id\":\"notice-2\",\"body\":\"Read me\"}"));

    const state_path = try std.fs.path.join(testing.allocator, &.{ cache_home, cache_directory_name, notice_file_name });
    defer testing.allocator.free(state_path);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, state_path, .{}));
}

test "handlePayload ignores absent empty and malformed notices" {
    var dispatcher = events.Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    const hook = UpdateNotice.init(testing.allocator, testing.io);

    try testing.expect(hook.handlePayloadAtCacheHome("unused", &dispatcher, ""));
    try testing.expect(hook.handlePayloadAtCacheHome("unused", &dispatcher, "  No notice found\n"));
    try testing.expect(hook.handlePayloadAtCacheHome("unused", &dispatcher, "not json"));
    try testing.expect(hook.handlePayloadAtCacheHome("unused", &dispatcher, "{\"id\":\"notice-3\",\"body\":\"  \"}"));
}
