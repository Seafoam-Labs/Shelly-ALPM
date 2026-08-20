const std = @import("std");
const toml = @import("toml");
const process_runner = @import("builder.zig");

pub const system_path = "/etc/shellybuild.conf";
pub const file_name = "shellybuild.conf";

pub const BuildConfiguration = struct {
    carch: []const u8,
    chost: []const u8,
    cppflags: []const []const u8,
    cflags: []const []const u8,
    cxxflags: []const []const u8,
    ldflags: []const []const u8,
    ltoflags: []const []const u8,
    makeflags: []const []const u8,
    check: bool,
    ccache: bool,
    distcc: bool,
    distcc_hosts: []const []const u8,
};

pub const PackageConfiguration = struct {
    packager: []const u8,
    extension: []const u8,
    options: []const []const u8,
    strip_binaries: []const []const u8,
    strip_shared: []const []const u8,
    strip_static: []const []const u8,
    sign: bool,
    sign_key: ?[]const u8,
};

pub const DestinationConfiguration = struct {
    build: ?[]const u8,
    packages: ?[]const u8,
    sources: ?[]const u8,
    logs: ?[]const u8,
};

/// Landlock confinement for the untrusted PKGBUILD lifecycle steps. Disabled
/// by default; when enabled the builder hard-fails on kernels without
/// Landlock support rather than running the steps unprotected.
pub const SandboxConfiguration = struct {
    enabled: bool,
    extra_read: []const []const u8,
    extra_write: []const []const u8,
};

const BuildLayer = struct {
    carch: ?[]const u8 = null,
    chost: ?[]const u8 = null,
    cppflags: ?[]const []const u8 = null,
    cflags: ?[]const []const u8 = null,
    cxxflags: ?[]const []const u8 = null,
    ldflags: ?[]const []const u8 = null,
    ltoflags: ?[]const []const u8 = null,
    makeflags: ?[]const []const u8 = null,
    check: ?bool = null,
    ccache: ?bool = null,
    distcc: ?bool = null,
    distcc_hosts: ?[]const []const u8 = null,
};

const PackageLayer = struct {
    packager: ?[]const u8 = null,
    extension: ?[]const u8 = null,
    options: ?[]const []const u8 = null,
    strip_binaries: ?[]const []const u8 = null,
    strip_shared: ?[]const []const u8 = null,
    strip_static: ?[]const []const u8 = null,
    sign: ?bool = null,
    sign_key: ?[]const u8 = null,
};

const DestinationLayer = struct {
    build: ?[]const u8 = null,
    packages: ?[]const u8 = null,
    sources: ?[]const u8 = null,
    logs: ?[]const u8 = null,
};

const SandboxLayer = struct {
    enabled: ?bool = null,
    extra_read: ?[]const []const u8 = null,
    extra_write: ?[]const []const u8 = null,
};

const ConfigurationLayer = struct {
    build: ?BuildLayer = null,
    package: ?PackageLayer = null,
    destinations: ?DestinationLayer = null,
    sandbox: ?SandboxLayer = null,
};

