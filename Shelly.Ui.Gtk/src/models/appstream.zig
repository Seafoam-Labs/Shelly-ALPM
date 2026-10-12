const std = @import("std");
pub const Candidate = struct {
    source: enum { native, flatpak },
    id: []const u8,
    name: []const u8,
    installed: bool,
    summary: []const u8 = "",
    remote: []const u8 = "",
    scope: []const u8 = "",
    ref: []const u8 = "",

    pub fn operationArgs(self: Candidate, buffer: *[7][]const u8) []const []const u8 {
        const args: []const []const u8 = if (self.source == .native)
            &.{ "remove", "standard", self.id }
        else if (self.installed)
            &.{ "remove", "flatpak", self.ref, "--scope", self.scope }
        else if (std.mem.eql(u8, self.scope, "user"))
            &.{ "install", "flatpak", self.id, "--remote", self.remote, "--user" }
        else
            &.{ "install", "flatpak", self.id, "--remote", self.remote };
        @memcpy(buffer[0..args.len], args);
        return buffer[0..args.len];
    }
};
pub const Result = struct {
    candidates: []const Candidate,
    problems: []const struct { source: []const u8, code: []const u8 },

    pub fn hasInstalled(self: Result) bool {
        for (self.candidates) |candidate| if (candidate.installed) return true;
        return false;
    }
    pub fn eligible(self: Result, candidate: Candidate) bool {
        return candidate.installed or !self.hasInstalled();
    }
};

test "AppStream selection prefers installed packages and preserves ambiguity" {
    const result: Result = .{ .candidates = &.{
        .{ .source = .native, .id = "editor", .name = "Editor", .installed = true },
        .{ .source = .flatpak, .id = "org.example.Editor", .name = "Editor", .installed = true, .scope = "user" },
        .{ .source = .flatpak, .id = "org.example.Editor", .name = "Editor", .installed = false, .scope = "system" },
    }, .problems = &.{} };
    try std.testing.expect(result.eligible(result.candidates[0]));
    try std.testing.expect(result.eligible(result.candidates[1]));
    try std.testing.expect(!result.eligible(result.candidates[2]));
}

test "AppStream removal targets the selected Flatpak scope and complete reference" {
    var buffer: [7][]const u8 = undefined;
    const app: Candidate = .{ .source = .flatpak, .id = "org.example.App", .name = "App", .installed = true, .scope = "user", .ref = "app/org.example.App/x86_64/beta" };
    const args = app.operationArgs(&buffer);
    try std.testing.expectEqualStrings("remove", args[0]);
    try std.testing.expectEqualStrings("app/org.example.App/x86_64/beta", args[2]);
    try std.testing.expectEqualStrings("--scope", args[3]);
    try std.testing.expectEqualStrings("user", args[4]);
    var system = app;
    system.scope = "system";
    try std.testing.expectEqualStrings("system", system.operationArgs(&buffer)[4]);
}
