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
const fwupd_download = @import("../services/fwupd_download.zig");
const DBus = @import("../services/dbus.zig").DBus;
const features = @import("../services/build_features.zig");
const runtime = @import("../services/runtime.zig");
const ConfirmDialog = @import("../dialog/page/yn_dialog.zig").ConfirmDialog;
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
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
        progress_box: *gtk.Box,
        progress_label: *gtk.Label,
        progress_bar: *gtk.ProgressBar,
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
        detail_link: *gtk.Label,
        detail_warning: *gtk.Label,
        detail_no_releases: *gtk.Label,
        release_scroll: *gtk.ScrolledWindow,
        release_list: *gtk.ListView,
        empty_page: *gtk.Box,
        error_page: *gtk.Box,
        error_label: *gtk.Label,
        installing_page: *gtk.Box,
        installing_spinner: *gtk.Spinner,
        installing_device_label: *gtk.Label,
        installing_version_label: *gtk.Label,
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
        state: PageState,
        updating_store: bool,
        install: ?*InstallState,
        install_flash_started: bool,
        download_pct: u32,
        dialog_active: bool,
        deferred_reload: bool,
        refreshing: bool,
        metadata_stale: bool,
        /// Set from runtime on first map; null in headless tests so workers
        /// never touch the undefined runtime globals.
        env: ?*const std.process.Environ.Map,
        last_busy: bool,
        dialog_queue: std.ArrayListUnmanaged(QueuedDialog),
        var offset: c_int = 0;
    };

    const PageState = enum { Loading, Loaded, Fail, Empty, Installing };

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
        p.state = .Loading;
        p.updating_store = false;
        p.install = null;
        p.install_flash_started = false;
        p.download_pct = 0;
        p.dialog_active = false;
        p.deferred_reload = false;
        p.refreshing = false;
        p.metadata_stale = false;
        p.env = null;
        p.last_busy = false;
        p.dialog_queue = .empty;
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

        _ = gobject.signalConnectData(
            p.detail_link.as(gobject.Object),
            "activate-link",
            @ptrCast(&on_info_link),
            null,
            null,
            .{},
        );

        support.connectLifecycle(Self, self);
    }

    // -----------------------------------------------------------------------
    // Lifecycle + load flow
    // -----------------------------------------------------------------------

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
        if (p.env == null) p.env = runtime.environ_map;
        // The daemon queues method calls behind a running install, so a load
        // started here would block until it finishes. Render the install from
        // the snapshot and live signals instead; the finish path reloads.
        if (p.install != null) {
            show_install_view(self);
            return;
        }
        start_load(self);
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;
        p.generation += 1;
        p.detail_generation += 1;
        // The client itself stays alive: in-flight workers still use it and
        // the connection is the shared GDBus singleton. While an install is in
        // flight the signal subscription stays too, so the reboot prompt and
        // post-install requests survive navigating away.
        if (p.install == null) p.backend.unsubscribeSignals();
        clear_data(self);
    }

    /// Free what Private owns. Template children (and the models they ref)
    /// are already disposed by GtkWidget, so no GTK calls here; the stores
    /// were emptied on unmap, which makes the arena teardown safe.
    fn finalize(object: *gobject.Object) callconv(.c) void {
        const parent_oc: *gobject.Object.Class = @ptrCast(Class.parent);
        const self = gobject.ext.cast(Self, object) orelse {
            parent_oc.f_finalize.?(object);
            return;
        };
        const p = self.priv();
        if (p.arena) |arena| {
            arena.deinit();
            c_alloc.destroy(arena);
            p.arena = null;
        }
        if (p.detail_arena) |arena| {
            arena.deinit();
            c_alloc.destroy(arena);
            p.detail_arena = null;
        }
        setSelectedId(self, null);
        clearDialogQueue(self);
        p.dialog_queue.deinit(c_alloc);
        if (p.install) |state| {
            p.install = null;
            freeInstallState(state);
        }
        p.client.deinit();
        parent_oc.f_finalize.?(object);
    }

    fn clear_data(self: *Self) void {
        const p = self.priv();
        p.updating_store = true;
        gio.ListStore.removeAll(p.list_store);
        gio.ListStore.removeAll(p.release_store);
        p.updating_store = false;
        hide_progress(self);
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
        gtk.Widget.setVisible(p.detail_link.as(gtk.Widget), 0);
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
        metadata_stale: bool,
    };

    fn load_worker(page: *Self, generation: u64) void {
        const arena = c_alloc.create(std.heap.ArenaAllocator) catch return;
        arena.* = std.heap.ArenaAllocator.init(c_alloc);
        const alloc = arena.allocator();
        const backend = page.priv().backend;
        const env = page.priv().env;
        const data = collectLoad(backend, alloc) catch {
            var failure: ?fwupd.Failure = null;
            if (backend.lastFailure()) |f| {
                failure = .{ .kind = f.kind, .message = alloc.dupe(u8, f.message) catch "" };
            }
            post_result(page, arena, generation, null, failure, false);
            return;
        };
        // Stale-metadata check for the automatic on-load refresh; the manual
        // button ignores the throttle.
        var metadata_stale = false;
        if (env) |e| {
            var threaded: std.Io.Threaded = .init(alloc, .{});
            defer threaded.deinit();
            const io = threaded.io();
            const last = fwupd_download.readLastRefresh(io, alloc, e);
            const now = std.Io.Clock.real.now(io).toSeconds();
            metadata_stale = fwupd_download.shouldAutoRefresh(last, now);
        }
        post_result(page, arena, generation, data, null, metadata_stale);
    }

    fn post_result(page: *Self, arena: *std.heap.ArenaAllocator, generation: u64, data: ?LoadData, failure: ?fwupd.Failure, metadata_stale: bool) void {
        const result = c_alloc.create(LoadResult) catch {
            arena.deinit();
            c_alloc.destroy(arena);
            return;
        };
        result.* = .{ .page = page, .arena = arena, .generation = generation, .data = data, .failure = failure, .metadata_stale = metadata_stale };
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
        p.metadata_stale = result.metadata_stale;
        c_alloc.destroy(result);

        p.props = p.backend.props();
        p.backend.subscribeSignals(signalCallbacks(page));
        update_summary(page);
        update_banner(page);
        if (load.devices.len == 0) {
            set_state(page, .Empty);
            maybe_auto_refresh(page);
            return 0;
        }
        set_state(page, .Loaded);
        restore_selection(page);
        queue_scroll_settle(page);
        maybe_auto_refresh(page);
        return 0;
    }

    const ScrollCtx = struct {
        page: *Self,
        generation: u64,

        /// Runs when the idle source is destroyed, whether it fired or was
        /// removed, so the page reference and the context always pair up.
        fn destroy(data: ?*anyopaque) callconv(.c) void {
            const ctx: *ScrollCtx = @ptrCast(@alignCast(data.?));
            ctx.page.as(gobject.Object).unref();
            c_alloc.destroy(ctx);
        }
    };

    /// The ListView anchors its scroll to the row that was on top when the
    /// sort model reorders, which can leave a fresh load scrolled past the
    /// upgrades. Settle the position once the sort idles have run.
    fn queue_scroll_settle(page: *Self) void {
        const ctx = c_alloc.create(ScrollCtx) catch return;
        ctx.* = .{ .page = page, .generation = page.priv().generation };
        // The idle can fire after the last external reference is gone; hold
        // one so the callback never touches a finalized page.
        _ = page.as(gobject.Object).ref();
        _ = glib.idleAddFull(glib.PRIORITY_DEFAULT_IDLE, &on_scroll_settle, ctx, &ScrollCtx.destroy);
    }

    fn on_scroll_settle(data: ?*anyopaque) callconv(.c) c_int {
        const ctx: *ScrollCtx = @ptrCast(@alignCast(data.?));
        const page = ctx.page;
        const p = page.priv();
        if (ctx.generation != p.generation or !p.loaded) return 0;
        const pos = if (p.selected_id != null) gtk.SingleSelection.getSelected(p.selection) else 0;
        if (pos != invalid_position) gtk.ListView.scrollTo(p.device_list, pos, .{}, null);
        return 0;
    }

    fn set_state(self: *Self, state: PageState) void {
        const p = self.priv();
        p.state = state;
        const busy = state == .Loading;
        if (busy) {
            gtk.Spinner.start(p.loading_spinner);
        } else {
            gtk.Spinner.stop(p.loading_spinner);
        }
        if (state == .Installing) {
            gtk.Spinner.start(p.installing_spinner);
        } else {
            gtk.Spinner.stop(p.installing_spinner);
        }
        update_header_spinner(p);
        gtk.Widget.setSensitive(p.refresh_button.as(gtk.Widget), @intFromBool(!busy and !isBusy(p)));
        const child: *gtk.Widget = switch (state) {
            .Loading => p.loading_page.as(gtk.Widget),
            .Loaded => p.content_page.as(gtk.Widget),
            .Fail => p.error_page.as(gtk.Widget),
            .Empty => p.empty_page.as(gtk.Widget),
            .Installing => p.installing_page.as(gtk.Widget),
        };
        gtk.Stack.setVisibleChild(p.page_stack, child);
    }

    /// Rebuild the mid-install view after a remap without any daemon calls:
    /// device/release come from the consent-time snapshot, progress from the
    /// last marshaled worker update and the daemon property signals.
    fn show_install_view(self: *Self) void {
        const p = self.priv();
        const state = p.install orelse return;
        var buf: [512]u8 = undefined;
        const name = std.fmt.bufPrintSentinel(&buf, "{s}", .{state.device.name}, 0) catch "";
        gtk.Label.setLabel(p.installing_device_label, name);
        const versions = std.fmt.bufPrintSentinel(&buf, "{s} → {s}", .{ state.device.version, state.release.version }, 0) catch "";
        gtk.Label.setLabel(p.installing_version_label, versions);
        set_state(self, .Installing);
        gtk.Widget.setVisible(p.progress_box.as(gtk.Widget), 1);
        if (p.install_flash_started) {
            update_flash_progress(self);
        } else if (p.download_pct > 0) {
            const text = std.fmt.bufPrintSentinel(&buf, "{s} {d}%", .{ translations._("Downloading…"), p.download_pct }, 0) catch translations._("Downloading…");
            gtk.Label.setLabel(p.progress_label, text);
            gtk.ProgressBar.setFraction(p.progress_bar, @as(f64, @floatFromInt(p.download_pct)) / 100.0);
        } else {
            gtk.Label.setLabel(p.progress_label, translations._("Downloading…"));
            gtk.ProgressBar.setFraction(p.progress_bar, 0);
            gtk.ProgressBar.pulse(p.progress_bar);
        }
        update_busy_ui(self);
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
        start_refresh(self, true);
    }

    // -----------------------------------------------------------------------
    // Metadata refresh (manual button + automatic stale check)
    // -----------------------------------------------------------------------

    fn update_header_spinner(p: *Private) void {
        const active = p.loading or p.refreshing;
        if (active) {
            gtk.Spinner.start(p.header_spinner);
        } else {
            gtk.Spinner.stop(p.header_spinner);
        }
        gtk.Widget.setVisible(p.header_spinner.as(gtk.Widget), @intFromBool(active));
    }

    /// Page banner: the system battery warning (live from daemon properties)
    /// plus the stale-metadata note. Battery comes first: it blocks updates
    /// until AC power is connected.
    fn update_banner(self: *Self) void {
        const p = self.priv();
        var parts: [3][]const u8 = undefined;
        var n: usize = 0;
        var stale_text: ?[]const u8 = null;
        defer if (stale_text) |t| c_alloc.free(t);
        if (models.batteryTooLow(p.props)) {
            parts[n] = translations._("Battery too low: connect AC power before updating firmware");
            n += 1;
        }
        if (p.metadata_stale and !p.refreshing) {
            stale_text = fillTemplate(c_alloc, translations._("Firmware metadata is out of date. Use {s} to refresh."), &.{translations._("Check Again")}) catch null;
            if (stale_text) |t| {
                parts[n] = t;
                n += 1;
            }
        }
        // The transient daemon emits Status=shutdown before it exits; the
        // cached list stays browsable but is stale until the next reconnect.
        if (p.loaded and !p.loading and !p.refreshing and p.props.status == .shutdown) {
            parts[n] = translations._("The firmware service stopped. Use Check Again to reconnect.");
            n += 1;
        }
        if (n > 0) blk: {
            var buf: [768]u8 = undefined;
            var off: usize = 0;
            for (parts[0..n], 0..) |part, i| {
                const sep = if (i > 0) "\n" else "";
                const written = std.fmt.bufPrintSentinel(buf[off..], "{s}{s}", .{ sep, part }, 0) catch break :blk;
                off += written.len;
            }
            gtk.Label.setLabel(p.banner_label, buf[0..off :0]);
        }
        gtk.Widget.setVisible(p.banner_box.as(gtk.Widget), @intFromBool(n > 0));
    }

    fn maybe_auto_refresh(self: *Self) void {
        const p = self.priv();
        if (!p.metadata_stale or p.env == null or p.loading or isBusy(p)) return;
        start_refresh(self, false);
    }

    /// Manual press always refreshes (bypasses the 24 h throttle) and doubles
    /// as the Fail-state retry; the automatic path only calls this when stale.
    /// `manual` decides whether failures surface as a dialog or just a log.
    fn start_refresh(self: *Self, manual: bool) void {
        const p = self.priv();
        if (p.refreshing or p.loading or isBusy(p)) return;
        const env = p.env orelse return;
        p.refreshing = true;
        update_busy_ui(self);
        update_banner(self);
        _ = self.as(gobject.Object).ref();
        const thread = std.Thread.spawn(.{}, refresh_worker, .{ self, p.generation, env, manual }) catch {
            self.as(gobject.Object).unref();
            p.refreshing = false;
            update_busy_ui(self);
            update_banner(self);
            return;
        };
        thread.detach();
    }

    fn refresh_worker(page: *Self, generation: u64, env: *const std.process.Environ.Map, manual: bool) void {
        var arena = std.heap.ArenaAllocator.init(c_alloc);
        defer arena.deinit();
        const alloc = arena.allocator();
        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();
        const backend = page.priv().backend;
        const props = backend.props();
        const user_agent = alloc.print("shelly/{f} fwupd/{s}", .{ features.version, props.daemon_version }) catch "shelly fwupd";
        var failure_text: ?[:0]const u8 = null;
        const outcome = fwupd_download.refreshMetadata(backend, alloc, threaded.io(), env, user_agent) catch |err| blk: {
            failure_text = installFailureText(err, backend.lastFailure());
            break :blk fwupd_download.RefreshOutcome{};
        };
        const result = c_alloc.create(RefreshResult) catch {
            page.as(gobject.Object).unref();
            return;
        };
        result.* = .{ .page = page, .generation = generation, .outcome = outcome, .failure_text = failure_text, .manual = manual };
        _ = glib.idleAdd(&on_refresh_complete, result);
    }

    const RefreshResult = struct {
        page: *Self,
        generation: u64,
        outcome: fwupd_download.RefreshOutcome,
        failure_text: ?[:0]const u8,
        manual: bool,
    };

    fn on_refresh_complete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *RefreshResult = @ptrCast(@alignCast(data.?));
        defer c_alloc.destroy(result);
        const page = result.page;
        defer page.as(gobject.Object).unref();
        const p = page.priv();
        p.refreshing = false;
        update_busy_ui(page);
        const matched = result.generation == p.generation and p.loaded;
        if (result.failure_text) |text| {
            log.warn("Firmware metadata refresh failed: {s}", .{text});
            update_banner(page);
            if (matched and result.manual) {
                enqueueInfo(page, translations._("Metadata refresh failed"), text);
                pumpDialogs(page);
            }
            return 0;
        }
        const outcome = result.outcome;
        // Nothing to refresh (no download remotes) or everything skipped means
        // the catalog is as current as it can get; only failures keep the banner.
        if (outcome.failed == 0 or outcome.succeeded > 0) {
            p.metadata_stale = false;
        }
        update_banner(page);
        if (matched and result.manual and outcome.succeeded == 0 and outcome.failed > 0) {
            enqueueInfo(page, translations._("Metadata refresh failed"), translations._("Could not refresh the firmware catalog. Check your network connection and try again."));
            pumpDialogs(page);
        }
        // A manual press always re-checks devices, even when every remote
        // skipped: the daemon may have restarted with a different device set
        // while the catalog stayed current. The automatic path only reloads
        // when the catalog actually changed (or the page needs a retry).
        if (matched and (result.manual or outcome.succeeded > 0 or p.state == .Fail)) {
            start_load(page);
        }
        return 0;
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
            gtk.Widget.setVisible(p.detail_link.as(gtk.Widget), 0);
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
        // Device read-more link derives from the fetched releases (devices carry no
        // AppstreamId). Hide it when no release qualifies so a stale link never lingers.
        if (models.deviceInfoUrl(result.arena.allocator(), releases)) |url| {
            gtk.Label.setMarkup(p.detail_link, infoLinkMarkup(result.arena.allocator(), url, translations._("View on LVFS")));
            gtk.Widget.setVisible(p.detail_link.as(gtk.Widget), 1);
        } else {
            gtk.Widget.setVisible(p.detail_link.as(gtk.Widget), 0);
        }
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

    fn sig_device_request(user_data: ?*anyopaque, request: models.Request) void {
        const self: *Self = @ptrCast(@alignCast(user_data.?));
        const p = self.priv();
        if (request.kind == .post) {
            // Post-install requests drain after the install finishes; outside
            // an install they belong to another client's flow.
            if (p.install) |state| {
                const alloc = state.arena.allocator();
                const copy = copyRequest(alloc, request) catch return;
                state.post_requests.append(alloc, copy) catch return;
            } else {
                log.debug("Ignoring post-install request outside an install: {s}", .{request.appstream_id});
            }
            return;
        }
        // Immediate (and unknown kinds): show now, or queue behind an open dialog.
        if (!p.loaded and p.install == null) return;
        enqueueRequest(self, request);
        pumpDialogs(self);
    }

    fn sig_changed(user_data: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(user_data.?));
        const p = self.priv();
        if (!p.loaded) return;
        // Transient daemon went away or finished a job: full reconnect+reload.
        // Mid-install the reload waits so the generation stays stable under
        // the worker; the finish path refreshes anyway.
        if (p.install != null) {
            p.deferred_reload = true;
            return;
        }
        start_load(self);
    }

    fn sig_properties_changed(user_data: ?*anyopaque, props: models.DaemonProps) void {
        const self: *Self = @ptrCast(@alignCast(user_data.?));
        const p = self.priv();
        p.props = props;
        if (!p.loaded) return;
        if (p.install != null and p.install_flash_started) update_flash_progress(self);
        update_busy_ui(self);
        // The battery banner tracks the daemon power properties live.
        update_banner(self);
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
    // Install flow: consent dialogs -> download -> flash -> finish
    // -----------------------------------------------------------------------

    const DialogStep = enum { confirm, branch, fde };

    /// Snapshot of one install attempt. Owns an arena with the device/release
    /// copies (the page arenas may be reset under the worker) and any post
    /// requests collected while the install runs.
    pub const InstallState = struct {
        arena: std.heap.ArenaAllocator,
        device: models.Device,
        release: models.Release,
        options: fwupd.InstallOptions,
        step: DialogStep = .confirm,
        generation: u64 = 0,
        post_requests: std.ArrayListUnmanaged(models.Request) = .empty,
    };

    /// FIFO of page dialogs waiting for the lockout: device requests, info
    /// notes (errors, UpdateMessage) and the power consent prompt. Strings are
    /// c_allocator copies freed when the entry is shown.
    const QueuedDialog = union(enum) {
        request: models.Request,
        info: struct { title: [:0]const u8, text: []const u8 },
        power: struct { kind: models.PowerPrompt, capability: DBus.PowerCapability },
    };

    fn isBusy(p: *const Private) bool {
        if (p.install != null or p.refreshing) return true;
        return switch (p.props.status) {
            // Shutdown means the transient daemon is gone, not that it is
            // working: Check Again must stay available to reconnect.
            .idle, .unknown, .shutdown => false,
            else => true,
        };
    }

    fn update_busy_ui(self: *Self) void {
        const p = self.priv();
        const busy = isBusy(p);
        gtk.Widget.setSensitive(p.refresh_button.as(gtk.Widget), @intFromBool(!busy and !p.loading));
        update_header_spinner(p);
        if (busy != p.last_busy) {
            p.last_busy = busy;
            rebind_release_rows(self);
        }
    }

    /// Re-run the factory bind for every release row (busy state changed).
    /// Re-appending the same objects is the only way to rebind a ListView
    /// without resetting its model; the held refs keep them alive across the
    /// removeAll.
    fn rebind_release_rows(self: *Self) void {
        const p = self.priv();
        const model = p.release_store.as(gio.ListModel);
        const n = gio.ListModel.getNItems(model);
        if (n == 0) return;
        var items: std.ArrayListUnmanaged(*gobject.Object) = .empty;
        defer items.deinit(c_alloc);
        for (0..n) |i| {
            const item = modelItem(model, @intCast(i)) orelse continue;
            items.append(c_alloc, item) catch {
                item.unref();
                continue;
            };
        }
        gio.ListStore.removeAll(p.release_store);
        for (items.items) |item| {
            gio.ListStore.append(p.release_store, item);
            item.unref();
        }
    }

    fn beginInstall(self: *Self, device_object: *DeviceObject, release_object: *ReleaseObject) void {
        const p = self.priv();
        if (p.install != null or p.dialog_active or isBusy(p)) return;
        const classification = release_object.getClassification();
        if (classification == .blocked or classification == .other) return;
        // Problems gate: buttons are already disabled, guard again here.
        if (device_object.getProblems() != 0) return;

        const state = c_alloc.create(InstallState) catch return;
        state.* = .{
            .arena = std.heap.ArenaAllocator.init(c_alloc),
            .device = undefined,
            .release = undefined,
            .options = fwupd.optionsForAction(classification, false),
            .generation = p.generation,
        };
        const alloc = state.arena.allocator();
        state.device = copyDevice(alloc, device_object) catch {
            freeInstallState(state);
            return;
        };
        state.release = copyRelease(alloc, release_object) catch {
            freeInstallState(state);
            return;
        };
        p.install = state;
        p.install_flash_started = false;
        p.download_pct = 0;
        update_busy_ui(self);
        showInstallDialog(self);
    }

    fn copyDevice(alloc: std.mem.Allocator, object: *DeviceObject) std.mem.Allocator.Error!models.Device {
        return .{
            .device_id = try alloc.dupe(u8, object.getDeviceId()),
            .name = try alloc.dupe(u8, object.getName()),
            .vendor = try alloc.dupe(u8, object.getVendor()),
            .version = try alloc.dupe(u8, object.getVersion()),
            .branch = try alloc.dupe(u8, object.getBranch()),
            .flags = object.getFlags(),
            .problems = object.getProblems(),
        };
    }

    fn copyRelease(alloc: std.mem.Allocator, object: *ReleaseObject) std.mem.Allocator.Error!models.Release {
        const locations = try alloc.alloc([]const u8, object.getLocations().len);
        for (locations, object.getLocations()) |*slot, s| slot.* = try alloc.dupe(u8, s);
        return .{
            .version = try alloc.dupe(u8, object.getVersion()),
            .trust_flags = object.getTrustFlags(),
            .locations = locations,
            .uri = try alloc.dupe(u8, object.getUri()),
            .remote_id = try alloc.dupe(u8, object.getRemoteId()),
            .checksum = try alloc.dupe(u8, object.getChecksum()),
            .filename = try alloc.dupe(u8, object.getFilename()),
            .size = object.getSize(),
            .install_duration = object.getInstallDuration(),
            .branch = try alloc.dupe(u8, object.getBranch()),
            .update_message = try alloc.dupe(u8, object.getUpdateMessage()),
        };
    }

    fn copyRequest(alloc: std.mem.Allocator, request: models.Request) std.mem.Allocator.Error!models.Request {
        return .{
            .appstream_id = try alloc.dupe(u8, request.appstream_id),
            .update_message = try alloc.dupe(u8, request.update_message),
            .kind = request.kind,
        };
    }

    fn freeInstallState(state: *InstallState) void {
        state.arena.deinit();
        c_alloc.destroy(state);
    }

    fn abortInstall(self: *Self) void {
        const p = self.priv();
        if (p.install) |state| {
            p.install = null;
            freeInstallState(state);
        }
        hide_progress(self);
        update_busy_ui(self);
        pumpDialogs(self);
    }

    /// Runtime placeholder substitution for translated templates: Zig fmt
    /// needs comptime formats, but gettext strings must stay whole sentences
    /// so translators can reorder placeholders. Only {s} is handled; format
    /// numbers before passing them in. Templates are our own strings, never
    /// daemon data.
    fn fillTemplate(alloc: std.mem.Allocator, template: []const u8, args: []const []const u8) std.mem.Allocator.Error![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var rest = template;
        var arg_i: usize = 0;
        while (std.mem.indexOf(u8, rest, "{s}")) |i| {
            try out.appendSlice(alloc, rest[0..i]);
            if (arg_i < args.len) {
                try out.appendSlice(alloc, args[arg_i]);
                arg_i += 1;
            }
            rest = rest[i + "{s}".len ..];
        }
        try out.appendSlice(alloc, rest);
        return out.items;
    }

    /// Escape daemon-supplied names before interpolating them into Pango
    /// markup (precedent: pkg_build.zig).
    fn escapeMarkup(alloc: std.mem.Allocator, text: []const u8) []const u8 {
        const escaped = glib.markupEscapeText(@ptrCast(text.ptr), @intCast(text.len));
        defer glib.free(escaped);
        return alloc.dupe(u8, std.mem.span(escaped)) catch text;
    }

    fn showInstallDialog(self: *Self) void {
        const p = self.priv();
        const state = p.install orelse return;
        const win = support.getWindow(ShellyWindow, self) orelse {
            // Consent is mandatory; without a window there is no dialog.
            abortInstall(self);
            return;
        };
        const alloc = state.arena.allocator();
        const classification = models.classifyRelease(state.device, state.release);
        var dialog_title: [:0]const u8 = "";
        var dialog: *ConfirmDialog = undefined;
        switch (state.step) {
            .confirm => {
                const name = escapeMarkup(alloc, state.device.name);
                const version = escapeMarkup(alloc, state.release.version);
                const name_bold = alloc.print("<b>{s}</b>", .{name}) catch name;
                const version_bold = alloc.print("<b>{s}</b>", .{version}) catch version;
                const template: []const u8 = switch (classification) {
                    .upgrade => translations._("Update {s} to version {s}?"),
                    .downgrade => translations._("Downgrade {s} to version {s}?"),
                    .reinstall => translations._("Reinstall {s} version {s}?"),
                    else => "{s} {s}",
                };
                var body: std.ArrayListUnmanaged(u8) = .empty;
                body.appendSlice(alloc, fillTemplate(alloc, template, &.{ name_bold, version_bold }) catch "") catch {};
                body.appendSlice(alloc, "\n\n") catch {};
                const usable = enums.DeviceFlags.has(state.device.flags, enums.DeviceFlags.usable_during_update);
                body.appendSlice(alloc, if (usable)
                    translations._("The device will remain usable for the duration of the update.")
                else
                    translations._("The device will be unavailable during this action.")) catch {};
                if (state.release.size > 0) {
                    var size_buf: [32]u8 = undefined;
                    const size_text = size_helper.convert_null_term(&size_buf, @intCast(state.release.size));
                    body.appendSlice(alloc, "\n") catch {};
                    body.appendSlice(alloc, fillTemplate(alloc, translations._("Download size: {s}"), &.{size_text}) catch "") catch {};
                }
                if (state.release.install_duration > 0) {
                    var duration_buf: [16]u8 = undefined;
                    const duration_text = std.fmt.bufPrint(&duration_buf, "{d}", .{state.release.install_duration}) catch "0";
                    body.appendSlice(alloc, "\n") catch {};
                    body.appendSlice(alloc, fillTemplate(alloc, translations._("Estimated install time: {s} seconds"), &.{duration_text}) catch "") catch {};
                }
                const message = alloc.dupeSentinel(u8, body.items, 0) catch "";
                dialog_title = switch (classification) {
                    .upgrade => translations._("Update device"),
                    .downgrade => translations._("Downgrade device"),
                    .reinstall => translations._("Reinstall device"),
                    else => translations._("Install firmware"),
                };
                dialog = ConfirmDialog.new(dialog_title, message, &on_install_dialog_response, self);
                dialog.setMarkupMessage(message);
                dialog.setButtons(releaseActionLabel(classification) orelse translations._("Confirm"), translations._("Cancel"));
            },
            .branch => {
                dialog_title = translations._("Switch firmware branch?");
                const message: [:0]const u8 = if (state.device.vendor.len > 0)
                    alloc.dupeSentinel(u8, fillTemplate(alloc, translations._("This firmware is not supplied by {s}. Installing it may damage your hardware or void your warranty."), &.{state.device.vendor}) catch "", 0) catch ""
                else
                    translations._("This firmware comes from a different branch. Installing it may damage your hardware or void your warranty.");
                dialog = ConfirmDialog.new(dialog_title, message, &on_install_dialog_response, self);
                dialog.setButtons(translations._("Switch Branch"), translations._("Cancel"));
            },
            .fde => {
                dialog_title = translations._("You may lose all your data without recovery keys");
                dialog = ConfirmDialog.new(
                    dialog_title,
                    translations._("Updating this firmware may invalidate the secrets that unlock your encrypted drives. Make sure you have the recovery keys for all your encrypted drives before continuing."),
                    &on_install_dialog_response,
                    self,
                );
                dialog.setCheckLabel(translations._("I have recovery keys for all my encrypted drives"));
                dialog.setButtons(translations._("Continue"), translations._("Cancel"));
            },
        }
        p.dialog_active = true;
        win.showLockoutNamed(dialog.as(gtk.Widget), dialog_title);
    }

    fn on_install_dialog_response(ctx: ?*anyopaque, confirmed: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        const p = self.priv();
        if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
        p.dialog_active = false;
        const state = p.install orelse return;
        if (!confirmed) {
            abortInstall(self);
            return;
        }
        const dialogs = models.installDialogs(state.device, state.release);
        switch (state.step) {
            .confirm => {
                if (dialogs.branch_warning) {
                    state.step = .branch;
                    showInstallDialog(self);
                } else if (dialogs.fde_gate) {
                    state.step = .fde;
                    showInstallDialog(self);
                } else {
                    startInstallWorker(self);
                }
            },
            .branch => {
                state.options.allow_branch_switch = true;
                if (dialogs.fde_gate) {
                    state.step = .fde;
                    showInstallDialog(self);
                } else {
                    startInstallWorker(self);
                }
            },
            .fde => startInstallWorker(self),
        }
    }

    fn startInstallWorker(self: *Self) void {
        const p = self.priv();
        const state = p.install orelse return;
        show_progress(self, translations._("Downloading…"));
        // Immediate requests queued while the consent dialogs were up.
        pumpDialogs(self);
        _ = self.as(gobject.Object).ref();
        const thread = std.Thread.spawn(.{}, install_worker, .{ self, state }) catch {
            self.as(gobject.Object).unref();
            p.install = null;
            hide_progress(self);
            freeInstallState(state);
            update_busy_ui(self);
            enqueueInfo(self, translations._("Failed to install firmware"), translations._("Could not start the installation"));
            pumpDialogs(self);
            return;
        };
        thread.detach();
    }

    pub const InstallOutcome = struct {
        failure_text: ?[:0]const u8 = null,
        fresh_device: ?models.Device = null,
        capability: DBus.PowerCapability = .unknown,
    };

    pub const PowerProbe = *const fn (kind: models.PowerPrompt) DBus.PowerCapability;

    pub const StageHooks = struct {
        ctx: ?*anyopaque = null,
        on_flash_start: ?*const fn (ctx: ?*anyopaque) void = null,
    };

    /// GTK-free worker body: download, Install(fd), then the post-install
    /// double refresh (properties + device list) and an optional power
    /// capability probe. The probe is injected so tests never touch logind.
    pub fn runInstall(
        backend: fwupd.Backend,
        alloc: std.mem.Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
        state: *InstallState,
        user_agent: []const u8,
        progress: fwupd_download.Progress,
        hooks: StageHooks,
        probe: ?PowerProbe,
    ) InstallOutcome {
        const payload_path = fwupd_download.fetchPayload(backend, alloc, io, env, state.release, user_agent, progress) catch |err| {
            return .{ .failure_text = installFailureText(err, backend.lastFailure()) };
        };
        if (hooks.on_flash_start) |f| f(hooks.ctx);
        backend.install(alloc, state.device.device_id, payload_path, state.options) catch |err| {
            return .{ .failure_text = installFailureText(err, backend.lastFailure()) };
        };
        var outcome: InstallOutcome = .{};
        // Best-effort refresh: the daemon may have restarted (transient), and
        // the device flags now carry NEEDS_REBOOT/NEEDS_SHUTDOWN.
        _ = backend.connect(alloc) catch {};
        if (backend.getDevices(alloc)) |devices| {
            for (devices) |device| {
                if (std.mem.eql(u8, device.device_id, state.device.device_id)) {
                    outcome.fresh_device = device;
                    break;
                }
            }
        } else |_| {}
        const flags = (outcome.fresh_device orelse state.device).flags;
        const prompt = models.powerPrompt(flags);
        if (prompt != .none) {
            if (probe) |f| outcome.capability = f(prompt);
        }
        return outcome;
    }

    fn installFailureText(err: anyerror, failure: ?fwupd.Failure) [:0]const u8 {
        switch (err) {
            error.CallFailed, error.InvalidReply => {
                if (failure) |f| return models.errorText(f.kind);
                return models.errorText(.unknown);
            },
            error.BusUnavailable => return translations._("Could not reach the firmware service"),
            error.RemoteNotFound => return translations._("The firmware source for this release is unavailable"),
            error.NoPayloadLocation => return translations._("This release has no download location"),
            error.ReleaseWithoutChecksums => return translations._("This release provides no checksums, so it cannot be verified"),
            error.InvalidChecksum => return translations._("The release checksum is invalid"),
            error.ChecksumMismatch => return translations._("The downloaded firmware failed verification"),
            error.DownloadFailed => return translations._("The firmware download failed"),
            error.FileFailed, error.FileOpenFailed, error.FdAppendFailed => return translations._("Could not access the firmware cache"),
            else => return models.errorText(.unknown),
        }
    }

    fn realPowerProbe(kind: models.PowerPrompt) DBus.PowerCapability {
        var dbus = DBus{};
        defer dbus.deinit();
        return if (kind == .reboot) dbus.canReboot() else dbus.canPowerOff();
    }

    fn install_worker(page: *Self, state: *InstallState) void {
        const alloc = state.arena.allocator();
        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();
        const backend = page.priv().backend;
        const props = backend.props();
        const user_agent = alloc.print("shelly/{f} fwupd/{s}", .{ features.version, props.daemon_version }) catch "shelly fwupd";
        const outcome = runInstall(backend, alloc, threaded.io(), runtime.environ_map, state, user_agent, .{
            .ctx = page,
            .on_progress = &on_download_progress_worker,
        }, .{
            .ctx = page,
            .on_flash_start = &on_flash_start_worker,
        }, &realPowerProbe);
        post_install_result(page, state, outcome);
    }

    const InstallResult = struct {
        page: *Self,
        state: *InstallState,
        generation: u64,
        outcome: InstallOutcome,
    };

    fn post_install_result(page: *Self, state: *InstallState, outcome: InstallOutcome) void {
        const result = c_alloc.create(InstallResult) catch {
            state.arena.deinit();
            c_alloc.destroy(state);
            page.as(gobject.Object).unref();
            return;
        };
        result.* = .{ .page = page, .state = state, .generation = state.generation, .outcome = outcome };
        _ = glib.idleAdd(&on_install_complete, result);
    }

    fn on_install_complete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *InstallResult = @ptrCast(@alignCast(data.?));
        defer c_alloc.destroy(result);
        const page = result.page;
        defer page.as(gobject.Object).unref();
        const p = page.priv();
        const state = result.state;
        // The installing view survives unmap/remap, which bumps the generation
        // away from the snapshot; it must still reload when the result lands.
        const install_view = p.state == .Installing;
        p.install = null;
        hide_progress(page);
        update_busy_ui(page);

        if (result.outcome.failure_text) |text| {
            log.warn("Firmware install failed: {s}", .{text});
            if (p.loaded and (install_view or (result.generation == p.generation and p.deferred_reload))) start_load(page);
            p.deferred_reload = false;
            freeInstallState(state);
            if (!p.loaded) p.backend.unsubscribeSignals();
            enqueueInfo(page, translations._("Failed to install firmware"), text);
            pumpDialogs(page);
            return 0;
        }

        // Finish dialogs: post requests, UpdateMessage, power prompt. The
        // state's strings are copied into the queue so it can be freed now.
        const fresh = result.outcome.fresh_device orelse state.device;
        const steps = models.finishSteps(state.arena.allocator(), fresh.flags, state.release.update_message, state.post_requests.items) catch &.{};
        for (steps) |step| {
            switch (step) {
                .request => |request| enqueueRequest(page, request),
                .update_message => |text| enqueueInfo(page, translations._("Update complete"), text),
                .power => |kind| enqueuePower(page, kind, result.outcome.capability),
            }
        }
        freeInstallState(state);
        if (p.loaded and (result.generation == p.generation or install_view)) {
            // Post-install refresh of badges, versions and release lists.
            start_load(page);
        } else if (!p.loaded) {
            p.backend.unsubscribeSignals();
        }
        p.deferred_reload = false;
        pumpDialogs(page);
        return 0;
    }

    // -----------------------------------------------------------------------
    // Dialog queue (requests, info notes, power prompt)
    // -----------------------------------------------------------------------

    fn enqueueRequest(self: *Self, request: models.Request) void {
        const p = self.priv();
        const copy = copyRequest(c_alloc, request) catch return;
        p.dialog_queue.append(c_alloc, .{ .request = copy }) catch {
            freeQueuedDialog(.{ .request = copy });
        };
    }

    fn enqueueInfo(self: *Self, note_title: [:0]const u8, text: []const u8) void {
        const p = self.priv();
        const copy = c_alloc.dupe(u8, text) catch return;
        p.dialog_queue.append(c_alloc, .{ .info = .{ .title = note_title, .text = copy } }) catch {
            c_alloc.free(copy);
        };
    }

    fn enqueuePower(self: *Self, kind: models.PowerPrompt, capability: DBus.PowerCapability) void {
        const p = self.priv();
        p.dialog_queue.append(c_alloc, .{ .power = .{ .kind = kind, .capability = capability } }) catch {};
    }

    fn freeQueuedDialog(entry: QueuedDialog) void {
        switch (entry) {
            .request => |request| {
                c_alloc.free(request.appstream_id);
                c_alloc.free(request.update_message);
            },
            .info => |info| c_alloc.free(info.text),
            .power => {},
        }
    }

    fn clearDialogQueue(self: *Self) void {
        const p = self.priv();
        for (p.dialog_queue.items) |entry| freeQueuedDialog(entry);
        p.dialog_queue.clearRetainingCapacity();
    }

    fn pumpDialogs(self: *Self) void {
        const p = self.priv();
        if (p.dialog_active) return;
        while (p.dialog_queue.items.len > 0) {
            const entry = p.dialog_queue.orderedRemove(0);
            defer freeQueuedDialog(entry);
            // GTK copies the strings, so the entry can be freed right after
            // the dialog is built. No window (headless tests): skip and drain.
            if (showQueuedDialog(self, entry)) {
                p.dialog_active = true;
                return;
            }
        }
    }

    fn showQueuedDialog(self: *Self, entry: QueuedDialog) bool {
        const win = support.getWindow(ShellyWindow, self) orelse return false;
        switch (entry) {
            .request => |request| {
                const text = models.requestText(request);
                const text_z = c_alloc.dupeSentinel(u8, text, 0) catch return false;
                defer c_alloc.free(text_z);
                const req_title = translations._("Device request");
                const dialog = ConfirmDialog.new(req_title, text_z, &on_queue_response, self);
                dialog.setCancelVisible(false);
                dialog.setButtons(translations._("OK"), "");
                win.showLockoutNamed(dialog.as(gtk.Widget), req_title);
            },
            .info => |info| {
                const text_z = c_alloc.dupeSentinel(u8, info.text, 0) catch return false;
                defer c_alloc.free(text_z);
                const dialog = ConfirmDialog.new(info.title, text_z, &on_queue_response, self);
                dialog.setCancelVisible(false);
                dialog.setButtons(translations._("OK"), "");
                win.showLockoutNamed(dialog.as(gtk.Widget), info.title);
            },
            .power => |power| {
                const reboot = power.kind == .reboot;
                const power_title: [:0]const u8 = if (reboot)
                    translations._("Restart to complete this update")
                else
                    translations._("Shutdown to complete this update");
                var body: std.ArrayListUnmanaged(u8) = .empty;
                defer body.deinit(c_alloc);
                body.appendSlice(c_alloc, if (reboot)
                    translations._("You must restart your device to complete the update. Make sure your device is plugged in or fully charged. Save your files before you restart to avoid losing data.")
                else
                    translations._("You must shut down your device to complete the update. Save your files before you shut down to avoid losing data.")) catch return false;
                if (!power.capability.buttonEnabled()) {
                    body.appendSlice(c_alloc, "\n\n") catch return false;
                    body.appendSlice(c_alloc, if (reboot)
                        translations._("Automatic restart is not available on this system.")
                    else
                        translations._("Automatic shutdown is not available on this system.")) catch return false;
                }
                const body_z = c_alloc.dupeSentinel(u8, body.items, 0) catch return false;
                defer c_alloc.free(body_z);
                const ctx = c_alloc.create(PowerCtx) catch return false;
                ctx.* = .{ .page = self, .kind = power.kind };
                const dialog = ConfirmDialog.new(power_title, body_z, &on_power_response, ctx);
                if (!power.capability.buttonEnabled()) dialog.setConfirmSensitive(false);
                dialog.setButtons(
                    if (reboot) translations._("Restart now") else translations._("Shut down now"),
                    if (reboot) translations._("Restart later") else translations._("Shut down later"),
                );
                win.showLockoutNamed(dialog.as(gtk.Widget), power_title);
            },
        }
        return true;
    }

    fn on_queue_response(ctx: ?*anyopaque, _: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        const p = self.priv();
        if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
        p.dialog_active = false;
        pumpDialogs(self);
    }

    const PowerCtx = struct { page: *Self, kind: models.PowerPrompt };

    fn on_power_response(ctx_ptr: ?*anyopaque, confirmed: bool) void {
        const ctx: *PowerCtx = @ptrCast(@alignCast(ctx_ptr.?));
        defer c_alloc.destroy(ctx);
        const self = ctx.page;
        const p = self.priv();
        if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
        p.dialog_active = false;
        if (!confirmed) {
            pumpDialogs(self);
            return;
        }
        _ = self.as(gobject.Object).ref();
        const thread = std.Thread.spawn(.{}, power_worker, .{ self, ctx.kind }) catch {
            self.as(gobject.Object).unref();
            pumpDialogs(self);
            return;
        };
        thread.detach();
    }

    fn power_worker(page: *Self, kind: models.PowerPrompt) void {
        var dbus = DBus{};
        defer dbus.deinit();
        // Interactive polkit: from an active local session allow_active=yes
        // executes without a prompt, so the now/later dialog was the consent.
        const outcome = if (kind == .reboot) dbus.reboot(true) else dbus.powerOff(true);
        const result = c_alloc.create(PowerResult) catch {
            page.as(gobject.Object).unref();
            return;
        };
        result.* = .{ .page = page, .kind = kind, .outcome = outcome };
        _ = glib.idleAdd(&on_power_complete, result);
    }

    const PowerResult = struct { page: *Self, kind: models.PowerPrompt, outcome: DBus.PowerOutcome };

    fn on_power_complete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *PowerResult = @ptrCast(@alignCast(data.?));
        defer c_alloc.destroy(result);
        const page = result.page;
        defer page.as(gobject.Object).unref();
        const reboot = result.kind == .reboot;
        switch (result.outcome) {
            .success => return 0, // the system is going down
            .cancelled => enqueueInfo(
                page,
                if (reboot) translations._("Restart cancelled") else translations._("Shutdown cancelled"),
                if (reboot)
                    translations._("The restart was cancelled. Restart later to complete the firmware update.")
                else
                    translations._("The shutdown was cancelled. Shut down later to complete the firmware update."),
            ),
            .failed => enqueueInfo(
                page,
                if (reboot) translations._("Restart failed") else translations._("Shutdown failed"),
                translations._("The system did not accept the request. You can try again later."),
            ),
        }
        pumpDialogs(page);
        return 0;
    }

    // -----------------------------------------------------------------------
    // Progress UI (download stage from the counting writer, flash from props)
    // -----------------------------------------------------------------------

    fn show_progress(self: *Self, label: [:0]const u8) void {
        const p = self.priv();
        gtk.Label.setLabel(p.progress_label, label);
        gtk.ProgressBar.setFraction(p.progress_bar, 0);
        gtk.Widget.setVisible(p.progress_box.as(gtk.Widget), 1);
    }

    fn hide_progress(self: *Self) void {
        gtk.Widget.setVisible(self.priv().progress_box.as(gtk.Widget), 0);
    }

    fn update_flash_progress(self: *Self) void {
        const p = self.priv();
        const fraction = models.progressFraction(p.props);
        if (fraction > 0) {
            gtk.ProgressBar.setFraction(p.progress_bar, fraction);
        } else {
            gtk.ProgressBar.pulse(p.progress_bar);
        }
        gtk.Label.setLabel(p.progress_label, models.statusText(p.props.status));
    }

    const DownloadProgress = struct { page: *Self, install: ?*InstallState, received: u64, total: u64 };

    /// Worker-thread callback from the counting writer; marshals to the main
    /// loop (throttling already happened in the download service).
    fn on_download_progress_worker(ctx: ?*anyopaque, received: u64, total: u64) void {
        const page: *Self = @ptrCast(@alignCast(ctx.?));
        const progress = c_alloc.create(DownloadProgress) catch return;
        progress.* = .{ .page = page, .install = page.priv().install, .received = received, .total = total };
        _ = glib.idleAdd(&on_download_progress, progress);
    }

    fn on_download_progress(data: ?*anyopaque) callconv(.c) c_int {
        const progress: *DownloadProgress = @ptrCast(@alignCast(data.?));
        defer c_alloc.destroy(progress);
        const page = progress.page;
        const p = page.priv();
        // Identity, not generation: unmap/remap mid-install bumps the
        // generation but the same install keeps receiving progress.
        if (p.install == null or p.install != progress.install) return 0;
        if (progress.total > 0) {
            const pct: u32 = @intCast(@min(100, progress.received * 100 / progress.total));
            p.download_pct = pct;
            var buf: [96]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "{s} {d}%", .{ translations._("Downloading…"), pct }, 0) catch translations._("Downloading…");
            gtk.Label.setLabel(p.progress_label, text);
            gtk.ProgressBar.setFraction(p.progress_bar, @as(f64, @floatFromInt(pct)) / 100.0);
        } else {
            gtk.Label.setLabel(p.progress_label, translations._("Downloading…"));
            gtk.ProgressBar.pulse(p.progress_bar);
        }
        return 0;
    }

    const FlashCtx = struct { page: *Self, install: ?*InstallState };

    fn on_flash_start_worker(ctx: ?*anyopaque) void {
        const page: *Self = @ptrCast(@alignCast(ctx.?));
        const flash = c_alloc.create(FlashCtx) catch return;
        flash.* = .{ .page = page, .install = page.priv().install };
        _ = glib.idleAdd(&on_flash_start, flash);
    }

    fn on_flash_start(data: ?*anyopaque) callconv(.c) c_int {
        const flash: *FlashCtx = @ptrCast(@alignCast(data.?));
        defer c_alloc.destroy(flash);
        const page = flash.page;
        const p = page.priv();
        if (p.install == null or p.install != flash.install) return 0;
        p.install_flash_started = true;
        gtk.Label.setLabel(p.progress_label, translations._("Installing firmware…"));
        gtk.ProgressBar.setFraction(p.progress_bar, 0);
        gtk.ProgressBar.pulse(p.progress_bar);
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
        bindReleaseRow(grid, object, self.priv().selected_problems, isBusy(self.priv()));
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

    fn bindReleaseRow(grid: *gtk.Grid, object: *ReleaseObject, device_problems: u64, busy: bool) void {
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
        } else if (busy) {
            gtk.Widget.setSensitive(action.as(gtk.Widget), 0);
            gtk.Widget.setTooltipText(action.as(gtk.Widget), translations._("An update is in progress"));
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
        const page_ptr = gobject.Object.getData(button.as(gobject.Object), "page") orelse return;
        const self: *Self = @ptrCast(@alignCast(page_ptr));
        const p = self.priv();
        const id = p.selected_id orelse return;
        const index = findDeviceIndex(self, id) orelse return;
        const device_object = deviceAt(self, index) orelse return;
        beginInstall(self, device_object, object);
    }

    /// Pango markup for a read-more link. The URL is daemon-derived, so escape it
    /// (incl. quotes) before interpolating into an href; the caption is our string.
    fn infoLinkMarkup(alloc: std.mem.Allocator, url: []const u8, caption: []const u8) [:0]const u8 {
        const escaped = escapeMarkup(alloc, url);
        return alloc.printSentinel("<a href=\"{s}\">{s}</a>", .{ escaped, caption }, 0) catch "";
    }

    /// Only http(s) URLs reach the launcher; the builders emit https only, so
    /// this is defense in depth against a hostile daemon or a future caller.
    fn isHttpUri(uri: []const u8) bool {
        return std.mem.startsWith(u8, uri, "https://") or std.mem.startsWith(u8, uri, "http://");
    }

    /// activate-link for the LVFS read-more label in the device detail pane.
    /// Return 1 to stop GTK's default handler; parent the launch to the window
    /// (polkit_warning idiom). Unref after launch: the async GTask holds its own ref.
    fn on_info_link(label: *gtk.Label, uri: [*:0]const u8, _: ?*anyopaque) callconv(.c) c_int {
        if (!isHttpUri(std.mem.span(uri))) return 1;
        const root = gtk.Widget.getRoot(label.as(gtk.Widget));
        const parent: ?*gtk.Window = if (root) |r| gobject.ext.cast(gtk.Window, r) else null;
        const launcher = gtk.UriLauncher.new(uri);
        defer launcher.unref();
        launcher.launch(parent, null, null, null);
        return 1;
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
        .{ "progress_box", @offsetOf(Private, "progress_box") },
        .{ "progress_label", @offsetOf(Private, "progress_label") },
        .{ "progress_bar", @offsetOf(Private, "progress_bar") },
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
        .{ "detail_link", @offsetOf(Private, "detail_link") },
        .{ "detail_warning", @offsetOf(Private, "detail_warning") },
        .{ "detail_no_releases", @offsetOf(Private, "detail_no_releases") },
        .{ "release_scroll", @offsetOf(Private, "release_scroll") },
        .{ "release_list", @offsetOf(Private, "release_list") },
        .{ "empty_page", @offsetOf(Private, "empty_page") },
        .{ "error_page", @offsetOf(Private, "error_page") },
        .{ "error_label", @offsetOf(Private, "error_label") },
        .{ "installing_page", @offsetOf(Private, "installing_page") },
        .{ "installing_spinner", @offsetOf(Private, "installing_spinner") },
        .{ "installing_device_label", @offsetOf(Private, "installing_device_label") },
        .{ "installing_version_label", @offsetOf(Private, "installing_version_label") },
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
            const oc: *gobject.Object.Class = @ptrCast(class);
            oc.f_finalize = &finalize;
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

test "firmware info link markup escapes the href and only http(s) launches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Daemon-supplied URL specials are escaped inside the href.
    const markup = FirmwarePage.infoLinkMarkup(alloc, "https://fwupd.org/lvfs/devices/a.b?x=1&y=\"2\"", "View on LVFS");
    try testing.expectEqualStrings(
        "<a href=\"https://fwupd.org/lvfs/devices/a.b?x=1&amp;y=&quot;2&quot;\">View on LVFS</a>",
        markup,
    );

    // Scheme gate: only http(s) is launchable.
    try testing.expect(FirmwarePage.isHttpUri("https://fwupd.org/lvfs/devices/x"));
    try testing.expect(FirmwarePage.isHttpUri("http://fwupd.org/lvfs/devices/x"));
    try testing.expect(!FirmwarePage.isHttpUri("javascript:alert(1)"));
    try testing.expect(!FirmwarePage.isHttpUri("file:///etc/passwd"));
    try testing.expect(!FirmwarePage.isHttpUri("ftp://fwupd.org/x"));
    try testing.expect(!FirmwarePage.isHttpUri(""));
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
        .metadata_stale = false,
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
        .metadata_stale = false,
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
        .metadata_stale = false,
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
    FirmwarePage.bindReleaseRow(release_grid, release_obj, 0, false);
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
    FirmwarePage.bindReleaseRow(release_grid, release_obj, 0, true);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getSensitive(action.as(gtk.Widget)));
    // Device problems gate the action button.
    FirmwarePage.bindReleaseRow(release_grid, release_obj, 1, false);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getSensitive(action.as(gtk.Widget)));
    FirmwarePage.bindReleaseRow(release_grid, release_obj, 0, false);
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getSensitive(action.as(gtk.Widget)));

    const blocked = ReleaseObject.new(alloc, device, .{
        .version = "0.9",
        .trust_flags = enums.TrustFlags.is_downgrade | enums.TrustFlags.blocked_version,
    });
    defer blocked.as(gobject.Object).unref();
    FirmwarePage.bindReleaseRow(release_grid, blocked, 0, false);
    try testing.expectEqualStrings("Blocked", std.mem.span(gtk.Button.getLabel(action).?));
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getSensitive(action.as(gtk.Widget)));

    // Unknown urgency and a trust badge swap which sub-labels are shown.
    const community = ReleaseObject.new(alloc, device, .{
        .version = "1.2",
        .trust_flags = enums.TrustFlags.is_upgrade | enums.TrustFlags.is_community,
    });
    defer community.as(gobject.Object).unref();
    FirmwarePage.bindReleaseRow(release_grid, community, 0, false);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(urgency.as(gtk.Widget)));
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(release_badges.as(gtk.Widget)));
    try testing.expectEqualStrings("Community supported", std.mem.span(gtk.Label.getLabel(release_badges)));
}

