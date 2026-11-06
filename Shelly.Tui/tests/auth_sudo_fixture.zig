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
    // Every elevated operation must use a private terminal, never an askpass helper.
    const mode = init.environ_map.get("SHELLY_FIXTURE_AUTH") orelse return error.MissingFixtureMode;
    if (init.environ_map.get("SHELLY_FIXTURE_EXPECT_SESSION")) |expected| {
        if (std.os.linux.getsid(0) != try std.fmt.parseInt(usize, expected, 10)) return error.AuthorizationSessionChanged;
    }
    if (init.environ_map.get("SUDO_ASKPASS") != null or init.environ_map.get("SHELLY_TUI_ASKPASS_SOCKET") != null) return error.UnexpectedAuthenticationHelper;
    const password_mode = std.mem.eql(u8, mode, "terminal") or std.mem.eql(u8, mode, "wrong");
    if (!password_mode and !std.mem.eql(u8, mode, "fingerprint") and !std.mem.eql(u8, mode, "cached")) return error.UnknownFixtureMode;
    {
        if (args.len < 2 or !std.mem.eql(u8, args[1], "fixture-cli")) return error.ExpectedDirectSudoInvocation;
        const tty = try std.Io.Dir.cwd().openFile(init.io, "/dev/tty", .{ .mode = .read_write });
        defer tty.close(init.io);
        var tty_output_buffer: [256]u8 = undefined;
        var tty_output = tty.writer(init.io, &tty_output_buffer);
        if (!std.mem.eql(u8, mode, "cached")) try tty_output.interface.writeAll("Fingerprint: touch the sensor.\n");
        try tty_output.interface.flush();
        if (password_mode) {
            var stderr_buffer: [128]u8 = undefined;
            var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
            try stderr.interface.writeAll("PAM message on stderr\n");
            try stderr.interface.flush();
            var tty_input_buffer: [128]u8 = undefined;
            defer std.crypto.secureZero(u8, &tty_input_buffer);
            var tty_input = tty.reader(init.io, &tty_input_buffer);
            for (0..2) |attempt| {
                try tty_output.interface.writeAll(if (attempt == 0) "Password: " else "Try again. Password: ");
                try tty_output.interface.flush();
                const password = try tty_input.interface.takeDelimiterInclusive('\n');
                if (std.mem.eql(u8, password, "fixture-secret\n")) break;
                if (attempt == 1) return error.IncorrectPassword;
            }
        }
    }
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    var input_buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().reader(init.io, &input_buffer);
    for ([_][]const u8{ "1", "2" }) |id| {
        const question = if (std.mem.eql(u8, id, "2"))
            "{\"$kind\":\"q.pkgbuilddiff\",\"QuestionId\":\"2\",\"PackageName\":\"fixture\",\"OldPkgbuild\":\"\",\"NewPkgbuild\":\"pkgname=fixture\",\"Warnings\":[]}"
        else
            try std.fmt.allocPrint(alloc, "{{\"$kind\":\"q.yesno\",\"QuestionId\":\"{s}\",\"QuestionKind\":\"fixture\",\"QuestionText\":\"Continue?\"}}", .{id});
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
