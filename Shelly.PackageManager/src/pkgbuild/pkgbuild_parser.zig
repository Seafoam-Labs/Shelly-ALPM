const std = @import("std");
const file_inspector = @import("../local/file_inspector.zig");
const listDictionary = @import("../shared/list_dictionary.zig").ListDictionary;

pub const pkgbuild_info = struct {
    pkg_name: ?[]const u8 = null,
    pkg_version: ?[]const u8 = null,
    pkg_rel: ?[]const u8 = null,
    epoch: ?[]const u8 = null,
    pkg_desc: ?[]const u8 = null,
    url: ?[]const u8 = null,
    license: ?[][]const u8 = null,
    arch: ?[][]const u8 = null,
    depends: ?[][]const u8 = null,
    make_depends: ?[][]const u8 = null,
    opt_depends: ?[][]const u8 = null,
    provides: ?[][]const u8 = null,
    conflicts: ?[][]const u8 = null,
    replaces: ?[][]const u8 = null,
    source: ?[][]const u8 = null,
    sha_256_sums: ?[][]const u8 = null,
    sha_512_sums: ?[][]const u8 = null,
    md_5_sums: ?[][]const u8 = null,
    variables: std.StringHashMap([]const u8),
    install_file: ?[]const u8 = null,
    post_install: ?[]const u8 = null,
    local_source_files: ?[][]const u8 = null,
    local_source_contents: std.StringHashMap([]const u8),
    parsed_depends: ?[]parsed_dep = null,
    parsed_make_depends: ?[]parsed_dep = null,
    parsed_check_depends: ?[]parsed_dep = null,
    check_depends: ?[][]const u8 = null,

    pub fn deinit(self: *pkgbuild_info, allocator: std.mem.Allocator) void {
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
        if (self.source) |a| {
            for (a) |item| allocator.free(item);
            allocator.free(a);
        }
        if (self.sha_256_sums) |a| {
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
        if (self.post_install) |v| allocator.free(v);

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
    }

    pub fn get_full_version(self: pkgbuild_info, allocator: std.mem.Allocator) ![]const u8 {
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

    pub fn deinit(self: kvp, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const PkgbuildParser = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    selected_package_name: ?[]const u8 = null,

    const InstallAssignment = struct {
        value: []u8,
        package_scoped: bool,
    };

    pub fn parser(self: PkgbuildParser, path: []const u8) !pkgbuild_info {
        const content = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited);
        defer self.allocator.free(content);

        const base_dir = std.fs.path.dirname(path);
        return self.parser_content(content, base_dir);
    }

    pub fn parser_content(self: PkgbuildParser, content: []const u8, base_dir: ?[]const u8) !pkgbuild_info {
        var vars = try self.build_var_hashmap(content);
        errdefer {
            var iterator = vars.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            vars.deinit();
        }

        const install_assignment = try self.resolve_install_assignment(content, &vars);
        defer if (install_assignment) |assignment| self.allocator.free(assignment.value);
        const install_file = if (install_assignment) |assignment|
            try self.resolve_install_string(assignment, &vars)
        else
            null;

        const source = try self.resolve_array_field(content, &vars, "source");
        const local_source_files = try self.extract_local_source_files(source);
        const local_source_contents = try self.resolve_local_source_contents(local_source_files, base_dir);

        const post_install = (try self.resolve_post_install(install_file, base_dir)) orelse
            if (try extract_function_body(content, "post_install")) |body|
                try self.allocator.dupe(u8, body)
            else
                null;

        const depends = try self.resolve_package_depends(content, &vars);
        const make_depends = try self.resolve_array_field(content, &vars, "makedepends");
        const check_depends = try self.resolve_array_field(content, &vars, "checkdepends");

        return pkgbuild_info{
            .variables = vars,
            .pkg_name = try resolve_or_parse(self, content, "pkgname", &vars),
            .pkg_version = try resolve_or_parse(self, content, "pkgver", &vars),
            .pkg_rel = try resolve_or_parse(self, content, "pkgrel", &vars),
            .epoch = try resolve_or_parse(self, content, "epoch", &vars),
            .pkg_desc = try resolve_or_parse(self, content, "pkgdesc", &vars),
            .url = try resolve_or_parse(self, content, "url", &vars),
            .license = try self.parse_array(content, "license"),
            .arch = try self.parse_array(content, "arch"),
            .depends = depends,
            .make_depends = make_depends,
            .check_depends = check_depends,
            .opt_depends = try self.resolve_array_field(content, &vars, "optdepends"),
            .provides = try self.resolve_array_field(content, &vars, "provides"),
            .conflicts = try self.parse_array(content, "conflicts"),
            .replaces = try self.parse_array(content, "replaces"),
            .source = source,
            .sha_256_sums = try self.parse_array(content, "sha256sums"),
            .sha_512_sums = try self.parse_array(content, "sha512sums"),
            .md_5_sums = try self.parse_array(content, "md5sums"),
            .install_file = install_file,
            .post_install = post_install,
            .local_source_files = local_source_files,
            .local_source_contents = local_source_contents,
            .parsed_depends = try self.parse_dependencies(depends),
            .parsed_make_depends = try self.parse_dependencies(make_depends),
            .parsed_check_depends = try self.parse_dependencies(check_depends),
        };
    }

    fn selected_package_body(self: PkgbuildParser, content: []const u8) !?[]const u8 {
        const package_name = self.selected_package_name orelse return null;
        const function_name = try std.fmt.allocPrint(
            self.allocator,
            "package_{s}",
            .{package_name},
        );
        defer self.allocator.free(function_name);

        return (try extract_function_body(content, function_name)) orelse
            try extract_function_body(content, "package");
    }

    fn resolve_install_assignment(
        self: PkgbuildParser,
        content: []const u8,
        vars: *const std.StringHashMap([]const u8),
    ) !?InstallAssignment {
        var assignment: ?InstallAssignment = if (vars.get("install")) |value|
            .{
                .value = try self.allocator.dupe(u8, value),
                .package_scoped = false,
            }
        else
            null;
        errdefer if (assignment) |current| self.allocator.free(current.value);

        if (try self.selected_package_body(content)) |body| {
            if (try parse_variable(body, "install")) |value| {
                const owned_value = try self.allocator.dupe(u8, value);
                if (assignment) |current| self.allocator.free(current.value);
                assignment = .{
                    .value = owned_value,
                    .package_scoped = true,
                };
            }
        }

        return assignment;
    }

    fn resolve_install_string(
        self: PkgbuildParser,
        assignment: InstallAssignment,
        vars: *std.StringHashMap([]const u8),
    ) ![]const u8 {
        const resolved = if (assignment.package_scoped) blk: {
            const package_name = self.selected_package_name orelse
                return error.MissingSelectedPackageName;
            var scoped_vars = std.StringHashMap([]const u8).init(self.allocator);
            defer scoped_vars.deinit();

            var iterator = vars.iterator();
            while (iterator.next()) |entry|
                try scoped_vars.put(entry.key_ptr.*, entry.value_ptr.*);
            try scoped_vars.put("pkgname", package_name);

            break :blk try self.resolve_string(assignment.value, &scoped_vars);
        } else try self.resolve_string(assignment.value, vars);
        errdefer self.allocator.free(resolved);

        if (std.mem.indexOfScalar(u8, resolved, '$') != null)
            return error.UnresolvedPkgbuildVariable;
        return resolved;
    }

    fn resolve_array_field(self: PkgbuildParser, content: []const u8, vars: *std.StringHashMap([]const u8), var_name: []const u8) ![][]const u8 {
        const raw = try self.parse_array(content, var_name);
        defer {
            for (raw) |it| self.allocator.free(it);
            self.allocator.free(raw);
        }
        return self.resolve_variable_references(content, vars, raw);
    }

    fn resolve_package_depends(self: PkgbuildParser, content: []const u8, vars: *std.StringHashMap([]const u8)) ![][]const u8 {
        const global = try self.resolve_array_field(content, vars, "depends");
        errdefer {
            for (global) |item| self.allocator.free(item);
            self.allocator.free(global);
        }

        const package_body = try self.selected_package_body(content) orelse return global;
        const raw_scoped = try self.parse_array(package_body, "depends");
        defer {
            for (raw_scoped) |item| self.allocator.free(item);
            self.allocator.free(raw_scoped);
        }
        if (raw_scoped.len == 0) return global;

        const scoped = try self.resolve_variable_references(content, vars, raw_scoped);
        errdefer {
            for (scoped) |item| self.allocator.free(item);
            self.allocator.free(scoped);
        }

        const combined = try self.allocator.alloc([]const u8, global.len + scoped.len);
        @memcpy(combined[0..global.len], global);
        @memcpy(combined[global.len..], scoped);
        self.allocator.free(global);
        self.allocator.free(scoped);
        return combined;
    }

    fn tokenize(self: PkgbuildParser, expr: []const u8) ![][]const u8 {
        var tokens: std.ArrayList([]const u8) = .empty;
        errdefer tokens.deinit(self.allocator);

        var i: usize = 0;
        while (i < expr.len) {
            if (std.ascii.isWhitespace(expr[i])) {
                i += 1;
                continue;
            }
            if (std.ascii.isDigit(expr[i])) {
                const start = i;
                while (i < expr.len and std.ascii.isDigit(expr[i])) i += 1;
                try tokens.append(self.allocator, expr[start..i]);
            } else if (std.mem.indexOfScalar(u8, "+-*/%()", expr[i]) != null) {
                try tokens.append(self.allocator, expr[i .. i + 1]);
                i += 1;
            } else {
                i += 1;
            }
        }
        return tokens.toOwnedSlice(self.allocator);
    }

    //replaces var resolved = Regex.Replace(expr, @"\$\{?(\w+)\}?", match =>
    fn substitute_variables(self: PkgbuildParser, expr: []const u8, vars: *const std.StringHashMap([]const u8)) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var i: usize = 0;
        while (i < expr.len) {
            if (expr[i] == '$') {
                var j = i + 1;
                const braced = j < expr.len and expr[j] == '{';
                if (braced) j += 1;
                const name_start = j;

                while (j < expr.len and (std.ascii.isAlphanumeric(expr[j]) or expr[j] == '_')) {
                    j += 1;
                }

                if (j > name_start) {
                    const name_end = j;
                    var match_end = name_end;
                    if (braced and match_end < expr.len and expr[match_end] == '}') {
                        match_end += 1;
                    }

                    const name = expr[name_start..name_end];
                    var substituted = false;

                    if (vars.get(name)) |val| {
                        if (std.fmt.parseInt(i64, val, 10)) |_| {
                            try out.appendSlice(self.allocator, val);
                            substituted = true;
                        } else |_| {}
                    }

                    if (!substituted) {
                        try out.appendSlice(self.allocator, expr[i..match_end]);
                    }

                    i = match_end;
                    continue;
                }
            }

            if (std.ascii.isAlphabetic(expr[i]) or expr[i] == '_') {
                const name_start = i;
                var j = i + 1;
                while (j < expr.len and (std.ascii.isAlphanumeric(expr[j]) or expr[j] == '_')) : (j += 1) {}
                const name = expr[name_start..j];

                var substituted = false;
                if (vars.get(name)) |val| {
                    if (std.fmt.parseInt(i64, val, 10)) |_| {
                        try out.appendSlice(self.allocator, val);
                        substituted = true;
                    } else |_| {}
                }
                if (!substituted) {
                    try out.appendSlice(self.allocator, name);
                }
                i = j;
                continue;
            }

            try out.append(self.allocator, expr[i]);
            i += 1;
        }

        return out.toOwnedSlice(self.allocator);
    }

    fn evaluate_arithmetic(self: PkgbuildParser, expr: []const u8, vars: *const std.StringHashMap([]const u8)) ![]u8 {
        const resolved = try substitute_variables(self, expr, vars);
        defer self.allocator.free(resolved);

        const value = compute: {
            const tokens = tokenize(self, resolved) catch break :compute null;
            defer self.allocator.free(tokens);
            var pos: usize = 0;
            break :compute eval_expression(tokens, 0, &pos) catch null;
        };

        if (value) |v| { //unwrap
            return std.fmt.allocPrint(self.allocator, "{d}", .{v});
        }

        std.debug.print("[Shelly] Warning: Cannot evaluate arithmetic: $(({s}))\n", .{expr});
        return self.allocator.dupe(u8, "0");
    }

    fn extract_local_source_files(self: PkgbuildParser, source: [][]const u8) ![][]const u8 {
        var files: std.ArrayList([]const u8) = .empty;
        errdefer files.deinit(self.allocator);

        for (source) |line| {
            const entry = split_source_entry(line);
            if (try is_remote_source(entry.location)) continue;

            const name = if (entry.file_name.len == 0) entry.location else entry.file_name;
            if (name.len == 0) continue;

            var already_have = false;
            for (files.items) |existing| {
                if (std.mem.eql(u8, existing, name)) {
                    already_have = true;
                    break;
                }
            }
            if (!already_have) {
                try files.append(self.allocator, try self.allocator.dupe(u8, name));
            }
        }

        return files.toOwnedSlice(self.allocator);
    }

    fn resolve_string(self: PkgbuildParser, input: []const u8, vars: *std.StringHashMap([]const u8)) ![]const u8 {
        const step1 = try self.replace_arithmetic(input, vars);
        defer self.allocator.free(step1);

        const step2 = try self.replace_command(step1);
        defer self.allocator.free(step2);

        const step3 = try self.replace_trim_expansion(step2, vars);
        defer self.allocator.free(step3);

        const step4 = try self.replace_replacement_expansion(step3, vars);
        defer self.allocator.free(step4);

        const step5 = try self.replace_substring_expansion(step4, vars);
        defer self.allocator.free(step5);

        return self.replace_plain_var(step5, vars);
    }

    fn replace_replacement_expansion(self: PkgbuildParser, input: []const u8, vars: *const std.StringHashMap([]const u8)) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(self.allocator);

        var pos: usize = 0;
        while (pos < input.len) {
            const open = std.mem.indexOfPos(u8, input, pos, "${") orelse {
                try result.appendSlice(self.allocator, input[pos..]);
                break;
            };
            try result.appendSlice(self.allocator, input[pos..open]);

            var cursor = open + 2;
            const start = cursor;
            cursor = scan_word_chars(input, cursor);
            const var_name = input[start..cursor];

            if (var_name.len == 0 or cursor >= input.len or input[cursor] != '/') {
                try result.append(self.allocator, input[open]);
                pos = open + 1;
                continue;
            }
            cursor += 1;

            var mode: []const u8 = "";
            if (cursor < input.len and (input[cursor] == '/' or input[cursor] == '#' or input[cursor] == '%')) {
                mode = input[cursor .. cursor + 1];
                cursor += 1;
            }

            const pattern_start = cursor;
            while (cursor < input.len and input[cursor] != '/' and input[cursor] != '}') : (cursor += 1) {}
            const find_glob = input[pattern_start..cursor];

            var repl: []const u8 = "";
            if (cursor < input.len and input[cursor] == '/') {
                cursor += 1;
                const repl_start = cursor;
                while (cursor < input.len and input[cursor] != '}') : (cursor += 1) {}
                repl = input[repl_start..cursor];
            }

            if (cursor >= input.len) {
                try result.append(self.allocator, '$');
                pos = input.len;
                continue;
            }
            if (input[cursor] != '}') {
                try result.append(self.allocator, input[open]);
                pos = open + 1;
                continue;
            }
            const match_end = cursor + 1;

            if (vars.get(var_name)) |val| {
                const applied = try apply_replacement(self, val, mode, find_glob, repl);
                defer self.allocator.free(applied);
                try result.appendSlice(self.allocator, applied);
            } else {
                try result.appendSlice(self.allocator, input[open..match_end]);
            }
            pos = match_end;
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn replace_substring_expansion(self: PkgbuildParser, input: []const u8, vars: *const std.StringHashMap([]const u8)) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(self.allocator);
        var pos: usize = 0;
        while (pos < input.len) {
            const open = std.mem.indexOfPos(u8, input, pos, "${") orelse {
                try result.appendSlice(self.allocator, input[pos..]);
                break;
            };
            try result.appendSlice(self.allocator, input[pos..open]);
            var cursor = open + 2;
            const name_start = cursor;
            cursor = scan_word_chars(input, cursor);
            const var_name = input[name_start..cursor];
            if (var_name.len == 0 or cursor >= input.len or input[cursor] != ':') {
                try result.append(self.allocator, input[open]);
                pos = open + 1;
                continue;
            }
            cursor += 1;
            var offset: i32 = undefined;
            var matched_offset = false;
            {
                const ws_end = scan_whitespace(input, cursor);
                const digit_end = scan_digits(input, ws_end);
                if (digit_end > ws_end) {
                    offset = std.fmt.parseInt(i32, input[ws_end..digit_end], 10) catch {
                        try result.append(self.allocator, input[open]);
                        pos = open + 1;
                        continue;
                    };
                    cursor = digit_end;
                    matched_offset = true;
                }
            }
            if (!matched_offset) {
                const ws_start = cursor;
                const ws_end = scan_whitespace(input, ws_start);
                if (ws_end > ws_start and ws_end < input.len and input[ws_end] == '-') {
                    const digit_end = scan_digits(input, ws_end + 1);
                    if (digit_end > ws_end + 1) {
                        offset = std.fmt.parseInt(i32, input[ws_end..digit_end], 10) catch {
                            try result.append(self.allocator, input[open]);
                            pos = open + 1;
                            continue;
                        };
                        cursor = digit_end;
                        matched_offset = true;
                    }
                }
            }
            if (!matched_offset) {
                try result.append(self.allocator, input[open]);
                pos = open + 1;
                continue;
            }
            var length: ?i32 = null;
            if (cursor < input.len and input[cursor] == ':') {
                const c2 = scan_whitespace(input, cursor + 1);
                const neg = c2 < input.len and input[c2] == '-';
                const digit_start = if (neg) c2 + 1 else c2;
                const digit_end = scan_digits(input, digit_start);
                if (digit_end > digit_start) {
                    length = std.fmt.parseInt(i32, input[c2..digit_end], 10) catch {
                        try result.append(self.allocator, input[open]);
                        pos = open + 1;
                        continue;
                    };
                    cursor = digit_end;
                }
            }
            if (cursor >= input.len) {
                try result.append(self.allocator, '$');
                pos = input.len;
                continue;
            }
            if (input[cursor] != '}') {
                try result.append(self.allocator, input[open]);
                pos = open + 1;
                continue;
            }
            const match_end = cursor + 1;
            if (vars.get(var_name)) |val| {
                const applied = try apply_substring(val, offset, length);
                try result.appendSlice(self.allocator, applied);
            } else {
                try result.appendSlice(self.allocator, input[open..match_end]);
            }
            pos = match_end;
        }
        return result.toOwnedSlice(self.allocator);
    }

    fn scan_whitespace(input: []const u8, start: usize) usize {
        var pos = start;
        while (pos < input.len and std.ascii.isWhitespace(input[pos])) : (pos += 1) {}
        return pos;
    }

    fn scan_digits(input: []const u8, start: usize) usize {
        var pos = start;
        while (pos < input.len and std.ascii.isDigit(input[pos])) : (pos += 1) {}
        return pos;
    }

    fn replace_command(self: PkgbuildParser, input: []const u8) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(self.allocator);

        var pos: usize = 0;
        while (pos < input.len) {
            const open = std.mem.indexOfPos(u8, input, pos, "$(") orelse {
                try result.appendSlice(self.allocator, input[pos..]);
                break;
            };
            try result.appendSlice(self.allocator, input[pos..open]);

            const start = open + 2;
            const close = std.mem.indexOfPos(u8, input, start, ")") orelse {
                try result.appendSlice(self.allocator, input[open..]);
                pos = input.len;
                break;
            };

            if (close == start) {
                try result.appendSlice(self.allocator, input[open .. close + 1]);
                pos = close + 1;
                continue;
            }

            const whole_match = input[open .. close + 1];
            std.debug.print("[Shelly] Warning: Cannot evaluate command substitution: {s}\n", .{whole_match});
            pos = close + 1;
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn replace_arithmetic(self: PkgbuildParser, input: []const u8, vars: *std.StringHashMap([]const u8)) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;

        defer result.deinit(self.allocator);

        var pos: usize = 0;
        while (pos < input.len) {
            const open = std.mem.indexOfPos(u8, input, pos, "$((") orelse {
                try result.appendSlice(self.allocator, input[pos..]);
                break;
            };
            try result.appendSlice(self.allocator, input[pos..open]);

            const start = open + 3;
            const close = std.mem.indexOfScalarPos(u8, input, start, ')') orelse {
                try result.appendSlice(self.allocator, input[open..]);
                pos = input.len;
                break;
            };

            if (close == start or close + 1 >= input.len or input[close + 1] != ')') {
                try result.appendSlice(self.allocator, input[open .. close + 1]);
                pos = open + 1;
                continue;
            }

            const expr = input[start..close];
            const evaluated = try evaluate_arithmetic(self, expr, vars);
            defer self.allocator.free(evaluated);
            try result.appendSlice(self.allocator, evaluated);
            pos = close + 2;
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn replace_trim_expansion(self: PkgbuildParser, input: []const u8, vars: *std.StringHashMap([]const u8)) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(self.allocator);

        var pos: usize = 0;
        while (pos < input.len) {
            const open = std.mem.indexOfPos(u8, input, pos, "${") orelse {
                try result.appendSlice(self.allocator, input[pos..]);
                break;
            };
            try result.appendSlice(self.allocator, input[pos..open]);
            var cursor = open + 2;
            const start = cursor;
            cursor = c: {
                var c_pos = start;
                while (c_pos < input.len and is_word(input[c_pos])) : (c_pos += 1) {}
                break :c c_pos;
            };
            const var_name = input[start..cursor];
            const operation: []const u8 = op: {
                if (cursor + 1 < input.len and input[cursor] == '#' and input[cursor + 1] == '#') {
                    cursor += 2;
                    break :op "##";
                } else if (cursor < input.len and input[cursor] == '#') {
                    cursor += 1;
                    break :op "#";
                } else if (cursor + 1 < input.len and input[cursor] == '%' and input[cursor + 1] == '%') {
                    cursor += 2;
                    break :op "%%";
                } else if (cursor < input.len and input[cursor] == '%') {
                    cursor += 1;
                    break :op "%";
                } else {
                    break :op "";
                }
            };

            if (operation.len == 0) {
                try result.append(self.allocator, input[open]);
                pos = open + 1;
                continue;
            }

            const arg_start = cursor;
            while (cursor < input.len and input[cursor] != '}') : (cursor += 1) {}
            if (cursor >= input.len) {
                try result.append(self.allocator, '$');
                pos = input.len;
                continue;
            }
            const arg = input[arg_start..cursor];
            const match_end = cursor + 1;

            if (vars.get(var_name)) |val| {
                const applied = apply_parameter_expansion(val, operation, arg);
                try result.appendSlice(self.allocator, applied);
            } else {
                try result.appendSlice(self.allocator, input[open..match_end]);
            }

            pos = match_end;
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn find_glob_match(pattern: []const u8, value: []const u8, search_from: usize, anchor_start: bool, anchor_end: bool) ?struct { start: usize, end: usize } {
        if (anchor_start) {
            if (search_from != 0) return null;
            var end: usize = value.len;
            while (true) {
                if (glob_matches(pattern, value[0..end])) return .{ .start = 0, .end = end };
                if (end == 0) return null;
                end -= 1;
            }
        }
        if (anchor_end) {
            var start: usize = search_from;
            while (start <= value.len) : (start += 1) {
                if (glob_matches(pattern, value[start..])) return .{ .start = start, .end = value.len };
            }
            return null;
        }
        var start: usize = search_from;
        while (start <= value.len) : (start += 1) {
            var end: usize = value.len;
            while (true) {
                if (glob_matches(pattern, value[start..end])) return .{ .start = start, .end = end };
                if (end == start) break;
                end -= 1;
            }
        }
        return null;
    }

    fn apply_replacement(self: PkgbuildParser, value: []const u8, mode: []const u8, find_glob: []const u8, repl: []const u8) ![]const u8 {
        if (find_glob.len == 0) return self.allocator.dupe(u8, value);
        const start = std.mem.eql(u8, mode, "#");
        const end = std.mem.eql(u8, mode, "%");
        const global = std.mem.eql(u8, mode, "/");
        const max_reps: usize = if (global) std.math.maxInt(usize) else 1;
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(self.allocator);
        var cursor: usize = 0;
        var replaced: usize = 0;
        while (replaced < max_reps) {
            const m = find_glob_match(find_glob, value, cursor, start, end) orelse break;
            try result.appendSlice(self.allocator, value[cursor..m.start]);
            try result.appendSlice(self.allocator, repl);
            replaced += 1;
            if (m.end == m.start) {
                if (m.end < value.len) try result.appendSlice(self.allocator, value[m.end .. m.end + 1]);
                cursor = m.end + 1;
            } else {
                cursor = m.end;
            }
        }
        if (cursor <= value.len) try result.appendSlice(self.allocator, value[cursor..]);
        if (replaced == 0) {
            return self.allocator.dupe(u8, value);
        }
        return result.toOwnedSlice(self.allocator);
    }

    fn replace_plain_var(self: PkgbuildParser, input: []const u8, vars: *std.StringHashMap([]const u8)) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(self.allocator);
        var pos: usize = 0;
        while (pos < input.len) {
            const dollar = std.mem.indexOfScalarPos(u8, input, pos, '$') orelse {
                try result.appendSlice(self.allocator, input[pos..]);
                break;
            };
            try result.appendSlice(self.allocator, input[pos..dollar]);

            if (dollar + 1 < input.len and input[dollar + 1] == '{') {
                const name_start = dollar + 2;
                const name_end = scan_word_chars(input, name_start);
                if (name_end > name_start and name_end < input.len and input[name_end] == '}') {
                    const var_name = input[name_start..name_end];
                    const match_end = name_end + 1;
                    if (vars.get(var_name)) |val| {
                        try result.appendSlice(self.allocator, val);
                    } else {
                        try result.appendSlice(self.allocator, input[dollar..match_end]);
                    }
                    pos = match_end;
                    continue;
                }
            } else if (dollar + 1 < input.len and is_word(input[dollar + 1])) {
                const name_start = dollar + 1;
                const name_end = scan_word_chars(input, name_start);
                const var_name = input[name_start..name_end];
                if (vars.get(var_name)) |val| {
                    try result.appendSlice(self.allocator, val);
                } else {
                    try result.appendSlice(self.allocator, input[dollar..name_end]);
                }
                pos = name_end;
                continue;
            }

            try result.append(self.allocator, '$');
            pos = dollar + 1;
        }
        return result.toOwnedSlice(self.allocator);
    }

    fn scan_word_chars(input: []const u8, start: usize) usize {
        var pos = start;
        while (pos < input.len and is_word(input[pos])) : (pos += 1) {}
        return pos;
    }

    fn glob_matches(pattern: []const u8, text: []const u8) bool {
        if (pattern.len == 0) return text.len == 0;

        switch (pattern[0]) {
            '*' => {
                var i: usize = 0;
                while (i <= text.len) : (i += 1) {
                    if (glob_matches(pattern[1..], text[i..])) return true;
                }
                return false;
            },
            '?' => {
                if (text.len == 0) return false;
                return glob_matches(pattern[1..], text[1..]);
            },
            else => {
                if (text.len == 0 or text[0] != pattern[0]) return false;
                return glob_matches(pattern[1..], text[1..]);
            },
        }
    }

    fn apply_parameter_expansion(value: []const u8, op: []const u8, glob: []const u8) []const u8 {
        if (glob.len == 0) return value;

        if (std.mem.eql(u8, op, "#")) {
            var j: usize = 0;
            while (j <= value.len) : (j += 1) {
                if (glob_matches(glob, value[0..j])) return value[j..];
            }
            return value;
        } else if (std.mem.eql(u8, op, "##")) {
            var j: usize = value.len;
            while (true) {
                if (glob_matches(glob, value[0..j])) return value[j..];
                if (j == 0) break;
                j -= 1;
            }
            return value;
        } else if (std.mem.eql(u8, op, "%")) {
            var i: usize = value.len;
            while (true) {
                if (glob_matches(glob, value[i..])) return value[0..i];
                if (i == 0) break;
                i -= 1;
            }
            return value;
        } else if (std.mem.eql(u8, op, "%%")) {
            var i: usize = 0;
            while (i <= value.len) : (i += 1) {
                if (glob_matches(glob, value[i..])) return value[0..i];
            }
            return value;
        } else {
            return value;
        }
    }

    fn is_remote_source(location: []const u8) !bool {
        if (std.ascii.indexOfIgnoreCase(location, "://") != null) return true else return false;
    }

    const max_local_source_size = 32 * 1024 * 1024;

    fn resolve_local_source_contents(self: PkgbuildParser, local_source_files: [][]const u8, base_dir: ?[]const u8) !std.StringHashMap([]const u8) {
        var contents: std.StringHashMap([]const u8) = .init(self.allocator);

        for (local_source_files) |file| {
            const resolved = try resolve_local_file(self, file, base_dir);
            if (resolved) |content| {
                defer self.allocator.free(content);
                const key_owned = try self.allocator.dupe(u8, file);
                const display = try self.allocator.dupe(u8, reviewable_local_source_content(content));
                try contents.put(key_owned, display);
            }
        }
        return contents;
    }

    fn reviewable_local_source_content(content: []const u8) []const u8 {
        if (file_inspector.isElfBytes(content)) {
            return "ELF executable binary (content is not displayed). Review the file's source and checksum before proceeding.";
        }
        if (!std.unicode.utf8ValidateSlice(content)) {
            return "Binary file (content is not displayed). Review the file's source and checksum before proceeding.";
        }
        return content;
    }

    fn eval_expression(tokens: [][]const u8, pos: usize, new_pos: *usize) std.fmt.ParseIntError!i64 {
        var cur_pos: usize = undefined;
        var left = try eval_term(tokens, pos, &cur_pos);
        while (cur_pos < tokens.len and
            (std.mem.eql(u8, tokens[cur_pos], "+") or std.mem.eql(u8, tokens[cur_pos], "-")))
        {
            const op = tokens[cur_pos];
            cur_pos += 1;
            var next_pos: usize = undefined;
            const right = try eval_term(tokens, cur_pos, &next_pos);
            cur_pos = next_pos;
            left = if (std.mem.eql(u8, op, "+")) left + right else left - right;
        }
        new_pos.* = cur_pos;
        return left;
    }

    fn eval_term(tokens: [][]const u8, pos: usize, new_pos: *usize) std.fmt.ParseIntError!i64 {
        var cur_pos: usize = undefined;
        var left = try eval_factor(tokens, pos, &cur_pos);
        while (cur_pos < tokens.len and
            (std.mem.eql(u8, tokens[cur_pos], "*") or
                std.mem.eql(u8, tokens[cur_pos], "/") or
                std.mem.eql(u8, tokens[cur_pos], "%")))
        {
            const op = tokens[cur_pos];
            cur_pos += 1;
            var next_pos: usize = undefined;
            const right = try eval_factor(tokens, cur_pos, &next_pos);
            cur_pos = next_pos;
            left = if (std.mem.eql(u8, op, "*"))
                left * right
            else if (std.mem.eql(u8, op, "/"))
                @divTrunc(left, right)
            else
                @rem(left, right);
        }
        new_pos.* = cur_pos;
        return left;
    }

    fn eval_factor(tokens: [][]const u8, pos: usize, new_pos: *usize) std.fmt.ParseIntError!i64 {
        if (pos < tokens.len and std.mem.eql(u8, tokens[pos], "(")) {
            var cur_pos: usize = undefined;
            const val = try eval_expression(tokens, pos + 1, &cur_pos);
            if (cur_pos < tokens.len and std.mem.eql(u8, tokens[cur_pos], ")")) cur_pos += 1;
            new_pos.* = cur_pos;
            return val;
        }
        if (pos < tokens.len) {
            if (std.fmt.parseInt(i64, tokens[pos], 10)) |num| {
                new_pos.* = pos + 1;
                return num;
            } else |_| {}
        }
        new_pos.* = pos + 1;
        return 0;
    }

    fn is_inside_conditional_block(content: []const u8, position: usize) bool {
        const before = content[0..position];
        return count_if_fi_Depth(before) > 0;
    }

    fn count_if_fi_Depth(before: []const u8) usize {
        var depth: usize = 0;
        var i: usize = 0;
        while (i < before.len) {
            const prev_ok = i == 0 or
                before[i - 1] == '\n' or
                before[i - 1] == ';' or
                std.ascii.isWhitespace(before[i - 1]);

            if (prev_ok and matches_keyword(before[i..], "if")) {
                depth += 1;
                i += 2;
                continue;
            }
            if (prev_ok and matches_keyword(before[i..], "fi")) {
                depth = if (depth > 0) depth - 1 else 0;
                i += 2;
                continue;
            }
            i += 1;
        }
        return depth;
    }

    fn matches_keyword(s: []const u8, keyword: []const u8) bool {
        if (!std.mem.startsWith(u8, s, keyword)) return false;
        if (s.len == keyword.len) return true;
        const next = s[keyword.len];
        return !(std.ascii.isAlphanumeric(next) or next == '_');
    }

    fn strip_comment(line: []const u8) ![]const u8 {
        var single_q = false;
        var double_q = false;
        for (line, 0..) |l, i| {
            if (l == '"' and !single_q) {
                double_q = !double_q;
            } else if (l == '\'' and !double_q) {
                single_q = !single_q;
            } else if (l == '#' and !single_q and !double_q) {
                return line[0..i];
            }
        }
        return line;
    }

    fn parse_variable(content: []const u8, var_name: []const u8) !?[]const u8 {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t\r");
            if (!std.mem.startsWith(u8, trimmed, var_name)) continue;

            const after_name = trimmed[var_name.len..];
            if (after_name.len == 0 or after_name[0] != '=') continue;

            const value_part = after_name[1..];
            if (value_part.len == 0) return "";

            return switch (value_part[0]) {
                '"' => extract_quoted(value_part, '"'),
                '\'' => extract_quoted(value_part, '\''),
                else => extract_bare_token(value_part),
            };
        }
        return null;
    }

    fn extract_quoted(s: []const u8, quote: u8) ?[]const u8 {
        const rest = s[1..];
        if (std.mem.indexOfScalar(u8, rest, quote)) |end| {
            return rest[0..end];
        }
        return null;
    }

    fn extract_bare_token(s: []const u8) []const u8 {
        const end = std.mem.indexOfAny(u8, s, " \t\r\n") orelse s.len;
        return s[0..end];
    }

    fn apply_substring(value: []const u8, offset: i32, length: ?i32) ![]const u8 {
        const len: i32 = @intCast(value.len);

        var start = if (offset < 0) len + offset else offset;
        start = std.math.clamp(start, 0, len);

        var end: i32 = undefined;
        if (length) |l| {
            end = if (l < 0) len + l else start + l;
        } else {
            end = len;
        }
        end = std.math.clamp(end, start, len);

        const start_u: usize = @intCast(start);
        const end_u: usize = @intCast(end);

        return value[start_u..end_u];
    }

    pub fn extract_function_body(content: []const u8, function_name: []const u8) !?[]const u8 {
        const header_match = try match_at_line_start(content, 0, function_name);
        const start = header_match orelse return null;

        var depth: usize = 1;
        var i = start;
        var closed = false;
        while (i < content.len and depth > 0) {
            const c = content[i];
            if (c == '{') {
                depth += 1;
            } else if (c == '}') {
                depth -= 1;
                if (depth == 0) closed = true;
            }
            i += 1;
        }

        const end: usize = if (closed) i - 1 else i;
        const substring = content[start..end];
        const trimmed = std.mem.trim(u8, substring, " \t\n\r");
        return trimmed;
    }

    fn match_at_line_start(content: []const u8, start: usize, name: []const u8) !?usize {
        var pos = start;
        while (pos < content.len) {
            const is_line_start = (pos == 0) or (content[pos - 1] == '\n');
            if (is_line_start) {
                const result = matchLineStart(content, pos, name);
                if (result) |r| return r;
                pos += 1;
                continue;
            }
            const nl = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse break;
            pos = nl + 1;
        }
        return null;
    }

    fn matchLineStart(c: []const u8, p: usize, n: []const u8) ?usize {
        var i = skip_ws(c, p);
        if (std.mem.startsWith(u8, c[i..], "function")) {
            const after_kw = i + "function".len;
            const after_ws = skip_ws(c, after_kw);
            if (after_ws > after_kw) {
                i = after_ws;
            }
        }
        if (!std.mem.startsWith(u8, c[i..], n)) return null;
        i += n.len;
        i = skip_ws(c, i);
        if (i >= c.len or c[i] != '(') return null;
        i += 1;
        i = skip_ws(c, i);
        if (i >= c.len or c[i] != ')') return null;
        i += 1;
        i = skip_ws(c, i);
        if (i >= c.len or c[i] != '{') return null;
        i += 1;
        return i;
    }

    fn resolve_post_install(self: PkgbuildParser, install_file: ?[]const u8, base_dir: ?[]const u8) !?[]const u8 {
        const file = install_file orelse return null;
        for (file) |c| {
            if (std.ascii.isWhitespace(c)) return null;
        }

        const path = if (base_dir) |dir|
            try std.fs.path.join(self.allocator, &.{ dir, file })
        else
            file;
        defer if (base_dir != null) self.allocator.free(path);

        const exists = blk: {
            std.Io.Dir.cwd().access(self.io, path, .{}) catch break :blk false;
            break :blk true;
        };
        if (!exists) return null;

        const install_content = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited);
        defer self.allocator.free(install_content);

        const body = try extract_function_body(install_content, "post_install");
        if (body) |b| {
            return try self.allocator.dupe(u8, b);
        }
        return null;
    }

    fn resolve_local_file(self: PkgbuildParser, file_name: []const u8, base_dir: ?[]const u8) !?[]const u8 {
        for (file_name) |c| {
            if (std.ascii.isWhitespace(c)) return null;
        }

        const path = if (base_dir) |dir|
            try std.fs.path.join(self.allocator, &.{ dir, file_name })
        else
            file_name;
        defer if (base_dir != null) self.allocator.free(path);

        const exists = blk: {
            std.Io.Dir.cwd().access(self.io, path, .{}) catch break :blk false;
            break :blk true;
        };
        if (!exists) return null;

        return try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(max_local_source_size));
    }

    fn skip_ws(content: []const u8, start: usize) usize {
        var i = start;
        while (i < content.len and std.ascii.isWhitespace(content[i])) : (i += 1) {}
        return i;
    }

    fn resolve_or_parse(self: PkgbuildParser, content: []const u8, var_name: []const u8, vars: *const std.StringHashMap([]const u8)) !?[]const u8 {
        if (vars.get(var_name)) |val| {
            return try self.allocator.dupe(u8, val);
        }
        const parsed = try parse_variable(content, var_name) orelse return null;
        return try self.allocator.dupe(u8, parsed);
    }

    fn split_source_entry(entry: []const u8) split_entry {
        const idx = std.ascii.indexOfIgnoreCase(entry, "::");
        if (idx) |i| {
            return split_entry{ .file_name = entry[0..i], .location = entry[i + 2 ..] };
        } else {
            return split_entry{ .file_name = "", .location = entry };
        }
    }

    fn parse_kvp(line: []const u8) ?kvp {
        var pos: usize = 0;
        while (pos < line.len and is_word(line[pos])) : (pos += 1) {}
        if (pos == 0) return null;
        const key = line[0..pos];

        if (pos >= line.len or line[pos] != '=') return null;
        pos += 1;
        if (pos >= line.len) return null;

        if (line[pos] == '"') {
            const start = pos + 1;
            const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
            return kvp{ .key = key, .value = line[start..end] };
        }

        if (line[pos] == '\'') {
            const start = pos + 1;
            const end = std.mem.indexOfScalarPos(u8, line, start, '\'') orelse return null;
            return kvp{ .key = key, .value = line[start..end] };
        }

        const start = pos;
        while (pos < line.len and !std.ascii.isWhitespace(line[pos])) : (pos += 1) {}
        if (pos == start) return null;
        return kvp{ .key = key, .value = line[start..pos] };
    }

    fn build_var_hashmap(self: PkgbuildParser, content: []const u8) !std.StringHashMap([]const u8) {
        var vars = std.StringHashMap([]const u8).init(self.allocator);
        errdefer vars.deinit();

        var line_itr = std.mem.splitScalar(u8, content, '\n');
        while (line_itr.next()) |full_line| {
            const line = std.mem.trimEnd(u8, full_line, "\r");
            const parsed = parse_kvp(line) orelse continue;

            if (std.mem.startsWith(u8, parsed.value, "(") or
                (std.mem.startsWith(u8, parsed.value, "$(") and !std.mem.startsWith(u8, parsed.value, "$((")))
            {
                continue;
            }

            const key_owned = try self.allocator.dupe(u8, parsed.key);
            errdefer self.allocator.free(key_owned);
            const value_owned = try self.allocator.dupe(u8, parsed.value);
            errdefer self.allocator.free(value_owned);

            if (vars.fetchRemove(key_owned)) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value);
            }
            try vars.put(key_owned, value_owned);
        }

        try self.inject_array_pkgname(content, &vars);

        var pass: usize = 0;
        while (pass < 10) : (pass += 1) {
            var changed = false;
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(self.allocator);
            var key_it = vars.keyIterator();
            while (key_it.next()) |k| try keys.append(self.allocator, k.*);

            for (keys.items) |key| {
                const original = vars.get(key).?;
                const resolved = try self.resolve_string(original, &vars);
                defer self.allocator.free(resolved);

                if (!std.mem.eql(u8, resolved, original)) {
                    const resolved_owned = try self.allocator.dupe(u8, resolved);
                    errdefer self.allocator.free(resolved_owned);

                    if (vars.fetchRemove(key)) |old| {
                        self.allocator.free(old.value);
                        try vars.put(old.key, resolved_owned);
                    }
                    changed = true;
                }
            }
            if (!changed) break;
        }

        return vars;
    }

    fn inject_array_pkgname(
        self: PkgbuildParser,
        content: []const u8,
        vars: *std.StringHashMap([]const u8),
    ) !void {
        if (vars.contains("pkgname")) return;

        const names = try self.parse_array(content, "pkgname");
        defer {
            for (names) |name| self.allocator.free(name);
            self.allocator.free(names);
        }
        if (names.len == 0) return;

        const value: []const u8 = if (self.selected_package_name) |package_name|
            for (names) |name| {
                if (std.mem.eql(u8, name, package_name)) break package_name;
            } else return
        else
            names[0];

        const owned_key = try self.allocator.dupe(u8, "pkgname");
        errdefer self.allocator.free(owned_key);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try vars.put(owned_key, owned_value);
    }

    fn is_word(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn match_operator_len(input: []const u8, pos: usize) ?usize {
        if (pos >= input.len) return null;
        switch (input[pos]) {
            '>', '<' => {
                if (pos + 1 < input.len and input[pos + 1] == '=') return 2;
                return 1;
            },
            '=' => return 1,
            else => return null,
        }
    }

    fn match_array_ref(item: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, item, "${")) return null;
        if (!std.mem.endsWith(u8, item, "[@]}")) return null;
        const name_start = 2;
        const name_end = item.len - 4;
        if (name_end <= name_start) return null;
        const name = item[name_start..name_end];
        for (name) |c| {
            if (!is_word(c)) return null;
        }
        return name;
    }

    fn strip_version_constraint(dep: []const u8) []const u8 {
        var pos: usize = 0;
        while (pos < dep.len) : (pos += 1) {
            const op_len = match_operator_len(dep, pos) orelse continue;
            var cursor = pos + op_len;

            if (cursor >= dep.len or dep[cursor] != '$') continue;
            cursor += 1;

            if (cursor < dep.len and dep[cursor] == '{') cursor += 1;

            const name_start = cursor;
            while (cursor < dep.len and is_word(dep[cursor])) : (cursor += 1) {}
            if (cursor == name_start) continue;

            return dep[0..pos];
        }
        return dep;
    }

    // Mirrors: (>=|<=|>|<|=)$
    fn strip_dangling_operator(dep: []const u8) []const u8 {
        if (dep.len >= 2) {
            const last2 = dep[dep.len - 2 ..];
            if (std.mem.eql(u8, last2, ">=") or std.mem.eql(u8, last2, "<=")) {
                return dep[0 .. dep.len - 2];
            }
        }
        if (dep.len >= 1) {
            const last = dep[dep.len - 1];
            if (last == '>' or last == '<' or last == '=') {
                return dep[0 .. dep.len - 1];
            }
        }
        return dep;
    }

    fn resolve_variable_references(self: PkgbuildParser, content: []const u8, vars: *std.StringHashMap([]const u8), items: [][]const u8) ![][]const u8 {
        var resolved: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (resolved.items) |it| self.allocator.free(it);
            resolved.deinit(self.allocator);
        }

        for (items) |item| {
            if (match_array_ref(item)) |referenced_var| {
                const referenced_items = try parse_array(self, content, referenced_var);
                defer {
                    for (referenced_items) |it| self.allocator.free(it);
                    self.allocator.free(referenced_items);
                }

                const nested = try self.resolve_variable_references(content, vars, referenced_items);
                defer self.allocator.free(nested);
                for (nested) |it| {
                    try resolved.append(self.allocator, it);
                }
            } else {
                const resolved_item = try self.resolve_string(item, vars);
                try resolved.append(self.allocator, resolved_item);
            }
        }

        for (resolved.items, 0..) |dep, idx| {
            var cleaned = strip_version_constraint(dep);
            if (std.mem.eql(u8, cleaned, dep)) {
                cleaned = strip_dangling_operator(dep);
            }
            if (!std.mem.eql(u8, cleaned, dep)) {
                std.debug.print("[Shelly] Warning: Stripped unresolved version constraint: {s} -> {s}\n", .{ dep, cleaned });
                const cleaned_owned = try self.allocator.dupe(u8, cleaned);
                self.allocator.free(dep);
                resolved.items[idx] = cleaned_owned;
            }
        }

        return resolved.toOwnedSlice(self.allocator);
    }

    fn parse_array(self: PkgbuildParser, content: []const u8, variable_name: []const u8) ![][]const u8 {
        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |it| self.allocator.free(it);
            result.deinit(self.allocator);
        }

        var search_from: usize = 0;
        while (find_next_array_start(content, variable_name, search_from)) |m| {
            search_from = m.after_paren;

            if (is_inside_conditional_block(content, m.start)) {
                std.debug.print("[Shelly] Skipping conditional {s}+=() at offset {d}\n", .{ variable_name, m.start });
                continue;
            }

            const scanned = try scan_array_body(self.allocator, content, m.after_paren);
            defer self.allocator.free(scanned.body);

            var cleaned: std.ArrayList(u8) = .empty;
            defer cleaned.deinit(self.allocator);

            var line_iter = std.mem.splitScalar(u8, scanned.body, '\n');
            var first_line = true;
            while (line_iter.next()) |line| {
                if (!first_line) try cleaned.append(self.allocator, '\n');
                first_line = false;
                const stripped = try strip_comment(line);
                try cleaned.appendSlice(self.allocator, stripped);
            }

            const items = try scan_array_items(self.allocator, cleaned.items);
            defer self.allocator.free(items);
            for (items) |item| {
                try result.append(self.allocator, item);
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn find_next_array_start(content: []const u8, variable_name: []const u8, search_from: usize) ?struct { start: usize, after_paren: usize } {
        var i = search_from;
        while (i < content.len) : (i += 1) {
            const at_line_start = (i == 0) or (content[i - 1] == '\n');
            if (!at_line_start) continue;
            if (!std.mem.startsWith(u8, content[i..], variable_name)) continue;

            var cursor = i + variable_name.len;
            if (cursor < content.len and content[cursor] == '+') cursor += 1;
            if (cursor >= content.len or content[cursor] != '=') continue;
            cursor += 1;
            if (cursor >= content.len or content[cursor] != '(') continue;
            cursor += 1;

            return .{ .start = i, .after_paren = cursor };
        }
        return null;
    }

    fn scan_array_body(allocator: std.mem.Allocator, content: []const u8, start: usize) !struct { body: []u8, end: usize } {
        var sb: std.ArrayList(u8) = .empty;
        errdefer sb.deinit(allocator);

        var in_single = false;
        var in_double = false;
        var i = start;
        while (i < content.len) {
            const c = content[i];
            if (c == '\\' and i + 1 < content.len) {
                try sb.append(allocator, c);
                try sb.append(allocator, content[i + 1]);
                i += 2;
                continue;
            }
            if (c == '\'' and !in_double) {
                in_single = !in_single;
                try sb.append(allocator, c);
                i += 1;
                continue;
            }
            if (c == '"' and !in_single) {
                in_double = !in_double;
                try sb.append(allocator, c);
                i += 1;
                continue;
            }
            if (c == ')' and !in_single and !in_double) {
                i += 1;
                break;
            }
            try sb.append(allocator, c);
            i += 1;
        }

        return .{ .body = try sb.toOwnedSlice(allocator), .end = i };
    }

    fn scan_array_items(allocator: std.mem.Allocator, cleaned: []const u8) ![][]const u8 {
        var items: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (items.items) |it| allocator.free(it);
            items.deinit(allocator);
        }

        var i: usize = 0;
        while (i < cleaned.len) {
            const c = cleaned[i];
            if (c == '"') {
                const start = i + 1;
                const end = std.mem.indexOfScalarPos(u8, cleaned, start, '"') orelse cleaned.len;
                i = if (end < cleaned.len) end + 1 else cleaned.len;
                i = try append_quoted_item(allocator, &items, cleaned[start..end], cleaned, i);
                continue;
            }
            if (c == '\'') {
                const start = i + 1;
                const end = std.mem.indexOfScalarPos(u8, cleaned, start, '\'') orelse cleaned.len;
                i = if (end < cleaned.len) end + 1 else cleaned.len;
                i = try append_quoted_item(allocator, &items, cleaned[start..end], cleaned, i);
                continue;
            }
            if (std.ascii.isWhitespace(c)) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < cleaned.len and !std.ascii.isWhitespace(cleaned[i])) : (i += 1) {}
            try append_bare_item(allocator, &items, cleaned[start..i]);
        }

        return items.toOwnedSlice(allocator);
    }

    fn append_quoted_item(
        allocator: std.mem.Allocator,
        items: *std.ArrayList([]const u8),
        base: []const u8,
        cleaned: []const u8,
        pos: usize,
    ) !usize {
        if (pos < cleaned.len and cleaned[pos] == '{') {
            if (std.mem.indexOfScalarPos(u8, cleaned, pos + 1, '}')) |close| {
                const inner = cleaned[pos + 1 .. close];
                if (std.mem.indexOfScalar(u8, inner, ',') != null) {
                    try append_brace_expansion(allocator, items, base, inner, "");
                    return close + 1;
                }
                try items.append(allocator, try std.fmt.allocPrint(allocator, "{s}{{{s}}}", .{ base, inner }));
                return close + 1;
            }
        }
        try items.append(allocator, try allocator.dupe(u8, base));
        return pos;
    }

    fn append_bare_item(
        allocator: std.mem.Allocator,
        items: *std.ArrayList([]const u8),
        token: []const u8,
    ) !void {
        if (std.mem.indexOfScalar(u8, token, '{')) |open| {
            if (std.mem.indexOfScalarPos(u8, token, open + 1, '}')) |close| {
                const inner = token[open + 1 .. close];
                if (std.mem.indexOfScalar(u8, inner, ',') != null) {
                    try append_brace_expansion(allocator, items, token[0..open], inner, token[close + 1 ..]);
                    return;
                }
            }
        }
        try items.append(allocator, try allocator.dupe(u8, token));
    }

    fn append_brace_expansion(
        allocator: std.mem.Allocator,
        items: *std.ArrayList([]const u8),
        prefix: []const u8,
        inner: []const u8,
        suffix: []const u8,
    ) !void {
        var alternatives = std.mem.splitScalar(u8, inner, ',');
        while (alternatives.next()) |alternative| {
            try items.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, alternative, suffix }));
        }
    }

    fn free_vars(allocator: std.mem.Allocator, vars: *std.StringHashMap([]const u8)) void {
        var it = vars.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        vars.deinit();
    }

    fn is_dep_name_char(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '@' or c == '.' or c == '_' or c == '+' or c == '-';
    }

    fn match_dep_operator(s: []const u8, pos: usize) ?usize {
        if (pos >= s.len) return null;
        if (pos + 1 < s.len and (s[pos] == '>' or s[pos] == '<') and s[pos + 1] == '=') return 2;
        return switch (s[pos]) {
            '=', '>', '<' => 1,
            else => null,
        };
    }

    fn parse_dependency(self: PkgbuildParser, dependency: []const u8) !parsed_dep {
        const trimmed = std.mem.trim(u8, dependency, " \t\r\n");

        var i: usize = 0;
        while (i < trimmed.len and is_dep_name_char(trimmed[i])) : (i += 1) {}

        if (i > 0) {
            if (match_dep_operator(trimmed, i)) |op_len| {
                const version_start = i + op_len;
                if (version_start < trimmed.len) {
                    const name = std.mem.trim(u8, trimmed[0..i], " \t\r\n");
                    const operator = trimmed[i..version_start];
                    const version = std.mem.trim(u8, trimmed[version_start..], " \t\r\n");
                    return parsed_dep{
                        .name = try self.allocator.dupe(u8, name),
                        .operator = try self.allocator.dupe(u8, operator),
                        .version = try self.allocator.dupe(u8, version),
                    };
                }
            }
        }

        return parsed_dep{
            .name = try self.allocator.dupe(u8, trimmed),
            .operator = try self.allocator.dupe(u8, ""),
            .version = try self.allocator.dupe(u8, ""),
        };
    }

    fn parse_dependencies(self: PkgbuildParser, items: [][]const u8) ![]parsed_dep {
        var result: std.ArrayList(parsed_dep) = .empty;
        errdefer {
            for (result.items) |d| d.deinit(self.allocator);
            result.deinit(self.allocator);
        }
        for (items) |item| {
            const d = try self.parse_dependency(item);
            try result.append(self.allocator, d);
        }
        return result.toOwnedSlice(self.allocator);
    }
};

