const std = @import("std");
const protocol = @import("Shelly_Flatpak_Protocol");

const wire = protocol.wire;

pub const Scope = enum(u8) {
    system,
    user,
    unknown,

    pub fn fromWire(value: wire.Scope) Scope {
        return switch (value) {
            .system => .system,
            .user => .user,
            .unknown => .unknown,
        };
    }

    pub fn toWire(value: Scope) wire.Scope {
        return switch (value) {
            .system => .system,
            .user => .user,
            .unknown => .unknown,
        };
    }
};

pub const RefKind = enum(u8) {
    app,
    runtime,
    unknown,

    pub fn fromWire(value: wire.RefKind) RefKind {
        return switch (value) {
            .app => .app,
            .runtime => .runtime,
            .unknown => .unknown,
        };
    }
};

pub const InstalledApplication = struct {
    id: []u8,
    name: []u8,
    arch: []u8,
    branch: []u8,
    summary: []u8,
    version: []u8,
    latest_commit: []u8,
    origin: []u8,
    kind: RefKind,
    installed_size: u64,
    scope: Scope,

    pub fn fromWire(
        allocator: std.mem.Allocator,
        value: wire.InstalledApplication,
    ) !InstalledApplication {
        const id = try allocator.dupe(u8, value.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, value.name);
        errdefer allocator.free(name);
        const arch = try allocator.dupe(u8, value.arch);
        errdefer allocator.free(arch);
        const branch = try allocator.dupe(u8, value.branch);
        errdefer allocator.free(branch);
        const summary = try allocator.dupe(u8, value.summary);
        errdefer allocator.free(summary);
        const version = try allocator.dupe(u8, value.version);
        errdefer allocator.free(version);
        const latest_commit = try allocator.dupe(
            u8,
            value.latest_commit,
        );
        errdefer allocator.free(latest_commit);
        const origin = try allocator.dupe(u8, value.origin);
        errdefer allocator.free(origin);
        return .{
            .id = id,
            .name = name,
            .arch = arch,
            .branch = branch,
            .summary = summary,
            .version = version,
            .latest_commit = latest_commit,
            .origin = origin,
            .kind = .fromWire(value.kind),
            .installed_size = value.installed_size,
            .scope = .fromWire(value.scope),
        };
    }

    pub fn deinit(
        self: *InstalledApplication,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arch);
        allocator.free(self.branch);
        allocator.free(self.summary);
        allocator.free(self.version);
        allocator.free(self.latest_commit);
        allocator.free(self.origin);
        self.* = undefined;
    }

    pub fn deinitSlice(
        allocator: std.mem.Allocator,
        values: []InstalledApplication,
    ) void {
        for (values) |*value| value.deinit(allocator);
        allocator.free(values);
    }
};

pub const InstalledRef = struct {
    id: []u8,
    name: []u8,
    arch: []u8,
    branch: []u8,
    reference: []u8,
    origin: []u8,
    version: []u8,
    summary: []u8,
    latest_commit: []u8,
    installed_size: u64,
    kind: RefKind,
    scope: Scope,
    permissions: [][]u8,

    pub fn fromWire(
        allocator: std.mem.Allocator,
        value: wire.InstalledRef,
    ) !InstalledRef {
        const id = try allocator.dupe(u8, value.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, value.name);
        errdefer allocator.free(name);
        const arch = try allocator.dupe(u8, value.arch);
        errdefer allocator.free(arch);
        const branch = try allocator.dupe(u8, value.branch);
        errdefer allocator.free(branch);
        const reference = try allocator.dupe(u8, value.reference);
        errdefer allocator.free(reference);
        const origin = try allocator.dupe(u8, value.origin);
        errdefer allocator.free(origin);
        const version = try allocator.dupe(u8, value.version);
        errdefer allocator.free(version);
        const summary = try allocator.dupe(u8, value.summary);
        errdefer allocator.free(summary);
        const latest_commit = try allocator.dupe(
            u8,
            value.latest_commit,
        );
        errdefer allocator.free(latest_commit);
        const permissions = try dupeStrings(allocator, value.permissions);
        errdefer freeStrings(allocator, permissions);
        return .{
            .id = id,
            .name = name,
            .arch = arch,
            .branch = branch,
            .reference = reference,
            .origin = origin,
            .version = version,
            .summary = summary,
            .latest_commit = latest_commit,
            .installed_size = value.installed_size,
            .kind = .fromWire(value.kind),
            .scope = .fromWire(value.scope),
            .permissions = permissions,
        };
    }

    pub fn deinit(
        self: *InstalledRef,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arch);
        allocator.free(self.branch);
        allocator.free(self.reference);
        allocator.free(self.origin);
        allocator.free(self.version);
        allocator.free(self.summary);
        allocator.free(self.latest_commit);
        freeStrings(allocator, self.permissions);
        self.* = undefined;
    }

    pub fn deinitSlice(
        allocator: std.mem.Allocator,
        values: []InstalledRef,
    ) void {
        for (values) |*value| value.deinit(allocator);
        allocator.free(values);
    }
};

