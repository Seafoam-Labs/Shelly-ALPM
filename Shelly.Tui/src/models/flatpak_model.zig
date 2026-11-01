//! Flatpak backend availability, catalog browsing, categories, and screenshots.
const updates_model = @import("updates_model.zig");
const operation_model = @import("operation_model.zig");
const std = @import("std");
const commands = @import("../commands.zig");
const flatpak_images = @import("../services/flatpak_images.zig");
const image_view = @import("../views/image_view.zig");
const flatpak_view = @import("../views/flatpak_view.zig");
const shelly_operation = @import("../services/shelly_operation.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const shelly_cli = @import("../services/shelly_cli.zig");
const ShellyCli = shelly_cli.ShellyCli;
const runtime = @import("../runtime.zig");
const Package = @import("packages.zig").Package;

const flatpak = @import("flatpak.zig");
const CheckUpdates = @import("sync.zig").CheckUpdates;

const Allocator = std.mem.Allocator;

const coordinator = @import("../model.zig");
const Model = coordinator.Model;
const Tab = coordinator.Tab;
const SudoPrompt = operation_model.SudoPrompt;

/// Page-owned state. Worker results are published to the UI loop before use.
pub const State = struct {
    flatpak_checked: bool = false,
    flatpak_probe_job: ?*FlatpakProbeJob = null,
    flatpak_probe_thread: ?std.Thread = null,
    flatpak_available: bool = false,
    flatpak_probe_error: ?anyerror = null,
    flatpak_job: ?*FlatpakJob = null,
    flatpak_thread: ?std.Thread = null,
    flatpak_catalog: ?std.json.Parsed([]flatpak.AppstreamApp) = null,
    flatpak_installed: ?std.json.Parsed([]flatpak.Flatpak) = null,
    flatpak_failure: ?anyerror = null,
    flatpak_installed_only: bool = false,
    flatpak_rows: std.ArrayList(flatpak_view.Row) = .empty,
    flatpak_field: vxfw.TextField,
    flatpak_list: vxfw.ListView,
    flatpak_details_scroll: vxfw.ScrollView,
    flatpak_details_cursor: ?u32 = null,
    flatpak_list_active: bool = false,
    screenshots_supported: bool = false,
    screenshot_open: bool = false,
    screenshot_app_id: []const u8 = "",
    screenshot_previous: vxfw.Button,
    screenshot_next: vxfw.Button,
    screenshot_generation: u64 = 0,
    screenshot_image_generation: u64 = 0,
    screenshot_request_after: ?std.Io.Timestamp = null,
    screenshot_tick_pending: bool = false,
    screenshot_items: []flatpak_images.Item = &.{},
    screenshot_index: usize = 0,
    screenshot_image: ?vaxis.Image = null,
    screenshot_failure: ?anyerror = null,
    screenshot_job: ?*flatpak_images.Job = null,
    screenshot_thread: ?std.Thread = null,
    flatpak_category: []const u8 = "",
    flatpak_categories: std.ArrayList(flatpak_view.CategoryOption) = .empty,
    flatpak_category_open: bool = false,
    flatpak_category_button: vxfw.Button,
    flatpak_category_list: vxfw.ListView,
    refresh_flatpak_after_operation: bool = false,
};

pub const FlatpakProbeJob = struct {
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
};

pub const FlatpakJob = struct {
    installed_only: bool,
    catalog: ?std.json.Parsed([]flatpak.AppstreamApp) = null,
    installed: ?std.json.Parsed([]flatpak.Flatpak) = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
};

pub fn init(gpa: Allocator, model: *Model) State {
    return .{
        .flatpak_details_scroll = .{ .item_count = 1, .children = .{ .builder = .{ .userdata = model, .buildFn = buildFlatpakDetails } } },
        .screenshot_previous = .{ .label = " < ", .userdata = model, .onClick = onPreviousScreenshot, .style = screenshotButtonStyle },
        .screenshot_next = .{ .label = " > ", .userdata = model, .onClick = onNextScreenshot, .style = screenshotButtonStyle },
        .flatpak_category_button = .{ .label = "All categories ▾", .userdata = model, .onClick = onFlatpakCategoryClick, .style = .{
            .default = .{ .fg = .{ .index = 250 } },
            .hover = .{ .fg = .{ .index = 7 }, .bold = true },
            .focus = .{ .fg = .{ .index = 7 }, .bold = true },
            .mouse_down = .{ .reverse = true },
        } },
        .flatpak_category_list = .{ .children = .{ .builder = .{ .userdata = model, .buildFn = buildFlatpakCategory } } },
        .flatpak_field = .{ .buf = .init(gpa), .userdata = model, .onChange = onFlatpakQueryChange },
        .flatpak_list = .{ .children = .{ .builder = .{ .userdata = model, .buildFn = buildFlatpakRow } } },
    };
}

pub fn deinit(self: *Model) void {
    const gpa = self.gpa;

    closeScreenshots(self);
    if (self.flatpak_state.screenshot_thread) |thread| thread.join();
    if (self.flatpak_state.screenshot_job) |job| job.deinit(self.gpa);
    if (self.flatpak_state.flatpak_probe_thread) |thread| thread.join();
    if (self.flatpak_state.flatpak_probe_job) |job| gpa.destroy(job);
    if (self.flatpak_state.flatpak_thread) |thread| thread.join();
    if (self.flatpak_state.flatpak_job) |job| {
        if (job.catalog) |*parsed| parsed.deinit();
        if (job.installed) |*parsed| parsed.deinit();
        gpa.destroy(job);
    }
    if (self.flatpak_state.flatpak_catalog) |*parsed| parsed.deinit();
    if (self.flatpak_state.flatpak_installed) |*parsed| parsed.deinit();
    self.flatpak_state.flatpak_rows.deinit(gpa);
    self.flatpak_state.flatpak_categories.deinit(gpa);
    if (self.flatpak_state.flatpak_category.len > 0) gpa.free(self.flatpak_state.flatpak_category);
    self.flatpak_state.flatpak_field.deinit();
}

pub fn startFlatpakProbe(self: *Model, ctx: *vxfw.EventContext) !void {
    if (!self.settings_state.settings.flatpak_enabled or self.flatpak_state.flatpak_probe_job != null) return;
    try ctx.tick(100, self.widget());
    const job = try self.gpa.create(FlatpakProbeJob);
    errdefer self.gpa.destroy(job);
    job.* = .{};
    const thread = try std.Thread.spawn(.{}, flatpakProbeThread, .{job});
    self.flatpak_state.flatpak_probe_job = job;
    self.flatpak_state.flatpak_probe_thread = thread;
    self.flatpak_state.flatpak_probe_error = null;
    self.flatpak_state.flatpak_failure = null;
}

pub fn flatpakProbeThread(job: *FlatpakProbeJob) void {
    defer job.done.store(true, .release);
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const cli: ShellyCli = .{ .allocator = std.heap.page_allocator, .io = threaded.io() };
    cli.probe_flatpak() catch |err| {
        job.failure = err;
    };
}

pub fn pollFlatpakProbe(self: *Model, ctx: *vxfw.EventContext) !void {
    const job = self.flatpak_state.flatpak_probe_job orelse return;
    if (!job.done.load(.acquire)) return;
    if (self.flatpak_state.flatpak_probe_thread) |thread| thread.join();
    self.flatpak_state.flatpak_probe_thread = null;
    self.flatpak_state.flatpak_probe_job = null;
    self.flatpak_state.flatpak_checked = true;
    self.flatpak_state.flatpak_probe_error = job.failure;
    self.flatpak_state.flatpak_available = job.failure == null;
    self.gpa.destroy(job);
    if (self.settings_state.settings.flatpak_enabled) {
        self.updates_state.updates_checked = false;
        if (self.flatpak_state.flatpak_available and self.active == .flatpak) try startFlatpak(self, ctx);
    }
}

pub fn ensureFlatpak(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.active != .flatpak or !self.settings_state.settings.flatpak_enabled) return;
    if (!self.flatpak_state.flatpak_checked and self.flatpak_state.flatpak_probe_job == null) try startFlatpakProbe(self, ctx);
    if (!self.flatpak_state.flatpak_available or self.flatpak_state.flatpak_job != null or self.flatpak_state.flatpak_failure != null) return;
    if (if (self.flatpak_state.flatpak_installed_only) self.flatpak_state.flatpak_installed == null else self.flatpak_state.flatpak_catalog == null)
        try startFlatpak(self, ctx);
}

pub fn startFlatpak(self: *Model, ctx: *vxfw.EventContext) !void {
    if (!self.settings_state.settings.flatpak_enabled or !self.flatpak_state.flatpak_available or self.flatpak_state.flatpak_job != null) return;
    try ctx.tick(100, self.widget());
    const job = try self.gpa.create(FlatpakJob);
    errdefer self.gpa.destroy(job);
    job.* = .{ .installed_only = self.flatpak_state.flatpak_installed_only };
    const thread = try std.Thread.spawn(.{}, flatpakThread, .{job});
    self.flatpak_state.flatpak_job = job;
    self.flatpak_state.flatpak_thread = thread;
    self.flatpak_state.flatpak_failure = null;
}

pub fn flatpakThread(job: *FlatpakJob) void {
    defer job.done.store(true, .release);
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const cli: ShellyCli = .{ .allocator = std.heap.page_allocator, .io = threaded.io() };
    if (job.installed_only) {
        job.installed = cli.get_installed_flatpaks() catch |err| {
            job.failure = err;
            return;
        };
    } else {
        job.catalog = cli.get_remote_appstream_apps() catch |err| {
            job.failure = err;
            return;
        };
        var installed = cli.get_installed_flatpaks() catch |err| {
            job.failure = err;
            return;
        };
        defer installed.deinit();
        markInstalledFlatpaks(job.catalog.?.value, installed.value);
    }
}

