//! Package assembly: tidy/strip handling, .PKGINFO/.BUILDINFO writers,
//! install-script and changelog placement, archive creation, and signing.

const std = @import("std");
const archive = @import("archive");
const process_runner = @import("../builder.zig");
const install_script = @import("../../pkgbuild/install_script.zig");
const pkgbuild_review = @import("pkgbuild_review.zig");
const package_signer = @import("../../shared/package_signer.zig");
const package_options = @import("package_options");
const metadata = @import("metadata.zig");
const virtual_ownership = @import("virtual_ownership.zig");
const steps = @import("steps.zig");
const alpm_bindings = @import("../../alpm/bindings.zig").libalpm;
const raw_alpm = alpm_bindings.alpm;
const PackageBuilder = @import("builder.zig").PackageBuilder;
const BuildArtifact = @import("builder.zig").BuildArtifact;
const PackageBuild = @import("../../pkgbuild/pkgbuild_parser.zig").Pkgbuild;

pub fn preparePackageDirectory(self: *PackageBuilder, package_build: *const PackageBuild) !void {
    const package_name = package_build.pkg_name orelse return error.MissingPackageName;
    const pkgdir = try std.fs.path.join(
        self.allocator,
        &.{ self.options.work_directory, "pkg", package_name },
    );
    defer self.allocator.free(pkgdir);
    std.Io.Dir.cwd().deleteTree(self.io, pkgdir) catch {
        steps.reportUnwritableBuildDirectory(self, pkgdir);
        return error.BuildDirectoryNotWritable;
    };
    std.Io.Dir.cwd().createDirPath(self.io, pkgdir) catch {
        steps.reportUnwritableBuildDirectory(self, pkgdir);
        return error.BuildDirectoryNotWritable;
    };
}

/// Applies the small, content-affecting subset of makepkg's tidy phase
/// currently modeled by Shelly. PKGBUILD options override makepkg.conf
/// options using the same `option`/`!option` convention as makepkg.
fn tidyPackage(self: *PackageBuilder, package_build: *const PackageBuild, pkgdir: []const u8) !void {
    const effective = try metadata.effectivePackageOptions(
        self.allocator,
        self.shellybuild_config.package.options,
        package_build.options orelse &.{},
    );
    defer metadata.freeOwnedStrings(self.allocator, effective);
    if (!metadata.optionEnabled(effective, "strip")) return;

    var directory = try std.Io.Dir.cwd().openDir(self.io, pkgdir, .{ .iterate = true });
    defer directory.close(self.io);
    var walker = try directory.walk(self.allocator);
    defer walker.deinit();
    while (try walker.next(self.io)) |entry| {
        if (entry.kind != .file) continue;
        if (self.active_operation) |operation| try operation.checkCancelled();
        const stat = try entry.dir.statFile(self.io, entry.basename, .{ .follow_symlinks = false });
        if (stat.permissions.toMode() & 0o200 == 0) continue;

        const path = try std.fs.path.join(self.allocator, &.{ pkgdir, entry.path });
        defer self.allocator.free(path);
        const kind = try stripKind(self.io, path);
        const flags = switch (kind orelse continue) {
            .binary => self.shellybuild_config.package.strip_binaries,
            .shared => self.shellybuild_config.package.strip_shared,
            .static => self.shellybuild_config.package.strip_static,
        };
        var command: std.ArrayList([]const u8) = .empty;
        defer command.deinit(self.allocator);
        try command.append(self.allocator, "strip");
        for (flags) |flag| try command.append(self.allocator, flag);
        try command.append(self.allocator, path);
        var result = try process_runner.runWithEnvironment(
            self.allocator,
            self.io,
            self.environ,
            command.items,
            null,
            60,
        );
        defer result.deinit(self.allocator);
        if (result.exit_code != 0) return error.StripFailed;
    }
}

