const std = @import("std");
const Zigalpm = @import("Zigalpm");
const model = @import("../config/model.zig");
const runtime = @import("../runtime/context.zig");
const xdg = @import("../runtime/xdg.zig");
const colors = @import("colors.zig");
const format = @import("format.zig");
const review_output = @import("review.zig");

pub fn writeListPlain(
    context: *runtime.RuntimeContext,
    config: *const model.Config,
) !void {
    var width: usize = 0;
    for (config.values.keys()) |key| width = @max(width, key.len);
    const use_color = supportsAnsi(context);
    for (config.values.keys()) |key| {
        if (use_color) try context.stdout.writeAll(colors.colorCode(.info));
        try context.stdout.print("{s}", .{key});
        try context.stdout.splatByteAll(' ', width - key.len);
        if (use_color) try context.stdout.writeAll(colors.reset);
        const value = try config.getDisplay(context.allocator, key);
        try context.stdout.print("  {s}\n", .{value orelse "(null)"});
    }
}

pub fn writeDictionaryJson(
    allocator: std.mem.Allocator,
    config: *const model.Config,
    writer: *std.Io.Writer,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    for (config.values.keys()) |key| {
        try json.objectField(key);
        const value = try config.getDisplay(allocator, key);
        try json.write(value);
    }
    try json.endObject();
}

pub fn writeSingleValueFrame(
    context: *runtime.RuntimeContext,
    key: []const u8,
    value: []const u8,
) !void {
    var payload = std.Io.Writer.Allocating.init(context.allocator);
    defer payload.deinit();
    var json: std.json.Stringify = .{ .writer = &payload.writer };
    try json.beginObject();
    try json.objectField(key);
    try json.write(value);
    try json.endObject();
    try writeFrame(context, payload.writer.buffered());
}

pub fn writeConfigFrame(context: *runtime.RuntimeContext, config: *const model.Config) !void {
    var payload = std.Io.Writer.Allocating.init(context.allocator);
    defer payload.deinit();
    try writeDictionaryJson(context.allocator, config, &payload.writer);
    try writeFrame(context, payload.writer.buffered());
}

pub fn writeInfoFrame(context: *runtime.RuntimeContext, message: []const u8) !void {
    try writeAlpmInfoFrame(context, "InformationalOutput", message);
}

pub fn writeWarningFrame(context: *runtime.RuntimeContext, message: []const u8) !void {
    var payload = std.Io.Writer.Allocating.init(context.allocator);
    defer payload.deinit();
    var json: std.json.Stringify = .{ .writer = &payload.writer };
    try json.beginObject();
    try json.objectField("$kind");
    try json.write("alpm.info");
    try json.objectField("EventType");
    try json.write("WarningOutput");
    try json.objectField("Message");
    try json.write(message);
    try json.objectField("PackageName");
    try json.write(null);
    try json.objectField("CurrentIndex");
    try json.write(null);
    try json.objectField("TotalCount");
    try json.write(null);
    try json.objectField("Source");
    try json.write("Flatpak");
    try json.objectField("Level");
    try json.write("Warning");
    try json.objectField("TimeStamp");
    const time = try timestamp(context);
    defer context.allocator.free(time);
    try json.write(time);
    try json.endObject();
    try writeFrame(context, payload.writer.buffered());
}

pub fn writeAlpmInfoFrame(
    context: *runtime.RuntimeContext,
    event_type: []const u8,
    message: []const u8,
) !void {
    var payload = std.Io.Writer.Allocating.init(context.allocator);
    defer payload.deinit();
    var json: std.json.Stringify = .{ .writer = &payload.writer };
    try json.beginObject();
    try json.objectField("$kind");
    try json.write("alpm.info");
    try json.objectField("EventType");
    try json.write(event_type);
    try json.objectField("Message");
    try json.write(message);
    try json.objectField("PackageName");
    try json.write(null);
    try json.objectField("CurrentIndex");
    try json.write(null);
    try json.objectField("TotalCount");
    try json.write(null);
    try json.objectField("Source");
    try json.write("Alpm");
    try json.objectField("Level");
    try json.write("Information");
    try json.objectField("TimeStamp");
    const time = try timestamp(context);
    defer context.allocator.free(time);
    try json.write(time);
    try json.endObject();
    try writeFrame(context, payload.writer.buffered());
}