pub fn markInstalledFlatpaks(apps: []flatpak.AppstreamApp, installed: []const flatpak.Flatpak) void {
    for (apps) |*app| {
        app.Installed = false;
        for (installed) |item| {
            if (item.Kind == .app and std.mem.eql(u8, app.Id, item.Id)) {
                app.Installed = true;
                break;
            }
        }
    }
}

pub fn pollFlatpak(self: *Model) !void {
    const job = self.flatpak_state.flatpak_job orelse return;
    if (!job.done.load(.acquire)) return;
    if (self.flatpak_state.flatpak_thread) |thread| thread.join();
    self.flatpak_state.flatpak_thread = null;
    self.flatpak_state.flatpak_job = null;
    defer self.gpa.destroy(job);
    var old_catalog = self.flatpak_state.flatpak_catalog;
    var old_installed = self.flatpak_state.flatpak_installed;
    defer if (!job.installed_only) {
        if (old_catalog) |*parsed| parsed.deinit();
    };
    defer if (job.installed_only) {
        if (old_installed) |*parsed| parsed.deinit();
    };
    if (self.overlay) |overlay| {
        if (overlay == .flatpak or overlay == .flatpak_install) self.overlay = null;
    }
    closeScreenshots(self);
    self.flatpak_state.flatpak_category_open = false;
    self.flatpak_state.flatpak_failure = job.failure;
    if (job.installed_only) self.flatpak_state.flatpak_installed = job.installed else self.flatpak_state.flatpak_catalog = job.catalog;
    try rebuildFlatpakFilter(self);
}

pub fn selectedScreenshotApp(self: *const Model) ?*const flatpak.AppstreamApp {
    if (self.flatpak_state.flatpak_job != null or self.flatpak_state.flatpak_list.cursor >= self.flatpak_state.flatpak_rows.items.len) return null;
    const row = self.flatpak_state.flatpak_rows.items[self.flatpak_state.flatpak_list.cursor];
    if (row != .catalog) return null;
    for (row.catalog.Screenshots) |shot| if (flatpak_images.variant(shot) != null) return row.catalog;
    return null;
}

pub fn clearScreenshotImage(self: *Model) void {
    if (self.flatpak_state.screenshot_image) |img| if (runtime.terminal) |app| app.vx.freeImage(app.tty.writer(), img.imageId());
    self.flatpak_state.screenshot_image = null;
}

pub fn closeScreenshots(self: *Model) void {
    resetScreenshots(self, true);
}

pub fn resetScreenshots(self: *Model, cancel_download: bool) void {
    self.flatpak_state.screenshot_open = false;
    self.flatpak_state.screenshot_generation +%= 1;
    self.flatpak_state.screenshot_request_after = null;
    if (cancel_download) if (self.flatpak_state.screenshot_job) |job| job.canceled.store(true, .release);
    clearScreenshotImage(self);
    if (self.flatpak_state.screenshot_items.len > 0) flatpak_images.freeItems(self.gpa, self.flatpak_state.screenshot_items);
    self.flatpak_state.screenshot_items = &.{};
    if (self.flatpak_state.screenshot_app_id.len > 0) self.gpa.free(self.flatpak_state.screenshot_app_id);
    self.flatpak_state.screenshot_app_id = "";
    self.flatpak_state.screenshot_failure = null;
}

pub fn screenshotsEnabled(self: *const Model) bool {
    return self.settings_state.settings.show_flatpak_screenshots and self.flatpak_state.screenshots_supported;
}

pub fn openScreenshots(self: *Model, ctx: *vxfw.EventContext) !void {
    if (!screenshotsEnabled(self)) return;
    const app = selectedScreenshotApp(self) orelse return;
    const items = try flatpak_images.collect(self.gpa, app);
    const app_id = self.gpa.dupe(u8, app.Id) catch |err| {
        flatpak_images.freeItems(self.gpa, items);
        return err;
    };
    resetScreenshots(self, false);
    self.flatpak_state.screenshot_app_id = app_id;
    self.flatpak_state.screenshot_items = items;
    self.flatpak_state.screenshot_index = 0;
    self.flatpak_state.screenshot_open = items.len > 0;
    try queueScreenshot(self, ctx);
}

pub fn syncScreenshots(self: *Model, ctx: *vxfw.EventContext) !void {
    const app = if (self.active == .flatpak and screenshotsEnabled(self)) selectedScreenshotApp(self) else null;
    if (app) |selected| {
        if (self.flatpak_state.screenshot_open and std.mem.eql(u8, selected.Id, self.flatpak_state.screenshot_app_id)) return;
        try openScreenshots(self, ctx);
    } else if (self.flatpak_state.screenshot_open) resetScreenshots(self, false);
}

pub fn onPreviousScreenshot(ptr: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ptr.?));
    try moveScreenshotFromMouse(self, ctx, false);
}

pub fn onNextScreenshot(ptr: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ptr.?));
    try moveScreenshotFromMouse(self, ctx, true);
}

pub fn moveScreenshotFromMouse(self: *Model, ctx: *vxfw.EventContext, forward: bool) !void {
    if (self.help_open or self.active != .flatpak or (self.overlay != null and self.overlay.? != .flatpak)) return;
    if (self.flatpak_state.flatpak_list.cursor >= self.flatpak_state.flatpak_rows.items.len) return;
    self.overlay = .{ .flatpak = self.flatpak_state.flatpak_rows.items[self.flatpak_state.flatpak_list.cursor] };
    _ = try moveScreenshot(self, ctx, forward);
    try ctx.requestFocus(self.widget());
    return ctx.consumeAndRedraw();
}

pub fn moveScreenshot(self: *Model, ctx: *vxfw.EventContext, forward: bool) !bool {
    if (!self.flatpak_state.screenshot_open or !screenshotsEnabled(self) or self.flatpak_state.screenshot_items.len < 2) return false;
    self.flatpak_state.screenshot_index = if (forward) (self.flatpak_state.screenshot_index + 1) % self.flatpak_state.screenshot_items.len else (if (self.flatpak_state.screenshot_index == 0) self.flatpak_state.screenshot_items.len - 1 else self.flatpak_state.screenshot_index - 1);
    try queueScreenshot(self, ctx);
    return true;
}

pub fn queueScreenshot(self: *Model, ctx: *vxfw.EventContext) !void {
    if (!self.flatpak_state.screenshot_open or !screenshotsEnabled(self)) return;
    // Trailing debounce: load only after the selection has stayed stable.
    // Let the sole in-flight download finish; generation checks discard it
    // if it belongs to an older selection. Never start another beside it.
    self.flatpak_state.screenshot_generation +%= 1;
    self.flatpak_state.screenshot_failure = null;
    self.flatpak_state.screenshot_request_after = std.Io.Timestamp.now(ctx.io, .awake).addDuration(.fromMilliseconds(300));
    try scheduleScreenshotTick(self, ctx);
}

pub fn screenshotTickWidget(self: *Model) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = onScreenshotTick, .drawFn = drawScreenshotTick };
}

pub fn drawScreenshotTick(ptr: *anyopaque, _: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *Model = @ptrCast(@alignCast(ptr));
    return .{ .size = .{ .width = 0, .height = 0 }, .widget = screenshotTickWidget(self), .buffer = &.{}, .children = &.{} };
}

pub fn scheduleScreenshotTick(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.flatpak_state.screenshot_tick_pending) return;
    try ctx.tick(50, screenshotTickWidget(self));
    self.flatpak_state.screenshot_tick_pending = true;
}

pub fn onScreenshotTick(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    if (event != .tick) return;
    const self: *Model = @ptrCast(@alignCast(ptr));
    self.flatpak_state.screenshot_tick_pending = false;
    pollScreenshot(self, ctx) catch |err| {
        self.flatpak_state.screenshot_failure = err;
        self.flatpak_state.screenshot_request_after = null;
    };
    if (self.flatpak_state.screenshot_job != null or self.flatpak_state.screenshot_request_after != null) try scheduleScreenshotTick(self, ctx);
    ctx.redraw = true;
}

pub fn startScreenshot(self: *Model, ctx: *vxfw.EventContext) !void {
    if (!self.flatpak_state.screenshot_open or !screenshotsEnabled(self)) return;
    if (self.flatpak_state.screenshot_job != null) return;
    _ = ctx;
    self.flatpak_state.screenshot_request_after = null;
    self.flatpak_state.screenshot_failure = null;
    const job = try self.gpa.create(flatpak_images.Job);
    errdefer self.gpa.destroy(job);
    job.* = .{ .generation = self.flatpak_state.screenshot_generation, .url = try self.gpa.dupe(u8, self.flatpak_state.screenshot_items[self.flatpak_state.screenshot_index].url) };
    errdefer self.gpa.free(job.url);
    self.flatpak_state.screenshot_thread = try std.Thread.spawn(.{}, flatpak_images.Job.run, .{job});
    self.flatpak_state.screenshot_job = job;
}

