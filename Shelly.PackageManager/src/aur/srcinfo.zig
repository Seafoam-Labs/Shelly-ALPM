const std = @import("std");
const pkgbuild_parser = @import("../pkgbuild/pkgbuild_parser.zig");
const arrays = @import("../pkgbuild/parser/arrays.zig");
const fields = @import("../pkgbuild/parser/fields.zig");
const function_body = @import("../pkgbuild/parser/function_body.zig");
const variables = @import("../pkgbuild/parser/variables.zig");
const dependencies = @import("../pkgbuild/parser/dependencies.zig");

const PkgbuildParser = pkgbuild_parser.PkgbuildParser;

pub const GenerateOptions = struct {
    package_carch: []const u8 = "x86_64",
    dynamic_overrides: ?*const std.StringHashMap([]const u8) = null,
    dynamic_unsets: ?*const std.StringHashMap(void) = null,
    dynamic_array_overrides: ?*const std.StringHashMap([]const []const u8) = null,
    dynamic_array_unsets: ?*const std.StringHashMap(void) = null,
};

const global_single_fields = [_][]const u8{
    "pkgdesc", "pkgver", "pkgrel", "epoch", "url", "install", "changelog",
};
const global_array_fields = [_][]const u8{
    "arch",       "groups",     "license",  "checkdepends", "makedepends",
    "depends",    "optdepends", "provides", "conflicts",    "replaces",
    "noextract",  "options",    "backup",   "source",       "validpgpkeys",
    "cksums",     "md5sums",    "sha1sums", "sha224sums",   "sha256sums",
    "sha384sums", "sha512sums", "b2sums",
};
const package_single_fields = [_][]const u8{ "pkgdesc", "url", "install", "changelog" };
const package_array_fields = [_][]const u8{
    "arch",       "groups",   "license",   "checkdepends", "depends",
    "optdepends", "provides", "conflicts", "replaces",     "options",
    "backup",
};
const architecture_array_fields = [_][]const u8{
    "source",     "provides",    "conflicts",    "depends",    "replaces",
    "optdepends", "makedepends", "checkdepends", "cksums",     "md5sums",
    "sha1sums",   "sha224sums",  "sha256sums",   "sha384sums", "sha512sums",
    "b2sums",
};

