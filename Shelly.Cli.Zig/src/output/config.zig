const std = @import("std");
const Zigalpm = @import("Zigalpm");
const model = @import("../config/model.zig");
const runtime = @import("../runtime/context.zig");
const xdg = @import("../runtime/xdg.zig");
const review_output = @import("review.zig");

pub fn writeListPlain(
    context: *runtime.RuntimeContext,
    config: *const model.Config,
) !void {
    var width: usize = 0;
    for (config.values.keys()) |key| width = @max(width, key.len);
    const use_color = supportsAnsi(context);
    for (config.values.keys()) |key| {
        if (use_color) try context.stdout.writeAll("\x1b[38;2;0;255;255m");
        try context.stdout.print("{s}", .{key});
        try context.stdout.splatByteAll(' ', width - key.len);
        if (use_color) try context.stdout.writeAll("\x1b[0m");
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
    try json.endObject();
    try writeFrame(context, payload.writer.buffered());
}

fn questionKindName(question: Zigalpm.OperationQuestion) []const u8 {
    return switch (question.envelope.kind) {
        .remove => "RemovePkgs",
        .update => "ConflictPkg",
        else => "InstallIgnorePkg",
    };
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
        std.ascii.eqlIgnoreCase(value, "download")) return null;
    return value;
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
    if (supportsAnsi(context)) {
        try context.stdout.print("\x1b[38;2;0;128;0m{s}\x1b[0m\n", .{message});
    } else {
        try context.stdout.print("{s}\n", .{message});
    }
}

pub fn writeFailure(context: *runtime.RuntimeContext, message: []const u8) !void {
    if (supportsAnsi(context)) {
        try context.stdout.print("\x1b[38;2;255;0;0m{s}\x1b[0m\n", .{message});
    } else {
        try context.stdout.print("{s}\n", .{message});
    }
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
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(
        context.allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}+00:00",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}