pub fn pollScreenshot(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.flatpak_state.screenshot_job) |job| {
        if (!job.done.load(.acquire)) return;
        self.flatpak_state.screenshot_thread.?.join();
        self.flatpak_state.screenshot_thread = null;
        self.flatpak_state.screenshot_job = null;
        defer job.deinit(self.gpa);
        const current = screenshotsEnabled(self) and self.flatpak_state.screenshot_open and !job.canceled.load(.acquire) and job.generation == self.flatpak_state.screenshot_generation and std.mem.eql(u8, job.url, self.flatpak_state.screenshot_items[self.flatpak_state.screenshot_index].url);
        if (current) {
            self.flatpak_state.screenshot_failure = job.failure;
            if (job.bytes) |bytes| {
                if (runtime.terminal) |app| {
                    const image = uploadScreenshot(self, app, bytes) catch |err| {
                        self.flatpak_state.screenshot_failure = err;
                        return;
                    };
                    // Complete the new upload before retiring the old image.
                    // Navigation keys never write graphics commands to the tty.
                    clearScreenshotImage(self);
                    self.flatpak_state.screenshot_image = image;
                    self.flatpak_state.screenshot_image_generation = job.generation;
                } else self.flatpak_state.screenshot_failure = error.NoGraphicsCapability;
            }
        }
    }
    if (self.flatpak_state.screenshot_request_after) |deadline| {
        if (self.flatpak_state.screenshot_open and std.Io.Timestamp.now(ctx.io, .awake).nanoseconds >= deadline.nanoseconds)
            try startScreenshot(self, ctx);
    }
}

pub fn uploadScreenshot(self: *Model, app: *vxfw.App, bytes: []const u8) !vaxis.Image {
    var decoded: ?vaxis.zigimg.Image = null;
    defer if (decoded) |*image| image.deinit(self.gpa);
    var converted: ?[]u8 = null;
    defer if (converted) |buffer| self.gpa.free(buffer);
    var png = bytes;
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) {
        decoded = try vaxis.zigimg.Image.fromMemory(self.gpa, bytes);
        // Leave room for PNG headers, filters and compression overhead,
        // including images too small for Vaxis's pixel-sized buffer.
        const pixel_bytes = decoded.?.imageByteSize();
        converted = try self.gpa.alloc(u8, pixel_bytes + pixel_bytes / 8 + 65536);
        png = try decoded.?.writeToMemory(self.gpa, converted.?, .{ .png = .{} });
    }
    const size = try flatpak_images.dimensions(png);
    const encoder = std.base64.standard.Encoder;
    const encoded = try self.gpa.alloc(u8, encoder.calcSize(png.len));
    defer self.gpa.free(encoded);
    const id = app.vx.next_img_id;
    app.vx.next_img_id += 1;
    try image_view.transmitPng(app.tty.writer(), encoder.encode(encoded, png), id, size.width, size.height);
    return vaxis.Image.init(id, size.width, size.height);
}

pub fn screenshotView(self: *Model) ?image_view.View {
    if (!self.flatpak_state.screenshot_open or !screenshotsEnabled(self) or self.flatpak_state.screenshot_items.len == 0) return null;
    // Hide captions until the shared AppStream parser selects their language correctly.
    return .{ .previous = &self.flatpak_state.screenshot_previous, .next = &self.flatpak_state.screenshot_next, .index = self.flatpak_state.screenshot_index, .count = self.flatpak_state.screenshot_items.len, .caption = "", .image = if (self.flatpak_state.screenshot_image_generation == self.flatpak_state.screenshot_generation) self.flatpak_state.screenshot_image else null, .failure = self.flatpak_state.screenshot_failure };
}

pub fn onFlatpakCategoryClick(ptr: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ptr.?));
    try toggleFlatpakCategories(self, ctx);
    return ctx.consumeAndRedraw();
}

pub fn toggleFlatpakCategories(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.help_open or self.flatpak_state.flatpak_installed_only or self.operation_state.install_job != null or operation_model.operationPrompt(self) != null or self.operation_state.review_prompt != null or (self.overlay != null and self.overlay.? != .flatpak)) return;
    self.flatpak_state.flatpak_category_open = !self.flatpak_state.flatpak_category_open;
    if (self.flatpak_state.flatpak_category_open) {
        try rebuildFlatpakCategories(self);
        try ctx.requestFocus(self.widget());
    } else try self.focusActiveTab(ctx);
}

pub fn onFlatpakCategorySelected(ptr: *anyopaque, ctx: *vxfw.EventContext, name: []const u8) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ptr));
    try chooseFlatpakCategory(self, name);
    try syncScreenshots(self, ctx);
    try self.focusActiveTab(ctx);
}

pub fn chooseFlatpakCategory(self: *Model, name: []const u8) !void {
    closeScreenshots(self);
    const owned = if (name.len > 0) try self.gpa.dupe(u8, name) else "";
    if (self.flatpak_state.flatpak_category.len > 0) self.gpa.free(self.flatpak_state.flatpak_category);
    self.flatpak_state.flatpak_category = owned;
    self.flatpak_state.flatpak_category_open = false;
    if (self.overlay != null and self.overlay.? == .flatpak) operation_model.closeOverlay(self);
    self.flatpak_state.flatpak_rows.clearRetainingCapacity();
    self.flatpak_state.flatpak_list.jumpToItem(0);
    try rebuildFlatpakFilter(self);
}

pub fn rebuildFlatpakCategories(self: *Model) !void {
    self.flatpak_state.flatpak_categories.clearRetainingCapacity();
    try self.flatpak_state.flatpak_categories.append(self.gpa, .{ .name = "", .userdata = self, .onSelect = onFlatpakCategorySelected });
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(self.gpa);
    if (self.flatpak_state.flatpak_catalog) |catalog| for (catalog.value) |app| {
        for (app.Categories) |name| {
            if (name.len == 0) continue;
            const entry = try names.getOrPut(self.gpa, name);
            if (entry.found_existing) continue;
            try self.flatpak_state.flatpak_categories.append(self.gpa, .{ .name = name, .userdata = self, .onSelect = onFlatpakCategorySelected });
        }
    };
    std.mem.sort(flatpak_view.CategoryOption, self.flatpak_state.flatpak_categories.items[1..], {}, struct {
        fn less(_: void, a: flatpak_view.CategoryOption, b: flatpak_view.CategoryOption) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    if (self.flatpak_state.flatpak_category.len > 0 and !names.contains(self.flatpak_state.flatpak_category)) {
        self.gpa.free(self.flatpak_state.flatpak_category);
        self.flatpak_state.flatpak_category = "";
    }
    self.flatpak_state.flatpak_category_list.item_count = @intCast(self.flatpak_state.flatpak_categories.items.len);
    self.flatpak_state.flatpak_category_list.jumpToItem(0);
    for (self.flatpak_state.flatpak_categories.items, 0..) |option, i| if (std.mem.eql(u8, option.name, self.flatpak_state.flatpak_category)) {
        self.flatpak_state.flatpak_category_list.jumpToItem(@intCast(i));
        break;
    };
}

pub fn buildFlatpakCategory(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
    const self: *const Model = @ptrCast(@alignCast(ptr));
    if (index >= self.flatpak_state.flatpak_categories.items.len) return null;
    return self.flatpak_state.flatpak_categories.items[index].widget();
}

pub fn matchesFlatpakCategory(self: *const Model, app: *const flatpak.AppstreamApp) bool {
    if (self.flatpak_state.flatpak_category.len == 0) return true;
    for (app.Categories) |name| if (std.mem.eql(u8, name, self.flatpak_state.flatpak_category)) return true;
    return false;
}

pub fn onFlatpakQueryChange(ptr: ?*anyopaque, ctx: *vxfw.EventContext, _: []const u8) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ptr orelse return));
    try rebuildFlatpakFilter(self);
    try syncScreenshots(self, ctx);
}

pub fn rebuildFlatpakFilter(self: *Model) Allocator.Error!void {
    try rebuildFlatpakCategories(self);
    const selected: ?flatpak_view.Row = if (self.flatpak_state.flatpak_list.cursor < self.flatpak_state.flatpak_rows.items.len) self.flatpak_state.flatpak_rows.items[self.flatpak_state.flatpak_list.cursor] else null;
    self.flatpak_state.flatpak_details_cursor = null;
    self.flatpak_state.flatpak_details_scroll.scroll = .{};
    self.flatpak_state.flatpak_rows.clearRetainingCapacity();
    const query = try self.flatpak_state.flatpak_field.buf.dupe();
    defer self.gpa.free(query);
    if (self.flatpak_state.flatpak_failure == null) {
        if (self.flatpak_state.flatpak_installed_only) {
            if (self.flatpak_state.flatpak_installed) |parsed| for (parsed.value) |*app| {
                const row: flatpak_view.Row = .{ .installed = app };
                if (row.matches(query)) try self.flatpak_state.flatpak_rows.append(self.gpa, row);
            };
        } else {
            if (self.flatpak_state.flatpak_catalog) |parsed| for (parsed.value) |*app| {
                const row: flatpak_view.Row = .{ .catalog = app };
                if (matchesFlatpakCategory(self, app) and row.matches(query)) try self.flatpak_state.flatpak_rows.append(self.gpa, row);
            };
        }
    }
    self.flatpak_state.flatpak_list.item_count = @intCast(self.flatpak_state.flatpak_rows.items.len);
    self.flatpak_state.flatpak_list.jumpToItem(0);
    if (selected) |previous| for (self.flatpak_state.flatpak_rows.items, 0..) |row, index| {
        if (row.sameIdentity(previous)) {
            self.flatpak_state.flatpak_list.jumpToItem(@intCast(index));
            break;
        }
    };
}

pub fn buildFlatpakRow(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
    const self: *const Model = @ptrCast(@alignCast(ptr));
    if (index >= self.flatpak_state.flatpak_rows.items.len) return null;
    return self.flatpak_state.flatpak_rows.items[index].widget();
}

