const std = @import("std");
const Zigalpm = @import("Zigalpm");
const config_manager = @import("manager.zig");
const config_model = @import("model.zig");
const runtime = @import("../runtime/context.zig");

pub const configuration_key = "DownloadAddressFamilyPolicy";

const AddressFamilyPolicy = Zigalpm.shared.downloader.AddressFamilyPolicy;

pub fn fromConfig(config: *const config_model.Config) AddressFamilyPolicy {
    const value = config.values.get(configuration_key) orelse return .prefer_ipv4;
    const text = switch (value) {
        .string => |text| text,
        else => return .prefer_ipv4,
    };
    return parse(text);
}

pub fn load(context: *runtime.RuntimeContext) AddressFamilyPolicy {
    const config = config_manager.Manager.init(context).read() catch return .prefer_ipv4;
    return fromConfig(&config);
}

/// Loads the native configuration once during CLI startup. Every ALPM manager
/// created afterwards, including managers nested inside AUR operations,
/// inherits this process-wide default.
pub fn applyProcessDefault(context: *runtime.RuntimeContext) void {
    Zigalpm.AlpmManager.setDefaultDownloadAddressFamilyPolicy(load(context));
}

fn parse(text: []const u8) AddressFamilyPolicy {
    if (std.ascii.eqlIgnoreCase(text, "PreferIPv6")) return .happy_eyeballs;
    if (std.ascii.eqlIgnoreCase(text, "IPv4Only")) return .ipv4_only;
    if (std.ascii.eqlIgnoreCase(text, "IPv6Only")) return .ipv6_only;
    return .prefer_ipv4;
}

test "configuration values map to downloader policies" {
    try std.testing.expectEqual(AddressFamilyPolicy.prefer_ipv4, parse("PreferIPv4"));
    try std.testing.expectEqual(AddressFamilyPolicy.happy_eyeballs, parse("preferipv6"));
    try std.testing.expectEqual(AddressFamilyPolicy.ipv4_only, parse("IPV4ONLY"));
    try std.testing.expectEqual(AddressFamilyPolicy.ipv6_only, parse("IPv6Only"));
}

test "missing and invalid values safely prefer IPv4" {
    try std.testing.expectEqual(AddressFamilyPolicy.prefer_ipv4, parse(""));
    try std.testing.expectEqual(AddressFamilyPolicy.prefer_ipv4, parse("Automatic"));

    const missing: config_model.Config = .{ .values = .empty };
    try std.testing.expectEqual(AddressFamilyPolicy.prefer_ipv4, fromConfig(&missing));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var config = try config_model.Config.defaults(arena.allocator());
    try config.values.put(arena.allocator(), configuration_key, .{ .string = "invalid" });
    try std.testing.expectEqual(AddressFamilyPolicy.prefer_ipv4, fromConfig(&config));
}

test "configured values are read from the shared model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var config = try config_model.Config.defaults(arena.allocator());

    try std.testing.expectEqual(AddressFamilyPolicy.prefer_ipv4, fromConfig(&config));
    try std.testing.expect(try config.set(arena.allocator(), configuration_key, "PreferIPv6"));
    try std.testing.expectEqual(AddressFamilyPolicy.happy_eyeballs, fromConfig(&config));
    try std.testing.expect(try config.set(arena.allocator(), configuration_key, "IPv4Only"));
    try std.testing.expectEqual(AddressFamilyPolicy.ipv4_only, fromConfig(&config));
    try std.testing.expect(try config.set(arena.allocator(), configuration_key, "IPv6Only"));
    try std.testing.expectEqual(AddressFamilyPolicy.ipv6_only, fromConfig(&config));
}

test "CLI startup applies the configured process default" {
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

    var config = try config_model.Config.defaults(arena.allocator());
    try std.testing.expect(try config.set(arena.allocator(), configuration_key, "PreferIPv6"));
    try config_manager.Manager.init(&context).save(&config);

    const previous = Zigalpm.AlpmManager.defaultDownloadAddressFamilyPolicy();
    defer Zigalpm.AlpmManager.setDefaultDownloadAddressFamilyPolicy(previous);
    applyProcessDefault(&context);
    try std.testing.expectEqual(
        AddressFamilyPolicy.happy_eyeballs,
        Zigalpm.AlpmManager.defaultDownloadAddressFamilyPolicy(),
    );
}
