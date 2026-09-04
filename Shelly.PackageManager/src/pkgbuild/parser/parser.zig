//! PKGBUILD parser orchestrator: reads a PKGBUILD and resolves its
//! metadata, fields, and makepkg execution plan via the sibling modules.
const std = @import("std");
const types = @import("types.zig");
const function_body = @import("function_body.zig");
const variables = @import("variables.zig");
const dependencies = @import("dependencies.zig");
const sources = @import("sources.zig");
const fields = @import("fields.zig");
const validation = @import("validation.zig");
const execution = @import("execution.zig");

pub const Pkgbuild = types.Pkgbuild;
pub const PackageNames = types.PackageNames;
pub const parsed_dep = types.parsed_dep;
pub const split_entry = types.split_entry;
pub const kvp = types.kvp;
pub const dynamic_assignment = types.dynamic_assignment;
pub const dynamic_array_assignment = types.dynamic_array_assignment;
pub const execution_step = types.execution_step;
pub const execution_plan = types.execution_plan;

test {
    _ = @import("types.zig");
    _ = @import("shell_scan.zig");
    _ = @import("function_body.zig");
    _ = @import("arithmetic.zig");
    _ = @import("expansion.zig");
    _ = @import("arrays.zig");
    _ = @import("variables.zig");
    _ = @import("dependencies.zig");
    _ = @import("sources.zig");
    _ = @import("fields.zig");
    _ = @import("validation.zig");
    _ = @import("execution.zig");
}

pub const PkgbuildParser = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    selected_package_name: ?[]const u8 = null,
    package_carch: []const u8 = "x86_64",
    /// Scalar values produced by sourcing the reviewed PKGBUILD in the build
    /// sandbox. These overlay the static parse so shell-only assignments such
    /// as `${name:=default}`, conditionals, and helper calls reach lifecycle
    /// functions. Null on the initial (analysis) parse.
    dynamic_overrides: ?*const std.StringHashMap([]const u8) = null,
    /// Scalars removed while sourcing the reviewed PKGBUILD. Tombstones are
    /// kept separately because an absent map entry otherwise means "no
    /// override", not `unset`.
    dynamic_unsets: ?*const std.StringHashMap(void) = null,
    /// Sandboxed indexed-array values produced after the initial review.
    /// Each map value owns an ordered list of already-expanded Bash array
    /// elements. Null during the initial static analysis parse.
    dynamic_array_overrides: ?*const std.StringHashMap([]const []const u8) = null,
    /// Indexed arrays removed while sourcing the reviewed PKGBUILD.
    dynamic_array_unsets: ?*const std.StringHashMap(void) = null,

    /// Public entry point kept on the parser type for existing callers;
    /// implemented in `function_body.zig`.
    pub const extract_function_body = function_body.extract_function_body;

    pub fn parser(self: PkgbuildParser, path: []const u8) !Pkgbuild {
        const content = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited);
        defer self.allocator.free(content);

        const base_dir = std.fs.path.dirname(path);
        return self.parser_content(content, base_dir);
    }

    /// Reads a PKGBUILD and returns every package named by its top-level
    /// `pkgname` declaration without executing the PKGBUILD.
    pub fn package_names(self: PkgbuildParser, path: []const u8) !PackageNames {
        const content = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited);
        defer self.allocator.free(content);
        return self.package_names_content(content);
    }

    /// Returns every package named by a PKGBUILD's top-level `pkgname`
    /// declaration. Variable references that the static parser understands
    /// are resolved with the same environment used by `parser_content`.
    pub fn package_names_content(self: PkgbuildParser, content: []const u8) !PackageNames {
        var vars = try variables.build_var_hashmap(self, content);
        defer variables.free_vars(self.allocator, &vars);

        const names = try fields.resolve_array_field(self, content, &vars, "pkgname");
        if (names.len > 0) {
            errdefer variables.freeStringSlice(self.allocator, names);
            try validation.validate_package_names(names);
            return .{ .items = names };
        }
        self.allocator.free(names);

        const scalar = vars.get("pkgname") orelse return error.MissingPackageName;
        if (scalar.len == 0) return error.MissingPackageName;
        const items = try self.allocator.alloc([]const u8, 1);
        errdefer self.allocator.free(items);
        items[0] = try self.allocator.dupe(u8, scalar);
        return .{ .items = items };
    }

    pub fn parser_content(self: PkgbuildParser, content: []const u8, base_dir: ?[]const u8) !Pkgbuild {
        var vars = try variables.build_var_hashmap(self, content);
        errdefer {
            var iterator = vars.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            vars.deinit();
        }
        const dynamic_assignments = try variables.collect_dynamic_assignments(self, content);
        errdefer {
            for (dynamic_assignments) |assignment| assignment.deinit(self.allocator);
            if (dynamic_assignments.len > 0) self.allocator.free(dynamic_assignments);
        }
        const dynamic_source_assignments = try execution.collect_dynamic_source_assignments(self, content);
        errdefer {
            for (dynamic_source_assignments) |assignment| assignment.deinit(self.allocator);
            if (dynamic_source_assignments.len > 0) self.allocator.free(dynamic_source_assignments);
        }
        try validation.validate_selected_package(self, content, &vars);
        try validation.validate_architecture_directives(self, content, &vars);
        const package_functions = try validation.inspect_package_functions(self, content, &vars);

        const install_assignment = try fields.resolve_file_assignment(self, content, &vars, "install");
        defer if (install_assignment) |assignment| self.allocator.free(assignment.value);
        const install_file = if (install_assignment) |assignment|
            try fields.resolve_file_string(self, assignment, &vars)
        else
            null;
        const changelog_assignment = try fields.resolve_file_assignment(self, content, &vars, "changelog");
        defer if (changelog_assignment) |assignment| self.allocator.free(assignment.value);
        const changelog_file = if (changelog_assignment) |assignment|
            try fields.resolve_file_string(self, assignment, &vars)
        else
            null;

        const source = if (dynamic_source_assignments.len > 0)
            try fields.resolve_dynamic_source_array_field(self, content, &vars)
        else
            try fields.resolve_arch_array_field(self, content, &vars, "source");
        const local_source_files = try sources.extract_local_source_files(self, source);
        const local_source_contents = try sources.resolve_local_source_contents(self, local_source_files, base_dir);

        const depends = try fields.resolve_package_array_field(self, content, &vars, "depends");
        const make_depends = try fields.resolve_arch_array_field(self, content, &vars, "makedepends");
        const check_depends = try fields.resolve_arch_array_field(self, content, &vars, "checkdepends");
        const xdata = try fields.resolve_array_field(self, content, &vars, "xdata");
        errdefer variables.freeStringSlice(self.allocator, xdata);
        try validation.validate_xdata(xdata);

        return Pkgbuild{
            .variables = vars,
            .pkg_name = if (self.selected_package_name) |name|
                try self.allocator.dupe(u8, name)
            else
                try variables.resolve_or_parse(self, content, "pkgname", &vars),
            .pkg_version = try variables.resolve_or_parse(self, content, "pkgver", &vars),
            .pkg_rel = try variables.resolve_or_parse(self, content, "pkgrel", &vars),
            .epoch = try variables.resolve_or_parse(self, content, "epoch", &vars),
            .pkg_desc = try fields.resolve_package_string_field(self, content, &vars, "pkgdesc"),
            .url = try fields.resolve_package_string_field(self, content, &vars, "url"),
            .license = try fields.resolve_package_array_field(self, content, &vars, "license"),
            .groups = try fields.resolve_package_array_field(self, content, &vars, "groups"),
            .arch = try fields.resolve_effective_architecture_field(self, content, &vars),
            .depends = depends,
            .make_depends = make_depends,
            .check_depends = check_depends,
            .opt_depends = try fields.resolve_package_array_field(self, content, &vars, "optdepends"),
            .provides = try fields.resolve_package_array_field(self, content, &vars, "provides"),
            .conflicts = try fields.resolve_package_array_field(self, content, &vars, "conflicts"),
            .replaces = try fields.resolve_package_array_field(self, content, &vars, "replaces"),
            .backup = try fields.resolve_package_array_field(self, content, &vars, "backup"),
            .options = try fields.resolve_package_array_field(self, content, &vars, "options"),
            .xdata = xdata,
            .source = source,
            .valid_pgp_keys = try fields.resolve_array_field(self, content, &vars, "validpgpkeys"),
            .no_extract = try fields.resolve_array_field(self, content, &vars, "noextract"),
            .sha_1_sums = try fields.resolve_arch_array_field(self, content, &vars, "sha1sums"),
            .sha_224_sums = try fields.resolve_arch_array_field(self, content, &vars, "sha224sums"),
            .sha_256_sums = try fields.resolve_arch_array_field(self, content, &vars, "sha256sums"),
            .sha_384_sums = try fields.resolve_arch_array_field(self, content, &vars, "sha384sums"),
            .sha_512_sums = try fields.resolve_arch_array_field(self, content, &vars, "sha512sums"),
            .md_5_sums = try fields.resolve_arch_array_field(self, content, &vars, "md5sums"),
            .b_2_sums = try fields.resolve_arch_array_field(self, content, &vars, "b2sums"),
            .install_file = install_file,
            .changelog_file = changelog_file,
            .is_split = package_functions.is_split,
            .has_generic_package_function = package_functions.has_generic,
            .has_selected_package_function = package_functions.has_selected,
            .has_build_function = package_functions.has_build,
            .has_invalid_package_assignment = try validation.has_forbidden_package_assignment(self, content, &vars),
            .has_complete_split_functions = package_functions.has_complete_split,
            .local_source_files = local_source_files,
            .local_source_contents = local_source_contents,
            .parsed_depends = try dependencies.parse_dependencies(self, depends),
            .parsed_make_depends = try dependencies.parse_dependencies(self, make_depends),
            .parsed_check_depends = try dependencies.parse_dependencies(self, check_depends),
            .execution = try execution.resolve_execution_plan(self, content, &vars, base_dir),
            .dynamic_assignments = dynamic_assignments,
            .dynamic_source_assignments = dynamic_source_assignments,
        };
    }

    //replaces var resolved = Regex.Replace(expr, @"\$\{?(\w+)\}?", match =>
};

fn parse_test_pkgbuild(
    parser: PkgbuildParser,
    content: []const u8,
    base_dir: ?[]const u8,
) !Pkgbuild {
    const complete = try std.fmt.allocPrint(parser.allocator, "arch=('any')\n{s}", .{content});
    defer parser.allocator.free(complete);
    return parser.parser_content(complete, base_dir);
}