test "parse_array: brace expansion after double-quoted item" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parser.parse_array("source=(\"https://example.com/pkg.tar.gz\"{,.asc})\n", "source");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("https://example.com/pkg.tar.gz", items[0]);
    try std.testing.expectEqualStrings("https://example.com/pkg.tar.gz.asc", items[1]);
}

test "parse_array: brace expansion after single-quoted item" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parser.parse_array("source=('https://example.com/pkg.tar.gz'{,.sig})\n", "source");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("https://example.com/pkg.tar.gz", items[0]);
    try std.testing.expectEqualStrings("https://example.com/pkg.tar.gz.sig", items[1]);
}

test "parse_array: brace expansion inside bare item" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parser.parse_array("source=(file{,.asc} doc.{pdf,html})\n", "source");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqualStrings("file", items[0]);
    try std.testing.expectEqualStrings("file.asc", items[1]);
    try std.testing.expectEqualStrings("doc.pdf", items[2]);
    try std.testing.expectEqualStrings("doc.html", items[3]);
}

test "parse_array: brace expansion supports more than two alternatives" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parser.parse_array("source=(\"archive\"{.tar.gz,.tar.xz,.zip})\n", "source");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("archive.tar.gz", items[0]);
    try std.testing.expectEqualStrings("archive.tar.xz", items[1]);
    try std.testing.expectEqualStrings("archive.zip", items[2]);
}

