//! Discovery and maintenance of pacman `.pacnew`, `.pacorig`, and `.pacsave`
//! files.
//!
//! The manager contains the non-interactive parts of `pacdiff`. A frontend can
//! use `discover` to present its own prompt, then call the file, diff, or merge
//! operations below. Paths returned by this module are owned by the caller.

const std = @import("std");
const cache_manager = @import("cache_manager.zig");
const alpm_manager = @import("manager.zig");
const configuration = @import("configuration.zig");

const default_find_paths = [_][]const u8{"/etc"};
const default_diff_program = [_][]const u8{ "vim", "-d" };
const default_merge_program = [_][]const u8{ "diff3", "-m" };
const locate_patterns = [_][]const u8{ "*.pacnew", "*.pacorig", "*.pacsave", "*.pacsave.[0-9]*" };
const max_backup_database_file_size = 64 * 1024 * 1024;
var temporary_directory_counter: std.atomic.Value(u64) = .init(0);

pub const Error = error{
    OutOfMemory,
    InvalidPacfile,
    InvalidConfiguredPath,
    DirectoryReadFailed,
    DatabaseReadFailed,
    FileReadFailed,
    FileWriteFailed,
    FileRemovalFailed,
    FileMoveFailed,
    OriginalMissing,
    LocateFailed,
    ToolFailed,
    ProcessOutputTooLarge,
    PackageOwnerNotFound,
    BaseArchiveNotFound,
    BaseExtractionFailed,
    TemporaryFileFailed,
    MergeFailed,
};

pub const SearchMode = enum {
    /// Search only paths recorded below `%BACKUP%` in the local pacman DB.
    pacman_database,
    /// Recursively walk `Options.find_paths`.
    find,
    /// Ask `locate` for each pacfile pattern.
    locate,
};

pub const Kind = enum {
    pacnew,
    pacorig,
    pacsave,
    numbered_pacsave,
};

pub const State = enum {
    original_missing,
    identical,
    different,
};

pub const DiffMode = enum {
    two_way,
    three_way,
};

pub const ParsedPath = struct {
    original_path: []const u8,
    kind: Kind,
    save_number: ?u64 = null,
};

/// Classifies a pacfile path without allocating. Numbered saves are accepted
/// only when the suffix after `.pacsave.` consists entirely of decimal digits.
pub fn parsePacfilePath(path: []const u8) ?ParsedPath {
    if (std.mem.endsWith(u8, path, ".pacnew")) {
        return .{ .original_path = path[0 .. path.len - ".pacnew".len], .kind = .pacnew };
    }
    if (std.mem.endsWith(u8, path, ".pacorig")) {
        return .{ .original_path = path[0 .. path.len - ".pacorig".len], .kind = .pacorig };
    }
    if (std.mem.endsWith(u8, path, ".pacsave")) {
        return .{ .original_path = path[0 .. path.len - ".pacsave".len], .kind = .pacsave };
    }
    const marker = ".pacsave.";
    const marker_index = std.mem.lastIndexOf(u8, path, marker) orelse return null;
    const number_text = path[marker_index + marker.len ..];
    if (number_text.len == 0) return null;
    for (number_text) |character| if (!std.ascii.isDigit(character)) return null;
    return .{
        .original_path = path[0..marker_index],
        .kind = .numbered_pacsave,
        // pacdiff accepts any run of decimal digits. Keep classifying values
        // larger than u64; callers simply do not get a numeric convenience
        // value for those unusually large suffixes.
        .save_number = std.fmt.parseUnsigned(u64, number_text, 10) catch null,
    };
}

pub const Pacfile = struct {
    path: []u8,
    original_path: []u8,
    kind: Kind,
    save_number: ?u64,

    pub fn deinit(self: *Pacfile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.original_path);
        self.* = undefined;
    }

    pub fn deinitSlice(allocator: std.mem.Allocator, files: []Pacfile) void {
        for (files) |*file| file.deinit(allocator);
        allocator.free(files);
    }
};

pub const Options = struct {
    root_directory: []const u8 = "/",
    database_path: []const u8 = "/var/lib/pacman",
    cache_directory: []const u8 = "/var/cache/pacman/pkg",
    additional_cache_directories: []const []const u8 = &.{},
    find_paths: []const []const u8 = &default_find_paths,
    temporary_directory: []const u8 = "/tmp",
    locate_command: []const u8 = "locate",
    pacman_command: []const u8 = "pacman",
    bsdtar_command: []const u8 = "bsdtar",
    diff_program: []const []const u8 = &default_diff_program,
    merge_program: []const []const u8 = &default_merge_program,
    max_process_output: usize = 64 * 1024 * 1024,
};

