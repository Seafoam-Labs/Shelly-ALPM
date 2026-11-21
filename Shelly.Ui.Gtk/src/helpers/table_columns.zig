//! package table column menu and saved column layout.
const std = @import("std");
const diagnostics = @import("diagnostics");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const glib = bindings.glib;
const gobject = bindings.gobject;
const runtime = @import("../services/runtime.zig");
const TableColumn = @import("../models/shelly_config.zig").TableColumn;
const translations = @import("translations.zig");

pub const Column = struct {
    /// stable name saved in the settings file.
    key: [:0]const u8,
    column: *gtk.ColumnViewColumn,
    /// false keeps the column out of the menu.
    hideable: bool = true,
    resizable: bool = true,
};

/// save once a column drag settles.
const save_delay_ms = 400;
const action_prefix = "show-";

/// a signal connection that `State` owns, holding a reference to its object
/// so it can be disconnected when the state is freed.
const Handler = struct {
    object: *gobject.Object,
    id: c_ulong,
};

const State = struct {
    table: [:0]const u8,
    columns: []Column,
    actions: []?*gio.SimpleAction,
    handlers: []Handler,
    handler_count: usize = 0,
    save_source: c_uint = 0,
};

/// restores the saved layout for `table` and wires the menu and saving.
pub fn attach(view: *gtk.ColumnView, table: [:0]const u8, columns: []const Column) void {
    const allocator = std.heap.c_allocator;
    const state = allocator.create(State) catch return;
    state.* = .{
        .table = table,
        .columns = allocator.dupe(Column, columns) catch {
            allocator.destroy(state);
            return;
        },
        .actions = allocator.alloc(?*gio.SimpleAction, columns.len) catch {
            allocator.free(state.columns);
            allocator.destroy(state);
            return;
        },
        // one notify handler per column, one toggle per hideable column, and reset.
        .handlers = allocator.alloc(Handler, columns.len * 2 + 1) catch {
            allocator.free(state.actions);
            allocator.free(state.columns);
            allocator.destroy(state);
            return;
        },
    };
    @memset(state.actions, null);
    gobject.Object.setDataFull(view.as(gobject.Object), "shelly-table-columns", state, &destroyState);

    restore(state);

    const group = gio.SimpleActionGroup.new();
    defer group.as(gobject.Object).unref();
    const toggles = gio.Menu.new();
    defer toggles.as(gobject.Object).unref();

    for (state.columns, 0..) |c, i| {
        gtk.ColumnViewColumn.setResizable(c.column, @intFromBool(c.resizable));
        track(state, c.column.as(gobject.Object), gobject.Object.signals.notify.connect(c.column.as(gobject.Object), *State, &onLayoutChanged, state, .{ .detail = "fixed-width" }));
        if (!c.hideable) continue;

        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrintSentinel(&name_buf, action_prefix ++ "{s}", .{c.key}, 0) catch continue;
        var detailed_buf: [80]u8 = undefined;
        const detailed = std.fmt.bufPrintSentinel(&detailed_buf, "columns.{s}", .{name}, 0) catch continue;

        const visible = gtk.ColumnViewColumn.getVisible(c.column) != 0;
        const action = gio.SimpleAction.newStateful(name, null, glib.Variant.newBoolean(@intFromBool(visible)));
        track(state, action.as(gobject.Object), gio.SimpleAction.signals.change_state.connect(action, *State, &onToggle, state, .{}));
        gio.ActionMap.addAction(group.as(gio.ActionMap), action.as(gio.Action));
        state.actions[i] = action;
        action.as(gobject.Object).unref();

        gio.Menu.append(toggles, gtk.ColumnViewColumn.getTitle(c.column), detailed);
    }

    const reset = gio.SimpleAction.new("reset", null);
    track(state, reset.as(gobject.Object), gio.SimpleAction.signals.activate.connect(reset, *State, &onReset, state, .{}));
    gio.ActionMap.addAction(group.as(gio.ActionMap), reset.as(gio.Action));
    reset.as(gobject.Object).unref();

    const reset_section = gio.Menu.new();
    defer reset_section.as(gobject.Object).unref();
    gio.Menu.append(reset_section, translations._("Reset Columns"), "columns.reset");

    const menu = gio.Menu.new();
    defer menu.as(gobject.Object).unref();
    gio.Menu.appendSection(menu, null, toggles.as(gio.MenuModel));
    gio.Menu.appendSection(menu, null, reset_section.as(gio.MenuModel));

    gtk.Widget.insertActionGroup(view.as(gtk.Widget), "columns", group.as(gio.ActionGroup));
    for (state.columns) |c| {
        gtk.ColumnViewColumn.setHeaderMenu(c.column, menu.as(gio.MenuModel));
    }
}

