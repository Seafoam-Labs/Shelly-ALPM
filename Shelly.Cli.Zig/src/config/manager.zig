const std = @import("std");
const model = @import("model.zig");
const runtime = @import("../runtime/context.zig");
const xdg = @import("../runtime/xdg.zig");
const native_defaults = @import("defaults.zig");

pub const Manager = struct {
    context: *runtime.RuntimeContext,

    pub fn init(context: *runtime.RuntimeContext) Manager {
        return .{ .context = context };
    }

    pub fn path(self: Manager) ![]const u8 {
        return xdg.configPath(self.context);
    }

    pub fn read(self: Manager) !model.Config {
        var config = try model.Config.defaults(self.context.allocator);
        const config_path = try self.path();
        const contents = std.Io.Dir.cwd().readFileAlloc(
            self.context.io,
            config_path,
            self.context.allocator,
            .limited(4 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => {
                try self.save(&config);
                return config;
            },
            else => return err,
        };
        const parsed = std.json.parseFromSliceLeaky(
            std.json.Value,
            self.context.allocator,
            contents,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                self.recoverFromUnreadableConfig(&config, config_path, err);
                return config;
            },
        };
        if (parsed != .object) {
            self.recoverFromUnreadableConfig(&config, config_path, error.InvalidConfig);
            return config;
        }
        try config.overlay(parsed.object);
        return config;
    }

    /// An unreadable file is kept aside and replaced with the defaults, so one
    /// truncated or hand-corrupted write cannot fail every command that reads
    /// configuration. A failed repair still leaves the defaults usable for the
    /// current run rather than aborting the command.
    fn recoverFromUnreadableConfig(
        self: Manager,
        config: *const model.Config,
        config_path: []const u8,
        json_error: anyerror,
    ) void {
        if (unreadable_config_reported.load(.seq_cst)) return;
        unreadable_config_reported.store(true, .seq_cst);

        const allocator = self.context.allocator;
        var kept: ?[]u8 = std.fmt.allocPrint(allocator, "{s}.corrupt", .{config_path}) catch null;
        if (kept) |copy| {
            std.Io.Dir.renameAbsolute(config_path, copy, self.context.io) catch |err| {
                warn(self.context, "Could not keep a copy of the unreadable configuration file. {0s}\n\nTechnical details: {1s}", .{ @import("diagnostics").cause(err), @errorName(err) });
                allocator.free(copy);
                kept = null;
            };
        }
        defer if (kept) |copy| allocator.free(copy);

        var repaired = true;
        self.save(config) catch |err| {
            repaired = false;
            warn(self.context, "Could not write the default configuration file. {0s}\n\nTechnical details: {1s}", .{ @import("diagnostics").cause(err), @errorName(err) });
        };

        const outcome: []const u8 = if (repaired)
            "it was replaced with the built-in defaults"
        else
            "the built-in defaults apply to this run";
        if (kept) |copy| {
            warn(self.context, "The configuration file was not readable as Shelly settings, so {0s}. A copy was kept as {1f}.\n\nTechnical details: {2s}", .{ outcome, @import("diagnostics").safe(copy), @errorName(json_error) });
        } else {
            warn(self.context, "The configuration file was not readable as Shelly settings, so {0s}.\n\nTechnical details: {1s}", .{ outcome, @errorName(json_error) });
        }
    }

    pub fn save(self: Manager, config: *const model.Config) !void {
        const config_path = try self.path();

        var output = std.Io.Writer.Allocating.init(self.context.allocator);
        defer output.deinit();
        try std.json.Stringify.value(
            std.json.Value{ .object = config.values },
            .{ .whitespace = .indent_2, .escape_unicode = true },
            &output.writer,
        );

        // Staged in a sibling file and renamed into place, so an interrupted
        // write can never leave an empty or half written configuration behind.
        // The sync is what keeps a power loss from committing an empty rename
        // over the previous contents.
        var staged = try std.Io.Dir.cwd().createFileAtomic(
            self.context.io,
            config_path,
            .{ .make_path = true, .replace = true },
        );
        defer staged.deinit(self.context.io);
        try staged.file.writeStreamingAll(self.context.io, output.writer.buffered());
        try staged.file.sync(self.context.io);
        try staged.replace(self.context.io);
    }

    pub fn reset(self: Manager) !void {
        const config = try model.Config.defaults(self.context.allocator);
        try self.save(&config);
    }

    pub fn update(self: Manager, key: []const u8, value: []const u8) !bool {
        var config = try self.read();
        if (!try config.set(self.context.allocator, key, value)) return false;
        try self.save(&config);
        return true;
    }

    pub fn get(self: Manager, key: []const u8) !?[]const u8 {
        const config = try self.read();
        return config.getDisplay(self.context.allocator, key);
    }
};