test "parse_array: brace group without comma stays literal" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parser.parse_array("source=(\"backup\"{old} note{1})\n", "source");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("backup{old}", items[0]);
    try std.testing.expectEqualStrings("note{1}", items[1]);
}

test "append_brace_expansion: joins prefix and suffix to each alternative in order" {
    var items: std.ArrayList([]const u8) = .empty;
    defer {
        for (items.items) |it| std.testing.allocator.free(it);
        items.deinit(std.testing.allocator);
    }

    try PkgbuildParser.append_brace_expansion(std.testing.allocator, &items, "doc.", "pdf,html", "");

    try std.testing.expectEqual(@as(usize, 2), items.items.len);
    try std.testing.expectEqualStrings("doc.pdf", items.items[0]);
    try std.testing.expectEqualStrings("doc.html", items.items[1]);
}

test "append_brace_expansion: applies suffix to every alternative" {
    var items: std.ArrayList([]const u8) = .empty;
    defer {
        for (items.items) |it| std.testing.allocator.free(it);
        items.deinit(std.testing.allocator);
    }

    try PkgbuildParser.append_brace_expansion(std.testing.allocator, &items, "pkg", ".tar.gz,.tar.xz", ".sig");

    try std.testing.expectEqual(@as(usize, 2), items.items.len);
    try std.testing.expectEqualStrings("pkg.tar.gz.sig", items.items[0]);
    try std.testing.expectEqualStrings("pkg.tar.xz.sig", items.items[1]);
}

