//! A metadata-only snapshot for deferred UI. No borrowed strings, Package
//! pointers, arenas, or file descriptors survive the originating callback.
const std = @import("std");
const C = @import("Callbacks.zig");
const Plan = @import("TransactionPlan.zig");
const Package = @import("Package.zig");

const OwnedQuestion = @This();
arena: std.heap.ArenaAllocator,
question: C.Question,

pub fn init(allocator: std.mem.Allocator, source: C.Question) !OwnedQuestion {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const question: C.Question = switch (source) {
        inline else => |value, tag| blk: {
            var copied: @TypeOf(value) = undefined;
            inline for (std.meta.fields(@TypeOf(value))) |field| {
                if (comptime std.mem.eql(u8, field.name, "views")) {
                    const views = try a.alloc(C.PackageView, value.views.len);
                    for (views, value.views) |*out, view| {
                        const pkg = try a.create(Package);
                        pkg.* = try Plan.copyMetadata(a, view.package.*);
                        out.* = .{ .reference = view.reference, .package = pkg };
                    }
                    copied.views = views;
                } else if (@typeInfo(field.type) == .error_set) {
                    @field(copied, field.name) = @field(value, field.name);
                } else @field(copied, field.name) = try Plan.copyValue(
                    field.type,
                    a,
                    @field(value, field.name),
                );
            }
            break :blk @unionInit(C.Question, @tagName(tag), copied);
        },
    };
    return .{ .arena = arena, .question = question };
}

pub fn deinit(self: *OwnedQuestion) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Copies only the answer, preserving all original problem data and views.
pub fn applyAnswer(destination: *C.Question, answer: C.Question) !void {
    if (std.meta.activeTag(destination.*) != std.meta.activeTag(answer)) return error.InvalidAnswer;
    switch (destination.*) {
        .install_ignored => |*q| q.install = answer.install_ignored.install,
        .replace => |*q| q.replace = answer.replace.replace,
        .conflict => |*q| q.remove = answer.conflict.remove,
        .corrupted => |*q| q.remove = answer.corrupted.remove,
        .remove_packages => |*q| q.skip = answer.remove_packages.skip,
        .import_key => |*q| q.import = answer.import_key.import,
        .select_provider => |*q| {
            if (answer.select_provider.selected >= q.candidates.len) return error.InvalidAnswer;
            q.selected = answer.select_provider.selected;
        },
    }
}
