const std = @import("std");
const Io = std.Io;
const Bindings = @import("bindings.zig");
const Allocator = std.mem.Allocator;

const equalIgnoreCase = std.ascii.eqlIgnoreCase;

const max_include_depth = 16;

const SigLevel = Bindings.libalpm.SigLevel;
const DatabaseUsage = Bindings.libalpm.DatabaseUsage;

inline fn sig(level: SigLevel) u32 {
    return @intFromEnum(level);
}
inline fn usageBit(flag: DatabaseUsage) u32 {
    return @intFromEnum(flag);
}

pub const Configuration = struct {
    pub const Repository = struct {
        name: []const u8,
        servers: std.ArrayList([]const u8) = .empty,
        sig_level: u32 = sig(.use_default),
        usage: u32 = 0,
    };

    pub const Config = struct {
        arena: *std.heap.ArenaAllocator,

        root_directory: []const u8,
        database_path: []const u8,
        cache_directory: []const u8,
        log_file: []const u8,
        gpg_directory: []const u8,
        hook_directory: std.ArrayList([]const u8),
        hold_packages: std.ArrayList([]const u8),
        transfer_command: []const u8,
        transfer_command_two: []const u8,
        use_delta: f64,
        architecture: []const u8,
        ignore_package: std.ArrayList([]const u8),
        ignore_group: std.ArrayList([]const u8),
        no_upgrade: std.ArrayList([]const u8),
        no_extract: std.ArrayList([]const u8),
        use_system_log: bool,
        check_space: bool,
        repositories: std.ArrayList(Repository),
        signature_level: u32,
        local_file_signature_level: u32,
        remote_file_signature_level: u32,

        pub fn initialize_with_defaults(arena: *std.heap.ArenaAllocator) Allocator.Error!Config {
            const alloc = arena.allocator();
            var conf = Config{
                .arena = arena,
                .root_directory = "/",
                .database_path = "/var/lib/pacman",
                .cache_directory = "/var/cache/pacman/pkg",
                .log_file = "/var/log/shelly.log",
                .gpg_directory = "/etc/pacman.d/gnupg",
                .hook_directory = .empty,
                .hold_packages = .empty,
                .transfer_command = "/usr/bin/curl -L -C - -f -o %o %u",
                .transfer_command_two = "/usr/bin/wget --passive-ftp -c -O %o %u",
                .use_delta = 0.7,
                .architecture = "auto",
                .ignore_package = .empty,
                .ignore_group = .empty,
                .no_upgrade = .empty,
                .no_extract = .empty,
                .use_system_log = false,
                .check_space = false,
                .repositories = .empty,

                .signature_level = sig(.package) | sig(.database_optional),
                .local_file_signature_level = sig(.package_optional) | sig(.database_optional),
                .remote_file_signature_level = sig(.package) | sig(.database),
            };
            try conf.hook_directory.append(alloc, "/usr/share/libalpm/hooks");
            try conf.hook_directory.append(alloc, "/etc/pacman.d/hooks");
            try conf.hold_packages.append(alloc, "pacman");
            try conf.hold_packages.append(alloc, "glibc");
            try conf.hold_packages.append(alloc, "shelly");
            return conf;
        }

        pub fn deinitialize(self: *Config) void {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self.arena);
        }
    };

    pub fn parse(gpa: Allocator, io: Io, path: []const u8) Allocator.Error!Config {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();

        var conf = try Config.initialize_with_defaults(arena);
        var parser = Parser{
            .io = io,
            .scratch_allocator = gpa,
            .arena_allocater = arena.allocator(),
            .config = &conf,
        };
        try parser.parse_file(path);
        try parser.finish();
        return conf;
    }

    pub fn parse_string(gpa: Allocator, io: Io, text: []const u8) Allocator.Error!Config {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();

        var conf = try Config.initialize_with_defaults(arena);
        var parser = Parser{
            .io = io,
            .scratch_allocator = gpa,
            .arena_allocater = arena.allocator(),
            .config = &conf,
        };
        try parser.parse_buffer(text);
        try parser.finish();
        return conf;
    }

    pub fn parse_signature_level(value: []const u8) u32 {
        var result: u32 = sig(.none);
        var it = std.mem.tokenizeScalar(u8, value, ' ');
        while (it.next()) |level| {
            if (equalIgnoreCase(level, "required") or equalIgnoreCase(level, "packagerequired")) {
                result |= sig(.package);
            } else if (equalIgnoreCase(level, "optional") or equalIgnoreCase(level, "packageoptional")) {
                result |= sig(.package_optional);
            } else if (equalIgnoreCase(level, "packagemarginalok")) {
                result |= sig(.package_marginal_ok);
            } else if (equalIgnoreCase(level, "packageunknownok")) {
                result |= sig(.package_unknown_ok);
            } else if (equalIgnoreCase(level, "databaserequired")) {
                result |= sig(.database);
            } else if (equalIgnoreCase(level, "databaseoptional")) {
                result |= sig(.database_optional);
            } else if (equalIgnoreCase(level, "databasemarginalok")) {
                result |= sig(.database_marginal_ok);
            } else if (equalIgnoreCase(level, "databaseunknownok")) {
                result |= sig(.database_unknown_ok);
            } else if (equalIgnoreCase(level, "never")) {
                result = sig(.none);
            } else if (equalIgnoreCase(level, "trustall")) {
                result |= sig(.package_unknown_ok) | sig(.package_marginal_ok) |
                    sig(.database_unknown_ok) | sig(.database_marginal_ok);
            } else if (equalIgnoreCase(level, "usedefault")) {
                result |= sig(.use_default);
            }
        }
        return result;
    }

    pub fn parse_usage(value: []const u8) u32 {
        var result: u32 = 0;
        var it = std.mem.tokenizeScalar(u8, value, ' ');
        while (it.next()) |flag| {
            if (equalIgnoreCase(flag, "sync")) {
                result |= usageBit(.sync);
            } else if (equalIgnoreCase(flag, "search")) {
                result |= usageBit(.search);
            } else if (equalIgnoreCase(flag, "install")) {
                result |= usageBit(.install);
            } else if (equalIgnoreCase(flag, "upgrade")) {
                result |= usageBit(.upgrade);
            } else if (equalIgnoreCase(flag, "all")) {
                result |= usageBit(.all);
            }
        }
        return result;
    }

    fn read_whole_file(io: Io, alloc: Allocator, path: []const u8) ![]u8 {
        return Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    }

    const Parser = struct {
        io: Io,
        scratch_allocator: Allocator,
        arena_allocater: Allocator,
        config: *Config,
        section: []const u8 = "",
        current_repository: ?Repository = null,
        depth: usize = 0,

        fn parse_file(self: *Parser, path: []const u8) Allocator.Error!void {
            if (self.depth >= max_include_depth) return;
            const bytes = read_whole_file(self.io, self.scratch_allocator, path) catch return;
            defer self.scratch_allocator.free(bytes);

            self.depth += 1;
            defer self.depth -= 1;
            try self.parse_buffer(bytes);
        }

        fn parse_buffer(self: *Parser, bytes: []const u8) Allocator.Error!void {
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r\n");
                if (line.len == 0 or line[0] == '#') continue;

                // Section header: [options] or [repo-name].
                if (line[0] == '[' and line[line.len - 1] == ']') {
                    // Commit the repo we were accumulating before switching.
                    if (self.current_repository) |repo| {
                        try self.config.repositories.append(self.arena_allocater, repo);
                        self.current_repository = null;
                    }
                    self.section = try self.dupe(line[1 .. line.len - 1]);
                    if (!std.mem.eql(u8, self.section, "options")) {
                        self.current_repository = Repository{ .name = self.section };
                    }
                    continue;
                }

                // key = value  (value optional, e.g. bare "CheckSpace").
                const eq = std.mem.indexOfScalar(u8, line, '=');
                const key = std.mem.trim(u8, if (eq) |i| line[0..i] else line, " \t\r\n");
                const value = std.mem.trim(u8, if (eq) |i| line[i + 1 ..] else "", " \t\r\n");

                if (std.mem.eql(u8, self.section, "options")) {
                    if (equalIgnoreCase(key, "include")) {
                        try self.parse_file(value);
                    } else {
                        try self.parse_option(key, value);
                    }
                } else if (self.current_repository != null) {
                    try self.parse_repository_option(key, value);
                }
                // A key before any section header is ignored.
            }
        }

        fn parse_option(self: *Parser, key: []const u8, value: []const u8) Allocator.Error!void {
            const c = self.config;
            if (equalIgnoreCase(key, "rootdir")) {
                c.root_directory = try self.dupe(value);
            } else if (equalIgnoreCase(key, "dbpath")) {
                c.database_path = try self.dupe(value);
            } else if (equalIgnoreCase(key, "cachedir")) {
                c.cache_directory = try self.dupe(value);
            } else if (equalIgnoreCase(key, "logfile")) {
                c.log_file = try self.dupe(value);
            } else if (equalIgnoreCase(key, "gpgdir")) {
                c.gpg_directory = try self.dupe(value);
            } else if (equalIgnoreCase(key, "hookdir")) {
                try self.add_split(&c.hook_directory, value);
            } else if (equalIgnoreCase(key, "holdpkg")) {
                c.hold_packages.clearRetainingCapacity();
                try self.add_split(&c.hold_packages, value);
                var has_shelly = false;
                for (c.hold_packages.items) |p| {
                    if (std.mem.eql(u8, p, "shelly")) {
                        has_shelly = true;
                        break;
                    }
                }
                if (!has_shelly) try c.hold_packages.append(self.arena_allocater, "shelly");
            } else if (equalIgnoreCase(key, "xfercommand")) {
                // Faithful to the C#: transfer_command has a non-empty default,
                // so the first XferCommand in a config lands in the second slot.
                if (c.transfer_command.len == 0) {
                    c.transfer_command = try self.dupe(value);
                } else {
                    c.transfer_command_two = try self.dupe(value);
                }
            } else if (equalIgnoreCase(key, "usedelta")) {
                if (std.fmt.parseFloat(f64, value)) |d| {
                    c.use_delta = d;
                } else |_| {}
            } else if (equalIgnoreCase(key, "architecture")) {
                c.architecture = try self.dupe(value);
            } else if (equalIgnoreCase(key, "ignorepkg")) {
                try self.add_split(&c.ignore_package, value);
            } else if (equalIgnoreCase(key, "ignoregroup")) {
                try self.add_split(&c.ignore_group, value);
            } else if (equalIgnoreCase(key, "noupgrade")) {
                try self.add_split(&c.no_upgrade, value);
            } else if (equalIgnoreCase(key, "noextract")) {
                try self.add_split(&c.no_extract, value);
            } else if (equalIgnoreCase(key, "usesyslog")) {
                c.use_system_log = true;
            } else if (equalIgnoreCase(key, "checkspace")) {
                c.check_space = true;
            } else if (equalIgnoreCase(key, "siglevel")) {
                c.signature_level = parse_signature_level(value);
            } else if (equalIgnoreCase(key, "localfilesiglevel")) {
                c.local_file_signature_level = parse_signature_level(value);
            } else if (equalIgnoreCase(key, "remotefilesiglevel")) {
                c.remote_file_signature_level = parse_signature_level(value);
            }
        }

        fn parse_repository_option(self: *Parser, key: []const u8, value: []const u8) Allocator.Error!void {
            const repo = &self.current_repository.?;
            if (equalIgnoreCase(key, "server")) {
                try repo.servers.append(self.arena_allocater, try self.dupe(value));
            } else if (equalIgnoreCase(key, "siglevel")) {
                repo.sig_level = parse_signature_level(value);
            } else if (equalIgnoreCase(key, "usage")) {
                repo.usage = parse_usage(value);
            } else if (equalIgnoreCase(key, "include")) {
                try self.parse_repository_include(value, repo);
            }
        }

        fn parse_repository_include(self: *Parser, path: []const u8, repo: *Repository) Allocator.Error!void {
            const bytes = read_whole_file(self.io, self.scratch_allocator, path) catch return;
            defer self.scratch_allocator.free(bytes);

            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r\n");
                if (line.len == 0 or line[0] == '#') continue;

                const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                const k = std.mem.trim(u8, line[0..eq], " \t\r\n");
                const v = std.mem.trim(u8, line[eq + 1 ..], " \t\r\n");

                if (equalIgnoreCase(k, "server")) {
                    try repo.servers.append(self.arena_allocater, try self.dupe(v));
                } else if (equalIgnoreCase(k, "siglevel")) {
                    repo.sig_level = parse_signature_level(v);
                } else if (equalIgnoreCase(k, "usage")) {
                    repo.usage = parse_usage(v);
                }
            }
        }

        fn finish(self: *Parser) Allocator.Error!void {
            if (self.current_repository) |repo| {
                try self.config.repositories.append(self.arena_allocater, repo);
                self.current_repository = null;
            }
        }

        fn dupe(self: *Parser, s: []const u8) Allocator.Error![]const u8 {
            return self.arena_allocater.dupe(u8, s);
        }

        fn add_split(self: *Parser, list: *std.ArrayList([]const u8), value: []const u8) Allocator.Error!void {
            var it = std.mem.tokenizeScalar(u8, value, ' ');
            while (it.next()) |tok| {
                try list.append(self.arena_allocater, try self.dupe(tok));
            }
        }
    };
};