test "firmware release row keeps badges plain (read-more link is device-level only)" {
    try gtk_test.requireDisplay();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const device = models.Device{ .device_id = "dev1", .version = "1.0" };

    const grid = FirmwarePage.buildReleaseRow();
    _ = grid.as(gobject.Object).refSink();
    defer grid.as(gobject.Object).unref();
    const text_box = gobject.ext.cast(gtk.Box, gtk.Grid.getChildAt(grid, 1, 0).?).?;
    const badges = gobject.ext.cast(gtk.Label, gtk.Widget.getNextSibling(gtk.Widget.getFirstChild(text_box.as(gtk.Widget)).?).?).?;
    const action = gobject.ext.cast(gtk.Button, gtk.Grid.getChildAt(grid, 3, 0).?).?;

    // Even an LVFS release with a community badge shows plain text, no per-row link:
    // the single read-more link lives in the device detail pane.
    const lvfs = ReleaseObject.new(alloc, device, .{
        .version = "1.1",
        .trust_flags = enums.TrustFlags.is_upgrade | enums.TrustFlags.is_community,
        .remote_id = "lvfs",
        .appstream_id = "com.lenovo.ThinkPadR2LET.firmware",
    });
    defer lvfs.as(gobject.Object).unref();
    FirmwarePage.bindReleaseRow(grid, lvfs, 0, false);
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(badges.as(gtk.Widget)));
    try testing.expectEqual(@as(c_int, 0), gtk.Label.getUseMarkup(badges));
    try testing.expectEqualStrings("Community supported", std.mem.span(gtk.Label.getLabel(badges)));

    // Blocked LVFS release: plain blocked reason, disabled action, still no row link.
    const blocked = ReleaseObject.new(alloc, device, .{
        .version = "0.9",
        .trust_flags = enums.TrustFlags.is_downgrade | enums.TrustFlags.blocked_version,
        .remote_id = "lvfs",
        .appstream_id = "com.lenovo.ThinkPadR2LET.firmware",
    });
    defer blocked.as(gobject.Object).unref();
    FirmwarePage.bindReleaseRow(grid, blocked, 0, false);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getSensitive(action.as(gtk.Widget)));
    try testing.expectEqual(@as(c_int, 0), gtk.Label.getUseMarkup(badges));
    const blocked_text = std.mem.span(gtk.Label.getLabel(badges));
    try testing.expect(std.mem.indexOf(u8, blocked_text, "This version is blocked on this device") != null);
    try testing.expect(std.mem.indexOf(u8, blocked_text, "<a href") == null);
}