/// `output.writeWarning` is unreachable here: `output/format.zig` imports this file.
fn warn(context: *runtime.RuntimeContext, comptime format: []const u8, args: anytype) void {
    context.stderr.print("warning: " ++ format ++ "\n", args) catch {};
}

/// Subsystems each read the configuration on their own, so an unreadable file
/// that cannot be repaired must be reported once per run, not once per read.
var unreadable_config_reported = std.atomic.Value(bool).init(false);

test "creates, updates, and reloads the XDG config file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("HOME", "/home/tester");
    try environment.put("XDG_CONFIG_HOME", absolute_buffer[0..absolute_length]);
    var stdout = std.Io.Writer.Discarding.init(&.{});
    var stderr = std.Io.Writer.Discarding.init(&.{});
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .environment = &environment,
    };
    const manager = Manager.init(&context);
    const config = try manager.read();
    try std.testing.expectEqualStrings("100", (try config.getDisplay(arena.allocator(), "ParallelDownloadCount")).?);
    try std.testing.expectEqualStrings(
        "PreferIPv4",
        (try config.getDisplay(arena.allocator(), "DownloadAddressFamilyPolicy")).?,
    );
    try std.testing.expectEqualStrings(
        "False",
        (try config.getDisplay(arena.allocator(), "AutoConfirmCacheClean")).?,
    );

    const saved = try temporary.dir.readFileAlloc(
        std.testing.io,
        "shelly/config.json",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings(
        std.mem.trimEnd(u8, native_defaults.json, "\n"),
        saved,
    );

    try std.testing.expect(try manager.update("ParallelDownloadCount", "22"));
    try std.testing.expectEqualStrings("22", (try manager.get("parallelDownloadCount")).?);
    try std.testing.expect(!try manager.update("ParallelDownloadCount", "many"));
    try std.testing.expect(try manager.update("DownloadAddressFamilyPolicy", "ipv6only"));
    try std.testing.expectEqualStrings(
        "IPv6Only",
        (try manager.get("downloadaddressfamilypolicy")).?,
    );
    try std.testing.expect(!try manager.update("DownloadAddressFamilyPolicy", "automatic"));
    try std.testing.expect(try manager.update("AutoConfirmCacheClean", "true"));
    try std.testing.expectEqualStrings(
        "True",
        (try manager.get("AutoConfirmCacheClean")).?,
    );
    try std.testing.expect(!try manager.update("AutoConfirmCacheClean", "yes"));
    try std.testing.expectEqualStrings("False", (try manager.get("DisableCacheClean")).?);
    try std.testing.expect(try manager.update("disablecacheclean", "TrUe"));
    try std.testing.expectEqualStrings("True", (try manager.get("DisableCacheClean")).?);
    try std.testing.expect(!try manager.update("DisableCacheClean", "yes"));
    try std.testing.expectEqualStrings("True", (try manager.get("DisableCacheClean")).?);
    try std.testing.expectEqualStrings("True", (try manager.get("CollapsePkgbuildDiff")).?);
    try std.testing.expect(try manager.update("collapsepkgbuilddiff", "FaLsE"));
    try std.testing.expectEqualStrings("False", (try manager.get("CollapsePkgbuildDiff")).?);
    try std.testing.expect(!try manager.update("CollapsePkgbuildDiff", "yes"));
    try std.testing.expectEqualStrings("False", (try manager.get("CollapsePkgbuildDiff")).?);
    try std.testing.expectEqualStrings("False", (try manager.get("DisableAppImageUpdateCheck")).?);
    try std.testing.expect(try manager.update("disableappimageupdatecheck", "TrUe"));
    try std.testing.expectEqualStrings("True", (try manager.get("DisableAppImageUpdateCheck")).?);
    try std.testing.expectEqualStrings("False", (try manager.get("DisableFlatpakUpdateCheck")).?);
    try std.testing.expect(try manager.update("disableflatpakupdatecheck", "TrUe"));
    try std.testing.expectEqualStrings("True", (try manager.get("DisableFlatpakUpdateCheck")).?);
    try std.testing.expect(!try manager.update("DisableFlatpakUpdateCheck", "yes"));
    try std.testing.expectEqualStrings("True", (try manager.get("DisableFlatpakUpdateCheck")).?);
    try std.testing.expect(!try manager.update("DisableAppImageUpdateCheck", "yes"));
    try std.testing.expectEqualStrings("True", (try manager.get("DisableAppImageUpdateCheck")).?);
    try manager.reset();
    try std.testing.expectEqualStrings("False", (try manager.get("DisableFlatpakUpdateCheck")).?);
    try std.testing.expectEqualStrings("False", (try manager.get("DisableAppImageUpdateCheck")).?);
    try std.testing.expectEqualStrings("True", (try manager.get("CollapsePkgbuildDiff")).?);
    try std.testing.expectEqualStrings("False", (try manager.get("DisableCacheClean")).?);
}

