const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const glib = bindings.glib;
const gobject = bindings.gobject;
const support = @import("support.zig");
const Toast = @import("../helpers/custom_ui_comps/toast.zig").Toast;
const c_string = @import("../helpers/c_string.zig");
const a11y = @import("../helpers/a11y.zig");
const translations = @import("../helpers/translations.zig");
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const package_lists = @import("../services/package_lists.zig");
const IconResolver = @import("../services/icon_resolver.zig").IconResolver;
const Package = @import("../models/packages.zig").Package;
const RecommendCategory = @import("../models/recommendation.zig").RecommendCategory;
const recommendations = @import("../services/recommendations.zig");
const runtime = @import("../services/runtime.zig");

pub const RecommendPage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "Recommended";
    pub const icon_name: [:0]const u8 = "star-filled-rounded-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/recommend_page.ui";

    const Private = struct {
        refresh_button: *gtk.Button,
        recommend_stack: *gtk.Stack,
        loading_page: *gtk.Box,
        loading_spinner: *gtk.Spinner,
        list_page: *gtk.ScrolledWindow,
        content_box: *gtk.Box,
        empty_page: *gtk.Box,
        selected_label: *gtk.Label,
        clear_button: *gtk.Button,
        install_selected_button: *gtk.Button,
        page_overlay: *gtk.Overlay,
        toast: *Toast,

        resolver: IconResolver,
        arena: ?*std.heap.ArenaAllocator,
        generation: u64,
        loaded: bool,
        loading: bool,
        spinner_source: c_uint,
        // hash of the sections the cards show, 0 without cards.
        shown_hash: u64,

        // Packages picked up for a batch install, keyed by name. The keys are
        // owned by the c allocator because the page arena they were read from
        // is torn down on every reload while the selection outlives it.
        selection: std.StringHashMapUnmanaged(void) = .empty,
        // Check buttons of the cards currently on screen. Cards are destroyed
        // and rebuilt whenever the list reloads, so this lives only as long
        // as the current cards do.
        checks: std.ArrayListUnmanaged(*gtk.CheckButton) = .empty,

        var offset: c_int = 0;
    };

    const CategorySection = struct {
        name: []const u8,
        packages: []Package,
    };

    const LoadJob = struct {
        page: *Self,
        generation: u64,
        force: bool,
        show_saved: bool,
        load_icons: bool,
    };

    const LoadResult = struct {
        page: *Self,
        categories: []CategorySection,
        arena: ?*std.heap.ArenaAllocator,
        resolver: ?IconResolver,
        generation: u64,
        // no newer listing follows this one.
        last: bool,
        failed: bool,
    };

    const spinner_delay_ms = 300;

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyRecommendPage",
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
        p.loaded = false;
        p.loading = false;
        p.spinner_source = 0;
        p.shown_hash = 0;
        p.arena = null;
        p.generation = 0;
        p.resolver = IconResolver.init(std.heap.c_allocator);

        const toast = Toast.new();
        gtk.Overlay.addOverlay(p.page_overlay, toast.as(gtk.Widget));
        p.toast = toast;

        support.connectLifecycle(Self, self);
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
        triggerReload(self, false, true);
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;
        p.generation += 1;
        self.cancel_spinner();
        p.loading = false;
        p.shown_hash = 0;

        while (gtk.Widget.getFirstChild(p.content_box.as(gtk.Widget))) |c| {
            gtk.Box.remove(p.content_box, c);
        }
        // The cards are gone, so their check buttons must not be reached
        // again, and the selection resets with the rest of the page.
        p.checks.clearRetainingCapacity();
        self.clear_selection();

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }

        p.resolver.deinit();
        p.resolver = IconResolver.init(std.heap.c_allocator);
    }

    extern fn malloc_trim(pad: usize) c_int;

    fn load_worker(job: LoadJob) void {
        // a listing needs much more memory than its rows; give the rest back.
        defer _ = malloc_trim(0);
        const alloc = std.heap.c_allocator;
        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();
        const cli = ShellyCli{ .allocator = alloc, .io = threaded.io() };

        var category_arena: std.heap.ArenaAllocator = .init(alloc);
        defer category_arena.deinit();
        const categories = if (job.force)
            recommendations.reload(category_arena.allocator(), threaded.io(), runtime.environ_map)
        else
            recommendations.load(category_arena.allocator(), threaded.io(), runtime.environ_map);

        var resolver: ?IconResolver = null;
        if (job.load_icons) {
            resolver = IconResolver.init(alloc);
            resolver.?.load(runtime.io, runtime.environ_map) catch {};
        }

        var slot: package_lists.Slot = undefined;
        slot.init(false);
        const saved = slot.read(cli);
        defer if (saved) |list| list.deinit(alloc);
        const saved_hash: ?u64 = if (saved) |list| list.cached.stamp else null;
        if (job.show_saved) {
            if (saved) |list| post_lists(job, categories, list.parsed.value, &resolver, false);
        }

        const fetched = package_lists.fetch(cli, false) catch {
            post_result(job, &.{}, null, &resolver, true, true);
            return;
        };
        defer fetched.deinit();
        const lists = fetched.lists();
        post_lists(job, categories, lists, &resolver, true);
        slot.update(cli, lists, lists.hash(), saved_hash);
    }

    fn post_lists(
        job: LoadJob,
        categories: []const RecommendCategory,
        lists: package_lists.PackageLists,
        resolver: *?IconResolver,
        last: bool,
    ) void {
        const arena = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena.* = .init(std.heap.c_allocator);
        const sections = make_sections(arena.allocator(), categories, lists) catch {
            free_arena(arena);
            if (last) post_result(job, &.{}, null, resolver, true, true);
            return;
        };
        // without the installed packages every card would offer an install.
        post_result(job, sections, arena, resolver, last, lists.Installed == null);
    }

    /// the sections own their strings, so the lists can be freed after this.
    fn make_sections(
        alloc: std.mem.Allocator,
        categories: []const RecommendCategory,
        lists: package_lists.PackageLists,
    ) ![]CategorySection {
        var scratch: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
        defer scratch.deinit();

        var installed: std.StringHashMapUnmanaged(void) = .empty;
        if (lists.Installed) |rows| {
            for (rows) |row| try installed.put(scratch.allocator(), row.Name, {});
        }
        var available: std.StringHashMapUnmanaged(*const package_lists.PackageRow) = .empty;
        for (lists.Available) |*row| {
            // repository copies come in priority order; keep the first.
            const entry = try available.getOrPut(scratch.allocator(), row.Name);
            if (!entry.found_existing) entry.value_ptr.* = row;
        }

        var sections: std.ArrayListUnmanaged(CategorySection) = .empty;
        for (categories) |cat| {
            var pkgs: std.ArrayListUnmanaged(Package) = .empty;
            for (cat.packages) |name| {
                const row = available.get(name) orelse continue;
                try pkgs.append(alloc, .{
                    .Name = try alloc.dupe(u8, row.Name),
                    .Version = try alloc.dupe(u8, row.Version),
                    .Description = try alloc.dupe(u8, row.Description),
                    .Installed = installed.contains(name),
                });
            }
            if (pkgs.items.len == 0) continue;
            try sections.append(alloc, .{ .name = try alloc.dupe(u8, cat.name), .packages = pkgs.items });
        }
        return sections.items;
    }

    /// covers everything a card shows, so an equal hash needs no new cards.
    fn sections_hash(sections: []const CategorySection) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        for (sections) |section| {
            std.hash.autoHashStrat(&hasher, section.name, .Deep);
            std.hash.autoHash(&hasher, section.packages.len);
            for (section.packages) |pkg| {
                std.hash.autoHashStrat(&hasher, pkg.Name, .Deep);
                std.hash.autoHashStrat(&hasher, pkg.Version, .Deep);
                std.hash.autoHashStrat(&hasher, pkg.Description, .Deep);
                std.hash.autoHash(&hasher, pkg.Installed);
            }
        }
        return hasher.final();
    }

    fn post_result(
        job: LoadJob,
        categories: []CategorySection,
        arena: ?*std.heap.ArenaAllocator,
        resolver: *?IconResolver,
        last: bool,
        failed: bool,
    ) void {
        const result = std.heap.c_allocator.create(LoadResult) catch {
            if (arena) |a| free_arena(a);
            return;
        };
        result.* = .{
            .page = job.page,
            .categories = categories,
            .arena = arena,
            .resolver = resolver.*,
            .generation = job.generation,
            .last = last,
            .failed = failed,
        };
        resolver.* = null;
        _ = glib.idleAdd(&onLoadComplete, result);
    }

    fn free_result(result: *LoadResult) void {
        if (result.resolver) |*resolver| resolver.deinit();
        if (result.arena) |a| free_arena(a);
        std.heap.c_allocator.destroy(result);
    }

    fn free_arena(arena: *std.heap.ArenaAllocator) void {
        arena.deinit();
        std.heap.c_allocator.destroy(arena);
    }

    fn onLoadComplete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *LoadResult = @ptrCast(@alignCast(data.?));
        defer free_result(result);
        const page = result.page;
        const p = page.priv();

        if (result.generation != p.generation) return 0;

        if (result.last) {
            p.loading = false;
            gtk.Widget.setSensitive(p.refresh_button.as(gtk.Widget), 1);
        }
        if (result.resolver) |resolver| {
            p.resolver.deinit();
            p.resolver = resolver;
            result.resolver = null;
        }

        // a failed reload leaves the cards as they are.
        if (result.failed and p.shown_hash != 0) {
            p.toast.show(.warning, translations._("Had an issue loading your packages. Check if you have a db lock."));
            return 0;
        }
        if (result.categories.len == 0) {
            if (!result.last) return 0;
            clear_cards(page);
            page.cancel_spinner();
            show_empty(page);
            return 0;
        }

        const hash = sections_hash(result.categories);
        if (hash == p.shown_hash) return 0;

        clear_cards(page);
        p.arena = result.arena;
        result.arena = null;
        p.shown_hash = hash;
        buildSections(page, result.categories);
        hide_loading(page);
        return 0;
    }

    /// the cards point into the arena, so both go together.
    fn clear_cards(self: *Self) void {
        const p = self.priv();
        while (gtk.Widget.getFirstChild(p.content_box.as(gtk.Widget))) |c| {
            gtk.Box.remove(p.content_box, c);
        }
        p.checks.clearRetainingCapacity();
        p.shown_hash = 0;
        if (p.arena) |a| free_arena(a);
        p.arena = null;
    }

    fn buildSections(self: *Self, categories: []const CategorySection) void {
        const p = self.priv();
        const sizeGroup = gtk.SizeGroup.new(.horizontal);

        // Prune before the cards are built so every check button shows the
        // final state: names installed since the last listing, or gone from
        // it entirely, cannot reach the batch install.
        const arena = p.arena orelse return;
        var installable: std.StringHashMapUnmanaged(void) = .empty;
        for (categories) |cat| {
            for (cat.packages) |*pkg| {
                if (!pkg.Installed) installable.put(arena.allocator(), pkg.Name, {}) catch {};
            }
        }
        finalize_selection(self, &installable);

        for (categories) |cat| {
            const section = gtk.Box.new(.vertical, 6);

            var nbuf: [256]u8 = undefined;
            const header = gtk.Label.new(c_string.cstr(&nbuf, cat.name));
            gtk.Widget.setHalign(header.as(gtk.Widget), .start);
            gtk.Widget.addCssClass(header.as(gtk.Widget), "title-4");
            gtk.Box.append(section, header.as(gtk.Widget));

            const flow = gtk.FlowBox.new();
            gtk.FlowBox.setSelectionMode(flow, .none);
            gtk.FlowBox.setColumnSpacing(flow, 8);
            gtk.FlowBox.setRowSpacing(flow, 8);
            gtk.FlowBox.setHomogeneous(flow, 1);
            gtk.FlowBox.setMinChildrenPerLine(flow, 1);
            gtk.FlowBox.setMaxChildrenPerLine(flow, 6);

            for (cat.packages) |*pkg| {
                const card = makeCard(self, pkg);
                gtk.SizeGroup.addWidget(sizeGroup, card.as(gtk.Widget));
                gtk.FlowBox.append(flow, card.as(gtk.Widget));
            }

            gtk.Box.append(section, flow.as(gtk.Widget));
            gtk.Box.append(p.content_box, section.as(gtk.Widget));
        }
    }

    fn makeCard(self: *Self, pkg: *const Package) *gtk.Widget {
        const p = self.priv();

        const content = gtk.Box.new(.horizontal, 10);
        gtk.Widget.setMarginTop(content.as(gtk.Widget), 8);
        gtk.Widget.setMarginBottom(content.as(gtk.Widget), 8);
        gtk.Widget.setMarginStart(content.as(gtk.Widget), 10);
        gtk.Widget.setMarginEnd(content.as(gtk.Widget), 10);
        gtk.Widget.setHexpand(content.as(gtk.Widget), 1);

        if (runtime.shellyIconsEnabled()) {
            const image = gtk.Image.new();
            if (p.resolver.resolve(pkg.Name)) |path| {
                gtk.Image.setFromFile(image, path);
            } else {
                gtk.Image.setFromIconName(image, "package-x-generic");
            }
            gtk.Image.setPixelSize(image, 48);
            gtk.Widget.setValign(image.as(gtk.Widget), .center);
            gtk.Widget.addCssClass(image.as(gtk.Widget), "icon-dropshadow");
            gtk.Box.append(content, image.as(gtk.Widget));
        }

        const text_box = gtk.Box.new(.vertical, 0);
        gtk.Widget.setHalign(text_box.as(gtk.Widget), .start);
        gtk.Widget.setValign(text_box.as(gtk.Widget), .center);
        gtk.Widget.setHexpand(text_box.as(gtk.Widget), 1);

        const title_box = gtk.Box.new(.horizontal, 6);
        gtk.Widget.setHalign(title_box.as(gtk.Widget), .start);

        var buf: [256]u8 = undefined;
        const title_label = gtk.Label.new(c_string.cstr(&buf, pkg.Name));
        gtk.Widget.setHalign(title_label.as(gtk.Widget), .start);
        gtk.Widget.addCssClass(title_label.as(gtk.Widget), "title-4");
        gtk.Box.append(title_box, title_label.as(gtk.Widget));

        var vbuf: [128]u8 = undefined;
        const version_label = gtk.Label.new(c_string.cstr(&vbuf, pkg.Version));
        gtk.Widget.setHalign(version_label.as(gtk.Widget), .start);
        gtk.Widget.setValign(version_label.as(gtk.Widget), .center);
        gtk.Widget.addCssClass(version_label.as(gtk.Widget), "caption");
        gtk.Box.append(title_box, version_label.as(gtk.Widget));

        const installed_check = gtk.Image.newFromIconName("object-select-symbolic");
        gtk.Widget.setVisible(installed_check.as(gtk.Widget), @intFromBool(pkg.Installed));
        gtk.Widget.setValign(installed_check.as(gtk.Widget), .center);
        gtk.Widget.setTooltipText(installed_check.as(gtk.Widget), "Package is already installed");
        a11y.setName(installed_check.as(gtk.Widget), translations._("Package is already installed"));
        gtk.Box.append(title_box, installed_check.as(gtk.Widget));

        gtk.Box.append(text_box, title_box.as(gtk.Widget));

        if (pkg.Description.len > 0) {
            var dbuf: [512]u8 = undefined;
            const desc_label = gtk.Label.new(c_string.cstr(&dbuf, pkg.Description));
            gtk.Widget.setHalign(desc_label.as(gtk.Widget), .start);
            gtk.Widget.addCssClass(desc_label.as(gtk.Widget), "dim-label");
            gtk.Label.setWrap(desc_label, 1);
            gtk.Label.setLines(desc_label, 2);
            gtk.Label.setEllipsize(desc_label, .end);
            gtk.Label.setMaxWidthChars(desc_label, 40);
            gtk.Box.append(text_box, desc_label.as(gtk.Widget));
        }

        gtk.Box.append(content, text_box.as(gtk.Widget));

        const name: [:0]const u8 = if (p.arena) |a|
            a.allocator().dupeSentinel(u8, pkg.Name, 0) catch ""
        else
            "";

        // Installed cards keep only their remove button; the check leads the
        // card so selecting reads like the Packages grid view.
        if (!pkg.Installed) {
            const check = gtk.CheckButton.new();
            gtk.Widget.setValign(check.as(gtk.Widget), .center);
            gobject.Object.setData(check.as(gobject.Object), "pkg-name", @ptrCast(@constCast(name.ptr)));
            gobject.Object.setData(check.as(gobject.Object), "page", self);
            gtk.CheckButton.setActive(check, @intFromBool(p.selection.contains(pkg.Name)));
            const select_hint = translations._("Select package for batch installation");
            gtk.Widget.setTooltipText(check.as(gtk.Widget), select_hint);
            a11y.setName(check.as(gtk.Widget), pkg.Name);
            _ = gtk.CheckButton.signals.toggled.connect(check, ?*anyopaque, &on_check_toggled, null, .{});
            gtk.Box.prepend(content, check.as(gtk.Widget));
            p.checks.append(std.heap.c_allocator, check) catch {};
        }

        const remove_button = gtk.Button.newFromIconName("edit-delete-symbolic");
        gtk.Widget.setVisible(remove_button.as(gtk.Widget), @intFromBool(pkg.Installed));
        gtk.Widget.addCssClass(remove_button.as(gtk.Widget), "destructive-action");
        gtk.Widget.setValign(remove_button.as(gtk.Widget), .center);
        gtk.Widget.setTooltipText(remove_button.as(gtk.Widget), "Remove package");
        gobject.Object.setData(remove_button.as(gobject.Object), "pkg-name", @ptrCast(@constCast(name.ptr)));
        gobject.Object.setData(remove_button.as(gobject.Object), "page", self);
        _ = gtk.Button.signals.clicked.connect(remove_button, ?*anyopaque, &on_remove_clicked, null, .{});
        gtk.Box.append(content, remove_button.as(gtk.Widget));

        const install_button = gtk.Button.newFromIconName("folder-download-symbolic");
        gtk.Widget.setVisible(install_button.as(gtk.Widget), @intFromBool(!pkg.Installed));
        gtk.Widget.addCssClass(install_button.as(gtk.Widget), "suggested-action");
        gtk.Widget.setValign(install_button.as(gtk.Widget), .center);
        gtk.Widget.setTooltipText(install_button.as(gtk.Widget), "Install package");
        gobject.Object.setData(install_button.as(gobject.Object), "pkg-name", @ptrCast(@constCast(name.ptr)));
        gobject.Object.setData(install_button.as(gobject.Object), "page", self);
        _ = gtk.Button.signals.clicked.connect(install_button, ?*anyopaque, &on_install_clicked, null, .{});
        gtk.Box.append(content, install_button.as(gtk.Widget));

        const frame = gtk.Frame.new(null);
        gtk.Frame.setChild(frame, content.as(gtk.Widget));
        gtk.Widget.setHexpand(frame.as(gtk.Widget), 1);
        gtk.Widget.setHalign(frame.as(gtk.Widget), .fill);
        gtk.Widget.addCssClass(frame.as(gtk.Widget), "card");

        return frame.as(gtk.Widget);
    }

    fn on_install_clicked(button: *gtk.Button, _: ?*anyopaque) callconv(.c) void {
        const page_ptr = gobject.Object.getData(button.as(gobject.Object), "page") orelse return;
        const self: *Self = @ptrCast(@alignCast(page_ptr));
        const name_ptr = gobject.Object.getData(button.as(gobject.Object), "pkg-name") orelse return;
        const name: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(name_ptr)));

        const names = [_][]const u8{name};
        const argv = [_][]const u8{ "install", "standard", "--needed", name };

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = "Installing package",
                .argv = &argv,
                .packages = &names,
                .on_complete = &on_transaction_complete,
                .privileged = true,
                .ctx = self,
            });
        }
    }

    fn on_remove_clicked(button: *gtk.Button, _: ?*anyopaque) callconv(.c) void {
        const page_ptr = gobject.Object.getData(button.as(gobject.Object), "page") orelse return;
        const self: *Self = @ptrCast(@alignCast(page_ptr));
        const name_ptr = gobject.Object.getData(button.as(gobject.Object), "pkg-name") orelse return;
        const name: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(name_ptr)));

        const names = [_][]const u8{name};
        const argv = [_][]const u8{ "remove", "standard", name };

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = "Removing package",
                .argv = &argv,
                .packages = &names,
                .on_complete = &on_transaction_complete,
                .privileged = true,
                .ctx = self,
            });
        }
    }

    /// Builds the CLI argv for a batch install of `names`, mirroring the
    /// Packages page: `install standard` followed by one argument per name.
    /// A name that is already installed is dropped; if that empties the
    /// selection no argv is produced and the caller must not start a
    /// transaction.
    pub fn build_install_argv(
        alloc: std.mem.Allocator,
        names: []const []const u8,
        installed: []const []const u8,
    ) !std.ArrayListUnmanaged([]const u8) {
        var argv = std.ArrayListUnmanaged([]const u8).empty;
        errdefer argv.deinit(alloc);

        for (names) |name| {
            var is_installed = false;
            for (installed) |have| {
                if (std.mem.eql(u8, name, have)) {
                    is_installed = true;
                    break;
                }
            }
            if (!is_installed) try argv.append(alloc, name);
        }
        if (argv.items.len == 0) return argv;

        // a saved listing may not know of a newer install.
        try argv.insertSlice(alloc, 0, &.{ "install", "standard", "--needed" });
        return argv;
    }

    /// Toggled handlers fire for programmatic changes too, so the selection
    /// always follows the check buttons rather than the other way around.
    fn on_check_toggled(check: *gtk.CheckButton, _: ?*anyopaque) callconv(.c) void {
        const page_ptr = gobject.Object.getData(check.as(gobject.Object), "page") orelse return;
        const self: *Self = @ptrCast(@alignCast(page_ptr));
        const name_ptr = gobject.Object.getData(check.as(gobject.Object), "pkg-name") orelse return;
        const name: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(name_ptr)));

        const p = self.priv();
        if (gtk.CheckButton.getActive(check) != 0) {
            if (p.selection.contains(name)) return;
            const owned = std.heap.c_allocator.dupeSentinel(u8, name, 0) catch return;
            p.selection.put(std.heap.c_allocator, owned, {}) catch {
                std.heap.c_allocator.free(owned);
                return;
            };
        } else if (p.selection.fetchRemove(name)) |entry| {
            free_key(entry.key);
        }
        self.update_action_bar();
    }

    /// Releases a key previously put into the selection map.
    fn free_key(name: []const u8) void {
        const z: [*:0]const u8 = @ptrCast(name.ptr);
        std.heap.c_allocator.free(@constCast(std.mem.span(z)));
    }

    fn clear_selection(self: *Self) void {
        const p = self.priv();
        var it = p.selection.keyIterator();
        while (it.next()) |key| free_key(key.*);
        p.selection.clearRetainingCapacity();
        self.update_action_bar();
    }

    /// Brings the selection in line with a rebuilt listing: only names it
    /// still offers as installable survive. A null set (no cards at all)
    /// clears everything.
    fn finalize_selection(self: *Self, installable: ?*const std.StringHashMapUnmanaged(void)) void {
        const p = self.priv();
        var stale: std.ArrayListUnmanaged([]const u8) = .empty;
        defer stale.deinit(std.heap.c_allocator);

        var it = p.selection.keyIterator();
        while (it.next()) |key| {
            const keep = if (installable) |set| set.contains(key.*) else false;
            if (!keep) stale.append(std.heap.c_allocator, key.*) catch {};
        }
        for (stale.items) |name| {
            _ = p.selection.remove(name);
            free_key(name);
        }
        self.update_action_bar();
    }

    fn update_action_bar(self: *Self) void {
        const p = self.priv();
        const count = p.selection.count();

        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(
            &buf,
            "{d} {s}",
            .{ count, translations._("Selected") },
            0,
        ) catch translations._("0 Selected");
        gtk.Label.setLabel(p.selected_label, text);

        const has = count > 0;
        gtk.Widget.setSensitive(p.install_selected_button.as(gtk.Widget), @intFromBool(has));
        gtk.Widget.setVisible(p.clear_button.as(gtk.Widget), @intFromBool(has));
    }

    fn on_clear_selection_clicked(self: *Self) callconv(.c) void {
        const p = self.priv();
        for (p.checks.items) |check| gtk.CheckButton.setActive(check, 0);
        // Deactivating dropped every name that had a card through
        // on_check_toggled; this sweeps up the rest and the owned keys.
        self.clear_selection();
    }

    fn on_install_selected_clicked(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.selection.count() == 0) return;

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(std.heap.c_allocator);
        var it = p.selection.keyIterator();
        while (it.next()) |key| names.append(std.heap.c_allocator, key.*) catch break;

        // No installed lookup here: buildSections already pruned the
        // selection against the data this listing was built from. That can be
        // the saved list, so a package installed elsewhere since then may
        // still be in it until the refresh; --needed skips it.
        var argv = build_install_argv(std.heap.c_allocator, names.items, &.{}) catch return;
        defer argv.deinit(std.heap.c_allocator);
        if (argv.items.len == 0) return;

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = translations._("Installing packages"),
                .argv = argv.items,
                .packages = names.items,
                .on_complete = &on_transaction_complete,
                .privileged = true,
                .ctx = self,
            });
        }
    }

    fn on_transaction_complete(ctx: *anyopaque, success: bool) void {
        if (!success) return;
        const self: *Self = @ptrCast(@alignCast(ctx));
        const p = self.priv();
        if (!p.loaded) return;
        triggerReload(self, false, false);
    }

    fn triggerReload(self: *Self, force: bool, show_saved: bool) void {
        const p = self.priv();
        p.loading = true;
        p.generation += 1;
        gtk.Widget.setSensitive(p.refresh_button.as(gtk.Widget), 0);

        self.cancel_spinner();
        if (force) {
            clear_cards(self);
            show_loading(self);
        } else if (p.shown_hash == 0) {
            p.spinner_source = glib.timeoutAdd(spinner_delay_ms, &on_spinner_delay, self);
        }

        const job: LoadJob = .{
            .page = self,
            .generation = p.generation,
            .force = force,
            .show_saved = show_saved,
            .load_icons = runtime.shellyIconsEnabled() and !p.resolver.loaded,
        };
        const thread = std.Thread.spawn(.{}, load_worker, .{job}) catch {
            p.loading = false;
            gtk.Widget.setSensitive(p.refresh_button.as(gtk.Widget), 1);
            self.cancel_spinner();
            if (p.shown_hash == 0) show_empty(self);
            return;
        };
        thread.detach();
    }

    fn on_spinner_delay(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        self.priv().spinner_source = 0;
        show_loading(self);
        return 0;
    }

    fn cancel_spinner(self: *Self) void {
        const p = self.priv();
        if (p.spinner_source == 0) return;
        _ = glib.Source.remove(p.spinner_source);
        p.spinner_source = 0;
    }

    fn on_refresh_clicked(self: *Self) callconv(.c) void {
        triggerReload(self, true, false);
    }

    fn show_loading(self: *Self) void {
        const p = self.priv();
        gtk.Spinner.start(p.loading_spinner);
        gtk.Stack.setVisibleChild(p.recommend_stack, p.loading_page.as(gtk.Widget));
    }

    fn hide_loading(self: *Self) void {
        const p = self.priv();
        self.cancel_spinner();
        gtk.Spinner.stop(p.loading_spinner);
        gtk.Stack.setVisibleChild(p.recommend_stack, p.list_page.as(gtk.Widget));
    }

    fn show_empty(self: *Self) void {
        const p = self.priv();
        finalize_selection(self, null);
        gtk.Spinner.stop(p.loading_spinner);
        gtk.Stack.setVisibleChild(p.recommend_stack, p.empty_page.as(gtk.Widget));
    }

    const template_children = .{
        .{ "page_overlay", @offsetOf(Private, "page_overlay") },
        .{ "refresh_button", @offsetOf(Private, "refresh_button") },
        .{ "recommend_stack", @offsetOf(Private, "recommend_stack") },
        .{ "loading_page", @offsetOf(Private, "loading_page") },
        .{ "loading_spinner", @offsetOf(Private, "loading_spinner") },
        .{ "list_page", @offsetOf(Private, "list_page") },
        .{ "content_box", @offsetOf(Private, "content_box") },
        .{ "empty_page", @offsetOf(Private, "empty_page") },
        .{ "selected_label", @offsetOf(Private, "selected_label") },
        .{ "clear_button", @offsetOf(Private, "clear_button") },
        .{ "install_selected_button", @offsetOf(Private, "install_selected_button") },
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
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_refresh_clicked", @ptrCast(&on_refresh_clicked));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_clear_selection_clicked", @ptrCast(&on_clear_selection_clicked));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_install_selected_clicked", @ptrCast(&on_install_selected_clicked));
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};

