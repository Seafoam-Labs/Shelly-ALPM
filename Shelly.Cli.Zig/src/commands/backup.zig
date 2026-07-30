const std = @import("std");
const Zigalpm = @import("Zigalpm");
const output = @import("../output/config.zig");
const format = @import("../output/format.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const spec = @import("../cli/spec.zig");
const xdg = @import("../runtime/xdg.zig");
const install = @import("install.zig");

const command_path = "shelly backup utility";

pub const Package = struct {
    name: []const u8,
    explicit: bool,
};

pub const Flatpak = struct {
    id: []const u8,
    kind: i32,
};

pub const State = struct {
    standard: []const Package,
    aur: []const Package,
    flatpak: []const Flatpak,
};

const Runner = struct {
    data: ?*anyopaque = null,
    call: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
    ) anyerror!State,
};

const real_runner: Runner = .{ .call = collectState };

const InstallCaller = struct {
    data: ?*anyopaque = null,
    call: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        backend: install.Backend,
        targets: []const []const u8,
        options: install.CallOptions,
    ) anyerror!u8,
};

fn callInstall(
    data: ?*anyopaque,
    _: *runtime.RuntimeContext,
    backend: install.Backend,
    targets: []const []const u8,
    options: install.CallOptions,
) !u8 {
    const caller: *install.Caller = @ptrCast(@alignCast(data.?));
    return caller.call(backend, targets, options);
}

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;
    return try executeWithRunner(context, invocation, real_runner);
}

fn executeWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
) !u8 {
    const export_requested = optionEnabled(invocation, "--export");
    const import_requested = optionEnabled(invocation, "--import");
    if (!export_requested and !import_requested) {
        try writeOperationRequired(context, invocation);
        return 1;
    }
    if (export_requested and import_requested) {
        try writeOperationConflict(context, invocation);
        return 1;
    }
    if (import_requested) return executeImport(context, invocation);

    const state = runner.call(runner.data, context) catch |err| {
        try writeFailure(context, invocation, err);
        return 1;
    };

    var toml = std.Io.Writer.Allocating.init(context.allocator);
    defer toml.deinit();
    writeToml(context.allocator, &toml.writer, state) catch |err| {
        try writeFailure(context, invocation, err);
        return 1;
    };

    const file_name = exportFileName(context, optionValue(invocation, "--name")) catch |err| {
        try writeFailure(context, invocation, err);
        return 1;
    };
    const path = exportPath(context, optionValue(invocation, "--directory"), file_name) catch |err| {
        try writeFailure(context, invocation, err);
        return 1;
    };
    writeExportFile(context, path, toml.writer.buffered()) catch |err| {
        try writeFailure(context, invocation, err);
        return 1;
    };

    try context.stdout.writeAll(toml.writer.buffered());
    if (toml.writer.buffered().len == 0 or toml.writer.buffered()[toml.writer.buffered().len - 1] != '\n')
        try context.stdout.writeByte('\n');
    try writeSuccess(context, path);
    return 0;
}

