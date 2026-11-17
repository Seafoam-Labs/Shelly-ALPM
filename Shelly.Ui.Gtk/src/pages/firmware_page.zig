//! Firmware page: updatable device list with upgrade badges, master-detail
//! release view and live signal updates against the fwupd D-Bus backend.
//!
//! Concurrency follows UpdatePage: sync backend calls on worker threads, a
//! generation counter per load (plus a detail token per release fetch), and
//! glib.idleAdd to apply results on the main thread. No GTK call happens off
//! the main thread.

const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const glib = bindings.glib;
const gio = bindings.gio;
const gdk = bindings.gdk;
const gobject = bindings.gobject;
const support = @import("support.zig");
const models = @import("../models/fwupd.zig");
const enums = @import("../services/fwupd_enums.zig");
const fwupd = @import("../services/fwupd.zig");
const DeviceObject = @import("../g_objects/firmware_device_object.zig").FirmwareDeviceObject;
const ReleaseObject = @import("../g_objects/firmware_release_object.zig").FirmwareReleaseObject;
const translations = @import("../helpers/translations.zig");
const size_helper = @import("../helpers/size_converts.zig").SizeConverter;

const log = std.log.scoped(.fwupd);
const c_alloc = std.heap.c_allocator;
const invalid_position: c_uint = std.math.maxInt(c_uint);