test "build_install_argv installs every selected package in one transaction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var argv = try RecommendPage.build_install_argv(arena.allocator(), &.{ "firefox", "htop" }, &.{});
    defer argv.deinit(arena.allocator());

    try std.testing.expectEqual(@as(usize, 5), argv.items.len);
    try std.testing.expectEqualStrings("install", argv.items[0]);
    try std.testing.expectEqualStrings("standard", argv.items[1]);
    try std.testing.expectEqualStrings("--needed", argv.items[2]);
    try std.testing.expectEqualStrings("firefox", argv.items[3]);
    try std.testing.expectEqualStrings("htop", argv.items[4]);
}

test "build_install_argv drops packages installed since the selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var argv = try RecommendPage.build_install_argv(
        arena.allocator(),
        &.{ "htop", "neofetch", "git" },
        &.{"neofetch"},
    );
    defer argv.deinit(arena.allocator());

    try std.testing.expectEqual(@as(usize, 5), argv.items.len);
    try std.testing.expectEqualStrings("install", argv.items[0]);
    try std.testing.expectEqualStrings("standard", argv.items[1]);
    try std.testing.expectEqualStrings("--needed", argv.items[2]);
    try std.testing.expectEqualStrings("htop", argv.items[3]);
    try std.testing.expectEqualStrings("git", argv.items[4]);
}