fn track(state: *State, object: *gobject.Object, id: c_ulong) void {
    _ = object.ref();
    state.handlers[state.handler_count] = .{ .object = object, .id = id };
    state.handler_count += 1;
}

fn restore(state: *State) void {
    const svc = runtime.config orelse return;
    const cfg = svc.get() catch return;
    for (cfg.TableColumns) |entry| {
        if (!std.mem.eql(u8, entry.Table, state.table)) continue;
        for (state.columns) |c| {
            if (!std.mem.eql(u8, entry.Column, c.key)) continue;
            if (c.resizable and entry.Width > 0) gtk.ColumnViewColumn.setFixedWidth(c.column, entry.Width);
            if (c.hideable and entry.Hidden) gtk.ColumnViewColumn.setVisible(c.column, 0);
        }
    }
}

fn onToggle(action: *gio.SimpleAction, value: ?*glib.Variant, state: *State) callconv(.c) void {
    const v = value orelse return;
    const name = std.mem.span(gio.Action.getName(action.as(gio.Action)));
    if (!std.mem.startsWith(u8, name, action_prefix)) return;
    for (state.columns) |c| {
        if (!std.mem.eql(u8, name[action_prefix.len..], c.key)) continue;
        gio.SimpleAction.setState(action, v);
        gtk.ColumnViewColumn.setVisible(c.column, glib.Variant.getBoolean(v));
        scheduleSave(state);
        return;
    }
}

fn onReset(_: *gio.SimpleAction, _: ?*glib.Variant, state: *State) callconv(.c) void {
    for (state.columns, state.actions) |c, action| {
        if (c.resizable) gtk.ColumnViewColumn.setFixedWidth(c.column, -1);
        if (!c.hideable) continue;
        gtk.ColumnViewColumn.setVisible(c.column, 1);
        if (action) |a| gio.SimpleAction.setState(a, glib.Variant.newBoolean(1));
    }
    scheduleSave(state);
}

fn onLayoutChanged(_: *gobject.Object, _: *gobject.ParamSpec, state: *State) callconv(.c) void {
    scheduleSave(state);
}

fn scheduleSave(state: *State) void {
    if (state.save_source != 0) _ = glib.Source.remove(state.save_source);
    state.save_source = glib.timeoutAdd(save_delay_ms, &onSaveTimeout, state);
}

fn onSaveTimeout(data: ?*anyopaque) callconv(.c) c_int {
    const state: *State = @ptrCast(@alignCast(data orelse return 0));
    state.save_source = 0;
    save(state);
    return 0;
}

fn save(state: *State) void {
    const svc = runtime.config orelse return;
    const cfg = svc.get() catch return;
    const allocator = std.heap.c_allocator;

    var entries: std.ArrayList(TableColumn) = .empty;
    defer entries.deinit(allocator);
    for (cfg.TableColumns) |entry| {
        if (std.mem.eql(u8, entry.Table, state.table)) continue;
        entries.append(allocator, entry) catch return;
    }
    for (state.columns) |c| {
        const width = if (c.resizable) gtk.ColumnViewColumn.getFixedWidth(c.column) else -1;
        const hidden = c.hideable and gtk.ColumnViewColumn.getVisible(c.column) == 0;
        if (width <= 0 and !hidden) continue;
        entries.append(allocator, .{ .Table = state.table, .Column = c.key, .Width = width, .Hidden = hidden }) catch return;
    }

    svc.updateField(.TableColumns, entries.items) catch |err| {
        std.log.err("Could not save the table column layout. {0s}\n\nTechnical details: {1s}", .{ diagnostics.cause(err), @errorName(err) });
    };
}

fn destroyState(data: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data orelse return));
    // the columns may be gone during teardown, so drop a pending save.
    if (state.save_source != 0) _ = glib.Source.remove(state.save_source);
    // the handlers hold their objects, so they can still be disconnected here.
    for (state.handlers[0..state.handler_count]) |h| {
        gobject.signalHandlerDisconnect(h.object, h.id);
        h.object.unref();
    }
    const allocator = std.heap.c_allocator;
    allocator.free(state.handlers);
    allocator.free(state.actions);
    allocator.free(state.columns);
    allocator.destroy(state);
}
