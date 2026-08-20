//! Data types produced by the PKGBUILD parser.
const std = @import("std");

pub const Pkgbuild = struct {
    pkg_name: ?[]const u8 = null,
    pkg_version: ?[]const u8 = null,
    pkg_rel: ?[]const u8 = null,
    epoch: ?[]const u8 = null,
    pkg_desc: ?[]const u8 = null,
    url: ?[]const u8 = null,
    license: ?[][]const u8 = null,
    groups: ?[][]const u8 = null,
    arch: ?[][]const u8 = null,
    depends: ?[][]const u8 = null,
    make_depends: ?[][]const u8 = null,
    opt_depends: ?[][]const u8 = null,
    provides: ?[][]const u8 = null,
    conflicts: ?[][]const u8 = null,
    replaces: ?[][]const u8 = null,
    backup: ?[][]const u8 = null,
    options: ?[][]const u8 = null,
    xdata: ?[][]const u8 = null,
    source: ?[][]const u8 = null,
    valid_pgp_keys: ?[][]const u8 = null,
    no_extract: ?[][]const u8 = null,
    sha_1_sums: ?[][]const u8 = null,
    sha_224_sums: ?[][]const u8 = null,
    sha_256_sums: ?[][]const u8 = null,
    sha_384_sums: ?[][]const u8 = null,
    sha_512_sums: ?[][]const u8 = null,
    md_5_sums: ?[][]const u8 = null,
    b_2_sums: ?[][]const u8 = null,
    variables: std.StringHashMap([]const u8),
    install_file: ?[]const u8 = null,
    changelog_file: ?[]const u8 = null,
    is_split: bool = false,
    has_generic_package_function: bool = false,
    has_selected_package_function: bool = false,
    has_build_function: bool = false,
    has_invalid_package_assignment: bool = false,
    has_complete_split_functions: bool = true,
    local_source_files: ?[][]const u8 = null,
    local_source_contents: std.StringHashMap([]const u8),
    parsed_depends: ?[]parsed_dep = null,
    parsed_make_depends: ?[]parsed_dep = null,
    parsed_check_depends: ?[]parsed_dep = null,
    check_depends: ?[][]const u8 = null,
    execution: ?execution_plan = null,
    /// Top-level scalar assignments whose value is a command substitution
    /// (`name=$(...)`). The static parser records them instead of executing
    /// them; the builder evaluates them post-review in the sandbox and
    /// re-parses with the results. Empty when none are present or after a
    /// re-parse that seeded every value.
    dynamic_assignments: []dynamic_assignment = &.{},

    pub fn deinit(self: *Pkgbuild, allocator: std.mem.Allocator) void {
        if (self.pkg_name) |v| allocator.free(v);
        if (self.pkg_version) |v| allocator.free(v);
        if (self.pkg_rel) |v| allocator.free(v);
        if (self.epoch) |v| allocator.free(v);
        if (self.pkg_desc) |v| allocator.free(v);
        if (self.url) |v| allocator.free(v);

        if (self.license) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.groups) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.arch) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.depends) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.make_depends) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.check_depends) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.opt_depends) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.provides) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.conflicts) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.replaces) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.backup) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.options) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.xdata) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.source) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.valid_pgp_keys) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.no_extract) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.sha_1_sums) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.sha_224_sums) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.sha_256_sums) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.sha_384_sums) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.sha_512_sums) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.md_5_sums) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.b_2_sums) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.local_source_files) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }

        var var_it = self.variables.iterator();
        while (var_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.variables.deinit();

        if (self.install_file) |v| allocator.free(v);
        if (self.changelog_file) |v| allocator.free(v);

        var lsc_it = self.local_source_contents.iterator();
        while (lsc_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.local_source_contents.deinit();

        if (self.parsed_depends) |deps| {
            for (deps) |d| d.deinit(allocator);
            allocator.free(deps);
        }
        if (self.parsed_make_depends) |deps| {
            for (deps) |d| d.deinit(allocator);
            allocator.free(deps);
        }
        if (self.parsed_check_depends) |deps| {
            for (deps) |d| d.deinit(allocator);
            allocator.free(deps);
        }
        if (self.execution) |plan| plan.deinit(allocator);
        for (self.dynamic_assignments) |assignment| assignment.deinit(allocator);
        if (self.dynamic_assignments.len > 0) allocator.free(self.dynamic_assignments);
    }

    pub fn hasDynamicAssignments(self: Pkgbuild) bool {
        return self.dynamic_assignments.len > 0;
    }

    pub fn get_full_version(self: Pkgbuild, allocator: std.mem.Allocator) ![]const u8 {
        const version = self.pkg_version;
        const version_part: []const u8 = version orelse "";
        const epoch_part: []const u8 = if (self.epoch) |e| e else "";
        const epoch_sep: []const u8 = if (self.epoch != null) ":" else "";
        const rel_sep: []const u8 = if (self.pkg_rel != null) "-" else "";
        const rel_part: []const u8 = if (self.pkg_rel) |r| r else "";

        return try std.mem.concat(allocator, u8, &.{
            epoch_part, epoch_sep, version_part, rel_sep, rel_part,
        });
    }
};

