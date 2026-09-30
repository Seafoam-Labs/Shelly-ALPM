const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const Fixture = @import("actions_fixture.zig");
const Archive = @import("archive_fixture.zig");

const a = std.testing.allocator;
const io = std.testing.io;
const trigger = "[Trigger]\nOperation=Install\nType=Package\nTarget=*\n";
const action = "[Action]\nWhen=PreTransaction\nExec=/usr/bin/bash -c 'exit 0'\n";

test "repeated actions override scalars while triggers and dependencies accumulate" {
    var hooks = rlpm.Hooks.init(a);
    defer hooks.deinit();
    try hooks.parse(
        "a.hook",
        trigger ++ action ++
            "[Action]\nWhen=PostTransaction\nDescription=old\nDescription=new\nExec=/new 'two words' \"\" x\\ y $literal\nDepends=virtual>=2\nDepends=base\nNeedsTargets=ignored\nAbortOnFail=false\nNetworkAccess=allowed\n" ++
            trigger,
    );
    try hooks.check();
    const hook = hooks.hooks.items[0];
    try std.testing.expectEqual(2, hook.triggers.items.len);
    try std.testing.expectEqual(2, hook.depends.items.len);
    try std.testing.expectEqual(.post_transaction, hook.when.?);
    try std.testing.expectEqualStrings("new", hook.description.?);
    try std.testing.expect(hook.abort_on_fail and hook.needs_targets and hook.allow_network);
    for (hook.argv, &[_][]const u8{ "/new", "two words", "", "x\\", "y", "$literal" }) |actual, expected|
        try std.testing.expectEqualStrings(
            expected,
            actual,
        );
    try std.testing.expectEqual(4, hooks.issues.items.len);
}

test "invalid hooks retain errors and line context; triggerless hooks mask" {
    const invalid = [_][]const u8{
        "Exec=/x",
        "[Unknown]",
        "[Trigger]\nTarget=x",
        trigger ++ "[Action]\nWhen=PreTransaction",
        trigger ++ action ++ "NetworkAccess=denied",
        trigger ++ action ++ "Unknown=x",
        trigger ++ action ++ "Exec=/x 'unterminated",
        trigger ++ action ++ "When=Invalid",
        trigger ++ "Operation=Invalid\n" ++ action,
    };
    for (invalid) |input| {
        var hooks = rlpm.Hooks.init(a);
        defer hooks.deinit();
        try hooks.parse("invalid.hook", input);
        try std.testing.expectError(error.InvalidHook, hooks.check());
        try std.testing.expectEqual(0, hooks.hooks.items.len);
        try std.testing.expect(hooks.issues.items[hooks.issues.items.len - 1].line > 0);
    }
    var hooks = rlpm.Hooks.init(a);
    defer hooks.deinit();
    try hooks.parse("empty.hook", "# masked\n");
    try hooks.parse("action-only.hook", "[Action]\nDescription=mask\n");
    try hooks.check();
    try std.testing.expectEqual(2, hooks.hooks.items.len);
}

test "directory precedence disabling missing directories and stem order" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("low/a.hook", trigger ++ action);
    try f.write("low/a-foo.hook", trigger ++ action);
    try f.write("low/masked.hook", trigger ++ action);
    try f.write("high/masked.hook", "");
    try f.write("low/override.hook", trigger ++ action);
    try f.write("high/override.hook", trigger ++ action ++ "Description=high\n");
    try f.write("low/not-a-hook.txt", "broken");
    try f.tmp.dir.createDirPath(io, "high/directory.hook");
    try f.tmp.dir.symLink(io, "/dev/null", "high/null.hook", .{});
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const low = try f.tmp.dir.realPathFileAlloc(io, "low", alloc);
    const high = try f.tmp.dir.realPathFileAlloc(io, "high", alloc);
    var hooks = rlpm.Hooks.init(a);
    defer hooks.deinit();
    try hooks.discover(io, &.{ low, "/nonexistent-rlpm-hooks", high });
    try hooks.check();
    try std.testing.expectEqual(5, hooks.hooks.items.len);
    try std.testing.expectEqualStrings("a.hook", hooks.hooks.items[0].name);
    try std.testing.expectEqualStrings("a-foo.hook", hooks.hooks.items[1].name);
    try std.testing.expectEqual(0, hooks.hooks.items[2].triggers.items.len);
    try std.testing.expectEqualStrings("high", hooks.hooks.items[4].description.?);
}

