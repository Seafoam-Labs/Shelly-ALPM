const std = @import("std");
const diagnostics = @import("diagnostics");
const time = @import("zig-time");

pub const libalpm = struct {
    // Raw libalpm symbols are generated from `alpm_include.h` during the build
    // and exposed as the `alpm_c` module by build.zig.
    pub const alpm = @import("alpm_c");

    pub fn str(ptr: [*c]const u8) ?[:0]const u8 {
        if (ptr == null) return null;
        return std.mem.span(ptr);
    }

    pub const Handle = ?*alpm.alpm_handle_t;
    pub const DatabaseList = ?*alpm.alpm_list_t;
    pub const List = ?*alpm.alpm_list_t;

    pub const Error = enum(i32) { Ok = 0, Memory, System, BadPerms, NotAFile, NotADir, WrongArgs, DiskSpace, HandleNull, HandleNotNull, HandleLock, DbOpen, DbCreate, DbNull, DbNotNull, DbNotFound, DbInvalid, DbInvalidSig, DbVersion, DbWrite, DbRemove, ServerBadUrl, ServerNone, TransNotNull, TransNull, TransDupTarget, TransDupFilename, TransNotInitialized, TransNotPrepared, TransAbort, TransType, TransNotLocked, TransHookFailed, PkgNotFound, PkgIgnored, PkgInvalid, PkgInvalidChecksum, PkgInvalidSig, PkgMissingSig, PkgOpen, PkgCantRemove, PkgInvalidName, PkgInvalidArch, SigMissing, SigInvalid, UnsatisfiedDeps, ConflictingDeps, FileConflicts, DownloadFailed, Gpgme, ExternalDownload, SandboxFailed };

    pub const PackageReason = @import("types.zig").PackageReason;
    pub const ReverseDependencyOptions = @import("types.zig").ReverseDependencyOptions;
    pub const SigLevel = @import("types.zig").SigLevel;

    pub const DatabaseUsage = @import("types.zig").DatabaseUsage;

    pub const TransFlag = @import("types.zig").TransFlag;

    pub const DatabaseOperation = enum {
        all,
        sync,
        search,
        install,
        upgrade,
    };

    pub const Database = struct {
        ptr: *alpm.alpm_db_t,

        pub fn from(data: *anyopaque) ?Database {
            return .{ .ptr = @ptrCast(@alignCast(data)) };
        }

        pub fn name(self: Database) ?[:0]const u8 {
            return str(alpm.alpm_db_get_name(self.ptr));
        }

        pub fn allowUsage(self: Database, required: DatabaseUsage) bool {
            var usage: c_int = 0;

            if (alpm.alpm_db_get_usage(self.ptr, &usage) != 0) return false;

            return (usage & @as(c_int, @intCast(@intFromEnum(required)))) != 0;
        }

        pub fn getPackage(self: Database, pkg_name: [:0]const u8) ?Package {
            const pkg = alpm.alpm_db_get_pkg(self.ptr, pkg_name.ptr) orelse return null;
            return .{ .ptr = pkg };
        }

        pub fn packages(self: Database) ListIterator(Package, Package.from) {
            return .{ .node = alpm.alpm_db_get_pkgcache(self.ptr) };
        }

        pub fn package_cache(self: Database) [*c]alpm.alpm_list_t {
            return alpm.alpm_db_get_pkgcache(self.ptr);
        }

        pub fn getGroup(self: Database, group_name: [:0]const u8) ?AlpmPackageGroup {
            const grp = alpm.alpm_db_get_group(self.ptr, group_name.ptr);
            if (grp == null) return null;
            return .{ .ptr = grp };
        }

        pub fn groups(self: Database) ListIterator(AlpmPackageGroup, AlpmPackageGroup.from) {
            return .{ .node = alpm.alpm_db_get_groupcache(self.ptr) };
        }

        pub fn servers(self: Database) ListIterator([:0]const u8, asStr) {
            return .{ .node = alpm.alpm_db_get_servers(self.ptr) };
        }
        pub fn cacheServers(self: Database) ListIterator([:0]const u8, asStr) {
            return .{ .node = alpm.alpm_db_get_cache_servers(self.ptr) };
        }

        pub fn addServer(self: Database, url: [:0]const u8) bool {
            return alpm.alpm_db_add_server(self.ptr, url.ptr) == 0;
        }

        pub fn isValid(self: Database) bool {
            return alpm.alpm_db_get_valid(self.ptr) == 0;
        }

        pub fn sigLevel(self: Database) i32 {
            return @intCast(alpm.alpm_db_get_siglevel(self.ptr));
        }

        // Basic sig validity
        pub fn checkPgpSignature(self: Database) c_int {
            var siglist: alpm.alpm_siglist_t = .{};
            defer _ = alpm.alpm_siglist_cleanup(&siglist);
            return alpm.alpm_db_check_pgp_signature(self.ptr, &siglist);
        }

        // Full context aware sig validation
        pub fn verify(self: Database) bool {
            const level: c_int = @intCast(alpm.alpm_db_get_siglevel(self.ptr));
            // Database signature checking not enabled -> nothing to enforce.
            if (level & alpm.ALPM_SIG_DATABASE == 0) return true;

            const optional = level & alpm.ALPM_SIG_DATABASE_OPTIONAL != 0;
            const marginal_ok = level & alpm.ALPM_SIG_DATABASE_MARGINAL_OK != 0;
            const unknown_ok = level & alpm.ALPM_SIG_DATABASE_UNKNOWN_OK != 0;

            var siglist: alpm.alpm_siglist_t = .{};
            defer _ = alpm.alpm_siglist_cleanup(&siglist);

            if (alpm.alpm_db_check_pgp_signature(self.ptr, &siglist) != 0) {
                // The only tolerable failure is a missing-but-optional signature.
                const errno: c_int = @intCast(alpm.alpm_errno(alpm.alpm_db_get_handle(self.ptr)));
                return optional and errno == alpm.ALPM_ERR_SIG_MISSING;
            }

            // A signature is present: every result must be valid and trusted to
            // the configured level (libalpm groups VALID and KEY_EXPIRED as valid).
            var i: usize = 0;
            while (i < siglist.count) : (i += 1) {
                const status: c_int = @intCast(siglist.results[i].status);
                const validity: c_int = @intCast(siglist.results[i].validity);
                switch (status) {
                    alpm.ALPM_SIGSTATUS_VALID, alpm.ALPM_SIGSTATUS_KEY_EXPIRED => switch (validity) {
                        alpm.ALPM_SIGVALIDITY_FULL => {},
                        alpm.ALPM_SIGVALIDITY_MARGINAL => if (!marginal_ok) return false,
                        alpm.ALPM_SIGVALIDITY_UNKNOWN => if (!unknown_ok) return false,
                        else => return false, // NEVER
                    },
                    else => return false, // SIG_EXPIRED, KEY_UNKNOWN, KEY_DISABLED, INVALID
                }
            }
            return true;
        }

        pub fn handle(self: Database) Handle {
            return alpm.alpm_db_get_handle(self.ptr);
        }

        pub fn unregister(self: Database) bool {
            return alpm.alpm_db_unregister(self.ptr) == 0;
        }

        pub fn verifyAndReport(self: Database) bool {
            var siglist: alpm.alpm_siglist_t = .{};
            defer _ = alpm.alpm_siglist_cleanup(&siglist);
            const ret = alpm.alpm_db_check_pgp_signature(self.ptr, &siglist);
            if (ret == 0) return true;
            var i: usize = 0;
            while (i < siglist.count) : (i += 1) {
                const r = siglist.results[i];
                if (r.status != alpm.ALPM_SIGSTATUS_VALID) {
                    std.log.warn("Could not verify the signature for repository database {0f}. Review signature status {1d} and validity {2d}.", .{ diagnostics.safe(self.name() orelse "?"), @intFromEnum(r.status), @intFromEnum(r.validity) });
                }
            }
            return false;
        }
    };

    pub const Package = struct {
        pub fn toOwned(self: Package, allocator: std.mem.Allocator, options: ReverseDependencyOptions) std.mem.Allocator.Error!OwnedPackage {
            return OwnedPackageFactory.initWithReverseDependencies(allocator, self, options);
        }

        ptr: *alpm.alpm_pkg_t,

        pub fn from(data: *anyopaque) ?Package {
            return .{ .ptr = @ptrCast(@alignCast(data)) };
        }

        pub fn name(self: Package) ?[:0]const u8 {
            return str(alpm.alpm_pkg_get_name(self.ptr));
        }

        pub fn version(self: Package) ?[:0]const u8 {
            return str(alpm.alpm_pkg_get_version(self.ptr));
        }

        pub fn download_size(self: Package) i64 {
            return @intCast(alpm.alpm_pkg_get_size(self.ptr));
        }

        pub fn install_size(self: Package) i64 {
            return @intCast(alpm.alpm_pkg_get_isize(self.ptr));
        }

        pub fn description(self: Package) ?[:0]const u8 {
            return str(alpm.alpm_pkg_get_desc(self.ptr));
        }

        pub fn url(self: Package) ?[:0]const u8 {
            return str(alpm.alpm_pkg_get_url(self.ptr));
        }

        pub fn repository(self: Package) ?[:0]const u8 {
            const db = alpm.alpm_pkg_get_db(self.ptr);
            if (db == null) return @as([:0]const u8, "local");
            return str(alpm.alpm_db_get_name(db));
        }

        pub fn database(self: Package) ?Database {
            const db = alpm.alpm_pkg_get_db(self.ptr) orelse return null;
            return .{ .ptr = db };
        }

        pub fn replaces(self: Package) ListIterator(Dependency, Dependency.from) {
            return .{ .node = alpm.alpm_pkg_get_replaces(self.ptr) };
        }

        pub fn licenses(self: Package) ListIterator([:0]const u8, asStr) {
            return .{ .node = alpm.alpm_pkg_get_licenses(self.ptr) };
        }

        pub fn groups(self: Package) ListIterator([:0]const u8, asStr) {
            return .{ .node = alpm.alpm_pkg_get_groups(self.ptr) };
        }

        pub fn provides(self: Package) ListIterator(Dependency, Dependency.from) {
            return .{ .node = alpm.alpm_pkg_get_provides(self.ptr) };
        }

        pub fn depends(self: Package) ListIterator(Dependency, Dependency.from) {
            return .{ .node = alpm.alpm_pkg_get_depends(self.ptr) };
        }

        pub fn optional_depends(self: Package) ListIterator(Dependency, Dependency.from) {
            return .{ .node = alpm.alpm_pkg_get_optdepends(self.ptr) };
        }

        pub fn make_depends(self: Package) ListIterator(Dependency, Dependency.from) {
            return .{ .node = alpm.alpm_pkg_get_makedepends(self.ptr) };
        }

        pub fn conflicts(self: Package) ListIterator(Dependency, Dependency.from) {
            return .{ .node = alpm.alpm_pkg_get_conflicts(self.ptr) };
        }

        pub fn install_reason(self: Package) PackageReason {
            return switch (alpm.alpm_pkg_get_reason(self.ptr)) {
                alpm.ALPM_PKG_REASON_EXPLICIT => .Explicit,
                alpm.ALPM_PKG_REASON_DEPEND => .Dependency,
                else => .Unknown,
            };
        }

        pub fn build_date(self: Package) ?time.Time {
            return time.Time.fromUnix(alpm.alpm_pkg_get_builddate(self.ptr), 0);
        }

        pub fn install_date(self: Package) ?time.Time {
            const date = alpm.alpm_pkg_get_installdate(self.ptr);
            if (date == 0) return null;
            return time.Time.fromUnix(date, 0);
        }

        pub fn optional_for(self: Package) ListIterator([:0]const u8, asStr) {
            return .{ .node = alpm.alpm_pkg_compute_optionalfor(self.ptr) };
        }

        pub fn required_by(self: Package) ListIterator([:0]const u8, asStr) {
            return .{ .node = alpm.alpm_pkg_compute_requiredby(self.ptr) };
        }

        /// Returns allocator-owned package names and releases libalpm's
        /// computed list before returning. The caller owns the returned slice
        /// and every string in it.
        pub fn owned_optional_for(self: Package, allocator: std.mem.Allocator) std.mem.Allocator.Error![][]const u8 {
            return dupeComputedStrings(allocator, alpm.alpm_pkg_compute_optionalfor(self.ptr));
        }

        /// Returns allocator-owned package names and releases libalpm's
        /// computed list before returning. The caller owns the returned slice
        /// and every string in it.
        pub fn owned_required_by(self: Package, allocator: std.mem.Allocator) std.mem.Allocator.Error![][]const u8 {
            return dupeComputedStrings(allocator, alpm.alpm_pkg_compute_requiredby(self.ptr));
        }

        pub fn files(self: Package) AlpmFileList {
            return AlpmFileList{ .ptr = alpm.alpm_pkg_get_files(self.ptr) };
        }

        pub fn file_name(self: Package) [:0]const u8 {
            const file_name_str = str(alpm.alpm_pkg_get_filename(self.ptr)) orelse "";
            return file_name_str;
        }

        pub fn base(self: Package) ?[:0]const u8 {
            return str(alpm.alpm_pkg_get_base(self.ptr));
        }
    };

    /// A Zig-owned snapshot of package metadata.
    ///
    /// Unlike `Package`, none of these fields borrow memory from libalpm, so an
    /// `OwnedPackage` remains valid after the originating handle is released.
    pub const OwnedPackage = @import("types.zig").OwnedPackage;
    const OwnedPackageFactory = struct {
        pub fn init(allocator: std.mem.Allocator, package: Package) std.mem.Allocator.Error!OwnedPackage {
            return initWithReverseDependencies(allocator, package, .{});
        }

        pub fn initWithReverseDependencies(
            allocator: std.mem.Allocator,
            package: Package,
            reverse_dependencies: ReverseDependencyOptions,
        ) std.mem.Allocator.Error!OwnedPackage {
            const name_value = try allocator.dupeZ(u8, package.name() orelse "");
            errdefer allocator.free(name_value);

            const base_value = try allocator.dupeZ(u8, package.base() orelse package.name() orelse "");
            errdefer allocator.free(base_value);

            const version_value = try allocator.dupeZ(u8, package.version() orelse "");
            errdefer allocator.free(version_value);

            const description_value = try dupeOptional(allocator, package.description());
            errdefer if (description_value) |value| allocator.free(value);

            const url_value = try dupeOptional(allocator, package.url());
            errdefer if (url_value) |value| allocator.free(value);

            const repository_value = try dupeOptional(allocator, package.repository());
            errdefer if (repository_value) |value| allocator.free(value);

            const file_name_value = try allocator.dupeZ(u8, package.file_name());
            errdefer allocator.free(file_name_value);

            const replaces_value = try dupeDependencies(allocator, package.replaces());
            errdefer freeStrings(allocator, replaces_value);
            const licenses_value = try dupeStrings(allocator, package.licenses());
            errdefer freeStrings(allocator, licenses_value);
            const groups_value = try dupeStrings(allocator, package.groups());
            errdefer freeStrings(allocator, groups_value);
            const provides_value = try dupeDependencies(allocator, package.provides());
            errdefer freeStrings(allocator, provides_value);
            const depends_value = try dupeDependencies(allocator, package.depends());
            errdefer freeStrings(allocator, depends_value);
            const optional_depends_value = try dupeDependencies(allocator, package.optional_depends());
            errdefer freeStrings(allocator, optional_depends_value);
            const conflicts_value = try dupeDependencies(allocator, package.conflicts());
            errdefer freeStrings(allocator, conflicts_value);
            // Reverse dependency computation walks the local package graph, so
            // keep it opt-in for broad queries such as search and list.
            const required_by_value = if (reverse_dependencies.required_by)
                try dupeComputedSentinelStrings(
                    allocator,
                    alpm.alpm_pkg_compute_requiredby(package.ptr),
                )
            else
                try allocator.alloc([:0]u8, 0);
            errdefer freeStrings(allocator, required_by_value);
            const optional_for_value = if (reverse_dependencies.optional_for)
                try dupeComputedSentinelStrings(
                    allocator,
                    alpm.alpm_pkg_compute_optionalfor(package.ptr),
                )
            else
                try allocator.alloc([:0]u8, 0);
            errdefer freeStrings(allocator, optional_for_value);

            const architecture_value = try dupeOptional(allocator, str(alpm.alpm_pkg_get_arch(package.ptr)));
            return .{
                .architecture_value = architecture_value,
                .name_value = name_value,
                .base_value = base_value,
                .version_value = version_value,
                .description_value = description_value,
                .url_value = url_value,
                .repository_value = repository_value,
                .file_name_value = file_name_value,
                .download_size_value = package.download_size(),
                .install_size_value = package.install_size(),
                .reason_value = package.install_reason(),
                .replaces_value = replaces_value,
                .licenses_value = licenses_value,
                .groups_value = groups_value,
                .provides_value = provides_value,
                .depends_value = depends_value,
                .optional_depends_value = optional_depends_value,
                .conflicts_value = conflicts_value,
                .required_by_value = required_by_value,
                .optional_for_value = optional_for_value,
                .build_date_value = if (package.build_date()) |date| date.unix() else 0,
                .install_date_value = if (package.install_date()) |date| date.unix() else null,
            };
        }

        fn dupeOptional(allocator: std.mem.Allocator, value: ?[:0]const u8) std.mem.Allocator.Error!?[:0]u8 {
            return if (value) |text| try allocator.dupeZ(u8, text) else null;
        }

        fn dupeStrings(allocator: std.mem.Allocator, iterator_value: anytype) std.mem.Allocator.Error![][:0]u8 {
            var iterator = iterator_value;
            var values: std.ArrayList([:0]u8) = .empty;
            errdefer {
                for (values.items) |value| allocator.free(value);
                values.deinit(allocator);
            }
            while (iterator.next()) |value| {
                const owned = try allocator.dupeZ(u8, value);
                values.append(allocator, owned) catch |err| {
                    allocator.free(owned);
                    return err;
                };
            }
            return values.toOwnedSlice(allocator);
        }

        fn dupeDependencies(allocator: std.mem.Allocator, iterator_value: anytype) std.mem.Allocator.Error![][:0]u8 {
            var iterator = iterator_value;
            var values: std.ArrayList([:0]u8) = .empty;
            errdefer {
                for (values.items) |value| allocator.free(value);
                values.deinit(allocator);
            }
            while (iterator.next()) |dependency| {
                const value = dependency.computed_dependency_string(allocator) orelse continue;
                values.append(allocator, @constCast(value)) catch |err| {
                    allocator.free(value);
                    return err;
                };
            }
            return values.toOwnedSlice(allocator);
        }

        fn dupeComputedSentinelStrings(
            allocator: std.mem.Allocator,
            list: [*c]alpm.alpm_list_t,
        ) std.mem.Allocator.Error![][:0]u8 {
            defer {
                alpm.alpm_list_free_inner(list, alpm.free);
                alpm.alpm_list_free(list);
            }

            var values: std.ArrayList([:0]u8) = .empty;
            errdefer {
                for (values.items) |value| allocator.free(value);
                values.deinit(allocator);
            }
            var node = list;
            while (node != null) : (node = node.*.next) {
                const data = node.*.data orelse continue;
                const value = asStr(data) orelse continue;
                const owned = try allocator.dupeZ(u8, value);
                values.append(allocator, owned) catch |err| {
                    allocator.free(owned);
                    return err;
                };
            }
            return values.toOwnedSlice(allocator);
        }

        fn freeStrings(allocator: std.mem.Allocator, values: [][:0]u8) void {
            for (values) |value| allocator.free(value);
            allocator.free(values);
        }
    };

    pub const PackageWithUpdate = struct {
        old_package: Package,
        new_package: Package,
    };

    pub const OwnedPackageWithUpdate = @import("types.zig").OwnedPackageWithUpdate;

    pub const Dependency = struct {
        ptr: *alpm.alpm_depend_t,

        pub const Comparator = enum(c_uint) {
            any = alpm.ALPM_DEP_MOD_ANY,
            equal = alpm.ALPM_DEP_MOD_EQ,
            great_equal = alpm.ALPM_DEP_MOD_GE,
            less_equal = alpm.ALPM_DEP_MOD_LE,
            greater_than = alpm.ALPM_DEP_MOD_GT,
            less_than = alpm.ALPM_DEP_MOD_LT,
        };

        pub fn from(data: *anyopaque) ?Dependency {
            return .{ .ptr = @ptrCast(@alignCast(data)) };
        }

        /// Name of the provider that satisfies this dependency
        pub fn name(self: Dependency) ?[:0]const u8 {
            return str(self.ptr.name);
        }

        /// Version that satifies the dependency
        pub fn version(self: Dependency) ?[:0]const u8 {
            return str(self.ptr.version);
        }

        /// Description of the dependency
        pub fn description(self: Dependency) ?[:0]const u8 {
            return str(self.ptr.desc);
        }

        /// Comparison value of the dependency
        pub fn comparison(self: Dependency) Comparator {
            return @enumFromInt(self.ptr.mod);
        }

        pub fn computed_dependency_string(self: Dependency, allocator: std.mem.Allocator) ?[:0]const u8 {
            const computed = alpm.alpm_dep_compute_string(self.ptr);
            if (computed == null) return null;
            defer std.c.free(computed);
            return allocator.dupeZ(u8, std.mem.span(computed)) catch {
                return null;
            };
        }
    };

    pub const AlpmFile = struct {
        ptr: *alpm.alpm_file_t,

        pub fn from(data: *anyopaque) ?AlpmFile {
            return .{ .ptr = @ptrCast(@alignCast(data)) };
        }

        pub fn name(self: AlpmFile) ?[:0]const u8 {
            return str(self.ptr.name);
        }

        pub fn size(self: AlpmFile) i64 {
            return @intCast(self.ptr.size);
        }

        pub fn mode(self: AlpmFile) FileType {
            return FileType.fromMode(self.ptr.mode);
        }
    };

    pub const AlpmFileList = struct {
        ptr: *alpm.alpm_filelist_t,

        pub fn from(data: *anyopaque) ?AlpmFileList {
            return .{ .ptr = @ptrCast(@alignCast(data)) };
        }

        pub fn count(self: AlpmFileList) usize {
            return @intCast(self.ptr.count);
        }

        pub fn files(self: AlpmFileList) FileIterator {
            return .{ .files = self.ptr.files, .len = self.count() };
        }

        pub const FileIterator = struct {
            files: [*c]alpm.alpm_file_t,
            len: usize,
            index: usize = 0,

            pub fn next(self: *FileIterator) ?AlpmFile {
                if (self.index >= self.len) return null;
                const file: *alpm.alpm_file_t = @ptrCast(&self.files[self.index]);
                self.index += 1;
                return .{ .ptr = file };
            }
        };
    };

    pub const AlpmPackageGroup = struct {
        ptr: *alpm.alpm_group_t,

        pub fn from(data: *anyopaque) ?AlpmPackageGroup {
            return .{ .ptr = @ptrCast(@alignCast(data)) };
        }

        pub fn name(self: AlpmPackageGroup) [:0]const u8 {
            return str(self.ptr.name);
        }

        pub fn packages(self: AlpmPackageGroup) ListIterator(Package, Package.from) {
            return .{ .node = self.ptr.packages };
        }
    };

    pub const PackageConflict = struct {
        ptr: *alpm.alpm_conflict_t,

        pub fn from(data: *anyopaque) ?PackageConflict {
            return .{ .ptr = @ptrCast(@alignCast(data)) };
        }

        pub fn packageOne(self: PackageConflict) Package {
            return .{ .ptr = self.ptr.package1.? };
        }

        pub fn packageTwo(self: PackageConflict) Package {
            return .{ .ptr = self.ptr.package2.? };
        }

        pub fn reason(self: PackageConflict) Dependency {
            return .{ .ptr = self.ptr.reason };
        }
    };

    pub const ConflictQuestion = struct {
        ptr: *alpm.alpm_question_conflict_t,

        pub fn from(data: *anyopaque) ?ConflictQuestion {
            return .{ .ptr = @ptrCast(@alignCast(data)) };
        }

        pub fn question_type(self: ConflictQuestion) QuestionType {
            return QuestionType.fromQuestionType(self.ptr.type);
        }

        pub fn confirm_removal(self: ConflictQuestion, confirmRemove: bool) void {
            if (confirmRemove) self.ptr.remove = 1 else self.ptr.remove = 0;
        }

        pub fn conflict(self: ConflictQuestion) PackageConflict {
            return .{ .ptr = self.ptr.conflict };
        }
    };

    pub const InstallIgnoredQuestion = struct {
        ptr: *alpm.alpm_question_install_ignorepkg_t,

        pub fn from(data: *anyopaque) ?InstallIgnoredQuestion {
            return .{ .ptr = @ptrCast(@alignCast(data)) };
        }

        pub fn question_type(self: InstallIgnoredQuestion) QuestionType {
            return QuestionType.fromQuestionType(self.ptr.type);
        }

        pub fn confirm_install(self: InstallIgnoredQuestion, confirmInstallation: bool) void {
            if (confirmInstallation) self.ptr.install = 1 else self.ptr.install = 0;
        }

        pub fn package(self: InstallIgnoredQuestion) Package {
            return .{ .ptr = self.ptr.pkg.? };
        }
    };

    pub const ReplacePackageQuestion = struct {
        ptr: *alpm.alpm_question_replace_t,

        pub fn from(data: *anyopaque) ?ReplacePackageQuestion {
            return .{ .ptr = @ptrCast(@alignCast(data)) };
        }

        pub fn question_type(self: ReplacePackageQuestion) QuestionType {
            return QuestionType.fromQuestionType(self.ptr.type);
        }

        pub fn old_package(self: ReplacePackageQuestion) Package {
            return .{ .ptr = self.ptr.oldpkg.? };
        }

        pub fn new_package(self: ReplacePackageQuestion) Package {
            return .{ .ptr = self.ptr.newpkg.? };
        }

        pub fn new_database(self: ReplacePackageQuestion) Database {
            return .{ .ptr = self.ptr.newdb.? };
        }

        pub fn confirm_replace(self: ReplacePackageQuestion, confirmReplace: bool) void {
            if (confirmReplace) self.ptr.replace = 1 else self.ptr.replace = 0;
        }
    };

    pub const RemoveCorruptedPackagesQuestion = struct {
        ptr: *alpm.alpm_question_corrupted_t,

        pub fn from(data: *anyopaque) ?RemoveCorruptedPackagesQuestion {
            return .{ .ptr = @ptrCast(@alignCast(data)) };
        }

        pub fn question_type(self: RemoveCorruptedPackagesQuestion) QuestionType {
            return QuestionType.fromQuestionType(self.ptr.type);
        }

        pub fn filepath(self: RemoveCorruptedPackagesQuestion) [:0]const u8 {
            return str(self.ptr.filepath) orelse "";
        }

        pub fn reason(self: RemoveCorruptedPackagesQuestion) Error {
            return Error.from(self.ptr.reason);
        }

        pub fn confirm_remove(self: RemoveCorruptedPackagesQuestion, confirmRemove: bool) void {
            if (confirmRemove) self.ptr.remove = 1 else self.ptr.remove = 0;
        }
    };

    pub const RemovePackagesQuestion = struct {
        ptr: *alpm.alpm_question_remove_pkgs_t,

        pub fn from(data: *anyopaque) ?RemovePackagesQuestion {
            return .{ .ptr = @ptrCast(@alignCast(data)) };
        }

        pub fn question_type(self: RemovePackagesQuestion) QuestionType {
            return QuestionType.fromQuestionType(self.ptr.type);
        }

        pub fn packages(self: RemovePackagesQuestion) ListIterator(Package, Package.from) {
            return .{ .node = self.ptr.packages };
        }

        pub fn skipRemoval(self: RemovePackagesQuestion, confirmRemoval: bool) void {
            if (confirmRemoval) self.ptr.skip = 1 else self.ptr.skip = 0;
        }
    };

    pub const SelectProviderQuestion = struct {
        ptr: *alpm.alpm_question_select_provider_t,

        pub fn from(data: *anyopaque) ?SelectProviderQuestion {
            return .{ .ptr = @ptrCast(@alignCast(data)) };
        }

        pub fn question_type(self: SelectProviderQuestion) QuestionType {
            return QuestionType.fromQuestionType(self.ptr.type);
        }

        pub fn choices(self: SelectProviderQuestion) ListIterator(Dependency, Dependency.from) {
            return .{ .node = self.ptr.depend };
        }

        pub fn selected_choice(self: SelectProviderQuestion, select: i32) void {
            self.ptr.use_index = select;
        }
    };

    pub const ImportKeyQuestion = struct {
        ptr: *alpm.alpm_question_import_key_t,

        pub fn from(data: *anyopaque) ?ImportKeyQuestion {
            return .{ .ptr = @ptrCast(@alignCast(data)) };
        }

        pub fn question_type(self: ImportKeyQuestion) QuestionType {
            return QuestionType.fromQuestionType(self.ptr.type);
        }

        pub fn import(self: ImportKeyQuestion, confirmImport: bool) void {
            if (confirmImport) self.ptr.import = 1 else self.ptr.import = 0;
        }

        pub fn uid(self: ImportKeyQuestion) ?[:0]const u8 {
            return str(self.ptr.uid);
        }

        pub fn fingerprint(self: ImportKeyQuestion) ?[:0]const u8 {
            return str(self.ptr.fingerprint);
        }
    };

    pub const QuestionType = @import("types.zig").QuestionType;

    pub const FileType = enum {
        regular,
        directory,
        symlink,
        block_device,
        char_device,
        fifo,
        socket,
        unknown,

        pub fn fromMode(mode: alpm.mode_t) FileType {
            return switch (mode & alpm.S_IFMT) {
                alpm.S_IFREG => .regular,
                alpm.S_IFDIR => .directory,
                alpm.S_IFLNK => .symlink,
                alpm.S_IFBLK => .block_device,
                alpm.S_IFCHR => .char_device,
                alpm.S_IFIFO => .fifo,
                alpm.S_IFSOCK => .socket,
                else => .unknown,
            };
        }
    };

    pub const EventType = @import("types.zig").EventType;

    fn ListIterator(comptime T: type, comptime convert: fn (*anyopaque) ?T) type {
        return struct {
            node: [*c]alpm.alpm_list_t,

            pub fn next(self: *@This()) ?T {
                while (self.node != null) {
                    const data = self.node.*.data;
                    self.node = self.node.*.next;
                    if (data) |data_type| if (convert(data_type)) |concrete| return concrete;
                }
                return null;
            }
        };
    }

    fn dupeComputedStrings(
        allocator: std.mem.Allocator,
        list: [*c]alpm.alpm_list_t,
    ) std.mem.Allocator.Error![][]const u8 {
        defer {
            alpm.alpm_list_free_inner(list, alpm.free);
            alpm.alpm_list_free(list);
        }

        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |item| allocator.free(item);
            result.deinit(allocator);
        }

        var node = list;
        while (node != null) : (node = node.*.next) {
            const data = node.*.data orelse continue;
            const value = asStr(data) orelse continue;
            const owned = try allocator.dupe(u8, value);
            result.append(allocator, owned) catch |err| {
                allocator.free(owned);
                return err;
            };
        }
        return result.toOwnedSlice(allocator);
    }

    fn asStr(data: *anyopaque) ?[:0]const u8 {
        return std.mem.span(@as([*c]const u8, @ptrCast(data)));
    }
};

