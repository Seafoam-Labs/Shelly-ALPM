//! Shared authentication, transaction questions, PKGBUILD review, and results.
const aur_model = @import("aur_model.zig");
const packages_model = @import("packages_model.zig");
const std = @import("std");
const commands = @import("../commands.zig");
const pkgbuild_view = @import("../views/pkgbuild_view.zig");
const PkgBuild = @import("pkgbuild.zig").PkgBuild;
const operation_view = @import("../views/operation_view.zig");
const shelly_operation = @import("../services/shelly_operation.zig");
const diagnostics = @import("diagnostics");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const shelly_cli = @import("../services/shelly_cli.zig");
const ShellyCli = shelly_cli.ShellyCli;
const runtime = @import("../runtime.zig");
const Package = @import("packages.zig").Package;
const AurPackage = @import("packages.zig").AurPackage;

const flatpak = @import("flatpak.zig");

const Allocator = std.mem.Allocator;
const OperationBackend = shelly_operation.Backend;

const coordinator = @import("../model.zig");
const Model = coordinator.Model;
const AurSearchJob = aur_model.AurSearchJob;

/// Page-owned state. Worker results are published to the UI loop before use.
pub const State = struct {
    pkgbuild_name: []const u8 = "",
    pkgbuild_generation: u64 = 0,
    pkgbuild_job: ?*PkgbuildJob = null,
    pkgbuild_thread: ?std.Thread = null,
    pkgbuild_document: ?pkgbuild_view.Document = null,
    pkgbuild_failure: ?anyerror = null,
    pkgbuild_scan_status: []const u8 = "",
    pkgbuild_wrap: bool = true,
    pkgbuild_scroll: vxfw.ScrollView,

    /// The currently running install, if any.
    install_job: ?*shelly_operation.Operation = null,
    sudo_session: shelly_operation.Session = .{},
    dependency_choices: vxfw.ListView,
    operation_question: ?shelly_operation.OwnedMessage = null,
    review_prompt: ?*SudoPrompt = null,
    answer_input: std.ArrayList(u8) = .empty,
    answer_error: []const u8 = "",
};

pub const PkgbuildJob = struct {
    name: []const u8,
    atoll: bool = false,
    generation: u64 = 0,
    mode: ShellyCli.PkgbuildFetchMode = .preview,
    expected_content: ?[]const u8 = null,
    result: ?std.json.Parsed([]PkgBuild) = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
};

pub const SudoPrompt = struct {
    /// Package being installed; owned by `gpa`.
    name: []const u8,
    targets: []const []const u8 = &.{},
    review_text: []const u8 = "",
    panel: operation_view.Panel = .{},
    backend: OperationBackend,
    action: shelly_operation.Action = .install,
    elevated: bool = true,
    include_flatpak: bool = true,
    include_aur: bool = true,
    flatpak_target: ?shelly_operation.FlatpakTarget = null,
    state: SudoPrompt.State = .entering,
    /// Failure detail shown after a failed attempt; owned by `gpa`.
    detail: []const u8 = "",

    progress: shelly_operation.Progress = .{},

    pub const State = enum { entering, running, succeeded, failed, declined };

    pub fn deinit(self: *SudoPrompt, gpa: Allocator) void {
        gpa.free(self.name);
        for (self.targets) |target| gpa.free(target);
        if (self.targets.len > 0) gpa.free(self.targets);
        if (self.review_text.len > 0) gpa.free(self.review_text);
        if (self.flatpak_target) |target| target.deinit(gpa);
        if (self.detail.len > 0) gpa.free(self.detail);
        gpa.destroy(self);
    }

    pub fn operationView(self: *const SudoPrompt) operation_view.View {
        return .{
            .name = self.name,
            .elevated = self.elevated,
            .combined = self.backend == .all,
            .backend = self.backend,
            .include_aur = self.include_aur,
            .include_flatpak = self.include_flatpak,
            .target = self.flatpak_target,
            .review = self.review_text,
            .action = self.action,
            .detail = self.detail,
            .progress = self.progress,
            .state = switch (self.state) {
                .entering => .entering,
                .running => .running,
                .succeeded => .succeeded,
                .failed => .failed,
                .declined => .declined,
            },
        };
    }
};

pub fn init(_: Allocator, model: *Model) State {
    return .{
        .dependency_choices = .{ .item_count = 0, .children = .{ .builder = .{ .userdata = model, .buildFn = buildDependencyChoice } } },
        .pkgbuild_scroll = .{ .children = .{ .builder = .{
            .userdata = model,
            .buildFn = buildPkgbuildLine,
        } } },
    };
}

pub fn deinit(self: *Model) void {
    const gpa = self.gpa;

    if (self.operation_state.operation_question) |*question| question.deinit();
    if (self.operation_state.review_prompt) |prompt| prompt.deinit(gpa);
    self.operation_state.answer_input.deinit(gpa);
    if (self.operation_state.pkgbuild_thread) |thread| thread.join();
    if (self.operation_state.pkgbuild_job) |job| {
        if (job.result) |*result| result.deinit();
        if (job.expected_content) |content| gpa.free(content);
        gpa.free(job.name);
        gpa.destroy(job);
    }
    if (self.operation_state.pkgbuild_document) |*document| document.deinit();
    if (self.operation_state.pkgbuild_name.len > 0) gpa.free(self.operation_state.pkgbuild_name);
    if (self.operation_state.install_job) |operation| operation.deinit();
    self.operation_state.sudo_session.deinit(runtime.io);
    if (self.overlay) |overlay| {
        switch (overlay) {
            .sudo => |prompt| prompt.deinit(gpa),
            else => {},
        }
    }
}

pub fn openPkgbuild(self: *Model, ctx: *vxfw.EventContext, name: []const u8) !void {
    // Duplicate before releasing the old name, including retry of the same target.
    const owned = try self.gpa.dupe(u8, name);
    if (self.operation_state.pkgbuild_name.len > 0) self.gpa.free(self.operation_state.pkgbuild_name);
    self.operation_state.pkgbuild_name = owned;
    self.operation_state.pkgbuild_generation +%= 1;
    if (self.operation_state.pkgbuild_document) |*document| document.deinit();
    self.operation_state.pkgbuild_document = null;
    self.operation_state.pkgbuild_failure = null;
    self.operation_state.pkgbuild_scan_status = "";
    self.operation_state.pkgbuild_scroll.scroll = .{};
    self.operation_state.pkgbuild_scroll.cursor = 0;
    self.operation_state.pkgbuild_scroll.item_count = 0;
    self.overlay = .pkgbuild;
    if (runtime.terminal) |app| app.vx.queueRefresh();
    if (self.operation_state.pkgbuild_job == null) startPkgbuild(self, ctx) catch |err| {
        self.operation_state.pkgbuild_failure = err;
    };
}

pub fn startPkgbuild(self: *Model, ctx: *vxfw.EventContext) !void {
    return startPkgbuildRequest(self, ctx, null);
}

