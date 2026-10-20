const std = @import("std");
const diagnostics = @import("diagnostics");
const translations = @import("../../helpers/translations.zig");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const glib = bindings.glib;
const gobject = bindings.gobject;
const gdk = bindings.gdk;
const support = @import("../../pages/support.zig");
const ShellyCli = @import("../../services/shelly_cli.zig").ShellyCli;
const PkgBuild = @import("../../models/pkgbuild.zig").PkgBuild;
const runtime = @import("../../services/runtime.zig");
const features = @import("../../services/build_features.zig");
const InstallReview = @import("pkg_build.zig").PkgbuildReviewDialog;

pub const PkgbuildReviewDialog = extern struct {
    parent_instance: Parent,
    const Self = @This();
    pub const Parent = gtk.Window;
    const resource_path = "/com/shellyorg/shelly/dialog/ui/preview_pkgbuild.ui";

    const PageState = enum {
        Loading,
        Loaded,
        Error,
    };

    const Private = struct {
        heading_label: *gtk.Label,
        scan_box: *gtk.Box,
        scan_icon: *gtk.Image,
        scan_label: *gtk.Label,
        scan_spinner: *gtk.Spinner,
        notebook: *gtk.Notebook,
        warnings_page: *gtk.ScrolledWindow,
        warnings_box: *gtk.Box,
        warnings_subtitle: *gtk.Label,
        sources_page: *gtk.ScrolledWindow,
        sources_box: *gtk.Box,
        retry_scan_button: *gtk.Button,
        scan_enabled: bool,
        package_name: []const u8,
        content: []const u8,
        diff_box: *gtk.Box,
        cancel_button: *gtk.Button,
        loading_spinner: *gtk.Spinner,
        error_label: *gtk.Label,
        state: PageState,
        ctx: ?*anyopaque,
        generation: u32,
        arena: ?*std.heap.ArenaAllocator,
        loaded: bool,
        responded: bool,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyPkgbuildPreviewDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    fn priv(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const p = self.priv();
        p.generation = 0;
        p.arena = null;
        p.loaded = false;
        p.responded = false;
        p.scan_enabled = false;
        p.package_name = "";
        p.content = "";

        support.connectLifecycle(Self, self);
    }

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn showPreview(self: *Self, name: []const u8) void {
        const p = self.priv();
        var buf: [512]u8 = undefined;
        const heading = std.fmt.bufPrintZ(
            &buf,
            "{s}: {s}",
            .{ "PKGBUILD", name },
        ) catch "PKGBUILD";
        gtk.Label.setLabel(p.heading_label, heading);
        p.scan_enabled = atoll_enabled();
        gtk.Notebook.setShowTabs(p.notebook, @intFromBool(p.scan_enabled));
        gtk.Notebook.setCurrentPage(p.notebook, 0);
        gtk.Widget.setVisible(p.warnings_page.as(gtk.Widget), @intFromBool(p.scan_enabled));
        gtk.Widget.setVisible(p.sources_page.as(gtk.Widget), @intFromBool(p.scan_enabled));
        gtk.Widget.setVisible(p.warnings_subtitle.as(gtk.Widget), 0);
        show_tab_message(p.warnings_box, translations._("Scanning PKGBUILD…"));
        show_tab_message(p.sources_box, translations._("Scanning PKGBUILD…"));
        gtk.Widget.setVisible(p.scan_box.as(gtk.Widget), @intFromBool(p.scan_enabled));
        self.start_load(name);
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();

        if (p.loaded) return;
    }

    pub fn present(self: *Self) void {
        const p = self.priv();
        gtk.Window.present(self.as(gtk.Window));

        _ = gtk.Widget.grabFocus(p.cancel_button.as(gtk.Widget));
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        p.loaded = false;

        p.generation += 1;

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }
    }

    // Allocate the result on the main thread so every worker failure can post
    // completion without allocating again or touching GTK from a worker thread.
    const Result = struct {
        page: *Self,
        name: []const u8,
        arena: *std.heap.ArenaAllocator,
        generation: u32,
        pkgbuild: ?PkgBuild = null,
        mode: ShellyCli.PkgbuildFetchMode,
        detail: ?[]u8 = null,
        err: ?anyerror = null,
    };

    fn atoll_enabled() bool {
        if (features.builtWithAtollOnly) return true;
        if (!features.builtWithAtoll) return false;
        const svc = runtime.config orelse return false;
        const cfg = svc.get() catch return false;
        return cfg.AtollAurEnabled;
    }

    fn start_load(self: *Self, package_name: []const u8) void {
        self.start_request(package_name, false);
    }

    fn start_request(self: *Self, package_name: []const u8, scan_only: bool) void {
        const p = self.priv();
        p.generation += 1;
        if (scan_only) {
            if (!p.scan_enabled or !atoll_enabled()) return;
            gtk.Label.setLabel(p.scan_label, translations._("Scanning PKGBUILD…"));
            gtk.Widget.setVisible(p.warnings_subtitle.as(gtk.Widget), 0);
            show_tab_message(p.warnings_box, translations._("Scanning PKGBUILD…"));
            show_tab_message(p.sources_box, translations._("Scanning PKGBUILD…"));
            gtk.Image.setFromIconName(p.scan_icon, "security-high-symbolic");
            gtk.Widget.removeCssClass(p.scan_label.as(gtk.Widget), "warning");
            gtk.Widget.removeCssClass(p.scan_label.as(gtk.Widget), "success");
            gtk.Widget.setVisible(p.scan_spinner.as(gtk.Widget), 1);
            p.scan_spinner.start();
            gtk.Widget.setVisible(p.retry_scan_button.as(gtk.Widget), 0);
        } else {
            self.set_page_state(.Loading);
        }
        const arena = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch {
            self.request_failure(scan_only, error.OutOfMemory, null);
            return;
        };
        arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        const allocator = arena.allocator();
        const result = allocator.create(Result) catch {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            self.request_failure(scan_only, error.OutOfMemory, null);
            return;
        };
        const name = allocator.dupe(u8, package_name) catch {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            self.request_failure(scan_only, error.OutOfMemory, null);
            return;
        };
        result.* = .{ .page = self, .name = name, .arena = arena, .generation = p.generation, .mode = if (scan_only) .atoll_scan else if (p.scan_enabled) .atoll_preview else .preview };
        _ = self.as(gobject.Object).ref();
        const thread = std.Thread.spawn(.{}, worker, .{result}) catch |err| {
            self.as(gobject.Object).unref();
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            self.request_failure(scan_only, err, null);
            return;
        };
        thread.detach();
    }

    fn worker(result: *Result) void {
        defer _ = glib.idleAdd(&on_complete, result);
        const allocator = result.arena.allocator();
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const cli = ShellyCli{ .allocator = allocator, .io = threaded.io(), .failure_detail = &result.detail };
        const parsed = cli.fetchPkgbuild(result.name, result.mode) catch |err| {
            result.err = err;
            return;
        };
        for (parsed.value) |package| {
            if (std.mem.eql(u8, std.mem.trimEnd(u8, package.Name, "\x00"), std.mem.trimEnd(u8, result.name, "\x00"))) {
                result.pkgbuild = package;
                return;
            }
        }
        result.err = error.PackageNotFound;
    }

    fn request_failure(self: *Self, scan_only: bool, err: anyerror, detail: ?[]const u8) void {
        if (!scan_only) {
            self.show_failure(err, detail);
            return;
        }
        const p = self.priv();
        p.scan_spinner.stop();
        gtk.Widget.setVisible(p.scan_spinner.as(gtk.Widget), 0);
        gtk.Image.setFromIconName(p.scan_icon, "dialog-warning-symbolic");
        gtk.Widget.addCssClass(p.scan_label.as(gtk.Widget), "warning");
        const message = std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s}\n{s}", .{
            translations._("Security scan unavailable."), detail orelse diagnostics.cause(err),
        }, 0) catch null;
        defer if (message) |text| std.heap.c_allocator.free(text);
        gtk.Label.setLabel(p.scan_label, message orelse translations._("Security scan unavailable."));
        gtk.Widget.setVisible(p.warnings_subtitle.as(gtk.Widget), 0);
        show_tab_message(p.warnings_box, message orelse translations._("Security scan unavailable."));
        show_tab_message(p.sources_box, translations._("Security scan unavailable."));
        gtk.Widget.setVisible(p.retry_scan_button.as(gtk.Widget), 1);
    }

    fn on_retry_scan(self: *Self) callconv(.c) void {
        self.start_request(self.priv().package_name, true);
    }

    fn on_cancel(self: *Self) callconv(.c) void {
        gtk.Window.destroy(self.as(gtk.Window));
    }

    fn on_close_request(self: *Self) callconv(.c) c_int {
        gtk.Window.destroy(self.as(gtk.Window));
        return 0;
    }

    fn show_failure(self: *Self, err: anyerror, detail: ?[]const u8) void {
        const heading = translations._("Could not load the PKGBUILD preview.");
        const message = std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s}\n{s}", .{
            heading, detail orelse diagnostics.cause(err),
        }, 0) catch {
            gtk.Label.setLabel(self.priv().error_label, heading);
            self.set_page_state(.Error);
            return;
        };
        defer std.heap.c_allocator.free(message);
        gtk.Label.setLabel(self.priv().error_label, message);
        self.set_page_state(.Error);
    }

    fn set_page_state(self: *Self, state: PageState) void {
        const p = self.priv();
        p.state = state;
        gtk.Widget.setVisible(p.loading_spinner.as(gtk.Widget), @intFromBool(state == .Loading));
        gtk.Widget.setVisible(p.error_label.as(gtk.Widget), @intFromBool(state == .Error));
        if (state == .Loading) p.loading_spinner.start() else p.loading_spinner.stop();
    }

    fn on_complete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *Result = @ptrCast(@alignCast(data.?));
        const page = result.page;
        const arena = result.arena;
        var transferred = false;
        defer {
            if (!transferred) {
                arena.deinit();
                std.heap.c_allocator.destroy(arena);
            }
            page.as(gobject.Object).unref();
        }
        const p = page.priv();
        if (result.generation != p.generation) return 0;
        if (result.mode == .atoll_scan and !atoll_enabled()) {
            gtk.Widget.setVisible(p.scan_box.as(gtk.Widget), 0);
            gtk.Notebook.setCurrentPage(p.notebook, 0);
            gtk.Notebook.setShowTabs(p.notebook, 0);
            gtk.Widget.setVisible(p.warnings_page.as(gtk.Widget), 0);
            gtk.Widget.setVisible(p.sources_page.as(gtk.Widget), 0);
            return 0;
        }
        if (result.err) |err| {
            const message = diagnostics.format(arena.allocator(), err, .{
                .operation = "the PKGBUILD preview",
                .subject = result.name,
                .detail = result.detail,
            }) catch null;
            page.request_failure(result.mode == .atoll_scan, err, message);
            return 0;
        }
        const package = result.pkgbuild orelse {
            page.request_failure(result.mode == .atoll_scan, error.PackageNotFound, null);
            return 0;
        };
        if (result.mode == .atoll_scan) {
            if (!std.mem.eql(u8, package.PkgBuild, p.content)) {
                page.request_failure(true, error.ReviewedPkgbuildChanged, translations._("PKGBUILD changed. Close and reopen the preview to scan the current version."));
                return 0;
            }
            const scan = package.Scan orelse {
                page.request_failure(true, error.MissingScanResult, null);
                return 0;
            };
            page.show_scan(scan, arena.allocator()) catch |err| page.request_failure(true, err, null);
            return 0;
        }
        const text = arena.allocator().dupeZ(u8, package.PkgBuild) catch {
            page.show_failure(error.OutOfMemory, null);
            return 0;
        };
        const view = gtk.TextView.new();
        gtk.TextView.setEditable(view, 0);
        gtk.TextView.setMonospace(view, 1);
        gtk.TextView.setWrapMode(view, .word_char);
        gtk.TextView.setCursorVisible(view, 0);
        gtk.TextBuffer.setText(gtk.TextView.getBuffer(view), text, @intCast(text.len));
        clear_box(p.diff_box);
        gtk.Box.append(p.diff_box, view.as(gtk.Widget));
        if (p.arena) |old| {
            old.deinit();
            std.heap.c_allocator.destroy(old);
        }
        p.arena = arena;
        transferred = true;
        p.loaded = true;
        p.content = package.PkgBuild;
        p.package_name = result.name;
        page.set_page_state(.Loaded);
        if (p.scan_enabled and atoll_enabled()) page.start_request(result.name, true);
        return 0;
    }

    fn show_scan(self: *Self, scan: PkgBuild.ScanResult, allocator: std.mem.Allocator) !void {
        const warnings = try allocator.alloc(InstallReview.Warning, scan.findings.len);
        for (scan.findings, warnings) |finding, *warning| {
            warning.* = .{
                .tool = try allocator.dupeZ(u8, finding.tool),
                .hook = try allocator.dupeZ(u8, finding.hook),
                .severity = try allocator.dupeZ(u8, if (std.mem.eql(u8, finding.severity, "critical")) "Critical" else finding.severity),
                .message = try allocator.dupeZ(u8, finding.message),
                .matched_line = try allocator.dupeZ(u8, finding.matched_line),
            };
        }
        const files = try allocator.alloc(InstallReview.SourceFile, scan.related_files.len);
        for (scan.related_files, files) |file, *row| {
            row.* = .{ .name = try allocator.dupeZ(u8, file.name), .content = try allocator.dupeZ(u8, file.content) };
        }
        const p = self.priv();
        clear_box(p.warnings_box);
        clear_box(p.sources_box);
        if (warnings.len > 0) {
            gtk.Box.append(p.warnings_box, make_warnings_view(warnings));
        } else {
            show_tab_message(p.warnings_box, translations._("Security scan completed - no issues found."));
        }
        for (files) |file| gtk.Box.append(p.sources_box, make_source_row(file));
        if (files.len == 0) show_tab_message(p.sources_box, translations._("No related files."));
        gtk.Widget.setVisible(p.warnings_subtitle.as(gtk.Widget), @intFromBool(warnings.len > 0));
        gtk.Widget.setVisible(p.warnings_page.as(gtk.Widget), 1);
        gtk.Widget.setVisible(p.sources_page.as(gtk.Widget), 1);
        p.scan_spinner.stop();
        gtk.Widget.setVisible(p.scan_spinner.as(gtk.Widget), 0);
        gtk.Image.setFromIconName(p.scan_icon, if (warnings.len > 0) "dialog-warning-symbolic" else "security-high-symbolic");
        var buffer: [128]u8 = undefined;
        const message = if (warnings.len > 0)
            std.fmt.bufPrintZ(&buffer, "{s} {d} {s}", .{ translations._("Security scan completed -"), warnings.len, translations._("warning(s) found.") }) catch translations._("Security scan completed - warnings found.")
        else
            translations._("Security scan completed - no issues found.");
        gtk.Label.setLabel(p.scan_label, message);
        gtk.Widget.addCssClass(p.scan_label.as(gtk.Widget), if (warnings.len > 0) "warning" else "success");
    }

    fn make_source_row(file: InstallReview.SourceFile) *gtk.Widget {
        const box = gtk.Box.new(.vertical, 8);
        gtk.Widget.setHexpand(box.as(gtk.Widget), 1);

        const title = gtk.Label.new(file.name);
        gtk.Label.setXalign(title, 0);
        gtk.Label.setSelectable(title, 1);
        gtk.Label.setWrap(title, 1);
        gtk.Widget.addCssClass(title.as(gtk.Widget), "heading");
        gtk.Box.append(box, title.as(gtk.Widget));

        const view = gtk.TextView.new();
        gtk.TextView.setEditable(view, 0);
        gtk.TextView.setMonospace(view, 1);
        gtk.TextView.setWrapMode(view, .none);
        gtk.TextView.setCursorVisible(view, 0);
        const buffer = gtk.TextView.getBuffer(view);
        gtk.TextBuffer.setText(buffer, file.content, @intCast(file.content.len));

        gtk.Box.append(box, view.as(gtk.Widget));

        return box.as(gtk.Widget);
    }

    fn make_warnings_view(warnings: []const InstallReview.Warning) *gtk.Widget {
        const view = gtk.TextView.new();
        gtk.TextView.setEditable(view, 0);
        gtk.TextView.setMonospace(view, 1);
        gtk.TextView.setWrapMode(view, .word_char);
        gtk.TextView.setCursorVisible(view, 0);
        const buffer = gtk.TextView.getBuffer(view);

        var iter: gtk.TextIter = undefined;
        gtk.TextBuffer.getEndIter(buffer, &iter);

        const used_in = translations._("used in");
        for (warnings, 0..) |warning, i| {
            if (i > 0) {
                gtk.TextBuffer.insert(buffer, &iter, "\n", 1);
            }

            const escaped_tool = glib.markupEscapeText(warning.tool, -1);
            defer glib.free(escaped_tool);
            const escaped_hook = glib.markupEscapeText(warning.hook, -1);
            defer glib.free(escaped_hook);

            var title_buffer: [512]u8 = undefined;
            const severity_color = if (std.mem.eql(u8, warning.severity, "Critical")) "#c01c28" else "#e5a50a";
            const title_markup = std.fmt.bufPrintZ(
                &title_buffer,
                "<b><span foreground=\"{s}\">{s} {s} {s}</span></b>",
                .{ severity_color, escaped_tool, used_in, escaped_hook },
            ) catch null;

            if (title_markup) |markup| {
                gtk.TextBuffer.insertMarkup(buffer, &iter, markup, -1);
            } else {
                gtk.TextBuffer.insert(buffer, &iter, warning.tool, @intCast(warning.tool.len));
                gtk.TextBuffer.insert(buffer, &iter, " ", 1);
                gtk.TextBuffer.insert(buffer, &iter, used_in, @intCast(used_in.len));
                gtk.TextBuffer.insert(buffer, &iter, " ", 1);
                gtk.TextBuffer.insert(buffer, &iter, warning.hook, @intCast(warning.hook.len));
            }

            if (warning.message.len > 0) {
                gtk.TextBuffer.insert(buffer, &iter, "\n", 1);
                gtk.TextBuffer.insert(buffer, &iter, warning.message, @intCast(warning.message.len));
            }

            if (warning.matched_line.len > 0) {
                gtk.TextBuffer.insert(buffer, &iter, "\n", 1);
                gtk.TextBuffer.insert(buffer, &iter, warning.matched_line, @intCast(warning.matched_line.len));
            }
        }

        return view.as(gtk.Widget);
    }

    fn show_tab_message(box: *gtk.Box, text: [:0]const u8) void {
        clear_box(box);
        const label = gtk.Label.new(text);
        gtk.Label.setXalign(label, 0);
        gtk.Label.setWrap(label, 1);
        gtk.Box.append(box, label.as(gtk.Widget));
    }

    fn clear_box(box: *gtk.Box) void {
        while (gtk.Widget.getFirstChild(box.as(gtk.Widget))) |child| {
            gtk.Box.remove(box, child);
        }
    }

    fn finalize(self: *Self) callconv(.c) void {
        const p = self.priv();

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }
        const parent_class: *gobject.Object.Class = @ptrCast(Class.parent);
        gobject.Object.virtual_methods.finalize.call(parent_class, self.as(gobject.Object));
    }

    const template_children = .{
        .{ "heading_label", @offsetOf(Private, "heading_label") },
        .{ "scan_box", @offsetOf(Private, "scan_box") },
        .{ "scan_icon", @offsetOf(Private, "scan_icon") },
        .{ "scan_label", @offsetOf(Private, "scan_label") },
        .{ "scan_spinner", @offsetOf(Private, "scan_spinner") },
        .{ "notebook", @offsetOf(Private, "notebook") },
        .{ "warnings_page", @offsetOf(Private, "warnings_page") },
        .{ "warnings_content", @offsetOf(Private, "warnings_box") },
        .{ "warnings_subtitle", @offsetOf(Private, "warnings_subtitle") },
        .{ "sources_page", @offsetOf(Private, "sources_page") },
        .{ "sources_box", @offsetOf(Private, "sources_box") },
        .{ "retry_scan_button", @offsetOf(Private, "retry_scan_button") },
        .{ "diff_box", @offsetOf(Private, "diff_box") },
        .{ "cancel_button", @offsetOf(Private, "cancel_button") },
        .{ "loading_spinner", @offsetOf(Private, "loading_spinner") },
        .{ "error_label", @offsetOf(Private, "error_label") },
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
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);

            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_retry_scan", @ptrCast(&on_retry_scan));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_cancel", @ptrCast(&on_cancel));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_close_request", @ptrCast(&on_close_request));
        }
    };
};
