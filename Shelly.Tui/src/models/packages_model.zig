//! Native package browsing, selection, loading, and page widgets.
const operation_model = @import("operation_model.zig");
const std = @import("std");
const commands = @import("../commands.zig");
const packages_view = @import("../views/packages_view.zig");
const shelly_operation = @import("../services/shelly_operation.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const shelly_cli = @import("../services/shelly_cli.zig");
const ShellyCli = shelly_cli.ShellyCli;
const Package = @import("packages.zig").Package;

const Allocator = std.mem.Allocator;

const coordinator = @import("../model.zig");
const Model = coordinator.Model;

/// Page-owned state. Worker results are published to the UI loop before use.
pub const State = struct {
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
    installed_only: bool = false,

    selected_list_view: vxfw.ListView,
    package_details_scroll: vxfw.ScrollView,
    package_details_cursor: ?u32 = null,
    package_list_active: bool = false,
    list_view: vxfw.ListView,
    text_field: vxfw.TextField,
};

/// Shared state between the UI and the background package loader. The
/// loader writes exactly once; `done` is published with release semantics
/// after the result fields are written, so the UI can read them with an
/// acquire load and no lock.
pub const LoadState = struct {
    result: ?std.json.Parsed([]Package) = null,
    failed: bool = false,
    done: std.atomic.Value(bool) = .init(false),
};

pub fn init(gpa: Allocator, model: *Model) !State {
    const load = try gpa.create(LoadState);
    load.* = .{};
    return .{
        .package_details_scroll = .{ .item_count = 1, .children = .{ .builder = .{
            .userdata = model,
            .buildFn = buildPackageDetails,
        } } },
        .load = load,
        .filtered = .empty,
        .selected_packages = .empty,
        .list_view = .{
            .children = .{ .builder = .{
                .userdata = model,
                .buildFn = buildRow,
            } },
        },
        .text_field = .{
            .buf = .init(gpa),
            .userdata = model,
            .onChange = onQueryChange,
        },
        .selected_list_view = .{
            .children = .{ .builder = .{
                .userdata = model,
                .buildFn = buildSelectedRow,
            } },
        },
    };
}

pub fn deinit(self: *Model) void {
    const gpa = self.gpa;

    if (self.packages_state.load_thread) |thread| {
        thread.join();
        self.packages_state.load_thread = null;
    }
    if (self.packages_state.load.result) |*result| result.deinit();
    gpa.destroy(self.packages_state.load);
    self.packages_state.text_field.deinit();
    self.packages_state.filtered.deinit(gpa);
    self.packages_state.selected_packages.deinit(gpa);
    if (self.packages_state.query.len > 0) gpa.free(self.packages_state.query);
    if (self.packages_state.parsed) |*parsed| parsed.deinit();
}

pub fn reloadPackages(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.packages_state.load_thread) |thread| thread.join();
    self.packages_state.load_thread = null;
    self.packages_state.load.* = .{};
    try startLoad(self, ctx);
    self.packages_state.loading = true;
    self.packages_state.load_failed = false;
}

pub fn startLoad(self: *Model, ctx: *vxfw.EventContext) !void {
    self.packages_state.load_thread = try std.Thread.spawn(.{}, loadPackages, .{self.packages_state.load});
    try ctx.tick(100, self.widget());
}