fn startPkgbuildRequest(self: *Model, ctx: *vxfw.EventContext, expected: ?[]const u8) !void {
    try ctx.tick(100, self.widget());
    const job = try self.gpa.create(PkgbuildJob);
    errdefer self.gpa.destroy(job);
    job.* = .{ .name = try self.gpa.dupe(u8, self.operation_state.pkgbuild_name), .atoll = self.settings_state.settings.atoll_aur_enabled, .generation = self.operation_state.pkgbuild_generation };
    errdefer self.gpa.free(job.name);
    job.mode = if (expected != null) .atoll_scan else if (job.atoll) .atoll_preview else .preview;
    if (expected) |content| job.expected_content = try self.gpa.dupe(u8, content);
    errdefer if (job.expected_content) |content| self.gpa.free(content);
    const thread = try std.Thread.spawn(.{}, fetchPkgbuildThread, .{job});
    self.operation_state.pkgbuild_thread = thread;
    self.operation_state.pkgbuild_job = job;
}

pub fn fetchPkgbuildThread(job: *PkgbuildJob) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const cli: ShellyCli = .{ .allocator = std.heap.page_allocator, .io = threaded.io() };
    job.result = cli.fetchPkgbuild(job.name, job.mode) catch |err| {
        job.failure = err;
        job.done.store(true, .release);
        return;
    };
    job.done.store(true, .release);
}

pub fn pollPkgbuild(self: *Model, ctx: *vxfw.EventContext) !void {
    const job = self.operation_state.pkgbuild_job orelse return;
    if (!job.done.load(.acquire)) return;
    self.operation_state.pkgbuild_thread.?.join();
    self.operation_state.pkgbuild_thread = null;
    self.operation_state.pkgbuild_job = null;
    defer {
        if (job.result) |*result| result.deinit();
        if (job.expected_content) |content| self.gpa.free(content);
        self.gpa.free(job.name);
        self.gpa.destroy(job);
    }
    if (self.operation_state.operation_question != null) return;
    if (job.generation != self.operation_state.pkgbuild_generation or job.atoll != self.settings_state.settings.atoll_aur_enabled or !std.mem.eql(u8, job.name, self.operation_state.pkgbuild_name)) {
        // The user selected a different package while this request was running.
        if (self.overlay != null and self.overlay.? == .pkgbuild)
            startPkgbuild(self, ctx) catch |err| {
                self.operation_state.pkgbuild_failure = err;
            };
        return;
    }
    if (job.mode == .atoll_scan) {
        const build = scannedPkgbuild(job) catch |err| {
            self.operation_state.pkgbuild_scan_status = if (err == error.ReviewedPkgbuildChanged) "PKGBUILD changed." else "Security scan failed.";
            const original = job.expected_content orelse {
                self.operation_state.pkgbuild_failure = error.NoPkgbuildData;
                return;
            };
            publishPkgbuild(self, .{ .Name = job.name, .PkgBuild = original });
            return;
        };
        publishPkgbuild(self, build);
        self.operation_state.pkgbuild_scan_status = if (build.Scan.?.findings.len == 0) "Security scan: no findings reported by the CLI." else "Security scan completed.";
        return;
    }
    self.operation_state.pkgbuild_failure = job.failure;
    if (job.result) |result| {
        const build = matchingPkgbuild(result.value, job.name) orelse {
            self.operation_state.pkgbuild_failure = error.PackageNotFound;
            return;
        };
        if (job.atoll and build.PkgBuild != null and self.overlay != null and self.overlay.? == .pkgbuild) {
            self.operation_state.pkgbuild_scan_status = "Scanning cached PKGBUILD…";
            startPkgbuildRequest(self, ctx, build.PkgBuild) catch {
                self.operation_state.pkgbuild_scan_status = "Could not start the security scan. Close and reopen the preview to retry.";
                publishPkgbuild(self, build);
            };
            return;
        }
        publishPkgbuild(self, build);
    }
}

fn scannedPkgbuild(job: *const PkgbuildJob) !PkgBuild {
    if (job.failure) |err| return err;
    const result = job.result orelse return error.NoPkgbuildData;
    const build = matchingPkgbuild(result.value, job.name) orelse return error.PackageNotFound;
    const original = job.expected_content orelse return error.NoPkgbuildData;
    const content = build.PkgBuild orelse return error.NoPkgbuildData;
    if (!std.mem.eql(u8, content, original)) return error.ReviewedPkgbuildChanged;
    if (build.Scan == null) return error.MissingScanResult;
    return build;
}

fn publishPkgbuild(self: *Model, build: PkgBuild) void {
    const document = pkgbuild_view.Document.init(self.gpa, &.{build}) catch |err| {
        self.operation_state.pkgbuild_failure = err;
        return;
    };
    if (self.operation_state.pkgbuild_document) |*old| old.deinit();
    self.operation_state.pkgbuild_document = document;
    self.operation_state.pkgbuild_scroll.item_count = @intCast(document.lines.len);
    self.operation_state.pkgbuild_scroll.scroll = .{};
    self.operation_state.pkgbuild_scroll.cursor = 0;
}

fn matchingPkgbuild(builds: []const PkgBuild, name: []const u8) ?PkgBuild {
    for (builds) |build| if (std.mem.eql(u8, std.mem.trimEnd(u8, build.Name, "\x00"), name)) return build;
    return null;
}

pub fn closePkgbuild(self: *Model) void {
    self.overlay = null;
    for (self.aur_state.aur_packages) |*pkg| {
        if (std.mem.eql(u8, pkg.Name, self.operation_state.pkgbuild_name)) {
            self.overlay = .{ .aur = pkg };
            self.aur_state.aur_list_active = true;
            for (self.aur_state.aur_filtered.items, 0..) |item, i| {
                if (std.mem.eql(u8, item.Name, self.operation_state.pkgbuild_name)) {
                    self.aur_state.aur_list.jumpToItem(@intCast(i));
                    break;
                }
            }
            break;
        }
    }
}

pub fn pkgbuildView(self: *Model) pkgbuild_view.View {
    return .{
        .name = self.operation_state.pkgbuild_name,
        .wrap = self.operation_state.pkgbuild_wrap,
        .scroll = &self.operation_state.pkgbuild_scroll,
        .loading = self.operation_state.pkgbuild_job != null and self.operation_state.operation_question == null,
        .failure = self.operation_state.pkgbuild_failure,
        .review = self.operation_state.operation_question != null,
        .pkgbuild_review = if (self.operation_state.operation_question) |message| message.value.question == .pkgbuild else false,
        .transaction_review = if (self.operation_state.operation_question) |message| message.value.question == .transaction else false,
        .optional_dependencies = if (self.operation_state.operation_question) |message| message.value.question == .select_many else false,
        .choice_list = &self.operation_state.dependency_choices,
        .choice_prompt = if (choiceOptions(self)) |_| switch (self.operation_state.operation_question.?.value.question) {
            .select_one => |q| q.prompt,
            .select_many => |q| q.prompt,
            else => unreachable,
        } else "",
        .choices = if (self.operation_state.operation_question) |message|
            message.value.question == .select_one or message.value.question == .select_many
        else
            false,
        .answer_input = self.operation_state.answer_input.items,
        .answer_error = self.operation_state.answer_error,
        .scan_status = if (self.operation_state.operation_question == null) self.operation_state.pkgbuild_scan_status else "",
    };
}

pub fn choiceOptions(self: *const Model) ?[]shelly_operation.Option {
    const message = self.operation_state.operation_question orelse return null;
    return switch (message.value.question) {
        .select_one => |q| q.options,
        .select_many => |q| q.options,
        else => null,
    };
}

