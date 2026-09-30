//! Owned hook discovery and matching. Discover separately at each transaction
//! boundary: a package may install, replace, or remove post-transaction hooks.
const std = @import("std");
const Patterns = @import("PathPatterns.zig");
const Plan = @import("TransactionPlan.zig");
const Manifest = @import("ExecutionManifest.zig");
pub const When = @import("Callbacks.zig").HookWhen;

const Hooks = @This();

pub const Operation = enum(u2) { install, upgrade, remove };

pub const Kind = enum { package, path };

pub const Trigger = struct {
    operations: u3 = 0,
    kind: ?Kind = null,
    targets: std.ArrayList([]const u8) = .empty,
};

pub const Hook = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    triggers: std.ArrayList(Trigger) = .empty,
    depends: std.ArrayList([]const u8) = .empty,
    argv: []const []const u8 = &.{},
    when: ?When = null,
    abort_on_fail: bool = false,
    needs_targets: bool = false,
    allow_network: bool = false,
};

pub const Issue = struct {
    name: []const u8,
    line: usize = 0,
    cause: anyerror,
    warning: bool = false,
};

pub const Change = struct {
    kind: Kind,
    operation: Operation,
    target: []const u8,
};

pub const Match = struct {
    hook: *const Hook,
    targets: []const []const u8,
};
arena: std.heap.ArenaAllocator,
hooks: std.ArrayList(Hook) = .empty,
issues: std.ArrayList(Issue) = .empty,

pub fn init(allocator: std.mem.Allocator) Hooks {
    return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
}

pub fn deinit(self: *Hooks) void {
    self.arena.deinit();
    self.* = undefined;
}

fn issue(self: *Hooks, name: []const u8, line: usize, cause: anyerror, warning: bool) !void {
    const a = self.arena.allocator();
    try self.issues.append(
        a,
        .{
            .name = try a.dupe(u8, name),
            .line = line,
            .cause = cause,
            .warning = warning,
        },
    );
}

pub fn check(self: *const Hooks) !void {
    for (self.issues.items) |item|
        if (!item.warning) return error.InvalidHook;
}

/// Parse errors are retained with filename/line. OOM remains a fatal error.
/// Storage, including argv and patterns, belongs to this Hooks instance.
pub fn parse(self: *Hooks, name: []const u8, input: []const u8) !void {
    var line: usize = 0;
    const hook = self.parseInternal(name, input, &line) catch |err| {
        if (err == error.OutOfMemory) return err;
        return self.issue(name, line, err, false);
    };
    try self.hooks.append(self.arena.allocator(), hook);
}

