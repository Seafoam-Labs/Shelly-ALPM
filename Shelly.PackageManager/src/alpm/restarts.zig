const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract.zig");
const mapped_libraries = @import("mapped_libraries.zig");
const pseudo_file = @import("../shared/pseudo_file.zig");
const RestartCheckOptions = contract.RestartCheckOptions;
const RestartReport = contract.RestartReport;
const AffectedProcess = contract.AffectedProcess;
const ServiceRestartFailure = contract.ServiceRestartFailure;
const ServiceRestartFailureKind = contract.ServiceRestartFailureKind;
const RestartSkipReason = contract.RestartSkipReason;
const SkippedService = contract.SkippedService;
const LibraryState = mapped_libraries.LibraryState;

pub const LibrarySnapshot = mapped_libraries.LibrarySnapshot;
pub const hasDeletedSharedLibrary = mapped_libraries.hasDeletedSharedLibrary;

pub fn check(self: anytype, options: RestartCheckOptions) error{OutOfMemory}!RestartReport {
    if (builtin.os.tag != .linux) return RestartReport.empty(self.allocator);

    var running_kernel: ?[]u8 = null;
    errdefer if (running_kernel) |kernel| self.allocator.free(kernel);
    var running_kernel_modules_present: ?bool = null;
    var needs_reboot = false;
    var needs_session_restart = false;
    var process_scan_complete = true;
    var skipped_processes: usize = 0;

    var changed_libraries: std.StringHashMapUnmanaged(LibraryState) = .empty;
    defer mapped_libraries.deinitStates(&changed_libraries, self.allocator);
    const scoped_to_transaction = options.library_snapshot != null;
    if (options.library_snapshot) |snapshot|
        try snapshot.collectChanges(self.io(), self.allocator, &changed_libraries);

    var affected_processes: std.ArrayList(AffectedProcess) = .empty;
    errdefer {
        for (affected_processes.items) |*process| process.deinit(self.allocator);
        affected_processes.deinit(self.allocator);
    }
    var affected_services: std.ArrayList([]u8) = .empty;
    errdefer {
        for (affected_services.items) |service| self.allocator.free(service);
        affected_services.deinit(self.allocator);
    }
    var restarted_services: std.ArrayList([]u8) = .empty;
    errdefer {
        for (restarted_services.items) |service| self.allocator.free(service);
        restarted_services.deinit(self.allocator);
    }
    var skipped_services: std.ArrayList(SkippedService) = .empty;
    errdefer {
        for (skipped_services.items) |*service| service.deinit(self.allocator);
        skipped_services.deinit(self.allocator);
    }
    var failures: std.ArrayList(ServiceRestartFailure) = .empty;
    errdefer {
        for (failures.items) |*failure| failure.deinit(self.allocator);
        failures.deinit(self.allocator);
    }

    const osrelease_path = std.fs.path.join(
        self.allocator,
        &.{ options.proc_root, "sys", "kernel", "osrelease" },
    ) catch return error.OutOfMemory;
    defer self.allocator.free(osrelease_path);

    if (pseudo_file.readAlloc(
        self.io(),
        self.allocator,
        osrelease_path,
        .limited(4096),
    )) |contents| {
        defer self.allocator.free(contents);
        const trimmed = std.mem.trim(u8, contents, " \t\r\n");
        if (trimmed.len != 0) {
            running_kernel = self.allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
            const modules_path = std.fs.path.join(
                self.allocator,
                &.{ options.modules_root, trimmed },
            ) catch return error.OutOfMemory;
            defer self.allocator.free(modules_path);

            if (std.Io.Dir.cwd().statFile(self.io(), modules_path, .{})) |stat| {
                running_kernel_modules_present = stat.kind == .directory;
                needs_reboot = !running_kernel_modules_present.?;
            } else |err| switch (err) {
                error.FileNotFound, error.NotDir => {
                    running_kernel_modules_present = false;
                    needs_reboot = true;
                },
                else => running_kernel_modules_present = null,
            }
        }
    } else |_| {}

    var proc_dir = std.Io.Dir.cwd().openDir(
        self.io(),
        options.proc_root,
        .{ .iterate = true },
    ) catch {
        process_scan_complete = false;
        return .{
            .allocator = self.allocator,
            .running_kernel = running_kernel,
            .running_kernel_modules_present = running_kernel_modules_present,
            .needs_reboot = needs_reboot,
            .needs_session_restart = needs_session_restart,
            .policy = options.policy,
            .process_scan_complete = process_scan_complete,
            .skipped_processes = skipped_processes,
            .affected_processes = &.{},
            .affected_services = &.{},
            .restarted_services = &.{},
            .skipped_services = &.{},
            .failures = &.{},
        };
    };
    defer proc_dir.close(self.io());

    var iterator = proc_dir.iterateAssumeFirstIteration();
    while (true) {
        const next_entry = iterator.next(self.io()) catch {
            process_scan_complete = false;
            break;
        };
        const entry = next_entry orelse break;
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;

        const maps_path = std.fs.path.join(
            self.allocator,
            &.{ options.proc_root, entry.name, "maps" },
        ) catch return error.OutOfMemory;
        defer self.allocator.free(maps_path);
        const maps = pseudo_file.readAlloc(
            self.io(),
            self.allocator,
            maps_path,
            .limited(16 * 1024 * 1024),
        ) catch {
            skipped_processes += 1;
            continue;
        };
        defer self.allocator.free(maps);
        if (!hasStaleSharedLibrary(maps, &changed_libraries, scoped_to_transaction)) continue;

        var command: ?[]u8 = null;
        var critical_process = false;
        const comm_path = std.fs.path.join(
            self.allocator,
            &.{ options.proc_root, entry.name, "comm" },
        ) catch return error.OutOfMemory;
        defer self.allocator.free(comm_path);
        if (pseudo_file.readAlloc(
            self.io(),
            self.allocator,
            comm_path,
            .limited(4096),
        )) |comm_contents| {
            defer self.allocator.free(comm_contents);
            const comm = std.mem.trim(u8, comm_contents, " \t\r\n");
            if (comm.len != 0) {
                command = self.allocator.dupe(u8, comm) catch return error.OutOfMemory;
                critical_process = isCriticalRestartProcess(comm);
            }
        } else |_| {}

        var service: ?[]u8 = null;
        var user_slice = false;
        const cgroup_path = std.fs.path.join(
            self.allocator,
            &.{ options.proc_root, entry.name, "cgroup" },
        ) catch {
            if (command) |owned| self.allocator.free(owned);
            return error.OutOfMemory;
        };
        defer self.allocator.free(cgroup_path);
        if (pseudo_file.readAlloc(
            self.io(),
            self.allocator,
            cgroup_path,
            .limited(1024 * 1024),
        )) |cgroup| {
            defer self.allocator.free(cgroup);
            user_slice = isUserSessionCgroup(cgroup);
            if (serviceFromCgroup(cgroup)) |service_name| {
                service = self.allocator.dupe(u8, service_name) catch {
                    if (command) |owned| self.allocator.free(owned);
                    return error.OutOfMemory;
                };

                var seen = false;
                for (affected_services.items) |known| {
                    if (std.mem.eql(u8, known, service_name)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    const owned_service = self.allocator.dupe(u8, service_name) catch {
                        if (command) |owned| self.allocator.free(owned);
                        if (service) |owned| self.allocator.free(owned);
                        return error.OutOfMemory;
                    };
                    affected_services.append(self.allocator, owned_service) catch {
                        self.allocator.free(owned_service);
                        if (command) |owned| self.allocator.free(owned);
                        if (service) |owned| self.allocator.free(owned);
                        return error.OutOfMemory;
                    };
                }
            }
        } else |_| {}

        // User managers and user buses only need the session to restart. A
        // system manager, system bus, or logind process indicates that the
        // running system itself is stale.
        if (critical_process) {
            if (user_slice)
                needs_session_restart = true
            else
                needs_reboot = true;
        }

        affected_processes.append(self.allocator, .{
            .pid = pid,
            .command = command,
            .service = service,
        }) catch {
            if (command) |owned| self.allocator.free(owned);
            if (service) |owned| self.allocator.free(owned);
            return error.OutOfMemory;
        };
    }

    std.mem.sort([]u8, affected_services.items, {}, stringBefore);

    if (options.policy == .automatic and !needs_reboot) {
        for (affected_services.items) |service| {
            if (isSessionCriticalUnit(service)) {
                try appendSkipped(self, &skipped_services, service, .session_critical);
                continue;
            }
            if (!unitIsActive(self, options.systemctl_path, service)) {
                try appendSkipped(self, &skipped_services, service, .inactive);
                continue;
            }
            const result = std.process.run(self.allocator, self.io(), .{
                // `try-restart` never starts a stopped or oneshot unit; a stale
                // mapping is only relevant while the service is running.
                .argv = &.{ options.systemctl_path, "try-restart", service },
                .stdout_limit = .limited(4096),
                .stderr_limit = .limited(64 * 1024),
            }) catch |err| {
                const failure_service = self.allocator.dupe(u8, service) catch return error.OutOfMemory;
                const failure_message = self.allocator.dupe(u8, @errorName(err)) catch {
                    self.allocator.free(failure_service);
                    return error.OutOfMemory;
                };
                failures.append(self.allocator, .{
                    .service = failure_service,
                    .kind = .spawn,
                    .exit_code = null,
                    .message = failure_message,
                }) catch {
                    self.allocator.free(failure_service);
                    self.allocator.free(failure_message);
                    return error.OutOfMemory;
                };
                continue;
            };
            defer self.allocator.free(result.stdout);
            defer self.allocator.free(result.stderr);

            const succeeded = switch (result.term) {
                .exited => |code| code == 0,
                else => false,
            };
            if (succeeded) {
                const restarted = self.allocator.dupe(u8, service) catch return error.OutOfMemory;
                restarted_services.append(self.allocator, restarted) catch {
                    self.allocator.free(restarted);
                    return error.OutOfMemory;
                };
                continue;
            }

            const failure_kind: ServiceRestartFailureKind = switch (result.term) {
                .exited => .exit_status,
                else => .terminated,
            };
            const exit_code: ?u8 = switch (result.term) {
                .exited => |code| code,
                else => null,
            };
            const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
            const failure_message = if (stderr.len != 0)
                self.allocator.dupe(u8, stderr) catch return error.OutOfMemory
            else if (exit_code) |code|
                std.fmt.allocPrint(self.allocator, "Could not restart the affected service: systemctl exited with code {0d}. Review the service command output.", .{code}) catch return error.OutOfMemory
            else
                self.allocator.dupe(
                    u8,
                    "Could not confirm the restart of the affected service because systemctl was terminated. Check the service status.",
                ) catch return error.OutOfMemory;
            const failure_service = self.allocator.dupe(u8, service) catch {
                self.allocator.free(failure_message);
                return error.OutOfMemory;
            };
            failures.append(self.allocator, .{
                .service = failure_service,
                .kind = failure_kind,
                .exit_code = exit_code,
                .message = failure_message,
            }) catch {
                self.allocator.free(failure_service);
                self.allocator.free(failure_message);
                return error.OutOfMemory;
            };
        }
    }

    const process_slice: []AffectedProcess = if (affected_processes.items.len == 0)
        &.{}
    else
        affected_processes.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    errdefer {
        for (process_slice) |*process| process.deinit(self.allocator);
        if (process_slice.len != 0) self.allocator.free(process_slice);
    }
    const affected_service_slice: [][]u8 = if (affected_services.items.len == 0)
        &.{}
    else
        affected_services.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    errdefer {
        for (affected_service_slice) |service| self.allocator.free(service);
        if (affected_service_slice.len != 0) self.allocator.free(affected_service_slice);
    }
    const restarted_service_slice: [][]u8 = if (restarted_services.items.len == 0)
        &.{}
    else
        restarted_services.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    errdefer {
        for (restarted_service_slice) |service| self.allocator.free(service);
        if (restarted_service_slice.len != 0) self.allocator.free(restarted_service_slice);
    }
    const skipped_service_slice: []SkippedService = if (skipped_services.items.len == 0)
        &.{}
    else
        skipped_services.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    errdefer {
        for (skipped_service_slice) |*service| service.deinit(self.allocator);
        if (skipped_service_slice.len != 0) self.allocator.free(skipped_service_slice);
    }
    const failure_slice: []ServiceRestartFailure = if (failures.items.len == 0)
        &.{}
    else
        failures.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    errdefer {
        for (failure_slice) |*failure| failure.deinit(self.allocator);
        if (failure_slice.len != 0) self.allocator.free(failure_slice);
    }

    return .{
        .allocator = self.allocator,
        .running_kernel = running_kernel,
        .running_kernel_modules_present = running_kernel_modules_present,
        .needs_reboot = needs_reboot,
        .needs_session_restart = needs_session_restart,
        .policy = options.policy,
        .process_scan_complete = process_scan_complete,
        .skipped_processes = skipped_processes,
        .affected_processes = process_slice,
        .affected_services = affected_service_slice,
        .restarted_services = restarted_service_slice,
        .skipped_services = skipped_service_slice,
        .failures = failure_slice,
    };
}

/// Returns true when the process maps a shared object that changed during the
/// transaction. An unscoped scan treats every deleted shared object as stale,
/// which is only appropriate for callers without a pre-transaction snapshot.
fn hasStaleSharedLibrary(
    maps: []const u8,
    changed: *const std.StringHashMapUnmanaged(LibraryState),
    scoped: bool,
) bool {
    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        const entry = mapped_libraries.parseMapEntry(line) orelse continue;
        if (!mapped_libraries.isSharedObjectPath(entry.path)) continue;
        if (!scoped) {
            if (entry.deleted) return true;
            continue;
        }
        const current = changed.get(entry.path) orelse continue;
        if (current.present and current.inode == entry.inode) continue;
        return true;
    }
    return false;
}