test "build_install_argv declines to start a transaction with nothing to install" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var empty = try RecommendPage.build_install_argv(arena.allocator(), &.{}, &.{});
    defer empty.deinit(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);

    var all_installed = try RecommendPage.build_install_argv(arena.allocator(), &.{"htop"}, &.{"htop"});
    defer all_installed.deinit(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), all_installed.items.len);
}

test "sections hold the first copy of each listed package and its installed state" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const categories = [_]RecommendCategory{
        .{ .name = "Tools", .packages = &.{ "foo", "missing", "bar" } },
        .{ .name = "Empty", .packages = &.{"missing"} },
    };
    const lists: package_lists.PackageLists = .{
        .Available = &.{
            .{ .Name = "foo", .Version = "2-1", .Repository = "first", .Description = "text" },
            .{ .Name = "foo", .Version = "1-1", .Repository = "second" },
            .{ .Name = "bar", .Version = "3-1" },
        },
        .Installed = &.{.{ .Name = "bar" }},
    };
    const sections = try RecommendPage.make_sections(arena.allocator(), &categories, lists);
    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expectEqualStrings("Tools", sections[0].name);
    try std.testing.expectEqual(@as(usize, 2), sections[0].packages.len);
    try std.testing.expectEqualStrings("2-1", sections[0].packages[0].Version);
    try std.testing.expectEqualStrings("text", sections[0].packages[0].Description);
    try std.testing.expect(!sections[0].packages[0].Installed);
    try std.testing.expect(sections[0].packages[1].Installed);
}

