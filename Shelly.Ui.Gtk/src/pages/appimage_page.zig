const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const gdk = bindings.gdk;
const glib = bindings.glib;
const gobject = bindings.gobject;
const support = @import("support.zig");
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const ShellyCommands = @import("../services/shelly_operation.zig").ShellyCommands;
const runtime = @import("../services/runtime.zig");
const AppImage = @import("../models/appimage.zig").AppImage;
const AppImageUpdate = @import("../models/appimage.zig").AppImageUpdate;
const UpdateType = @import("../models/appimage.zig").UpdateType;
const SizeConverter = @import("../helpers/size_converts.zig").SizeConverter;
const Toast = @import("../helpers/custom_ui_comps/toast.zig").Toast;
const ConfirmDialog = @import("../dialog/page/yn_dialog.zig").ConfirmDialog;
const appimage_icon = @import("../helpers/appimage_icon.zig");
const c_string = @import("../helpers/c_string.zig");
const translations = @import("../helpers/translations.zig");

fn uriComponentText(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
}

fn isValidHttpUrl(value: []const u8) bool {
    const uri = std.Uri.parse(value) catch return false;
    return (std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        std.ascii.eqlIgnoreCase(uri.scheme, "https")) and uri.host != null;
}

fn isValidForgejoRepositoryUrl(value: []const u8) bool {
    const uri = std.Uri.parse(value) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(uri.scheme, "https"))
    {
        return false;
    }
    if (uri.host == null or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null)
    {
        return false;
    }

    const host = uriComponentText(uri.host.?);
    var path = uriComponentText(uri.path);
    if (host.len == 0 or path.len == 0 or path[0] != '/') return false;
    if (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    if (std.mem.count(u8, path, "/") == 3 and std.mem.endsWith(u8, path, "/releases"))
        path = path[0 .. path.len - "/releases".len];
    if (std.mem.count(u8, path, "/") != 2) return false;

    const owner_and_repo = path[1..];
    const separator = std.mem.indexOfScalar(u8, owner_and_repo, '/') orelse return false;
    const owner = owner_and_repo[0..separator];
    const repo = owner_and_repo[separator + 1 ..];
    return owner.len > 0 and repo.len > 0 and
        !std.mem.eql(u8, owner, ".") and !std.mem.eql(u8, owner, "..") and
        !std.mem.eql(u8, repo, ".") and !std.mem.eql(u8, repo, "..");
}

