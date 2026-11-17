//! fwupd wire structs, tolerant `a{sv}` parsers and pure firmware logic.
//!
//! Every key is optional (omitted when unset); unknown keys are logged and
//! ignored; wrong-typed keys skip the field instead of failing the parse. Structs carry
//! allocator-owned slices; callers pass a per-load arena.
//!
//! Wire quirks handled here: release `Checksum` is one comma-joined string; remote
//! `Enabled`/`ApprovalRequired` are b and `Priority` is i; the remote kind key is `Type`
//! and its id key is `RemoteId`; release `Locations` is `as` with legacy `Uri` (s)
//! tolerated; releases carry no `VersionRaw`. `fwupdmgr --json` keys are NOT wire keys.

const std = @import("std");
const diagnostics = @import("diagnostics");
const bindings = @import("Shelly_Ui_Gtk");
const glib = bindings.glib;
const translations = @import("../helpers/translations.zig");
pub const enums = @import("../services/fwupd_enums.zig");

const log = std.log.scoped(.fwupd);

// ---------------------------------------------------------------------------
// Wire structs
// ---------------------------------------------------------------------------

pub const Device = struct {
    device_id: []const u8 = "",
    name: []const u8 = "",
    vendor: []const u8 = "",
    summary: []const u8 = "",
    plugin: []const u8 = "",
    protocol: []const u8 = "",
    serial: []const u8 = "",
    version: []const u8 = "",
    version_lowest: []const u8 = "",
    version_bootloader: []const u8 = "",
    version_highest: []const u8 = "",
    version_raw: u64 = 0,
    version_lowest_raw: u64 = 0,
    version_bootloader_raw: u64 = 0,
    version_highest_raw: u64 = 0,
    version_format: enums.VersionFormat = .unknown,
    version_build_date: u64 = 0,
    flags: u64 = 0,
    problems: u64 = 0,
    request_flags: u64 = 0,
    guid: []const []const u8 = &.{},
    instance_ids: []const []const u8 = &.{},
    icon: []const []const u8 = &.{},
    vendor_id: []const u8 = "",
    branch: []const u8 = "",
    parent_device_id: []const u8 = "",
    composite_id: []const u8 = "",
    created: u64 = 0,
    modified: u64 = 0,
    install_duration: u32 = 0,
    flashes_left: u32 = 0,
    battery_level: u32 = enums.battery_level_invalid,
    battery_threshold: u32 = enums.battery_level_invalid,
    update_state: enums.UpdateState = .unknown,
    update_error: []const u8 = "",
    checksum: []const u8 = "",
    issues: []const []const u8 = &.{},
    details_url: []const u8 = "",
    status: enums.Status = .unknown,
    percentage: u32 = 0,
};

pub const Release = struct {
    version: []const u8 = "",
    name: []const u8 = "",
    summary: []const u8 = "",
    description: []const u8 = "",
    trust_flags: u64 = 0,
    urgency: enums.Urgency = .unknown,
    locations: []const []const u8 = &.{},
    /// Legacy single-URL key; `locations` wins when both are present.
    uri: []const u8 = "",
    remote_id: []const u8 = "",
    /// One comma-joined string of hex digests (libfwupd splits on ',').
    checksum: []const u8 = "",
    filename: []const u8 = "",
    size: u64 = 0,
    install_duration: u32 = 0,
    created: u64 = 0,
    license: []const u8 = "",
    homepage: []const u8 = "",
    appstream_id: []const u8 = "",
    protocol: []const u8 = "",
    vendor: []const u8 = "",
    branch: []const u8 = "",
    categories: []const []const u8 = &.{},
    issues: []const []const u8 = &.{},
    tags: []const []const u8 = &.{},
    details_url: []const u8 = "",
    source_url: []const u8 = "",
    sbom_url: []const u8 = "",
    update_message: []const u8 = "",
    update_image: []const u8 = "",
    name_variant_suffix: []const u8 = "",
    release_id: []const u8 = "",
    detach_caption: []const u8 = "",
    detach_image: []const u8 = "",
};

pub const Remote = struct {
    remote_id: []const u8 = "",
    title: []const u8 = "",
    kind: enums.RemoteKind = .unknown,
    enabled: bool = false,
    approval_required: bool = false,
    automatic_reports: bool = false,
    automatic_security_reports: bool = false,
    priority: i32 = 0,
    /// Metadata URL, NOT the payload base.
    uri: []const u8 = "",
    firmware_base_uri: []const u8 = "",
    filename_cache: []const u8 = "",
    filename_source: []const u8 = "",
    remotes_dir: []const u8 = "",
    /// Metadata *signature* checksum in 2.x (not the metadata file's).
    checksum: []const u8 = "",
    username: []const u8 = "",
    password: []const u8 = "",
    report_uri: []const u8 = "",
    privacy_uri: []const u8 = "",
    agreement: []const u8 = "",
    modification_time: u64 = 0,
    refresh_interval: u64 = 0,
    flags: u64 = 0,
};

pub const Request = struct {
    /// Request id, e.g. `org.freedesktop.fwupd.request.remove-replug`.
    appstream_id: []const u8 = "",
    device_id: []const u8 = "",
    kind: enums.RequestKind = .unknown,
    update_message: []const u8 = "",
    update_image: []const u8 = "",
    created: u64 = 0,
    flags: u64 = 0,
};

/// Daemon properties from `org.freedesktop.DBus.Properties.GetAll`.
pub const DaemonProps = struct {
    daemon_version: []const u8 = "",
    status: enums.Status = .unknown,
    percentage: u32 = 0,
    percentage_full: f64 = 0,
    battery_level: u32 = enums.battery_level_invalid,
    battery_threshold: u32 = enums.battery_level_invalid,
    only_trusted: bool = true,
};

// ---------------------------------------------------------------------------
// Tolerant a{sv} parsing
// ---------------------------------------------------------------------------

const Kind = enum {
    string,
    strv,
    uint32,
    uint64,
    int32,
    boolean,
    double,
    status,
    update_state,
    version_format,
    urgency,
    remote_kind,
    request_kind,
};

const Spec = struct {
    key: [:0]const u8,
    field: []const u8,
    kind: Kind,
};

