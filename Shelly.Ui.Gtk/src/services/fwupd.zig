//! fwupd D-Bus client service: connection lifecycle, handshake, method wrappers,
//! signal dispatch and the `Backend` vtable the Firmware page depends on.
//!
//! Threading contract: method wrappers are synchronous and run on worker
//! threads; `subscribeSignals`/`unsubscribeSignals` run on the main thread and
//! signal callbacks are delivered on the main loop. The GDBus system-bus
//! singleton is shared process-wide and thread-safe; lazy connection init uses
//! an atomic pointer because load and badge workers may overlap.
//!
//! Transient daemon: `Status == shutdown` is not an error; it clears `connected`.
//! A later `Changed` signal also clears it and the page reconnects (calls
//! auto-activate the daemon via D-Bus activation).
//!
//! Signal callbacks receive arena-owned structs that are freed right after the
//! callback returns; copy anything that must outlive the dispatch.

const std = @import("std");
const diagnostics = @import("diagnostics");
const bindings = @import("Shelly_Ui_Gtk");
const gio = bindings.gio;
const glib = bindings.glib;
const models = @import("../models/fwupd.zig");
const enums = @import("fwupd_enums.zig");

const log = std.log.scoped(.fwupd);

const FWUPD_NAME: [:0]const u8 = "org.freedesktop.fwupd";
const FWUPD_PATH: [:0]const u8 = "/";
const FWUPD_IFACE: [:0]const u8 = "org.freedesktop.fwupd";
const PROPS_IFACE: [:0]const u8 = "org.freedesktop.DBus.Properties";
const ERROR_PREFIX = "org.freedesktop.fwupd.";

pub const get_timeout_ms: c_int = 25_000;
pub const install_timeout_ms: c_int = 600_000;
pub const metadata_timeout_ms: c_int = 60_000;

/// A failed D-Bus call: fwupd error kind plus the raw daemon message.
/// `message` slices into client-owned storage, valid until the next failure.
pub const Failure = struct {
    kind: enums.Error,
    message: []const u8,
};

pub const Error = std.mem.Allocator.Error || error{
    BusUnavailable,
    CallFailed,
    InvalidReply,
    FileOpenFailed,
    FdAppendFailed,
};

/// Install options dict (`a{sv}`), fwupd 2.x: `reason` and `filename` are always
/// sent; the allow-* booleans only when true. No `offline`, no `ignore-power`.
pub const InstallOptions = struct {
    allow_older: bool = false,
    allow_reinstall: bool = false,
    allow_branch_switch: bool = false,
};

/// Options per release classification: downgrades need `allow-older`,
/// reinstalls `allow-reinstall`; the branch-switch flag is added only after the
/// user accepts the branch warning.
pub fn optionsForAction(classification: models.Classification, branch_switch: bool) InstallOptions {
    return .{
        .allow_older = classification == .downgrade,
        .allow_reinstall = classification == .reinstall,
        .allow_branch_switch = branch_switch,
    };
}

/// Main-loop signal callbacks. Structs passed to callbacks are only valid for
/// the duration of the call (see module comment).
pub const SignalCallbacks = struct {
    user_data: ?*anyopaque = null,
    on_device_added: ?*const fn (user_data: ?*anyopaque, device: models.Device) void = null,
    on_device_changed: ?*const fn (user_data: ?*anyopaque, device: models.Device) void = null,
    on_device_removed: ?*const fn (user_data: ?*anyopaque, device_id: []const u8) void = null,
    on_device_request: ?*const fn (user_data: ?*anyopaque, request: models.Request) void = null,
    on_changed: ?*const fn (user_data: ?*anyopaque) void = null,
    on_properties_changed: ?*const fn (user_data: ?*anyopaque, props: models.DaemonProps) void = null,
};