pub const FirmwarePage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "Firmware";
    pub const icon_name: [:0]const u8 = "firmware-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/firmware_page.ui";

    const Private = struct {
        // Template children
        summary_label: *gtk.Label,
        header_spinner: *gtk.Spinner,
        refresh_button: *gtk.Button,
        banner_box: *gtk.Box,
        banner_label: *gtk.Label,
        page_stack: *gtk.Stack,
        loading_page: *gtk.Box,
        loading_spinner: *gtk.Spinner,
        content_page: *gtk.Box,
        device_list: *gtk.ListView,
        detail_stack: *gtk.Stack,
        detail_empty: *gtk.Box,
        detail_loading: *gtk.Box,
        detail_spinner: *gtk.Spinner,
        detail_page: *gtk.Box,
        detail_name: *gtk.Label,
        detail_vendor: *gtk.Label,
        detail_summary: *gtk.Label,
        detail_version: *gtk.Label,
        detail_lowest_caption: *gtk.Label,
        detail_version_lowest: *gtk.Label,
        detail_latest_caption: *gtk.Label,
        detail_latest: *gtk.Label,
        detail_branch_caption: *gtk.Label,
        detail_branch: *gtk.Label,
        detail_flags: *gtk.Label,
        detail_problems: *gtk.Label,
        detail_guids: *gtk.Label,
        detail_warning: *gtk.Label,
        detail_no_releases: *gtk.Label,
        release_scroll: *gtk.ScrolledWindow,
        release_list: *gtk.ListView,
        empty_page: *gtk.Box,
        error_page: *gtk.Box,
        error_label: *gtk.Label,
        // State
        list_store: *gio.ListStore,
        sorter: *gtk.CustomSorter,
        sort_model: *gtk.SortListModel,
        selection: *gtk.SingleSelection,
        release_store: *gio.ListStore,
        client: fwupd.Client,
        backend: fwupd.Backend,
        arena: ?*std.heap.ArenaAllocator,
        detail_arena: ?*std.heap.ArenaAllocator,
        generation: u64,
        detail_generation: u64,
        selected_id: ?[]const u8,
        selected_problems: u64,
        props: models.DaemonProps,
        loaded: bool,
        loading: bool,
        updating_store: bool,
        var offset: c_int = 0;
    };

    const PageState = enum { Loading, Loaded, Fail, Empty };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyFirmwarePage",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn priv(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const p = self.priv();
        p.arena = null;
        p.detail_arena = null;
        p.generation = 0;
        p.detail_generation = 0;
        p.selected_id = null;
        p.selected_problems = 0;
        p.props = .{};
        p.loaded = false;
        p.loading = false;
        p.updating_store = false;
        // GObject private memory is zeroed, which is not a valid Client
        // (its arena needs the child allocator); assign the defaults.
        p.client = .{};
        p.backend = p.client.backend();

        p.list_store = gio.ListStore.new(DeviceObject.getGObjectType());
        p.sorter = gtk.CustomSorter.new(&device_compare, null, null);
        p.sort_model = gtk.SortListModel.new(p.list_store.as(gio.ListModel), p.sorter.as(gtk.Sorter));
        // Device counts are small; sorting synchronously keeps the ListView
        // from anchoring its scroll to a row that a later idle re-sort moves.
        gtk.SortListModel.setIncremental(p.sort_model, 0);
        p.selection = gtk.SingleSelection.new(p.sort_model.as(gio.ListModel));
        gtk.SingleSelection.setAutoselect(p.selection, 0);
        gtk.SingleSelection.setCanUnselect(p.selection, 1);
        gtk.ListView.setModel(p.device_list, p.selection.as(gtk.SelectionModel));
        const device_factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(device_factory, *Self, &on_device_row_setup, self, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(device_factory, *Self, &on_device_row_bind, self, .{});
        gtk.ListView.setFactory(p.device_list, device_factory.as(gtk.ListItemFactory));
        _ = gobject.Object.signals.notify.connect(p.selection.as(gobject.Object), *Self, &on_selection_changed, self, .{ .detail = "selected" });

        p.release_store = gio.ListStore.new(ReleaseObject.getGObjectType());
        const release_selection = gtk.NoSelection.new(p.release_store.as(gio.ListModel));
        gtk.ListView.setModel(p.release_list, release_selection.as(gtk.SelectionModel));
        const release_factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(release_factory, *Self, &on_release_row_setup, self, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(release_factory, *Self, &on_release_row_bind, self, .{});
        gtk.ListView.setFactory(p.release_list, release_factory.as(gtk.ListItemFactory));

        support.connectLifecycle(Self, self);
    }

    // -----------------------------------------------------------------------
    // Lifecycle + load flow
    // -----------------------------------------------------------------------

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
        start_load(self);
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;
        p.generation += 1;
        p.detail_generation += 1;
        // The client itself stays alive: in-flight workers still use it and
        // the connection is the shared GDBus singleton.
        p.backend.unsubscribeSignals();
        clear_data(self);
    }

    fn clear_data(self: *Self) void {
        const p = self.priv();
        p.updating_store = true;
        gio.ListStore.removeAll(p.list_store);
        gio.ListStore.removeAll(p.release_store);
        p.updating_store = false;
        // Lifetime rule: objects reference arena strings, so empty the stores
        // before the arenas die.
        if (p.arena) |arena| {
            arena.deinit();
            c_alloc.destroy(arena);
            p.arena = null;
        }
        clear_releases(self);
        show_detail_empty(self);
    }

    fn clear_releases(self: *Self) void {
        const p = self.priv();
        gio.ListStore.removeAll(p.release_store);
        if (p.detail_arena) |arena| {
            arena.deinit();
            c_alloc.destroy(arena);
            p.detail_arena = null;
        }
        gtk.Widget.setVisible(p.detail_warning.as(gtk.Widget), 0);
        gtk.Widget.setVisible(p.detail_no_releases.as(gtk.Widget), 0);
        gtk.Widget.setVisible(p.release_scroll.as(gtk.Widget), 1);
    }

    fn start_load(self: *Self) void {
        const p = self.priv();
        p.generation += 1;
        p.detail_generation += 1;
        p.loading = true;
        clear_data(self);
        set_state(self, .Loading);
        const thread = std.Thread.spawn(.{}, load_worker, .{ self, p.generation }) catch {
            p.loading = false;
            set_state(self, .Fail);
            return;
        };
        thread.detach();
    }

    pub const LoadData = struct {
        devices: []const models.Device,
        badges: []const DeviceObject.Badge,
    };

    /// GTK-free worker body: handshake, updatable filter, per-device badges.
    /// Badge failures degrade to "no badge"; they never fail the whole load.
    pub fn collectLoad(backend: fwupd.Backend, alloc: std.mem.Allocator) fwupd.Error!LoadData {
        _ = try backend.connect(alloc);
        const all = try backend.getDevices(alloc);
        var devices: std.ArrayListUnmanaged(models.Device) = .empty;
        for (all) |device| {
            if (enums.DeviceFlags.isUpdatable(device.flags)) try devices.append(alloc, device);
        }
        const badges = try alloc.alloc(DeviceObject.Badge, devices.items.len);
        for (devices.items, badges) |device, *badge| {
            badge.* = badgeFor(backend, alloc, device.device_id);
        }
        return .{ .devices = devices.items, .badges = badges };
    }

    fn badgeFor(backend: fwupd.Backend, alloc: std.mem.Allocator, device_id: []const u8) DeviceObject.Badge {
        const upgrades = backend.getUpgrades(alloc, device_id) catch return .{};
        // GetUpgrades only returns daemon-flagged upgrades, so classification
        // does not need the device version here.
        if (models.latestUpgradeIndex(.{}, upgrades)) |i| {
            return .{ .has_upgrade = true, .latest_version = upgrades[i].version };
        }
        return .{};
    }

    const LoadResult = struct {
        page: *Self,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
        data: ?LoadData,
        failure: ?fwupd.Failure,
    };

    fn load_worker(page: *Self, generation: u64) void {
        const arena = c_alloc.create(std.heap.ArenaAllocator) catch return;
        arena.* = std.heap.ArenaAllocator.init(c_alloc);
        const alloc = arena.allocator();
        const backend = page.priv().backend;
        const data = collectLoad(backend, alloc) catch {
            var failure: ?fwupd.Failure = null;
            if (backend.lastFailure()) |f| {
                failure = .{ .kind = f.kind, .message = alloc.dupe(u8, f.message) catch "" };
            }
            post_result(page, arena, generation, null, failure);
            return;
        };
        post_result(page, arena, generation, data, null);
    }

    fn post_result(page: *Self, arena: *std.heap.ArenaAllocator, generation: u64, data: ?LoadData, failure: ?fwupd.Failure) void {
        const result = c_alloc.create(LoadResult) catch {
            arena.deinit();
            c_alloc.destroy(arena);
            return;
        };
        result.* = .{ .page = page, .arena = arena, .generation = generation, .data = data, .failure = failure };
        _ = glib.idleAdd(&on_load_complete, result);
    }

    fn discard_result(result: *LoadResult) void {
        result.arena.deinit();
        c_alloc.destroy(result.arena);
        c_alloc.destroy(result);
    }

    fn on_load_complete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *LoadResult = @ptrCast(@alignCast(data.?));
        const page = result.page;
        const p = page.priv();
        if (result.generation != p.generation) {
            discard_result(result);
            return 0;
        }
        p.loading = false;
        if (result.failure) |f| {
            log.warn("Firmware load failed: {s}", .{f.message});
            gtk.Label.setLabel(p.error_label, models.errorText(f.kind));
            discard_result(result);
            set_state(page, .Fail);
            return 0;
        }
        const load = result.data.?;
        p.updating_store = true;
        for (load.devices, load.badges, 0..) |device, badge, i| {
            const object = DeviceObject.new(result.arena.allocator(), device, badge, @intCast(i));
            gio.ListStore.append(p.list_store, object.as(gobject.Object));
            object.as(gobject.Object).unref();
        }
        p.updating_store = false;
        // Keep the arena even when empty so hotplug additions have storage.
        p.arena = result.arena;
        c_alloc.destroy(result);

        p.props = p.backend.props();
        p.backend.subscribeSignals(signalCallbacks(page));
        update_summary(page);
        if (load.devices.len == 0) {
            set_state(page, .Empty);
            return 0;
        }
        set_state(page, .Loaded);
        restore_selection(page);
        queue_scroll_settle(page);
        return 0;
    }

    const ScrollCtx = struct { page: *Self, generation: u64 };

    /// The ListView anchors its scroll to the row that was on top when the
    /// sort model reorders, which can leave a fresh load scrolled past the
    /// upgrades. Settle the position once the sort idles have run.
    fn queue_scroll_settle(page: *Self) void {
        const ctx = c_alloc.create(ScrollCtx) catch return;
        ctx.* = .{ .page = page, .generation = page.priv().generation };
        _ = glib.idleAdd(&on_scroll_settle, ctx);
    }

    fn on_scroll_settle(data: ?*anyopaque) callconv(.c) c_int {
        const ctx: *ScrollCtx = @ptrCast(@alignCast(data.?));
        defer c_alloc.destroy(ctx);
        const page = ctx.page;
        const p = page.priv();
        if (ctx.generation != p.generation or !p.loaded) return 0;
        const pos = if (p.selected_id != null) gtk.SingleSelection.getSelected(p.selection) else 0;
        if (pos != invalid_position) gtk.ListView.scrollTo(p.device_list, pos, .{}, null);
        return 0;
    }

    fn set_state(self: *Self, state: PageState) void {
        const p = self.priv();
        const busy = state == .Loading;
        if (busy) {
            gtk.Spinner.start(p.loading_spinner);
            gtk.Spinner.start(p.header_spinner);
        } else {
            gtk.Spinner.stop(p.loading_spinner);
            gtk.Spinner.stop(p.header_spinner);
        }
        gtk.Widget.setVisible(p.header_spinner.as(gtk.Widget), @intFromBool(busy));
        gtk.Widget.setSensitive(p.refresh_button.as(gtk.Widget), @intFromBool(!busy));
        const child: *gtk.Widget = switch (state) {
            .Loading => p.loading_page.as(gtk.Widget),
            .Loaded => p.content_page.as(gtk.Widget),
            .Fail => p.error_page.as(gtk.Widget),
            .Empty => p.empty_page.as(gtk.Widget),
        };
        gtk.Stack.setVisibleChild(p.page_stack, child);
    }

    /// `gio.ListModel.getItem` is typed `?*anyopaque`; every item here is a
    /// GObject and the returned reference belongs to the caller.
    fn modelItem(model: *gio.ListModel, index: c_uint) ?*gobject.Object {
        const item = gio.ListModel.getItem(model, index) orelse return null;
        return @ptrCast(@alignCast(item));
    }

    fn update_summary(self: *Self) void {
        const p = self.priv();
        const model = p.list_store.as(gio.ListModel);
        const count = gio.ListModel.getNItems(model);
        var upgrades: usize = 0;
        for (0..count) |i| {
            const item = modelItem(model, @intCast(i)) orelse continue;
            defer item.unref();
            const object = gobject.ext.cast(DeviceObject, item) orelse continue;
            if (object.hasUpgrade()) upgrades += 1;
        }
        var buf: [128]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, "{d} {s} · {d} {s}", .{
            count,
            translations._("devices"),
            upgrades,
            translations._("updates available"),
        }, 0) catch translations._("Firmware devices");
        gtk.Label.setLabel(p.summary_label, text);
    }

    fn refresh_firmware(self: *Self) callconv(.c) void {
        start_load(self);
    }

    // -----------------------------------------------------------------------
    // Selection (tracked by device id so it survives re-sort and reload)
    // -----------------------------------------------------------------------

    fn setSelectedId(self: *Self, id: ?[]const u8) void {
        const p = self.priv();
        if (p.selected_id) |old| c_alloc.free(old);
        p.selected_id = if (id) |s| c_alloc.dupe(u8, s) catch null else null;
    }

    pub fn indexOfId(ids: []const []const u8, id: []const u8) ?c_uint {
        for (ids, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, id)) return @intCast(i);
        }
        return null;
    }

    fn restore_selection(self: *Self) void {
        const p = self.priv();
        const id = p.selected_id orelse {
            show_detail_empty(self);
            return;
        };
        const alloc = pageArena(self) orelse return;
        const model = p.sort_model.as(gio.ListModel);
        const count = gio.ListModel.getNItems(model);
        const ids = alloc.alloc([]const u8, count) catch return;
        for (ids, 0..) |*slot, i| {
            slot.* = "";
            const item = modelItem(model, @intCast(i)) orelse continue;
            defer item.unref();
            const object = gobject.ext.cast(DeviceObject, item) orelse continue;
            slot.* = object.getDeviceId();
        }
        if (indexOfId(ids, id)) |pos| {
            gtk.SingleSelection.setSelected(p.selection, pos);
        } else {
            setSelectedId(self, null);
            show_detail_empty(self);
        }
    }

    fn on_selection_changed(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.updating_store) return;
        // getSelectedItem is transfer-none: the selection and the store own
        // the item, so an unref here would finalize it under the model.
        const item = gtk.SingleSelection.getSelectedItem(p.selection) orelse {
            setSelectedId(self, null);
            p.selected_problems = 0;
            clear_releases(self);
            show_detail_empty(self);
            return;
        };
        const object = gobject.ext.cast(DeviceObject, item) orelse return;
        const id = object.getDeviceId();
        const same = if (p.selected_id) |cur| std.mem.eql(u8, cur, id) else false;
        setSelectedId(self, id);
        if (!same) clear_releases(self);
        render_device_info(self, object);
        start_detail_load(self, object, !same);
    }

    fn show_detail_empty(self: *Self) void {
        const p = self.priv();
        gtk.Spinner.stop(p.detail_spinner);
        gtk.Stack.setVisibleChild(p.detail_stack, p.detail_empty.as(gtk.Widget));
    }

    fn findDeviceIndex(self: *Self, id: []const u8) ?c_uint {
        const model = self.priv().list_store.as(gio.ListModel);
        const count = gio.ListModel.getNItems(model);
        for (0..count) |i| {
            const item = modelItem(model, @intCast(i)) orelse continue;
            defer item.unref();
            const object = gobject.ext.cast(DeviceObject, item) orelse continue;
            if (std.mem.eql(u8, object.getDeviceId(), id)) return @intCast(i);
        }
        return null;
    }

    fn deviceAt(self: *Self, index: c_uint) ?*DeviceObject {
        const item = modelItem(self.priv().list_store.as(gio.ListModel), index) orelse return null;
        defer item.unref();
        return gobject.ext.cast(DeviceObject, item);
    }

    fn pageArena(self: *Self) ?std.mem.Allocator {
        const p = self.priv();
        if (p.arena == null) {
            const arena = c_alloc.create(std.heap.ArenaAllocator) catch return null;
            arena.* = std.heap.ArenaAllocator.init(c_alloc);
            p.arena = arena;
        }
        return p.arena.?.allocator();
    }

    // -----------------------------------------------------------------------
    // Detail pane
    // -----------------------------------------------------------------------

    fn render_device_info(self: *Self, object: *DeviceObject) void {
        const p = self.priv();
        gtk.Label.setLabel(p.detail_name, object.getName());
        gtk.Label.setLabel(p.detail_vendor, object.getVendor());
        gtk.Widget.setVisible(p.detail_vendor.as(gtk.Widget), @intFromBool(object.getVendor().len > 0));
        gtk.Label.setLabel(p.detail_summary, object.getSummary());
        gtk.Widget.setVisible(p.detail_summary.as(gtk.Widget), @intFromBool(object.getSummary().len > 0));
        gtk.Label.setLabel(p.detail_version, object.getVersion());

        const lowest = object.getVersionLowest();
        gtk.Widget.setVisible(p.detail_lowest_caption.as(gtk.Widget), @intFromBool(lowest.len > 0));
        gtk.Widget.setVisible(p.detail_version_lowest.as(gtk.Widget), @intFromBool(lowest.len > 0));
        gtk.Label.setLabel(p.detail_version_lowest, lowest);

        const latest = object.getLatestVersion();
        const show_latest = object.hasUpgrade() and latest.len > 0;
        gtk.Widget.setVisible(p.detail_latest_caption.as(gtk.Widget), @intFromBool(show_latest));
        gtk.Widget.setVisible(p.detail_latest.as(gtk.Widget), @intFromBool(show_latest));
        gtk.Label.setLabel(p.detail_latest, latest);

        const branch = object.getBranch();
        gtk.Widget.setVisible(p.detail_branch_caption.as(gtk.Widget), @intFromBool(branch.len > 0));
        gtk.Widget.setVisible(p.detail_branch.as(gtk.Widget), @intFromBool(branch.len > 0));
        gtk.Label.setLabel(p.detail_branch, branch);

        const alloc = pageArena(self) orelse return;
        const flags = flagLabels(alloc, object.getFlags()) catch &.{};
        const flags_text = joinSentinel(alloc, flags, ", ");
        gtk.Label.setLabel(p.detail_flags, flags_text);
        gtk.Widget.setVisible(p.detail_flags.as(gtk.Widget), @intFromBool(flags.len > 0));

        const guids = joinSentinel(alloc, object.getGuid(), "\n");
        gtk.Label.setLabel(p.detail_guids, guids);
        gtk.Widget.setVisible(p.detail_guids.as(gtk.Widget), @intFromBool(object.getGuid().len > 0));

        render_problems(self, object);
    }

    fn render_problems(self: *Self, object: *DeviceObject) void {
        const p = self.priv();
        p.selected_problems = object.getProblems();
        const alloc = pageArena(self) orelse return;
        const device = models.Device{
            .problems = object.getProblems(),
            .battery_level = object.getBatteryLevel(),
            .battery_threshold = object.getBatteryThreshold(),
        };
        const problems = models.problemStrings(alloc, device, p.props) catch &.{};
        const text = joinSentinel(alloc, problems, "\n");
        gtk.Label.setLabel(p.detail_problems, text);
        gtk.Widget.setVisible(p.detail_problems.as(gtk.Widget), @intFromBool(problems.len > 0));
    }

    const DetailResult = struct {
        page: *Self,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
        token: u64,
        device_id: []const u8,
        device_version: []const u8,
        releases: ?[]const models.Release,
        failure: ?fwupd.Failure,
    };

    fn start_detail_load(self: *Self, object: *DeviceObject, show_loading: bool) void {
        const p = self.priv();
        p.detail_generation += 1;
        const token = p.detail_generation;
        if (show_loading) {
            gtk.Spinner.start(p.detail_spinner);
            gtk.Stack.setVisibleChild(p.detail_stack, p.detail_loading.as(gtk.Widget));
        }
        // The worker outlives this call and the page arena may be reset under
        // it, so the id/version copies use the plain C allocator and ownership
        // moves into the result.
        const id = c_alloc.dupe(u8, object.getDeviceId()) catch return;
        const version = c_alloc.dupe(u8, object.getVersion()) catch {
            c_alloc.free(id);
            return;
        };
        const thread = std.Thread.spawn(.{}, releases_worker, .{ self, p.generation, token, id, version }) catch {
            c_alloc.free(id);
            c_alloc.free(version);
            return;
        };
        thread.detach();
    }

    fn releases_worker(page: *Self, generation: u64, token: u64, id: []const u8, version: []const u8) void {
        const arena = c_alloc.create(std.heap.ArenaAllocator) catch {
            c_alloc.free(id);
            c_alloc.free(version);
            return;
        };
        arena.* = std.heap.ArenaAllocator.init(c_alloc);
        const backend = page.priv().backend;
        const releases = backend.getReleases(arena.allocator(), id) catch {
            var failure: ?fwupd.Failure = null;
            if (backend.lastFailure()) |f| {
                failure = .{ .kind = f.kind, .message = arena.allocator().dupe(u8, f.message) catch "" };
            }
            if (failure == null) failure = .{ .kind = .unknown, .message = "" };
            post_detail(page, arena, generation, token, id, version, null, failure);
            return;
        };
        post_detail(page, arena, generation, token, id, version, releases, null);
    }

    fn post_detail(
        page: *Self,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
        token: u64,
        id: []const u8,
        version: []const u8,
        releases: ?[]const models.Release,
        failure: ?fwupd.Failure,
    ) void {
        const result = c_alloc.create(DetailResult) catch {
            arena.deinit();
            c_alloc.destroy(arena);
            c_alloc.free(id);
            c_alloc.free(version);
            return;
        };
        result.* = .{
            .page = page,
            .arena = arena,
            .generation = generation,
            .token = token,
            .device_id = id,
            .device_version = version,
            .releases = releases,
            .failure = failure,
        };
        _ = glib.idleAdd(&on_detail_complete, result);
    }

    fn discard_detail(result: *DetailResult) void {
        result.arena.deinit();
        c_alloc.destroy(result.arena);
        c_alloc.free(result.device_id);
        c_alloc.free(result.device_version);
        c_alloc.destroy(result);
    }

    fn on_detail_complete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *DetailResult = @ptrCast(@alignCast(data.?));
        const page = result.page;
        const p = page.priv();
        if (result.generation != p.generation or result.token != p.detail_generation or !p.loaded) {
            discard_detail(result);
            return 0;
        }
        if (result.failure) |f| {
            log.warn("GetReleases failed for {s}: {s}", .{ result.device_id, f.message });
            // Keep the previous list (same-device refresh) and warn inline.
            gtk.Label.setLabel(p.detail_warning, models.errorText(f.kind));
            gtk.Widget.setVisible(p.detail_warning.as(gtk.Widget), 1);
            const empty = gio.ListModel.getNItems(p.release_store.as(gio.ListModel)) == 0;
            gtk.Widget.setVisible(p.detail_no_releases.as(gtk.Widget), @intFromBool(empty));
            gtk.Widget.setVisible(p.release_scroll.as(gtk.Widget), @intFromBool(!empty));
            gtk.Spinner.stop(p.detail_spinner);
            gtk.Stack.setVisibleChild(p.detail_stack, p.detail_page.as(gtk.Widget));
            discard_detail(result);
            return 0;
        }
        const releases = result.releases.?;
        gio.ListStore.removeAll(p.release_store);
        if (p.detail_arena) |old| {
            old.deinit();
            c_alloc.destroy(old);
        }
        p.detail_arena = result.arena;
        const device = models.Device{ .version = result.device_version };
        for (releases) |release| {
            const object = ReleaseObject.new(result.arena.allocator(), device, release);
            gio.ListStore.append(p.release_store, object.as(gobject.Object));
            object.as(gobject.Object).unref();
        }
        gtk.Widget.setVisible(p.detail_warning.as(gtk.Widget), 0);
        gtk.Widget.setVisible(p.detail_no_releases.as(gtk.Widget), @intFromBool(releases.len == 0));
        gtk.Widget.setVisible(p.release_scroll.as(gtk.Widget), @intFromBool(releases.len > 0));
        gtk.Spinner.stop(p.detail_spinner);
        gtk.Stack.setVisibleChild(p.detail_stack, p.detail_page.as(gtk.Widget));
        c_alloc.free(result.device_id);
        c_alloc.free(result.device_version);
        c_alloc.destroy(result);
        return 0;
    }

    // -----------------------------------------------------------------------
    // Signals (main loop; structs are only valid during the callback)
    // -----------------------------------------------------------------------

    fn signalCallbacks(page: *Self) fwupd.SignalCallbacks {
        return .{
            .user_data = page,
            .on_device_added = &sig_device_added,
            .on_device_changed = &sig_device_changed,
            .on_device_removed = &sig_device_removed,
            .on_device_request = &sig_device_request,
            .on_changed = &sig_changed,
            .on_properties_changed = &sig_properties_changed,
        };
    }

    fn sig_device_added(user_data: ?*anyopaque, device: models.Device) void {
        const self: *Self = @ptrCast(@alignCast(user_data.?));
        const p = self.priv();
        if (!p.loaded or p.loading) return;
        if (!enums.DeviceFlags.isUpdatable(device.flags)) return;
        if (findDeviceIndex(self, device.device_id) != null) {
            sig_device_changed(user_data, device);
            return;
        }
        const alloc = pageArena(self) orelse return;
        const order = gio.ListModel.getNItems(p.list_store.as(gio.ListModel));
        const object = DeviceObject.new(alloc, device, .{}, order);
        gio.ListStore.append(p.list_store, object.as(gobject.Object));
        object.as(gobject.Object).unref();
        set_state(self, .Loaded);
        update_summary(self);
        start_badge_check(self, device.device_id);
    }

    fn sig_device_changed(user_data: ?*anyopaque, device: models.Device) void {
        const self: *Self = @ptrCast(@alignCast(user_data.?));
        const p = self.priv();
        if (!p.loaded or p.loading) return;
        const index = findDeviceIndex(self, device.device_id) orelse return;
        const object = deviceAt(self, index) orelse return;
        if (object.isSameState(device)) return;
        const alloc = pageArena(self) orelse return;
        object.updateFromDevice(alloc, device);
        gtk.Sorter.changed(p.sorter.as(gtk.Sorter), .different);
        update_summary(self);
        start_badge_check(self, device.device_id);
        if (p.selected_id) |id| {
            if (std.mem.eql(u8, id, device.device_id)) {
                render_device_info(self, object);
                start_detail_load(self, object, false);
            }
        }
    }

    fn sig_device_removed(user_data: ?*anyopaque, device_id: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(user_data.?));
        const p = self.priv();
        if (!p.loaded or p.loading) return;
        const index = findDeviceIndex(self, device_id) orelse return;
        if (p.selected_id) |id| {
            if (std.mem.eql(u8, id, device_id)) {
                gtk.SingleSelection.setSelected(p.selection, invalid_position);
            }
        }
        gio.ListStore.remove(p.list_store, index);
        update_summary(self);
        if (gio.ListModel.getNItems(p.list_store.as(gio.ListModel)) == 0) {
            set_state(self, .Empty);
        }
    }

    fn sig_device_request(_: ?*anyopaque, request: models.Request) void {
        log.debug("Ignoring DeviceRequest '{s}'", .{request.appstream_id});
    }

    fn sig_changed(user_data: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(user_data.?));
        const p = self.priv();
        if (!p.loaded) return;
        // Transient daemon went away or finished a job: full reconnect+reload.
        start_load(self);
    }

    fn sig_properties_changed(user_data: ?*anyopaque, props: models.DaemonProps) void {
        const self: *Self = @ptrCast(@alignCast(user_data.?));
        const p = self.priv();
        p.props = props;
        if (!p.loaded) return;
        // Problem text interpolates the system battery values.
        if (p.selected_id) |id| {
            if (findDeviceIndex(self, id)) |index| {
                if (deviceAt(self, index)) |object| render_problems(self, object);
            }
        }
    }

    const BadgeResult = struct {
        page: *Self,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
        device_id: []const u8,
        badge: DeviceObject.Badge,
    };

    fn start_badge_check(self: *Self, device_id: []const u8) void {
        const p = self.priv();
        const id = c_alloc.dupe(u8, device_id) catch return;
        const thread = std.Thread.spawn(.{}, badge_worker, .{ self, p.generation, id }) catch {
            c_alloc.free(id);
            return;
        };
        thread.detach();
    }

    fn badge_worker(page: *Self, generation: u64, id: []const u8) void {
        const arena = c_alloc.create(std.heap.ArenaAllocator) catch {
            c_alloc.free(id);
            return;
        };
        arena.* = std.heap.ArenaAllocator.init(c_alloc);
        const badge = badgeFor(page.priv().backend, arena.allocator(), id);
        const result = c_alloc.create(BadgeResult) catch {
            arena.deinit();
            c_alloc.destroy(arena);
            c_alloc.free(id);
            return;
        };
        result.* = .{ .page = page, .arena = arena, .generation = generation, .device_id = id, .badge = badge };
        _ = glib.idleAdd(&on_badge_complete, result);
    }

    fn on_badge_complete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *BadgeResult = @ptrCast(@alignCast(data.?));
        const page = result.page;
        const p = page.priv();
        if (result.generation == p.generation and p.loaded) {
            if (findDeviceIndex(page, result.device_id)) |index| {
                if (deviceAt(page, index)) |object| {
                    if (pageArena(page)) |alloc| {
                        object.setBadge(alloc, result.badge);
                        gtk.Sorter.changed(p.sorter.as(gtk.Sorter), .different);
                        update_summary(page);
                        if (p.selected_id) |id| {
                            if (std.mem.eql(u8, id, result.device_id)) render_device_info(page, object);
                        }
                    }
                }
            }
        }
        result.arena.deinit();
        c_alloc.destroy(result.arena);
        c_alloc.free(result.device_id);
        c_alloc.destroy(result);
        return 0;
    }

    // -----------------------------------------------------------------------
    // Device rows
    // -----------------------------------------------------------------------

    pub fn compareDeviceKeys(a_upgrade: bool, a_order: u32, b_upgrade: bool, b_order: u32) c_int {
        if (a_upgrade != b_upgrade) return if (a_upgrade) -1 else 1;
        if (a_order < b_order) return -1;
        if (a_order > b_order) return 1;
        return 0;
    }

    fn device_compare(a_ptr: ?*const anyopaque, b_ptr: ?*const anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const a: *DeviceObject = @ptrCast(@alignCast(@constCast(a_ptr.?)));
        const b: *DeviceObject = @ptrCast(@alignCast(@constCast(b_ptr.?)));
        return compareDeviceKeys(a.hasUpgrade(), a.getOrder(), b.hasUpgrade(), b.getOrder());
    }

    fn on_device_row_setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: *Self) callconv(.c) void {
        const list_item = gobject.ext.cast(gtk.ListItem, item) orelse return;
        gtk.ListItem.setChild(list_item, buildDeviceRow().as(gtk.Widget));
    }

    fn on_device_row_bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: *Self) callconv(.c) void {
        const list_item = gobject.ext.cast(gtk.ListItem, item) orelse return;
        const item_obj = gtk.ListItem.getItem(list_item) orelse return;
        const object = gobject.ext.cast(DeviceObject, item_obj) orelse return;
        const child = gtk.ListItem.getChild(list_item) orelse return;
        const grid = gobject.ext.cast(gtk.Grid, child) orelse return;
        bindDeviceRow(grid, object);
    }

    fn buildDeviceRow() *gtk.Grid {
        const grid = gtk.Grid.new();
        gtk.Widget.setMarginStart(grid.as(gtk.Widget), 4);
        gtk.Widget.setMarginEnd(grid.as(gtk.Widget), 4);
        gtk.Widget.setMarginTop(grid.as(gtk.Widget), 4);
        gtk.Widget.setMarginBottom(grid.as(gtk.Widget), 4);
        gtk.Grid.setColumnSpacing(grid, 12);
        gtk.Grid.setRowSpacing(grid, 2);
        gtk.Widget.setHexpand(grid.as(gtk.Widget), 1);

        const icon = gtk.Image.new();
        gtk.Image.setPixelSize(icon, 16);
        gtk.Widget.setValign(icon.as(gtk.Widget), .center);
        gtk.Grid.attach(grid, icon.as(gtk.Widget), 0, 0, 1, 2);

        // Name and summary share a box so a hidden summary collapses fully:
        // a grid row would keep its spacing even with an invisible label.
        const text_box = gtk.Box.new(.vertical, 2);
        gtk.Widget.setHexpand(text_box.as(gtk.Widget), 1);
        gtk.Grid.attach(grid, text_box.as(gtk.Widget), 1, 0, 1, 1);

        const name = gtk.Label.new("");
        gtk.Label.setXalign(name, 0);
        gtk.Label.setEllipsize(name, .end);
        gtk.Widget.setHexpand(name.as(gtk.Widget), 1);
        gtk.Widget.addCssClass(name.as(gtk.Widget), "heading");
        gtk.Box.append(text_box, name.as(gtk.Widget));

        const summary = gtk.Label.new("");
        gtk.Label.setXalign(summary, 0);
        gtk.Label.setEllipsize(summary, .end);
        gtk.Widget.addCssClass(summary.as(gtk.Widget), "caption");
        gtk.Widget.addCssClass(summary.as(gtk.Widget), "dim-label");
        gtk.Box.append(text_box, summary.as(gtk.Widget));

        // Versions live on their own row: beside the name they squeeze long
        // device names and get clipped themselves on narrow panes.
        const bottom = gtk.Box.new(.horizontal, 8);
        gtk.Widget.setHexpand(bottom.as(gtk.Widget), 1);
        const current = gtk.Label.new("");
        gtk.Label.setXalign(current, 0);
        gtk.Widget.addCssClass(current.as(gtk.Widget), "dim-label");
        gtk.Box.append(bottom, current.as(gtk.Widget));
        const arrow = gtk.Image.newFromIconName("go-next-symbolic");
        gtk.Image.setPixelSize(arrow, 12);
        gtk.Widget.setValign(arrow.as(gtk.Widget), .center);
        gtk.Box.append(bottom, arrow.as(gtk.Widget));
        const latest = gtk.Label.new("");
        gtk.Label.setXalign(latest, 0);
        gtk.Widget.addCssClass(latest.as(gtk.Widget), "heading");
        gtk.Box.append(bottom, latest.as(gtk.Widget));
        const badges = gtk.Label.new("");
        gtk.Label.setXalign(badges, 0);
        gtk.Label.setEllipsize(badges, .end);
        gtk.Widget.setHalign(badges.as(gtk.Widget), .end);
        gtk.Widget.setHexpand(badges.as(gtk.Widget), 1);
        gtk.Widget.addCssClass(badges.as(gtk.Widget), "caption");
        gtk.Widget.addCssClass(badges.as(gtk.Widget), "warning");
        gtk.Box.append(bottom, badges.as(gtk.Widget));
        gtk.Grid.attach(grid, bottom.as(gtk.Widget), 1, 1, 1, 1);

        return grid;
    }

    fn bindDeviceRow(grid: *gtk.Grid, object: *DeviceObject) void {
        const icon = gobject.ext.cast(gtk.Image, gtk.Grid.getChildAt(grid, 0, 0) orelse return) orelse return;
        const text_box = gobject.ext.cast(gtk.Box, gtk.Grid.getChildAt(grid, 1, 0) orelse return) orelse return;
        const name = gobject.ext.cast(gtk.Label, gtk.Widget.getFirstChild(text_box.as(gtk.Widget)) orelse return) orelse return;
        const summary = gobject.ext.cast(gtk.Label, gtk.Widget.getNextSibling(name.as(gtk.Widget)) orelse return) orelse return;
        const bottom = gobject.ext.cast(gtk.Box, gtk.Grid.getChildAt(grid, 1, 1) orelse return) orelse return;
        const current = gobject.ext.cast(gtk.Label, gtk.Widget.getFirstChild(bottom.as(gtk.Widget)) orelse return) orelse return;
        const arrow = gtk.Widget.getNextSibling(current.as(gtk.Widget)) orelse return;
        const latest = gobject.ext.cast(gtk.Label, gtk.Widget.getNextSibling(arrow) orelse return) orelse return;
        const badges = gobject.ext.cast(gtk.Label, gtk.Widget.getNextSibling(latest.as(gtk.Widget)) orelse return) orelse return;

        var icon_buf: [128]u8 = undefined;
        gtk.Image.setFromIconName(icon, deviceIconName(object.getIcon(), &icon_buf));
        gtk.Label.setLabel(name, object.getName());
        gtk.Label.setLabel(summary, object.getSummary());
        gtk.Widget.setVisible(summary.as(gtk.Widget), @intFromBool(object.getSummary().len > 0));
        gtk.Label.setLabel(current, object.getVersion());
        gtk.Label.setLabel(latest, object.getLatestVersion());
        const show_upgrade = @intFromBool(object.hasUpgrade());
        gtk.Widget.setVisible(arrow, show_upgrade);
        gtk.Widget.setVisible(latest.as(gtk.Widget), show_upgrade);

        var buf: [128]u8 = undefined;
        var text: [:0]const u8 = "";
        const eol = enums.DeviceFlags.has(object.getFlags(), enums.DeviceFlags.end_of_life);
        const unsigned = enums.DeviceFlags.has(object.getFlags(), enums.DeviceFlags.unsigned_payload);
        if (eol and unsigned) {
            text = std.fmt.bufPrintSentinel(&buf, "{s} · {s}", .{ translations._("End of life"), translations._("Unsigned payload") }, 0) catch "";
        } else if (eol) {
            text = translations._("End of life");
        } else if (unsigned) {
            text = translations._("Unsigned payload");
        }
        gtk.Label.setLabel(badges, text);
        gtk.Widget.setVisible(badges.as(gtk.Widget), @intFromBool(text.len > 0));
    }

    /// Writes into `buf` because the result must outlive this call.
    fn deviceIconName(icon: []const u8, buf: []u8) [:0]const u8 {
        if (icon.len == 0) return "computer-symbolic";
        const name = std.fmt.bufPrintSentinel(buf, "{s}-symbolic", .{icon}, 0) catch return "computer-symbolic";
        if (gdk.Display.getDefault()) |display| {
            const theme = gtk.IconTheme.getForDisplay(display);
            if (gtk.IconTheme.hasIcon(theme, name) == 0) return "computer-symbolic";
        }
        return name;
    }

    // -----------------------------------------------------------------------
    // Release rows
    // -----------------------------------------------------------------------

    fn on_release_row_setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, self: *Self) callconv(.c) void {
        const list_item = gobject.ext.cast(gtk.ListItem, item) orelse return;
        const grid = buildReleaseRow();
        const button = gobject.ext.cast(gtk.Button, gtk.Grid.getChildAt(grid, 3, 0) orelse return) orelse return;
        gobject.Object.setData(button.as(gobject.Object), "page", self);
        gobject.Object.setData(button.as(gobject.Object), "list_item", list_item);
        _ = gtk.Button.signals.clicked.connect(button, ?*anyopaque, &on_release_action, null, .{});
        gtk.ListItem.setChild(list_item, grid.as(gtk.Widget));
    }

    fn on_release_row_bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, self: *Self) callconv(.c) void {
        const list_item = gobject.ext.cast(gtk.ListItem, item) orelse return;
        const item_obj = gtk.ListItem.getItem(list_item) orelse return;
        const object = gobject.ext.cast(ReleaseObject, item_obj) orelse return;
        const child = gtk.ListItem.getChild(list_item) orelse return;
        const grid = gobject.ext.cast(gtk.Grid, child) orelse return;
        bindReleaseRow(grid, object, self.priv().selected_problems);
    }

    fn buildReleaseRow() *gtk.Grid {
        const grid = gtk.Grid.new();
        gtk.Widget.setMarginStart(grid.as(gtk.Widget), 0);
        gtk.Widget.setMarginEnd(grid.as(gtk.Widget), 0);
        gtk.Widget.setMarginTop(grid.as(gtk.Widget), 6);
        gtk.Widget.setMarginBottom(grid.as(gtk.Widget), 6);
        gtk.Grid.setColumnSpacing(grid, 12);
        gtk.Widget.setHexpand(grid.as(gtk.Widget), 1);

        // Each text column is a centered box so a lone line sits mid-row like
        // the size and action columns; hidden sub-labels collapse fully.
        const version_box = gtk.Box.new(.vertical, 2);
        gtk.Widget.setValign(version_box.as(gtk.Widget), .center);
        gtk.Grid.attach(grid, version_box.as(gtk.Widget), 0, 0, 1, 1);

        const version = gtk.Label.new("");
        gtk.Label.setXalign(version, 0);
        gtk.Label.setSelectable(version, 1);
        gtk.Widget.addCssClass(version.as(gtk.Widget), "heading");
        gtk.Box.append(version_box, version.as(gtk.Widget));

        const urgency = gtk.Label.new("");
        gtk.Label.setXalign(urgency, 0);
        gtk.Widget.addCssClass(urgency.as(gtk.Widget), "caption");
        gtk.Widget.addCssClass(urgency.as(gtk.Widget), "dim-label");
        gtk.Box.append(version_box, urgency.as(gtk.Widget));

        const text_box = gtk.Box.new(.vertical, 2);
        gtk.Widget.setValign(text_box.as(gtk.Widget), .center);
        gtk.Widget.setHexpand(text_box.as(gtk.Widget), 1);
        gtk.Grid.attach(grid, text_box.as(gtk.Widget), 1, 0, 1, 1);

        const summary = gtk.Label.new("");
        gtk.Label.setXalign(summary, 0);
        gtk.Label.setSelectable(summary, 1);
        gtk.Label.setEllipsize(summary, .end);
        gtk.Label.setMaxWidthChars(summary, 48);
        gtk.Widget.setHexpand(summary.as(gtk.Widget), 1);
        gtk.Box.append(text_box, summary.as(gtk.Widget));

        const badges = gtk.Label.new("");
        gtk.Label.setXalign(badges, 0);
        gtk.Widget.addCssClass(badges.as(gtk.Widget), "caption");
        gtk.Widget.addCssClass(badges.as(gtk.Widget), "dim-label");
        gtk.Box.append(text_box, badges.as(gtk.Widget));

        const size = gtk.Label.new("");
        gtk.Label.setXalign(size, 1);
        gtk.Widget.setValign(size.as(gtk.Widget), .center);
        gtk.Widget.addCssClass(size.as(gtk.Widget), "dim-label");
        gtk.Grid.attach(grid, size.as(gtk.Widget), 2, 0, 1, 1);

        const action = gtk.Button.newWithLabel("");
        gtk.Widget.setValign(action.as(gtk.Widget), .center);
        gtk.Grid.attach(grid, action.as(gtk.Widget), 3, 0, 1, 1);

        return grid;
    }

    fn bindReleaseRow(grid: *gtk.Grid, object: *ReleaseObject, device_problems: u64) void {
        const version_box = gobject.ext.cast(gtk.Box, gtk.Grid.getChildAt(grid, 0, 0) orelse return) orelse return;
        const version = gobject.ext.cast(gtk.Label, gtk.Widget.getFirstChild(version_box.as(gtk.Widget)) orelse return) orelse return;
        const urgency = gobject.ext.cast(gtk.Label, gtk.Widget.getNextSibling(version.as(gtk.Widget)) orelse return) orelse return;
        const text_box = gobject.ext.cast(gtk.Box, gtk.Grid.getChildAt(grid, 1, 0) orelse return) orelse return;
        const summary = gobject.ext.cast(gtk.Label, gtk.Widget.getFirstChild(text_box.as(gtk.Widget)) orelse return) orelse return;
        const badges = gobject.ext.cast(gtk.Label, gtk.Widget.getNextSibling(summary.as(gtk.Widget)) orelse return) orelse return;
        const size = gobject.ext.cast(gtk.Label, gtk.Grid.getChildAt(grid, 2, 0) orelse return) orelse return;
        const action = gobject.ext.cast(gtk.Button, gtk.Grid.getChildAt(grid, 3, 0) orelse return) orelse return;

        gtk.Label.setLabel(version, object.getVersion());
        const urgency_text = urgencyLabel(object.getUrgency());
        gtk.Label.setLabel(urgency, urgency_text orelse "");
        gtk.Widget.setVisible(urgency.as(gtk.Widget), @intFromBool(urgency_text != null));
        gtk.Label.setLabel(summary, object.getSummary());

        var arena = std.heap.ArenaAllocator.init(c_alloc);
        defer arena.deinit();
        const badge_text = releaseBadgeText(arena.allocator(), object.getTrustFlags(), object.getClassification());
        gtk.Label.setLabel(badges, badge_text);
        gtk.Widget.setVisible(badges.as(gtk.Widget), @intFromBool(badge_text.len > 0));

        var size_buf: [32]u8 = undefined;
        const size_text: [:0]const u8 = if (object.getSize() > 0)
            size_helper.convert_null_term(&size_buf, @intCast(object.getSize()))
        else
            "";
        gtk.Label.setLabel(size, size_text);

        const classification = object.getClassification();
        const label = releaseActionLabel(classification);
        gtk.Widget.setVisible(action.as(gtk.Widget), @intFromBool(label != null));
        gtk.Button.setLabel(action, label orelse "");
        if (classification == .blocked) {
            gtk.Widget.setSensitive(action.as(gtk.Widget), 0);
            gtk.Widget.setTooltipText(action.as(gtk.Widget), blockedReason(object.getTrustFlags()));
        } else if (device_problems != 0) {
            gtk.Widget.setSensitive(action.as(gtk.Widget), 0);
            gtk.Widget.setTooltipText(action.as(gtk.Widget), translations._("Resolve the device problems before updating"));
        } else {
            gtk.Widget.setSensitive(action.as(gtk.Widget), 1);
            gtk.Widget.setTooltipText(action.as(gtk.Widget), null);
        }
    }

    fn on_release_action(button: *gtk.Button, _: ?*anyopaque) callconv(.c) void {
        const li_ptr = gobject.Object.getData(button.as(gobject.Object), "list_item") orelse return;
        const list_item: *gtk.ListItem = @ptrCast(@alignCast(li_ptr));
        const item_obj = gtk.ListItem.getItem(list_item) orelse return;
        const object = gobject.ext.cast(ReleaseObject, item_obj) orelse return;
        log.debug("Firmware action requested for release {s}", .{object.getVersion()});
    }

    // -----------------------------------------------------------------------
    // Pure label helpers
    // -----------------------------------------------------------------------

    pub fn flagLabels(alloc: std.mem.Allocator, flags: u64) std.mem.Allocator.Error![]const []const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        const entries = .{
            .{ enums.DeviceFlags.locked, translations._("Locked") },
            .{ enums.DeviceFlags.needs_bootloader, translations._("Needs bootloader") },
            .{ enums.DeviceFlags.needs_reboot, translations._("Needs restart") },
            .{ enums.DeviceFlags.needs_shutdown, translations._("Needs shutdown") },
            .{ enums.DeviceFlags.needs_activation, translations._("Needs activation") },
            .{ enums.DeviceFlags.usable_during_update, translations._("Usable during the update") },
            .{ enums.DeviceFlags.affects_fde, translations._("Affects full-disk encryption") },
            .{ enums.DeviceFlags.end_of_life, translations._("End of life") },
            .{ enums.DeviceFlags.unsigned_payload, translations._("Unsigned payload") },
        };
        inline for (entries) |entry| {
            if (enums.DeviceFlags.has(flags, entry[0])) try list.append(alloc, entry[1]);
        }
        return list.items;
    }

    pub fn urgencyLabel(urgency: enums.Urgency) ?[:0]const u8 {
        return switch (urgency) {
            .unknown => null,
            .low => translations._("Low priority"),
            .medium => translations._("Medium priority"),
            .high => translations._("High priority"),
            .critical => translations._("Critical priority"),
        };
    }

    pub fn releaseActionLabel(classification: models.Classification) ?[:0]const u8 {
        return switch (classification) {
            .upgrade => translations._("Update"),
            .downgrade => translations._("Downgrade"),
            .reinstall => translations._("Reinstall"),
            .blocked => translations._("Blocked"),
            .other => null,
        };
    }

    pub fn blockedReason(trust_flags: u64) [:0]const u8 {
        if (trust_flags & enums.TrustFlags.blocked_approval != 0) {
            return translations._("This release requires approval before it can be installed");
        }
        return translations._("This version is blocked on this device");
    }

    fn releaseBadgeText(alloc: std.mem.Allocator, trust_flags: u64, classification: models.Classification) [:0]const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        if (classification == .blocked) {
            list.append(alloc, blockedReason(trust_flags)) catch return "";
        }
        if (trust_flags & enums.TrustFlags.is_community != 0) {
            list.append(alloc, translations._("Community supported")) catch return "";
        }
        if (trust_flags & enums.TrustFlags.is_alternate_branch != 0) {
            list.append(alloc, translations._("Alternate branch")) catch return "";
        }
        return joinSentinel(alloc, list.items, " · ");
    }

    fn joinSentinel(alloc: std.mem.Allocator, parts: []const []const u8, sep: []const u8) [:0]const u8 {
        const joined = std.mem.join(alloc, sep, parts) catch return "";
        return alloc.dupeSentinel(u8, joined, 0) catch "";
    }

    const template_children = .{
        .{ "summary_label", @offsetOf(Private, "summary_label") },
        .{ "header_spinner", @offsetOf(Private, "header_spinner") },
        .{ "refresh_button", @offsetOf(Private, "refresh_button") },
        .{ "banner_box", @offsetOf(Private, "banner_box") },
        .{ "banner_label", @offsetOf(Private, "banner_label") },
        .{ "page_stack", @offsetOf(Private, "page_stack") },
        .{ "loading_page", @offsetOf(Private, "loading_page") },
        .{ "loading_spinner", @offsetOf(Private, "loading_spinner") },
        .{ "content_page", @offsetOf(Private, "content_page") },
        .{ "device_list", @offsetOf(Private, "device_list") },
        .{ "detail_stack", @offsetOf(Private, "detail_stack") },
        .{ "detail_empty", @offsetOf(Private, "detail_empty") },
        .{ "detail_loading", @offsetOf(Private, "detail_loading") },
        .{ "detail_spinner", @offsetOf(Private, "detail_spinner") },
        .{ "detail_page", @offsetOf(Private, "detail_page") },
        .{ "detail_name", @offsetOf(Private, "detail_name") },
        .{ "detail_vendor", @offsetOf(Private, "detail_vendor") },
        .{ "detail_summary", @offsetOf(Private, "detail_summary") },
        .{ "detail_version", @offsetOf(Private, "detail_version") },
        .{ "detail_lowest_caption", @offsetOf(Private, "detail_lowest_caption") },
        .{ "detail_version_lowest", @offsetOf(Private, "detail_version_lowest") },
        .{ "detail_latest_caption", @offsetOf(Private, "detail_latest_caption") },
        .{ "detail_latest", @offsetOf(Private, "detail_latest") },
        .{ "detail_branch_caption", @offsetOf(Private, "detail_branch_caption") },
        .{ "detail_branch", @offsetOf(Private, "detail_branch") },
        .{ "detail_flags", @offsetOf(Private, "detail_flags") },
        .{ "detail_problems", @offsetOf(Private, "detail_problems") },
        .{ "detail_guids", @offsetOf(Private, "detail_guids") },
        .{ "detail_warning", @offsetOf(Private, "detail_warning") },
        .{ "detail_no_releases", @offsetOf(Private, "detail_no_releases") },
        .{ "release_scroll", @offsetOf(Private, "release_scroll") },
        .{ "release_list", @offsetOf(Private, "release_list") },
        .{ "empty_page", @offsetOf(Private, "empty_page") },
        .{ "error_page", @offsetOf(Private, "error_page") },
        .{ "error_label", @offsetOf(Private, "error_label") },
    };

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            const wc = gobject.ext.as(gtk.Widget.Class, class);
            gtk.Widget.Class.setTemplateFromResource(wc, resource_path);
            inline for (template_children) |child| {
                support.bindChild(class, Private.offset, child[0], child[1]);
            }
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "refresh_firmware", @ptrCast(&refresh_firmware));
        }
    };
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const gtk_test = @import("../helpers/gtk_test.zig");

