const std = @import("std");
const commands = @import("commands.zig");
const packages_view = @import("views/packages_view.zig");
const aur_view = @import("views/aur_view.zig");
const updates_view = @import("views/updates_view.zig");
const pkgbuild_view = @import("views/pkgbuild_view.zig");
const PkgBuild = @import("models/pkgbuild.zig").PkgBuild;
const operation_view = @import("views/operation_view.zig");
const shelly_operation = @import("services/shelly_operation.zig");
const diagnostics = @import("diagnostics");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const shelly_cli = @import("services/shelly_cli.zig");
const ShellyCli = shelly_cli.ShellyCli;
const runtime = @import("runtime.zig");
const Package = @import("models/packages.zig").Package;
const AurPackage = @import("models/packages.zig").AurPackage;

const CheckUpdates = @import("models/sync.zig").CheckUpdates;

const Allocator = std.mem.Allocator;
const InstallBackend = shelly_cli.ShellyCli.InstallBackend;

pub const Tab = enum {
    packages,
    aur,
    upgrade,

    pub const all: []const Tab = &.{ .packages, .aur, .upgrade };

    pub fn title(self: Tab) []const u8 {
        return switch (self) {
            .packages => "Packages",
            .aur => "AUR",
            .upgrade => "Upgrade",
        };
    }
};

/// Shared state between the UI and the background package loader. The
/// loader writes exactly once; `done` is published with release semantics
/// after the result fields are written, so the UI can read them with an
/// acquire load and no lock.
const LoadState = struct {
    result: ?std.json.Parsed([]Package) = null,
    failed: bool = false,
    done: std.atomic.Value(bool) = .init(false),
};

const AurSearchJob = struct {
    result: ?std.json.Parsed([]AurPackage) = null,
    failed: bool = false,
    done: std.atomic.Value(bool) = .init(false),
};

const UpdatesJob = struct {
    result: ?std.json.Parsed(CheckUpdates) = null,
    failed: bool = false,
    done: std.atomic.Value(bool) = .init(false),
};

const PkgbuildJob = struct {
    name: []const u8,
    result: ?std.json.Parsed([]PkgBuild) = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
};

/// Modal password prompt used to elevate installs through sudo.
const SudoPrompt = struct {
    /// Package being installed; owned by `gpa`.
    name: []const u8,
    backend: InstallBackend,
    action: shelly_operation.Action = .install,
    password: std.ArrayList(u8),
    state: State = .entering,
    /// Failure detail shown after a failed attempt; owned by `gpa`.
    detail: []const u8 = "",

    progress: shelly_operation.Progress = .{},

    const State = enum { entering, running, succeeded, failed };

    fn operationView(self: *const SudoPrompt) ?operation_view.View {
        return .{
            .name = self.name,
            .action = self.action,
            .detail = self.detail,
            .progress = self.progress,
            .state = switch (self.state) {
                .entering => return null,
                .running => .running,
                .succeeded => .succeeded,
                .failed => .failed,
            },
        };
    }

    fn deinit(self: *SudoPrompt, gpa: Allocator) void {
        // Scrub the password before releasing its memory.
        @memset(self.password.items, 0);
        self.password.deinit(gpa);
        gpa.free(self.name);
        if (self.detail.len > 0) gpa.free(self.detail);
        gpa.destroy(self);
    }
};

const Overlay = union(enum) {
    package: *const Package,
    aur: *const AurPackage,
    sudo: *SudoPrompt,
    pkgbuild,
};