test "parser_content resolves python-sabctools source as remote" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var info = try parse_test_pkgbuild(parser,
        \\pkgname=python-sabctools
        \\_name=sabctools
        \\pkgver=9.6.3
        \\pkgrel=1
        \\source=("https://files.pythonhosted.org/packages/source/${_name::1}/${_name}/${_name}-${pkgver}.tar.gz")
    , null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), info.source.?.len);
    try std.testing.expectEqualStrings(
        "https://files.pythonhosted.org/packages/source/s/sabctools/sabctools-9.6.3.tar.gz",
        info.source.?[0],
    );
    try std.testing.expectEqual(@as(usize, 0), info.local_source_files.?.len);
    try std.testing.expectEqual(@as(usize, 0), info.local_source_contents.count());
}

test "parser_content expands Dropbox archive and signature sources" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var info = try parse_test_pkgbuild(parser,
        \\pkgname=dropbox
        \\pkgver=258.4.3749
        \\pkgrel=1
        \\source=("DropboxGlyph_Blue.svg"
        \\        "terms.txt"
        \\        "dropbox.service"
        \\        "dropbox@.service"
        \\        "https://edge.dropboxstatic.com/dbx-releng/client/dropbox-lnx.x86_64-$pkgver.tar.gz"{,.asc})
    , null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 6), info.source.?.len);
    try std.testing.expectEqualStrings(
        "https://edge.dropboxstatic.com/dbx-releng/client/dropbox-lnx.x86_64-258.4.3749.tar.gz",
        info.source.?[4],
    );
    try std.testing.expectEqualStrings(
        "https://edge.dropboxstatic.com/dbx-releng/client/dropbox-lnx.x86_64-258.4.3749.tar.gz.asc",
        info.source.?[5],
    );
    try std.testing.expectEqual(@as(usize, 4), info.local_source_files.?.len);
    try std.testing.expectEqualStrings("DropboxGlyph_Blue.svg", info.local_source_files.?[0]);
    try std.testing.expectEqualStrings("terms.txt", info.local_source_files.?[1]);
    try std.testing.expectEqualStrings("dropbox.service", info.local_source_files.?[2]);
    try std.testing.expectEqualStrings("dropbox@.service", info.local_source_files.?[3]);
    for (info.local_source_files.?) |file_name| {
        try std.testing.expect(!std.mem.eql(u8, file_name, "{,.asc}"));
    }
}

test "package_names_content discovers and resolves every split package member" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\_pkgbase=demo
        \\pkgname=("$_pkgbase" "${_pkgbase}-docs" "${_pkgbase}-debug")
        \\arch=('any')
    ;
    var names = try parser.package_names_content(content);
    defer names.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("demo", names.items[0]);
    try std.testing.expectEqualStrings("demo-docs", names.items[1]);
    try std.testing.expectEqualStrings("demo-debug", names.items[2]);

    for (names.items) |name| {
        var info = try (PkgbuildParser{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .selected_package_name = name,
        }).parser_content(content, null);
        defer info.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(name, info.pkg_name.?);
    }
}

test "parser_content: Cachy-style package names survive if prose in comments" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\# This reads the database if it exists
        \\# Use this only if the GPU is supported
        \\pkgbase=linux-cachyos
        \\pkgname=("$pkgbase")
        \\[ "$build_debug" = yes ] && pkgname+=("$pkgbase-dbg")
        \\pkgname+=("$pkgbase-headers")
        \\if [ "$build_zfs" = yes ]; then
        \\pkgname+=("$pkgbase-zfs")
        \\fi
        \\arch=('x86_64')
    ;
    var names = try parser.package_names_content(content);
    defer names.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("linux-cachyos", names.items[0]);
    try std.testing.expectEqualStrings("linux-cachyos-headers", names.items[1]);
}

test "package_names_content discovers a resolved scalar package name" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var names = try parser.package_names_content(
        \\_pkgbase=demo
        \\pkgname="${_pkgbase}-cli"
    );
    defer names.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), names.items.len);
    try std.testing.expectEqualStrings("demo-cli", names.items[0]);
}

test "package_names reads a PKGBUILD file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "PKGBUILD",
        .data = "pkgname=(demo demo-docs)\n",
    });
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, "PKGBUILD", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var names = try parser.package_names(path);
    defer names.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("demo", names.items[0]);
    try std.testing.expectEqualStrings("demo-docs", names.items[1]);
}

test "package_names_content rejects missing and duplicate package names" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    try std.testing.expectError(
        error.MissingPackageName,
        parser.package_names_content("pkgver=1\n"),
    );
    try std.testing.expectError(
        error.DuplicatePackageName,
        parser.package_names_content("pkgname=(demo demo)\n"),
    );
}

test "parser_content: scalar fields and raw arrays" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=myapp
        \\pkgver=1.2.3
        \\pkgrel=2
        \\pkgdesc="A test package"
        \\url="https://example.com"
        \\license=('MIT' 'GPL')
        \\arch=('x86_64' 'aarch64')
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("myapp", info.pkg_name.?);
    try std.testing.expectEqualStrings("1.2.3", info.pkg_version.?);
    try std.testing.expectEqualStrings("2", info.pkg_rel.?);
    try std.testing.expectEqualStrings("A test package", info.pkg_desc.?);
    try std.testing.expectEqualStrings("https://example.com", info.url.?);

    try std.testing.expectEqual(@as(usize, 2), info.license.?.len);
    try std.testing.expectEqualStrings("MIT", info.license.?[0]);
    try std.testing.expectEqualStrings("GPL", info.license.?[1]);

    try std.testing.expectEqual(@as(usize, 2), info.arch.?.len);
    try std.testing.expectEqualStrings("x86_64", info.arch.?[0]);
    try std.testing.expectEqualStrings("aarch64", info.arch.?[1]);
}

test "parser_content: depends resolved through variable substitution" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=myapp
        \\_libver=1.0
        \\depends=('bash' 'somelib>=1.0')
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), info.depends.?.len);
    try std.testing.expectEqualStrings("bash", info.depends.?[0]);
    try std.testing.expectEqualStrings("somelib>=1.0", info.depends.?[1]);
}

test "parser_content: dangling version constraint on unresolved variable is stripped" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=myapp
        \\depends=('somepkg>=$_missing_var')
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), info.depends.?.len);
    try std.testing.expectEqualStrings("somepkg", info.depends.?[0]);
}

test "parser_content: parsed_depends splits name, operator, and version" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=myapp
        \\depends=('bash' 'somelib>=1.0')
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), info.parsed_depends.?.len);

    try std.testing.expectEqualStrings("bash", info.parsed_depends.?[0].name);
    try std.testing.expectEqualStrings("", info.parsed_depends.?[0].operator);
    try std.testing.expectEqualStrings("", info.parsed_depends.?[0].version);

    try std.testing.expectEqualStrings("somelib", info.parsed_depends.?[1].name);
    try std.testing.expectEqualStrings(">=", info.parsed_depends.?[1].operator);
    try std.testing.expectEqualStrings("1.0", info.parsed_depends.?[1].version);
}

test "parser_content: array reference expansion via ${arr[@]}" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=myapp
        \\_common_deps=('bash' 'coreutils')
        \\depends=('${_common_deps[@]}' 'extra-pkg')
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), info.depends.?.len);
    try std.testing.expectEqualStrings("bash", info.depends.?[0]);
    try std.testing.expectEqualStrings("coreutils", info.depends.?[1]);
    try std.testing.expectEqualStrings("extra-pkg", info.depends.?[2]);
}

test "parser_content: local source file content is read via base_dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fix.patch", .data = "diff content here" });
    const base_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_dir);

    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=myapp
        \\source=('fix.patch' 'https://example.com/upstream.tar.gz')
    ;
    var info = try parse_test_pkgbuild(parser, content, base_dir);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), info.source.?.len);
    try std.testing.expectEqualStrings("fix.patch", info.source.?[0]);

    try std.testing.expectEqual(@as(usize, 1), info.local_source_files.?.len);
    try std.testing.expectEqualStrings("fix.patch", info.local_source_files.?[0]);

    try std.testing.expectEqualStrings("diff content here", info.local_source_contents.get("fix.patch").?);
}

test "parser_content: inline post_install is not treated as an install script" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=myapp
        \\post_install() {
        \\  echo "installed"
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);
    try std.testing.expect(info.install_file == null);
}

test "parser_content: resolves install filename without reading hook bodies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "myapp.install",
        .data = "post_install() {\n  echo \"from install file\"\n}",
    });
    const base_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_dir);

    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=myapp
        \\install=myapp.install
    ;
    var info = try parse_test_pkgbuild(parser, content, base_dir);
    defer info.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("myapp.install", info.install_file.?);
}

test "parser_content: flutter-3382-bin resolves dependencies declared in package" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "flutter-3382-bin",
    };
    const content =
        \\_pkgname="flutter"
        \\pkgname="$_pkgname-3382-bin"
        \\pkgver=3.38.2
        \\
        \\package() {
        \\  depends+=(
        \\    clang
        \\    cmake
        \\    git
        \\    lld
        \\    llvm
        \\    ninja
        \\    unionfs-fuse
        \\  )
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("flutter-3382-bin", info.pkg_name.?);
    try std.testing.expectEqual(@as(usize, 7), info.depends.?.len);
    try std.testing.expectEqualStrings("unionfs-fuse", info.depends.?[6]);
    try std.testing.expectEqualStrings("unionfs-fuse", info.parsed_depends.?[6].name);
}

test "parser_content: galaxybudsclient case conversion resolves package metadata" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "galaxybudsclient-bin.install",
        .data = "post_install() { :; }\n",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "galaxybudsclient.desktop",
        .data = "[Desktop Entry]\nName=Galaxy Buds Client\n",
    });
    const base_dir = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_dir);

    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\_program_name=GalaxyBudsClient
        \\_pkgname="${_program_name,,}"
        \\pkgname="${_pkgname}-bin"
        \\pkgver=5.2.1
        \\pkgrel=1
        \\arch=('x86_64')
        \\install="${pkgname}.install"
        \\source=("${_pkgname}.desktop")
        \\sha256sums=('SKIP')
    ;
    var info = try parse_test_pkgbuild(parser, content, base_dir);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("galaxybudsclient-bin", info.pkg_name.?);
    try std.testing.expectEqualStrings("galaxybudsclient-bin.install", info.install_file.?);
    try std.testing.expectEqualStrings("galaxybudsclient.desktop", info.source.?[0]);
    try std.testing.expectEqualStrings("GalaxyBudsClient", info.variables.get("_program_name").?);
    try std.testing.expectEqualStrings("galaxybudsclient", info.variables.get("_pkgname").?);
}