/// Reads typed values out of an `a{sv}` dict. Missing keys keep the field default;
/// wrong-typed keys are logged and skipped (never fatal).
const DictReader = struct {
    vd: *glib.VariantDict,
    alloc: std.mem.Allocator,
    context: []const u8,

    fn lookup(self: DictReader, key: [:0]const u8, expected: []const u8) ?*glib.Variant {
        const v = self.vd.lookupValue(key, null) orelse return null;
        const actual = std.mem.span(v.getTypeString());
        if (!std.mem.eql(u8, actual, expected)) {
            log.debug("{s} dict: key '{s}' has type '{s}', expected '{s}'; skipping", .{
                self.context, key, actual, expected,
            });
            v.unref();
            return null;
        }
        return v;
    }

    fn string(self: DictReader, key: [:0]const u8, default: []const u8) std.mem.Allocator.Error![]const u8 {
        const v = self.lookup(key, "s") orelse return default;
        defer v.unref();
        var len: usize = 0;
        const s = v.getString(&len);
        return self.alloc.dupe(u8, s[0..len]);
    }

    fn strv(self: DictReader, key: [:0]const u8) std.mem.Allocator.Error![]const []const u8 {
        const v = self.lookup(key, "as") orelse return &.{};
        defer v.unref();
        var len: usize = 0;
        const arr = v.getStrv(&len);
        defer glib.free(@ptrCast(@constCast(arr)));
        const out = try self.alloc.alloc([]const u8, len);
        for (out, 0..) |*slot, i| {
            slot.* = try self.alloc.dupe(u8, std.mem.span(arr[i] orelse ""));
        }
        return out;
    }

    fn uint64(self: DictReader, key: [:0]const u8, default: u64) u64 {
        const v = self.lookup(key, "t") orelse return default;
        defer v.unref();
        return v.getUint64();
    }

    fn uint32(self: DictReader, key: [:0]const u8, default: u32) u32 {
        const v = self.lookup(key, "u") orelse return default;
        defer v.unref();
        return v.getUint32();
    }

    fn int32(self: DictReader, key: [:0]const u8, default: i32) i32 {
        const v = self.lookup(key, "i") orelse return default;
        defer v.unref();
        return v.getInt32();
    }

    fn boolean(self: DictReader, key: [:0]const u8, default: bool) bool {
        const v = self.lookup(key, "b") orelse return default;
        defer v.unref();
        return v.getBoolean() != 0;
    }

    fn double(self: DictReader, key: [:0]const u8, default: f64) f64 {
        const v = self.lookup(key, "d") orelse return default;
        defer v.unref();
        return v.getDouble();
    }
};

fn parseDict(
    comptime T: type,
    comptime specs: []const Spec,
    comptime ignored_keys: []const [:0]const u8,
    alloc: std.mem.Allocator,
    dict: *glib.Variant,
    context: []const u8,
) std.mem.Allocator.Error!T {
    var out: T = .{};
    const reader = DictReader{
        .vd = glib.VariantDict.new(dict),
        .alloc = alloc,
        .context = context,
    };
    defer reader.vd.unref();

    inline for (specs) |s| {
        @field(out, s.field) = switch (s.kind) {
            .string => try reader.string(s.key, @field(out, s.field)),
            .strv => try reader.strv(s.key),
            .uint32 => reader.uint32(s.key, @field(out, s.field)),
            .uint64 => reader.uint64(s.key, @field(out, s.field)),
            .int32 => reader.int32(s.key, @field(out, s.field)),
            .boolean => reader.boolean(s.key, @field(out, s.field)),
            .double => reader.double(s.key, @field(out, s.field)),
            .status => enums.Status.decode(reader.uint32(s.key, 0)),
            .update_state => enums.UpdateState.decode(reader.uint32(s.key, 0)),
            .version_format => enums.VersionFormat.decode(reader.uint32(s.key, 0)),
            .urgency => enums.Urgency.decode(reader.uint32(s.key, 0)),
            .remote_kind => enums.RemoteKind.decode(reader.uint32(s.key, 0)),
            .request_kind => enums.RequestKind.decode(reader.uint32(s.key, 0)),
        };
    }

    logUnknownKeys(dict, specs, ignored_keys, context);
    return out;
}

fn logUnknownKeys(
    dict: *glib.Variant,
    comptime specs: []const Spec,
    comptime ignored_keys: []const [:0]const u8,
    context: []const u8,
) void {
    var iter: glib.VariantIter = undefined;
    _ = iter.init(dict);
    while (iter.nextValue()) |entry| {
        defer entry.unref();
        const key_v = entry.getChildValue(0);
        defer key_v.unref();
        var len: usize = 0;
        const key = key_v.getString(&len)[0..len];
        const known = blk: {
            inline for (specs) |s| {
                if (std.mem.eql(u8, key, s.key)) break :blk true;
            }
            inline for (ignored_keys) |k| {
                if (std.mem.eql(u8, key, k)) break :blk true;
            }
            break :blk false;
        };
        if (!known) {
            log.debug("{s} dict: ignoring unknown key '{f}'", .{ context, diagnostics.safe(key) });
        }
    }
}

const device_specs = [_]Spec{
    .{ .key = "DeviceId", .field = "device_id", .kind = .string },
    .{ .key = "Name", .field = "name", .kind = .string },
    .{ .key = "Vendor", .field = "vendor", .kind = .string },
    .{ .key = "Summary", .field = "summary", .kind = .string },
    .{ .key = "Plugin", .field = "plugin", .kind = .string },
    .{ .key = "Protocol", .field = "protocol", .kind = .string },
    .{ .key = "Serial", .field = "serial", .kind = .string },
    .{ .key = "Version", .field = "version", .kind = .string },
    .{ .key = "VersionLowest", .field = "version_lowest", .kind = .string },
    .{ .key = "VersionBootloader", .field = "version_bootloader", .kind = .string },
    .{ .key = "VersionHighest", .field = "version_highest", .kind = .string },
    .{ .key = "VersionRaw", .field = "version_raw", .kind = .uint64 },
    .{ .key = "VersionLowestRaw", .field = "version_lowest_raw", .kind = .uint64 },
    .{ .key = "VersionBootloaderRaw", .field = "version_bootloader_raw", .kind = .uint64 },
    .{ .key = "VersionHighestRaw", .field = "version_highest_raw", .kind = .uint64 },
    .{ .key = "VersionFormat", .field = "version_format", .kind = .version_format },
    .{ .key = "VersionBuildDate", .field = "version_build_date", .kind = .uint64 },
    .{ .key = "Flags", .field = "flags", .kind = .uint64 },
    .{ .key = "Problems", .field = "problems", .kind = .uint64 },
    .{ .key = "RequestFlags", .field = "request_flags", .kind = .uint64 },
    .{ .key = "Guid", .field = "guid", .kind = .strv },
    .{ .key = "InstanceIds", .field = "instance_ids", .kind = .strv },
    .{ .key = "Icon", .field = "icon", .kind = .strv },
    .{ .key = "VendorId", .field = "vendor_id", .kind = .string },
    .{ .key = "Branch", .field = "branch", .kind = .string },
    .{ .key = "ParentDeviceId", .field = "parent_device_id", .kind = .string },
    .{ .key = "CompositeId", .field = "composite_id", .kind = .string },
    .{ .key = "Created", .field = "created", .kind = .uint64 },
    .{ .key = "Modified", .field = "modified", .kind = .uint64 },
    .{ .key = "InstallDuration", .field = "install_duration", .kind = .uint32 },
    .{ .key = "FlashesLeft", .field = "flashes_left", .kind = .uint32 },
    .{ .key = "BatteryLevel", .field = "battery_level", .kind = .uint32 },
    .{ .key = "BatteryThreshold", .field = "battery_threshold", .kind = .uint32 },
    .{ .key = "UpdateState", .field = "update_state", .kind = .update_state },
    .{ .key = "UpdateError", .field = "update_error", .kind = .string },
    .{ .key = "Checksum", .field = "checksum", .kind = .string },
    .{ .key = "Issues", .field = "issues", .kind = .strv },
    .{ .key = "DetailsUrl", .field = "details_url", .kind = .string },
    .{ .key = "Status", .field = "status", .kind = .status },
    .{ .key = "Percentage", .field = "percentage", .kind = .uint32 },
};

