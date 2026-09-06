const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gdk = bindings.gdk;
const glib = bindings.glib;
const gobject = bindings.gobject;
const support = @import("support.zig");
const ShellyOperation = @import("../services/shelly_operation.zig").ShellyOperation;
const Event = @import("../services/shelly_operation.zig").Event;
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const ConfirmDialog = @import("../dialog/page/yn_dialog.zig").ConfirmDialog;
const PendingQuestion = @import("../services/shelly_operation.zig").PendingQuestion;
const TransactionQuestion = @import("../services/shelly_operation.zig").TransactionQuestion;
const TransactionPackage = @import("../services/shelly_operation.zig").TransactionPackage;
const runtime = @import("../services/runtime.zig");
const MultiSelectDialog = @import("../dialog/page/multiselect.zig").MultiSelectDialog;
const PkgbuildReviewDialog = @import("../dialog/page/pkg_build.zig").PkgbuildReviewDialog;
const PlanDialog = @import("../dialog/page/plan.zig").PlanDialog;
const ProviderDialog = @import("../dialog/page/provider.zig").ProviderDialog;
const translations = @import("../helpers/translations.zig");

const log = std.log.scoped(.transaction_page);

pub const TransactionRequest = struct {
    title: []const u8,
    argv: []const []const u8,
    packages: []const []const u8,
    privileged: bool = true,
    on_complete: ?*const fn (ctx: *anyopaque, success: bool) void = null,
    ctx: ?*anyopaque = null,
};

const PackageRow = struct {
    name: [:0]const u8,
    root: *gtk.Box,
    status_label: *gtk.Label,
    progress: *gtk.ProgressBar,
    stage: ?[]const u8 = null,
    pulse_source: c_uint = 0,
};

const ProgressLine = struct {
    start: *gtk.TextMark,
    end: *gtk.TextMark,
};