pub const ToolResult = struct {
    term: std.process.Child.Term,

    pub fn successful(self: ToolResult) bool {
        return switch (self.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

pub const ViewResult = struct {
    tool: ToolResult,
    used_mode: DiffMode,
    fell_back_to_two_way: bool,
    removed_identical_pacfile: bool,
};

/// A merge is deliberately prepared separately from applying it. This lets a
/// frontend show `original_path` versus `merged_path` and ask for confirmation,
/// matching pacdiff without putting terminal prompting in this library.
pub const PreparedMerge = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []u8,
    original_path: []u8,
    pacfile_path: []u8,
    base_path: []u8,
    merged_path: []u8,
    has_conflicts: bool,
    applied: bool = false,
    preserve_workspace: bool = false,

    pub fn deinit(self: *PreparedMerge) void {
        if (!self.preserve_workspace)
            std.Io.Dir.cwd().deleteTree(self.io, self.workspace_path) catch {};
        self.allocator.free(self.workspace_path);
        self.allocator.free(self.original_path);
        self.allocator.free(self.pacfile_path);
        self.allocator.free(self.base_path);
        self.allocator.free(self.merged_path);
        self.* = undefined;
    }

    /// Keeps the staged base and merge result on disk when `deinit` is called.
    /// This is useful after a failed apply so the reviewed merge is not lost.
    pub fn preserveWorkspace(self: *PreparedMerge) void {
        self.preserve_workspace = true;
    }
};

pub const PacfileManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) PacfileManager {
        return .{ .allocator = allocator, .io = io, .options = options };
    }

    pub fn initFromConfiguration(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: *const configuration.Configuration.Config,
    ) PacfileManager {
        return init(allocator, io, .{
            .root_directory = config.root_directory,
            .database_path = config.database_path,
            .cache_directory = config.cache_directory,
        });
    }

    /// Returns a sorted, deduplicated, owned list. This is also the data needed
    /// for pacdiff's `--output` behavior.
    pub fn discover(self: *PacfileManager, mode: SearchMode) Error![]Pacfile {
        var files: std.ArrayList(Pacfile) = .empty;
        errdefer deinitList(self.allocator, &files);
        switch (mode) {
            .pacman_database => try self.discoverPacmanDatabase(&files),
            .find => try self.discoverFind(&files),
            .locate => try self.discoverLocate(&files),
        }
        std.mem.sort(Pacfile, files.items, {}, pacfileLessThan);
        return files.toOwnedSlice(self.allocator) catch return Error.OutOfMemory;
    }

    pub fn state(self: *const PacfileManager, pacfile: Pacfile) Error!State {
        if (!try self.fileExists(pacfile.original_path)) return .original_missing;
        return if (try self.filesEqual(pacfile.path, pacfile.original_path)) .identical else .different;
    }

    pub fn remove(self: *const PacfileManager, pacfile: Pacfile) Error!void {
        std.Io.Dir.cwd().deleteFile(self.io, pacfile.path) catch return Error.FileRemovalFailed;
    }

    /// Removes the sidecar only when it has the same contents as the original.
    pub fn removeIfIdentical(self: *const PacfileManager, pacfile: Pacfile) Error!bool {
        if (try self.state(pacfile) != .identical) return false;
        try self.remove(pacfile);
        return true;
    }

    /// Replaces the original with the pacfile. When requested, the old original
    /// is first copied to `<original>.bak`, preserving its permissions.
    pub fn overwrite(self: *const PacfileManager, pacfile: Pacfile, backup: bool) Error!void {
        if (!try self.fileExists(pacfile.original_path)) return Error.OriginalMissing;
        if (backup) try self.backupOriginal(pacfile.original_path);
        std.Io.Dir.rename(.cwd(), pacfile.path, .cwd(), pacfile.original_path, self.io) catch
            return Error.FileMoveFailed;
    }

    pub fn viewDiff(
        self: *PacfileManager,
        pacfile: Pacfile,
        requested_mode: DiffMode,
    ) Error!ViewResult {
        if (!try self.fileExists(pacfile.original_path)) return Error.OriginalMissing;
        var mode = requested_mode;
        var fell_back = false;
        var workspace: ?[]u8 = null;
        defer if (workspace) |path| {
            std.Io.Dir.cwd().deleteTree(self.io, path) catch {};
            self.allocator.free(path);
        };

        var base_path: ?[]u8 = null;
        defer if (base_path) |path| self.allocator.free(path);
        if (mode == .three_way) {
            base_path = self.prepareBaseFile(pacfile.original_path, "diff") catch |err| switch (err) {
                Error.PackageOwnerNotFound, Error.BaseArchiveNotFound, Error.BaseExtractionFailed => blk: {
                    mode = .two_way;
                    fell_back = true;
                    break :blk null;
                },
                else => return err,
            };
            if (base_path) |path| workspace = self.allocator.dupe(u8, std.fs.path.dirname(path).?) catch return Error.OutOfMemory;
        }

        const term = if (mode == .three_way)
            try self.runInteractiveTool(self.options.diff_program, &.{ pacfile.path, base_path.?, pacfile.original_path })
        else
            try self.runInteractiveTool(self.options.diff_program, &.{ pacfile.path, pacfile.original_path });

        const removed = try self.removeIfIdentical(pacfile);
        return .{
            .tool = .{ .term = term },
            .used_mode = mode,
            .fell_back_to_two_way = fell_back,
            .removed_identical_pacfile = removed,
        };
    }

    /// Creates the three-way merge result but does not modify either input.
    /// Exit status 1 from diff3-style tools is retained as a conflicted result.
    pub fn prepareMerge(self: *PacfileManager, pacfile: Pacfile) Error!PreparedMerge {
        if (!try self.fileExists(pacfile.original_path)) return Error.OriginalMissing;
        const base_path = try self.prepareBaseFile(pacfile.original_path, "merge");
        errdefer {
            const workspace = std.fs.path.dirname(base_path).?;
            std.Io.Dir.cwd().deleteTree(self.io, workspace) catch {};
            self.allocator.free(base_path);
        }
        const workspace = std.fs.path.dirname(base_path).?;
        const merged_path = std.fs.path.join(self.allocator, &.{ workspace, "merged" }) catch return Error.OutOfMemory;
        errdefer self.allocator.free(merged_path);

        const merge_argv = try self.toolArgv(
            self.options.merge_program,
            &.{ pacfile.original_path, base_path, pacfile.path },
        );
        defer self.allocator.free(merge_argv);
        const result = std.process.run(self.allocator, self.io, .{
            .argv = merge_argv,
            .stdout_limit = .limited(self.options.max_process_output),
            .stderr_limit = .limited(self.options.max_process_output),
        }) catch |err| switch (err) {
            error.StreamTooLong => return Error.ProcessOutputTooLarge,
            else => return Error.MergeFailed,
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => return Error.MergeFailed,
        };
        if (exit_code > 1) return Error.MergeFailed;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = merged_path, .data = result.stdout }) catch
            return Error.TemporaryFileFailed;

        const owned_workspace = self.allocator.dupe(u8, workspace) catch return Error.OutOfMemory;
        errdefer self.allocator.free(owned_workspace);
        const original_path = self.allocator.dupe(u8, pacfile.original_path) catch return Error.OutOfMemory;
        errdefer self.allocator.free(original_path);
        const pacfile_path = self.allocator.dupe(u8, pacfile.path) catch return Error.OutOfMemory;
        errdefer self.allocator.free(pacfile_path);
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .workspace_path = owned_workspace,
            .original_path = original_path,
            .pacfile_path = pacfile_path,
            .base_path = base_path,
            .merged_path = merged_path,
            .has_conflicts = exit_code == 1,
        };
    }

    pub fn viewPreparedMerge(self: *PacfileManager, merge: *const PreparedMerge) Error!ToolResult {
        return .{ .term = try self.runInteractiveTool(
            self.options.diff_program,
            &.{ merge.original_path, merge.merged_path },
        ) };
    }

    /// Applies a previously reviewed merge and removes its pacfile. The caller
    /// must still call `PreparedMerge.deinit`, whether this succeeds or fails.
    pub fn applyPreparedMerge(
        self: *const PacfileManager,
        merge: *PreparedMerge,
        backup: bool,
    ) Error!void {
        if (merge.applied) return;
        if (backup) try self.backupOriginal(merge.original_path);
        const stat = std.Io.Dir.cwd().statFile(self.io, merge.original_path, .{}) catch
            return Error.FileReadFailed;
        std.Io.Dir.copyFile(
            .cwd(),
            merge.merged_path,
            .cwd(),
            merge.original_path,
            self.io,
            .{ .permissions = stat.permissions },
        ) catch return Error.FileWriteFailed;
        std.Io.Dir.cwd().deleteFile(self.io, merge.pacfile_path) catch return Error.FileRemovalFailed;
        merge.applied = true;
    }

    /// Finds the second-newest cached archive for a package, matching the base
    /// selection used by pacdiff. The returned path is owned by the caller.
    pub fn findBaseArchive(self: *PacfileManager, package_name: []const u8) Error![]u8 {
        var entries: std.ArrayList(cache_manager.Entry) = .empty;
        defer {
            for (entries.items) |*entry| entry.deinit(self.allocator);
            entries.deinit(self.allocator);
        }
        try self.collectCacheEntries(self.options.cache_directory, package_name, &entries);
        for (self.options.additional_cache_directories) |directory| {
            try self.collectCacheEntries(directory, package_name, &entries);
        }
        if (entries.items.len < 2) return Error.BaseArchiveNotFound;
        std.mem.sort(cache_manager.Entry, entries.items, {}, cacheEntryNewerThan);
        return self.allocator.dupe(u8, entries.items[1].full_path) catch return Error.OutOfMemory;
    }

    fn discoverPacmanDatabase(self: *PacfileManager, files: *std.ArrayList(Pacfile)) Error!void {
        const local_path = std.fs.path.join(self.allocator, &.{ self.options.database_path, "local" }) catch
            return Error.OutOfMemory;
        defer self.allocator.free(local_path);
        var local = std.Io.Dir.cwd().openDir(self.io, local_path, .{ .iterate = true }) catch
            return Error.DirectoryReadFailed;
        defer local.close(self.io);
        var iterator = local.iterate();
        while (iterator.next(self.io) catch return Error.DatabaseReadFailed) |package| {
            if (package.kind != .directory) continue;
            const backup_file = std.fs.path.join(self.allocator, &.{ local_path, package.name, "files" }) catch
                return Error.OutOfMemory;
            defer self.allocator.free(backup_file);
            const contents = std.Io.Dir.cwd().readFileAlloc(
                self.io,
                backup_file,
                self.allocator,
                .limited(max_backup_database_file_size),
            ) catch |err| switch (err) {
                error.FileNotFound => continue,
                error.StreamTooLong => return Error.DatabaseReadFailed,
                else => return Error.DatabaseReadFailed,
            };
            defer self.allocator.free(contents);
            try self.addBackupRecords(files, contents);
        }
    }

    fn addBackupRecords(self: *PacfileManager, files: *std.ArrayList(Pacfile), contents: []const u8) Error!void {
        var lines = std.mem.splitScalar(u8, contents, '\n');
        var in_backup_section = false;
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (!in_backup_section) {
                if (std.mem.eql(u8, line, "%BACKUP%")) in_backup_section = true;
                continue;
            }
            if (line.len == 0) break;
            const separator = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
            const relative_path = line[0..separator];
            if (!safeRelativePath(relative_path)) continue;
            const original = try self.rootedPath(relative_path);
            defer self.allocator.free(original);
            inline for (.{ ".pacnew", ".pacorig", ".pacsave" }) |suffix| {
                const candidate = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ original, suffix }) catch
                    return Error.OutOfMemory;
                defer self.allocator.free(candidate);
                if (self.discoverableFileExists(candidate)) try addUnique(self.allocator, files, candidate);
            }
            try self.addNumberedSaves(files, original);
        }
    }

    fn addNumberedSaves(
        self: *PacfileManager,
        files: *std.ArrayList(Pacfile),
        original_path: []const u8,
    ) Error!void {
        const parent = std.fs.path.dirname(original_path) orelse return;
        const prefix = std.fmt.allocPrint(self.allocator, "{s}.pacsave.", .{std.fs.path.basename(original_path)}) catch
            return Error.OutOfMemory;
        defer self.allocator.free(prefix);
        var directory = std.Io.Dir.cwd().openDir(self.io, parent, .{ .iterate = true }) catch return;
        defer directory.close(self.io);
        var iterator = directory.iterate();
        while (iterator.next(self.io) catch return Error.DirectoryReadFailed) |entry| {
            if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, prefix)) continue;
            const number = entry.name[prefix.len..];
            if (!isDecimal(number)) continue;
            const path = std.fs.path.join(self.allocator, &.{ parent, entry.name }) catch return Error.OutOfMemory;
            defer self.allocator.free(path);
            try addUnique(self.allocator, files, path);
        }
    }

    fn discoverFind(self: *PacfileManager, files: *std.ArrayList(Pacfile)) Error!void {
        for (self.options.find_paths) |search_path| {
            const stat = std.Io.Dir.cwd().statFile(self.io, search_path, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return Error.DirectoryReadFailed,
            };
            if (stat.kind == .file) {
                if (parsePacfilePath(search_path) != null) try addUnique(self.allocator, files, search_path);
                continue;
            }
            if (stat.kind != .directory) continue;
            var directory = std.Io.Dir.cwd().openDir(self.io, search_path, .{ .iterate = true }) catch
                return Error.DirectoryReadFailed;
            defer directory.close(self.io);
            var walker = directory.walk(self.allocator) catch return Error.OutOfMemory;
            defer walker.deinit();
            while (walker.next(self.io) catch return Error.DirectoryReadFailed) |entry| {
                if (entry.kind != .file or parsePacfilePath(entry.basename) == null) continue;
                const path = std.fs.path.join(self.allocator, &.{ search_path, entry.path }) catch
                    return Error.OutOfMemory;
                defer self.allocator.free(path);
                try addUnique(self.allocator, files, path);
            }
        }
    }

    fn discoverLocate(self: *PacfileManager, files: *std.ArrayList(Pacfile)) Error!void {
        // Separate invocations work with both plocate's AND pattern behavior and
        // mlocate's OR behavior.
        for (locate_patterns) |pattern| {
            const result = std.process.run(self.allocator, self.io, .{
                .argv = &.{ self.options.locate_command, "-0", "-e", "-b", pattern },
                .stdout_limit = .limited(self.options.max_process_output),
                .stderr_limit = .limited(self.options.max_process_output),
            }) catch |err| switch (err) {
                error.StreamTooLong => return Error.ProcessOutputTooLarge,
                else => return Error.LocateFailed,
            };
            defer self.allocator.free(result.stdout);
            defer self.allocator.free(result.stderr);
            const code = switch (result.term) {
                .exited => |exit_code| exit_code,
                else => return Error.LocateFailed,
            };
            if (code > 1) return Error.LocateFailed;
            var paths = std.mem.tokenizeAny(u8, result.stdout, "\x00\r\n");
            while (paths.next()) |path| {
                if (parsePacfilePath(path) == null) continue;
                if (self.discoverableFileExists(path)) try addUnique(self.allocator, files, path);
            }
        }
    }

    fn prepareBaseFile(self: *PacfileManager, original_path: []const u8, purpose: []const u8) Error![]u8 {
        const package = try self.packageOwner(original_path);
        defer self.allocator.free(package);
        const archive = try self.findBaseArchive(package);
        defer self.allocator.free(archive);
        const workspace = try self.makeTemporaryDirectory(purpose);
        errdefer {
            std.Io.Dir.cwd().deleteTree(self.io, workspace) catch {};
            self.allocator.free(workspace);
        }
        const base_path = std.fs.path.join(self.allocator, &.{ workspace, "base" }) catch
            return Error.OutOfMemory;
        errdefer self.allocator.free(base_path);
        const logical_path = try self.logicalPath(original_path);
        defer self.allocator.free(logical_path);
        const member = std.mem.trimStart(u8, logical_path, "/");
        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{ self.options.bsdtar_command, "-xqOf", archive, member },
            .stdout_limit = .limited(self.options.max_process_output),
            .stderr_limit = .limited(self.options.max_process_output),
        }) catch |err| switch (err) {
            error.StreamTooLong => return Error.ProcessOutputTooLarge,
            else => return Error.BaseExtractionFailed,
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return Error.BaseExtractionFailed,
            else => return Error.BaseExtractionFailed,
        }
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = base_path, .data = result.stdout }) catch
            return Error.TemporaryFileFailed;
        self.allocator.free(workspace);
        return base_path;
    }

    fn packageOwner(self: *PacfileManager, original_path: []const u8) Error![]u8 {
        const logical_path = try self.logicalPath(original_path);
        defer self.allocator.free(logical_path);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        argv.append(self.allocator, self.options.pacman_command) catch return Error.OutOfMemory;
        if (!std.mem.eql(u8, self.options.root_directory, "/")) {
            argv.appendSlice(self.allocator, &.{ "--root", self.options.root_directory, "--dbpath", self.options.database_path }) catch
                return Error.OutOfMemory;
        }
        argv.appendSlice(self.allocator, &.{ "-Qoq", logical_path }) catch return Error.OutOfMemory;
        const result = std.process.run(self.allocator, self.io, .{
            .argv = argv.items,
            .stdout_limit = .limited(self.options.max_process_output),
            .stderr_limit = .limited(self.options.max_process_output),
        }) catch |err| switch (err) {
            error.StreamTooLong => return Error.ProcessOutputTooLarge,
            else => return Error.PackageOwnerNotFound,
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return Error.PackageOwnerNotFound,
            else => return Error.PackageOwnerNotFound,
        }
        const owner = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (owner.len == 0 or std.mem.indexOfAny(u8, owner, " \t\r\n") != null)
            return Error.PackageOwnerNotFound;
        return self.allocator.dupe(u8, owner) catch return Error.OutOfMemory;
    }

    fn collectCacheEntries(
        self: *PacfileManager,
        directory_path: []const u8,
        package_name: []const u8,
        entries: *std.ArrayList(cache_manager.Entry),
    ) Error!void {
        var directory = std.Io.Dir.cwd().openDir(self.io, directory_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return Error.DirectoryReadFailed,
        };
        defer directory.close(self.io);
        var iterator = directory.iterate();
        while (iterator.next(self.io) catch return Error.DirectoryReadFailed) |item| {
            if (item.kind != .file) continue;
            const path = std.fs.path.join(self.allocator, &.{ directory_path, item.name }) catch
                return Error.OutOfMemory;
            defer self.allocator.free(path);
            var parsed = (cache_manager.parsePackageFilename(self.allocator, path, 0) catch
                return Error.OutOfMemory) orelse continue;
            if (!std.mem.eql(u8, parsed.name, package_name)) {
                parsed.deinit(self.allocator);
                continue;
            }
            entries.append(self.allocator, parsed) catch {
                parsed.deinit(self.allocator);
                return Error.OutOfMemory;
            };
        }
    }

    fn backupOriginal(self: *const PacfileManager, original_path: []const u8) Error!void {
        const backup_path = std.fmt.allocPrint(self.allocator, "{s}.bak", .{original_path}) catch
            return Error.OutOfMemory;
        defer self.allocator.free(backup_path);
        std.Io.Dir.copyFile(.cwd(), original_path, .cwd(), backup_path, self.io, .{}) catch
            return Error.FileWriteFailed;
    }

    fn filesEqual(self: *const PacfileManager, left_path: []const u8, right_path: []const u8) Error!bool {
        var left = std.Io.Dir.cwd().openFile(self.io, left_path, .{}) catch return Error.FileReadFailed;
        defer left.close(self.io);
        var right = std.Io.Dir.cwd().openFile(self.io, right_path, .{}) catch return Error.FileReadFailed;
        defer right.close(self.io);
        const left_stat = left.stat(self.io) catch return Error.FileReadFailed;
        const right_stat = right.stat(self.io) catch return Error.FileReadFailed;
        if (left_stat.size != right_stat.size) return false;
        var left_reader = left.reader(self.io, &.{});
        var right_reader = right.reader(self.io, &.{});
        var left_buffer: [64 * 1024]u8 = undefined;
        var right_buffer: [64 * 1024]u8 = undefined;
        while (true) {
            const left_amount = left_reader.interface.readSliceShort(&left_buffer) catch return Error.FileReadFailed;
            const right_amount = right_reader.interface.readSliceShort(&right_buffer) catch return Error.FileReadFailed;
            if (left_amount != right_amount) return false;
            if (!std.mem.eql(u8, left_buffer[0..left_amount], right_buffer[0..right_amount])) return false;
            if (left_amount == 0) return true;
        }
    }

    fn fileExists(self: *const PacfileManager, path: []const u8) Error!bool {
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return Error.FileReadFailed,
        };
        return stat.kind == .file;
    }

    /// Discovery mirrors shell `[[ -f path ]]`: inaccessible, dangling, and
    /// otherwise unstatable candidates are simply not emitted.
    fn discoverableFileExists(self: *const PacfileManager, path: []const u8) bool {
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
        return stat.kind == .file;
    }

    fn rootedPath(self: *PacfileManager, relative_path: []const u8) Error![]u8 {
        if (!safeRelativePath(relative_path)) return Error.InvalidConfiguredPath;
        return std.fs.path.join(self.allocator, &.{ self.options.root_directory, relative_path }) catch
            return Error.OutOfMemory;
    }

    fn logicalPath(self: *PacfileManager, host_path: []const u8) Error![]u8 {
        const root = std.mem.trimEnd(u8, self.options.root_directory, "/");
        if (root.len == 0) {
            if (!std.fs.path.isAbsolute(host_path)) return Error.InvalidConfiguredPath;
            return self.allocator.dupe(u8, host_path) catch return Error.OutOfMemory;
        }
        if (host_path.len <= root.len or !std.mem.startsWith(u8, host_path, root) or host_path[root.len] != '/')
            return Error.InvalidConfiguredPath;
        return self.allocator.dupe(u8, host_path[root.len..]) catch return Error.OutOfMemory;
    }

    fn makeTemporaryDirectory(self: *PacfileManager, purpose: []const u8) Error![]u8 {
        std.Io.Dir.cwd().createDirPath(self.io, self.options.temporary_directory) catch
            return Error.TemporaryFileFailed;
        const counter = temporary_directory_counter.fetchAdd(1, .monotonic);
        const timestamp = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        const path = std.fmt.allocPrint(
            self.allocator,
            "{s}/shelly-pacfile-{s}-{d}-{x}",
            .{ std.mem.trimEnd(u8, self.options.temporary_directory, "/"), purpose, timestamp, counter },
        ) catch return Error.OutOfMemory;
        errdefer self.allocator.free(path);
        std.Io.Dir.cwd().createDir(self.io, path, .default_dir) catch return Error.TemporaryFileFailed;
        return path;
    }

    fn runInteractiveTool(
        self: *PacfileManager,
        program: []const []const u8,
        arguments: []const []const u8,
    ) Error!std.process.Child.Term {
        const argv = try self.toolArgv(program, arguments);
        defer self.allocator.free(argv);
        var process = std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch return Error.ToolFailed;
        return process.wait(self.io) catch return Error.ToolFailed;
    }

    fn toolArgv(
        self: *PacfileManager,
        program: []const []const u8,
        arguments: []const []const u8,
    ) Error![]const []const u8 {
        if (program.len == 0) return Error.ToolFailed;
        const argv = self.allocator.alloc([]const u8, program.len + arguments.len) catch
            return Error.OutOfMemory;
        @memcpy(argv[0..program.len], program);
        @memcpy(argv[program.len..], arguments);
        return argv;
    }
};