pub fn loadPackages(load: *LoadState) void {
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

pub fn pollLoad(self: *Model) !bool {
    if (!self.packages_state.loading) return false;
    if (!self.packages_state.load.done.load(.acquire)) return true;

    const failed = self.packages_state.load.failed;
    const parsed = self.packages_state.load.result;
    self.packages_state.load.result = null;
    self.packages_state.loading = false;
    self.packages_state.load_failed = failed;
    if (parsed) |p| {
        var old = self.packages_state.parsed;
        defer if (old) |*owner| owner.deinit();
        const selected = if (self.packages_state.list_view.cursor < self.packages_state.filtered.items.len)
            self.packages_state.filtered.items[self.packages_state.list_view.cursor]
        else
            null;
        if (self.overlay) |overlay| {
            if (overlay == .package) self.overlay = null;
        }
        var previous_selection = self.packages_state.selected_packages;
        defer previous_selection.deinit(self.gpa);
        self.packages_state.selected_packages = .empty;
        self.packages_state.parsed = p;
        self.packages_state.packages = p.value;
        for (previous_selection.items) |name| {
            for (self.packages_state.packages) |pkg| {
                if (std.mem.eql(u8, pkg.Name, name)) {
                    try self.packages_state.selected_packages.append(self.gpa, pkg.Name);
                    break;
                }
            }
        }
        self.packages_state.selected_list_view.item_count = @intCast(self.packages_state.selected_packages.items.len);
        try rebuildFilter(self);
        if (selected) |previous| {
            for (self.packages_state.filtered.items, 0..) |pkg, index| {
                if (std.mem.eql(u8, pkg.Name, previous.Name) and
                    std.mem.eql(u8, pkg.Repository, previous.Repository))
                {
                    self.packages_state.list_view.jumpToItem(@intCast(index));
                    break;
                }
            }
        }
    } else {
        try rebuildFilter(self);
    }
    return false;
}

pub fn packageMarked(self: *const Model, name: []const u8) bool {
    for (self.packages_state.selected_packages.items) |selected| {
        if (std.mem.eql(u8, name, selected)) return true;
    }
    return false;
}

pub fn openNativePrompt(self: *Model, action: shelly_operation.Action) !void {
    if (self.operation_state.install_job != null or self.packages_state.loading or self.packages_state.load_failed) return;
    return operation_model.openPackageBatchPrompt(self, action, .standard, self.packages_state.packages, false);
}

pub fn toggleSelectedList(self: *Model) !void {
    try self.setNotice("");
    const package_name = self.packages_state.filtered.items[self.packages_state.list_view.cursor].Name;
    for (self.packages_state.selected_packages.items, 0..) |*item, index| {
        if (std.mem.eql(u8, item.*, package_name)) {
            _ = self.packages_state.selected_packages.orderedRemove(index);
            return;
        }
    }
    try self.packages_state.selected_packages.append(self.gpa, package_name);
}

pub fn onQueryChange(maybe_ptr: ?*anyopaque, _: *vxfw.EventContext, str: []const u8) anyerror!void {
    const ptr = maybe_ptr orelse return;
    const self: *Model = @ptrCast(@alignCast(ptr));
    try setQuery(self, str);
}

pub fn setQuery(self: *Model, str: []const u8) Allocator.Error!void {
    const duped = if (str.len > 0) try self.gpa.dupe(u8, str) else "";
    if (self.packages_state.query.len > 0) self.gpa.free(self.packages_state.query);
    self.packages_state.query = duped;
    try rebuildFilter(self);
}

pub fn rebuildFilter(self: *Model) Allocator.Error!void {
    self.packages_state.package_details_scroll.scroll = .{};
    self.packages_state.filtered.clearRetainingCapacity();
    for (self.packages_state.packages) |*pkg| {
        if (self.packages_state.installed_only and !pkg.Installed) continue;
        if (self.packages_state.query.len == 0 or
            Model.containsFold(pkg.Name, self.packages_state.query) or
            Model.containsFold(pkg.Description, self.packages_state.query))
        {
            try self.packages_state.filtered.append(self.gpa, pkg);
        }
    }
    self.packages_state.list_view.item_count = @intCast(self.packages_state.filtered.items.len);
    self.packages_state.list_view.jumpToItem(0);
}

pub fn packagesView(self: *Model) packages_view.View {
    if (self.packages_state.package_details_cursor == null or self.packages_state.package_details_cursor.? != self.packages_state.list_view.cursor) {
        self.packages_state.package_details_scroll.scroll = .{};
        self.packages_state.package_details_cursor = self.packages_state.list_view.cursor;
    }
    var selected_installed: usize = 0;
    for (self.packages_state.selected_packages.items) |name| {
        for (self.packages_state.packages) |pkg| {
            if (std.mem.eql(u8, pkg.Name, name)) {
                if (pkg.Installed) selected_installed += 1;
                break;
            }
        }
    }
    return .{
        .list_percent = self.list_percent,
        .text_field = &self.packages_state.text_field,
        .list_view = &self.packages_state.list_view,
        .details_scroll = &self.packages_state.package_details_scroll,
        .help = if (self.help_open) &self.help_panel else null,
        .selected = selectedPackage(self),
        .details_active = !self.help_open and (if (self.overlay) |overlay| overlay == .package else false),
        .list_active = self.packages_state.package_list_active and !self.help_open,
        .selected_count = self.packages_state.selected_packages.items.len,
        .selected_installed = selected_installed,
        .loading = self.packages_state.loading,
        .load_failed = self.packages_state.load_failed,
        .query = self.packages_state.query,
        .filtered_count = self.packages_state.filtered.items.len,
        .package_count = self.packages_state.packages.len,
        .installed_only = self.packages_state.installed_only,
    };
}

pub fn selectedPackage(self: *const Model) ?*const Package {
    if (self.packages_state.list_view.cursor >= self.packages_state.filtered.items.len) return null;
    return self.packages_state.filtered.items[self.packages_state.list_view.cursor];
}

pub fn buildPackageDetails(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
    if (idx != 0) return null;
    const self: *const Model = @ptrCast(@alignCast(ptr));
    const pkg = selectedPackage(self) orelse return null;
    return .{ .userdata = @constCast(pkg), .drawFn = packages_view.drawDetails };
}

pub fn buildRow(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
    const self: *const Model = @ptrCast(@alignCast(ptr));
    if (idx >= self.packages_state.filtered.items.len) return null;
    const pkg = self.packages_state.filtered.items[idx];
    return .{
        .userdata = @constCast(pkg),
        .drawFn = if (packageMarked(self, pkg.Name)) packages_view.drawMarkedPackageRow else packages_view.drawPackageRow,
    };
}

pub fn buildSelectedRow(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
    const self: *const Model = @ptrCast(@alignCast(ptr));
    if (idx >= self.packages_state.selected_packages.items.len) return null;
    return .{ .userdata = @ptrCast(&self.packages_state.selected_packages.items[idx]), .drawFn = packages_view.drawSelectedRow };
}

/// Returns whether page input was consumed. Globals remain with the coordinator.
pub fn handleKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key, global_command: bool) anyerror!bool {
    if (!global_command) {
        if (self.packages_state.package_list_active) {
            if (commands.matches(key, .clear_selection)) {
                self.packages_state.selected_packages.clearRetainingCapacity();
                self.packages_state.selected_list_view.item_count = 0;
                try self.setNotice("");
                ctx.consumeAndRedraw();
                return true;
            }
            if (commands.packageAction(key)) |action| {
                try openNativePrompt(self, if (action == .install) .install else .remove);
                ctx.consumeAndRedraw();
                return true;
            }
        }
        if (commands.packageNavigation(key, !self.packages_state.package_list_active)) |action| {
            switch (action) {
                .previous, .next => {
                    if (action == .previous and self.packages_state.package_list_active and self.packages_state.list_view.cursor == 0) {
                        self.packages_state.package_list_active = false;
                    } else {
                        self.packages_state.package_list_active = true;
                        try self.packages_state.list_view.handleEvent(ctx, .{ .key_press = .{ .codepoint = if (action == .previous) vaxis.Key.up else vaxis.Key.down } });
                    }
                },
                .details => if (selectedPackage(self)) |pkg| {
                    self.overlay = .{ .package = pkg };
                },
                .search => self.packages_state.package_list_active = false,
                .select => {
                    self.packages_state.package_list_active = true;
                    if (selectedPackage(self) != null) try toggleSelectedList(self);
                },
            }
            ctx.consumeAndRedraw();
            return true;
        }
    }
    if (commands.togglesInstalled(key)) {
        self.packages_state.installed_only = !self.packages_state.installed_only;
        try rebuildFilter(self);
        ctx.consumeAndRedraw();
        return true;
    }
    if (self.packages_state.package_list_active and commands.matches(key, .mark)) {
        if (self.packages_state.list_view.cursor < self.packages_state.filtered.items.len) try toggleSelectedList(self);
        ctx.consumeAndRedraw();
        return true;
    }
    if (self.packages_state.package_list_active and !global_command) {
        ctx.consumeEvent();
        return true;
    }
    return false;
}