const ConfigFixture = struct {
    arena: std.heap.ArenaAllocator,
    stdout: std.Io.Writer.Allocating,
    stderr: std.Io.Writer.Allocating,
    config_home: [std.Io.Dir.max_path_bytes]u8 = undefined,
    environment: std.process.Environ.Map,
    context: runtime.RuntimeContext,

    fn read(self: *ConfigFixture) !model.Config {
        return Manager.init(&self.context).read();
    }

    fn allocator(self: *ConfigFixture) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn warnings(self: *const ConfigFixture) []const u8 {
        return self.stderr.writer.buffered();
    }
};

/// Fills a caller-owned fixture instead of returning one because the context
/// refers to the fixture's own writers.
fn setUpConfigFixture(fixture: *ConfigFixture, temporary: *std.testing.TmpDir) !void {
    // Every fixture stands for a fresh process, including the once-per-run notice.
    unreadable_config_reported.store(false, .seq_cst);
    fixture.* = .{
        .arena = .init(std.testing.allocator),
        .stdout = .init(std.testing.allocator),
        .stderr = .init(std.testing.allocator),
        .environment = undefined,
        .context = undefined,
    };
    const length = try temporary.dir.realPath(std.testing.io, &fixture.config_home);
    fixture.environment = std.process.Environ.Map.init(fixture.arena.allocator());
    try fixture.environment.put("HOME", "/home/tester");
    try fixture.environment.put("XDG_CONFIG_HOME", fixture.config_home[0..length]);
    fixture.context = .{
        .allocator = fixture.arena.allocator(),
        .io = std.testing.io,
        .stdout = &fixture.stdout.writer,
        .stderr = &fixture.stderr.writer,
        .environment = &fixture.environment,
    };
}

fn tearDownConfigFixture(fixture: *ConfigFixture) void {
    fixture.stderr.deinit();
    fixture.stdout.deinit();
    fixture.arena.deinit();
}

fn seedConfig(temporary: *std.testing.TmpDir, contents: []const u8) !void {
    var directory = try temporary.dir.createDirPathOpen(std.testing.io, "shelly", .{});
    defer directory.close(std.testing.io);
    const file = try directory.createFile(std.testing.io, "config.json", .{ .truncate = true });
    defer file.close(std.testing.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &buffer);
    try writer.interface.writeAll(contents);
    try writer.flush();
}

fn readShellyFile(temporary: *std.testing.TmpDir, name: []const u8) ![]u8 {
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "shelly/{s}", .{name});
    return temporary.dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(4 * 1024 * 1024));
}

test "read falls back to the defaults for an empty configuration file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try seedConfig(&temporary, "");

    var fixture: ConfigFixture = undefined;
    try setUpConfigFixture(&fixture, &temporary);
    defer tearDownConfigFixture(&fixture);

    const config = try fixture.read();
    try std.testing.expectEqualStrings(
        "100",
        (try config.getDisplay(fixture.allocator(), "ParallelDownloadCount")).?,
    );

    const kept = try readShellyFile(&temporary, "config.json.corrupt");
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqual(@as(usize, 0), kept.len);

    const rewritten = try readShellyFile(&temporary, "config.json");
    defer std.testing.allocator.free(rewritten);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"ParallelDownloadCount\": 100") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.warnings(), "UnexpectedEndOfInput") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.warnings(), "config.json.corrupt") != null);
}