fn appendSkipped(
    self: anytype,
    skipped: *std.ArrayList(SkippedService),
    service: []const u8,
    reason: RestartSkipReason,
) error{OutOfMemory}!void {
    const owned = self.allocator.dupe(u8, service) catch return error.OutOfMemory;
    errdefer self.allocator.free(owned);
    skipped.append(self.allocator, .{ .service = owned, .reason = reason }) catch
        return error.OutOfMemory;
}

/// Runs `systemctl is-active --quiet`. Only the documented inactive (3) and
/// unknown (4) exit codes skip a restart; other failures proceed so the
/// restart attempt reports the real error.
fn unitIsActive(self: anytype, systemctl_path: []const u8, service: []const u8) bool {
    const result = std.process.run(self.allocator, self.io(), .{
        .argv = &.{ systemctl_path, "is-active", "--quiet", service },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(64 * 1024),
    }) catch return true;
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code != 3 and code != 4,
        else => true,
    };
}

pub fn serviceFromCgroup(cgroup: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, cgroup, '\n');
    while (lines.next()) |line| {
        const marker = "/system.slice/";
        const marker_index = std.mem.indexOf(u8, line, marker) orelse continue;
        var components = std.mem.splitScalar(u8, line[marker_index + marker.len ..], '/');
        while (components.next()) |component| {
            const trimmed = std.mem.trim(u8, component, " \t\r");
            if (trimmed.len > ".service".len and std.mem.endsWith(u8, trimmed, ".service")) {
                return trimmed;
            }
        }
    }
    return null;
}