const testing = std.testing;
const raw = libalpm.alpm;

test "iterator-returning methods type-check" {
    // These methods are analyzed lazily by Zig, so a clean build alone does not
    // prove their `ListIterator(..., X.from)` return types are sound. Referencing
    // them here forces full semantic analysis (return-type instantiation +
    // converter type-check) without invoking any extern libalpm call.
    _ = &libalpm.Package.replaces;
    _ = &libalpm.Package.licenses;
    _ = &libalpm.Package.groups;
    _ = &libalpm.Package.provides;
    _ = &libalpm.Package.depends;
    _ = &libalpm.Package.optional_depends;
    _ = &libalpm.Package.conflicts;
    _ = &libalpm.Package.optional_for;
    _ = &libalpm.Package.required_by;
    _ = &libalpm.Package.owned_optional_for;
    _ = &libalpm.Package.owned_required_by;
    _ = &libalpm.AlpmPackageGroup.packages;
    // PackageConflict accessors have no other callers, so force them too.
    _ = &libalpm.PackageConflict.packageOne;
    _ = &libalpm.PackageConflict.packageTwo;
    _ = &libalpm.PackageConflict.reason;
}

test "str returns null for a null pointer" {
    try testing.expect(libalpm.str(null) == null);
}

test "str spans a null-terminated C string" {
    const c: [*c]const u8 = "hello";
    const span = libalpm.str(c) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("hello", span);
    // The returned slice must carry its sentinel.
    try testing.expectEqual(@as(usize, 5), span.len);
}