const testing = std.testing;

test "empty input yields defaults" {
    var conf = try Configuration.parse_string(testing.allocator, testing.io, "");
    defer conf.deinitialize();

    try testing.expectEqualStrings("/", conf.root_directory);
    try testing.expectEqualStrings("/var/lib/pacman", conf.database_path);
    try testing.expectEqual(@as(usize, 0), conf.repositories.items.len);
    try testing.expectEqual(@as(usize, 3), conf.hold_packages.items.len);
    try testing.expectEqual(sig(.package) | sig(.database_optional), conf.signature_level);
}

test "parses options section" {
    const text =
        \\# a comment
        \\[options]
        \\RootDir = /mnt/target
        \\DBPath  = /mnt/target/var/lib/pacman
        \\Architecture = x86_64
        \\IgnorePkg = linux nvidia
        \\CheckSpace
        \\SigLevel = Required DatabaseOptional
    ;
    var conf = try Configuration.parse_string(testing.allocator, testing.io, text);
    defer conf.deinitialize();

    try testing.expectEqualStrings("/mnt/target", conf.root_directory);
    try testing.expectEqualStrings("/mnt/target/var/lib/pacman", conf.database_path);
    try testing.expectEqualStrings("x86_64", conf.architecture);
    try testing.expectEqual(@as(usize, 2), conf.ignore_package.items.len);
    try testing.expectEqualStrings("linux", conf.ignore_package.items[0]);
    try testing.expectEqualStrings("nvidia", conf.ignore_package.items[1]);
    try testing.expect(conf.check_space);
    try testing.expectEqual(sig(.package) | sig(.database_optional), conf.signature_level);
}