pub fn assemblePackage(self: *PackageBuilder, package_build: *const PackageBuild) !BuildArtifact {
    const package_name = package_build.pkg_name orelse return error.MissingPackageName;
    const full_version = try package_build.get_full_version(self.allocator);
    defer self.allocator.free(full_version);
    if (full_version.len == 0) return error.MissingPackageVersion;

    const package_arch = packageArchitecture(self, package_build);
    const pkgdir = try std.fs.path.join(
        self.allocator,
        &.{ self.options.work_directory, "pkg", package_name },
    );
    defer self.allocator.free(pkgdir);

    // Resolve inode-attached ownership before tidy tools such as `strip` can
    // replace a file behind the same final package path.
    var owned_virtual_metadata: ?virtual_ownership.OwnedMetadata = if (self.virtual_ownership_tracker) |*tracker|
        if (tracker.hasNonDefaultOwnership())
            try tracker.buildMetadata(self.io, pkgdir)
        else
            null
    else
        null;
    defer if (owned_virtual_metadata) |*owned| owned.deinit();
    const virtual_metadata: archive.VirtualMetadata = if (owned_virtual_metadata) |*owned| owned.view() else .{};

    try tidyPackage(self, package_build, pkgdir);

    var pkgdir_handle = try std.Io.Dir.cwd().openDir(self.io, pkgdir, .{ .iterate = true });
    defer pkgdir_handle.close(self.io);

    const payload_size = try directorySize(self.allocator, self.io, pkgdir_handle);
    const build_date = self.source_date_epoch orelse return error.MissingSourceDateEpoch;
    try writePackageInfo(self, package_build, pkgdir_handle, full_version, package_arch, payload_size, build_date);
    try writeBuildInfo(self, package_build, pkgdir_handle, full_version, package_arch, build_date);
    if (package_build.install_file) |install_file| {
        const reviewed_script = findInstallScript(self, install_file) orelse return error.MissingInstallFile;
        try writeMetadataFile(pkgdir_handle, self.io, ".INSTALL", reviewed_script.contents);
    } else {
        try deleteFileIgnoreMissing(pkgdir_handle, self.io, ".INSTALL");
    }
    if (package_build.changelog_file) |changelog_file| {
        const reviewed_file = findReviewedFile(self, changelog_file) orelse return error.MissingChangelogFile;
        try writeMetadataFile(pkgdir_handle, self.io, ".CHANGELOG", reviewed_file.contents);
    } else {
        try deleteFileIgnoreMissing(pkgdir_handle, self.io, ".CHANGELOG");
    }

    const mtree_path = try std.fs.path.join(self.allocator, &.{ pkgdir, ".MTREE" });
    defer self.allocator.free(mtree_path);
    try archive.writeMtreeWithMetadata(self.allocator, self.io, pkgdir, mtree_path, virtual_metadata);
    var mtree_file = try pkgdir_handle.openFile(self.io, ".MTREE", .{});
    defer mtree_file.close(self.io);
    try mtree_file.setPermissions(self.io, .fromMode(0o644));

    try std.Io.Dir.cwd().createDirPath(self.io, self.options.package_destination);
    const file_name = try std.fmt.allocPrint(
        self.allocator,
        "{s}-{s}-{s}{s}",
        .{ package_name, full_version, package_arch, self.shellybuild_config.package.extension },
    );
    defer self.allocator.free(file_name);
    const output_path = try std.fs.path.joinZ(
        self.allocator,
        &.{ self.options.package_destination, file_name },
    );
    errdefer self.allocator.free(output_path);
    if (!self.options.overwrite) {
        if (std.Io.Dir.cwd().access(self.io, output_path, .{})) |_| {
            return error.AlreadyBuilt;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }
    var random_suffix: [8]u8 = undefined;
    self.io.random(&random_suffix);
    const suffix = std.fmt.bytesToHex(random_suffix, .lower);
    const temporary_path = try std.fmt.allocPrint(
        self.allocator,
        "{s}/.shelly-{s}-{s}",
        .{ self.options.package_destination, suffix, file_name },
    );
    defer self.allocator.free(temporary_path);
    errdefer std.Io.Dir.cwd().deleteFile(self.io, temporary_path) catch {};

    {
        var writer = try archive.Writer.initWithMetadata(self.allocator, self.io, temporary_path, virtual_metadata);
        defer writer.deinit();
        try writer.addDirectory(pkgdir);
        try writer.finish();
    }

    var temporary_signature_path: ?[]u8 = null;
    defer if (temporary_signature_path) |path| self.allocator.free(path);
    errdefer if (temporary_signature_path) |path| {
        std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
    };
    if (self.options.sign) {
        try steps.logPhase(self, "signing");
        temporary_signature_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.sig",
            .{temporary_path},
        );
        try signPackageArchive(self, temporary_path, temporary_signature_path.?);
    }

    try std.Io.Dir.cwd().rename(temporary_path, std.Io.Dir.cwd(), output_path, self.io);
    errdefer if (self.options.sign) {
        std.Io.Dir.cwd().deleteFile(self.io, output_path) catch {};
    };
    if (self.options.sign) {
        const output_signature_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.sig",
            .{output_path},
        );
        defer self.allocator.free(output_signature_path);
        errdefer std.Io.Dir.cwd().deleteFile(self.io, output_signature_path) catch {};
        try std.Io.Dir.cwd().rename(
            temporary_signature_path.?,
            std.Io.Dir.cwd(),
            output_signature_path,
            self.io,
        );
    }

    const owned_name = try self.allocator.dupe(u8, package_name);
    errdefer self.allocator.free(owned_name);
    return .{ .path = output_path, .package_name = owned_name };
}