pub const Model = struct {
    gpa: Allocator,

    active: Tab = .packages,

    /// All known packages, borrowed from `parsed`.
    packages: []Package = &.{},
    selected_packages: std.ArrayList([]const u8),
    /// Owns the package data returned by the CLI.
    parsed: ?std.json.Parsed([]Package) = null,

    load: *LoadState,
    load_thread: ?std.Thread = null,
    loading: bool = true,
    load_failed: bool = false,

    /// Packages matching `query`, in display order.
    filtered: std.ArrayList(*const Package),
    /// Owned by `gpa` unless empty.
    query: []const u8 = "",

    /// AUR tab state.
    aur_packages: []const AurPackage = &.{},
    aur_parsed: ?std.json.Parsed([]AurPackage) = null,
    aur_job: ?*AurSearchJob = null,
    /// Last executed AUR query; owned by `gpa` unless empty.
    aur_query: []const u8 = "",
    aur_failed: bool = false,

    /// Modal package details.
    overlay: ?Overlay = null,
    pkgbuild_name: []const u8 = "",
    pkgbuild_job: ?*PkgbuildJob = null,
    pkgbuild_thread: ?std.Thread = null,
    pkgbuild_document: ?pkgbuild_view.Document = null,
    pkgbuild_failure: ?anyerror = null,
    pkgbuild_scroll: vxfw.ScrollView,

    /// The currently running install, if any.
    install_job: ?*shelly_operation.Operation = null,
    /// Result of the last finished operation; owned by `gpa` unless empty.
    updates_job: ?*UpdatesJob = null,
    updates_thread: ?std.Thread = null,
    updates_parsed: ?std.json.Parsed(CheckUpdates) = null,
    refresh_after_upgrade: bool = false,
    updates_checked: bool = false,
    updates_failed: bool = false,
    updates_list: vxfw.ListView,

    notice: []const u8 = "",

    selected_list_view: vxfw.ListView,
    list_view: vxfw.ListView,
    text_field: vxfw.TextField,
    aur_list: vxfw.ListView,
    aur_field: vxfw.TextField,

    pub fn init(gpa: Allocator) !*Model {
        const load = try gpa.create(LoadState);
        errdefer gpa.destroy(load);
        load.* = .{};

        const model = try gpa.create(Model);
        errdefer gpa.destroy(model);

        model.* = .{
            .updates_list = .{ .children = .{ .builder = .{
                .userdata = model,
                .buildFn = Model.buildUpdateRow,
            } } },
            .pkgbuild_scroll = .{ .children = .{ .builder = .{
                .userdata = model,
                .buildFn = Model.buildPkgbuildLine,
            } } },
            .gpa = gpa,
            .load = load,
            .filtered = .empty,
            .selected_packages = .empty,
            .list_view = .{
                .children = .{ .builder = .{
                    .userdata = model,
                    .buildFn = Model.buildRow,
                } },
            },
            .text_field = .{
                .buf = .init(gpa),
                .userdata = model,
                .onChange = Model.onQueryChange,
            },
            .aur_list = .{
                .children = .{ .builder = .{
                    .userdata = model,
                    .buildFn = Model.buildAurRow,
                } },
            },
            .aur_field = .{
                .buf = .init(gpa),
                .userdata = model,
                .onSubmit = Model.onAurSubmit,
            },
            .selected_list_view = .{
                .children = .{ .builder = .{
                    .userdata = model,
                    .buildFn = Model.buildSelectedRow,
                } },
            },
        };
        return model;
    }

    pub fn deinit(self: *Model) void {
        const gpa = self.gpa;
        if (self.pkgbuild_thread) |thread| thread.join();
        if (self.pkgbuild_job) |job| {
            if (job.result) |*result| result.deinit();
            gpa.free(job.name);
            gpa.destroy(job);
        }
        if (self.pkgbuild_document) |*document| document.deinit();
        if (self.pkgbuild_name.len > 0) gpa.free(self.pkgbuild_name);
        if (self.updates_thread) |thread| thread.join();
        if (self.updates_job) |job| {
            if (job.result) |*result| result.deinit();
            gpa.destroy(job);
        }
        if (self.updates_parsed) |*parsed| parsed.deinit();
        if (self.load_thread) |thread| {
            thread.join();
            self.load_thread = null;
        }
        if (self.load.result) |*result| result.deinit();
        gpa.destroy(self.load);
        self.text_field.deinit();
        self.aur_field.deinit();
        self.filtered.deinit(gpa);
        self.selected_packages.deinit(gpa);
        if (self.query.len > 0) gpa.free(self.query);
        if (self.aur_query.len > 0) gpa.free(self.aur_query);
        if (self.notice.len > 0) gpa.free(self.notice);
        if (self.parsed) |*parsed| parsed.deinit();
        if (self.aur_parsed) |*parsed| parsed.deinit();
        // Finished jobs are reaped by the pollers; anything still running at
        // exit is intentionally leaked because its worker thread may still
        // hold a reference.
        if (self.aur_job) |job| if (job.done.load(.acquire)) gpa.destroy(job);
        if (self.install_job) |operation| operation.deinit();
        if (self.overlay) |overlay| {
            switch (overlay) {
                .sudo => |prompt| prompt.deinit(gpa),
                else => {},
            }
        }
        gpa.destroy(self);
    }

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .captureHandler = typeErasedCaptureHandler,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    // -- events ------------------------------------------------------------

    /// Capture phase runs root-first, before the focused widget sees the
    /// event. This is where we intercept keys that must work even while the
    /// user is typing, and where the modal overlay swallows all input.
    fn typeErasedCaptureHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .key_press => |key| {
                const command = commands.global(key, Tab.all.len);
                if (command) |action| {
                    if (action == .quit) {
                        ctx.quit = true;
                        return ctx.consumeEvent();
                    }
                }
                if (self.overlay) |overlay| {
                    switch (overlay) {
                        .package, .aur => {
                            if (commands.detail(key)) |action| {
                                switch (action) {
                                    .close => self.closeOverlay(),
                                    .install => try self.operationFromOverlay(.install),
                                    .remove => try self.operationFromOverlay(.remove),
                                    .preview => if (overlay == .aur) try self.openPkgbuild(ctx, overlay.aur.Name),
                                }
                                return ctx.consumeAndRedraw();
                            }
                            return ctx.consumeEvent();
                        },
                        .sudo => |prompt| {
                            return self.handleSudoKey(prompt, ctx, key);
                        },
                        .pkgbuild => {
                            const view = self.pkgbuildView();
                            if (view.handleKey(key)) |action| {
                                switch (action) {
                                    .close => self.closePkgbuild(),
                                    .retry => if (self.pkgbuild_job == null) try self.openPkgbuild(ctx, self.pkgbuild_name),
                                }
                                return ctx.consumeAndRedraw();
                            }
                            if (self.pkgbuild_document != null and self.pkgbuild_job == null)
                                try self.pkgbuild_scroll.handleEvent(ctx, event);
                            return ctx.consumeAndRedraw();
                        },
                    }
                }
                if (self.active == .upgrade) {
                    if (self.updatesView().handleKey(key)) |action| {
                        switch (action) {
                            .refresh => try self.startUpdates(ctx),
                            .upgrade_system => try self.upgradeSystemFromUpdates(),
                        }
                        return ctx.consumeAndRedraw();
                    }
                }
                if (self.active == .packages and key.matches(vaxis.Key.space, .{})) {
                    if (self.list_view.cursor < self.filtered.items.len) try self.toggleSelectedList();
                    return ctx.consumeAndRedraw();
                }

                if (command) |action| {
                    switch (action) {
                        .quit => unreachable,
                        .next_tab, .previous_tab => {
                            self.switchTab(if (action == .next_tab) 1 else -1);
                            try self.focusActiveTab(ctx);
                            try self.ensureUpdates(ctx);
                        },
                        .select_tab => |index| try self.setTab(Tab.all[index], ctx),
                    }
                    return ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                try self.startLoad(ctx);
                ctx.redraw = true;
                return self.focusActiveTab(ctx);
            },
            .focus_in => {
                return self.focusActiveTab(ctx);
            },
            .tick => {
                const loading = try self.pollLoad();
                const searching = try self.pollAurSearch();
                const installing = try self.pollInstall();
                self.pollUpdates();
                try self.pollPkgbuild(ctx);
                if (self.refresh_after_upgrade and !self.loading and self.updates_job == null) {
                    try self.reloadPackages(ctx);
                    try self.startUpdates(ctx);
                    self.refresh_after_upgrade = false;
                }
                if (loading or searching or installing or self.loading or self.updates_job != null or self.pkgbuild_job != null) {
                    try ctx.tick(100, self.widget());
                }
                return ctx.consumeAndRedraw();
            },
            .key_press => |key| {
                // Enter opens the details of the selected package. On the
                // AUR tab Enter is consumed by the search field instead.
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.active == .packages and
                        self.filtered.items.len > 0 and
                        @as(usize, self.list_view.cursor) < self.filtered.items.len)
                    {
                        self.overlay = .{ .package = self.filtered.items[self.list_view.cursor] };
                        return ctx.consumeAndRedraw();
                    }
                }
                // Let the active list handle whatever the search field
                // ignored (arrow keys, mouse wheel, ...)
                return switch (self.active) {
                    .packages => self.list_view.handleEvent(ctx, event),
                    .aur => self.aur_list.handleEvent(ctx, event),
                    .upgrade => self.updates_list.handleEvent(ctx, event),
                };
            },
            .mouse => {
                if (self.overlay) |overlay| {
                    if (overlay == .pkgbuild and self.pkgbuild_document != null and self.pkgbuild_job == null)
                        return self.pkgbuild_scroll.handleEvent(ctx, event);
                }
                if (self.active == .upgrade and self.overlay == null)
                    return self.updates_list.handleEvent(ctx, event);
            },
            else => {},
        }
    }

    // -- tabs --------------------------------------------------------------

    fn switchTab(self: *Model, delta: i32) void {
        const count: i32 = @intCast(Tab.all.len);
        const current: i32 = for (Tab.all, 0..) |tab, index| {
            if (tab == self.active) break @intCast(index);
        } else unreachable;
        var next = @rem(current + delta, count);
        if (next < 0) next += count;
        self.active = Tab.all[@intCast(next)];
    }

    fn setTab(self: *Model, tab: Tab, ctx: *vxfw.EventContext) !void {
        if (tab == self.active) return;
        self.active = tab;
        try self.focusActiveTab(ctx);
        try self.ensureUpdates(ctx);
    }

    fn focusActiveTab(self: *Model, ctx: *vxfw.EventContext) !void {
        switch (self.active) {
            .packages => try ctx.requestFocus(self.text_field.widget()),
            .aur => try ctx.requestFocus(self.aur_field.widget()),
            .upgrade => try ctx.requestFocus(self.widget()),
        }
    }

    // -- background jobs ---------------------------------------------------

    fn openPkgbuild(self: *Model, ctx: *vxfw.EventContext, name: []const u8) !void {
        // Duplicate before releasing the old name, including retry of the same target.
        const owned = try self.gpa.dupe(u8, name);
        if (self.pkgbuild_name.len > 0) self.gpa.free(self.pkgbuild_name);
        self.pkgbuild_name = owned;
        if (self.pkgbuild_document) |*document| document.deinit();
        self.pkgbuild_document = null;
        self.pkgbuild_failure = null;
        self.pkgbuild_scroll.scroll = .{};
        self.pkgbuild_scroll.cursor = 0;
        self.pkgbuild_scroll.item_count = 0;
        self.overlay = .pkgbuild;
        if (self.pkgbuild_job == null) self.startPkgbuild(ctx) catch |err| {
            self.pkgbuild_failure = err;
        };
    }

    fn startPkgbuild(self: *Model, ctx: *vxfw.EventContext) !void {
        try ctx.tick(100, self.widget());
        const job = try self.gpa.create(PkgbuildJob);
        errdefer self.gpa.destroy(job);
        job.* = .{ .name = try self.gpa.dupe(u8, self.pkgbuild_name) };
        errdefer self.gpa.free(job.name);
        const thread = try std.Thread.spawn(.{}, fetchPkgbuildThread, .{job});
        self.pkgbuild_thread = thread;
        self.pkgbuild_job = job;
    }

    fn fetchPkgbuildThread(job: *PkgbuildJob) void {
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const cli: ShellyCli = .{ .allocator = std.heap.page_allocator, .io = threaded.io() };
        job.result = cli.fetch_pkgbuild(job.name) catch |err| {
            job.failure = err;
            job.done.store(true, .release);
            return;
        };
        job.done.store(true, .release);
    }

    fn pollPkgbuild(self: *Model, ctx: *vxfw.EventContext) !void {
        const job = self.pkgbuild_job orelse return;
        if (!job.done.load(.acquire)) return;
        self.pkgbuild_thread.?.join();
        self.pkgbuild_thread = null;
        self.pkgbuild_job = null;
        defer {
            if (job.result) |*result| result.deinit();
            self.gpa.free(job.name);
            self.gpa.destroy(job);
        }
        if (!std.mem.eql(u8, job.name, self.pkgbuild_name)) {
            // The user selected a different package while this request was running.
            if (self.overlay != null and self.overlay.? == .pkgbuild)
                self.startPkgbuild(ctx) catch |err| {
                    self.pkgbuild_failure = err;
                };
            return;
        }
        self.pkgbuild_failure = job.failure;
        if (job.result) |result| {
            self.pkgbuild_document = pkgbuild_view.Document.init(self.gpa, result.value) catch |err| {
                self.pkgbuild_failure = err;
                return;
            };
            self.pkgbuild_scroll.item_count = @intCast(self.pkgbuild_document.?.lines.len);
        }
    }

    fn closePkgbuild(self: *Model) void {
        self.overlay = null;
        for (self.aur_packages) |*pkg| {
            if (std.mem.eql(u8, pkg.Name, self.pkgbuild_name)) {
                self.overlay = .{ .aur = pkg };
                break;
            }
        }
    }

    fn pkgbuildView(self: *Model) pkgbuild_view.View {
        return .{
            .name = self.pkgbuild_name,
            .scroll = &self.pkgbuild_scroll,
            .loading = self.pkgbuild_job != null,
            .failure = self.pkgbuild_failure,
        };
    }

    fn buildPkgbuildLine(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (self.pkgbuild_document) |*document| return pkgbuild_view.row(document, index);
        return null;
    }

    fn ensureUpdates(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.active == .upgrade and !self.updates_checked and self.updates_job == null)
            try self.startUpdates(ctx);
    }

    fn startUpdates(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.updates_job != null or self.install_job != null) return;
        try ctx.tick(100, self.widget());
        const job = try self.gpa.create(UpdatesJob);
        errdefer self.gpa.destroy(job);
        job.* = .{};
        const thread = try std.Thread.spawn(.{}, checkUpdatesThread, .{job});
        self.updates_thread = thread;
        self.updates_job = job;
        self.updates_checked = true;
        self.updates_failed = false;
    }

    fn checkUpdatesThread(job: *UpdatesJob) void {
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const cli: ShellyCli = .{ .allocator = std.heap.page_allocator, .io = threaded.io() };
        job.result = cli.check_updates(false) catch {
            job.failed = true;
            job.done.store(true, .release);
            return;
        };
        job.done.store(true, .release);
    }

    fn pollUpdates(self: *Model) void {
        const job = self.updates_job orelse return;
        if (!job.done.load(.acquire)) return;
        self.updates_thread.?.join();
        self.updates_thread = null;
        self.updates_job = null;
        defer self.gpa.destroy(job);
        self.updates_failed = job.failed;
        if (job.result) |parsed| {
            if (self.updates_parsed) |*old| old.deinit();
            self.updates_parsed = parsed;
            self.updates_list.item_count = @intCast(parsed.value.count());
            self.updates_list.jumpToItem(0);
        }
    }

    fn updatesView(self: *Model) updates_view.View {
        return .{
            .list = &self.updates_list,
            .data = if (self.updates_parsed) |*parsed| &parsed.value else null,
            .loading = self.updates_job != null,
            .failed = self.updates_failed,
            .checked = self.updates_checked,
        };
    }

    fn buildUpdateRow(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        const parsed = self.updates_parsed orelse return null;
        return updates_view.row(&parsed.value, index);
    }

    fn upgradeSystemFromUpdates(self: *Model) !void {
        if (self.install_job != null or self.overlay != null or !self.updatesView().canUpgrade()) return;
        const prompt = try self.gpa.create(SudoPrompt);
        errdefer self.gpa.destroy(prompt);
        prompt.* = .{
            .name = try self.gpa.dupe(u8, "system packages"),
            .backend = .standard,
            .action = .upgrade,
            .password = .empty,
        };
        self.overlay = .{ .sudo = prompt };
    }

    fn reloadPackages(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.load_thread) |thread| thread.join();
        self.load_thread = null;
        self.load.* = .{};
        try self.startLoad(ctx);
        self.loading = true;
        self.load_failed = false;
    }

    fn startLoad(self: *Model, ctx: *vxfw.EventContext) !void {
        self.load_thread = try std.Thread.spawn(.{}, loadPackages, .{self.load});
        try ctx.tick(100, self.widget());
    }

    fn loadPackages(load: *LoadState) void {
        // Workers run their own threaded IO and use the page allocator so
        // they never share state with the UI thread.
        const alloc = std.heap.page_allocator;
        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        const cli: ShellyCli = .{ .allocator = alloc, .io = threaded.io() };
        const parsed = cli.get_packages(false) catch {
            load.failed = true;
            load.done.store(true, .release);
            return;
        };
        const installed = cli.get_installed_packages() catch {
            parsed.deinit();
            load.failed = true;
            load.done.store(true, .release);
            return;
        };
        defer installed.deinit();
        for (installed.value) |pkg| {
            for (parsed.value) |*p_pkg| {
                if (std.ascii.eqlIgnoreCase(p_pkg.Name, pkg.Name)) p_pkg.Installed = true;
            }
        }
        load.result = parsed;
        load.done.store(true, .release);
    }

    fn pollLoad(self: *Model) !bool {
        if (!self.loading) return false;
        if (!self.load.done.load(.acquire)) return true;

        const failed = self.load.failed;
        const parsed = self.load.result;
        self.load.result = null;
        self.loading = false;
        self.load_failed = failed;
        if (parsed) |p| {
            var old = self.parsed;
            defer if (old) |*owner| owner.deinit();
            const selected = if (self.list_view.cursor < self.filtered.items.len)
                self.filtered.items[self.list_view.cursor]
            else
                null;
            if (self.overlay) |overlay| {
                if (overlay == .package) self.overlay = null;
            }
            var previous_selection = self.selected_packages;
            defer previous_selection.deinit(self.gpa);
            self.selected_packages = .empty;
            self.parsed = p;
            self.packages = p.value;
            for (previous_selection.items) |name| {
                for (self.packages) |pkg| {
                    if (std.mem.eql(u8, pkg.Name, name)) {
                        try self.selected_packages.append(self.gpa, pkg.Name);
                        break;
                    }
                }
            }
            self.selected_list_view.item_count = @intCast(self.selected_packages.items.len);
            try self.rebuildFilter();
            if (selected) |previous| {
                for (self.filtered.items, 0..) |pkg, index| {
                    if (std.mem.eql(u8, pkg.Name, previous.Name) and
                        std.mem.eql(u8, pkg.Repository, previous.Repository))
                    {
                        self.list_view.jumpToItem(@intCast(index));
                        break;
                    }
                }
            }
        } else {
            try self.rebuildFilter();
        }
        return false;
    }

    fn onAurSubmit(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const ptr = maybe_ptr orelse return;
        const self: *Model = @ptrCast(@alignCast(ptr));
        const query = std.mem.trim(u8, str, " \t");

        // Enter with an unchanged query opens the selected result instead
        // of repeating the search
        if (self.aur_packages.len > 0 and
            (query.len == 0 or std.mem.eql(u8, query, self.aur_query)))
        {
            if (@as(usize, self.aur_list.cursor) < self.aur_packages.len) {
                self.overlay = .{ .aur = &self.aur_packages[self.aur_list.cursor] };
                return ctx.consumeAndRedraw();
            }
            return;
        }
        if (query.len == 0) return;
        if (self.aur_job != null) return; // search in flight
        try self.startAurSearch(ctx, query);
    }

    fn startAurSearch(self: *Model, ctx: *vxfw.EventContext, query: []const u8) !void {
        const job = try self.gpa.create(AurSearchJob);
        errdefer self.gpa.destroy(job);
        job.* = .{};

        const duped = try self.gpa.dupe(u8, query);
        if (self.aur_query.len > 0) self.gpa.free(self.aur_query);
        self.aur_query = duped;
        self.aur_failed = false;
        self.aur_job = job;

        const thread = try std.Thread.spawn(.{}, aurSearchThread, .{ job, duped });
        thread.detach();
        try ctx.tick(100, self.widget());
    }

    fn aurSearchThread(job: *AurSearchJob, query: []const u8) void {
        const alloc = std.heap.page_allocator;
        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        const cli: ShellyCli = .{ .allocator = alloc, .io = threaded.io() };
        const parsed = cli.search_aur(query) catch {
            job.failed = true;
            job.done.store(true, .release);
            return;
        };

        const installed = cli.get_installed_packages() catch {
            parsed.deinit();
            job.failed = true;
            job.done.store(true, .release);
            return;
        };
        defer installed.deinit();
        for (parsed.value) |*pkg| {
            for (installed.value) |local| {
                if (std.mem.eql(u8, pkg.Name, local.Name)) {
                    pkg.Installed = true;
                    break;
                }
            }
        }

        job.result = parsed;
        job.done.store(true, .release);
    }

    fn pollAurSearch(self: *Model) !bool {
        const job = self.aur_job orelse return false;
        if (!job.done.load(.acquire)) return true;

        const parsed = job.result;
        const failed = job.failed;
        self.aur_job = null;
        self.gpa.destroy(job);

        if (self.aur_parsed) |*old| old.deinit();
        self.aur_parsed = null;
        self.aur_packages = &.{};
        self.aur_failed = failed;
        if (parsed) |p| {
            self.aur_parsed = p;
            self.aur_packages = p.value;
        }
        self.aur_list.item_count = @intCast(self.aur_packages.len);
        self.aur_list.jumpToItem(0);
        return false;
    }

    fn operationFromOverlay(self: *Model, action: shelly_operation.Action) !void {
        if (self.install_job != null) return; // one install at a time
        const overlay = self.overlay orelse return;
        var name: []const u8 = undefined;
        var backend: InstallBackend = undefined;
        switch (overlay) {
            .package => |pkg| {
                if (action == .remove and !pkg.Installed) return;
                name = pkg.Name;
                backend = .standard;
            },
            .aur => |pkg| {
                if (action == .remove and !pkg.Installed) return;
                name = pkg.Name;
                backend = .aur;
            },
            .sudo, .pkgbuild => return,
        }
        const prompt = try self.gpa.create(SudoPrompt);
        errdefer self.gpa.destroy(prompt);
        prompt.* = .{
            .name = try self.gpa.dupe(u8, name),
            .backend = backend,
            .action = action,
            .password = .empty,
        };
        self.overlay = .{ .sudo = prompt };
    }

    fn toggleSelectedList(self: *Model) !void {
        const package_name = self.filtered.items[self.list_view.cursor].Name;
        for (self.selected_packages.items, 0..) |*item, index| {
            if (std.mem.eql(u8, item.*, package_name)) {
                _ = self.selected_packages.orderedRemove(index);
                return;
            }
        }
        try self.selected_packages.append(self.gpa, package_name);
    }

    fn closeOverlay(self: *Model) void {
        if (self.overlay) |overlay| {
            switch (overlay) {
                .sudo => |prompt| prompt.deinit(self.gpa),
                else => {},
            }
        }
        self.overlay = null;
    }

    fn handleSudoKey(self: *Model, prompt: *SudoPrompt, ctx: *vxfw.EventContext, key: vaxis.Key) anyerror!void {
        if (prompt.operationView()) |view| {
            if (view.handleKey(key) == .close) self.closeOverlay();
            return ctx.consumeAndRedraw();
        }

        if (key.matches(vaxis.Key.enter, .{})) {
            if (prompt.password.items.len == 0) return ctx.consumeEvent();
            try self.startElevatedInstall(ctx, prompt);
            prompt.state = .running;
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            popGrapheme(&prompt.password);
            return ctx.consumeAndRedraw();
        }
        if (key.text) |text| {
            for (text) |b| {
                if (b >= 0x20) try prompt.password.append(self.gpa, b);
            }
            return ctx.consumeAndRedraw();
        }
        return ctx.consumeEvent();
    }

    fn startElevatedInstall(self: *Model, ctx: *vxfw.EventContext, prompt: *SudoPrompt) !void {
        if (self.install_job != null) return error.OperationAlreadyRunning;
        // Schedule polling before starting so scheduling failure cannot orphan a worker.
        try ctx.tick(100, self.widget());
        self.install_job = try shelly_operation.Operation.start(.{
            .shelly_bin = shellyBin(),
            .environ_map = runtime.environ_map,
            .name = prompt.name,
            .action = prompt.action,
            .backend = @tagName(prompt.backend),
            .password = prompt.password.items,
        });
    }

    fn shellyBin() []const u8 {
        return if (runtime.is_debug)
            "../Shelly.Cli.Zig/zig-out/bin/shelly"
        else
            "shelly";
    }

    fn popGrapheme(list: *std.ArrayList(u8)) void {
        const len = list.items.len;
        if (len == 0) return;
        var n: usize = 1;
        // Walk back over UTF-8 continuation bytes to drop a whole codepoint
        while (n < len and (list.items[len - n] & 0xC0) == 0x80) n += 1;
        list.shrinkRetainingCapacity(len - n);
    }

    fn pollInstall(self: *Model) !bool {
        const job = self.install_job orelse return false;
        const result = job.poll();
        if (self.overlay) |overlay| {
            if (overlay == .sudo) overlay.sudo.progress = job.snapshot(runtime.io);
        }
        const completed = result orelse return true;
        defer job.deinit();

        const failed = completed.failed;
        self.install_job = null;
        if (job.request.action == .upgrade) self.refresh_after_upgrade = true;

        // Native and AUR operations change the same installed package database.
        if (!failed and job.request.action != .upgrade) {
            for (self.packages) |*pkg| {
                if (std.mem.eql(u8, pkg.Name, job.request.name)) {
                    pkg.Installed = job.request.action == .install;
                    break;
                }
            }
        }
        if (!failed and job.request.action != .upgrade) {
            if (self.aur_parsed) |parsed| {
                for (parsed.value) |*pkg| {
                    if (std.mem.eql(u8, pkg.Name, job.request.name))
                        pkg.Installed = job.request.action == .install;
                }
            }
        }
        // Reflect the outcome in the sudo prompt if it is still open
        if (self.overlay) |overlay| {
            switch (overlay) {
                .sudo => |prompt| {
                    if (failed) {
                        prompt.state = .failed;
                        if (prompt.detail.len > 0) self.gpa.free(prompt.detail);
                        prompt.detail = if (completed.error_detail.len > 0)
                            self.gpa.dupe(u8, completed.error_detail) catch ""
                        else
                            "";
                    } else {
                        prompt.state = .succeeded;
                    }
                },
                else => {},
            }
        }

        const message = if (failed)
            try std.fmt.allocPrint(self.gpa, "Could not {s} {f}.", .{ @tagName(job.request.action), diagnostics.safe(job.request.name) })
        else
            try std.fmt.allocPrint(self.gpa, "{s} {s}", .{ job.request.action.completed(), job.request.name });
        defer self.gpa.free(message);
        try self.setNotice(message);

        return false;
    }

    fn setNotice(self: *Model, message: []const u8) Allocator.Error!void {
        if (self.notice.len > 0) self.gpa.free(self.notice);
        self.notice = if (message.len > 0) try self.gpa.dupe(u8, message) else "";
    }

    // -- filtering ---------------------------------------------------------

    fn onQueryChange(maybe_ptr: ?*anyopaque, _: *vxfw.EventContext, str: []const u8) anyerror!void {
        const ptr = maybe_ptr orelse return;
        const self: *Model = @ptrCast(@alignCast(ptr));
        try self.setQuery(str);
    }

    fn setQuery(self: *Model, str: []const u8) Allocator.Error!void {
        const duped = if (str.len > 0) try self.gpa.dupe(u8, str) else "";
        if (self.query.len > 0) self.gpa.free(self.query);
        self.query = duped;
        try self.rebuildFilter();
    }

    fn rebuildFilter(self: *Model) Allocator.Error!void {
        self.filtered.clearRetainingCapacity();
        for (self.packages) |*pkg| {
            if (self.query.len == 0 or
                containsFold(pkg.Name, self.query) or
                containsFold(pkg.Description, self.query))
            {
                try self.filtered.append(self.gpa, pkg);
            }
        }
        self.list_view.item_count = @intCast(self.filtered.items.len);
        self.list_view.jumpToItem(0);
    }

    /// Case-insensitive substring match (ASCII folding only, which is all
    /// that package names need).
    fn containsFold(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (haystack.len < needle.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var j: usize = 0;
            while (j < needle.len and
                std.ascii.toLower(haystack[i + j]) == std.ascii.toLower(needle[j])) j += 1;
            if (j == needle.len) return true;
        }
        return false;
    }

    // -- drawing -----------------------------------------------------------

    fn packagesView(self: *Model) packages_view.View {
        return .{
            .text_field = &self.text_field,
            .list_view = &self.list_view,
            .selected_list_view = &self.selected_list_view,
            .loading = self.loading,
            .load_failed = self.load_failed,
            .query = self.query,
            .filtered_count = self.filtered.items.len,
            .package_count = self.packages.len,
        };
    }

    fn aurView(self: *Model) aur_view.View {
        return .{
            .aur_field = &self.aur_field,
            .aur_list = &self.aur_list,
            .searching = self.aur_job != null,
            .aur_failed = self.aur_failed,
            .aur_query = self.aur_query,
            .result_count = self.aur_packages.len,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const arena = ctx.arena;
        const max = ctx.max.size();

        // Need room for the tab bar, at least one content row and the
        // status bar
        if (max.width == 0 or max.height < 4) {
            return .{
                .size = max,
                .widget = self.widget(),
                .buffer = &.{},
                .children = &.{},
            };
        }

        var children: std.ArrayList(vxfw.SubSurface) = .empty;

        // Row 0: tab bar
        const tab_bar = try self.drawTabBar(arena);
        try children.append(arena, .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try tab_bar.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = max.width, .height = 1 },
            )),
        });

        switch (self.active) {
            .packages => try self.packagesView().appendContent(ctx, &children),
            .aur => try self.aurView().appendContent(ctx, &children),
            .upgrade => try self.updatesView().appendContent(ctx, &children),
        }

        // Bottom row: status bar
        var status: vxfw.Text = .{
            .text = try self.statusText(arena),
            .style = .{ .fg = .{ .index = 245 } },
        };
        try children.append(arena, .{
            .origin = .{ .row = max.height - 1, .col = 0 },
            .surface = try status.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = max.width, .height = 1 },
            )),
        });

        // Modal overlay on top of everything
        if (self.overlay) |overlay| {
            const overlay_child: ?vxfw.SubSurface = switch (overlay) {
                .package, .aur => try self.drawDetailsOverlay(ctx, arena, max, overlay),
                .sudo => |prompt| try self.drawSudoPrompt(ctx, arena, max, prompt),
                .pkgbuild => try self.pkgbuildView().draw(ctx),
            };
            if (overlay_child) |child| {
                try children.append(arena, child);
            }
        }

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }

    fn drawTabBar(self: *Model, arena: Allocator) Allocator.Error!vxfw.Widget {
        const spans = try arena.alloc(vxfw.RichText.TextSpan, Tab.all.len);
        for (Tab.all, 0..) |tab, i| {
            spans[i] = .{
                .text = try std.fmt.allocPrint(arena, " {d}:{s} ", .{ i + 1, tab.title() }),
                .style = if (tab == self.active)
                    .{ .bold = true, .reverse = true }
                else
                    .{ .fg = .{ .index = 245 } },
            };
        }
        const bar = try arena.create(TabBar);
        bar.* = .{
            .model = self,
            .rich = .{ .text = spans, .softwrap = false },
        };
        return bar.widget();
    }

    fn statusText(self: *Model, arena: Allocator) Allocator.Error![]const u8 {
        if (self.install_job) |job| {
            return try std.fmt.allocPrint(arena, "{s} {s}…", .{ job.request.action.ongoing(), job.request.name });
        }
        if (self.active == .upgrade) return self.updatesView().statusText(arena);
        if (self.notice.len > 0) return self.notice;
        return switch (self.active) {
            .packages => self.packagesView().statusText(arena),
            .aur => self.aurView().statusText(arena),
            .upgrade => self.updatesView().statusText(arena),
        };
    }

    fn drawDetailsOverlay(self: *const Model, ctx: vxfw.DrawContext, arena: Allocator, max: vxfw.Size, overlay: Overlay) Allocator.Error!?vxfw.SubSurface {
        var title: []const u8 = undefined;
        var body: []const u8 = undefined;
        switch (overlay) {
            .package => |pkg| {
                title = try std.fmt.allocPrint(arena, "{s} {s}", .{ pkg.Name, pkg.Version });
                body = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{
                    try packages_view.detailsText(arena, pkg),
                    commands.detailsHint(pkg.Installed),
                });
            },
            .aur => |pkg| {
                title = try std.fmt.allocPrint(arena, "{s} {s} (AUR)", .{ pkg.Name, pkg.Version });
                body = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{
                    try aur_view.detailsText(arena, pkg),
                    commands.aurDetailsHint(pkg.Installed),
                });
            },
            .sudo, .pkgbuild => return null,
        }
        if (self.install_job) |job| {
            body = try std.fmt.allocPrint(arena, "{s}\n\n{s} {s}…", .{ body, job.request.action.ongoing(), job.request.name });
        }

        const box_width = @min(max.width -| 2, @as(u16, 80));
        const box_height = @min(max.height -| 2, @as(u16, 28));
        if (box_width < 20 or box_height < 6) return null;

        var text: vxfw.Text = .{ .text = body };
        const labels = [_]vxfw.Border.BorderLabel{.{ .text = title, .alignment = .top_left }};
        var border: vxfw.Border = .{
            .child = text.widget(),
            .labels = &labels,
        };
        const surface = try border.widget().draw(ctx.withConstraints(
            .{ .width = 0, .height = 0 },
            .{ .width = box_width, .height = box_height },
        ));
        return .{
            .origin = .{
                .row = @divFloor(@as(i17, max.height) - @as(i17, surface.size.height), 2),
                .col = @divFloor(@as(i17, max.width) - @as(i17, surface.size.width), 2),
            },
            .surface = surface,
            .z_index = 2,
        };
    }

    fn drawSudoPrompt(_: *const Model, ctx: vxfw.DrawContext, arena: Allocator, max: vxfw.Size, prompt: *const SudoPrompt) Allocator.Error!?vxfw.SubSurface {
        if (prompt.operationView()) |view| return view.draw(ctx);
        const count = codepointCount(prompt.password.items);
        const mask = try arena.alloc(u8, count * 3);
        var pos: usize = 0;
        for (0..count) |_| {
            @memcpy(mask[pos .. pos + 3], "●");
            pos += 3;
        }
        const body = try std.fmt.allocPrint(arena, "{s} '{s}'?{s}\n\nPassword: {s}\n\n{s}", .{
            prompt.action.verb(),                                                                                                                                                                               prompt.name,
            if (prompt.action == .remove) "\nUnused dependencies and configuration will be kept." else if (prompt.action == .upgrade) "\nFull system upgrade. AUR, Flatpak and AppImage are excluded." else "", mask[0..pos],
            commands.authentication_hint,
        });

        const box_width = @min(max.width -| 2, @as(u16, 70));
        const box_height = @min(max.height -| 2, @as(u16, 20));
        if (box_width < 30 or box_height < 8) return null;

        var text: vxfw.Text = .{ .text = body };
        const labels = [_]vxfw.Border.BorderLabel{.{ .text = "Administrator privileges", .alignment = .top_left }};
        var border: vxfw.Border = .{
            .child = text.widget(),
            .labels = &labels,
        };
        const surface = try border.widget().draw(ctx.withConstraints(
            .{ .width = 0, .height = 0 },
            .{ .width = box_width, .height = box_height },
        ));
        return .{
            .origin = .{
                .row = @divFloor(@as(i17, max.height) - @as(i17, surface.size.height), 2),
                .col = @divFloor(@as(i17, max.width) - @as(i17, surface.size.width), 2),
            },
            .surface = surface,
            .z_index = 2,
        };
    }

    fn codepointCount(bytes: []const u8) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
            i += @min(@as(usize, seq_len), bytes.len - i);
            count += 1;
        }
        return count;
    }

    // -- list rows ---------------------------------------------------------

    /// ListView builder: constructs the widget for a single row on demand, so
    /// only visible rows are ever built.
    fn buildRow(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (idx >= self.filtered.items.len) return null;
        const pkg = self.filtered.items[idx];
        return .{
            .userdata = @constCast(pkg),
            .drawFn = packages_view.drawPackageRow,
        };
    }

    fn buildSelectedRow(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (idx >= self.selected_packages.items.len) return null;
        return .{ .userdata = @ptrCast(&self.selected_packages.items[idx]), .drawFn = packages_view.drawSelectedRow };
    }

    fn buildAurRow(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (idx >= self.aur_packages.len) return null;
        const pkg = &self.aur_packages[idx];
        return .{
            .userdata = @constCast(pkg),
            .drawFn = aur_view.drawAurRow,
        };
    }

    // -- details -----------------------------------------------------------

};

