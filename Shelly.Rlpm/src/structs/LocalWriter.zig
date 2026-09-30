//! Durable, journaled local records. db.lck is held by the caller; cooperating
//! readers additionally share the local directory lock. A journal is a rollback
//! instruction; unlink+fsync is the commit point. Payload writes are not undone.
const std = @import("std");
const Root = @import("RootPath.zig");
const Ops = @import("RootOperations.zig");
const Package = @import("Package.zig");

const c = Ops.c;
const stage_name = ".rlpm-local-stage";
const journal_path = stage_name ++ "/journal";

pub fn recordName(a: std.mem.Allocator, package: *const Package) ![:0]const u8 {
    const result = try std.fmt.allocPrintSentinel(a, "{s}-{s}", .{ package.name, package.version.raw }, 0);
    _ = try Root.normalize(result);
    if (std.mem.indexOfAny(u8, result, "\r\n") != null) return error.InvalidDatabaseEntry;
    if (std.mem.indexOfScalar(u8, result, '/') != null) return error.InvalidDatabaseEntry;
    return result;
}

fn field(w: *std.Io.Writer, key: []const u8, value: ?[]const u8) !void {
    if (value) |text|
        if (text.len != 0) try w.print("%{s}%\n{s}\n\n", .{ key, text });
}

fn number(w: *std.Io.Writer, key: []const u8, value: anytype) !void {
    if (value) |n|
        if (n != 0) try w.print("%{s}%\n{d}\n\n", .{ key, n });
}

pub fn description(a: std.mem.Allocator, p: *const Package) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(a);
    errdefer output.deinit();
    const w = &output.writer;
    try field(w, "NAME", p.name);
    try field(w, "VERSION", p.version.raw);
    try field(w, "BASE", p.base);
    try field(w, "DESC", p.description);
    try field(w, "URL", p.url);
    try field(w, "ARCH", p.architecture);
    try field(w, "INSTALLED_DB", p.installed_database);
    try number(w, "BUILDDATE", p.build_date);
    try number(w, "INSTALLDATE", p.install_date);
    try field(w, "PACKAGER", p.packager);
    try number(w, "SIZE", p.installed_size);
    if (p.install_reason == .dependency) try field(w, "REASON", "1");
    inline for (.{ .{ "GROUPS", "groups" }, .{ "LICENSE", "licenses" } }) |pair| {
        const items = @field(p, pair[1]);
        if (items.len != 0) {
            try w.print("%{s}%\n", .{pair[0]});
            for (items) |item|
                try w.print("{s}\n", .{item});
            try w.writeByte('\n');
        }
    }
    if (p.validation.none or p.validation.md5 or p.validation.sha256 or p.validation.pgp) {
        try w.writeAll("%VALIDATION%\n");
        inline for (std.meta.fields(Package.Validation)) |item|
            if (@field(p.validation, item.name)) {
                try w.print("{s}\n", .{item.name});
            };
        try w.writeByte('\n');
    }
    inline for (.{
        .{ "REPLACES", "replaces" },
        .{ "DEPENDS", "depends" },
        .{ "OPTDEPENDS", "optional_depends" },
        .{ "CONFLICTS", "conflicts" },
        .{ "PROVIDES", "provides" },
    }) |pair| {
        const items = @field(p, pair[1]);
        if (items.len != 0) {
            try w.print("%{s}%\n", .{pair[0]});
            for (items) |item|
                try w.print("{f}\n", .{item});
            try w.writeByte('\n');
        }
    }
    if (p.xdata.len != 0) {
        try w.writeAll("%XDATA%\n");
        for (p.xdata) |item|
            try w.print("{s}={s}\n", .{ item.name, item.value });
        try w.writeByte('\n');
    }
    return output.toOwnedSlice();
}

pub fn files(a: std.mem.Allocator, p: *const Package) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(a);
    errdefer output.deinit();
    const w = &output.writer;
    if (p.files.len != 0) {
        try w.writeAll("%FILES%\n");
        for (p.files) |item|
            try w.print("{s}\n", .{item.name});
        try w.writeByte('\n');
    }
    if (p.backups.len != 0) {
        try w.writeAll("%BACKUP%\n");
        for (p.backups) |item|
            try w.print("{s}\t{s}\n", .{ item.name, item.hash orelse "(null)" });
        try w.writeByte('\n');
    }
    return output.toOwnedSlice();
}

pub fn ensureReadable(io: std.Io, a: std.mem.Allocator, local_path: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ local_path, "..", journal_path });
    defer a.free(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| return if (err == error.FileNotFound) {} else err;
    return error.DatabaseRecoveryRequired;
}

