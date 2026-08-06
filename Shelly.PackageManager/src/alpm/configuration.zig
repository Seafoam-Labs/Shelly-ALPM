const std = @import("std");
const Io = std.Io;
const Bindings = @import("bindings.zig");
const Allocator = std.mem.Allocator;

const equalIgnoreCase = std.ascii.eqlIgnoreCase;

const max_include_depth = 16;

const SigLevel = Bindings.libalpm.SigLevel;
const DatabaseUsage = Bindings.libalpm.DatabaseUsage;

pub const PackageDirectiveError = error{
    InvalidPackageName,
    ConfigReadFailed,
    ConfigWriteFailed,
    OutOfMemory,
};

pub const IgnorePackageError = PackageDirectiveError;
pub const HoldPackageError = PackageDirectiveError;

pub const RepositoryError = error{
    InvalidRepositoryName,
    DuplicateRepository,
    ConfigReadFailed,
    ConfigWriteFailed,
    OutOfMemory,
};

inline fn sig(level: SigLevel) u32 {
    return @bitCast(level.to_sig_level());
}
inline fn usageBit(flag: DatabaseUsage) u32 {
    return @intFromEnum(flag);
}

pub const Configuration = struct {
    pub const Repository = struct {
        name: []const u8,
        servers: std.ArrayList([]const u8) = .empty,
        sig_level: u32 = sig(.{ .use_default = true }),
        usage: u32 = 0,
    };

    pub const Config = struct {
        arena: *std.heap.ArenaAllocator,

        root_directory: [:0]const u8,
        database_path: [:0]const u8,
        cache_directory: [:0]const u8,
        log_file: [:0]const u8,
        gpg_directory: [:0]const u8,
        hook_directory: std.ArrayList([:0]const u8),
        hold_packages: std.ArrayList([:0]const u8),
        transfer_command: [:0]const u8,
        transfer_command_two: [:0]const u8,
        use_delta: f64,
        architecture: [:0]const u8,
        ignore_package: std.ArrayList([:0]const u8),
        ignore_group: std.ArrayList([:0]const u8),
        no_upgrade: std.ArrayList([:0]const u8),
        no_extract: std.ArrayList([:0]const u8),
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

                .signature_level = sig(.{ .package = true }) | sig(.{ .database = true }) | sig(.{ .database_optional = true }),
                .local_file_signature_level = sig(.{ .package_optional = true }) | sig(.{ .database_optional = true }),
                .remote_file_signature_level = sig(.{ .package = true }) | sig(.{ .database = true }),
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

    pub fn add_ignore_package(
        config: *Config,
        io: Io,
        scratch_allocator: Allocator,
        config_path: []const u8,
        package_name: []const u8,
    ) IgnorePackageError!void {
        const normalized = normalize_package_name(package_name) orelse
            return IgnorePackageError.InvalidPackageName;
        try add_ignore_packages(config, io, scratch_allocator, config_path, &.{normalized});
    }

    pub fn add_ignore_packages(
        config: *Config,
        io: Io,
        scratch_allocator: Allocator,
        config_path: []const u8,
        package_names: []const []const u8,
    ) IgnorePackageError!void {
        var changed = false;
        const arena_allocator = config.arena.allocator();

        for (package_names) |package_name| {
            const normalized = normalize_package_name(package_name) orelse continue;
            if (contains_package_name(config.ignore_package.items, normalized)) continue;

            const owned_name = try arena_allocator.dupeSentinel(u8, normalized, 0);
            try config.ignore_package.append(arena_allocator, owned_name);
            changed = true;
        }

        if (changed) try rewrite_ignore_packages(config, io, scratch_allocator, config_path);
    }

    pub fn remove_ignore_package(
        config: *Config,
        io: Io,
        scratch_allocator: Allocator,
        config_path: []const u8,
        package_name: []const u8,
    ) IgnorePackageError!void {
        const normalized = normalize_package_name(package_name) orelse
            return IgnorePackageError.InvalidPackageName;
        try remove_ignore_packages(config, io, scratch_allocator, config_path, &.{normalized});
    }

    pub fn remove_ignore_packages(
        config: *Config,
        io: Io,
        scratch_allocator: Allocator,
        config_path: []const u8,
        package_names: []const []const u8,
    ) IgnorePackageError!void {
        var normalized_names: std.ArrayList([]const u8) = .empty;
        defer normalized_names.deinit(scratch_allocator);

        for (package_names) |package_name| {
            const normalized = normalize_package_name(package_name) orelse continue;
            if (contains_name(normalized_names.items, normalized)) continue;
            try normalized_names.append(scratch_allocator, normalized);
        }
        if (normalized_names.items.len == 0) return;

        var changed = false;
        var index: usize = 0;
        while (index < config.ignore_package.items.len) {
            if (contains_name(normalized_names.items, config.ignore_package.items[index])) {
                _ = config.ignore_package.orderedRemove(index);
                changed = true;
            } else {
                index += 1;
            }
        }

        if (changed) try rewrite_ignore_packages(config, io, scratch_allocator, config_path);
    }

    /// Returns a normalized list whose strings are borrowed from `config`.
    /// The caller must deinitialize the returned list, but must not free its items.
    pub fn get_ignored_packages(
        config: *const Config,
        allocator: Allocator,
    ) IgnorePackageError!std.ArrayList([:0]const u8) {
        var result: std.ArrayList([:0]const u8) = .empty;
        errdefer result.deinit(allocator);

        for (config.ignore_package.items) |package_name| {
            if (package_name.len == 0 or contains_package_name(result.items, package_name)) continue;
            try result.append(allocator, package_name);
        }

        return result;
    }

    pub fn add_hold_package(
        config: *Config,
        io: Io,
        scratch_allocator: Allocator,
        config_path: []const u8,
        package_name: []const u8,
    ) HoldPackageError!void {
        const normalized = normalize_package_name(package_name) orelse
            return HoldPackageError.InvalidPackageName;
        try add_hold_packages(config, io, scratch_allocator, config_path, &.{normalized});
    }

    pub fn add_hold_packages(
        config: *Config,
        io: Io,
        scratch_allocator: Allocator,
        config_path: []const u8,
        package_names: []const []const u8,
    ) HoldPackageError!void {
        var changed = false;
        const arena_allocator = config.arena.allocator();

        for (package_names) |package_name| {
            const normalized = normalize_package_name(package_name) orelse continue;
            if (contains_package_name(config.hold_packages.items, normalized)) continue;

            const owned_name = try arena_allocator.dupeSentinel(u8, normalized, 0);
            try config.hold_packages.append(arena_allocator, owned_name);
            changed = true;
        }

        if (changed) try rewrite_hold_packages(config, io, scratch_allocator, config_path);
    }

    pub fn remove_hold_package(
        config: *Config,
        io: Io,
        scratch_allocator: Allocator,
        config_path: []const u8,
        package_name: []const u8,
    ) HoldPackageError!void {
        const normalized = normalize_package_name(package_name) orelse
            return HoldPackageError.InvalidPackageName;
        try remove_hold_packages(config, io, scratch_allocator, config_path, &.{normalized});
    }

    pub fn remove_hold_packages(
        config: *Config,
        io: Io,
        scratch_allocator: Allocator,
        config_path: []const u8,
        package_names: []const []const u8,
    ) HoldPackageError!void {
        var normalized_names: std.ArrayList([]const u8) = .empty;
        defer normalized_names.deinit(scratch_allocator);

        for (package_names) |package_name| {
            const normalized = normalize_package_name(package_name) orelse continue;
            if (std.mem.eql(u8, normalized, "shelly")) continue;
            if (contains_name(normalized_names.items, normalized)) continue;
            try normalized_names.append(scratch_allocator, normalized);
        }
        if (normalized_names.items.len == 0) return;

        var changed = false;
        var index: usize = 0;
        while (index < config.hold_packages.items.len) {
            if (contains_name(normalized_names.items, config.hold_packages.items[index])) {
                _ = config.hold_packages.orderedRemove(index);
                changed = true;
            } else {
                index += 1;
            }
        }

        if (changed) try rewrite_hold_packages(config, io, scratch_allocator, config_path);
    }

    /// Returns a normalized list whose strings are borrowed from `config`.
    /// The caller must deinitialize the returned list, but must not free its items.
    pub fn get_held_packages(
        config: *const Config,
        allocator: Allocator,
    ) HoldPackageError!std.ArrayList([:0]const u8) {
        var result: std.ArrayList([:0]const u8) = .empty;
        errdefer result.deinit(allocator);

        for (config.hold_packages.items) |package_name| {
            if (package_name.len == 0 or contains_package_name(result.items, package_name)) continue;
            try result.append(allocator, package_name);
        }

        return result;
    }

    /// Returns repository names borrowed from `config` in declaration order.
    /// The caller must deinitialize the returned list, but must not free its items.
    pub fn get_repository_names(
        config: *const Config,
        allocator: Allocator,
    ) Allocator.Error!std.ArrayList([]const u8) {
        var result: std.ArrayList([]const u8) = .empty;
        errdefer result.deinit(allocator);

        try result.ensureTotalCapacity(allocator, config.repositories.items.len);
        for (config.repositories.items) |repository| {
            result.appendAssumeCapacity(repository.name);
        }
        return result;
    }

    /// Finds a configured repository by its exact ALPM database name.
    /// The returned pointer and all of its strings are borrowed from `config`.
    pub fn find_repository(config: *const Config, name: []const u8) ?*const Repository {
        for (config.repositories.items) |*repository| {
            if (std.mem.eql(u8, repository.name, name)) return repository;
        }
        return null;
    }

    /// Adds a repository to the configuration and appends its `[name]` section
    /// to the config file. `sig_level` and `usage` are raw config strings such
    /// as "Required DatabaseOptional" and "Sync Search"; empty strings omit the
    /// directive and keep the `Repository` defaults.
    pub fn add_repository(
        config: *Config,
        io: Io,
        scratch_allocator: Allocator,
        config_path: []const u8,
        name: []const u8,
        servers: []const []const u8,
        sig_level: []const u8,
        usage: []const u8,
    ) RepositoryError!void {
        const normalized = normalize_repository_name(name) orelse
            return RepositoryError.InvalidRepositoryName;
        if (find_repository(config, normalized) != null)
            return RepositoryError.DuplicateRepository;

        const arena_allocator = config.arena.allocator();
        var repository = Repository{ .name = try arena_allocator.dupe(u8, normalized) };
        for (servers) |server| {
            const trimmed = std.mem.trim(u8, server, " \t\r\n");
            if (trimmed.len == 0) continue;
            try repository.servers.append(arena_allocator, try arena_allocator.dupe(u8, trimmed));
        }
        if (sig_level.len != 0) repository.sig_level = parse_signature_level(sig_level);
        if (usage.len != 0) repository.usage = parse_usage(usage);

        try config.repositories.append(arena_allocator, repository);
        try rewrite_add_repository(io, scratch_allocator, config_path, repository, sig_level, usage);
    }

    /// Removes every repository named `name` from the configuration and deletes
    /// its section from the config file. Unknown names leave everything untouched.
    pub fn remove_repository(
        config: *Config,
        io: Io,
        scratch_allocator: Allocator,
        config_path: []const u8,
        name: []const u8,
    ) RepositoryError!void {
        const normalized = normalize_repository_name(name) orelse
            return RepositoryError.InvalidRepositoryName;

        var changed = false;
        var index: usize = 0;
        while (index < config.repositories.items.len) {
            if (std.mem.eql(u8, config.repositories.items[index].name, normalized)) {
                _ = config.repositories.orderedRemove(index);
                changed = true;
            } else {
                index += 1;
            }
        }

        if (changed) try rewrite_remove_repository(io, scratch_allocator, config_path, normalized);
    }

    fn rewrite_ignore_packages(
        config: *const Config,
        io: Io,
        allocator: Allocator,
        config_path: []const u8,
    ) IgnorePackageError!void {
        return rewrite_package_directive(
            io,
            allocator,
            config_path,
            "IgnorePkg",
            config.ignore_package.items,
        );
    }

    fn rewrite_hold_packages(
        config: *const Config,
        io: Io,
        allocator: Allocator,
        config_path: []const u8,
    ) HoldPackageError!void {
        return rewrite_package_directive(
            io,
            allocator,
            config_path,
            "HoldPkg",
            config.hold_packages.items,
        );
    }

    fn rewrite_package_directive(
        io: Io,
        allocator: Allocator,
        config_path: []const u8,
        directive: []const u8,
        package_names: []const [:0]const u8,
    ) PackageDirectiveError!void {
        const contents = Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ConfigReadFailed,
        };
        defer allocator.free(contents);

        var lines = try split_lines(allocator, contents);
        defer lines.deinit(allocator);

        const section = find_section(lines.items, "options");
        const first_directive_line = find_directive_line(lines.items, section, directive);

        var unique_names: std.ArrayList([:0]const u8) = .empty;
        defer unique_names.deinit(allocator);
        for (package_names) |package_name| {
            if (package_name.len == 0 or contains_package_name(unique_names.items, package_name)) continue;
            try unique_names.append(allocator, package_name);
        }

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);

        var insert_index = lines.items.len;
        if (first_directive_line) |line_index| {
            insert_index = line_index;
        } else if (section.start) |start| {
            insert_index = start + 1;
        }

        try append_lines_skipping_directives(&output, allocator, lines.items[0..insert_index], 0, section, directive);
        if (section.start == null) try append_config_line(&output, allocator, "[options]");
        try append_package_directive_line(&output, allocator, directive, unique_names.items);
        try append_lines_skipping_directives(&output, allocator, lines.items[insert_index..], insert_index, section, directive);

        try write_config_file(io, config_path, output.items);
    }

    fn rewrite_add_repository(
        io: Io,
        allocator: Allocator,
        config_path: []const u8,
        repository: Repository,
        sig_level: []const u8,
        usage: []const u8,
    ) RepositoryError!void {
        const contents = Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ConfigReadFailed,
        };
        defer allocator.free(contents);

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);

        try output.appendSlice(allocator, contents);
        if (contents.len != 0 and contents[contents.len - 1] != '\n') {
            try output.append(allocator, '\n');
        }
        try append_repository_section(&output, allocator, repository.name, repository.servers.items, sig_level, usage);
        try write_config_file(io, config_path, output.items);
    }

    fn rewrite_remove_repository(
        io: Io,
        allocator: Allocator,
        config_path: []const u8,
        name: []const u8,
    ) RepositoryError!void {
        const contents = Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ConfigReadFailed,
        };
        defer allocator.free(contents);

        var lines = try split_lines(allocator, contents);
        defer lines.deinit(allocator);

        const section = find_section(lines.items, name);
        const start = section.start orelse return;

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);

        // Track where the trailing run of blank lines begins so blanks left
        // behind by removing the final section can be dropped.
        var trailing_blank_start: ?usize = null;
        for (lines.items, 0..) |line, index| {
            if (index >= start and index < section.end) continue;
            if (std.mem.trim(u8, line, " \t").len == 0) {
                if (trailing_blank_start == null) trailing_blank_start = output.items.len;
            } else {
                trailing_blank_start = null;
            }
            try append_config_line(&output, allocator, line);
        }
        if (trailing_blank_start) |length| output.items.len = length;

        try write_config_file(io, config_path, output.items);
    }

    fn split_lines(allocator: Allocator, contents: []const u8) Allocator.Error!std.ArrayList([]const u8) {
        var lines: std.ArrayList([]const u8) = .empty;
        errdefer lines.deinit(allocator);

        var line_start: usize = 0;
        while (line_start < contents.len) {
            const newline = std.mem.indexOfScalarPos(u8, contents, line_start, '\n');
            const line_end = newline orelse contents.len;
            const line = std.mem.trimEnd(u8, contents[line_start..line_end], "\r");
            try lines.append(allocator, line);
            line_start = if (newline) |position| position + 1 else contents.len;
        }

        return lines;
    }

    const Section = struct {
        start: ?usize,
        end: usize,

        fn contains_line(self: Section, line_index: usize) bool {
            const start = self.start orelse return false;
            return line_index > start and line_index < self.end;
        }
    };

    /// Finds the line range of the `[name]` section. `end` is the index of the
    /// next section header, or `lines.len` when the section runs to EOF.
    fn find_section(lines: []const []const u8, name: []const u8) Section {
        var section = Section{ .start = null, .end = lines.len };
        for (lines, 0..) |line, index| {
            const section_name = config_section_name(line) orelse continue;
            if (section.start == null) {
                if (equalIgnoreCase(section_name, name)) section.start = index;
            } else {
                section.end = index;
                break;
            }
        }
        return section;
    }

    fn find_directive_line(
        lines: []const []const u8,
        section: Section,
        directive: []const u8,
    ) ?usize {
        const start = section.start orelse return null;
        for (lines[start + 1 .. section.end], start + 1..) |line, index| {
            if (is_package_directive_line(line, directive)) return index;
        }
        return null;
    }

    fn write_config_file(io: Io, config_path: []const u8, contents: []const u8) error{ConfigWriteFailed}!void {
        var file = Io.Dir.cwd().createFile(io, config_path, .{}) catch
            return error.ConfigWriteFailed;
        defer file.close(io);

        var write_buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &write_buffer);
        writer.interface.writeAll(contents) catch return error.ConfigWriteFailed;
        writer.interface.flush() catch return error.ConfigWriteFailed;
    }

    fn normalize_package_name(package_name: []const u8) ?[]const u8 {
        const normalized = std.mem.trim(u8, package_name, " \t\r\n");
        return if (normalized.len == 0) null else normalized;
    }

    fn normalize_repository_name(name: []const u8) ?[]const u8 {
        const normalized = std.mem.trim(u8, name, " \t\r\n");
        if (normalized.len == 0 or equalIgnoreCase(normalized, "options")) return null;
        for (normalized) |character| {
            switch (character) {
                '[', ']', ' ', '\t', '\r', '\n' => return null,
                else => {},
            }
        }
        return normalized;
    }

    fn contains_package_name(package_names: []const [:0]const u8, needle: []const u8) bool {
        for (package_names) |package_name| {
            if (std.mem.eql(u8, package_name, needle)) return true;
        }
        return false;
    }

    fn contains_name(package_names: []const []const u8, needle: []const u8) bool {
        for (package_names) |package_name| {
            if (std.mem.eql(u8, package_name, needle)) return true;
        }
        return false;
    }

    fn config_section_name(line: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return null;
        return std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r");
    }

    fn is_package_directive_line(line: []const u8, directive: []const u8) bool {
        var trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len != 0 and trimmed[0] == '#') {
            trimmed = std.mem.trimStart(u8, trimmed[1..], " \t");
        }
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
        const key = std.mem.trim(u8, trimmed[0..equals], " \t");
        return equalIgnoreCase(key, directive);
    }

    fn append_config_line(
        output: *std.ArrayList(u8),
        allocator: Allocator,
        line: []const u8,
    ) Allocator.Error!void {
        try output.appendSlice(allocator, line);
        try output.append(allocator, '\n');
    }

    fn append_lines_skipping_directives(
        output: *std.ArrayList(u8),
        allocator: Allocator,
        lines: []const []const u8,
        start_index: usize,
        section: Section,
        directive: []const u8,
    ) PackageDirectiveError!void {
        for (lines, start_index..) |line, index| {
            if (section.contains_line(index) and is_package_directive_line(line, directive)) continue;
            try append_config_line(output, allocator, line);
        }
    }

    fn append_package_directive_line(
        output: *std.ArrayList(u8),
        allocator: Allocator,
        directive: []const u8,
        package_names: []const [:0]const u8,
    ) PackageDirectiveError!void {
        if (package_names.len == 0) {
            try output.append(allocator, '#');
            try output.appendSlice(allocator, directive);
            try output.appendSlice(allocator, " =\n");
            return;
        }

        try output.appendSlice(allocator, directive);
        try output.appendSlice(allocator, " = ");
        for (package_names, 0..) |package_name, index| {
            if (index != 0) try output.append(allocator, ' ');
            try output.appendSlice(allocator, package_name);
        }
        try output.append(allocator, '\n');
    }

    fn append_repository_section(
        output: *std.ArrayList(u8),
        allocator: Allocator,
        name: []const u8,
        servers: []const []const u8,
        sig_level: []const u8,
        usage: []const u8,
    ) Allocator.Error!void {
        try output.append(allocator, '[');
        try output.appendSlice(allocator, name);
        try output.append(allocator, ']');
        try output.append(allocator, '\n');

        if (sig_level.len != 0) {
            try output.appendSlice(allocator, "SigLevel = ");
            try append_config_line(output, allocator, sig_level);
        }
        if (usage.len != 0) {
            try output.appendSlice(allocator, "Usage = ");
            try append_config_line(output, allocator, usage);
        }
        for (servers) |server| {
            try output.appendSlice(allocator, "Server = ");
            try append_config_line(output, allocator, server);
        }
    }

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
        var level: u32 = 0;
        var it = std.mem.tokenizeScalar(u8, value, ' ');
        while (it.next()) |token| {
            var name = token;
            var package = true;
            var database = true;
            if (token.len >= 7 and equalIgnoreCase(token[0..7], "package")) {
                name = token[7..];
                database = false;
            } else if (token.len >= 8 and equalIgnoreCase(token[0..8], "database")) {
                name = token[8..];
                package = false;
            }

            if (equalIgnoreCase(name, "never")) {
                if (package) level &= ~sig(.{ .package = true });
                if (database) level &= ~sig(.{ .database = true });
            } else if (equalIgnoreCase(name, "optional")) {
                if (package) level |= sig(.{ .package = true }) | sig(.{ .package_optional = true });
                if (database) level |= sig(.{ .database = true }) | sig(.{ .database_optional = true });
            } else if (equalIgnoreCase(name, "required")) {
                if (package) {
                    level |= sig(.{ .package = true });
                    level &= ~sig(.{ .package_optional = true });
                }
                if (database) {
                    level |= sig(.{ .database = true });
                    level &= ~sig(.{ .database_optional = true });
                }
            } else if (equalIgnoreCase(name, "trustedonly")) {
                if (package) level &= ~(sig(.{ .package_marginal_ok = true }) | sig(.{ .package_unknown_ok = true }));
                if (database) level &= ~(sig(.{ .database_marginal_ok = true }) | sig(.{ .database_unknown_ok = true }));
            } else if (equalIgnoreCase(name, "trustall")) {
                if (package) level |= sig(.{ .package_marginal_ok = true }) | sig(.{ .package_unknown_ok = true });
                if (database) level |= sig(.{ .database_marginal_ok = true }) | sig(.{ .database_unknown_ok = true });
            }
            level &= ~sig(.{ .use_default = true });
        }
        return level;
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

        fn dupe(self: *Parser, s: []const u8) Allocator.Error![:0]const u8 {
            return self.arena_allocater.dupeSentinel(u8, s, 0);
        }

        fn add_split(self: *Parser, list: *std.ArrayList([:0]const u8), value: []const u8) Allocator.Error!void {
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
    try testing.expectEqual(sig(.{ .package = true }) | sig(.{ .database = true }) | sig(.{ .database_optional = true }), conf.signature_level);
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
    try testing.expectEqual(sig(.{ .package = true }) | sig(.{ .database = true }) | sig(.{ .database_optional = true }), conf.signature_level);
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
    try testing.expectEqual(sig(.{ .package = true }) | sig(.{ .database = true }) | sig(.{ .database_optional = true }), conf.signature_level);
    try testing.expectEqual(usageBit(.sync) | usageBit(.search), core.usage);

    const extra = conf.repositories.items[1];
    try testing.expectEqualStrings("extra", extra.name);
    try testing.expectEqual(@as(usize, 2), extra.servers.items.len);

    var names = try Configuration.get_repository_names(&conf, testing.allocator);
    defer names.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), names.items.len);
    try testing.expectEqualStrings("core", names.items[0]);
    try testing.expectEqualStrings("extra", names.items[1]);

    const found = Configuration.find_repository(&conf, "extra") orelse return error.TestFailed;
    try testing.expectEqualStrings("extra", found.name);
    try testing.expectEqual(@as(usize, 2), found.servers.items.len);
    try testing.expect(Configuration.find_repository(&conf, "missing") == null);
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