pub fn syncProviderSelection(self: *Model) void {
    const message = self.operation_state.operation_question orelse return;
    if (message.value.question != .select_one) return;
    for (message.value.question.select_one.options, 0..) |*option, index| option.is_selected = index == self.operation_state.dependency_choices.cursor;
}

pub fn buildDependencyChoice(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
    const self: *const Model = @ptrCast(@alignCast(ptr));
    const options = choiceOptions(self) orelse return null;
    if (index >= options.len) return null;
    return .{ .userdata = &options[index], .drawFn = pkgbuild_view.drawChoice };
}

pub fn buildPkgbuildLine(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
    const self: *const Model = @ptrCast(@alignCast(ptr));
    if (self.operation_state.pkgbuild_document) |*document| return pkgbuild_view.rowWithWrap(document, index, self.operation_state.pkgbuild_wrap);
    return null;
}

pub fn operationFromOverlay(self: *Model, action: shelly_operation.Action) !void {
    if (self.operation_state.install_job != null) return; // one install at a time
    const overlay = self.overlay orelse return;
    switch (overlay) {
        .package => |pkg| {
            _ = pkg;
            return packages_model.openNativePrompt(self, action);
        },
        .aur => return aur_model.openAurPrompt(self, action),
        .sudo, .pkgbuild, .flatpak, .flatpak_install => return,
    }
}

pub fn resetPackageSelection(self: *Model) void {
    self.packages_state.selected_packages.clearRetainingCapacity();
    self.packages_state.selected_list_view.item_count = 0;
    self.packages_state.selected_list_view.jumpToItem(0);
    aur_model.clearAurSelection(self);
}

pub fn openPackageBatchPrompt(self: *Model, action: shelly_operation.Action, backend: OperationBackend, packages: []const Package, include_all: bool) !void {
    var targets: std.ArrayList([]const u8) = .empty;
    defer targets.deinit(self.gpa);
    var review: std.ArrayList(u8) = .empty;
    defer review.deinit(self.gpa);
    var installed_names: std.ArrayList([]const u8) = .empty;
    defer installed_names.deinit(self.gpa);
    var available_names: std.ArrayList([]const u8) = .empty;
    defer available_names.deinit(self.gpa);
    var excluded: usize = 0;
    const highlighted = packages_model.selectedPackage(self);
    for (packages) |pkg| {
        const included = if (include_all) true else if (self.packages_state.selected_packages.items.len > 0)
            packages_model.packageMarked(self, pkg.Name)
        else if (highlighted) |item|
            std.mem.eql(u8, item.Name, pkg.Name)
        else
            false;
        if (!included) continue;
        if (action == .remove and !pkg.Installed) {
            excluded += 1;
            continue;
        }
        var duplicate = false;
        for (targets.items) |target| {
            if (std.mem.eql(u8, target, pkg.Name)) duplicate = true;
        }
        if (duplicate) continue;
        try targets.append(self.gpa, pkg.Name);
        if (pkg.Installed) {
            try installed_names.append(self.gpa, pkg.Name);
        } else {
            try available_names.append(self.gpa, pkg.Name);
        }
    }
    if (targets.items.len == 0) {
        try self.setNotice(if (action == .remove) "No installed packages selected for removal." else "No packages selected.");
        return;
    }
    const groups = [_]struct { label: []const u8, names: []const []const u8 }{
        .{ .label = "Install", .names = available_names.items },
        .{ .label = if (action == .remove) "Remove" else "Reinstall", .names = installed_names.items },
    };
    for (groups) |group| {
        if (group.names.len == 0) continue;
        const names = try std.mem.join(self.gpa, ", ", group.names);
        defer self.gpa.free(names);
        const line = try std.fmt.allocPrint(self.gpa, "{s} ({d}): {f}\n", .{ group.label, group.names.len, diagnostics.safe(names) });
        defer self.gpa.free(line);
        try review.appendSlice(self.gpa, line);
    }
    if (excluded > 0) {
        const note = try std.fmt.allocPrint(self.gpa, "{d} uninstalled selections excluded.\n", .{excluded});
        defer self.gpa.free(note);
        try review.appendSlice(self.gpa, note);
    }
    if (action == .remove) try review.appendSlice(self.gpa, "Unused dependencies and configuration will be kept.\n");
    const prompt = try self.gpa.create(SudoPrompt);
    prompt.* = .{ .name = "", .backend = backend, .action = action };
    errdefer prompt.deinit(self.gpa);
    prompt.name = if (targets.items.len == 1) try self.gpa.dupe(u8, targets.items[0]) else try std.fmt.allocPrint(self.gpa, "{d} packages", .{targets.items.len});
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |target| self.gpa.free(target);
        owned.deinit(self.gpa);
    }
    for (targets.items) |target| {
        const copy = try self.gpa.dupe(u8, target);
        errdefer self.gpa.free(copy);
        try owned.append(self.gpa, copy);
    }
    prompt.targets = try owned.toOwnedSlice(self.gpa);
    prompt.review_text = try self.gpa.dupe(u8, review.items);
    self.overlay = .{ .sudo = prompt };
}

pub fn closeOverlay(self: *Model) void {
    if (self.overlay) |overlay| {
        switch (overlay) {
            .sudo => |prompt| {
                if (prompt.backend == .standard or prompt.backend == .aur) resetPackageSelection(self);
                prompt.deinit(self.gpa);
                if (self.notice.len > 0) self.gpa.free(self.notice);
                self.notice = "";
            },
            else => {},
        }
    }
    self.overlay = null;
}

pub fn showOperationQuestion(self: *Model, message: shelly_operation.OwnedMessage) !void {
    const overlay = self.overlay orelse return error.NoOperationDialog;
    if (overlay != .sudo) return error.NoOperationDialog;
    const question = message.value.question;
    var document = try pkgbuild_view.Document.fromQuestionForAction(self.gpa, question, overlay.sudo.action);
    errdefer document.deinit();
    const name = try self.gpa.dupe(u8, if (question == .pkgbuild) question.pkgbuild.package_name else overlay.sudo.name);
    if (self.operation_state.pkgbuild_document) |*old| old.deinit();
    if (self.operation_state.pkgbuild_name.len > 0) self.gpa.free(self.operation_state.pkgbuild_name);
    self.operation_state.pkgbuild_name = name;
    self.operation_state.pkgbuild_document = document;
    self.operation_state.pkgbuild_failure = null;
    self.operation_state.pkgbuild_scan_status = "";
    self.operation_state.pkgbuild_scroll.scroll = .{};
    self.operation_state.pkgbuild_scroll.cursor = 0;
    self.operation_state.pkgbuild_scroll.item_count = @intCast(document.lines.len);
    self.operation_state.operation_question = message;
    self.operation_state.dependency_choices.jumpToItem(0);
    if (choiceOptions(self)) |options| {
        self.operation_state.dependency_choices.item_count = @intCast(options.len);
        if (question == .select_one) for (options, 0..) |option, index| {
            if (option.is_selected) {
                self.operation_state.dependency_choices.jumpToItem(@intCast(index));
                break;
            }
        };
    }
    syncProviderSelection(self);
    self.operation_state.review_prompt = overlay.sudo;
    self.operation_state.answer_input.clearRetainingCapacity();
    self.operation_state.answer_error = "";
    self.overlay = .pkgbuild;
    if (runtime.terminal) |app| app.vx.queueRefresh();
}