/// Returns whether page input was consumed; globals remain with the coordinator.
pub fn handleDetailsKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key, global_command: bool) anyerror!bool {
    if (commands.leavesPackageDetails(key)) {
        operation_model.closeOverlay(self);
        self.packages_state.package_list_active = true;
        ctx.consumeAndRedraw();
        return true;
    }
    if (commands.detail(key)) |action| {
        switch (action) {
            .close => operation_model.closeOverlay(self),
            .install => try operation_model.operationFromOverlay(self, .install),
            .remove => try operation_model.operationFromOverlay(self, .remove),
            .preview => {},
        }
        ctx.consumeAndRedraw();
        return true;
    }
    if (global_command) return false;
    try self.packages_state.package_details_scroll.handleEvent(ctx, .{ .key_press = commands.scrollKey(key) orelse key });
    ctx.consumeAndRedraw();
    return true;
}

pub fn handleUnhandledKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) anyerror!void {
    if (commands.matches(key, .select) and self.packages_state.filtered.items.len > 0 and self.packages_state.list_view.cursor < self.packages_state.filtered.items.len) {
        self.packages_state.package_list_active = true;
        try toggleSelectedList(self);
        return ctx.consumeAndRedraw();
    }
    const previous = self.packages_state.list_view.cursor;
    try self.packages_state.list_view.handleEvent(ctx, .{ .key_press = key });
    if (previous != self.packages_state.list_view.cursor) self.packages_state.package_details_scroll.scroll = .{};
}