pub fn parseDevice(alloc: std.mem.Allocator, dict: *glib.Variant) std.mem.Allocator.Error!Device {
    // `Release` (embedded history releases) is a known key we deliberately don't parse.
    return parseDict(Device, &device_specs, &.{"Release"}, alloc, dict, "device");
}

const release_specs = [_]Spec{
    .{ .key = "Version", .field = "version", .kind = .string },
    .{ .key = "Name", .field = "name", .kind = .string },
    .{ .key = "Summary", .field = "summary", .kind = .string },
    .{ .key = "Description", .field = "description", .kind = .string },
    .{ .key = "TrustFlags", .field = "trust_flags", .kind = .uint64 },
    .{ .key = "Urgency", .field = "urgency", .kind = .urgency },
    .{ .key = "Locations", .field = "locations", .kind = .strv },
    .{ .key = "Uri", .field = "uri", .kind = .string },
    .{ .key = "RemoteId", .field = "remote_id", .kind = .string },
    .{ .key = "Checksum", .field = "checksum", .kind = .string },
    .{ .key = "Filename", .field = "filename", .kind = .string },
    .{ .key = "Size", .field = "size", .kind = .uint64 },
    .{ .key = "InstallDuration", .field = "install_duration", .kind = .uint32 },
    .{ .key = "Created", .field = "created", .kind = .uint64 },
    .{ .key = "License", .field = "license", .kind = .string },
    .{ .key = "Homepage", .field = "homepage", .kind = .string },
    .{ .key = "AppstreamId", .field = "appstream_id", .kind = .string },
    .{ .key = "Protocol", .field = "protocol", .kind = .string },
    .{ .key = "Vendor", .field = "vendor", .kind = .string },
    .{ .key = "Branch", .field = "branch", .kind = .string },
    .{ .key = "Categories", .field = "categories", .kind = .strv },
    .{ .key = "Issues", .field = "issues", .kind = .strv },
    .{ .key = "Tags", .field = "tags", .kind = .strv },
    .{ .key = "DetailsUrl", .field = "details_url", .kind = .string },
    .{ .key = "SourceUrl", .field = "source_url", .kind = .string },
    .{ .key = "SbomUrl", .field = "sbom_url", .kind = .string },
    .{ .key = "UpdateMessage", .field = "update_message", .kind = .string },
    .{ .key = "UpdateImage", .field = "update_image", .kind = .string },
    .{ .key = "NameVariantSuffix", .field = "name_variant_suffix", .kind = .string },
    .{ .key = "ReleaseId", .field = "release_id", .kind = .string },
    .{ .key = "DetachCaption", .field = "detach_caption", .kind = .string },
    .{ .key = "DetachImage", .field = "detach_image", .kind = .string },
};

pub fn parseRelease(alloc: std.mem.Allocator, dict: *glib.Variant) std.mem.Allocator.Error!Release {
    // Nested `Metadata`/`Reports` dicts are known but not parsed.
    return parseDict(Release, &release_specs, &.{ "Metadata", "Reports" }, alloc, dict, "release");
}

const remote_specs = [_]Spec{
    .{ .key = "RemoteId", .field = "remote_id", .kind = .string },
    .{ .key = "Title", .field = "title", .kind = .string },
    .{ .key = "Type", .field = "kind", .kind = .remote_kind },
    .{ .key = "Enabled", .field = "enabled", .kind = .boolean },
    .{ .key = "ApprovalRequired", .field = "approval_required", .kind = .boolean },
    .{ .key = "AutomaticReports", .field = "automatic_reports", .kind = .boolean },
    .{ .key = "AutomaticSecurityReports", .field = "automatic_security_reports", .kind = .boolean },
    .{ .key = "Priority", .field = "priority", .kind = .int32 },
    .{ .key = "Uri", .field = "uri", .kind = .string },
    .{ .key = "FirmwareBaseUri", .field = "firmware_base_uri", .kind = .string },
    .{ .key = "FilenameCache", .field = "filename_cache", .kind = .string },
    .{ .key = "FilenameSource", .field = "filename_source", .kind = .string },
    .{ .key = "RemotesDir", .field = "remotes_dir", .kind = .string },
    .{ .key = "Checksum", .field = "checksum", .kind = .string },
    .{ .key = "Username", .field = "username", .kind = .string },
    .{ .key = "Password", .field = "password", .kind = .string },
    .{ .key = "ReportUri", .field = "report_uri", .kind = .string },
    .{ .key = "PrivacyUri", .field = "privacy_uri", .kind = .string },
    .{ .key = "Agreement", .field = "agreement", .kind = .string },
    .{ .key = "ModificationTime", .field = "modification_time", .kind = .uint64 },
    .{ .key = "RefreshInterval", .field = "refresh_interval", .kind = .uint64 },
    .{ .key = "Flags", .field = "flags", .kind = .uint64 },
};

pub fn parseRemote(alloc: std.mem.Allocator, dict: *glib.Variant) std.mem.Allocator.Error!Remote {
    return parseDict(Remote, &remote_specs, &.{}, alloc, dict, "remote");
}

const request_specs = [_]Spec{
    .{ .key = "AppstreamId", .field = "appstream_id", .kind = .string },
    .{ .key = "DeviceId", .field = "device_id", .kind = .string },
    .{ .key = "RequestKind", .field = "kind", .kind = .request_kind },
    .{ .key = "UpdateMessage", .field = "update_message", .kind = .string },
    .{ .key = "UpdateImage", .field = "update_image", .kind = .string },
    .{ .key = "Created", .field = "created", .kind = .uint64 },
    .{ .key = "Flags", .field = "flags", .kind = .uint64 },
};

pub fn parseRequest(alloc: std.mem.Allocator, dict: *glib.Variant) std.mem.Allocator.Error!Request {
    return parseDict(Request, &request_specs, &.{}, alloc, dict, "request");
}

const daemon_props_specs = [_]Spec{
    .{ .key = "DaemonVersion", .field = "daemon_version", .kind = .string },
    .{ .key = "Status", .field = "status", .kind = .status },
    .{ .key = "Percentage", .field = "percentage", .kind = .uint32 },
    .{ .key = "PercentageFull", .field = "percentage_full", .kind = .double },
    .{ .key = "BatteryLevel", .field = "battery_level", .kind = .uint32 },
    .{ .key = "BatteryThreshold", .field = "battery_threshold", .kind = .uint32 },
    .{ .key = "OnlyTrusted", .field = "only_trusted", .kind = .boolean },
};

pub fn parseDaemonProps(alloc: std.mem.Allocator, dict: *glib.Variant) std.mem.Allocator.Error!DaemonProps {
    return parseDict(DaemonProps, &daemon_props_specs, &.{}, alloc, dict, "daemon-props");
}

// ---------------------------------------------------------------------------
// Pure logic
// ---------------------------------------------------------------------------

pub const Classification = enum { upgrade, downgrade, reinstall, blocked, other };