pub fn finishOperationQuestion(self: *Model) void {
    if (self.operation_state.operation_question) |*question| question.deinit();
    self.operation_state.operation_question = null;
    if (self.operation_state.pkgbuild_document) |*document| document.deinit();
    self.operation_state.pkgbuild_document = null;
    self.operation_state.answer_input.clearRetainingCapacity();
    self.operation_state.answer_error = "";
    if (self.operation_state.review_prompt) |prompt| self.overlay = .{ .sudo = prompt };
    self.operation_state.review_prompt = null;
    if (runtime.terminal) |app| app.vx.queueRefresh();
}

pub fn dependencyAnswer(self: *const Model, indices: *std.ArrayList(usize)) !shelly_operation.Answer {
    const question = self.operation_state.operation_question.?.value.question;
    return switch (question) {
        .select_one => |request| blk: {
            if (self.operation_state.dependency_choices.cursor >= request.options.len) return error.NoProvider;
            break :blk .{ .provider = request.options[self.operation_state.dependency_choices.cursor].index };
        },
        .select_many => |request| blk: {
            for (request.options) |option| if (option.is_selected) {
                try indices.append(self.gpa, option.index);
            };
            break :blk .{ .optional_dependencies = indices.items };
        },
        else => unreachable,
    };
}

pub fn answerOperationQuestion(self: *Model, approve: bool) !void {
    const message = self.operation_state.operation_question orelse return;
    const job = self.operation_state.install_job orelse return;
    const question = message.value.question;
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(self.gpa);
    const answer: shelly_operation.Answer = switch (question) {
        .pkgbuild => .{ .pkgbuild = approve },
        .yes_no => .{ .yes_no = approve },
        .transaction => .{ .transaction = approve },
        .select_one, .select_many => blk: {
            if (!approve) return;
            break :blk dependencyAnswer(self, &indices) catch |err| {
                if (err != error.NoProvider) return err;
                self.operation_state.answer_error = "No provider is available to select.";
                return;
            };
        },
    };
    job.sendAnswer(runtime.io, shelly_operation.questionId(question), answer) catch {
        self.operation_state.answer_error = "Could not send the answer. The operation may have ended.";
        return;
    };
    if (!approve and (std.mem.eql(u8, job.request.backend, "standard") or std.mem.eql(u8, job.request.backend, "aur"))) resetPackageSelection(self);
    finishOperationQuestion(self);
}

fn sendAuthenticationKey(job: *shelly_operation.Operation, key: vaxis.Key) !void {
    // Do not retain, mask, or log credentials. Sudo owns line editing.
    if (key.matches(vaxis.Key.enter, .{})) {
        try job.sendAuthentication(runtime.io, "\n");
    } else if (key.matches(vaxis.Key.backspace, .{})) {
        try job.sendAuthentication(runtime.io, "\x7f");
    } else if (key.matches('u', .{ .ctrl = true })) {
        try job.sendAuthentication(runtime.io, "\x15");
    } else if (key.matches('w', .{ .ctrl = true })) {
        try job.sendAuthentication(runtime.io, "\x17");
    } else if (key.matches('d', .{ .ctrl = true })) {
        try job.sendAuthentication(runtime.io, "\x04");
    } else if (commands.matches(key, .cancel)) {
        try job.sendAuthentication(runtime.io, "\x03");
    } else if (key.text) |text| {
        for (text) |byte| if (byte < 0x20 or byte == 0x7f) return;
        try job.sendAuthentication(runtime.io, text);
    }
}

pub fn handleSudoKey(self: *Model, prompt: *SudoPrompt, ctx: *vxfw.EventContext, key: vaxis.Key) anyerror!void {
    if (prompt.state == .running) if (self.operation_state.install_job) |job| {
        if (job.snapshot(runtime.io).authenticating) {
            sendAuthenticationKey(job, key) catch {
                try self.setNotice("Could not send authentication input safely. No credentials were logged.");
            };
            return ctx.consumeAndRedraw();
        }
    };
    switch (try prompt.panel.handleKey(promptView(self, prompt), ctx, key)) {
        .none => {},
        .close => closeOverlay(self),
        .confirm => {
            try startElevatedInstall(self, ctx, prompt);
            prompt.state = .running;
        },
    }
    return ctx.consumeAndRedraw();
}

pub fn aurPaneFocused(self: *const Model) bool {
    if (self.active == .flatpak) return self.overlay != null and (self.overlay.? == .flatpak or self.overlay.? == .flatpak_install);
    if (self.active != .aur) return false;
    const overlay = self.overlay orelse return false;
    return overlay == .aur or overlay == .pkgbuild;
}

pub fn operationPrompt(self: *Model) ?*SudoPrompt {
    const overlay = self.overlay orelse return null;
    return if (overlay == .sudo) overlay.sudo else null;
}

pub fn promptView(self: *const Model, prompt: *const SudoPrompt) operation_view.View {
    var view = prompt.operationView();
    view.refresh_pending = self.updates_state.refresh_after_upgrade or self.flatpak_state.refresh_flatpak_after_operation or
        self.updates_state.refresh_updates_after_operation or self.packages_state.loading or self.updates_state.updates_job != null or self.flatpak_state.flatpak_job != null;
    return view;
}

pub fn startElevatedInstall(self: *Model, ctx: *vxfw.EventContext, prompt: *SudoPrompt) !void {
    if (self.operation_state.install_job != null) return error.OperationAlreadyRunning;
    // Schedule polling before starting so scheduling failure cannot orphan a worker.
    try ctx.tick(100, self.widget());
    self.operation_state.install_job = try shelly_operation.Operation.start(.{
        .shelly_bin = runtime.shellyBin(),
        .session = &self.operation_state.sudo_session,
        .environ_map = runtime.environ_map,
        .name = prompt.name,
        .targets = prompt.targets,
        .action = prompt.action,
        .backend = @tagName(prompt.backend),
        .flatpak = prompt.flatpak_target,
        .include_flatpak = prompt.include_flatpak,
        .include_aur = prompt.include_aur,
    });
}

