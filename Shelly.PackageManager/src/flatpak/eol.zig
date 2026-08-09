const std = @import("std");
const types = @import("types.zig");

pub const ParsedRef = struct {
    kind: types.RefKind,
    id: []const u8,
    arch: []const u8,
    branch: []const u8,
};

pub fn parseRef(reference: []const u8) ?ParsedRef {
    var iterator = std.mem.splitScalar(u8, reference, '/');
    const kind_text = iterator.next() orelse return null;
    const id = iterator.next() orelse return null;
    const arch = iterator.next() orelse return null;
    const branch = iterator.next() orelse return null;
    if (iterator.next() != null) return null;
    if (id.len == 0 or arch.len == 0 or branch.len == 0) return null;
    const kind: types.RefKind = if (std.mem.eql(u8, kind_text, "app"))
        .app
    else if (std.mem.eql(u8, kind_text, "runtime"))
        .runtime
    else
        return null;
    return .{ .kind = kind, .id = id, .arch = arch, .branch = branch };
}

pub fn kindPrefix(kind: types.RefKind) []const u8 {
    return switch (kind) {
        .runtime => "runtime",
        .app, .unknown => "app",
    };
}

pub fn buildRef(
    allocator: std.mem.Allocator,
    kind: types.RefKind,
    id: []const u8,
    arch: []const u8,
    branch: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}/{s}",
        .{ kindPrefix(kind), id, arch, branch },
    );
}

pub const RebaseTarget = struct {
    id: []const u8,
    branch: []const u8,
    reference: ?[]const u8,
};

pub fn parseRebaseTarget(
    eol_rebase: []const u8,
    fallback_branch: []const u8,
) ?RebaseTarget {
    if (eol_rebase.len == 0) return null;
    if (std.mem.indexOfScalar(u8, eol_rebase, '/') == null) {
        return .{ .id = eol_rebase, .branch = fallback_branch, .reference = null };
    }
    const parsed = parseRef(eol_rebase) orelse return null;
    return .{ .id = parsed.id, .branch = parsed.branch, .reference = eol_rebase };
}

pub fn refLabel(
    allocator: std.mem.Allocator,
    id: []const u8,
    branch: []const u8,
) ![]u8 {
    if (branch.len == 0) return try allocator.dupe(u8, id);
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ id, branch });
}

pub fn rebasePrompt(
    allocator: std.mem.Allocator,
    old_id: []const u8,
    old_branch: []const u8,
    new_id: []const u8,
    new_branch: []const u8,
    question: []const u8,
) ![]u8 {
    const old_label = try refLabel(allocator, old_id, old_branch);
    defer allocator.free(old_label);
    const new_label = try refLabel(allocator, new_id, new_branch);
    defer allocator.free(new_label);
    return std.fmt.allocPrint(
        allocator,
        "{s} is end-of-life, replaced by {s}. {s}",
        .{ old_label, new_label, question },
    );
}

pub fn eolOnlyWarning(
    allocator: std.mem.Allocator,
    id: []const u8,
    branch: []const u8,
    reason: ?[]const u8,
) ![]u8 {
    const label = try refLabel(allocator, id, branch);
    defer allocator.free(label);
    if (reason) |text| {
        if (text.len > 0)
            return std.fmt.allocPrint(
                allocator,
                "{s} is end-of-life: {s}",
                .{ label, text },
            );
    }
    return std.fmt.allocPrint(allocator, "{s} is end-of-life.", .{label});
}

pub fn unchangedWarning(
    allocator: std.mem.Allocator,
    id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s} left unchanged; it remains end-of-life.",
        .{id},
    );
}

pub fn rebasedMessage(
    allocator: std.mem.Allocator,
    old_id: []const u8,
    new_id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Rebased {s} to {s}; app data migrated.",
        .{ old_id, new_id },
    );
}

test "parseRef accepts canonical app and runtime refs" {
    const app = parseRef("app/org.example.App/x86_64/stable").?;
    try std.testing.expectEqual(types.RefKind.app, app.kind);
    try std.testing.expectEqualStrings("org.example.App", app.id);
    try std.testing.expectEqualStrings("x86_64", app.arch);
    try std.testing.expectEqualStrings("stable", app.branch);

    const runtime_ref = parseRef("runtime/org.freedesktop.Platform/aarch64/24.08").?;
    try std.testing.expectEqual(types.RefKind.runtime, runtime_ref.kind);
    try std.testing.expectEqualStrings("24.08", runtime_ref.branch);
}

