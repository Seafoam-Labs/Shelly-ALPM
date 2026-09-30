//! Backend-independent native package records and flags.
const std = @import("std");

pub const PackageReason = enum(i32) { Explicit = 0, Dependency = 1, Unknown = 2 };

pub const ReverseDependencyOptions = struct {
    required_by: bool = false,
    optional_for: bool = false,
};

pub const SigLevel = packed struct(u32) {
    package: bool = false,
    package_optional: bool = false,
    package_marginal_ok: bool = false,
    package_unknown_ok: bool = false,
    _reserved_4_9: u6 = 0,
    database: bool = false,
    database_optional: bool = false,
    database_marginal_ok: bool = false,
    database_unknown_ok: bool = false,
    _reserved_14_29: u16 = 0,
    use_default: bool = false,
    _reserved_31: u1 = 0,

    pub fn from_sig_level(sig_level: u32) SigLevel {
        return @bitCast(sig_level);
    }

    pub fn to_sig_level(sig_level: SigLevel) c_int {
        const bits: u32 = @bitCast(sig_level);
        return @bitCast(bits);
    }

    pub fn contains(combined: SigLevel, level: SigLevel) bool {
        const combined_bits: u32 = @bitCast(combined);
        const level_bits: u32 = @bitCast(level);
        return level_bits != 0 and (combined_bits & level_bits) == level_bits;
    }
};

pub const DatabaseUsage = enum(u32) {
    sync = 1 << 0,
    search = 1 << 1,
    install = 1 << 2,
    upgrade = 1 << 3,
    all = (1 << 4) - 1,

    pub fn from_db_usage(usage_level: u32) DatabaseUsage {
        return @enumFromInt(usage_level);
    }
};

pub const TransFlag = packed struct(u32) {
    nodeps: bool = false,
    _reserved_1: u1 = 0,
    nosave: bool = false,
    nodepversion: bool = false,
    cascade: bool = false,
    recurse: bool = false,
    dbonly: bool = false,
    nohooks: bool = false,
    alldeps: bool = false,
    downloadonly: bool = false,
    noscriptlet: bool = false,
    noconflicts: bool = false,
    _reserved_12: u1 = 0,
    needed: bool = false,
    allexplicit: bool = false,
    unneeded: bool = false,
    recurseall: bool = false,
    nolock: bool = false,
    _reserved_high: u14 = 0,

    pub fn from_trans_flag(trans_flag: u32) TransFlag {
        return @bitCast(trans_flag);
    }

    pub fn to_trans_flag(trans_flag: TransFlag) u32 {
        return @bitCast(trans_flag);
    }

    pub fn contains(combined: TransFlag, flag: TransFlag) bool {
        const combined_bits: u32 = @bitCast(combined);
        const flag_bits: u32 = @bitCast(flag);
        return flag_bits != 0 and (combined_bits & flag_bits) == flag_bits;
    }
};

pub const QuestionType = enum(u32) {
    install_ignore = 1,
    replace_package = 2,
    conflict_package = 4,
    corrupted_package = 8,
    remove_packages = 16,
    select_provider = 32,
    import_key = 64,
    select_optional_dependencies = 256,
    update_notice = 512,
    unknown = 0,

    pub fn fromQuestionType(questionType: u32) QuestionType {
        return switch (questionType) {
            1 => .install_ignore,
            2 => .replace_package,
            4 => .conflict_package,
            8 => .corrupted_package,
            16 => .remove_packages,
            32 => .select_provider,
            64 => .import_key,
            256 => .select_optional_dependencies,
            512 => .update_notice,
            else => .unknown,
        };
    }
};

pub const EventType = @import("native_output").EventType;