test "firmware detail link follows fetched releases and hides on reset" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{};
    p.backend = fake.backend();
    p.generation = 7;
    p.detail_generation = 3;
    p.loaded = true;
    defer {
        p.generation += 1;
        p.loaded = false;
        FirmwarePage.setSelectedId(page, null);
        FirmwarePage.clear_data(page);
    }

    // Success with an LVFS appstream id: the component-page link is shown.
    const lvfs_arena = try c_alloc.create(std.heap.ArenaAllocator);
    lvfs_arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    const lvfs_releases = try lvfs_arena.allocator().alloc(models.Release, 1);
    lvfs_releases[0] = .{ .version = "1.1", .remote_id = "lvfs", .appstream_id = "com.lenovo.ThinkPadR2LET.firmware", .trust_flags = enums.TrustFlags.is_upgrade };
    const lvfs_result = try c_alloc.create(FirmwarePage.DetailResult);
    lvfs_result.* = .{
        .page = page,
        .arena = lvfs_arena,
        .generation = 7,
        .token = 3,
        .device_id = try c_alloc.dupe(u8, "dev1"),
        .device_version = try c_alloc.dupe(u8, "1.0"),
        .releases = lvfs_releases,
        .failure = null,
    };
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_detail_complete(lvfs_result));
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(p.detail_link.as(gtk.Widget)));
    const link_markup = std.mem.span(gtk.Label.getLabel(p.detail_link));
    try testing.expect(std.mem.indexOf(u8, link_markup, "href=\"https://fwupd.org/lvfs/devices/com.lenovo.ThinkPadR2LET.firmware\"") != null);
    try testing.expect(std.mem.indexOf(u8, link_markup, "View on LVFS</a>") != null);
    try testing.expectEqual(@as(c_int, 0), gtk.Label.getSelectable(p.detail_link));

    // Success with only non-LVFS releases: no device link.
    const local_arena = try c_alloc.create(std.heap.ArenaAllocator);
    local_arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    const local_releases = try local_arena.allocator().alloc(models.Release, 1);
    local_releases[0] = .{ .version = "1.2", .remote_id = "local", .appstream_id = "org.local.fw" };
    const local_result = try c_alloc.create(FirmwarePage.DetailResult);
    local_result.* = .{
        .page = page,
        .arena = local_arena,
        .generation = 7,
        .token = 3,
        .device_id = try c_alloc.dupe(u8, "dev1"),
        .device_version = try c_alloc.dupe(u8, "1.0"),
        .releases = local_releases,
        .failure = null,
    };
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_detail_complete(local_result));
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(p.detail_link.as(gtk.Widget)));

    // Device switch / unmap reset hides the link.
    FirmwarePage.clear_releases(page);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(p.detail_link.as(gtk.Widget)));

    // A failed fetch hides the link as well.
    const fail_arena = try c_alloc.create(std.heap.ArenaAllocator);
    fail_arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    const fail_result = try c_alloc.create(FirmwarePage.DetailResult);
    fail_result.* = .{
        .page = page,
        .arena = fail_arena,
        .generation = 7,
        .token = 3,
        .device_id = try c_alloc.dupe(u8, "dev1"),
        .device_version = try c_alloc.dupe(u8, "1.0"),
        .releases = null,
        .failure = .{ .kind = .internal, .message = "" },
    };
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_detail_complete(fail_result));
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(p.detail_link.as(gtk.Widget)));
}

