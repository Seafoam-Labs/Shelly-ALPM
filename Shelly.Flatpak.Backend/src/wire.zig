const std = @import("std");

pub const schema_version: u32 = 1;
pub const max_message_size: usize = 16 * 1024 * 1024;

pub const Method = struct {
    pub const install = "install";
    pub const install_ref_file = "install_ref_file";
    pub const install_bundle = "install_bundle";
    pub const update_installed = "update_installed";
    pub const uninstall_installed = "uninstall_installed";
    pub const repair_installed = "repair_installed";
    pub const upgrade_all = "upgrade_all";
    pub const remove_unused = "remove_unused";
    pub const list_installed = "list_installed";
    pub const find_installed = "find_installed";
    pub const list_updates = "list_updates";
    pub const list_unused = "list_unused";
    pub const list_running = "list_running";
    pub const search_remote_refs = "search_remote_refs";
    pub const get_remote_ref = "get_remote_ref";
    pub const launch = "launch";
    pub const kill = "kill";
    pub const list_remotes = "list_remotes";
    pub const add_remote = "add_remote";
    pub const remove_remote = "remove_remote";
    pub const highest_priority_remote = "highest_priority_remote";
    pub const list_remote_refs = "list_remote_refs";
    pub const update_all_appstreams = "update_all_appstreams";
    pub const update_remote_appstream = "update_remote_appstream";
    pub const get_remote_catalog = "get_remote_catalog";
    pub const get_all_remote_catalogs = "get_all_remote_catalogs";
    pub const load_catalog = "load_catalog";
};

pub const Scope = enum(u8) {
    system,
    user,
    unknown,
};

pub const RefKind = enum(u8) {
    app,
    runtime,
    unknown,
};

pub const RequestEnvelope = struct {
    schema: u32,
    operation_id: u64,
    method: []const u8,
    arguments: std.json.Value,
};

pub const ErrorPayload = struct {
    code: []const u8,
    message: []const u8,
    native_code: ?i64 = null,
};

pub const ResponseHeader = struct {
    schema: u32,
    operation_id: u64,
    result: ?std.json.Value = null,
    @"error": ?ErrorPayload = null,
};

pub const EventKind = enum(u8) {
    started,
    status,
    progress,
    failure,
    completed,
};

pub const EventLevel = enum(u8) {
    information,
    warning,
    err,
    success,
};

pub const EventEnvelope = struct {
    schema: u32,
    operation_id: u64,
    kind: EventKind,
    code: []const u8,
    message: []const u8,
    level: EventLevel = .information,
    percentage: ?f64 = null,
    completed: ?u64 = null,
    total: ?u64 = null,
    native_code: ?i64 = null,
};

pub const EmptyArguments = struct {};
pub const BoolResult = struct { value: bool };

pub const InstallArguments = struct {
    id: []const u8,
    remote: []const u8,
    scope: Scope,
    branch: []const u8,
    runtime: bool = false,
};

pub const InstallFileArguments = struct {
    path: []const u8,
    scope: Scope,
};

pub const UpdateInstalledArguments = struct {
    name_or_id: []const u8,
    scope: ?Scope = null,
    commit: ?[]const u8 = null,
};

pub const UninstallInstalledArguments = struct {
    name_or_id: []const u8,
    scope: ?Scope = null,
    remove_unused: bool = false,
};

pub const NameArguments = struct {
    name_or_id: []const u8,
};

pub const QueryArguments = struct {
    query: []const u8,
};

pub const ScopeArguments = struct {
    scope: Scope,
};

pub const RemoteNameArguments = struct {
    remote: []const u8,
};

pub const RemoteMutationArguments = struct {
    name: []const u8,
    scope: Scope,
};

pub const AddRemoteArguments = struct {
    name: []const u8,
    url: []const u8,
    scope: Scope,
    gpg_verify: bool = true,
    gpg_key: ?[]const u8 = null,
};

pub const RemoteRefArguments = struct {
    remote: []const u8,
    name: []const u8,
    branch: []const u8,
    scope: Scope,
};

pub const CatalogArguments = struct {
    remote: []const u8,
    arch: ?[]const u8 = null,
};

pub const CatalogsArguments = struct {
    arch: ?[]const u8 = null,
};

pub const UpdateAppstreamArguments = struct {
    scope: Scope,
    remote: []const u8,
};

pub const LoadCatalogArguments = struct {
    remote: []const u8,
    scope: Scope,
    arch: []const u8,
    path: []const u8,
};

pub const InstalledListMode = enum(u8) {
    applications,
    refs,
};

pub const ListInstalledArguments = struct {
    mode: InstalledListMode = .applications,
};

pub const InstalledApplication = struct {
    id: []const u8,
    name: []const u8,
    arch: []const u8,
    branch: []const u8,
    summary: []const u8,
    version: []const u8,
    latest_commit: []const u8,
    origin: []const u8,
    kind: RefKind,
    installed_size: u64,
    scope: Scope,
};

pub const InstalledRef = struct {
    id: []const u8,
    name: []const u8,
    arch: []const u8,
    branch: []const u8,
    reference: []const u8,
    origin: []const u8,
    version: []const u8,
    summary: []const u8,
    latest_commit: []const u8,
    installed_size: u64,
    kind: RefKind,
    scope: Scope,
    permissions: []const []const u8 = &.{},
};

pub const Ref = struct {
    id: []const u8,
    arch: []const u8,
    branch: []const u8,
    reference: []const u8,
    kind: RefKind,
    scope: Scope,
};

pub const Remote = struct {
    name: []const u8,
    url: []const u8,
    priority: i32,
    scope: Scope,
    gpg_verify: bool,
    nodeps: bool,
    noenumerate: bool,
    remote_type: i32,
    disabled: bool,
};

pub const RemoteRef = struct {
    remote_name: []const u8,
    installed_size: u64,
    download_size: u64,
    eol: ?[]const u8 = null,
    eol_rebase: ?[]const u8 = null,
    scope: Scope,
    permissions: []const []const u8 = &.{},
};

pub const RunningInstance = struct {
    instance_id: []const u8,
    application_id: []const u8,
    arch: []const u8,
    branch: []const u8,
    pid: i32,
    child_pid: i32,
};

pub const UnusedDependency = struct {
    reference: []const u8,
    scope: Scope,
};

pub const CatalogLocation = struct {
    remote: []const u8,
    scope: Scope,
    arch: []const u8,
    path: []const u8,
};
