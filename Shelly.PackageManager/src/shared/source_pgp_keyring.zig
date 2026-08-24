const std = @import("std");
const operation_api = @import("operation_context");
const source_pgp_verifier = @import("source_pgp_verifier.zig");

/// Command boundary used by AUR orchestration. Imports deliberately go back
/// through the public `shelly keyring recv --user` command instead of writing
/// a GnuPG keyring from package-manager internals.
pub const Backend = struct {
    context: ?*anyopaque,
    contains: *const fn (context: ?*anyopaque, fingerprint: []const u8) anyerror!bool,
    receive: *const fn (context: ?*anyopaque, fingerprint: []const u8) anyerror!bool,
};

pub fn ensurePinnedKeys(
    allocator: std.mem.Allocator,
    operation: *const operation_api.Operation,
    package_name: []const u8,
    fingerprints: []const []const u8,
    backend: Backend,
) !void {
    try source_pgp_verifier.validatePinnedKeys(fingerprints);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (fingerprints) |fingerprint| {
        if (seen.contains(fingerprint)) continue;
        try seen.put(fingerprint, {});
        if (try backend.contains(backend.context, fingerprint)) continue;

        const prompt = try std.fmt.allocPrint(
            allocator,
            "PKGBUILD {s} requires source-signing key {s}. Import it using `shelly keyring recv --user`?",
            .{ package_name, fingerprint },
        );
        defer allocator.free(prompt);
        var answer = try operation.ask(.{
            .kind = .import_pgp_key,
            .prompt = prompt,
            .pgp_key_import = .{
                .package_name = package_name,
                .fingerprint = fingerprint,
            },
            .default_response = .declined,
        });
        defer answer.deinit(allocator);
        if (answer.response != .accepted) return error.PgpKeyImportDeclined;

        const status = try std.fmt.allocPrint(
            allocator,
            "Receiving source-signing key {s} with shelly keyring",
            .{fingerprint},
        );
        defer allocator.free(status);
        operation.status(.information, status, "aur.pgp_key.receive", null);
        if (!(try backend.receive(backend.context, fingerprint)))
            return error.PgpKeyReceiveFailed;
        if (!(try backend.contains(backend.context, fingerprint)))
            return error.MissingPgpKey;
    }
}

test "source PGP key preflight prompts once and imports through backend" {
    const Capture = struct {
        present: bool = false,
        receives: usize = 0,
        questions: usize = 0,

        fn contains(data: ?*anyopaque, _: []const u8) !bool {
            return (@as(*@This(), @ptrCast(@alignCast(data.?)))).present;
        }

        fn receive(data: ?*anyopaque, _: []const u8) !bool {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.receives += 1;
            self.present = true;
            return true;
        }

        fn answer(data: ?*anyopaque, question: operation_api.Question) operation_api.QuestionResponse {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.questions += 1;
            std.testing.expect(question.kind == .import_pgp_key) catch return .declined;
            std.testing.expect(question.pgp_key_import != null) catch return .declined;
            return .accepted;
        }
    };
    var capture: Capture = .{};
    var context = operation_api.OperationContext.init(std.testing.allocator, std.testing.io);
    defer context.deinit();
    context.setQuestionHandler(.{ .function = Capture.answer, .data = &capture });
    var operation = context.begin(.{ .backend = .aur, .kind = .build, .subject = "demo" });
    defer operation.finish(.success);

    const fingerprint = "E1096BCBFF6D418796DE78515384CE82BA52C83A";
    try ensurePinnedKeys(
        std.testing.allocator,
        &operation,
        "spotify",
        &.{ fingerprint, fingerprint },
        .{ .context = &capture, .contains = Capture.contains, .receive = Capture.receive },
    );
    try std.testing.expectEqual(@as(usize, 1), capture.questions);
    try std.testing.expectEqual(@as(usize, 1), capture.receives);
}

test "source PGP key preflight fails closed when no question handler exists" {
    const BackendImpl = struct {
        fn contains(_: ?*anyopaque, _: []const u8) !bool {
            return false;
        }
        fn receive(_: ?*anyopaque, _: []const u8) !bool {
            return error.TestUnexpectedResult;
        }
    };
    var context = operation_api.OperationContext.init(std.testing.allocator, std.testing.io);
    defer context.deinit();
    var operation = context.begin(.{ .backend = .aur, .kind = .build, .subject = "demo" });
    defer operation.finish(.failed);
    try std.testing.expectError(error.PgpKeyImportDeclined, ensurePinnedKeys(
        std.testing.allocator,
        &operation,
        "spotify",
        &.{"E1096BCBFF6D418796DE78515384CE82BA52C83A"},
        .{ .context = null, .contains = BackendImpl.contains, .receive = BackendImpl.receive },
    ));
}
