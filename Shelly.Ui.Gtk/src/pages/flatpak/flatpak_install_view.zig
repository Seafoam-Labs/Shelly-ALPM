const std = @import("std");
const HttpClient = @import("ShellyHttp");
const bindings = @import("Shelly_Ui_Gtk");
const gio = bindings.gio;
const glib = bindings.glib;
const gtk = bindings.gtk;
const gdk = bindings.gdk;
const gobject = bindings.gobject;
const support = @import("../support.zig");
const flatpak = @import("../../models/flatpak.zig");
const search = @import("../../helpers/search.zig");
const c_string = @import("../../helpers/c_string.zig");

const ShellyCli = @import("../../services/shelly_cli.zig").ShellyCli;
const AppstreamAppObject = @import("../../g_objects/appstream_app_object.zig").AppstreamAppObject;
const Carousel = @import("../../helpers/custom_ui_comps/carousel.zig").Carousel;
const CarouselIndicatorDots = @import("../../helpers/custom_ui_comps/carousel_indicator_dots.zig").CarouselIndicatorDots;
const SizeConverter = @import("../../helpers/size_converts.zig").SizeConverter;
const ShellyWindow = @import("../../shelly_window.zig").ShellyWindow;
const ShellyCommands = @import("../../services/shelly_operation.zig").ShellyCommands;
const Category = @import("../../models/flatpak.zig").Category;
const FlatHubApiService = @import("../../services/flathub_api.zig").FlatHubApiService;
const PermissionsDialog = @import("../../dialog/page/permissions.zig").PermissionsDialog;
const VersionHistoryDialog = @import("../../dialog/page/version_history.zig").VersionHistoryDialog;
const Entry = @import("../../dialog/page/version_history.zig").Entry;
const translations = @import("../../helpers/translations.zig");

extern fn g_get_user_data_dir() [*:0]const u8;
extern fn g_file_test(filename: [*:0]const u8, flags: c_uint) c_int;
extern fn g_strndup(str: [*]const u8, len: usize) [*:0]u8;
extern fn malloc_trim(pad: usize) c_int;