pub fn buildFlatpakDetails(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
    const self: *const Model = @ptrCast(@alignCast(ptr));
    if (index != 0 or self.flatpak_state.flatpak_job != null or self.flatpak_state.flatpak_list.cursor >= self.flatpak_state.flatpak_rows.items.len) return null;
    return .{ .userdata = @constCast(&self.flatpak_state.flatpak_rows.items[self.flatpak_state.flatpak_list.cursor]), .drawFn = flatpak_view.drawDetails };
}

pub fn flatpakView(self: *Model) flatpak_view.View {
    if (self.flatpak_state.flatpak_details_cursor == null or self.flatpak_state.flatpak_details_cursor.? != self.flatpak_state.flatpak_list.cursor) {
        self.flatpak_state.flatpak_details_scroll.scroll = .{};
        self.flatpak_state.flatpak_details_cursor = self.flatpak_state.flatpak_list.cursor;
    }
    return .{ .images = screenshotView(self), .category = self.flatpak_state.flatpak_category, .category_button = if (!self.flatpak_state.flatpak_installed_only) &self.flatpak_state.flatpak_category_button else null, .category_list = &self.flatpak_state.flatpak_category_list, .category_open = self.flatpak_state.flatpak_category_open, .details_scroll = &self.flatpak_state.flatpak_details_scroll, .selected = if (self.flatpak_state.flatpak_job == null and self.flatpak_state.flatpak_list.cursor < self.flatpak_state.flatpak_rows.items.len) self.flatpak_state.flatpak_rows.items[self.flatpak_state.flatpak_list.cursor] else null, .list_active = self.flatpak_state.flatpak_list_active, .details_active = self.overlay != null and self.overlay.? == .flatpak, .help = if (self.help_open) &self.help_panel else null, .field = &self.flatpak_state.flatpak_field, .list = &self.flatpak_state.flatpak_list, .installed_only = self.flatpak_state.flatpak_installed_only, .loading = self.flatpak_state.flatpak_job != null, .checking_backend = self.flatpak_state.flatpak_probe_job != null, .backend_failure = self.flatpak_state.flatpak_probe_error, .failure = self.flatpak_state.flatpak_failure, .checked = if (self.flatpak_state.flatpak_installed_only) self.flatpak_state.flatpak_installed != null else self.flatpak_state.flatpak_catalog != null, .count = self.flatpak_state.flatpak_rows.items.len };
}

pub fn openFlatpakInstallChoice(self: *Model, app: *const flatpak.AppstreamApp) !void {
    if (self.operation_state.install_job != null) return;
    if (!self.settings_state.settings.flatpak_enabled or !self.flatpak_state.flatpak_available) {
        try self.setNotice("The Flatpak backend is unavailable. Refresh Flatpak before installing.");
        return;
    }
    if (app.Remotes.len == 0) {
        try self.setNotice("No configured remote is available for this catalog entry.");
        return;
    }
    var selected: usize = 0;
    for (app.Remotes, 0..) |remote, i| if (remote.Scope == .system) {
        selected = i;
        break;
    };
    self.overlay = .{ .flatpak_install = .{ .app = app, .selected = selected } };
}

pub fn openFlatpakPrompt(self: *Model, action: shelly_operation.Action, name: []const u8, target: ?shelly_operation.FlatpakTarget) !void {
    if (!self.settings_state.settings.flatpak_enabled or !self.flatpak_state.flatpak_available or self.operation_state.install_job != null) return;
    const prompt = try self.gpa.create(SudoPrompt);
    errdefer self.gpa.destroy(prompt);
    const owned_name = try self.gpa.dupe(u8, name);
    errdefer self.gpa.free(owned_name);
    prompt.* = .{
        .name = owned_name,
        .backend = .flatpak,
        .action = action,
        .password = .empty,
        .elevated = shelly_operation.flatpakNeedsElevation(action, target),
        .flatpak_target = if (target) |value| try value.clone(self.gpa) else null,
    };
    self.overlay = .{ .sudo = prompt };
}

pub const screenshotButtonStyle: @TypeOf(@as(vxfw.Button, undefined).style) = .{
    .default = .{ .fg = .{ .index = 250 } },
    .hover = .{ .fg = .{ .index = 7 }, .bold = true },
    .focus = .{ .fg = .{ .index = 7 }, .bold = true },
    .mouse_down = .{ .reverse = true },
};

test "Flatpak probe publishes independently and failure does not hide an enabled tab" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings_state.settings.flatpak_enabled = true;
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    const ready = try allocator.create(FlatpakProbeJob);
    ready.* = .{ .done = .init(true) };
    model.flatpak_state.flatpak_probe_job = ready;
    try pollFlatpakProbe(model, &events);
    try std.testing.expect(model.packages_state.loading and !model.packages_state.load.done.load(.acquire));
    try std.testing.expect(model.flatpak_state.flatpak_available);
    model.active = .flatpak;
    const failed = try allocator.create(FlatpakProbeJob);
    failed.* = .{ .done = .init(true), .failure = error.CommandFailed };
    model.flatpak_state.flatpak_probe_job = failed;
    try pollFlatpakProbe(model, &events);
    try std.testing.expect(!model.flatpak_state.flatpak_available);
    try std.testing.expectEqual(Tab.flatpak, model.active);
    try std.testing.expect(model.tabEnabled(.flatpak));
    try std.testing.expectEqual(error.CommandFailed, model.flatpak_state.flatpak_probe_error.?);
}

test "Flatpak browsing preserves scoped identity through refresh and filters locally" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings_state.settings.flatpak_enabled = true;
    model.flatpak_state.flatpak_available = true;
    model.active = .flatpak;
    model.flatpak_state.flatpak_installed_only = true;
    model.flatpak_state.flatpak_installed = try std.json.parseFromSlice([]flatpak.Flatpak, allocator,
        \\[{"Id":"org.example.Editor","InstallLevel":0,"Arch":"x86_64","Branch":"stable","Remote":"flathub"},{"Id":"org.example.Editor","InstallLevel":1,"Arch":"x86_64","Branch":"stable","Remote":"flathub"}]
    , .{ .allocate = .alloc_always });
    try rebuildFlatpakFilter(model);
    try std.testing.expectEqual(@as(usize, 2), model.flatpak_state.flatpak_rows.items.len);
    try std.testing.expect(!model.flatpak_state.flatpak_rows.items[0].sameIdentity(model.flatpak_state.flatpak_rows.items[1]));
    model.flatpak_state.flatpak_list.jumpToItem(1);
    model.overlay = .{ .flatpak = model.flatpak_state.flatpak_rows.items[1] };
    const replacement = try allocator.create(FlatpakJob);
    replacement.* = .{ .installed_only = true, .done = .init(true), .installed = try std.json.parseFromSlice([]flatpak.Flatpak, allocator,
        \\[{"Id":"org.example.Editor","InstallLevel":1,"Arch":"x86_64","Branch":"stable","Remote":"flathub"},{"Id":"org.example.Editor","InstallLevel":0,"Arch":"x86_64","Branch":"stable","Remote":"flathub"}]
    , .{ .allocate = .alloc_always }) };
    model.flatpak_state.flatpak_job = replacement;
    try pollFlatpak(model);
    try std.testing.expect(model.overlay == null);
    try std.testing.expectEqual(@as(usize, 0), model.flatpak_state.flatpak_list.cursor);
    try std.testing.expectEqual(flatpak.InstallLevel.user, model.flatpak_state.flatpak_rows.items[0].installed.InstallLevel);
    try model.flatpak_state.flatpak_field.buf.insertSliceAtCursor("EDITOR");
    try rebuildFlatpakFilter(model);
    try std.testing.expectEqual(@as(usize, 2), model.flatpak_state.flatpak_rows.items.len);
    model.flatpak_state.flatpak_field.buf.clearRetainingCapacity();
    try model.flatpak_state.flatpak_field.buf.insertSliceAtCursor("missing");
    try rebuildFlatpakFilter(model);
    try std.testing.expectEqual(@as(usize, 0), model.flatpak_state.flatpak_rows.items.len);
}

test "Flatpak browsing separates failure empty results and unconsumed job cleanup" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    const empty = try allocator.create(FlatpakJob);
    empty.* = .{ .installed_only = false, .done = .init(true), .catalog = try std.json.parseFromSlice([]flatpak.AppstreamApp, allocator, "[]", .{}) };
    model.flatpak_state.flatpak_job = empty;
    try pollFlatpak(model);
    try std.testing.expect(flatpakView(model).checked);
    try std.testing.expect(flatpakView(model).failure == null);
    const failed = try allocator.create(FlatpakJob);
    failed.* = .{ .installed_only = false, .done = .init(true), .failure = error.CommandFailed };
    model.flatpak_state.flatpak_job = failed;
    try pollFlatpak(model);
    try std.testing.expectEqual(error.CommandFailed, flatpakView(model).failure.?);
    try std.testing.expect(!flatpakView(model).checked);
    const unconsumed = try allocator.create(FlatpakJob);
    unconsumed.* = .{ .installed_only = true, .installed = try std.json.parseFromSlice([]flatpak.Flatpak, allocator, "[{\"Id\":\"org.example.App\"}]", .{ .allocate = .alloc_always }) };
    model.flatpak_state.flatpak_job = unconsumed;
    const Worker = struct {
        fn finish(job: *FlatpakJob) void {
            job.done.store(true, .release);
        }
    };
    model.flatpak_state.flatpak_thread = try std.Thread.spawn(.{}, Worker.finish, .{unconsumed});
}