fn signPackageArchive(
    self: *PackageBuilder,
    payload_path: []const u8,
    signature_path: []const u8,
) !void {
    const signer = package_signer.Signer{
        .allocator = self.allocator,
        .io = self.io,
        .environ = self.environ,
        .gnupg_home = self.options.sign_gnupg_home,
    };
    try signer.signDetached(payload_path, signature_path, self.options.sign_key);
}

/// Removes a published archive together with its detached signature, if
/// one exists, so rollbacks never leave orphaned signature files.
pub fn removePublishedArtifact(self: *PackageBuilder, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
    const signature_path = std.fmt.allocPrint(self.allocator, "{s}.sig", .{path}) catch return;
    defer self.allocator.free(signature_path);
    std.Io.Dir.cwd().deleteFile(self.io, signature_path) catch {};
}

fn findInstallScript(self: *const PackageBuilder, file_name: []const u8) ?*const install_script.Script {
    for (self.options.install_scripts) |*script| {
        if (std.mem.eql(u8, script.file_name, file_name)) return script;
    }
    return null;
}

pub fn installScriptsMatch(
    self: *const PackageBuilder,
    current_scripts: []const install_script.Script,
) bool {
    if (self.options.install_scripts.len != current_scripts.len) return false;
    for (current_scripts) |current| {
        const reviewed = findInstallScript(self, current.file_name) orelse return false;
        if (!std.mem.eql(u8, reviewed.contents, current.contents)) return false;
    }
    return true;
}

fn findReviewedFile(
    self: *const PackageBuilder,
    file_name: []const u8,
) ?*const pkgbuild_review.ReviewedFile {
    for (self.options.reviewed_files) |*file| {
        if (std.mem.eql(u8, file.name, file_name)) return file;
    }
    return null;
}

pub fn reviewedFilesMatch(
    self: *const PackageBuilder,
    current_files: []const pkgbuild_review.ReviewedFile,
) bool {
    if (self.options.reviewed_files.len != current_files.len) return false;
    for (current_files) |current| {
        const reviewed = findReviewedFile(self, current.name) orelse return false;
        if (!std.mem.eql(u8, reviewed.contents, current.contents)) return false;
        if (reviewed.permissions != current.permissions) return false;
    }
    return true;
}

fn packageArchitecture(self: *const PackageBuilder, package_build: *const PackageBuild) []const u8 {
    if (package_build.arch) |architectures| {
        for (architectures) |architecture| {
            if (std.mem.eql(u8, architecture, "any")) return "any";
        }
    }
    return self.shellybuild_config.build.carch;
}

pub fn packageSupportsArchitecture(
    self: *const PackageBuilder,
    package_build: *const PackageBuild,
) bool {
    const architectures = package_build.arch orelse return true;
    if (architectures.len == 0) return true;
    for (architectures) |architecture| {
        if (std.mem.eql(u8, architecture, "any") or
            std.mem.eql(u8, architecture, self.shellybuild_config.build.carch)) return true;
    }
    return false;
}