pub const TransactionPage = extern struct {
    parent_instance: Parent,
    const Self = @This();
    pub const Parent = gtk.Box;
    pub const title: [:0]const u8 = "Transaction";
    const resource_path = "/com/shellyorg/shelly/ui/transaction_page.ui";

    const Private = struct {
        status_icon: *gtk.Image,
        title_label: *gtk.Label,
        terminal_toggle: *gtk.Button,
        close_button: *gtk.Button,
        paned: *gtk.Paned,
        rows_box: *gtk.Box,
        terminal_scroll: *gtk.ScrolledWindow,
        terminal_view: *gtk.TextView,
        question_layer: *gtk.Box,
        status_label: *gtk.Label,
        arena: ?*std.heap.ArenaAllocator,
        rows: std.StringHashMapUnmanaged(*PackageRow),
        terminal_lines: std.StringHashMapUnmanaged(void),
        on_complete: ?*const fn (ctx: *anyopaque, success: bool) void,
        on_complete_ctx: ?*anyopaque,
        operation: ?*ShellyOperation,
        progress_lines: std.StringHashMapUnmanaged(ProgressLine),
        finished: bool,
        failure_message: ?[]const u8,
        privileged: bool,
        cancelled: bool,
        terminal_visible: bool,
        scratch: [1024]u8 = undefined,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyTransactionPage",
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
        log.debug("terminal_view={*} rows_box={*}", .{ p.terminal_view, p.rows_box });

        p.on_complete = null;
        p.on_complete_ctx = null;
        p.arena = null;
        p.rows = .empty;
        p.terminal_lines = .empty;
        p.operation = null;
        p.finished = false;
        p.failure_message = null;
        p.privileged = false;
        p.cancelled = false;
        p.terminal_visible = true;
        p.progress_lines = .empty;
    }

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn run(self: *Self, request: TransactionRequest) void {
        const p = self.priv();
        self.reset();

        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        p.arena = arena_ptr;
        const alloc = arena_ptr.allocator();

        setLabel(p.title_label, request.title);

        for (request.packages) |name| {
            const owned = alloc.dupeZ(u8, name) catch continue;
            const row = build_row(alloc, owned) catch continue;
            gtk.Box.append(p.rows_box, row.root.as(gtk.Widget));
            p.rows.put(alloc, owned, row) catch {};
        }

        const add_no_confirm = shouldAddNoConfirm(request.argv);
        const argv_len = request.argv.len + @as(usize, if (add_no_confirm) 1 else 0);
        const argv = alloc.alloc([]const u8, argv_len) catch return;
        for (request.argv, 0..) |a, i| {
            argv[i] = alloc.dupe(u8, a) catch return;
        }
        if (add_no_confirm) {
            argv[request.argv.len] = alloc.dupe(u8, "--no-confirm") catch return;
        }

        const op = std.heap.c_allocator.create(ShellyOperation) catch return;
        op.* = ShellyOperation.init(
            std.heap.c_allocator,
            &on_op_event,
            &on_op_done,
            &on_op_question,
            self,
        );
        op.threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
        op.io = op.threaded.io();
        p.operation = op;

        p.privileged = request.privileged;
        p.on_complete = request.on_complete;
        p.on_complete_ctx = request.ctx;

        const started = if (request.privileged) op.startPrivileged(argv) else op.start(argv);
        started catch {
            append_terminal(self, translations._("Failed to start operation."));
            op.threaded.deinit();
            std.heap.c_allocator.destroy(op);
            p.operation = null;
            p.finished = true;
            self.showFinishedUI(.failed, translations._("Failed to start operation."));
            if (p.on_complete) |cb| {
                if (p.on_complete_ctx) |ctx| cb(ctx, false);
            }
        };
    }

    fn shouldAddNoConfirm(argv: []const []const u8) bool {
        for (argv) |arg| {
            if (std.mem.eql(u8, arg, "--no-confirm") or std.mem.eql(u8, arg, "-n")) {
                return false;
            }
        }

        const svc = runtime.config orelse return false;
        const cfg = svc.get() catch return false;
        return cfg.NoConfirm;
    }

    fn rowStageChanged(self: *Self, row: *PackageRow, stage: []const u8) bool {
        if (!stageChanged(row.stage, stage)) return false;

        const arena = self.priv().arena orelse return false;
        row.stage = arena.allocator().dupe(u8, stage) catch return false;
        return true;
    }

    fn reset(self: *Self) void {
        const p = self.priv();
        p.failure_message = null;
        p.cancelled = false;
        p.finished = false;
        gtk.Widget.setVisible(p.status_icon.as(gtk.Widget), 0);
        gtk.Widget.removeCssClass(p.status_icon.as(gtk.Widget), "success");
        gtk.Widget.removeCssClass(p.status_icon.as(gtk.Widget), "error");
        gtk.Widget.removeCssClass(p.status_icon.as(gtk.Widget), "warning");
        gtk.Widget.setVisible(p.close_button.as(gtk.Widget), 0);
        gtk.Widget.removeCssClass(p.close_button.as(gtk.Widget), "suggested-action");
        gtk.Widget.removeCssClass(p.close_button.as(gtk.Widget), "destructive-action");
        setLabel(p.status_label, "");
        var rows = p.rows.valueIterator();
        while (rows.next()) |row| stopRowPulse(row.*);
        while (gtk.Widget.getFirstChild(p.rows_box.as(gtk.Widget))) |c| {
            gtk.Box.remove(p.rows_box, c);
        }
        p.rows.clearRetainingCapacity();
        p.terminal_lines = .empty;

        const buffer = gtk.TextView.getBuffer(p.terminal_view);
        gtk.TextBuffer.setText(buffer, "", 0);
        p.progress_lines = .empty;

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }
    }

    fn build_row(alloc: std.mem.Allocator, name: [:0]const u8) !*PackageRow {
        const row = try alloc.create(PackageRow);

        const card = gtk.Box.new(.vertical, 6);
        gtk.Widget.addCssClass(card.as(gtk.Widget), "pkg-card");

        const row_top = gtk.Box.new(.horizontal, 8);

        const name_label = gtk.Label.new(name);
        gtk.Widget.setHalign(name_label.as(gtk.Widget), .start);
        gtk.Widget.setHexpand(name_label.as(gtk.Widget), 1);
        gtk.Label.setXalign(name_label, 0);
        gtk.Widget.addCssClass(name_label.as(gtk.Widget), "pkg-name");
        gtk.Label.setEllipsize(name_label, .end);
        gtk.Box.append(row_top, name_label.as(gtk.Widget));

        const status = gtk.Label.new(translations._("Pending"));
        gtk.Widget.setHalign(status.as(gtk.Widget), .end);
        gtk.Label.setXalign(status, 1);
        gtk.Widget.addCssClass(status.as(gtk.Widget), "pkg-status");
        gtk.Box.append(row_top, status.as(gtk.Widget));

        gtk.Box.append(card, row_top.as(gtk.Widget));

        const progress = gtk.ProgressBar.new();
        gtk.Widget.setHexpand(progress.as(gtk.Widget), 1);
        gtk.Box.append(card, progress.as(gtk.Widget));

        row.* = .{
            .name = name,
            .root = card,
            .status_label = status,
            .progress = progress,
        };
        return row;
    }

    fn on_op_event(ctx: *anyopaque, event: Event) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.handle_event(event);
    }
    fn on_op_done(ctx: *anyopaque, exit_code: u8) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.handle_done(exit_code);
    }

    fn handle_event(self: *Self, event: Event) void {
        switch (event) {
            .info => |i| {
                append_terminal(self, i.message);
                if (std.mem.eql(u8, i.event_type, "TransactionCancelled"))
                    self.priv().cancelled = true;

                if (std.mem.eql(u8, i.event_type, "TransactionStart")) {
                    // optionally set a global status line
                } else if (std.mem.eql(u8, i.event_type, "TransactionDone")) {
                    var it = self.priv().rows.valueIterator();
                    while (it.next()) |row| mark_row_done(row.*);
                } else if (std.mem.eql(u8, i.event_type, "TransactionFailed")) {
                    var it = self.priv().rows.valueIterator();
                    while (it.next()) |row| mark_row_failed(row.*);
                } else if (i.package_name) |name| {
                    if (find_row(self, name)) |row| {
                        setLabel(row.status_label, i.event_type);
                    }
                }
            },
            .err => |e| {
                append_terminal(self, e.message);
                const p = self.priv();
                if (p.failure_message == null) {
                    if (p.arena) |arena| p.failure_message = arena.allocator().dupe(u8, e.message) catch null;
                }
            },
            .alpm_progress => |pr| {
                appendAlpmProgress(self, pr);

                if (is_transaction_phase(pr.progress_type)) {
                    setLabel(self.priv().status_label, phase_label(pr.progress_type));
                    return;
                }

                const is_database = std.mem.eql(u8, pr.progress_type, "DatabaseDownload");
                if (is_database) {
                    setLabel(self.priv().status_label, translations._("Synchronizing databases"));
                }

                const display_name = if (is_database)
                    std.fs.path.basename(pr.package_name)
                else
                    pr.package_name;

                if (ensure_row_named(self, pr.package_name, display_name)) |row| {
                    const stage = nonEmpty(pr.stage) orelse pr.progress_type;
                    if (rowStageChanged(self, row, stage)) {
                        stopRowPulse(row);
                        gtk.ProgressBar.setFraction(row.progress, 0.0);
                    }
                    if (isAurPackageFailed(pr.stage)) {
                        var key_buf: [256]u8 = undefined;
                        finalizeProgressKey(self, progressKey(&key_buf, pr));
                        mark_row_failed(row);
                        return;
                    }
                    if (isAurPackageCompleted(pr.stage)) {
                        var key_buf: [256]u8 = undefined;
                        finalizeProgressKey(self, progressKey(&key_buf, pr));
                        mark_row_done(row);
                        return;
                    }
                    if (isAurBuildStart(pr.progress_type, pr.stage)) {
                        setLabel(row.status_label, translations._("Building"));
                        startRowPulse(row);
                        return;
                    }

                    stopRowPulse(row);
                    gtk.ProgressBar.setFraction(row.progress, progressFraction(
                        pr.progress_type,
                        pr.stage,
                        pr.percent,
                        pr.current_download,
                        pr.total_download,
                    ));
                    setLabel(row.status_label, nonEmpty(pr.message) orelse phase_label(pr.progress_type));
                }
            },
            .flatpak_progress => |pr| {
                handleSimpleProgress(self, translations._("Flatpak"), pr.status, pr.percentage);
            },
            .appimage_progress => |pr| {
                handleSimpleProgress(self, translations._("AppImage"), pr.status, pr.percentage);
            },
            .unknown => {},
        }
    }

    fn progressKey(buf: []u8, pr: anytype) []const u8 {
        return std.fmt.bufPrint(buf, "{s}:{s}", .{ pr.progress_type, pr.package_name }) catch pr.package_name;
    }

    fn is_transaction_phase(progress_type: []const u8) bool {
        return std.mem.eql(u8, progress_type, "LoadStart") or
            std.mem.eql(u8, progress_type, "KeyringStart") or
            std.mem.eql(u8, progress_type, "IntegrityStart") or
            std.mem.eql(u8, progress_type, "ConflictsStart") or
            std.mem.eql(u8, progress_type, "DiskspaceStart");
    }

    fn ensure_row_named(self: *Self, key: []const u8, display: []const u8) ?*PackageRow {
        const p = self.priv();
        if (key.len == 0) return null;
        if (p.rows.get(key)) |row| return row;

        const arena = p.arena orelse return null;
        const alloc = arena.allocator();
        const owned_key = alloc.dupeZ(u8, key) catch return null;
        const owned_display = alloc.dupeZ(u8, display) catch return null;
        const row = build_row(alloc, owned_display) catch return null;

        gtk.Box.append(p.rows_box, row.root.as(gtk.Widget));
        p.rows.put(alloc, owned_key, row) catch return null;
        return row;
    }

    fn phase_label(progress_type: []const u8) []const u8 {
        if (std.mem.eql(u8, progress_type, "AurDownload")) return translations._("Downloading");
        if (std.mem.eql(u8, progress_type, "MakepkgBuild")) return translations._("Building");
        if (std.mem.eql(u8, progress_type, "MakepkgPackage")) return translations._("Packaging");
        if (std.mem.eql(u8, progress_type, "PackageDownload")) return translations._("Downloading");
        if (std.mem.eql(u8, progress_type, "DatabaseDownload")) return translations._("Downloading");
        if (std.mem.eql(u8, progress_type, "AddStart")) return translations._("Installing");
        if (std.mem.eql(u8, progress_type, "UpgradeStart")) return translations._("Upgrading");
        if (std.mem.eql(u8, progress_type, "DowngradeStart")) return translations._("Downgrading");
        if (std.mem.eql(u8, progress_type, "ReinstallStart")) return translations._("Reinstalling");
        if (std.mem.eql(u8, progress_type, "RemoveStart")) return translations._("Removing");
        if (std.mem.eql(u8, progress_type, "KeyringStart")) return translations._("Checking keyring");
        if (std.mem.eql(u8, progress_type, "IntegrityStart")) return translations._("Checking integrity");
        if (std.mem.eql(u8, progress_type, "LoadStart")) return translations._("Loading packages");
        if (std.mem.eql(u8, progress_type, "ConflictsStart")) return translations._("Checking conflicts");
        if (std.mem.eql(u8, progress_type, "DiskspaceStart")) return translations._("Checking disk space");
        return translations._("Working");
    }

    fn fractionFromPercent(percent: i64) f64 {
        const clamped = if (percent < 0)
            0
        else if (percent > 100)
            100
        else
            percent;

        return @as(f64, @floatFromInt(clamped)) / 100.0;
    }

    fn progressFraction(
        progress_type: []const u8,
        stage: ?[]const u8,
        percent: i64,
        current: i64,
        total: i64,
    ) f64 {
        if (isDownloadProgress(progress_type) and
            !isAurLifecycleStage(stage) and
            total > 0)
        {
            const safe_current = @max(current, 0);
            const fraction = @as(f64, @floatFromInt(safe_current)) /
                @as(f64, @floatFromInt(total));
            return @min(fraction, 1.0);
        }
        return fractionFromPercent(percent);
    }

    fn isDownloadProgress(progress_type: []const u8) bool {
        return std.mem.eql(u8, progress_type, "PackageDownload") or
            std.mem.eql(u8, progress_type, "DatabaseDownload") or
            std.mem.eql(u8, progress_type, "AurDownload");
    }

    fn stageChanged(previous: ?[]const u8, current: []const u8) bool {
        const old = previous orelse return true;
        return !std.mem.eql(u8, old, current);
    }

    fn nonEmpty(value: ?[]const u8) ?[]const u8 {
        const text = value orelse return null;
        return if (text.len == 0) null else text;
    }

    fn find_row(self: *Self, name: []const u8) ?*PackageRow {
        return self.priv().rows.get(name);
    }

    fn isAurLifecycleStage(stage: ?[]const u8) bool {
        const value = stage orelse return false;
        return std.mem.startsWith(u8, value, "aur_");
    }

    fn isAurBuildStart(progress_type: []const u8, stage: ?[]const u8) bool {
        return std.mem.eql(u8, progress_type, "MakepkgBuild") and
            if (stage) |value| std.mem.eql(u8, value, "aur_build_start") else false;
    }

    fn isAurPackageFailed(stage: ?[]const u8) bool {
        return if (stage) |value| std.mem.eql(u8, value, "aur_package_failed") else false;
    }

    fn isAurPackageCompleted(stage: ?[]const u8) bool {
        return if (stage) |value| std.mem.eql(u8, value, "aur_package_completed") else false;
    }

    fn startRowPulse(row: *PackageRow) void {
        if (row.pulse_source != 0) return;
        gtk.ProgressBar.pulse(row.progress);
        row.pulse_source = glib.timeoutAdd(100, &onRowPulse, row);
    }

    fn stopRowPulse(row: *PackageRow) void {
        if (row.pulse_source == 0) return;
        _ = glib.Source.remove(row.pulse_source);
        row.pulse_source = 0;
    }

    fn onRowPulse(data: ?*anyopaque) callconv(.c) c_int {
        const row: *PackageRow = @ptrCast(@alignCast(data.?));
        if (row.pulse_source == 0) return 0;
        gtk.ProgressBar.pulse(row.progress);
        return 1;
    }

    fn mark_row_done(row: *PackageRow) void {
        stopRowPulse(row);
        gtk.Label.setLabel(row.status_label, translations._("Done"));
        gtk.ProgressBar.setFraction(row.progress, 1.0);
        gtk.Widget.addCssClass(row.status_label.as(gtk.Widget), "status-done");
    }

    fn mark_row_failed(row: *PackageRow) void {
        stopRowPulse(row);
        gtk.Label.setLabel(row.status_label, translations._("Failed"));
        gtk.ProgressBar.setFraction(row.progress, 1.0);
        gtk.Widget.addCssClass(row.status_label.as(gtk.Widget), "status-failed");
    }

    const Outcome = enum { success, failed, cancelled };

    fn showFinishedUI(self: *Self, outcome: Outcome, detail: []const u8) void {
        const p = self.priv();

        const icon: [:0]const u8 = switch (outcome) {
            .success => "checkmark-small-symbolic",
            .failed => "dialog-error-symbolic",
            .cancelled => "dialog-warning-symbolic",
        };
        const tone: [:0]const u8 = switch (outcome) {
            .success => "success",
            .failed => "error",
            .cancelled => "warning",
        };

        gtk.Image.setFromIconName(p.status_icon, icon);
        gtk.Widget.setVisible(p.status_icon.as(gtk.Widget), 1);
        gtk.Widget.removeCssClass(p.status_icon.as(gtk.Widget), "success");
        gtk.Widget.removeCssClass(p.status_icon.as(gtk.Widget), "error");
        gtk.Widget.removeCssClass(p.status_icon.as(gtk.Widget), "warning");
        gtk.Widget.addCssClass(p.status_icon.as(gtk.Widget), tone);

        gtk.Widget.removeCssClass(p.close_button.as(gtk.Widget), "suggested-action");
        gtk.Widget.removeCssClass(p.close_button.as(gtk.Widget), "destructive-action");
        switch (outcome) {
            .success => {
                gtk.Widget.addCssClass(p.close_button.as(gtk.Widget), "suggested-action");
                gtk.Button.setLabel(p.close_button, translations._("Done"));
                setLabel(p.title_label, translations._("Transaction Completed"));
            },
            .failed => {
                gtk.Widget.addCssClass(p.close_button.as(gtk.Widget), "destructive-action");
                gtk.Button.setLabel(p.close_button, translations._("Close"));
                setLabel(p.title_label, translations._("Transaction Failed"));
            },
            .cancelled => {
                gtk.Button.setLabel(p.close_button, translations._("Close"));
                setLabel(p.title_label, translations._("Transaction Cancelled"));
            },
        }

        setLabel(p.status_label, detail);
        gtk.Widget.setVisible(p.close_button.as(gtk.Widget), 1);
        _ = gtk.Widget.grabFocus(p.close_button.as(gtk.Widget));
    }

    fn handle_done(self: *Self, exit_code: u8) void {
        const p = self.priv();
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s} ({s} {d})", .{ translations._("Finished"), translations._("exit"), exit_code }) catch translations._("Finished");
        append_terminal(self, msg);

        p.finished = true;

        const outcome: Outcome = if (p.cancelled)
            .cancelled
        else if (exit_code == 0)
            .success
        else
            .failed;

        switch (outcome) {
            .cancelled => self.showFinishedUI(outcome, translations._("The operation was cancelled.")),
            .success => self.showFinishedUI(outcome, translations._("All operations finished successfully.")),
            .failed => {
                var fail_buf: [128]u8 = undefined;
                const fallback = if (p.privileged and (exit_code == 126 or exit_code == 127))
                    translations._("Permission to manage packages was not granted. Try again and approve the authorization request to continue.")
                else
                    std.fmt.bufPrint(&fail_buf, "{s} ({s} {d})", .{ translations._("Operation failed"), translations._("exit"), exit_code }) catch translations._("Operation failed");
                const detail = p.failure_message orelse fallback;
                const end = std.mem.indexOf(u8, detail, "\n\nTechnical details:") orelse
                    std.mem.indexOf(u8, detail, "\nTechnical details:") orelse detail.len;
                self.showFinishedUI(outcome, detail[0..end]);
            },
        }

        var it = p.rows.valueIterator();
        while (it.next()) |row_ptr| {
            const row = row_ptr.*;
            switch (outcome) {
                .success => mark_row_done(row),
                .failed => mark_row_failed(row),
                .cancelled => {
                    stopRowPulse(row);
                    gtk.Label.setLabel(row.status_label, translations._("Cancelled"));
                },
            }
        }

        if (p.on_complete) |cb| {
            log.debug("on_complete set, ctx={}", .{p.on_complete_ctx != null});
            if (p.on_complete_ctx) |c| cb(c, exit_code == 0 and !p.cancelled);
        } else {
            log.debug("on_complete is NULL", .{});
        }

        if (p.operation) |op| {
            if (op.reader) |t| t.join();
            op.threaded.deinit();
            std.heap.c_allocator.destroy(op);
            p.operation = null;
        }
    }

    fn appendAlpmProgress(self: *Self, pr: anytype) void {
        const line = formatAlpmProgress(std.heap.c_allocator, pr) catch return;
        defer std.heap.c_allocator.free(line);

        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ pr.progress_type, pr.package_name }) catch line;
        updateProgressLine(self, key, line);
    }

    fn formatAlpmProgress(allocator: std.mem.Allocator, pr: anytype) ![]u8 {
        const message = nonEmpty(pr.message) orelse
            nonEmpty(pr.stage) orelse
            phase_label(pr.progress_type);
        const display_name = if (std.mem.eql(u8, pr.progress_type, "DatabaseDownload"))
            std.fs.path.basename(pr.package_name)
        else
            pr.package_name;
        return std.fmt.allocPrint(
            allocator,
            "[{s}] {s} — {s} ({d}%)",
            .{ pr.progress_type, display_name, message, pr.percent },
        );
    }

    fn handleSimpleProgress(
        self: *Self,
        backend: []const u8,
        status: ?[]const u8,
        percentage: i64,
    ) void {
        const message = nonEmpty(status) orelse translations._("Working");
        if (formatSimpleProgress(std.heap.c_allocator, backend, status, percentage)) |line| {
            defer std.heap.c_allocator.free(line);
            updateProgressLine(self, backend, line);
        } else |_| {}

        if (ensure_row_named(self, backend, backend)) |row| {
            setLabel(row.status_label, message);
            gtk.ProgressBar.setFraction(row.progress, fractionFromPercent(percentage));
        }
    }

    fn formatSimpleProgress(
        allocator: std.mem.Allocator,
        backend: []const u8,
        status: ?[]const u8,
        percentage: i64,
    ) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "[{s}] {s} ({d}%)",
            .{ backend, nonEmpty(status) orelse translations._("Working"), percentage },
        );
    }

    fn setLabel(label: *gtk.Label, text: []const u8) void {
        const value = std.heap.c_allocator.dupeZ(u8, text) catch return;
        defer std.heap.c_allocator.free(value);
        gtk.Label.setLabel(label, value);
    }

    fn append_terminal(self: *Self, text: []const u8) void {
        const p = self.priv();
        const normalized = normalizeTerminalText(text);
        if (p.arena) |arena| {
            if (!rememberTerminalLine(arena.allocator(), &p.terminal_lines, normalized)) return;
        }

        const buffer = gtk.TextView.getBuffer(p.terminal_view);
        var end: gtk.TextIter = undefined;
        gtk.TextBuffer.getEndIter(buffer, &end);

        const normalized_z = std.heap.c_allocator.dupeZ(u8, normalized) catch return;
        defer std.heap.c_allocator.free(normalized_z);
        gtk.TextBuffer.insert(buffer, &end, normalized_z, @intCast(normalized.len));
        gtk.TextBuffer.insert(buffer, &end, "\n", 1);

        self.scrollTerminalToBottom();
    }

    fn scratchZ(self: *Self, s: []const u8) [:0]const u8 {
        const p = self.priv();
        const n = @min(s.len, p.scratch.len - 1);
        @memcpy(p.scratch[0..n], s[0..n]);
        p.scratch[n] = 0;
        return p.scratch[0..n :0];
    }

    fn updateProgressLine(self: *Self, key: []const u8, text: []const u8) void {
        const p = self.priv();
        const normalized = normalizeTerminalText(text);
        const buffer = gtk.TextView.getBuffer(p.terminal_view);

        const text_z = self.scratchZ(normalized);

        if (p.progress_lines.get(key)) |line| {
            var start: gtk.TextIter = undefined;
            gtk.TextBuffer.getIterAtMark(buffer, &start, line.start);

            var end = start;
            if (gtk.TextIter.getCharsInLine(&end) > 0) {
                _ = gtk.TextIter.forwardToLineEnd(&end);
            }
            gtk.TextBuffer.delete(buffer, &start, &end);
            gtk.TextBuffer.getIterAtMark(buffer, &start, line.start);
            gtk.TextBuffer.insert(buffer, &start, text_z, @intCast(normalized.len));
        } else {
            const arena = p.arena orelse return;
            var end: gtk.TextIter = undefined;
            gtk.TextBuffer.getEndIter(buffer, &end);
            const start_mark = gtk.TextBuffer.createMark(buffer, null, &end, 1);
            gtk.TextBuffer.insert(buffer, &end, text_z, @intCast(normalized.len));
            const end_mark = gtk.TextBuffer.createMark(buffer, null, &end, 0);
            gtk.TextBuffer.insert(buffer, &end, "\n", 1);

            const owned_key = arena.allocator().dupe(u8, key) catch return;
            p.progress_lines.put(arena.allocator(), owned_key, .{ .start = start_mark, .end = end_mark }) catch return;
        }

        self.scrollTerminalToBottom();
    }

    fn finalizeProgressKey(self: *Self, key: []const u8) void {
        const p = self.priv();
        if (p.progress_lines.fetchRemove(key)) |kv| {
            const buffer = gtk.TextView.getBuffer(p.terminal_view);
            gtk.TextBuffer.deleteMark(buffer, kv.value.start);
            gtk.TextBuffer.deleteMark(buffer, kv.value.end);
        }
    }

    fn scrollTerminalToBottom(self: *Self) void {
        const p = self.priv();
        const buffer = gtk.TextView.getBuffer(p.terminal_view);
        var end: gtk.TextIter = undefined;
        gtk.TextBuffer.getEndIter(buffer, &end);
        const mark = gtk.TextBuffer.createMark(buffer, null, &end, 0);
        gtk.TextView.scrollToMark(p.terminal_view, mark, 0, 1, 0, 1);
        gtk.TextBuffer.deleteMark(buffer, mark);
    }

    fn rememberTerminalLine(
        allocator: std.mem.Allocator,
        lines: *std.StringHashMapUnmanaged(void),
        line: []const u8,
    ) bool {
        if (lines.contains(line)) return false;

        const owned = allocator.dupe(u8, line) catch return true;
        lines.put(allocator, owned, {}) catch {
            allocator.free(owned);
            return true;
        };
        return true;
    }

    fn normalizeTerminalText(text: []const u8) []const u8 {
        var end = text.len;
        while (end > 0 and (text[end - 1] == '\r' or text[end - 1] == '\n')) {
            end -= 1;
        }
        return text[0..end];
    }

    fn on_terminal_toggle(self: *Self) callconv(.c) void {
        const p = self.priv();
        p.terminal_visible = !p.terminal_visible;
        gtk.Widget.setVisible(p.terminal_scroll.as(gtk.Widget), @intFromBool(p.terminal_visible));
    }

    fn on_close(self: *Self) callconv(.c) void {
        if (support.getWindow(ShellyWindow, self)) |win| {
            win.hideLockout();
        }
    }

    fn on_key_pressed(self: *Self, keyval: c_uint, keycode: c_uint, state: gdk.ModifierType) callconv(.c) c_int {
        const p = self.priv();
        if (!p.finished) return 0;
        if (keyval == gdk.KEY_Escape) {
            if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
            return 1;
        }
        _ = keycode;
        _ = state;
        return 0;
    }

    fn on_op_question(ctx: *anyopaque, pending: *PendingQuestion) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.handle_question(pending);
    }

    fn getQuestionText(question_kind: []const u8, fallback: []const u8) []const u8 {
        if (std.mem.eql(u8, question_kind, "CacheCleanExtraEntries")) {
            return translations._("Would you like to remove extra cache entries?");
        }
        return fallback;
    }

    fn handle_question(self: *Self, pending: *PendingQuestion) void {
        const p = self.priv();
        log.debug("handle_question: question_layer={*}", .{p.question_layer});

        switch (pending.request) {
            .yes_no => |q| {
                const qa = pending.arena.allocator();

                const text = getQuestionText(q.question_kind, q.question_text);

                const text_z = qa.dupeZ(u8, text) catch {
                    pending.operation.answerYesNo(q.question_id, false) catch {};
                    pending.destroy();
                    return;
                };

                pending.on_dismiss = &dismiss_question;
                pending.dismiss_ctx = self;

                const dialog = ConfirmDialog.new(translations._("Confirm"), text_z, &on_yesno_response, pending);
                dialog.setButtons(translations._("Yes"), translations._("No"));

                gtk.Box.append(p.question_layer, dialog.as(gtk.Widget));
                gtk.Widget.setVisible(p.question_layer.as(gtk.Widget), 1);
                gtk.Widget.setVisible(dialog.as(gtk.Widget), 1);
                gtk.Widget.setHalign(p.question_layer.as(gtk.Widget), .center);
                gtk.Widget.setValign(p.question_layer.as(gtk.Widget), .center);
                log.debug("dialog widget: {*}, visible={}", .{ dialog, gtk.Widget.getVisible(dialog.as(gtk.Widget)) });
            },
            .select_many => |q| {
                pending.on_dismiss = &dismiss_question;
                pending.dismiss_ctx = self;

                const dialog = MultiSelectDialog.new(
                    pending.arena.allocator(),
                    q.prompt,
                    q.options,
                    &on_multiselect_response,
                    pending,
                );

                gtk.Box.append(p.question_layer, dialog.as(gtk.Widget));
                gtk.Widget.setVisible(p.question_layer.as(gtk.Widget), 1);
            },
            .select_one => |q| {
                log.debug("select_one: {s}", .{q.prompt});
                pending.on_dismiss = &dismiss_question;
                pending.dismiss_ctx = self;

                const dialog = ProviderDialog.new(
                    pending.arena.allocator(),
                    "Select Provider",
                    q.options,
                    &on_single_select_response,
                    pending,
                );

                gtk.Box.append(p.question_layer, dialog.as(gtk.Widget));
                gtk.Widget.setVisible(p.question_layer.as(gtk.Widget), 1);
            },
            .pkgbuild => |q| {
                var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
                defer arena.deinit();
                const a = arena.allocator();

                const name = a.dupeZ(u8, q.package_name) catch return;

                const lines = a.alloc([:0]const u8, q.diff_lines.len) catch return;
                for (q.diff_lines, 0..) |line, i| {
                    lines[i] = a.dupeZ(u8, line) catch return;
                }

                const warns = a.alloc(PkgbuildReviewDialog.Warning, q.warnings.len) catch return;
                for (q.warnings, 0..) |w, i| {
                    warns[i] = .{
                        .tool = a.dupeZ(u8, w.Tool) catch return,
                        .hook = a.dupeZ(u8, w.Hook) catch return,
                        .severity = a.dupeZ(u8, w.Severity) catch return,
                        .message = a.dupeZ(u8, w.Message) catch return,
                        .matched_line = a.dupeZ(u8, w.MatchedLine) catch return,
                    };
                }

                pending.on_dismiss = &dismiss_question;
                pending.dismiss_ctx = self;

                const sources = a.alloc(
                    PkgbuildReviewDialog.SourceFile,
                    q.source_files.len,
                ) catch return;

                for (q.source_files, sources) |source, *target| {
                    target.* = .{
                        .name = a.dupeZ(u8, source.name) catch return,
                        .content = a.dupeZ(u8, source.content) catch return,
                    };
                }

                const dialog = PkgbuildReviewDialog.new(
                    name,
                    lines,
                    warns,
                    sources,
                    &on_pkgbuild_response,
                    pending,
                );
                if (support.getWindow(ShellyWindow, self)) |win| {
                    gtk.Window.setTransientFor(dialog.as(gtk.Window), win.as(gtk.Window));
                }
                dialog.present();
            },
            .transaction => |q| {
                pending.on_dismiss = &dismiss_question;
                pending.dismiss_ctx = self;
                const dialog = PlanDialog.new(q, &on_plan_response, pending);
                gtk.Box.append(p.question_layer, dialog.as(gtk.Widget));
                gtk.Widget.setVisible(p.question_layer.as(gtk.Widget), 1);
            },
        }
    }

    fn on_plan_response(ctx: ?*anyopaque, confirmed: bool) void {
        const pending: *PendingQuestion = @ptrCast(@alignCast(ctx.?));
        respondToTransaction(pending, confirmed);
    }

    fn respondToTransaction(pending: *PendingQuestion, accepted: bool) void {
        if (pending.completed) return;
        pending.completed = true;
        pending.operation.answerTransaction(pending.questionId(), accepted) catch {
            pending.operation.cancel();
        };
        if (pending.on_dismiss) |cb| {
            if (pending.dismiss_ctx) |ctx| cb(ctx);
        }
        pending.destroy();
    }

    fn on_multiselect_response(ctx: ?*anyopaque, confirmed: bool, selected: []const usize) void {
        const pending: *PendingQuestion = @ptrCast(@alignCast(ctx.?));
        if (pending.completed) return;
        pending.completed = true;

        if (confirmed) {
            pending.operation.answerOptDeps(pending.questionId(), selected) catch {
                pending.operation.cancel();
            };
        } else {
            pending.operation.answerOptDeps(pending.questionId(), &.{}) catch {
                pending.operation.cancel();
            };
        }

        if (pending.on_dismiss) |cb| {
            if (pending.dismiss_ctx) |c| cb(c);
        }
        pending.destroy();
    }

    fn on_single_select_response(ctx: ?*anyopaque, confirmed: bool, selected: usize) void {
        const pending: *PendingQuestion = @ptrCast(@alignCast(ctx.?));
        if (pending.completed) return;
        pending.completed = true;

        if (confirmed) {
            pending.operation.answerProvider(pending.questionId(), selected) catch {
                pending.operation.cancel();
            };
        } else {
            pending.operation.answerProvider(pending.questionId(), 0) catch {
                pending.operation.cancel();
            };
        }

        if (pending.on_dismiss) |cb| {
            if (pending.dismiss_ctx) |c| cb(c);
        }
        pending.destroy();
    }

    fn on_pkgbuild_response(ctx: ?*anyopaque, confirmed: bool) void {
        const pending: *PendingQuestion = @ptrCast(@alignCast(ctx.?));
        if (pending.completed) return;
        pending.completed = true;

        if (confirmed) {
            pending.operation.answerPkgbuildDiff(
                pending.questionId(),
                true,
            ) catch {
                pending.operation.cancel();
            };
        } else {
            pending.operation.answerPkgbuildDiff(pending.questionId(), false) catch {
                pending.operation.cancel();
            };
        }

        if (pending.on_dismiss) |cb| {
            if (pending.dismiss_ctx) |c| cb(c);
        }
        pending.destroy();
    }

    fn dismiss_question(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const p = self.priv();

        while (gtk.Widget.getFirstChild(p.question_layer.as(gtk.Widget))) |c| {
            gtk.Box.remove(p.question_layer, c);
        }
        gtk.Widget.setVisible(p.question_layer.as(gtk.Widget), 0);
    }

    fn on_yesno_response(ctx: ?*anyopaque, confirmed: bool) void {
        const pending: *PendingQuestion = @ptrCast(@alignCast(ctx.?));
        if (pending.completed) return;
        pending.completed = true;

        pending.operation.answerYesNo(pending.questionId(), confirmed) catch {
            pending.operation.cancel();
        };

        if (pending.on_dismiss) |cb| {
            if (pending.dismiss_ctx) |c| cb(c);
        }

        pending.destroy();
    }
    const template_children = .{
        .{ "status_icon", @offsetOf(Private, "status_icon") },
        .{ "title_label", @offsetOf(Private, "title_label") },
        .{ "terminal_toggle", @offsetOf(Private, "terminal_toggle") },
        .{ "paned", @offsetOf(Private, "paned") },
        .{ "rows_box", @offsetOf(Private, "rows_box") },
        .{ "terminal_scroll", @offsetOf(Private, "terminal_scroll") },
        .{ "terminal_view", @offsetOf(Private, "terminal_view") },
        .{ "close_button", @offsetOf(Private, "close_button") },
        .{ "question_layer", @offsetOf(Private, "question_layer") },
        .{ "status_label", @offsetOf(Private, "status_label") },
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
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_terminal_toggle", @ptrCast(&on_terminal_toggle));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_close", @ptrCast(&on_close));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_key_pressed", @ptrCast(&on_key_pressed));
        }
    };

    fn finalize(self: *Self) callconv(.c) void {
        const p = self.priv();
        var rows = p.rows.valueIterator();
        while (rows.next()) |row| stopRowPulse(row.*);
        if (p.operation) |op| {
            op.cancel();
            if (op.reader) |t| t.join();
            op.threaded.deinit();
            std.heap.c_allocator.destroy(op);
            p.operation = null;
        }
        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }

        const parent_class: *gobject.Object.Class = @ptrCast(Class.parent);
        gobject.Object.virtual_methods.finalize.call(parent_class, self.as(gobject.Object));
    }
};