pub const OwnedPackage = struct {
    name_value: [:0]u8,
    base_value: [:0]u8,
    architecture_value: ?[:0]u8 = null,
    version_value: [:0]u8,
    description_value: ?[:0]u8,
    url_value: ?[:0]u8,
    repository_value: ?[:0]u8,
    file_name_value: [:0]u8,
    download_size_value: i64,
    install_size_value: i64,
    reason_value: PackageReason,
    replaces_value: [][:0]u8,
    licenses_value: [][:0]u8,
    groups_value: [][:0]u8,
    provides_value: [][:0]u8,
    depends_value: [][:0]u8,
    optional_depends_value: [][:0]u8,
    conflicts_value: [][:0]u8,
    required_by_value: [][:0]u8,
    optional_for_value: [][:0]u8,
    build_date_value: i64,
    install_date_value: ?i64,

    pub fn init(allocator: std.mem.Allocator, package: anytype) std.mem.Allocator.Error!OwnedPackage {
        return package.toOwned(allocator, .{});
    }
    pub fn initWithReverseDependencies(allocator: std.mem.Allocator, package: anytype, options: ReverseDependencyOptions) std.mem.Allocator.Error!OwnedPackage {
        return package.toOwned(allocator, options);
    }
    fn freeStrings(allocator: std.mem.Allocator, values: [][:0]u8) void {
        for (values) |value| allocator.free(value);
        allocator.free(values);
    }

    pub fn owned_required_by(self: OwnedPackage, allocator: std.mem.Allocator) ![][]const u8 {
        const values = try allocator.alloc([]const u8, self.required_by_value.len);
        var count: usize = 0;
        errdefer {
            for (values[0..count]) |value| allocator.free(value);
            allocator.free(values);
        }
        for (self.required_by_value, values) |source, *value| {
            value.* = try allocator.dupe(u8, source);
            count += 1;
        }
        return values;
    }
    pub fn owned_optional_for(self: OwnedPackage, allocator: std.mem.Allocator) ![][]const u8 {
        const values = try allocator.alloc([]const u8, self.optional_for_value.len);
        var count: usize = 0;
        errdefer {
            for (values[0..count]) |value| allocator.free(value);
            allocator.free(values);
        }
        for (self.optional_for_value, values) |source, *value| {
            value.* = try allocator.dupe(u8, source);
            count += 1;
        }
        return values;
    }
    pub fn deinit(self: *OwnedPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.name_value);
        allocator.free(self.base_value);
        if (self.architecture_value) |value| allocator.free(value);
        allocator.free(self.version_value);
        if (self.description_value) |value| allocator.free(value);
        if (self.url_value) |value| allocator.free(value);
        if (self.repository_value) |value| allocator.free(value);
        allocator.free(self.file_name_value);
        freeStrings(allocator, self.replaces_value);
        freeStrings(allocator, self.licenses_value);
        freeStrings(allocator, self.groups_value);
        freeStrings(allocator, self.provides_value);
        freeStrings(allocator, self.depends_value);
        freeStrings(allocator, self.optional_depends_value);
        freeStrings(allocator, self.conflicts_value);
        freeStrings(allocator, self.required_by_value);
        freeStrings(allocator, self.optional_for_value);
        self.* = undefined;
    }

    pub fn deinitItems(allocator: std.mem.Allocator, packages: []OwnedPackage) void {
        for (packages) |*package| package.deinit(allocator);
    }

    pub fn deinitSlice(allocator: std.mem.Allocator, packages: []OwnedPackage) void {
        deinitItems(allocator, packages);
        allocator.free(packages);
    }

    pub fn name(self: OwnedPackage) ?[:0]const u8 {
        return self.name_value;
    }

    pub fn base(self: OwnedPackage) [:0]const u8 {
        return self.base_value;
    }

    pub fn version(self: OwnedPackage) ?[:0]const u8 {
        return self.version_value;
    }

    pub fn description(self: OwnedPackage) ?[:0]const u8 {
        return self.description_value;
    }

    pub fn url(self: OwnedPackage) ?[:0]const u8 {
        return self.url_value;
    }

    pub fn repository(self: OwnedPackage) ?[:0]const u8 {
        return self.repository_value;
    }

    pub fn file_name(self: OwnedPackage) [:0]const u8 {
        return self.file_name_value;
    }

    pub fn download_size(self: OwnedPackage) i64 {
        return self.download_size_value;
    }

    pub fn install_size(self: OwnedPackage) i64 {
        return self.install_size_value;
    }

    pub fn install_reason(self: OwnedPackage) PackageReason {
        return self.reason_value;
    }

    pub fn replaces(self: OwnedPackage) []const [:0]u8 {
        return self.replaces_value;
    }

    pub fn licenses(self: OwnedPackage) []const [:0]u8 {
        return self.licenses_value;
    }

    pub fn groups(self: OwnedPackage) []const [:0]u8 {
        return self.groups_value;
    }

    pub fn provides(self: OwnedPackage) []const [:0]u8 {
        return self.provides_value;
    }

    pub fn depends(self: OwnedPackage) []const [:0]u8 {
        return self.depends_value;
    }

    pub fn optional_depends(self: OwnedPackage) []const [:0]u8 {
        return self.optional_depends_value;
    }

    pub fn conflicts(self: OwnedPackage) []const [:0]u8 {
        return self.conflicts_value;
    }

    pub fn required_by(self: OwnedPackage) []const [:0]u8 {
        return self.required_by_value;
    }

    pub fn optional_for(self: OwnedPackage) []const [:0]u8 {
        return self.optional_for_value;
    }

    pub fn build_date(self: OwnedPackage) i64 {
        return self.build_date_value;
    }

    pub fn install_date(self: OwnedPackage) ?i64 {
        return self.install_date_value;
    }
};

pub const OwnedPackageWithUpdate = struct {
    old_package: OwnedPackage,
    new_package: OwnedPackage,

    pub fn init(
        allocator: std.mem.Allocator,
        old_package: anytype,
        new_package: anytype,
    ) std.mem.Allocator.Error!OwnedPackageWithUpdate {
        var owned_old = try OwnedPackage.init(allocator, old_package);
        errdefer owned_old.deinit(allocator);

        const owned_new = try OwnedPackage.init(allocator, new_package);
        return .{
            .old_package = owned_old,
            .new_package = owned_new,
        };
    }

    pub fn deinit(self: *OwnedPackageWithUpdate, allocator: std.mem.Allocator) void {
        self.old_package.deinit(allocator);
        self.new_package.deinit(allocator);
        self.* = undefined;
    }

    pub fn deinitSlice(allocator: std.mem.Allocator, updates: []OwnedPackageWithUpdate) void {
        for (updates) |*update| update.deinit(allocator);
        allocator.free(updates);
    }
};