pub const Manager = PacfileManager;

fn addUnique(allocator: std.mem.Allocator, files: *std.ArrayList(Pacfile), path: []const u8) Error!void {
    for (files.items) |file| if (std.mem.eql(u8, file.path, path)) return;
    const parsed = parsePacfilePath(path) orelse return Error.InvalidPacfile;
    const owned_path = allocator.dupe(u8, path) catch return Error.OutOfMemory;
    errdefer allocator.free(owned_path);
    const original = allocator.dupe(u8, parsed.original_path) catch return Error.OutOfMemory;
    errdefer allocator.free(original);
    files.append(allocator, .{
        .path = owned_path,
        .original_path = original,
        .kind = parsed.kind,
        .save_number = parsed.save_number,
    }) catch return Error.OutOfMemory;
}

fn deinitList(allocator: std.mem.Allocator, files: *std.ArrayList(Pacfile)) void {
    for (files.items) |*file| file.deinit(allocator);
    files.deinit(allocator);
}

fn pacfileLessThan(_: void, left: Pacfile, right: Pacfile) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}

fn cacheEntryNewerThan(_: void, left: cache_manager.Entry, right: cache_manager.Entry) bool {
    const order = alpm_manager.Manager.compare_package_versions(left.version_release, right.version_release);
    if (order != 0) return order > 0;
    return std.mem.order(u8, left.full_path, right.full_path) == .lt;
}

fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn isDecimal(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |character| if (!std.ascii.isDigit(character)) return false;
    return true;
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "pacfile paths distinguish regular and numbered saves" {
    const pacnew = parsePacfilePath("/etc/example.conf.pacnew").?;
    try testing.expectEqual(Kind.pacnew, pacnew.kind);
    try testing.expectEqualStrings("/etc/example.conf", pacnew.original_path);

    const numbered = parsePacfilePath("/etc/example.conf.pacsave.12").?;
    try testing.expectEqual(Kind.numbered_pacsave, numbered.kind);
    try testing.expectEqual(@as(?u64, 12), numbered.save_number);
    const oversized = parsePacfilePath("/etc/example.conf.pacsave.184467440737095516160").?;
    try testing.expectEqual(Kind.numbered_pacsave, oversized.kind);
    try testing.expectEqual(@as(?u64, null), oversized.save_number);
    try testing.expect(parsePacfilePath("/etc/example.conf.pacsave.old") == null);
}

test "find discovery sorts deduplicates and classifies pacfiles" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);
    const nested = try std.fs.path.join(testing.allocator, &.{ root, "etc/nested" });
    defer testing.allocator.free(nested);
    try std.Io.Dir.cwd().createDirPath(testing.io, nested);
    const first = try std.fs.path.join(testing.allocator, &.{ root, "etc/z.conf.pacnew" });
    defer testing.allocator.free(first);
    const second = try std.fs.path.join(testing.allocator, &.{ root, "etc/nested/a.conf.pacsave.2" });
    defer testing.allocator.free(second);
    const ignored = try std.fs.path.join(testing.allocator, &.{ root, "etc/nested/readme" });
    defer testing.allocator.free(ignored);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = first, .data = "new" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = second, .data = "saved" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = ignored, .data = "ignore" });
    var paths = [_][]const u8{ root, nested };
    var manager = PacfileManager.init(testing.allocator, testing.io, .{ .find_paths = &paths });
    const files = try manager.discover(.find);
    defer Pacfile.deinitSlice(testing.allocator, files);
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expect(std.mem.order(u8, files[0].path, files[1].path) == .lt);
    try testing.expectEqual(Kind.numbered_pacsave, files[0].kind);
    try testing.expectEqual(Kind.pacnew, files[1].kind);
}

