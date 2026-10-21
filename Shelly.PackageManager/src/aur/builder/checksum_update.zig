//! Checksum generation and narrowly scoped PKGBUILD array edits.
const std = @import("std");
const checksums = @import("checksums.zig");
const sources = @import("sources.zig");
const source_spec = @import("source_spec.zig");
const steps = @import("steps.zig");
const PackageBuilder = @import("builder.zig").PackageBuilder;
const Operation = @import("operation_context").Operation;
const scan = @import("../../pkgbuild/parser/shell_scan.zig");
const functions = @import("../../pkgbuild/parser/function_body.zig");
const Parser = @import("../../pkgbuild/pkgbuild_parser.zig").PkgbuildParser;

pub const Replacements = std.StringHashMap([]const u8);
const algorithms = std.meta.tags(checksums.ChecksumAlgorithm);

fn family(name: []const u8, base: []const u8) bool {
    return std.mem.eql(u8, name, base) or
        (name.len > base.len + 1 and std.mem.startsWith(u8, name, base) and name[base.len] == '_');
}

fn checksumName(name: []const u8) bool {
    inline for (algorithms) |algorithm| {
        if (family(name, @tagName(algorithm) ++ "sums")) return true;
    }
    return family(name, "cksums");
}

/// The evaluated arrays retain all architecture suffixes, unlike Pkgbuild.source.
pub fn generate(self: *PackageBuilder, operation: *Operation, evaluated: *const steps.DynamicMetadataOverrides, content: []const u8) ![]u8 {
    const allocator = self.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var replacements = Replacements.init(scratch);
    var selected = [_]bool{false} ** algorithms.len;
    var names: std.ArrayList([]const u8) = .empty;
    var entries = evaluated.arrays.iterator();
    while (entries.next()) |entry| {
        const name = entry.key_ptr.*;
        if (family(name, "cksums")) return error.UnsupportedChecksumAlgorithm;
        inline for (algorithms, 0..) |algorithm, index| {
            if (family(name, @tagName(algorithm) ++ "sums")) {
                selected[index] = true;
                try replacements.put(name, try std.fmt.allocPrint(scratch, "{s}=()", .{name}));
            }
        }
        if (family(name, "source") and entry.value_ptr.len > 0) try names.append(scratch, name);
    }
    if (names.items.len == 0) return error.NoSourcesToUpdate;
    // Validate edit locations before downloading anything.
    const preflight = try render(allocator, self.io, content, &replacements);
    allocator.free(preflight);
    if (std.mem.indexOfScalar(bool, &selected, true) == null) selected[@intFromEnum(checksums.ChecksumAlgorithm.sha256)] = true;
    std.mem.sort([]const u8, names.items, {}, lessThan);
    // The shared cache is keyed by filename. Do not silently hash one
    // architecture's payload for another URL with the same cache name.
    var locations = std.StringHashMap([]const u8).init(scratch);
    for (names.items) |name| for (evaluated.arrays.get(name).?) |raw| {
        const source = try source_spec.ParsedSource.parse(scratch, raw);
        if (locations.get(source.name)) |location| {
            if (!std.mem.eql(u8, location, source.location)) return error.ConflictingChecksumSourceNames;
        } else try locations.put(source.name, source.location);
    };
    const staging = try std.fs.path.join(scratch, &.{ self.options.work_directory, "checksum-sources" });
    try std.Io.Dir.cwd().createDirPath(self.io, staging);
    defer std.Io.Dir.cwd().deleteTree(self.io, staging) catch {};
    for (names.items, 0..) |name, group_index| {
        const values = evaluated.arrays.get(name).?;
        const suffix = name["source".len..];
        var output: [algorithms.len]std.Io.Writer.Allocating = undefined;
        for (&output) |*writer| writer.* = .init(scratch);
        var sum_names: [algorithms.len][]const u8 = undefined;
        for (algorithms, 0..) |algorithm, a| {
            if (!selected[a]) continue;
            sum_names[a] = try std.fmt.allocPrint(scratch, "{s}sums{s}", .{ @tagName(algorithm), suffix });
            try output[a].writer.print("{s}=(", .{sum_names[a]});
        }
        for (values, 0..) |raw, index| {
            try operation.checkCancelled();
            var source = try source_spec.ParsedSource.parse(allocator, raw);
            defer source.deinit(allocator);
            const destination = try std.fmt.allocPrint(scratch, "{s}/{d}-{d}", .{ staging, group_index, index });
            try sources.acquireSource(self, operation, source, destination);
            const moving = source.kind == .git and (source.reference == null or source.reference.?.kind == .branch);
            var prepared = source_spec.PreparedSource{ .source = source, .destination = destination, .index = index };
            const archive_path = if (source.kind == .git and !moving) try sources.gitChecksumArchive(self, operation, &prepared) else null;
            defer if (archive_path) |path| {
                std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
                allocator.free(path);
            };
            for (algorithms, 0..) |algorithm, a| {
                if (!selected[a]) continue;
                const previous = evaluated.arrays.get(sum_names[a]) orelse &.{};
                const skip = moving or (index < previous.len and std.ascii.eqlIgnoreCase(previous[index], "SKIP"));
                const digest = if (skip) "SKIP" else try checksums.generateFileHash(scratch, self.io, archive_path orelse destination, algorithm);
                if (index > 0) try output[a].writer.writeAll("\n            ");
                try output[a].writer.print("'{s}'", .{digest});
            }
        }
        for (algorithms, 0..) |_, a| {
            if (!selected[a]) continue;
            try output[a].writer.writeByte(')');
            try replacements.put(sum_names[a], output[a].written());
        }
    }
    return render(allocator, self.io, content, &replacements);
}