test "append_brace_expansion: empty alternative yields prefix/suffix only" {
    var items: std.ArrayList([]const u8) = .empty;
    defer {
        for (items.items) |it| std.testing.allocator.free(it);
        items.deinit(std.testing.allocator);
    }

    try PkgbuildParser.append_brace_expansion(std.testing.allocator, &items, "pkg.tar.gz", ",.asc", "");

    try std.testing.expectEqual(@as(usize, 2), items.items.len);
    try std.testing.expectEqualStrings("pkg.tar.gz", items.items[0]);
    try std.testing.expectEqualStrings("pkg.tar.gz.asc", items.items[1]);
}

test "append_bare_item: inline brace group with comma expands with prefix and suffix" {
    var items: std.ArrayList([]const u8) = .empty;
    defer {
        for (items.items) |it| std.testing.allocator.free(it);
        items.deinit(std.testing.allocator);
    }

    try PkgbuildParser.append_bare_item(std.testing.allocator, &items, "file{,.asc}");

    try std.testing.expectEqual(@as(usize, 2), items.items.len);
    try std.testing.expectEqualStrings("file", items.items[0]);
    try std.testing.expectEqualStrings("file.asc", items.items[1]);
}

test "append_bare_item: suffix after closing brace is appended to each expansion" {
    var items: std.ArrayList([]const u8) = .empty;
    defer {
        for (items.items) |it| std.testing.allocator.free(it);
        items.deinit(std.testing.allocator);
    }

    try PkgbuildParser.append_bare_item(std.testing.allocator, &items, "doc.{pdf,html}.in");

    try std.testing.expectEqual(@as(usize, 2), items.items.len);
    try std.testing.expectEqualStrings("doc.pdf.in", items.items[0]);
    try std.testing.expectEqualStrings("doc.html.in", items.items[1]);
}

test "append_bare_item: token without brace group is appended verbatim" {
    var items: std.ArrayList([]const u8) = .empty;
    defer {
        for (items.items) |it| std.testing.allocator.free(it);
        items.deinit(std.testing.allocator);
    }

    try PkgbuildParser.append_bare_item(std.testing.allocator, &items, "plain.txt");

    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqualStrings("plain.txt", items.items[0]);
}

test "append_bare_item: brace group without comma stays literal" {
    var items: std.ArrayList([]const u8) = .empty;
    defer {
        for (items.items) |it| std.testing.allocator.free(it);
        items.deinit(std.testing.allocator);
    }

    try PkgbuildParser.append_bare_item(std.testing.allocator, &items, "note{1}");

    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqualStrings("note{1}", items.items[0]);
}

test "append_brace_expansion: nested brace group is not recursively expanded" {
    var items: std.ArrayList([]const u8) = .empty;
    defer {
        for (items.items) |it| std.testing.allocator.free(it);
        items.deinit(std.testing.allocator);
    }

    // The inner `{c}` is treated as literal text; only the top-level comma splits.
    try PkgbuildParser.append_brace_expansion(std.testing.allocator, &items, "x", "a,b{c}", "");

    try std.testing.expectEqual(@as(usize, 2), items.items.len);
    try std.testing.expectEqualStrings("xa", items.items[0]);
    try std.testing.expectEqualStrings("xb{c}", items.items[1]);
}

test "append_quoted_item: brace group with comma after quoted item expands" {
    var items: std.ArrayList([]const u8) = .empty;
    defer {
        for (items.items) |it| std.testing.allocator.free(it);
        items.deinit(std.testing.allocator);
    }

    const cleaned = "\"pkg.tar.gz\"{,.asc}";
    // `pos` points just past the closing quote, at the opening brace.
    const pos = cleaned.len - "{,.asc}".len;
    const new_pos = try PkgbuildParser.append_quoted_item(
        std.testing.allocator,
        &items,
        "pkg.tar.gz",
        cleaned,
        pos,
    );

    try std.testing.expectEqual(@as(usize, 2), items.items.len);
    try std.testing.expectEqualStrings("pkg.tar.gz", items.items[0]);
    try std.testing.expectEqualStrings("pkg.tar.gz.asc", items.items[1]);
    // New position is just past the closing brace.
    try std.testing.expectEqual(cleaned.len, new_pos);
}

test "append_quoted_item: brace group without comma is joined literally" {
    var items: std.ArrayList([]const u8) = .empty;
    defer {
        for (items.items) |it| std.testing.allocator.free(it);
        items.deinit(std.testing.allocator);
    }

    const cleaned = "\"backup\"{old}";
    const pos = cleaned.len - "{old}".len;
    const new_pos = try PkgbuildParser.append_quoted_item(
        std.testing.allocator,
        &items,
        "backup",
        cleaned,
        pos,
    );

    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqualStrings("backup{old}", items.items[0]);
    try std.testing.expectEqual(cleaned.len, new_pos);
}

test "append_quoted_item: no brace group appends base and returns original position" {
    var items: std.ArrayList([]const u8) = .empty;
    defer {
        for (items.items) |it| std.testing.allocator.free(it);
        items.deinit(std.testing.allocator);
    }

    const cleaned = "\"plain\" tail";
    const pos: usize = "\"plain\"".len;
    const new_pos = try PkgbuildParser.append_quoted_item(
        std.testing.allocator,
        &items,
        "plain",
        cleaned,
        pos,
    );

    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqualStrings("plain", items.items[0]);
    // Position is returned unchanged so the caller continues scanning the tail.
    try std.testing.expectEqual(pos, new_pos);
}

test "parser_content: dropbox PKGBUILD expands trailing {,.asc} signature source" {
    // Regression test for https://aur.archlinux.org/packages/dropbox: the
    // final source entry is a quoted URL followed by `{,.asc}`. The literal
    // `{,.asc}` fragment used to be parsed as its own local source file and
    // fail review with FileNotFound.
    const dropbox_pkgbuild =
        \\pkgname=dropbox
        \\pkgver=264.4.3421
        \\pkgrel=1
        \\pkgdesc="A free service that lets you bring your photos, docs, and videos anywhere and share them easily."
        \\arch=("x86_64")
        \\url="https://www.dropbox.com"
        \\license=(custom:Dropbox)
        \\depends=("libsm" "libxslt")
        \\makedepends=("gendesk")
        \\options=('!strip')
        \\
        \\source=("DropboxGlyph_Blue.svg"
        \\        "terms.txt"
        \\        "dropbox.service"
        \\        "dropbox@.service"
        \\        "https://edge.dropboxstatic.com/dbx-releng/client/dropbox-lnx.x86_64-$pkgver.tar.gz"{,.asc})
        \\
        \\sha256sums=('9ba76205ec5838db85d822f23cfd7e2112fd2757e8031d8374709f102143c548'
        \\            '1610ff57e8b20ee7a37682c3cc505da4ddc9cec2bd7234c90c0f2073657521d2'
        \\            '6c67a9c8c95c08fafafd2f1d828074b13e3347b05d2e4f4bf4e62746115d7477'
        \\            '98581e65a91ae1f19ed42edcdaaa52e102298b5da0d71b50089393d364474d3d'
        \\            '4aa06821de43b5e1cf4f27f83cb5f0bca82d01107c758091d7895f0d723f5411'
        \\            'SKIP')
        \\
    ;

    var parser: PkgbuildParser = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
    };
    var info = try parser.parser_content(dropbox_pkgbuild, null);
    defer info.deinit(std.testing.allocator);

    const source = info.source.?;
    try std.testing.expectEqual(@as(usize, 6), source.len);
    try std.testing.expectEqualStrings("DropboxGlyph_Blue.svg", source[0]);
    try std.testing.expectEqualStrings("terms.txt", source[1]);
    try std.testing.expectEqualStrings("dropbox.service", source[2]);
    try std.testing.expectEqualStrings("dropbox@.service", source[3]);
    try std.testing.expectEqualStrings(
        "https://edge.dropboxstatic.com/dbx-releng/client/dropbox-lnx.x86_64-264.4.3421.tar.gz",
        source[4],
    );
    try std.testing.expectEqualStrings(
        "https://edge.dropboxstatic.com/dbx-releng/client/dropbox-lnx.x86_64-264.4.3421.tar.gz.asc",
        source[5],
    );
    for (source) |entry| {
        try std.testing.expect(std.mem.indexOfScalar(u8, entry, '{') == null);
    }

    const local_files = info.local_source_files.?;
    try std.testing.expectEqual(@as(usize, 4), local_files.len);
    try std.testing.expectEqualStrings("DropboxGlyph_Blue.svg", local_files[0]);
    try std.testing.expectEqualStrings("terms.txt", local_files[1]);
    try std.testing.expectEqualStrings("dropbox.service", local_files[2]);
    try std.testing.expectEqualStrings("dropbox@.service", local_files[3]);

    const sums = info.sha_256_sums.?;
    try std.testing.expectEqual(@as(usize, 6), sums.len);
    try std.testing.expectEqualStrings("SKIP", sums[5]);
}