test "str spans an empty C string" {
    const c: [*c]const u8 = "";
    const span = libalpm.str(c) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("", span);
    try testing.expectEqual(@as(usize, 0), span.len);
}

test "FileType.fromMode maps every S_IF* constant" {
    const FileType = libalpm.FileType;
    const Case = struct { mode: raw.mode_t, want: FileType };
    const cases = [_]Case{
        .{ .mode = @intCast(raw.S_IFREG), .want = .regular },
        .{ .mode = @intCast(raw.S_IFDIR), .want = .directory },
        .{ .mode = @intCast(raw.S_IFLNK), .want = .symlink },
        .{ .mode = @intCast(raw.S_IFBLK), .want = .block_device },
        .{ .mode = @intCast(raw.S_IFCHR), .want = .char_device },
        .{ .mode = @intCast(raw.S_IFIFO), .want = .fifo },
        .{ .mode = @intCast(raw.S_IFSOCK), .want = .socket },
    };
    for (cases) |c| {
        try testing.expectEqual(c.want, FileType.fromMode(c.mode));
    }
}

test "FileType.fromMode ignores permission bits" {
    // A regular file with rw-r--r-- permissions must still be classified as regular.
    const mode: raw.mode_t = @intCast(raw.S_IFREG | @as(c_int, 0o644));
    try testing.expectEqual(libalpm.FileType.regular, libalpm.FileType.fromMode(mode));
}