fn parseInternal(self: *Hooks, name: []const u8, input: []const u8, line_number: *usize) !Hook {
    const a = self.arena.allocator();
    const contents = try a.dupe(u8, input);
    if (std.mem.indexOfScalar(u8, contents, 0) != null) return error.InvalidHook;
    var hook: Hook = .{ .name = try a.dupe(u8, name) };
    var section: enum { none, trigger, action } = .none;
    var offset: usize = 0;
    while (offset < contents.len) {
        // safe_fgets in the pinned parser uses PATH_MAX bytes, so long physical
        // lines are interpreted as separate 4095-byte chunks.
        const available = contents[offset..@min(contents.len, offset + 4095)];
        const count = if (std.mem.indexOfScalar(u8, available, '\n')) |index| index + 1 else available.len;
        const raw = available[0..count];
        offset += count;
        line_number.* += 1;
        // Native INI comments occupy a whole line; inline # is literal.
        const line = std.mem.trim(u8, raw, " \t\r\n\x0b\x0c");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            if (std.mem.eql(u8, line, "[Trigger]")) {
                section = .trigger;
                try hook.triggers.append(a, .{});
            } else if (std.mem.eql(u8, line, "[Action]"))
                section = .action
            else
                return error.InvalidHookSection;
            continue;
        }
        const split = std.mem.indexOfScalar(u8, line, '=');
        const key = std.mem.trim(u8, line[0 .. split orelse line.len], " \t\r\x0b\x0c");
        const value = if (split) |index| std.mem.trim(u8, line[index + 1 ..], " \t\r\x0b\x0c") else "";
        switch (section) {
            .none => return error.InvalidHookOption,
            .trigger => {
                const trigger = &hook.triggers.items[hook.triggers.items.len - 1];
                if (std.mem.eql(u8, key, "Operation")) {
                    const op: Operation = if (std.mem.eql(u8, value, "Install"))
                        .install
                    else if (std.mem.eql(u8, value, "Upgrade"))
                        .upgrade
                    else if (std.mem.eql(u8, value, "Remove"))
                        .remove
                    else
                        return error.InvalidHookValue;
                    trigger.operations |= @as(u3, 1) << @intFromEnum(op);
                } else if (std.mem.eql(u8, key, "Type")) {
                    if (trigger.kind != null)
                        try self.issue(
                            name,
                            line_number.*,
                            error.RepeatedHookOption,
                            true,
                        );
                    trigger.kind = if (std.mem.eql(u8, value, "Package"))
                        .package
                    else if (std.mem.eql(u8, value, "Path") or
                        std.mem.eql(u8, value, "File"))
                        .path
                    else
                        return error.InvalidHookValue;
                } else if (std.mem.eql(u8, key, "Target")) {
                    if (split == null) return error.InvalidHookValue;
                    try trigger.targets.append(a, value);
                } else return error.InvalidHookOption;
            },
            .action => {
                if (std.mem.eql(u8, key, "AbortOnFail")) {
                    hook.abort_on_fail = true;
                } else if (std.mem.eql(u8, key, "NeedsTargets")) {
                    hook.needs_targets = true;
                } else if (std.mem.eql(u8, key, "When")) {
                    if (hook.when != null) try self.issue(name, line_number.*, error.RepeatedHookOption, true);
                    hook.when = if (std.mem.eql(u8, value, "PreTransaction"))
                        .pre_transaction
                    else if (std.mem.eql(u8, value, "PostTransaction"))
                        .post_transaction
                    else
                        return error.InvalidHookValue;
                } else if (std.mem.eql(u8, key, "Exec")) {
                    if (hook.argv.len != 0)
                        try self.issue(
                            name,
                            line_number.*,
                            error.RepeatedHookOption,
                            true,
                        );
                    hook.argv = try wordsplit(a, value);
                } else if (std.mem.eql(u8, key, "Description")) {
                    if (split == null) return error.InvalidHookValue;
                    if (hook.description != null)
                        try self.issue(
                            name,
                            line_number.*,
                            error.RepeatedHookOption,
                            true,
                        );
                    hook.description = value;
                } else if (std.mem.eql(u8, key, "Depends")) {
                    if (split == null) return error.InvalidHookValue;
                    try hook.depends.append(a, value);
                } else if (std.mem.eql(u8, key, "NetworkAccess")) {
                    if (!std.mem.eql(u8, value, "allowed")) return error.InvalidHookValue;
                    hook.allow_network = true;
                } else return error.InvalidHookOption;
            },
        }
    }
    if (hook.triggers.items.len == 0) return hook;
    for (hook.triggers.items) |trigger|
        if (trigger.kind == null or trigger.operations == 0 or
            trigger.targets.items.len == 0)
            return error.IncompleteHookTrigger;
    if (hook.argv.len == 0 or hook.when == null) return error.IncompleteHookAction;
    if (hook.when == .post_transaction and hook.abort_on_fail)
        try self.issue(
            name,
            line_number.*,
            error.PostHookAbortIgnored,
            true,
        );
    return hook;
}

/// Native Exec tokenization, without shell expansion or PATH lookup. Allocator
/// must be an arena (intermediate strings are intentionally arena-owned).
pub fn wordsplit(a: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var quote: ?u8 = null;
    var started = false;
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        const ch = value[index];
        // Only quotes can be escaped. Within quotes, only that delimiter is
        // escapable; other backslashes remain literal (including before space).
        if (ch == '\\' and index + 1 < value.len and
            (if (quote) |q| value[index + 1] == q else value[index + 1] == '\'' or value[index + 1] == '"'))
        {
            index += 1;
            try word.append(a, value[index]);
            started = true;
        } else if (quote) |q| {
            if (ch == q) quote = null else try word.append(a, ch);
        } else if (ch == '\'' or ch == '"') {
            quote = ch;
            started = true;
        } else if (std.ascii.isWhitespace(ch)) {
            if (started) {
                try words.append(a, try word.toOwnedSlice(a));
                started = false;
            }
        } else {
            try word.append(a, ch);
            started = true;
        }
    }
    if (quote != null) return error.InvalidHookCommand;
    if (started) try words.append(a, try word.toOwnedSlice(a));
    if (words.items.len == 0 or words.items[0].len == 0) return error.InvalidHookCommand;
    return words.toOwnedSlice(a);
}

fn less(_: void, lhs: Hook, rhs: Hook) bool {
    return std.mem.lessThan(u8, lhs.name[0 .. lhs.name.len - 5], rhs.name[0 .. rhs.name.len - 5]);
}