/// The package members declared by a PKGBUILD's `pkgname` value. A scalar
/// declaration contains one item, while a split-package array contains every
/// member in declaration order.
pub const PackageNames = struct {
    items: [][]const u8,

    pub fn deinit(self: *PackageNames, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const parsed_dep = struct {
    name: []const u8,
    operator: []const u8,
    version: []const u8,

    pub fn deinit(self: parsed_dep, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.operator);
        allocator.free(self.version);
    }
};

pub const split_entry = struct {
    file_name: []const u8,
    location: []const u8,

    pub fn deinit(self: split_entry, allocator: std.mem.Allocator) void {
        allocator.free(self.file_name);
        allocator.free(self.location);
    }
};

pub const kvp = struct {
    key: []const u8,
    value: []const u8,
    append: bool = false,

    pub fn deinit(self: kvp, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

/// A top-level scalar assignment whose value contains a command substitution,
/// e.g. `_date="$(date -u +%Y%m%d)"`. `statement` is the full assignment line
/// exactly as written, so the builder can re-emit it verbatim for sandboxed
/// evaluation (this also covers `name+=$(...)`). Nothing about it is executed
/// by the static parser.
pub const dynamic_assignment = struct {
    name: []const u8,
    statement: []const u8,

    pub fn deinit(self: dynamic_assignment, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.statement);
    }
};

/// One makepkg execution step of a PKGBUILD: verify, prepare, pkgver, build,
/// check, package/package_<name>, and its body. verify is stored separately in
/// execution_plan because it runs before source extraction.
pub const execution_step = struct {
    name: []const u8,
    /// The function body exactly as written in the PKGBUILD.
    body: []const u8,
    /// `body` with every statically knowable variable expanded: PKGBUILD
    /// assignments plus the makepkg built-ins that are known at parse time
    /// (pkgbase, startdir, srcdir, pkgdir). References only the shell can
    /// resolve (command substitutions, loop variables, unknown names) are
    /// left untouched for the shell, and single-quoted, backslash-escaped,
    /// and quoted-heredoc regions are preserved verbatim to match bash
    /// expansion rules.
    expanded_body: []const u8,
    pub fn deinit(self: execution_step, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.body);
        allocator.free(self.expanded_body);
    }
};

/// Extracted lifecycle steps and the two helper environments they share.
/// Helpers are stored once instead of being duplicated into every step.
pub const execution_plan = struct {
    /// Global source-authentication function, executed before extraction.
    verify_step: ?execution_step,
    steps: []execution_step,
    /// Safely quoted declarations that reconstruct the PKGBUILD's supported
    /// top-level scalar and indexed-array state for shared lifecycle steps.
    shared_prelude: []const u8,
    /// The same environment with the selected split-package name overlaid for
    /// package()/package_<name>().
    package_prelude: []const u8,
    shared_helpers: []const u8,
    package_helpers: []const u8,

    pub fn deinit(self: execution_plan, allocator: std.mem.Allocator) void {
        if (self.verify_step) |step| step.deinit(allocator);
        for (self.steps) |step| step.deinit(allocator);
        allocator.free(self.steps);
        allocator.free(self.shared_prelude);
        allocator.free(self.package_prelude);
        allocator.free(self.shared_helpers);
        allocator.free(self.package_helpers);
    }
};
pub fn contains_string(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

test "kvp.deinit: frees both key and value" {
    const key = try std.testing.allocator.dupe(u8, "pkgname");
    const value = try std.testing.allocator.dupe(u8, "myapp");
    const pair = kvp{ .key = key, .value = value };
    pair.deinit(std.testing.allocator);
}

test "kvp.deinit: works with empty strings" {
    const key = try std.testing.allocator.dupe(u8, "");
    const value = try std.testing.allocator.dupe(u8, "");
    const pair = kvp{ .key = key, .value = value };
    pair.deinit(std.testing.allocator);
}

test "kvp.deinit: works when key and value are the same length" {
    const key = try std.testing.allocator.dupe(u8, "abc");
    const value = try std.testing.allocator.dupe(u8, "xyz");
    const pair = kvp{ .key = key, .value = value };
    pair.deinit(std.testing.allocator);
}

test "kvp.deinit: multiple independent pairs each free correctly" {
    const key1 = try std.testing.allocator.dupe(u8, "first");
    const value1 = try std.testing.allocator.dupe(u8, "1");
    const key2 = try std.testing.allocator.dupe(u8, "second");
    const value2 = try std.testing.allocator.dupe(u8, "2");

    const pair1 = kvp{ .key = key1, .value = value1 };
    const pair2 = kvp{ .key = key2, .value = value2 };

    pair1.deinit(std.testing.allocator);
    pair2.deinit(std.testing.allocator);
}