pub const Ref = struct {
    id: []u8,
    arch: []u8,
    branch: []u8,
    reference: []u8,
    kind: RefKind,
    scope: Scope,

    pub fn fromWire(
        allocator: std.mem.Allocator,
        value: wire.Ref,
    ) !Ref {
        const id = try allocator.dupe(u8, value.id);
        errdefer allocator.free(id);
        const arch = try allocator.dupe(u8, value.arch);
        errdefer allocator.free(arch);
        const branch = try allocator.dupe(u8, value.branch);
        errdefer allocator.free(branch);
        return .{
            .id = id,
            .arch = arch,
            .branch = branch,
            .reference = try allocator.dupe(u8, value.reference),
            .kind = .fromWire(value.kind),
            .scope = .fromWire(value.scope),
        };
    }

    pub fn deinit(self: *Ref, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.arch);
        allocator.free(self.branch);
        allocator.free(self.reference);
        self.* = undefined;
    }

    pub fn deinitSlice(
        allocator: std.mem.Allocator,
        values: []Ref,
    ) void {
        for (values) |*value| value.deinit(allocator);
        allocator.free(values);
    }
};

pub const Remote = struct {
    name: []u8,
    url: []u8,
    priority: i32,
    scope: Scope,
    gpg_verify: bool,
    nodeps: bool,
    noenumerate: bool,
    remote_type: i32,
    disabled: bool,

    pub fn fromWire(
        allocator: std.mem.Allocator,
        value: wire.Remote,
    ) !Remote {
        const name = try allocator.dupe(u8, value.name);
        errdefer allocator.free(name);
        return .{
            .name = name,
            .url = try allocator.dupe(u8, value.url),
            .priority = value.priority,
            .scope = .fromWire(value.scope),
            .gpg_verify = value.gpg_verify,
            .nodeps = value.nodeps,
            .noenumerate = value.noenumerate,
            .remote_type = value.remote_type,
            .disabled = value.disabled,
        };
    }

    pub fn deinit(self: *Remote, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.url);
        self.* = undefined;
    }

    pub fn deinitSlice(
        allocator: std.mem.Allocator,
        values: []Remote,
    ) void {
        for (values) |*value| value.deinit(allocator);
        allocator.free(values);
    }
};

pub const RemoteRef = struct {
    remote_name: []u8,
    installed_size: u64,
    download_size: u64,
    eol: ?[]u8,
    eol_rebase: ?[]u8,
    scope: Scope,
    permissions: [][]u8,

    pub fn fromWire(
        allocator: std.mem.Allocator,
        value: wire.RemoteRef,
    ) !RemoteRef {
        const remote_name = try allocator.dupe(u8, value.remote_name);
        errdefer allocator.free(remote_name);
        const eol = if (value.eol) |text|
            try allocator.dupe(u8, text)
        else
            null;
        errdefer if (eol) |text| allocator.free(text);
        const eol_rebase = if (value.eol_rebase) |text|
            try allocator.dupe(u8, text)
        else
            null;
        errdefer if (eol_rebase) |text| allocator.free(text);
        return .{
            .remote_name = remote_name,
            .installed_size = value.installed_size,
            .download_size = value.download_size,
            .eol = eol,
            .eol_rebase = eol_rebase,
            .scope = .fromWire(value.scope),
            .permissions = try dupeStrings(
                allocator,
                value.permissions,
            ),
        };
    }

    pub fn deinit(self: *RemoteRef, allocator: std.mem.Allocator) void {
        allocator.free(self.remote_name);
        if (self.eol) |value| allocator.free(value);
        if (self.eol_rebase) |value| allocator.free(value);
        freeStrings(allocator, self.permissions);
        self.* = undefined;
    }
};

