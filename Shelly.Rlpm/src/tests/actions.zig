//! Real processes inside disposable roots, run under an unprivileged user
//! namespace. Unavailable chroot/network capabilities are test failures.
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const Fixture = @import("actions_fixture.zig");
const Archive = @import("archive_fixture.zig");
const options = @import("action_fixtures");

const a = std.testing.allocator;
const io = std.testing.io;
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("unistd.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("signal.h");
});
const trigger = "[Trigger]\nOperation=Install\nType=Package\nTarget=*\n";
const pre = "[Action]\nWhen=PreTransaction\n";
const post = "[Action]\nWhen=PostTransaction\n";
const info = "pkgname = demo\npkgver = 2-1\narch = any\n";
const script = "printf 'sourced:%s\\n' \"$#\" >> /trace\npre_install() { printf 'pre_install:%s:%s\\n' \"$#\" \"$1\" >> /trace; }\npost_install() { printf 'post_install:%s:%s\\n' \"$#\" \"$1\" >> /trace; }\npre_upgrade() { printf 'pre_upgrade:%s:%s:%s\\n' \"$#\" \"$1\" \"$2\" >> /trace; }\npost_upgrade() { printf 'post_upgrade:%s:%s:%s\\n' \"$#\" \"$1\" \"$2\" >> /trace; }\npre_remove() { printf 'pre_remove:%s:%s\\n' \"$#\" \"$1\" >> /trace; }\npost_remove() { printf 'post_remove:%s:%s\\n' \"$#\" \"$1\" >> /trace; }\n";

const Events = struct {
    output: std.ArrayList(u8) = .empty,
    hooks: std.ArrayList(u8) = .empty,
    owner: ?*rlpm.Owner = null,
    cancel_on_output: bool = false,
    cancel_on_phase: ?rlpm.Callbacks.Boundary = null,
    reentry: ?anyerror = null,

    fn deinit(self: *Events) void {
        self.output.deinit(a);
        self.hooks.deinit(a);
    }

    fn event(context: ?*anyopaque, value: rlpm.Callbacks.Event) void {
        const self: *Events = @ptrCast(@alignCast(context.?));
        switch (value) {
            .scriptlet_output => |line| {
                self.output.appendSlice(a, line) catch @panic("allocation");
                if (self.cancel_on_output) self.owner.?.requestCancellation();
                if (self.owner) |owner| owner.setList(io, .ignore_packages, &.{"reentry"}) catch |err| {
                    self.reentry = err;
                };
            },
            .phase => |phase| {
                if (phase.phase == .transaction and self.cancel_on_phase == phase.boundary)
                    self.owner.?.requestCancellation();
            },
            .hook_run => |hook| {
                self.hooks.appendSlice(a, hook.name) catch @panic("allocation");
                self.hooks.append(a, if (hook.boundary == .start) '>' else '<') catch @panic("allocation");
            },
            else => {},
        }
    }

    fn configure(self: *Events, owner: *rlpm.Owner) !void {
        self.owner = owner;
        var config = owner.options();
        config.callbacks.event = event;
        config.callbacks.event_context = self;
        try owner.setOptions(io, config);
    }
};

fn probe(f: *Fixture) !void {
    try f.shell();
    try f.executable(options.probe, "root/probe");
}

fn filter(owner: *rlpm.Owner) !void {
    var config = owner.options();
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(io, options.filter, a);
    defer a.free(executable);
    config.worker_executable = executable;
    try owner.setOptions(io, config);
}

fn emptyArchive() !Archive {
    return Archive.init(&.{.{ .path = ".PKGINFO", .contents = info }}, .none);
}