pub fn discover(self: *Hooks, io: std.Io, directories: []const []const u8) !void {
    const a = self.arena.allocator();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var index = directories.len;
    while (index > 0) {
        index -= 1;
        var dir = std.Io.Dir.cwd().openDir(io, directories[index], .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) continue;
            try self.issue(directories[index], 0, err, false);
            continue;
        };
        defer dir.close(io);
        var iterator = dir.iterate();
        while (iterator.next(io) catch |err| blk: {
            try self.issue(directories[index], 0, err, false);
            break :blk null;
        }) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".hook") or seen.contains(entry.name)) continue;
            const file = dir.openFile(io, entry.name, .{}) catch |err| {
                try self.issue(entry.name, 0, err, false);
                continue;
            };
            defer file.close(io);
            const info = file.stat(io) catch |err| {
                try self.issue(entry.name, 0, err, false);
                continue;
            };
            if (info.kind == .directory) continue;
            // /dev/null is deliberately readable as an empty masking hook.
            var reader = file.reader(io, &.{});
            const contents = reader.interface.allocRemaining(a, .limited(4 * 1024 * 1024)) catch |err| {
                if (err == error.OutOfMemory) return err;
                try self.issue(entry.name, 0, err, false);
                continue;
            };
            const count = self.hooks.items.len;
            try self.parse(entry.name, contents);
            if (self.hooks.items.len != count) try seen.put(a, self.hooks.items[count].name, {});
        }
    }
    std.mem.sort(Hook, self.hooks.items, {}, less);
}

/// Path operations use ownership inventories, not on-disk existence: missing
/// removals still match, transfers become Upgrade, .pacnew uses the original
/// name, and NoExtract removes only the incoming side of the comparison.
pub fn changes(
    a: std.mem.Allocator,
    plan: *const Plan,
    manifest: *const Manifest,
    no_extract: []const []const u8,
) ![]const Change {
    var result: std.ArrayList(Change) = .empty;
    errdefer result.deinit(a);
    var paths: std.StringHashMapUnmanaged(u2) = .empty;
    defer paths.deinit(a);
    for (plan.additions) |addition| {
        try result.append(
            a,
            .{
                .kind = .package,
                .operation = if (addition.old != null)
                    .upgrade
                else
                    .install,
                .target = plan.package(addition.package).name,
            },
        );
    }
    for (plan.removals) |id| {
        const name = plan.package(id).name;
        var replacing = false;
        for (plan.additions) |addition|
            if (std.mem.eql(u8, name, plan.package(addition.package).name)) {
                replacing = true;
                break;
            };
        if (!replacing) try result.append(a, .{
            .kind = .package,
            .operation = .remove,
            .target = name,
        });
    }
    for (manifest.archives.items) |archive|
        for (archive.package.files) |file| {
            if (try Patterns.match(a, no_extract, file.name) == .matched) continue;
            const slot = try paths.getOrPut(a, file.name);
            if (!slot.found_existing) slot.value_ptr.* = 0;
            slot.value_ptr.* |= 1;
        };
    for (manifest.locals.items) |local| {
        var removing = std.mem.indexOfScalar(Plan.Id, plan.removals, local.id) != null;
        for (plan.additions) |addition|
            if (addition.old == local.id) {
                removing = true;
                break;
            };
        if (!removing) continue;
        for (local.package.files) |file| {
            const slot = try paths.getOrPut(a, file.name);
            if (!slot.found_existing) slot.value_ptr.* = 0;
            slot.value_ptr.* |= 2;
        }
    }
    var iterator = paths.iterator();
    while (iterator.next()) |item|
        try result.append(a, .{
            .kind = .path,
            .target = item.key_ptr.*,
            .operation = switch (item.value_ptr.*) {
                1 => .install,
                2 => .remove,
                3 => .upgrade,
                else => unreachable,
            },
        });
    return result.toOwnedSlice(a);
}

pub fn match(self: *Hooks, when: When, effects: []const Change) ![]const Match {
    const a = self.arena.allocator();
    var result: std.ArrayList(Match) = .empty;
    for (self.hooks.items) |*hook| {
        if (hook.when != when) continue;
        var targets: std.StringHashMapUnmanaged(void) = .empty;
        for (hook.triggers.items) |trigger|
            for (effects) |effect| {
                if (trigger.kind != effect.kind or
                    trigger.operations & (@as(u3, 1) << @intFromEnum(effect.operation)) == 0)
                    continue;
                if (try Patterns.match(a, trigger.targets.items, effect.target) == .matched)
                    try targets.put(a, effect.target, {});
            };
        if (targets.count() == 0) continue;
        const names = try a.alloc([]const u8, targets.count());
        var keys = targets.keyIterator();
        for (names) |*name|
            name.* = try a.dupe(u8, keys.next().?.*);
        std.mem.sort([]const u8, names, {}, stringLess);
        try result.append(a, .{ .hook = hook, .targets = names });
    }
    return result.toOwnedSlice(a);
}

fn stringLess(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}