pub const AppImagePage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "AppImage";
    pub const icon_name: [:0]const u8 = "application-x-executable-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/appimage_page.ui";

    const fallback_icon = "application-x-executable-symbolic";

    const Private = struct {
        app_list: *gtk.ListBox,
        list_view: *gtk.Widget,
        page_overlay: *gtk.Overlay,
        detail_view: *gtk.Widget,
        detail_title: *gtk.Label,
        detail_version: *gtk.Label,
        detail_description: *gtk.Label,
        detail_icon: *gtk.Image,
        detail_size: *gtk.Label,
        search_entry: *gtk.SearchEntry,
        drop_zone: *gtk.Widget,
        scrolled_list: *gtk.ScrolledWindow,
        update_type_drop: *gtk.DropDown,
        update_url_entry: *gtk.Entry,
        update_url_error: *gtk.Label,
        prerelease_check: *gtk.CheckButton,
        install_path_entry: *gtk.Entry,
        launch_flags_entry: *gtk.Entry,
        environment_view: *gtk.TextView,
        environment_error: *gtk.Label,
        environment_save: *gtk.Button,
        environment_loading: bool = false,
        environment_dirty: bool = false,
        sync_button: *gtk.Button,
        save_button: *gtk.Button,
        remove_button: *gtk.Button,
        sync_all_button: *gtk.Button,
        upgrade_all_button: *gtk.Button,
        install_button: *gtk.Button,

        apps: []AppImage = &.{},
        updates: []AppImageUpdate = &.{},
        arena: ?*std.heap.ArenaAllocator = null,
        updates_arena: ?*std.heap.ArenaAllocator = null,
        selected_index: ?usize = null,
        generation: u64 = 0,
        loaded: bool = false,
        toast: *Toast,
        var offset: c_int = 0;
    };

    const AppsResult = struct {
        page: *Self,
        apps: []AppImage,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
    };

    const UpdatesResult = struct {
        page: *Self,
        updates: []AppImageUpdate,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyAppImagePage",
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

        gtk.Widget.setVexpand(p.detail_view, 1);
        gtk.Widget.setHexpand(p.detail_view, 1);

        const toast = Toast.new();
        gtk.Overlay.addOverlay(p.page_overlay, toast.as(gtk.Widget));
        p.toast = toast;

        const type_strings = gtk.StringList.new(null);
        for ([_][:0]const u8{
            translations._("None"),
            translations._("Static URL"),
            translations._("GitHub"),
            translations._("GitLab"),
            translations._("Codeberg"),
            translations._("Forgejo"),
        }) |label| {
            gtk.StringList.append(type_strings, label);
        }
        gtk.DropDown.setModel(p.update_type_drop, type_strings.as(gio.ListModel));
        type_strings.as(gobject.Object).unref();

        _ = gobject.Object.signals.notify.connect(
            p.update_type_drop.as(gobject.Object),
            *Self,
            &on_update_type_changed,
            self,
            .{ .detail = "selected" },
        );

        const drop_target = gtk.DropTarget.new(gio.File.getGObjectType(), .{ .copy = true });
        _ = gtk.DropTarget.signals.drop.connect(drop_target, *Self, &on_file_drop, self, .{});
        _ = gtk.DropTarget.signals.enter.connect(drop_target, *Self, &on_drag_enter, self, .{});
        _ = gtk.DropTarget.signals.leave.connect(drop_target, *Self, &on_drag_leave, self, .{});
        gtk.Widget.addController(p.scrolled_list.as(gtk.Widget), drop_target.as(gtk.EventController));

        const group = gio.SimpleActionGroup.new();
        const action = gio.SimpleAction.new("focus", null);
        _ = gio.SimpleAction.signals.activate.connect(action, *Self, &onFocusSearch, self, .{});
        gio.ActionMap.addAction(group.as(gio.ActionMap), action.as(gio.Action));
        gtk.Widget.insertActionGroup(self.as(gtk.Widget), "search", group.as(gio.ActionGroup));

        _ = gtk.TextBuffer.signals.changed.connect(gtk.TextView.getBuffer(p.environment_view), *Self, &environment_changed, self, .{});
        support.connectLifecycle(Self, self);
        _ = gtk.ListBox.signals.row_activated.connect(p.app_list, *Self, &onRowActivated, self, .{});
    }

    fn onFocusSearch(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = gtk.Widget.grabFocus(self.priv().search_entry.as(gtk.Widget));
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
        self.reload();
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded or p.environment_dirty) return;
        p.loaded = false;
        p.generation += 1;

        gtk.ListBox.removeAll(p.app_list);

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }
        if (p.updates_arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.updates_arena = null;
        }
        p.apps = &.{};
        p.updates = &.{};
        p.selected_index = null;
    }

    fn reload(self: *Self) void {
        const p = self.priv();
        p.generation += 1;
        const thread = std.Thread.spawn(.{}, load_worker, .{ self, p.generation }) catch return;
        thread.detach();
    }

    fn load_worker(page: *Self, generation: u64) void {
        var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
        defer threaded.deinit();

        const apps_arena = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        apps_arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        {
            const cli = ShellyCli{ .allocator = apps_arena.allocator(), .io = threaded.io() };
            const apps = cli.get_appimages() catch |err| {
                std.debug.print("get_appimages failed: {t}\n", .{err});
                apps_arena.deinit();
                std.heap.c_allocator.destroy(apps_arena);
                return;
            };
            post_apps_result(page, apps.value, apps_arena, generation);
        }

        const updates_arena = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        updates_arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        const cli = ShellyCli{ .allocator = updates_arena.allocator(), .io = threaded.io() };
        const updates = cli.get_appimage_updates() catch {
            updates_arena.deinit();
            std.heap.c_allocator.destroy(updates_arena);
            return;
        };
        if (updates.value.len == 0) {
            updates_arena.deinit();
            std.heap.c_allocator.destroy(updates_arena);
            return;
        }
        post_updates_result(page, updates.value, updates_arena, generation);
    }

    fn post_apps_result(page: *Self, apps: []AppImage, arena: *std.heap.ArenaAllocator, generation: u64) void {
        const result = std.heap.c_allocator.create(AppsResult) catch {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            return;
        };
        result.* = .{
            .page = page,
            .apps = apps,
            .arena = arena,
            .generation = generation,
        };
        _ = glib.idleAdd(&onLoadAppsComplete, result);
    }

    fn post_updates_result(page: *Self, updates: []AppImageUpdate, arena: *std.heap.ArenaAllocator, generation: u64) void {
        const result = std.heap.c_allocator.create(UpdatesResult) catch {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            return;
        };
        result.* = .{
            .page = page,
            .updates = updates,
            .arena = arena,
            .generation = generation,
        };
        _ = glib.idleAdd(&onLoadUpdatesComplete, result);
    }

    fn onLoadAppsComplete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *AppsResult = @ptrCast(@alignCast(data.?));
        const self = result.page;
        const p = self.priv();
        if (result.generation != p.generation or p.environment_dirty) {
            result.arena.deinit();
            std.heap.c_allocator.destroy(result.arena);
            std.heap.c_allocator.destroy(result);
            return 0;
        }

        if (p.arena) |old| {
            old.deinit();
            std.heap.c_allocator.destroy(old);
        }

        if (p.updates_arena) |old| {
            old.deinit();
            std.heap.c_allocator.destroy(old);
            p.updates_arena = null;
        }

        p.updates = &.{};
        p.arena = result.arena;
        p.apps = result.apps;
        std.heap.c_allocator.destroy(result);

        gtk.ListBox.removeAll(p.app_list);
        for (p.apps, 0..) |*app, i| {
            const row = make_app_row(app, i);
            gtk.ListBox.append(p.app_list, row);
        }

        gtk.Widget.setVisible(p.drop_zone, @intFromBool(p.apps.len == 0));
        apply_search_filter(self);
        return 0;
    }

    fn onLoadUpdatesComplete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *UpdatesResult = @ptrCast(@alignCast(data.?));
        const self = result.page;
        const p = self.priv();
        if (result.generation != p.generation) {
            result.arena.deinit();
            std.heap.c_allocator.destroy(result.arena);
            std.heap.c_allocator.destroy(result);
            return 0;
        }

        if (p.updates_arena) |old| {
            old.deinit();
            std.heap.c_allocator.destroy(old);
        }
        p.updates_arena = result.arena;
        p.updates = result.updates;
        std.heap.c_allocator.destroy(result);

        var i: usize = 0;
        var maybe_child = gtk.Widget.getFirstChild(p.app_list.as(gtk.Widget));
        while (maybe_child) |child| : (maybe_child = gtk.Widget.getNextSibling(child)) {
            if (i >= p.apps.len) break;
            defer i += 1;
            const update = findUpdateFor(p.updates, &p.apps[i]) orelse continue;
            var buf: [128]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "{s}: {s}", .{ translations._("Update Available"), update.Version }, 0) catch continue;
            set_row_update_badge(child, text);
        }
        return 0;
    }

    fn versionEquals(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, std.mem.trimStart(u8, a, "v"), std.mem.trimStart(u8, b, "v"));
    }

    fn findUpdateFor(updates: []const AppImageUpdate, app: *const AppImage) ?*const AppImageUpdate {
        for (updates) |*u| {
            if (!u.IsUpdateAvailable) continue;
            if (!std.mem.eql(u8, u.Name, app.Name)) continue;
            if (versionEquals(u.Version, app.Version)) continue;
            return u;
        }
        return null;
    }

    fn make_app_row(app: *const AppImage, index: usize) *gtk.Widget {
        const row = gtk.ListBoxRow.new();
        gtk.ListBoxRow.setActivatable(row, 1);

        gobject.Object.setData(
            row.as(gobject.Object),
            "app-index",
            @ptrFromInt(index + 1),
        );

        const hbox = gtk.Box.new(.horizontal, 12);
        gtk.Widget.setMarginStart(hbox.as(gtk.Widget), 12);
        gtk.Widget.setMarginEnd(hbox.as(gtk.Widget), 12);
        gtk.Widget.setMarginTop(hbox.as(gtk.Widget), 8);
        gtk.Widget.setMarginBottom(hbox.as(gtk.Widget), 8);

        const icon = gtk.Image.new();
        gtk.Image.setPixelSize(icon, 32);
        set_app_icon(icon, app);
        gtk.Box.append(hbox, icon.as(gtk.Widget));

        const vbox = gtk.Box.new(.vertical, 2);
        gtk.Widget.setHexpand(vbox.as(gtk.Widget), 1);

        var buf: [512]u8 = undefined;
        const display_name = if (app.DesktopName.len > 0) app.DesktopName else app.Name;
        const name_label = gtk.Label.new(c_string.cstr(&buf, display_name));
        gtk.Widget.addCssClass(name_label.as(gtk.Widget), "title-4");
        gtk.Label.setXalign(name_label, 0);
        gtk.Box.append(vbox, name_label.as(gtk.Widget));

        const version_hbox = gtk.Box.new(.horizontal, 6);

        var vbuf: [128]u8 = undefined;
        const version_label = gtk.Label.new(c_string.cstr(&vbuf, app.Version));
        gtk.Widget.addCssClass(version_label.as(gtk.Widget), "caption");
        gtk.Widget.addCssClass(version_label.as(gtk.Widget), "dim-label");
        gtk.Label.setXalign(version_label, 0);
        gtk.Box.append(version_hbox, version_label.as(gtk.Widget));

        const update_label = gtk.Label.new("");
        gtk.Widget.setVisible(update_label.as(gtk.Widget), 0);
        gtk.Widget.setValign(update_label.as(gtk.Widget), .center);
        gtk.Widget.addCssClass(update_label.as(gtk.Widget), "caption");
        gtk.Widget.addCssClass(update_label.as(gtk.Widget), "dim-label");
        gtk.Box.append(version_hbox, update_label.as(gtk.Widget));
        gobject.Object.setData(row.as(gobject.Object), "update-label", update_label);

        gtk.Box.append(vbox, version_hbox.as(gtk.Widget));

        if (app.Description.len > 0) {
            var dbuf: [512]u8 = undefined;
            const desc_label = gtk.Label.new(c_string.cstr(&dbuf, app.Description));
            gtk.Widget.addCssClass(desc_label.as(gtk.Widget), "caption");
            gtk.Widget.addCssClass(desc_label.as(gtk.Widget), "dim-label");
            gtk.Label.setXalign(desc_label, 0);
            gtk.Label.setEllipsize(desc_label, .end);
            gtk.Label.setMaxWidthChars(desc_label, 50);
            gtk.Box.append(vbox, desc_label.as(gtk.Widget));
        }

        gtk.Box.append(hbox, vbox.as(gtk.Widget));
        gtk.ListBoxRow.setChild(row, hbox.as(gtk.Widget));
        return row.as(gtk.Widget);
    }

    fn set_row_update_badge(row: *gtk.Widget, text: [:0]const u8) void {
        const raw = gobject.Object.getData(row.as(gobject.Object), "update-label") orelse return;
        const label: *gtk.Label = @ptrCast(@alignCast(raw));
        gtk.Label.setLabel(label, text);
        gtk.Widget.setVisible(label.as(gtk.Widget), 1);
    }

    fn set_app_icon(image: *gtk.Image, app: *const AppImage) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (appimage_icon.resolveIconPath(&path_buf, app.IconName)) |path| {
            gtk.Image.setFromFile(image, path);
            return;
        }
        if (app.IconName.len > 0) {
            var buf: [256]u8 = undefined;
            gtk.Image.setFromIconName(image, c_string.cstr(&buf, app.IconName));
        } else {
            gtk.Image.setFromIconName(image, fallback_icon);
        }
    }

    fn on_search_changed(self: *Self) callconv(.c) void {
        apply_search_filter(self);
    }

    fn apply_search_filter(self: *Self) void {
        const p = self.priv();
        const text = std.mem.span(gtk.Editable.getText(p.search_entry.as(gtk.Editable)));

        var i: usize = 0;
        var maybe_child = gtk.Widget.getFirstChild(p.app_list.as(gtk.Widget));
        while (maybe_child) |child| : (maybe_child = gtk.Widget.getNextSibling(child)) {
            if (i >= p.apps.len) break;
            const app = p.apps[i];
            defer i += 1;

            const display_name = if (app.DesktopName.len > 0) app.DesktopName else app.Name;
            const matches = text.len == 0 or
                contains_ignore_case(display_name, text) or
                contains_ignore_case(app.Name, text);
            gtk.Widget.setVisible(child, @intFromBool(matches));
        }
    }

    fn contains_ignore_case(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        outer: while (i + needle.len <= haystack.len) : (i += 1) {
            for (needle, 0..) |n, j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(n)) continue :outer;
            }
            return true;
        }
        return false;
    }

    fn onRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const raw = gobject.Object.getData(row.as(gobject.Object), "app-index");
        if (raw == null) return;
        const index = @intFromPtr(raw) - 1;

        const p = self.priv();
        if (index >= p.apps.len) return;
        show_detail(self, index);
    }

    fn show_detail(self: *Self, index: usize) void {
        const p = self.priv();
        const app = p.apps[index];
        p.selected_index = index;

        var buf: [512]u8 = undefined;

        const display_name = if (app.DesktopName.len > 0) app.DesktopName else app.Name;
        gtk.Label.setLabel(p.detail_title, c_string.cstr(&buf, display_name));

        var vbuf: [128]u8 = undefined;
        gtk.Label.setLabel(p.detail_version, std.fmt.bufPrintSentinel(&vbuf, "{s} {s}", .{ translations._("Version"), app.Version }, 0) catch translations._("Version ?"));

        gtk.Label.setLabel(p.detail_description, c_string.cstr(&buf, app.Description));

        var sbuf: [64]u8 = undefined;
        gtk.Label.setLabel(p.detail_size, SizeConverter.convert_null_term(&sbuf, app.SizeOnDisk));

        set_app_icon(p.detail_icon, &app);

        gtk.DropDown.setSelected(p.update_type_drop, @intFromEnum(app.UpdateType));

        switch (app.UpdateType) {
            .GitHub, .GitLab, .Codeberg => {
                const text = if (app.RepoOwner != null and app.RepoName != null)
                    std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ app.RepoOwner.?, app.RepoName.? }, 0) catch ""
                else
                    "";
                gtk.Editable.setText(p.update_url_entry.as(gtk.Editable), text);
            },
            .StaticUrl, .Forgejo => {
                gtk.Editable.setText(p.update_url_entry.as(gtk.Editable), c_string.cstr(&buf, app.UpdateURl));
            },
            .None => gtk.Editable.setText(p.update_url_entry.as(gtk.Editable), ""),
        }

        gtk.Widget.setVisible(p.update_url_error.as(gtk.Widget), 0);
        gtk.Widget.removeCssClass(p.update_url_entry.as(gtk.Widget), "error");
        update_strategy_controls(self);

        gtk.CheckButton.setActive(p.prerelease_check, @intFromBool(app.AllowPrerelease));
        gtk.Editable.setText(p.install_path_entry.as(gtk.Editable), if (app.Path) |path| c_string.cstr(&buf, path) else "");
        gtk.Editable.setText(p.launch_flags_entry.as(gtk.Editable), if (app.CommandLineArgs) |args| c_string.cstr(&buf, args) else "");

        var environment_text: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
        defer environment_text.deinit();
        for (app.EnvironmentVariables) |variable| {
            environment_text.writer.print("{s}={s}\n", .{ variable.Key, variable.Value }) catch return;
        }
        const environment_z = std.heap.c_allocator.dupeZ(u8, environment_text.written()) catch return;
        defer std.heap.c_allocator.free(environment_z);
        p.environment_loading = true;
        gtk.TextBuffer.setText(gtk.TextView.getBuffer(p.environment_view), environment_z, -1);
        p.environment_loading = false;
        p.environment_dirty = false;
        validate_environment(self);

        gtk.Widget.setVisible(p.list_view, 0);
        gtk.Widget.setVisible(p.detail_view, 1);
    }

    fn show_list(self: *Self) void {
        const p = self.priv();
        p.selected_index = null;
        gtk.Widget.setVisible(p.detail_view, 0);
        gtk.Widget.setVisible(p.list_view, 1);
    }

    fn selectedUpdateType(p: *Private) UpdateType {
        const selected = gtk.DropDown.getSelected(p.update_type_drop);
        if (selected <= @intFromEnum(UpdateType.Forgejo)) {
            return @enumFromInt(@as(u8, @intCast(selected)));
        }
        return .None;
    }

    fn update_strategy_controls(self: *Self) void {
        const p = self.priv();
        const is_none = selectedUpdateType(p) == .None;
        const sensitive: c_int = if (is_none) 0 else 1;

        gtk.Widget.setSensitive(p.update_url_entry.as(gtk.Widget), sensitive);
        gtk.Widget.setSensitive(p.prerelease_check.as(gtk.Widget), sensitive);

        if (is_none) {
            gtk.Editable.setText(p.update_url_entry.as(gtk.Editable), "");
            gtk.Widget.setVisible(p.update_url_error.as(gtk.Widget), 0);
            gtk.Widget.removeCssClass(p.update_url_entry.as(gtk.Widget), "error");
        }
    }

    fn on_update_type_changed(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        update_strategy_controls(self);
    }

    fn validateUpdateConfig(self: *Self) bool {
        const p = self.priv();
        const text = std.mem.span(gtk.Editable.getText(p.update_url_entry.as(gtk.Editable)));
        const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);

        const update_type = selectedUpdateType(p);

        var error_text: ?[:0]const u8 = null;
        switch (update_type) {
            .None => {},
            .GitHub, .GitLab, .Codeberg => {
                const valid = trimmed.len > 0 and
                    trimmed[0] != '/' and trimmed[trimmed.len - 1] != '/' and
                    std.mem.count(u8, trimmed, "/") == 1;
                if (!valid) {
                    error_text = translations._("Invalid format. Use owner/repo (e.g. seafoam-labs/shelly-alpm)");
                }
            },
            .StaticUrl => {
                if (!isValidHttpUrl(trimmed)) {
                    error_text = translations._("Invalid URL. Must start with http:// or https://");
                }
            },
            .Forgejo => {
                if (!isValidForgejoRepositoryUrl(trimmed)) {
                    error_text = translations._("Invalid Forgejo URL. Use http(s)://host/owner/repo or http(s)://host/owner/repo/releases");
                }
            },
        }

        if (error_text) |msg| {
            gtk.Label.setLabel(p.update_url_error, msg);
            gtk.Widget.setVisible(p.update_url_error.as(gtk.Widget), 1);
            gtk.Widget.addCssClass(p.update_url_entry.as(gtk.Widget), "error");
            return false;
        }

        gtk.Widget.setVisible(p.update_url_error.as(gtk.Widget), 0);
        gtk.Widget.removeCssClass(p.update_url_entry.as(gtk.Widget), "error");
        return true;
    }

    fn install_appimage(self: *Self) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        gtk.FileDialog.setTitle(dialog, translations._("Choose an AppImage file"));

        const filter = gtk.FileFilter.new();
        gtk.FileFilter.setName(filter, translations._("AppImage files"));
        gtk.FileFilter.addSuffix(filter, "AppImage");
        gtk.FileFilter.addSuffix(filter, "appimage");

        const filters = gio.ListStore.new(gtk.FileFilter.getGObjectType());
        gio.ListStore.append(filters, filter.as(gobject.Object));
        gtk.FileDialog.setFilters(dialog, filters.as(gio.ListModel));
        filter.as(gobject.Object).unref();
        filters.as(gobject.Object).unref();

        const root = gtk.Widget.getRoot(self.as(gtk.Widget));
        const parent_window: ?*gtk.Window = if (root) |r| gobject.ext.cast(gtk.Window, r) else null;

        _ = self.as(gobject.Object).ref();
        gtk.FileDialog.open(dialog, parent_window, null, &on_file_chosen, self);
    }

    fn on_file_chosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        defer self.as(gobject.Object).unref();
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));

        const file = gtk.FileDialog.openFinish(dialog, result, null) orelse return;
        defer file.as(gobject.Object).unref();

        const path_c = gio.File.getPath(file) orelse return;
        defer glib.free(path_c);
        self.installFromPath(std.mem.span(path_c));
    }

    fn installFromPath(self: *Self, path: []const u8) void {
        const p = self.priv();
        if (!std.ascii.endsWithIgnoreCase(path, ".appimage")) {
            p.toast.show(.warning, translations._("Only .AppImage files can be installed"));
            return;
        }

        const argv = ShellyCommands.install_appimage(std.heap.c_allocator, path) catch return;
        defer std.heap.c_allocator.free(argv);

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(std.heap.c_allocator);
        names.append(std.heap.c_allocator, std.fs.path.basename(path)) catch {};

        const win = support.getWindow(ShellyWindow, self) orelse return;
        win.startTransaction(.{
            .title = translations._("Installing AppImage"),
            .argv = argv,
            .packages = names.items,
            .on_complete = &on_op_complete,
            .ctx = self,
            .privileged = false,
        });
    }

    fn on_file_drop(_: *gtk.DropTarget, value: *gobject.Value, _: f64, _: f64, self: *Self) callconv(.c) c_int {
        const p = self.priv();
        gtk.Widget.removeCssClass(p.drop_zone, "drag-hover");

        const obj = gobject.Value.getObject(value) orelse return 0;
        const file = gobject.ext.cast(gio.File, obj) orelse return 0;
        const path_c = gio.File.getPath(file) orelse return 0;
        defer glib.free(path_c);

        self.installFromPath(std.mem.span(path_c));
        return 1;
    }

    fn on_drag_enter(_: *gtk.DropTarget, _: f64, _: f64, self: *Self) callconv(.c) gdk.DragAction {
        const p = self.priv();
        gtk.Widget.addCssClass(p.drop_zone, "drag-hover");
        return .{ .copy = true };
    }

    fn on_drag_leave(_: *gtk.DropTarget, self: *Self) callconv(.c) void {
        const p = self.priv();
        gtk.Widget.removeCssClass(p.drop_zone, "drag-hover");
    }

    fn upgrade_appimage(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.updates.len == 0) {
            p.toast.show(.info, translations._("No AppImages need to be upgraded"));
            return;
        }

        const argv = ShellyCommands.upgrade_appimages(std.heap.c_allocator) catch return;
        defer std.heap.c_allocator.free(argv);

        const win = support.getWindow(ShellyWindow, self) orelse return;
        win.startTransaction(.{
            .title = translations._("Upgrading AppImages"),
            .argv = argv,
            .packages = &.{},
            .on_complete = &on_op_complete,
            .ctx = self,
            .privileged = false,
        });
    }

    fn sync_all_appimage(self: *Self) callconv(.c) void {
        const argv = ShellyCommands.sync_appimage(std.heap.c_allocator, null) catch return;
        defer std.heap.c_allocator.free(argv);

        const win = support.getWindow(ShellyWindow, self) orelse return;
        win.startTransaction(.{
            .title = translations._("Syncing AppImages"),
            .argv = argv,
            .packages = &.{},
            .on_complete = &on_op_complete,
            .ctx = self,
            .privileged = false,
        });
    }

    fn sync_appimage(self: *Self) callconv(.c) void {
        const p = self.priv();
        const index = p.selected_index orelse return;
        const app = p.apps[index];

        const argv = ShellyCommands.sync_appimage(std.heap.c_allocator, app.Name) catch return;
        defer std.heap.c_allocator.free(argv);

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(std.heap.c_allocator);
        names.append(std.heap.c_allocator, app.Name) catch {};

        const win = support.getWindow(ShellyWindow, self) orelse return;
        win.startTransaction(.{
            .title = translations._("Syncing AppImage"),
            .argv = argv,
            .packages = names.items,
            .on_complete = &on_op_complete,
            .ctx = self,
            .privileged = false,
        });
    }

    fn get_environment_text(self: *Self) [:0]u8 {
        const buffer = gtk.TextView.getBuffer(self.priv().environment_view);
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        gtk.TextBuffer.getBounds(buffer, &start, &end);
        return std.mem.span(gtk.TextBuffer.getText(buffer, &start, &end, 0));
    }

    fn environment_changed(_: *gtk.TextBuffer, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.environment_loading) return;
        p.environment_dirty = true;
        validate_environment(self);
    }

    fn validate_environment(self: *Self) void {
        const p = self.priv();
        gtk.Widget.setSensitive(p.sync_button.as(gtk.Widget), @intFromBool(!p.environment_dirty));
        gtk.Widget.setSensitive(p.save_button.as(gtk.Widget), @intFromBool(!p.environment_dirty));
        gtk.Widget.setSensitive(p.remove_button.as(gtk.Widget), @intFromBool(!p.environment_dirty));
        const text = get_environment_text(self);
        defer glib.free(text.ptr);
        const json = @import("../models/appimage.zig").environmentJson(std.heap.c_allocator, text) catch {
            gtk.Label.setLabel(p.environment_error, translations._("Use unique KEY=value lines. Keys must start with a letter or underscore and contain only letters, digits, or underscores."));
            gtk.Widget.setVisible(p.environment_error.as(gtk.Widget), 1);
            gtk.Widget.setSensitive(p.environment_save.as(gtk.Widget), 0);
            return;
        };
        defer std.heap.c_allocator.free(json);
        gtk.Widget.setVisible(p.environment_error.as(gtk.Widget), 0);
        gtk.Widget.setSensitive(p.environment_save.as(gtk.Widget), @intFromBool(p.environment_dirty));
    }

    fn save_environment(self: *Self) callconv(.c) void {
        const p = self.priv();
        const index = p.selected_index orelse return;
        const app = p.apps[index];
        const text = get_environment_text(self);
        defer glib.free(text.ptr);
        const json = @import("../models/appimage.zig").environmentJson(std.heap.c_allocator, text) catch return;
        defer std.heap.c_allocator.free(json);
        const argv = ShellyCommands.configure_appimage_environment(std.heap.c_allocator, app.Name, json) catch return;
        defer std.heap.c_allocator.free(argv);
        const win = support.getWindow(ShellyWindow, self) orelse return;
        gtk.Widget.setSensitive(p.environment_save.as(gtk.Widget), 0);
        win.startTransaction(.{
            .title = translations._("Saving AppImage environment"),
            .argv = argv,
            .packages = &.{app.Name},
            .on_complete = &on_environment_saved,
            .ctx = self,
            .privileged = false,
        });
    }

    fn on_environment_saved(ctx: *anyopaque, success: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (success) self.priv().environment_dirty = false else validate_environment(self);
        on_op_complete(ctx, success);
    }

    fn save_config(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.environment_dirty) return;
        const index = p.selected_index orelse return;
        const app = p.apps[index];

        if (!validateUpdateConfig(self)) return;

        const text = std.mem.trim(
            u8,
            std.mem.span(gtk.Editable.getText(p.update_url_entry.as(gtk.Editable))),
            &std.ascii.whitespace,
        );
        const update_type = selectedUpdateType(p);
        const prerelease = gtk.CheckButton.getActive(p.prerelease_check) != 0;

        const url: []const u8 = if (update_type == .None) "" else text;

        const argv = ShellyCommands.configure_appimage(std.heap.c_allocator, app.Name, url, update_type, prerelease) catch return;
        defer std.heap.c_allocator.free(argv);

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(std.heap.c_allocator);
        names.append(std.heap.c_allocator, app.Name) catch {};

        const win = support.getWindow(ShellyWindow, self) orelse return;
        win.startTransaction(.{
            .title = translations._("Saving update configuration"),
            .argv = argv,
            .packages = names.items,
            .on_complete = &on_op_complete,
            .ctx = self,
            .privileged = false,
        });
    }

    fn remove_appimage(self: *Self) callconv(.c) void {
        const p = self.priv();
        const index = p.selected_index orelse return;
        const app = p.apps[index];

        var buf: [512]u8 = undefined;
        const message = std.fmt.bufPrintSentinel(
            &buf,
            "{s} {s}? {s}",
            .{ translations._("Remove"), app.Name, translations._("Configuration files will be kept.") },
            0,
        ) catch translations._("Remove this AppImage?");
        const dialog = ConfirmDialog.new(translations._("Remove AppImage"), message, &on_remove_response, self);
        dialog.setButtons(translations._("Remove"), translations._("Cancel"));
        if (support.getWindow(ShellyWindow, self)) |win| {
            win.showLockout(dialog.as(gtk.Widget));
        }
    }

    fn on_remove_response(ctx: ?*anyopaque, confirmed: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
        if (!confirmed) return;

        const p = self.priv();
        const index = p.selected_index orelse return;
        const app = p.apps[index];

        var remove_config = false;
        if (runtime.config) |cfg_service| {
            if (cfg_service.get()) |cfg| {
                remove_config = cfg.PackageManagementRemoveConfigs;
            } else |_| {}
        }

        const argv = ShellyCommands.remove_appimage(std.heap.c_allocator, app.Name, remove_config) catch return;
        defer std.heap.c_allocator.free(argv);

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(std.heap.c_allocator);
        names.append(std.heap.c_allocator, app.Name) catch {};

        const win = support.getWindow(ShellyWindow, self) orelse return;
        win.startTransaction(.{
            .title = translations._("Removing AppImage"),
            .argv = argv,
            .packages = names.items,
            .on_complete = &on_op_complete,
            .ctx = self,
            .privileged = false,
        });
    }

    fn on_op_complete(ctx: *anyopaque, success: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const p = self.priv();
        if (success) {
            p.toast.show(.success, translations._("Operation completed successfully"));
            show_list(self);
            self.reload();
        } else {
            p.toast.show(.@"error", translations._("Operation failed"));
        }
    }

    fn back_to_list(self: *Self) callconv(.c) void {
        if (self.priv().environment_dirty) {
            const dialog = ConfirmDialog.new(translations._("Discard environment changes?"), translations._("Your environment changes have not been saved."), &on_discard_environment, self);
            dialog.setButtons(translations._("Discard"), translations._("Cancel"));
            if (support.getWindow(ShellyWindow, self)) |win| win.showLockout(dialog.as(gtk.Widget));
            return;
        }
        show_list(self);
    }

    fn on_discard_environment(ctx: ?*anyopaque, confirmed: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
        if (confirmed) {
            self.priv().environment_dirty = false;
            show_list(self);
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        self.priv().environment_dirty = false;
        self.onUnmap();
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    const template_children = .{
        .{ "AppImageListBox", @offsetOf(Private, "app_list") },
        .{ "AppImageOverlay", @offsetOf(Private, "page_overlay") },
        .{ "AppImagePageMain", @offsetOf(Private, "list_view") },
        .{ "AppImageDetailView", @offsetOf(Private, "detail_view") },
        .{ "DetailTitleLabel", @offsetOf(Private, "detail_title") },
        .{ "DetailVersionLabel", @offsetOf(Private, "detail_version") },
        .{ "DetailDescriptionLabel", @offsetOf(Private, "detail_description") },
        .{ "DetailIcon", @offsetOf(Private, "detail_icon") },
        .{ "DetailSizeLabel", @offsetOf(Private, "detail_size") },
        .{ "AppImageSearchEntry", @offsetOf(Private, "search_entry") },
        .{ "DropZone", @offsetOf(Private, "drop_zone") },
        .{ "AppImageListWindow", @offsetOf(Private, "scrolled_list") },
        .{ "UpdateTypeDropDown", @offsetOf(Private, "update_type_drop") },
        .{ "UpdateUrlEntry", @offsetOf(Private, "update_url_entry") },
        .{ "UpdateUrlErrorLabel", @offsetOf(Private, "update_url_error") },
        .{ "AllowPrereleaseCheckButton", @offsetOf(Private, "prerelease_check") },
        .{ "InstallPathEntry", @offsetOf(Private, "install_path_entry") },
        .{ "LaunchFlagsEntry", @offsetOf(Private, "launch_flags_entry") },
        .{ "EnvironmentView", @offsetOf(Private, "environment_view") },
        .{ "EnvironmentError", @offsetOf(Private, "environment_error") },
        .{ "SaveEnvironmentButton", @offsetOf(Private, "environment_save") },
        .{ "SyncButton", @offsetOf(Private, "sync_button") },
        .{ "SaveConfigButton", @offsetOf(Private, "save_button") },
        .{ "RemoveAppImageButton", @offsetOf(Private, "remove_button") },
        .{ "SyncAllButton", @offsetOf(Private, "sync_all_button") },
        .{ "UpgradeAllButton", @offsetOf(Private, "upgrade_all_button") },
        .{ "InstallAppImageButton", @offsetOf(Private, "install_button") },
    };

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            const wc = gobject.ext.as(gtk.Widget.Class, class);
            gtk.Widget.Class.setTemplateFromResource(wc, resource_path);
            inline for (template_children) |c| {
                support.bindChild(class, Private.offset, c[0], c[1]);
            }
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "install_appimage", @ptrCast(&install_appimage));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "upgrade_appimage", @ptrCast(&upgrade_appimage));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "sync_all_appimage", @ptrCast(&sync_all_appimage));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "sync_appimage", @ptrCast(&sync_appimage));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "save_config", @ptrCast(&save_config));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "save_environment", @ptrCast(&save_environment));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "remove_appimage", @ptrCast(&remove_appimage));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "back_to_list", @ptrCast(&back_to_list));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "search_changed", @ptrCast(&on_search_changed));
        }
    };
};