pub fn isUserSessionCgroup(cgroup: []const u8) bool {
    return std.mem.indexOf(u8, cgroup, "/user.slice/") != null;
}

/// Units whose restart would end the invoking session, the system bus, or the
/// display manager. They are always reported and never restarted
/// automatically.
pub fn isSessionCriticalUnit(unit: []const u8) bool {
    const exact = [_][]const u8{
        "dbus.service",
        "dbus-broker.service",
        "systemd-logind.service",
        "systemd-journald.service",
        "systemd-udevd.service",
        "systemd-user-sessions.service",
        "polkit.service",
        "accounts-daemon.service",
        "display-manager.service",
        "greetd.service",
        "gdm.service",
        "sddm.service",
        "lightdm.service",
        "lxdm.service",
        "pearl-greeter.service",
        "devario-gpu-driver.service",
        "devario-gpu-hotplug.service",
    };
    for (exact) |candidate| {
        if (std.mem.eql(u8, unit, candidate)) return true;
    }
    return (std.mem.startsWith(u8, unit, "user@") or std.mem.startsWith(u8, unit, "getty@")) and
        std.mem.endsWith(u8, unit, ".service");
}

pub fn isCriticalRestartProcess(command: []const u8) bool {
    return std.mem.eql(u8, command, "systemd") or
        std.mem.eql(u8, command, "dbus-daemon") or
        std.mem.eql(u8, command, "dbus-broker");
}

