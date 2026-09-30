const std = @import("std");
const architecture_utils = @import("../alpm/architectures.zig");
const rlpm = @import("Shelly_Rlpm");
const Config = @import("../alpm/configuration.zig").Configuration.Config;
const SigLevel = @import("../alpm/types.zig").SigLevel;

pub fn signature(bits: u32, fallback: u32) rlpm.SignaturePolicy {
    const value: SigLevel = @bitCast(if (bits & (1 << 30) != 0) fallback else bits);
    return .{
        .package = if (!value.package) .disabled else if (value.package_optional) .optional else .required,
        .database = if (!value.database) .disabled else if (value.database_optional) .optional else .required,
        .package_trust = .{ .allow_marginal = value.package_marginal_ok, .allow_unknown = value.package_unknown_ok },
        .database_trust = .{ .allow_marginal = value.database_marginal_ok, .allow_unknown = value.database_unknown_ok },
    };
}
fn slices(a: std.mem.Allocator, values: []const [:0]const u8) ![]const []const u8 {
    const result = try a.alloc([]const u8, values.len);
    for (values, result) |value, *item| item.* = value;
    return result;
}
pub fn createOwner(io: std.Io, allocator: std.mem.Allocator, c: *const Config, parallel: u8, worker_executable: ?[]const u8) !rlpm.Owner {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var arches = try architecture_utils.expand(a, c.architectures.items, c.architecture);
    const server_arch = arches.items[0];
    var hooks: std.ArrayList([]const u8) = .empty;
    const system_hooks = try std.fs.path.join(a, &.{ c.root_directory, "usr/share/libalpm/hooks" });
    try hooks.append(a, system_hooks);
    for (c.hook_directory.items) |path| {
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, path, "/"), system_hooks)) try hooks.append(a, path);
    }
    const repos = try a.alloc(rlpm.DatabaseConfiguration, c.repositories.items.len);
    for (c.repositories.items, repos) |repo, *registration| {
        const usage = if (repo.usage == 0) 15 else repo.usage;
        registration.* = .{ .database_name = repo.name, .signature_policy = if (repo.sig_level == 0) null else signature(repo.sig_level, c.signature_level), .usage = .{ .sync = usage & 1 != 0, .search = usage & 2 != 0, .install = usage & 4 != 0, .upgrade = usage & 8 != 0 } };
        inline for (.{ "servers", "cache_servers" }) |field| {
            const values = @field(repo, field).items;
            const resolved = try a.alloc([]const u8, values.len);
            for (values, resolved) |url, *dest| {
                const first = try std.mem.replaceOwned(u8, a, url, "$repo", repo.name);
                dest.* = try std.mem.replaceOwned(u8, a, first, "$arch", server_arch);
                // Preserve the configured CachyOS ISA tiers accepted by the
                // existing facade, including archives from lower tiers.
                if (std.mem.indexOf(u8, url, "$arch")) |offset| {
                    const tail = url[offset + 5 ..];
                    const end = std.mem.indexOfScalar(u8, tail, '/') orelse tail.len;
                    if (std.mem.indexOfScalar(u8, tail[0..end], 'v')) |v| {
                        var level = std.fmt.parseInt(u8, tail[v + 1 .. end], 10) catch 0;
                        while (level >= 2) : (level -= 1) {
                            const name = try std.fmt.allocPrint(a, "{s}_v{d}", .{ server_arch, level });
                            var present = false;
                            for (arches.items) |existing| {
                                if (std.mem.eql(u8, existing, name)) present = true;
                            }
                            if (!present) try arches.append(a, name);
                        }
                    }
                }
            }
            @field(registration, field) = resolved;
        }
    }
    const assumed = try a.alloc(rlpm.PackageRelation, c.assume_installed.items.len);
    for (c.assume_installed.items, assumed) |text, *dep| dep.* = try rlpm.PackageRelation.parse(text);
    return rlpm.Owner.init(io, allocator, .{
        .root = c.root_directory,
        .database_path = c.database_path,
        .cache_directories = try slices(a, if (c.cache_directories.items.len != 0) c.cache_directories.items else &.{c.cache_directory}),
        .hook_directories = hooks.items,
        .gpg_directory = c.gpg_directory,
        .log_file = c.log_file,
        .architectures = arches.items,
        .ignore_packages = try slices(a, c.ignore_package.items),
        .ignore_groups = try slices(a, c.ignore_group.items),
        .no_upgrade = try slices(a, c.no_upgrade.items),
        .no_extract = try slices(a, c.no_extract.items),
        .assume_installed = assumed,
        .check_space = c.check_space,
        .use_syslog = c.use_system_log,
        .default_signature_policy = signature(c.signature_level, 0),
        .local_file_signature_policy = signature(c.local_file_signature_level, c.signature_level),
        .remote_file_signature_policy = signature(c.remote_file_signature_level, c.signature_level),
        .worker_executable = worker_executable,
        .parallel_downloads = c.parallel_downloads orelse parallel,
        .sandbox_user = c.sandbox_user,
        .disable_download_timeout = c.disable_download_timeout,
        .sandbox = .{ .disable_filesystem = c.disable_sandbox or c.disable_sandbox_filesystem, .disable_syscalls = c.disable_sandbox or c.disable_sandbox_syscalls, .disable_network = c.disable_sandbox or c.disable_sandbox_network },
    }, repos);
}