pub const Client = struct {
    connection: std.atomic.Value(?*gio.DBusConnection) = .init(null),
    connected: bool = false,
    props: models.DaemonProps = .{},
    version_buf: [64]u8 = undefined,
    has_failure: bool = false,
    failure_kind: enums.Error = .unknown,
    failure_buf: [512]u8 = undefined,
    failure_len: usize = 0,
    callbacks: SignalCallbacks = .{},
    subscribed: bool = false,
    subscription_ids: [6]c_uint = @splat(0),
    signal_arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator),

    pub fn deinit(self: *Client) void {
        self.unsubscribeSignals();
        if (self.connection.swap(null, .acq_rel)) |c| c.unref();
        self.signal_arena.deinit();
    }

    /// GDBus hands out the same system-bus singleton with a ref per call, so a
    /// losing racer just drops its extra reference; no lock needed.
    fn ensureConnection(self: *Client) ?*gio.DBusConnection {
        if (self.connection.load(.acquire)) |c| return c;
        var err: ?*glib.Error = null;
        const conn = gio.busGetSync(.system, null, &err);
        if (err) |e| {
            log.warn("Could not connect to the system bus. {0f}", .{diagnostics.safe(e.f_message orelse "unknown")});
            glib.Error.free(e);
            return null;
        }
        if (self.connection.cmpxchgStrong(null, conn, .acq_rel, .acquire)) |existing| {
            conn.?.unref();
            return existing;
        }
        return conn;
    }

    fn recordFailure(self: *Client, kind: enums.Error, message: []const u8) void {
        self.failure_kind = kind;
        const n = @min(message.len, self.failure_buf.len);
        @memcpy(self.failure_buf[0..n], message[0..n]);
        self.failure_len = n;
        self.has_failure = true;
    }

    fn recordGError(self: *Client, err: *const glib.Error) void {
        const message = if (err.f_message) |m| std.mem.span(m) else "unknown";
        self.recordFailure(errorKindFromGError(err), message);
    }

    pub fn lastFailure(self: *const Client) ?Failure {
        if (!self.has_failure) return null;
        return .{ .kind = self.failure_kind, .message = self.failure_buf[0..self.failure_len] };
    }

    /// Synchronous fwupd method call on the worker thread. Consumes the floating
    /// `params` reference; the caller unrefs the returned reply.
    fn call(
        self: *Client,
        method: enums.Method,
        params: ?*glib.Variant,
        reply_type: [:0]const u8,
        timeout_ms: c_int,
    ) Error!*glib.Variant {
        const conn = self.ensureConnection() orelse return error.BusUnavailable;
        const rt = glib.VariantType.new(reply_type);
        defer rt.free();
        var err: ?*glib.Error = null;
        const reply = conn.callSync(FWUPD_NAME, FWUPD_PATH, FWUPD_IFACE, method.wireName(), params, rt, .{}, timeout_ms, null, &err);
        if (err) |e| {
            self.recordGError(e);
            glib.Error.free(e);
            return error.CallFailed;
        }
        return reply orelse error.InvalidReply;
    }

    fn storeVersion(self: *Client, version: []const u8) void {
        const n = @min(version.len, self.version_buf.len);
        @memcpy(self.version_buf[0..n], version[0..n]);
        self.props.daemon_version = self.version_buf[0..n];
    }

    /// Handshake: cache daemon properties, set hints, advertise feature flags
    /// (before any device scan). Runs on the worker thread.
    pub fn connect(self: *Client, alloc: std.mem.Allocator) Error!models.DaemonProps {
        const conn = self.ensureConnection() orelse return error.BusUnavailable;

        const params = glib.Variant.new("(s)", FWUPD_IFACE.ptr);
        const rt = glib.VariantType.new("(a{sv})");
        defer rt.free();
        var err: ?*glib.Error = null;
        const reply = conn.callSync(FWUPD_NAME, FWUPD_PATH, PROPS_IFACE, "GetAll", params, rt, .{}, get_timeout_ms, null, &err);
        if (err) |e| {
            self.recordGError(e);
            glib.Error.free(e);
            return error.CallFailed;
        }
        const res = reply orelse return error.InvalidReply;
        defer res.unref();
        const dict = res.getChildValue(0);
        defer dict.unref();
        const parsed = try models.parseDaemonProps(alloc, dict);
        self.props = parsed;
        self.storeVersion(parsed.daemon_version);
        self.connected = self.props.status != .shutdown;

        const hints_reply = try self.call(.set_hints, buildHintsParams(), "()", get_timeout_ms);
        hints_reply.unref();
        const flags_reply = try self.call(.set_feature_flags, featureFlagsParams(), "()", get_timeout_ms);
        flags_reply.unref();

        return self.props;
    }

    pub fn getDevices(self: *Client, alloc: std.mem.Allocator) Error![]const models.Device {
        const reply = try self.call(.get_devices, null, "(aa{sv})", get_timeout_ms);
        defer reply.unref();
        const array = reply.getChildValue(0);
        defer array.unref();
        return parseDeviceList(alloc, array);
    }

    pub fn getUpgrades(self: *Client, alloc: std.mem.Allocator, device_id: []const u8) Error![]const models.Release {
        return self.deviceReleases(alloc, .get_upgrades, device_id);
    }

    pub fn getReleases(self: *Client, alloc: std.mem.Allocator, device_id: []const u8) Error![]const models.Release {
        return self.deviceReleases(alloc, .get_releases, device_id);
    }

    /// `NothingToDo`/`NotSupported` mean an empty list (e.g. empty silo), not a
    /// failure; every other error propagates with `lastFailure()` set.
    fn deviceReleases(self: *Client, alloc: std.mem.Allocator, method: enums.Method, device_id: []const u8) Error![]const models.Release {
        const id_z = try alloc.dupeSentinel(u8, device_id, 0);
        const reply = self.call(method, glib.Variant.new("(s)", id_z.ptr), "(aa{sv})", get_timeout_ms) catch |err| {
            if (err == error.CallFailed and
                (self.failure_kind == .nothing_to_do or self.failure_kind == .not_supported))
            {
                return &.{};
            }
            return err;
        };
        defer reply.unref();
        const array = reply.getChildValue(0);
        defer array.unref();
        return parseArray(models.Release, models.parseRelease, alloc, array);
    }

    pub fn getRemotes(self: *Client, alloc: std.mem.Allocator) Error![]const models.Remote {
        const reply = try self.call(.get_remotes, null, "(aa{sv})", get_timeout_ms);
        defer reply.unref();
        const array = reply.getChildValue(0);
        defer array.unref();
        return parseArray(models.Remote, models.parseRemote, alloc, array);
    }

    /// `Install(s h a{sv})`: the payload fd is passed by list index (the daemon
    /// reads index 0 and requires exactly one fd). `payload_path` is resolved to
    /// an absolute path for the options dict. Runs on the worker thread.
    pub fn install(
        self: *Client,
        alloc: std.mem.Allocator,
        device_id: []const u8,
        payload_path: []const u8,
        options: InstallOptions,
    ) Error!void {
        const absolute = try std.fs.path.resolve(alloc, &.{payload_path});
        const absolute_z = try alloc.dupeSentinel(u8, absolute, 0);
        const fd = std.posix.openatZ(std.posix.AT.FDCWD, absolute_z, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileOpenFailed;
        defer _ = std.os.linux.close(fd);

        const list = gio.UnixFDList.new();
        defer list.unref();
        const index = try self.appendFd(list, fd);

        const id_z = try alloc.dupeSentinel(u8, device_id, 0);
        const options_v = buildInstallOptions(absolute_z, options);
        // Bare 'h' consumes an i32 list index (not newHandle, which is for '@h').
        const params = glib.Variant.new("(sh@a{sv})", id_z.ptr, index, options_v);
        try self.sendFdCall(.install, params, list, install_timeout_ms);
    }

    /// `UpdateMetadata(s h h)`: exactly two fds, index 0 = metadata, 1 = signature.
    pub fn updateMetadata(
        self: *Client,
        alloc: std.mem.Allocator,
        remote_id: []const u8,
        data_path: []const u8,
        signature_path: []const u8,
    ) Error!void {
        const data_z = try alloc.dupeSentinel(u8, data_path, 0);
        const sig_z = try alloc.dupeSentinel(u8, signature_path, 0);
        const data_fd = std.posix.openatZ(std.posix.AT.FDCWD, data_z, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileOpenFailed;
        defer _ = std.os.linux.close(data_fd);
        const sig_fd = std.posix.openatZ(std.posix.AT.FDCWD, sig_z, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileOpenFailed;
        defer _ = std.os.linux.close(sig_fd);

        const list = gio.UnixFDList.new();
        defer list.unref();
        const data_index = try self.appendFd(list, data_fd);
        const sig_index = try self.appendFd(list, sig_fd);

        const id_z = try alloc.dupeSentinel(u8, remote_id, 0);
        const params = glib.Variant.new("(shh)", id_z.ptr, data_index, sig_index);
        try self.sendFdCall(.update_metadata, params, list, metadata_timeout_ms);
    }

    /// `append` dups the fd and can fail (fd limits); the caller keeps and closes
    /// its own descriptor.
    fn appendFd(self: *Client, list: *gio.UnixFDList, fd: std.posix.fd_t) Error!c_int {
        var err: ?*glib.Error = null;
        const index = list.append(fd, &err);
        if (err) |e| {
            self.recordGError(e);
            glib.Error.free(e);
            return error.FdAppendFailed;
        }
        if (index < 0) return error.FdAppendFailed;
        return index;
    }

    fn sendFdCall(self: *Client, method: enums.Method, params: *glib.Variant, list: *gio.UnixFDList, timeout_ms: c_int) Error!void {
        const conn = self.ensureConnection() orelse return error.BusUnavailable;
        const rt = glib.VariantType.new("()");
        defer rt.free();
        var out_list: ?*gio.UnixFDList = null;
        var err: ?*glib.Error = null;
        const reply = conn.callWithUnixFdListSync(
            FWUPD_NAME,
            FWUPD_PATH,
            FWUPD_IFACE,
            method.wireName(),
            params,
            rt,
            .{},
            timeout_ms,
            list,
            // The binding declares ?**UnixFDList, but GDBus stores NULL when the
            // reply carries no fds (Install/UpdateMetadata replies are empty).
            @ptrCast(&out_list),
            null,
            &err,
        );
        if (out_list) |l| l.unref();
        if (err) |e| {
            self.recordGError(e);
            glib.Error.free(e);
            return error.CallFailed;
        }
        if (reply) |r| r.unref();
    }

    /// Subscribe on the main thread after the first successful connect; once per
    /// page lifetime. While an install is in flight the page defers
    /// `unsubscribeSignals` until it finishes.
    pub fn subscribeSignals(self: *Client, callbacks: SignalCallbacks) void {
        if (self.subscribed) return;
        const conn = self.ensureConnection() orelse return;
        self.callbacks = callbacks;
        const members = [_][:0]const u8{ "DeviceAdded", "DeviceChanged", "DeviceRemoved", "DeviceRequest", "Changed" };
        inline for (members, 0..) |member, i| {
            self.subscription_ids[i] = conn.signalSubscribe(
                FWUPD_NAME,
                FWUPD_IFACE,
                member,
                FWUPD_PATH,
                null,
                .{},
                &onSignal,
                self,
                null,
            );
        }
        self.subscription_ids[5] = conn.signalSubscribe(
            FWUPD_NAME,
            PROPS_IFACE,
            "PropertiesChanged",
            FWUPD_PATH,
            FWUPD_IFACE,
            .{},
            &onSignal,
            self,
            null,
        );
        self.subscribed = true;
    }

    pub fn unsubscribeSignals(self: *Client) void {
        if (!self.subscribed) return;
        if (self.connection.load(.acquire)) |conn| {
            for (self.subscription_ids) |id| {
                if (id != 0) conn.signalUnsubscribe(id);
            }
        }
        self.subscription_ids = @splat(0);
        self.subscribed = false;
    }

    fn onSignal(
        _: *gio.DBusConnection,
        _: ?[*:0]const u8,
        _: [*:0]const u8,
        _: [*:0]const u8,
        member: [*:0]const u8,
        params: *glib.Variant,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Client = @ptrCast(@alignCast(user_data.?));
        self.dispatch(std.mem.span(member), params);
    }

    /// Main-loop signal handling, split from the C trampoline so tests can drive
    /// it without a bus connection.
    fn dispatch(self: *Client, member: []const u8, params: *glib.Variant) void {
        const alloc = self.signal_arena.allocator();
        defer _ = self.signal_arena.reset(.retain_capacity);
        const cb = self.callbacks;

        if (std.mem.eql(u8, member, "Changed")) {
            // Transient daemon went away (or finished a job): full reconnect.
            self.connected = false;
            if (cb.on_changed) |f| f(cb.user_data);
            return;
        }
        if (std.mem.eql(u8, member, "PropertiesChanged")) {
            const dict = params.getChildValue(1);
            defer dict.unref();
            self.mergeProps(dict);
            if (cb.on_properties_changed) |f| f(cb.user_data, self.props);
            return;
        }

        const dict = params.getChildValue(0);
        defer dict.unref();
        if (std.mem.eql(u8, member, "DeviceRequest")) {
            const request = models.parseRequest(alloc, dict) catch |err| {
                log.warn("Could not parse DeviceRequest: {s}", .{@errorName(err)});
                return;
            };
            if (cb.on_device_request) |f| f(cb.user_data, request);
            return;
        }
        if (std.mem.eql(u8, member, "DeviceAdded") or
            std.mem.eql(u8, member, "DeviceChanged") or
            std.mem.eql(u8, member, "DeviceRemoved"))
        {
            const device = models.parseDevice(alloc, dict) catch |err| {
                log.warn("Could not parse {s} device: {s}", .{ member, @errorName(err) });
                return;
            };
            if (std.mem.eql(u8, member, "DeviceAdded")) {
                if (cb.on_device_added) |f| f(cb.user_data, device);
            } else if (std.mem.eql(u8, member, "DeviceChanged")) {
                // Dedupe against the page store happens in the callback.
                if (cb.on_device_changed) |f| f(cb.user_data, device);
            } else {
                if (cb.on_device_removed) |f| f(cb.user_data, device.device_id);
            }
            return;
        }
        log.debug("Ignoring unknown fwupd signal '{f}'", .{diagnostics.safe(member)});
    }

    /// Merge a `PropertiesChanged` dict into the cache; only present keys change.
    fn mergeProps(self: *Client, dict: *glib.Variant) void {
        const vd = glib.VariantDict.new(dict);
        defer vd.unref();
        if (lookupTyped(vd, "DaemonVersion", "s")) |v| {
            defer v.unref();
            var len: usize = 0;
            const s = v.getString(&len);
            self.storeVersion(s[0..len]);
        }
        if (lookupTyped(vd, "Status", "u")) |v| {
            defer v.unref();
            self.props.status = enums.Status.decode(v.getUint32());
            self.connected = self.props.status != .shutdown;
        }
        if (lookupTyped(vd, "Percentage", "u")) |v| {
            defer v.unref();
            self.props.percentage = v.getUint32();
        }
        if (lookupTyped(vd, "PercentageFull", "d")) |v| {
            defer v.unref();
            self.props.percentage_full = v.getDouble();
        }
        if (lookupTyped(vd, "BatteryLevel", "u")) |v| {
            defer v.unref();
            self.props.battery_level = v.getUint32();
        }
        if (lookupTyped(vd, "BatteryThreshold", "u")) |v| {
            defer v.unref();
            self.props.battery_threshold = v.getUint32();
        }
        if (lookupTyped(vd, "OnlyTrusted", "b")) |v| {
            defer v.unref();
            self.props.only_trusted = v.getBoolean() != 0;
        }
    }

    pub fn backend(self: *Client) Backend {
        return .{ .ctx = self, .vtable = &client_vtable };
    }

    fn asClient(ctx: *anyopaque) *Client {
        return @ptrCast(@alignCast(ctx));
    }

    const client_vtable: Backend.VTable = .{
        .connect = struct {
            fn f(ctx: *anyopaque, alloc: std.mem.Allocator) Error!models.DaemonProps {
                return asClient(ctx).connect(alloc);
            }
        }.f,
        .getDevices = struct {
            fn f(ctx: *anyopaque, alloc: std.mem.Allocator) Error![]const models.Device {
                return asClient(ctx).getDevices(alloc);
            }
        }.f,
        .getUpgrades = struct {
            fn f(ctx: *anyopaque, alloc: std.mem.Allocator, device_id: []const u8) Error![]const models.Release {
                return asClient(ctx).getUpgrades(alloc, device_id);
            }
        }.f,
        .getReleases = struct {
            fn f(ctx: *anyopaque, alloc: std.mem.Allocator, device_id: []const u8) Error![]const models.Release {
                return asClient(ctx).getReleases(alloc, device_id);
            }
        }.f,
        .getRemotes = struct {
            fn f(ctx: *anyopaque, alloc: std.mem.Allocator) Error![]const models.Remote {
                return asClient(ctx).getRemotes(alloc);
            }
        }.f,
        .install = struct {
            fn f(ctx: *anyopaque, alloc: std.mem.Allocator, device_id: []const u8, payload_path: []const u8, options: InstallOptions) Error!void {
                return asClient(ctx).install(alloc, device_id, payload_path, options);
            }
        }.f,
        .updateMetadata = struct {
            fn f(ctx: *anyopaque, alloc: std.mem.Allocator, remote_id: []const u8, data_path: []const u8, signature_path: []const u8) Error!void {
                return asClient(ctx).updateMetadata(alloc, remote_id, data_path, signature_path);
            }
        }.f,
        .subscribeSignals = struct {
            fn f(ctx: *anyopaque, callbacks: SignalCallbacks) void {
                asClient(ctx).subscribeSignals(callbacks);
            }
        }.f,
        .unsubscribeSignals = struct {
            fn f(ctx: *anyopaque) void {
                asClient(ctx).unsubscribeSignals();
            }
        }.f,
        .props = struct {
            fn f(ctx: *anyopaque) models.DaemonProps {
                return asClient(ctx).props;
            }
        }.f,
        .lastFailure = struct {
            fn f(ctx: *anyopaque) ?Failure {
                return asClient(ctx).lastFailure();
            }
        }.f,
    };
};

// ---------------------------------------------------------------------------
// Backend interface
// ---------------------------------------------------------------------------

pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        connect: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator) Error!models.DaemonProps,
        getDevices: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator) Error![]const models.Device,
        getUpgrades: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, device_id: []const u8) Error![]const models.Release,
        getReleases: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, device_id: []const u8) Error![]const models.Release,
        getRemotes: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator) Error![]const models.Remote,
        install: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, device_id: []const u8, payload_path: []const u8, options: InstallOptions) Error!void,
        updateMetadata: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, remote_id: []const u8, data_path: []const u8, signature_path: []const u8) Error!void,
        subscribeSignals: *const fn (ctx: *anyopaque, callbacks: SignalCallbacks) void,
        unsubscribeSignals: *const fn (ctx: *anyopaque) void,
        props: *const fn (ctx: *anyopaque) models.DaemonProps,
        lastFailure: *const fn (ctx: *anyopaque) ?Failure,
    };

    pub fn connect(self: Backend, alloc: std.mem.Allocator) Error!models.DaemonProps {
        return self.vtable.connect(self.ctx, alloc);
    }
    pub fn getDevices(self: Backend, alloc: std.mem.Allocator) Error![]const models.Device {
        return self.vtable.getDevices(self.ctx, alloc);
    }
    pub fn getUpgrades(self: Backend, alloc: std.mem.Allocator, device_id: []const u8) Error![]const models.Release {
        return self.vtable.getUpgrades(self.ctx, alloc, device_id);
    }
    pub fn getReleases(self: Backend, alloc: std.mem.Allocator, device_id: []const u8) Error![]const models.Release {
        return self.vtable.getReleases(self.ctx, alloc, device_id);
    }
    pub fn getRemotes(self: Backend, alloc: std.mem.Allocator) Error![]const models.Remote {
        return self.vtable.getRemotes(self.ctx, alloc);
    }
    pub fn install(self: Backend, alloc: std.mem.Allocator, device_id: []const u8, payload_path: []const u8, options: InstallOptions) Error!void {
        return self.vtable.install(self.ctx, alloc, device_id, payload_path, options);
    }
    pub fn updateMetadata(self: Backend, alloc: std.mem.Allocator, remote_id: []const u8, data_path: []const u8, signature_path: []const u8) Error!void {
        return self.vtable.updateMetadata(self.ctx, alloc, remote_id, data_path, signature_path);
    }
    pub fn subscribeSignals(self: Backend, callbacks: SignalCallbacks) void {
        self.vtable.subscribeSignals(self.ctx, callbacks);
    }
    pub fn unsubscribeSignals(self: Backend) void {
        self.vtable.unsubscribeSignals(self.ctx);
    }
    pub fn props(self: Backend) models.DaemonProps {
        return self.vtable.props(self.ctx);
    }
    pub fn lastFailure(self: Backend) ?Failure {
        return self.vtable.lastFailure(self.ctx);
    }
};