test "pacman database discovery follows backup records and numbered saves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/root", .{tmp.sub_path});
    defer testing.allocator.free(root);
    const database = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/db", .{tmp.sub_path});
    defer testing.allocator.free(database);
    const package_dir = try std.fs.path.join(testing.allocator, &.{ database, "local/example-1.0-1" });
    defer testing.allocator.free(package_dir);
    const config_dir = try std.fs.path.join(testing.allocator, &.{ root, "etc" });
    defer testing.allocator.free(config_dir);
    try std.Io.Dir.cwd().createDirPath(testing.io, package_dir);
    try std.Io.Dir.cwd().createDirPath(testing.io, config_dir);
    const files_db = try std.fs.path.join(testing.allocator, &.{ package_dir, "files" });
    defer testing.allocator.free(files_db);
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = files_db,
        .data = "%FILES%\netc/example.conf\n\n%BACKUP%\netc/example.conf\tdeadbeef\n\n",
    });
    const original = try std.fs.path.join(testing.allocator, &.{ root, "etc/example.conf" });
    defer testing.allocator.free(original);
    const pacnew = try std.fmt.allocPrint(testing.allocator, "{s}.pacnew", .{original});
    defer testing.allocator.free(pacnew);
    const numbered = try std.fmt.allocPrint(testing.allocator, "{s}.pacsave.3", .{original});
    defer testing.allocator.free(numbered);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = original, .data = "old" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = pacnew, .data = "new" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = numbered, .data = "saved" });
    var manager = PacfileManager.init(testing.allocator, testing.io, .{
        .root_directory = root,
        .database_path = database,
    });
    const files = try manager.discover(.pacman_database);
    defer Pacfile.deinitSlice(testing.allocator, files);
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expectEqual(Kind.pacnew, files[0].kind);
    try testing.expectEqual(Kind.numbered_pacsave, files[1].kind);
}

