const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const glib = bindings.glib;
const gio = bindings.gio;
const model = @import("../models/appstream.zig");
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const runtime = @import("../services/runtime.zig");
const support = @import("support.zig");
const Window = @import("../shelly_window.zig").ShellyWindow;
const NativeDetail = @import("package_detail.zig").PackageDetail;
const FlatpakDetail = @import("flatpak_package_detail.zig").FlatpakPackageDetail;
const Confirm = @import("../dialog/page/yn_dialog.zig").ConfirmDialog;
const tr = @import("../helpers/translations.zig")._;
const alloc = std.heap.c_allocator;

pub const AppstreamPage = extern struct {
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    const Self = @This();
    const Private = struct {
        status: *gtk.Label,
        choices: *gtk.DropDown,
        details: *gtk.Stack,
        native: *NativeDetail,
        flatpak: *FlatpakDetail,
        action: *gtk.Button,
        result: ?std.json.Parsed(model.Result),
        id: ?[:0]u8,
        generation: usize,
        choice_prompt: bool,
        var offset: c_int = 0;
    };
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyAppstreamPage",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });
    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }
    fn priv(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }
    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }
    fn init(self: *Self, _: *Class) callconv(.c) void {
        const p = self.priv();
        p.result = null;
        p.id = null;
        p.generation = 0;
        p.choice_prompt = false;
        self.as(gtk.Orientable).setOrientation(.vertical);
        self.as(gtk.Box).setSpacing(12);
        self.as(gtk.Widget).setMarginTop(16);
        self.as(gtk.Widget).setMarginBottom(16);
        self.as(gtk.Widget).setMarginStart(16);
        self.as(gtk.Widget).setMarginEnd(16);
        p.status = gtk.Label.new(null);
        p.status.setWrap(1);
        p.status.setXalign(0);
        self.as(gtk.Box).append(p.status.as(gtk.Widget));
        p.choices = gtk.DropDown.new(null, null);
        self.as(gtk.Box).append(p.choices.as(gtk.Widget));
        p.action = gtk.Button.newWithLabel(tr("Remove"));
        p.action.as(gtk.Widget).setHalign(.start);
        self.as(gtk.Box).append(p.action.as(gtk.Widget));
        p.details = gtk.Stack.new();
        p.details.as(gtk.Widget).setVexpand(1);
        p.native = NativeDetail.new();
        p.flatpak = FlatpakDetail.new();
        _ = p.details.addNamed(p.native.as(gtk.Widget), "native");
        _ = p.details.addNamed(p.flatpak.as(gtk.Widget), "flatpak");
        self.as(gtk.Box).append(p.details.as(gtk.Widget));
        _ = gobject.Object.signals.notify.connect(p.choices.as(gobject.Object), *Self, &selected, self, .{ .detail = "selected" });
        _ = gtk.Button.signals.clicked.connect(p.action, *Self, &act, self, .{});
        support.connectLifecycle(Self, self);
    }
    pub fn onMap(_: *Self) void {}
    pub fn onUnmap(self: *Self) void {
        self.cancel();
    }
    pub fn cancel(self: *Self) void {
        self.priv().generation +%= 1;
    }

    pub fn open(self: *Self, id: []const u8) void {
        const owned = alloc.dupeZ(u8, id) catch return;
        const p = self.priv();
        if (p.id) |old| alloc.free(old);
        p.id = owned;
        self.load();
    }
    fn load(self: *Self) void {
        const p = self.priv();
        self.cancel();
        p.status.setLabel(tr("Looking up application…"));
        p.choices.as(gtk.Widget).setVisible(0);
        p.action.as(gtk.Widget).setVisible(0);
        p.details.as(gtk.Widget).setVisible(0);
        var flatpak = true;
        if (runtime.config) |service| if (service.get() catch null) |cfg| {
            flatpak = cfg.FlatPackEnabled;
        };
        const job = alloc.create(Job) catch {
            self.failed();
            return;
        };
        const id = alloc.dupe(u8, p.id orelse "") catch {
            alloc.destroy(job);
            self.failed();
            return;
        };
        job.* = .{ .page = self, .generation = p.generation, .id = id, .flatpak = flatpak };
        _ = self.as(gobject.Object).ref();
        const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            job.destroy();
            self.failed();
            return;
        };
        thread.detach();
    }
    fn failed(self: *Self) void {
        self.priv().status.setLabel(tr("Could not look up this application. Please try again."));
    }
    const Job = struct {
        page: *Self,
        generation: usize,
        id: []u8,
        flatpak: bool,
        result: ?std.json.Parsed(model.Result) = null,
        fn destroy(job: *Job) void {
            if (job.result) |result| result.deinit();
            job.page.as(gobject.Object).unref();
            alloc.free(job.id);
            alloc.destroy(job);
        }
    };
    fn worker(job: *Job) void {
        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();
        const cli: ShellyCli = .{ .allocator = alloc, .io = threaded.io() };
        job.result = cli.resolve_appstream(job.id, job.flatpak) catch null;
        _ = glib.idleAdd(&complete, job);
    }
    fn complete(data: ?*anyopaque) callconv(.c) c_int {
        const job: *Job = @ptrCast(@alignCast(data.?));
        defer job.destroy();
        const self = job.page;
        const p = self.priv();
        if (job.generation != p.generation) return 0;
        const win = support.getWindow(Window, self) orelse return 0;
        if (win.navigationLocked()) return 0;
        if (job.result == null) {
            self.failed();
            return 0;
        }
        // Clear selection before releasing the data used by its callback.
        p.choices.setModel(null);
        if (p.result) |old| old.deinit();
        p.result = job.result;
        job.result = null;
        self.renderResult();
        return 0;
    }
    fn renderResult(self: *Self) void {
        const p = self.priv();
        const result = p.result.?.value;
        const strings = gtk.StringList.new(null);
        defer strings.as(gobject.Object).unref();
        var count: usize = 0;
        for (result.candidates) |item| if (result.eligible(item)) {
            count += 1;
        };
        p.choice_prompt = count > 1;
        if (p.choice_prompt) strings.append(tr("Choose an installation…"));
        for (result.candidates) |candidate| {
            if (!result.eligible(candidate)) continue;
            const label = std.fmt.allocPrintSentinel(alloc, "{s} — {s}{s}{s}{s}{s}{s}{s}", .{
                candidate.name,                              if (candidate.source == .native) tr("Native package") else tr("Flatpak"),
                if (candidate.scope.len > 0) " / " else "",  candidate.scope,
                if (candidate.remote.len > 0) " / " else "", candidate.remote,
                if (candidate.ref.len > 0) " / " else "",    candidate.ref,
            }, 0) catch {
                self.failed();
                return;
            };
            defer alloc.free(label);
            strings.append(label);
        }
        if (count == 0) {
            p.status.setLabel(if (result.problems.len == 0) tr("No package was found for this application.") else tr("Could not resolve this application. A package source or its metadata is unavailable."));
            return;
        }
        p.status.setLabel(if (result.problems.len > 0) tr("Some package sources could not be checked. Available matches are shown below.") else if (count > 1) tr("Choose the application installation to manage.") else tr("Application details"));
        p.choices.setModel(strings.as(gio.ListModel));
        p.choices.setSelected(0);
        p.choices.as(gtk.Widget).setVisible(@intFromBool(count > 1));
        self.showSelected();
        return;
    }
    fn selectedCandidate(self: *Self) ?model.Candidate {
        const p = self.priv();
        const result = (p.result orelse return null).value;
        var index = p.choices.getSelected();
        if (p.choice_prompt) {
            if (index == 0) return null;
            index -= 1;
        }
        var i: usize = 0;
        for (result.candidates) |item| {
            if (!result.eligible(item)) continue;
            if (i == index) return item;
            i += 1;
        }
        return null;
    }
    fn selected(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.showSelected();
    }
    fn showSelected(self: *Self) void {
        const p = self.priv();
        const item = self.selectedCandidate() orelse {
            p.details.as(gtk.Widget).setVisible(0);
            p.action.as(gtk.Widget).setVisible(0);
            return;
        };
        if (item.source == .native) {
            p.native.showPackage(item.id, item.installed, null);
            p.details.setVisibleChildName("native");
        } else {
            p.flatpak.showHit(&.{ .id = item.id, .name = item.name, .summary = item.summary, .remote = item.remote });
            p.details.setVisibleChildName("flatpak");
        }
        p.details.as(gtk.Widget).setVisible(1);
        p.action.setLabel(if (item.installed) tr("Remove") else tr("Install"));
        p.action.as(gtk.Widget).setVisible(1);
    }
    fn act(_: *gtk.Button, self: *Self) callconv(.c) void {
        const item = self.selectedCandidate() orelse return;
        const win = support.getWindow(Window, self) orelse return;
        const message = std.fmt.allocPrintSentinel(alloc, "{s} {s}?", .{ if (item.installed) tr("Remove") else tr("Install"), item.name }, 0) catch return;
        defer alloc.free(message);
        const dialog = Confirm.new(tr("Manage application"), message, &confirmed, self);
        win.showLockout(dialog.as(gtk.Widget));
    }
    fn confirmed(context: ?*anyopaque, accepted: bool) void {
        const self: *Self = @ptrCast(@alignCast(context.?));
        const win = support.getWindow(Window, self) orelse return;
        win.hideLockout();
        if (!accepted) return;
        const item = self.selectedCandidate() orelse return;
        var buffer: [7][]const u8 = undefined;
        const args = item.operationArgs(&buffer);
        _ = self.as(gobject.Object).ref();
        win.startTransaction(.{
            .title = if (item.installed) tr("Removing application") else tr("Installing application"),
            .argv = args,
            .packages = &.{item.id},
            .privileged = item.source == .native or !std.mem.eql(u8, item.scope, "user"),
            .on_complete = &transactionComplete,
            .ctx = self,
        });
    }
    fn transactionComplete(context: *anyopaque, _: bool) void {
        const self: *Self = @ptrCast(@alignCast(context));
        defer self.as(gobject.Object).unref();
        if (gtk.Widget.getRoot(self.as(gtk.Widget)) != null) self.load();
    }
    fn finalize(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.result) |result| result.deinit();
        if (p.id) |id| alloc.free(id);
        gobject.Object.virtual_methods.finalize.call(Class.parent.as(gobject.Object.Class), self.as(gobject.Object));
    }
    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;
        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};