pub fn pollInstall(self: *Model) !bool {
    const job = self.operation_state.install_job orelse return false;
    const result = job.poll();
    if (result == null and self.operation_state.operation_question == null) {
        if (job.takeQuestion(runtime.io)) |message| {
            showOperationQuestion(self, message) catch |err| {
                var owned = message;
                owned.deinit();
                job.closeInput(runtime.io);
                const detail = try std.fmt.allocPrint(self.gpa, "Could not display operation review: {s}", .{@errorName(err)});
                defer self.gpa.free(detail);
                try self.setNotice(detail);
            };
        }
    }
    if (result != null and self.operation_state.operation_question != null) finishOperationQuestion(self);
    if (self.overlay) |overlay| {
        if (overlay == .sudo) {
            const progress = job.snapshot(runtime.io);
            if (overlay.sudo.progress.authenticating and !progress.authenticating) {
                if (runtime.terminal) |app| app.vx.queueRefresh();
            }
            overlay.sudo.progress = progress;
        }
    }
    const completed = result orelse return true;
    defer job.deinit();

    const failed = completed.failed;
    self.operation_state.install_job = null;
    self.quit_blocked_notice = false;
    const is_appimage = std.mem.eql(u8, job.request.backend, "appimage");
    if (is_appimage) {
        self.appimage_state.refresh_after_operation = true;
        @import("updates_model.zig").invalidate(self);
    }
    const is_flatpak = std.mem.eql(u8, job.request.backend, "flatpak");
    const is_combined = std.mem.eql(u8, job.request.backend, "all");
    if (!is_flatpak and !is_appimage) {
        aur_model.invalidateInstalledCache(self);
        if (self.settings_state.settings.aur_enabled) self.aur_state.refresh_aur_after_operation = true;
    }
    const package_batch = job.request.targets.len > 0;
    const package_change = (job.request.action == .install or job.request.action == .remove) and
        (std.mem.eql(u8, job.request.backend, "standard") or std.mem.eql(u8, job.request.backend, "aur"));
    if (package_change and (!failed or completed.declined)) {
        resetPackageSelection(self);
        self.updates_state.refresh_after_upgrade = true;
        self.updates_state.refresh_updates_after_operation = true;
        if (self.settings_state.settings.aur_enabled) self.aur_state.refresh_aur_after_operation = true;
    }
    if (package_batch) {
        self.updates_state.refresh_after_upgrade = true;
        self.updates_state.refresh_updates_after_operation = true;
    }
    if (is_flatpak or (is_combined and job.request.include_flatpak)) self.flatpak_state.refresh_flatpak_after_operation = true;
    if (job.request.action == .upgrade or is_flatpak or std.mem.eql(u8, job.request.backend, "aur")) self.updates_state.refresh_updates_after_operation = true;
    if (!is_flatpak and (job.request.action == .upgrade or std.mem.eql(u8, job.request.backend, "aur"))) self.updates_state.refresh_after_upgrade = true;
    if ((is_combined and job.request.include_aur) or std.mem.eql(u8, job.request.backend, "aur")) self.aur_state.refresh_aur_after_operation = true;

    // Native and AUR operations change the same installed package database.
    if (!package_batch and package_change and !failed and !completed.declined and job.request.action != .upgrade) {
        for (self.packages_state.packages) |*pkg| {
            if (std.mem.eql(u8, pkg.Name, job.request.name)) {
                pkg.Installed = job.request.action == .install;
                break;
            }
        }
    }
    if (!package_batch and package_change and !failed and !completed.declined and job.request.action != .upgrade) {
        if (self.aur_state.aur_parsed) |parsed| {
            for (parsed.value) |*pkg| {
                if (std.mem.eql(u8, pkg.Name, job.request.name))
                    pkg.Installed = job.request.action == .install;
            }
        }
    }
    if (self.packages_state.installed_only) try packages_model.rebuildFilter(self);
    // Reflect the outcome in the sudo prompt if it is still open
    if (self.overlay) |overlay| {
        switch (overlay) {
            .sudo => |prompt| {
                if (failed or completed.declined) {
                    prompt.state = if (completed.declined) .declined else .failed;
                    if (prompt.detail.len > 0) self.gpa.free(prompt.detail);
                    prompt.detail = if (completed.error_detail.len > 0)
                        self.gpa.dupe(u8, completed.error_detail) catch ""
                    else
                        "";
                } else {
                    prompt.state = .succeeded;
                }
            },
            else => {},
        }
    }

    return false;
}

pub fn handleReviewKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) anyerror!void {
    const view = pkgbuildView(self);
    if (view.handleKey(key)) |action| {
        switch (action) {
            .toggle_wrap => {
                self.operation_state.pkgbuild_wrap = !self.operation_state.pkgbuild_wrap;
                self.operation_state.pkgbuild_scroll.scroll.left = 0;
                self.operation_state.pkgbuild_scroll.scroll.vertical_offset = 0;
            },
            .close => closePkgbuild(self),
            .retry => if (self.operation_state.pkgbuild_job == null) try openPkgbuild(self, ctx, self.operation_state.pkgbuild_name),
            .approve => try answerOperationQuestion(self, true),
            .decline => try answerOperationQuestion(self, false),
        }
        return ctx.consumeAndRedraw();
    }
    if (choiceOptions(self)) |options| {
        const cursor = self.operation_state.dependency_choices.cursor;
        if (commands.matches(key, .mark) and cursor < options.len) {
            if (self.operation_state.operation_question.?.value.question == .select_many) options[cursor].is_selected = !options[cursor].is_selected;
        } else {
            try self.operation_state.dependency_choices.handleEvent(ctx, .{ .key_press = commands.scrollKey(key) orelse key });
        }
        syncProviderSelection(self);
        self.operation_state.answer_error = "";
        return ctx.consumeAndRedraw();
    }
    if (self.operation_state.pkgbuild_document != null and !pkgbuildView(self).loading)
        try self.operation_state.pkgbuild_scroll.handleEvent(ctx, .{ .key_press = commands.scrollKey(key) orelse key });
    return ctx.consumeAndRedraw();
}

pub fn handleReviewMouse(self: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    if (choiceOptions(self) != null) {
        try self.operation_state.dependency_choices.handleEvent(ctx, event);
        syncProviderSelection(self);
    } else try self.operation_state.pkgbuild_scroll.handleEvent(ctx, event);
}

test "operation panel reserves one third of the terminal across stages" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{.{ .Name = "example" }};
    model.packages_state.packages = &packages;
    model.packages_state.loading = false;
    try packages_model.rebuildFilter(model);
    try packages_model.openNativePrompt(model, .install);
    const prompt = model.overlay.?.sudo;
    for ([_]vxfw.Size{ .{ .width = 80, .height = 24 }, .{ .width = 120, .height = 40 }, .{ .width = 40, .height = 12 } }) |size| {
        for ([_]SudoPrompt.State{ .entering, .running, .succeeded, .failed, .declined }) |state| {
            prompt.state = state;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const drawn = try model.widget().draw(.{
                .arena = arena.allocator(),
                .min = .{},
                .max = .{ .width = size.width, .height = size.height },
                .cell_size = .{ .width = 10, .height = 20 },
            });
            const panel = drawn.children[drawn.children.len - 2];
            try std.testing.expectEqual(@as(i17, 0), panel.origin.col);
            try std.testing.expectEqual(size.width, panel.surface.size.width);
            try std.testing.expectEqual(@as(usize, size.height - 1), @as(usize, @intCast(panel.origin.row)) + panel.surface.size.height);
            try std.testing.expectEqual(@as(u8, 0), panel.z_index);
            for (drawn.children[0 .. drawn.children.len - 2]) |child| {
                try std.testing.expect(child.origin.row + child.surface.size.height <= panel.origin.row);
            }
            const expected_height: u16 = switch (size.height) {
                24 => 8,
                40 => 14,
                12 => 4,
                else => unreachable,
            };
            try std.testing.expectEqual(expected_height, panel.surface.size.height);
        }
    }
}