/// Canned-data backend for page/flow tests: injectable errors,
/// recorded install calls and direct signal emission.
pub const FakeBackend = struct {
    devices: []const models.Device = &.{},
    upgrades: []const models.Release = &.{},
    releases: []const models.Release = &.{},
    remotes: []const models.Remote = &.{},
    daemon_props: models.DaemonProps = .{},
    connect_error: ?enums.Error = null,
    upgrades_error: ?enums.Error = null,
    releases_error: ?enums.Error = null,
    remotes_error: ?enums.Error = null,
    install_error: ?enums.Error = null,
    metadata_error: ?enums.Error = null,
    install_calls: [8]InstallCall = undefined,
    install_call_count: usize = 0,
    metadata_calls: [8]MetadataCall = undefined,
    metadata_call_count: usize = 0,
    callbacks: SignalCallbacks = .{},
    failure: ?Failure = null,

    pub const InstallCall = struct {
        device_id: []const u8,
        payload_path: []const u8,
        options: InstallOptions,
    };

    pub const MetadataCall = struct {
        remote_id: []const u8,
        data_path: []const u8,
        signature_path: []const u8,
    };

    pub fn backend(self: *FakeBackend) Backend {
        return .{ .ctx = self, .vtable = &fake_vtable };
    }

    fn asFake(ctx: *anyopaque) *FakeBackend {
        return @ptrCast(@alignCast(ctx));
    }

    fn fail(self: *FakeBackend, kind: enums.Error) Error {
        self.failure = .{ .kind = kind, .message = kind.wireName() orelse "unknown" };
        return error.CallFailed;
    }

    fn releasesOrEmpty(self: *FakeBackend, kind: ?enums.Error, canned: []const models.Release) Error![]const models.Release {
        if (kind) |k| {
            if (k == .nothing_to_do or k == .not_supported) return &.{};
            return self.fail(k);
        }
        return canned;
    }

    pub fn emitDeviceAdded(self: *FakeBackend, device: models.Device) void {
        if (self.callbacks.on_device_added) |f| f(self.callbacks.user_data, device);
    }
    pub fn emitDeviceChanged(self: *FakeBackend, device: models.Device) void {
        if (self.callbacks.on_device_changed) |f| f(self.callbacks.user_data, device);
    }
    pub fn emitDeviceRemoved(self: *FakeBackend, device_id: []const u8) void {
        if (self.callbacks.on_device_removed) |f| f(self.callbacks.user_data, device_id);
    }
    pub fn emitDeviceRequest(self: *FakeBackend, request: models.Request) void {
        if (self.callbacks.on_device_request) |f| f(self.callbacks.user_data, request);
    }
    pub fn emitChanged(self: *FakeBackend) void {
        if (self.callbacks.on_changed) |f| f(self.callbacks.user_data);
    }
    pub fn emitPropertiesChanged(self: *FakeBackend, new_props: models.DaemonProps) void {
        self.daemon_props = new_props;
        if (self.callbacks.on_properties_changed) |f| f(self.callbacks.user_data, new_props);
    }

    const fake_vtable: Backend.VTable = .{
        .connect = struct {
            fn f(ctx: *anyopaque, _: std.mem.Allocator) Error!models.DaemonProps {
                const self = asFake(ctx);
                if (self.connect_error) |k| return self.fail(k);
                return self.daemon_props;
            }
        }.f,
        .getDevices = struct {
            fn f(ctx: *anyopaque, _: std.mem.Allocator) Error![]const models.Device {
                return asFake(ctx).devices;
            }
        }.f,
        .getUpgrades = struct {
            fn f(ctx: *anyopaque, _: std.mem.Allocator, _: []const u8) Error![]const models.Release {
                const self = asFake(ctx);
                return self.releasesOrEmpty(self.upgrades_error, self.upgrades);
            }
        }.f,
        .getReleases = struct {
            fn f(ctx: *anyopaque, _: std.mem.Allocator, _: []const u8) Error![]const models.Release {
                const self = asFake(ctx);
                return self.releasesOrEmpty(self.releases_error, self.releases);
            }
        }.f,
        .getRemotes = struct {
            fn f(ctx: *anyopaque, _: std.mem.Allocator) Error![]const models.Remote {
                const self = asFake(ctx);
                if (self.remotes_error) |k| return self.fail(k);
                return self.remotes;
            }
        }.f,
        .install = struct {
            fn f(ctx: *anyopaque, _: std.mem.Allocator, device_id: []const u8, payload_path: []const u8, options: InstallOptions) Error!void {
                const self = asFake(ctx);
                if (self.install_error) |k| return self.fail(k);
                if (self.install_call_count < self.install_calls.len) {
                    self.install_calls[self.install_call_count] = .{
                        .device_id = device_id,
                        .payload_path = payload_path,
                        .options = options,
                    };
                }
                self.install_call_count += 1;
            }
        }.f,
        .updateMetadata = struct {
            fn f(ctx: *anyopaque, _: std.mem.Allocator, remote_id: []const u8, data_path: []const u8, signature_path: []const u8) Error!void {
                const self = asFake(ctx);
                if (self.metadata_error) |k| return self.fail(k);
                if (self.metadata_call_count < self.metadata_calls.len) {
                    self.metadata_calls[self.metadata_call_count] = .{
                        .remote_id = remote_id,
                        .data_path = data_path,
                        .signature_path = signature_path,
                    };
                }
                self.metadata_call_count += 1;
            }
        }.f,
        .subscribeSignals = struct {
            fn f(ctx: *anyopaque, callbacks: SignalCallbacks) void {
                asFake(ctx).callbacks = callbacks;
            }
        }.f,
        .unsubscribeSignals = struct {
            fn f(ctx: *anyopaque) void {
                asFake(ctx).callbacks = .{};
            }
        }.f,
        .props = struct {
            fn f(ctx: *anyopaque) models.DaemonProps {
                return asFake(ctx).daemon_props;
            }
        }.f,
        .lastFailure = struct {
            fn f(ctx: *anyopaque) ?Failure {
                return asFake(ctx).failure;
            }
        }.f,
    };
};