test "parse_variable: bare token stops at whitespace" {
    const content = "pkgver=1.2.3 extra stuff\n";
    const result = try PkgbuildParser.parse_variable(content, "pkgver");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("1.2.3", result.?);
}

test "parse_variable: quoted value containing spaces" {
    const content = "pkgdesc=\"a package with spaces\"\n";
    const result = try PkgbuildParser.parse_variable(content, "pkgdesc");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("a package with spaces", result.?);
}

test "parse_variable: variable not found returns null" {
    const content = "pkgname=foo\n";
    const result = try PkgbuildParser.parse_variable(content, "pkgver");
    try std.testing.expect(result == null);
}

test "parse_variable: empty value returns empty string" {
    const content = "pkgrel=\n";
    const result = try PkgbuildParser.parse_variable(content, "pkgrel");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("", result.?);
}

test "parse_variable: does not match prefix of longer variable name" {
    const content = "pkgname=foo\n";
    const result = try PkgbuildParser.parse_variable(content, "pkg");
    try std.testing.expect(result == null);
}

test "parse_variable: matches on later line" {
    const content =
        \\pkgname=foo
        \\pkgver=1.0.0
        \\pkgrel=1
    ;
    const result = try PkgbuildParser.parse_variable(content, "pkgver");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("1.0.0", result.?);
}

test "strip_comment: no comment returns full line" {
    const result = try PkgbuildParser.strip_comment("pkgname=foo");
    try std.testing.expectEqualStrings("pkgname=foo", result);
}

test "strip_comment: simple trailing comment" {
    const result = try PkgbuildParser.strip_comment("pkgname=foo # comment");
    try std.testing.expectEqualStrings("pkgname=foo ", result);
}

test "strip_comment: comment at start of line" {
    const result = try PkgbuildParser.strip_comment("# full comment line");
    try std.testing.expectEqualStrings("", result);
}

test "strip_comment: hash inside double quotes is not a comment" {
    const result = try PkgbuildParser.strip_comment("pkgdesc=\"a # not a comment\"");
    try std.testing.expectEqualStrings("pkgdesc=\"a # not a comment\"", result);
}

test "strip_comment: empty line" {
    const result = try PkgbuildParser.strip_comment("");
    try std.testing.expectEqualStrings("", result);
}

test "is_inside_conditional_block: no if/fi returns false" {
    const content = "pkgname=foo\npkgver=1.0\n";
    try std.testing.expect(!PkgbuildParser.is_inside_conditional_block(content, content.len));
}

test "is_inside_conditional_block: inside an open if block" {
    const content = "if true; then\n  pkgname=foo\n";
    try std.testing.expect(PkgbuildParser.is_inside_conditional_block(content, content.len));
}

test "is_inside_conditional_block: closed by matching fi" {
    const content = "if true; then\n  pkgname=foo\nfi\npkgver=1.0\n";
    try std.testing.expect(!PkgbuildParser.is_inside_conditional_block(content, content.len));
}

test "is_inside_conditional_block: nested if only closed one level" {
    const content = "if true; then\n  if true; then\n    pkgname=foo\n  fi\n";
    try std.testing.expect(PkgbuildParser.is_inside_conditional_block(content, content.len));
}

test "is_inside_conditional_block: extra fi does not go negative" {
    const content = "fi\nfi\npkgname=foo\n";
    try std.testing.expect(!PkgbuildParser.is_inside_conditional_block(content, content.len));
}

test "is_inside_conditional_block: word boundary rejects 'ifs' and 'fix'" {
    const content = "ifs=foo\nfix=1\n";
    try std.testing.expect(!PkgbuildParser.is_inside_conditional_block(content, content.len));
}

test "is_inside_conditional_block: position before the if is not inside" {
    const content = "pkgname=foo\nif true; then\n  pkgrel=1\nfi\n";
    const if_pos = std.mem.indexOf(u8, content, "if").?;
    try std.testing.expect(!PkgbuildParser.is_inside_conditional_block(content, if_pos));
}

test "eval_expression: single number" {
    const tokens = [_][]const u8{"42"};
    var new_pos: usize = undefined;
    const result = try PkgbuildParser.eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 42), result);
    try std.testing.expectEqual(@as(usize, 1), new_pos);
}

test "eval_expression: simple addition" {
    const tokens = [_][]const u8{ "1", "+", "2" };
    var new_pos: usize = undefined;
    const result = try PkgbuildParser.eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 3), result);
    try std.testing.expectEqual(@as(usize, 3), new_pos);
}

test "eval_expression: simple subtraction" {
    const tokens = [_][]const u8{ "5", "-", "3" };
    var new_pos: usize = undefined;
    const result = try PkgbuildParser.eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 2), result);
}

test "eval_expression: operator precedence, multiplication before addition" {
    const tokens = [_][]const u8{ "2", "+", "3", "*", "4" };
    var new_pos: usize = undefined;
    const result = try PkgbuildParser.eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 14), result);
}

test "eval_expression: division" {
    const tokens = [_][]const u8{ "10", "/", "2" };
    var new_pos: usize = undefined;
    const result = try PkgbuildParser.eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 5), result);
}

test "eval_expression: modulo" {
    const tokens = [_][]const u8{ "10", "%", "3" };
    var new_pos: usize = undefined;
    const result = try PkgbuildParser.eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "eval_expression: parentheses override precedence" {
    const tokens = [_][]const u8{ "(", "2", "+", "3", ")", "*", "4" };
    var new_pos: usize = undefined;
    const result = try PkgbuildParser.eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 20), result);
}

test "eval_expression: nested parentheses" {
    const tokens = [_][]const u8{ "(", "(", "1", "+", "2", ")", "*", "(", "3", "+", "4", ")", ")" };
    var new_pos: usize = undefined;
    const result = try PkgbuildParser.eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 21), result);
}

test "eval_expression: chained same-precedence operators" {
    const tokens = [_][]const u8{ "10", "-", "2", "-", "3" };
    var new_pos: usize = undefined;
    const result = try PkgbuildParser.eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 5), result);
}

test "eval_factor: unparseable token returns zero" {
    const tokens = [_][]const u8{"abc"};
    var new_pos: usize = undefined;
    const result = try PkgbuildParser.eval_factor(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 0), result);
    try std.testing.expectEqual(@as(usize, 1), new_pos);
}

test "tokenize: single number" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const tokens = try parser.tokenize("42");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqualStrings("42", tokens[0]);
}

test "tokenize: simple expression" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const tokens = try parser.tokenize("1+2");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqualStrings("1", tokens[0]);
    try std.testing.expectEqualStrings("+", tokens[1]);
    try std.testing.expectEqualStrings("2", tokens[2]);
}

test "tokenize: multi-digit numbers" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const tokens = try parser.tokenize("123*456");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqualStrings("123", tokens[0]);
    try std.testing.expectEqualStrings("*", tokens[1]);
    try std.testing.expectEqualStrings("456", tokens[2]);
}

test "tokenize: ignores whitespace" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const tokens = try parser.tokenize("  1 + 2  ");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqualStrings("1", tokens[0]);
    try std.testing.expectEqualStrings("+", tokens[1]);
    try std.testing.expectEqualStrings("2", tokens[2]);
}

test "tokenize: parentheses" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const tokens = try parser.tokenize("(1+2)*3");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 7), tokens.len);
    try std.testing.expectEqualStrings("(", tokens[0]);
    try std.testing.expectEqualStrings("1", tokens[1]);
    try std.testing.expectEqualStrings("+", tokens[2]);
    try std.testing.expectEqualStrings("2", tokens[3]);
    try std.testing.expectEqualStrings(")", tokens[4]);
    try std.testing.expectEqualStrings("*", tokens[5]);
    try std.testing.expectEqualStrings("3", tokens[6]);
}

test "tokenize: all operators" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const tokens = try parser.tokenize("+-*/%()");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 7), tokens.len);
    const expected = [_][]const u8{ "+", "-", "*", "/", "%", "(", ")" };
    for (tokens, expected) |got, want| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "tokenize: empty expression returns empty slice" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const tokens = try parser.tokenize("");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 0), tokens.len);
}

test "tokenize: unknown characters are skipped" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const tokens = try parser.tokenize("1 & 2");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqualStrings("1", tokens[0]);
    try std.testing.expectEqualStrings("2", tokens[1]);
}

test "apply_substring: positive offset, no length" {
    const result = try PkgbuildParser.apply_substring("hello world", 6, null);
    try std.testing.expectEqualStrings("world", result);
}

test "apply_substring: positive offset and length" {
    const result = try PkgbuildParser.apply_substring("hello world", 0, 5);
    try std.testing.expectEqualStrings("hello", result);
}

test "apply_substring: negative offset counts from end" {
    const result = try PkgbuildParser.apply_substring("hello world", -5, null);
    try std.testing.expectEqualStrings("world", result);
}

test "apply_substring: negative length trims from end" {
    const result = try PkgbuildParser.apply_substring("hello world", 0, -6);
    try std.testing.expectEqualStrings("hello", result);
}

test "apply_substring: offset beyond length clamps to empty" {
    const result = try PkgbuildParser.apply_substring("hello", 100, null);
    try std.testing.expectEqualStrings("", result);
}

test "apply_substring: negative offset beyond start clamps to zero" {
    const result = try PkgbuildParser.apply_substring("hello", -100, null);
    try std.testing.expectEqualStrings("hello", result);
}

test "apply_substring: length longer than remaining string clamps" {
    const result = try PkgbuildParser.apply_substring("hello", 2, 100);
    try std.testing.expectEqualStrings("llo", result);
}

test "apply_substring: zero length returns empty string" {
    const result = try PkgbuildParser.apply_substring("hello", 2, 0);
    try std.testing.expectEqualStrings("", result);
}

test "apply_substring: negative length larger than start clamps to empty" {
    const result = try PkgbuildParser.apply_substring("hello", 3, -100);
    try std.testing.expectEqualStrings("", result);
}

test "apply_substring: empty input string" {
    const result = try PkgbuildParser.apply_substring("", 0, null);
    try std.testing.expectEqualStrings("", result);
}

test "match_at_line_start: bare function call syntax, no keyword" {
    const content = "myFunction() {\n  return;\n}";
    const result = try PkgbuildParser.match_at_line_start(content, 0, "myFunction");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 14), result.?); // index just past the '{'
}

test "match_at_line_start: with 'function' keyword prefix" {
    const content = "function myFunction() {\n  return;\n}";
    const result = try PkgbuildParser.match_at_line_start(content, 0, "myFunction");
    try std.testing.expect(result != null);
}

test "match_at_line_start: name that starts with 'function' but isn't the keyword" {
    const content = "functionCall() {\n}";
    const result = try PkgbuildParser.match_at_line_start(content, 0, "functionCall");
    try std.testing.expect(result != null);
}

test "match_at_line_start: wrong function name does not match" {
    const content = "otherFunction() {\n}";
    const result = try PkgbuildParser.match_at_line_start(content, 0, "myFunction");
    try std.testing.expect(result == null);
}

test "match_at_line_start: function with parameters does not match" {
    const content = "myFunction(a, b) {\n}";
    const result = try PkgbuildParser.match_at_line_start(content, 0, "myFunction");
    try std.testing.expect(result == null);
}

test "match_at_line_start: whitespace and newlines between tokens are tolerated" {
    const content =
        \\myFunction
        \\  (
        \\  )
        \\  {
    ;
    const result = try PkgbuildParser.match_at_line_start(content, 0, "myFunction");
    try std.testing.expect(result != null);
}

test "extract_function_body: simple body with no nesting" {
    const content = "myFunction() {\n  return 1;\n}";
    const result = try PkgbuildParser.extract_function_body(content, "myFunction");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("return 1;", result.?);
}

test "extract_function_body: nested braces are balanced correctly" {
    const content =
        \\myFunction() {
        \\  if (x) {
        \\    doThing();
        \\  }
        \\  return 1;
        \\}
    ;
    const result = try PkgbuildParser.extract_function_body(content, "myFunction");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(
        "if (x) {\n    doThing();\n  }\n  return 1;",
        result.?,
    );
}

test "extract_function_body: no matching function returns null" {
    const content = "otherFunction() {\n  return 1;\n}";
    const result = try PkgbuildParser.extract_function_body(content, "myFunction");
    try std.testing.expect(result == null);
}

test "extract_function_body: empty body" {
    const content = "myFunction() {}";
    const result = try PkgbuildParser.extract_function_body(content, "myFunction");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("", result.?);
}

test "extract_function_body: unclosed brace consumes to end of content" {
    // depth never reaches 0, so the loop runs until content.len
    const content = "myFunction() {\n  return 1;";
    const result = try PkgbuildParser.extract_function_body(content, "myFunction");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("return 1;", result.?);
}

test "resolve_post_install: null install_file returns null" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.resolve_post_install(null, null);
    try std.testing.expect(result == null);
}

test "resolve_post_install: install_file containing whitespace returns null" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.resolve_post_install("my install.sh", null);
    try std.testing.expect(result == null);
}

test "resolve_post_install: nonexistent file returns null" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.resolve_post_install("definitely_does_not_exist.install", null);
    try std.testing.expect(result == null);
}

test "resolve_post_install: existing file with no base_dir extracts body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = "post_install() {\n  echo hello\n}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "test.install", .data = content });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "test.install", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.resolve_post_install(path, null);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("echo hello", result.?);
}

test "resolve_post_install: joins base_dir and install_file correctly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = "post_install() {\n  echo joined\n}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "myapp.install", .data = content });

    const base_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_dir);

    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.resolve_post_install("myapp.install", base_dir);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("echo joined", result.?);
}

test "resolve_local_file: file name containing whitespace returns null" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.resolve_local_file("my source.tar.gz", null);
    try std.testing.expect(result == null);
}

test "resolve_local_file: nonexistent file returns null" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.resolve_local_file("definitely_not_a_file.txt", null);
    try std.testing.expect(result == null);
}

test "resolve_local_file: existing file with no base_dir returns content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const expected = "hello world\nthis is my file content";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "test.txt", .data = expected });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "test.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.resolve_local_file(path, null);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings(expected, result.?);
}

test "resolve_local_file: joins base_dir and file_name correctly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const expected = "data in a subdir";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data.txt", .data = expected });

    const base_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_dir);

    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.resolve_local_file("data.txt", base_dir);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings(expected, result.?);
}

test "substitute_variables: no variables in expression" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.substitute_variables("hello world", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "substitute_variables: single variable with integer value" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("EPOCH", "2");

    const result = try parser.substitute_variables("pkgver=1.0.$EPOCH", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("pkgver=1.0.2", result);
}

test "substitute_variables: braced variable with integer value" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("REL", "3");

    const result = try parser.substitute_variables("${REL}", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("3", result);
}

test "substitute_variables: variable not found keeps original text" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.substitute_variables("value=$MISSING", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("value=$MISSING", result);
}

test "substitute_variables: non-integer value keeps original text" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("NAME", "hello");

    const result = try parser.substitute_variables("$NAME", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("$NAME", result);
}

test "substitute_variables: mixed substituted and unsubstituted variables" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("A", "1");
    try vars.put("B", "not_a_number");

    const result = try parser.substitute_variables("$A $B", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1 $B", result);
}

test "substitute_variables: multiple integer variables" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("X", "10");
    try vars.put("Y", "20");

    const result = try parser.substitute_variables("$X+$Y", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("10+20", result);
}

test "substitute_variables: variable with underscore in name" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("MY_VAR", "42");

    const result = try parser.substitute_variables("$MY_VAR", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("42", result);
}

test "substitute_variables: dollar sign at end of string" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.substitute_variables("price$", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("price$", result);
}

test "substitute_variables: empty expression" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.substitute_variables("", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "substitute_variables: adjacent braced variables" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("A", "1");
    try vars.put("B", "2");

    const result = try parser.substitute_variables("${A}${B}", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("12", result);
}

test "substitute_variables: negative integer value is substituted" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("NEG", "-5");

    const result = try parser.substitute_variables("$NEG", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("-5", result);
}

test "substitute_variables: braced mixed with unbraced" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("X", "7");

    const result = try parser.substitute_variables("$X and ${X}", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("7 and 7", result);
}

test "evaluate_arithmetic: simple addition" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.evaluate_arithmetic("1 + 2", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("3", result);
}

test "evaluate_arithmetic: simple subtraction" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.evaluate_arithmetic("10 - 3", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("7", result);
}

test "evaluate_arithmetic: multiplication" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.evaluate_arithmetic("4 * 5", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("20", result);
}

test "evaluate_arithmetic: division" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.evaluate_arithmetic("15 / 3", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("5", result);
}

test "evaluate_arithmetic: modulo" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.evaluate_arithmetic("10 % 3", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1", result);
}

test "evaluate_arithmetic: operator precedence" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.evaluate_arithmetic("2 + 3 * 4", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("14", result);
}

test "evaluate_arithmetic: parentheses override precedence" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.evaluate_arithmetic("(2 + 3) * 4", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("20", result);
}

test "evaluate_arithmetic: single number" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.evaluate_arithmetic("42", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("42", result);
}

test "evaluate_arithmetic: variable substitution with arithmetic" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("EPOCH", "1");
    try vars.put("REL", "2");

    const result = try parser.evaluate_arithmetic("$EPOCH + $REL", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("3", result);
}

test "evaluate_arithmetic: braced variable substitution" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("X", "10");
    try vars.put("Y", "5");

    const result = try parser.evaluate_arithmetic("${X} - ${Y}", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("5", result);
}

test "evaluate_arithmetic: variable with non-integer value falls back to 0" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("BAD", "hello");

    const result = try parser.evaluate_arithmetic("$BAD + 1", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("0", result);
}

test "evaluate_arithmetic: unresolvable expression returns 0" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.evaluate_arithmetic("foo + bar", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("0", result);
}

test "evaluate_arithmetic: nested parentheses" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.evaluate_arithmetic("((2 + 3) * (4 - 1))", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("15", result);
}

test "evaluate_arithmetic: chained operators" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.evaluate_arithmetic("1 + 2 + 3 + 4", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("10", result);
}

test "resolve_local_source_contents: empty file list returns empty map" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const files: [][]const u8 = &.{};
    var result = try parser.resolve_local_source_contents(files, ".");
    defer {
        var it = result.valueIterator();
        while (it.next()) |value| {
            std.testing.allocator.free(value.*);
        }
        result.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), result.count());
}