/// A clickable tab bar. Only widgets with an event handler participate in
/// hit testing, so this wraps the RichText instead of using it bare.
const TabBar = struct {
    model: *Model,
    rich: vxfw.RichText,

    pub fn widget(self: *TabBar) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = handleEvent,
            .drawFn = drawFn,
        };
    }

    fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *TabBar = @ptrCast(@alignCast(ptr));
        return self.rich.draw(ctx);
    }

    fn handleEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *TabBar = @ptrCast(@alignCast(ptr));
        switch (event) {
            // Mouse coordinates arrive local to this surface
            .mouse => |mouse| {
                if (mouse.button != .left or mouse.type != .press) return;
                if (mouse.col < 0) return;
                var col: i16 = 0;
                for (self.rich.text, 0..) |span, i| {
                    // Labels are ASCII, so byte length == display width
                    const width: i16 = @intCast(span.text.len);
                    if (mouse.col < col + width) {
                        try self.model.setTab(Tab.all[i], ctx);
                        return ctx.consumeAndRedraw();
                    }
                    col += width;
                }
            },
            else => {},
        }
    }
};

test "tab switching requests focus on a widget in the active page" {
    var model: Model = undefined;
    model.active = .packages;
    var ctx: vxfw.EventContext = .{
        .io = undefined,
        .alloc = std.testing.allocator,
        .cmds = .empty,
    };
    defer ctx.cmds.deinit(std.testing.allocator);

    for ([_]i32{ 1, 1, 1, -1, -1, -1 }) |direction| {
        ctx.cmds.clearRetainingCapacity();
        model.switchTab(direction);
        try model.focusActiveTab(&ctx);
        try std.testing.expectEqual(@as(usize, 1), ctx.cmds.items.len);
        const expected = switch (model.active) {
            .packages => model.text_field.widget(),
            .aur => model.aur_field.widget(),
            .upgrade => model.widget(),
        };
        try std.testing.expect(ctx.cmds.items[0].request_focus.eql(expected));
    }
}