// ---------------------------------------------------------------------------
// Variant construction and parsing helpers
// ---------------------------------------------------------------------------

fn featureFlagsParams() *glib.Variant {
    return glib.Variant.new("(t)", enums.FeatureFlags.client);
}

fn buildHintsParams() *glib.Variant {
    const vt = glib.VariantType.new("a{ss}");
    defer vt.free();
    var builder = glib.VariantBuilder.new(vt);
    if (std.c.getenv("LANG")) |lang_z| {
        if (std.mem.span(lang_z).len > 0) builder.add("{ss}", "locale", lang_z);
    }
    return glib.Variant.new("(@a{ss})", builder.end());
}

/// `reason="user-action"` and an absolute `filename` always; allow-* booleans
/// only when true (libfwupd 2.1.9 semantics).
fn buildInstallOptions(filename_z: [:0]const u8, options: InstallOptions) *glib.Variant {
    const vt = glib.VariantType.new("a{sv}");
    defer vt.free();
    var builder = glib.VariantBuilder.new(vt);
    builder.add("{sv}", "reason", glib.Variant.new("s", "user-action"));
    builder.add("{sv}", "filename", glib.Variant.new("s", filename_z.ptr));
    if (options.allow_older) builder.add("{sv}", "allow-older", glib.Variant.newBoolean(1));
    if (options.allow_reinstall) builder.add("{sv}", "allow-reinstall", glib.Variant.newBoolean(1));
    if (options.allow_branch_switch) builder.add("{sv}", "allow-branch-switch", glib.Variant.newBoolean(1));
    return builder.end();
}