pub const ShellyBuildConfiguration = struct {
    const Self = @This();

    backing_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    build: BuildConfiguration,
    package: PackageConfiguration,
    destinations: DestinationConfiguration,
    sandbox: SandboxConfiguration,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        environ: std.process.Environ,
    ) !*Self {
        const user_path = try resolveUserConfigurationPath(allocator, io, environ);
        defer allocator.free(user_path);
        return initFromPaths(io, allocator, system_path, user_path);
    }

    pub fn initFromPaths(
        io: std.Io,
        allocator: std.mem.Allocator,
        configured_system_path: []const u8,
        configured_user_path: []const u8,
    ) !*Self {
        const system_content = try readOptionalFile(io, allocator, configured_system_path);
        defer if (system_content) |content| allocator.free(content);
        const user_content = try readOptionalFile(io, allocator, configured_user_path);
        defer if (user_content) |content| allocator.free(content);
        return initFromBuffers(allocator, system_content, user_content);
    }

    pub fn initFromBuffers(
        allocator: std.mem.Allocator,
        system_content: ?[]const u8,
        user_content: ?[]const u8,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .backing_allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .build = .{
                .carch = "x86_64",
                .chost = "x86_64-pc-linux-gnu",
                .cppflags = &.{},
                .cflags = &.{ "-O2", "-pipe" },
                .cxxflags = &.{ "-O2", "-pipe" },
                .ldflags = &.{ "-Wl,-z,relro", "-Wl,-z,now" },
                .ltoflags = &.{"-flto=auto"},
                .makeflags = &.{"-j2"},
                .check = true,
                .ccache = false,
                .distcc = false,
                .distcc_hosts = &.{},
            },
            .package = .{
                .packager = "Unknown Packager",
                .extension = ".pkg.tar.zst",
                .options = &.{ "strip", "docs", "emptydirs", "zipman", "purge", "lto" },
                .strip_binaries = &.{"--strip-all"},
                .strip_shared = &.{"--strip-debug"},
                .strip_static = &.{"--strip-unneeded"},
                .sign = false,
                .sign_key = null,
            },
            .destinations = .{
                .build = null,
                .packages = null,
                .sources = null,
                .logs = null,
            },
            .sandbox = .{
                .enabled = false,
                .extra_read = &.{},
                .extra_write = &.{},
            },
        };
        errdefer self.arena.deinit();

        if (system_content) |content| try self.applyBuffer(content);
        if (user_content) |content| try self.applyBuffer(content);
        try self.validate();
        return self;
    }

    pub fn deinit(self: *Self) void {
        const allocator = self.backing_allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn applyBuffer(self: *Self, content: []const u8) !void {
        try validateKnownKeys(self.backing_allocator, content);
        var parser = toml.Parser(ConfigurationLayer).init(self.backing_allocator);
        defer parser.deinit();
        var parsed = parser.parseString(content) catch return error.InvalidConfiguration;
        defer parsed.deinit();
        const layer = parsed.value;
        const allocator = self.arena.allocator();

        if (layer.build) |build| {
            if (build.carch) |value| self.build.carch = try allocator.dupe(u8, value);
            if (build.chost) |value| self.build.chost = try allocator.dupe(u8, value);
            if (build.cppflags) |value| self.build.cppflags = try duplicateStrings(allocator, value);
            if (build.cflags) |value| self.build.cflags = try duplicateStrings(allocator, value);
            if (build.cxxflags) |value| self.build.cxxflags = try duplicateStrings(allocator, value);
            if (build.ldflags) |value| self.build.ldflags = try duplicateStrings(allocator, value);
            if (build.ltoflags) |value| self.build.ltoflags = try duplicateStrings(allocator, value);
            if (build.makeflags) |value| self.build.makeflags = try duplicateStrings(allocator, value);
            if (build.check) |value| self.build.check = value;
            if (build.ccache) |value| self.build.ccache = value;
            if (build.distcc) |value| self.build.distcc = value;
            if (build.distcc_hosts) |value| self.build.distcc_hosts = try duplicateStrings(allocator, value);
        }
        if (layer.package) |package| {
            if (package.packager) |value| self.package.packager = try allocator.dupe(u8, value);
            if (package.extension) |value| self.package.extension = try allocator.dupe(u8, value);
            if (package.options) |value| self.package.options = try duplicateStrings(allocator, value);
            if (package.strip_binaries) |value| self.package.strip_binaries = try duplicateStrings(allocator, value);
            if (package.strip_shared) |value| self.package.strip_shared = try duplicateStrings(allocator, value);
            if (package.strip_static) |value| self.package.strip_static = try duplicateStrings(allocator, value);
            if (package.sign) |value| self.package.sign = value;
            if (package.sign_key) |value| self.package.sign_key = try allocator.dupe(u8, value);
        }
        if (layer.destinations) |destinations| {
            if (destinations.build) |value| self.destinations.build = try allocator.dupe(u8, value);
            if (destinations.packages) |value| self.destinations.packages = try allocator.dupe(u8, value);
            if (destinations.sources) |value| self.destinations.sources = try allocator.dupe(u8, value);
            if (destinations.logs) |value| self.destinations.logs = try allocator.dupe(u8, value);
        }
        if (layer.sandbox) |sandbox| {
            if (sandbox.enabled) |value| self.sandbox.enabled = value;
            if (sandbox.extra_read) |value| self.sandbox.extra_read = try duplicateStrings(allocator, value);
            if (sandbox.extra_write) |value| self.sandbox.extra_write = try duplicateStrings(allocator, value);
        }
    }

    fn validate(self: *const Self) !void {
        if (self.build.carch.len == 0 or self.build.chost.len == 0)
            return error.InvalidConfiguration;
        for (self.package.options) |option| {
            if (!isValidPackageOption(option)) return error.InvalidPackageOption;
        }
        if (!isValidPackageExtension(self.package.extension))
            return error.InvalidPackageExtension;
        if (self.package.sign_key) |key| {
            if (key.len == 0) return error.InvalidConfiguration;
        }
        inline for (.{ self.destinations.build, self.destinations.packages, self.destinations.sources, self.destinations.logs }) |path| {
            if (path) |configured| {
                if (!std.fs.path.isAbsolute(configured)) return error.DestinationPathNotAbsolute;
            }
        }
        for (self.sandbox.extra_read) |path| {
            if (!std.fs.path.isAbsolute(path)) return error.SandboxPathNotAbsolute;
        }
        for (self.sandbox.extra_write) |path| {
            if (!std.fs.path.isAbsolute(path)) return error.SandboxPathNotAbsolute;
        }
    }
};