fn executeImport(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !u8 {
    const requested_name = optionValue(invocation, "--name") orelse {
        try writeImportFailure(context, invocation, error.BackupImportNameRequired);
        return 1;
    };
    if (std.mem.trim(u8, requested_name, " \t\r\n").len == 0) {
        try writeImportFailure(context, invocation, error.BackupImportNameRequired);
        return 1;
    }
    const file_name = exportFileName(context, requested_name) catch |err| {
        try writeImportFailure(context, invocation, err);
        return 1;
    };
    const path = exportPath(context, optionValue(invocation, "--directory"), file_name) catch |err| {
        try writeImportFailure(context, invocation, err);
        return 1;
    };
    const source = std.Io.Dir.cwd().readFileAlloc(
        context.io,
        path,
        context.allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| {
        try writeImportFailure(context, invocation, err);
        return 1;
    };
    defer context.allocator.free(source);

    importState(context, invocation, source) catch |err| {
        try writeImportFailure(context, invocation, err);
        return 1;
    };
    try writeImportSuccess(context, path);
    return 0;
}

fn importState(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    source: []const u8,
) !void {
    var caller = try install.Caller.init(context);
    return importStateWithCaller(
        context,
        invocation,
        source,
        .{ .data = &caller, .call = callInstall },
    );
}

fn importStateWithCaller(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    source: []const u8,
    caller: InstallCaller,
) !void {
    const state = try parseBackupToml(context.allocator, source);
    const options: install.CallOptions = .{
        .no_confirm = invocation.globals.no_confirm,
        .ui_mode = invocation.globals.ui_mode,
    };

    try installTargets(context, caller, .standard, state.standard, options);
    try installTargets(context, caller, .aur, state.aur, options);
    for (state.flatpak) |application_id|
        try installTargets(context, caller, .flatpak, &.{application_id}, options);
}

fn installTargets(
    context: *runtime.RuntimeContext,
    caller: InstallCaller,
    backend: install.Backend,
    targets: []const []const u8,
    options: install.CallOptions,
) !void {
    if (targets.len == 0) return;
    if (try caller.call(caller.data, context, backend, targets, options) != 0)
        return error.BackupPackageInstallFailed;
}

fn collectState(_: ?*anyopaque, context: *runtime.RuntimeContext) !State {
    var standard: std.ArrayList(Package) = .empty;
    var aur: std.ArrayList(Package) = .empty;
    var flatpaks: std.ArrayList(Flatpak) = .empty;

    {
        const manager = try Zigalpm.AlpmManager.init(
            context.allocator,
            context.environ,
            null,
            false,
            null,
        );
        defer manager.deinit();
        if (!manager.show_hidden_packages) _ = manager.toggle_hidden_packages();

        const installed = try manager.get_installed_packages();
        defer Zigalpm.alpm.OwnedPackage.deinitSlice(context.allocator, installed);
        const foreign = try manager.get_foreign_packages();
        defer Zigalpm.alpm.OwnedPackage.deinitSlice(context.allocator, foreign);

        for (installed) |package| {
            const name = package.name() orelse continue;
            if (containsOwnedPackage(foreign, name)) continue;
            try standard.append(context.allocator, .{
                .name = try context.allocator.dupe(u8, name),
                .explicit = package.install_reason() == .Explicit,
            });
        }
    }

    {
        const manager = try Zigalpm.AurManager.init(context.allocator, context.environ, .{
            .show_hidden_packages = true,
        });
        defer manager.deinit();
        const installed = try manager.getInstalledPackages();
        defer Zigalpm.aur.models.Package.deinitSlice(context.allocator, installed);
        for (installed) |package| {
            try aur.append(context.allocator, .{
                .name = try context.allocator.dupe(u8, package.name),
                .explicit = package.explicit,
            });
        }
    }

    flatpak_collection: {
        var manager = Zigalpm.FlatpakManager{
            .allocator = context.allocator,
            .io = context.io,
        };
        defer manager.deinit();
        const installed = manager.list_installed_applications() catch |err| {
            if (Zigalpm.flatpak.errors.unavailableMessage(err)) |message| {
                try output.writeWarning(context, message);
                break :flatpak_collection;
            }
            return err;
        };
        defer Zigalpm.flatpak.InstalledApplication.deinitSlice(context.allocator, installed);
        for (installed) |application| {
            try flatpaks.append(context.allocator, .{
                .id = try context.allocator.dupe(u8, application.id),
                .kind = @intFromEnum(application.kind),
            });
        }
    }

    return .{
        .standard = try standard.toOwnedSlice(context.allocator),
        .aur = try aur.toOwnedSlice(context.allocator),
        .flatpak = try flatpaks.toOwnedSlice(context.allocator),
    };
}

fn containsOwnedPackage(packages: []const Zigalpm.alpm.OwnedPackage, name: []const u8) bool {
    for (packages) |package| {
        if (std.mem.eql(u8, package.name() orelse continue, name)) return true;
    }
    return false;
}

fn writeToml(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    state: State,
) !void {
    const standard = try selectedPackages(allocator, state.standard);
    const aur = try selectedPackages(allocator, state.aur);
    const flatpaks = try selectedFlatpaks(allocator, state.flatpak);

    try writePackageArray(writer, "standard", standard);
    try writer.writeByte('\n');
    try writePackageArray(writer, "aur", aur);
    try writer.writeByte('\n');
    try writeFlatpakArray(writer, flatpaks);
}

fn selectedPackages(
    allocator: std.mem.Allocator,
    packages: []const Package,
) ![]Package {
    var selected: std.ArrayList(Package) = .empty;
    for (packages) |package| {
        if (package.explicit) try selected.append(allocator, package);
    }
    std.mem.sort(Package, selected.items, {}, struct {
        fn lessThan(_: void, left: Package, right: Package) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return selected.toOwnedSlice(allocator);
}

fn selectedFlatpaks(
    allocator: std.mem.Allocator,
    flatpaks: []const Flatpak,
) ![]Flatpak {
    var selected: std.ArrayList(Flatpak) = .empty;
    for (flatpaks) |application| {
        // Flatpak application refs are user-selected objects; runtime refs are
        // dependencies and are intentionally omitted from an explicit export.
        if (application.kind != 0 or containsFlatpak(selected.items, application.id)) continue;
        // The same ID may exist at both system and user scope. A TOML table
        // cannot contain duplicate keys, and reinstalling the ID only needs one
        // entry, so retain the system-first result returned by the manager.
        try selected.append(allocator, application);
    }
    std.mem.sort(Flatpak, selected.items, {}, struct {
        fn lessThan(_: void, left: Flatpak, right: Flatpak) bool {
            return std.mem.lessThan(u8, left.id, right.id);
        }
    }.lessThan);
    return selected.toOwnedSlice(allocator);
}

fn containsFlatpak(flatpaks: []const Flatpak, id: []const u8) bool {
    for (flatpaks) |application| {
        if (std.mem.eql(u8, application.id, id)) return true;
    }
    return false;
}

fn writePackageArray(
    writer: *std.Io.Writer,
    type_name: []const u8,
    packages: []const Package,
) !void {
    try writer.print("{s} = [\n", .{type_name});
    for (packages) |package| {
        try writer.writeAll("  ");
        try writeTomlString(writer, package.name);
        try writer.writeAll(",\n");
    }
    try writer.writeAll("]\n");
}

fn writeFlatpakArray(writer: *std.Io.Writer, flatpaks: []const Flatpak) !void {
    try writer.writeAll("flatpak = [\n");
    for (flatpaks) |application| {
        try writer.writeAll("  ");
        try writeTomlString(writer, application.id);
        try writer.writeAll(",\n");
    }
    try writer.writeAll("]\n");
}

fn writeTomlString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        0x00...0x07, 0x0b, 0x0e...0x1f, 0x7f => try writer.print("\\u{X:0>4}", .{byte}),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn exportFileName(
    context: *runtime.RuntimeContext,
    requested_name: ?[]const u8,
) ![]const u8 {
    if (requested_name) |name| {
        if (name.len > 0) {
            if (std.mem.endsWith(u8, name, ".toml"))
                return context.allocator.dupe(u8, name);
            return std.fmt.allocPrint(context.allocator, "{s}.toml", .{name});
        }
    }

    const seconds = std.Io.Clock.real.now(context.io).toSeconds();
    if (seconds < 0) return error.InvalidTimestamp;
    const stamp = try format.formatCompactDateTime(context.allocator, seconds);
    defer context.allocator.free(stamp);
    return std.fmt.allocPrint(context.allocator, "{s}_shelly.toml", .{stamp});
}

fn exportPath(
    context: *runtime.RuntimeContext,
    requested_output: ?[]const u8,
    file_name: []const u8,
) ![]const u8 {
    if (requested_output) |directory| {
        if (directory.len > 0)
            return std.fs.path.join(context.allocator, &.{ directory, file_name });
    }
    return xdg.shellyCache(context, &.{file_name});
}

fn writeExportFile(
    context: *runtime.RuntimeContext,
    path: []const u8,
    contents: []const u8,
) !void {
    if (std.fs.path.dirname(path)) |directory|
        try std.Io.Dir.cwd().createDirPath(context.io, directory);
    var file = try std.Io.Dir.cwd().createFile(context.io, path, .{});
    defer file.close(context.io);
    try file.writeStreamingAll(context.io, contents);
}

fn writeSuccess(context: *runtime.RuntimeContext, path: []const u8) !void {
    if (output.supportsAnsi(context))
        try context.stdout.print("\x1b[34mBackup exported to: {s}\x1b[0m\n", .{path})
    else
        try context.stdout.print("Backup exported to: {s}\n", .{path});
}

fn writeImportSuccess(context: *runtime.RuntimeContext, path: []const u8) !void {
    if (output.supportsAnsi(context))
        try context.stdout.print("\x1b[34mBackup imported from: {s}\x1b[0m\n", .{path})
    else
        try context.stdout.print("Backup imported from: {s}\n", .{path});
}

fn writeFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    err: anyerror,
) !void {
    const message = try std.fmt.allocPrint(
        context.allocator,
        "Unable to export backup: {t}",
        .{err},
    );
    if (invocation.globals.ui_mode)
        try output.writeErrorFrame(context, message)
    else
        try context.stderr.print("{s}\n", .{message});
}

fn writeImportFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    err: anyerror,
) !void {
    const message = try std.fmt.allocPrint(
        context.allocator,
        "Unable to import backup: {t}",
        .{err},
    );
    if (invocation.globals.ui_mode)
        try output.writeErrorFrame(context, message)
    else
        try context.stderr.print("{s}\n", .{message});
}

fn writeOperationRequired(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !void {
    const message = "No backup operation selected. Use --export or --import.";
    if (invocation.globals.ui_mode)
        try output.writeErrorFrame(context, message)
    else
        try context.stderr.print("{s}\n", .{message});
}

fn writeOperationConflict(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !void {
    const message = "Choose exactly one backup operation: --export or --import.";
    if (invocation.globals.ui_mode)
        try output.writeErrorFrame(context, message)
    else
        try context.stderr.print("{s}\n", .{message});
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        return option.value == null or !std.ascii.eqlIgnoreCase(option.value.?, "false");
    }
    return false;
}

fn optionValue(invocation: *const parser.Invocation, name: []const u8) ?[]const u8 {
    for (invocation.options) |option| {
        if (std.mem.eql(u8, option.name, name)) return option.value;
    }
    return null;
}

const sample_state: State = .{
    .standard = &.{
        .{ .name = "zlib", .explicit = false },
        .{ .name = "linux", .explicit = true },
        .{ .name = "base", .explicit = true },
    },
    .aur = &.{
        .{ .name = "aur-dependency", .explicit = false },
        .{ .name = "yay", .explicit = true },
    },
    .flatpak = &.{
        .{ .id = "org.example.Runtime", .kind = 1 },
        .{ .id = "org.mozilla.firefox", .kind = 0 },
        .{ .id = "org.mozilla.firefox", .kind = 0 },
    },
};

fn sampleRunner(_: ?*anyopaque, _: *runtime.RuntimeContext) !State {
    return sample_state;
}

const ImportState = struct {
    standard: []const []const u8 = &.{},
    aur: []const []const u8 = &.{},
    flatpak: []const []const u8 = &.{},
};

const Section = enum {
    standard,
    aur,
    flatpak,
};

fn parseBackupToml(
    allocator: std.mem.Allocator,
    source: []const u8,
) !ImportState {
    var standard: std.ArrayList([]const u8) = .empty;
    var aur: std.ArrayList([]const u8) = .empty;
    var flatpak: std.ArrayList([]const u8) = .empty;

    var current: ?Section = null;
    var seen_standard = false;
    var seen_aur = false;
    var seen_flatpak = false;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (line.len == 0 or line[0] == '#') continue;

        if (current == null) {
            // Parse exactly: standard = [, aur = [, or flatpak = [
            current = try parseSectionStart(
                line,
                &seen_standard,
                &seen_aur,
                &seen_flatpak,
            );
            continue;
        }

        if (std.mem.eql(u8, line, "]")) {
            current = null;
            continue;
        }

        const value = try parseArrayString(allocator, line);

        switch (current.?) {
            .standard => try standard.append(allocator, value),
            .aur => try aur.append(allocator, value),
            .flatpak => try flatpak.append(allocator, value),
        }
    }

    if (current != null) return error.UnterminatedArray;
    if (!seen_standard or !seen_aur or !seen_flatpak)
        return error.MissingBackupSection;

    return .{
        .standard = try standard.toOwnedSlice(allocator),
        .aur = try aur.toOwnedSlice(allocator),
        .flatpak = try flatpak.toOwnedSlice(allocator),
    };
}

fn parseArrayString(
    allocator: std.mem.Allocator,
    line: []const u8,
) ![]const u8 {
    var token = std.mem.trim(u8, line, " \t\r");

    // A trailing comma is optional for the final array entry.
    if (std.mem.endsWith(u8, token, ","))
        token = std.mem.trim(
            u8,
            token[0 .. token.len - 1],
            " \t\r",
        );

    if (token.len < 2 or
        token[0] != '"' or
        token[token.len - 1] != '"')
    {
        return error.InvalidBackupString;
    }

    const body = token[1 .. token.len - 1];

    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(allocator);

    var index: usize = 0;
    while (index < body.len) : (index += 1) {
        const byte = body[index];

        // Quotes must be escaped. Raw TOML control characters are invalid.
        if (byte == '"' or byte < 0x20 or byte == 0x7f)
            return error.InvalidBackupString;

        if (byte != '\\') {
            try decoded.append(allocator, byte);
            continue;
        }

        if (index + 1 >= body.len)
            return error.InvalidBackupEscape;

        index += 1;

        switch (body[index]) {
            '"' => try decoded.append(allocator, '"'),
            '\\' => try decoded.append(allocator, '\\'),
            'b' => try decoded.append(allocator, 0x08),
            't' => try decoded.append(allocator, '\t'),
            'n' => try decoded.append(allocator, '\n'),
            'f' => try decoded.append(allocator, 0x0c),
            'r' => try decoded.append(allocator, '\r'),

            'u' => {
                if (index + 4 >= body.len)
                    return error.InvalidBackupEscape;

                const digits = body[index + 1 .. index + 5];
                for (digits) |digit| {
                    if (!std.ascii.isHex(digit))
                        return error.InvalidBackupEscape;
                }

                const codepoint = std.fmt.parseInt(
                    u21,
                    digits,
                    16,
                ) catch return error.InvalidBackupEscape;

                var encoded: [4]u8 = undefined;
                const encoded_len = std.unicode.utf8Encode(
                    codepoint,
                    &encoded,
                ) catch return error.InvalidBackupEscape;

                try decoded.appendSlice(
                    allocator,
                    encoded[0..encoded_len],
                );

                index += 4;
            },

            else => return error.InvalidBackupEscape,
        }
    }

    if (!std.unicode.utf8ValidateSlice(decoded.items))
        return error.InvalidBackupString;

    return decoded.toOwnedSlice(allocator);
}

fn parseSectionStart(
    line: []const u8,
    seen_standard: *bool,
    seen_aur: *bool,
    seen_flatpak: *bool,
) !Section {
    const equals_index = std.mem.indexOfScalar(u8, line, '=') orelse
        return error.InvalidBackupSection;

    const key = std.mem.trim(u8, line[0..equals_index], " \t\r");
    const value = std.mem.trim(u8, line[equals_index + 1 ..], " \t\r");

    // This schema only supports multiline arrays beginning with `[`.
    if (!std.mem.eql(u8, value, "["))
        return error.InvalidBackupSection;

    if (std.mem.eql(u8, key, "standard")) {
        if (seen_standard.*) return error.DuplicateBackupSection;
        seen_standard.* = true;
        return .standard;
    }

    if (std.mem.eql(u8, key, "aur")) {
        if (seen_aur.*) return error.DuplicateBackupSection;
        seen_aur.* = true;
        return .aur;
    }

    if (std.mem.eql(u8, key, "flatpak")) {
        if (seen_flatpak.*) return error.DuplicateBackupSection;
        seen_flatpak.* = true;
        return .flatpak;
    }

    return error.UnknownBackupSection;
}

test "parseArrayString decodes TOML strings" {
    const parsed = try parseArrayString(
        std.testing.allocator,
        "  \"quoted\\\"package\\n\\u0041\", ",
    );
    defer std.testing.allocator.free(parsed);

    try std.testing.expectEqualStrings(
        "quoted\"package\nA",
        parsed,
    );
}

test "parseSectionStart recognizes sections and rejects duplicates" {
    var seen_standard = false;
    var seen_aur = false;
    var seen_flatpak = false;

    try std.testing.expectEqual(
        Section.standard,
        try parseSectionStart(
            "standard = [",
            &seen_standard,
            &seen_aur,
            &seen_flatpak,
        ),
    );

    try std.testing.expectError(
        error.DuplicateBackupSection,
        parseSectionStart(
            "standard = [",
            &seen_standard,
            &seen_aur,
            &seen_flatpak,
        ),
    );

    try std.testing.expectError(
        error.UnknownBackupSection,
        parseSectionStart(
            "unknown = [",
            &seen_standard,
            &seen_aur,
            &seen_flatpak,
        ),
    );
}

test "parses exported backup TOML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rendered = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer rendered.deinit();

    try writeToml(allocator, &rendered.writer, sample_state);

    const imported = try parseBackupToml(
        allocator,
        rendered.writer.buffered(),
    );

    try std.testing.expectEqualStrings("base", imported.standard[0]);
    try std.testing.expectEqualStrings("linux", imported.standard[1]);
    try std.testing.expectEqualStrings("yay", imported.aur[0]);
    try std.testing.expectEqualStrings(
        "org.mozilla.firefox",
        imported.flatpak[0],
    );
}

test "backup import delegates every backend to install with inherited globals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = try spec.Manifest.load(allocator);
    const outcome = try parser.parse(allocator, &manifest, &.{
        "backup",
        "--import",
        "--name",
        "snapshot",
        "--no-confirm",
        "--ui-mode",
    });
    try std.testing.expect(outcome == .dispatch);

    var stdout = std.Io.Writer.Discarding.init(&.{});
    var stderr = std.Io.Writer.Discarding.init(&.{});
    var context: runtime.RuntimeContext = .{
        .allocator = allocator,
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const Capture = struct {
        calls: usize = 0,

        fn run(
            data: ?*anyopaque,
            _: *runtime.RuntimeContext,
            backend: install.Backend,
            targets: []const []const u8,
            options: install.CallOptions,
        ) !u8 {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            try std.testing.expect(options.no_confirm);
            try std.testing.expect(options.ui_mode);
            switch (self.calls) {
                0 => {
                    try std.testing.expectEqual(install.Backend.standard, backend);
                    try expectArguments(&.{ "base", "linux" }, targets);
                },
                1 => {
                    try std.testing.expectEqual(install.Backend.aur, backend);
                    try expectArguments(&.{"yay"}, targets);
                },
                2 => {
                    try std.testing.expectEqual(install.Backend.flatpak, backend);
                    try expectArguments(&.{"org.mozilla.firefox"}, targets);
                },
                else => return error.UnexpectedInstallCall,
            }
            self.calls += 1;
            return 0;
        }
    };
    var capture: Capture = .{};
    try importStateWithCaller(
        &context,
        &outcome.dispatch,
        \\standard = [
        \\  "base",
        \\  "linux",
        \\]
        \\aur = [
        \\  "yay",
        \\]
        \\flatpak = [
        \\  "org.mozilla.firefox",
        \\]
    ,
        .{ .data = &capture, .call = Capture.run },
    );
    try std.testing.expectEqual(@as(usize, 3), capture.calls);
}

test "backup is a standalone -B command with export and local modifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = try spec.Manifest.load(allocator);

    const base = try @import("../cli/shortcodes.zig").translate(allocator, &manifest, &.{"-B"});
    try std.testing.expect(base == .translated);
    try expectArguments(&.{"backup"}, base.translated);

    const export_state = try @import("../cli/shortcodes.zig").translate(allocator, &manifest, &.{"-Be"});
    try std.testing.expect(export_state == .translated);
    try expectArguments(&.{ "backup", "-e" }, export_state.translated);

    const named = try @import("../cli/shortcodes.zig").translate(
        allocator,
        &manifest,
        &.{ "-Bea", "snapshot" },
    );
    try std.testing.expect(named == .translated);
    try expectArguments(&.{ "backup", "-e", "-a", "snapshot" }, named.translated);

    const help = try @import("../cli/shortcodes.zig").translate(allocator, &manifest, &.{"-Bh"});
    try std.testing.expect(help == .translated);
    try expectArguments(&.{ "backup", "--help" }, help.translated);

    const long_form = try parser.parse(allocator, &manifest, &.{ "backup", "--export" });
    try std.testing.expect(long_form == .dispatch);
    try std.testing.expectEqualStrings(command_path, long_form.dispatch.command.path);

    const removed_export_command = try parser.parse(allocator, &manifest, &.{"export"});
    try std.testing.expect(removed_export_command == .dispatch);
    try std.testing.expectEqualStrings("shelly", removed_export_command.dispatch.command.path);

    const removed_export_shortcode = try @import("../cli/shortcodes.zig").translate(
        allocator,
        &manifest,
        &.{"-E"},
    );
    try std.testing.expect(removed_export_shortcode == .unchanged);
}

