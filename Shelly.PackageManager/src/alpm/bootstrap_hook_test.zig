//! Runs only in a fresh user/mount/PID namespace; never needs host root.
const std = @import("std");
const worker_fixture = @import("worker_fixture");
const pm = @import("PackageManager");
const Manager = pm.Manager;
const fixture = @import("hook_fixture");

test "native provisioning discovers newly installed guest hooks and detects their failures" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    for ([_]Manager.Backend{ .libalpm, .rlpm }) |backend| {
        if (!backend.available()) continue;
        for ([_]bool{ false, true }) |fail| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
            defer allocator.free(path);
            const root = try std.fs.path.join(allocator, &.{ path, "root" });
            defer allocator.free(root);
            const database = try std.fs.path.join(allocator, &.{ root, "var/lib/pacman" });
            defer allocator.free(database);
            const config_path = try std.fs.path.join(allocator, &.{ path, "pacman.conf" });
            defer allocator.free(config_path);
            const host_hooks = try std.fs.path.join(allocator, &.{ path, "host-hooks" });
            defer allocator.free(host_hooks);
            const log_path = try std.fs.path.join(allocator, &.{ root, "pacman.log" });
            defer allocator.free(log_path);
            try tmp.dir.createDirPath(io, "root/var/lib/pacman");
            try tmp.dir.createDirPath(io, "root/tmp");
            try tmp.dir.createDirPath(io, "host-hooks");
            const config = try std.fmt.allocPrint(
                allocator,
                "[options]\nArchitecture = auto\nSigLevel = Never\nHookDir = {s}\n",
                .{host_hooks},
            );
            defer allocator.free(config);
            try tmp.dir.writeFile(io, .{ .sub_path = "pacman.conf", .data = config });
            // Would abort the transaction before package extraction if loaded.
            try tmp.dir.writeFile(io, .{
                .sub_path = "host-hooks/00-host.hook",
                .data = "[Trigger]\nType = Package\nOperation = Install\nTarget = *\n" ++
                    "[Action]\nWhen = PreTransaction\nAbortOnFail\nExec = /does-not-exist\n",
            });

            const helper = try std.Io.Dir.cwd().readFileAlloc(io, fixture.helper, allocator, .limited(32 * 1024 * 1024));
            defer allocator.free(helper);
            var archive = try tmp.dir.createFile(io, "fixture.pkg.tar", .{});
            var archive_open = true;
            defer if (archive_open) archive.close(io);
            var buffer: [4096]u8 = undefined;
            var writer = archive.writer(io, &buffer);
            var tar: std.tar.Writer = .{ .underlying_writer = &writer.interface };
            try tar.writeFileBytes(".PKGINFO", "pkgname = hook-fixture\npkgver = 1-1\npkgdesc = Hook test\narch = any\nsize = 0\nxdata = pkgtype=pkg\n", .{ .mode = 0o644 });
            try tar.writeFileBytes("usr/bin/hook-helper", helper, .{ .mode = 0o755 });
            try tar.writeFileBytes("usr/share/libalpm/hooks/10-first.hook", "[Trigger]\nType = Package\nOperation = Install\nTarget = hook-fixture\n" ++
                "[Action]\nWhen = PostTransaction\nExec = /usr/bin/hook-helper first\n", .{ .mode = 0o644 });
            try tar.writeFileBytes("usr/share/libalpm/hooks/20-second.hook", "[Trigger]\nType = Path\nOperation = Install\nTarget = usr/bin/hook-helper\n" ++
                "[Action]\nWhen = PostTransaction\nDepends = hook-fixture\nExec = /usr/bin/hook-helper second\n", .{ .mode = 0o644 });
            if (fail) try tar.writeFileBytes("usr/share/libalpm/hooks/30-failure.hook", "[Trigger]\nType = Package\nOperation = Install\nTarget = *\n" ++
                "[Action]\nWhen = PostTransaction\nExec = /usr/bin/hook-helper fail\n", .{ .mode = 0o644 });
            try tar.finishPedantically();
            try writer.interface.flush();
            archive.close(io);
            archive_open = false;
            const package = try std.fs.path.join(allocator, &.{ path, "fixture.pkg.tar" });
            defer allocator.free(package);

            const executable = try std.Io.Dir.cwd().realPathFileAlloc(io, worker_fixture.path, allocator);
            defer allocator.free(executable);
            const manager = try Manager.init(allocator, std.testing.environ, .{
                .backend = backend,
                .worker_executable = executable,
                .config_path = config_path,
                .root_directory = root,
                .database_path = database,
                .use_root = true,
                .root_hooks_only = true,
                .log_file = log_path,
            });
            defer manager.deinit();
            // The transaction below must still exclude host hooks after refresh.
            try manager.refresh();

            const Capture = struct {
                saw_failed_hook: bool = false,
                hooks: usize = 0,
                legacy_hooks: usize = 0,
                hook_format_valid: bool = true,
                fn question(_: ?*anyopaque, _: pm.operation.Question) pm.operation.QuestionResponse {
                    return .accepted;
                }
                fn operationEvent(data: ?*anyopaque, event: pm.OperationEvent) void {
                    const self: *@This() = @ptrCast(@alignCast(data.?));
                    if (event == .progress and std.mem.eql(u8, event.progress.update.stage orelse "", "hook")) {
                        const update = event.progress.update;
                        self.hooks += 1;
                        var expected: [64]u8 = undefined;
                        const prefix = std.fmt.bufPrint(&expected, "({d}/{d}) ", .{ update.completed orelse 0, update.total orelse 0 }) catch unreachable;
                        self.hook_format_valid = self.hook_format_valid and std.mem.startsWith(u8, update.message orelse "", prefix) and update.completed == self.hooks;
                    }
                }
                fn hook(data: ?*anyopaque, args: Manager.events.HookArgs) void {
                    const self: *@This() = @ptrCast(@alignCast(data.?));
                    self.legacy_hooks += 1;
                    self.hook_format_valid = self.hook_format_valid and args.position == self.legacy_hooks and args.total >= args.position;
                }
                fn errorMessage(data: ?*anyopaque, args: Manager.events.ErrorArgs) void {
                    const self: *@This() = @ptrCast(@alignCast(data.?));
                    if (std.mem.indexOf(u8, args.message, "30-failure.hook") != null) self.saw_failed_hook = true;
                }
            };
            var capture: Capture = .{};
            var operations = pm.OperationContext.init(allocator, io);
            defer operations.deinit();
            operations.setQuestionHandler(.{ .function = Capture.question });
            _ = try operations.subscribe(.{ .function = Capture.operationEvent, .data = &capture });
            manager.setOperationContext(&operations);
            defer manager.setOperationContext(null);
            _ = try manager.dispatcher.addHookHandler(.{ .function = Capture.hook, .data = &capture });
            _ = try manager.dispatcher.addErrorHandler(.{ .function = Capture.errorMessage, .data = &capture });
            try manager.install_local_packages(&.{package}, .{});
            try std.testing.expectEqual(@as(usize, if (fail) 3 else 2), capture.hooks);
            try std.testing.expectEqual(capture.hooks, capture.legacy_hooks);
            try std.testing.expect(capture.hook_format_valid);
            try std.testing.expectEqual(fail, manager.packageSetupFailed());
            try std.testing.expectEqual(fail, capture.saw_failed_hook);
            for ([_][]const u8{ "root/first", "root/second" }) |marker| {
                const content = try tmp.dir.readFileAlloc(io, marker, allocator, .limited(64));
                defer allocator.free(content);
                try std.testing.expectEqualStrings("guest hook ran\n", content);
            }
        }
    }
}
