//! AUR base URL resolution for the CLI.
//!
//! Precedence:
//!   1. `--aur-url` command-line option
//!   2. `AurUrl` from the invoking user's XDG Shelly configuration
//!   3. `https://aur.archlinux.org` (default)

const std = @import("std");
const config_manager = @import("manager.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");

pub const config_key = "AurUrl";
pub const option_name = "--aur-url";
pub const default_base = "https://aur.archlinux.org";

/// Returns the raw `--aur-url` override carried by an invocation.
pub fn overrideValue(invocation: *const parser.Invocation) ?[]const u8 {
    for (invocation.options) |option| {
        if (std.mem.eql(u8, option.name, option_name)) return option.value;
    }
    return null;
}

/// Resolves the effective AUR base URL from CLI override, config, or default.
pub fn resolve(context: *runtime.RuntimeContext, override: ?[]const u8) ![]const u8 {
    if (override) |value| {
        if (!isValidBase(value)) return error.InvalidAurUrl;
        return std.mem.trim(u8, value, " \t\r\n");
    }
    const manager = config_manager.Manager.init(context);
    const configured = manager.get(config_key) catch |err| switch (err) {
        error.HomeNotConfigured, error.FileNotFound => return default_base,
        else => return err,
    } orelse return default_base;
    if (!isValidBase(configured)) return error.InvalidAurUrl;
    return std.mem.trim(u8, configured, " \t\r\n");
}

/// Returns child arguments with `--aur-url` appended if not already present.
pub fn argumentsWithEffectiveBase(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) ![]const []const u8 {
    const existing_override = overrideValue(invocation);
    const effective_base = try resolve(context, existing_override);
    const extra_count: usize = if (existing_override == null) 2 else 0;
    const arguments = try context.allocator.alloc([]const u8, invocation.arguments.len + extra_count);
    if (extra_count == 0) {
        @memcpy(arguments, invocation.arguments);
        return arguments;
    }

    const insertion_index = for (invocation.arguments, 0..) |argument, index| {
        if (std.mem.eql(u8, argument, "--")) break index;
    } else invocation.arguments.len;
    @memcpy(arguments[0..insertion_index], invocation.arguments[0..insertion_index]);
    arguments[insertion_index] = option_name;
    arguments[insertion_index + 1] = effective_base;
    @memcpy(arguments[insertion_index + 2 ..], invocation.arguments[insertion_index..]);
    return arguments;
}

/// Resolves the effective AUR base URL for an invocation.
pub fn resolveFor(context: *runtime.RuntimeContext, invocation: *const parser.Invocation) ![]const u8 {
    return resolve(context, overrideValue(invocation));
}

/// Validates that `value` is an HTTP(S) URL without query, fragment, or userinfo.
pub fn isValidBase(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, '\\') != null) return false;
    for (trimmed) |character| if (std.ascii.isWhitespace(character) or std.ascii.isControl(character)) return false;

    const uri = std.Uri.parse(trimmed) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return false;
    if (uri.host == null or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null) return false;
    return componentText(uri.host.?).len != 0;
}

fn componentText(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |text| text,
        .percent_encoded => |text| text,
    };
}

test "AUR URL validation accepts plain HTTP(S) bases only" {
    try std.testing.expect(isValidBase("https://aur.archlinux.org"));
    try std.testing.expect(isValidBase("http://localhost:8080"));
    try std.testing.expect(isValidBase("https://atoll.seafoam-labs.org"));
    try std.testing.expect(isValidBase("https://host/atoll"));
    try std.testing.expect(isValidBase("  https://host/atoll/  "));

    try std.testing.expect(!isValidBase(""));
    try std.testing.expect(!isValidBase("   "));
    try std.testing.expect(!isValidBase("ftp://host"));
    try std.testing.expect(!isValidBase("ssh://aur@aur.archlinux.org"));
    try std.testing.expect(!isValidBase("https://"));
    try std.testing.expect(!isValidBase("/tmp/local-remotes"));
    try std.testing.expect(!isValidBase("https://user:pass@host"));
    try std.testing.expect(!isValidBase("https://host/rpc?v=5"));
    try std.testing.expect(!isValidBase("https://host/atoll#fragment"));
    try std.testing.expect(!isValidBase("https://:"));
    try std.testing.expect(!isValidBase("https://host:invalid"));
    try std.testing.expect(!isValidBase("https://host/path with spaces"));
    try std.testing.expect(!isValidBase("https://host/path\\segment"));
    try std.testing.expect(!isValidBase("https://[::1"));
}