test "firmware sorter puts upgrades first and keeps daemon order" {
    const compare = FirmwarePage.compareDeviceKeys;
    try testing.expect(compare(true, 5, false, 0) < 0);
    try testing.expect(compare(false, 0, true, 5) > 0);
    try testing.expect(compare(true, 1, true, 2) < 0);
    try testing.expect(compare(false, 2, false, 1) > 0);
    try testing.expectEqual(@as(c_int, 0), compare(true, 3, true, 3));
}

test "firmware selection restore finds devices by id" {
    const ids = [_][]const u8{ "aaa", "bbb", "ccc" };
    try testing.expectEqual(@as(?c_uint, 1), FirmwarePage.indexOfId(&ids, "bbb"));
    try testing.expectEqual(@as(?c_uint, null), FirmwarePage.indexOfId(&ids, "ddd"));
    try testing.expectEqual(@as(?c_uint, null), FirmwarePage.indexOfId(&.{}, "aaa"));
}

test "firmware flag labels cover the UI-relevant device flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqual(@as(usize, 0), (try FirmwarePage.flagLabels(alloc, 0)).len);
    const labels = try FirmwarePage.flagLabels(alloc, enums.DeviceFlags.affects_fde | enums.DeviceFlags.end_of_life);
    try testing.expectEqual(@as(usize, 2), labels.len);
    try testing.expectEqualStrings("Affects full-disk encryption", labels[0]);
    try testing.expectEqualStrings("End of life", labels[1]);
}