test "ignore package mutations normalize names and rewrite the options section" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/pacman.conf",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(config_path);

    const original =
        \\[options]
        \\Architecture = auto
        \\IgnorePkg = existing existing
        \\# IgnorePkg = stale
        \\[core]
        \\Server = https://example.invalid/$repo/os/$arch
        \\
    ;

    var file = try Io.Dir.cwd().createFile(testing.io, config_path, .{});
    try file.writeStreamingAll(testing.io, original);
    file.close(testing.io);

    var config = try Configuration.parse_string(testing.allocator, testing.io, original);
    defer config.deinitialize();

    const additions = [_][]const u8{ " linux ", "", "linux", "mesa" };
    try Configuration.add_ignore_packages(
        &config,
        testing.io,
        testing.allocator,
        config_path,
        &additions,
    );

    const after_add = try Io.Dir.cwd().readFileAlloc(
        testing.io,
        config_path,
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(after_add);
    try testing.expectEqualStrings(
        "[options]\n" ++
            "Architecture = auto\n" ++
            "IgnorePkg = existing linux mesa\n" ++
            "[core]\n" ++
            "Server = https://example.invalid/$repo/os/$arch\n",
        after_add,
    );

    var ignored = try Configuration.get_ignored_packages(&config, testing.allocator);
    defer ignored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), ignored.items.len);
    try testing.expectEqualStrings("existing", ignored.items[0]);
    try testing.expectEqualStrings("linux", ignored.items[1]);
    try testing.expectEqualStrings("mesa", ignored.items[2]);

    const removals = [_][]const u8{ " existing ", "linux", "linux", "mesa" };
    try Configuration.remove_ignore_packages(
        &config,
        testing.io,
        testing.allocator,
        config_path,
        &removals,
    );

    const after_remove = try Io.Dir.cwd().readFileAlloc(
        testing.io,
        config_path,
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(after_remove);
    try testing.expectEqualStrings(
        "[options]\n" ++
            "Architecture = auto\n" ++
            "#IgnorePkg =\n" ++
            "[core]\n" ++
            "Server = https://example.invalid/$repo/os/$arch\n",
        after_remove,
    );
}