test "tab views preserve input widgets and render without background work" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    for ([_]vxfw.Size{ .{ .width = 80, .height = 24 }, .{ .width = 40, .height = 12 } }) |size| {
        for (Tab.all) |tab| {
            model.active = tab;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const surface = try model.widget().draw(.{
                .arena = arena.allocator(),
                .min = .{},
                .max = .{ .width = size.width, .height = size.height },
                .cell_size = .{ .width = 10, .height = 20 },
            });
            try std.testing.expectEqual(size, surface.size);
            const input = switch (tab) {
                .packages => model.text_field.widget(),
                .aur => model.aur_field.widget(),
                .upgrade => model.widget(),
            };
            var found = surface.widget.eql(input);
            for (surface.children) |child| {
                found = found or child.surface.widget.eql(input);
            }
            try std.testing.expect(found);
        }
    }
}

test "updates view renders source rows and distinguishes query states" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .upgrade;
    model.updates_checked = true;
    model.updates_parsed = try std.json.parseFromSlice(CheckUpdates, std.testing.allocator,
        \\{"Packages":[{"Name":"native","CurrentVersion":"1","NewVersion":"2"}],"Aur":[{"Name":"aur","Version":"2","NewVersion":"3"}],"Flatpak":[{"Id":"org.test.App","NewVersion":"4","InstallLevel":1}],"AppImage":[{"Name":"image","Version":"5","IsUpdateAvailable":true}]}
    , .{ .allocate = .alloc_always });
    model.updates_list.item_count = 4;
    try std.testing.expectEqual(@as(usize, 4), model.updates_parsed.?.value.count());
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]vxfw.Size{ .{ .width = 80, .height = 24 }, .{ .width = 40, .height = 12 } }) |size| {
        const ctx: vxfw.DrawContext = .{
            .arena = arena.allocator(),
            .min = .{},
            .max = .{ .width = size.width, .height = size.height },
            .cell_size = .{ .width = 10, .height = 20 },
        };
        _ = try model.widget().draw(ctx);
        for (0..4) |index| {
            const widget = Model.buildUpdateRow(model, index, 0) orelse return error.MissingUpdateRow;
            _ = try widget.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 }));
        }
        try std.testing.expect(Model.buildUpdateRow(model, 4, 0) == null);
    }
    var view = model.updatesView();
    view.failed = true;
    try std.testing.expectEqualStrings("Update check failed — R: retry", try view.statusText(arena.allocator()));
    view.loading = true;
    try std.testing.expectEqualStrings("Checking for updates…", try view.statusText(arena.allocator()));
}

