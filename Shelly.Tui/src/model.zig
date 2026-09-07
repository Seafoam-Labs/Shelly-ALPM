const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const builtin = @import("builtin");
const shelly_cli = @import("shelly_cli.zig");
const ShellyCli = shelly_cli.ShellyCli;
const runtime = @import("runtime.zig");
const Package = @import("packages.zig").Package;
const AurPackage = @import("packages.zig").AurPackage;

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

const InstallJob = struct {
    name: []const u8,
    backend: InstallBackend,
    failed: bool = false,
    /// Failure output captured by the worker; owned by the page allocator.
    error_detail: []const u8 = "",
    done: std.atomic.Value(bool) = .init(false),
};

/// Modal password prompt used to elevate installs through sudo.
const SudoPrompt = struct {
    /// Package being installed; owned by `gpa`.
    name: []const u8,
    backend: InstallBackend,
    password: std.ArrayList(u8),
    state: State = .entering,
    /// Failure detail shown after a failed attempt; owned by `gpa`.
    detail: []const u8 = "",

    const State = enum { entering, running, succeeded, failed };

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
    /// The currently running install, if any.
    install_job: ?*InstallJob = null,
    /// Result of the last finished operation; owned by `gpa` unless empty.
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
        if (self.install_job) |job| {
            if (job.done.load(.acquire)) {
                if (job.error_detail.len > 0) {
                    std.heap.page_allocator.free(@constCast(job.error_detail));
                }
                gpa.free(job.name);
                gpa.destroy(job);
            }
        }
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
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }
                if (self.overlay) |overlay| {
                    switch (overlay) {
                        .package, .aur => {
                            if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
                                self.closeOverlay();
                                return ctx.consumeAndRedraw();
                            }
                            if (key.matches('i', .{})) {
                                try self.installFromOverlay();
                                return ctx.consumeAndRedraw();
                            }
                            return ctx.consumeEvent();
                        },
                        .sudo => |prompt| {
                            return self.handleSudoKey(prompt, ctx, key);
                        },
                    }
                }
                if (key.matches(vaxis.Key.space, .{})) {
                    try self.toggleSelectedList();
                    return ctx.consumeAndRedraw();
                }

                if (key.matches(vaxis.Key.tab, .{})) {
                    self.switchTab(1);
                    try self.focusActiveTab(ctx);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
                    self.switchTab(-1);
                    try self.focusActiveTab(ctx);
                    return ctx.consumeAndRedraw();
                }
                // Alt+<n> jumps straight to tab n
                for (Tab.all, 1..) |tab, number| {
                    if (key.matches('0' + @as(u21, @intCast(number)), .{ .alt = true })) {
                        try self.setTab(tab, ctx);
                        return ctx.consumeAndRedraw();
                    }
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
                if (loading or searching or installing) {
                    try ctx.tick(100, self.widget());
                }
                return ctx.consumeAndRedraw();
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }
                if (key.matches(vaxis.Key.escape, .{})) {
                    switch (self.active) {
                        .packages => {
                            if (self.query.len > 0) {
                                self.text_field.clearRetainingCapacity();
                                try self.setQuery("");
                                return ctx.consumeAndRedraw();
                            }
                        },
                        .aur => {
                            if (self.aur_field.buf.realLength() > 0) {
                                self.aur_field.clearRetainingCapacity();
                                return ctx.consumeAndRedraw();
                            }
                        },
                        .upgrade => {
                            return ctx.consumeAndRedraw();
                        },
                    }
                    ctx.quit = true;
                    return;
                }
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
                // Arrows and plain digits switch tabs. Note these only fire
                // when the search field does not have focus — the field
                // consumes arrows for cursor movement and digits as text.
                if (key.matches(vaxis.Key.left, .{})) {
                    self.switchTab(-1);
                    try self.focusActiveTab(ctx);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.right, .{})) {
                    self.switchTab(1);
                    try self.focusActiveTab(ctx);
                    return ctx.consumeAndRedraw();
                }
                for (Tab.all, 1..) |tab, number| {
                    if (key.matches('0' + @as(u21, @intCast(number)), .{})) {
                        try self.setTab(tab, ctx);
                        return ctx.consumeAndRedraw();
                    }
                }
                // Let the active list handle whatever the search field
                // ignored (arrow keys, mouse wheel, ...)
                return switch (self.active) {
                    .packages => self.list_view.handleEvent(ctx, event),
                    .aur => self.aur_list.handleEvent(ctx, event),
                    .upgrade => {},
                };
            },
            else => {},
        }
    }

    // -- tabs --------------------------------------------------------------

    fn switchTab(self: *Model, delta: i32) void {
        const count: i32 = @intCast(Tab.all.len);
        var next: i32 = @intFromEnum(self.active);
        next = @rem(next + delta, count);
        if (next < 0) next += count;
        self.active = @enumFromInt(@as(std.meta.Tag(Tab), @intCast(next)));
    }

    fn setTab(self: *Model, tab: Tab, ctx: *vxfw.EventContext) !void {
        if (tab == self.active) return;
        self.active = tab;
        try self.focusActiveTab(ctx);
    }

    fn focusActiveTab(self: *Model, ctx: *vxfw.EventContext) !void {
        switch (self.active) {
            .packages => try ctx.requestFocus(self.text_field.widget()),
            .aur => try ctx.requestFocus(self.aur_field.widget()),
            .upgrade => {},
        }
    }

    // -- background jobs ---------------------------------------------------

    fn startLoad(self: *Model, ctx: *vxfw.EventContext) !void {
        const thread = try std.Thread.spawn(.{}, loadPackages, .{self.load});
        thread.detach();
        try ctx.tick(100, self.widget());
    }

    fn loadPackages(load: *LoadState) void {
        // Workers run their own threaded IO and use the page allocator so
        // they never share state with the UI thread.
        const alloc = std.heap.page_allocator;
        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        const cli: ShellyCli = .{ .allocator = alloc, .io = threaded.io() };
        const parsed = cli.get_packages() catch {
            load.failed = true;
            load.done.store(true, .release);
            return;
        };
        const installed = cli.get_installed_packages() catch {
            load.failed = true;
            load.done.store(true, .release);
            return;
        };
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
        self.loading = false;
        self.load_failed = failed;
        if (parsed) |p| {
            self.parsed = p;
            self.packages = p.value;
        }
        try self.rebuildFilter();
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

    fn installFromOverlay(self: *Model) !void {
        if (self.install_job != null) return; // one install at a time
        const overlay = self.overlay orelse return;
        var name: []const u8 = undefined;
        var backend: InstallBackend = undefined;
        switch (overlay) {
            .package => |pkg| {
                name = pkg.Name;
                backend = .standard;
            },
            .aur => |pkg| {
                name = pkg.Name;
                backend = .aur;
            },
            .sudo => return,
        }
        const prompt = try self.gpa.create(SudoPrompt);
        errdefer self.gpa.destroy(prompt);
        prompt.* = .{
            .name = try self.gpa.dupe(u8, name),
            .backend = backend,
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
        switch (prompt.state) {
            .entering => {
                if (key.matches(vaxis.Key.escape, .{})) {
                    self.closeOverlay();
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
                    // Record printable input only; skip control characters
                    for (text) |b| {
                        if (b >= 0x20) try prompt.password.append(self.gpa, b);
                    }
                    return ctx.consumeAndRedraw();
                }
                return ctx.consumeEvent();
            },
            .running => {
                // Ctrl+C is intercepted earlier, in the capture handler
                return ctx.consumeEvent();
            },
            .succeeded, .failed => {
                if (key.matches(vaxis.Key.escape, .{}) or
                    key.matches(vaxis.Key.enter, .{}) or
                    key.matches('q', .{}))
                {
                    self.closeOverlay();
                    return ctx.consumeAndRedraw();
                }
                return ctx.consumeEvent();
            },
        }
    }

    fn startElevatedInstall(self: *Model, ctx: *vxfw.EventContext, prompt: *SudoPrompt) !void {
        const job = try self.gpa.create(InstallJob);
        errdefer self.gpa.destroy(job);
        job.* = .{
            .name = try self.gpa.dupe(u8, prompt.name),
            .backend = prompt.backend,
        };
        errdefer self.gpa.free(job.name);
        self.install_job = job;

        // The worker owns this copy and wipes it after feeding it to sudo.
        // It must be allocated with the page allocator because the worker
        // frees it with the page allocator (using a different allocator than
        // the one that allocated a block is undefined behavior).
        const password = try std.heap.page_allocator.dupe(u8, prompt.password.items);
        errdefer std.heap.page_allocator.free(password);

        const thread = try std.Thread.spawn(.{}, installElevatedThread, .{ job, password });
        thread.detach();
        try ctx.tick(100, self.widget());
    }

    fn installElevatedThread(job: *InstallJob, password: []u8) void {
        const alloc = std.heap.page_allocator;
        defer {
            // Wipe and release the duplicated password
            @memset(password, 0);
            alloc.free(password);
        }

        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        elevatedInstall(threaded.io(), alloc, job, password);
        job.done.store(true, .release);
    }

    fn elevatedInstall(io: std.Io, alloc: Allocator, job: *InstallJob, password: []const u8) void {
        const argv = alloc.alloc([]const u8, 10) catch {
            job.failed = true;
            return;
        };
        defer alloc.free(argv);
        argv[0] = "sudo";
        argv[1] = "-S";
        argv[2] = "-p";
        argv[3] = "";
        argv[4] = shellyBin();
        argv[5] = "install";
        argv[6] = @tagName(job.backend);
        argv[7] = job.name;
        argv[8] = "--no-confirm";
        argv[9] = "--ui-mode";

        var child = std.process.spawn(io, .{
            .argv = argv,
            .environ_map = runtime.environ_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch {
            job.error_detail = alloc.dupe(u8, "Failed to start sudo.") catch "";
            job.failed = true;
            return;
        };
        defer child.kill(io);

        // Feed the password to sudo, then close stdin. The writes fail
        // harmlessly if sudo already exited (e.g. wrong password); the
        // error then surfaces via stderr below.
        {
            var stdin_buffer: [1024]u8 = undefined;
            var stdin_writer = child.stdin.?.writer(io, &stdin_buffer);
            const stdin = &stdin_writer.interface;
            stdin.writeAll(password) catch {};
            stdin.writeByte('\n') catch {};
            stdin.flush() catch {};
            child.stdin.?.close(io);
            child.stdin = null;
        }

        // Drain both streams concurrently, mirroring std.process.run
        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(alloc, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer multi_reader.deinit();

        var read_failed = false;
        while (true) {
            multi_reader.fill(64, .none) catch |err| {
                if (err != error.EndOfStream) read_failed = true;
                break;
            };
        }
        if (read_failed) {
            job.error_detail = alloc.dupe(u8, "Failed to read the command output.") catch "";
            job.failed = true;
            return;
        }

        const term = child.wait(io) catch {
            job.error_detail = alloc.dupe(u8, "Failed to wait for the command.") catch "";
            job.failed = true;
            return;
        };

        if (term != .exited or term.exited != 0) {
            const stderr = multi_reader.toOwnedSlice(1) catch &.{};
            const stdout = multi_reader.toOwnedSlice(0) catch &.{};
            defer if (stderr.len > 0) alloc.free(stderr);
            defer if (stdout.len > 0) alloc.free(stdout);
            job.error_detail = (@import("ui_decode.zig").JsonPackFrame.failureMessage(alloc, stdout) catch null) orelse
                (alloc.dupe(u8, if (stderr.len > 0) std.mem.trim(u8, stderr, " \t\r\n") else "Could not complete the installation. No error details were returned by Shelly.") catch "");
            job.failed = true;
        }
    }

    fn shellyBin() []const u8 {
        return if (builtin.mode == .Debug)
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
        if (!job.done.load(.acquire)) return true;

        const failed = job.failed;
        self.install_job = null;

        // Reflect a successful standard install in the loaded data
        if (!failed and job.backend == .standard) {
            for (self.packages) |*pkg| {
                if (std.mem.eql(u8, pkg.Name, job.name)) {
                    pkg.Installed = true;
                    break;
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
                        prompt.detail = if (job.error_detail.len > 0)
                            self.gpa.dupe(u8, job.error_detail) catch ""
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
            try std.fmt.allocPrint(self.gpa, "Installation failed: {s}", .{job.name})
        else
            try std.fmt.allocPrint(self.gpa, "Installed {s}", .{job.name});
        try self.setNotice(message);
        self.gpa.free(message);

        if (job.error_detail.len > 0) {
            std.heap.page_allocator.free(@constCast(job.error_detail));
        }
        self.gpa.free(job.name);
        self.gpa.destroy(job);
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

        const right_w: u16 = @max(24, max.width / 4); // pick a panel width
        const left_w: u16 = max.width -| right_w;
        switch (self.active) {
            .packages => {
                // Row 1: search prompt + field
                var prompt: vxfw.Text = .{ .text = "❯", .style = .{ .fg = .{ .index = 4 } } };
                try children.append(arena, .{
                    .origin = .{ .row = 1, .col = 0 },
                    .surface = try prompt.draw(ctx.withConstraints(
                        ctx.min,
                        .{ .width = 2, .height = 1 },
                    )),
                });
                try children.append(arena, .{
                    .origin = .{ .row = 1, .col = 2 },
                    .surface = try self.text_field.draw(ctx.withConstraints(
                        ctx.min,
                        .{ .width = max.width -| 2, .height = 1 },
                    )),
                });

                // Rows 2..height-2: package list
                try children.append(arena, .{
                    .origin = .{ .row = 2, .col = 0 },
                    .surface = try self.list_view.draw(ctx.withConstraints(
                        .{ .width = 0, .height = 0 },
                        .{ .width = left_w -| 1, .height = max.height - 3 },
                    )),
                });
                try children.append(arena, .{
                    .origin = .{ .row = 2, .col = left_w },
                    .surface = try self.selected_list_view.draw(ctx.withConstraints(.{ .width = 0, .height = 0 }, .{ .width = right_w, .height = max.height - 3 })),
                });

                if (self.loading or self.load_failed) {
                    var message: vxfw.Text = if (self.loading)
                        .{ .text = "Loading packages…", .style = .{ .fg = .{ .index = 245 } } }
                    else
                        .{ .text = "Failed to load packages. Is the shelly CLI available?", .style = .{ .fg = .{ .index = 1 } } };
                    try children.append(arena, .{
                        .origin = .{ .row = 3, .col = 2 },
                        .surface = try message.draw(ctx.withConstraints(
                            ctx.min,
                            .{ .width = max.width -| 2, .height = 1 },
                        )),
                        .z_index = 1,
                    });
                }
            },
            .aur => {
                // Row 1: search prompt + field
                var prompt: vxfw.Text = .{ .text = "❯", .style = .{ .fg = .{ .index = 4 } } };
                try children.append(arena, .{
                    .origin = .{ .row = 1, .col = 0 },
                    .surface = try prompt.draw(ctx.withConstraints(
                        ctx.min,
                        .{ .width = 2, .height = 1 },
                    )),
                });
                try children.append(arena, .{
                    .origin = .{ .row = 1, .col = 2 },
                    .surface = try self.aur_field.draw(ctx.withConstraints(
                        ctx.min,
                        .{ .width = max.width -| 2, .height = 1 },
                    )),
                });

                // Rows 2..height-2: results
                try children.append(arena, .{
                    .origin = .{ .row = 2, .col = 0 },
                    .surface = try self.aur_list.draw(ctx.withConstraints(
                        .{ .width = 0, .height = 0 },
                        .{ .width = max.width, .height = max.height - 3 },
                    )),
                });

                if (try self.aurMessage(arena)) |message| {
                    var message_text: vxfw.Text = .{
                        .text = message.text,
                        .style = .{ .fg = .{ .index = if (message.red) @as(u8, 1) else 245 } },
                    };
                    try children.append(arena, .{
                        .origin = .{ .row = 3, .col = 2 },
                        .surface = try message_text.draw(ctx.withConstraints(
                            ctx.min,
                            .{ .width = max.width -| 2, .height = 1 },
                        )),
                        .z_index = 1,
                    });
                }
            },
            .upgrade => {},
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

    fn aurMessage(self: *const Model, arena: Allocator) Allocator.Error!?struct { text: []const u8, red: bool } {
        if (self.aur_job != null) {
            return .{
                .text = try std.fmt.allocPrint(arena, "Searching AUR for '{s}'…", .{self.aur_query}),
                .red = false,
            };
        }
        if (self.aur_failed) {
            return .{ .text = "AUR search failed. Check your connection and try again.", .red = true };
        }
        if (self.aur_query.len == 0) {
            return .{ .text = "Type a search term and press Enter to query the AUR.", .red = false };
        }
        if (self.aur_packages.len == 0) {
            return .{ .text = "No AUR packages matched.", .red = false };
        }
        return null;
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

    fn statusText(self: *const Model, arena: Allocator) Allocator.Error![]const u8 {
        if (self.install_job) |job| {
            return try std.fmt.allocPrint(arena, "Installing {s}…", .{job.name});
        }
        if (self.notice.len > 0) return self.notice;
        switch (self.active) {
            .packages => {
                if (self.loading) return "Loading packages…";
                if (self.load_failed) return "Failed to load packages";
                if (self.query.len > 0) {
                    return try std.fmt.allocPrint(arena, "{d} of {d} packages match", .{
                        self.filtered.items.len, self.packages.len,
                    });
                }
                return try std.fmt.allocPrint(arena, "{d} packages", .{self.packages.len});
            },
            .aur => {
                if (self.aur_job != null) {
                    return try std.fmt.allocPrint(arena, "Searching AUR for '{s}'…", .{self.aur_query});
                }
                if (self.aur_failed) return "AUR search failed";
                if (self.aur_query.len == 0) return "AUR — type a query and press Enter";
                return try std.fmt.allocPrint(arena, "{d} AUR results for '{s}'", .{
                    self.aur_packages.len, self.aur_query,
                });
            },
            .upgrade => {
                return try std.fmt.allocPrint(arena, "Not implemented yet", .{});
            },
        }
    }

    fn drawDetailsOverlay(self: *const Model, ctx: vxfw.DrawContext, arena: Allocator, max: vxfw.Size, overlay: Overlay) Allocator.Error!?vxfw.SubSurface {
        var title: []const u8 = undefined;
        var body: []const u8 = undefined;
        switch (overlay) {
            .package => |pkg| {
                title = try std.fmt.allocPrint(arena, "{s} {s}", .{ pkg.Name, pkg.Version });
                body = try packageDetailsText(arena, pkg);
            },
            .aur => |pkg| {
                title = try std.fmt.allocPrint(arena, "{s} {s} (AUR)", .{ pkg.Name, pkg.Version });
                body = try aurDetailsText(arena, pkg);
            },
            .sudo => return null,
        }
        if (self.install_job) |job| {
            body = try std.fmt.allocPrint(arena, "{s}\n\nInstalling {s}…", .{ body, job.name });
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
        var body: []const u8 = undefined;
        switch (prompt.state) {
            .entering => {
                const count = codepointCount(prompt.password.items);
                const mask = try arena.alloc(u8, count * 3);
                var pos: usize = 0;
                for (0..count) |_| {
                    @memcpy(mask[pos .. pos + 3], "●");
                    pos += 3;
                }
                body = try std.fmt.allocPrint(arena, "Installing '{s}' requires administrator privileges.\n\nPassword: {s}\n\nEnter: run with sudo    Esc: cancel", .{ prompt.name, mask[0..pos] });
            },
            .running => {
                body = try std.fmt.allocPrint(arena, "Installing '{s}' as root…", .{prompt.name});
            },
            .succeeded => {
                body = try std.fmt.allocPrint(arena, "✔ '{s}' was installed successfully.\n\nEsc: close", .{prompt.name});
            },
            .failed => {
                body = try std.fmt.allocPrint(arena, "✘ Installing '{s}' failed.\n\n{s}\n\nEsc: close", .{ prompt.name, if (prompt.detail.len > 0) prompt.detail else "No error details were captured." });
            },
        }

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
            .drawFn = drawPackageRow,
        };
    }

    fn drawPackageRow(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const pkg: *const Package = @ptrCast(@alignCast(ptr));
        const arena = ctx.arena;

        var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
        if (pkg.Installed) {
            try spans.append(arena, .{ .text = "● ", .style = .{ .fg = .{ .index = 2 } } });
        } else {
            try spans.append(arena, .{ .text = "  " });
        }
        try spans.append(arena, .{ .text = pkg.Name, .style = .{ .bold = true } });
        try spans.append(arena, .{ .text = " " });
        try spans.append(arena, .{ .text = pkg.Version, .style = .{ .fg = .{ .index = 245 } } });
        if (pkg.Description.len > 0) {
            try spans.append(arena, .{ .text = " — " });
            try spans.append(arena, .{
                .text = pkg.Description,
                .style = .{ .fg = .{ .index = 245 } },
            });
        }

        const rich = try arena.create(vxfw.RichText);
        rich.* = .{
            .text = spans.items,
            .softwrap = false,
            .overflow = .ellipsis,
        };
        return rich.draw(ctx);
    }
    fn buildSelectedRow(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (idx >= self.selected_packages.items.len) return null;
        return .{ .userdata = @ptrCast(&self.selected_packages.items[idx]), .drawFn = drawSelectedRow };
    }

    fn drawSelectedRow(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const name_ptr: *const []const u8 = @ptrCast(@alignCast(ptr));
        const name = name_ptr.*;
        const arena = ctx.arena;
        var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
        try spans.append(arena, .{ .text = name });
        const rich = try arena.create(vxfw.RichText);
        rich.* = .{ .text = spans.items, .softwrap = false, .overflow = .ellipsis };
        return rich.draw(ctx);
    }

    fn buildAurRow(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (idx >= self.aur_packages.len) return null;
        const pkg = &self.aur_packages[idx];
        return .{
            .userdata = @constCast(pkg),
            .drawFn = drawAurRow,
        };
    }

    fn drawAurRow(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const pkg: *const AurPackage = @ptrCast(@alignCast(ptr));
        const arena = ctx.arena;

        var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
        try spans.append(arena, .{ .text = "  " });
        try spans.append(arena, .{ .text = pkg.Name, .style = .{ .bold = true } });
        try spans.append(arena, .{ .text = " " });
        try spans.append(arena, .{
            .text = pkg.Version,
            .style = .{ .fg = .{ .index = if (pkg.OutOfDate != null) @as(u8, 1) else 245 } },
        });
        try spans.append(arena, .{
            .text = try std.fmt.allocPrint(arena, " ▲ {d}", .{pkg.NumVotes}),
            .style = .{ .fg = .{ .index = 245 } },
        });
        if (pkg.Description) |description| {
            if (description.len > 0) {
                try spans.append(arena, .{ .text = " — " });
                try spans.append(arena, .{
                    .text = description,
                    .style = .{ .fg = .{ .index = 245 } },
                });
            }
        }

        const rich = try arena.create(vxfw.RichText);
        rich.* = .{
            .text = spans.items,
            .softwrap = false,
            .overflow = .ellipsis,
        };
        return rich.draw(ctx);
    }

    // -- details -----------------------------------------------------------

    fn packageDetailsText(arena: Allocator, pkg: *const Package) Allocator.Error![]const u8 {
        var lines: std.ArrayList([]const u8) = .empty;

        try lines.append(arena, if (pkg.Description.len > 0) pkg.Description else "No description.");
        try lines.append(arena, "");

        try lines.append(arena, try std.fmt.allocPrint(arena, "Repository:     {s}", .{pkg.Repository}));
        try lines.append(arena, try std.fmt.allocPrint(arena, "Version:        {s}", .{pkg.Version}));
        try lines.append(arena, try std.fmt.allocPrint(arena, "Installed:      {s}", .{if (pkg.Installed) "yes" else "no"}));
        if (pkg.Url) |url| {
            try lines.append(arena, try std.fmt.allocPrint(arena, "URL:            {s}", .{url}));
        }
        try appendDetailList(arena, &lines, "Licenses:     ", pkg.Licenses);
        try appendDetailList(arena, &lines, "Groups:       ", pkg.Groups);
        try appendDetailList(arena, &lines, "Depends:      ", pkg.Depends);
        try appendDetailList(arena, &lines, "Opt depends:  ", pkg.OptDepends);
        try appendDetailList(arena, &lines, "Provides:     ", pkg.Provides);
        try appendDetailList(arena, &lines, "Conflicts:    ", pkg.Conflicts);
        try appendDetailList(arena, &lines, "Replaces:     ", pkg.Replaces);
        try lines.append(arena, try std.fmt.allocPrint(arena, "Download size:  {s}", .{try formatSize(arena, pkg.DownloadSize)}));
        try lines.append(arena, try std.fmt.allocPrint(arena, "Installed size: {s}", .{try formatSize(arena, pkg.InstalledSize)}));
        if (pkg.BuildDate.len > 0) {
            try lines.append(arena, try std.fmt.allocPrint(arena, "Build date:     {s}", .{pkg.BuildDate}));
        }

        return try std.mem.join(arena, "\n", lines.items);
    }

    fn aurDetailsText(arena: Allocator, pkg: *const AurPackage) Allocator.Error![]const u8 {
        var lines: std.ArrayList([]const u8) = .empty;

        try lines.append(arena, pkg.Description orelse "No description.");
        try lines.append(arena, "");

        try lines.append(arena, try std.fmt.allocPrint(arena, "Version:         {s}", .{pkg.Version}));
        try lines.append(arena, try std.fmt.allocPrint(arena, "Package base:    {s}", .{pkg.PackageBase}));
        try lines.append(arena, try std.fmt.allocPrint(arena, "Votes:           {d}", .{pkg.NumVotes}));
        try lines.append(arena, try std.fmt.allocPrint(arena, "Popularity:      {d:.2}", .{pkg.Popularity}));
        try lines.append(arena, try std.fmt.allocPrint(arena, "Maintainer:      {s}", .{pkg.Maintainer orelse "—"}));
        try lines.append(arena, try std.fmt.allocPrint(arena, "Out of date:     {s}", .{if (pkg.OutOfDate != null) "yes" else "no"}));
        if (pkg.Url) |url| {
            try lines.append(arena, try std.fmt.allocPrint(arena, "URL:             {s}", .{url}));
        }
        if (pkg.License) |licenses| try appendDetailList(arena, &lines, "Licenses:      ", licenses);
        if (pkg.Depends) |depends| try appendDetailList(arena, &lines, "Depends:       ", depends);
        if (pkg.MakeDepends) |make_depends| try appendDetailList(arena, &lines, "Make deps:     ", make_depends);
        try lines.append(arena, try std.fmt.allocPrint(arena, "First submitted: {s}", .{try formatEpoch(arena, pkg.FirstSubmitted)}));
        try lines.append(arena, try std.fmt.allocPrint(arena, "Last modified:   {s}", .{try formatEpoch(arena, pkg.LastModified)}));

        return try std.mem.join(arena, "\n", lines.items);
    }

    fn appendDetailList(arena: Allocator, lines: *std.ArrayList([]const u8), comptime label: []const u8, items: []const []const u8) Allocator.Error!void {
        if (items.len == 0) return;
        try lines.append(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{
            label, try std.mem.join(arena, ", ", items),
        }));
    }

    fn formatSize(arena: Allocator, bytes: i64) Allocator.Error![]const u8 {
        if (bytes <= 0) return "—";
        const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
        var value: f64 = @floatFromInt(bytes);
        var unit: usize = 0;
        while (value >= 1024.0 and unit < units.len - 1) {
            value /= 1024.0;
            unit += 1;
        }
        if (unit == 0) return try std.fmt.allocPrint(arena, "{d} B", .{bytes});
        return try std.fmt.allocPrint(arena, "{d:.1} {s}", .{ value, units[unit] });
    }

    fn formatEpoch(arena: Allocator, seconds: i64) Allocator.Error![]const u8 {
        if (seconds <= 0) return "—";
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        return try std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2}", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
        });
    }
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