pub fn writeOperationProgressFrame(
    context: *runtime.RuntimeContext,
    progress: Zigalpm.operation.ProgressEvent,
) !void {
    switch (progress.envelope.backend) {
        .flatpak => try writeSimpleProgressFrame(
            context,
            "flatpak.progress",
            "Flatpak",
            progress.update.stage orelse progress.update.message orelse progress.envelope.subject,
            progressPercentage(progress.update),
        ),
        .appimage => try writeSimpleProgressFrame(
            context,
            "appimage.progress",
            "AppImage",
            progress.update.message orelse progress.envelope.subject orelse progress.update.stage,
            progressPercentage(progress.update),
        ),
        .alpm, .aur, .local_package, .download => try writeAlpmProgressFrame(context, progress),
    }
}

pub fn writePkgbuildQuestionFrame(
    context: *runtime.RuntimeContext,
    question: Zigalpm.OperationQuestion,
) !void {
    const review = question.review orelse return error.MissingReviewPayload;
    const diff = try review_output.buildDiff(context.allocator, review.old_content, review.new_content);
    defer context.allocator.free(diff);
    const question_id = try std.fmt.allocPrint(context.allocator, "{d}", .{question.question_id});
    defer context.allocator.free(question_id);

    var payload = std.Io.Writer.Allocating.init(context.allocator);
    defer payload.deinit();
    var json: std.json.Stringify = .{ .writer = &payload.writer };
    try json.beginObject();
    try json.objectField("$kind");
    try json.write("q.pkgbuilddiff");
    try json.objectField("QuestionId");
    try json.write(question_id);
    try json.objectField("PackageName");
    try json.write(review.subject);
    try json.objectField("OldPkgbuild");
    try json.write(review.old_content);
    try json.objectField("NewPkgbuild");
    try json.write(review.new_content);
    try json.objectField("Warnings");
    try json.beginArray();
    for (review.findings) |finding| {
        try json.beginObject();
        try json.objectField("Tool");
        try json.write(finding.tool);
        try json.objectField("Severity");
        try json.write(switch (finding.severity) {
            .info => "Info",
            .warning => "Warning",
            .critical => "Critical",
        });
        try json.objectField("Hook");
        try json.write(finding.hook);
        try json.objectField("MatchedLine");
        try json.write(finding.matched_line);
        try json.objectField("Message");
        try json.write(finding.message);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("DiffLines");
    try json.beginArray();
    for (diff) |line| switch (line.kind) {
        .unchanged => {
            const value = try std.fmt.allocPrint(context.allocator, "[white]  {s}[/]", .{line.text});
            defer context.allocator.free(value);
            try json.write(value);
        },
        .added => {
            const value = try std.fmt.allocPrint(context.allocator, "[green]+ {s}[/]", .{line.text});
            defer context.allocator.free(value);
            try json.write(value);
        },
        .removed => {
            const value = try std.fmt.allocPrint(context.allocator, "[red]- {s}[/]", .{line.text});
            defer context.allocator.free(value);
            try json.write(value);
        },
    };
    try json.endArray();
    try json.objectField("SourceFiles");
    if (review.related_files.len == 0) {
        try json.write(null);
    } else {
        try json.beginObject();
        for (review.related_files) |file| {
            try json.objectField(file.name);
            try json.write(file.content);
        }
        try json.endObject();
    }
    try json.endObject();
    try writeFrame(context, payload.writer.buffered());
}

pub fn writeYesNoQuestionFrame(
    context: *runtime.RuntimeContext,
    question: Zigalpm.OperationQuestion,
) !void {
    const question_id = try std.fmt.allocPrint(context.allocator, "{d}", .{question.question_id});
    defer context.allocator.free(question_id);

    var payload = std.Io.Writer.Allocating.init(context.allocator);
    defer payload.deinit();
    var json: std.json.Stringify = .{ .writer = &payload.writer };
    try json.beginObject();
    try json.objectField("$kind");
    try json.write("q.yesno");
    try json.objectField("QuestionId");
    try json.write(question_id);
    try json.objectField("QuestionKind");
    try json.write(questionKindName(question));
    try json.objectField("QuestionText");
    try json.write(question.prompt);
    if (question.pgp_key_import) |key| {
        try json.objectField("PackageName");
        try json.write(key.package_name);
        try json.objectField("Fingerprint");
        try json.write(key.fingerprint);
    }
    try json.objectField("Arguments");
    try json.beginArray();
    for (question.arguments) |argument| {
        try json.write(argument);
    }
    try json.endArray();
    try json.endObject();
    try writeFrame(context, payload.writer.buffered());
}

pub fn writeTransactionQuestionFrame(
    context: *runtime.RuntimeContext,
    question: Zigalpm.OperationQuestion,
) !void {
    const plan = question.transaction_plan orelse return error.MissingTransactionPlan;
    const question_id = try std.fmt.allocPrint(context.allocator, "{d}", .{question.question_id});
    defer context.allocator.free(question_id);

    var payload = std.Io.Writer.Allocating.init(context.allocator);
    defer payload.deinit();
    var json: std.json.Stringify = .{ .writer = &payload.writer };
    try json.beginObject();
    try json.objectField("$kind");
    try json.write("q.transaction");
    try json.objectField("QuestionId");
    try json.write(question_id);
    try json.objectField("QuestionText");
    try json.write(question.prompt);
    try json.objectField("Action");
    try json.write(@tagName(plan.action));
    try json.objectField("Packages");
    try json.beginArray();
    for (plan.packages) |package| {
        try json.beginObject();
        try json.objectField("Name");
        try json.write(package.name);
        try json.objectField("Version");
        try json.write(package.version);
        try json.objectField("Repository");
        try json.write(package.repository);
        try json.objectField("PackageBase");
        try json.write(package.package_base);
        try json.objectField("Revision");
        try json.write(package.revision);
        try json.objectField("Source");
        try json.write(@tagName(package.source));
        try json.objectField("Role");
        try json.write(@tagName(package.role));
        try json.objectField("DownloadSize");
        try json.write(package.download_size);
        try json.objectField("InstalledSize");
        try json.write(package.installed_size);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("TotalDownloadSize");
    try json.write(plan.total_download_size);
    try json.objectField("TotalInstalledSize");
    try json.write(plan.total_installed_size);
    try json.objectField("NetInstalledSize");
    try json.write(plan.net_installed_size);
    try json.endObject();
    try writeFrame(context, payload.writer.buffered());
}

pub fn writeOptionalDependenciesQuestionFrame(
    context: *runtime.RuntimeContext,
    question: Zigalpm.OperationQuestion,
) !void {
    try writeSelectionQuestionFrame(context, question, "q.optdeps", true);
}

pub fn writeProviderQuestionFrame(
    context: *runtime.RuntimeContext,
    question: Zigalpm.OperationQuestion,
) !void {
    try writeSelectionQuestionFrame(context, question, "q.provider", false);
}

fn writeSelectionQuestionFrame(
    context: *runtime.RuntimeContext,
    question: Zigalpm.OperationQuestion,
    wire_kind: []const u8,
    include_question_text: bool,
) !void {
    const question_id = try std.fmt.allocPrint(context.allocator, "{d}", .{question.question_id});
    defer context.allocator.free(question_id);

    var payload = std.Io.Writer.Allocating.init(context.allocator);
    defer payload.deinit();
    var json: std.json.Stringify = .{ .writer = &payload.writer };
    try json.beginObject();
    try json.objectField("$kind");
    try json.write(wire_kind);
    try json.objectField("QuestionId");
    try json.write(question_id);
    try json.objectField("DependencyName");
    try json.write(question.dependency_name orelse switch (question.kind) {
        .select_one, .select_many => question.prompt,
        else => "",
    });
    if (include_question_text) {
        try json.objectField("QuestionText");
        try json.write(question.prompt);
    }
    try json.objectField("Options");
    try json.beginArray();
    for (question.options, 0..) |option, index| {
        try json.beginObject();
        try json.objectField("Index");
        try json.write(index);
        try json.objectField("Name");
        try json.write(option.label);
        try json.objectField("Description");
        try json.write(option.description);
        try json.objectField("IsInstalled");
        try json.write(option.is_installed);
        try json.objectField("IsSelected");
        try json.write(option.is_selected);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try writeFrame(context, payload.writer.buffered());
}

fn questionKindName(question: Zigalpm.OperationQuestion) []const u8 {
    
    switch(question.purpose) {
        .cache_clean_extra_entries => return "CacheCleanExtraEntries",
        .package_conflict => return "PackageConflict",
        .generic => {},
    }
    
    if (question.kind == .import_pgp_key) return "ImportPgpKey";
    
    return switch (question.envelope.kind) {
        .remove => "RemovePkgs",
        .update => "ConflictPkg",
        else => "InstallIgnorePkg",
    };
}

test "cache clean question uses cache clean wire kind" {
    const question: Zigalpm.OperationQuestion = .{
        .question_id = 1,
        .envelope = .{
            .operation_id = 1,
            .parent_id = null,
            .backend = .alpm,
            .kind = .cleanup,
            .subject = null,
        },
        .kind = .confirmation,
        .purpose = .cache_clean_extra_entries,
        .prompt = "Would you like to remove extra cache entries?",
        .options = &.{},
        .attachments = &.{},
        .review = null,
        .arguments = &.{},
        .transaction_plan = null,
        .dependency_name = null,
        .pgp_key_import = null,
        .default_response = .accepted,
    };

    try std.testing.expectEqualStrings(
        "CacheCleanExtraEntries",
        questionKindName(question),
    );
}

fn writeAlpmProgressFrame(
    context: *runtime.RuntimeContext,
    progress: Zigalpm.operation.ProgressEvent,
) !void {
    const percent = progressPercentage(progress.update);
    const current = progress.update.bytes_completed orelse
        progress.update.completed orelse
        @as(u64, percent);
    const total = progress.update.bytes_total orelse
        progress.update.total orelse
        if (progress.update.percentage != null) @as(u64, 100) else 0;
    const package_name = progress.update.message orelse
        progress.envelope.subject orelse
        "Unknown Package";
    const message = progressMessage(progress.update.stage);

    var payload = std.Io.Writer.Allocating.init(context.allocator);
    defer payload.deinit();
    var json: std.json.Stringify = .{ .writer = &payload.writer };
    try json.beginObject();
    try json.objectField("$kind");
    try json.write("alpm.progress");
    try json.objectField("PackageName");
    try json.write(package_name);
    try json.objectField("CurrentDownload");
    try json.write(current);
    try json.objectField("TotalDownload");
    try json.write(total);
    try json.objectField("ProgressType");
    try json.write(progressType(progress));
    try json.objectField("Percent");
    try json.write(percent);
    try json.objectField("Stage");
    try json.write(progress.update.stage);
    try json.objectField("Message");
    try json.write(message);
    try json.objectField("Source");
    try json.write("Alpm");
    try json.objectField("Level");
    try json.write("Information");
    try json.objectField("TimeStamp");
    const time = try timestamp(context);
    defer context.allocator.free(time);
    try json.write(time);
    try json.endObject();
    try writeFrame(context, payload.writer.buffered());
}

fn writeSimpleProgressFrame(
    context: *runtime.RuntimeContext,
    kind: []const u8,
    source: []const u8,
    status: ?[]const u8,
    percentage: u8,
) !void {
    var payload = std.Io.Writer.Allocating.init(context.allocator);
    defer payload.deinit();
    var json: std.json.Stringify = .{ .writer = &payload.writer };
    try json.beginObject();
    try json.objectField("$kind");
    try json.write(kind);
    try json.objectField("Status");
    try json.write(status);
    try json.objectField("Percentage");
    try json.write(percentage);
    try json.objectField("Source");
    try json.write(source);
    try json.objectField("Level");
    try json.write("Information");
    try json.objectField("TimeStamp");
    const time = try timestamp(context);
    defer context.allocator.free(time);
    try json.write(time);
    try json.endObject();
    try writeFrame(context, payload.writer.buffered());
}

fn progressPercentage(update: Zigalpm.operation.ProgressUpdate) u8 {
    if (update.native_code) |native_code| switch (native_code) {
        512, 514, 516, 518 => return 0,
        513, 515, 517, 519, 520, 521 => return 100,
        else => {},
    };
    if (update.percentage) |percentage| {
        if (std.math.isNan(percentage) or percentage <= 0) return 0;
        if (percentage >= 100) return 100;
        return @intFromFloat(percentage);
    }
    const current = update.bytes_completed orelse update.completed orelse 0;
    const total = update.bytes_total orelse update.total orelse 0;
    if (total == 0) return 0;
    return @intCast(@min(@as(u128, 100), (@as(u128, current) * 100) / total));
}

fn progressType(progress: Zigalpm.operation.ProgressEvent) []const u8 {
    if (progress.envelope.backend == .download) {
        const subject = progress.envelope.subject orelse "";
        return if (std.mem.endsWith(u8, subject, ".db") or
            std.mem.endsWith(u8, subject, ".db.sig"))
            "DatabaseDownload"
        else
            "PackageDownload";
    }
    if (progress.update.native_code) |native_code| return switch (native_code) {
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
        200 => "MakepkgBuild",
        201 => "MakepkgPackage",
        202 => "AurDownload",
        512, 513 => "AurDownload",
        514, 515 => "MakepkgBuild",
        516, 517 => "AddStart",
        518, 519 => "RemoveStart",
        else => fallbackProgressType(progress.envelope.kind),
    };
    return fallbackProgressType(progress.envelope.kind);
}

fn fallbackProgressType(kind: Zigalpm.operation.OperationKind) []const u8 {
    return switch (kind) {
        .install => "AddStart",
        .remove, .cleanup => "RemoveStart",
        .update => "UpgradeStart",
        .sync => "DatabaseDownload",
        .download => "PackageDownload",
        .build => "MakepkgBuild",
        .search, .inspect, .configure, .launch => "LoadStart",
    };
}

fn progressMessage(stage: ?[]const u8) ?[]const u8 {
    const value = stage orelse return null;
    if (std.ascii.eqlIgnoreCase(value, "transaction") or
        std.ascii.eqlIgnoreCase(value, "download") or
        std.mem.startsWith(u8, value, "aur_")) return null;
    return value;
}

test "AUR lifecycle progress uses stage semantics instead of package position" {
    const build_start: Zigalpm.operation.ProgressEvent = .{
        .envelope = .{
            .operation_id = 1,
            .parent_id = null,
            .backend = .aur,
            .kind = .install,
            .subject = "demo",
        },
        .update = .{
            .stage = "aur_build_start",
            .completed = 1,
            .total = 1,
            .native_code = 514,
        },
    };
    try std.testing.expectEqualStrings("MakepkgBuild", progressType(build_start));
    try std.testing.expectEqual(@as(u8, 0), progressPercentage(build_start.update));
    try std.testing.expect(progressMessage(build_start.update.stage) == null);

    var build_done = build_start;
    build_done.update.stage = "aur_build_done";
    build_done.update.native_code = 515;
    try std.testing.expectEqual(@as(u8, 100), progressPercentage(build_done.update));

    var install_start = build_start;
    install_start.update.stage = "aur_install_start";
    install_start.update.native_code = 516;
    try std.testing.expectEqualStrings("AddStart", progressType(install_start));
    try std.testing.expectEqual(@as(u8, 0), progressPercentage(install_start.update));
}

pub fn writeErrorFrame(context: *runtime.RuntimeContext, message: []const u8) !void {
    var payload = std.Io.Writer.Allocating.init(context.allocator);
    defer payload.deinit();
    var json: std.json.Stringify = .{ .writer = &payload.writer };
    try json.beginObject();
    try json.objectField("$kind");
    try json.write("alpm.error");
    try json.objectField("ErrorMessage");
    try json.write(message);
    try json.objectField("Source");
    try json.write("Alpm");
    try json.objectField("Level");
    try json.write("Error");
    try json.objectField("TimeStamp");
    const time = try timestamp(context);
    defer context.allocator.free(time);
    try json.write(time);
    try json.endObject();
    try writeFrame(context, payload.writer.buffered());
}

pub fn writeSuccess(context: *runtime.RuntimeContext, message: []const u8) !void {
    try colors.printLine(context, .success, "{s}", .{message});
}

pub fn writeFailure(context: *runtime.RuntimeContext, message: []const u8) !void {
    try colors.printLine(context, .err, "{s}", .{message});
}

pub fn writeWarning(context: *runtime.RuntimeContext, message: []const u8) !void {
    try context.stderr.print("warning: {s}\n", .{message});
}

pub fn writeFrame(context: *runtime.RuntimeContext, payload: []const u8) !void {
    const size = std.base64.standard.Encoder.calcSize(payload.len);
    const encoded = try context.allocator.alloc(u8, size);
    defer context.allocator.free(encoded);
    const result = std.base64.standard.Encoder.encode(encoded, payload);
    try context.stdout.print("[JSON]{s}[/JSON]\n", .{result});
}

pub fn supportsAnsi(context: *const runtime.RuntimeContext) bool {
    if (!context.stdin_is_tty or !context.stdout_is_tty) return false;
    if (xdg.getEnv(context, "NO_COLOR") != null) return false;
    if (xdg.getEnv(context, "TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return false;
    }
    return true;
}

fn timestamp(context: *runtime.RuntimeContext) ![]const u8 {
    const seconds = std.Io.Clock.real.now(context.io).toSeconds();
    if (seconds < 0) return error.InvalidTimestamp;
    return format.formatIsoDateTimeUtc(context.allocator, seconds);
}