pub const FlatpakInstallView = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    const resource_path = "/com/shellyorg/shelly/ui/flatpak/flatpak_install_view.ui";
    const batch_size = 128;
    const default_branch = "stable";

    const Private = struct {
        content_stack: *gtk.Stack,
        list_overlay: *gtk.Overlay,
        list_flatpaks: *gtk.GridView,
        loading_overlay: *gtk.Box,
        loading_spinner: *gtk.Spinner,
        loading_label: *gtk.Label,
        overlay_panel: *gtk.Box,
        overlay_back_button: *gtk.Button,
        overlay_icon: *gtk.Image,
        overlay_name_label: *gtk.Label,
        overlay_author_label: *gtk.Label,
        overlay_version_label: *gtk.Label,
        overlay_size_label: *gtk.Label,
        overlay_license_label: *gtk.Label,
        overlay_screenshots_container: *gtk.Box,
        overlay_summary_label: *gtk.Label,
        overlay_description_label: *gtk.Label,
        overlay_description_label_full: *gtk.Label,
        description_revealer: *gtk.Revealer,
        description_reveal_button: *gtk.Button,
        overlay_remote_selection: *gtk.DropDown,
        overlay_install_button: *gtk.Button,
        overlay_permissions_button: *gtk.Button,
        version_history_button: *gtk.Button,
        overlay_links_box: *gtk.ListBox,
        model: ?*gio.ListStore,
        filter: ?*gtk.CustomFilter,
        selection: ?*gtk.SingleSelection,
        selected_app: ?*AppstreamAppObject,

        loaded: bool,
        disposed: bool,
        load_generation: u64,
        details_generation: u64,
        remote_info_generation: u64,
        suppress_remote_notify: bool,
        search_text: [256]u8,
        category: Category,
        search_len: usize,
        var offset: c_int = 0;
    };

    const LoadResult = struct {
        page: *Self,
        generation: u64,
        arena: ?*std.heap.ArenaAllocator = null,
        parsed: ?std.json.Parsed([]flatpak.AppstreamApp) = null,
        next_index: usize = 0,
        trending_set: std.StringHashMapUnmanaged(void) = .empty,
        popular_set: std.StringHashMapUnmanaged(void) = .empty,
        recently_updated_set: std.StringHashMapUnmanaged(void) = .empty,
        recently_added_set: std.StringHashMapUnmanaged(void) = .empty,
        failed: bool = false,
    };
    const ScreenshotLoad = struct {
        page: *Self,
        picture: *gtk.Picture,
        generation: u64,
        url: [:0]u8,
        data: ?[]u8 = null,
        failed: bool = false,
    };

    const RemoteInfoLoad = struct {
        page: *Self,
        details_generation: u64,
        request_generation: u64,
        remote: [:0]u8,
        app_id: [:0]u8,
        download_size: i64 = 0,
        installed_size: i64 = 0,
        permissions: []const []const u8 = &.{},
        app: *AppstreamAppObject,
        failed: bool = false,
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyFlatpakInstallView",
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
        p.model = null;
        p.filter = null;
        p.selection = null;
        p.selected_app = null;

        p.loaded = false;
        p.disposed = false;
        p.load_generation = 0;
        p.details_generation = 0;
        p.remote_info_generation = 0;
        p.suppress_remote_notify = false;
        p.search_len = 0;
        self.setup_grid();
        _ = gtk.Button.signals.clicked.connect(p.overlay_back_button, *Self, &on_back_clicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.description_reveal_button, *Self, &on_description_reveal_clicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.overlay_install_button, *Self, &on_install_clicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.overlay_permissions_button, *Self, &on_permissions_clicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.version_history_button, *Self, &on_version_history_clicked, self, .{});
        _ = gobject.Object.signals.notify.connect(p.overlay_remote_selection.as(gobject.Object), *Self, &on_remote_selected, self, .{ .detail = "selected" });
        gtk.Stack.setVisibleChild(p.content_stack, p.list_overlay.as(gtk.Widget));
        support.connectLifecycle(Self, self);
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
        p.load_generation +%= 1;
        self.load_apps(p.load_generation);
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;
        p.load_generation +%= 1;
        gtk.Widget.setVisible(p.loading_overlay.as(gtk.Widget), 0);
        self.show_list();
        if (p.model) |model| gio.ListStore.removeAll(model);
        _ = malloc_trim(0);
    }

    fn setup_grid(self: *Self) void {
        const p = self.priv();
        const model = gio.ListStore.new(AppstreamAppObject.getGObjectType());
        p.model = model;

        const filter = gtk.CustomFilter.new(&filter_app, self, null);
        p.filter = filter;
        _ = model.as(gobject.Object).ref();
        _ = filter.as(gobject.Object).ref();
        const filter_model = gtk.FilterListModel.new(model.as(gio.ListModel), filter.as(gtk.Filter));
        const selection = gtk.SingleSelection.new(filter_model.as(gio.ListModel));
        p.selection = selection;
        gtk.GridView.setModel(p.list_flatpaks, selection.as(gtk.SelectionModel));
        gtk.GridView.setMinColumns(p.list_flatpaks, 1);
        gtk.GridView.setMaxColumns(p.list_flatpaks, 4);
        _ = gtk.GridView.signals.activate.connect(p.list_flatpaks, *Self, &on_app_activated, self, .{});

        const factory = gtk.SignalListItemFactory.new();
        const callbacks = struct {
            fn setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: *Self) callconv(.c) void {
                const list_item = gobject.ext.cast(gtk.ListItem, item) orelse return;

                const content_grid = gtk.Grid.new();
                gtk.Widget.setMarginStart(content_grid.as(gtk.Widget), 12);
                gtk.Widget.setMarginEnd(content_grid.as(gtk.Widget), 12);
                gtk.Widget.setMarginTop(content_grid.as(gtk.Widget), 6);
                gtk.Widget.setMarginBottom(content_grid.as(gtk.Widget), 6);
                gtk.Grid.setColumnSpacing(content_grid, 6);
                gtk.Grid.setRowSpacing(content_grid, 0);
                gtk.Widget.setHexpand(content_grid.as(gtk.Widget), 0);
                gtk.Widget.setHalign(content_grid.as(gtk.Widget), .start);
                gtk.Widget.setValign(content_grid.as(gtk.Widget), .center);

                const icon = gtk.Image.new();
                gtk.Image.setPixelSize(icon, 64);
                gtk.Widget.setValign(icon.as(gtk.Widget), .center);
                gtk.Widget.setHalign(icon.as(gtk.Widget), .center);
                gtk.Grid.attach(content_grid, icon.as(gtk.Widget), 0, 0, 1, 2);

                const right_box = gtk.Box.new(.vertical, 0);
                gtk.Widget.setValign(right_box.as(gtk.Widget), .center);
                gtk.Widget.setHalign(right_box.as(gtk.Widget), .start);

                const title_grid = gtk.Grid.new();
                gtk.Grid.setColumnSpacing(title_grid, 4);
                gtk.Widget.setHalign(title_grid.as(gtk.Widget), .start);

                const name_label = gtk.Label.new("");
                gtk.Widget.setHalign(name_label.as(gtk.Widget), .start);
                gtk.Label.setUseMarkup(name_label, 1);
                gtk.Label.setWrap(name_label, 0);
                gtk.Label.setEllipsize(name_label, .end);
                gtk.Widget.setHexpand(name_label.as(gtk.Widget), 0);
                gtk.Widget.setVexpand(name_label.as(gtk.Widget), 0);
                gtk.Label.setMaxWidthChars(name_label, 30);
                gtk.Grid.attach(title_grid, name_label.as(gtk.Widget), 0, 0, 1, 1);

                const verified_icon = gtk.Image.newFromIconName("security-high-symbolic");
                gtk.Image.setPixelSize(verified_icon, 14);
                gtk.Widget.setValign(verified_icon.as(gtk.Widget), .center);
                gtk.Widget.setHalign(verified_icon.as(gtk.Widget), .start);
                gtk.Widget.setHexpand(verified_icon.as(gtk.Widget), 0);
                gtk.Widget.setVexpand(verified_icon.as(gtk.Widget), 0);
                gtk.Widget.setTooltipText(verified_icon.as(gtk.Widget), translations._("Verified"));
                gtk.Grid.attach(title_grid, verified_icon.as(gtk.Widget), 1, 0, 1, 1);
                gtk.Box.append(right_box, title_grid.as(gtk.Widget));

                const summary_label = gtk.Label.new("");
                gtk.Widget.setHalign(summary_label.as(gtk.Widget), .start);
                gtk.Widget.setHexpand(summary_label.as(gtk.Widget), 1);
                gtk.Label.setWrap(summary_label, 0);
                gtk.Label.setEllipsize(summary_label, .end);
                gtk.Label.setMaxWidthChars(summary_label, 35);
                gtk.Label.setWidthChars(summary_label, -1);
                gtk.Box.append(right_box, summary_label.as(gtk.Widget));
                gtk.Grid.attach(content_grid, right_box.as(gtk.Widget), 1, 0, 1, 2);

                const frame = gtk.Frame.new(null);
                gtk.Frame.setChild(frame, content_grid.as(gtk.Widget));
                gtk.Widget.setSizeRequest(frame.as(gtk.Widget), 300, -1);
                gtk.Widget.setHexpand(frame.as(gtk.Widget), 0);
                gtk.Widget.setHalign(frame.as(gtk.Widget), .fill);
                gtk.Widget.setMarginStart(frame.as(gtk.Widget), 2);
                gtk.Widget.setMarginEnd(frame.as(gtk.Widget), 2);
                gtk.Widget.setMarginTop(frame.as(gtk.Widget), 1);
                gtk.Widget.setMarginBottom(frame.as(gtk.Widget), 1);
                gtk.Widget.addCssClass(frame.as(gtk.Widget), "card");
                gtk.ListItem.setChild(list_item, frame.as(gtk.Widget));
            }

            fn bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: *Self) callconv(.c) void {
                const list_item = gobject.ext.cast(gtk.ListItem, item) orelse return;
                const object = gobject.ext.cast(AppstreamAppObject, gtk.ListItem.getItem(list_item) orelse return) orelse return;
                const frame = gobject.ext.cast(gtk.Frame, gtk.ListItem.getChild(list_item) orelse return) orelse return;
                const content_grid = gobject.ext.cast(gtk.Grid, gtk.Frame.getChild(frame) orelse return) orelse return;
                const icon = gobject.ext.cast(gtk.Image, gtk.Grid.getChildAt(content_grid, 0, 0) orelse return) orelse return;
                const right_box = gobject.ext.cast(gtk.Box, gtk.Grid.getChildAt(content_grid, 1, 0) orelse return) orelse return;
                const title_grid = gobject.ext.cast(gtk.Grid, gtk.Widget.getFirstChild(right_box.as(gtk.Widget)) orelse return) orelse return;
                const name_label = gobject.ext.cast(gtk.Label, gtk.Grid.getChildAt(title_grid, 0, 0) orelse return) orelse return;
                const verified_icon = gtk.Grid.getChildAt(title_grid, 1, 0) orelse return;
                const summary_label = gobject.ext.cast(gtk.Label, gtk.Widget.getLastChild(right_box.as(gtk.Widget)) orelse return) orelse return;

                var markup_buffer: [512]u8 = undefined;
                const escaped = glib.markupEscapeText(object.getName(), -1);
                defer glib.free(escaped);
                const markup = std.fmt.bufPrintZ(&markup_buffer, "<b>{s}</b>", .{escaped}) catch object.getName();
                gtk.Label.setMarkup(name_label, markup);
                gtk.Label.setLabel(summary_label, object.getSummary());
                gtk.Widget.setVisible(verified_icon, @intFromBool(object.isVerified()));
                set_app_icon(icon, object);
            }
        };
        _ = gtk.SignalListItemFactory.signals.setup.connect(factory, *Self, &callbacks.setup, self, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(factory, *Self, &callbacks.bind, self, .{});
        gtk.GridView.setFactory(p.list_flatpaks, factory.as(gtk.ListItemFactory));
        factory.as(gobject.Object).unref();
    }

    fn on_app_activated(_: *gtk.GridView, position: c_uint, self: *Self) callconv(.c) void {
        const selection = self.priv().selection orelse return;
        const item: *gobject.Object = @ptrCast(@alignCast(gio.ListModel.getItem(selection.as(gio.ListModel), position) orelse return));
        defer item.unref();
        const app = gobject.ext.cast(AppstreamAppObject, item) orelse return;
        self.show_details(app);
    }

    fn on_back_clicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.show_list();
    }

    fn on_description_reveal_clicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const p = self.priv();
        const revealed = gtk.Revealer.getRevealChild(p.description_revealer) != 0;
        gtk.Revealer.setRevealChild(p.description_revealer, @intFromBool(!revealed));
        gtk.Button.setLabel(p.description_reveal_button, if (revealed) translations._("Show more") else translations._("Show less"));
    }

    fn on_install_clicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const p = self.priv();
        const app = p.selected_app orelse return;
        const remotes = app.getRemotes();
        const selected: usize = @intCast(gtk.DropDown.getSelected(p.overlay_remote_selection));
        if (selected >= remotes.len) return;
        const remote = remotes[selected];
        std.log.info("Flatpak install stub: app={s} remote={s} scope={s}", .{
            app.getId(),
            remote.Name,
            if (remote.Scope == .user) "user" else "system",
        });

        const argv = ShellyCommands.install_flatpak(std.heap.c_allocator, app.getId(), remote.Scope) catch return;
        defer std.mem.Allocator.free(std.heap.c_allocator, argv);

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(std.heap.c_allocator);

        names.append(std.heap.c_allocator, app.getName()) catch {};

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = translations._("Installing flatpak"),
                .argv = argv,
                .packages = names.items,
                .on_complete = &on_transaction_complete,
                .privileged = false,
                .ctx = self,
            });
        }
    }

    fn on_transaction_complete(ctx: *anyopaque, success: bool) void {
        const self: *FlatpakInstallView = @ptrCast(@alignCast(ctx));
        if (!success) return;

        gtk.Widget.setSensitive(self.priv().overlay_install_button.as(gtk.Widget), 1);
    }

    fn on_remote_selected(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (self.priv().suppress_remote_notify) return;
        self.request_selected_remote_info();
    }

    fn on_permissions_clicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const app = self.priv().selected_app orelse return;

        const dlg = PermissionsDialog.new(translations._("Permissions"), app.getName(), app.getPermissions(), &on_close, self);
        if (support.getWindow(ShellyWindow, self)) |win| win.showLockout(dlg.as(gtk.Widget));
    }

    fn on_version_history_clicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const app = self.priv().selected_app orelse return;

        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        errdefer {
            for (entries.items) |e| {
                std.heap.c_allocator.free(e.version);
                if (e.note) |n| std.heap.c_allocator.free(n);
            }
            entries.deinit(std.heap.c_allocator);
        }

        for (app.getReleases()) |release| {
            const version = std.heap.c_allocator.dupeZ(u8, release.Version) catch continue;
            const note = std.heap.c_allocator.dupeZ(u8, release.Description) catch {
                std.heap.c_allocator.free(version);
                continue;
            };
            entries.append(std.heap.c_allocator, .{ .version = version, .note = note, .date = "" }) catch {
                std.heap.c_allocator.free(version);
                std.heap.c_allocator.free(note);
                continue;
            };
        }

        const owned = entries.toOwnedSlice(std.heap.c_allocator) catch return;
        const dlg = VersionHistoryDialog.new(translations._("Version History"), app.getName(), owned, &on_close, self);

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.showLockout(dlg.as(gtk.Widget));
        }
    }

    fn on_close(ctx: ?*anyopaque) void {
        const self: *FlatpakInstallView = @ptrCast(@alignCast(ctx.?));

        if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
    }

    fn show_list(self: *Self) void {
        const p = self.priv();
        gtk.Stack.setVisibleChild(p.content_stack, p.list_overlay.as(gtk.Widget));
        self.clear_details();
    }

    fn show_details(self: *Self, app: *AppstreamAppObject) void {
        const p = self.priv();
        self.clear_details();
        p.selected_app = app;
        _ = app.as(gobject.Object).ref();

        gtk.Label.setLabel(p.overlay_name_label, if (app.getName().len > 0) app.getName() else app.getId());
        gtk.Label.setLabel(p.overlay_author_label, if (app.getDeveloperName().len > 0) app.getDeveloperName() else translations._("Unknown developer"));
        set_app_icon(p.overlay_icon, app);

        var version_buffer: [256]u8 = undefined;
        const releases = app.getReleases();
        const version = if (releases.len > 0 and releases[0].Version.len > 0) releases[0].Version else translations._("Unknown");
        gtk.Label.setLabel(p.overlay_version_label, std.fmt.bufPrintZ(&version_buffer, "{s}: {s}", .{ translations._("Version"), version }) catch translations._("Version: Unknown"));

        const remotes = app.getRemotes();
        if (remotes.len > 0) {
            gtk.Label.setLabel(p.overlay_size_label, translations._("Size: Loading..."));
        } else {
            gtk.Label.setLabel(p.overlay_size_label, translations._("Size: Unknown"));
        }

        var license_buffer: [256]u8 = undefined;
        const license = if (app.getProjectLicense().len > 0) app.getProjectLicense() else translations._("Unknown");
        gtk.Label.setLabel(p.overlay_license_label, std.fmt.bufPrintZ(&license_buffer, "{s}: {s}", .{ translations._("License"), license }) catch translations._("License: Unknown"));
        gtk.Label.setLabel(p.overlay_summary_label, if (app.getSummary().len > 0) app.getSummary() else translations._("No summary available"));
        self.populate_remotes(app);
        self.set_description(app.getDescription());
        self.populate_screenshots(app);
        self.populate_links(app);
        gtk.Stack.setVisibleChild(p.content_stack, p.overlay_panel.as(gtk.Widget));
    }

    fn populate_remotes(self: *Self, app: *AppstreamAppObject) void {
        const p = self.priv();
        const strings = gtk.StringList.new(null);
        defer strings.as(gobject.Object).unref();
        const remotes = app.getRemotes();
        std.log.debug("remotes {d}", .{remotes.len});
        for (remotes) |remote| {
            var buffer: [512]u8 = undefined;
            const label = std.fmt.bufPrintZ(
                &buffer,
                "{s} ({s})",
                .{ remote.Name, if (remote.Scope == .user) translations._("user") else translations._("system") },
            ) catch continue;
            gtk.StringList.append(strings, label);
        }
        p.suppress_remote_notify = true;
        defer p.suppress_remote_notify = false;
        gtk.DropDown.setModel(p.overlay_remote_selection, strings.as(gio.ListModel));
        gtk.DropDown.setSelected(p.overlay_remote_selection, 0);
        gtk.Widget.setSensitive(p.overlay_remote_selection.as(gtk.Widget), @intFromBool(remotes.len > 0));
        gtk.Widget.setSensitive(p.overlay_install_button.as(gtk.Widget), @intFromBool(remotes.len > 0));
        if (remotes.len > 0) self.request_remote_info(remotes[0].Name, app);
        gtk.Widget.setVisible(p.overlay_remote_selection.as(gtk.Widget), @intFromBool(remotes.len > 1));
    }

    fn request_selected_remote_info(self: *Self) void {
        const p = self.priv();
        const app = p.selected_app orelse return;
        const remotes = app.getRemotes();
        const selected = gtk.DropDown.getSelected(p.overlay_remote_selection);
        if (selected == std.math.maxInt(u32) or selected >= remotes.len) return;
        self.request_remote_info(remotes[selected].Name, app);
    }

    fn request_remote_info(self: *Self, remote: []const u8, app: *AppstreamAppObject) void {
        const p = self.priv();
        p.remote_info_generation +%= 1;
        const request_generation = p.remote_info_generation;
        gtk.Label.setLabel(p.overlay_size_label, translations._("Size: Loading..."));

        const load = std.heap.c_allocator.create(RemoteInfoLoad) catch {
            gtk.Label.setLabel(p.overlay_size_label, translations._("Size: Unavailable"));
            return;
        };
        const owned_remote = std.heap.c_allocator.dupeZ(u8, remote) catch {
            std.heap.c_allocator.destroy(load);
            gtk.Label.setLabel(p.overlay_size_label, translations._("Size: Unavailable"));
            return;
        };
        const owned_app_id = std.heap.c_allocator.dupeZ(u8, app.getId()) catch {
            std.heap.c_allocator.free(owned_remote);
            std.heap.c_allocator.destroy(load);
            gtk.Label.setLabel(p.overlay_size_label, translations._("Size: Unavailable"));
            return;
        };
        load.* = .{
            .page = self,
            .details_generation = p.details_generation,
            .request_generation = request_generation,
            .remote = owned_remote,
            .app = app,
            .app_id = owned_app_id,
        };
        _ = self.as(gobject.Object).ref();
        const thread = std.Thread.spawn(.{}, remote_info_worker, .{load}) catch {
            cleanup_remote_info_load(load);
            gtk.Label.setLabel(p.overlay_size_label, translations._("Size: Unavailable"));
            return;
        };
        thread.detach();
    }

    fn remote_info_worker(load: *RemoteInfoLoad) void {
        var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
        defer threaded.deinit();
        const cli: ShellyCli = .{ .allocator = std.heap.c_allocator, .io = threaded.io() };
        const parsed = cli.get_flatpak_remote_info(load.remote, load.app_id, default_branch) catch {
            load.failed = true;
            _ = glib.idleAdd(&remote_info_complete, load);
            return;
        };

        defer parsed.deinit();
        if (parsed.value.hits.len == 0) {
            load.failed = true;
            _ = glib.idleAdd(&remote_info_complete, load);
            return;
        }
        load.download_size = parsed.value.hits[0].download_size;
        load.installed_size = parsed.value.hits[0].installed_size;
        load.permissions = parsed.value.hits[0].permissions;

        _ = glib.idleAdd(&remote_info_complete, load);
    }

    fn remote_info_complete(data: ?*anyopaque) callconv(.c) c_int {
        const load: *RemoteInfoLoad = @ptrCast(@alignCast(data orelse return 0));
        const p = load.page.priv();
        if (!p.disposed and p.selected_app != null and
            p.details_generation == load.details_generation and
            p.remote_info_generation == load.request_generation)
        {
            if (load.failed) {
                gtk.Label.setLabel(p.overlay_size_label, translations._("Size: Unavailable"));
            } else {
                var download_buffer: [64]u8 = undefined;
                var installed_buffer: [64]u8 = undefined;
                var label_buffer: [192]u8 = undefined;
                const download = SizeConverter.convert_null_term(&download_buffer, load.download_size);
                const installed = SizeConverter.convert_null_term(&installed_buffer, load.installed_size);
                const label = std.fmt.bufPrintZ(
                    &label_buffer,
                    "{s}: {s}  •  {s}: {s}",
                    .{ translations._("Download"), download, translations._("Installed"), installed },
                ) catch translations._("Size: Unavailable");
                gtk.Widget.setSensitive(p.overlay_permissions_button.as(gtk.Widget), 1);
                gtk.Label.setLabel(p.overlay_size_label, label);
                load.app.setPermissions(load.permissions);
            }
        }
        cleanup_remote_info_load(load);
        return 0;
    }

    fn cleanup_remote_info_load(load: *RemoteInfoLoad) void {
        load.page.as(gobject.Object).unref();
        std.heap.c_allocator.free(load.remote);
        std.heap.c_allocator.free(load.app_id);
        std.heap.c_allocator.destroy(load);
    }

    fn set_description(self: *Self, description: [:0]const u8) void {
        const p = self.priv();
        if (description_split_index(description)) |index| {
            const preview = g_strndup(description.ptr, index);
            defer glib.free(preview);
            gtk.Label.setLabel(p.overlay_description_label, preview);
            gtk.Label.setLabel(p.overlay_description_label_full, description[index + 1 ..]);
            gtk.Widget.setVisible(p.description_reveal_button.as(gtk.Widget), 1);
        } else {
            gtk.Label.setLabel(p.overlay_description_label, if (description.len > 0) description else translations._("No description available."));
            gtk.Label.setLabel(p.overlay_description_label_full, "");
            gtk.Widget.setVisible(p.description_reveal_button.as(gtk.Widget), 1);
        }
        gtk.Revealer.setRevealChild(p.description_revealer, 0);
        gtk.Button.setLabel(p.description_reveal_button, translations._("Show more"));
    }

    fn populate_screenshots(self: *Self, app: *AppstreamAppObject) void {
        const p = self.priv();
        const carousel = Carousel.new();
        var count: usize = 0;
        for (app.getScreenshots()) |screenshot| {
            const screenshot_url = first_screenshot_url(screenshot) orelse continue;
            const picture = gtk.Picture.new();
            gtk.Picture.setCanShrink(picture, 1);
            gtk.Picture.setContentFit(picture, .contain);
            gtk.Widget.setSizeRequest(picture.as(gtk.Widget), -1, 584);
            gtk.Widget.setHexpand(picture.as(gtk.Widget), 1);
            gtk.Widget.setVexpand(picture.as(gtk.Widget), 1);
            gtk.Widget.setHalign(picture.as(gtk.Widget), .center);
            gtk.Widget.setValign(picture.as(gtk.Widget), .center);
            carousel.addWidget(picture.as(gtk.Widget));
            self.load_screenshot(picture, screenshot_url, p.details_generation);
            count += 1;
        }

        if (count == 0) {
            carousel.as(gobject.Object).unref();
            gtk.Widget.setVisible(p.overlay_screenshots_container.as(gtk.Widget), 0);
            return;
        }
        gtk.Widget.setVisible(p.overlay_screenshots_container.as(gtk.Widget), 1);
        gtk.Box.append(p.overlay_screenshots_container, carousel.as(gtk.Widget));
        const dots = CarouselIndicatorDots.new(carousel);
        gtk.Box.append(p.overlay_screenshots_container, dots.as(gtk.Widget));
    }

    fn load_screenshot(self: *Self, picture: *gtk.Picture, url: [:0]const u8, generation: u64) void {
        const load = std.heap.c_allocator.create(ScreenshotLoad) catch {
            gtk.Widget.setTooltipText(picture.as(gtk.Widget), translations._("Unable to load screenshot"));
            return;
        };
        const owned_url = std.heap.c_allocator.dupeZ(u8, url) catch {
            std.heap.c_allocator.destroy(load);
            gtk.Widget.setTooltipText(picture.as(gtk.Widget), translations._("Unable to load screenshot"));
            return;
        };
        load.* = .{
            .page = self,
            .picture = picture,
            .generation = generation,
            .url = owned_url,
        };
        _ = self.as(gobject.Object).ref();
        _ = picture.as(gobject.Object).ref();
        const thread = std.Thread.spawn(.{}, screenshot_worker, .{load}) catch {
            cleanup_screenshot_load(load);
            gtk.Widget.setTooltipText(picture.as(gtk.Widget), translations._("Unable to load screenshot"));
            return;
        };
        thread.detach();
    }

    fn screenshot_worker(load: *ScreenshotLoad) void {
        var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
        defer threaded.deinit();
        const bytes = download_screenshot(threaded.io(), load.url) catch {
            load.failed = true;
            _ = glib.idleAdd(&screenshot_complete, load);
            return;
        };
        load.data = bytes;
        _ = glib.idleAdd(&screenshot_complete, load);
    }

    // Downloads the screenshot fully into memory rather than caching it on
    // disk. The returned buffer is owned by the caller and must be freed with
    // the C allocator once the texture has been created from it.
    fn download_screenshot(io: std.Io, url: []const u8) ![]u8 {
        var allocating: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
        errdefer allocating.deinit();

        var client: HttpClient = .{
            .allocator = std.heap.c_allocator,
            .io = io,
        };
        defer client.deinit();

        const response = try client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &allocating.writer,
        });
        if (response.status.class() != .success) return error.HttpStatusNotSuccessful;
        return try allocating.toOwnedSlice();
    }

    fn screenshot_complete(data: ?*anyopaque) callconv(.c) c_int {
        const load: *ScreenshotLoad = @ptrCast(@alignCast(data orelse return 0));
        const p = load.page.priv();
        if (!p.disposed and p.selected_app != null and p.details_generation == load.generation) {
            if (load.failed or load.data == null) {
                gtk.Picture.setPaintable(load.picture, null);
                gtk.Widget.setTooltipText(load.picture.as(gtk.Widget), translations._("Unable to download screenshot"));
            } else if (texture_from_bytes(load.data.?)) |texture| {
                gtk.Picture.setPaintable(load.picture, texture.as(gdk.Paintable));
                texture.unref();
                gtk.Widget.setTooltipText(load.picture.as(gtk.Widget), null);
            } else {
                gtk.Picture.setPaintable(load.picture, null);
                gtk.Widget.setTooltipText(load.picture.as(gtk.Widget), translations._("Unable to display screenshot"));
            }
        }
        cleanup_screenshot_load(load);
        return 0;
    }

    // Decodes the in-memory image bytes into a GdkTexture. The picture keeps its
    // own reference to the texture, so the raw bytes can be freed immediately
    // afterwards and nothing is left behind on disk.
    fn texture_from_bytes(data: []const u8) ?*gdk.Texture {
        const bytes = glib.Bytes.new(data.ptr, data.len);
        defer bytes.unref();
        return gdk.Texture.newFromBytes(bytes, null);
    }

    fn cleanup_screenshot_load(load: *ScreenshotLoad) void {
        load.picture.as(gobject.Object).unref();
        load.page.as(gobject.Object).unref();
        std.heap.c_allocator.free(load.url);
        if (load.data) |bytes| std.heap.c_allocator.free(bytes);
        std.heap.c_allocator.destroy(load);
    }

    fn populate_links(self: *Self, app: *AppstreamAppObject) void {
        var iterator = app.getUrls().map.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.*.len == 0) continue;

            const row = gtk.ListBoxRow.new();
            const content = gtk.Box.new(.horizontal, 6);
            gtk.Widget.setMarginTop(content.as(gtk.Widget), 8);
            gtk.Widget.setMarginBottom(content.as(gtk.Widget), 8);
            gtk.Widget.setMarginStart(content.as(gtk.Widget), 6);
            gtk.Widget.setMarginEnd(content.as(gtk.Widget), 6);

            const icon = gtk.Image.newFromIconName(icon_for_url_type(entry.key_ptr.*));
            gtk.Widget.setMarginStart(icon.as(gtk.Widget), 6);
            gtk.Widget.setMarginEnd(icon.as(gtk.Widget), 6);
            gtk.Widget.setValign(icon.as(gtk.Widget), .center);
            gtk.Box.append(content, icon.as(gtk.Widget));

            const labels = gtk.Box.new(.vertical, 2);
            gtk.Widget.setHalign(labels.as(gtk.Widget), .start);
            gtk.Widget.setValign(labels.as(gtk.Widget), .center);

            var type_buffer: [128]u8 = undefined;
            const type_label = gtk.Label.new(format_url_type(&type_buffer, entry.key_ptr.*));
            gtk.Widget.setHalign(type_label.as(gtk.Widget), .start);
            gtk.Label.setXalign(type_label, 0);
            gtk.Box.append(labels, type_label.as(gtk.Widget));

            const url_label = gtk.Label.new(@ptrCast(entry.value_ptr.*.ptr));
            gtk.Widget.addCssClass(url_label.as(gtk.Widget), "dim-label");
            gtk.Widget.addCssClass(url_label.as(gtk.Widget), "caption");
            gtk.Widget.setHalign(url_label.as(gtk.Widget), .start);
            gtk.Label.setXalign(url_label, 0);
            gtk.Label.setSelectable(url_label, 1);
            gtk.Box.append(labels, url_label.as(gtk.Widget));
            gtk.Box.append(content, labels.as(gtk.Widget));

            const spacer = gtk.Box.new(.horizontal, 0);
            gtk.Widget.setHexpand(spacer.as(gtk.Widget), 1);
            gtk.Box.append(content, spacer.as(gtk.Widget));

            const open_link = gtk.LinkButton.newWithLabel(@ptrCast(entry.value_ptr.*.ptr), "");
            gtk.Button.setIconName(open_link.as(gtk.Button), "web-browser");
            gtk.Widget.setHalign(open_link.as(gtk.Widget), .end);
            gtk.Widget.setValign(open_link.as(gtk.Widget), .center);
            gtk.Widget.setTooltipText(open_link.as(gtk.Widget), translations._("Open link in browser"));
            gtk.Box.append(content, open_link.as(gtk.Widget));

            gtk.ListBoxRow.setChild(row, content.as(gtk.Widget));
            gtk.ListBox.append(self.priv().overlay_links_box, row.as(gtk.Widget));
        }
    }

    fn icon_for_url_type(url_type: []const u8) [:0]const u8 {
        if (std.ascii.eqlIgnoreCase(url_type, "homepage")) return "go-home";
        if (std.ascii.eqlIgnoreCase(url_type, "bugtracker")) return "dialog-warning";
        if (std.ascii.eqlIgnoreCase(url_type, "donation")) return "emblem-favorite";
        if (std.ascii.eqlIgnoreCase(url_type, "faq")) return "help-faq";
        if (std.ascii.eqlIgnoreCase(url_type, "help")) return "help-browser";
        if (std.ascii.eqlIgnoreCase(url_type, "vcs-browser")) return "folder-saved-search";
        if (std.ascii.eqlIgnoreCase(url_type, "contact")) return "mail-send-receive";
        if (std.ascii.eqlIgnoreCase(url_type, "translate")) return "accessories-dictionary";
        return "web-browser";
    }

    fn format_url_type(buffer: *[128]u8, url_type: []const u8) [:0]const u8 {
        if (url_type.len == 0) return "";
        if (std.ascii.eqlIgnoreCase(url_type, "homepage")) return translations._("Homepage");
        if (std.ascii.eqlIgnoreCase(url_type, "bugtracker")) return translations._("Bug tracker");
        if (std.ascii.eqlIgnoreCase(url_type, "donation")) return translations._("Donation");
        if (std.ascii.eqlIgnoreCase(url_type, "faq")) return translations._("FAQ");
        if (std.ascii.eqlIgnoreCase(url_type, "help")) return translations._("Help");
        if (std.ascii.eqlIgnoreCase(url_type, "vcs-browser")) return translations._("Vcs-browser");
        if (std.ascii.eqlIgnoreCase(url_type, "contact")) return translations._("Contact");
        if (std.ascii.eqlIgnoreCase(url_type, "translate")) return translations._("Translate");
        const len = @min(url_type.len, buffer.len - 1);
        @memcpy(buffer[0..len], url_type[0..len]);
        buffer[0] = std.ascii.toUpper(buffer[0]);
        buffer[len] = 0;
        return buffer[0..len :0];
    }

    fn clear_details(self: *Self) void {
        const p = self.priv();
        p.details_generation +%= 1;
        p.remote_info_generation +%= 1;
        while (gtk.Widget.getFirstChild(p.overlay_screenshots_container.as(gtk.Widget))) |child| {
            gtk.Box.remove(p.overlay_screenshots_container, child);
        }
        gtk.DropDown.setModel(p.overlay_remote_selection, null);
        gtk.Widget.setSensitive(p.overlay_remote_selection.as(gtk.Widget), 0);
        gtk.Widget.setSensitive(p.overlay_install_button.as(gtk.Widget), 0);
        gtk.Widget.setSensitive(p.overlay_permissions_button.as(gtk.Widget), 0);
        gtk.ListBox.removeAll(p.overlay_links_box);
        if (p.selected_app) |app| {
            app.as(gobject.Object).unref();
            p.selected_app = null;
        }
    }

    fn filter_app(item: *gobject.Object, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        const p = self.priv();
        const app = gobject.ext.cast(AppstreamAppObject, item) orelse return 0;

        switch (p.category) {
            .@"All Applications" => {},

            .@"Most Wanted" => if (!app.getMembership().contains(.trending)) return 0,
            .Recommended => if (!app.getMembership().contains(.popular)) return 0,
            .@"Recently Updated" => if (!app.getMembership().contains(.recently_updated)) return 0,
            .@"Recently Added" => if (!app.getMembership().contains(.recently_added)) return 0,

            else => {
                const categories = app.getCategories();
                var found_match = false;
                for (categories) |cat| {
                    if (std.mem.indexOf(u8, cat, p.category.toString()) != null) {
                        found_match = true;
                        break;
                    }
                }
                if (!found_match) return 0;
            },
        }

        const query = p.search_text[0..p.search_len];
        return @intFromBool(search.matchesAnyIgnoreCase(query, &.{ app.getName(), app.getId(), app.getSummary() }));
    }

    pub fn apply_search(self: *Self, text: []const u8) void {
        const p = self.priv();
        const len = @min(text.len, p.search_text.len);
        @memcpy(p.search_text[0..len], text[0..len]);
        p.search_len = len;
        if (p.filter) |filter| gtk.Filter.changed(filter.as(gtk.Filter), .different);
    }

    pub fn apply_category(self: *Self, category: Category) void {
        const p = self.priv();
        p.category = category;
        self.show_list();
        if (p.filter) |filter| gtk.Filter.changed(filter.as(gtk.Filter), .different);
    }

    fn set_app_icon(icon: *gtk.Image, object: *AppstreamAppObject) void {
        const remotes = object.getRemotes();
        if (remotes.len == 0 or object.getId().len == 0) {
            gtk.Image.setFromIconName(icon, "package-x-generic");
            return;
        }

        const remote = remotes[0];
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = if (remote.Scope == .user)
            std.fmt.bufPrintZ(&path_buffer, "{s}/flatpak/appstream/{s}/x86_64/active/icons/64x64/{s}.png", .{ g_get_user_data_dir(), remote.Name, object.getId() }) catch null
        else
            std.fmt.bufPrintZ(&path_buffer, "/var/lib/flatpak/appstream/{s}/x86_64/active/icons/64x64/{s}.png", .{ remote.Name, object.getId() }) catch null;

        if (path) |value| {
            if (g_file_test(value.ptr, 1 << 4) != 0) {
                gtk.Image.setFromFile(icon, value);
                return;
            }
        }
        gtk.Image.setFromIconName(icon, "package-x-generic");
    }

    fn load_apps(self: *Self, generation: u64) void {
        const p = self.priv();
        if (p.model) |model| gio.ListStore.removeAll(model);
        gtk.Label.setLabel(p.loading_label, translations._("Loading Flatpak Data..."));
        gtk.Widget.setVisible(p.loading_spinner.as(gtk.Widget), 1);
        gtk.Spinner.start(p.loading_spinner);
        gtk.Widget.setVisible(p.loading_overlay.as(gtk.Widget), 1);

        const result = std.heap.c_allocator.create(LoadResult) catch {
            self.show_status(translations._("Unable to allocate memory while loading Flatpak data."), false);
            return;
        };
        result.* = .{ .page = self, .generation = generation };
        _ = self.as(gobject.Object).ref();

        const thread = std.Thread.spawn(.{}, load_worker, .{result}) catch {
            self.as(gobject.Object).unref();
            std.heap.c_allocator.destroy(result);
            self.show_status(translations._("Unable to start the Flatpak data loader."), false);
            return;
        };
        thread.detach();
    }

    fn load_worker(result: *LoadResult) void {
        const arena = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch {
            result.failed = true;
            _ = glib.idleAdd(&load_complete, result);
            return;
        };
        arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        result.arena = arena;
        const alloc = arena.allocator();

        var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const cli: ShellyCli = .{ .allocator = alloc, .io = io };
        cli.sync_remote_appstream_flatpak() catch {};
        std.log.debug("sync_remote_appstream_flatpak completed", .{});
        result.parsed = cli.get_remote_appstream_apps() catch {
            result.failed = true;
            _ = glib.idleAdd(&load_complete, result);
            return;
        };

        var flathub = FlatHubApiService.init(std.heap.c_allocator, io);
        defer flathub.deinit();

        result.trending_set = collectionSet(alloc, &flathub, .trending);
        result.popular_set = collectionSet(alloc, &flathub, .popular);
        result.recently_updated_set = collectionSet(alloc, &flathub, .recently_updated);
        result.recently_added_set = collectionSet(alloc, &flathub, .recently_added);

        _ = glib.idleAdd(&load_complete, result);
    }

    fn collectionSet(alloc: std.mem.Allocator, flathub: *FlatHubApiService, which: AppstreamAppObject.Collection) std.StringHashMapUnmanaged(void) {
        const ids = switch (which) {
            .trending => flathub.getCollectionTrending(1, 20),
            .popular => flathub.getCollectionPopular(1, 20),
            .recently_updated => flathub.getCollectionRecentlyUpdated(1, 20),
            .recently_added => flathub.getCollectionRecentlyAdded(1, 20),
        } catch return .empty;

        var set: std.StringHashMapUnmanaged(void) = .empty;
        set.ensureTotalCapacity(alloc, @intCast(ids.len)) catch return .empty;
        for (ids) |id| {
            const owned = alloc.dupe(u8, id) catch continue;
            set.putAssumeCapacity(owned, {});
        }
        return set;
    }

    fn load_complete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *LoadResult = @ptrCast(@alignCast(data orelse return 0));
        const page = result.page;
        const p = page.priv();
        if (p.disposed or !p.loaded or p.load_generation != result.generation) {
            cleanup_result(result);
            return 0;
        }
        if (result.failed or result.parsed == null) {
            page.show_status(translations._("Unable to load Flatpak applications."), false);
            cleanup_result(result);
            return 0;
        }

        const apps = result.parsed.?.value;
        const end = @min(result.next_index + batch_size, apps.len);
        const model = p.model orelse {
            cleanup_result(result);
            return 0;
        };
        for (apps[result.next_index..end]) |app| {
            const object = AppstreamAppObject.new(app) catch continue;

            var membership: AppstreamAppObject.Membership = .{};
            if (result.trending_set.contains(app.Id)) membership.insert(.trending);
            if (result.popular_set.contains(app.Id)) membership.insert(.popular);
            if (result.recently_updated_set.contains(app.Id)) membership.insert(.recently_updated);
            if (result.recently_added_set.contains(app.Id)) membership.insert(.recently_added);
            object.setMembership(membership);

            gio.ListStore.append(model, object.as(gobject.Object));
            object.as(gobject.Object).unref();
        }
        result.next_index = end;
        if (end < apps.len) return 1;

        if (gio.ListModel.getNItems(model.as(gio.ListModel)) == 0) {
            page.show_status(translations._("No Flatpak applications are available."), false);
        } else {
            gtk.Spinner.stop(p.loading_spinner);
            gtk.Widget.setVisible(p.loading_overlay.as(gtk.Widget), 0);
        }
        cleanup_result(result);
        return 0;
    }

    fn show_status(self: *Self, message: [:0]const u8, spinning: bool) void {
        const p = self.priv();
        gtk.Label.setLabel(p.loading_label, message);
        gtk.Widget.setVisible(p.loading_spinner.as(gtk.Widget), @intFromBool(spinning));
        if (spinning) gtk.Spinner.start(p.loading_spinner) else gtk.Spinner.stop(p.loading_spinner);
        gtk.Widget.setVisible(p.loading_overlay.as(gtk.Widget), 1);
    }

    fn cleanup_result(result: *LoadResult) void {
        if (result.parsed) |*parsed| parsed.deinit();
        if (result.arena) |arena| {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
        }
        result.page.as(gobject.Object).unref();
        std.heap.c_allocator.destroy(result);
    }

    fn dispose(object: *gobject.Object) callconv(.c) void {
        const self = gobject.ext.cast(Self, object) orelse {
            gobject.ext.as(gobject.Object.Class, Class.parent).f_dispose.?(object);
            return;
        };
        const p = self.priv();
        if (!p.disposed) {
            p.disposed = true;
            p.loaded = false;
            p.load_generation +%= 1;

            self.clear_details();
            gtk.GridView.setModel(p.list_flatpaks, null);
            gtk.GridView.setFactory(p.list_flatpaks, null);
            if (p.selection) |selection| {
                selection.as(gobject.Object).unref();
                p.selection = null;
            }
            if (p.filter) |filter| {
                filter.as(gobject.Object).unref();
                p.filter = null;
            }
            if (p.model) |model| {
                gio.ListStore.removeAll(model);
                model.as(gobject.Object).unref();
                p.model = null;
            }
        }
        gobject.ext.as(gobject.Object.Class, Class.parent).f_dispose.?(object);
    }

    const template_children = .{
        .{ "content_stack", @offsetOf(Private, "content_stack") },
        .{ "list_overlay", @offsetOf(Private, "list_overlay") },
        .{ "list_flatpaks", @offsetOf(Private, "list_flatpaks") },
        .{ "loading_overlay", @offsetOf(Private, "loading_overlay") },
        .{ "loading_spinner", @offsetOf(Private, "loading_spinner") },
        .{ "loading_label", @offsetOf(Private, "loading_label") },
        .{ "overlay_panel", @offsetOf(Private, "overlay_panel") },
        .{ "overlay_back_button", @offsetOf(Private, "overlay_back_button") },
        .{ "overlay_icon", @offsetOf(Private, "overlay_icon") },
        .{ "overlay_name_label", @offsetOf(Private, "overlay_name_label") },
        .{ "overlay_author_label", @offsetOf(Private, "overlay_author_label") },
        .{ "overlay_version_label", @offsetOf(Private, "overlay_version_label") },
        .{ "overlay_size_label", @offsetOf(Private, "overlay_size_label") },
        .{ "overlay_license_label", @offsetOf(Private, "overlay_license_label") },
        .{ "overlay_screenshots_container", @offsetOf(Private, "overlay_screenshots_container") },
        .{ "overlay_summary_label", @offsetOf(Private, "overlay_summary_label") },
        .{ "overlay_description_label", @offsetOf(Private, "overlay_description_label") },
        .{ "overlay_description_label_full", @offsetOf(Private, "overlay_description_label_full") },
        .{ "description_revealer", @offsetOf(Private, "description_revealer") },
        .{ "description_reveal_button", @offsetOf(Private, "description_reveal_button") },
        .{ "overlay_remote_selection", @offsetOf(Private, "overlay_remote_selection") },
        .{ "overlay_install_button", @offsetOf(Private, "overlay_install_button") },
        .{ "overlay_permissions_button", @offsetOf(Private, "overlay_permissions_button") },
        .{ "version_history_button", @offsetOf(Private, "version_history_button") },
        .{ "overlay_links_box", @offsetOf(Private, "overlay_links_box") },
    };

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            const wc = gobject.ext.as(gtk.Widget.Class, class);
            gtk.Widget.Class.setTemplateFromResource(wc, resource_path);
            inline for (template_children) |c| {
                support.bindChild(class, Private.offset, c[0], c[1]);
            }
            const object_class = gobject.ext.as(gobject.Object.Class, class);
            object_class.f_dispose = &dispose;
        }
    };
};