/// Daemon trust flags decide first; blocked releases are never installable even when
/// also flagged as upgrades. Reinstall is plain version-string equality: releases
/// carry no `VersionRaw`, and the daemon enforces version policy via install options.
pub fn classifyRelease(device: Device, release: Release) Classification {
    const trust = release.trust_flags;
    if (trust & (enums.TrustFlags.blocked_version | enums.TrustFlags.blocked_approval) != 0) return .blocked;
    if (trust & enums.TrustFlags.is_upgrade != 0) return .upgrade;
    if (trust & enums.TrustFlags.is_downgrade != 0) return .downgrade;
    if (release.version.len > 0 and std.mem.eql(u8, release.version, device.version)) return .reinstall;
    return .other;
}

/// Index of the latest upgrade: the first release the daemon flags as an upgrade,
/// in daemon order. Never `releases[0]` blindly, never string-sorted.
pub fn latestUpgradeIndex(device: Device, releases: []const Release) ?usize {
    for (releases, 0..) |release, i| {
        if (classifyRelease(device, release) == .upgrade) return i;
    }
    return null;
}

pub const ChecksumAlgo = enum {
    sha512,
    sha256,
    sha1,

    fn rank(self: ChecksumAlgo) u8 {
        return switch (self) {
            .sha1 => 0,
            .sha256 => 1,
            .sha512 => 2,
        };
    }
};

pub const Checksum = struct {
    algo: ChecksumAlgo,
    hex: []const u8,
};

/// Pick the strongest digest from a release's comma-joined `Checksum` string.
/// Algorithm is inferred from hex length (128=SHA512, 64=SHA256, 40=SHA1);
/// MD5 (32) and malformed entries are rejected. Null when nothing usable remains;
/// the download layer turns that into `error.ReleaseWithoutChecksums`.
pub fn pickChecksum(joined: []const u8) ?Checksum {
    var best: ?Checksum = null;
    var it = std.mem.splitScalar(u8, joined, ',');
    while (it.next()) |part| {
        const hex = std.mem.trim(u8, part, " \t");
        const algo: ChecksumAlgo = switch (hex.len) {
            128 => .sha512,
            64 => .sha256,
            40 => .sha1,
            else => continue,
        };
        if (!isHex(hex)) continue;
        if (best == null or algo.rank() > best.?.algo.rank()) {
            best = .{ .algo = algo, .hex = hex };
        }
    }
    return best;
}

fn isHex(text: []const u8) bool {
    for (text) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Stream-hash a payload file and compare against the expected digest.
/// Returns false on mismatch; IO errors propagate.
pub fn verifyFile(io: std.Io, dir: std.Io.Dir, path: []const u8, checksum: Checksum) !bool {
    var expected_buf: [64]u8 = undefined;
    const expected = std.fmt.hexToBytes(&expected_buf, checksum.hex) catch return error.InvalidChecksum;

    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var read_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const reader = &file_reader.interface;

    switch (checksum.algo) {
        inline else => |algo| {
            const Hash = switch (algo) {
                .sha512 => std.crypto.hash.sha2.Sha512,
                .sha256 => std.crypto.hash.sha2.Sha256,
                .sha1 => std.crypto.hash.Sha1,
            };
            if (expected.len != Hash.digest_length) return error.InvalidChecksum;
            var hasher = Hash.init(.{});
            while (true) {
                const chunk = reader.peekGreedy(1) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return err,
                };
                hasher.update(chunk);
                reader.toss(chunk.len);
            }
            var digest: [Hash.digest_length]u8 = undefined;
            hasher.final(&digest);
            return std.mem.eql(u8, &digest, expected);
        },
    }
}

pub const PayloadLocation = union(enum) {
    url: []const u8,
    path: []const u8,
};

/// Resolve where a release payload lives:
/// `Locations[0]` wins over legacy `Uri`; local remotes read from the daemon's cache
/// directory, directory remotes strip `file://`, download remotes apply the
/// `FirmwareBaseUri` CDN rewrite or resolve bare filenames against the metadata URL.
pub fn resolvePayloadUrl(alloc: std.mem.Allocator, release: Release, remote: Remote) !PayloadLocation {
    const base = if (release.locations.len > 0) release.locations[0] else release.uri;
    if (base.len == 0) return error.NoPayloadLocation;

    switch (remote.kind) {
        .local => {
            const dir = std.fs.path.dirname(remote.filename_cache) orelse "";
            return .{ .path = try std.fs.path.join(alloc, &.{ dir, urlBasename(base) }) };
        },
        .directory => {
            const stripped = if (std.mem.startsWith(u8, base, "file://")) base["file://".len..] else base;
            return .{ .path = try alloc.dupe(u8, stripped) };
        },
        else => {
            if (remote.firmware_base_uri.len > 0) {
                const trimmed = std.mem.trimEnd(u8, remote.firmware_base_uri, "/");
                return .{ .url = try std.mem.concat(alloc, u8, &.{ trimmed, "/", urlBasename(base) }) };
            }
            if (std.mem.indexOfScalar(u8, base, '/') == null) {
                return .{ .url = try std.mem.concat(alloc, u8, &.{ urlDirname(remote.uri), "/", base }) };
            }
            return .{ .url = try alloc.dupe(u8, base) };
        },
    }
}

/// URL-aware basename/dirname: unlike std.fs.path these never collapse the `//`
/// after a URL scheme.
fn urlBasename(url: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, url, '/')) |i| return url[i + 1 ..];
    return url;
}

fn urlDirname(url: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, url, '/')) |i| return url[0..i];
    return "";
}

/// Map a bare fwupd D-Bus error name (prefix already stripped by the service layer)
/// to the enum; unrecognized names fall back to `.unknown`.
pub fn mapError(name: []const u8) enums.Error {
    return enums.Error.fromName(name) orelse .unknown;
}

/// Friendly dialog text for every fwupd error.
pub fn errorText(err: enums.Error) [:0]const u8 {
    return switch (err) {
        .internal => translations._("Internal error"),
        .version_newer => translations._("Installed newer firmware version"),
        .version_same => translations._("Installed same firmware version"),
        .already_pending => translations._("Already set to be installed offline"),
        .auth_failed => translations._("Failed to get authentication"),
        .read => translations._("Failed to read from device"),
        .write => translations._("Failed to write to the device"),
        .invalid_file => translations._("Invalid file format"),
        .not_found => translations._("No matching device exists"),
        .nothing_to_do => translations._("Nothing to do"),
        .not_supported => translations._("Action was not possible"),
        .signature_invalid => translations._("Signature was invalid"),
        .ac_power_required => translations._("AC power was required"),
        .permission_denied => translations._("Permission was denied"),
        .broken_system => translations._("User has configured their system in a broken way"),
        .battery_level_too_low => translations._("The system battery level is too low"),
        .needs_user_action => translations._("User needs to do an action to complete the update"),
        .auth_expired => translations._("Failed to get authentication: credentials expired"),
        .invalid_data => translations._("The firmware data is invalid"),
        .timed_out => translations._("The operation timed out"),
        .busy => translations._("The device is busy; try again in a moment"),
        .not_reachable => translations._("The device could not be reached"),
        .unknown => translations._("Unknown error"),
    };
}