test "parser_content: selected split package isolates package-scoped dependencies" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "demo-two",
    };
    const content =
        \\pkgname=('demo-one' 'demo-two')
        \\depends=('glibc')
        \\
        \\package_demo-one() {
        \\  depends+=('gtk4')
        \\}
        \\
        \\package_demo-two() {
        \\  depends+=('readline')
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), info.depends.?.len);
    try std.testing.expectEqualStrings("glibc", info.depends.?[0]);
    try std.testing.expectEqualStrings("readline", info.depends.?[1]);
}

test "parser_content: selected package must belong to pkgname" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "not-a-member",
    };
    try std.testing.expectError(
        error.SelectedPackageNotFound,
        parser.parser_content("pkgname=('demo' 'demo-docs')\n", null),
    );
}

test "parser_content: selected split package resolves package-scoped install file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "dms-shell-git.install",
        .data = "post_install() {\n  echo \"installed\"\n}",
    });
    const base_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_dir);

    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "dms-shell-git",
    };
    const content =
        \\pkgbase=dms-shell-git
        \\_pkgbase=${pkgbase%-git}
        \\pkgname=($_pkgbase-git)
        \\
        \\package_dms-shell-git() {
        \\  install="$pkgname.install"
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, base_dir);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("dms-shell-git.install", info.install_file.?);
}

test "parser_content: pkgname resolves when pkgbase is also present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "rustdesk-bin.install",
        .data = "post_install() {\n  echo \"installed\"\n}",
    });
    const base_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_dir);

    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "rustdesk-bin",
    };
    const content =
        \\pkgbase=rustdesk-bin
        \\pkgname=(rustdesk-bin)
        \\pkgver=1.4.9
        \\pkgrel=1
        \\pkgdesc="Yet another remote desktop software, written in Rust."
        \\url="https://github.com/rustdesk/rustdesk"
        \\license=('AGPL-3.0-only')
        \\arch=('x86_64' 'aarch64')
        \\provides=("${pkgname%-bin}")
        \\conflicts=("${pkgname%-bin}")
        \\depends=(
        \\    'gtk3'
        \\    'xdotool'
        \\    'libxcb'
        \\)
        \\options=('!strip' '!lto' '!debug')
        \\install=$pkgname.install
        \\
        \\package() {
        \\    install -d "${pkgdir}/usr/share/" "${pkgdir}/usr/bin/"
        \\    cp -r "${srcdir}/usr/share/rustdesk/" "${pkgdir}/usr/share/"
        \\
        \\    ln -s "/usr/share/rustdesk/rustdesk" "${pkgdir}/usr/bin/rustdesk"
        \\
        \\    install -Dm 644 "${srcdir}/usr/share/rustdesk/files/rustdesk.desktop" "${pkgdir}/usr/share/applications/rustdesk.desktop"
        \\
        \\    # Remove useless files
        \\    rm -r "${pkgdir}/usr/share/rustdesk/files/"
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, base_dir);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("rustdesk-bin", info.pkg_name.?);
    try std.testing.expectEqualStrings("1.4.9", info.pkg_version.?);
    try std.testing.expectEqualStrings("1", info.pkg_rel.?);
    try std.testing.expectEqualStrings("rustdesk-bin.install", info.install_file.?);

    try std.testing.expectEqual(@as(usize, 1), info.provides.?.len);
    try std.testing.expectEqualStrings("rustdesk", info.provides.?[0]);

    try std.testing.expectEqual(@as(usize, 3), info.depends.?.len);
    try std.testing.expectEqualStrings("gtk3", info.depends.?[0]);
    try std.testing.expectEqualStrings("xdotool", info.depends.?[1]);
    try std.testing.expectEqualStrings("libxcb", info.depends.?[2]);
    try std.testing.expectEqual(@as(usize, 3), info.options.?.len);
    try std.testing.expectEqualStrings("!strip", info.options.?[0]);
    try std.testing.expectEqualStrings("!lto", info.options.?[1]);
    try std.testing.expectEqualStrings("!debug", info.options.?[2]);
}

test "parser_content: split sources retain the first global pkgname" {
    const content =
        \\pkgbase=adwaita-qt
        \\pkgname=(adwaita-qt5 adwaita-qt6)
        \\pkgver=1.4.2
        \\pkgrel=1
        \\pkgdesc='A style to bend Qt applications to look like they belong into GNOME Shell'
        \\arch=(x86_64)
        \\url='https://github.com/FedoraQt/adwaita-qt'
        \\license=(GPL)
        \\makedepends=(cmake qt5-x11extras qt6-base)
        \\source=(https://github.com/FedoraQt/adwaita-qt/archive/$pkgver/$pkgname-$pkgver.tar.gz)
        \\sha256sums=('cd5fd71c46271d70c08ad44562e57c34e787d6a8650071db115910999a335ba8')
        \\
        \\build() {
        \\  cmake -B build-qt5 -S $pkgbase-$pkgver \
        \\    -DCMAKE_INSTALL_PREFIX=/usr \
        \\    -DUSE_QT6=OFF
        \\  cmake --build build-qt5
        \\
        \\  cmake -B build-qt6 -S $pkgbase-$pkgver \
        \\    -DCMAKE_INSTALL_PREFIX=/usr \
        \\    -DUSE_QT6=ON
        \\  cmake --build build-qt6
        \\}
        \\
        \\package_adwaita-qt5() {
        \\  pkgdesc='A style to bend Qt5 applications to look like they belong into GNOME Shell'
        \\  depends=(qt5-x11extras)
        \\  replaces=(adwaita-qt)
        \\
        \\  DESTDIR="$pkgdir" cmake --install build-qt5
        \\}
        \\
        \\package_adwaita-qt6() {
        \\  pkgdesc='A style to bend Qt6 applications to look like they belong into GNOME Shell'
        \\  depends=(qt6-base)
        \\
        \\  DESTDIR="$pkgdir" cmake --install build-qt6
        \\}
    ;

    var info_qt5 = try (PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "adwaita-qt5",
    }).parser_content(content, null);
    defer info_qt5.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("adwaita-qt5", info_qt5.pkg_name.?);
    try std.testing.expectEqualStrings("adwaita-qt", info_qt5.variables.get("pkgbase").?);
    try std.testing.expectEqualStrings("1.4.2", info_qt5.pkg_version.?);
    try std.testing.expectEqualStrings("1", info_qt5.pkg_rel.?);
    try std.testing.expectEqualStrings(
        "A style to bend Qt5 applications to look like they belong into GNOME Shell",
        info_qt5.pkg_desc.?,
    );
    try std.testing.expectEqualStrings("https://github.com/FedoraQt/adwaita-qt", info_qt5.url.?);

    try std.testing.expectEqual(@as(usize, 1), info_qt5.source.?.len);
    try std.testing.expectEqualStrings(
        "https://github.com/FedoraQt/adwaita-qt/archive/1.4.2/adwaita-qt5-1.4.2.tar.gz",
        info_qt5.source.?[0],
    );

    try std.testing.expectEqual(@as(usize, 1), info_qt5.arch.?.len);
    try std.testing.expectEqualStrings("x86_64", info_qt5.arch.?[0]);
    try std.testing.expectEqual(@as(usize, 1), info_qt5.license.?.len);
    try std.testing.expectEqualStrings("GPL", info_qt5.license.?[0]);

    try std.testing.expectEqual(@as(usize, 3), info_qt5.make_depends.?.len);
    try std.testing.expectEqualStrings("cmake", info_qt5.make_depends.?[0]);
    try std.testing.expectEqualStrings("qt5-x11extras", info_qt5.make_depends.?[1]);
    try std.testing.expectEqualStrings("qt6-base", info_qt5.make_depends.?[2]);
    try std.testing.expectEqual(@as(usize, 3), info_qt5.parsed_make_depends.?.len);
    try std.testing.expectEqualStrings("qt5-x11extras", info_qt5.parsed_make_depends.?[1].name);

    try std.testing.expectEqual(@as(usize, 1), info_qt5.sha_256_sums.?.len);
    try std.testing.expectEqualStrings(
        "cd5fd71c46271d70c08ad44562e57c34e787d6a8650071db115910999a335ba8",
        info_qt5.sha_256_sums.?[0],
    );

    try std.testing.expectEqual(@as(usize, 1), info_qt5.depends.?.len);
    try std.testing.expectEqualStrings("qt5-x11extras", info_qt5.depends.?[0]);
    try std.testing.expectEqual(@as(usize, 1), info_qt5.replaces.?.len);
    try std.testing.expectEqualStrings("adwaita-qt", info_qt5.replaces.?[0]);

    try std.testing.expect(info_qt5.install_file == null);

    var info_qt6 = try (PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "adwaita-qt6",
    }).parser_content(content, null);
    defer info_qt6.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("adwaita-qt6", info_qt6.pkg_name.?);
    try std.testing.expectEqualStrings("adwaita-qt", info_qt6.variables.get("pkgbase").?);
    try std.testing.expectEqualStrings(
        "A style to bend Qt6 applications to look like they belong into GNOME Shell",
        info_qt6.pkg_desc.?,
    );
    try std.testing.expectEqual(@as(usize, 1), info_qt6.depends.?.len);
    try std.testing.expectEqualStrings("qt6-base", info_qt6.depends.?[0]);
    try std.testing.expectEqual(@as(usize, 1), info_qt6.source.?.len);
    try std.testing.expectEqualStrings(
        "https://github.com/FedoraQt/adwaita-qt/archive/1.4.2/adwaita-qt5-1.4.2.tar.gz",
        info_qt6.source.?[0],
    );
}

test "parser_content: selected split package install overrides global and sibling values" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "demo-two",
    };
    const content =
        \\pkgname=('demo-one' 'demo-two')
        \\install=common.install
        \\
        \\package_demo-one() {
        \\  install=demo-one.install
        \\}
        \\
        \\package_demo-two() {
        \\  install="$pkgname.install"
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("demo-two.install", info.install_file.?);
}

test "parser_content: records complete split metadata and function contract state" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "demo-two",
    };
    var info = try parser.parser_content(
        \\pkgbase=demo
        \\pkgname=('demo-one' 'demo-two')
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\groups=('shared')
        \\backup=('etc/shared.conf')
        \\xdata=('channel=stable')
        \\package_demo-one() { :; }
        \\package_demo-two() {
        \\  groups=('selected')
        \\  changelog="$pkgname.changelog"
        \\}
    , null);
    defer info.deinit(std.testing.allocator);
    try std.testing.expect(info.is_split);
    try std.testing.expect(!info.has_generic_package_function);
    try std.testing.expect(info.has_selected_package_function);
    try std.testing.expectEqualStrings("selected", info.groups.?[0]);
    try std.testing.expectEqualStrings("etc/shared.conf", info.backup.?[0]);
    try std.testing.expectEqualStrings("channel=stable", info.xdata.?[0]);
    try std.testing.expectEqualStrings("demo-two.changelog", info.changelog_file.?);
}