test "firmware install flow runs download, install and finish refresh against the fake backend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var map: std.process.Environ.Map = .init(testing.allocator);
    defer map.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "install flow payload";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "fw.cab", .data = payload });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const location = try alloc.print("file://{s}/fw.cab", .{try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path})});

    var fake = fwupd.FakeBackend{
        .remotes = &.{.{ .remote_id = "dir", .kind = .directory }},
        .devices = &.{.{
            .device_id = "dev1",
            .name = "Device",
            .version = "1.1",
            .flags = enums.DeviceFlags.updatable | enums.DeviceFlags.needs_reboot,
        }},
        .daemon_props = .{ .daemon_version = "2.1.10", .status = .idle },
    };
    const state = try testing.allocator.create(FirmwarePage.InstallState);
    defer testing.allocator.destroy(state);
    state.* = .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .device = .{ .device_id = "dev1", .name = "Device", .version = "1.0", .flags = enums.DeviceFlags.updatable },
        .release = .{
            .version = "1.1",
            .trust_flags = enums.TrustFlags.is_upgrade,
            .remote_id = "dir",
            .locations = &.{location},
            .checksum = &hex,
            .update_message = "Replug to finish",
        },
        .options = fwupd.optionsForAction(.upgrade, false),
    };
    defer state.arena.deinit();
    try state.post_requests.append(state.arena.allocator(), .{ .appstream_id = "org.freedesktop.fwupd.request.remove-replug", .kind = .post });

    var flash_calls: usize = 0;
    const hooks = FirmwarePage.StageHooks{
        .ctx = &flash_calls,
        .on_flash_start = struct {
            fn f(ctx: ?*anyopaque) void {
                const count: *usize = @ptrCast(@alignCast(ctx.?));
                count.* += 1;
            }
        }.f,
    };
    const outcome = FirmwarePage.runInstall(fake.backend(), alloc, threaded.io(), &map, state, "shelly/test", .{}, hooks, null);

    try testing.expect(outcome.failure_text == null);
    try testing.expectEqual(@as(usize, 1), flash_calls);
    try testing.expectEqual(@as(usize, 1), fake.install_call_count);
    try testing.expectEqualStrings("dev1", fake.install_calls[0].device_id);
    try testing.expect(std.mem.endsWith(u8, fake.install_calls[0].payload_path, "/fw.cab"));
    try testing.expect(!fake.install_calls[0].options.allow_older);
    // Finish refresh found the device with its post-install flags.
    try testing.expect(outcome.fresh_device != null);
    try testing.expectEqualStrings("1.1", outcome.fresh_device.?.version);
    try testing.expectEqual(models.PowerPrompt.reboot, models.powerPrompt(outcome.fresh_device.?.flags));
    // No probe injected: capability stays unknown, never touches logind.
    try testing.expectEqual(DBus.PowerCapability.unknown, outcome.capability);

    // Finish order: post request, UpdateMessage, reboot prompt.
    const steps = try models.finishSteps(alloc, outcome.fresh_device.?.flags, state.release.update_message, state.post_requests.items);
    try testing.expectEqual(@as(usize, 3), steps.len);
    try testing.expectEqualStrings("org.freedesktop.fwupd.request.remove-replug", steps[0].request.appstream_id);
    try testing.expectEqualStrings("Replug to finish", steps[1].update_message);
    try testing.expectEqual(models.PowerPrompt.reboot, steps[2].power);
}