test "the section hash follows what a card shows" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const categories = [_]RecommendCategory{.{ .name = "Tools", .packages = &.{"foo"} }};
    const base: package_lists.PackageRow = .{ .Name = "foo", .Version = "1-1", .Description = "text" };
    const hashOf = struct {
        fn run(alloc: std.mem.Allocator, cats: []const RecommendCategory, row: package_lists.PackageRow, installed: bool) !u64 {
            const lists: package_lists.PackageLists = .{
                .Available = &.{row},
                .Installed = if (installed) &.{row} else &.{},
            };
            return RecommendPage.sections_hash(try RecommendPage.make_sections(alloc, cats, lists));
        }
    }.run;

    const expected = try hashOf(arena.allocator(), &categories, base, false);
    try std.testing.expectEqual(expected, try hashOf(arena.allocator(), &categories, base, false));

    var other_repository = base;
    other_repository.Repository = "extra";
    try std.testing.expectEqual(expected, try hashOf(arena.allocator(), &categories, other_repository, false));

    var changed = base;
    changed.Version = "2-1";
    try std.testing.expect(expected != try hashOf(arena.allocator(), &categories, changed, false));
    changed = base;
    changed.Description = "other";
    try std.testing.expect(expected != try hashOf(arena.allocator(), &categories, changed, false));
    try std.testing.expect(expected != try hashOf(arena.allocator(), &categories, base, true));
    const renamed = [_]RecommendCategory{.{ .name = "Other", .packages = &.{"foo"} }};
    try std.testing.expect(expected != try hashOf(arena.allocator(), &renamed, base, false));
}
