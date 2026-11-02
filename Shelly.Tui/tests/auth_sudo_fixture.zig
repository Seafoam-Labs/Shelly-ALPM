const std = @import("std");

fn frame(alloc: std.mem.Allocator, writer: *std.Io.Writer, json: []const u8) !void {
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(json.len));
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, json);
    try writer.print("[JSON]{s}[/JSON]\n", .{encoded});
    try writer.flush();
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    // Reject the old validation/cache flow; each operation gets one invocation.
    if (args.len < 3 or !std.mem.eql(u8, args[1], "-A")) return error.ExpectedSingleAskpassInvocation;
    const mode = init.environ_map.get("SHELLY_FIXTURE_AUTH") orelse return error.MissingFixtureMode;
    if (!std.mem.eql(u8, mode, "cached")) {
        const helper = init.environ_map.get("SHELLY_FIXTURE_HELPER") orelse return error.MissingFixtureHelper;
        const response = try std.process.run(alloc, init.io, .{ .argv = &.{ helper, "Fixture password:" }, .environ_map = init.environ_map });
        defer alloc.free(response.stdout);
        defer alloc.free(response.stderr);
        if (response.term != .exited or response.term.exited != 0 or !std.mem.eql(u8, response.stdout, "fixture-secret\n")) {
            // A wrong-password retry must not retrieve the credential again.
            const retry = try std.process.run(alloc, init.io, .{ .argv = &.{ helper, "Retry:" }, .environ_map = init.environ_map });
            if (retry.term != .exited or retry.term.exited == 0 or retry.stdout.len != 0) return error.RetryLeakedCredential;
            std.process.exit(1);
        }
    }
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    var input_buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().reader(init.io, &input_buffer);
    for ([_][]const u8{ "1", "2" }) |id| {
        const question = try std.fmt.allocPrint(alloc, "{{\"$kind\":\"q.yesno\",\"QuestionId\":\"{s}\",\"QuestionKind\":\"fixture\",\"QuestionText\":\"Continue?\"}}", .{id});
        try frame(alloc, &output.interface, question);
        const line = try input.interface.takeDelimiterInclusive('\n');
        const answer = std.mem.trimEnd(u8, line, "\n");
        // A password accidentally sent to stdin will fail this framing check.
        if (!std.mem.startsWith(u8, answer, "[JSON]") or !std.mem.endsWith(u8, answer, "[/JSON]")) return error.CredentialsReachedStdin;
        const payload = answer[6 .. answer.len - 7];
        const json = try alloc.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(payload));
        try std.base64.standard.Decoder.decode(json, payload);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        const answer_id = parsed.value.object.get("QuestionId") orelse return error.MissingAnswerId;
        if (answer_id != .string or !std.mem.eql(u8, answer_id.string, id)) return error.WrongAnswerId;
    }
    try frame(alloc, &output.interface, "{\"$kind\":\"alpm.info\",\"EventType\":\"TransactionDone\",\"Message\":\"Fixture completed\"}");
}