test "firmware release labels map classification, urgency and blocked reasons" {
    try testing.expectEqualStrings("Update", FirmwarePage.releaseActionLabel(.upgrade).?);
    try testing.expectEqualStrings("Downgrade", FirmwarePage.releaseActionLabel(.downgrade).?);
    try testing.expectEqualStrings("Reinstall", FirmwarePage.releaseActionLabel(.reinstall).?);
    try testing.expectEqualStrings("Blocked", FirmwarePage.releaseActionLabel(.blocked).?);
    try testing.expect(FirmwarePage.releaseActionLabel(.other) == null);
    try testing.expect(FirmwarePage.urgencyLabel(.unknown) == null);
    try testing.expectEqualStrings("Critical priority", FirmwarePage.urgencyLabel(.critical).?);
    try testing.expectEqualStrings(
        "This release requires approval before it can be installed",
        FirmwarePage.blockedReason(enums.TrustFlags.blocked_approval),
    );
    try testing.expectEqualStrings(
        "This version is blocked on this device",
        FirmwarePage.blockedReason(enums.TrustFlags.blocked_version),
    );
}

test "firmware collectLoad filters updatable devices and attaches badges" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fake = fwupd.FakeBackend{
        .devices = &.{
            .{ .device_id = "dev1", .flags = enums.DeviceFlags.updatable },
            .{ .device_id = "dev2", .flags = enums.DeviceFlags.internal },
            .{ .device_id = "dev3", .flags = enums.DeviceFlags.updatable_hidden },
        },
        .upgrades = &.{.{ .version = "2.0", .trust_flags = enums.TrustFlags.is_upgrade }},
    };
    const data = try FirmwarePage.collectLoad(fake.backend(), arena.allocator());
    try testing.expectEqual(@as(usize, 2), data.devices.len);
    try testing.expectEqualStrings("dev1", data.devices[0].device_id);
    try testing.expectEqualStrings("dev3", data.devices[1].device_id);
    try testing.expect(data.badges[0].has_upgrade);
    try testing.expectEqualStrings("2.0", data.badges[0].latest_version);
    try testing.expect(data.badges[1].has_upgrade);
}