test "firmware install flow surfaces friendly failure text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var map: std.process.Environ.Map = .init(testing.allocator);
    defer map.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fake = fwupd.FakeBackend{
        .remotes = &.{
            .{ .remote_id = "lvfs", .kind = .download },
            .{ .remote_id = "dir", .kind = .directory },
        },
    };
    const state = try testing.allocator.create(FirmwarePage.InstallState);
    defer testing.allocator.destroy(state);
    state.* = .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .device = .{ .device_id = "dev1" },
        .release = .{ .version = "1.1", .remote_id = "lvfs", .locations = &.{"https://cdn.example/fw.cab"} },
        .options = .{},
    };
    defer state.arena.deinit();

    // No checksums: the download layer refuses before any HTTP request.
    const no_sum = FirmwarePage.runInstall(fake.backend(), alloc, threaded.io(), &map, state, "shelly/test", .{}, .{}, null);
    try testing.expectEqualStrings("This release provides no checksums, so it cannot be verified", no_sum.failure_text.?);
    try testing.expectEqual(@as(usize, 0), fake.install_call_count);

    // A local payload downloads fine; the fwupd install error maps to text.
    const payload = "local payload";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "fw.cab", .data = payload });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const location = try alloc.print("file://{s}/fw.cab", .{try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path})});
    state.release.remote_id = "dir";
    state.release.locations = &.{location};
    state.release.checksum = &hex;
    fake.install_error = .auth_failed;
    const denied = FirmwarePage.runInstall(fake.backend(), alloc, threaded.io(), &map, state, "shelly/test", .{}, .{}, null);
    try testing.expectEqualStrings(models.errorText(.auth_failed), denied.failure_text.?);
    // The fake records successful installs only; the failure is inspectable.
    try testing.expectEqual(enums.Error.auth_failed, fake.failure.?.kind);
}