test "parseRef rejects malformed refs" {
    try std.testing.expect(parseRef("") == null);
    try std.testing.expect(parseRef("app") == null);
    try std.testing.expect(parseRef("app/org.example.App") == null);
    try std.testing.expect(parseRef("app/org.example.App/x86_64") == null);
    try std.testing.expect(parseRef("app/org.example.App/x86_64/stable/extra") == null);
    try std.testing.expect(parseRef("app//x86_64/stable") == null);
    try std.testing.expect(parseRef("extension/org.example.App/x86_64/stable") == null);
}

test "buildRef round-trips canonical refs" {
    const built = try buildRef(std.testing.allocator, .app, "org.example.App", "x86_64", "stable");
    defer std.testing.allocator.free(built);
    try std.testing.expectEqualStrings("app/org.example.App/x86_64/stable", built);

    const runtime_ref = try buildRef(std.testing.allocator, .runtime, "org.freedesktop.Platform", "aarch64", "24.08");
    defer std.testing.allocator.free(runtime_ref);
    try std.testing.expectEqualStrings("runtime/org.freedesktop.Platform/aarch64/24.08", runtime_ref);
}

test "parseRebaseTarget accepts full refs and bare application IDs" {
    const full = parseRebaseTarget("app/no.bragefuglseth.Keypunch/x86_64/stable", "beta").?;
    try std.testing.expectEqualStrings("no.bragefuglseth.Keypunch", full.id);
    try std.testing.expectEqualStrings("stable", full.branch);
    try std.testing.expectEqualStrings("app/no.bragefuglseth.Keypunch/x86_64/stable", full.reference.?);

    const bare = parseRebaseTarget("no.bragefuglseth.Keypunch", "beta").?;
    try std.testing.expectEqualStrings("no.bragefuglseth.Keypunch", bare.id);
    try std.testing.expectEqualStrings("beta", bare.branch);
    try std.testing.expect(bare.reference == null);
}

test "parseRebaseTarget rejects empty and malformed markers" {
    try std.testing.expect(parseRebaseTarget("", "stable") == null);
    try std.testing.expect(parseRebaseTarget("app/only-two", "stable") == null);
}

test "message helpers render branch-aware labels" {
    const prompt = try rebasePrompt(
        std.testing.allocator,
        "dev.bragefuglseth.Keypunch",
        "stable",
        "no.bragefuglseth.Keypunch",
        "stable",
        "Replace and migrate app data?",
    );
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings(
        "dev.bragefuglseth.Keypunch stable is end-of-life, replaced by no.bragefuglseth.Keypunch stable. Replace and migrate app data?",
        prompt,
    );

    const branchless = try refLabel(std.testing.allocator, "org.example.App", "");
    defer std.testing.allocator.free(branchless);
    try std.testing.expectEqualStrings("org.example.App", branchless);

    const eol_only = try eolOnlyWarning(std.testing.allocator, "org.example.Dead", "stable", "No longer maintained");
    defer std.testing.allocator.free(eol_only);
    try std.testing.expectEqualStrings("org.example.Dead stable is end-of-life: No longer maintained", eol_only);

    const eol_no_reason = try eolOnlyWarning(std.testing.allocator, "org.example.Dead", "stable", null);
    defer std.testing.allocator.free(eol_no_reason);
    try std.testing.expectEqualStrings("org.example.Dead stable is end-of-life.", eol_no_reason);

    const unchanged = try unchangedWarning(std.testing.allocator, "org.example.Dead");
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("org.example.Dead left unchanged; it remains end-of-life.", unchanged);

    const rebased = try rebasedMessage(std.testing.allocator, "org.example.Old", "org.example.New");
    defer std.testing.allocator.free(rebased);
    try std.testing.expectEqualStrings("Rebased org.example.Old to org.example.New; app data migrated.", rebased);
}