test "package refresh replaces borrowed data and preserves selection" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.packages_state.parsed = try std.json.parseFromSlice([]Package, std.testing.allocator,
        \\[{"Name":"native","Repository":"repo","Version":"1","Installed":true}]
    , .{ .allocate = .alloc_always });
    model.packages_state.packages = model.packages_state.parsed.?.value;
    try rebuildFilter(model);
    try model.packages_state.selected_packages.append(std.testing.allocator, model.packages_state.packages[0].Name);
    model.packages_state.load.result = try std.json.parseFromSlice([]Package, std.testing.allocator,
        \\[{"Name":"native","Repository":"repo","Version":"2","Installed":true}]
    , .{ .allocate = .alloc_always });
    model.packages_state.load.done.store(true, .release);
    model.packages_state.loading = true;
    _ = try pollLoad(model);
    try std.testing.expectEqualStrings("2", model.packages_state.packages[0].Version);
    try std.testing.expectEqualStrings("native", model.packages_state.selected_packages.items[0]);
    try std.testing.expect(model.packages_state.selected_packages.items[0].ptr == model.packages_state.packages[0].Name.ptr);
    try std.testing.expectEqual(@as(u32, 0), model.packages_state.list_view.cursor);
}

test "installed package filters combine local text and installed state" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{
        .{ .Name = "editor", .Installed = true },
        .{ .Name = "editor-extra", .Installed = false },
        .{ .Name = "shell", .Installed = true },
    };
    model.packages_state.packages = &packages;
    model.packages_state.installed_only = true;
    try setQuery(model, "editor");
    try std.testing.expectEqual(@as(usize, 1), model.packages_state.filtered.items.len);
    try std.testing.expectEqualStrings("editor", model.packages_state.filtered.items[0].Name);
    model.packages_state.installed_only = false;
    try rebuildFilter(model);
    try std.testing.expectEqual(@as(usize, 2), model.packages_state.filtered.items.len);
}

test "packages split details follow selection and remain within the page on resize" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{
        .{ .Name = "first", .Description = "First package", .Repository = "core" },
        .{ .Name = "second", .Description = "Second package", .Repository = "extra", .Installed = true },
    };
    model.packages_state.packages = &packages;
    try rebuildFilter(model);
    model.packages_state.loading = false;
    try std.testing.expectEqualStrings("first", packagesView(model).selected.?.Name);
    model.packages_state.list_view.cursor = 1;
    try std.testing.expectEqualStrings("second", packagesView(model).selected.?.Name);

    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    model.packages_state.package_list_active = true;
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.right } });
    try std.testing.expect(packagesView(model).details_active);
    for ([_]vxfw.Size{ .{ .width = 120, .height = 30 }, .{ .width = 80, .height = 24 }, .{ .width = 40, .height = 12 }, .{ .width = 1, .height = 4 } }) |size| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const ctx: vxfw.DrawContext = .{
            .arena = arena.allocator(),
            .min = .{},
            .max = .{ .width = size.width, .height = size.height },
            .cell_size = .{ .width = 10, .height = 20 },
        };
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        try packagesView(model).appendContent(ctx, &children);
        var details_on_right = false;
        var list_on_left = false;
        for (children.items) |child| {
            try std.testing.expect(child.origin.col >= 0 and child.origin.row >= 0);
            try std.testing.expect(@as(usize, @intCast(child.origin.col)) + child.surface.size.width <= size.width);
            try std.testing.expect(@as(usize, @intCast(child.origin.row)) + child.surface.size.height <= size.height - 1);
            if (child.origin.col > 0) {
                details_on_right = true;
                try std.testing.expectEqual(@as(i17, 1), child.origin.row);
                try std.testing.expectEqual(size.height - 2, child.surface.size.height);
            }
            const content_row: i17 = if (size.width >= 2 and size.height >= 8) 4 else 2;
            if (child.origin.row == content_row) {
                if (child.surface.widget.eql(model.packages_state.list_view.widget())) list_on_left = true;
                for (child.surface.children) |nested| {
                    if (nested.surface.widget.eql(model.packages_state.list_view.widget())) list_on_left = true;
                }
            }
        }
        try std.testing.expectEqual(size.width >= 64, details_on_right);
        try std.testing.expectEqual(size.width >= 64, list_on_left);
    }
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = 'q' } });
    try std.testing.expect(model.overlay == null);
    try std.testing.expectEqual(@as(u32, 1), model.packages_state.list_view.cursor);
    try setQuery(model, "no matches");
    try std.testing.expect(packagesView(model).selected == null);
}