test "FileType.fromMode returns unknown for an unrecognized type" {
    // No format bits set: not any known S_IF* value.
    try testing.expectEqual(libalpm.FileType.unknown, libalpm.FileType.fromMode(0));
}

test "Comparator variants match libalpm dependency mode constants" {
    const C = libalpm.Dependency.Comparator;
    try testing.expectEqual(@as(c_int, raw.ALPM_DEP_MOD_ANY), @as(c_int, @intFromEnum(C.any)));
    try testing.expectEqual(@as(c_int, raw.ALPM_DEP_MOD_EQ), @as(c_int, @intFromEnum(C.equal)));
    try testing.expectEqual(@as(c_int, raw.ALPM_DEP_MOD_GE), @as(c_int, @intFromEnum(C.great_equal)));
    try testing.expectEqual(@as(c_int, raw.ALPM_DEP_MOD_LE), @as(c_int, @intFromEnum(C.less_equal)));
    try testing.expectEqual(@as(c_int, raw.ALPM_DEP_MOD_GT), @as(c_int, @intFromEnum(C.greater_than)));
    try testing.expectEqual(@as(c_int, raw.ALPM_DEP_MOD_LT), @as(c_int, @intFromEnum(C.less_than)));
}

test "SigLevel packed struct preserves and combines libalpm signature bits" {
    const level = libalpm.SigLevel{
        .package_optional = true,
        .database_optional = true,
        .use_default = true,
    };
    const raw_level = level.to_sig_level();
    const expected: c_int = @intCast(
        raw.ALPM_SIG_PACKAGE_OPTIONAL |
            raw.ALPM_SIG_DATABASE_OPTIONAL |
            raw.ALPM_SIG_USE_DEFAULT,
    );

    try testing.expectEqual(expected, raw_level);
    try testing.expect(level.contains(.{ .package_optional = true, .database_optional = true }));
    try testing.expect(!level.contains(.{ .package = true }));

    const round_trip = libalpm.SigLevel.from_sig_level(@bitCast(raw_level));
    try testing.expect(round_trip.package_optional);
    try testing.expect(round_trip.database_optional);
    try testing.expect(round_trip.use_default);
    try testing.expect(!round_trip.package);
}