test "Flatpak catalog details retain remote scopes and Enter opens the selected app" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.active = .flatpak;
    model.settings_state.settings.flatpak_enabled = true;
    model.flatpak_state.flatpak_available = true;
    model.flatpak_state.flatpak_catalog = try std.json.parseFromSlice([]flatpak.AppstreamApp, allocator,
        \\[{"Id":"org.example.App","Name":"Example","Summary":"An editor","Remotes":[{"Name":"flathub","Scope":0},{"Name":"flathub","Scope":1}]}]
    , .{ .allocate = .alloc_always });
    try rebuildFlatpakFilter(model);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    try Model.typeErasedEventHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expectEqualStrings("org.example.App", model.overlay.?.flatpak.title());
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const details = try model.overlay.?.flatpak.details(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, details, "flathub (system)") != null);
    try std.testing.expect(std.mem.indexOf(u8, details, "flathub (user)") != null);
    vxfw.DrawContext.init(.unicode);
    for ([_]vxfw.Size{ .{ .width = 80, .height = 24 }, .{ .width = 40, .height = 12 } }) |size| {
        _ = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{ .width = 10, .height = 20 } });
    }
}

test "Flatpak install chooses remote scope and owns confirmation target" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings_state.settings.flatpak_enabled = true;
    model.flatpak_state.flatpak_available = true;
    const app: flatpak.AppstreamApp = .{
        .Id = "org.example.App",
        .Name = "Example",
        .Remotes = &.{ .{ .Name = "system-remote", .Scope = .system }, .{ .Name = "user-remote", .Scope = .user } },
    };
    model.overlay = .{ .flatpak = .{ .catalog = &app } };
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = 'i' } });
    try std.testing.expect(model.overlay.? == .flatpak_install);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expectEqual(@as(usize, 1), model.overlay.?.flatpak_install.selected);
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const picker = try flatpak_view.drawInstallChoices(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{ .width = 10, .height = 20 } }, &app, 1);
    try std.testing.expectEqual(@as(u16, 80), picker.size.width);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    const prompt = model.overlay.?.sudo;
    try std.testing.expect(!prompt.elevated);
    try std.testing.expectEqual(flatpak.InstallLevel.user, prompt.flatpak_target.?.scope);
    try std.testing.expectEqualStrings("user-remote", prompt.flatpak_target.?.remote);
    try std.testing.expectEqualStrings("org.example.App", prompt.name);
    try std.testing.expect(model.operation_state.install_job == null);
    operation_model.closeOverlay(model);
    try openFlatpakPrompt(model, .install, app.Id, .{ .scope = .system, .remote = "system-remote" });
    try std.testing.expect(model.overlay.?.sudo.elevated);
}

test "Flatpak removal copies exact identity and updates require backend availability" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings_state.settings.flatpak_enabled = true;
    model.flatpak_state.flatpak_available = true;
    var apps = try std.json.parseFromSlice([]flatpak.Flatpak, allocator,
        \\[{"Id":"org.example.App","Remote":"flathub","InstallLevel":1,"Kind":0,"Arch":"x86_64","Branch":"beta","FullRef":"app/org.example.App/x86_64/beta"}]
    , .{ .allocate = .alloc_always });
    model.overlay = .{ .flatpak = .{ .installed = &apps.value[0] } };
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = 'r' } });
    apps.deinit();
    const prompt = model.overlay.?.sudo;
    try std.testing.expectEqual(shelly_operation.Action.remove, prompt.action);
    try std.testing.expectEqualStrings("app/org.example.App/x86_64/beta", prompt.flatpak_target.?.reference);
    try std.testing.expect(!prompt.elevated);
    operation_model.closeOverlay(model);
    model.updates_state.updates_parsed = try std.json.parseFromSlice(CheckUpdates, allocator, "{\"Flatpak\":[{\"Id\":\"org.example.App\"}]}", .{ .allocate = .alloc_always });
    try std.testing.expectEqual(commands.Updates.upgrade_flatpak, updates_model.updatesView(model).handleKey(.{ .codepoint = 'f' }).?);
    try updates_model.upgradeFromUpdates(model, .flatpak);
    try std.testing.expectEqual(shelly_operation.Action.upgrade, model.overlay.?.sudo.action);
    try std.testing.expect(!model.overlay.?.sudo.elevated);
    operation_model.closeOverlay(model);
    model.flatpak_state.flatpak_available = false;
    try std.testing.expect(updates_model.updatesView(model).handleKey(.{ .codepoint = 'f' }) == null);
    try updates_model.upgradeFromUpdates(model, .flatpak);
    try std.testing.expect(model.overlay == null);
}

test "Flatpak operation completion refreshes Flatpak data without changing native flags" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    var packages = [_]Package{.{ .Name = "org.example.App", .Installed = false }};
    model.packages_state.packages = &packages;
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    const job = try std.heap.page_allocator.create(shelly_operation.Operation);
    job.* = .{
        .arena = .init(std.heap.page_allocator),
        .done = .init(true),
        .request = .{ .shelly_bin = "unused", .environ_map = &env, .backend = "flatpak", .name = "org.example.App", .password = "" },
    };
    model.operation_state.install_job = job;
    try std.testing.expect(!try operation_model.pollInstall(model));
    try std.testing.expect(model.flatpak_state.refresh_flatpak_after_operation);
    try std.testing.expect(!model.updates_state.refresh_after_upgrade);
    try std.testing.expect(!packages[0].Installed);
}

test "Flatpak split details navigate back to the selected row and keep scope visible" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings_state.settings.flatpak_enabled = true;
    model.flatpak_state.flatpak_available = true;
    model.active = .flatpak;
    model.flatpak_state.flatpak_installed_only = true;
    model.flatpak_state.flatpak_installed = try std.json.parseFromSlice([]flatpak.Flatpak, allocator,
        \\[{"Id":"org.example.Editor","Name":"Editor","InstallLevel":0,"Branch":"stable","Remote":"flathub"},{"Id":"org.example.Editor","Name":"Editor","InstallLevel":1,"Branch":"stable","Remote":"flathub"}]
    , .{ .allocate = .alloc_always });
    try rebuildFlatpakFilter(model);
    model.flatpak_state.flatpak_list.jumpToItem(1);
    model.flatpak_state.flatpak_list_active = true;
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    try model.captureEvent(&events, .{ .key_press = commands.bindings.details });
    try std.testing.expect(model.overlay.? == .flatpak);
    try std.testing.expectEqual(flatpak.InstallLevel.user, model.overlay.?.flatpak.installed.InstallLevel);
    try std.testing.expect(model.commandContext().split_details);
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for ([_]vxfw.Size{ .{ .width = 100, .height = 30 }, .{ .width = 40, .height = 12 }, .{ .width = 12, .height = 5 } }) |size| {
        _ = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{ .width = 10, .height = 20 } });
    }
    try model.captureEvent(&events, .{ .key_press = .{ .codepoint = vaxis.Key.left } });
    try std.testing.expect(model.overlay == null);
    try std.testing.expect(model.flatpak_state.flatpak_list_active);
    try std.testing.expectEqual(@as(u32, 1), model.flatpak_state.flatpak_list.cursor);
    try model.captureEvent(&events, .{ .key_press = commands.bindings.search });
    try std.testing.expect(!model.flatpak_state.flatpak_list_active);
}

test "Flatpak categories combine with search and retain both remote scopes" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings_state.settings.flatpak_enabled = true;
    model.active = .flatpak;
    model.flatpak_state.flatpak_catalog = try std.json.parseFromSlice([]flatpak.AppstreamApp, allocator,
        \\[{"Id":"editor","Name":"Editor","Categories":["Utility","Development"],"Remotes":[{"Name":"flathub","Scope":0},{"Name":"flathub","Scope":1}]},{"Id":"player","Name":"Player","Categories":["AudioVideo","Utility"],"Remotes":[{"Name":"user-repo","Scope":1}]},{"Id":"unknown","Categories":[]}]
    , .{ .allocate = .alloc_always });
    try rebuildFlatpakFilter(model);
    try std.testing.expectEqual(@as(usize, 3), model.flatpak_state.flatpak_rows.items.len);
    try std.testing.expectEqual(@as(usize, 4), model.flatpak_state.flatpak_categories.items.len);
    try std.testing.expectEqualStrings("", model.flatpak_state.flatpak_categories.items[0].name);
    try std.testing.expectEqualStrings("AudioVideo", model.flatpak_state.flatpak_categories.items[1].name);
    try chooseFlatpakCategory(model, "Utility");
    try std.testing.expectEqual(@as(usize, 2), model.flatpak_state.flatpak_rows.items.len);
    try std.testing.expectEqual(@as(usize, 2), model.flatpak_state.flatpak_rows.items[0].catalog.Remotes.len);
    try model.flatpak_state.flatpak_field.buf.insertSliceAtCursor("PLAYER");
    try rebuildFlatpakFilter(model);
    try std.testing.expectEqual(@as(usize, 1), model.flatpak_state.flatpak_rows.items.len);
    try std.testing.expectEqualStrings("player", model.flatpak_state.flatpak_rows.items[0].title());
    try chooseFlatpakCategory(model, "Development");
    try std.testing.expectEqual(@as(usize, 0), model.flatpak_state.flatpak_rows.items.len);
    try chooseFlatpakCategory(model, "");
    try std.testing.expectEqual(@as(usize, 1), model.flatpak_state.flatpak_rows.items.len);
    model.flatpak_state.flatpak_field.buf.clearRetainingCapacity();
    try rebuildFlatpakFilter(model);
    try std.testing.expectEqual(@as(usize, 3), model.flatpak_state.flatpak_rows.items.len);
    // A catalog-only category filter does not hide installed applications.
    model.flatpak_state.flatpak_installed = try std.json.parseFromSlice([]flatpak.Flatpak, allocator,
        \\[{"Id":"system-app","InstallLevel":0},{"Id":"user-app","InstallLevel":1}]
    , .{ .allocate = .alloc_always });
    try chooseFlatpakCategory(model, "Development");
    model.flatpak_state.flatpak_installed_only = true;
    try rebuildFlatpakFilter(model);
    try std.testing.expectEqual(@as(usize, 2), model.flatpak_state.flatpak_rows.items.len);
    try std.testing.expect(flatpakView(model).category_button == null);
    try std.testing.expect(!model.commandContext().categories_available);
}