fn writePackageInfo(
    self: *PackageBuilder,
    package_build: *const PackageBuild,
    pkgdir: std.Io.Dir,
    full_version: []const u8,
    package_arch: []const u8,
    payload_size: u64,
    build_date: i64,
) !void {
    const package_name = package_build.pkg_name orelse return error.MissingPackageName;
    const package_base = package_build.variables.get("pkgbase") orelse package_name;

    var output: std.Io.Writer.Allocating = .init(self.allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writeKeyValue(writer, "pkgname", package_name);
    try writeKeyValue(writer, "pkgbase", package_base);
    try writeKeyValue(writer, "xdata", if (package_build.is_split) "pkgtype=split" else "pkgtype=pkg");
    try writeKeyValues(writer, "xdata", package_build.xdata);
    try writeKeyValue(writer, "pkgver", full_version);
    if (package_build.pkg_desc) |value| try writeKeyValue(writer, "pkgdesc", value);
    if (package_build.url) |value| try writeKeyValue(writer, "url", value);
    try writer.print("builddate = {d}\n", .{build_date});
    try writeKeyValue(writer, "packager", self.shellybuild_config.package.packager);
    try writer.print("size = {d}\n", .{payload_size});
    try writeKeyValue(writer, "arch", package_arch);
    try writeKeyValues(writer, "license", package_build.license);
    try writeKeyValues(writer, "replaces", package_build.replaces);
    try writeKeyValues(writer, "group", package_build.groups);
    try writeKeyValues(writer, "conflict", package_build.conflicts);
    try writeKeyValues(writer, "provides", package_build.provides);
    try writeKeyValues(writer, "backup", package_build.backup);
    try writeKeyValues(writer, "depend", package_build.depends);
    try writeKeyValues(writer, "optdepend", package_build.opt_depends);
    try writeKeyValues(writer, "makedepend", package_build.make_depends);
    try writeKeyValues(writer, "checkdepend", package_build.check_depends);
    try writeMetadataFile(pkgdir, self.io, ".PKGINFO", output.written());
}

fn writeBuildInfo(
    self: *PackageBuilder,
    package_build: *const PackageBuild,
    pkgdir: std.Io.Dir,
    full_version: []const u8,
    package_arch: []const u8,
    build_date: i64,
) !void {
    const package_name = package_build.pkg_name orelse return error.MissingPackageName;
    const package_base = package_build.variables.get("pkgbase") orelse package_name;

    var output: std.Io.Writer.Allocating = .init(self.allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writeKeyValue(writer, "format", "2");
    try writeKeyValue(writer, "pkgname", package_name);
    try writeKeyValue(writer, "pkgbase", package_base);
    try writeKeyValue(writer, "pkgver", full_version);
    try writeKeyValue(writer, "pkgarch", package_arch);
    const pkgbuild_digest = self.options.pkgbuild_sha256sum orelse
        return error.MissingPkgbuildDigest;
    const pkgbuild_digest_hex = std.fmt.bytesToHex(pkgbuild_digest, .lower);
    try writeKeyValue(writer, "pkgbuild_sha256sum", &pkgbuild_digest_hex);
    try writeKeyValue(writer, "packager", self.shellybuild_config.package.packager);
    try writer.print("builddate = {d}\n", .{build_date});
    try writeKeyValue(writer, "builddir", self.options.work_directory);
    try writeKeyValue(
        writer,
        "startdir",
        if (self.options.pkgbuild_path) |path|
            std.fs.path.dirname(path) orelse self.options.start_directory
        else
            self.options.start_directory,
    );
    try writeKeyValue(writer, "buildtool", "shelly");
    try writeKeyValue(writer, "buildtoolver", package_options.version);

    try writeKeyValue(writer, "buildenv", if (self.options.run_check) "check" else "!check");
    try writeKeyValue(writer, "buildenv", if (self.shellybuild_config.build.ccache) "ccache" else "!ccache");
    try writeKeyValue(writer, "buildenv", if (self.shellybuild_config.build.distcc) "distcc" else "!distcc");

    const effective_options = try metadata.effectivePackageOptions(
        self.allocator,
        self.shellybuild_config.package.options,
        package_build.options orelse &.{},
    );
    defer metadata.freeOwnedStrings(self.allocator, effective_options);
    for (effective_options) |value| try writeKeyValue(writer, "options", value);

    if (self.options.installed_packages) |installed| {
        for (installed) |value| try writeKeyValue(writer, "installed", value);
    } else {
        const installed = try collectInstalledPackages(self.allocator);
        defer metadata.freeOwnedStrings(self.allocator, installed);
        for (installed) |value| try writeKeyValue(writer, "installed", value);
    }
    try writeMetadataFile(pkgdir, self.io, ".BUILDINFO", output.written());
}

const StripKind = enum { binary, shared, static };

fn stripKind(io: std.Io, path: []const u8) !?StripKind {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var header: [20]u8 = undefined;
    const amount = try file.readPositionalAll(io, &header, 0);
    if (amount >= 8 and std.mem.eql(u8, header[0..8], "!<arch>\n")) return .static;
    if (amount < header.len or !std.mem.eql(u8, header[0..4], "\x7fELF")) return null;
    const elf_type: u16 = switch (header[5]) {
        1 => std.mem.readInt(u16, header[16..18], .little),
        2 => std.mem.readInt(u16, header[16..18], .big),
        else => return null,
    };
    return switch (elf_type) {
        1 => if (std.mem.endsWith(u8, path, ".o")) .static else if (std.mem.endsWith(u8, path, ".ko")) .shared else null,
        2 => .binary,
        3 => .shared,
        else => null,
    };
}

fn collectInstalledPackages(allocator: std.mem.Allocator) ![][]u8 {
    var alpm_error: raw_alpm.alpm_errno_t = 0;
    const handle = raw_alpm.alpm_initialize("/", "/var/lib/pacman", &alpm_error) orelse
        return error.LocalDatabaseOpenFailed;
    defer _ = raw_alpm.alpm_release(handle);
    const database = raw_alpm.alpm_get_localdb(handle) orelse
        return error.LocalDatabaseOpenFailed;
    var packages = raw_alpm.alpm_db_get_pkgcache(database);
    var installed: std.ArrayList([]u8) = .empty;
    errdefer {
        for (installed.items) |value| allocator.free(value);
        installed.deinit(allocator);
    }
    while (packages != null) : (packages = packages.?.*.next) {
        const package = packages.?.*.data orelse continue;
        const name = alpm_bindings.str(raw_alpm.alpm_pkg_get_name(@ptrCast(package))) orelse continue;
        const version = alpm_bindings.str(raw_alpm.alpm_pkg_get_version(@ptrCast(package))) orelse continue;
        const architecture = alpm_bindings.str(raw_alpm.alpm_pkg_get_arch(@ptrCast(package))) orelse continue;
        try installed.append(
            allocator,
            try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ name, version, architecture }),
        );
    }
    std.mem.sort([]u8, installed.items, {}, struct {
        fn before(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.before);
    return installed.toOwnedSlice(allocator);
}

fn directorySize(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
) !u64 {
    var walker = try directory.walk(allocator);
    defer walker.deinit();

    var size: u64 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.path, ".PKGINFO") or
            std.mem.eql(u8, entry.path, ".BUILDINFO") or
            std.mem.eql(u8, entry.path, ".MTREE") or
            std.mem.eql(u8, entry.path, ".INSTALL")) continue;
        const stat = try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false });
        size = std.math.add(u64, size, stat.size) catch return error.PackageTooLarge;
    }
    return size;
}

fn writeMetadataFile(
    directory: std.Io.Dir,
    io: std.Io,
    name: []const u8,
    contents: []const u8,
) !void {
    try deleteFileIgnoreMissing(directory, io, name);
    try directory.writeFile(io, .{
        .sub_path = name,
        .data = contents,
        .flags = .{ .permissions = .fromMode(0o644) },
    });
}

fn deleteFileIgnoreMissing(directory: std.Io.Dir, io: std.Io, name: []const u8) !void {
    directory.deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn writeKeyValue(writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    if (std.mem.indexOfScalar(u8, value, '\n') != null) return error.InvalidPackageMetadata;
    try writer.print("{s} = {s}\n", .{ key, value });
}

fn writeKeyValues(
    writer: *std.Io.Writer,
    key: []const u8,
    values: ?[][]const u8,
) !void {
    for (values orelse return) |value| try writeKeyValue(writer, key, value);
}