test "firmware collectLoad degrades badge errors and propagates connect failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fake = fwupd.FakeBackend{
        .devices = &.{.{ .device_id = "dev1", .flags = enums.DeviceFlags.updatable }},
        .upgrades_error = .not_supported,
    };
    const data = try FirmwarePage.collectLoad(fake.backend(), arena.allocator());
    try testing.expectEqual(@as(usize, 1), data.devices.len);
    try testing.expect(!data.badges[0].has_upgrade);

    fake.upgrades_error = .internal;
    const degraded = try FirmwarePage.collectLoad(fake.backend(), arena.allocator());
    try testing.expect(!degraded.badges[0].has_upgrade);

    fake.connect_error = .internal;
    try testing.expectError(error.CallFailed, FirmwarePage.collectLoad(fake.backend(), arena.allocator()));
}

test "firmware load result is discarded when its generation is stale" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{};
    p.backend = fake.backend();
    p.generation = 7;

    const arena = try c_alloc.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    const devices = try arena.allocator().alloc(models.Device, 1);
    devices[0] = .{ .device_id = "dev1", .name = "Device", .flags = enums.DeviceFlags.updatable };
    const badges = try arena.allocator().alloc(DeviceObject.Badge, 1);
    badges[0] = .{};
    const result = try c_alloc.create(FirmwarePage.LoadResult);
    result.* = .{
        .page = page,
        .arena = arena,
        .generation = 6,
        .data = .{ .devices = devices, .badges = badges },
        .failure = null,
    };
    // Stale: the arena must be freed (testing.allocator catches leaks) and
    // nothing may reach the store.
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_load_complete(result));
    try testing.expectEqual(@as(c_uint, 0), gio.ListModel.getNItems(p.list_store.as(gio.ListModel)));
    try testing.expect(p.arena == null);
}