/// Writes makepkg-compatible SRCINFO content for a reviewed PKGBUILD. The
/// caller owns policy around review and sandbox evaluation; optional dynamic
/// maps let the serializer observe the already-evaluated top-level shell
/// state without executing package lifecycle functions.
pub fn writePkgbuild(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    content: []const u8,
    options: GenerateOptions,
) !void {
    const global_parser = parserFor(allocator, io, null, options);
    var names = try global_parser.package_names_content(content);
    defer names.deinit(allocator);

    var global_vars = try variables.build_var_hashmap(global_parser, content);
    defer variables.free_vars(allocator, &global_vars);

    const package_base = global_vars.get("pkgbase") orelse names.items[0];
    try writer.print("pkgbase = {s}\n", .{package_base});
    for (global_single_fields) |name|
        if (global_vars.get(name)) |value| try writeAttribute(writer, name, value);

    const global_architectures = try fields.resolve_array_field(
        global_parser,
        content,
        &global_vars,
        "arch",
    );
    defer variables.freeStringSlice(allocator, global_architectures);

    for (global_array_fields) |name| {
        if (std.mem.eql(u8, name, "arch")) {
            try writeAttributes(writer, name, global_architectures);
            continue;
        }
        try writeGlobalArray(global_parser, writer, content, &global_vars, name);
    }
    try writeArchitectureArrays(
        global_parser,
        writer,
        content,
        &global_vars,
        global_architectures,
        false,
    );

    for (names.items) |package_name| {
        try writer.print("\npkgname = {s}\n", .{package_name});
        const package_parser = parserFor(allocator, io, package_name, options);
        var package_vars = try variables.build_var_hashmap(package_parser, content);
        defer variables.free_vars(allocator, &package_vars);
        const body = try function_body.selected_package_body_with_vars(
            package_parser,
            content,
            &package_vars,
        );

        for (package_single_fields) |name| {
            if (!hasScalarAssignment(body, name)) continue;
            if (std.mem.eql(u8, name, "install") or std.mem.eql(u8, name, "changelog")) {
                const assignment = try fields.resolve_file_assignment(
                    package_parser,
                    content,
                    &package_vars,
                    name,
                );
                if (assignment) |resolved_assignment| {
                    defer allocator.free(resolved_assignment.value);
                    const value = try fields.resolve_file_string(
                        package_parser,
                        resolved_assignment,
                        &package_vars,
                    );
                    defer allocator.free(value);
                    try writeAttribute(writer, name, value);
                }
                continue;
            }
            const value = try fields.resolve_package_string_field(
                package_parser,
                content,
                &package_vars,
                name,
            );
            defer if (value) |owned| allocator.free(owned);
            if (value) |resolved| try writeAttribute(writer, name, resolved);
        }

        var package_architectures: ?[][]const u8 = null;
        defer if (package_architectures) |values| variables.freeStringSlice(allocator, values);
        for (package_array_fields) |name| {
            if (!hasArrayAssignment(body, name)) continue;
            const values = try fields.resolve_package_array_field(
                package_parser,
                content,
                &package_vars,
                name,
            );
            if (std.mem.eql(u8, name, "arch")) {
                package_architectures = values;
                try writeAttributes(writer, name, values);
            } else {
                defer variables.freeStringSlice(allocator, values);
                try writeAttributes(writer, name, values);
            }
        }
        const effective_architectures = package_architectures orelse global_architectures;
        try writeArchitectureArrays(
            package_parser,
            writer,
            content,
            &package_vars,
            effective_architectures,
            true,
        );
    }
}

fn parserFor(
    allocator: std.mem.Allocator,
    io: std.Io,
    selected_package_name: ?[]const u8,
    options: GenerateOptions,
) PkgbuildParser {
    return .{
        .allocator = allocator,
        .io = io,
        .selected_package_name = selected_package_name,
        .package_carch = options.package_carch,
        .dynamic_overrides = options.dynamic_overrides,
        .dynamic_unsets = options.dynamic_unsets,
        .dynamic_array_overrides = options.dynamic_array_overrides,
        .dynamic_array_unsets = options.dynamic_array_unsets,
    };
}

fn writeGlobalArray(
    parser: PkgbuildParser,
    writer: *std.Io.Writer,
    content: []const u8,
    vars: *std.StringHashMap([]const u8),
    name: []const u8,
) !void {
    const values = try fields.resolve_array_field(parser, content, vars, name);
    defer variables.freeStringSlice(parser.allocator, values);
    try writeAttributes(writer, name, values);
}

fn writeArchitectureArrays(
    parser: PkgbuildParser,
    writer: *std.Io.Writer,
    content: []const u8,
    vars: *std.StringHashMap([]const u8),
    architectures: []const []const u8,
    package_scoped: bool,
) !void {
    for (architectures) |architecture| {
        if (std.mem.eql(u8, architecture, "any")) continue;
        for (architecture_array_fields) |base_name| {
            const name = try std.fmt.allocPrint(parser.allocator, "{s}_{s}", .{ base_name, architecture });
            defer parser.allocator.free(name);
            if (package_scoped and !hasArrayAssignment(
                try function_body.selected_package_body_with_vars(parser, content, vars),
                name,
            )) continue;
            const values = if (package_scoped)
                try fields.resolve_package_array_field(parser, content, vars, name)
            else
                try fields.resolve_array_field(parser, content, vars, name);
            defer variables.freeStringSlice(parser.allocator, values);
            try writeAttributes(writer, name, values);
        }
    }
}