test "updates polling transfers results and cleans unconsumed results" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    const Worker = struct {
        fn complete(job: *UpdatesJob) void {
            job.done.store(true, .release);
        }
    };
    const job = try std.testing.allocator.create(UpdatesJob);
    job.* = .{ .result = try std.json.parseFromSlice(CheckUpdates, std.testing.allocator,
        \\{"Packages":[{"Name":"test","CurrentVersion":"1","NewVersion":"2"}]}
    , .{ .allocate = .alloc_always }) };
    model.updates_job = job;
    model.updates_thread = try std.Thread.spawn(.{}, Worker.complete, .{job});
    job.done.store(true, .release);
    model.pollUpdates();
    try std.testing.expect(model.updates_job == null);
    try std.testing.expectEqual(@as(?u32, 1), model.updates_list.item_count);
    try std.testing.expectEqualStrings("test", model.updates_parsed.?.value.Packages[0].Name);

    // A failed refresh must remain a failure, retaining the previous owned data.
    const failed = try std.testing.allocator.create(UpdatesJob);
    failed.* = .{ .failed = true };
    model.updates_job = failed;
    model.updates_thread = try std.Thread.spawn(.{}, Worker.complete, .{failed});
    failed.done.store(true, .release);
    model.pollUpdates();
    try std.testing.expect(model.updates_failed);
    try std.testing.expectEqualStrings("test", model.updates_parsed.?.value.Packages[0].Name);

    // deinit owns an unpolled worker and its result.
    const pending = try std.testing.allocator.create(UpdatesJob);
    pending.* = .{ .result = try std.json.parseFromSlice(CheckUpdates, std.testing.allocator, "{}", .{}) };
    model.updates_job = pending;
    model.updates_thread = try std.Thread.spawn(.{}, Worker.complete, .{pending});
}