test "Flatpak category menu supports keyboard mouse and narrow layouts" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings_state.settings.flatpak_enabled = true;
    model.active = .flatpak;
    model.flatpak_state.flatpak_catalog = try std.json.parseFromSlice([]flatpak.AppstreamApp, allocator,
        \\[{"Id":"editor","Categories":["Utility","Development"]}]
    , .{ .allocate = .alloc_always });
    try rebuildFlatpakFilter(model);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    try model.captureEvent(&events, .{ .key_press = commands.bindings.categories });
    try std.testing.expect(model.flatpak_state.flatpak_category_open);
    try std.testing.expect(model.commandContext().category_choice);
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for ([_]vxfw.Size{ .{ .width = 100, .height = 30 }, .{ .width = 64, .height = 18 }, .{ .width = 25, .height = 16 }, .{ .width = 12, .height = 5 } }) |size| {
        _ = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{ .width = 10, .height = 20 } });
    }
    try model.captureEvent(&events, .{ .key_press = commands.bindings.next });
    try model.captureEvent(&events, .{ .key_press = commands.bindings.confirm });
    try std.testing.expectEqualStrings("Development", model.flatpak_state.flatpak_category);
    try std.testing.expect(!model.flatpak_state.flatpak_category_open);
    try model.captureEvent(&events, .{ .key_press = commands.bindings.categories });
    try model.captureEvent(&events, .{ .key_press = commands.bindings.close });
    try std.testing.expectEqualStrings("Development", model.flatpak_state.flatpak_category);
    try onFlatpakCategoryClick(model, &events);
    const surface = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 100, .height = 30 }, .cell_size = .{ .width = 10, .height = 20 } });
    var hits: std.ArrayList(vxfw.HitResult) = .empty;
    defer hits.deinit(allocator);
    // All categories is the first option beneath the selector.
    try surface.hitTest(allocator, &hits, .{ .col = 3, .row = 7 });
    try hits.items[hits.items.len - 1].widget.handleEvent(&events, .{ .mouse = .{ .button = .left, .type = .press, .col = 0, .row = 0, .mods = .{} } });
    try std.testing.expectEqualStrings("", model.flatpak_state.flatpak_category);
    try std.testing.expect(!model.flatpak_state.flatpak_category_open);
}

test "Flatpak category refresh owns selection and resets missing categories" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.flatpak_state.flatpak_catalog = try std.json.parseFromSlice([]flatpak.AppstreamApp, allocator,
        \\[{"Id":"old","Categories":["Utility"]}]
    , .{ .allocate = .alloc_always });
    try rebuildFlatpakFilter(model);
    try chooseFlatpakCategory(model, model.flatpak_state.flatpak_categories.items[1].name);
    const replacement = try allocator.create(FlatpakJob);
    replacement.* = .{ .installed_only = false, .done = .init(true), .catalog = try std.json.parseFromSlice([]flatpak.AppstreamApp, allocator,
        \\[{"Id":"new","Categories":["Game"]}]
    , .{ .allocate = .alloc_always }) };
    model.flatpak_state.flatpak_job = replacement;
    model.flatpak_state.flatpak_category_open = true;
    try pollFlatpak(model);
    try std.testing.expectEqualStrings("", model.flatpak_state.flatpak_category);
    try std.testing.expect(!model.flatpak_state.flatpak_category_open);
    try std.testing.expectEqualStrings("Game", model.flatpak_state.flatpak_categories.items[1].name);
    try std.testing.expectEqualStrings("new", model.flatpak_state.flatpak_rows.items[0].title());
}

test "inline screenshots require graphics and expose controls only in details" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings_state.settings.flatpak_enabled = true;
    model.active = .flatpak;
    model.flatpak_state.flatpak_list_active = true;
    model.flatpak_state.flatpak_catalog = try std.json.parseFromSlice([]flatpak.AppstreamApp, allocator,
        \\[{"Id":"editor","Screenshots":[{"Caption":"Editor","Images":[{"Url":"https://example.test/editor.png","Width":800}]},{"Images":[{"Url":"https://example.test/second.png"}]}]}]
    , .{ .allocate = .alloc_always });
    try rebuildFlatpakFilter(model);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    try syncScreenshots(model, &events);
    try std.testing.expect(!model.flatpak_state.screenshot_open and model.flatpak_state.screenshot_job == null);
    try std.testing.expect(screenshotView(model) == null);
    model.flatpak_state.screenshots_supported = true;
    try syncScreenshots(model, &events);
    try std.testing.expect(model.flatpak_state.screenshot_open and model.flatpak_state.screenshot_request_after != null);
    try std.testing.expect(model.overlay == null);
    try std.testing.expect(!model.commandContext().screenshots_navigable);
    model.overlay = .{ .flatpak = model.flatpak_state.flatpak_rows.items[0] };
    try std.testing.expect(model.commandContext().screenshots_navigable);
    try std.testing.expectEqual(commands.Mode.details, model.commandContext().mode);
    try model.captureEvent(&events, .{ .key_press = commands.bindings.next_screenshot });
    try std.testing.expectEqual(@as(usize, 1), model.flatpak_state.screenshot_index);
    try model.captureEvent(&events, .{ .key_press = commands.bindings.back });
    try std.testing.expect(model.overlay == null and model.flatpak_state.flatpak_list_active);
    try std.testing.expect(model.flatpak_state.screenshot_open);
    try std.testing.expect(!model.commandContext().screenshots_navigable);
    try model.captureEvent(&events, .{ .key_press = commands.bindings.previous_screenshot });
    try std.testing.expectEqual(@as(usize, 1), model.flatpak_state.screenshot_index);
    try model.flatpak_state.flatpak_field.buf.insertSliceAtCursor("missing");
    try onFlatpakQueryChange(model, &events, "missing");
    try std.testing.expect(screenshotView(model) == null);
    try std.testing.expect(model.flatpak_state.screenshot_request_after == null);
    model.flatpak_state.flatpak_field.buf.clearRetainingCapacity();
    try onFlatpakQueryChange(model, &events, "");
    try std.testing.expect(model.flatpak_state.screenshot_open);
    try std.testing.expectEqual(@as(usize, 0), model.flatpak_state.screenshot_index);
    model.active = .packages;
    try syncScreenshots(model, &events);
    try std.testing.expect(!model.flatpak_state.screenshot_open and model.flatpak_state.screenshot_request_after == null);
}

test "closed screenshot downloads discard late results without terminal access" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    const job = try allocator.create(flatpak_images.Job);
    job.* = .{ .url = try allocator.dupe(u8, "https://example.test/old.png"), .done = .init(true), .bytes = try std.heap.page_allocator.dupe(u8, "stale image bytes") };
    model.flatpak_state.screenshot_job = job;
    model.flatpak_state.screenshot_thread = try std.Thread.spawn(.{}, struct {
        fn done() void {}
    }.done, .{});
    closeScreenshots(model);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    try pollScreenshot(model, &events);
    try std.testing.expect(model.flatpak_state.screenshot_job == null and model.flatpak_state.screenshot_thread == null);
    try std.testing.expect(model.flatpak_state.screenshot_image == null and model.flatpak_state.screenshot_failure == null);
}

test "rapid screenshot navigation coalesces requests and rejects same-URL stale results" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.active = .flatpak;
    model.flatpak_state.screenshots_supported = true;
    model.flatpak_state.screenshot_open = true;
    const app: flatpak.AppstreamApp = .{ .Screenshots = &.{
        .{ .Caption = "First", .Images = &.{.{ .Url = "https://example.test/shared.png" }} },
        .{ .Caption = "Second", .Images = &.{.{ .Url = "https://example.test/shared.png" }} },
    } };
    model.flatpak_state.screenshot_items = try flatpak_images.collect(allocator, &app);
    model.overlay = .{ .flatpak = .{ .catalog = &app } };
    model.flatpak_state.screenshot_image = vaxis.Image.init(99, 800, 600);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    for (0..400) |i| {
        try model.captureEvent(&events, .{ .key_press = if (i % 2 == 0) commands.bindings.next_screenshot else commands.bindings.previous_screenshot });
        try std.testing.expectEqual(@as(u32, 99), model.flatpak_state.screenshot_image.?.imageId());
        try std.testing.expect(screenshotView(model).?.image == null);
    }
    try std.testing.expectEqual(@as(usize, 0), model.flatpak_state.screenshot_index);
    try std.testing.expectEqual(@as(u64, 400), model.flatpak_state.screenshot_generation);
    try std.testing.expectEqual(@as(usize, 1), events.cmds.items.len);
    try std.testing.expect(model.flatpak_state.screenshot_job == null);
    const pending = model.flatpak_state.screenshot_request_after.?;
    // A result with the same URL still belongs to an obsolete selection.
    const job = try allocator.create(flatpak_images.Job);
    job.* = .{ .generation = 0, .url = try allocator.dupe(u8, model.flatpak_state.screenshot_items[0].url), .done = .init(true), .bytes = try std.heap.page_allocator.dupe(u8, "stale") };
    model.flatpak_state.screenshot_job = job;
    model.flatpak_state.screenshot_thread = try std.Thread.spawn(.{}, struct {
        fn finish() void {}
    }.finish, .{});
    model.flatpak_state.screenshot_request_after = std.Io.Timestamp.now(std.testing.io, .awake).addDuration(.fromMilliseconds(30000));
    try pollScreenshot(model, &events);
    try std.testing.expect(model.flatpak_state.screenshot_job == null);
    try std.testing.expect(model.flatpak_state.screenshot_failure == null);
    try std.testing.expectEqual(@as(u32, 99), model.flatpak_state.screenshot_image.?.imageId());
    try std.testing.expect(model.flatpak_state.screenshot_request_after.?.nanoseconds >= pending.nanoseconds);
    closeScreenshots(model);
    try std.testing.expect(model.flatpak_state.screenshot_request_after == null);
    try std.testing.expect(model.flatpak_state.screenshot_image == null);
}