test "adding an ignored package creates a missing options section" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/pacman.conf",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(config_path);

    const original = "[core]\nServer = https://example.invalid/$repo/os/$arch\n";
    var file = try Io.Dir.cwd().createFile(testing.io, config_path, .{});
    try file.writeStreamingAll(testing.io, original);
    file.close(testing.io);

    var config = try Configuration.parse_string(testing.allocator, testing.io, original);
    defer config.deinitialize();
    try Configuration.add_ignore_package(
        &config,
        testing.io,
        testing.allocator,
        config_path,
        "linux",
    );

    const rewritten = try Io.Dir.cwd().readFileAlloc(
        testing.io,
        config_path,
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(rewritten);
    try testing.expectEqualStrings(
        original ++ "[options]\nIgnorePkg = linux\n",
        rewritten,
    );
}

test "hold package mutations rewrite HoldPkg and preserve shelly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/pacman.conf",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(config_path);

    const original =
        \\[options]
        \\Architecture = auto
        \\HoldPkg = pacman glibc
    ;
    var file = try Io.Dir.cwd().createFile(testing.io, config_path, .{});
    try file.writeStreamingAll(testing.io, original);
    file.close(testing.io);

    var config = try Configuration.parse_string(testing.allocator, testing.io, original);
    defer config.deinitialize();
    try Configuration.add_hold_packages(
        &config,
        testing.io,
        testing.allocator,
        config_path,
        &.{ " linux ", "linux" },
    );

    var held = try Configuration.get_held_packages(&config, testing.allocator);
    defer held.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), held.items.len);
    try testing.expectEqualStrings("linux", held.items[3]);

    try Configuration.remove_hold_packages(
        &config,
        testing.io,
        testing.allocator,
        config_path,
        &.{ "pacman", "glibc", "linux", "shelly" },
    );

    var remaining = try Configuration.get_held_packages(&config, testing.allocator);
    defer remaining.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), remaining.items.len);
    try testing.expectEqualStrings("shelly", remaining.items[0]);

    const rewritten = try Io.Dir.cwd().readFileAlloc(
        testing.io,
        config_path,
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(rewritten);
    try testing.expectEqualStrings(
        "[options]\nArchitecture = auto\nHoldPkg = shelly\n",
        rewritten,
    );
}