test "operation completion and dismissal restore the browsing shortcut footer" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    runtime.io = threaded.io();
    defer runtime.io = std.testing.io;
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{.{ .Name = "example" }};
    model.packages_state.packages = &packages;
    model.packages_state.loading = false;
    model.packages_state.package_list_active = true;
    try packages_model.rebuildFilter(model);
    try packages_model.openNativePrompt(model, .install);
    const prompt = model.overlay.?.sudo;
    prompt.state = .running;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const job = try std.heap.page_allocator.create(shelly_operation.Operation);
    job.* = .{
        .arena = .init(std.heap.page_allocator),
        .done = .init(true),
        .request = .{ .shelly_bin = "unused", .environ_map = &env, .backend = "standard", .action = .install, .name = "example", .targets = &.{"example"} },
    };
    const history = "Retained operation event";
    @memcpy(job.progress.messages[63][0..history.len], history);
    job.progress.lengths[63] = history.len;
    model.operation_state.install_job = job;
    try std.testing.expectEqual(commands.Mode.running, model.commandContext().mode);
    try std.testing.expect(!try pollInstall(model));
    try std.testing.expectEqual(SudoPrompt.State.succeeded, prompt.state);
    try std.testing.expectEqualStrings(history, prompt.progress.messages[63][0..prompt.progress.lengths[63]]);
    try std.testing.expectEqualStrings("", model.notice);
    try std.testing.expectEqual(commands.Mode.result, model.commandContext().mode);
    try model.setNotice("Stale operation notice");
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = 'q' } });
    try std.testing.expect(model.overlay == null);
    try std.testing.expectEqualStrings("", model.notice);
    try std.testing.expectEqual(commands.Mode.packages, model.commandContext().mode);
}

test "help preserves operation confirmation and follows operation stages" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{.{ .Name = "example" }};
    model.packages_state.packages = &packages;
    model.packages_state.loading = false;
    try packages_model.rebuildFilter(model);
    try packages_model.openNativePrompt(model, .install);
    const prompt = model.overlay.?.sudo;
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.f1 } });
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = 'x', .text = "x" } });
    try std.testing.expectEqual(SudoPrompt.State.entering, prompt.state);
    try std.testing.expect(model.operation_state.install_job == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{ .width = 10, .height = 20 } };
    _ = try model.widget().draw(ctx);
    try std.testing.expectEqual(commands.Mode.authentication, model.help_panel.context.mode);
    prompt.state = .running;
    _ = try model.widget().draw(ctx);
    try std.testing.expectEqual(commands.Mode.running, model.help_panel.context.mode);
    prompt.state = .succeeded;
    _ = try model.widget().draw(ctx);
    try std.testing.expectEqual(commands.Mode.result, model.help_panel.context.mode);
    try std.testing.expect(std.mem.indexOf(u8, try model.help_panel.text(arena.allocator()), "Dismiss the operation result") != null);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.f1 } });
    try std.testing.expect(!model.help_open);
    try std.testing.expect(model.overlay.?.sudo == prompt);
    try std.testing.expectEqual(SudoPrompt.State.succeeded, prompt.state);
}

test "incomplete reviews keep the worker input open until an explicit answer" {
    runtime.io = std.testing.io;
    defer runtime.io = undefined;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    for ([_]bool{ false, true }) |approve| {
        const model = try Model.init(std.testing.allocator);
        defer model.deinit();
        const prompt = try std.testing.allocator.create(SudoPrompt);
        prompt.* = .{ .name = try std.testing.allocator.dupe(u8, "demo"), .backend = .aur, .state = .running };
        model.overlay = .{ .sudo = prompt };
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var job: shelly_operation.Operation = .{
            .arena = .init(std.testing.allocator),
            .request = .{ .shelly_bin = "unused", .environ_map = &env, .name = "demo", .backend = "aur" },
            .input = try temporary.dir.createFile(std.testing.io, "answers", .{}),
            .expected_answer = .pkgbuild,
            .expected_id = @splat(0),
            .expected_len = 1,
        };
        defer job.arena.deinit();
        defer job.closeInput(std.testing.io);
        job.expected_id[0] = '1';
        var message = try shelly_operation.decodeJson(std.testing.allocator,
            \\{"$kind":"q.pkgbuilddiff","QuestionId":"1","PackageName":"demo","OldPkgbuild":"","NewPkgbuild":"pkgname=demo","Warnings":[]}
        );
        const long = try message.arena.allocator().alloc(u8, 8193);
        @memset(long, 'x');
        message.value.question.pkgbuild.source_files = &.{.{ .name = "long.txt", .content = long }};
        job.pending = message;
        model.operation_state.install_job = &job;
        defer model.operation_state.install_job = null;
        try std.testing.expect(try pollInstall(model));
        try std.testing.expect(!job.input_closing and job.input != null);
        try std.testing.expect(job.expected_answer != null);
        try std.testing.expect(model.overlay.? == .pkgbuild);
        try std.testing.expect(model.operation_state.review_prompt.? == prompt);
        try std.testing.expect(std.mem.startsWith(u8, model.operation_state.pkgbuild_document.?.lines[0], "Some content could not be displayed."));
        const view = pkgbuildView(model);
        try std.testing.expectEqual(pkgbuild_view.Action.approve, view.handleKey(commands.bindings.approve).?);
        try std.testing.expectEqual(pkgbuild_view.Action.decline, view.handleKey(commands.bindings.decline).?);
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
        defer ctx.cmds.deinit(std.testing.allocator);
        model.operation_state.pkgbuild_scroll.last_height = 4;
        model.operation_state.pkgbuild_scroll.scroll.top = 2;
        try handleReviewKey(model, &ctx, commands.bindings.half_page_up);
        try std.testing.expectEqual(@as(i17, -2), model.operation_state.pkgbuild_scroll.scroll.pending_lines);
        try std.testing.expect(job.expected_answer != null);
        try handleReviewKey(model, &ctx, if (approve) commands.bindings.approve else commands.bindings.decline);
        try std.testing.expect(job.expected_answer == null);
        try std.testing.expectEqual(!approve, job.user_declined);
        try std.testing.expect(model.operation_state.operation_question == null);
        try std.testing.expect(model.overlay.?.sudo == prompt);
    }
}

test "dependency checkboxes navigate toggle and submit actual CLI indices" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    const prompt = try std.testing.allocator.create(SudoPrompt);
    prompt.* = .{ .name = try std.testing.allocator.dupe(u8, "demo"), .backend = .aur, .state = .running };
    model.overlay = .{ .sudo = prompt };
    try showOperationQuestion(model, try shelly_operation.decodeJson(std.testing.allocator,
        \\{"$kind":"q.optdeps","QuestionId":"101","QuestionText":"Optional dependencies","Options":[{"Index":0,"Name":"docs","IsSelected":true},{"Index":7,"Name":"plugin"}]}
    ));
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    try std.testing.expect(choiceOptions(model).?[0].is_selected);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.mark });
    try std.testing.expect(!choiceOptions(model).?[0].is_selected);
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), (try dependencyAnswer(model, &indices)).optional_dependencies.len);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.next });
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.mark });
    const answer = try dependencyAnswer(model, &indices);
    try std.testing.expectEqualSlices(usize, &.{7}, answer.optional_dependencies);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{ .width = 10, .height = 20 } });
    try std.testing.expect(choiceOptions(model).?[1].is_selected);
    finishOperationQuestion(model);
    try showOperationQuestion(model, try shelly_operation.decodeJson(std.testing.allocator,
        \\{"$kind":"q.provider","QuestionId":"102","QuestionText":"Choose provider","Options":[{"Index":3,"Name":"first"},{"Index":9,"Name":"second","IsSelected":true}]}
    ));
    try std.testing.expectEqual(@as(usize, 9), (try dependencyAnswer(model, &indices)).provider);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.previous });
    try std.testing.expectEqual(@as(usize, 3), (try dependencyAnswer(model, &indices)).provider);
    try std.testing.expect(choiceOptions(model).?[0].is_selected);
    try std.testing.expect(!choiceOptions(model).?[1].is_selected);
    try std.testing.expectEqual(@as(usize, 0), model.operation_state.answer_input.items.len);
}