fn hasScalarAssignment(body: ?[]const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, body orelse return false, '\n');
    while (lines.next()) |line|
        if (variables.parse_variable(line, name) catch null != null) return true;
    return false;
}

fn hasArrayAssignment(body: ?[]const u8, name: []const u8) bool {
    return arrays.find_next_scoped_array_start(body orelse return false, name, 0) != null;
}

fn writeAttributes(writer: *std.Io.Writer, name: []const u8, values: []const []const u8) !void {
    for (values) |value| try writeAttribute(writer, name, value);
}

fn writeAttribute(writer: *std.Io.Writer, name: []const u8, raw_value: []const u8) !void {
    const value = std.mem.trim(u8, raw_value, " \t\r\n\x0b\x0c");
    if (value.len == 0) return;
    try writer.print("\t{s} = ", .{name});
    var whitespace = false;
    for (value) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            whitespace = true;
            continue;
        }
        if (whitespace) try writer.writeByte(' ');
        whitespace = false;
        try writer.writeByte(byte);
    }
    try writer.writeByte('\n');
}

pub const Info = struct {
    package_base: ?[]u8 = null,
    package_names: [][]u8,

    pub fn deinit(self: *Info, allocator: std.mem.Allocator) void {
        if (self.package_base) |package_base| allocator.free(package_base);
        for (self.package_names) |name| allocator.free(name);
        allocator.free(self.package_names);
        self.* = undefined;
    }

    pub fn contains(self: *const Info, package_name: []const u8) bool {
        if (self.package_base) |package_base|
            if (std.mem.eql(u8, package_base, package_name)) return true;
        for (self.package_names) |name|
            if (std.mem.eql(u8, name, package_name)) return true;
        return false;
    }
};

/// Dependency fields selected from evaluated SRCINFO. This is deliberately
/// separate from the statically parsed PKGBUILD so dependency planning does
/// not mutate the content and review state later used by the builder.
pub const DependencyMetadata = struct {
    depends: [][]const u8,
    make_depends: [][]const u8,
    check_depends: [][]const u8,
    opt_depends: [][]const u8,
    parsed_depends: []pkgbuild_parser.parsed_dep,
    parsed_make_depends: []pkgbuild_parser.parsed_dep,
    parsed_check_depends: []pkgbuild_parser.parsed_dep,

    pub fn deinit(self: *DependencyMetadata, allocator: std.mem.Allocator) void {
        freeValues(allocator, self.depends);
        freeValues(allocator, self.make_depends);
        freeValues(allocator, self.check_depends);
        freeValues(allocator, self.opt_depends);
        freeParsedDependencies(allocator, self.parsed_depends);
        freeParsedDependencies(allocator, self.parsed_make_depends);
        freeParsedDependencies(allocator, self.parsed_check_depends);
        self.* = undefined;
    }
};

const DependencyField = enum { runtime, build, check, optional };