test "TransFlag packed struct preserves and combines libalpm flag bits" {
    const flags = libalpm.TransFlag{
        .nodeps = true,
        .cascade = true,
        .dbonly = true,
    };
    const raw_flags = flags.to_trans_flag();
    const expected: raw.alpm_transflag_t = @intCast(
        raw.ALPM_TRANS_FLAG_NODEPS |
            raw.ALPM_TRANS_FLAG_CASCADE |
            raw.ALPM_TRANS_FLAG_DBONLY,
    );

    try testing.expectEqual(expected, raw_flags);
    try testing.expect(flags.contains(.{ .dbonly = true, .nodeps = true }));
    try testing.expect(!flags.contains(.{ .nosave = true }));

    const round_trip = libalpm.TransFlag.from_trans_flag(raw_flags);
    try testing.expect(round_trip.nodeps);
    try testing.expect(round_trip.cascade);
    try testing.expect(round_trip.dbonly);
    try testing.expect(!round_trip.nosave);
}

test "Dependency accessors read the underlying struct" {
    var name_buf = [_:0]u8{ 'g', 'l', 'i', 'b', 'c' };
    var ver_buf = [_:0]u8{ '2', '.', '3', '9' };
    var desc_buf = [_:0]u8{ 'c', ' ', 'l', 'i', 'b' };

    var dep = raw.alpm_depend_t{
        .name = &name_buf,
        .version = &ver_buf,
        .desc = &desc_buf,
        .mod = @intCast(raw.ALPM_DEP_MOD_GE),
    };
    const d = libalpm.Dependency{ .ptr = &dep };

    try testing.expectEqualStrings("glibc", d.name().?);
    try testing.expectEqualStrings("2.39", d.version().?);
    try testing.expectEqualStrings("c lib", d.description().?);
    try testing.expectEqual(libalpm.Dependency.Comparator.great_equal, d.comparison());
}