/// Check that sourcing the edited file actually exposes the generated sums.
/// This avoids another download/hash pass and catches eval/unset overrides.
pub fn verifyRendered(allocator: std.mem.Allocator, io: std.Io, content: []const u8, before: *const steps.DynamicMetadataOverrides, after: *const steps.DynamicMetadataOverrides) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var replacements = Replacements.init(scratch);
    var entries = after.arrays.iterator();
    while (entries.next()) |entry| {
        const name = entry.key_ptr.*;
        if (family(name, "source")) {
            const old = before.arrays.get(name) orelse return error.UnsupportedChecksumAssignment;
            if (!sameValues(old, entry.value_ptr.*)) return error.UnsupportedChecksumAssignment;
        }
        if (!checksumName(name)) continue;
        var output: std.Io.Writer.Allocating = .init(scratch);
        try output.writer.print("{s}=(", .{name});
        for (entry.value_ptr.*, 0..) |value, index| {
            // Digests contain only hex digits or the literal SKIP. Reject
            // shell syntax rather than interpolating evaluated arbitrary text.
            if (!std.mem.eql(u8, value, "SKIP")) {
                if (value.len == 0) return error.UnsupportedChecksumAssignment;
                for (value) |c| if (!std.ascii.isHex(c)) return error.UnsupportedChecksumAssignment;
            }
            if (index > 0) try output.writer.writeAll("\n            ");
            try output.writer.print("'{s}'", .{value});
        }
        try output.writer.writeByte(')');
        try replacements.put(name, output.written());
    }
    var previous = before.arrays.keyIterator();
    while (previous.next()) |name| if (family(name.*, "source") and !after.arrays.contains(name.*)) return error.UnsupportedChecksumAssignment;
    const rendered = try render(allocator, io, content, &replacements);
    defer allocator.free(rendered);
    if (!std.mem.eql(u8, content, rendered)) return error.UnsupportedChecksumAssignment;
}

fn sameValues(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn quotedEnd(content: []const u8, start: usize) error{UnsupportedChecksumAssignment}!usize {
    const quote = content[start];
    var i = start + 1;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\\' and quote != '\'') {
            i += 1;
            continue;
        }
        if (quote == '"' and std.mem.startsWith(u8, content[i..], "$(")) {
            i = (try arrayEnd(content, i + 2)) - 1;
            continue;
        }
        if (content[i] == quote) return i + 1;
    }
    return error.UnsupportedChecksumAssignment;
}