test "parser_content: marks forbidden package assignments and rejects reserved xdata" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var info = try parser.parser_content(
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() { pkgrel=2; }
    , null);
    defer info.deinit(std.testing.allocator);
    try std.testing.expect(info.has_invalid_package_assignment);

    try std.testing.expectError(
        error.InvalidPackageXdata,
        parser.parser_content(
            \\pkgname=demo
            \\pkgver=1
            \\pkgrel=1
            \\arch=('any')
            \\xdata=('pkgtype=debug')
            \\package() { :; }
        , null),
    );
}

test "parser_content: unresolved install variable fails before filesystem validation" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "demo",
    };
    const content =
        \\pkgname=('demo')
        \\package_demo() {
        \\  install="$missing.install"
        \\}
    ;

    try std.testing.expectError(
        error.UnresolvedPkgbuildVariable,
        parse_test_pkgbuild(parser, content, null),
    );
}

test "parser_content: minimal content produces empty package metadata" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var info = try parser.parser_content("arch=('any')\n", null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(info.pkg_name == null);
    try std.testing.expectEqual(@as(usize, 0), info.depends.?.len);
    try std.testing.expectEqual(@as(usize, 0), info.source.?.len);
    try std.testing.expect(info.execution == null);
}

test "parser: reads PKGBUILD from disk and resolves relative base_dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "PKGBUILD",
        .data =
        \\pkgname=myapp
        \\pkgver=1.0.0
        \\pkgrel=1
        \\arch=('any')
        \\source=('fix.patch')
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "fix.patch",
        .data = "diff content here",
    });

    const pkgbuild_path = try tmp.dir.realPathFileAlloc(std.testing.io, "PKGBUILD", std.testing.allocator);
    defer std.testing.allocator.free(pkgbuild_path);

    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var info = try parser.parser(pkgbuild_path);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("myapp", info.pkg_name.?);
    try std.testing.expectEqualStrings("1.0.0", info.pkg_version.?);
    try std.testing.expectEqualStrings("1", info.pkg_rel.?);

    // Confirms base_dir was correctly derived from the PKGBUILD's own path,
    // letting the relative source file resolve and its content load.
    try std.testing.expectEqual(@as(usize, 1), info.local_source_files.?.len);
    try std.testing.expectEqualStrings("fix.patch", info.local_source_files.?[0]);
    try std.testing.expectEqualStrings("diff content here", info.local_source_contents.get("fix.patch").?);
}

test "parser: PKGBUILD with no directory component resolves base_dir to null" {
    const dirname = std.fs.path.dirname("PKGBUILD");
    try std.testing.expect(dirname == null);
}

test "parser: full PKGBUILD exercises the whole pipeline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "PKGBUILD",
        .data =
        \\pkgname=myapp
        \\_pkgbase=myapp-base
        \\pkgver=1.0.0
        \\epoch=2
        \\pkgrel=$((1+1))
        \\pkgdesc="Package for $_pkgbase"
        \\url="https://example.com/myapp"
        \\license=('MIT')
        \\arch=('x86_64')
        \\_common_deps=('libfoo' 'libbar')
        \\depends=('bash' 'coreutils>=8.0' '${_common_deps[@]}' 'somelib>=$_missing_var')
        \\makedepends=('cmake' 'ninja')
        \\checkdepends=('pytest')
        \\optdepends=('extra-tool: for extra features')
        \\if [ "$CARCH" = "arm" ]; then
        \\  optdepends+=('armtool: for arm')
        \\fi
        \\provides=('myapp-bin')
        \\conflicts=('myapp-git')
        \\replaces=('oldmyapp')
        \\source=('fix.patch' 'https://example.com/upstream-1.0.0.tar.gz')
        \\sha256sums=('abc123'
        \\            'SKIP')
        \\install=myapp.install
        \\
        \\prepare() {
        \\  patch -p1 < fix.patch
        \\}
        \\
        \\build() {
        \\  make
        \\}
        \\
        \\package() {
        \\  make DESTDIR="$pkgdir" install
        \\}
        ,
    });

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "fix.patch",
        .data = "diff content here",
    });

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "myapp.install",
        .data = "post_install() {\n  echo \"Enjoy $pkgname!\"\n}",
    });

    const pkgbuild_path = try tmp.dir.realPathFileAlloc(std.testing.io, "PKGBUILD", std.testing.allocator);
    defer std.testing.allocator.free(pkgbuild_path);

    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var info = try parser.parser(pkgbuild_path);
    defer info.deinit(std.testing.allocator);

    // --- Scalars ---
    try std.testing.expectEqualStrings("myapp", info.pkg_name.?);
    try std.testing.expectEqualStrings("1.0.0", info.pkg_version.?);
    try std.testing.expectEqualStrings("2", info.pkg_rel.?); // resolved from $((1+1))
    try std.testing.expectEqualStrings("2", info.epoch.?);
    try std.testing.expectEqualStrings("Package for myapp-base", info.pkg_desc.?); // $_pkgbase resolved
    try std.testing.expectEqualStrings("https://example.com/myapp", info.url.?);

    // --- get_full_version composes epoch/version/rel correctly ---
    const full_version = try info.get_full_version(std.testing.allocator);
    defer std.testing.allocator.free(full_version);
    try std.testing.expectEqualStrings("2:1.0.0-2", full_version);

    // --- Raw arrays (no variable resolution applied) ---
    try std.testing.expectEqual(@as(usize, 1), info.license.?.len);
    try std.testing.expectEqualStrings("MIT", info.license.?[0]);
    try std.testing.expectEqual(@as(usize, 1), info.arch.?.len);
    try std.testing.expectEqualStrings("x86_64", info.arch.?[0]);
    try std.testing.expectEqual(@as(usize, 1), info.provides.?.len);
    try std.testing.expectEqualStrings("myapp-bin", info.provides.?[0]);
    try std.testing.expectEqual(@as(usize, 1), info.conflicts.?.len);
    try std.testing.expectEqualStrings("myapp-git", info.conflicts.?[0]);
    try std.testing.expectEqual(@as(usize, 1), info.replaces.?.len);
    try std.testing.expectEqualStrings("oldmyapp", info.replaces.?[0]);
    try std.testing.expectEqual(@as(usize, 2), info.sha_256_sums.?.len);
    try std.testing.expectEqualStrings("abc123", info.sha_256_sums.?[0]);
    try std.testing.expectEqualStrings("SKIP", info.sha_256_sums.?[1]);

    // --- depends: array-ref expansion + dangling version-constraint stripping ---
    try std.testing.expectEqual(@as(usize, 5), info.depends.?.len);
    try std.testing.expectEqualStrings("bash", info.depends.?[0]);
    try std.testing.expectEqualStrings("coreutils>=8.0", info.depends.?[1]); // resolved constraint kept as-is
    try std.testing.expectEqualStrings("libfoo", info.depends.?[2]); // from ${_common_deps[@]}
    try std.testing.expectEqualStrings("libbar", info.depends.?[3]);
    try std.testing.expectEqualStrings("somelib", info.depends.?[4]); // >=$_missing_var stripped

    try std.testing.expectEqual(@as(usize, 2), info.make_depends.?.len);
    try std.testing.expectEqualStrings("cmake", info.make_depends.?[0]);
    try std.testing.expectEqualStrings("ninja", info.make_depends.?[1]);

    try std.testing.expectEqual(@as(usize, 1), info.check_depends.?.len);
    try std.testing.expectEqualStrings("pytest", info.check_depends.?[0]);

    // --- optdepends: conditional block correctly skipped ---
    try std.testing.expectEqual(@as(usize, 1), info.opt_depends.?.len);
    try std.testing.expectEqualStrings("extra-tool: for extra features", info.opt_depends.?[0]);

    // --- parsed_depends: name/operator/version split correctly ---
    try std.testing.expectEqual(@as(usize, 5), info.parsed_depends.?.len);
    try std.testing.expectEqualStrings("bash", info.parsed_depends.?[0].name);
    try std.testing.expectEqualStrings("", info.parsed_depends.?[0].operator);

    try std.testing.expectEqualStrings("coreutils", info.parsed_depends.?[1].name);
    try std.testing.expectEqualStrings(">=", info.parsed_depends.?[1].operator);
    try std.testing.expectEqualStrings("8.0", info.parsed_depends.?[1].version);

    try std.testing.expectEqualStrings("libfoo", info.parsed_depends.?[2].name);
    try std.testing.expectEqualStrings("libbar", info.parsed_depends.?[3].name);
    try std.testing.expectEqualStrings("somelib", info.parsed_depends.?[4].name);
    try std.testing.expectEqualStrings("", info.parsed_depends.?[4].operator);

    // --- source: local vs remote correctly split ---
    try std.testing.expectEqual(@as(usize, 2), info.source.?.len);
    try std.testing.expectEqualStrings("fix.patch", info.source.?[0]);
    try std.testing.expectEqualStrings("https://example.com/upstream-1.0.0.tar.gz", info.source.?[1]);

    try std.testing.expectEqual(@as(usize, 1), info.local_source_files.?.len);
    try std.testing.expectEqualStrings("fix.patch", info.local_source_files.?[0]);
    try std.testing.expectEqualStrings("diff content here", info.local_source_contents.get("fix.patch").?);

    // --- install filename is selected; its contents belong to package review ---
    try std.testing.expectEqualStrings("myapp.install", info.install_file.?);

    // --- execution steps: functions captured in makepkg execution order ---
    try std.testing.expectEqual(@as(usize, 3), info.execution.?.steps.len);
    try std.testing.expectEqualStrings("prepare", info.execution.?.steps[0].name);
    try std.testing.expectEqualStrings("patch -p1 < fix.patch", info.execution.?.steps[0].body);
    try std.testing.expectEqualStrings("build", info.execution.?.steps[1].name);
    try std.testing.expectEqualStrings("make", info.execution.?.steps[1].body);
    try std.testing.expectEqualStrings("package", info.execution.?.steps[2].name);
    try std.testing.expectEqualStrings("make DESTDIR=\"$pkgdir\" install", info.execution.?.steps[2].body);
}