test "transaction progress helpers preserve determinate percentages" {
    try std.testing.expectEqual(@as(f64, 0.0), TransactionPage.fractionFromPercent(-1));
    try std.testing.expectEqual(@as(f64, 0.0), TransactionPage.fractionFromPercent(0));
    try std.testing.expectEqual(@as(f64, 0.37), TransactionPage.fractionFromPercent(37));
    try std.testing.expectEqual(@as(f64, 1.0), TransactionPage.fractionFromPercent(100));
    try std.testing.expectEqual(@as(f64, 1.0), TransactionPage.fractionFromPercent(101));

    try std.testing.expectEqual(
        @as(f64, 0.5),
        TransactionPage.progressFraction("PackageDownload", null, 10, 50, 100),
    );
    try std.testing.expectEqual(
        @as(f64, 1.0),
        TransactionPage.progressFraction("DatabaseDownload", null, 10, 150, 100),
    );
    try std.testing.expectEqual(
        @as(f64, 0.0),
        TransactionPage.progressFraction("AurDownload", null, 10, -1, 100),
    );
    try std.testing.expectEqual(
        @as(f64, 0.37),
        TransactionPage.progressFraction("AddStart", null, 37, 0, 0),
    );
    try std.testing.expectEqual(
        @as(f64, 0.0),
        TransactionPage.progressFraction("AurDownload", "aur_download_start", 0, 1, 1),
    );
}