test "firmware load result applies on matching generation with upgrades first" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{
        .releases = &.{.{ .version = "2.0", .trust_flags = enums.TrustFlags.is_upgrade }},
    };
    p.backend = fake.backend();
    p.generation = 7;
    p.loaded = true;
    defer {
        p.generation += 1;
        p.loaded = false;
        FirmwarePage.setSelectedId(page, null);
        FirmwarePage.clear_data(page);
    }

    const arena = try c_alloc.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    const devices = try arena.allocator().alloc(models.Device, 2);
    devices[0] = .{ .device_id = "dev1", .name = "First", .flags = enums.DeviceFlags.updatable };
    devices[1] = .{ .device_id = "dev2", .name = "Second", .flags = enums.DeviceFlags.updatable };
    const badges = try arena.allocator().alloc(DeviceObject.Badge, 2);
    badges[0] = .{};
    badges[1] = .{ .has_upgrade = true, .latest_version = "2.0" };
    const result = try c_alloc.create(FirmwarePage.LoadResult);
    result.* = .{
        .page = page,
        .arena = arena,
        .generation = 7,
        .data = .{ .devices = devices, .badges = badges },
        .failure = null,
    };
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_load_complete(result));
    try testing.expectEqual(@as(c_uint, 2), gio.ListModel.getNItems(p.list_store.as(gio.ListModel)));
    try testing.expect(p.arena != null);
    try testing.expect(fake.callbacks.on_device_added != null);

    // Upgrades-first sorting: dev2 (badge) precedes dev1 in the sorted model.
    const sorted = p.sort_model.as(gio.ListModel);
    const first = FirmwarePage.modelItem(sorted, 0).?;
    defer first.unref();
    const first_obj = gobject.ext.cast(DeviceObject, first).?;
    try testing.expectEqualStrings("dev2", first_obj.getDeviceId());
}