test "resolve_local_source_contents: single existing file" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "content a" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    var files = [_][]const u8{"a.txt"};
    var result = try parser.resolve_local_source_contents(files[0..], base);
    defer {
        var it = result.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        result.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), result.count());
    try std.testing.expect(result.get("a.txt") != null);
    try std.testing.expectEqualStrings("content a", result.get("a.txt").?);
}

test "resolve_local_source_contents: multiple existing files" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "alpha" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.txt", .data = "beta" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    var files = [_][]const u8{ "a.txt", "b.txt" };
    var result = try parser.resolve_local_source_contents(files[0..], base);
    defer {
        var it = result.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        result.deinit();
    }
    try std.testing.expectEqual(@as(usize, 2), result.count());
    try std.testing.expectEqualStrings("alpha", result.get("a.txt").?);
    try std.testing.expectEqualStrings("beta", result.get("b.txt").?);
}

test "resolve_local_source_contents: skips nonexistent files" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "exists.txt", .data = "here" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    var files = [_][]const u8{ "exists.txt", "missing.txt" };
    var result = try parser.resolve_local_source_contents(files[0..], base);
    defer {
        var it = result.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        result.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), result.count());
    try std.testing.expect(result.get("missing.txt") == null);
    try std.testing.expectEqualStrings("here", result.get("exists.txt").?);
}

test "resolve_local_source_contents: skips files with whitespace in name" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "good.txt", .data = "ok" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    var files = [_][]const u8{ "good.txt", "bad file.txt" };
    var result = try parser.resolve_local_source_contents(files[0..], base);

    defer {
        var it = result.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        result.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), result.count());
    try std.testing.expect(result.get("bad file.txt") == null);
    try std.testing.expectEqualStrings("ok", result.get("good.txt").?);
}

test "resolve_local_source_contents: all files missing returns empty map" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    var files = [_][]const u8{ "no1.txt", "no2.txt" };
    var result = try parser.resolve_local_source_contents(files[0..], base);
    defer {
        var it = result.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        result.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), result.count());
}

test "is_remote_source true" {
    try std.testing.expect(try PkgbuildParser.is_remote_source("https://example.com"));
}

test "is_remote_source false" {
    try std.testing.expect(!try PkgbuildParser.is_remote_source("67.com"));
}

test "split_source_entry: normal case" {
    const result = PkgbuildParser.split_source_entry("archive.tar.gz::https://example.com/archive.tar.gz");
    try std.testing.expectEqualStrings("archive.tar.gz", result.file_name);
    try std.testing.expectEqualStrings("https://example.com/archive.tar.gz", result.location);
}

test "split_source_entry: no separator" {
    const result = PkgbuildParser.split_source_entry("https://example.com/file.tar.gz");
    try std.testing.expectEqualStrings("", result.file_name);
    try std.testing.expectEqualStrings("https://example.com/file.tar.gz", result.location);
}

test "split_source_entry: separator at start" {
    const result = PkgbuildParser.split_source_entry("::https://example.com");
    try std.testing.expectEqualStrings("", result.file_name);
    try std.testing.expectEqualStrings("https://example.com", result.location);
}

test "split_source_entry: separator at end" {
    const result = PkgbuildParser.split_source_entry("file.tar.gz::");
    try std.testing.expectEqualStrings("file.tar.gz", result.file_name);
    try std.testing.expectEqualStrings("", result.location);
}

test "split_source_entry: multiple separators" {
    const result = PkgbuildParser.split_source_entry("file::key::value");
    try std.testing.expectEqualStrings("file", result.file_name);
    try std.testing.expectEqualStrings("key::value", result.location);
}

test "split_source_entry: case insensitive separator" {
    // :: has no alphabetic characters, so case doesn't matter,
    // but this confirms the function handles the input as-is
    const result = PkgbuildParser.split_source_entry("pkg::url");
    try std.testing.expectEqualStrings("pkg", result.file_name);
    try std.testing.expectEqualStrings("url", result.location);
}
test "extract_local_source_files: keeps every local source, including extensionless binaries" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var source = [_][]const u8{
        "install.sh",
        "fix.patch",
        "readme.md",
        "updater",
    };
    const result = try parser.extract_local_source_files(source[0..]);
    defer {
        for (result) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("install.sh", result[0]);
    try std.testing.expectEqualStrings("fix.patch", result[1]);
    try std.testing.expectEqualStrings("readme.md", result[2]);
    try std.testing.expectEqualStrings("updater", result[3]);
}

test "extract_local_source_files: excludes remote sources" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var source = [_][]const u8{
        "https://example.com/archive.tar.gz",
        "renamed.sh::https://example.com/script.sh",
        "local.conf",
    };
    const result = try parser.extract_local_source_files(source[0..]);
    defer {
        for (result) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(result);
    }

    // "renamed.sh::https://..." has a local file_name but remote location —
    // confirm expected behavior here depends on how is_remote_source/split_source_entry
    // handle the "::" form for your implementation.
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("local.conf", result[0]);
}

test "extract_local_source_files: dedupes repeated file names" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var source = [_][]const u8{
        "install.sh",
        "install.sh",
        "install.sh",
    };
    const result = try parser.extract_local_source_files(source[0..]);
    defer {
        for (result) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("install.sh", result[0]);
}

test "extract_local_source_files: empty source returns empty slice" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var source = [_][]const u8{};
    const result = try parser.extract_local_source_files(source[0..]);
    defer {
        for (result) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "extract_local_source_files: keeps source names regardless of filename casing" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var source = [_][]const u8{
        "SETUP.SH",
    };
    const result = try parser.extract_local_source_files(source[0..]);
    defer {
        for (result) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("SETUP.SH", result[0]);
}

test "reviewable local source content marks ELF and non-text binaries without changing text" {
    try std.testing.expectEqualStrings(
        "ELF executable binary (content is not displayed). Review the file's source and checksum before proceeding.",
        PkgbuildParser.reviewable_local_source_content("\x7fELFpayload"),
    );
    try std.testing.expectEqualStrings(
        "Binary file (content is not displayed). Review the file's source and checksum before proceeding.",
        PkgbuildParser.reviewable_local_source_content(&.{ 0, 159, 146, 150 }),
    );
    try std.testing.expectEqualStrings("#!/bin/sh\nexit 0", PkgbuildParser.reviewable_local_source_content("#!/bin/sh\nexit 0"));
}

test "replace_arithmetic: simple expression" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.replace_arithmetic("$((1+2))", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("3", result);
}

test "replace_arithmetic: multiple expressions" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.replace_arithmetic("$((1+2)) and $((3*4))", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("3 and 12", result);
}

test "replace_arithmetic: no expressions" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.replace_arithmetic("hello world", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "replace_arithmetic: empty expression" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.replace_arithmetic("$(()))", &vars);
    defer parser.allocator.free(result);
    // Empty $(( )) is skipped: emits '$' then appends remainder
    try std.testing.expectEqualStrings("$(()(()))", result);
}

test "replace_arithmetic: unclosed expression" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.replace_arithmetic("$((1+2", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("$((1+2", result);
}

test "replace_arithmetic: mixed text and expressions" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.replace_arithmetic("count=$((10*2)) items", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("count=20 items", result);
}

test "replace_command: no substitution" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.replace_command("hello world");
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "replace_command: single substitution stripped" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.replace_command("prefix $(echo hello) suffix");
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("prefix  suffix", result);
}

test "replace_command: empty substitution preserved" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.replace_command("test $() end");
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("test $() end", result);
}

test "replace_command: unclosed substitution preserved" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.replace_command("test $(unclosed");
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("test $(unclosed", result);
}

test "replace_command: multiple substitutions" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.replace_command("$(cmd1) and $(cmd2)");
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings(" and ", result);
}

test "replace_command: substitution at start and end" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try parser.replace_command("$(cmd) middle $(cmd2)");
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings(" middle ", result);
}

test "glob_matches: empty pattern and empty text" {
    try std.testing.expect(PkgbuildParser.glob_matches("", ""));
}

test "glob_matches: empty pattern non-empty text" {
    try std.testing.expectEqual(false, PkgbuildParser.glob_matches("", "abc"));
}

test "glob_matches: non-empty pattern empty text" {
    try std.testing.expectEqual(false, PkgbuildParser.glob_matches("abc", ""));
}

test "glob_matches: exact match" {
    try std.testing.expect(PkgbuildParser.glob_matches("hello", "hello"));
    try std.testing.expectEqual(false, PkgbuildParser.glob_matches("hello", "world"));
}

test "glob_matches: star matches all" {
    try std.testing.expect(PkgbuildParser.glob_matches("*", ""));
    try std.testing.expect(PkgbuildParser.glob_matches("*", "anything"));
}

test "glob_matches: star at start" {
    try std.testing.expect(PkgbuildParser.glob_matches("*.txt", "file.txt"));
    try std.testing.expect(PkgbuildParser.glob_matches("*.txt", ".txt"));
    try std.testing.expectEqual(false, PkgbuildParser.glob_matches("*.txt", "file.zip"));
}

test "glob_matches: question mark" {
    try std.testing.expect(PkgbuildParser.glob_matches("?.txt", "a.txt"));
    try std.testing.expectEqual(false, PkgbuildParser.glob_matches("?.txt", "ab.txt"));
    try std.testing.expectEqual(false, PkgbuildParser.glob_matches("?.txt", ".txt"));
}

test "glob_matches: mixed star and question mark" {
    try std.testing.expect(PkgbuildParser.glob_matches("src/?*.zig", "src/main.zig"));
    try std.testing.expectEqual(false, PkgbuildParser.glob_matches("src/?*.zig", "src/.zig"));
}

test "glob_matches: consecutive stars" {
    try std.testing.expect(PkgbuildParser.glob_matches("**", ""));
    try std.testing.expect(PkgbuildParser.glob_matches("**", "a/b/c"));
    try std.testing.expect(PkgbuildParser.glob_matches("a**b", "ab"));
    try std.testing.expect(PkgbuildParser.glob_matches("a**b", "axyzb"));
}

test "apply_parameter_expansion: empty glob returns value" {
    try std.testing.expectEqualStrings("hello", PkgbuildParser.apply_parameter_expansion("hello", "#", ""));
}

test "apply_parameter_expansion: unknown op returns value" {
    try std.testing.expectEqualStrings("hello", PkgbuildParser.apply_parameter_expansion("hello", "!", "h"));
}

test "apply_parameter_expansion: # removes shortest prefix" {
    // "hello.tar.gz" - shortest prefix matching "h" is "h"
    try std.testing.expectEqualStrings("ello.tar.gz", PkgbuildParser.apply_parameter_expansion("hello.tar.gz", "#", "h"));
    // shortest prefix matching "*." is ".gz" → no, it's "hello."
    try std.testing.expectEqualStrings("tar.gz", PkgbuildParser.apply_parameter_expansion("hello.tar.gz", "#", "*."));
}

test "apply_parameter_expansion: ## removes longest prefix" {
    // longest prefix matching "*." is "hello.tar."
    try std.testing.expectEqualStrings("gz", PkgbuildParser.apply_parameter_expansion("hello.tar.gz", "##", "*."));
    // longest prefix matching "h" is "h"
    try std.testing.expectEqualStrings("ello.tar.gz", PkgbuildParser.apply_parameter_expansion("hello.tar.gz", "##", "h"));
}

test "apply_parameter_expansion: % removes shortest suffix" {
    try std.testing.expectEqualStrings("hello.tar", PkgbuildParser.apply_parameter_expansion("hello.tar.gz", "%", ".gz"));
    try std.testing.expectEqualStrings("hello.tar", PkgbuildParser.apply_parameter_expansion("hello.tar.gz", "%", "*.gz"));
}

test "apply_parameter_expansion: %% removes longest suffix" {
    try std.testing.expectEqualStrings("hello", PkgbuildParser.apply_parameter_expansion("hello.tar.gz", "%%", ".tar.gz"));
    try std.testing.expectEqualStrings("hello.tar.g", PkgbuildParser.apply_parameter_expansion("hello.tar.gz", "%%", "z"));
}

test "apply_parameter_expansion: # no match returns value" {
    try std.testing.expectEqualStrings("hello", PkgbuildParser.apply_parameter_expansion("hello", "#", "xyz"));
}

test "apply_parameter_expansion: % no match returns value" {
    try std.testing.expectEqualStrings("hello", PkgbuildParser.apply_parameter_expansion("hello", "%", "xyz"));
}

test "apply_parameter_expansion: # with question mark" {
    try std.testing.expectEqualStrings("lo", PkgbuildParser.apply_parameter_expansion("hello", "#", "he?"));
}

test "replace_trim_expansion: hash removes shortest matching prefix" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try parser.replace_trim_expansion("${file#h}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("ello.tar.gz", result);
}

test "replace_trim_expansion: double hash removes longest matching prefix" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try parser.replace_trim_expansion("${file##*.}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("gz", result);
}

test "replace_trim_expansion: percent removes shortest matching suffix" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try parser.replace_trim_expansion("${file%.gz}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello.tar", result);
}

test "replace_trim_expansion: double percent removes longest matching suffix" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try parser.replace_trim_expansion("${file%%.*}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "replace_trim_expansion: multiple expansions" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try parser.replace_trim_expansion("${file#h} and ${file%.gz}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("ello.tar.gz and hello.tar", result);
}

test "replace_trim_expansion: no operation leaves input untouched" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try parser.replace_trim_expansion("${file}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("${file}", result);
}

test "replace_trim_expansion: variable not found keeps original text" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try parser.replace_trim_expansion("${unknown#p}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("${unknown#p}", result);
}

test "replace_trim_expansion: pattern with no match returns value unchanged" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try parser.replace_trim_expansion("${file#xyz}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello.tar.gz", result);
}

test "replace_trim_expansion: glob wildcards in pattern" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("path", "/usr/local/bin");
    const result = try parser.replace_trim_expansion("${path##*/}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("bin", result);
}

test "replace_trim_expansion: empty pattern matches empty string" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello");
    const result = try parser.replace_trim_expansion("${file#}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "replace_trim_expansion: unclosed expansion emits dollar sign" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try parser.replace_trim_expansion("${file#h", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("$", result);
}

test "replace_trim_expansion: text with no expansions is unchanged" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try parser.replace_trim_expansion("plain text, nothing here", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("plain text, nothing here", result);
}

test "replace_trim_expansion: literal text surrounding an expansion is preserved" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("ext", "tar.gz");
    const result = try parser.replace_trim_expansion("archive.${ext%.gz} ready", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("archive.tar ready", result);
}
test "find_glob_match: unanchored literal match in the middle" {
    const m = PkgbuildParser.find_glob_match("cd", "abcdef", 0, false, false);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 2), m.?.start);
    try std.testing.expectEqual(@as(usize, 4), m.?.end);
}