test "add_repository appends a repository section to the config file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/pacman.conf",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(config_path);

    const original =
        \\[options]
        \\Architecture = auto
    ;
    var file = try Io.Dir.cwd().createFile(testing.io, config_path, .{});
    try file.writeStreamingAll(testing.io, original);
    file.close(testing.io);

    var config = try Configuration.parse_string(testing.allocator, testing.io, original);
    defer config.deinitialize();

    try Configuration.add_repository(
        &config,
        testing.io,
        testing.allocator,
        config_path,
        "core",
        &.{ "https://mirror.a/$repo/os/$arch", " https://mirror.b/$repo/os/$arch " },
        "Required DatabaseOptional",
        "Sync Search",
    );

    const rewritten = try Io.Dir.cwd().readFileAlloc(
        testing.io,
        config_path,
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(rewritten);
    try testing.expectEqualStrings(
        "[options]\n" ++
            "Architecture = auto\n" ++
            "[core]\n" ++
            "SigLevel = Required DatabaseOptional\n" ++
            "Usage = Sync Search\n" ++
            "Server = https://mirror.a/$repo/os/$arch\n" ++
            "Server = https://mirror.b/$repo/os/$arch\n",
        rewritten,
    );

    const repository = Configuration.find_repository(&config, "core") orelse return error.TestFailed;
    try testing.expectEqual(@as(usize, 2), repository.servers.items.len);
    try testing.expectEqualStrings("https://mirror.b/$repo/os/$arch", repository.servers.items[1]);
    try testing.expectEqual(Configuration.parse_signature_level("Required DatabaseOptional"), repository.sig_level);
    try testing.expectEqual(usageBit(.sync) | usageBit(.search), repository.usage);
}