fn parseArray(
    comptime T: type,
    comptime parseFn: fn (std.mem.Allocator, *glib.Variant) std.mem.Allocator.Error!T,
    alloc: std.mem.Allocator,
    array: *glib.Variant,
) Error![]const T {
    var list: std.ArrayListUnmanaged(T) = .empty;
    var iter: glib.VariantIter = undefined;
    _ = iter.init(array);
    while (iter.nextValue()) |dict| {
        defer dict.unref();
        try list.append(alloc, try parseFn(alloc, dict));
    }
    return list.toOwnedSlice(alloc);
}

/// Device list with the client-side updatable filter (bits 1 and 37).
fn parseDeviceList(alloc: std.mem.Allocator, array: *glib.Variant) Error![]const models.Device {
    const all = try parseArray(models.Device, models.parseDevice, alloc, array);
    var list: std.ArrayListUnmanaged(models.Device) = .empty;
    for (all) |device| {
        if (enums.DeviceFlags.isUpdatable(device.flags)) try list.append(alloc, device);
    }
    return list.toOwnedSlice(alloc);
}

fn lookupTyped(vd: *glib.VariantDict, key: [:0]const u8, expected: []const u8) ?*glib.Variant {
    const v = vd.lookupValue(key, null) orelse return null;
    if (!std.mem.eql(u8, std.mem.span(v.getTypeString()), expected)) {
        v.unref();
        return null;
    }
    return v;
}