test "Dependency accessors return null for unset fields" {
    var dep = raw.alpm_depend_t{
        .name = null,
        .version = null,
        .desc = null,
        .mod = @intCast(raw.ALPM_DEP_MOD_ANY),
    };
    const d = libalpm.Dependency{ .ptr = &dep };

    try testing.expect(d.name() == null);
    try testing.expect(d.version() == null);
    try testing.expect(d.description() == null);
    try testing.expectEqual(libalpm.Dependency.Comparator.any, d.comparison());
}

test "AlpmFile exposes name and mode" {
    var name_buf = [_:0]u8{ '/', 'e', 't', 'c', '/', 'f', 's', 't', 'a', 'b' };
    var file = raw.alpm_file_t{
        .name = &name_buf,
        .size = 512,
        .mode = @intCast(raw.S_IFREG),
    };
    const f = libalpm.AlpmFile{ .ptr = &file };

    try testing.expectEqualStrings("/etc/fstab", f.name().?);
    try testing.expectEqual(libalpm.FileType.regular, f.mode());
}

test "AlpmFileList reports count and iterates its files" {
    var n0 = [_:0]u8{ 'u', 's', 'r', '/' };
    var n1 = [_:0]u8{ 'u', 's', 'r', '/', 'b', 'i', 'n' };

    var files_arr = [_]raw.alpm_file_t{
        .{ .name = &n0, .size = 0, .mode = @intCast(raw.S_IFDIR) },
        .{ .name = &n1, .size = 0, .mode = @intCast(raw.S_IFDIR) },
    };
    var list = raw.alpm_filelist_t{ .count = files_arr.len, .files = &files_arr };
    const fl = libalpm.AlpmFileList{ .ptr = &list };

    try testing.expectEqual(@as(usize, 2), fl.count());

    var it = fl.files();
    try testing.expectEqualStrings("usr/", it.next().?.name().?);
    try testing.expectEqualStrings("usr/bin", it.next().?.name().?);
    try testing.expect(it.next() == null);
}