fn stringBefore(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

test "check reads the running kernel through the real procfs" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    const ProcHost = struct {
        allocator: std.mem.Allocator,
        pub fn io(self: *@This()) std.Io {
            _ = self;
            return testing.io;
        }
    };
    var host = ProcHost{ .allocator = testing.allocator };
    // No fake fixture can cover the reader regression: regular files report a
    // real stat size, so only the real procfs distinguishes a streaming read
    // from a size-based one. Report mode keeps the scan from restarting real
    // services on the test host.
    var report = try check(&host, .{ .policy = .report });
    defer report.deinit();
    try testing.expect(report.running_kernel != null);
    try testing.expect(report.running_kernel.?.len > 0);
    try testing.expect(report.process_scan_complete);
}

test "session-critical units are never restarted automatically" {
    const testing = std.testing;
    try testing.expect(isSessionCriticalUnit("dbus-broker.service"));
    try testing.expect(isSessionCriticalUnit("systemd-logind.service"));
    try testing.expect(isSessionCriticalUnit("pearl-greeter.service"));
    try testing.expect(isSessionCriticalUnit("getty@tty1.service"));
    try testing.expect(isSessionCriticalUnit("user@1000.service"));
    try testing.expect(!isSessionCriticalUnit("NetworkManager.service"));
}