test "firmware selection changes keep model items alive" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{};
    p.backend = fake.backend();
    p.generation = 7;
    p.loaded = true;
    defer {
        p.generation += 1;
        p.loaded = false;
        FirmwarePage.setSelectedId(page, null);
        FirmwarePage.clear_data(page);
    }

    const arena = try c_alloc.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    const devices = try arena.allocator().alloc(models.Device, 2);
    devices[0] = .{ .device_id = "dev1", .name = "First", .flags = enums.DeviceFlags.updatable };
    devices[1] = .{ .device_id = "dev2", .name = "Second", .flags = enums.DeviceFlags.updatable };
    const badges = try arena.allocator().alloc(DeviceObject.Badge, 2);
    badges[0] = .{};
    badges[1] = .{};
    const result = try c_alloc.create(FirmwarePage.LoadResult);
    result.* = .{
        .page = page,
        .arena = arena,
        .generation = 7,
        .data = .{ .devices = devices, .badges = badges },
        .failure = null,
    };
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_load_complete(result));

    // The selection must add exactly one ref to the newly selected item and
    // give it back on deselect; a stolen ref shows up as a missing delta long
    // before the depleted object crashes a later ref or the store teardown.
    const sorted = p.sort_model.as(gio.ListModel);
    const first = FirmwarePage.modelItem(sorted, 0).?;
    const second = FirmwarePage.modelItem(sorted, 1).?;
    defer first.unref();
    defer second.unref();
    const base_first = first.f_ref_count;
    const base_second = second.f_ref_count;

    gtk.SingleSelection.setSelected(p.selection, 1);
    try testing.expectEqual(base_second + 1, second.f_ref_count);
    try testing.expectEqual(base_first, first.f_ref_count);
    gtk.SingleSelection.setSelected(p.selection, std.math.maxInt(c_uint));
    try testing.expectEqual(base_second, second.f_ref_count);
    for (0..50) |_| {
        _ = glib.MainContext.default().iteration(0);
        glib.usleep(10_000);
    }
}