test "real chroot process preserves parent state and forwards merged complete output" {
    var f = try Fixture.init();
    defer f.deinit();
    try probe(&f);
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    var events: Events = .{};
    defer events.deinit();
    try events.configure(&owner);
    var manifest = try rlpm.ExecutionManifest.init(a, f.root, f.db);
    defer manifest.deinit();
    if (c.dup2(manifest.root.fd, 200) != 200) return error.FixtureDescriptor;
    defer _ = c.close(200);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    defer a.free(cwd);
    const old_umask = c.umask(0o077);
    defer _ = c.umask(old_umask);
    const result = try rlpm.ActionProcess.run(
        &owner,
        io,
        .{
            .root = &manifest.root,
            .argv = &.{ "/probe", "environment" },
        },
    );
    if (!result.success())
        std.debug.print(
            "action result={any} output={s}\n",
            .{ result, events.output.items },
        );
    try std.testing.expect(result.success());
    try std.testing.expectEqualStrings("environment-ok\nstderr-ok\n", events.output.items);
    try std.testing.expectEqual(0o077, c.umask(0o077));
    const after_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    defer a.free(after_cwd);
    try std.testing.expectEqualStrings(cwd, after_cwd);
    try std.testing.expectEqual(error.CallbackReentry, events.reentry.?);
    const signal = try rlpm.ActionProcess.run(
        &owner,
        io,
        .{
            .root = &manifest.root,
            .argv = &.{ "/usr/bin/bash", "-c", "kill -TERM $$" },
        },
    );
    try std.testing.expect(signal.term == .signal);
    try std.testing.expect(signal.setup_failure == null);
    const missing = try rlpm.ActionProcess.run(&owner, io, .{ .root = &manifest.root, .argv = &.{"bash"} });
    try std.testing.expectEqual(.execute, missing.setup_failure.?.stage);
    const exit125 = try rlpm.ActionProcess.run(
        &owner,
        io,
        .{
            .root = &manifest.root,
            .argv = &.{ "/usr/bin/bash", "-c", "exit 125" },
        },
    );
    try std.testing.expectEqual(125, exit125.term.exited);
    try std.testing.expect(exit125.setup_failure == null);
}