test "shared commands quit from every tab and modal" {
    const model = try Model.init(std.testing.allocator);
    defer {
        model.overlay = null;
        model.deinit();
    }
    var ctx: vxfw.EventContext = .{
        .io = undefined,
        .alloc = std.testing.allocator,
        .cmds = .empty,
    };
    defer ctx.cmds.deinit(std.testing.allocator);
    for (Tab.all) |tab| {
        model.active = tab;
        ctx.quit = false;
        ctx.consume_event = false;
        try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
        try std.testing.expect(ctx.quit and ctx.consume_event);
    }
    var pkg: Package = .{ .Name = "test" };
    model.overlay = .{ .package = &pkg };
    ctx.quit = false;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
    try std.testing.expect(ctx.quit);
    var prompt: SudoPrompt = .{ .name = "test", .backend = .standard, .password = .empty };
    for ([_]SudoPrompt.State{ .entering, .running, .succeeded, .failed }) |state| {
        prompt.state = state;
        model.overlay = .{ .sudo = &prompt };
        ctx.quit = false;
        try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
        try std.testing.expect(ctx.quit);
    }
    model.overlay = .pkgbuild;
    ctx.quit = false;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
    try std.testing.expect(ctx.quit);
    model.overlay = null;
    try std.testing.expect(commands.global(.{ .codepoint = vaxis.Key.left }, Tab.all.len) == null);
    try std.testing.expect(commands.global(.{ .codepoint = '1' }, Tab.all.len) == null);
}