test "packages details scroll and retain the selected install and removal target" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{.{ .Name = "installed", .Installed = true }};
    model.packages_state.packages = &packages;
    try rebuildFilter(model);
    model.packages_state.loading = false;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 12 }, .cell_size = .{ .width = 10, .height = 20 } });
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    model.packages_state.package_list_active = true;
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.right } });
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expect(model.packages_state.package_details_scroll.scroll.pending_lines > 0);
    try std.testing.expectEqual(@as(u32, 0), model.packages_state.list_view.cursor);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = 'r' } });
    try std.testing.expect(model.overlay.? == .sudo);
    try std.testing.expectEqualStrings("installed", model.overlay.?.sudo.name);
    try std.testing.expectEqual(shelly_operation.Action.remove, model.overlay.?.sudo.action);
}

test "package pane arrows preserve search editing and navigate list and details" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{ .{ .Name = "first" }, .{ .Name = "second" } };
    model.packages_state.packages = &packages;
    try rebuildFilter(model);
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    const left: vaxis.Key = .{ .codepoint = vaxis.Key.left };
    const right: vaxis.Key = .{ .codepoint = vaxis.Key.right };
    try std.testing.expect(commands.packageNavigation(left, true) == null);
    try std.testing.expect(commands.packageNavigation(right, true) == null);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = right });
    try std.testing.expect(model.overlay == null);
    try std.testing.expect(!model.packages_state.package_list_active);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expect(model.packages_state.package_list_active);
    const selected = model.packages_state.list_view.cursor;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = right });
    try std.testing.expect(packagesView(model).details_active);
    try std.testing.expectEqualStrings(model.packages_state.filtered.items[selected].Name, model.overlay.?.package.Name);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = left });
    try std.testing.expect(model.overlay == null);
    try std.testing.expect(model.packages_state.package_list_active);
    try std.testing.expectEqual(selected, model.packages_state.list_view.cursor);
    model.packages_state.package_list_active = true;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = 'a', .text = "a" } });
    try std.testing.expect(model.packages_state.package_list_active);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = '/', .text = "/" } });
    try std.testing.expect(!model.packages_state.package_list_active);
    try std.testing.expectEqual(selected, model.packages_state.list_view.cursor);
    model.packages_state.package_list_active = true;
    model.packages_state.list_view.cursor = 0;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    try std.testing.expect(!model.packages_state.package_list_active);
    try std.testing.expectEqual(@as(u32, 0), model.packages_state.list_view.cursor);
}

test "package list actions open prompts while search letters stay editable" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{ .{ .Name = "available" }, .{ .Name = "installed", .Installed = true } };
    model.packages_state.packages = &packages;
    try rebuildFilter(model);
    model.packages_state.loading = false;
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    for ([_]u21{ 'i', 'r' }) |letter| {
        try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = letter, .text = if (letter == 'i') "i" else "r" } });
        try std.testing.expect(model.overlay == null);
    }
    model.packages_state.package_list_active = true;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = 'r' } });
    try std.testing.expect(model.overlay == null);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = 'i' } });
    try std.testing.expectEqualStrings("available", model.overlay.?.sudo.name);
    try std.testing.expectEqual(shelly_operation.Action.install, model.overlay.?.sudo.action);
    try std.testing.expect(model.operation_state.install_job == null);
    operation_model.closeOverlay(model);
    model.packages_state.list_view.cursor = 1;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = 'r' } });
    try std.testing.expectEqualStrings("installed", model.overlay.?.sudo.name);
    try std.testing.expectEqual(shelly_operation.Action.remove, model.overlay.?.sudo.action);
    try std.testing.expect(model.operation_state.install_job == null);
}