test "network namespace isolates while explicit and global permissions bypass it" {
    var f = try Fixture.init();
    defer f.deinit();
    try probe(&f);
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    var events: Events = .{};
    defer events.deinit();
    try events.configure(&owner);
    var manifest = try rlpm.ExecutionManifest.init(a, f.root, f.db);
    defer manifest.deinit();
    const socket = c.socket(c.AF_INET, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (socket < 0) return error.FixtureSocket;
    defer _ = c.close(socket);
    var address: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    address.sin_family = c.AF_INET;
    address.sin_addr.s_addr = std.mem.nativeToBig(u32, 0x7f000001);
    if (c.bind(socket, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0 or c.listen(socket, 8) != 0)
        return error.FixtureSocket;
    var len: c.socklen_t = @sizeOf(@TypeOf(address));
    if (c.getsockname(socket, @ptrCast(&address), &len) != 0) return error.FixtureSocket;
    const port = try std.fmt.allocPrint(a, "{d}", .{std.mem.bigToNative(u16, address.sin_port)});
    defer a.free(port);
    for ([_]rlpm.ActionProcess.Network{ .required, .allowed }) |network| {
        const result = try rlpm.ActionProcess.run(
            &owner,
            io,
            .{
                .root = &manifest.root,
                .argv = &.{ "/probe", "network", port },
                .network = network,
            },
        );
        if (!result.success())
            std.debug.print(
                "action result={any} output={s}\n",
                .{ result, events.output.items },
            );
        try std.testing.expect(result.success());
    }
    var config = owner.options();
    config.sandbox.disable_network = true;
    try owner.setOptions(io, config);
    const permitted = try rlpm.ActionProcess.run(
        &owner,
        io,
        .{
            .root = &manifest.root,
            .argv = &.{ "/probe", "network", port },
        },
    );
    try std.testing.expect(permitted.success());
    try std.testing.expectEqualStrings("isolated\nconnected\nconnected\n", events.output.items);
}

test "required isolation failure blocks execution best effort warns and independent controls remain independent" {
    var f = try Fixture.init();
    defer f.deinit();
    try probe(&f);
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    try filter(&owner);
    var events: Events = .{};
    defer events.deinit();
    try events.configure(&owner);
    var manifest = try rlpm.ExecutionManifest.init(a, f.root, f.db);
    defer manifest.deinit();
    for ([_]bool{ false, true }) |disabled| {
        var config = owner.options();
        config.sandbox.disable_filesystem = disabled;
        config.sandbox.disable_syscalls = disabled;
        try owner.setOptions(io, config);
        const result = try rlpm.ActionProcess.run(
            &owner,
            io,
            .{
                .root = &manifest.root,
                .argv = &.{ "/probe", "environment" },
            },
        );
        try std.testing.expectEqual(.network, result.setup_failure.?.stage);
        try std.testing.expectEqual(0, events.output.items.len);
    }
    const best = try rlpm.ActionProcess.run(
        &owner,
        io,
        .{
            .root = &manifest.root,
            .argv = &.{ "/probe", "environment" },
            .network = .best_effort,
        },
    );
    try std.testing.expect(best.success() and best.network_warning != null);
    var config = owner.options();
    config.sandbox.setDisabled(true);
    try owner.setOptions(io, config);
    const global = try rlpm.ActionProcess.run(
        &owner,
        io,
        .{
            .root = &manifest.root,
            .argv = &.{ "/probe", "environment" },
        },
    );
    try std.testing.expect(global.success() and global.network_warning == null);
}

test "large target input and output progress concurrently without pipe deadlock" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.shell();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    var events: Events = .{};
    defer events.deinit();
    try events.configure(&owner);
    var manifest = try rlpm.ExecutionManifest.init(a, f.root, f.db);
    defer manifest.deinit();
    const input = try a.alloc(u8, 512 * 1024);
    defer a.free(input);
    @memset(input, 'x');
    input[input.len - 1] = '\n';
    const result = try rlpm.ActionProcess.run(
        &owner,
        io,
        .{
            .root = &manifest.root,
            .argv = &.{
                "/usr/bin/bash",
                "-c",
                "printf '%262144s' x; IFS= read -r line; printf '\\nlength=%s\\n' \"${#line}\"",
            },
            .stdin = input,
        },
    );
    if (!result.success())
        std.debug.print(
            "action result={any} output={s}\n",
            .{ result, events.output.items },
        );
    try std.testing.expect(result.success());
    try std.testing.expect(std.mem.endsWith(u8, events.output.items, "length=524287\n"));
    try std.testing.expect(events.output.items.len > 262144);
    const early = try rlpm.ActionProcess.run(
        &owner,
        io,
        .{
            .root = &manifest.root,
            .argv = &.{ "/usr/bin/bash", "-c", "exit 0" },
            .stdin = input,
        },
    );
    try std.testing.expect(early.success());
}

test "cancellation terminates process group and retains interrupted outcome" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.shell();
    try f.hook(
        "a.hook",
        trigger ++ pre ++
            "Exec=/usr/bin/bash -c '(while :; do :; done) & printf \"ready\\n\"; wait'\nAbortOnFail\n",
    );
    var archive = try emptyArchive();
    defer archive.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    var events: Events = .{ .cancel_on_output = true };
    defer events.deinit();
    try events.configure(&owner);
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, archive.path);
    try tx.prepare();
    try tx.preflight();
    Fixture.enter(tx);
    defer Fixture.leave(tx);
    try std.testing.expectError(error.Cancelled, tx.startActions());
    try std.testing.expectEqual(.failed, tx.actions().?.state);
    try std.testing.expectEqual(error.Cancelled, tx.actions().?.outcomes.items[0].cause.?);
    try std.testing.expectEqualStrings("a.hook>a.hook<", events.hooks.items);
}

test "install stages trace hooks scriptlets linker cache and refreshed post hook discovery" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.shell();
    try f.hook(
        "a.hook",
        trigger ++ pre ++
            "Exec=/usr/bin/bash -c 'printf \"pre-hook\\n\" >> /trace; while IFS= read -r target; do printf \"target:%s\\n\" \"$target\" >> /trace; done'\nNeedsTargets\n",
    );
    try f.write("root/etc/ld.so.conf", "");
    try f.write("root/usr/bin/ldconfig", "#!/usr/bin/bash\nprintf 'ldconfig\\n' >> /trace\n");
    const file = try f.tmp.dir.openFile(io, "root/usr/bin/ldconfig", .{});
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0o755));
    var archive = try Archive.init(
        &.{
            .{ .path = ".PKGINFO", .contents = info },
            .{ .path = ".INSTALL", .contents = script },
        },
        .none,
    );
    defer archive.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, archive.path);
    try tx.prepare();
    try tx.preflight();
    Fixture.enter(tx);
    defer Fixture.leave(tx);
    const actions = try tx.startActions();
    try std.testing.expectError(error.InvalidActionState, actions.finish());
    const id = tx.plan().?.additions[0].package;
    try actions.beforePackage(id);
    try std.testing.expectError(error.InvalidActionState, actions.beforePackage(id));
    try f.installed("demo", "2-1", "", "post_install() { printf 'new-db-post:%s\\n' \"$1\" >> /trace; }\n");
    try f.hook(
        "b.hook",
        trigger ++ post ++ "Exec=/usr/bin/bash -c 'printf \"post-hook\\n\" >> /trace'\nDepends=demo>=2\n",
    );
    try actions.afterPackage(id);
    try owner.local.?.reloadDatabase(io, null);
    try actions.finish();
    try std.testing.expectEqual(.complete, actions.state);
    try f.expect(
        "root/trace",
        "pre-hook\ntarget:demo\nsourced:0\npre_install:1:2-1\nnew-db-post:2-1\nldconfig\npost-hook\n",
    );
    var tmpdir = try f.tmp.dir.openDir(io, "root/tmp", .{ .iterate = true });
    defer tmpdir.close(io);
    var iterator = tmpdir.iterate();
    try std.testing.expect(try iterator.next(io) == null);
}