test "parser_content: execution steps follow makepkg execution order" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    // Functions declared in scrambled order on purpose: the stored steps must
    // follow makepkg's execution order (prepare, pkgver, build, check, package),
    // not the declaration order.
    const content =
        \\pkgname=demo
        \\
        \\verify() {
        \\  test -f upstream.tar.gz
        \\}
        \\
        \\package() {
        \\  make install
        \\}
        \\
        \\check() {
        \\  make test
        \\}
        \\
        \\pkgver() {
        \\  git describe --long
        \\}
        \\
        \\prepare() {
        \\  patch -p1 < fix.patch
        \\}
        \\
        \\build() {
        \\  make
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 5), steps.len);
    try std.testing.expectEqualStrings("verify", info.execution.?.verify_step.?.name);
    try std.testing.expectEqualStrings(
        "test -f upstream.tar.gz",
        info.execution.?.verify_step.?.body,
    );
    try std.testing.expect(std.mem.indexOf(u8, info.execution.?.shared_helpers, "verify()") == null);

    try std.testing.expectEqualStrings("prepare", steps[0].name);
    try std.testing.expectEqualStrings("patch -p1 < fix.patch", steps[0].body);

    try std.testing.expectEqualStrings("pkgver", steps[1].name);
    try std.testing.expectEqualStrings("git describe --long", steps[1].body);

    try std.testing.expectEqualStrings("build", steps[2].name);
    try std.testing.expectEqualStrings("make", steps[2].body);

    try std.testing.expectEqualStrings("check", steps[3].name);
    try std.testing.expectEqualStrings("make test", steps[3].body);

    try std.testing.expectEqualStrings("package", steps[4].name);
    try std.testing.expectEqualStrings("make install", steps[4].body);
}

test "parser_content: execution steps skip functions the PKGBUILD does not define" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=demo
        \\
        \\build() {
        \\  cargo build --release
        \\}
        \\
        \\package() {
        \\  install -Dm755 target/demo "$pkgdir/usr/bin/demo"
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 2), steps.len);
    try std.testing.expectEqualStrings("build", steps[0].name);
    try std.testing.expectEqualStrings("cargo build --release", steps[0].body);
    try std.testing.expectEqualStrings("package", steps[1].name);
    try std.testing.expectEqualStrings("install -Dm755 target/demo \"$pkgdir/usr/bin/demo\"", steps[1].body);
}

test "parser_content: quoted braces keep AUR lifecycle steps separate" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=equicord-openasar
        \\pkgver=1
        \\pkgrel=1
        \\prepare() {
        \\  sed -i \\
        \\    -e '#async function fetchUpdates\\(\\) {#a return false;' \\
        \\    -e '#async function applyUpdates\\(\\) {#a return false;' \\
        \\    src/updater.ts
        \\}
        \\build() {
        \\  pnpm build
        \\}
        \\package() {
        \\  install -Dm644 app.asar "$pkgdir/usr/lib/app.asar"
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 3), steps.len);
    try std.testing.expectEqualStrings("prepare", steps[0].name);
    try std.testing.expect(std.mem.indexOf(u8, steps[0].body, "fetchUpdates") != null);
    try std.testing.expect(std.mem.indexOf(u8, steps[0].body, "build()") == null);
    try std.testing.expectEqualStrings("build", steps[1].name);
    try std.testing.expectEqualStrings("pnpm build", steps[1].body);
    try std.testing.expectEqualStrings("package", steps[2].name);
    try std.testing.expectEqualStrings(
        "install -Dm644 app.asar \"$pkgdir/usr/lib/app.asar\"",
        steps[2].body,
    );
}

test "parser_content: Darkly-style subshell lifecycle functions produce execution steps" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=darkly
        \\pkgver=0.5.39
        \\pkgrel=1
        \\arch=('x86_64' 'aarch64')
        \\build_dir=build_kf6
        \\depends_kf6=('kdecoration' 'qt6-declarative' 'libplasma')
        \\depends_kf5=('kcmutils5' 'kirigami2')
        \\depends=("${depends_kf6[@]}" "${depends_kf5[@]}")
        \\build() (
        \\  local cmake_options=(
        \\    -B $build_dir
        \\    -S "Darkly-${pkgver}"
        \\    -DBUILD_TESTING=OFF
        \\  )
        \\  cmake "${cmake_options[@]}"
        \\  cmake --build $build_dir
        \\)
        \\package() (
        \\  DESTDIR="$pkgdir" cmake --install $build_dir
        \\  rm -rf "$pkgdir/usr/lib/cmake"
        \\)
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(info.execution != null);
    try std.testing.expectEqual(@as(usize, 2), info.execution.?.steps.len);
    try std.testing.expectEqualStrings("build", info.execution.?.steps[0].name);
    try std.testing.expect(std.mem.indexOf(
        u8,
        info.execution.?.steps[0].body,
        "cmake --build $build_dir",
    ) != null);
    try std.testing.expectEqualStrings("package", info.execution.?.steps[1].name);
    try std.testing.expect(std.mem.indexOf(
        u8,
        info.execution.?.steps[1].body,
        "cmake --install $build_dir",
    ) != null);
    try std.testing.expect(info.has_build_function);
    try std.testing.expect(info.has_generic_package_function);
}

test "parser_content: subshell helper definitions preserve subshell semantics" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=demo
        \\helper() (
        \\  cd nested
        \\  generate
        \\)
        \\build() (
        \\  helper
        \\)
        \\package() { install -Dm755 demo "$pkgdir/usr/bin/demo"; }
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(
        u8,
        info.execution.?.shared_helpers,
        "helper() (\ncd nested\n  generate\n)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        info.execution.?.shared_helpers,
        "helper() {",
    ) == null);
}

test "parser_content: execution steps is null when no known functions are defined" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=demo
        \\
        \\helper() {
        \\  echo "not an execution step"
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(info.execution == null);
}

test "parser_content: verify-only execution remains separate from extracted lifecycle steps" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=demo
        \\verify() {
        \\  _authenticate source.tar.gz
        \\}
        \\_authenticate() {
        \\  test -f "$1"
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), info.execution.?.steps.len);
    try std.testing.expectEqualStrings("verify", info.execution.?.verify_step.?.name);
    try std.testing.expect(std.mem.indexOf(
        u8,
        info.execution.?.shared_helpers,
        "_authenticate()",
    ) != null);
}

test "parser_content: execution steps resolve package-scoped function for selected split package" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "demo-two",
    };
    const content =
        \\pkgname=('demo-one' 'demo-two')
        \\
        \\build() {
        \\  make
        \\}
        \\
        \\package_demo-one() {
        \\  make install-one
        \\}
        \\
        \\package_demo-two() {
        \\  make install-two
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 2), steps.len);
    try std.testing.expectEqualStrings("build", steps[0].name);
    try std.testing.expectEqualStrings("make", steps[0].body);
    try std.testing.expectEqualStrings("package_demo-two", steps[1].name);
    try std.testing.expectEqualStrings("make install-two", steps[1].body);
}

test "parser_content: execution steps fall back to package() when package-scoped function is missing" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "demo",
    };
    const content =
        \\pkgname=('demo')
        \\
        \\package() {
        \\  make install
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    try std.testing.expectEqualStrings("package", steps[0].name);
    try std.testing.expectEqualStrings("make install", steps[0].body);
}

test "parser_content: execution step bodies preserve nested blocks" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=demo
        \\
        \\check() {
        \\  if [ "$CARCH" = "x86_64" ]; then
        \\    make test
        \\  fi
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    try std.testing.expectEqualStrings("check", steps[0].name);
    // The body is preserved verbatim; only surrounding whitespace is trimmed.
    try std.testing.expectEqualStrings(
        \\if [ "$CARCH" = "x86_64" ]; then
        \\    make test
        \\  fi
    , steps[0].body);
}

test "parser_content: execution prelude preserves generic scalars arrays and appends" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=demo
        \\pkgver=1
        \\_gitname=scx
        \\_label=can
        \\_label+="'t"
        \\_backports=(first "second value")
        \\_backports+=(third)
        \\_combined=("${_backports[@]}" tail)
        \\_literal=('$(not-executed)')
        \\_reverts=()
        \\prepare() {
        \\  for commit in "${_backports[@]}"; do echo "$commit"; done
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, "/build/demo");
    defer info.deinit(std.testing.allocator);

    const prelude = info.execution.?.shared_prelude;
    try std.testing.expect(std.mem.indexOf(
        u8,
        prelude,
        "declare -a _backports=('first' 'second value' 'third')",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, prelude, "declare -a _reverts=()") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        prelude,
        "declare -a _combined=('first' 'second value' 'third' 'tail')",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        prelude,
        "declare -a _literal=('$(not-executed)')",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, prelude, "declare -- _gitname='scx'") != null);
    try std.testing.expect(std.mem.indexOf(u8, prelude, "declare -- _label='can'\\''t'") != null);
}

test "parser_content: scalar command substitution is recorded for build-time evaluation" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var info = try parse_test_pkgbuild(parser,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\_date="$(date -u +%Y%m%d)"
        \\package() { :; }
    , null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(info.hasDynamicAssignments());
    try std.testing.expectEqual(@as(usize, 1), info.dynamic_assignments.len);
    try std.testing.expectEqualStrings("_date", info.dynamic_assignments[0].name);
    try std.testing.expectEqualStrings("_date=\"$(date -u +%Y%m%d)\"", info.dynamic_assignments[0].statement);
    // The unresolved variable is absent from the analysis-time map.
    try std.testing.expect(info.variables.get("_date") == null);
}

test "parser_content: seeded dynamic override resolves dependent fields" {
    var overrides: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer overrides.deinit();
    try overrides.put("_date", "20260819");

    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .dynamic_overrides = &overrides,
    };
    var info = try parse_test_pkgbuild(parser,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\_date="$(date -u +%Y%m%d)"
        \\source=("demo-$_date.tar.gz::https://example.test/demo-$_date.tar.gz")
        \\sha256sums=('SKIP')
        \\package() { :; }
    , null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(!info.hasDynamicAssignments());
    try std.testing.expectEqualStrings("20260819", info.variables.get("_date").?);
    try std.testing.expectEqual(@as(usize, 1), info.source.?.len);
    try std.testing.expectEqualStrings(
        "demo-20260819.tar.gz::https://example.test/demo-20260819.tar.gz",
        info.source.?[0],
    );
}

test "parser_content: arbitrary array command substitution is deferred to sandbox evaluation" {
    const content =
        \\pkgname=demo
        \\pkgver=1
        \\arch=('any')
        \\_items=($(generate_items))
        \\package() { :; }
    ;
    var initial = try (PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
    }).parser_content(content, null);
    defer initial.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, initial.execution.?.shared_prelude, "declare -a _items=") == null);

    var array_overrides = std.StringHashMap([]const []const u8).init(std.testing.allocator);
    defer array_overrides.deinit();
    try array_overrides.put("_items", &.{ "one", "second value" });
    var evaluated = try (PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .dynamic_array_overrides = &array_overrides,
    }).parser_content(content, null);
    defer evaluated.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        evaluated.execution.?.shared_prelude,
        "declare -a _items=('one' 'second value')",
    ) != null);

    var empty_overrides = std.StringHashMap([]const []const u8).init(std.testing.allocator);
    defer empty_overrides.deinit();
    var array_unsets = std.StringHashMap(void).init(std.testing.allocator);
    defer array_unsets.deinit();
    try array_unsets.put("_items", {});
    var unset = try (PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .dynamic_array_overrides = &empty_overrides,
        .dynamic_array_unsets = &array_unsets,
    }).parser_content(content, null);
    defer unset.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, unset.execution.?.shared_prelude, "declare -a _items=") == null);
    try std.testing.expect(std.mem.indexOf(u8, unset.execution.?.shared_prelude, "unset -- _items") != null);
}