test "native batch selection survives filtering and confirms mixed targets" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{
        .{ .Name = "available" },                            .{ .Name = "installed", .Installed = true },
        .{ .Name = "another-installed", .Installed = true },
    };
    model.packages_state.packages = &packages;
    model.packages_state.loading = false;
    try rebuildFilter(model);
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    const enter: vxfw.Event = .{ .key_press = .{ .codepoint = vaxis.Key.enter } };
    try Model.typeErasedCaptureHandler(model, &ctx, enter);
    try std.testing.expect(model.overlay == null);
    try std.testing.expect(packageMarked(model, "available"));
    model.packages_state.list_view.cursor = 1;
    try Model.typeErasedCaptureHandler(model, &ctx, enter);
    try std.testing.expectEqual(@as(usize, 2), model.packages_state.selected_packages.items.len);
    try setQuery(model, "another");
    try std.testing.expectEqual(@as(usize, 1), model.packages_state.filtered.items.len);
    try std.testing.expectEqual(@as(usize, 2), model.packages_state.selected_packages.items.len);
    try std.testing.expectEqual(@as(usize, 1), packagesView(model).selected_installed);
    try openNativePrompt(model, .install);
    var prompt = model.overlay.?.sudo;
    try std.testing.expectEqualStrings("available", prompt.targets[0]);
    try std.testing.expectEqualStrings("installed", prompt.targets[1]);
    try std.testing.expect(std.mem.indexOf(u8, prompt.review_text, "Install (1): available") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.review_text, "Reinstall (1): installed") != null);
    // Confirmation owns its targets, independently of the source records.
    packages[0].Name = "changed-source-name";
    try std.testing.expectEqualStrings("available", prompt.targets[0]);
    packages[0].Name = "available";
    operation_model.closeOverlay(model);
    try std.testing.expectEqual(@as(usize, 0), model.packages_state.selected_packages.items.len);
    try model.packages_state.selected_packages.appendSlice(std.testing.allocator, &.{ "available", "installed" });
    try openNativePrompt(model, .remove);
    prompt = model.overlay.?.sudo;
    try std.testing.expectEqual(@as(usize, 1), prompt.targets.len);
    try std.testing.expectEqualStrings("installed", prompt.targets[0]);
    try std.testing.expect(std.mem.indexOf(u8, prompt.review_text, "1 uninstalled selections excluded.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.review_text, "Remove (1): installed") != null);
    operation_model.closeOverlay(model);
    try std.testing.expectEqual(@as(usize, 0), model.packages_state.selected_packages.items.len);
    try model.packages_state.selected_packages.append(std.testing.allocator, "available");
    try std.testing.expectEqual(@as(usize, 1), model.packages_state.selected_packages.items.len);
    try std.testing.expect(packageMarked(model, "available"));
    try openNativePrompt(model, .remove);
    try std.testing.expect(model.overlay == null);
    try std.testing.expect(std.mem.indexOf(u8, model.notice, "No installed packages") != null);
}

test "native batch confirmation scrolls long reviews and keeps password entry visible" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages: [60]Package = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (&packages, 0..) |*pkg, i| pkg.* = .{ .Name = try std.fmt.allocPrint(arena.allocator(), "package-{d}", .{i}) };
    model.packages_state.packages = &packages;
    model.packages_state.loading = false;
    try rebuildFilter(model);
    for (packages) |pkg| try model.packages_state.selected_packages.append(std.testing.allocator, pkg.Name);
    try openNativePrompt(model, .install);
    const prompt = model.overlay.?.sudo;
    const drawn = try model.widget().draw(.{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 24 },
        .cell_size = .{ .width = 10, .height = 20 },
    });
    try std.testing.expectEqual(@as(u16, 24), drawn.size.height);
    try std.testing.expect(prompt.panel.scroll.scroll.has_more_vertical);
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expect(prompt.panel.scroll.scroll.pending_lines > 0);
    try std.testing.expectEqual(@as(usize, 0), prompt.password.items.len);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = 'q', .mods = .{ .ctrl = true } } });
    try std.testing.expect(model.overlay == null);
    try std.testing.expectEqual(@as(usize, 0), model.packages_state.selected_packages.items.len);
}