test "successful native and AUR installs and removals deselect both lists through refresh" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    runtime.io = threaded.io();
    defer runtime.io = std.testing.io;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    for ([_][]const u8{ "standard", "aur" }) |backend| {
        inline for ([_]shelly_operation.Action{ .install, .remove }) |action| {
            for ([_]bool{ false, true }) |batch| {
                const model = try Model.init(std.testing.allocator);
                defer model.deinit();
                model.settings_state.settings.aur_enabled = true;
                var packages = [_]Package{ .{ .Name = "target" }, .{ .Name = "other-native" } };
                model.packages_state.packages = &packages;
                model.packages_state.loading = false;
                try packages_model.rebuildFilter(model);
                try model.packages_state.selected_packages.appendSlice(std.testing.allocator, &.{ "target", "other-native" });
                model.packages_state.selected_list_view.item_count = 2;
                model.packages_state.selected_list_view.jumpToItem(1);
                var aur = [_]AurPackage{ .{ .Name = "target" }, .{ .Name = "other-aur" } };
                model.aur_state.aur_packages = &aur;
                try aur_model.rebuildAurFilter(model);
                try aur_model.toggleAurSelection(model);
                model.aur_state.aur_list.jumpToItem(1);
                try aur_model.toggleAurSelection(model);
                const job = try std.heap.page_allocator.create(shelly_operation.Operation);
                job.* = .{
                    .arena = .init(std.heap.page_allocator),
                    .done = .init(true),
                    .request = .{ .shelly_bin = "unused", .environ_map = &env, .backend = backend, .action = action, .name = "target", .targets = if (batch) &.{"target"} else &.{} },
                };
                model.aur_state.installed_cache = try std.json.parseFromSlice([]AurPackage, model.gpa, "[]", .{});
                model.operation_state.install_job = job;
                try std.testing.expect(!try pollInstall(model));
                try std.testing.expect(model.aur_state.installed_cache == null);
                try std.testing.expectEqual(@as(usize, 0), model.packages_state.selected_packages.items.len);
                try std.testing.expectEqual(@as(usize, 0), model.aur_state.aur_selection.items.len);
                try std.testing.expectEqual(@as(u32, 0), model.packages_state.selected_list_view.item_count orelse unreachable);
                try std.testing.expect(model.updates_state.refresh_after_upgrade);
                try std.testing.expect(model.aur_state.refresh_aur_after_operation);
                // Deliver fresh results through the actual refresh publication paths.
                model.packages_state.loading = true;
                model.packages_state.load.result = try std.json.parseFromSlice([]Package, std.testing.allocator, "[{\"Name\":\"target\",\"Installed\":true},{\"Name\":\"other-native\"}]", .{ .allocate = .alloc_always });
                model.packages_state.load.done.store(true, .release);
                try std.testing.expect(!try packages_model.pollLoad(model));
                const aur_job = try std.testing.allocator.create(AurSearchJob);
                aur_job.* = .{ .cache_epoch = model.aur_state.cache_epoch, .result = try std.json.parseFromSlice([]AurPackage, std.testing.allocator, "[{\"Name\":\"target\",\"Installed\":true},{\"Name\":\"other-aur\"}]", .{ .allocate = .alloc_always }) };
                aur_job.done.store(true, .release);
                model.aur_state.aur_job = aur_job;
                try std.testing.expect(!try aur_model.pollAurSearch(model));
                try std.testing.expectEqual(@as(usize, 0), model.packages_state.selected_packages.items.len);
                try std.testing.expectEqual(@as(usize, 0), model.aur_state.aur_selection.items.len);
                try std.testing.expect(!packages_model.packageMarked(model, "target"));
                try std.testing.expect(!aur_model.aurMarked(model, "target"));
            }
        }
    }
}

test "cancelling native and AUR authentication or declining a review clears both selections" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    runtime.io = threaded.io();
    defer runtime.io = std.testing.io;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    for ([_]OperationBackend{ .standard, .aur }) |backend| {
        const model = try Model.init(std.testing.allocator);
        defer model.deinit();
        var packages = [_]Package{.{ .Name = "native", .Installed = true }};
        var aur = [_]AurPackage{.{ .Name = "aur", .Installed = true }};
        model.packages_state.packages = &packages;
        model.aur_state.aur_packages = &aur;
        model.settings_state.settings.aur_enabled = true;
        model.packages_state.loading = false;
        try packages_model.rebuildFilter(model);
        try aur_model.rebuildAurFilter(model);
        try model.packages_state.selected_packages.append(std.testing.allocator, "native");
        try aur_model.toggleAurSelection(model);
        if (backend == .standard) try packages_model.openNativePrompt(model, .remove) else try aur_model.openAurPrompt(model, .remove);
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
        defer ctx.cmds.deinit(std.testing.allocator);
        try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.cancel });
        try std.testing.expect(model.overlay == null);
        try std.testing.expectEqual(@as(usize, 0), model.packages_state.selected_packages.items.len);
        try std.testing.expectEqual(@as(usize, 0), model.aur_state.aur_selection.items.len);
        try model.packages_state.selected_packages.append(std.testing.allocator, "native");
        try aur_model.toggleAurSelection(model);
        const job = try std.heap.page_allocator.create(shelly_operation.Operation);
        job.* = .{
            .arena = .init(std.heap.page_allocator),
            .done = .init(true),
            .result = .{ .declined = true },
            .request = .{ .shelly_bin = "unused", .environ_map = &env, .backend = @tagName(backend), .name = "target" },
        };
        model.operation_state.install_job = job;
        try std.testing.expect(!try pollInstall(model));
        try std.testing.expectEqual(@as(usize, 0), model.packages_state.selected_packages.items.len);
        try std.testing.expectEqual(@as(usize, 0), model.aur_state.aur_selection.items.len);
        try std.testing.expectEqual(@as(u32, 0), model.packages_state.selected_list_view.item_count.?);
    }
}