test "AppImagePage.versionEquals strips leading v" {
    try std.testing.expect(AppImagePage.versionEquals("v1.2.3", "1.2.3"));
    try std.testing.expect(AppImagePage.versionEquals("1.2.3", "1.2.3"));
    try std.testing.expect(!AppImagePage.versionEquals("v1.2.3", "1.2.4"));
}

test "AppImagePage.contains_ignore_case matches substrings case-insensitively" {
    try std.testing.expect(AppImagePage.contains_ignore_case("Blender", "blend"));
    try std.testing.expect(AppImagePage.contains_ignore_case("OBS Studio", "studio"));
    try std.testing.expect(!AppImagePage.contains_ignore_case("Krita", "obs"));
    try std.testing.expect(!AppImagePage.contains_ignore_case("Krita", "krita-longer"));
}

test "Forgejo update validation accepts repository and release-page URLs" {
    try std.testing.expect(isValidForgejoRepositoryUrl(
        "https://git.eden-emu.dev/eden-ci/nightly",
    ));
    try std.testing.expect(isValidForgejoRepositoryUrl(
        "https://git.eden-emu.dev/eden-ci/nightly/",
    ));
    try std.testing.expect(isValidForgejoRepositoryUrl(
        "https://git.eden-emu.dev/eden-ci/nightly/releases",
    ));
    try std.testing.expect(isValidForgejoRepositoryUrl(
        "https://git.eden-emu.dev/eden-ci/nightly/releases/",
    ));
}

test "Forgejo update validation rejects unrelated and incomplete paths" {
    try std.testing.expect(!isValidForgejoRepositoryUrl(
        "https://git.eden-emu.dev/eden-ci/nightly/actions",
    ));
    try std.testing.expect(!isValidForgejoRepositoryUrl(
        "https://git.eden-emu.dev/eden-ci",
    ));
    try std.testing.expect(!isValidForgejoRepositoryUrl(
        "git.eden-emu.dev/eden-ci/nightly",
    ));
}