test "find_glob_match: unanchored no match returns null" {
    const m = PkgbuildParser.find_glob_match("xyz", "abcdef", 0, false, false);
    try std.testing.expect(m == null);
}

test "find_glob_match: unanchored leftmost match wins" {
    const m = PkgbuildParser.find_glob_match("a*b", "xaybzab", 0, false, false);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 1), m.?.start);
}

test "find_glob_match: unanchored greedy star takes longest span at leftmost start" {
    const m = PkgbuildParser.find_glob_match("a*b", "aXbYb", 0, false, false);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 0), m.?.start);
    try std.testing.expectEqual(@as(usize, 5), m.?.end);
}

test "find_glob_match: anchor_start only matches at position 0" {
    const m1 = PkgbuildParser.find_glob_match("ab", "abcabc", 0, true, false);
    try std.testing.expect(m1 != null);
    try std.testing.expectEqual(@as(usize, 0), m1.?.start);
    try std.testing.expectEqual(@as(usize, 2), m1.?.end);

    const m2 = PkgbuildParser.find_glob_match("bc", "abcabc", 0, true, false);
    try std.testing.expect(m2 == null);
}

test "find_glob_match: anchor_start refuses non-zero search_from" {
    const m = PkgbuildParser.find_glob_match("ab", "ababab", 2, true, false);
    try std.testing.expect(m == null);
}

test "find_glob_match: anchor_end only matches at end of string" {
    const m1 = PkgbuildParser.find_glob_match("bc", "abcabc", 0, false, true);
    try std.testing.expect(m1 != null);
    try std.testing.expectEqual(@as(usize, 4), m1.?.start);
    try std.testing.expectEqual(@as(usize, 6), m1.?.end);

    const m2 = PkgbuildParser.find_glob_match("ab", "abcabc", 0, false, true);
    try std.testing.expect(m2 == null);
}

test "find_glob_match: glob wildcards work in search" {
    const m = PkgbuildParser.find_glob_match("f?o", "xxfooxx", 0, false, false);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 2), m.?.start);
    try std.testing.expectEqual(@as(usize, 5), m.?.end);
}

test "find_glob_match: search_from skips earlier occurrences" {
    const m = PkgbuildParser.find_glob_match("ab", "ababab", 2, false, false);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 2), m.?.start);
}

test "find_glob_match: zero-width pattern matches empty span" {
    const m = PkgbuildParser.find_glob_match("", "abc", 0, false, false);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 0), m.?.start);
    try std.testing.expectEqual(@as(usize, 0), m.?.end);
}

test "apply_replacement: empty glob returns value unchanged" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.apply_replacement("hello", "", "", "X");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "apply_replacement: no match returns value unchanged" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.apply_replacement("hello", "", "xyz", "X");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "apply_replacement: unanchored mode replaces first match only" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.apply_replacement("foo bar foo", "", "foo", "X");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("X bar foo", result);
}

test "apply_replacement: slash mode replaces all matches" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.apply_replacement("foo bar foo", "/", "foo", "X");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("X bar X", result);
}

test "apply_replacement: hash mode replaces only if match is at the start" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.apply_replacement("foobar", "#", "foo", "X");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Xbar", result);
}

test "apply_replacement: hash mode does nothing if match is not at the start" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.apply_replacement("barfoo", "#", "foo", "X");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("barfoo", result);
}

test "apply_replacement: percent mode replaces only if match is at the end" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.apply_replacement("barfoo", "%", "foo", "X");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("barX", result);
}

test "apply_replacement: percent mode does nothing if match is not at the end" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.apply_replacement("foobar", "%", "foo", "X");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("foobar", result);
}

test "apply_replacement: glob wildcards in find pattern" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.apply_replacement("aXbYc", "/", "?", "_");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("_____", result);
}

test "apply_replacement: empty replacement deletes matches" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.apply_replacement("hello world", "/", "o", "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hell wrld", result);
}

test "apply_replacement: global replace with trailing star consumes greedily" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try parser.apply_replacement("aXaXaX", "/", "a*", "_");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("_", result);
}

test "replace_plain_var: braced variable found" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("name", "world");
    const result = try parser.replace_plain_var("hello ${name}!", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello world!", result);
}

test "replace_plain_var: bare variable found" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("name", "world");
    const result = try parser.replace_plain_var("hello $name!", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello world!", result);
}

test "replace_plain_var: braced variable not found keeps original text" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try parser.replace_plain_var("hello ${missing}!", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello ${missing}!", result);
}

test "replace_plain_var: bare variable not found keeps original text" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try parser.replace_plain_var("hello $missing!", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello $missing!", result);
}

test "replace_plain_var: multiple variables in one string" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("first", "foo");
    try vars.put("second", "bar");
    const result = try parser.replace_plain_var("${first}-$second", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("foo-bar", result);
}

test "replace_plain_var: unclosed brace is left untouched" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("name", "world");
    const result = try parser.replace_plain_var("hello ${name and more", &vars);
    defer parser.allocator.free(result);
    // No closing '}' -> the regex wouldn't match at all, so nothing is substituted
    // and the text passes through as-is (this also exercises the infinite-loop bug fix).
    try std.testing.expectEqualStrings("hello ${name and more", result);
}

test "replace_plain_var: trailing lone dollar sign" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try parser.replace_plain_var("price: $", &vars);
    defer parser.allocator.free(result);
    // '$' at the very end of the string, with nothing after it -- this also
    // exercises the infinite-loop bug fix (dollar+1 == input.len).
    try std.testing.expectEqualStrings("price: $", result);
}

test "replace_plain_var: dollar followed by non-word non-brace character" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try parser.replace_plain_var("cost: $5.00", &vars);
    defer parser.allocator.free(result);
    // '$' followed by a digit, which is neither '{' nor a word-start char
    // per is_word's definition used elsewhere -- passes through untouched.
    try std.testing.expectEqualStrings("cost: $5.00", result);
}

test "replace_plain_var: no dollar sign at all" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try parser.replace_plain_var("no variables here", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("no variables here", result);
}

test "replace_replacement_expansion: unanchored replaces first match only" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("greeting", "foo bar foo");
    const result = try parser.replace_replacement_expansion("${greeting/foo/X}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("X bar foo", result);
}

test "replace_replacement_expansion: double slash replaces all matches" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("greeting", "foo bar foo");
    const result = try parser.replace_replacement_expansion("${greeting//foo/X}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("X bar X", result);
}

test "replace_replacement_expansion: hash mode replaces only prefix match" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "foobar");
    const result = try parser.replace_replacement_expansion("${file/#foo/X}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("Xbar", result);
}

test "replace_replacement_expansion: percent mode replaces only suffix match" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "barfoo");
    const result = try parser.replace_replacement_expansion("${file/%foo/X}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("barX", result);
}

test "replace_replacement_expansion: missing replacement deletes the match" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("greeting", "hello world");
    const result = try parser.replace_replacement_expansion("${greeting/o/}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hell world", result);
}

test "replace_replacement_expansion: glob wildcards in find pattern" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "cat");
    const result = try parser.replace_replacement_expansion("${word/?at/dog}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("dog", result);
}

test "replace_replacement_expansion: variable not found keeps original text" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try parser.replace_replacement_expansion("${missing/foo/X}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("${missing/foo/X}", result);
}

test "replace_replacement_expansion: no slash after var name is not a match" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("name", "world");
    // no '/' -> not this expansion type; passed through untouched
    const result = try parser.replace_replacement_expansion("${name}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("${name}", result);
}

test "replace_replacement_expansion: unclosed expansion discards to end" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("greeting", "foo bar");
    const result = try parser.replace_replacement_expansion("${greeting/foo/X", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("$", result);
}

test "replace_replacement_expansion: multiple expansions in one string" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("first", "aaa");
    try vars.put("second", "bbb");
    const result = try parser.replace_replacement_expansion("${first/a/X} and ${second/b/Y}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("Xaa and Ybb", result);
}
test "replace_substring_expansion: offset only" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "hello world");
    const result = try parser.replace_substring_expansion("${word:6}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("world", result);
}

test "replace_substring_expansion: offset and length" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "hello world");
    const result = try parser.replace_substring_expansion("${word:0:5}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "replace_substring_expansion: negative offset counts from the end" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "hello world");
    const result = try parser.replace_substring_expansion("${word: -5}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("world", result);
}

test "replace_substring_expansion: negative length counts back from the end" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "hello world");
    const result = try parser.replace_substring_expansion("${word:0:-6}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "replace_substring_expansion: offset beyond string length clamps to empty" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "hi");
    const result = try parser.replace_substring_expansion("${word:10}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "replace_substring_expansion: variable not found keeps original text" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try parser.replace_substring_expansion("${missing:0:3}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("${missing:0:3}", result);
}

test "replace_substring_expansion: no colon after var name is not a match" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("name", "world");
    const result = try parser.replace_substring_expansion("${name}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("${name}", result);
}

test "replace_substring_expansion: unclosed expansion discards to end" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "hello world");
    const result = try parser.replace_substring_expansion("${word:0:5", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("$", result);
}

test "replace_substring_expansion: multiple expansions in one string" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("a", "abcdef");
    try vars.put("b", "123456");
    const result = try parser.replace_substring_expansion("${a:0:3} and ${b:3}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("abc and 456", result);
}

test "resolve_string: plain braced variable" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("name", "world");
    const result = try parser.resolve_string("hello ${name}!", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello world!", result);
}

test "resolve_string: plain bare variable" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("name", "world");
    const result = try parser.resolve_string("hello $name!", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello world!", result);
}

test "resolve_string: trim expansion" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try parser.resolve_string("${file#h} and ${file%.gz}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("ello.tar.gz and hello.tar", result);
}

test "resolve_string: replacement expansion" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("greeting", "foo bar foo");
    const result = try parser.resolve_string("${greeting//foo/X}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("X bar X", result);
}

test "resolve_string: substring expansion" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "hello world");
    const result = try parser.resolve_string("${word:6} and ${word:0:5}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("world and hello", result);
}

test "resolve_string: arithmetic expansion" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("count", "3");
    const result = try parser.resolve_string("total: $((count * 2))", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("total: 6", result);
}

test "resolve_string: command substitution is unresolved and emptied" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try parser.resolve_string("output: [$(echo hello)]", &vars);
    defer parser.allocator.free(result);
    // Command substitution can't be evaluated -> warns to stderr, replaced with "".
    try std.testing.expectEqualStrings("output: []", result);
}

test "resolve_string: variable not found in any step keeps original text" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try parser.resolve_string("${missing} and ${missing#x} and ${missing/a/b} and ${missing:0:1}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("${missing} and ${missing#x} and ${missing/a/b} and ${missing:0:1}", result);
}

test "resolve_string: combines multiple expansion types in one string" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("pkgname", "my-package");
    try vars.put("count", "2");
    const result = try parser.resolve_string(
        "${pkgname%-package}-$((count + 1)).tar.gz for $pkgname",
        &vars,
    );
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("my-3.tar.gz for my-package", result);
}

test "resolve_string: plain text with no expansions is unchanged" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try parser.resolve_string("nothing special here", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("nothing special here", result);
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
test "build_var_hashmap: parses double-quoted, single-quoted, and bare values" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = try parser.build_var_hashmap(
        "pkgname=\"my app\"\npkgver='1.0'\narch=x86_64\n",
    );
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try std.testing.expectEqualStrings("my app", vars.get("pkgname").?);
    try std.testing.expectEqualStrings("1.0", vars.get("pkgver").?);
    try std.testing.expectEqualStrings("x86_64", vars.get("arch").?);
}

test "build_var_hashmap: skips array declarations" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = try parser.build_var_hashmap("depends=(foo bar)\npkgname=app\n");
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try std.testing.expect(vars.get("depends") == null);
    try std.testing.expectEqualStrings("app", vars.get("pkgname").?);
}

test "build_var_hashmap: skips command substitution but keeps arithmetic" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = try parser.build_var_hashmap(
        "gitrev=$(git rev-parse HEAD)\ncount=$((1+2))\n",
    );
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try std.testing.expect(vars.get("gitrev") == null);
    try std.testing.expect(vars.get("count") != null);
}

test "build_var_hashmap: resolves chained variable references" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = try parser.build_var_hashmap("_a=1\n_b=$_a\n_c=$_b\n");
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try std.testing.expectEqualStrings("1", vars.get("_a").?);
    try std.testing.expectEqualStrings("1", vars.get("_b").?);
    try std.testing.expectEqualStrings("1", vars.get("_c").?);
}

test "build_var_hashmap: later redeclaration overwrites earlier value" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = try parser.build_var_hashmap("pkgver=1.0\npkgver=2.0\n");
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try std.testing.expectEqualStrings("2.0", vars.get("pkgver").?);
}

test "build_var_hashmap: empty content produces empty map" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = try parser.build_var_hashmap("");
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try std.testing.expectEqual(@as(usize, 0), vars.count());
}

test "build_var_hashmap: lines that do not match key=value are ignored" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = try parser.build_var_hashmap("# a comment\n\npkgname=app\n");
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try std.testing.expectEqual(@as(usize, 1), vars.count());
    try std.testing.expectEqualStrings("app", vars.get("pkgname").?);
}

test "inject_array_pkgname: no-op when vars already contains pkgname" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    const existing_key = try std.testing.allocator.dupe(u8, "pkgname");
    const existing_value = try std.testing.allocator.dupe(u8, "already-set");
    try vars.put(existing_key, existing_value);

    try parser.inject_array_pkgname("pkgname=(foo bar)\n", &vars);

    try std.testing.expectEqual(@as(usize, 1), vars.count());
    try std.testing.expectEqualStrings("already-set", vars.get("pkgname").?);
}

test "inject_array_pkgname: missing pkgname array leaves vars untouched" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try parser.inject_array_pkgname("pkgver=1.0\narch=(x86_64)\n", &vars);

    try std.testing.expect(!vars.contains("pkgname"));
}

test "inject_array_pkgname: empty pkgname array leaves vars untouched" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try parser.inject_array_pkgname("pkgname=()\n", &vars);

    try std.testing.expect(!vars.contains("pkgname"));
}

test "inject_array_pkgname: null selected_package_name uses names[0]" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try parser.inject_array_pkgname("pkgname=(alpha beta gamma)\n", &vars);

    try std.testing.expectEqualStrings("alpha", vars.get("pkgname").?);
}

test "inject_array_pkgname: null selected_package_name with single-element array" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try parser.inject_array_pkgname("pkgname=(solo)\n", &vars);

    try std.testing.expectEqualStrings("solo", vars.get("pkgname").?);
}

test "inject_array_pkgname: selected_package_name matching names[0] uses that name" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "alpha",
    };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try parser.inject_array_pkgname("pkgname=(alpha beta gamma)\n", &vars);

    try std.testing.expectEqualStrings("alpha", vars.get("pkgname").?);
}

test "inject_array_pkgname: selected_package_name matching a non-first name uses that name" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "beta",
    };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try parser.inject_array_pkgname("pkgname=(alpha beta gamma)\n", &vars);

    try std.testing.expectEqualStrings("beta", vars.get("pkgname").?);
}

test "inject_array_pkgname: selected_package_name matching the last name uses that name" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "gamma",
    };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try parser.inject_array_pkgname("pkgname=(alpha beta gamma)\n", &vars);

    try std.testing.expectEqualStrings("gamma", vars.get("pkgname").?);
}

test "inject_array_pkgname: selected_package_name with no match returns without inserting" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "delta",
    };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try parser.inject_array_pkgname("pkgname=(alpha beta gamma)\n", &vars);

    try std.testing.expect(!vars.contains("pkgname"));
}

test "inject_array_pkgname: selected_package_name match is case-sensitive" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "Beta",
    };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try parser.inject_array_pkgname("pkgname=(alpha beta gamma)\n", &vars);

    try std.testing.expect(!vars.contains("pkgname"));
}

test "inject_array_pkgname: stored value is independent of the selected_package_name buffer" {
    var name_buffer: [4]u8 = undefined;
    @memcpy(name_buffer[0..], "beta");

    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = name_buffer[0..],
    };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer PkgbuildParser.free_vars(std.testing.allocator, &vars);

    try parser.inject_array_pkgname("pkgname=(alpha beta gamma)\n", &vars);

    name_buffer[0] = 'x';

    try std.testing.expectEqualStrings("beta", vars.get("pkgname").?);
}