test "native removal refreshes actual state and clears all successful selections" {
    for ([_]bool{ false, true }) |failed| {
        const model = try Model.init(std.testing.allocator);
        defer model.deinit();
        var packages = [_]Package{ .{ .Name = "available" }, .{ .Name = "installed", .Installed = true } };
        model.packages_state.packages = &packages;
        try model.packages_state.selected_packages.appendSlice(std.testing.allocator, &.{ "available", "installed" });
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        const job = try std.heap.page_allocator.create(shelly_operation.Operation);
        job.* = .{
            .arena = .init(std.heap.page_allocator),
            .done = .init(true),
            .result = .{ .failed = failed },
            .request = .{ .shelly_bin = "unused", .environ_map = &env, .backend = "standard", .action = .remove, .name = "installed", .targets = &.{"installed"}, .password = "" },
        };
        model.operation_state.install_job = job;
        try std.testing.expect(!try operation_model.pollInstall(model));
        try std.testing.expect(model.updates_state.refresh_after_upgrade);
        try std.testing.expect(model.updates_state.refresh_updates_after_operation);
        try std.testing.expect(packages[1].Installed); // No optimistic batch result.
        try std.testing.expectEqual(failed, packageMarked(model, "available"));
        try std.testing.expectEqual(failed, packageMarked(model, "installed"));
    }
}

test "clear selection includes filtered packages and preserves search and cursor" {
    const original = commands.bindings;
    defer commands.bindings = original;
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{ .{ .Name = "visible" }, .{ .Name = "hidden", .Installed = true } };
    model.packages_state.packages = &packages;
    model.packages_state.loading = false;
    try rebuildFilter(model);
    try model.packages_state.selected_packages.appendSlice(std.testing.allocator, &.{ "visible", "hidden" });
    try setQuery(model, "visible");
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    const clear: vxfw.Event = .{ .key_press = .{ .codepoint = 'u', .mods = .{ .ctrl = true } } };
    // The search field retains Ctrl+U for editing its text.
    try Model.typeErasedCaptureHandler(model, &ctx, clear);
    try std.testing.expectEqual(@as(usize, 2), model.packages_state.selected_packages.items.len);
    model.packages_state.package_list_active = true;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const help = try commands.entries(arena.allocator(), model.commandContext());
    var advertised = false;
    for (help) |entry| if (entry.id == .clear_selection) {
        advertised = true;
    };
    try std.testing.expect(advertised);
    const cursor = model.packages_state.list_view.cursor;
    try Model.typeErasedCaptureHandler(model, &ctx, clear);
    try std.testing.expectEqual(@as(usize, 0), model.packages_state.selected_packages.items.len);
    try std.testing.expectEqualStrings("visible", model.packages_state.query);
    try std.testing.expectEqual(cursor, model.packages_state.list_view.cursor);
    try std.testing.expect(model.packages_state.package_list_active);
    for (try commands.entries(arena.allocator(), model.commandContext())) |entry|
        try std.testing.expect(entry.id != .clear_selection);
    try model.packages_state.selected_packages.append(std.testing.allocator, "hidden");
    commands.bindings.clear_selection = .{ .codepoint = 'k', .mods = .{ .ctrl = true } };
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = 'k', .mods = .{ .ctrl = true } } });
    try std.testing.expectEqual(@as(usize, 0), model.packages_state.selected_packages.items.len);
}

test "packages input preserves search editing and delegates global navigation" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    model.packages_state.package_list_active = false;
    try std.testing.expect(!try handleKey(model, &ctx, .{ .codepoint = 'x' }, false));
    try std.testing.expect(!ctx.consume_event);
    model.packages_state.package_list_active = true;
    try std.testing.expect(try handleKey(model, &ctx, .{ .codepoint = 'x' }, false));
    try std.testing.expect(ctx.consume_event);
    // A reused event context must not make the handler report a global key handled.
    try std.testing.expect(!try handleKey(model, &ctx, commands.bindings.next_tab, true));
    try std.testing.expect(model.packages_state.package_list_active);
}