test "firmware install result queues finish dialogs and frees the state" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{};
    p.backend = fake.backend();
    p.generation = 7;
    p.loaded = true;
    // Hold the queue so the entries can be inspected; no window is attached,
    // so pumping would drain them anyway.
    p.dialog_active = true;
    defer {
        p.dialog_active = false;
        FirmwarePage.clearDialogQueue(page);
        p.generation += 1;
        p.loaded = false;
        FirmwarePage.setSelectedId(page, null);
        FirmwarePage.clear_data(page);
    }

    const state = try c_alloc.create(FirmwarePage.InstallState);
    state.* = .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .device = .{ .device_id = "dev1", .flags = enums.DeviceFlags.updatable },
        .release = .{ .version = "1.1", .update_message = "Replug to finish" },
        .options = .{},
        .generation = 6, // stale: no reload may start under the test
    };
    try state.post_requests.append(state.arena.allocator(), .{ .appstream_id = "org.freedesktop.fwupd.request.remove-replug", .kind = .post });
    const result = try c_alloc.create(FirmwarePage.InstallResult);
    result.* = .{
        .page = page,
        .state = state,
        .generation = 6,
        .outcome = .{
            .fresh_device = .{ .device_id = "dev1", .flags = enums.DeviceFlags.updatable | enums.DeviceFlags.needs_reboot },
            .capability = .yes,
        },
    };
    // The handler drops the worker's page ref; balance the direct call.
    _ = page.as(gobject.Object).ref();
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_install_complete(result));
    try testing.expect(p.install == null);
    try testing.expectEqual(@as(usize, 3), p.dialog_queue.items.len);
    try testing.expectEqualStrings("org.freedesktop.fwupd.request.remove-replug", p.dialog_queue.items[0].request.appstream_id);
    try testing.expectEqualStrings("Replug to finish", p.dialog_queue.items[1].info.text);
    try testing.expectEqual(models.PowerPrompt.reboot, p.dialog_queue.items[2].power.kind);
    try testing.expectEqual(DBus.PowerCapability.yes, p.dialog_queue.items[2].power.capability);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(p.progress_box.as(gtk.Widget)));
}

test "firmware install failure result queues the error note and frees the state" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{};
    p.backend = fake.backend();
    p.generation = 7;
    p.loaded = true;
    p.dialog_active = true;
    defer {
        p.dialog_active = false;
        FirmwarePage.clearDialogQueue(page);
        p.generation += 1;
        p.loaded = false;
        FirmwarePage.setSelectedId(page, null);
        FirmwarePage.clear_data(page);
    }

    const state = try c_alloc.create(FirmwarePage.InstallState);
    state.* = .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .device = .{ .device_id = "dev1" },
        .release = .{ .version = "1.1" },
        .options = .{},
        .generation = 7,
    };
    const result = try c_alloc.create(FirmwarePage.InstallResult);
    result.* = .{
        .page = page,
        .state = state,
        .generation = 7,
        .outcome = .{ .failure_text = models.errorText(.write) },
    };
    // The handler drops the worker's page ref; balance the direct call.
    _ = page.as(gobject.Object).ref();
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_install_complete(result));
    try testing.expect(p.install == null);
    try testing.expectEqual(@as(usize, 1), p.dialog_queue.items.len);
    try testing.expectEqualStrings("Failed to install firmware", p.dialog_queue.items[0].info.title);
    try testing.expectEqualStrings(models.errorText(.write), p.dialog_queue.items[0].info.text);
}