fn arrayEnd(content: []const u8, start: usize) error{UnsupportedChecksumAssignment}!usize {
    var depth: usize = 1;
    var i = start;
    while (i < content.len) {
        switch (content[i]) {
            '\'', '"', '`' => {
                i = try quotedEnd(content, i);
                continue;
            },
            '\\' => {
                i += 2;
                continue;
            },
            '#' => if (i == start or std.ascii.isWhitespace(content[i - 1])) {
                i = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
                continue;
            },
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
        i += 1;
    }
    return error.UnsupportedChecksumAssignment;
}

/// Recognize standalone top-level assignments; quoted text, heredocs and
/// function bodies are opaque. Conditional or computed edits fail closed.
pub fn render(allocator: std.mem.Allocator, io: std.Io, content: []const u8, replacements: *const Replacements) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var emitted = std.StringHashMap(void).init(allocator);
    defer emitted.deinit();
    var pending: std.ArrayList(scan.heredoc_declaration) = .empty;
    defer {
        for (pending.items) |doc| allocator.free(doc.delimiter);
        pending.deinit(allocator);
    }
    const parser = Parser{ .allocator = allocator, .io = io };
    var brace_depth: usize = 0;
    var copied: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (c == '\n') {
            i += 1;
            for (pending.items) |doc| {
                var found = false;
                while (i < content.len) {
                    const end = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
                    const line = if (doc.strip_tabs) std.mem.trimStart(u8, content[i..end], "\t") else content[i..end];
                    i = @min(end + 1, content.len);
                    if (std.mem.eql(u8, line, doc.delimiter)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return error.UnsupportedChecksumAssignment;
            }
            for (pending.items) |doc| allocator.free(doc.delimiter);
            pending.clearRetainingCapacity();
            line_start = i;
            continue;
        }
        if (c == '\\') {
            i = @min(i + 2, content.len);
            continue;
        }
        if (c == '\'' or c == '"' or c == '`') {
            i = try quotedEnd(content, i);
            continue;
        }
        if (c == '#' and (i == 0 or std.ascii.isWhitespace(content[i - 1]) or content[i - 1] == ';')) {
            i = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
            continue;
        }
        if (std.mem.startsWith(u8, content[i..], "<<") and !std.mem.startsWith(u8, content[i..], "<<<")) {
            const doc = try scan.parse_heredoc(allocator, content, i + 2) orelse return error.UnsupportedChecksumAssignment;
            pending.append(allocator, doc) catch |err| {
                allocator.free(doc.delimiter);
                return err;
            };
            i = doc.end;
            continue;
        }
        if (std.mem.startsWith(u8, content[i..], "$(")) {
            i = try arrayEnd(content, i + 2);
            continue;
        }
        if (c == '(') {
            i = try arrayEnd(content, i + 1);
            continue;
        }
        if (c == '{' and (i == 0 or std.ascii.isWhitespace(content[i - 1])) and i + 1 < content.len and std.ascii.isWhitespace(content[i + 1])) brace_depth += 1;
        if (c == '}' and brace_depth > 0 and (i == 0 or std.ascii.isWhitespace(content[i - 1]))) brace_depth -= 1;
        if (!(std.ascii.isAlphabetic(c) or c == '_') or (i > 0 and scan.is_word(content[i - 1]))) {
            i += 1;
            continue;
        }
        const end_name = scan.scan_word_chars(content, i);
        var name = content[i..end_name];
        var cursor = end_name;
        const standalone = std.mem.trim(u8, content[line_start..i], " \t").len == 0;
        // Skip complete shell functions before inspecting their contents.
        if (standalone) {
            if (std.mem.eql(u8, name, "function")) {
                const start_name = scan.skip_ws(content, cursor);
                cursor = scan.scan_word_chars(content, start_name);
                name = content[start_name..cursor];
            }
            const after = scan.skip_ws(content, cursor);
            if (after < content.len and (content[after] == '(' or content[after] == '{')) {
                if (try functions.function_end(content[line_start..], name)) |end| {
                    i = line_start + end;
                    line_start = (std.mem.lastIndexOfScalar(u8, content[0..i], '\n') orelse 0) + 1;
                    continue;
                }
            }
        }
        cursor = end_name;
        if (cursor < content.len and content[cursor] == '+') cursor += 1;
        if (cursor >= content.len or content[cursor] != '=') {
            i = end_name;
            continue;
        }
        cursor += 1;
        if (!checksumName(name)) {
            // Arrays may contain text resembling checksum declarations.
            i = if (cursor < content.len and content[cursor] == '(') try arrayEnd(content, cursor + 1) else cursor;
            continue;
        }
        if (brace_depth > 0 or !standalone or try scan.is_inside_conditional_block(parser, content, i) or cursor >= content.len or content[cursor] != '(')
            return error.UnsupportedChecksumAssignment;
        const end = try arrayEnd(content, cursor + 1);
        const line_end = std.mem.indexOfScalarPos(u8, content, end, '\n') orelse content.len;
        const tail = std.mem.trim(u8, content[end..line_end], " \t\r");
        if (tail.len > 0 and tail[0] != '#') return error.UnsupportedChecksumAssignment;
        const replacement = replacements.get(name) orelse return error.UnsupportedChecksumAssignment;
        try output.writer.writeAll(content[copied..i]);
        if (!emitted.contains(name)) {
            try output.writer.writeAll(replacement);
            try emitted.put(name, {});
        }
        copied = end;
        i = end;
        line_start = (std.mem.lastIndexOfScalar(u8, content[0..i], '\n') orelse 0) + 1;
    }
    try output.writer.writeAll(content[copied..]);
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(allocator);
    var keys = replacements.keyIterator();
    while (keys.next()) |key| if (!emitted.contains(key.*)) {
        try missing.append(allocator, key.*);
    };
    std.mem.sort([]const u8, missing.items, {}, lessThan);
    if (missing.items.len > 0 and content.len > 0 and content[content.len - 1] != '\n') try output.writer.writeByte('\n');
    for (missing.items) |name| try output.writer.print("{s}\n", .{replacements.get(name).?});
    return output.toOwnedSlice();
}

test "updpkgsums editor preserves shell text and replaces multiline appended arrays" {
    const allocator = std.testing.allocator;
    const input =
        "# sums\npkgver=1\n" ++
        "text='\nsha256sums=(quoted)\n'\n" ++
        "cat <<'DOC'\nsha256sums=(heredoc)\nDOC\n" ++
        "helper() {\nsha256sums=(function)\n}\n" ++
        "value=$(\nsha256sums=(substitution)\n)\n" ++
        "  sha256sums=(\n 'old' # Don't count ) here\n) # keep\n" ++
        "sha256sums+=('extra')\npackage() { :; }\n";
    var replacements = Replacements.init(allocator);
    defer replacements.deinit();
    try replacements.put("sha256sums", "sha256sums=('new' 'SKIP')");
    try replacements.put("sha256sums_aarch64", "sha256sums_aarch64=('arch')");
    const result = try render(allocator, std.testing.io, input, &replacements);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "text='\nsha256sums=(quoted)\n'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "cat <<'DOC'\nsha256sums=(heredoc)\nDOC") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "helper() {\nsha256sums=(function)\n}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "  sha256sums=('new' 'SKIP') # keep\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "value=$(\nsha256sums=(substitution)\n)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "extra") == null);
    const again = try render(allocator, std.testing.io, result, &replacements);
    defer allocator.free(again);
    try std.testing.expectEqualStrings(result, again);
}

test "updpkgsums editor rejects ambiguous checksum assignments" {
    var replacements = Replacements.init(std.testing.allocator);
    defer replacements.deinit();
    try replacements.put("sha256sums", "sha256sums=('new')");
    for ([_][]const u8{
        "if true; then\nsha256sums=('old')\nfi\n",
        "true && sha256sums=('old')\n",
        "sha256sums=('old'); echo next\n",
        "sha256sums=old\n",
        "sha256sums=(unterminated\n",
        "{\nsha256sums=('old')\n}\n",
    }) |input| try std.testing.expectError(error.UnsupportedChecksumAssignment, render(std.testing.allocator, std.testing.io, input, &replacements));
}