// ---------------------------------------------------------------------------
// Error extraction
// ---------------------------------------------------------------------------

/// Map a GError to an fwupd error kind: registered remote name first, then a
/// message scan for the fwupd prefix, then `.internal`.
fn errorKindFromGError(err: *const glib.Error) enums.Error {
    if (gio.DBusError.getRemoteError(err)) |name_z| {
        defer glib.free(@ptrCast(name_z));
        const name = std.mem.span(name_z);
        const bare = if (std.mem.startsWith(u8, name, ERROR_PREFIX)) name[ERROR_PREFIX.len..] else name;
        if (enums.Error.fromName(bare)) |kind| return kind;
    }
    const message = if (err.f_message) |m| std.mem.span(m) else "";
    return errorKindFromMessage(message);
}

fn errorKindFromMessage(message: []const u8) enums.Error {
    var rest = message;
    while (std.mem.indexOf(u8, rest, ERROR_PREFIX)) |i| {
        const start = i + ERROR_PREFIX.len;
        var end = start;
        while (end < rest.len and std.ascii.isAlphanumeric(rest[end])) : (end += 1) {}
        if (enums.Error.fromName(rest[start..end])) |kind| return kind;
        rest = rest[end..];
    }
    return .internal;
}

// ---------------------------------------------------------------------------
// Tests (no display, no daemon)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fixture(comptime type_str: [:0]const u8, text: [:0]const u8) *glib.Variant {
    const vt = glib.VariantType.new(type_str);
    defer vt.free();
    var err: ?*glib.Error = null;
    const v = glib.Variant.parse(vt, text, null, null, &err);
    if (err) |e| {
        std.debug.panic("fwupd service fixture parse failed: {s}", .{std.mem.span(e.f_message orelse "unknown")});
    }
    return v orelse unreachable;
}

test "fwupd client backend vtable wires every method" {
    // Taking the vtable forces analysis of the bus-dependent wrappers (install,
    // updateMetadata, subscriptions) without needing a live daemon.
    var client: Client = .{};
    defer client.deinit();
    const backend = client.backend();
    try testing.expect(@intFromPtr(backend.vtable.connect) != 0);
    try testing.expect(@intFromPtr(backend.vtable.install) != 0);
    try testing.expect(@intFromPtr(backend.vtable.updateMetadata) != 0);
    try testing.expect(@intFromPtr(backend.vtable.subscribeSignals) != 0);
    try testing.expect(backend.lastFailure() == null);
}

test "fwupd service extracts all 22 error kinds from remote GErrors" {
    inline for (std.enums.values(enums.Error)) |kind| {
        if (kind.wireName()) |name| {
            var name_buf: [128]u8 = undefined;
            const full = try std.mem.printSentinel(&name_buf, "{s}{s}", .{ ERROR_PREFIX, name }, 0);
            const err = gio.DBusError.newForDbusError(full.ptr, "daemon says no");
            defer glib.Error.free(err);
            try testing.expectEqual(kind, errorKindFromGError(err));
        }
    }
}

test "fwupd service error extraction falls back to message scan then internal" {
    // Unrecognized remote name: message scan finds no known name either.
    const future = gio.DBusError.newForDbusError("org.freedesktop.fwupd.FutureThing", "brand new error");
    defer glib.Error.free(future);
    try testing.expectEqual(enums.Error.internal, errorKindFromGError(future));

    // Non-DBus GError whose message embeds a known fwupd name.
    const embedded = glib.Error.newLiteral(glib.quarkFromString("shelly-fwupd-test"), 1, "GDBus.Error:org.freedesktop.fwupd.Busy: device is busy");
    defer glib.Error.free(embedded);
    try testing.expectEqual(enums.Error.busy, errorKindFromGError(embedded));

    // Plain error with no fwupd content.
    const plain = glib.Error.newLiteral(glib.quarkFromString("shelly-fwupd-test"), 2, "something broke");
    defer glib.Error.free(plain);
    try testing.expectEqual(enums.Error.internal, errorKindFromGError(plain));

    // Non-fwupd remote errors stay internal.
    const denied = gio.DBusError.newForDbusError("org.freedesktop.DBus.Error.AccessDenied", "rejected");
    defer glib.Error.free(denied);
    try testing.expectEqual(enums.Error.internal, errorKindFromGError(denied));
}

test "fwupd service records failures in client-owned storage" {
    var client: Client = .{};
    defer client.deinit();
    try testing.expect(client.lastFailure() == null);

    const err = gio.DBusError.newForDbusError("org.freedesktop.fwupd.NotSupported", "no components in silo");
    defer glib.Error.free(err);
    client.recordGError(err);
    const failure = client.lastFailure().?;
    try testing.expectEqual(enums.Error.not_supported, failure.kind);
    // Unregistered remote errors carry the GDBus.Error name prefix in the message.
    try testing.expectEqualStrings("GDBus.Error:org.freedesktop.fwupd.NotSupported: no components in silo", failure.message);
}

test "fwupd service feature flags params advertise 0x2BC" {
    const params = featureFlagsParams();
    defer params.unref();
    try testing.expectEqualStrings("(t)", std.mem.span(params.getTypeString()));
    const value = params.getChildValue(0);
    defer value.unref();
    try testing.expectEqual(@as(u64, 0x2BC), value.getUint64());
}