test "database downloads use independent downloading rows" {
    try std.testing.expect(!TransactionPage.is_transaction_phase("DatabaseDownload"));
    try std.testing.expectEqualStrings("Downloading", TransactionPage.phase_label("DatabaseDownload"));
}

test "transaction preparation phases map to descriptive labels" {
    try std.testing.expect(TransactionPage.is_transaction_phase("KeyringStart"));
    try std.testing.expect(TransactionPage.is_transaction_phase("IntegrityStart"));
    try std.testing.expect(TransactionPage.is_transaction_phase("LoadStart"));
    try std.testing.expect(TransactionPage.is_transaction_phase("ConflictsStart"));
    try std.testing.expect(TransactionPage.is_transaction_phase("DiskspaceStart"));

    try std.testing.expectEqualStrings("Checking keyring", TransactionPage.phase_label("KeyringStart"));
    try std.testing.expectEqualStrings("Checking integrity", TransactionPage.phase_label("IntegrityStart"));
    try std.testing.expectEqualStrings("Loading packages", TransactionPage.phase_label("LoadStart"));
    try std.testing.expectEqualStrings("Checking conflicts", TransactionPage.phase_label("ConflictsStart"));
    try std.testing.expectEqualStrings("Checking disk space", TransactionPage.phase_label("DiskspaceStart"));
}