/// Progress-banner text for the daemon `Status` property.
pub fn statusText(status: enums.Status) [:0]const u8 {
    return switch (status) {
        .unknown => translations._("Unknown state"),
        .idle => translations._("Idle"),
        .loading => translations._("Loading a resource"),
        .decompressing => translations._("Decompressing firmware"),
        .device_restart => translations._("Restarting the device"),
        .device_write => translations._("Writing to a device"),
        .device_verify => translations._("Verifying (reading) a device"),
        .scheduling => translations._("Scheduling an offline update"),
        .downloading => translations._("A file is downloading"),
        .device_read => translations._("Reading from a device"),
        .device_erase => translations._("Erasing a device"),
        .waiting_for_auth => translations._("Waiting for authentication"),
        .device_busy => translations._("The device is busy"),
        .shutdown => translations._("The daemon is shutting down"),
        .waiting_for_user => translations._("Waiting for user action"),
    };
}

fn batteryValid(level: u32, threshold: u32) bool {
    return level <= 100 and threshold <= 100;
}

fn powerProblemText(
    alloc: std.mem.Allocator,
    base: []const u8,
    level: u32,
    threshold: u32,
) std.mem.Allocator.Error![]const u8 {
    if (batteryValid(level, threshold)) {
        return alloc.print("{s} ({d}%, {s} {d}%)", .{ base, level, translations._("requires"), threshold });
    }
    return base;
}

/// Human-readable reasons a device cannot be updated, covering all 15 problem bits.
/// Power percentages come from the daemon properties (system power) or the device
/// fields (device battery); invalid values fall back to generic wording. Unknown bits
/// produce one generic line.
pub fn problemStrings(
    alloc: std.mem.Allocator,
    device: Device,
    props: DaemonProps,
) std.mem.Allocator.Error![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    if (device.problems == 0) return &.{};

    const generic = translations._("The device has a problem that prevents updates");
    if (device.problems == enums.Problem.unknown) {
        try list.append(alloc, generic);
        return list.items;
    }

    inline for (std.enums.values(enums.Problem)) |problem| {
        if (device.problems & @backingInt(problem) != 0) {
            const text: []const u8 = switch (problem) {
                .system_power_too_low => try powerProblemText(
                    alloc,
                    translations._("System power is too low to perform the update"),
                    props.battery_level,
                    props.battery_threshold,
                ),
                .@"unreachable" => translations._("Device is unreachable, or out of wireless range"),
                .power_too_low => try powerProblemText(
                    alloc,
                    translations._("Device battery power is too low"),
                    device.battery_level,
                    device.battery_threshold,
                ),
                .update_pending => translations._("Device is waiting for the update to be applied"),
                .require_ac_power => translations._("Device requires AC power to be connected"),
                .lid_is_closed => translations._("Device cannot be used while the lid is closed"),
                .is_emulated => translations._("Device is emulated"),
                .missing_license => translations._("The firmware license is missing"),
                .system_inhibit => translations._("Another process is blocking firmware updates"),
                .update_in_progress => translations._("Device is already being updated"),
                .in_use => translations._("Device is in use"),
                .display_required => translations._("Device cannot be used while there are no displays plugged in"),
                .lower_priority => translations._("A higher-priority connection to this device is in use"),
                .insecure_platform => translations._("The device is signed with an insecure key"),
                .firmware_locked => translations._("Device firmware is locked"),
            };
            try list.append(alloc, text);
        }
    }

    if (device.problems & ~enums.Problem.known_mask != 0) {
        try list.append(alloc, generic);
    }
    return list.items;
}