test "updates action opens a native-only upgrade prompt" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.updates_checked = true;
    model.updates_parsed = try std.json.parseFromSlice(CheckUpdates, std.testing.allocator,
        \\{"Packages":[{"Name":"native","CurrentVersion":"1","NewVersion":"2"}],"Aur":[{"Name":"foreign"}]}
    , .{ .allocate = .alloc_always });
    const action = model.updatesView().handleKey(.{ .codepoint = 'u' });
    try std.testing.expectEqual(commands.Updates.upgrade_system, action.?);
    try model.upgradeSystemFromUpdates();
    const prompt = model.overlay.?.sudo;
    try std.testing.expectEqual(shelly_operation.Action.upgrade, prompt.action);
    try std.testing.expectEqual(InstallBackend.standard, prompt.backend);
    try std.testing.expectEqualStrings("system packages", prompt.name);
    model.closeOverlay();
    model.updates_failed = true;
    try std.testing.expect(model.updatesView().handleKey(.{ .codepoint = 'u' }) == null);
}

test "package refresh replaces borrowed data and preserves selection" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.parsed = try std.json.parseFromSlice([]Package, std.testing.allocator,
        \\[{"Name":"native","Repository":"repo","Version":"1","Installed":true}]
    , .{ .allocate = .alloc_always });
    model.packages = model.parsed.?.value;
    try model.rebuildFilter();
    try model.selected_packages.append(std.testing.allocator, model.packages[0].Name);
    model.load.result = try std.json.parseFromSlice([]Package, std.testing.allocator,
        \\[{"Name":"native","Repository":"repo","Version":"2","Installed":true}]
    , .{ .allocate = .alloc_always });
    model.load.done.store(true, .release);
    model.loading = true;
    _ = try model.pollLoad();
    try std.testing.expectEqualStrings("2", model.packages[0].Version);
    try std.testing.expectEqualStrings("native", model.selected_packages.items[0]);
    try std.testing.expect(model.selected_packages.items[0].ptr == model.packages[0].Name.ptr);
    try std.testing.expectEqual(@as(u32, 0), model.list_view.cursor);
}