test "firmware detail collapses empty text and keeps labels selectable" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const p = page.priv();

    const bare = DeviceObject.new(alloc, .{ .device_id = "dev1", .name = "Database Key", .version = "2025" }, .{}, 0);
    defer bare.as(gobject.Object).unref();
    FirmwarePage.render_device_info(page, bare);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(p.detail_vendor.as(gtk.Widget)));
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(p.detail_summary.as(gtk.Widget)));

    const full = DeviceObject.new(alloc, .{
        .device_id = "dev2",
        .name = "KEK CA",
        .vendor = "Microsoft",
        .summary = "Key Exchange Key",
        .version = "2011",
    }, .{}, 1);
    defer full.as(gobject.Object).unref();
    FirmwarePage.render_device_info(page, full);
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(p.detail_vendor.as(gtk.Widget)));
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(p.detail_summary.as(gtk.Widget)));

    // Title, vendor and summary must be copyable for web searches.
    try testing.expectEqual(@as(c_int, 1), gtk.Label.getSelectable(p.detail_name));
    try testing.expectEqual(@as(c_int, 1), gtk.Label.getSelectable(p.detail_vendor));
    try testing.expectEqual(@as(c_int, 1), gtk.Label.getSelectable(p.detail_summary));
}

test "firmware rows bind device and release data" {
    try gtk_test.requireDisplay();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const device = models.Device{
        .device_id = "dev1",
        .name = "System Firmware",
        .summary = "UEFI ESRT",
        .version = "1.0",
        .flags = enums.DeviceFlags.updatable | enums.DeviceFlags.end_of_life,
    };
    const object = DeviceObject.new(alloc, device, .{ .has_upgrade = true, .latest_version = "1.1" }, 0);
    defer object.as(gobject.Object).unref();
    const device_grid = FirmwarePage.buildDeviceRow();
    _ = device_grid.as(gobject.Object).refSink();
    defer device_grid.as(gobject.Object).unref();
    FirmwarePage.bindDeviceRow(device_grid, object);
    const text_box = gobject.ext.cast(gtk.Box, gtk.Grid.getChildAt(device_grid, 1, 0).?).?;
    const name = gobject.ext.cast(gtk.Label, gtk.Widget.getFirstChild(text_box.as(gtk.Widget)).?).?;
    const summary = gobject.ext.cast(gtk.Label, gtk.Widget.getNextSibling(name.as(gtk.Widget)).?).?;
    try testing.expectEqualStrings("System Firmware", std.mem.span(gtk.Label.getLabel(name)));
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(summary.as(gtk.Widget)));
    const bottom = gobject.ext.cast(gtk.Box, gtk.Grid.getChildAt(device_grid, 1, 1).?).?;
    const current = gtk.Widget.getFirstChild(bottom.as(gtk.Widget)).?;
    const arrow = gtk.Widget.getNextSibling(current).?;
    const latest = gtk.Widget.getNextSibling(arrow).?;
    const badges = gobject.ext.cast(gtk.Label, gtk.Widget.getNextSibling(latest).?).?;
    try testing.expectEqualStrings("1.0", std.mem.span(gtk.Label.getLabel(gobject.ext.cast(gtk.Label, current).?)));
    try testing.expectEqualStrings("1.1", std.mem.span(gtk.Label.getLabel(gobject.ext.cast(gtk.Label, latest).?)));
    try testing.expectEqualStrings("End of life", std.mem.span(gtk.Label.getLabel(badges)));

    // A device without a summary hides the label instead of leaving a gap.
    const plain = DeviceObject.new(alloc, .{ .device_id = "dev2", .name = "Plain device", .version = "2.0" }, .{}, 1);
    defer plain.as(gobject.Object).unref();
    FirmwarePage.bindDeviceRow(device_grid, plain);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(summary.as(gtk.Widget)));
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(arrow));
    FirmwarePage.bindDeviceRow(device_grid, object);
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(summary.as(gtk.Widget)));

    const release = models.Release{
        .version = "1.1",
        .summary = "Security fixes",
        .trust_flags = enums.TrustFlags.is_upgrade,
        .urgency = .high,
        .size = 2048,
    };
    const release_obj = ReleaseObject.new(alloc, device, release);
    defer release_obj.as(gobject.Object).unref();
    const release_grid = FirmwarePage.buildReleaseRow();
    _ = release_grid.as(gobject.Object).refSink();
    defer release_grid.as(gobject.Object).unref();
    FirmwarePage.bindReleaseRow(release_grid, release_obj, 0);
    const action = gobject.ext.cast(gtk.Button, gtk.Grid.getChildAt(release_grid, 3, 0).?).?;
    const release_version_box = gobject.ext.cast(gtk.Box, gtk.Grid.getChildAt(release_grid, 0, 0).?).?;
    const release_version = gobject.ext.cast(gtk.Label, gtk.Widget.getFirstChild(release_version_box.as(gtk.Widget)).?).?;
    const urgency = gobject.ext.cast(gtk.Label, gtk.Widget.getNextSibling(gtk.Widget.getFirstChild(release_version_box.as(gtk.Widget)).?).?).?;
    const release_text_box = gobject.ext.cast(gtk.Box, gtk.Grid.getChildAt(release_grid, 1, 0).?).?;
    const release_summary = gobject.ext.cast(gtk.Label, gtk.Widget.getFirstChild(release_text_box.as(gtk.Widget)).?).?;
    const release_badges = gobject.ext.cast(gtk.Label, gtk.Widget.getNextSibling(gtk.Widget.getFirstChild(release_text_box.as(gtk.Widget)).?).?).?;
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(urgency.as(gtk.Widget)));
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(release_badges.as(gtk.Widget)));
    // Version and summary stay copyable for web searches.
    try testing.expectEqual(@as(c_int, 1), gtk.Label.getSelectable(release_version));
    try testing.expectEqual(@as(c_int, 1), gtk.Label.getSelectable(release_summary));
    try testing.expectEqualStrings("Update", std.mem.span(gtk.Button.getLabel(action).?));
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getSensitive(action.as(gtk.Widget)));
    // Device problems gate the action button.
    FirmwarePage.bindReleaseRow(release_grid, release_obj, 1);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getSensitive(action.as(gtk.Widget)));

    const blocked = ReleaseObject.new(alloc, device, .{
        .version = "0.9",
        .trust_flags = enums.TrustFlags.is_downgrade | enums.TrustFlags.blocked_version,
    });
    defer blocked.as(gobject.Object).unref();
    FirmwarePage.bindReleaseRow(release_grid, blocked, 0);
    try testing.expectEqualStrings("Blocked", std.mem.span(gtk.Button.getLabel(action).?));
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getSensitive(action.as(gtk.Widget)));

    // Unknown urgency and a trust badge swap which sub-labels are shown.
    const community = ReleaseObject.new(alloc, device, .{
        .version = "1.2",
        .trust_flags = enums.TrustFlags.is_upgrade | enums.TrustFlags.is_community,
    });
    defer community.as(gobject.Object).unref();
    FirmwarePage.bindReleaseRow(release_grid, community, 0);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(urgency.as(gtk.Widget)));
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(release_badges.as(gtk.Widget)));
    try testing.expectEqualStrings("Community supported", std.mem.span(gtk.Label.getLabel(release_badges)));
}