test "add_repository rejects duplicate and invalid repository names" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/pacman.conf",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(config_path);

    const original = "[options]\n";
    var file = try Io.Dir.cwd().createFile(testing.io, config_path, .{});
    try file.writeStreamingAll(testing.io, original);
    file.close(testing.io);

    var config = try Configuration.parse_string(testing.allocator, testing.io, original);
    defer config.deinitialize();

    try Configuration.add_repository(
        &config,
        testing.io,
        testing.allocator,
        config_path,
        " core ",
        &.{"https://mirror.a/core"},
        "",
        "",
    );

    try testing.expectError(
        RepositoryError.DuplicateRepository,
        Configuration.add_repository(
            &config,
            testing.io,
            testing.allocator,
            config_path,
            "core",
            &.{"https://mirror.b/core"},
            "",
            "",
        ),
    );

    const invalid_names = [_][]const u8{ "", "   ", "options", "OPTIONS", "core repo", "co[re" };
    for (invalid_names) |invalid_name| {
        try testing.expectError(
            RepositoryError.InvalidRepositoryName,
            Configuration.add_repository(
                &config,
                testing.io,
                testing.allocator,
                config_path,
                invalid_name,
                &.{"https://mirror.a/core"},
                "",
                "",
            ),
        );
    }

    try testing.expectEqual(@as(usize, 1), config.repositories.items.len);

    const rewritten = try Io.Dir.cwd().readFileAlloc(
        testing.io,
        config_path,
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(rewritten);
    try testing.expectEqualStrings(
        "[options]\n[core]\nServer = https://mirror.a/core\n",
        rewritten,
    );
}