test "firmware beginInstall guards problems, blocked releases and busy state" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{};
    p.backend = fake.backend();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    defer {
        FirmwarePage.clearDialogQueue(page);
        FirmwarePage.setSelectedId(page, null);
        FirmwarePage.clear_data(page);
    }

    const device = models.Device{ .device_id = "dev1", .name = "Device", .version = "1.0", .flags = enums.DeviceFlags.updatable };
    const device_obj = DeviceObject.new(alloc, device, .{}, 0);
    defer device_obj.as(gobject.Object).unref();
    const upgrade = ReleaseObject.new(alloc, device, .{ .version = "1.1", .trust_flags = enums.TrustFlags.is_upgrade });
    defer upgrade.as(gobject.Object).unref();

    // Problems gate the install even if a click gets through.
    const problem_obj = DeviceObject.new(alloc, .{ .device_id = "dev2", .problems = 1, .flags = enums.DeviceFlags.updatable }, .{}, 1);
    defer problem_obj.as(gobject.Object).unref();
    FirmwarePage.beginInstall(page, problem_obj, upgrade);
    try testing.expect(p.install == null);

    // Blocked releases never start.
    const blocked = ReleaseObject.new(alloc, device, .{ .version = "0.9", .trust_flags = enums.TrustFlags.blocked_version });
    defer blocked.as(gobject.Object).unref();
    FirmwarePage.beginInstall(page, device_obj, blocked);
    try testing.expect(p.install == null);

    // Busy daemon status gates the install.
    p.props = .{ .status = .device_write };
    FirmwarePage.beginInstall(page, device_obj, upgrade);
    try testing.expect(p.install == null);
    p.props = .{};

    // Without a window the mandatory consent dialog cannot show, so the
    // attempt aborts cleanly instead of installing without consent.
    FirmwarePage.beginInstall(page, device_obj, upgrade);
    try testing.expect(p.install == null);
    try testing.expectEqual(@as(usize, 0), p.dialog_queue.items.len);
}

test "firmware remap mid-install renders the installing view without a load" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{};
    p.backend = fake.backend();
    p.generation = 5;
    p.loaded = true;
    p.state = .Loaded;

    const state = try c_alloc.create(FirmwarePage.InstallState);
    state.* = .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .device = .{ .device_id = "dev1", .name = "Webcam", .version = "1.2.2" },
        .release = .{ .version = "1.2.4" },
        .options = .{},
        .generation = 5,
    };
    p.install = state;
    defer {
        p.install = null;
        FirmwarePage.freeInstallState(state);
        p.loaded = false;
        FirmwarePage.clear_data(page);
    }

    page.onUnmap();
    try testing.expect(!p.loaded);
    try testing.expectEqual(@as(u64, 6), p.generation);

    // The daemon would block a load behind the running install; the remap
    // must render from the snapshot instead of starting one.
    page.onMap();
    try testing.expect(p.loaded);
    try testing.expect(!p.loading);
    try testing.expectEqual(FirmwarePage.PageState.Installing, p.state);
    try testing.expectEqual(@as(u64, 6), p.generation);
    try testing.expectEqualStrings("Webcam", std.mem.span(gtk.Label.getLabel(p.installing_device_label)));
    try testing.expectEqualStrings("1.2.2 → 1.2.4", std.mem.span(gtk.Label.getLabel(p.installing_version_label)));
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(p.progress_box.as(gtk.Widget)));
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getSensitive(p.refresh_button.as(gtk.Widget)));
}

test "firmware install progress applies after remap and drops for stale installs" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{};
    p.backend = fake.backend();
    p.generation = 9;
    p.loaded = true;

    const state = try c_alloc.create(FirmwarePage.InstallState);
    state.* = .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .device = .{ .device_id = "dev1" },
        .release = .{ .version = "1.1" },
        .options = .{},
        .generation = 5, // stale vs the page: identity must carry the update
    };
    p.install = state;
    defer {
        p.install = null;
        FirmwarePage.freeInstallState(state);
        p.loaded = false;
        FirmwarePage.clear_data(page);
    }

    const progress = try c_alloc.create(FirmwarePage.DownloadProgress);
    progress.* = .{ .page = page, .install = state, .received = 50, .total = 100 };
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_download_progress(progress));
    try testing.expectEqual(@as(u32, 50), p.download_pct);
    try testing.expectApproxEqAbs(@as(f64, 0.5), gtk.ProgressBar.getFraction(p.progress_bar), 0.001);

    const flash = try c_alloc.create(FirmwarePage.FlashCtx);
    flash.* = .{ .page = page, .install = state };
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_flash_start(flash));
    try testing.expect(p.install_flash_started);

    // Flash fraction then follows the daemon property signals.
    FirmwarePage.sig_properties_changed(page, .{ .status = .device_write, .percentage_full = 40 });
    try testing.expectApproxEqAbs(@as(f64, 0.4), gtk.ProgressBar.getFraction(p.progress_bar), 0.001);

    // Once the install is gone, marshaled updates for it are dropped.
    p.install = null;
    const stale = try c_alloc.create(FirmwarePage.DownloadProgress);
    stale.* = .{ .page = page, .install = state, .received = 90, .total = 100 };
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_download_progress(stale));
    try testing.expectEqual(@as(u32, 50), p.download_pct);
}

test "firmware install completion reloads from the installing view despite a stale generation" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{
        .devices = &.{.{ .device_id = "dev1", .name = "Device", .flags = enums.DeviceFlags.updatable }},
    };
    p.backend = fake.backend();
    p.generation = 7;
    p.loaded = true;
    p.state = .Installing;
    p.dialog_active = true;
    defer {
        p.dialog_active = false;
        FirmwarePage.clearDialogQueue(page);
        p.generation += 1;
        p.loaded = false;
        FirmwarePage.setSelectedId(page, null);
        FirmwarePage.clear_data(page);
    }

    const state = try c_alloc.create(FirmwarePage.InstallState);
    state.* = .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .device = .{ .device_id = "dev1", .flags = enums.DeviceFlags.updatable },
        .release = .{ .version = "1.1" },
        .options = .{},
        .generation = 6, // unmap bumped the page generation past the snapshot
    };
    p.install = state;
    const result = try c_alloc.create(FirmwarePage.InstallResult);
    result.* = .{
        .page = page,
        .state = state,
        .generation = 6,
        .outcome = .{ .fresh_device = .{ .device_id = "dev1", .flags = enums.DeviceFlags.updatable } },
    };
    // The handler drops the worker's page ref; balance the direct call.
    _ = page.as(gobject.Object).ref();
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_install_complete(result));
    try testing.expect(p.install == null);
    try testing.expect(p.loading);
    try testing.expectEqual(FirmwarePage.PageState.Loading, p.state);

    // Drain the fake-backed reload (and its scroll-settle idle) while the
    // page is still alive so nothing outlives it.
    var spins: usize = 0;
    while (p.loading and spins < 5000) : (spins += 1) {
        _ = glib.MainContext.default().iteration(0);
        const ts = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    try testing.expect(!p.loading);
    try testing.expectEqual(FirmwarePage.PageState.Loaded, p.state);
    for (0..10) |_| _ = glib.MainContext.default().iteration(0);
}

test "firmware stale load result triggers the automatic refresh" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{
        .devices = &.{.{ .device_id = "dev1", .name = "Device", .flags = enums.DeviceFlags.updatable }},
    };
    p.backend = fake.backend();
    p.generation = 7;
    p.loaded = true;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var map: std.process.Environ.Map = .init(testing.allocator);
    defer map.deinit();
    const cache_root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(cache_root);
    try map.put("XDG_CACHE_HOME", cache_root);
    p.env = &map;
    defer {
        p.env = null;
        p.generation += 1;
        p.loaded = false;
        FirmwarePage.setSelectedId(page, null);
        FirmwarePage.clear_data(page);
    }

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
        .generation = 7,
        .data = .{ .devices = devices, .badges = badges },
        .failure = null,
        .metadata_stale = true,
    };
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_load_complete(result));
    // The automatic refresh started and gates the page while it runs.
    try testing.expect(p.refreshing);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getSensitive(p.refresh_button.as(gtk.Widget)));
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(p.header_spinner.as(gtk.Widget)));
    // The banner hides while the refresh that fixes it is in flight.
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(p.banner_box.as(gtk.Widget)));

    var spins: usize = 0;
    while (p.refreshing and spins < 5000) : (spins += 1) {
        _ = glib.MainContext.default().iteration(0);
        const ts = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    try testing.expect(!p.refreshing);
    // No download remotes: nothing attempted, nothing failed, so the stale
    // flag clears without a reload and the throttle marker was written.
    try testing.expect(!p.metadata_stale);
    try testing.expect(!p.loading);
    try testing.expectEqual(FirmwarePage.PageState.Loaded, p.state);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(p.banner_box.as(gtk.Widget)));
    const marker = try std.fs.path.join(testing.allocator, &.{ cache_root, "shelly", "fwupd", "last_refresh" });
    defer testing.allocator.free(marker);
    try std.Io.Dir.cwd().access(testing.io, marker, .{});
    for (0..10) |_| _ = glib.MainContext.default().iteration(0);
}

test "firmware refresh success clears the stale banner and reloads" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{
        .devices = &.{.{ .device_id = "dev1", .name = "Device", .flags = enums.DeviceFlags.updatable }},
    };
    p.backend = fake.backend();
    p.generation = 7;
    p.loaded = true;
    p.state = .Loaded;
    p.metadata_stale = true;
    p.refreshing = true;
    defer {
        p.generation += 1;
        p.loaded = false;
        FirmwarePage.setSelectedId(page, null);
        FirmwarePage.clear_data(page);
    }

    const result = try c_alloc.create(FirmwarePage.RefreshResult);
    result.* = .{
        .page = page,
        .generation = 7,
        .outcome = .{ .attempted = 1, .succeeded = 1 },
        .failure_text = null,
        .manual = true,
    };
    // The handler drops the worker's page ref; balance the direct call.
    _ = page.as(gobject.Object).ref();
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_refresh_complete(result));
    try testing.expect(!p.refreshing);
    try testing.expect(!p.metadata_stale);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(p.banner_box.as(gtk.Widget)));
    try testing.expect(p.loading);
    try testing.expectEqual(FirmwarePage.PageState.Loading, p.state);

    // Drain the fake-backed reload while the page is still alive.
    var spins: usize = 0;
    while (p.loading and spins < 5000) : (spins += 1) {
        _ = glib.MainContext.default().iteration(0);
        const ts = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    try testing.expect(!p.loading);
    try testing.expectEqual(FirmwarePage.PageState.Loaded, p.state);
    for (0..10) |_| _ = glib.MainContext.default().iteration(0);
}