test "upgrade reinstall downgrade use new archive then new database with new old arguments" {
    for ([_][]const u8{ "1-1", "2-1", "3-1" }) |old| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.shell();
        try f.installed("demo", old, "", "pre_remove() { exit 99; }\npre_upgrade() { exit 99; }\n");
        var archive = try Archive.init(
            &.{
                .{ .path = ".PKGINFO", .contents = info },
                .{ .path = ".INSTALL", .contents = script },
            },
            .none,
        );
        defer archive.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, .{});
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, archive.path);
        try tx.prepare();
        try tx.preflight();
        Fixture.enter(tx);
        defer Fixture.leave(tx);
        const actions = try tx.startActions();
        const id = tx.plan().?.additions[0].package;
        try actions.beforePackage(id);
        try f.installed("demo", "2-1", "", script);
        try actions.afterPackage(id);
        try actions.finish();
        const expected = try std.fmt.allocPrint(
            a,
            "sourced:0\npre_upgrade:2:2-1:{s}\nsourced:0\npost_upgrade:2:2-1:{s}\n",
            .{ old, old },
        );
        defer a.free(expected);
        try f.expect("root/trace", expected);
    }
}

test "removal uses old install on both sides before deleting local record" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.shell();
    try f.installed("demo", "1-1", "", script);
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try tx.remove("demo");
    try tx.prepare();
    try tx.preflight();
    Fixture.enter(tx);
    defer Fixture.leave(tx);
    const actions = try tx.startActions();
    const id = tx.plan().?.removals[0];
    try actions.beforePackage(id);
    try actions.afterPackage(id);
    try actions.finish();
    try f.expect("root/trace", "sourced:0\npre_remove:1:1-1\nsourced:0\npost_remove:1:1-1\n");
}

test "hook dependencies failure policy AbortOnFail and post errors preserve results" {
    for ([_]bool{ false, true }) |abort| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.shell();
        try f.hook(
            "a.hook",
            if (abort)
                trigger ++ pre ++ "Exec=/usr/bin/bash -c 'exit 3'\nAbortOnFail\n"
            else
                trigger ++ pre ++ "Exec=/usr/bin/bash -c 'exit 3'\n",
        );
        try f.hook("b.hook", trigger ++ pre ++ "Exec=/usr/bin/bash -c 'printf \"b\\n\" >> /trace'\n");
        try f.hook("c.hook", trigger ++ post ++ "Exec=/usr/bin/bash -c 'exit 4'\nAbortOnFail\n");
        try f.hook("d.hook", trigger ++ post ++ "Exec=/usr/bin/bash -c 'printf \"d\\n\" >> /trace'\n");
        try f.hook(
            "e.hook",
            trigger ++ post ++ "Exec=/usr/bin/bash -c 'printf \"BAD\\n\" >> /trace'\nDepends=absent\n",
        );
        var archive = try emptyArchive();
        defer archive.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        try owner.addAssumedInstalled(io, try rlpm.PackageRelation.parse("absent"));
        const tx = try owner.initializeTransaction(io, .{});
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, archive.path);
        try tx.prepare();
        try tx.preflight();
        Fixture.enter(tx);
        defer Fixture.leave(tx);
        if (abort) {
            try std.testing.expectError(error.PreTransactionHookFailed, tx.startActions());
            try std.testing.expectEqual(.failed, tx.actions().?.state);
            try std.testing.expectError(error.FileNotFound, f.read("root/trace"));
        } else {
            const actions = try tx.startActions();
            const id = tx.plan().?.additions[0].package;
            try actions.beforePackage(id);
            try actions.afterPackage(id);
            try f.hook("bad.hook", "[Invalid]\n"); // post discovery error must not suppress valid hooks
            try actions.finish();
            try f.expect("root/trace", "b\nd\n");
            var missing = false;
            for (actions.outcomes.items) |outcome|
                if (outcome.cause) |cause| {
                    if (cause == error.HookDependencyMissing) missing = true;
                };
            try std.testing.expect(missing);
        }
    }
}