test "parses repositories, servers, siglevel and usage" {
    const text =
        \\[options]
        \\[core]
        \\SigLevel = Required DatabaseOptional
        \\Usage = Sync Search
        \\Server = https://mirror.a/core
        \\[extra]
        \\Server = https://mirror.a/extra
        \\Server = https://mirror.b/extra
    ;
    var conf = try Configuration.parse_string(testing.allocator, testing.io, text);
    defer conf.deinitialize();

    try testing.expectEqual(@as(usize, 2), conf.repositories.items.len);

    const core = conf.repositories.items[0];
    try testing.expectEqualStrings("core", core.name);
    try testing.expectEqual(@as(usize, 1), core.servers.items.len);
    try testing.expectEqual(sig(.package) | sig(.database_optional), core.sig_level);
    try testing.expectEqual(usageBit(.sync) | usageBit(.search), core.usage);

    const extra = conf.repositories.items[1];
    try testing.expectEqualStrings("extra", extra.name);
    try testing.expectEqual(@as(usize, 2), extra.servers.items.len);
}

test "HoldPkg is replaced and shelly is injected" {
    const text =
        \\[options]
        \\HoldPkg = pacman glibc linux
    ;
    var conf = try Configuration.parse_string(testing.allocator, testing.io, text);
    defer conf.deinitialize();

    try testing.expectEqual(@as(usize, 4), conf.hold_packages.items.len);
    var found = false;
    for (conf.hold_packages.items) |p| {
        if (std.mem.eql(u8, p, "shelly")) found = true;
    }
    try testing.expect(found);
}