test "inline screenshots stay fixed while metadata scrolls and mouse buttons navigate" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings_state.settings.flatpak_enabled = true;
    model.active = .flatpak;
    model.flatpak_state.screenshots_supported = true;
    const description = try allocator.alloc(u8, 4096);
    defer allocator.free(description);
    @memset(description, 'x');
    const apps = [_]flatpak.AppstreamApp{.{ .Id = "editor", .Name = "Editor", .Description = description, .Screenshots = &.{
        .{ .Images = &.{.{ .Url = "https://example.test/one.png" }} },
        .{ .Images = &.{.{ .Url = "https://example.test/two.png" }} },
    } }};
    const json = try std.json.Stringify.valueAlloc(allocator, &apps, .{});
    defer allocator.free(json);
    model.flatpak_state.flatpak_catalog = try std.json.parseFromSlice([]flatpak.AppstreamApp, allocator, json, .{ .allocate = .alloc_always });
    try rebuildFlatpakFilter(model);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    try syncScreenshots(model, &events);
    model.flatpak_state.screenshot_image = vaxis.Image.init(42, 800, 600);
    model.flatpak_state.screenshot_image_generation = model.flatpak_state.screenshot_generation;
    model.overlay = .{ .flatpak = model.flatpak_state.flatpak_rows.items[0] };
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 100, .height = 30 }, .cell_size = .{ .width = 10, .height = 20 } };
    const Find = struct {
        fn widget(surface: vxfw.Surface, ptr: *anyopaque) ?vxfw.Surface {
            if (surface.widget.userdata == ptr) return surface;
            for (surface.children) |child| if (widget(child.surface, ptr)) |found| return found;
            return null;
        }
        fn image(surface: vxfw.Surface, origin: vxfw.RelativePoint) ?vxfw.RelativePoint {
            for (surface.buffer, 0..) |cell, i| if (cell.image != null) return .{ .row = origin.row + @as(i17, @intCast(i / surface.size.width)), .col = origin.col + @as(i17, @intCast(i % surface.size.width)) };
            for (surface.children) |child| if (image(child.surface, .{ .row = origin.row + child.origin.row, .col = origin.col + child.origin.col })) |found| return found;
            return null;
        }
    };
    const first = try model.widget().draw(ctx);
    const first_image = Find.image(first, .{ .row = 0, .col = 0 }).?;
    const scroll = Find.widget(first, &model.flatpak_state.flatpak_details_scroll).?;
    try std.testing.expect(scroll.size.height >= 5 and scroll.size.height < 24);
    try std.testing.expect(first_image.col > 40 and first_image.row < 15);
    try model.captureEvent(&events, .{ .key_press = commands.bindings.next });
    const second = try model.widget().draw(ctx);
    const second_image = Find.image(second, .{ .row = 0, .col = 0 }).?;
    try std.testing.expectEqual(first_image, second_image);
    try std.testing.expect(model.flatpak_state.flatpak_details_scroll.scroll.top > 0 or model.flatpak_state.flatpak_details_scroll.scroll.vertical_offset != 0);
    const scroll_offset = model.flatpak_state.flatpak_details_scroll.scroll.vertical_offset;
    const button = Find.widget(second, &model.flatpak_state.screenshot_next).?;
    try button.widget.handleEvent(&events, .mouse_enter);
    try button.widget.handleEvent(&events, .{ .mouse = .{ .button = .left, .type = .press, .col = 0, .row = 0, .mods = .{} } });
    try button.widget.handleEvent(&events, .{ .mouse = .{ .button = .left, .type = .release, .col = 0, .row = 0, .mods = .{} } });
    try std.testing.expectEqual(@as(usize, 1), model.flatpak_state.screenshot_index);
    try std.testing.expectEqual(scroll_offset, model.flatpak_state.flatpak_details_scroll.scroll.vertical_offset);
    try std.testing.expect(model.overlay.? == .flatpak);
    // A single screenshot retains its preview without misleading navigation.
    flatpak_images.freeItems(allocator, model.flatpak_state.screenshot_items);
    model.flatpak_state.screenshot_items = try flatpak_images.collect(allocator, &.{ .Screenshots = apps[0].Screenshots[0..1] });
    model.flatpak_state.screenshot_index = 0;
    try std.testing.expect(!model.commandContext().screenshots_navigable);
    const single = try model.widget().draw(ctx);
    try std.testing.expect(Find.widget(single, &model.flatpak_state.screenshot_previous) == null);
    try std.testing.expect(Find.widget(single, &model.flatpak_state.screenshot_next) == null);
}

test "rapid package paging retains one independent screenshot timer" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.active = .flatpak;
    model.flatpak_state.screenshots_supported = true;
    const apps = [_]flatpak.AppstreamApp{
        .{ .Id = "one", .Screenshots = &.{.{ .Images = &.{.{ .Url = "https://example.test/one.png" }} }} },
        .{ .Id = "two", .Screenshots = &.{.{ .Images = &.{.{ .Url = "https://example.test/two.png" }} }} },
    };
    for (&apps) |*app| try model.flatpak_state.flatpak_rows.append(allocator, .{ .catalog = app });
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    for (0..400) |i| {
        model.flatpak_state.flatpak_list.cursor = @intCast(i % 2);
        try syncScreenshots(model, &events);
    }
    try std.testing.expectEqual(@as(usize, 1), events.cmds.items.len);
    try std.testing.expect(events.cmds.items[0].tick.widget.eql(screenshotTickWidget(model)));
    try std.testing.expect(!events.cmds.items[0].tick.widget.eql(model.widget()));
    try std.testing.expect(model.flatpak_state.screenshot_tick_pending);
    closeScreenshots(model);
    events.cmds.clearRetainingCapacity();
    try onScreenshotTick(model, &events, .tick);
    try std.testing.expect(!model.flatpak_state.screenshot_tick_pending);
    try std.testing.expectEqual(@as(usize, 0), events.cmds.items.len);
}

test "Flatpak result scrolling stays unrestricted while images wait to load" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.active = .flatpak;
    model.flatpak_state.flatpak_list_active = true;
    model.flatpak_state.flatpak_catalog = try std.json.parseFromSlice([]flatpak.AppstreamApp, allocator,
        \\[{"Id":"one"},{"Id":"two"},{"Id":"three"}]
    , .{ .allocate = .alloc_always });
    try rebuildFlatpakFilter(model);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    for (0..500) |i| {
        try model.captureEvent(&events, .{ .key_press = if (i % 2 == 0) commands.bindings.next else commands.bindings.previous });
        try std.testing.expectEqual(@as(u32, if (i % 2 == 0) 1 else 0), model.flatpak_state.flatpak_list.cursor);
    }
    try Model.typeErasedEventHandler(model, &events, .{ .key_press = .{ .codepoint = 'n', .mods = .{ .ctrl = true } } });
    try std.testing.expectEqual(@as(u32, 1), model.flatpak_state.flatpak_list.cursor);
    events.consume_event = false;
    try model.captureEvent(&events, .{ .mouse = .{ .button = .wheel_down, .type = .press, .col = 0, .row = 0, .mods = .{} } });
    try std.testing.expect(!events.consume_event);
}