pub fn resolveUserConfigurationPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) ![]u8 {
    const elevated = environ.getPosix("SUDO_USER") != null or
        environ.getPosix("DOAS_USER") != null or
        environ.getPosix("PKEXEC_UID") != null;
    if (!elevated) {
        if (environ.getPosix("XDG_CONFIG_HOME")) |xdg_config_home| {
            if (xdg_config_home.len != 0 and std.fs.path.isAbsolute(xdg_config_home))
                return std.fs.path.join(allocator, &.{ xdg_config_home, "shelly", file_name });
        }
    }
    const home = try process_runner.resolveInvokingUserHome(allocator, io, environ);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".config", "shelly", file_name });
}

fn readOptionalFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn duplicateStrings(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const duplicated = try allocator.alloc([]const u8, values.len);
    for (values, duplicated) |value, *destination| destination.* = try allocator.dupe(u8, value);
    return duplicated;
}

fn validateKnownKeys(allocator: std.mem.Allocator, content: []const u8) !void {
    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();
    var parsed = parser.parseString(content) catch return error.InvalidConfiguration;
    defer parsed.deinit();
    var root = parsed.value.iterator();
    while (root.next()) |entry| {
        const allowed = if (std.mem.eql(u8, entry.key_ptr.*, "build"))
            build_keys
        else if (std.mem.eql(u8, entry.key_ptr.*, "package"))
            package_keys
        else if (std.mem.eql(u8, entry.key_ptr.*, "destinations"))
            destination_keys
        else if (std.mem.eql(u8, entry.key_ptr.*, "sandbox"))
            sandbox_keys
        else
            return error.UnknownConfigurationKey;
        const table = switch (entry.value_ptr.*) {
            .table => |table| table,
            else => return error.InvalidConfiguration,
        };
        var fields = table.iterator();
        while (fields.next()) |field| {
            if (!containsString(allowed, field.key_ptr.*)) return error.UnknownConfigurationKey;
        }
    }
}

const build_keys: []const []const u8 = &.{ "carch", "chost", "cppflags", "cflags", "cxxflags", "ldflags", "ltoflags", "makeflags", "check", "ccache", "distcc", "distcc_hosts" };
const package_keys: []const []const u8 = &.{ "packager", "extension", "options", "strip_binaries", "strip_shared", "strip_static", "sign", "sign_key" };
const destination_keys: []const []const u8 = &.{ "build", "packages", "sources", "logs" };
const sandbox_keys: []const []const u8 = &.{ "enabled", "extra_read", "extra_write" };