test "transaction rows detect progress stage changes" {
    try std.testing.expect(TransactionPage.stageChanged(null, "download"));
    try std.testing.expect(!TransactionPage.stageChanged("download", "download"));
    try std.testing.expect(TransactionPage.stageChanged("download", "transaction"));
}

test "AUR build lifecycle selects indeterminate and terminal row states" {
    try std.testing.expect(TransactionPage.isAurLifecycleStage("aur_build_start"));
    try std.testing.expect(!TransactionPage.isAurLifecycleStage("makepkg_build"));
    try std.testing.expect(TransactionPage.isAurBuildStart("MakepkgBuild", "aur_build_start"));
    try std.testing.expect(!TransactionPage.isAurBuildStart("MakepkgBuild", "makepkg_build"));
    try std.testing.expect(TransactionPage.isAurPackageFailed("aur_package_failed"));
    try std.testing.expect(TransactionPage.isAurPackageCompleted("aur_package_completed"));
}

test "progress console lines include backend stage and percentage" {
    const database_line = try TransactionPage.formatAlpmProgress(std.testing.allocator, .{
        .progress_type = "DatabaseDownload",
        .package_name = "/var/lib/pacman/sync/extra.db",
        .message = @as(?[]const u8, null),
        .stage = @as(?[]const u8, "download"),
        .percent = 52,
    });
    defer std.testing.allocator.free(database_line);
    try std.testing.expectEqualStrings(
        "[DatabaseDownload] extra.db — download (52%)",
        database_line,
    );

    const install_line = try TransactionPage.formatAlpmProgress(std.testing.allocator, .{
        .progress_type = "AddStart",
        .package_name = "demo",
        .message = @as(?[]const u8, "Installing files"),
        .stage = @as(?[]const u8, "transaction"),
        .percent = 37,
    });
    defer std.testing.allocator.free(install_line);
    try std.testing.expectEqualStrings(
        "[AddStart] demo — Installing files (37%)",
        install_line,
    );

    const simple_line = try TransactionPage.formatSimpleProgress(
        std.testing.allocator,
        "Flatpak",
        "Updating runtime",
        68,
    );
    defer std.testing.allocator.free(simple_line);
    try std.testing.expectEqualStrings("[Flatpak] Updating runtime (68%)", simple_line);

    const fallback_line = try TransactionPage.formatSimpleProgress(
        std.testing.allocator,
        "AppImage",
        null,
        0,
    );
    defer std.testing.allocator.free(fallback_line);
    try std.testing.expectEqualStrings("[AppImage] Working (0%)", fallback_line);
}