pub fn preparePreview(io: std.Io, allocator: std.mem.Allocator, c: *Config, destination: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = try std.Io.Dir.cwd().openDir(io, try std.fs.path.join(a, &.{ c.database_path, "local" }), .{ .iterate = true });
    defer src.close(io);
    var source_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const source = source_buffer[0..try src.realPath(io, &source_buffer)];
    std.Io.Dir.cwd().createDirPath(io, destination) catch |err| switch (err) {
        error.NotDir => return error.InvalidPreviewRoot,
        else => return err,
    };
    var parent = try std.Io.Dir.cwd().openDir(io, destination, .{});
    defer parent.close(io);
    var parent_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target = try std.fs.path.join(a, &.{ parent_buffer[0..try parent.realPath(io, &parent_buffer)], "local" });
    // Compare canonical paths before clearing a prior snapshot. The cache's
    // parent must never alias or overlap the live local database.
    if (containsPath(source, target) or containsPath(target, source)) return error.InvalidPreviewRoot;
    const stat = parent.statFile(io, "local", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (stat) |value| {
        if (value.kind == .sym_link) {
            // libalpm's update preview uses a link to the live local database.
            // Unlink that known legacy entry before making our private copy;
            // never traverse it when deleting the previous snapshot.
            var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const linked = link_buffer[0 .. parent.realPathFile(io, "local", &link_buffer) catch return error.InvalidPreviewRoot];
            if (!std.mem.eql(u8, source, linked)) return error.InvalidPreviewRoot;
            try parent.deleteFile(io, "local");
        } else if (value.kind != .directory) return error.InvalidPreviewRoot;
    }
    try parent.deleteTree(io, "local");
    try parent.createDirPath(io, "local");
    var dst = try parent.openDir(io, "local", .{});
    defer dst.close(io);
    var walk = try src.walk(a);
    defer walk.deinit();
    while (try walk.next(io)) |entry| switch (entry.kind) {
        .directory => try dst.createDirPath(io, entry.path),
        .file => try std.Io.Dir.copyFile(src, entry.path, dst, entry.path, io, .{}),
        else => return error.InvalidLocalDatabaseEntry,
    };
    c.database_path = try c.arena.allocator().dupeZ(u8, destination);
    // Read-only update previews match the native facade. Actual transactions
    // reopen the real database with its complete signature policy.
    const database_bits: u32 = @bitCast(SigLevel{ .database = true, .database_optional = true, .database_marginal_ok = true, .database_unknown_ok = true });
    c.signature_level &= ~database_bits;
    for (c.repositories.items) |*repo| repo.sig_level &= ~database_bits;
}

fn containsPath(parent: []const u8, child: []const u8) bool {
    return std.mem.eql(u8, parent, child) or (child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/');
}