fn openDir(fd: c_int, name: [:0]const u8) !c_int {
    const result = c.openat(fd, name, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (result < 0) return Ops.failure();
    return result;
}

fn exists(fd: c_int, name: [:0]const u8) !bool {
    var stat: c.struct_stat = undefined;
    if (c.fstatat(fd, name, &stat, c.AT_SYMLINK_NOFOLLOW) == 0) return true;
    if (std.c._errno().* == c.ENOENT) return false;
    return Ops.failure();
}

fn move(from: c_int, name: [:0]const u8, to: c_int, destination: [:0]const u8) !void {
    if (c.renameat(from, name, to, destination) != 0) return Ops.failure();
}

/// Called only with db.lck and the exclusive local directory lock held.
pub fn recoverLocked(io: std.Io, a: std.mem.Allocator, database: *const Root) !void {
    if (!try exists(database.fd, stage_name)) return;
    const fd = try openDir(database.fd, stage_name);
    defer _ = c.close(fd);
    const dir: std.Io.Dir = .{ .handle = fd };
    if (try exists(fd, "journal")) {
        const bytes = try dir.readFileAlloc(io, "journal", a, .limited(16384));
        defer a.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        const old = lines.next() orelse return error.InvalidPublicationJournal;
        const new = lines.next() orelse return error.InvalidPublicationJournal;
        if (!std.mem.eql(u8, lines.next() orelse return error.InvalidPublicationJournal, "") or
            lines.next() != null)
            return error.InvalidPublicationJournal;
        for ([_][]const u8{ old, new }) |value|
            if (value.len != 0) {
                _ = try Root.normalize(value);
                if (std.mem.indexOfScalar(u8, value, '/') != null) return error.InvalidPublicationJournal;
            };
        const old_z = try a.dupeSentinel(u8, old, 0);
        defer a.free(old_z);
        const new_z = try a.dupeSentinel(u8, new, 0);
        defer a.free(new_z);
        const local = try openDir(database.fd, "local");
        defer _ = c.close(local);
        // 'record' missing means it was published. Retain it in staging while
        // restoring old so every intermediate recovery step can be replayed.
        if (new.len != 0 and !try exists(fd, "record") and try exists(local, new_z))
            try move(local, new_z, fd, "record");
        if (old.len != 0 and try exists(fd, "old")) try move(fd, "old", local, old_z);
        try Ops.sync(fd);
        try Ops.sync(local);
        if (c.unlinkat(fd, "journal", 0) != 0) return Ops.failure();
        try Ops.sync(fd);
    }
    const dbdir: std.Io.Dir = .{ .handle = database.fd };
    try dbdir.deleteTree(io, stage_name);
    try Ops.sync(database.fd);
}

pub const Record = struct {
    database: *const Root,
    io: std.Io,
    a: std.mem.Allocator,
    fd: c_int,
    record: c_int,
    /// On publication failure the journal and its recovery inputs survive.
    keep: bool = false,

    pub fn init(database: *const Root, io: std.Io, a: std.mem.Allocator) !Record {
        if (c.mkdirat(database.fd, stage_name, 0o700) != 0) return Ops.failure();
        errdefer {
            const dir: std.Io.Dir = .{ .handle = database.fd };
            dir.deleteTree(io, stage_name) catch {};
        }
        const fd = try openDir(database.fd, stage_name);
        errdefer _ = c.close(fd);
        if (c.mkdirat(fd, "record", 0o755) != 0) return Ops.failure();
        const record = try openDir(fd, "record");
        if (c.fchmod(record, 0o755) != 0) {
            _ = c.close(record);
            return Ops.failure();
        }
        return .{
            .database = database,
            .io = io,
            .a = a,
            .fd = fd,
            .record = record,
        };
    }

    pub fn deinit(self: *Record) !void {
        _ = c.close(self.record);
        _ = c.close(self.fd);
        if (!self.keep) {
            const dir: std.Io.Dir = .{ .handle = self.database.fd };
            try dir.deleteTree(self.io, stage_name);
            try Ops.sync(self.database.fd);
        }
    }

    pub fn metadata(self: *Record, p: *const Package) !void {
        const desc = try description(self.a, p);
        defer self.a.free(desc);
        try Ops.write(self.record, "desc", desc);
        const inventory = try files(self.a, p);
        defer self.a.free(inventory);
        try Ops.write(self.record, "files", inventory);
        try Ops.sync(self.record);
    }

    pub fn publish(self: *Record, old: ?[:0]const u8, new: ?[:0]const u8) !void {
        const local = try openDir(self.database.fd, "local");
        defer _ = c.close(local);
        if (c.flock(local, c.LOCK_EX) != 0) return error.CacheBusy;
        defer _ = c.flock(local, c.LOCK_UN);
        if (new) |name|
            if ((old == null or !std.mem.eql(u8, old.?, name)) and try exists(local, name))
                return error.DuplicatePackage;
        const journal = try std.fmt.allocPrint(self.a, "{s}\n{s}\n", .{ old orelse "", new orelse "" });
        defer self.a.free(journal);
        try Ops.sync(self.record);
        try Ops.write(self.fd, "journal", journal);
        self.keep = true;
        try Ops.sync(self.fd);
        try Ops.sync(self.database.fd);
        errdefer recoverLocked(self.io, self.a, self.database) catch {};
        if (old) |name| try move(local, name, self.fd, "old");
        if (new) |name| try move(self.fd, "record", local, name);
        try Ops.sync(self.fd);
        try Ops.sync(local);
        if (c.unlinkat(self.fd, "journal", 0) != 0) return Ops.failure();
        try Ops.sync(self.fd);
        self.keep = false;
    }
};