test "terminal normalization preserves long and multiline output" {
    var long_text: [2048]u8 = undefined;
    @memset(&long_text, 'x');
    const normalized_long = TransactionPage.normalizeTerminalText(&long_text);
    try std.testing.expectEqual(@as(usize, long_text.len), normalized_long.len);
    try std.testing.expectEqualStrings("first\nsecond", TransactionPage.normalizeTerminalText("first\nsecond\r\n"));
}

test "terminal output suppresses duplicate lines and preserves unique updates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lines: std.StringHashMapUnmanaged(void) = .empty;

    try std.testing.expect(TransactionPage.rememberTerminalLine(
        arena.allocator(),
        &lines,
        "Downloading firefox (10%)",
    ));
    try std.testing.expect(!TransactionPage.rememberTerminalLine(
        arena.allocator(),
        &lines,
        "Downloading firefox (10%)",
    ));
    try std.testing.expect(TransactionPage.rememberTerminalLine(
        arena.allocator(),
        &lines,
        "Downloading firefox (11%)",
    ));
    try std.testing.expect(TransactionPage.rememberTerminalLine(
        arena.allocator(),
        &lines,
        "Downloading linux (10%)",
    ));
    try std.testing.expect(!TransactionPage.rememberTerminalLine(
        arena.allocator(),
        &lines,
        "Downloading firefox (10%)",
    ));
}