test "read falls back to the defaults for unreadable JSON" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try seedConfig(&temporary, "{oops");

    var fixture: ConfigFixture = undefined;
    try setUpConfigFixture(&fixture, &temporary);
    defer tearDownConfigFixture(&fixture);

    const config = try fixture.read();
    try std.testing.expectEqualStrings(
        "singlepane",
        (try config.getDisplay(fixture.allocator(), "OutputMode")).?,
    );

    const kept = try readShellyFile(&temporary, "config.json.corrupt");
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("{oops", kept);
    try std.testing.expect(std.mem.indexOf(u8, fixture.warnings(), "SyntaxError") != null);
}

test "read falls back to the defaults for a configuration that is not an object" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try seedConfig(&temporary, "[1, 2]");

    var fixture: ConfigFixture = undefined;
    try setUpConfigFixture(&fixture, &temporary);
    defer tearDownConfigFixture(&fixture);

    const config = try fixture.read();
    try std.testing.expectEqualStrings(
        "False",
        (try config.getDisplay(fixture.allocator(), "DisableCacheClean")).?,
    );
    try std.testing.expect(std.mem.indexOf(u8, fixture.warnings(), "InvalidConfig") != null);
}

test "read leaves a readable configuration file alone" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try seedConfig(&temporary, "{\n  \"ParallelDownloadCount\": 7\n}");

    var fixture: ConfigFixture = undefined;
    try setUpConfigFixture(&fixture, &temporary);
    defer tearDownConfigFixture(&fixture);

    const config = try fixture.read();
    try std.testing.expectEqualStrings(
        "7",
        (try config.getDisplay(fixture.allocator(), "ParallelDownloadCount")).?,
    );

    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.access(std.testing.io, "shelly/config.json.corrupt", .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), fixture.warnings().len);
}

test "read still returns the defaults when the unreadable file cannot be kept" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try seedConfig(&temporary, "{oops");
    try temporary.dir.createDirPath(std.testing.io, "shelly/config.json.corrupt");

    var fixture: ConfigFixture = undefined;
    try setUpConfigFixture(&fixture, &temporary);
    defer tearDownConfigFixture(&fixture);

    const config = try fixture.read();
    try std.testing.expectEqualStrings(
        "100",
        (try config.getDisplay(fixture.allocator(), "ParallelDownloadCount")).?,
    );
    try std.testing.expect(std.mem.indexOf(u8, fixture.warnings(), "Could not keep a copy") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.warnings(), "A copy was kept as") == null);

    const rewritten = try readShellyFile(&temporary, "config.json");
    defer std.testing.allocator.free(rewritten);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"ParallelDownloadCount\": 100") != null);
}

test "read still returns the defaults when the repair cannot be written" {
    if (std.c.geteuid() == 0) return error.SkipZigTest; // root ignores the directory mode

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try seedConfig(&temporary, "{oops");

    var directory = try temporary.dir.openDir(std.testing.io, "shelly", .{ .iterate = true });
    defer directory.setPermissions(std.testing.io, .fromMode(0o700)) catch {};
    try directory.setPermissions(std.testing.io, .fromMode(0o500));

    var fixture: ConfigFixture = undefined;
    try setUpConfigFixture(&fixture, &temporary);
    defer tearDownConfigFixture(&fixture);

    const config = try fixture.read();
    try std.testing.expectEqualStrings(
        "100",
        (try config.getDisplay(fixture.allocator(), "ParallelDownloadCount")).?,
    );
    try std.testing.expect(std.mem.indexOf(u8, fixture.warnings(), "Could not keep a copy") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.warnings(), "Could not write the default configuration file") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.warnings(), "the built-in defaults apply to this run") != null);

    // The next reader in the same run must not repeat the notice.
    const noticed = fixture.warnings().len;
    _ = try fixture.read();
    try std.testing.expectEqual(noticed, fixture.warnings().len);
}

test "save leaves no staging files beside the configuration file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var fixture: ConfigFixture = undefined;
    try setUpConfigFixture(&fixture, &temporary);
    defer tearDownConfigFixture(&fixture);

    try std.testing.expect(try Manager.init(&fixture.context).update("ParallelDownloadCount", "22"));

    var directory = try temporary.dir.openDir(std.testing.io, "shelly", .{ .iterate = true });
    defer directory.close(std.testing.io);
    var others: usize = 0;
    var iterator = directory.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        if (!std.mem.eql(u8, entry.name, "config.json")) others += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), others);
    try std.testing.expectEqual(@as(usize, 0), fixture.warnings().len);
}