/// fwupd emits noisy `DeviceChanged` signals with identical content; drop those.
/// Returns true when the new dict carries no UI-relevant change.
pub fn dedupeDeviceChanged(old: Device, new: Device) bool {
    return std.mem.eql(u8, old.device_id, new.device_id) and
        std.mem.eql(u8, old.version, new.version) and
        old.flags == new.flags and
        old.problems == new.problems and
        old.update_state == new.update_state;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build an `a{sv}` fixture from GVariant text format, e.g.
/// `{'DeviceId': <'dev1'>, 'Flags': <uint64 2>}`.
fn fixture(text: [:0]const u8) *glib.Variant {
    const vt = glib.VariantType.new("a{sv}");
    defer vt.free();
    var err: ?*glib.Error = null;
    const v = glib.Variant.parse(vt, text, null, null, &err);
    if (err) |e| {
        std.debug.panic("fwupd fixture parse failed: {s}", .{std.mem.span(e.f_message orelse "unknown")});
    }
    return v orelse unreachable;
}

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

test "fwupd device parses a full fixture" {
    var arena = testArena();
    defer arena.deinit();
    const v = fixture(
        \\{'DeviceId': <'dev1'>, 'Name': <'System Firmware'>, 'Vendor': <'Acme'>,
        \\ 'Summary': <'UEFI ESRT'>, 'Plugin': <'uefi_capsule'>, 'Protocol': <'org.uefi.capsule'>,
        \\ 'Version': <'1.2.3'>, 'VersionLowest': <'1.0.0'>, 'VersionRaw': <uint64 66051>,
        \\ 'VersionFormat': <uint32 4>, 'Flags': <uint64 2>, 'Problems': <uint64 1>,
        \\ 'Guid': <['guid-a', 'guid-b']>, 'InstanceIds': <['inst-1']>, 'Icon': <['computer']>,
        \\ 'VendorId': <'PCI:0x1234'>, 'Branch': <'main'>, 'InstallDuration': <uint32 60>,
        \\ 'BatteryLevel': <uint32 80>, 'BatteryThreshold': <uint32 50>,
        \\ 'UpdateState': <uint32 4>, 'UpdateError': <'boom'>, 'Issues': <['CVE-2026-1']>,
        \\ 'Status': <uint32 5>, 'Percentage': <uint32 42>}
    );
    defer v.unref();
    const dev = try parseDevice(arena.allocator(), v);

    try testing.expectEqualStrings("dev1", dev.device_id);
    try testing.expectEqualStrings("System Firmware", dev.name);
    try testing.expectEqualStrings("Acme", dev.vendor);
    try testing.expectEqualStrings("UEFI ESRT", dev.summary);
    try testing.expectEqualStrings("uefi_capsule", dev.plugin);
    try testing.expectEqualStrings("org.uefi.capsule", dev.protocol);
    try testing.expectEqualStrings("1.2.3", dev.version);
    try testing.expectEqualStrings("1.0.0", dev.version_lowest);
    try testing.expectEqual(@as(u64, 66051), dev.version_raw);
    try testing.expectEqual(enums.VersionFormat.triplet, dev.version_format);
    try testing.expectEqual(@as(u64, 2), dev.flags);
    try testing.expectEqual(@as(u64, 1), dev.problems);
    try expectStrings(&.{ "guid-a", "guid-b" }, dev.guid);
    try expectStrings(&.{"inst-1"}, dev.instance_ids);
    try expectStrings(&.{"computer"}, dev.icon);
    try testing.expectEqualStrings("PCI:0x1234", dev.vendor_id);
    try testing.expectEqualStrings("main", dev.branch);
    try testing.expectEqual(@as(u32, 60), dev.install_duration);
    try testing.expectEqual(@as(u32, 80), dev.battery_level);
    try testing.expectEqual(@as(u32, 50), dev.battery_threshold);
    try testing.expectEqual(enums.UpdateState.needs_reboot, dev.update_state);
    try testing.expectEqualStrings("boom", dev.update_error);
    try expectStrings(&.{"CVE-2026-1"}, dev.issues);
    try testing.expectEqual(enums.Status.device_write, dev.status);
    try testing.expectEqual(@as(u32, 42), dev.percentage);
}

test "fwupd device minimal fixture keeps defaults" {
    var arena = testArena();
    defer arena.deinit();
    const v = fixture("{}");
    defer v.unref();
    const dev = try parseDevice(arena.allocator(), v);

    try testing.expectEqualStrings("", dev.device_id);
    try testing.expectEqualStrings("", dev.version);
    try testing.expectEqual(@as(u64, 0), dev.flags);
    try testing.expectEqual(@as(u64, 0), dev.problems);
    try testing.expectEqual(enums.battery_level_invalid, dev.battery_level);
    try testing.expectEqual(enums.battery_level_invalid, dev.battery_threshold);
    try testing.expectEqual(enums.UpdateState.unknown, dev.update_state);
    try testing.expectEqual(@as(usize, 0), dev.icon.len);
}

test "fwupd device skips wrong-typed keys and ignores unknown keys" {
    var arena = testArena();
    defer arena.deinit();
    const v = fixture(
        \\{'DeviceId': <'dev1'>, 'Name': <uint32 5>, 'Flags': <'not-a-number'>,
        \\ 'Icon': <'computer'>, 'Guid': <uint64 7>, 'BatteryLevel': <true>,
        \\ 'TotallyUnknownKey': <'x'>}
    );
    defer v.unref();
    const dev = try parseDevice(arena.allocator(), v);

    try testing.expectEqualStrings("dev1", dev.device_id);
    try testing.expectEqualStrings("", dev.name);
    try testing.expectEqual(@as(u64, 0), dev.flags);
    try testing.expectEqual(@as(usize, 0), dev.icon.len);
    try testing.expectEqual(@as(usize, 0), dev.guid.len);
    try testing.expectEqual(enums.battery_level_invalid, dev.battery_level);
}

test "fwupd release parses locations, legacy uri and comma-joined checksum" {
    var arena = testArena();
    defer arena.deinit();
    const v = fixture(
        \\{'Version': <'1.3.0'>, 'Summary': <'Fixes'>, 'TrustFlags': <uint64 4>,
        \\ 'Urgency': <uint32 3>, 'Locations': <['https://cdn.example/fw.cab', 'https://mirror/fw.cab']>,
        \\ 'Uri': <'https://legacy/fw.cab'>, 'RemoteId': <'lvfs'>,
        \\ 'Checksum': <'aaaa,bbbb'>, 'Filename': <'fw.cab'>, 'Size': <uint64 1024>,
        \\ 'InstallDuration': <uint32 30>, 'UpdateMessage': <'Replug the device'>,
        \\ 'Branch': <'alt'>, 'Issues': <['CVE-2026-2']>}
    );
    defer v.unref();
    const rel = try parseRelease(arena.allocator(), v);

    try testing.expectEqualStrings("1.3.0", rel.version);
    try testing.expectEqualStrings("Fixes", rel.summary);
    try testing.expectEqual(@as(u64, 4), rel.trust_flags);
    try testing.expectEqual(enums.Urgency.high, rel.urgency);
    try expectStrings(&.{ "https://cdn.example/fw.cab", "https://mirror/fw.cab" }, rel.locations);
    try testing.expectEqualStrings("https://legacy/fw.cab", rel.uri);
    try testing.expectEqualStrings("lvfs", rel.remote_id);
    try testing.expectEqualStrings("aaaa,bbbb", rel.checksum);
    try testing.expectEqualStrings("fw.cab", rel.filename);
    try testing.expectEqual(@as(u64, 1024), rel.size);
    try testing.expectEqual(@as(u32, 30), rel.install_duration);
    try testing.expectEqualStrings("Replug the device", rel.update_message);
    try testing.expectEqualStrings("alt", rel.branch);
}

test "fwupd release minimal and wrong-typed fixtures stay tolerant" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const empty = fixture("{}");
    defer empty.unref();
    const rel = try parseRelease(alloc, empty);
    try testing.expectEqualStrings("", rel.version);
    try testing.expectEqual(@as(u64, 0), rel.trust_flags);
    try testing.expectEqual(enums.Urgency.unknown, rel.urgency);
    try testing.expectEqual(@as(usize, 0), rel.locations.len);

    const wrong = fixture("{'TrustFlags': <'4'>, 'Locations': <'https://x/fw.cab'>, 'Size': <uint32 5>}");
    defer wrong.unref();
    const rel2 = try parseRelease(alloc, wrong);
    try testing.expectEqual(@as(u64, 0), rel2.trust_flags);
    try testing.expectEqual(@as(usize, 0), rel2.locations.len);
    try testing.expectEqual(@as(u64, 0), rel2.size);
}

test "fwupd remote parses booleans, int32 priority and Type kind" {
    var arena = testArena();
    defer arena.deinit();
    const v = fixture(
        \\{'RemoteId': <'lvfs'>, 'Title': <'Linux Vendor Firmware Service'>,
        \\ 'Type': <uint32 1>, 'Enabled': <true>, 'ApprovalRequired': <false>,
        \\ 'Priority': <int32 5>, 'Uri': <'https://fwupd.org/downloads/firmware.xml.gz'>,
        \\ 'FirmwareBaseUri': <'https://cdn.lvfs.org/firmware'>,
        \\ 'FilenameCache': <'/var/cache/fwupd/lvfs.xml.gz'>, 'Checksum': <'sigsum'>,
        \\ 'Username': <'user'>, 'Password': <'pass'>, 'RefreshInterval': <uint64 86400>}
    );
    defer v.unref();
    const remote = try parseRemote(arena.allocator(), v);

    try testing.expectEqualStrings("lvfs", remote.remote_id);
    try testing.expectEqual(enums.RemoteKind.download, remote.kind);
    try testing.expect(remote.enabled);
    try testing.expect(!remote.approval_required);
    try testing.expectEqual(@as(i32, 5), remote.priority);
    try testing.expectEqualStrings("https://fwupd.org/downloads/firmware.xml.gz", remote.uri);
    try testing.expectEqualStrings("https://cdn.lvfs.org/firmware", remote.firmware_base_uri);
    try testing.expectEqualStrings("/var/cache/fwupd/lvfs.xml.gz", remote.filename_cache);
    try testing.expectEqualStrings("sigsum", remote.checksum);
    try testing.expectEqualStrings("user", remote.username);
    try testing.expectEqual(@as(u64, 86400), remote.refresh_interval);
}

test "fwupd remote wrong-typed Enabled/Priority fall back to defaults" {
    var arena = testArena();
    defer arena.deinit();
    // Enabled is b and Priority is i on the wire, not integer flags.
    const v = fixture("{'Enabled': <uint64 1>, 'Priority': <uint32 5>, 'Type': <uint32 99>}");
    defer v.unref();
    const remote = try parseRemote(arena.allocator(), v);
    try testing.expect(!remote.enabled);
    try testing.expectEqual(@as(i32, 0), remote.priority);
    try testing.expectEqual(enums.RemoteKind.unknown, remote.kind);
}