/// Parses the effective global and selected-package dependency declarations
/// for the active architecture from makepkg-compatible SRCINFO output.
pub fn parseDependencyMetadata(
    allocator: std.mem.Allocator,
    io: std.Io,
    content: []const u8,
    selected_package_names: []const []const u8,
    carch: []const u8,
) !DependencyMetadata {
    var runtime: std.ArrayList([]const u8) = .empty;
    errdefer freeValueList(allocator, &runtime);
    var build: std.ArrayList([]const u8) = .empty;
    errdefer freeValueList(allocator, &build);
    var check: std.ArrayList([]const u8) = .empty;
    errdefer freeValueList(allocator, &check);
    var optional: std.ArrayList([]const u8) = .empty;
    errdefer freeValueList(allocator, &optional);

    var in_package_scope = false;
    var selected_scope = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equal], " \t");
        const value = std.mem.trim(u8, line[equal + 1 ..], " \t");
        if (std.mem.eql(u8, key, "pkgname")) {
            in_package_scope = true;
            selected_scope = containsString(selected_package_names, value);
            continue;
        }
        if (value.len == 0 or (in_package_scope and !selected_scope)) continue;
        switch (dependencyField(key, carch) orelse continue) {
            .runtime => try appendOwnedValue(allocator, &runtime, value),
            .build => try appendOwnedValue(allocator, &build, value),
            .check => try appendOwnedValue(allocator, &check, value),
            .optional => try appendOwnedValue(allocator, &optional, value),
        }
    }

    const runtime_values = try runtime.toOwnedSlice(allocator);
    errdefer freeValues(allocator, runtime_values);
    const build_values = try build.toOwnedSlice(allocator);
    errdefer freeValues(allocator, build_values);
    const check_values = try check.toOwnedSlice(allocator);
    errdefer freeValues(allocator, check_values);
    const optional_values = try optional.toOwnedSlice(allocator);
    errdefer freeValues(allocator, optional_values);

    const parser = PkgbuildParser{ .allocator = allocator, .io = io };
    const parsed_runtime = try dependencies.parse_dependencies(parser, runtime_values);
    errdefer freeParsedDependencies(allocator, parsed_runtime);
    const parsed_build = try dependencies.parse_dependencies(parser, build_values);
    errdefer freeParsedDependencies(allocator, parsed_build);
    const parsed_check = try dependencies.parse_dependencies(parser, check_values);
    errdefer freeParsedDependencies(allocator, parsed_check);
    return .{
        .depends = runtime_values,
        .make_depends = build_values,
        .check_depends = check_values,
        .opt_depends = optional_values,
        .parsed_depends = parsed_runtime,
        .parsed_make_depends = parsed_build,
        .parsed_check_depends = parsed_check,
    };
}

fn dependencyField(
    key: []const u8,
    carch: []const u8,
) ?DependencyField {
    inline for (.{
        .{ "depends", DependencyField.runtime },
        .{ "makedepends", DependencyField.build },
        .{ "checkdepends", DependencyField.check },
        .{ "optdepends", DependencyField.optional },
    }) |entry| {
        if (std.mem.eql(u8, key, entry[0])) return entry[1];
        if (key.len == entry[0].len + carch.len + 1 and
            std.mem.startsWith(u8, key, entry[0]) and
            key[entry[0].len] == '_' and
            std.mem.eql(u8, key[entry[0].len + 1 ..], carch)) return entry[1];
    }
    return null;
}

fn appendOwnedValue(
    allocator: std.mem.Allocator,
    values: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    const owned = try allocator.dupe(u8, value);
    values.append(allocator, owned) catch |err| {
        allocator.free(owned);
        return err;
    };
}

fn containsString(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn freeValueList(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8)) void {
    for (values.items) |value| allocator.free(value);
    values.deinit(allocator);
}

fn freeValues(allocator: std.mem.Allocator, values: [][]const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn freeParsedDependencies(
    allocator: std.mem.Allocator,
    parsed: []pkgbuild_parser.parsed_dep,
) void {
    for (parsed) |dependency| dependency.deinit(allocator);
    allocator.free(parsed);
}

pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Info {
    var package_base: ?[]u8 = null;
    errdefer if (package_base) |value| allocator.free(value);
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equal], " \t");
        const value = std.mem.trim(u8, line[equal + 1 ..], " \t");
        if (value.len == 0) continue;

        if (std.mem.eql(u8, key, "pkgbase")) {
            if (package_base) |old| allocator.free(old);
            package_base = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "pkgname")) {
            var duplicate = false;
            for (names.items) |name| {
                if (std.mem.eql(u8, name, value)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) try names.append(allocator, try allocator.dupe(u8, value));
        }
    }

    return .{
        .package_base = package_base,
        .package_names = try names.toOwnedSlice(allocator),
    };
}

pub fn parseFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Info {
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(content);
    return parse(allocator, content);
}

