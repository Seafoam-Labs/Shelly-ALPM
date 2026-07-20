const std = @import("std");
const Zigalpm = @import("Zigalpm");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");

const PacfileManager = Zigalpm.PacfileManager;
const Pacfile = Zigalpm.alpm.Pacfile;

const WorkflowOptions = struct {
    search_mode: Zigalpm.alpm.PacfileSearchMode = .pacman_database,
    backup: bool = false,
    output_only: bool = false,
    three_way: bool = false,
};

const Choice = enum {
    view,
    merge,
    skip,
    remove,
    overwrite,
    quit,
};

pub fn run(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !u8 {
    const parsed = parseWorkflowOptions(invocation) orelse {
        try context.stderr.writeAll("Only one pacfile search option may be used at a time.\n");
        return 1;
    };
    if (invocation.globals.json and !parsed.output_only) {
        try context.stderr.writeAll("Pacfile JSON output requires --output.\n");
        return 1;
    }

    var config = try Zigalpm.alpm.configuration.Configuration.parse(
        context.allocator,
        context.io,
        "/etc/pacman.conf",
    );
    defer config.deinitialize();

    const cache_directories = try optionValues(context.allocator, invocation, "--cachedir");
    defer context.allocator.free(cache_directories);
    const find_paths = try configuredFindPaths(context, invocation);
    defer context.allocator.free(find_paths);
    const diff_program = try configuredDiffProgram(context, invocation);
    defer context.allocator.free(diff_program);
    const merge_program = try configuredMergeProgram(context, invocation);
    defer context.allocator.free(merge_program);

    var manager = PacfileManager.init(context.allocator, context.io, .{
        .root_directory = config.root_directory,
        .database_path = config.database_path,
        .cache_directory = if (cache_directories.len > 0) cache_directories[0] else config.cache_directory,
        .additional_cache_directories = if (cache_directories.len > 1) cache_directories[1..] else &.{},
        .find_paths = find_paths,
        .diff_program = diff_program,
        .merge_program = merge_program,
    });
    return runWithManager(context, invocation, &manager, parsed);
}

fn runWithManager(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    manager: *PacfileManager,
    options: WorkflowOptions,
) !u8 {
    const files = manager.discover(options.search_mode) catch |err| {
        try context.stderr.print("Unable to discover pacfiles: {t}\n", .{err});
        return 1;
    };
    defer Pacfile.deinitSlice(context.allocator, files);

    if (options.output_only) {
        try writeDiscoveredPaths(context, invocation, files);
        return 0;
    }

    for (files) |file| {
        if (file.kind == .numbered_pacsave) continue;
        const quit = try maintainOne(context, invocation, manager, file, options);
        if (quit) return 0;
    }
    for (files) |file| {
        if (file.kind == .numbered_pacsave)
            try context.stderr.print("warning: Ignoring {s}\n", .{file.path});
    }
    return 0;
}

fn maintainOne(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    manager: *PacfileManager,
    file: Pacfile,
    options: WorkflowOptions,
) !bool {
    const label = kindLabel(file.kind);
    try context.stdout.print("{s} file found for {s}\n", .{ label, file.original_path });
    const current_state = manager.state(file) catch |err| {
        try context.stderr.print("Unable to compare {s}: {t}\n", .{ file.path, err });
        return false;
    };
    switch (current_state) {
        .original_missing => {
            try context.stderr.print("warning: {s} does not exist\n", .{file.original_path});
            if (!invocation.globals.no_confirm and
                try confirm(context, "Remove the pacfile?", false))
            {
                manager.remove(file) catch |err| {
                    try context.stderr.print("Unable to remove {s}: {t}\n", .{ file.path, err });
                    return false;
                };
                try context.stdout.print("removed {s}\n", .{file.path});
            }
            return false;
        },
        .identical => {
            try context.stdout.writeAll("  Files are identical, removing...\n");
            manager.remove(file) catch |err| {
                try context.stderr.print("Unable to remove {s}: {t}\n", .{ file.path, err });
                return false;
            };
            try context.stdout.print("removed {s}\n", .{file.path});
            return false;
        },
        .different => {},
    }

    if (invocation.globals.no_confirm) return false;
    while (true) {
        switch (try promptChoice(context, label)) {
            .quit => return true,
            .skip => return false,
            .remove => {
                manager.remove(file) catch |err| {
                    try context.stderr.print("Unable to remove {s}: {t}\n", .{ file.path, err });
                    continue;
                };
                try context.stdout.print("removed {s}\n", .{file.path});
                return false;
            },
            .overwrite => {
                manager.overwrite(file, options.backup) catch |err| {
                    try context.stderr.print("Unable to overwrite {s}: {t}\n", .{ file.original_path, err });
                    continue;
                };
                if (options.backup)
                    try context.stdout.print("saved {s}.bak\n", .{file.original_path});
                try context.stdout.print("installed {s}\n", .{file.original_path});
                return false;
            },
            .view => {
                try flushForExternalTool(context);
                const result = manager.viewDiff(
                    file,
                    if (options.three_way) .three_way else .two_way,
                ) catch |err| {
                    try context.stderr.print("Unable to view {s}: {t}\n", .{ file.path, err });
                    continue;
                };
                if (result.fell_back_to_two_way)
                    try context.stderr.writeAll("warning: No older cached package was available; used a two-way diff.\n");
                if (result.removed_identical_pacfile) {
                    try context.stdout.writeAll("  Files are identical, removing the pacfile...\n");
                    return false;
                }
            },
            .merge => {
                var prepared = manager.prepareMerge(file) catch |err| {
                    try context.stderr.print("Unable to merge {s}: {t}\n", .{ file.path, err });
                    continue;
                };
                defer prepared.deinit();
                if (prepared.has_conflicts)
                    try context.stderr.writeAll("warning: The automatic merge contains conflicts.\n")
                else
                    try context.stdout.writeAll("  Merged without conflicts.\n");
                try flushForExternalTool(context);
                const preview = manager.viewPreparedMerge(&prepared) catch |err| {
                    try context.stderr.print("Unable to preview the merge: {t}\n", .{err});
                    continue;
                };
                if (!preview.successful())
                    try context.stderr.writeAll("warning: The diff program exited unsuccessfully.\n");
                if (!try confirm(context, "Would you like to use the results of the merge?", false))
                    continue;
                manager.applyPreparedMerge(&prepared, options.backup) catch |err| {
                    prepared.preserveWorkspace();
                    try context.stderr.print(
                        "Unable to apply the merge: {t}. The merged file is preserved at {s}\n",
                        .{ err, prepared.merged_path },
                    );
                    continue;
                };
                if (options.backup)
                    try context.stdout.print("saved {s}.bak\n", .{file.original_path});
                try context.stdout.print("installed merged {s}\n", .{file.original_path});
                return false;
            },
        }
    }
}

fn parseWorkflowOptions(invocation: *const parser.Invocation) ?WorkflowOptions {
    var result: WorkflowOptions = .{};
    var search_modes: usize = 0;
    for (invocation.options) |option| {
        if (std.mem.eql(u8, option.name, "--find")) {
            result.search_mode = .find;
            search_modes += 1;
        } else if (std.mem.eql(u8, option.name, "--locate")) {
            result.search_mode = .locate;
            search_modes += 1;
        } else if (std.mem.eql(u8, option.name, "--pacmandb")) {
            result.search_mode = .pacman_database;
            search_modes += 1;
        } else if (std.mem.eql(u8, option.name, "--backup")) {
            result.backup = true;
        } else if (std.mem.eql(u8, option.name, "--output")) {
            result.output_only = true;
        } else if (std.mem.eql(u8, option.name, "--threeway")) {
            result.three_way = true;
        }
    }
    return if (search_modes <= 1) result else null;
}

/// Interactive maintenance can remove or replace root-owned configuration
/// files, including automatic cleanup of identical pacfiles. Elevate before
/// discovery so every possible interactive action has consistent privileges.
pub fn requiresElevation(invocation: *const parser.Invocation) bool {
    if (hasOption(invocation, "--output")) return false;
    // Let validation reject this combination without prompting for elevation.
    if (invocation.globals.json) return false;
    return true;
}

fn writeDiscoveredPaths(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    files: []const Pacfile,
) !void {
    if (!invocation.globals.json) {
        for (files) |file| try context.stdout.print("{s}\n", .{file.path});
        return;
    }
    var json: std.json.Stringify = .{ .writer = context.stdout };
    try json.beginArray();
    for (files) |file| try json.write(file.path);
    try json.endArray();
    try context.stdout.writeByte('\n');
}

fn promptChoice(context: *runtime.RuntimeContext, label: []const u8) !Choice {
    const reader = context.stdin orelse return .skip;
    while (true) {
        try context.stdout.print(
            "(V)iew, (M)erge, (S)kip, (R)emove {s}, (O)verwrite with {s}, (Q)uit: [v/m/s/r/o/q] ",
            .{ label, label },
        );
        try context.stdout.flush();
        const input = (try reader.takeDelimiter('\n')) orelse return .skip;
        const answer = std.mem.trim(u8, input, " \t\r\n");
        if (answer.len == 1) return switch (std.ascii.toLower(answer[0])) {
            'v' => .view,
            'm' => .merge,
            's' => .skip,
            'r' => .remove,
            'o' => .overwrite,
            'q' => .quit,
            else => {
                try context.stdout.writeAll("  Invalid answer.\n");
                continue;
            },
        };
        try context.stdout.writeAll("  Invalid answer.\n");
    }
}

fn confirm(context: *runtime.RuntimeContext, prompt: []const u8, default_value: bool) !bool {
    const reader = context.stdin orelse return default_value;
    while (true) {
        try context.stdout.print("{s} [{s}] ", .{ prompt, if (default_value) "Y/n" else "y/N" });
        try context.stdout.flush();
        const input = (try reader.takeDelimiter('\n')) orelse return default_value;
        const answer = std.mem.trim(u8, input, " \t\r\n");
        if (answer.len == 0) return default_value;
        if (std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes")) return true;
        if (std.ascii.eqlIgnoreCase(answer, "n") or std.ascii.eqlIgnoreCase(answer, "no")) return false;
        try context.stdout.writeAll("  Invalid answer.\n");
    }
}

fn configuredFindPaths(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) ![]const []const u8 {
    const explicit = try optionValues(context.allocator, invocation, "--search-path");
    if (explicit.len > 0) return explicit;
    context.allocator.free(explicit);
    if (environmentValue(context, "DIFFSEARCHPATH")) |value| {
        const paths = try splitWords(context.allocator, value);
        if (paths.len > 0) return paths;
        context.allocator.free(paths);
    }
    const paths = try context.allocator.alloc([]const u8, 1);
    paths[0] = "/etc";
    return paths;
}

fn configuredDiffProgram(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) ![]const []const u8 {
    if (lastOptionValue(invocation, "--diff-program") orelse environmentValue(context, "DIFFPROG")) |value| {
        const words = try splitWords(context.allocator, value);
        if (words.len > 0) return words;
        context.allocator.free(words);
    }
    const editor = environmentValue(context, "EDITOR");
    return duplicateWords(
        context.allocator,
        if (editor != null and std.mem.eql(u8, editor.?, "nvim")) &.{ "nvim", "-d" } else &.{ "vim", "-d" },
    );
}

fn configuredMergeProgram(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) ![]const []const u8 {
    if (lastOptionValue(invocation, "--merge-program") orelse environmentValue(context, "MERGEPROG")) |value| {
        const words = try splitWords(context.allocator, value);
        if (words.len > 0) return words;
        context.allocator.free(words);
    }
    return duplicateWords(context.allocator, &.{ "diff3", "-m" });
}

fn optionValues(
    allocator: std.mem.Allocator,
    invocation: *const parser.Invocation,
    name: []const u8,
) ![]const []const u8 {
    var values: std.ArrayList([]const u8) = .empty;
    for (invocation.options) |option| {
        if (std.mem.eql(u8, option.name, name) and option.value != null)
            try values.append(allocator, option.value.?);
    }
    return values.toOwnedSlice(allocator);
}

fn lastOptionValue(invocation: *const parser.Invocation, name: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    for (invocation.options) |option| {
        if (std.mem.eql(u8, option.name, name)) result = option.value;
    }
    return result;
}

fn hasOption(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| if (std.mem.eql(u8, option.name, name)) return true;
    return false;
}

fn environmentValue(context: *const runtime.RuntimeContext, name: []const u8) ?[]const u8 {
    return if (context.environment) |environment| environment.get(name) else null;
}

fn splitWords(allocator: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (iterator.next()) |word| try words.append(allocator, word);
    return words.toOwnedSlice(allocator);
}

fn duplicateWords(allocator: std.mem.Allocator, words: []const []const u8) ![]const []const u8 {
    return allocator.dupe([]const u8, words);
}

fn flushForExternalTool(context: *runtime.RuntimeContext) !void {
    try context.stdout.flush();
    try context.stderr.flush();
}

fn kindLabel(kind: Zigalpm.alpm.PacfileKind) []const u8 {
    return switch (kind) {
        .pacnew => "pacnew",
        .pacorig => "pacorig",
        .pacsave => "pacsave",
        .numbered_pacsave => "numbered pacsave",
    };
}

test "pacfile option parsing defaults to pacman DB and rejects search conflicts" {
    const standard = parser.Invocation{
        .command = undefined,
        .arguments = &.{},
        .positionals = &.{},
        .options = &.{
            .{ .name = "--pacfiles", .value = "true" },
            .{ .name = "--backup", .value = "true" },
            .{ .name = "--threeway", .value = "true" },
        },
        .globals = .{},
    };
    const parsed = parseWorkflowOptions(&standard).?;
    try std.testing.expectEqual(Zigalpm.alpm.PacfileSearchMode.pacman_database, parsed.search_mode);
    try std.testing.expect(parsed.backup);
    try std.testing.expect(parsed.three_way);

    var conflicting = standard;
    conflicting.options = &.{
        .{ .name = "--pacfiles", .value = "true" },
        .{ .name = "--find", .value = "true" },
        .{ .name = "--locate", .value = "true" },
    };
    try std.testing.expect(parseWorkflowOptions(&conflicting) == null);

    try std.testing.expect(requiresElevation(&standard));
    var output_only = standard;
    output_only.options = &.{
        .{ .name = "--pacfiles", .value = "true" },
        .{ .name = "--output", .value = "true" },
    };
    try std.testing.expect(!requiresElevation(&output_only));
}

test "pacdiff choice prompt retries invalid input" {
    var input = std.Io.Reader.fixed("invalid\no\n");
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .stdin = &input,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    try std.testing.expectEqual(Choice.overwrite, try promptChoice(&context, "pacnew"));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Invalid answer") != null);
}

test "pacfile utility output and safe automatic cleanup use the ALPM backend" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(root);
    const original = try std.fs.path.join(std.testing.allocator, &.{ root, "example.conf" });
    defer std.testing.allocator.free(original);
    const pacnew = try std.fmt.allocPrint(std.testing.allocator, "{s}.pacnew", .{original});
    defer std.testing.allocator.free(pacnew);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = original, .data = "same\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = pacnew, .data = "same\n" });

    var find_paths = [_][]const u8{root};
    var manager = PacfileManager.init(std.testing.allocator, std.testing.io, .{ .find_paths = &find_paths });
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var invocation: parser.Invocation = .{
        .command = undefined,
        .arguments = &.{},
        .positionals = &.{},
        .options = &.{},
        .globals = .{},
    };
    try std.testing.expectEqual(
        @as(u8, 0),
        try runWithManager(&context, &invocation, &manager, .{ .search_mode = .find, .output_only = true }),
    );
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), pacnew) != null);

    stdout.writer.end = 0;
    invocation.globals.no_confirm = true;
    try std.testing.expectEqual(
        @as(u8, 0),
        try runWithManager(&context, &invocation, &manager, .{ .search_mode = .find }),
    );
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, pacnew, .{}));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Files are identical") != null);
}
