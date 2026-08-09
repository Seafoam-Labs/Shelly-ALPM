const std = @import("std");
const Zigalpm = @import("Zigalpm");
const runtime = @import("../../runtime/context.zig");

pub fn emitEolStatus(
    operation_context: *Zigalpm.OperationContext,
    kind: Zigalpm.OperationKind,
    level: Zigalpm.OperationStatusLevel,
    subject: []const u8,
    message: []const u8,
) void {
    var operation = operation_context.begin(.{
        .backend = .flatpak,
        .kind = kind,
        .subject = subject,
    });
    operation.status(level, message, "flatpak.eol", null);
    operation.finish(.success);
}

pub fn promptRebase(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    kind: Zigalpm.OperationKind,
    subject: []const u8,
    old_id: []const u8,
    old_branch: []const u8,
    new_id: []const u8,
    new_branch: []const u8,
    question: []const u8,
) !bool {
    const prompt = try Zigalpm.flatpak.eol.rebasePrompt(
        context.allocator,
        old_id,
        old_branch,
        new_id,
        new_branch,
        question,
    );
    defer context.allocator.free(prompt);

    var operation = operation_context.begin(.{
        .backend = .flatpak,
        .kind = kind,
        .subject = subject,
    });
    defer operation.finish(.success);
    var response = try operation.ask(.{
        .kind = .confirmation,
        .prompt = prompt,
        .default_response = .accepted,
    });
    defer response.deinit(context.allocator);
    return response.response == .accepted;
}

pub fn archFromReference(reference: []const u8) ?[]const u8 {
    const parsed = Zigalpm.flatpak.eol.parseRef(reference) orelse return null;
    return parsed.arch;
}