test "fwupd service install options dict carries reason, filename and only requested flags" {
    const minimal = buildInstallOptions("/cache/shelly/fwupd/fw.cab", .{});
    defer minimal.unref();
    const vd = glib.VariantDict.new(minimal);
    defer vd.unref();

    const reason = vd.lookupValue("reason", null).?;
    defer reason.unref();
    var len: usize = 0;
    try testing.expectEqualStrings("user-action", reason.getString(&len)[0..len]);

    const filename = vd.lookupValue("filename", null).?;
    defer filename.unref();
    try testing.expectEqualStrings("/cache/shelly/fwupd/fw.cab", filename.getString(&len)[0..len]);

    try testing.expect(vd.lookupValue("allow-older", null) == null);
    try testing.expect(vd.lookupValue("allow-reinstall", null) == null);
    try testing.expect(vd.lookupValue("allow-branch-switch", null) == null);
    // 2.x has no offline or ignore-power options.
    try testing.expect(vd.lookupValue("offline", null) == null);
    try testing.expect(vd.lookupValue("ignore-power", null) == null);

    const full = buildInstallOptions("/cache/fw.cab", .{
        .allow_older = true,
        .allow_reinstall = true,
        .allow_branch_switch = true,
    });
    defer full.unref();
    const vd2 = glib.VariantDict.new(full);
    defer vd2.unref();
    inline for (.{ "allow-older", "allow-reinstall", "allow-branch-switch" }) |key| {
        const flag = vd2.lookupValue(key, null).?;
        defer flag.unref();
        try testing.expect(flag.getBoolean() != 0);
    }
}

test "fwupd service options per action map classification to allow flags" {
    const upgrade = optionsForAction(.upgrade, false);
    try testing.expect(!upgrade.allow_older);
    try testing.expect(!upgrade.allow_reinstall);
    try testing.expect(!upgrade.allow_branch_switch);

    const downgrade = optionsForAction(.downgrade, false);
    try testing.expect(downgrade.allow_older);
    try testing.expect(!downgrade.allow_reinstall);

    const reinstall = optionsForAction(.reinstall, false);
    try testing.expect(!reinstall.allow_older);
    try testing.expect(reinstall.allow_reinstall);

    const branch = optionsForAction(.upgrade, true);
    try testing.expect(branch.allow_branch_switch);
    try testing.expect(!branch.allow_older);
}

test "fwupd service install params use an fd-list index handle" {
    const options = buildInstallOptions("/cache/fw.cab", .{});
    const params = glib.Variant.new("(sh@a{sv})", "dev1", @as(c_int, 0), options);
    defer params.unref();
    try testing.expectEqualStrings("(sha{sv})", std.mem.span(params.getTypeString()));
    const handle = params.getChildValue(1);
    defer handle.unref();
    try testing.expectEqual(@as(i32, 0), handle.getHandle());
}

test "fwupd service device list parsing filters updatable devices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const array = fixture(
        "aa{sv}",
        "[{'DeviceId': <'a'>, 'Flags': <uint64 2>}," ++
            " {'DeviceId': <'b'>, 'Flags': <uint64 137438953472>}," ++ // 1 << 37
            " {'DeviceId': <'c'>, 'Flags': <uint64 32>}," ++ // supported only
            " {'DeviceId': <'d'>, 'Flags': <uint64 0>}]",
    );
    defer array.unref();
    const devices = try parseDeviceList(arena.allocator(), array);
    try testing.expectEqual(@as(usize, 2), devices.len);
    try testing.expectEqualStrings("a", devices[0].device_id);
    try testing.expectEqualStrings("b", devices[1].device_id);
}

test "fwupd service props merge keeps untouched fields and tracks shutdown" {
    var client: Client = .{};
    defer client.deinit();
    client.props = .{ .daemon_version = "2.1.10", .status = .idle, .percentage = 10, .battery_level = 80 };
    client.connected = true;

    const partial = fixture("a{sv}", "{'Percentage': <uint32 55>, 'PercentageFull': <double 55.5>, 'Status': <uint32 5>}");
    defer partial.unref();
    client.mergeProps(partial);
    try testing.expectEqualStrings("2.1.10", client.props.daemon_version);
    try testing.expectEqual(@as(u32, 55), client.props.percentage);
    try testing.expectEqual(@as(f64, 55.5), client.props.percentage_full);
    try testing.expectEqual(enums.Status.device_write, client.props.status);
    try testing.expectEqual(@as(u32, 80), client.props.battery_level);
    try testing.expect(client.connected);

    const shutdown = fixture("a{sv}", "{'Status': <uint32 13>}");
    defer shutdown.unref();
    client.mergeProps(shutdown);
    try testing.expect(!client.connected);

    const wrong_type = fixture("a{sv}", "{'Percentage': <'nope'>, 'BatteryLevel': <true>}");
    defer wrong_type.unref();
    client.mergeProps(wrong_type);
    try testing.expectEqual(@as(u32, 55), client.props.percentage);
    try testing.expectEqual(@as(u32, 80), client.props.battery_level);
}

const SignalCapture = struct {
    added: usize = 0,
    changed_id: [64]u8 = undefined,
    changed_id_len: usize = 0,
    removed_id: [64]u8 = undefined,
    removed_id_len: usize = 0,
    requests: usize = 0,
    changed: usize = 0,
    props_updates: usize = 0,
    last_percentage: u32 = 0,

    fn callbacks(self: *SignalCapture) SignalCallbacks {
        return .{
            .user_data = self,
            .on_device_added = struct {
                fn f(data: ?*anyopaque, _: models.Device) void {
                    const cap: *SignalCapture = @ptrCast(@alignCast(data.?));
                    cap.added += 1;
                }
            }.f,
            .on_device_changed = struct {
                fn f(data: ?*anyopaque, device: models.Device) void {
                    const cap: *SignalCapture = @ptrCast(@alignCast(data.?));
                    const n = @min(device.device_id.len, cap.changed_id.len);
                    @memcpy(cap.changed_id[0..n], device.device_id[0..n]);
                    cap.changed_id_len = n;
                }
            }.f,
            .on_device_removed = struct {
                fn f(data: ?*anyopaque, device_id: []const u8) void {
                    const cap: *SignalCapture = @ptrCast(@alignCast(data.?));
                    const n = @min(device_id.len, cap.removed_id.len);
                    @memcpy(cap.removed_id[0..n], device_id[0..n]);
                    cap.removed_id_len = n;
                }
            }.f,
            .on_device_request = struct {
                fn f(data: ?*anyopaque, _: models.Request) void {
                    const cap: *SignalCapture = @ptrCast(@alignCast(data.?));
                    cap.requests += 1;
                }
            }.f,
            .on_changed = struct {
                fn f(data: ?*anyopaque) void {
                    const cap: *SignalCapture = @ptrCast(@alignCast(data.?));
                    cap.changed += 1;
                }
            }.f,
            .on_properties_changed = struct {
                fn f(data: ?*anyopaque, props: models.DaemonProps) void {
                    const cap: *SignalCapture = @ptrCast(@alignCast(data.?));
                    cap.props_updates += 1;
                    cap.last_percentage = props.percentage;
                }
            }.f,
        };
    }
};