fn containsString(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn isValidPackageOption(option: []const u8) bool {
    return containsString(&.{ "strip", "docs", "libtool", "staticlibs", "emptydirs", "zipman", "purge", "debug", "lto", "autodeps", "buildflags", "makeflags" }, option);
}

fn isValidPackageExtension(extension: []const u8) bool {
    for ([_][]const u8{ ".pkg.tar.zst", ".pkg.tar.xz", ".pkg.tar.gz", ".pkg.tar.bz2", ".pkg.tar.lrz", ".pkg.tar.lzo", ".pkg.tar.Z", ".pkg.tar.lz4", ".pkg.tar.lz" }) |supported| {
        if (std.mem.eql(u8, extension, supported)) return true;
    }
    return false;
}

fn expectOptionalUnset(value: anytype) !void {
    const type_info = @typeInfo(@TypeOf(value));
    try std.testing.expect(type_info == .optional);
    if (type_info == .optional) try std.testing.expect(value == null);
}

test "shellybuild compiled defaults are safe and complete" {
    const config = try ShellyBuildConfiguration.initFromBuffers(std.testing.allocator, null, null);
    defer config.deinit();

    try std.testing.expectEqualStrings("x86_64", config.build.carch);
    try std.testing.expectEqualStrings("x86_64-pc-linux-gnu", config.build.chost);
    try std.testing.expect(config.build.check);
    try std.testing.expect(!config.build.ccache);
    try std.testing.expect(!config.build.distcc);
    try std.testing.expectEqualStrings(".pkg.tar.zst", config.package.extension);
    try std.testing.expect(!config.package.sign);
    try expectOptionalUnset(config.package.sign_key);
    try expectOptionalUnset(config.destinations.build);
    try expectOptionalUnset(config.destinations.packages);
    try expectOptionalUnset(config.destinations.sources);
    try expectOptionalUnset(config.destinations.logs);
    try std.testing.expect(!config.sandbox.enabled);
    try std.testing.expectEqual(@as(usize, 0), config.sandbox.extra_read.len);
    try std.testing.expectEqual(@as(usize, 0), config.sandbox.extra_write.len);
}

test "shellybuild comment-only sections do not override compiled defaults" {
    const template =
        \\# Every value in the installed template is optional.
        \\[build]
        \\# check = false
        \\[package]
        \\# packager = "Example"
        \\[destinations]
        \\# logs = "/var/log/shelly/build"
    ;
    const config = try ShellyBuildConfiguration.initFromBuffers(
        std.testing.allocator,
        template,
        null,
    );
    defer config.deinit();

    try std.testing.expect(config.build.check);
    try std.testing.expectEqualStrings("Unknown Packager", config.package.packager);
    try expectOptionalUnset(config.destinations.build);
    try expectOptionalUnset(config.destinations.packages);
    try expectOptionalUnset(config.destinations.sources);
    try expectOptionalUnset(config.destinations.logs);
}

test "shellybuild merges system and user files field by field" {
    const system =
        \\[build]
        \\cflags = ["-O1"]
        \\check = false
        \\[package]
        \\packager = "System Packager"
        \\[destinations]
        \\packages = "/system/packages"
    ;
    const user =
        \\[build]
        \\cflags = ["-O3", "-pipe"]
        \\ccache = true
        \\[destinations]
        \\logs = "/user/logs"
    ;
    const config = try ShellyBuildConfiguration.initFromBuffers(std.testing.allocator, system, user);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 2), config.build.cflags.len);
    try std.testing.expectEqualStrings("-O3", config.build.cflags[0]);
    try std.testing.expectEqualStrings("-pipe", config.build.cflags[1]);
    try std.testing.expect(!config.build.check);
    try std.testing.expect(config.build.ccache);
    try std.testing.expectEqualStrings("System Packager", config.package.packager);
    try std.testing.expectEqualStrings("/system/packages", config.destinations.packages.?);
    try std.testing.expectEqualStrings("/user/logs", config.destinations.logs.?);
}

test "shellybuild rejects unknown keys malformed TOML and invalid values" {
    try std.testing.expectError(error.UnknownConfigurationKey, ShellyBuildConfiguration.initFromBuffers(
        std.testing.allocator,
        "[build]\nunknown = true\n",
        null,
    ));
    try std.testing.expectError(error.InvalidConfiguration, ShellyBuildConfiguration.initFromBuffers(
        std.testing.allocator,
        "[build\ncflags = [\"-O2\"]\n",
        null,
    ));
    try std.testing.expectError(error.InvalidPackageOption, ShellyBuildConfiguration.initFromBuffers(
        std.testing.allocator,
        "[package]\noptions = [\"strip\", \"unsupported\"]\n",
        null,
    ));
    try std.testing.expectError(error.InvalidPackageExtension, ShellyBuildConfiguration.initFromBuffers(
        std.testing.allocator,
        "[package]\nextension = \"pkg.tar.zst\"\n",
        null,
    ));
}

test "shellybuild requires absolute destination paths" {
    try std.testing.expectError(error.DestinationPathNotAbsolute, ShellyBuildConfiguration.initFromBuffers(
        std.testing.allocator,
        "[destinations]\nsources = \"relative/sources\"\n",
        null,
    ));
}

test "shellybuild sandbox section parses and merges field by field" {
    const system =
        \\[sandbox]
        \\enabled = true
        \\extra_read = ["/system/read"]
    ;
    const config = try ShellyBuildConfiguration.initFromBuffers(std.testing.allocator, system, null);
    defer config.deinit();
    try std.testing.expect(config.sandbox.enabled);
    try std.testing.expectEqual(@as(usize, 1), config.sandbox.extra_read.len);
    try std.testing.expectEqualStrings("/system/read", config.sandbox.extra_read[0]);
    try std.testing.expectEqual(@as(usize, 0), config.sandbox.extra_write.len);

    const overridden = try ShellyBuildConfiguration.initFromBuffers(
        std.testing.allocator,
        system,
        "[sandbox]\nenabled = false\nextra_write = [\"/user/write\"]\n",
    );
    defer overridden.deinit();
    try std.testing.expect(!overridden.sandbox.enabled);
    try std.testing.expectEqualStrings("/system/read", overridden.sandbox.extra_read[0]);
    try std.testing.expectEqual(@as(usize, 1), overridden.sandbox.extra_write.len);
    try std.testing.expectEqualStrings("/user/write", overridden.sandbox.extra_write[0]);
}