test "user-slice cgroups identify session restarts and not system reboots" {
    const testing = std.testing;
    try testing.expect(isUserSessionCgroup("0::/user.slice/user-1000.slice/user@1000.service/app.slice\n"));
    try testing.expect(!isUserSessionCgroup("0::/system.slice/dbus-broker.service\n"));
    try testing.expect(!isUserSessionCgroup("0::/init.scope\n"));
}

test "stale shared libraries are filtered to the captured transaction changes" {
    const testing = std.testing;
    var changed: std.StringHashMapUnmanaged(LibraryState) = .empty;
    defer mapped_libraries.deinitStates(&changed, testing.allocator);
    try changed.put(testing.allocator, try testing.allocator.dupe(u8, "/usr/lib/libsystemd.so.0"), .{ .present = true, .inode = 9 });

    try testing.expect(hasStaleSharedLibrary(
        "7f00-7f01 r-xp 00000000 00:1e 7 /usr/lib/libsystemd.so.0 (deleted)\n",
        &changed,
        true,
    ));
    // A mapping that already uses the current inode is not stale.
    try testing.expect(!hasStaleSharedLibrary(
        "7f00-7f01 r-xp 00000000 00:1e 9 /usr/lib/libsystemd.so.0\n",
        &changed,
        true,
    ));
    // Libraries outside this transaction are ignored even when deleted.
    try testing.expect(!hasStaleSharedLibrary(
        "7f00-7f01 r-xp 00000000 00:1f 42 /usr/lib/libother.so.1 (deleted)\n",
        &changed,
        true,
    ));
    // Without a snapshot the legacy deleted-object scan still applies.
    try testing.expect(hasStaleSharedLibrary(
        "7f00-7f01 r-xp 00000000 00:1f 42 /usr/lib/libother.so.1 (deleted)\n",
        &changed,
        false,
    ));
}