test "fwupd request parses kind and flags" {
    var arena = testArena();
    defer arena.deinit();
    const v = fixture(
        \\{'AppstreamId': <'org.freedesktop.fwupd.request.remove-replug'>,
        \\ 'DeviceId': <'dev1'>, 'RequestKind': <uint32 2>,
        \\ 'UpdateMessage': <'Please replug'>, 'Flags': <uint64 5>}
    );
    defer v.unref();
    const req = try parseRequest(arena.allocator(), v);
    try testing.expectEqualStrings("org.freedesktop.fwupd.request.remove-replug", req.appstream_id);
    try testing.expectEqualStrings("dev1", req.device_id);
    try testing.expectEqual(enums.RequestKind.immediate, req.kind);
    try testing.expectEqualStrings("Please replug", req.update_message);
    try testing.expectEqual(@as(u64, 5), req.flags);
}

test "fwupd daemon props parse double PercentageFull and battery fields" {
    var arena = testArena();
    defer arena.deinit();
    const v = fixture(
        \\{'DaemonVersion': <'2.1.10'>, 'Status': <uint32 1>, 'Percentage': <uint32 42>,
        \\ 'PercentageFull': <double 42.5>, 'BatteryLevel': <uint32 80>,
        \\ 'BatteryThreshold': <uint32 50>, 'OnlyTrusted': <true>}
    );
    defer v.unref();
    const props = try parseDaemonProps(arena.allocator(), v);
    try testing.expectEqualStrings("2.1.10", props.daemon_version);
    try testing.expectEqual(enums.Status.idle, props.status);
    try testing.expectEqual(@as(u32, 42), props.percentage);
    try testing.expectEqual(@as(f64, 42.5), props.percentage_full);
    try testing.expectEqual(@as(u32, 80), props.battery_level);
    try testing.expectEqual(@as(u32, 50), props.battery_threshold);
    try testing.expect(props.only_trusted);

    const empty = fixture("{}");
    defer empty.unref();
    const defaults = try parseDaemonProps(arena.allocator(), empty);
    try testing.expectEqual(enums.battery_level_invalid, defaults.battery_level);
    try testing.expect(defaults.only_trusted);
}

test "fwupd release classification follows trust flags before version equality" {
    const device = Device{ .version = "1.0.0" };
    const T = enums.TrustFlags;

    try testing.expectEqual(Classification.upgrade, classifyRelease(device, .{ .version = "1.1.0", .trust_flags = T.is_upgrade }));
    try testing.expectEqual(Classification.downgrade, classifyRelease(device, .{ .version = "0.9.0", .trust_flags = T.is_downgrade }));
    try testing.expectEqual(Classification.reinstall, classifyRelease(device, .{ .version = "1.0.0" }));
    try testing.expectEqual(Classification.other, classifyRelease(device, .{ .version = "0.9.0" }));
    try testing.expectEqual(Classification.other, classifyRelease(device, .{ .version = "" }));
    // Blocked wins even when the daemon also flags an upgrade.
    try testing.expectEqual(Classification.blocked, classifyRelease(device, .{ .version = "1.1.0", .trust_flags = T.is_upgrade | T.blocked_version }));
    try testing.expectEqual(Classification.blocked, classifyRelease(device, .{ .version = "1.0.0", .trust_flags = T.blocked_approval }));
    // Community support is a badge, not a classification change.
    try testing.expectEqual(Classification.upgrade, classifyRelease(device, .{ .version = "1.1.0", .trust_flags = T.is_upgrade | T.is_community }));
}

test "fwupd latest upgrade picks the first flagged upgrade in daemon order" {
    const device = Device{ .version = "1.0.0" };
    const releases = [_]Release{
        .{ .version = "2.0.0", .trust_flags = enums.TrustFlags.blocked_version },
        .{ .version = "1.0.0" },
        .{ .version = "1.2.0", .trust_flags = enums.TrustFlags.is_upgrade },
        .{ .version = "1.1.0", .trust_flags = enums.TrustFlags.is_upgrade },
    };
    try testing.expectEqual(@as(?usize, 2), latestUpgradeIndex(device, &releases));
    try testing.expectEqual(@as(?usize, null), latestUpgradeIndex(device, releases[0..2]));
    try testing.expectEqual(@as(?usize, null), latestUpgradeIndex(device, &.{}));
}

test "fwupd checksum picker prefers SHA512 over SHA256 over SHA1 and rejects MD5" {
    const sha1: [40]u8 = @splat('a');
    const sha256: [64]u8 = @splat('b');
    const sha512: [128]u8 = @splat('c');
    const md5: [32]u8 = @splat('d');

    const best = pickChecksum(sha1 ++ "," ++ sha512 ++ "," ++ sha256).?;
    try testing.expectEqual(ChecksumAlgo.sha512, best.algo);
    try testing.expectEqualStrings(&sha512, best.hex);

    const mid = pickChecksum(sha1 ++ "," ++ sha256).?;
    try testing.expectEqual(ChecksumAlgo.sha256, mid.algo);

    const low = pickChecksum(&sha1).?;
    try testing.expectEqual(ChecksumAlgo.sha1, low.algo);

    try testing.expect(pickChecksum(&md5) == null);
    try testing.expect(pickChecksum("") == null);
    try testing.expect(pickChecksum("zz") == null);
    // Non-hex characters invalidate an otherwise right-sized entry.
    const non_hex: [64]u8 = @splat('g');
    try testing.expect(pickChecksum(&non_hex) == null);
    // Whitespace around entries is trimmed; first of equal rank wins.
    const spaced = pickChecksum(" " ++ sha256 ++ " , " ++ sha256).?;
    try testing.expectEqualStrings(&sha256, spaced.hex);
}

test "fwupd verifyFile accepts matching digests and rejects mismatches" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = "firmware payload bytes\x00\x01\x02";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "payload.bin", .data = data });

    var sha256_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &sha256_digest, .{});
    const sha256_hex = std.fmt.bytesToHex(sha256_digest, .lower);
    try testing.expect(try verifyFile(testing.io, tmp.dir, "payload.bin", .{ .algo = .sha256, .hex = &sha256_hex }));

    var sha512_digest: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(data, &sha512_digest, .{});
    const sha512_hex = std.fmt.bytesToHex(sha512_digest, .upper);
    try testing.expect(try verifyFile(testing.io, tmp.dir, "payload.bin", .{ .algo = .sha512, .hex = &sha512_hex }));

    var sha1_digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(data, &sha1_digest, .{});
    const sha1_hex = std.fmt.bytesToHex(sha1_digest, .lower);
    try testing.expect(try verifyFile(testing.io, tmp.dir, "payload.bin", .{ .algo = .sha1, .hex = &sha1_hex }));

    var wrong = sha256_hex;
    wrong[0] = if (wrong[0] == '0') '1' else '0';
    try testing.expect(!try verifyFile(testing.io, tmp.dir, "payload.bin", .{ .algo = .sha256, .hex = &wrong }));

    // Digest length must match the algorithm.
    try testing.expectError(error.InvalidChecksum, verifyFile(testing.io, tmp.dir, "payload.bin", .{ .algo = .sha256, .hex = &sha1_hex }));
}