test "NOHOOKS NOSCRIPTLET DBONLY DOWNLOADONLY are independent" {
    for ([_]rlpm.TransactionFlags{
        .{},
        .{ .no_hooks = true },
        .{ .no_scriptlets = true },
        .{ .database_only = true },
        .{ .no_hooks = true, .no_scriptlets = true },
        .{ .download_only = true },
    }) |flags| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.shell();
        try f.hook("a.hook", trigger ++ pre ++ "Exec=/usr/bin/bash -c 'printf \"hook\\n\" >> /trace'\n");
        var archive = try Archive.init(
            &.{
                .{ .path = ".PKGINFO", .contents = info },
                .{ .path = ".INSTALL", .contents = script },
            },
            .none,
        );
        defer archive.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, flags);
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, archive.path);
        try tx.prepare();
        if (!flags.download_only) try tx.preflight();
        Fixture.enter(tx);
        defer Fixture.leave(tx);
        const actions = try tx.startActions();
        if (!flags.download_only) {
            const id = tx.plan().?.additions[0].package;
            try actions.beforePackage(id);
            try actions.afterPackage(id);
        }
        try actions.finish();
        if (flags.download_only or (flags.no_hooks and flags.no_scriptlets))
            try std.testing.expectError(
                error.FileNotFound,
                f.read("root/trace"),
            )
        else
            try f.expect(
                "root/trace",
                if (flags.no_hooks)
                    "sourced:0\npre_install:1:2-1\n"
                else if (flags.no_scriptlets)
                    "hook\n"
                else
                    "hook\nsourced:0\npre_install:1:2-1\n",
            );
    }
}

test "malformed pre hooks abort before any action and NOHOOKS bypasses discovery" {
    for ([_]bool{ false, true }) |no_hooks| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.shell();
        try f.hook("a.hook", trigger ++ pre ++ "Exec=/usr/bin/bash -c 'printf \"BAD\\n\" >> /trace'\n");
        try f.hook("z.hook", "[Invalid]\n");
        var archive = try emptyArchive();
        defer archive.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, .{ .no_hooks = no_hooks });
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, archive.path);
        try tx.prepare();
        try tx.preflight();
        Fixture.enter(tx);
        defer Fixture.leave(tx);
        if (no_hooks) {
            _ = try tx.startActions();
        } else try std.testing.expectError(error.InvalidHook, tx.startActions());
        try std.testing.expectError(error.FileNotFound, f.read("root/trace"));
    }
}

test "scriptlet failures stay nonfatal and versions cannot inject shell code" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.shell();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    var manifest = try rlpm.ExecutionManifest.init(a, f.root, f.db);
    defer manifest.deinit();
    try f.write("root/install", "pre_install() { printf '%s\\n' \"$1\" > /trace; return 7; }\n");
    const source = try std.fmt.allocPrint(a, "{s}/install", .{f.root});
    defer a.free(source);
    const result = try rlpm.Scriptlets.run(
        &owner,
        io,
        &manifest.root,
        .{ .file = source },
        .pre_install,
        "1'; printf INJECTED > /bad; '-1",
        null,
    );
    try std.testing.expectEqual(7, result.process.?.term.exited);
    try f.expect("root/trace", "1'; printf INJECTED > /bad; '-1\n");
    try std.testing.expectError(error.FileNotFound, f.read("root/bad"));
}