test "pacfile state removal overwrite and backup are deterministic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);
    const original = try std.fs.path.join(testing.allocator, &.{ root, "example.conf" });
    defer testing.allocator.free(original);
    const pacnew = try std.fmt.allocPrint(testing.allocator, "{s}.pacnew", .{original});
    defer testing.allocator.free(pacnew);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = original, .data = "old" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = pacnew, .data = "old" });
    var manager = PacfileManager.init(testing.allocator, testing.io, .{});
    var file_list: std.ArrayList(Pacfile) = .empty;
    defer deinitList(testing.allocator, &file_list);
    try addUnique(testing.allocator, &file_list, pacnew);
    try testing.expectEqual(State.identical, try manager.state(file_list.items[0]));
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = pacnew, .data = "new" });
    try testing.expectEqual(State.different, try manager.state(file_list.items[0]));
    try manager.overwrite(file_list.items[0], true);
    const new_contents = try std.Io.Dir.cwd().readFileAlloc(testing.io, original, testing.allocator, .limited(32));
    defer testing.allocator.free(new_contents);
    try testing.expectEqualStrings("new", new_contents);
    const backup = try std.fmt.allocPrint(testing.allocator, "{s}.bak", .{original});
    defer testing.allocator.free(backup);
    const backup_contents = try std.Io.Dir.cwd().readFileAlloc(testing.io, backup, testing.allocator, .limited(32));
    defer testing.allocator.free(backup_contents);
    try testing.expectEqualStrings("old", backup_contents);
}