test "parser_content: issue 1750 source command substitution is deferred and overridden" {
    const content =
        \\pkgname=gpu-screen-recorder-ui-git
        \\pkgver=1
        \\pkgrel=1
        \\arch=('x86_64')
        \\_pkgname="gpu-screen-recorder-ui"
        \\url="https://git.dec05eba.com/gpu-screen-recorder-ui"
        \\_pkgsrc="$_pkgname"
        \\source=("$_pkgsrc"::"git+$(sed 's&//git\.&//repo.&' <<< "$url")")
        \\sha256sums=('SKIP')
        \\package() { :; }
    ;
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "gpu-screen-recorder-ui-git",
    };
    var initial = try parser.parser_content(content, null);
    defer initial.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), initial.dynamic_source_assignments.len);
    try std.testing.expect(initial.dynamic_source_assignments[0].has_command_substitution);
    try std.testing.expectEqualStrings("sha256sums", initial.dynamic_source_assignments[1].name);
    try std.testing.expectEqual(@as(usize, 1), initial.source.?.len);
    try std.testing.expectEqualStrings(
        "gpu-screen-recorder-ui::git+$(sed 's&//git\\.&//repo.&' <<< https://git.dec05eba.com/gpu-screen-recorder-ui)",
        initial.source.?[0],
    );
    try std.testing.expectEqual(@as(usize, 0), initial.local_source_files.?.len);

    var array_overrides: std.StringHashMap([]const []const u8) = .init(std.testing.allocator);
    defer array_overrides.deinit();
    try array_overrides.put("source", &.{
        "gpu-screen-recorder-ui::git+https://repo.dec05eba.com/gpu-screen-recorder-ui",
    });
    var resolved = try (PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "gpu-screen-recorder-ui-git",
        .dynamic_array_overrides = &array_overrides,
    }).parser_content(content, null);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), resolved.dynamic_source_assignments.len);
    try std.testing.expectEqualStrings(
        "gpu-screen-recorder-ui::git+https://repo.dec05eba.com/gpu-screen-recorder-ui",
        resolved.source.?[0],
    );
    try std.testing.expectEqual(@as(usize, 0), resolved.local_source_files.?.len);
}

test "parser_content: dynamic source keeps assignment and architecture append ordering" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var info = try parse_test_pkgbuild(parser,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\source=('base.patch')
        \\source+=(
        \\  "remote::https://$(printf example.test)/source"
        \\)
        \\source_x86_64=("arch::https://$(printf arch.example.test)/source")
        \\sha256sums=('SKIP' 'SKIP')
        \\sha256sums_x86_64=('SKIP')
        \\package() { :; }
    , null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), info.dynamic_source_assignments.len);
    try std.testing.expectEqualStrings("source", info.dynamic_source_assignments[0].name);
    try std.testing.expect(!info.dynamic_source_assignments[0].has_command_substitution);
    try std.testing.expect(info.dynamic_source_assignments[1].has_command_substitution);
    try std.testing.expectEqualStrings("source_x86_64", info.dynamic_source_assignments[2].name);
    try std.testing.expect(info.dynamic_source_assignments[2].has_command_substitution);
    try std.testing.expectEqualStrings("sha256sums", info.dynamic_source_assignments[3].name);
    try std.testing.expectEqualStrings("sha256sums_x86_64", info.dynamic_source_assignments[4].name);
    try std.testing.expectEqual(@as(usize, 1), info.local_source_files.?.len);
    try std.testing.expectEqualStrings("base.patch", info.local_source_files.?[0]);
}

test "parser_content: conditional source integrity arrays are deferred as one family" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=generic-conditional
        \\pkgver=1
        \\pkgrel=1
        \\arch=('x86_64')
        \\_feature=yes
        \\source=('base.patch')
        \\sha256sums=('base-sum')
        \\if [ "$_feature" = yes ]; then
        \\  source+=('feature.patch')
        \\  sha256sums+=('feature-sum')
        \\fi
        \\case "$CARCH" in
        \\  x86_64)
        \\    source_x86_64+=('architecture.patch')
        \\    sha256sums_x86_64+=('architecture-sum')
        \\    ;;
        \\esac
        \\package() { :; }
    ;
    var initial = try parser.parser_content(content, null);
    defer initial.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 6), initial.dynamic_source_assignments.len);
    try std.testing.expectEqual(@as(usize, 1), initial.source.?.len);
    try std.testing.expectEqual(@as(usize, 1), initial.sha_256_sums.?.len);

    var array_overrides: std.StringHashMap([]const []const u8) = .init(std.testing.allocator);
    defer array_overrides.deinit();
    try array_overrides.put("source", &.{ "base.patch", "feature.patch" });
    try array_overrides.put("sha256sums", &.{ "base-sum", "feature-sum" });
    try array_overrides.put("source_x86_64", &.{"architecture.patch"});
    try array_overrides.put("sha256sums_x86_64", &.{"architecture-sum"});
    var resolved = try (PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .dynamic_array_overrides = &array_overrides,
    }).parser_content(content, null);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), resolved.dynamic_source_assignments.len);
    try std.testing.expectEqual(@as(usize, 3), resolved.source.?.len);
    try std.testing.expectEqualStrings("architecture.patch", resolved.source.?[2]);
    try std.testing.expectEqual(@as(usize, 3), resolved.sha_256_sums.?.len);
    try std.testing.expectEqualStrings("architecture-sum", resolved.sha_256_sums.?[2]);
}

test "parser_content: source URL resolves CARCH statically" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var info = try parse_test_pkgbuild(parser,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\source=("demo-$CARCH.tar.gz::https://example.test/demo-$CARCH.tar.gz")
        \\sha256sums=('SKIP')
        \\package() { :; }
    , null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), info.source.?.len);
    try std.testing.expectEqualStrings(
        "demo-x86_64.tar.gz::https://example.test/demo-x86_64.tar.gz",
        info.source.?[0],
    );
}

test "parser_content: dynamic date and CARCH both resolve in source" {
    var overrides: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer overrides.deinit();
    try overrides.put("_date", "20260819");

    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .dynamic_overrides = &overrides,
    };
    var info = try parse_test_pkgbuild(parser,
        \\pkgname=demo-nightly-bin
        \\pkgver=1
        \\pkgrel=1
        \\_date="$(date -u +%Y%m%d)"
        \\source=("demo-$_date-$CARCH.zip::https://example.test/nightly/demo-$CARCH-linux-gnu.zip")
        \\sha256sums=('SKIP')
        \\package() { :; }
    , null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), info.source.?.len);
    try std.testing.expectEqualStrings(
        "demo-20260819-x86_64.zip::https://example.test/nightly/demo-x86_64-linux-gnu.zip",
        info.source.?[0],
    );
}