test "backup requires an operation before collecting package state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{"backup"});
    try std.testing.expect(outcome == .dispatch);

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
    var called = false;
    const runner: Runner = .{ .data = &called, .call = struct {
        fn run(data: ?*anyopaque, _: *runtime.RuntimeContext) !State {
            const observed: *bool = @ptrCast(@alignCast(data.?));
            observed.* = true;
            return sample_state;
        }
    }.run };
    try std.testing.expectEqual(@as(u8, 1), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expect(!called);
    try std.testing.expectEqualStrings(
        "No backup operation selected. Use --export or --import.\n",
        stderr.writer.buffered(),
    );
}

test "backup TOML uses top-level type arrays without versions or dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rendered = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer rendered.deinit();

    try writeToml(arena.allocator(), &rendered.writer, sample_state);
    try std.testing.expectEqualStrings(
        \\standard = [
        \\  "base",
        \\  "linux",
        \\]
        \\
        \\aur = [
        \\  "yay",
        \\]
        \\
        \\flatpak = [
        \\  "org.mozilla.firefox",
        \\]
        \\
    , rendered.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, rendered.writer.buffered(), "zlib") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.writer.buffered(), "aur-dependency") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.writer.buffered(), "Runtime") == null);
}

test "backup export writes named TOML files to the requested directory" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "backup",
        "--export",
        "--name",
        "machine",
        "--directory",
        absolute_buffer[0..absolute_length],
    });
    try std.testing.expect(outcome == .dispatch);

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
    try std.testing.expectEqual(
        @as(u8, 0),
        try executeWithRunner(&context, &outcome.dispatch, .{ .call = sampleRunner }),
    );

    const saved = try temporary.dir.readFileAlloc(
        std.testing.io,
        "machine.toml",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(saved);
    try std.testing.expect(std.mem.startsWith(u8, saved, "standard = [\n"));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), saved) != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "machine.toml") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
}

test "TOML package names are escaped" {
    var rendered = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer rendered.deinit();
    try writePackageArray(&rendered.writer, "standard", &.{.{
        .name = "quoted\"package",
        .explicit = true,
    }});
    try std.testing.expectEqualStrings(
        "standard = [\n  \"quoted\\\"package\",\n]\n",
        rendered.writer.buffered(),
    );
}

fn expectArguments(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |wanted, observed|
        try std.testing.expectEqualStrings(wanted, observed);
}