test "pinned CachyOS oracle matches parser decisions script arguments and traces" {
    const Case = struct {
        name: []const u8,
        hook: []const u8,
        script: ?[]const u8 = null,
        old_version: ?[]const u8 = null,
        flags: u32 = 0,
        success: bool,
        trace: []const u8,
    };

    const Oracle = struct {
        library_sha256: []const u8,
        cases: []const Case,
    };
    const parsed = try std.json.parseFromSlice(
        Oracle,
        a,
        @embedFile("reference/actions.json"),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    const identity = try std.json.parseFromSlice(
        struct {
            library: struct {
                sha256: []const u8,
            },
        },
        a,
        @embedFile("reference/manifest.json"),
        .{ .ignore_unknown_fields = true },
    );
    defer identity.deinit();
    try std.testing.expectEqualStrings(identity.value.library.sha256, parsed.value.library_sha256);
    try std.testing.expectEqual(19, parsed.value.cases.len);
    for (parsed.value.cases) |case| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.shell();
        try f.hook("fixture.hook", case.hook);
        if (case.old_version) |old| try f.installed("demo", old, "", "pre_remove() { exit 99; }\n");
        var entries: std.ArrayList(Archive.Entry) = .empty;
        defer entries.deinit(a);
        try entries.append(a, .{ .path = ".PKGINFO", .contents = info });
        if (case.script) |install| try entries.append(a, .{ .path = ".INSTALL", .contents = install });
        var archive = try Archive.init(entries.items, .none);
        defer archive.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, try .fromBits(case.flags));
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, archive.path);
        try tx.prepare();
        try tx.preflight();
        Fixture.enter(tx);
        defer Fixture.leave(tx);
        if (tx.startActions()) |actions| {
            if (!case.success)
                std.debug.print(
                    "oracle case {s}: native aborted; RLPM proceeded\n",
                    .{case.name},
                );
            try std.testing.expect(case.success);
            const id = tx.plan().?.additions[0].package;
            try actions.beforePackage(id);
            try f.installed("demo", "2-1", "", case.script);
            try actions.afterPackage(id);
            try owner.local.?.reloadDatabase(io, null);
            try actions.finish();
        } else |err| {
            if (case.success)
                std.debug.print(
                    "oracle case {s}: native succeeded; RLPM {s}\n",
                    .{ case.name, @errorName(err) },
                );
            try std.testing.expect(!case.success);
            try std.testing.expect(err == error.InvalidHook or err == error.PreTransactionHookFailed);
        }
        const trace = f.read("root/trace") catch |err|
            if (err == error.FileNotFound)
                try a.dupe(u8, "")
            else
                return err;
        defer a.free(trace);
        if (!std.mem.eql(u8, case.trace, trace))
            std.debug.print("oracle trace differs: {s}\n", .{case.name});
        try std.testing.expectEqualStrings(case.trace, trace);
    }
}

test "nonfatal script failure retains status and failed payload skips post hooks" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.shell();
    try f.hook("post.hook", trigger ++ post ++ "Exec=/usr/bin/bash -c 'printf BAD > /trace'\n");
    var archive = try Archive.init(
        &.{
            .{ .path = ".PKGINFO", .contents = info },
            .{
                .path = ".INSTALL",
                .contents = "pre_install() { return 7; }\n",
            },
        },
        .none,
    );
    defer archive.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, archive.path);
    try tx.prepare();
    try tx.preflight();
    Fixture.enter(tx);
    defer Fixture.leave(tx);
    const actions = try tx.startActions();
    try actions.beforePackage(tx.plan().?.additions[0].package);
    try std.testing.expectEqual(error.ScriptletFailed, actions.outcomes.items[0].cause.?);
    try std.testing.expectEqual(7, actions.outcomes.items[0].process.?.term.exited);
    actions.fail();
    try std.testing.expectError(error.InvalidActionState, actions.finish());
    try std.testing.expectError(error.FileNotFound, f.read("root/trace"));
}