test "report policy lists affected services without invoking systemctl" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const proc_root = try std.fs.path.join(testing.allocator, &.{ root, "proc" });
    defer testing.allocator.free(proc_root);
    const modules_root = try std.fs.path.join(testing.allocator, &.{ root, "modules" });
    defer testing.allocator.free(modules_root);
    const kernel_parent = try std.fs.path.join(testing.allocator, &.{ proc_root, "sys", "kernel" });
    defer testing.allocator.free(kernel_parent);
    const process_dir = try std.fs.path.join(testing.allocator, &.{ proc_root, "123" });
    defer testing.allocator.free(process_dir);
    const kernel_file = try std.fs.path.join(testing.allocator, &.{ kernel_parent, "osrelease" });
    defer testing.allocator.free(kernel_file);
    const maps_file = try std.fs.path.join(testing.allocator, &.{ process_dir, "maps" });
    defer testing.allocator.free(maps_file);
    const comm_file = try std.fs.path.join(testing.allocator, &.{ process_dir, "comm" });
    defer testing.allocator.free(comm_file);
    const cgroup_file = try std.fs.path.join(testing.allocator, &.{ process_dir, "cgroup" });
    defer testing.allocator.free(cgroup_file);
    const kernel_dir = try std.fs.path.join(testing.allocator, &.{ modules_root, "6.12.1-test" });
    defer testing.allocator.free(kernel_dir);

    try std.Io.Dir.cwd().createDirPath(testing.io, kernel_parent);
    try std.Io.Dir.cwd().createDirPath(testing.io, process_dir);
    try std.Io.Dir.cwd().createDirPath(testing.io, kernel_dir);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = kernel_file, .data = "6.12.1-test\n" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = maps_file,
        .data = "7f00-7f01 r-xp 00000000 00:00 0 /usr/lib/libdemo.so.1 (deleted)\n",
    });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = comm_file, .data = "demo\n" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = cgroup_file,
        .data = "0::/system.slice/system-demo.slice/demo.service\n",
    });

    const Host = struct {
        allocator: std.mem.Allocator,
        pub fn io(self: *@This()) std.Io {
            _ = self;
            return testing.io;
        }
    };
    var host = Host{ .allocator = testing.allocator };
    var report = try check(&host, .{
        .proc_root = proc_root,
        .modules_root = modules_root,
        // Report mode must not spawn the restart command.
        .systemctl_path = "/definitely/missing/systemctl",
        .policy = .report,
    });
    defer report.deinit();
    try testing.expectEqual(contract.RestartPolicy.report, report.policy);
    try testing.expectEqual(@as(usize, 1), report.affected_services.len);
    try testing.expectEqualStrings("demo.service", report.affected_services[0]);
    try testing.expectEqual(@as(usize, 0), report.restarted_services.len);
    try testing.expectEqual(@as(usize, 0), report.skipped_services.len);
    try testing.expectEqual(@as(usize, 0), report.failures.len);
}
