const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract.zig");
const RestartCheckOptions = contract.RestartCheckOptions;
const RestartReport = contract.RestartReport;
const AffectedProcess = contract.AffectedProcess;
const ServiceRestartFailure = contract.ServiceRestartFailure;
const ServiceRestartFailureKind = contract.ServiceRestartFailureKind;
pub fn check(self: anytype, options: RestartCheckOptions) error{OutOfMemory}!RestartReport {
    if (builtin.os.tag != .linux) return RestartReport.empty(self.allocator);

    var running_kernel: ?[]u8 = null;
    errdefer if (running_kernel) |kernel| self.allocator.free(kernel);
    var running_kernel_modules_present: ?bool = null;
    var needs_reboot = false;
    var process_scan_complete = true;
    var skipped_processes: usize = 0;

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

    if (std.Io.Dir.cwd().readFileAlloc(
        self.io(),
        osrelease_path,
        self.allocator,
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
            .process_scan_complete = process_scan_complete,
            .skipped_processes = skipped_processes,
            .affected_processes = &.{},
            .affected_services = &.{},
            .restarted_services = &.{},
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
        const maps = std.Io.Dir.cwd().readFileAlloc(
            self.io(),
            maps_path,
            self.allocator,
            .limited(16 * 1024 * 1024),
        ) catch {
            skipped_processes += 1;
            continue;
        };
        defer self.allocator.free(maps);
        if (!hasDeletedSharedLibrary(maps)) continue;

        var command: ?[]u8 = null;
        const comm_path = std.fs.path.join(
            self.allocator,
            &.{ options.proc_root, entry.name, "comm" },
        ) catch return error.OutOfMemory;
        defer self.allocator.free(comm_path);
        if (std.Io.Dir.cwd().readFileAlloc(
            self.io(),
            comm_path,
            self.allocator,
            .limited(4096),
        )) |comm_contents| {
            defer self.allocator.free(comm_contents);
            const comm = std.mem.trim(u8, comm_contents, " \t\r\n");
            if (comm.len != 0) {
                command = self.allocator.dupe(u8, comm) catch return error.OutOfMemory;
                if (isCriticalRestartProcess(comm)) needs_reboot = true;
            }
        } else |_| {}

        var service: ?[]u8 = null;
        const cgroup_path = std.fs.path.join(
            self.allocator,
            &.{ options.proc_root, entry.name, "cgroup" },
        ) catch {
            if (command) |owned| self.allocator.free(owned);
            return error.OutOfMemory;
        };
        defer self.allocator.free(cgroup_path);
        if (std.Io.Dir.cwd().readFileAlloc(
            self.io(),
            cgroup_path,
            self.allocator,
            .limited(1024 * 1024),
        )) |cgroup| {
            defer self.allocator.free(cgroup);
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

    if (options.restart_services and !needs_reboot) {
        for (affected_services.items) |service| {
            const result = std.process.run(self.allocator, self.io(), .{
                .argv = &.{ options.systemctl_path, "restart", service },
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
        .process_scan_complete = process_scan_complete,
        .skipped_processes = skipped_processes,
        .affected_processes = process_slice,
        .affected_services = affected_service_slice,
        .restarted_services = restarted_service_slice,
        .failures = failure_slice,
    };
}
fn hasDeletedSharedLibrary(maps: []const u8) bool {
    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "(deleted)") != null and
            std.mem.indexOf(u8, line, ".so") != null)
        {
            return true;
        }
    }
    return false;
}
fn serviceFromCgroup(cgroup: []const u8) ?[]const u8 {
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
fn isCriticalRestartProcess(command: []const u8) bool {
    return std.mem.eql(u8, command, "systemd") or
        std.mem.eql(u8, command, "dbus-daemon") or
        std.mem.eql(u8, command, "dbus-broker");
}
fn stringBefore(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}