test "parser_content: scx style PKGBUILD with commented backports parses" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var info = try parser.parser_content(
        \\# Maintainer: Peter Jung ptr1337 <admin@ptr1337.dev>
        \\# Maintainer: Piotr Górski <lucjan.lucjanov@gmail.com>
        \\# Contributor: Tejun Heo <tj@kernel.org>
        \\
        \\# Available profiles: “release”, “release-tiny”, “release-fast“
        \\# See: https://github.com/sched-ext/scx/blob/main/Cargo.toml
        \\_mode=release
        \\
        \\pkgname=scx-scheds-git
        \\_gitname=scx
        \\pkgver=1.1.2.r109.g096342e06
        \\pkgrel=1
        \\pkgdesc='sched_ext schedulers and tools'
        \\url='https://github.com/sched-ext/scx'
        \\arch=('x86_64')
        \\license=('GPL-2.0-only')
        \\depends=(
        \\  libseccomp
        \\  libelf
        \\  zlib
        \\)
        \\makedepends=(
        \\  cargo
        \\  clang
        \\  git
        \\  llvm
        \\  llvm-libs
        \\)
        \\optdepends=(
        \\'scx-tools: scx_loader and scxctl - A DBUS Interface for Managing sched_ext Schedulers '
        \\)
        \\options=(!lto)
        \\provides=("scx-scheds")
        \\conflicts=("scx-scheds")
        \\source=("git+https://github.com/sched-ext/scx")
        \\sha256sums=('SKIP')
        \\
        \\_backports=(
        \\9d9398fcb7d97bf3ba4fa851afbd1aee84225035 # scx_cake: 1.2.0 — clean-slate EEVDF-parity rewrite
        \\c400cfe078ba18fda721623ec350589da3ba62b6 # scx_cake: identity-gated preempt fast paths + RT-owned CPU avoidance
        \\d2a0488beaa506a2ba072856acd37a8a67c30e05 # scx_cake 1.2.0: K+L+M+S1d checkpoint — game gate passed, sealed benchmark wins
        \\aff3b3e83aa1360e2dff098c49f32345b2267e69 # scx_cake: G20-G26 campaign checkpoint -- first frame win over native EEVDF
        \\f81768c9d4ee80c531b0d62e2b5cf9682db34d15 # scheds: Introduce scx_maestro
        \\0a1ee1a70f6e342e7f03198b8f60618dbc6b2146 # scx_maestro: Honor cgroup cpu.weight for tasks and sub-schedulers
        \\78edbf583f264fe8fd8da14431c4eb0cc08f3c5d # scx_maestro: Allow to enable/disable NUMA and SMT optimizations
        \\308a0f86b81b4c9d216c329087e32446c57089ef # scx_maestro: Don't update deadline in case of re-enqueue
        \\a1b3b62908ff87f29004723945f234df392f1537 # scx_maestro: Introduce completely fair scheduling
        \\df5e4db110f7f6f8dd40b697925e10c8a69a490d # scx_maestro: Make enqueue + CPU kick more reliable
        \\1c522b684df912ff1331843f611c3ce00187b801 # scx_maestro: Enforce preemption each tick on CPU contention
        \\f4027d565a830ef640f06531af0b27318747ccb9 # scx_maestro: Temporarily drop sub-sched support
        \\1aa5c53760f1b1c244dc790c46b28ea999ac1827 # scx_maestro: bump to 1.1.1
        \\593d82c4c1d2585697ff62e97c28cd263b705d73 # scx_maestro: fix formatting
        \\93e75b8cc9d1eb1a221c9c03c7131f37937e3404 # scx_maestro: bump to 1.1.2
        \\7b4def157aaa88f038906268081fb95c2a619a78 # scx_maestro: Use scx_bpf_task_set_slice() setter
        \\099df006b3d903b6665bacbde70d9dac6af5d2fe # scx_pandemonium: bump to 5.17.0
        \\9c7987d7153ae0e1769ba708011147a51b95a562 # scx_pandemonium: bump to 5.17.1
        \\5d0467ac827b8f1e98bbf57ccbdbf88a96a47b23 # Cargo: update dependencies to latest versions
        \\)
        \\
        \\_reverts=(
        \\)
        \\
        \\pkgver() {
        \\  cd $_gitname
        \\  git describe --long --tags | sed 's/^v//;s/\([^-]*-g\)/r\1/;s/-/./g'
        \\}
        \\
        \\prepare() {
        \\  cd $_gitname
        \\
        \\  local _c _l
        \\   for _c in "${_backports[@]}"; do
        \\     if [[ "${_c}" == *..* ]]; then _l='--reverse'; else _l='--max-count=1'; fi
        \\     git log --oneline "${_l}" "${_c}"
        \\     git cherry-pick --mainline 1 --no-commit "${_c}"
        \\   done
        \\   for _c in "${_reverts[@]}"; do
        \\     if [[ "${_c}" == *..* ]]; then _l='--reverse'; else _l='--max-count=1'; fi
        \\     git log --oneline "${_l}" "${_c}"
        \\     git revert --mainline 1 --no-commit "${_c}"
        \\   done
        \\
        \\  local src
        \\   for src in "${source[@]}"; do
        \\     src="${src%%::*}"
        \\     src="${src##*/}"
        \\     [[ $src = *.patch ]] || continue
        \\     echo "Applying patch $src..."
        \\     patch -Np1 < "../$src"
        \\   done
        \\
        \\  export RUSTUP_TOOLCHAIN=stable
        \\  cargo fetch --locked --target "$(rustc -vV | sed -n 's/host: //p')"
        \\}
        \\
        \\build() {
        \\  cd $_gitname
        \\  export RUSTUP_TOOLCHAIN=stable
        \\  export CARGO_TARGET_DIR=target
        \\  cargo build \
        \\     --profile=$_mode \
        \\     --frozen \
        \\     --workspace \
        \\     --exclude scx_rlfifo \
        \\     --exclude scx_characterize \
        \\     --exclude xtask \
        \\     --exclude vmlinux_docify \
        \\     --exclude scx_arena_selftests
        \\}
        \\
        \\package() {
        \\  cd $_gitname
        \\
        \\  # Install all built executables (skip .so and .d files)
        \\  find target/$_mode \
        \\    -maxdepth 1 -type f -executable ! -name '*.so' \
        \\    -exec install -Dm755 -t "$pkgdir/usr/bin/" {} +
        \\}
    , null);
    defer info.deinit(std.testing.allocator);

    const prelude = info.execution.?.shared_prelude;
    try std.testing.expect(std.mem.indexOf(
        u8,
        prelude,
        "declare -a _backports=('9d9398fcb7d97bf3ba4fa851afbd1aee84225035' 'c400cfe078ba18fda721623ec350589da3ba62b6' 'd2a0488beaa506a2ba072856acd37a8a67c30e05' 'aff3b3e83aa1360e2dff098c49f32345b2267e69' 'f81768c9d4ee80c531b0d62e2b5cf9682db34d15' '0a1ee1a70f6e342e7f03198b8f60618dbc6b2146' '78edbf583f264fe8fd8da14431c4eb0cc08f3c5d' '308a0f86b81b4c9d216c329087e32446c57089ef' 'a1b3b62908ff87f29004723945f234df392f1537' 'df5e4db110f7f6f8dd40b697925e10c8a69a490d' '1c522b684df912ff1331843f611c3ce00187b801' 'f4027d565a830ef640f06531af0b27318747ccb9' '1aa5c53760f1b1c244dc790c46b28ea999ac1827' '593d82c4c1d2585697ff62e97c28cd263b705d73' '93e75b8cc9d1eb1a221c9c03c7131f37937e3404' '7b4def157aaa88f038906268081fb95c2a619a78' '099df006b3d903b6665bacbde70d9dac6af5d2fe' '9c7987d7153ae0e1769ba708011147a51b95a562' '5d0467ac827b8f1e98bbf57ccbdbf88a96a47b23')",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, prelude, "declare -a _reverts=()") != null);
    try std.testing.expect(std.mem.indexOf(u8, prelude, "declare -- _mode='release'") != null);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 4), steps.len);
    try std.testing.expectEqualStrings("prepare", steps[0].name);
    try std.testing.expectEqualStrings("pkgver", steps[1].name);
    try std.testing.expectEqualStrings("build", steps[2].name);
    try std.testing.expectEqualStrings("package", steps[3].name);
}

test "parser_content: array comment quotes do not leak past the closing paren" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var info = try parser.parser_content(
        \\pkgname=demo
        \\pkgver=1
        \\arch=('any')
        \\_list=(
        \\abc123 # Don't let this apostrophe escape the array
        \\def456
        \\)
        \\prepare() {
        \\  :
        \\}
        \\package() {
        \\  echo "$(impossible)" > /dev/null
        \\}
    , null);
    defer info.deinit(std.testing.allocator);

    const prelude = info.execution.?.shared_prelude;
    try std.testing.expect(std.mem.indexOf(u8, prelude, "declare -a _list=('abc123' 'def456')") != null);
}

test "parser_content: execution step expanded bodies resolve PKGBUILD and makepkg variables" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=hello
        \\pkgver=1.2.3
        \\pkgrel=2
        \\_commit=abc1234
        \\
        \\prepare() {
        \\  git checkout "$_commit"
        \\}
        \\
        \\build() {
        \\  cd "$srcdir/$pkgname-$pkgver"
        \\  make
        \\}
        \\
        \\package() {
        \\  make DESTDIR="$pkgdir" install
        \\  install -Dm644 README "$pkgdir/usr/share/doc/$pkgname/README"
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, "/build/hello");
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 3), steps.len);

    // raw bodies are preserved for review
    try std.testing.expectEqualStrings("git checkout \"$_commit\"", steps[0].body);
    try std.testing.expectEqualStrings("cd \"$srcdir/$pkgname-$pkgver\"\n  make", steps[1].body);

    try std.testing.expectEqualStrings("git checkout \"abc1234\"", steps[0].expanded_body);
    try std.testing.expectEqualStrings(
        \\cd "/build/hello/src/hello-1.2.3"
        \\  make
    , steps[1].expanded_body);
    try std.testing.expectEqualStrings(
        \\make DESTDIR="/build/hello/pkg/hello" install
        \\  install -Dm644 README "/build/hello/pkg/hello/usr/share/doc/hello/README"
    , steps[2].expanded_body);
}

test "parser_content: execution step expansion respects single quotes and escapes" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=hello
        \\pkgver=1.2.3
        \\
        \\package() {
        \\  echo '$pkgname is not expanded'
        \\  echo "$pkgname is expanded"
        \\  echo \$pkgname stays literal
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    try std.testing.expectEqualStrings(
        \\echo '$pkgname is not expanded'
        \\  echo "hello is expanded"
        \\  echo \$pkgname stays literal
    , steps[0].expanded_body);
}

test "parser_content: execution step expansion keeps runtime syntax for the shell" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=hello
        \\
        \\build() {
        \\  cd "$pkgname-$(pkgver)"
        \\  for f in *.patch; do patch -p1 < "$f"; done
        \\  test $? -eq 0 && echo ${UNSET_VAR:-ok} $$
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    try std.testing.expectEqualStrings(
        \\cd "hello-$(pkgver)"
        \\  for f in *.patch; do patch -p1 < "$f"; done
        \\  test $? -eq 0 && echo ${UNSET_VAR:-ok} $$
    , steps[0].expanded_body);
}

test "parser_content: execution step expansion leaves directory variables literal without base_dir" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=hello
        \\pkgver=1.0
        \\
        \\package() {
        \\  install -Dm755 hello "$pkgdir/usr/bin/hello"
        \\  cd "$srcdir/$pkgname-$pkgver"
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    try std.testing.expectEqualStrings(
        \\install -Dm755 hello "$pkgdir/usr/bin/hello"
        \\  cd "$srcdir/hello-1.0"
    , steps[0].expanded_body);
}

test "parser_content: execution step expansion uses selected split package for pkgname and pkgdir" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "demo-two",
    };
    const content =
        \\pkgname=('demo-one' 'demo-two')
        \\pkgver=2.0
        \\
        \\package_demo-two() {
        \\  echo "$pkgbase $pkgname"
        \\  install -Dm644 license "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, "/build/demo");
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    try std.testing.expectEqualStrings("package_demo-two", steps[0].name);
    try std.testing.expectEqualStrings(
        \\echo "demo-one demo-two"
        \\  install -Dm644 license "/build/demo/pkg/demo-two/usr/share/licenses/demo-two/LICENSE"
    , steps[0].expanded_body);
}