test "shellybuild requires absolute sandbox paths and known keys" {
    try std.testing.expectError(error.SandboxPathNotAbsolute, ShellyBuildConfiguration.initFromBuffers(
        std.testing.allocator,
        "[sandbox]\nextra_read = [\"relative/read\"]\n",
        null,
    ));
    try std.testing.expectError(error.SandboxPathNotAbsolute, ShellyBuildConfiguration.initFromBuffers(
        std.testing.allocator,
        "[sandbox]\nextra_write = [\"relative/write\"]\n",
        null,
    ));
    try std.testing.expectError(error.UnknownConfigurationKey, ShellyBuildConfiguration.initFromBuffers(
        std.testing.allocator,
        "[sandbox]\nnetwork = false\n",
        null,
    ));
}

test "shellybuild signing policy merges field by field and rejects empty keys" {
    const system =
        \\[package]
        \\sign = true
        \\sign_key = "CE4814F7337B98A2527A32F8FCEBF9274CA93649"
    ;
    const config = try ShellyBuildConfiguration.initFromBuffers(std.testing.allocator, system, null);
    defer config.deinit();
    try std.testing.expect(config.package.sign);
    try std.testing.expectEqualStrings(
        "CE4814F7337B98A2527A32F8FCEBF9274CA93649",
        config.package.sign_key.?,
    );

    const overridden = try ShellyBuildConfiguration.initFromBuffers(
        std.testing.allocator,
        system,
        "[package]\nsign = false\n",
    );
    defer overridden.deinit();
    try std.testing.expect(!overridden.package.sign);
    try std.testing.expectEqualStrings(
        "CE4814F7337B98A2527A32F8FCEBF9274CA93649",
        overridden.package.sign_key.?,
    );

    try std.testing.expectError(error.InvalidConfiguration, ShellyBuildConfiguration.initFromBuffers(
        std.testing.allocator,
        "[package]\nsign_key = \"\"\n",
        null,
    ));
}

test "shellybuild resolves XDG path with HOME fallback" {
    var xdg_map = std.process.Environ.Map.init(std.testing.allocator);
    defer xdg_map.deinit();
    try xdg_map.put("HOME", "/home/invoker");
    try xdg_map.put("XDG_CONFIG_HOME", "/custom/config");
    const xdg_environ: std.process.Environ = .{
        .block = try xdg_map.createPosixBlock(std.testing.allocator, .{}),
    };
    defer xdg_environ.block.deinit(std.testing.allocator);
    const xdg_path = try resolveUserConfigurationPath(std.testing.allocator, std.testing.io, xdg_environ);
    defer std.testing.allocator.free(xdg_path);
    try std.testing.expectEqualStrings("/custom/config/shelly/shellybuild.conf", xdg_path);

    var fallback_map = std.process.Environ.Map.init(std.testing.allocator);
    defer fallback_map.deinit();
    try fallback_map.put("HOME", "/home/invoker");
    const fallback_environ: std.process.Environ = .{
        .block = try fallback_map.createPosixBlock(std.testing.allocator, .{}),
    };
    defer fallback_environ.block.deinit(std.testing.allocator);
    const fallback_path = try resolveUserConfigurationPath(std.testing.allocator, std.testing.io, fallback_environ);
    defer std.testing.allocator.free(fallback_path);
    try std.testing.expectEqualStrings("/home/invoker/.config/shelly/shellybuild.conf", fallback_path);
}

test "shellybuild elevated path ignores the coordinator XDG directory" {
    var elevated_map = std.process.Environ.Map.init(std.testing.allocator);
    defer elevated_map.deinit();
    try elevated_map.put("HOME", "/home/invoker");
    try elevated_map.put("XDG_CONFIG_HOME", "/root/custom-config");
    try elevated_map.put("SUDO_USER", "shelly-test-user-not-in-passwd");
    const elevated_environ: std.process.Environ = .{
        .block = try elevated_map.createPosixBlock(std.testing.allocator, .{}),
    };
    defer elevated_environ.block.deinit(std.testing.allocator);
    const path = try resolveUserConfigurationPath(std.testing.allocator, std.testing.io, elevated_environ);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/invoker/.config/shelly/shellybuild.conf", path);
}
