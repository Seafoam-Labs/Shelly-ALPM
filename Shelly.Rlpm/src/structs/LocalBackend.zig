const std = @import("std");
const Database = @import("Database.zig");
const Package = @import("Package.zig");
const Parsed = @import("ParsedDescription.zig");
const Record = @import("DatabaseRecord.zig");
const Backend = @import("Backend.zig");
const Publication = @import("Publication.zig");
const LocalWriter = @import("LocalWriter.zig");

const LocalBackend = @This();

mode: Backend.Mode = .read_only,

pub const Metadata = struct {
    description: bool = true,
    files: bool = false,
    members: bool = false,
};

/// Registration validates/initializes the format, without reading package descs.
pub fn validate(self: LocalBackend, io: std.Io, db: *Database) !void {
    var dir = std.Io.Dir.cwd().openDir(io, db.path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            db.status.markMissing();
            if (self.mode == .read_only) return;
            try std.Io.Dir.cwd().createDir(io, db.path, .default_dir);
            return self.validate(io, db);
        },
        else => return err,
    };
    defer dir.close(io);
    db.status.presence = .exists;
    const version = dir.readFileAlloc(io, "ALPM_DB_VERSION", db.allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => {
            var entries = dir.iterate();
            if (try entries.next(io) != null) return error.UnsupportedDatabaseVersion;
            if (self.mode == .read_only) return error.UnsupportedDatabaseVersion;
            // Do not truncate a marker installed concurrently by another owner.
            const file = dir.createFile(io, "ALPM_DB_VERSION", .{ .exclusive = true }) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => return self.validate(io, db),
                else => return create_err,
            };
            defer file.close(io);
            try file.writeStreamingAll(io, "9\n");
            db.status.markValid();
            return;
        },
        error.StreamTooLong => return error.UnsupportedDatabaseVersion,
        else => return err,
    };
    defer db.allocator.free(version);
    // fscanf("%zu") consumes an initial integer, allowing whitespace/trailing text.
    const trimmed = std.mem.trimStart(u8, version, " \t\r\n\x0b\x0c");
    const value = if (std.mem.startsWith(u8, trimmed, "+")) trimmed[1..] else trimmed;
    var length: usize = 0;
    while (length < value.len and std.ascii.isDigit(value[length])) : (length += 1) {}
    if ((std.fmt.parseInt(u64, value[0..length], 10) catch 0) != 9)
        return error.UnsupportedDatabaseVersion;
    db.status.markValid();
}

pub fn populate(self: LocalBackend, io: std.Io, db: *Database) !void {
    try self.validate(io, db);
    if (db.status.presence == .missing) return;
    var dir = try std.Io.Dir.cwd().openDir(io, db.path, .{ .iterate = true });
    defer dir.close(io);
    var guard = try Publication.DirectoryLock.acquire(db.path, false, false);
    defer guard.deinit();
    try LocalWriter.ensureReadable(io, db.allocator, db.path);
    const allocator = db.cache_arena.allocator();
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .directory and entry.kind != .unknown and entry.kind != .sym_link) continue;
        var child = dir.openDir(io, entry.name, .{}) catch |err| switch (err) {
            error.NotDir, error.FileNotFound => continue,
            else => return err,
        };
        child.close(io);
        const identity = Record.splitName(entry.name) catch {
            try db.recordSkipped(entry.name, error.InvalidDatabaseEntry);
            continue;
        };
        if (db.packages.by_name.contains(identity.name)) {
            try db.recordSkipped(entry.name, error.DuplicatePackage);
            continue;
        }
        const parsed: Parsed = .{ .name = identity.name, .version = identity.version };
        const directory = try std.fs.path.join(allocator, &.{ db.path, entry.name });
        var package = try parsed.intoPackage(
            &db.cache_arena,
            .{
                .origin = .local,
                .database_name = db.name,
                .metadata_directory = directory,
            },
        );
        package.description_loaded = false;
        try db.addPackage(package);
    }
}

/// Work on a candidate package and arena; Database publishes them together.
pub fn loadMetadata(
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    package: *Package,
    request: Metadata,
) !void {
    var guard = try Publication.DirectoryLock.acquire(
        std.fs.path.dirname(
            package.metadata_directory.?,
        ).?,
        false,
        false,
    );
    defer guard.deinit();
    try LocalWriter.ensureReadable(
        io,
        arena.allocator(),
        std.fs.path.dirname(
            package.metadata_directory.?,
        ).?,
    );
    const allocator = arena.allocator();
    var dir = try std.Io.Dir.cwd().openDir(
        io,
        package.metadata_directory orelse return error.InvalidPath,
        .{},
    );
    defer dir.close(io);
    if (request.description and !package.description_loaded) {
        const bytes = try dir.readFileAlloc(io, "desc", allocator, .limited(1 << 20));
        var parsed: Parsed = .{ .name = package.name, .version = package.version.raw };
        defer parsed.deinit(allocator);
        var issues = package.metadata_issues;
        try Record.append(&parsed, allocator, bytes, false, &issues);
        var candidate = try parsed.intoPackage(
            arena,
            .{
                .origin = .local,
                .database_name = package.database_name,
                .metadata_directory = package.metadata_directory,
            },
        );
        candidate.files = package.files;
        candidate.backups = package.backups;
        candidate.files_loaded = package.files_loaded;
        candidate.files_source = package.files_source;
        candidate.members = package.members;
        candidate.has_scriptlet = package.has_scriptlet;
        candidate.metadata_issues = issues;
        package.* = candidate;
    }
    if (request.files and !package.files_loaded) {
        const bytes = try dir.readFileAlloc(io, "files", allocator, .limited(32 << 20));
        var parsed: Parsed = .{
            .name = package.name,
            .version = package.version.raw,
            .files_loaded = true,
        };
        defer parsed.deinit(allocator);
        try Record.append(&parsed, allocator, bytes, false, &package.metadata_issues);
        const candidate = try parsed.intoPackage(arena, .{ .origin = .local });
        package.files = candidate.files;
        package.backups = candidate.backups;
        package.files_loaded = true;
        package.files_source = .database;
    }
    if (request.members) {
        inline for (std.meta.fields(Package.Members)) |field| {
            @field(package.members, field.name) = present: {
                _ = dir.statFile(io, field.name, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :present .absent,
                    else => return err,
                };
                break :present .present;
            };
        }
        package.has_scriptlet = package.members.install == .present;
    }
}