test "any trigger matches and NeedsTargets unions sorts deduplicates and negates" {
    var hooks = rlpm.Hooks.init(a);
    defer hooks.deinit();
    try hooks.parse("a.hook", trigger ++ action ++ "NeedsTargets\nTarget=invalid-in-action\n");
    try std.testing.expectError(error.InvalidHook, hooks.check());
    var valid = rlpm.Hooks.init(a);
    defer valid.deinit();
    try valid.parse(
        "b.hook",
        trigger ++ "Target=!skip\n" ++ action ++
            "NeedsTargets\n[Trigger]\nType=Path\nOperation=Upgrade\nOperation=Remove\nTarget=usr/*\n",
    );
    const matches = try valid.match(.pre_transaction, &.{
        .{
            .kind = .package,
            .operation = .install,
            .target = "z",
        },
        .{
            .kind = .package,
            .operation = .install,
            .target = "skip",
        },
        .{
            .kind = .package,
            .operation = .install,
            .target = "usr/a",
        },
        .{
            .kind = .path,
            .operation = .upgrade,
            .target = "usr/a",
        },
        .{
            .kind = .path,
            .operation = .remove,
            .target = "usr/b",
        },
        .{
            .kind = .path,
            .operation = .install,
            .target = "usr/c",
        },
    });
    try std.testing.expectEqual(1, matches.len);
    try std.testing.expectEqual(3, matches[0].targets.len);
    for (matches[0].targets, &[_][]const u8{ "usr/a", "usr/b", "z" }) |actual, expected|
        try std.testing.expectEqualStrings(
            expected,
            actual,
        );
    try std.testing.expectEqual(0, (try valid.match(.post_transaction, &.{})).len);
}

test "inventory matching includes absent removals NoExtract and original pacnew paths" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.installed("demo", "1-1", "conf\nmissing\nskipped\nusr/", null);
    try f.write("root/conf", "local");
    var archive = try Archive.init(
        &.{
            .{
                .path = ".PKGINFO",
                .contents = "pkgname = demo\npkgver = 2-1\narch = any\n",
            },
            .{ .path = "conf", .contents = "new" },
            .{ .path = "skipped", .contents = "skip" },
            .{ .path = "usr/", .kind = .directory },
            .{ .path = "usr/new", .contents = "new" },
        },
        .none,
    );
    defer archive.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    try owner.setList(io, .no_extract, &.{"skipped"});
    try owner.setList(io, .no_upgrade, &.{"conf"});
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, archive.path);
    try tx.prepare();
    try tx.preflight();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const changes = try rlpm.Hooks.changes(
        arena.allocator(),
        tx.plan().?,
        tx.manifest().?,
        owner.options().no_extract,
    );
    try std.testing.expectEqual(6, changes.len);
    for (changes) |change| {
        const expected: rlpm.Hooks.Operation = if (std.mem.eql(u8, change.target, "missing") or
            std.mem.eql(u8, change.target, "skipped"))
            .remove
        else if (std.mem.eql(u8, change.target, "usr/new"))
            .install
        else
            .upgrade;
        try std.testing.expectEqual(expected, change.operation);
    }
    try std.testing.expectError(error.InvalidTransactionState, tx.startActions());
    try std.testing.expectEqual(.prepared, tx.state); // Read-only preflight boundary.
}

test "scriptlet function discovery follows comments and native line chunks" {
    try std.testing.expect(!rlpm.Scriptlets.contains("# pre_install() {}\npost_install() {}", .pre_install));
    try std.testing.expect(rlpm.Scriptlets.contains("echo pre_install\n", .pre_install));
    var bytes: [1040]u8 = @splat('x');
    @memcpy(bytes[1020..1031], "pre_install");
    try std.testing.expect(!rlpm.Scriptlets.contains(&bytes, .pre_install));
}

fn allocations(allocator: std.mem.Allocator) !void {
    var hooks = rlpm.Hooks.init(allocator);
    defer hooks.deinit();
    try hooks.parse("a.hook", trigger ++ action ++ "NeedsTargets\n");
    try hooks.check();
    _ = try hooks.match(.pre_transaction, &.{.{
        .kind = .package,
        .operation = .install,
        .target = "demo",
    }});
}
test "parser and matcher release every allocation on failure" {
    try std.testing.checkAllAllocationFailures(a, allocations, .{});
}