test "selection changes during a fetch debounce the latest image without canceling the active download" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.active = .flatpak;
    model.flatpak_state.screenshots_supported = true;
    const apps = [_]flatpak.AppstreamApp{
        .{ .Id = "one", .Screenshots = &.{
            .{ .Images = &.{.{ .Url = "https://example.test/one.png" }} },
            .{ .Images = &.{.{ .Url = "https://example.test/two.png" }} },
        } },
        .{ .Id = "three", .Screenshots = &.{.{ .Images = &.{.{ .Url = "https://example.test/three.png" }} }} },
    };
    for (&apps) |*app| try model.flatpak_state.flatpak_rows.append(allocator, .{ .catalog = app });
    model.flatpak_state.flatpak_list.item_count = 2;
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    try syncScreenshots(model, &events);
    model.overlay = .{ .flatpak = .{ .catalog = &apps[0] } };
    const job = try allocator.create(flatpak_images.Job);
    job.* = .{ .generation = model.flatpak_state.screenshot_generation, .url = try allocator.dupe(u8, model.flatpak_state.screenshot_items[0].url) };
    model.flatpak_state.screenshot_job = job;
    model.flatpak_state.screenshot_request_after = null;
    const before = std.Io.Timestamp.now(std.testing.io, .awake);
    try model.captureEvent(&events, .{ .key_press = commands.bindings.next_screenshot });
    try std.testing.expectEqual(@as(usize, 1), model.flatpak_state.screenshot_index);
    try std.testing.expect(model.flatpak_state.screenshot_request_after.?.nanoseconds >= before.addDuration(.fromMilliseconds(300)).nanoseconds);
    try std.testing.expect(!job.canceled.load(.acquire));
    try onNextScreenshot(model, &events);
    try std.testing.expectEqual(@as(usize, 0), model.flatpak_state.screenshot_index);
    try model.captureEvent(&events, .{ .key_press = commands.bindings.back });
    try model.captureEvent(&events, .{ .key_press = commands.bindings.next });
    try std.testing.expectEqual(@as(u32, 1), model.flatpak_state.flatpak_list.cursor);
    try syncScreenshots(model, &events);
    try std.testing.expectEqualStrings("three", model.flatpak_state.screenshot_app_id);
    try std.testing.expect(!job.canceled.load(.acquire));
    try std.testing.expect(model.flatpak_state.screenshot_job.? == job);
    const latest = model.flatpak_state.screenshot_generation;
    model.flatpak_state.screenshot_request_after = std.Io.Timestamp.now(std.testing.io, .awake).addDuration(.fromMilliseconds(30000));
    job.done.store(true, .release);
    model.flatpak_state.screenshot_thread = try std.Thread.spawn(.{}, struct {
        fn finish() void {}
    }.finish, .{});
    try pollScreenshot(model, &events);
    try std.testing.expect(model.flatpak_state.screenshot_job == null);
    try std.testing.expectEqual(latest, model.flatpak_state.screenshot_generation);
    try std.testing.expect(model.flatpak_state.screenshot_failure == null);
    try std.testing.expect(model.flatpak_state.screenshot_request_after != null);
    // Polling before the final quiet-period deadline cannot start a request.
    try pollScreenshot(model, &events);
    try std.testing.expect(model.flatpak_state.screenshot_job == null);
    closeScreenshots(model);
    try std.testing.expect(model.flatpak_state.screenshot_request_after == null);
}

test "Flatpak source authentication progress and results share the bottom operation area" {
    const allocator = std.testing.allocator;
    vxfw.DrawContext.init(.unicode);
    for ([_]flatpak.InstallLevel{ .system, .user }) |scope| {
        const model = try Model.init(allocator);
        defer model.deinit();
        model.active = .flatpak;
        model.settings_state.settings.flatpak_enabled = true;
        model.flatpak_state.flatpak_available = true;
        const app: flatpak.AppstreamApp = .{ .Id = "org.example.Editor", .Remotes = &.{ .{ .Name = "user-repo", .Scope = .user }, .{ .Name = "system-repo", .Scope = .system } } };
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
        defer events.cmds.deinit(allocator);
        try openFlatpakInstallChoice(model, &app);
        try std.testing.expectEqual(@as(usize, 1), model.overlay.?.flatpak_install.selected);
        try std.testing.expectEqual(commands.Mode.choice, model.commandContext().mode);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const Check = struct {
            fn panel(surface: vxfw.Surface) !vxfw.Size {
                var found: ?vxfw.Size = null;
                const height = surface.size.height;
                const panel_height = @max(@as(u16, 4), height / 3 + @intFromBool(height % 3 != 0));
                for (surface.children) |child| {
                    try std.testing.expectEqual(@as(u8, 0), child.z_index);
                    try std.testing.expect(child.origin.row >= 0);
                    try std.testing.expect(@as(u32, @intCast(child.origin.row)) + child.surface.size.height <= height);
                    if (child.origin.row == height - panel_height - 1 and child.surface.size.width == surface.size.width) found = child.surface.size;
                }
                const size = found orelse return error.MissingOperationPanel;
                try std.testing.expectEqual(panel_height, size.height);
                return size;
            }
        };
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{ .width = 10, .height = 20 } };
        const source_size = try Check.panel(try model.widget().draw(ctx));
        // Cancelling source selection returns to details without starting work.
        try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = commands.bindings.close });
        try std.testing.expect(model.overlay.? == .flatpak);
        try std.testing.expect(model.operation_state.install_job == null);
        try openFlatpakInstallChoice(model, &app);
        if (scope == .user) try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = commands.bindings.next });
        try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = commands.bindings.confirm });
        const prompt = model.overlay.?.sudo;
        try std.testing.expectEqual(scope == .system, prompt.elevated);
        try std.testing.expectEqual(scope, prompt.flatpak_target.?.scope);
        try std.testing.expectEqual(if (scope == .system) commands.Mode.authentication else commands.Mode.confirmation, model.commandContext().mode);
        try std.testing.expectEqual(source_size, try Check.panel(try model.widget().draw(ctx)));
        if (scope == .system) {
            try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = 'p', .text = "p" } });
            try std.testing.expectEqual(@as(usize, 1), prompt.operationView().password_length);
        }
        for ([_]SudoPrompt.State{ .running, .succeeded, .failed, .declined }) |state| {
            prompt.state = state;
            try std.testing.expectEqual(source_size, try Check.panel(try model.widget().draw(ctx)));
        }
        prompt.state = .entering;
        _ = try model.widget().draw(ctx);
        try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = commands.bindings.cancel });
        try std.testing.expect(model.overlay == null and model.operation_state.install_job == null);
        for ([_]vxfw.Size{ .{ .width = 120, .height = 40 }, .{ .width = 40, .height = 12 }, .{ .width = 12, .height = 5 } }) |size| {
            try openFlatpakInstallChoice(model, &app);
            const surface = try model.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height }));
            for (surface.children) |child| {
                try std.testing.expectEqual(@as(u8, 0), child.z_index);
                try std.testing.expect(@as(u32, @intCast(child.origin.row)) + child.surface.size.height <= size.height);
            }
        }
    }
}

test "Flatpak install cannot enter source selection without an available backend or remote" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    const app: flatpak.AppstreamApp = .{ .Id = "org.example.Editor", .Remotes = &.{.{ .Name = "flathub" }} };
    try openFlatpakInstallChoice(model, &app);
    try std.testing.expect(model.overlay == null and model.operation_state.install_job == null);
    model.settings_state.settings.flatpak_enabled = true;
    try openFlatpakInstallChoice(model, &app);
    try std.testing.expect(model.overlay == null and model.operation_state.install_job == null);
    model.flatpak_state.flatpak_available = true;
    try openFlatpakInstallChoice(model, &.{ .Id = "no-remote" });
    try std.testing.expect(model.overlay == null and model.operation_state.install_job == null);
}

test "Flatpak catalog installed markers match application IDs across scopes and reset on refresh" {
    var apps = [_]flatpak.AppstreamApp{
        .{ .Id = "org.example.System" },
        .{ .Id = "org.example.User" },
        .{ .Id = "org.example.System.Extra" },
        .{ .Id = "org.example.Runtime" },
    };
    const installed = [_]flatpak.Flatpak{
        .{ .Id = "org.example.System", .InstallLevel = .system },
        .{ .Id = "org.example.User", .InstallLevel = .user },
        .{ .Id = "org.example.Runtime", .Kind = .runtime },
    };
    markInstalledFlatpaks(&apps, &installed);
    try std.testing.expect(apps[0].Installed);
    try std.testing.expect(apps[1].Installed);
    try std.testing.expect(!apps[2].Installed);
    try std.testing.expect(!apps[3].Installed);
    markInstalledFlatpaks(&apps, &.{});
    for (apps) |app| try std.testing.expect(!app.Installed);
}

test "saved screenshot preference cancels images and preserves source state" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings_state.settings.flatpak_enabled = true;
    model.settings_state.settings_draft = model.settings_state.settings;
    model.flatpak_state.screenshots_supported = true;
    model.updates_state.updates_checked = true;
    model.settings_state.settings_selected = @import("settings_model.zig").screenshots_index;
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    try @import("settings_model.zig").toggleSetting(model, &events);
    try std.testing.expect(screenshotsEnabled(model));
    try std.testing.expect(!model.settings_state.settings_draft.show_flatpak_screenshots);
    const job = try allocator.create(flatpak_images.Job);
    job.* = .{ .url = try allocator.dupe(u8, "https://example.test/old.png"), .done = .init(true), .bytes = try std.heap.page_allocator.dupe(u8, "late image") };
    model.flatpak_state.screenshot_job = job;
    model.flatpak_state.screenshot_thread = try std.Thread.spawn(.{}, struct {
        fn done() void {}
    }.done, .{});
    model.flatpak_state.screenshot_open = true;
    @import("settings_model.zig").applySettings(model, model.settings_state.settings_draft);
    try std.testing.expect(job.canceled.load(.acquire));
    try std.testing.expect(!screenshotsEnabled(model));
    try std.testing.expect(model.updates_state.updates_checked);
    try std.testing.expect(model.settings_state.settings.flatpak_enabled);
    try syncScreenshots(model, &events);
    try queueScreenshot(model, &events);
    try std.testing.expect(model.flatpak_state.screenshot_request_after == null);
    try std.testing.expect(screenshotView(model) == null);
    try std.testing.expect(!model.commandContext().screenshots_navigable);
    try pollScreenshot(model, &events);
    try std.testing.expect(model.flatpak_state.screenshot_job == null);
    var enabled = model.settings_state.settings;
    enabled.show_flatpak_screenshots = true;
    @import("settings_model.zig").applySettings(model, enabled);
    try std.testing.expect(screenshotsEnabled(model));
    model.flatpak_state.screenshots_supported = false;
    try std.testing.expect(!screenshotsEnabled(model));
}