test "AppStream page asks for an installation when native and Flatpak are installed" {
    try @import("../helpers/gtk_test.zig").requireDisplay();
    const page = AppstreamPage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    page.priv().result = try std.json.parseFromSlice(model.Result, alloc,
        \\{"candidates":[{"source":"native","id":"editor","name":"Editor","installed":true},{"source":"flatpak","id":"org.example.Editor","name":"Editor","installed":true,"scope":"user","ref":"app/org.example.Editor/x86_64/stable"}],"problems":[]}
    , .{});
    page.renderResult();
    try std.testing.expect(page.selectedCandidate() == null);
    try std.testing.expect(page.priv().choices.as(gtk.Widget).getVisible() != 0);
    page.priv().choices.setSelected(2);
    try std.testing.expectEqualStrings("user", page.selectedCandidate().?.scope);
    try std.testing.expectEqualStrings("flatpak", std.mem.span(page.priv().details.getVisibleChildName().?));
    try std.testing.expect(page.priv().action.as(gtk.Widget).getVisible() != 0);
}

test "AppStream page ignores completion from an obsolete navigation request" {
    try @import("../helpers/gtk_test.zig").requireDisplay();
    const page = AppstreamPage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    const job = try alloc.create(AppstreamPage.Job);
    _ = page.as(gobject.Object).ref();
    job.* = .{ .page = page, .generation = page.priv().generation, .id = try alloc.dupe(u8, "old"), .flatpak = false };
    page.cancel();
    _ = AppstreamPage.complete(job);
    try std.testing.expect(page.priv().result == null);
}

test "AppStream page opens one native package directly with removal available" {
    try @import("../helpers/gtk_test.zig").requireDisplay();
    const page = AppstreamPage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    page.priv().result = try std.json.parseFromSlice(model.Result, alloc,
        \\{"candidates":[{"source":"native","id":"chromium","name":"chromium","installed":true}],"problems":[]}
    , .{});
    page.renderResult();
    try std.testing.expectEqualStrings("chromium", page.selectedCandidate().?.id);
    try std.testing.expectEqualStrings("native", std.mem.span(page.priv().details.getVisibleChildName().?));
    try std.testing.expect(page.priv().choices.as(gtk.Widget).getVisible() == 0);
    try std.testing.expectEqualStrings(tr("Remove"), std.mem.span(page.priv().action.getLabel().?));
}