test "match_operator_len: greater-than returns length 1" {
    try std.testing.expectEqual(@as(?usize, 1), PkgbuildParser.match_operator_len(">", 0));
}

test "match_operator_len: less-than returns length 1" {
    try std.testing.expectEqual(@as(?usize, 1), PkgbuildParser.match_operator_len("<", 0));
}

test "match_operator_len: equal returns length 1" {
    try std.testing.expectEqual(@as(?usize, 1), PkgbuildParser.match_operator_len("=", 0));
}

test "match_operator_len: greater-than-or-equal returns length 2" {
    try std.testing.expectEqual(@as(?usize, 2), PkgbuildParser.match_operator_len(">=", 0));
}

test "match_operator_len: less-than-or-equal returns length 2" {
    try std.testing.expectEqual(@as(?usize, 2), PkgbuildParser.match_operator_len("<=", 0));
}

test "match_operator_len: greater-than followed by non-equals returns length 1" {
    try std.testing.expectEqual(@as(?usize, 1), PkgbuildParser.match_operator_len(">x", 0));
}

test "match_array_ref: valid array reference extracts name" {
    try std.testing.expectEqualStrings("arr", PkgbuildParser.match_array_ref("${arr[@]}").?);
}

test "match_array_ref: valid array reference with underscore" {
    try std.testing.expectEqualStrings("my_arr", PkgbuildParser.match_array_ref("${my_arr[@]}").?);
}

test "match_array_ref: name with digits is accepted" {
    try std.testing.expectEqualStrings("a1", PkgbuildParser.match_array_ref("${a1[@]}").?);
}

test "match_array_ref: single character name" {
    try std.testing.expectEqualStrings("x", PkgbuildParser.match_array_ref("${x[@]}").?);
}

test "match_array_ref: name containing hyphen returns null" {
    try std.testing.expectEqual(null, PkgbuildParser.match_array_ref("${my-arr[@]}"));
}

test "strip_version_constraint: no constraint returns full string" {
    try std.testing.expectEqualStrings("bash", PkgbuildParser.strip_version_constraint("bash"));
}

test "strip_version_constraint: greater-than-or-equal with bare variable strips to name" {
    try std.testing.expectEqualStrings("bash", PkgbuildParser.strip_version_constraint("bash>=$pkgver"));
}

test "strip_version_constraint: greater-than with bare variable strips to name" {
    try std.testing.expectEqualStrings("foo", PkgbuildParser.strip_version_constraint("foo>$ver"));
}

test "strip_version_constraint: less-than with bare variable strips to name" {
    try std.testing.expectEqualStrings("lib", PkgbuildParser.strip_version_constraint("lib<$pkgver"));
}

test "strip_version_constraint: less-than-or-equal with bare variable strips to name" {
    try std.testing.expectEqualStrings("bar", PkgbuildParser.strip_version_constraint("bar<=$ver"));
}

test "strip_version_constraint: equals with bare variable strips to name" {
    try std.testing.expectEqualStrings("dep", PkgbuildParser.strip_version_constraint("dep=$pkgver"));
}

test "strip_version_constraint: operator with braced variable strips to name" {
    try std.testing.expectEqualStrings("bash", PkgbuildParser.strip_version_constraint("bash>=${pkgver}"));
}

test "strip_version_constraint: operator with space before dollar returns full string" {
    try std.testing.expectEqualStrings("bash>= $pkgver", PkgbuildParser.strip_version_constraint("bash>= $pkgver"));
}

test "strip_version_constraint: operator not followed by dollar returns full string" {
    try std.testing.expectEqualStrings("bash>= 5.0", PkgbuildParser.strip_version_constraint("bash>= 5.0"));
}

test "strip_version_constraint: operator at end of string returns full string" {
    try std.testing.expectEqualStrings("bash>=", PkgbuildParser.strip_version_constraint("bash>="));
}

test "strip_version_constraint: empty input returns empty string" {
    try std.testing.expectEqualStrings("", PkgbuildParser.strip_version_constraint(""));
}

test "strip_version_constraint: dollar without operator returns full string" {
    try std.testing.expectEqualStrings("$pkgver", PkgbuildParser.strip_version_constraint("$pkgver"));
}

test "strip_version_constraint: operator followed by dollar but no variable name returns full string" {
    try std.testing.expectEqualStrings("foo>=$", PkgbuildParser.strip_version_constraint("foo>=$"));
}

test "strip_version_constraint: operator followed by dollar and non-word char returns full string" {
    try std.testing.expectEqualStrings("bar>$-bad", PkgbuildParser.strip_version_constraint("bar>$-bad"));
}

test "strip_dangling_operator: strips trailing greater-than-or-equal" {
    try std.testing.expectEqualStrings("bash", PkgbuildParser.strip_dangling_operator("bash>="));
}

test "strip_dangling_operator: strips trailing less-than-or-equal" {
    try std.testing.expectEqualStrings("foo", PkgbuildParser.strip_dangling_operator("foo<="));
}

test "strip_dangling_operator: strips trailing greater-than" {
    try std.testing.expectEqualStrings("bar", PkgbuildParser.strip_dangling_operator("bar>"));
}

test "strip_dangling_operator: strips trailing less-than" {
    try std.testing.expectEqualStrings("lib", PkgbuildParser.strip_dangling_operator("lib<"));
}

test "strip_dangling_operator: strips trailing equals" {
    try std.testing.expectEqualStrings("dep", PkgbuildParser.strip_dangling_operator("dep="));
}

test "strip_dangling_operator: no trailing operator returns unchanged" {
    try std.testing.expectEqualStrings("bash", PkgbuildParser.strip_dangling_operator("bash"));
}

test "strip_dangling_operator: empty input returns empty string" {
    try std.testing.expectEqualStrings("", PkgbuildParser.strip_dangling_operator(""));
}

test "strip_dangling_operator: lone greater-than-or-equal returns empty string" {
    try std.testing.expectEqualStrings("", PkgbuildParser.strip_dangling_operator(">="));
}

test "strip_dangling_operator: lone greater-than returns empty string" {
    try std.testing.expectEqualStrings("", PkgbuildParser.strip_dangling_operator(">"));
}

test "strip_dangling_operator: double equals strips only one" {
    try std.testing.expectEqualStrings("foo=", PkgbuildParser.strip_dangling_operator("foo=="));
}

test "strip_dangling_operator: operator in the middle is untouched" {
    try std.testing.expectEqualStrings("a>b", PkgbuildParser.strip_dangling_operator("a>b"));
}

test "resolve_variable_references: empty items returns empty slice" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var items = [_][]const u8{};
    const result = try parser.resolve_variable_references("", &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "resolve_variable_references: resolves plain variable" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("dep_name", "bash");

    var items = [_][]const u8{"${dep_name}"};
    const result = try parser.resolve_variable_references("", &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("bash", result[0]);
}

test "resolve_variable_references: strips dangling greater-than-or-equal" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var items = [_][]const u8{"bash>="};
    const result = try parser.resolve_variable_references("", &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("bash", result[0]);
}

test "resolve_variable_references: strips dangling less-than" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var items = [_][]const u8{"foo<"};
    const result = try parser.resolve_variable_references("", &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("foo", result[0]);
}

test "resolve_variable_references: strips dangling equals" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var items = [_][]const u8{"bar="};
    const result = try parser.resolve_variable_references("", &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("bar", result[0]);
}

test "resolve_variable_references: does not strip when no dangling operator" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var items = [_][]const u8{"bash"};
    const result = try parser.resolve_variable_references("", &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("bash", result[0]);
}

test "resolve_variable_references: multiple items resolved independently" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("a", "first");
    try vars.put("b", "second");

    var items = [_][]const u8{ "${a}", "${b}" };
    const result = try parser.resolve_variable_references("", &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("first", result[0]);
    try std.testing.expectEqualStrings("second", result[1]);
}

test "resolve_variable_references: array reference expands to multiple items" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const content = "mydep=(alpha beta gamma)\n";
    var items = [_][]const u8{"${mydep[@]}"};
    const result = try parser.resolve_variable_references(content, &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("alpha", result[0]);
    try std.testing.expectEqualStrings("beta", result[1]);
    try std.testing.expectEqualStrings("gamma", result[2]);
}

test "resolve_variable_references: strips dangling operator from array expanded items" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const content = "mydep=(x>= y<)\n";
    var items = [_][]const u8{"${mydep[@]}"};
    const result = try parser.resolve_variable_references(content, &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("x", result[0]);
    try std.testing.expectEqualStrings("y", result[1]);
}

test "resolve_variable_references: mixed plain and array items" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const content = "extra=(one two)\n";
    var items = [_][]const u8{ "static", "${extra[@]}" };
    const result = try parser.resolve_variable_references(content, &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("static", result[0]);
    try std.testing.expectEqualStrings("one", result[1]);
    try std.testing.expectEqualStrings("two", result[2]);
}

test "parse_array: simple bare items" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parser.parse_array("depends=(foo bar baz)\n", "depends");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("foo", items[0]);
    try std.testing.expectEqualStrings("bar", items[1]);
    try std.testing.expectEqualStrings("baz", items[2]);
}

test "parse_array: double and single quoted items" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parser.parse_array("depends=(\"foo bar\" 'baz qux')\n", "depends");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("foo bar", items[0]);
    try std.testing.expectEqualStrings("baz qux", items[1]);
}

test "parse_array: multiline array" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parser.parse_array(
        "depends=(\n  foo\n  bar\n  baz\n)\n",
        "depends",
    );
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("foo", items[0]);
    try std.testing.expectEqualStrings("bar", items[1]);
    try std.testing.expectEqualStrings("baz", items[2]);
}

test "parse_array: strips inline comments per line" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parser.parse_array(
        "depends=(\n  foo # needed for x\n  bar\n)\n",
        "depends",
    );
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("foo", items[0]);
    try std.testing.expectEqualStrings("bar", items[1]);
}

test "parse_array: closing paren inside quotes is not treated as array end" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parser.parse_array("depends=(\"has (paren) inside\" bar)\n", "depends");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("has (paren) inside", items[0]);
    try std.testing.expectEqualStrings("bar", items[1]);
}

test "parse_array: escaped characters are preserved literally" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parser.parse_array("depends=(foo\\ bar baz)\n", "depends");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("foo\\", items[0]);
    try std.testing.expectEqualStrings("bar", items[1]);
    try std.testing.expectEqualStrings("baz", items[2]);
}

test "parse_array: += appends to an existing declaration across matches" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parser.parse_array(
        "depends=(foo)\ndepends+=(bar)\n",
        "depends",
    );
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("foo", items[0]);
    try std.testing.expectEqualStrings("bar", items[1]);
}

test "parse_array: empty array returns no items" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parser.parse_array("depends=()\n", "depends");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "parse_array: variable name not present returns no items" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parser.parse_array("pkgname=app\n", "depends");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "parse_array: does not match variable name as a substring of another" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    // "makedepends" contains "depends" as a substring but shouldn't match
    // a search for "depends" specifically, since the regex requires the
    // full identifier to start right at the line start.
    const items = try parser.parse_array("makedepends=(foo)\n", "depends");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "parse_array: unterminated array consumes to end of content" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parser.parse_array("depends=(foo bar", "depends");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("foo", items[0]);
    try std.testing.expectEqualStrings("bar", items[1]);
}

test "parse_array: conditional block is skipped" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parser.parse_array(
        "if [ \"$CARCH\" = \"x86_64\" ]; then\ndepends=(foo)\nfi\n",
        "depends",
    );
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 0), items.len);
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
    var info = try parser.parser_content(content, null);
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
    var info = try parser.parser_content(content, null);
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
    var info = try parser.parser_content(content, null);
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
    var info = try parser.parser_content(content, null);
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
    var info = try parser.parser_content(content, null);
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
    var info = try parser.parser_content(content, base_dir);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), info.source.?.len);
    try std.testing.expectEqualStrings("fix.patch", info.source.?[0]);

    try std.testing.expectEqual(@as(usize, 1), info.local_source_files.?.len);
    try std.testing.expectEqualStrings("fix.patch", info.local_source_files.?[0]);

    try std.testing.expectEqualStrings("diff content here", info.local_source_contents.get("fix.patch").?);
}

test "parser_content: post_install falls back to extract_function_body when no install file" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\pkgname=myapp
        \\post_install() {
        \\  echo "installed"
        \\}
    ;
    var info = try parser.parser_content(content, null);
    // post_install here is a borrowed slice of `content` (extract_function_body
    // fallback path, not resolve_post_install) -- pass false, do NOT free it.
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(info.post_install != null);
    try std.testing.expectEqualStrings("echo \"installed\"", info.post_install.?);
}

test "parser_content: post_install resolved from install file" {
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
    var info = try parser.parser_content(content, base_dir);
    // post_install here IS owned (resolve_post_install succeeded) -- pass true.
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(info.post_install != null);
    try std.testing.expectEqualStrings("echo \"from install file\"", info.post_install.?);
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
    var info = try parser.parser_content(content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("flutter-3382-bin", info.pkg_name.?);
    try std.testing.expectEqual(@as(usize, 7), info.depends.?.len);
    try std.testing.expectEqualStrings("unionfs-fuse", info.depends.?[6]);
    try std.testing.expectEqualStrings("unionfs-fuse", info.parsed_depends.?[6].name);
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
    var info = try parser.parser_content(content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), info.depends.?.len);
    try std.testing.expectEqualStrings("glibc", info.depends.?[0]);
    try std.testing.expectEqualStrings("readline", info.depends.?[1]);
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
    var info = try parser.parser_content(content, base_dir);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("dms-shell-git.install", info.install_file.?);
    try std.testing.expectEqualStrings("echo \"installed\"", info.post_install.?);
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
    var info = try parser.parser_content(content, base_dir);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("rustdesk-bin", info.pkg_name.?);
    try std.testing.expectEqualStrings("1.4.9", info.pkg_version.?);
    try std.testing.expectEqualStrings("1", info.pkg_rel.?);
    try std.testing.expectEqualStrings("rustdesk-bin.install", info.install_file.?);
    try std.testing.expectEqualStrings("echo \"installed\"", info.post_install.?);

    try std.testing.expectEqual(@as(usize, 1), info.provides.?.len);
    try std.testing.expectEqualStrings("rustdesk", info.provides.?[0]);

    try std.testing.expectEqual(@as(usize, 3), info.depends.?.len);
    try std.testing.expectEqualStrings("gtk3", info.depends.?[0]);
    try std.testing.expectEqualStrings("xdotool", info.depends.?[1]);
    try std.testing.expectEqualStrings("libxcb", info.depends.?[2]);
}

test "parser_content: pkgbase with split pkgname array resolves per selected package" {
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
        "A style to bend Qt applications to look like they belong into GNOME Shell",
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

    try std.testing.expectEqual(@as(usize, 0), info_qt5.depends.?.len);

    try std.testing.expect(info_qt5.install_file == null);
    try std.testing.expect(info_qt5.post_install == null);

    var info_qt6 = try (PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "adwaita-qt6",
    }).parser_content(content, null);
    defer info_qt6.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("adwaita-qt6", info_qt6.pkg_name.?);
    try std.testing.expectEqualStrings("adwaita-qt", info_qt6.variables.get("pkgbase").?);
    try std.testing.expectEqualStrings(
        "A style to bend Qt applications to look like they belong into GNOME Shell",
        info_qt6.pkg_desc.?,
    );
    try std.testing.expectEqual(@as(usize, 1), info_qt6.source.?.len);
    try std.testing.expectEqualStrings(
        "https://github.com/FedoraQt/adwaita-qt/archive/1.4.2/adwaita-qt6-1.4.2.tar.gz",
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
    var info = try parser.parser_content(content, null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("demo-two.install", info.install_file.?);
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
        parser.parser_content(content, null),
    );
}

test "parser_content: empty content produces empty arrays and null scalars" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var info = try parser.parser_content("", null);
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(info.pkg_name == null);
    try std.testing.expectEqual(@as(usize, 0), info.depends.?.len);
    try std.testing.expectEqual(@as(usize, 0), info.source.?.len);
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
    // post_install came from resolve_post_install (install file existed) -> owned.
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

    // --- install file + post_install extracted from real file, unresolved literally ---
    try std.testing.expectEqualStrings("myapp.install", info.install_file.?);
    try std.testing.expect(info.post_install != null);
    // $pkgname inside the install file body is NOT substituted (matches C# behavior:
    // ResolvePostInstall/ExtractFunctionBody never runs variable resolution on file content).
    try std.testing.expectEqualStrings("echo \"Enjoy $pkgname!\"", info.post_install.?);
}