test "parser_content: execution step expansion applies parameter expansion operators" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=hello-world
        \\pkgver=1.2.3
        \\pkgrel=2
        \\_archive=hello-world-1.2.3.tar.gz
        \\
        \\build() {
        \\  tar xf ${_archive%%.tar.gz}.tar.xz
        \\  dir=${pkgname##*-}
        \\  short=${pkgver:0:3}
        \\  fixed=${pkgname//-/_}
        \\  rel=$((pkgrel + 1))
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    try std.testing.expectEqualStrings(
        \\tar xf hello-world-1.2.3.tar.xz
        \\  dir=world
        \\  short=1.2
        \\  fixed=hello_world
        \\  rel=3
    , steps[0].expanded_body);
}

test "parser_content: execution step expansion keeps quoted heredoc bodies literal" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=hello
        \\
        \\package() {
        \\  cat <<'EOF' | install -Dm644 /dev/stdin "$pkgdir/usr/share/applications/hello.desktop"
        \\[Desktop Entry]
        \\Name=$pkgname stays literal
        \\Comment=don't let apostrophes break expansion
        \\EOF
        \\  echo "$pkgname"
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    // The quoted body survives verbatim (including $pkgname), while code
    // before and after it still expands — proving quote tracking did not
    // leak out of the heredoc body.
    try std.testing.expectEqualStrings(
        \\cat <<'EOF' | install -Dm644 /dev/stdin "$pkgdir/usr/share/applications/hello.desktop"
        \\[Desktop Entry]
        \\Name=$pkgname stays literal
        \\Comment=don't let apostrophes break expansion
        \\EOF
        \\  echo "hello"
    , steps[0].expanded_body);
}

test "parser_content: execution step expansion expands unquoted heredoc bodies" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=hello
        \\pkgver=1.0
        \\
        \\package() {
        \\  cat > "$pkgdir/hello.txt" << EOF
        \\Name=$pkgname
        \\Version=$pkgver
        \\Note=quotes do not protect ' inside heredoc bodies
        \\EOF
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    try std.testing.expectEqualStrings(
        \\cat > "$pkgdir/hello.txt" << EOF
        \\Name=hello
        \\Version=1.0
        \\Note=quotes do not protect ' inside heredoc bodies
        \\EOF
    , steps[0].expanded_body);
}

test "parser_content: execution step expansion shields nested heredocs inside quoted bodies" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    // Mirrors the Shelly PKGBUILD: a quoted <<'SCRIPT' body that is itself
    // a bash script containing variables, apostrophes and a nested heredoc.
    const content =
        \\pkgname=shelly
        \\
        \\package() {
        \\  cat <<'SCRIPT' | install -Dm755 /dev/stdin "$pkgdir/usr/bin/tool"
        \\#!/bin/bash
        \\# don't break on apostrophes
        \\dest="$HOME/.local/share"
        \\filename=app.desktop
        \\app_id="${filename%.desktop}"
        \\cat >> "$dest" << EOF
        \\Name=$pkgname
        \\EOF
        \\SCRIPT
        \\  install -Dm644 README "$pkgdir/README"
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, "/build/shelly");
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    try std.testing.expectEqualStrings(
        \\cat <<'SCRIPT' | install -Dm755 /dev/stdin "/build/shelly/pkg/shelly/usr/bin/tool"
        \\#!/bin/bash
        \\# don't break on apostrophes
        \\dest="$HOME/.local/share"
        \\filename=app.desktop
        \\app_id="${filename%.desktop}"
        \\cat >> "$dest" << EOF
        \\Name=$pkgname
        \\EOF
        \\SCRIPT
        \\  install -Dm644 README "/build/shelly/pkg/shelly/README"
    , steps[0].expanded_body);
}

test "parser_content: execution step expansion matches tab-indented heredoc terminators" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content = "pkgname=hello\n\npackage() {\n  cat <<-EOF\n\tbody line $pkgname\n\tEOF\n  echo done\n}";
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    try std.testing.expectEqualStrings(
        "cat <<-EOF\n\tbody line hello\n\tEOF\n  echo done",
        steps[0].expanded_body,
    );
}

test "parser_content: execution step expansion does not mistake arithmetic shifts for heredocs" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=hello
        \\
        \\build() {
        \\  echo $((1 << 4))
        \\  echo "$pkgname"
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    // The shift never opens a heredoc: the following line still expands.
    try std.testing.expectEqualStrings(
        \\echo 1
        \\  echo "hello"
    , steps[0].expanded_body);
}

test "parser_content: execution step expansion does not mistake here-strings for heredocs" {
    // Issue 1848 (rime-ice-pinyin-git): `<<<` with a quoted command
    // substitution was treated as a heredoc introducer, swallowing the
    // rest of the function body.
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=hello
        \\
        \\build() {
        \\  mapfile -t deps <<< "$(sed -n '/dependencies:/,/^$/ {/dependencies:/d; p }' list.txt)"
        \\  echo "$pkgname"
        \\}
        \\
        \\package() {
        \\  echo "$pkgname"
        \\}
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);

    const steps = info.execution.?.steps;
    try std.testing.expectEqual(@as(usize, 2), steps.len);
    try std.testing.expectEqualStrings("build", steps[0].name);
    try std.testing.expectEqualStrings(
        \\mapfile -t deps <<< "$(sed -n '/dependencies:/,/^$/ {/dependencies:/d; p }' list.txt)"
        \\  echo "hello"
    , steps[0].expanded_body);
    try std.testing.expectEqualStrings("package", steps[1].name);
    try std.testing.expectEqualStrings("echo \"hello\"", steps[1].expanded_body);
}

test "parser_content: architecture sources and b2 sums follow makepkg ordering" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .package_carch = "aarch64",
    };
    const content =
        \\pkgname=qwen-code-bin
        \\arch=('aarch64')
        \\source=('common.txt')
        \\source_x86_64=('x86.tar.gz')
        \\source_aarch64=('arm.tar.gz')
        \\b2sums=('SKIP')
        \\b2sums_x86_64=('wrong-arch')
        \\b2sums_aarch64=('SKIP')
        \\noextract=('arm.tar.gz')
    ;
    var info = try parser.parser_content(content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), info.source.?.len);
    try std.testing.expectEqualStrings("common.txt", info.source.?[0]);
    try std.testing.expectEqualStrings("arm.tar.gz", info.source.?[1]);
    try std.testing.expectEqual(@as(usize, 2), info.b_2_sums.?.len);
    try std.testing.expectEqualStrings("SKIP", info.b_2_sums.?[0]);
    try std.testing.expectEqualStrings("SKIP", info.b_2_sums.?[1]);
    try std.testing.expectEqualStrings("arm.tar.gz", info.no_extract.?[0]);
}

test "architecture-specific build dependencies merge active suffixes" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .package_carch = "aarch64",
    };
    const content =
        \\pkgname=dependency-demo
        \\arch=('x86_64' 'aarch64')
        \\makedepends=('cmake>=3')
        \\makedepends_x86_64=('nasm')
        \\makedepends_aarch64=('meson')
        \\checkdepends=('pytest')
        \\checkdepends_x86_64=('dejagnu')
        \\checkdepends_aarch64=('bats>=1')
    ;
    var info = try parser.parser_content(content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), info.make_depends.?.len);
    try std.testing.expectEqualStrings("cmake>=3", info.make_depends.?[0]);
    try std.testing.expectEqualStrings("meson", info.make_depends.?[1]);
    try std.testing.expectEqual(@as(usize, 2), info.parsed_make_depends.?.len);
    try std.testing.expectEqualStrings("cmake", info.parsed_make_depends.?[0].name);
    try std.testing.expectEqualStrings("3", info.parsed_make_depends.?[0].version);
    try std.testing.expectEqualStrings("meson", info.parsed_make_depends.?[1].name);

    try std.testing.expectEqual(@as(usize, 2), info.check_depends.?.len);
    try std.testing.expectEqualStrings("pytest", info.check_depends.?[0]);
    try std.testing.expectEqualStrings("bats>=1", info.check_depends.?[1]);
    try std.testing.expectEqual(@as(usize, 2), info.parsed_check_depends.?.len);
    try std.testing.expectEqualStrings("bats", info.parsed_check_depends.?[1].name);
    try std.testing.expectEqualStrings("1", info.parsed_check_depends.?[1].version);
}

test "architecture directives enforce makepkg rules" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };

    var native = try parser.parser_content("pkgname=demo\narch=('x86_64')\n", null);
    native.deinit(std.testing.allocator);
    var portable = try parser.parser_content("pkgname=demo\narch=('any')\n", null);
    portable.deinit(std.testing.allocator);

    const custom_parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .package_carch = "custom_arch64",
    };
    var custom = try custom_parser.parser_content("pkgname=demo\narch=('custom_arch64')\n", null);
    custom.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.InvalidArchitectureDirective,
        parser.parser_content("pkgname=demo\n", null),
    );
    try std.testing.expectError(
        error.InvalidArchitectureDirective,
        parser.parser_content("pkgname=demo\narch=()\n", null),
    );
    try std.testing.expectError(
        error.UnsupportedArchitecture,
        parser.parser_content("pkgname=demo\narch=('aarch64')\n", null),
    );
    try std.testing.expectError(
        error.InvalidArchitectureDirective,
        parser.parser_content("pkgname=demo\narch=('x86_64' 'x86_64')\n", null),
    );
    try std.testing.expectError(
        error.InvalidArchitectureDirective,
        parser.parser_content("pkgname=demo\narch=('x86-64' 'x86_64')\n", null),
    );
    try std.testing.expectError(
        error.InvalidArchitectureDirective,
        parser.parser_content("pkgname=demo\narch=('any' 'x86_64')\n", null),
    );
}

test "split architecture overrides validate every member and inherit empty arrays" {
    const content =
        \\pkgname=('demo-native' 'demo-foreign' 'demo-portable')
        \\arch=('x86_64' 'aarch64')
        \\package_demo-native() {
        \\  arch=()
        \\}
        \\package_demo-foreign() {
        \\  arch=('aarch64')
        \\}
        \\package_demo-portable() {
        \\  arch=('any')
        \\}
    ;
    const native_parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "demo-native",
    };
    var native = try native_parser.parser_content(content, null);
    defer native.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), native.arch.?.len);
    try std.testing.expectEqualStrings("x86_64", native.arch.?[0]);
    try std.testing.expectEqualStrings("aarch64", native.arch.?[1]);

    const portable_parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "demo-portable",
    };
    var portable = try portable_parser.parser_content(content, null);
    defer portable.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), portable.arch.?.len);
    try std.testing.expectEqualStrings("any", portable.arch.?[0]);

    const invalid_member_prefix =
        \\pkgname=('demo-native' 'demo-invalid')
        \\arch=('x86_64' 'aarch64')
        \\package_demo-native() {
        \\  arch=('x86_64')
        \\}
    ;
    try std.testing.expectError(
        error.InvalidArchitectureDirective,
        native_parser.parser_content(invalid_member_prefix ++
            "\npackage_demo-invalid() {\n  arch=('riscv64')\n}\n", null),
    );
    try std.testing.expectError(
        error.InvalidArchitectureDirective,
        native_parser.parser_content(invalid_member_prefix ++
            "\npackage_demo-invalid() {\n  arch=('x86-64')\n}\n", null),
    );
    try std.testing.expectError(
        error.InvalidArchitectureDirective,
        native_parser.parser_content(invalid_member_prefix ++
            "\npackage_demo-invalid() {\n  arch=('any' 'x86_64')\n}\n", null),
    );
    try std.testing.expectError(
        error.InvalidArchitectureDirective,
        native_parser.parser_content(invalid_member_prefix ++
            "\npackage_demo-invalid() {\n  arch=('aarch64' 'aarch64')\n}\n", null),
    );
}

test "parser_content: resolves validpgpkeys as a global array" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=signed-demo
        \\validpgpkeys=(
        \\  '0123456789ABCDEF0123456789ABCDEF01234567'
        \\  '89ABCDEF0123456789ABCDEF0123456789ABCDEF'
        \\)
    ;
    var info = try parse_test_pkgbuild(parser, content, null);
    defer info.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), info.valid_pgp_keys.?.len);
    try std.testing.expectEqualStrings(
        "0123456789ABCDEF0123456789ABCDEF01234567",
        info.valid_pgp_keys.?[0],
    );
}