test ".SRCINFO parser resolves split package members" {
    var info = try parse(std.testing.allocator,
        \\# generated by makepkg
        \\pkgbase = demo-suite
        \\pkgname = demo-cli
        \\pkgname = demo-ui
        \\pkgname = demo-ui
    );
    defer info.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("demo-suite", info.package_base.?);
    try std.testing.expect(info.contains("demo-ui"));
    try std.testing.expect(info.contains("demo-suite"));
    try std.testing.expect(!info.contains("missing"));
    try std.testing.expectEqual(@as(usize, 2), info.package_names.len);
}

test ".SRCINFO dependency parser merges global selected and architecture scopes" {
    const allocator = std.testing.allocator;
    var metadata = try parseDependencyMetadata(allocator, std.testing.io,
        \\pkgbase = demo-suite
        \\    depends = global-runtime
        \\    makedepends = cmake
        \\    makedepends_x86_64 = architecture-tool
        \\    makedepends_aarch64 = wrong-architecture
        \\pkgname = demo-cli
        \\    depends = cli-runtime>=2
        \\    optdepends = cli-docs: documentation
        \\pkgname = demo-ui
        \\    depends = ui-runtime
    , &.{"demo-cli"}, "x86_64");
    defer metadata.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), metadata.depends.len);
    try std.testing.expectEqualStrings("global-runtime", metadata.depends[0]);
    try std.testing.expectEqualStrings("cli-runtime", metadata.parsed_depends[1].name);
    try std.testing.expectEqualStrings(">=", metadata.parsed_depends[1].operator);
    try std.testing.expectEqual(@as(usize, 2), metadata.make_depends.len);
    try std.testing.expectEqualStrings("architecture-tool", metadata.make_depends[1]);
    try std.testing.expectEqual(@as(usize, 1), metadata.opt_depends.len);
    try std.testing.expectEqualStrings("cli-docs: documentation", metadata.opt_depends[0]);
}

test ".SRCINFO writer preserves global package and architecture scopes" {
    const content =
        \\pkgbase=demo-suite
        \\pkgname=(demo demo-docs)
        \\pkgver=1.2.3
        \\pkgrel=2
        \\epoch=1
        \\url=https://example.invalid/demo
        \\arch=(x86_64 aarch64)
        \\license=(MIT)
        \\makedepends=(zig)
        \\source=(demo.tar.zst)
        \\source_x86_64=(demo-x86.patch)
        \\sha256sums=(SKIP)
        \\sha256sums_x86_64=(SKIP)
        \\package_demo() {
        \\  pkgdesc="  Main   package  "
        \\  depends=(glibc)
        \\}
        \\package_demo-docs() {
        \\  pkgdesc='Documentation package'
        \\  arch=(any)
        \\  depends=(demo=1.2.3-2)
        \\}
    ;
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writePkgbuild(
        std.testing.allocator,
        std.testing.io,
        &output.writer,
        content,
        .{},
    );
    try std.testing.expectEqualStrings(
        "pkgbase = demo-suite\n" ++
            "\tpkgver = 1.2.3\n" ++
            "\tpkgrel = 2\n" ++
            "\tepoch = 1\n" ++
            "\turl = https://example.invalid/demo\n" ++
            "\tarch = x86_64\n" ++
            "\tarch = aarch64\n" ++
            "\tlicense = MIT\n" ++
            "\tmakedepends = zig\n" ++
            "\tsource = demo.tar.zst\n" ++
            "\tsha256sums = SKIP\n" ++
            "\tsource_x86_64 = demo-x86.patch\n" ++
            "\tsha256sums_x86_64 = SKIP\n" ++
            "\n" ++
            "pkgname = demo\n" ++
            "\tpkgdesc = Main package\n" ++
            "\tdepends = glibc\n" ++
            "\n" ++
            "pkgname = demo-docs\n" ++
            "\tpkgdesc = Documentation package\n" ++
            "\tarch = any\n" ++
            "\tdepends = demo=1.2.3-2\n",
        output.writer.buffered(),
    );
}