test "linker cache runs best effort despite NOHOOKS NOSCRIPTLET DBONLY" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.shell();
    try f.write("root/etc/ld.so.conf", "");
    try f.write("root/usr/bin/ldconfig", "#!/usr/bin/bash\nprintf ldconfig > /trace\n");
    const file = try f.tmp.dir.openFile(io, "root/usr/bin/ldconfig", .{});
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0o755));
    var archive = try emptyArchive();
    defer archive.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    try filter(&owner);
    const tx = try owner.initializeTransaction(
        io,
        .{
            .no_hooks = true,
            .no_scriptlets = true,
            .database_only = true,
        },
    );
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, archive.path);
    try tx.prepare();
    try tx.preflight();
    Fixture.enter(tx);
    defer Fixture.leave(tx);
    const actions = try tx.startActions();
    const id = tx.plan().?.additions[0].package;
    try actions.beforePackage(id);
    try actions.afterPackage(id);
    try actions.finish();
    try f.expect("root/trace", "ldconfig");
    try std.testing.expectEqual(error.NetworkIsolationWarning, actions.outcomes.items[0].cause.?);
    try std.testing.expect(actions.outcomes.items[0].process.?.success());
}

test "scriptlet cancellation cleans staging and preserves temporary directory mode" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.shell();
    try f.write("root/install", "pre_install() { printf 'ready\\n'; while :; do :; done; }\n");
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    var events: Events = .{ .cancel_on_output = true };
    defer events.deinit();
    try events.configure(&owner);
    var manifest = try rlpm.ExecutionManifest.init(a, f.root, f.db);
    defer manifest.deinit();
    const source = try std.fmt.allocPrint(a, "{s}/install", .{f.root});
    defer a.free(source);
    const old_umask = c.umask(0o077);
    defer _ = c.umask(old_umask);
    try std.testing.expectError(
        error.Cancelled,
        rlpm.Scriptlets.run(
            &owner,
            io,
            &manifest.root,
            .{ .file = source },
            .pre_install,
            "2-1",
            null,
        ),
    );
    var tmpdir = try f.tmp.dir.openDir(io, "root/tmp", .{ .iterate = true });
    defer tmpdir.close(io);
    var iterator = tmpdir.iterate();
    try std.testing.expect(try iterator.next(io) == null);
    var stat: c.struct_stat = undefined;
    try std.testing.expectEqual(0, c.fstat(tmpdir.handle, &stat));
    try std.testing.expectEqual(0o1777, stat.st_mode & 0o7777);
}

test "scriptlet cleanup diagnostics survive successful execution" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.shell();
    var archive = try Archive.init(
        &.{
            .{ .path = ".PKGINFO", .contents = info },
            .{
                .path = ".INSTALL",
                .contents = "pre_install() { printf extra > \"${BASH_SOURCE%/*}/extra\"; }\n",
            },
        },
        .none,
    );
    defer archive.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, archive.path);
    try tx.prepare();
    try tx.preflight();
    Fixture.enter(tx);
    defer Fixture.leave(tx);
    const actions = try tx.startActions();
    try actions.beforePackage(tx.plan().?.additions[0].package);
    try std.testing.expect(actions.outcomes.items[0].process.?.success());
    try std.testing.expectEqual(.cleanup, actions.outcomes.items[1].kind);
    try std.testing.expectEqual(error.ScriptletCleanupFailed, actions.outcomes.items[1].cause.?);
}

test "phase callbacks can cancel before payload or post hooks" {
    for ([_]rlpm.Callbacks.Boundary{ .start, .done }) |boundary| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.shell();
        try f.hook("post.hook", trigger ++ post ++ "Exec=/usr/bin/bash -c 'printf BAD > /trace'\n");
        var archive = try emptyArchive();
        defer archive.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        var events: Events = .{ .cancel_on_phase = boundary };
        defer events.deinit();
        try events.configure(&owner);
        const tx = try owner.initializeTransaction(io, .{});
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, archive.path);
        try tx.prepare();
        try tx.preflight();
        Fixture.enter(tx);
        defer Fixture.leave(tx);
        if (boundary == .start) try std.testing.expectError(error.Cancelled, tx.startActions()) else {
            const actions = try tx.startActions();
            const id = tx.plan().?.additions[0].package;
            try actions.beforePackage(id);
            try actions.afterPackage(id);
            try std.testing.expectError(error.Cancelled, actions.finish());
        }
        try std.testing.expectEqual(.failed, tx.actions().?.state);
        try std.testing.expectError(error.FileNotFound, f.read("root/trace"));
    }
}