test "base archive selection returns the second newest package" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/cache", .{tmp.sub_path});
    defer testing.allocator.free(cache);
    try std.Io.Dir.cwd().createDirPath(testing.io, cache);
    inline for (.{ "example-1.0-1-x86_64.pkg.tar.zst", "example-3.0-1-x86_64.pkg.tar.zst", "example-2.0-1-x86_64.pkg.tar.xz" }) |name| {
        const path = try std.fs.path.join(testing.allocator, &.{ cache, name });
        defer testing.allocator.free(path);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "archive" });
    }
    var manager = PacfileManager.init(testing.allocator, testing.io, .{ .cache_directory = cache });
    const selected = try manager.findBaseArchive("example");
    defer testing.allocator.free(selected);
    try testing.expect(std.mem.endsWith(u8, selected, "example-2.0-1-x86_64.pkg.tar.xz"));
}

test "three-way merge is reviewable and applies with a backup" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const real_path_length = try tmp.dir.realPath(testing.io, &real_path_buffer);
    const root = real_path_buffer[0..real_path_length];
    const cache = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache);
    const work = try std.fs.path.join(testing.allocator, &.{ root, "work" });
    defer testing.allocator.free(work);
    try std.Io.Dir.cwd().createDirPath(testing.io, cache);

    inline for (.{ "example-1.0-1-x86_64.pkg.tar.zst", "example-2.0-1-x86_64.pkg.tar.zst" }) |name| {
        const archive = try std.fs.path.join(testing.allocator, &.{ cache, name });
        defer testing.allocator.free(archive);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = archive, .data = "fixture" });
    }

    const original = try std.fs.path.join(testing.allocator, &.{ root, "example.conf" });
    defer testing.allocator.free(original);
    const pacnew = try std.fmt.allocPrint(testing.allocator, "{s}.pacnew", .{original});
    defer testing.allocator.free(pacnew);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = original, .data = "local\n" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = pacnew, .data = "package\n" });

    const owner_tool = try std.fs.path.join(testing.allocator, &.{ root, "owner-tool" });
    defer testing.allocator.free(owner_tool);
    const extract_tool = try std.fs.path.join(testing.allocator, &.{ root, "extract-tool" });
    defer testing.allocator.free(extract_tool);
    const merge_tool = try std.fs.path.join(testing.allocator, &.{ root, "merge-tool" });
    defer testing.allocator.free(merge_tool);
    try writeExecutable(owner_tool, "#!/bin/sh\nprintf 'example\\n'\n");
    try writeExecutable(extract_tool, "#!/bin/sh\nprintf 'base\\n'\n");
    try writeExecutable(merge_tool, "#!/bin/sh\nprintf 'merged\\n'\nexit 1\n");
    var merge_program = [_][]const u8{merge_tool};
    var diff_program = [_][]const u8{"/usr/bin/true"};
    var manager = PacfileManager.init(testing.allocator, testing.io, .{
        .cache_directory = cache,
        .temporary_directory = work,
        .pacman_command = owner_tool,
        .bsdtar_command = extract_tool,
        .merge_program = &merge_program,
        .diff_program = &diff_program,
    });
    var file_list: std.ArrayList(Pacfile) = .empty;
    defer deinitList(testing.allocator, &file_list);
    try addUnique(testing.allocator, &file_list, pacnew);

    var prepared = try manager.prepareMerge(file_list.items[0]);
    defer prepared.deinit();
    try testing.expect(prepared.has_conflicts);
    try testing.expect((try manager.viewPreparedMerge(&prepared)).successful());
    const staged = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        prepared.merged_path,
        testing.allocator,
        .limited(32),
    );
    defer testing.allocator.free(staged);
    try testing.expectEqualStrings("merged\n", staged);

    try manager.applyPreparedMerge(&prepared, true);
    try testing.expect(prepared.applied);
    const installed = try std.Io.Dir.cwd().readFileAlloc(testing.io, original, testing.allocator, .limited(32));
    defer testing.allocator.free(installed);
    try testing.expectEqualStrings("merged\n", installed);
    const backup = try std.fmt.allocPrint(testing.allocator, "{s}.bak", .{original});
    defer testing.allocator.free(backup);
    const saved_original = try std.Io.Dir.cwd().readFileAlloc(testing.io, backup, testing.allocator, .limited(32));
    defer testing.allocator.free(saved_original);
    try testing.expectEqualStrings("local\n", saved_original);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, pacnew, .{}));
}

fn writeExecutable(path: []const u8, contents: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = contents });
    var file = try std.Io.Dir.cwd().openFile(testing.io, path, .{ .mode = .read_write });
    defer file.close(testing.io);
    try file.setPermissions(testing.io, .fromMode(0o755));
}