test "PKGBUILD preview renders scrolls and returns to AUR details" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .aur;
    var package = [_]AurPackage{.{ .Name = "demo" }};
    model.aur_packages = &package;
    model.pkgbuild_name = try std.testing.allocator.dupe(u8, "demo");
    const line = "echo a long source line with content and more content and more content and more content\n";
    var source_buffer: [line.len * 80]u8 = undefined;
    for (0..80) |index| @memcpy(source_buffer[index * line.len ..][0..line.len], line);
    const source = &source_buffer;
    model.pkgbuild_document = try pkgbuild_view.Document.init(std.testing.allocator, &.{.{ .Name = "demo", .PkgBuild = source }});
    model.pkgbuild_scroll.item_count = @intCast(model.pkgbuild_document.?.lines.len);
    model.overlay = .pkgbuild;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]vxfw.Size{ .{ .width = 80, .height = 24 }, .{ .width = 40, .height = 12 } }) |size| {
        const ctx: vxfw.DrawContext = .{
            .arena = arena.allocator(),
            .min = .{},
            .max = .{ .width = size.width, .height = size.height },
            .cell_size = .{ .width = 10, .height = 20 },
        };
        const first = (try model.pkgbuildView().draw(ctx)).?;
        var state_view = model.pkgbuildView();
        state_view.loading = true;
        try std.testing.expectEqual(first.surface.size, (try state_view.draw(ctx)).?.surface.size);
        state_view.loading = false;
        state_view.failure = error.CommandFailed;
        try std.testing.expectEqual(first.surface.size, (try state_view.draw(ctx)).?.surface.size);
        var events: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
        defer events.cmds.deinit(std.testing.allocator);
        for (0..6) |_| {
            try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
            _ = try model.pkgbuildView().draw(ctx);
        }
        try std.testing.expect(model.pkgbuild_scroll.scroll.top > 0);
        const after = (try model.pkgbuildView().draw(ctx)).?;
        try std.testing.expectEqual(first.surface.size, after.surface.size);
    }
    model.closePkgbuild();
    try std.testing.expect(model.overlay.? == .aur);
    try std.testing.expectEqualStrings("demo", model.overlay.?.aur.Name);
}

test "PKGBUILD preview discards stale results and joins unpolled jobs" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.pkgbuild_name = try std.testing.allocator.dupe(u8, "new-target");
    const Worker = struct {
        fn finish(job: *PkgbuildJob) void {
            job.done.store(true, .release);
        }
    };
    const job = try std.testing.allocator.create(PkgbuildJob);
    job.* = .{
        .name = try std.testing.allocator.dupe(u8, "old-target"),
        .result = try std.json.parseFromSlice([]PkgBuild, std.testing.allocator,
            \\[{"Name":"old-target","PkgBuild":"echo old"}]
        , .{ .allocate = .alloc_always }),
    };
    model.pkgbuild_job = job;
    model.pkgbuild_thread = try std.Thread.spawn(.{}, Worker.finish, .{job});
    job.done.store(true, .release);
    var ctx: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    try model.pollPkgbuild(&ctx);
    try std.testing.expect(model.pkgbuild_document == null);
    try std.testing.expect(model.pkgbuild_job == null);
    const pending = try std.testing.allocator.create(PkgbuildJob);
    pending.* = .{
        .name = try std.testing.allocator.dupe(u8, "new-target"),
        .result = try std.json.parseFromSlice([]PkgBuild, std.testing.allocator,
            \\[{"Name":"new-target","PkgBuild":"echo new"}]
        , .{ .allocate = .alloc_always }),
    };
    model.pkgbuild_job = pending;
    model.pkgbuild_thread = try std.Thread.spawn(.{}, Worker.finish, .{pending});
    // Model.deinit joins and frees this unconsumed result.
}