test "fwupd service signal dispatch parses payloads and drives callbacks" {
    var client: Client = .{};
    defer client.deinit();
    var capture: SignalCapture = .{};
    client.callbacks = capture.callbacks();
    client.connected = true;

    const device = fixture("(a{sv})", "({'DeviceId': <'dev1'>, 'Name': <'Webcam'>, 'Flags': <uint64 2>},)");
    defer device.unref();
    client.dispatch("DeviceAdded", device);
    try testing.expectEqual(@as(usize, 1), capture.added);
    client.dispatch("DeviceChanged", device);
    try testing.expectEqualStrings("dev1", capture.changed_id[0..capture.changed_id_len]);
    client.dispatch("DeviceRemoved", device);
    try testing.expectEqualStrings("dev1", capture.removed_id[0..capture.removed_id_len]);

    const request = fixture("(a{sv})", "({'AppstreamId': <'org.freedesktop.fwupd.request.remove-replug'>, 'RequestKind': <uint32 2>},)");
    defer request.unref();
    client.dispatch("DeviceRequest", request);
    try testing.expectEqual(@as(usize, 1), capture.requests);

    const props = fixture("(sa{sv}as)", "('org.freedesktop.fwupd', {'Percentage': <uint32 42>}, @as [])");
    defer props.unref();
    client.dispatch("PropertiesChanged", props);
    try testing.expectEqual(@as(usize, 1), capture.props_updates);
    try testing.expectEqual(@as(u32, 42), capture.last_percentage);
    try testing.expectEqual(@as(u32, 42), client.props.percentage);

    const empty = fixture("()", "()");
    defer empty.unref();
    client.dispatch("Changed", empty);
    try testing.expectEqual(@as(usize, 1), capture.changed);
    try testing.expect(!client.connected);
}

test "fwupd fake backend serves canned data and injectable errors" {
    var fake: FakeBackend = .{
        .devices = &.{.{ .device_id = "dev1", .name = "System Firmware", .flags = enums.DeviceFlags.updatable }},
        .releases = &.{.{ .version = "1.2.0", .trust_flags = enums.TrustFlags.is_upgrade }},
        .daemon_props = .{ .daemon_version = "2.1.10", .status = .idle },
    };
    const backend = fake.backend();

    const props = try backend.connect(testing.allocator);
    try testing.expectEqualStrings("2.1.10", props.daemon_version);
    const devices = try backend.getDevices(testing.allocator);
    try testing.expectEqual(@as(usize, 1), devices.len);
    try testing.expectEqualStrings("dev1", devices[0].device_id);
    const releases = try backend.getReleases(testing.allocator, "dev1");
    try testing.expectEqual(@as(usize, 1), releases.len);
    try testing.expect(backend.lastFailure() == null);

    // Empty-silo special case: empty list, not an error.
    fake.releases_error = .not_supported;
    try testing.expectEqual(@as(usize, 0), (try backend.getReleases(testing.allocator, "dev1")).len);
    fake.releases_error = .nothing_to_do;
    try testing.expectEqual(@as(usize, 0), (try backend.getUpgrades(testing.allocator, "dev1")).len);

    // Other errors keep the failure inspectable.
    fake.releases_error = .internal;
    try testing.expectError(error.CallFailed, backend.getReleases(testing.allocator, "dev1"));
    try testing.expectEqual(enums.Error.internal, backend.lastFailure().?.kind);
}

test "fwupd fake backend records installs and drives signals" {
    var fake: FakeBackend = .{};
    const backend = fake.backend();
    var capture: SignalCapture = .{};
    backend.subscribeSignals(capture.callbacks());

    try backend.install(testing.allocator, "dev1", "/cache/fw.cab", .{ .allow_older = true });
    try testing.expectEqual(@as(usize, 1), fake.install_call_count);
    try testing.expectEqualStrings("dev1", fake.install_calls[0].device_id);
    try testing.expectEqualStrings("/cache/fw.cab", fake.install_calls[0].payload_path);
    try testing.expect(fake.install_calls[0].options.allow_older);
    try testing.expect(!fake.install_calls[0].options.allow_reinstall);

    fake.install_error = .auth_failed;
    try testing.expectError(error.CallFailed, backend.install(testing.allocator, "dev1", "/cache/fw.cab", .{}));
    try testing.expectEqual(enums.Error.auth_failed, backend.lastFailure().?.kind);

    try backend.updateMetadata(testing.allocator, "lvfs", "/cache/metadata", "/cache/metadata.jcat");
    try testing.expectEqual(@as(usize, 1), fake.metadata_call_count);

    fake.emitDeviceAdded(.{ .device_id = "dev2" });
    try testing.expectEqual(@as(usize, 1), capture.added);
    fake.emitChanged();
    try testing.expectEqual(@as(usize, 1), capture.changed);
    fake.emitPropertiesChanged(.{ .percentage = 90 });
    try testing.expectEqual(@as(u32, 90), capture.last_percentage);
    try testing.expectEqual(@as(u32, 90), backend.props().percentage);

    backend.unsubscribeSignals();
    fake.emitDeviceAdded(.{ .device_id = "dev3" });
    try testing.expectEqual(@as(usize, 1), capture.added);
}

// Manual smoke against the real daemon; skipped unless
// SHELLY_FWUPD_LIVE=1. Read-only: handshake, device list, releases, remotes.
test "fwupd live daemon smoke (SHELLY_FWUPD_LIVE=1)" {
    if (std.c.getenv("SHELLY_FWUPD_LIVE") == null) return error.SkipZigTest;
    var client: Client = .{};
    defer client.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const props = try client.connect(alloc);
    std.debug.print("live: daemon {s}, status {s}, connected {}\n", .{ props.daemon_version, @tagName(props.status), client.connected });
    try testing.expect(props.daemon_version.len > 0);

    const devices = try client.getDevices(alloc);
    std.debug.print("live: {d} updatable devices\n", .{devices.len});
    for (devices) |device| {
        const releases = try client.getReleases(alloc, device.device_id);
        const upgrades = try client.getUpgrades(alloc, device.device_id);
        std.debug.print("live: {s} ({s}) version {s}: {d} releases, {d} upgrades\n", .{ device.name, device.device_id, device.version, releases.len, upgrades.len });
    }

    const remotes = try client.getRemotes(alloc);
    std.debug.print("live: {d} remotes\n", .{remotes.len});
    for (remotes) |remote| {
        std.debug.print("live: remote {s} kind {s} enabled {}\n", .{ remote.remote_id, @tagName(remote.kind), remote.enabled });
    }
}