test "AUR URL resolution applies override, configuration, and default precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);

    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("HOME", "/home/tester");
    try environment.put("XDG_CONFIG_HOME", absolute_buffer[0..absolute_length]);
    var stdout = std.Io.Writer.Discarding.init(&.{});
    var stderr = std.Io.Writer.Discarding.init(&.{});
    var context: runtime.RuntimeContext = .{
        .allocator = allocator,
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .environment = &environment,
    };

    // Default when no configuration exists.
    try std.testing.expectEqualStrings(default_base, try resolve(&context, null));

    // Configuration is used when no override is present.
    const manager = config_manager.Manager.init(&context);
    try std.testing.expect(try manager.update(config_key, "https://atoll.seafoam-labs.org"));
    try std.testing.expectEqualStrings(
        "https://atoll.seafoam-labs.org",
        try resolve(&context, null),
    );

    // The command-line override wins over the configuration.
    try std.testing.expectEqualStrings(
        "https://host/atoll",
        try resolve(&context, "https://host/atoll"),
    );

    // Relaunch arguments materialize the effective configured value so a child
    // does not depend on inheriting the same XDG environment.
    const manifest = try @import("../cli/spec.zig").Manifest.load(allocator);
    const parsed = try parser.parse(allocator, &manifest, &.{ "upgrade", "all" });
    const child_arguments = try argumentsWithEffectiveBase(&context, &parsed.dispatch);
    defer context.allocator.free(child_arguments);
    try std.testing.expectEqualStrings(option_name, child_arguments[child_arguments.len - 2]);
    try std.testing.expectEqualStrings("https://atoll.seafoam-labs.org", child_arguments[child_arguments.len - 1]);

    // Invalid values never fall back silently.
    try std.testing.expectError(error.InvalidAurUrl, resolve(&context, "not-a-url"));
    try std.testing.expectError(error.InvalidAurUrl, resolve(&context, "https://user@host"));
}

test "effective AUR URL arguments are inserted before the option terminator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const spec = @import("../cli/spec.zig");
    const manifest = try spec.Manifest.load(allocator);
    const parsed = try parser.parse(allocator, &manifest, &.{ "install", "aur", "--", "demo" });

    var stdout = std.Io.Writer.Discarding.init(&.{});
    var stderr = std.Io.Writer.Discarding.init(&.{});
    var context: runtime.RuntimeContext = .{
        .allocator = allocator,
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const child_arguments = try argumentsWithEffectiveBase(&context, &parsed.dispatch);
    const reparsed = try parser.parse(allocator, &manifest, child_arguments);
    try std.testing.expectEqual(@as(usize, 1), reparsed.dispatch.positionals.len);
    try std.testing.expectEqualStrings("demo", reparsed.dispatch.positionals[0]);
    try std.testing.expectEqualStrings(default_base, overrideValue(&reparsed.dispatch).?);
}

test "AUR URL overrides are read from parsed invocations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const spec = @import("../cli/spec.zig");
    const manifest = try spec.Manifest.load(arena.allocator());

    const before_command = try parser.parse(arena.allocator(), &manifest, &.{
        "--aur-url", "https://atoll.seafoam-labs.org", "install", "aur", "demo",
    });
    try std.testing.expectEqualStrings(
        "https://atoll.seafoam-labs.org",
        overrideValue(&before_command.dispatch).?,
    );

    const after_command = try parser.parse(arena.allocator(), &manifest, &.{
        "search", "aur", "--aur-url=https://host/atoll", "demo",
    });
    try std.testing.expectEqualStrings(
        "https://host/atoll",
        overrideValue(&after_command.dispatch).?,
    );

    const without_override = try parser.parse(arena.allocator(), &manifest, &.{
        "search", "aur", "demo",
    });
    try std.testing.expect(overrideValue(&without_override.dispatch) == null);
}