test "add_repository omits empty siglevel and usage directives" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/pacman.conf",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(config_path);

    const original = "[options]\n";
    var file = try Io.Dir.cwd().createFile(testing.io, config_path, .{});
    try file.writeStreamingAll(testing.io, original);
    file.close(testing.io);

    var config = try Configuration.parse_string(testing.allocator, testing.io, original);
    defer config.deinitialize();

    try Configuration.add_repository(
        &config,
        testing.io,
        testing.allocator,
        config_path,
        "extra",
        &.{" https://mirror.a/extra "},
        "",
        "",
    );

    const rewritten = try Io.Dir.cwd().readFileAlloc(
        testing.io,
        config_path,
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(rewritten);
    try testing.expectEqualStrings(
        "[options]\n[extra]\nServer = https://mirror.a/extra\n",
        rewritten,
    );

    const repository = Configuration.find_repository(&config, "extra") orelse return error.TestFailed;
    try testing.expectEqual(sig(.{ .use_default = true }), repository.sig_level);
    try testing.expectEqual(@as(u32, 0), repository.usage);
    try testing.expectEqualStrings("https://mirror.a/extra", repository.servers.items[0]);
}

test "remove_repository deletes only the matching section" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/pacman.conf",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(config_path);

    const original =
        \\[options]
        \\Architecture = auto
        \\
        \\[core]
        \\Server = https://mirror.a/core
        \\
        \\[extra]
        \\Server = https://mirror.a/extra
        \\
    ;
    var file = try Io.Dir.cwd().createFile(testing.io, config_path, .{});
    try file.writeStreamingAll(testing.io, original);
    file.close(testing.io);

    var config = try Configuration.parse_string(testing.allocator, testing.io, original);
    defer config.deinitialize();

    try Configuration.remove_repository(
        &config,
        testing.io,
        testing.allocator,
        config_path,
        "core",
    );

    const after_first = try Io.Dir.cwd().readFileAlloc(
        testing.io,
        config_path,
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(after_first);
    try testing.expectEqualStrings(
        "[options]\n" ++
            "Architecture = auto\n" ++
            "\n" ++
            "[extra]\n" ++
            "Server = https://mirror.a/extra\n",
        after_first,
    );
    try testing.expect(Configuration.find_repository(&config, "core") == null);
    try testing.expect(Configuration.find_repository(&config, "extra") != null);

    try Configuration.remove_repository(
        &config,
        testing.io,
        testing.allocator,
        config_path,
        "extra",
    );

    const after_second = try Io.Dir.cwd().readFileAlloc(
        testing.io,
        config_path,
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(after_second);
    try testing.expectEqualStrings(
        "[options]\nArchitecture = auto\n",
        after_second,
    );
    try testing.expectEqual(@as(usize, 0), config.repositories.items.len);
}

test "remove_repository is a no-op for unknown repositories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/pacman.conf",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(config_path);

    const original =
        \\[options]
        \\[core]
        \\Server = https://mirror.a/core
        \\
    ;
    var file = try Io.Dir.cwd().createFile(testing.io, config_path, .{});
    try file.writeStreamingAll(testing.io, original);
    file.close(testing.io);

    var config = try Configuration.parse_string(testing.allocator, testing.io, original);
    defer config.deinitialize();

    try Configuration.remove_repository(
        &config,
        testing.io,
        testing.allocator,
        config_path,
        "missing",
    );
    try testing.expectError(
        RepositoryError.InvalidRepositoryName,
        Configuration.remove_repository(
            &config,
            testing.io,
            testing.allocator,
            config_path,
            "options",
        ),
    );

    try testing.expectEqual(@as(usize, 1), config.repositories.items.len);

    const rewritten = try Io.Dir.cwd().readFileAlloc(
        testing.io,
        config_path,
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(rewritten);
    try testing.expectEqualStrings(original, rewritten);
}