test "fwupd verifyFile streams files larger than the read buffer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = testArena();
    defer arena.deinit();
    const data = try arena.allocator().alloc(u8, 256 * 1024);
    for (data, 0..) |*byte, i| byte.* = @truncate(i *% 31);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.bin", .data = data });

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try testing.expect(try verifyFile(testing.io, tmp.dir, "big.bin", .{ .algo = .sha256, .hex = &hex }));
}

test "fwupd payload URL resolution matrix" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const download = Remote{ .kind = .download, .uri = "https://fwupd.org/downloads/firmware.xml.gz" };

    // Absolute URL passes through unchanged; Locations wins over legacy Uri.
    const abs = Release{ .locations = &.{"https://cdn.example/fw/1.2.cab"}, .uri = "https://legacy/old.cab" };
    const abs_loc = try resolvePayloadUrl(alloc, abs, download);
    try testing.expectEqualStrings("https://cdn.example/fw/1.2.cab", abs_loc.url);

    // Legacy Uri fallback.
    const legacy = Release{ .uri = "https://fwupd.org/downloads/1.2.cab" };
    try testing.expectEqualStrings("https://fwupd.org/downloads/1.2.cab", (try resolvePayloadUrl(alloc, legacy, download)).url);

    // CDN rewrite via FirmwareBaseUri (trailing slash trimmed, basename kept).
    const cdn = Remote{ .kind = .download, .uri = download.uri, .firmware_base_uri = "https://cdn.lvfs.org/firmware/" };
    try testing.expectEqualStrings("https://cdn.lvfs.org/firmware/1.2.cab", (try resolvePayloadUrl(alloc, abs, cdn)).url);

    // Bare filename resolves against the metadata URL's directory.
    const bare = Release{ .locations = &.{"1.2.cab"} };
    try testing.expectEqualStrings("https://fwupd.org/downloads/1.2.cab", (try resolvePayloadUrl(alloc, bare, download)).url);

    // Local remote: daemon cache directory + payload basename.
    const local = Remote{ .kind = .local, .filename_cache = "/var/cache/fwupd/lvfs.xml.gz" };
    const local_loc = try resolvePayloadUrl(alloc, abs, local);
    try testing.expectEqualStrings("/var/cache/fwupd/1.2.cab", local_loc.path);

    // Directory remote: strip file://.
    const directory = Remote{ .kind = .directory };
    const dir_rel = Release{ .locations = &.{"file:///srv/firmware/1.2.cab"} };
    try testing.expectEqualStrings("/srv/firmware/1.2.cab", (try resolvePayloadUrl(alloc, dir_rel, directory)).path);

    // No location at all is an error.
    try testing.expectError(error.NoPayloadLocation, resolvePayloadUrl(alloc, .{}, download));
}

test "fwupd error mapping covers all 22 names with friendly text" {
    var count: usize = 0;
    inline for (std.enums.values(enums.Error)) |e| {
        if (e.wireName()) |name| {
            count += 1;
            try testing.expectEqual(e, mapError(name));
            try testing.expect(errorText(e).len > 0);
        }
    }
    try testing.expectEqual(@as(usize, 22), count);
    try testing.expectEqual(enums.Error.unknown, mapError("SomethingNew"));
    try testing.expectEqualStrings("Unknown error", errorText(.unknown));
    try testing.expectEqualStrings("Failed to get authentication", errorText(.auth_failed));
    try testing.expectEqualStrings("Permission was denied", errorText(.permission_denied));
}

test "fwupd problem strings interpolate battery percentages" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const props = DaemonProps{ .battery_level = 20, .battery_threshold = 50 };
    const dev = Device{
        .problems = @backingInt(enums.Problem.system_power_too_low) | @backingInt(enums.Problem.power_too_low),
        .battery_level = 10,
        .battery_threshold = 30,
    };
    const texts = try problemStrings(alloc, dev, props);
    try testing.expectEqual(@as(usize, 2), texts.len);
    try testing.expectEqualStrings("System power is too low to perform the update (20%, requires 50%)", texts[0]);
    try testing.expectEqualStrings("Device battery power is too low (10%, requires 30%)", texts[1]);
}

test "fwupd problem strings fall back to generic wording without battery data" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const dev = Device{ .problems = @backingInt(enums.Problem.system_power_too_low) };
    const texts = try problemStrings(alloc, dev, .{});
    try testing.expectEqual(@as(usize, 1), texts.len);
    try testing.expectEqualStrings("System power is too low to perform the update", texts[0]);
}

test "fwupd problem strings cover known bits, unknown bits and the sentinel" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const none = try problemStrings(alloc, .{}, .{});
    try testing.expectEqual(@as(usize, 0), none.len);

    const common = Device{ .problems = @backingInt(enums.Problem.require_ac_power) | @backingInt(enums.Problem.in_use) };
    const texts = try problemStrings(alloc, common, .{});
    try testing.expectEqual(@as(usize, 2), texts.len);
    try testing.expectEqualStrings("Device requires AC power to be connected", texts[0]);
    try testing.expectEqualStrings("Device is in use", texts[1]);

    const unknown_bit = Device{ .problems = 1 << 20 };
    const unknown_texts = try problemStrings(alloc, unknown_bit, .{});
    try testing.expectEqual(@as(usize, 1), unknown_texts.len);
    try testing.expectEqualStrings("The device has a problem that prevents updates", unknown_texts[0]);

    const sentinel = Device{ .problems = enums.Problem.unknown };
    const sentinel_texts = try problemStrings(alloc, sentinel, .{});
    try testing.expectEqual(@as(usize, 1), sentinel_texts.len);
    try testing.expectEqualStrings("The device has a problem that prevents updates", sentinel_texts[0]);
}

test "fwupd status text covers shutdown and waiting-for-user" {
    try testing.expectEqualStrings("Idle", statusText(.idle));
    try testing.expectEqualStrings("Writing to a device", statusText(.device_write));
    try testing.expectEqualStrings("The daemon is shutting down", statusText(.shutdown));
    try testing.expectEqualStrings("Waiting for user action", statusText(.waiting_for_user));
    try testing.expectEqualStrings("Unknown state", statusText(.unknown));
}

test "fwupd DeviceChanged dedupe drops only fully equal updates" {
    const old = Device{
        .device_id = "dev1",
        .version = "1.0.0",
        .flags = 2,
        .problems = 0,
        .update_state = .success,
    };
    try testing.expect(dedupeDeviceChanged(old, old));

    var changed = old;
    changed.version = "1.1.0";
    try testing.expect(!dedupeDeviceChanged(old, changed));
    changed = old;
    changed.flags = 2 | enums.DeviceFlags.needs_reboot;
    try testing.expect(!dedupeDeviceChanged(old, changed));
    changed = old;
    changed.problems = 1;
    try testing.expect(!dedupeDeviceChanged(old, changed));
    changed = old;
    changed.update_state = .needs_reboot;
    try testing.expect(!dedupeDeviceChanged(old, changed));
    changed = old;
    changed.device_id = "dev2";
    try testing.expect(!dedupeDeviceChanged(old, changed));

    // Fields outside the dedupe set do not keep a noisy signal alive.
    changed = old;
    changed.summary = "different summary";
    try testing.expect(dedupeDeviceChanged(old, changed));
}