test "AUR batch removal refresh failure and retry remain drawable and navigable" {
    vxfw.DrawContext.init(.unicode);
    runtime.io = std.testing.io;
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .aur;
    model.settings_state.settings.aur_enabled = true;
    model.packages_state.loading = false;
    model.aur_state.aur_installed_only = true;
    model.aur_state.aur_list_active = true;
    model.aur_state.aur_parsed = try std.json.parseFromSlice([]AurPackage, std.testing.allocator, "[{\"Name\":\"first-git\",\"Installed\":true},{\"Name\":\"second-git\",\"Installed\":true}]", .{ .allocate = .alloc_always });
    model.aur_state.aur_packages = model.aur_state.aur_parsed.?.value;
    try aur_model.rebuildAurFilter(model);
    for (0..2) |index| {
        model.aur_state.aur_list.cursor = @intCast(index);
        try aur_model.toggleAurSelection(model);
    }
    try aur_model.openAurPrompt(model, .remove);
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const job = try std.heap.page_allocator.create(shelly_operation.Operation);
    job.* = .{ .arena = .init(std.heap.page_allocator), .done = .init(true), .request = .{
        .shelly_bin = "unused",
        .environ_map = &env,
        .backend = "aur",
        .action = .remove,
        .name = "2 packages",
        .targets = &.{ "first-git", "second-git" },
    } };
    model.operation_state.install_job = job;
    try std.testing.expect(!try pollInstall(model));
    for ([_]bool{ true, false }) |failed_refresh| {
        const refresh = try std.testing.allocator.create(aur_model.AurSearchJob);
        refresh.* = .{ .cache_epoch = model.aur_state.cache_epoch, .installed_only = true, .failed = failed_refresh, .done = .init(true), .result = if (failed_refresh) null else try std.json.parseFromSlice([]AurPackage, std.testing.allocator, "[]", .{}) };
        model.aur_state.aur_job = refresh;
        try std.testing.expect(!try aur_model.pollAurSearch(model));
        try std.testing.expectEqual(failed_refresh, model.aur_state.aur_failed);
        try std.testing.expect(model.overlay.?.sudo.state == .succeeded);
        for ([_]vxfw.Size{ .{ .width = 100, .height = 30 }, .{ .width = 40, .height = 12 } }) |size| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            _ = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{ .width = 10, .height = 20 } });
        }
    }
    closeOverlay(model);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    for ([_]vaxis.Key{ commands.bindings.previous, commands.bindings.next, commands.bindings.details, commands.bindings.select, commands.bindings.clear_selection }) |key| {
        try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = key });
    }
    try std.testing.expect(model.overlay == null);
    try std.testing.expectEqual(@as(usize, 0), model.aur_state.aur_selection.items.len);
}

test "Atoll preview stays loading until the scan finishes and retains source on failure" {
    const Worker = struct {
        fn finish() void {}
    };
    for (0..5) |scenario| {
        const model = try Model.init(std.testing.allocator);
        defer model.deinit();
        model.settings_state.settings.atoll_aur_enabled = true;
        model.overlay = .pkgbuild;
        model.operation_state.pkgbuild_name = try model.gpa.dupe(u8, "demo");
        const job = try model.gpa.create(PkgbuildJob);
        job.* = .{
            .name = try model.gpa.dupe(u8, "demo"),
            .expected_content = try model.gpa.dupe(u8, "pkgname=demo"),
            .atoll = true,
            .mode = .atoll_scan,
            .done = .init(true),
        };
        model.operation_state.pkgbuild_job = job;
        model.operation_state.pkgbuild_thread = try std.Thread.spawn(.{}, Worker.finish, .{});
        if (scenario == 2) {
            job.failure = error.CommandFailed;
        } else {
            job.result = try std.json.parseFromSlice([]PkgBuild, model.gpa, switch (scenario) {
                0 => "[{\"Name\":\"demo\",\"PkgBuild\":\"pkgname=demo\",\"Scan\":{\"findings\":[],\"related_files\":[{\"name\":\"demo.install\",\"content\":\"echo checked\"}]}}]",
                1 => "[{\"Name\":\"demo\",\"PkgBuild\":\"changed\",\"Scan\":{\"findings\":[],\"related_files\":[]}}]",
                4 => "[{\"Name\":\"demo\",\"PkgBuild\":null}]",
                else => "[{\"Name\":\"demo\",\"PkgBuild\":\"pkgname=demo\"}]",
            }, .{ .allocate = .alloc_always });
        }
        // Retain only the fetched source while scanning, without highlighting it.
        try std.testing.expect(model.operation_state.pkgbuild_document == null);
        try std.testing.expect(pkgbuildView(model).loading);
        try std.testing.expect(!model.commandContext().scrollable);
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = model.gpa, .cmds = .empty };
        defer ctx.cmds.deinit(model.gpa);
        try pollPkgbuild(model, &ctx);
        try std.testing.expect(!pkgbuildView(model).loading);
        try std.testing.expect(model.commandContext().scrollable);
        try std.testing.expect(model.operation_state.pkgbuild_failure == null);
        var source_found = false;
        for (model.operation_state.pkgbuild_document.?.lines) |line| {
            if (std.mem.endsWith(u8, line, "pkgname=demo")) source_found = true;
        }
        try std.testing.expect(source_found);
        const status = model.operation_state.pkgbuild_scan_status;
        try std.testing.expect(std.mem.indexOf(u8, status, if (scenario == 0) "no findings" else if (scenario == 1) "changed" else "failed") != null);
        if (scenario == 0) {
            var found = false;
            for (model.operation_state.pkgbuild_document.?.lines) |line| {
                if (std.mem.endsWith(u8, line, "echo checked")) found = true;
            }
            try std.testing.expect(found);
        }
    }
}

test "regular PKGBUILD preview never schedules an Atoll security scan" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.overlay = .pkgbuild;
    model.operation_state.pkgbuild_name = try model.gpa.dupe(u8, "demo");
    const job = try model.gpa.create(PkgbuildJob);
    job.* = .{ .name = try model.gpa.dupe(u8, "demo"), .done = .init(true), .result = try std.json.parseFromSlice([]PkgBuild, model.gpa, "[{\"Name\":\"demo\",\"PkgBuild\":\"pkgname=demo\"}]", .{ .allocate = .alloc_always }) };
    const Worker = struct {
        fn finish() void {}
    };
    model.operation_state.pkgbuild_job = job;
    model.operation_state.pkgbuild_thread = try std.Thread.spawn(.{}, Worker.finish, .{});
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = model.gpa, .cmds = .empty };
    defer ctx.cmds.deinit(model.gpa);
    try pollPkgbuild(model, &ctx);
    try std.testing.expect(model.operation_state.pkgbuild_document != null);
    try std.testing.expect(model.operation_state.pkgbuild_job == null);
    try std.testing.expectEqualStrings("", model.operation_state.pkgbuild_scan_status);
}

test "missing Atoll preview source is displayed without scheduling another request" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.settings_state.settings.atoll_aur_enabled = true;
    model.overlay = .pkgbuild;
    model.operation_state.pkgbuild_name = try model.gpa.dupe(u8, "demo");
    const job = try model.gpa.create(PkgbuildJob);
    job.* = .{ .name = try model.gpa.dupe(u8, "demo"), .atoll = true, .done = .init(true), .result = try std.json.parseFromSlice([]PkgBuild, model.gpa,
        \\[{"Name":"demo","PkgBuild":null}]
    , .{ .allocate = .alloc_always }) };
    const Worker = struct {
        fn finish() void {}
    };
    model.operation_state.pkgbuild_job = job;
    model.operation_state.pkgbuild_thread = try std.Thread.spawn(.{}, Worker.finish, .{});
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = model.gpa, .cmds = .empty };
    defer ctx.cmds.deinit(model.gpa);
    try pollPkgbuild(model, &ctx);
    try std.testing.expect(model.operation_state.pkgbuild_job == null);
    try std.testing.expect(model.operation_state.pkgbuild_document != null);
    try std.testing.expectEqualStrings("", model.operation_state.pkgbuild_scan_status);
    const text = try std.mem.join(model.gpa, "\n", model.operation_state.pkgbuild_document.?.lines);
    defer model.gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "PKGBUILD unavailable for demo.") != null);
}