pub const RunningInstance = struct {
    instance_id: []u8,
    application_id: []u8,
    arch: []u8,
    branch: []u8,
    pid: i32,
    child_pid: i32,

    pub fn fromWire(
        allocator: std.mem.Allocator,
        value: wire.RunningInstance,
    ) !RunningInstance {
        const instance_id = try allocator.dupe(u8, value.instance_id);
        errdefer allocator.free(instance_id);
        const application_id = try allocator.dupe(
            u8,
            value.application_id,
        );
        errdefer allocator.free(application_id);
        const arch = try allocator.dupe(u8, value.arch);
        errdefer allocator.free(arch);
        return .{
            .instance_id = instance_id,
            .application_id = application_id,
            .arch = arch,
            .branch = try allocator.dupe(u8, value.branch),
            .pid = value.pid,
            .child_pid = value.child_pid,
        };
    }

    pub fn deinit(
        self: *RunningInstance,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.instance_id);
        allocator.free(self.application_id);
        allocator.free(self.arch);
        allocator.free(self.branch);
        self.* = undefined;
    }

    pub fn deinitSlice(
        allocator: std.mem.Allocator,
        values: []RunningInstance,
    ) void {
        for (values) |*value| value.deinit(allocator);
        allocator.free(values);
    }
};

pub const UnusedDependency = struct {
    reference: []u8,
    scope: Scope,

    pub fn fromWire(
        allocator: std.mem.Allocator,
        value: wire.UnusedDependency,
    ) !UnusedDependency {
        return .{
            .reference = try allocator.dupe(u8, value.reference),
            .scope = .fromWire(value.scope),
        };
    }

    pub fn deinit(
        self: *UnusedDependency,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.reference);
        self.* = undefined;
    }

    pub fn deinitSlice(
        allocator: std.mem.Allocator,
        values: []UnusedDependency,
    ) void {
        for (values) |*value| value.deinit(allocator);
        allocator.free(values);
    }
};

pub const AppstreamIcon = struct {
    type: []const u8,
    url: []const u8,
    width: ?i32 = null,
    height: ?i32 = null,
    scale: ?i32 = null,
};

pub const AppstreamImage = struct {
    type: []const u8,
    url: []const u8,
    width: ?i32 = null,
    height: ?i32 = null,
};

pub const AppstreamScreenshot = struct {
    is_default: bool,
    caption: []const u8,
    images: []const AppstreamImage,
};

pub const AppstreamRelease = struct {
    version: []const u8,
    type: []const u8,
    timestamp: ?i64 = null,
    description: []const u8,
};

pub const AppstreamApp = struct {
    type: []const u8,
    id: []const u8,
    name: []const u8,
    summary: []const u8,
    project_license: []const u8,
    developer_name: []const u8,
    extends: ?[]const u8,
    description: []const u8,
    categories: []const []const u8,
    keywords: []const []const u8,
    urls: std.StringArrayHashMapUnmanaged([]const u8),
    icons: []const AppstreamIcon,
    screenshots: []const AppstreamScreenshot,
    releases: []const AppstreamRelease,
    is_verified: bool,
    verification_method: ?[]const u8,
    addons: []AppstreamApp,
};

pub const AppstreamCatalog = struct {
    owner_allocator: std.mem.Allocator,
    arena_state: *std.heap.ArenaAllocator,
    remote_name: []const u8,
    scope: Scope,
    arch: []const u8,
    path: []const u8,
    apps: []AppstreamApp,

    pub fn deinit(self: *AppstreamCatalog) void {
        self.arena_state.deinit();
        self.owner_allocator.destroy(self.arena_state);
        self.* = undefined;
    }

    pub fn deinitSlice(
        allocator: std.mem.Allocator,
        catalogs: []AppstreamCatalog,
    ) void {
        for (catalogs) |*catalog| catalog.deinit();
        allocator.free(catalogs);
    }
};

fn dupeStrings(
    allocator: std.mem.Allocator,
    values: []const []const u8,
) ![][]u8 {
    const result = try allocator.alloc([]u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |value| allocator.free(value);
        allocator.free(result);
    }
    for (values, result) |value, *output| {
        output.* = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return result;
}

fn freeStrings(
    allocator: std.mem.Allocator,
    values: [][]u8,
) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}