fn description_split_index(description: []const u8) ?usize {
    var newline_count: usize = 0;
    for (description, 0..) |character, index| {
        if (character != '\n') continue;
        newline_count += 1;
        if (newline_count == 3 and index + 1 < description.len) return index;
    }
    return null;
}

fn first_screenshot_url(screenshot: flatpak.AppstreamScreenshot) ?[:0]const u8 {
    for (screenshot.Images) |image| {
        if (image.Url.len > 0) return image.Url.ptr[0..image.Url.len :0];
    }
    return null;
}

test "Flatpak details split descriptions only when additional lines exist" {
    try std.testing.expectEqual(@as(?usize, 13), description_split_index("one\ntwo\nthree\nfour"));
    try std.testing.expectEqual(@as(?usize, null), description_split_index("one\ntwo\nthree"));
    try std.testing.expectEqual(@as(?usize, null), description_split_index("one\ntwo\nthree\n"));
}

test "Flatpak details find the first usable screenshot URL" {
    const no_images: flatpak.AppstreamScreenshot = .{};
    try std.testing.expect(first_screenshot_url(no_images) == null);

    const images = [_]flatpak.AppstreamImage{
        .{},
        .{ .Url = "https://example.test/screenshot.png" },
    };
    const screenshot: flatpak.AppstreamScreenshot = .{ .Images = &images };
    try std.testing.expectEqualStrings("https://example.test/screenshot.png", first_screenshot_url(screenshot).?);
}

test "Flatpak details map AppStream URL types to C# icons" {
    try std.testing.expectEqualStrings("go-home", FlatpakInstallView.icon_for_url_type("Homepage"));
    try std.testing.expectEqualStrings("dialog-warning", FlatpakInstallView.icon_for_url_type("bugtracker"));
    try std.testing.expectEqualStrings("folder-saved-search", FlatpakInstallView.icon_for_url_type("vcs-browser"));
    try std.testing.expectEqualStrings("web-browser", FlatpakInstallView.icon_for_url_type("unknown"));
}

test "Flatpak details capitalize AppStream URL type labels" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Homepage", FlatpakInstallView.format_url_type(&buffer, "homepage"));
    try std.testing.expectEqualStrings("Vcs-browser", FlatpakInstallView.format_url_type(&buffer, "vcs-browser"));
    try std.testing.expectEqualStrings("", FlatpakInstallView.format_url_type(&buffer, ""));
}