test "firmware manual refresh reloads even when every remote skips" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{
        .devices = &.{.{ .device_id = "dev1", .name = "Device", .flags = enums.DeviceFlags.updatable }},
    };
    p.backend = fake.backend();
    p.generation = 7;
    p.loaded = true;
    p.state = .Loaded;
    p.refreshing = true;
    defer {
        p.generation += 1;
        p.loaded = false;
        FirmwarePage.setSelectedId(page, null);
        FirmwarePage.clear_data(page);
    }

    // All remotes skipped (signature unchanged): the catalog is current, but
    // a manual press still re-checks devices against the live daemon, which
    // may have restarted with a different device set.
    const result = try c_alloc.create(FirmwarePage.RefreshResult);
    result.* = .{
        .page = page,
        .generation = 7,
        .outcome = .{ .attempted = 1, .skipped = 1 },
        .failure_text = null,
        .manual = true,
    };
    _ = page.as(gobject.Object).ref();
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_refresh_complete(result));
    try testing.expect(!p.refreshing);
    try testing.expect(p.loading);
    try testing.expectEqual(FirmwarePage.PageState.Loading, p.state);

    var spins: usize = 0;
    while (p.loading and spins < 5000) : (spins += 1) {
        _ = glib.MainContext.default().iteration(0);
        const ts = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    try testing.expect(!p.loading);
    try testing.expectEqual(FirmwarePage.PageState.Loaded, p.state);
    for (0..10) |_| _ = glib.MainContext.default().iteration(0);
}

test "firmware refresh failures keep the banner and only manual presses dialog" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{};
    p.backend = fake.backend();
    p.generation = 7;
    p.loaded = true;
    p.state = .Loaded;
    p.metadata_stale = true;
    p.dialog_active = true;
    defer {
        p.dialog_active = false;
        FirmwarePage.clearDialogQueue(page);
        p.generation += 1;
        p.loaded = false;
        FirmwarePage.setSelectedId(page, null);
        FirmwarePage.clear_data(page);
    }

    // Manual bus failure: friendly note, banner stays, no reload.
    p.refreshing = true;
    const failed = try c_alloc.create(FirmwarePage.RefreshResult);
    failed.* = .{
        .page = page,
        .generation = 7,
        .outcome = .{},
        .failure_text = models.errorText(.internal),
        .manual = true,
    };
    _ = page.as(gobject.Object).ref();
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_refresh_complete(failed));
    try testing.expect(!p.refreshing);
    try testing.expect(p.metadata_stale);
    try testing.expect(!p.loading);
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(p.banner_box.as(gtk.Widget)));
    try testing.expectEqual(@as(usize, 1), p.dialog_queue.items.len);
    try testing.expectEqualStrings("Metadata refresh failed", p.dialog_queue.items[0].info.title);
    try testing.expectEqualStrings(models.errorText(.internal), p.dialog_queue.items[0].info.text);
    FirmwarePage.clearDialogQueue(page);

    // Automatic failure: logged only, no dialog.
    p.refreshing = true;
    const auto_failed = try c_alloc.create(FirmwarePage.RefreshResult);
    auto_failed.* = .{
        .page = page,
        .generation = 7,
        .outcome = .{},
        .failure_text = models.errorText(.internal),
        .manual = false,
    };
    _ = page.as(gobject.Object).ref();
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_refresh_complete(auto_failed));
    try testing.expectEqual(@as(usize, 0), p.dialog_queue.items.len);
    try testing.expect(p.metadata_stale);

    // Manual total per-remote failure: catalog note, banner stays.
    p.refreshing = true;
    const all_failed = try c_alloc.create(FirmwarePage.RefreshResult);
    all_failed.* = .{
        .page = page,
        .generation = 7,
        .outcome = .{ .attempted = 1, .failed = 1 },
        .failure_text = null,
        .manual = true,
    };
    _ = page.as(gobject.Object).ref();
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_refresh_complete(all_failed));
    try testing.expect(p.metadata_stale);
    // Manual presses re-check devices even when every remote failed.
    try testing.expect(p.loading);
    try testing.expectEqual(@as(usize, 1), p.dialog_queue.items.len);
    try testing.expectEqualStrings("Metadata refresh failed", p.dialog_queue.items[0].info.title);
    var spins: usize = 0;
    while (p.loading and spins < 5000) : (spins += 1) {
        _ = glib.MainContext.default().iteration(0);
        const ts = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    try testing.expect(!p.loading);
    for (0..10) |_| _ = glib.MainContext.default().iteration(0);
}

test "firmware refresh result is discarded when its generation is stale" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{};
    p.backend = fake.backend();
    p.generation = 7;
    p.loaded = true;
    p.state = .Loaded;
    p.refreshing = true;
    defer {
        p.generation += 1;
        p.loaded = false;
        FirmwarePage.clear_data(page);
    }

    const result = try c_alloc.create(FirmwarePage.RefreshResult);
    result.* = .{
        .page = page,
        .generation = 6,
        .outcome = .{ .attempted = 1, .succeeded = 1 },
        .failure_text = null,
        .manual = true,
    };
    _ = page.as(gobject.Object).ref();
    try testing.expectEqual(@as(c_int, 0), FirmwarePage.on_refresh_complete(result));
    // The busy state resets, but no reload starts under a stale generation.
    try testing.expect(!p.refreshing);
    try testing.expect(!p.loading);
    try testing.expectEqual(FirmwarePage.PageState.Loaded, p.state);
    try testing.expectEqual(@as(usize, 0), p.dialog_queue.items.len);
}

test "firmware refreshing gates the install flow" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{};
    p.backend = fake.backend();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    defer {
        FirmwarePage.clearDialogQueue(page);
        FirmwarePage.setSelectedId(page, null);
        FirmwarePage.clear_data(page);
    }

    const device = models.Device{ .device_id = "dev1", .name = "Device", .version = "1.0", .flags = enums.DeviceFlags.updatable };
    const device_obj = DeviceObject.new(alloc, device, .{}, 0);
    defer device_obj.as(gobject.Object).unref();
    const upgrade = ReleaseObject.new(alloc, device, .{ .version = "1.1", .trust_flags = enums.TrustFlags.is_upgrade });
    defer upgrade.as(gobject.Object).unref();

    p.refreshing = true;
    FirmwarePage.update_busy_ui(page);
    FirmwarePage.beginInstall(page, device_obj, upgrade);
    try testing.expect(p.install == null);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getSensitive(p.refresh_button.as(gtk.Widget)));
    p.refreshing = false;
    FirmwarePage.update_busy_ui(page);
}

test "firmware battery banner tracks daemon property changes live" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{};
    p.backend = fake.backend();
    p.generation = 7;
    p.loaded = true;
    p.state = .Loaded;
    defer {
        p.generation += 1;
        p.loaded = false;
        FirmwarePage.setSelectedId(page, null);
        FirmwarePage.clear_data(page);
    }

    const battery_text = "Battery too low: connect AC power before updating firmware";
    FirmwarePage.sig_properties_changed(page, .{ .battery_level = 20, .battery_threshold = 50 });
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(p.banner_box.as(gtk.Widget)));
    try testing.expectEqualStrings(battery_text, std.mem.span(gtk.Label.getLabel(p.banner_label)));

    // Plugged in / healthy level: the banner disappears without a reload.
    FirmwarePage.sig_properties_changed(page, .{ .battery_level = 80, .battery_threshold = 50 });
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(p.banner_box.as(gtk.Widget)));

    // Invalid values (on AC or unknown) never warn.
    FirmwarePage.sig_properties_changed(page, .{});
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(p.banner_box.as(gtk.Widget)));
}

test "firmware battery and stale-metadata banners combine in one box" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{};
    p.backend = fake.backend();
    p.generation = 7;
    p.loaded = true;
    p.state = .Loaded;
    p.metadata_stale = true;
    p.props = .{ .battery_level = 20, .battery_threshold = 50 };
    defer {
        p.generation += 1;
        p.loaded = false;
        FirmwarePage.setSelectedId(page, null);
        FirmwarePage.clear_data(page);
    }

    const battery_text = "Battery too low: connect AC power before updating firmware";
    const stale_text = "Firmware metadata is out of date. Use Check Again to refresh.";
    FirmwarePage.update_banner(page);
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(p.banner_box.as(gtk.Widget)));
    try testing.expectEqualStrings(battery_text ++ "\n" ++ stale_text, std.mem.span(gtk.Label.getLabel(p.banner_label)));

    // A running refresh hides only the stale line; the battery warning stays.
    p.refreshing = true;
    FirmwarePage.update_banner(page);
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(p.banner_box.as(gtk.Widget)));
    try testing.expectEqualStrings(battery_text, std.mem.span(gtk.Label.getLabel(p.banner_label)));

    // Healthy battery mid-refresh: nothing left to show.
    p.props = .{};
    FirmwarePage.update_banner(page);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(p.banner_box.as(gtk.Widget)));

    // Refresh done, still stale: the stale line returns on its own.
    p.refreshing = false;
    FirmwarePage.update_banner(page);
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(p.banner_box.as(gtk.Widget)));
    try testing.expectEqualStrings(stale_text, std.mem.span(gtk.Label.getLabel(p.banner_label)));
}

test "firmware disconnected banner tracks daemon shutdown" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{};
    p.backend = fake.backend();
    p.generation = 7;
    p.loaded = true;
    p.state = .Loaded;
    defer {
        p.generation += 1;
        p.loaded = false;
        FirmwarePage.setSelectedId(page, null);
        FirmwarePage.clear_data(page);
    }

    const gone_text = "The firmware service stopped. Use Check Again to reconnect.";
    FirmwarePage.sig_properties_changed(page, .{ .status = .shutdown });
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(p.banner_box.as(gtk.Widget)));
    try testing.expectEqualStrings(gone_text, std.mem.span(gtk.Label.getLabel(p.banner_label)));

    // Fresh props after a reconnect clear the banner without a reload.
    FirmwarePage.sig_properties_changed(page, .{ .status = .idle });
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(p.banner_box.as(gtk.Widget)));

    // Combines with the battery warning; the reconnect itself is not stale.
    FirmwarePage.sig_properties_changed(page, .{ .status = .shutdown, .battery_level = 20, .battery_threshold = 50 });
    try testing.expectEqualStrings(
        "Battery too low: connect AC power before updating firmware\n" ++ gone_text,
        std.mem.span(gtk.Label.getLabel(p.banner_label)),
    );
    p.loading = true;
    FirmwarePage.update_banner(page);
    try testing.expectEqualStrings(
        "Battery too low: connect AC power before updating firmware",
        std.mem.span(gtk.Label.getLabel(p.banner_label)),
    );
    p.loading = false;
    FirmwarePage.update_banner(page);
    try testing.expectEqualStrings(
        "Battery too low: connect AC power before updating firmware\n" ++ gone_text,
        std.mem.span(gtk.Label.getLabel(p.banner_label)),
    );
}

test "firmware shutdown status keeps Check Again available" {
    try gtk_test.requireDisplay();
    const page = FirmwarePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const p = page.priv();
    var fake = fwupd.FakeBackend{};
    p.backend = fake.backend();
    p.generation = 7;
    p.loaded = true;
    p.state = .Loaded;
    defer {
        p.generation += 1;
        p.loaded = false;
        FirmwarePage.setSelectedId(page, null);
        FirmwarePage.clear_data(page);
    }

    // A vanished daemon is not a busy daemon: the reconnect button stays
    // sensitive while the banner explains the stale list.
    FirmwarePage.sig_properties_changed(page, .{ .status = .shutdown });
    try testing.expect(!FirmwarePage.isBusy(p));
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getSensitive(p.refresh_button.as(gtk.Widget)));
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(p.banner_box.as(gtk.Widget)));

    // Real work statuses still gate the button.
    FirmwarePage.sig_properties_changed(page, .{ .status = .device_write });
    try testing.expect(FirmwarePage.isBusy(p));
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getSensitive(p.refresh_button.as(gtk.Widget)));

    FirmwarePage.sig_properties_changed(page, .{ .status = .idle });
    try testing.expect(!FirmwarePage.isBusy(p));
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getSensitive(p.refresh_button.as(gtk.Widget)));
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(p.banner_box.as(gtk.Widget)));
}