test "AlpmFileList iterator over an empty list yields nothing" {
    var list = raw.alpm_filelist_t{ .count = 0, .files = null };
    const fl = libalpm.AlpmFileList{ .ptr = &list };

    try testing.expectEqual(@as(usize, 0), fl.count());
    var it = fl.files();
    try testing.expect(it.next() == null);
}

test "ListIterator walks nodes, converts data, and skips null entries" {
    var s0 = [_:0]u8{ 'c', 'o', 'r', 'e' };
    var s2 = [_:0]u8{ 'e', 'x', 't', 'r', 'a' };

    var node2 = raw.alpm_list_t{ .data = @ptrCast(&s2), .prev = null, .next = null };
    // Middle node carries no data and must be skipped by the iterator.
    var node1 = raw.alpm_list_t{ .data = null, .prev = null, .next = &node2 };
    var node0 = raw.alpm_list_t{ .data = @ptrCast(&s0), .prev = null, .next = &node1 };

    var it = libalpm.ListIterator([:0]const u8, libalpm.asStr){ .node = &node0 };
    try testing.expectEqualStrings("core", it.next().?);
    try testing.expectEqualStrings("extra", it.next().?);
    try testing.expect(it.next() == null);
}

test "ListIterator over a null head yields nothing" {
    var it = libalpm.ListIterator([:0]const u8, libalpm.asStr){ .node = null };
    try testing.expect(it.next() == null);
}

test "asStr spans the pointed-to C string" {
    var buf = [_:0]u8{ 'M', 'I', 'T' };
    const s = libalpm.asStr(@ptrCast(&buf)) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("MIT", s);
}
