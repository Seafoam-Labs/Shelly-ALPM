const std = @import("std");
const pkgbuild = @import("pkgbuild_parser.zig");
const shared_validator = @import("shared_validtor.zig");

pub const HomographValidator = struct {
    allocator: std.mem.Allocator,

    pub fn validate(self: HomographValidator, pkg_build: pkgbuild.Pkgbuild) !shared_validator.ValidationResult {
        var result = shared_validator.ValidationResult{
            .has_findings = false,
            .findings = std.ArrayList(shared_validator.ValidationFinding).empty,
        };

        try self.scan(pkg_build.pkg_name, "pkgname", &result);
        if (pkg_build.depends) |deps| for (deps) |dep| try self.scan(dep, "depends", &result);
        if (pkg_build.make_depends) |deps| for (deps) |dep| try self.scan(dep, "makedepends", &result);
        try self.scan(pkg_build.url, "url", &result);
        if (pkg_build.source) |srcs| for (srcs) |src| try self.scan(src, "source", &result);

        return result;
    }

    pub fn validate_field(self: HomographValidator, value: ?[]const u8, field: []const u8) !shared_validator.ValidationResult {
        var result = shared_validator.ValidationResult{
            .has_findings = false,
            .findings = std.ArrayList(shared_validator.ValidationFinding).empty,
        };

        try self.scan(value, field, &result);

        return result;
    }

    const script_class = enum(i32) { latin, cyrillic, greek, armenian, other };

    fn scan(self: HomographValidator, value: ?[]const u8, hook: []const u8, result: *shared_validator.ValidationResult) !void {
        if (value == null) return;
        const v = value.?;
        if (std.mem.trim(u8, v, " \t\r\n").len == 0) return;

        if (try is_plain_ascii(v)) return;

        // 1. Zero-width / bidi / other invisible or control characters.
        const hidden = try find_hidden_character(self, v);
        if (hidden) |h| {
            defer self.allocator.free(h);
            const matched = try describe(self, v);
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "'{s}' in {s} contains a hidden/invisible character ({s}) - this can be used to spoof a trusted name (homograph attack).",
                .{ matched, hook, h },
            );
            const dup_hook = try self.allocator.dupe(u8, hook);
            try result.findings.append(self.allocator, .{ .hook = dup_hook, .tool = "<homograph>", .severity = shared_validator.ValidationSeverity.critical, .matched_line = matched, .message = msg });

            result.has_findings = true;

            return;
        }

        // 2. Mixed-script detection.

        var scripts = try collect_scripts(self, v);
        defer scripts.deinit();
        if (scripts.count() > 1 and scripts.contains(.latin)) {
            _ = scripts.remove(.latin);
            var script_names: std.ArrayList([]const u8) = .empty;
            defer script_names.deinit(self.allocator);

            var iter = scripts.keyIterator();
            while (iter.next()) |key| {
                const name = switch (key.*) {
                    .cyrillic => "Cyrillic",
                    .greek => "Greek",
                    .armenian => "Armenian",
                    .other => "Other",
                    .latin => unreachable,
                };
                try script_names.append(self.allocator, name);
            }
            const scripts_str = try std.mem.join(self.allocator, ", ", script_names.items);
            defer self.allocator.free(scripts_str);
            const skel = try skeleton(self, v);
            defer self.allocator.free(skel);
            const matched = try describe(self, v);
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "'{s}' in {s} mixes Latin with another script ({s}) - possible homograph spoofing (skeleton '{s}').",
                .{ matched, hook, scripts_str, skel },
            );
            result.has_findings = true;
            const dup_hook = try self.allocator.dupe(u8, hook);
            try result.findings.append(self.allocator, .{ .hook = dup_hook, .tool = "<homograph>", .severity = shared_validator.ValidationSeverity.critical, .matched_line = matched, .message = msg });

            return;
        }

        // 3. Fullwidth characters U+FF01..U+FF5E.

        var it = (try std.unicode.Utf8View.init(v)).iterator();
        var has_fullwidth = false;
        while (it.nextCodepoint()) |cp| {
            if (cp >= 0xFF01 and cp <= 0xFF5E) {
                has_fullwidth = true;
                break;
            }
        }
        if (has_fullwidth) {
            const matched = try describe(self, v);
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "'{s}' in {s} uses fullwidth characters that resemble ASCII - possible homograph spoofing.",
                .{ matched, hook },
            );
            result.has_findings = true;
            const dup_hook = try self.allocator.dupe(u8, hook);
            try result.findings.append(self.allocator, .{ .hook = dup_hook, .tool = "<homograph>", .severity = shared_validator.ValidationSeverity.critical, .matched_line = matched, .message = msg });

            return;
        }

        // 4. Confusable skeleton.

        const skel = try skeleton(self, v);
        defer self.allocator.free(skel);
        if (!std.mem.eql(u8, skel, v) and try is_plain_ascii(skel)) {
            const matched = try describe(self, v);
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "'{s}' in {s} contains non-ASCII characters that resemble ASCII (skeleton '{s}') - possible homograph spoofing.",
                .{ matched, hook, skel },
            );
            result.has_findings = true;
            const dup_hook = try self.allocator.dupe(u8, hook);
            try result.findings.append(self.allocator, .{ .hook = dup_hook, .tool = "<homograph>", .severity = shared_validator.ValidationSeverity.critical, .matched_line = matched, .message = msg });
        }
    }

    fn is_plain_ascii(value: []const u8) !bool {
        for (value) |char| {
            if (char > 127 or std.ascii.isControl(char)) return false;
        }
        return true;
    }

    fn find_hidden_character(self: HomographValidator, value: []const u8) !?[]const u8 {
        var buf: [8]u8 = undefined;

        var it = (try std.unicode.Utf8View.init(value)).iterator();
        while (it.nextCodepoint()) |cp| {
            const is_hidden =
                cp == 0x200B or cp == 0x200C or cp == 0x200D or cp == 0xFEFF or
                (cp >= 0x202A and cp <= 0x202E) or
                (cp >= 0x2066 and cp <= 0x2069) or
                (cp != '\t' and cp != '\n' and cp != '\r' and isControl21(cp));

            if (is_hidden) {
                const formatted = try std.fmt.bufPrint(&buf, "U+{X:0>4}", .{cp});
                return try self.allocator.dupe(u8, formatted);
            }
        }
        return null;
    }

    fn isControl21(cp: u21) bool {
        if (cp > 0xFF) return false;
        const b: u8 = @intCast(cp);
        return std.ascii.isControl(b) or (b >= 0x80 and b <= 0x9F);
    }

    fn collect_scripts(self: HomographValidator, value: []const u8) !std.hash_map.AutoHashMap(script_class, void) {
        var set = std.hash_map.AutoHashMap(script_class, void).init(self.allocator);

        var it = (try std.unicode.Utf8View.init(value)).iterator();
        while (it.nextCodepoint()) |cp| {
            const cls = classify(cp);
            if (cls) |c| {
                try set.put(c, {});
            }
        }

        return set;
    }

    fn classify(cp: u21) ?script_class {
        if ((cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or
            (cp >= 0x00C0 and cp <= 0x024F)) // Latin-1 Supplement / Extended-A/B
        {
            return .latin;
        }
        if (cp >= 0x0370 and cp <= 0x03FF) return .greek;
        if (cp >= 0x0400 and cp <= 0x04FF) return .cyrillic;
        if (cp >= 0x0530 and cp <= 0x058F) return .armenian;
        return .other;
    }

    fn skeleton(self: HomographValidator, value: []const u8) ![]const u8 {
        const confusables = [_]struct { u21, []const u8 }{
            // Cyrillic look-alikes
            .{ 0x0430, "a" }, .{ 0x0435, "e" }, .{ 0x043E, "o" }, .{ 0x0440, "p" },
            .{ 0x0441, "c" }, .{ 0x0445, "x" }, .{ 0x0443, "y" }, .{ 0x0456, "i" },
            .{ 0x0458, "j" }, .{ 0x0455, "s" }, .{ 0x04BB, "h" }, .{ 0x0501, "d" },
            .{ 0x0410, "A" }, .{ 0x0412, "B" }, .{ 0x0415, "E" }, .{ 0x041A, "K" },
            .{ 0x041C, "M" }, .{ 0x041D, "H" }, .{ 0x041E, "O" }, .{ 0x0420, "P" },
            .{ 0x0421, "C" }, .{ 0x0422, "T" }, .{ 0x0425, "X" },
            // Greek look-alikes
            .{ 0x03BF, "o" },
            .{ 0x03B1, "a" }, .{ 0x03B5, "e" }, .{ 0x03C1, "p" }, .{ 0x03BD, "v" },
            .{ 0x03B9, "i" }, .{ 0x03BA, "k" }, .{ 0x039F, "O" }, .{ 0x0391, "A" },
            .{ 0x0392, "B" }, .{ 0x0395, "E" }, .{ 0x0397, "H" }, .{ 0x0399, "I" },
            .{ 0x039A, "K" }, .{ 0x039C, "M" }, .{ 0x039D, "N" }, .{ 0x03A1, "P" },
            .{ 0x03A4, "T" }, .{ 0x03A7, "X" },
        };

        var sb: std.ArrayList(u8) = .empty;
        errdefer sb.deinit(self.allocator);

        var it = (try std.unicode.Utf8View.init(value)).iterator();
        while (it.nextCodepoint()) |cp| {
            const ascii = for (confusables) |entry| {
                if (entry[0] == cp) break entry[1];
            } else null;

            if (ascii) |a| {
                try sb.appendSlice(self.allocator, a);
            } else {
                var buf: [8]u8 = undefined;
                const len = try std.unicode.utf8Encode(cp, &buf);
                try sb.appendSlice(self.allocator, buf[0..len]);
            }
        }

        return try sb.toOwnedSlice(self.allocator);
    }

    fn describe(self: HomographValidator, value: []const u8) ![]const u8 {
        var sb: std.ArrayList(u8) = .empty;
        errdefer sb.deinit(self.allocator);

        var it = (try std.unicode.Utf8View.init(value)).iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp <= 0x7F and !std.ascii.isControl(@intCast(cp))) {
                try sb.append(self.allocator, @intCast(cp));
            } else {
                var buf: [10]u8 = undefined;
                const formatted = try std.fmt.bufPrint(&buf, "[U+{X:0>4}]", .{cp});
                try sb.appendSlice(self.allocator, formatted);
            }
        }

        return try sb.toOwnedSlice(self.allocator);
    }
};

test "is_plain_ascii - valid ascii" {
    try std.testing.expect(try HomographValidator.is_plain_ascii("hello world"));
    try std.testing.expect(try HomographValidator.is_plain_ascii("Shelly-ALPM 1.0"));
    try std.testing.expect(try HomographValidator.is_plain_ascii("abc123!@#"));
    try std.testing.expect(try HomographValidator.is_plain_ascii("")); // empty string
    try std.testing.expect(try HomographValidator.is_plain_ascii(" ")); // space is valid (32)
    try std.testing.expect(try HomographValidator.is_plain_ascii("~")); // tilde is 126, valid
}

test "is_plain_ascii - extended bytes (>127)" {
    try std.testing.expectEqual(false, try HomographValidator.is_plain_ascii("\xc3\xbc")); // ü (UTF-8)
    try std.testing.expectEqual(false, try HomographValidator.is_plain_ascii(&[_]u8{128}));
    try std.testing.expectEqual(false, try HomographValidator.is_plain_ascii(&[_]u8{255}));
    try std.testing.expectEqual(false, try HomographValidator.is_plain_ascii("caf\xeb")); // café
}

test "is_plain_ascii - control characters" {
    try std.testing.expectEqual(false, try HomographValidator.is_plain_ascii("\n"));
    try std.testing.expectEqual(false, try HomographValidator.is_plain_ascii("\t"));
    try std.testing.expectEqual(false, try HomographValidator.is_plain_ascii("\r"));
    try std.testing.expectEqual(false, try HomographValidator.is_plain_ascii(&[_]u8{0})); // NUL
    try std.testing.expectEqual(false, try HomographValidator.is_plain_ascii(&[_]u8{127})); // DEL
}

test "find_hidden_character - clean ascii returns null" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.find_hidden_character("hello world");
    try std.testing.expect(result == null);
}

test "find_hidden_character - clean unicode returns null" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.find_hidden_character("héllo wörld");
    try std.testing.expect(result == null);
}

test "find_hidden_character - zero width space" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.find_hidden_character("hello\u{200B}world");
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("U+200B", result.?);
}

test "find_hidden_character - zero width non-joiner and joiner" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };

    const r1 = try validator.find_hidden_character("a\u{200C}b");
    try std.testing.expect(r1 != null);
    defer std.testing.allocator.free(r1.?);
    try std.testing.expectEqualStrings("U+200C", r1.?);

    const r2 = try validator.find_hidden_character("a\u{200D}b");
    try std.testing.expect(r2 != null);
    defer std.testing.allocator.free(r2.?);
    try std.testing.expectEqualStrings("U+200D", r2.?);
}

test "find_hidden_character - BOM" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.find_hidden_character("\u{FEFF}text");
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("U+FEFF", result.?);
}

test "find_hidden_character - bidi override range boundaries" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };

    // lower bound of range: U+202A
    const r1 = try validator.find_hidden_character("\u{202A}text");
    try std.testing.expect(r1 != null);
    defer std.testing.allocator.free(r1.?);
    try std.testing.expectEqualStrings("U+202A", r1.?);

    // upper bound of range: U+202E
    const r2 = try validator.find_hidden_character("\u{202E}text");
    try std.testing.expect(r2 != null);
    defer std.testing.allocator.free(r2.?);
    try std.testing.expectEqualStrings("U+202E", r2.?);

    // just outside the range should NOT be flagged by this branch
    const r3 = try validator.find_hidden_character("\u{2029}text");
    try std.testing.expect(r3 == null);
}

test "find_hidden_character - bidi isolate range boundaries" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };

    const r1 = try validator.find_hidden_character("\u{2066}text");
    try std.testing.expect(r1 != null);
    defer std.testing.allocator.free(r1.?);
    try std.testing.expectEqualStrings("U+2066", r1.?);

    const r2 = try validator.find_hidden_character("\u{2069}text");
    try std.testing.expect(r2 != null);
    defer std.testing.allocator.free(r2.?);
    try std.testing.expectEqualStrings("U+2069", r2.?);
}

test "find_hidden_character - tab, newline, CR are allowed" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    try std.testing.expect(try validator.find_hidden_character("a\tb") == null);
    try std.testing.expect(try validator.find_hidden_character("a\nb") == null);
    try std.testing.expect(try validator.find_hidden_character("a\rb") == null);
}

test "find_hidden_character - C0 control character" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.find_hidden_character("a\x01b");
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("U+0001", result.?);
}

test "find_hidden_character - DEL character" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.find_hidden_character("a\x7Fb");
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("U+007F", result.?);
}

test "find_hidden_character - C1 control character" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.find_hidden_character("a\u{0085}b"); // NEL, within 0x80-0x9F
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("U+0085", result.?);
}

test "find_hidden_character - returns first hidden character found" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.find_hidden_character("a\u{200B}b\u{FEFF}c");
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("U+200B", result.?);
}

test "find_hidden_character - invalid utf8 returns error" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    try std.testing.expectError(error.InvalidUtf8, validator.find_hidden_character("\xff\xfe"));
}

test "find_hidden_character - empty string returns null" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.find_hidden_character("");
    try std.testing.expect(result == null);
}

test "classify - basic latin ascii letters" {
    try std.testing.expectEqual(HomographValidator.script_class.latin, HomographValidator.classify('A').?);
    try std.testing.expectEqual(HomographValidator.script_class.latin, HomographValidator.classify('Z').?);
    try std.testing.expectEqual(HomographValidator.script_class.latin, HomographValidator.classify('a').?);
    try std.testing.expectEqual(HomographValidator.script_class.latin, HomographValidator.classify('z').?);
}

test "classify - latin-1 supplement / extended range" {
    try std.testing.expectEqual(HomographValidator.script_class.latin, HomographValidator.classify(0x00C0).?); // À, lower bound
    try std.testing.expectEqual(HomographValidator.script_class.latin, HomographValidator.classify(0x024F).?); // ɏ, upper bound
    try std.testing.expectEqual(HomographValidator.script_class.latin, HomographValidator.classify(0x00E9).?); // é
}

test "classify - greek range" {
    try std.testing.expectEqual(HomographValidator.script_class.greek, HomographValidator.classify(0x0370).?); // lower bound
    try std.testing.expectEqual(HomographValidator.script_class.greek, HomographValidator.classify(0x03FF).?); // upper bound
    try std.testing.expectEqual(HomographValidator.script_class.greek, HomographValidator.classify(0x03B1).?); // α
}

test "classify - cyrillic range" {
    try std.testing.expectEqual(HomographValidator.script_class.cyrillic, HomographValidator.classify(0x0400).?); // lower bound
    try std.testing.expectEqual(HomographValidator.script_class.cyrillic, HomographValidator.classify(0x04FF).?); // upper bound
    try std.testing.expectEqual(HomographValidator.script_class.cyrillic, HomographValidator.classify(0x0410).?); // А
}

test "classify - armenian range" {
    try std.testing.expectEqual(HomographValidator.script_class.armenian, HomographValidator.classify(0x0530).?); // lower bound
    try std.testing.expectEqual(HomographValidator.script_class.armenian, HomographValidator.classify(0x058F).?); // upper bound
    try std.testing.expectEqual(HomographValidator.script_class.armenian, HomographValidator.classify(0x0531).?); // Ա
}

test "classify - boundary just outside each range falls to other" {
    try std.testing.expectEqual(HomographValidator.script_class.other, HomographValidator.classify(0x024F + 1)); // just past latin ext, before greek starts
    try std.testing.expectEqual(HomographValidator.script_class.other, HomographValidator.classify(0x036F)); // just before greek starts
    // NOTE: no gap exists between greek (ends 0x03FF) and cyrillic (starts 0x0400) — adjacent ranges
    try std.testing.expectEqual(HomographValidator.script_class.other, HomographValidator.classify(0x04FF + 1)); // just past cyrillic, before armenian
    try std.testing.expectEqual(HomographValidator.script_class.other, HomographValidator.classify(0x052F)); // just before armenian starts
}

test "classify - digits and ascii punctuation are other, not null" {
    // NOTE: locks in current behavior — see prior caveat that these are NOT
    // filtered to null the way C#'s Rune.IsLetter guard would do.
    try std.testing.expectEqual(HomographValidator.script_class.other, HomographValidator.classify('5'));
    try std.testing.expectEqual(HomographValidator.script_class.other, HomographValidator.classify(' '));
    try std.testing.expectEqual(HomographValidator.script_class.other, HomographValidator.classify('!'));
}

test "classify - never returns null (current implementation has no null path)" {
    // Documents that the ?script_class optional is currently unused —
    // every input falls into some variant, including .other.
    try std.testing.expect(HomographValidator.classify('x') != null);
    try std.testing.expect(HomographValidator.classify('5') != null);
    try std.testing.expect(HomographValidator.classify(0x1F600) != null); // emoji, way outside all ranges
}

test "collect_scripts - empty string" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var set = try validator.collect_scripts("");
    defer set.deinit();
    try std.testing.expect(set.count() == 0);
}

test "collect_scripts - ascii letters produce latin" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var set = try validator.collect_scripts("hello world");
    defer set.deinit();
    try std.testing.expect(set.contains(HomographValidator.script_class.latin));
    try std.testing.expect(set.contains(HomographValidator.script_class.other)); // space, punctuation
    try std.testing.expectEqual(2, set.count());
}

test "collect_scripts - cyrillic produces cyrillic" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var set = try validator.collect_scripts("\u{0410}\u{0411}\u{0412}"); // АБВ
    defer set.deinit();
    try std.testing.expect(set.contains(HomographValidator.script_class.cyrillic));
    try std.testing.expectEqual(1, set.count());
}

test "collect_scripts - greek produces greek" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var set = try validator.collect_scripts("\u{03B1}\u{03B2}\u{03B3}"); // αβγ
    defer set.deinit();
    try std.testing.expect(set.contains(HomographValidator.script_class.greek));
    try std.testing.expectEqual(1, set.count());
}

test "collect_scripts - armenian produces armenian" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var set = try validator.collect_scripts("\u{0531}\u{0532}"); // ԱԲ
    defer set.deinit();
    try std.testing.expect(set.contains(HomographValidator.script_class.armenian));
    try std.testing.expectEqual(1, set.count());
}

test "collect_scripts - mixed latin and cyrillic" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var set = try validator.collect_scripts("hello\u{0410}world"); // helloАworld
    defer set.deinit();
    try std.testing.expect(set.contains(HomographValidator.script_class.latin));
    try std.testing.expect(set.contains(HomographValidator.script_class.cyrillic));
    try std.testing.expectEqual(2, set.count());
}

test "collect_scripts - all four named scripts" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var set = try validator.collect_scripts("\u{0041}\u{03B1}\u{0410}\u{0531}"); // AαАԱ
    defer set.deinit();
    try std.testing.expect(set.contains(HomographValidator.script_class.latin));
    try std.testing.expect(set.contains(HomographValidator.script_class.greek));
    try std.testing.expect(set.contains(HomographValidator.script_class.cyrillic));
    try std.testing.expect(set.contains(HomographValidator.script_class.armenian));
    try std.testing.expectEqual(4, set.count());
}

test "collect_scripts - emoji falls to other" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var set = try validator.collect_scripts("\u{1F600}"); // 😀
    defer set.deinit();
    try std.testing.expect(set.contains(HomographValidator.script_class.other));
    try std.testing.expectEqual(1, set.count());
}

test "collect_scripts - latin extended characters" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var set = try validator.collect_scripts("café résumé");
    defer set.deinit();
    try std.testing.expect(set.contains(HomographValidator.script_class.latin));
    try std.testing.expect(set.contains(HomographValidator.script_class.other)); // space
    try std.testing.expectEqual(2, set.count());
}

test "collect_scripts - invalid utf8 returns error" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    try std.testing.expectError(error.InvalidUtf8, validator.collect_scripts("\xff\xfe"));
}

test "skeleton - plain ascii unchanged" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.skeleton("hello world");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "skeleton - empty string" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.skeleton("");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "skeleton - cyrillic lowercase look-alikes" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.skeleton("\u{0430}\u{0435}\u{043E}\u{0440}\u{0441}\u{0445}\u{0443}\u{0456}\u{0458}\u{0455}");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("aeopcxyijs", result);
}

test "skeleton - cyrillic uppercase look-alikes" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.skeleton("\u{0410}\u{0412}\u{0415}\u{041A}\u{041C}\u{041D}\u{041E}\u{0420}\u{0421}\u{0422}\u{0425}");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("ABEKMHOPCTX", result);
}

test "skeleton - greek lowercase look-alikes" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.skeleton("\u{03BF}\u{03B1}\u{03B5}\u{03C1}\u{03BD}\u{03B9}\u{03BA}");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("oaepvik", result);
}

test "skeleton - greek uppercase look-alikes" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.skeleton("\u{039F}\u{0391}\u{0392}\u{0395}\u{0397}\u{0399}\u{039A}\u{039C}\u{039D}\u{03A1}\u{03A4}\u{03A7}");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("OABEHIKMNPTX", result);
}

test "skeleton - mixed ascii and confusable cyrillic" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.skeleton("hello\u{0430}world"); // helloаworld
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("helloaworld", result);
}

test "skeleton - non-confusable unicode passes through" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.skeleton("\u{1F600}"); // 😀 emoji, not in confusables
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\u{1F600}", result);
}

test "skeleton - mixed confusable and non-confusable" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.skeleton("\u{0410}\u{1F600}\u{03B1}"); // А😀α
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("A\u{1F600}a", result);
}

test "skeleton - full homograph attack example" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    // "gооgle" with Cyrillic о (U+043E)
    const result = try validator.skeleton("g\u{043E}\u{043E}gle");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("google", result);
}

test "skeleton - invalid utf8 returns error" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    try std.testing.expectError(error.InvalidUtf8, validator.skeleton("\xff\xfe"));
}

test "describe - plain ascii unchanged" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.describe("hello world");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "describe - cyrillic codepoints" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.describe("\u{0410}\u{0411}"); // АБ
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("[U+0410][U+0411]", result);
}

test "describe - mixed ascii and non-ascii" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.describe("g\u{043E}\u{043E}gle"); // google with Cyrillic о
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("g[U+043E][U+043E]gle", result);
}

test "describe - control character formatted" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.describe("a\x01b");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a[U+0001]b", result);
}

test "describe - empty string" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.describe("");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "describe - emoji codepoint" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.describe("\u{1F600}"); // 😀
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("[U+1F600]", result);
}

test "describe - greek and punctuation" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    const result = try validator.describe("test@\u{03B1}.com"); // test@α.com
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("test@[U+03B1].com", result);
}

test "describe - invalid utf8 returns error" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    try std.testing.expectError(error.InvalidUtf8, validator.describe("\xff\xfe"));
}

fn empty_result() shared_validator.ValidationResult {
    return .{
        .has_findings = false,
        .findings = std.ArrayList(shared_validator.ValidationFinding).empty,
    };
}

test "scan - hidden character (zero-width space)" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan("pkg\u{200B}name", "pkgname", &result);

    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, result.findings.items[0].severity);
    try std.testing.expect(std.mem.indexOf(u8, result.findings.items[0].message, "hidden") != null);
}

test "scan - hidden character (BOM)" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan("pkg\u{FEFF}name", "pkgname", &result);

    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
}

test "scan - hidden character (bidi override)" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan("pkg\u{202E}name", "pkgname", &result);

    try std.testing.expect(result.has_findings);
}

test "scan - mixed script (Latin + Cyrillic)" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    // "pkgа" = Latin 'p','k','g' + Cyrillic 'а' (U+0430)
    try validator.scan("pkg\u{0430}ge", "pkgname", &result);

    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, result.findings.items[0].message, "mixes Latin") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.findings.items[0].message, "Cyrillic") != null);
}

test "scan - mixed script (Latin + Greek)" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan("pkg\u{03B1}", "depends", &result);

    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, result.findings.items[0].message, "Greek") != null);
}

test "scan - mixed script (Latin + Armenian)" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan("pkg\u{0531}", "url", &result);

    try std.testing.expect(result.has_findings);
    try std.testing.expect(std.mem.indexOf(u8, result.findings.items[0].message, "Armenian") != null);
}

test "scan - pure cyrillic does NOT trigger mixed-script" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    // Pure Cyrillic has only 1 script -> falls through to skeleton check
    try validator.scan("\u{0430}\u{0435}\u{043E}\u{0440}", "pkgname", &result);

    try std.testing.expect(result.has_findings);
    try std.testing.expect(std.mem.indexOf(u8, result.findings.items[0].message, "mixes Latin") == null);
}

test "scan - fullwidth characters (pure fullwidth)" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    // "ABC" = fullwidth ABC, only .other script -> skips mixed-script
    try validator.scan("\u{FF21}\u{FF22}\u{FF23}", "pkgname", &result);

    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, result.findings.items[0].message, "fullwidth") != null);
}

test "scan - fullwidth range lower boundary (U+FF01)" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan("\u{FF01}", "source", &result);

    try std.testing.expect(result.has_findings);
}

test "scan - fullwidth range upper boundary (U+FF5E)" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan("\u{FF5E}", "source", &result);

    try std.testing.expect(result.has_findings);
}

test "scan - just above fullwidth range (U+FF5F) does NOT trigger" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan("\u{FF5F}", "source", &result);

    try std.testing.expectEqual(false, result.has_findings);
}

test "scan - confusable cyrillic skeleton" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan("\u{0430}\u{0435}\u{043E}\u{0440}", "pkgname", &result);

    try std.testing.expect(result.has_findings);
    try std.testing.expect(std.mem.indexOf(u8, result.findings.items[0].message, "skeleton") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.findings.items[0].message, "aeop") != null); // was "aeor"
}

test "scan - confusable greek skeleton" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    // "οαε" -> skeleton "oae"
    try validator.scan("\u{03BF}\u{03B1}\u{03B5}", "depends", &result);

    try std.testing.expect(result.has_findings);
    try std.testing.expect(std.mem.indexOf(u8, result.findings.items[0].message, "skeleton") != null);
}

test "scan - non-confusable unicode passes all checks" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    // U+1F600 (emoji) has no confusable mapping
    try validator.scan("\u{1F600}", "pkgname", &result);

    try std.testing.expectEqual(false, result.has_findings);
}

test "scan - clean ascii passes" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan("valid-package-name", "pkgname", &result);

    try std.testing.expectEqual(false, result.has_findings);
}

test "scan - null value passes" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan(null, "pkgname", &result);

    try std.testing.expectEqual(false, result.has_findings);
}

test "scan - whitespace value passes" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan("  \t\n  ", "pkgname", &result);

    try std.testing.expectEqual(false, result.has_findings);
}

test "scan - embedded whitespace does not bypass homograph analysis" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan("trusted dеpendency", "depends", &result);

    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, result.findings.items[0].severity);
}

test "scan - matched_line shows codepoints for non-ascii" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan("\u{0430}\u{0435}\u{043E}\u{0440}", "pkgname", &result);

    try std.testing.expect(std.mem.indexOf(u8, result.findings.items[0].matched_line, "[U+") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.findings.items[0].matched_line, "U+0430]") != null);
}

fn cleanup_pkgbuild_test_fields(info: *pkgbuild.Pkgbuild) void {
    info.variables.deinit();
    info.local_source_contents.deinit();
}

test "validate - clean pkgbuild has no findings" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var depends = [_][]const u8{ "glibc", "openssl" };
    var make_depends = [_][]const u8{"cmake"};
    var source = [_][]const u8{"https://example.com/src.tar.gz"};

    var info = pkgbuild.Pkgbuild{
        .pkg_name = "valid-package",
        .depends = &depends,
        .make_depends = &make_depends,
        .url = "https://example.com",
        .source = &source,
        .variables = std.StringHashMap([]const u8).init(std.testing.allocator),
        .local_source_contents = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer cleanup_pkgbuild_test_fields(&info);

    var result = try validator.validate(info);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(false, result.has_findings);
    try std.testing.expectEqual(@as(usize, 0), result.findings.items.len);
}

test "validate - hidden character in pkgname" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };

    var info = pkgbuild.Pkgbuild{
        .pkg_name = "pkg\u{200B}name",
        .variables = std.StringHashMap([]const u8).init(std.testing.allocator),
        .local_source_contents = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer cleanup_pkgbuild_test_fields(&info);

    var result = try validator.validate(info);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expectEqualStrings("pkgname", result.findings.items[0].hook);
}

test "validate - hidden character in one of several depends" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var depends = [_][]const u8{ "glibc", "open\u{200B}ssl", "zlib" };

    var info = pkgbuild.Pkgbuild{
        .pkg_name = "valid-package",
        .depends = &depends,
        .variables = std.StringHashMap([]const u8).init(std.testing.allocator),
        .local_source_contents = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer cleanup_pkgbuild_test_fields(&info);

    var result = try validator.validate(info);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expectEqualStrings("depends", result.findings.items[0].hook);
}

test "validate - hidden character in makedepends" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var make_depends = [_][]const u8{"cmake\u{FEFF}"};

    var info = pkgbuild.Pkgbuild{
        .pkg_name = "valid-package",
        .make_depends = &make_depends,
        .variables = std.StringHashMap([]const u8).init(std.testing.allocator),
        .local_source_contents = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer cleanup_pkgbuild_test_fields(&info);

    var result = try validator.validate(info);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.has_findings);
    try std.testing.expectEqualStrings("makedepends", result.findings.items[0].hook);
}

test "validate - mixed script in url" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };

    var info = pkgbuild.Pkgbuild{
        .pkg_name = "valid-package",
        .url = "https://exampl\u{0435}.com", // Cyrillic е instead of e
        .variables = std.StringHashMap([]const u8).init(std.testing.allocator),
        .local_source_contents = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer cleanup_pkgbuild_test_fields(&info);

    var result = try validator.validate(info);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.has_findings);
    try std.testing.expectEqualStrings("url", result.findings.items[0].hook);
}

test "validate - hidden character in one of several source entries" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var source = [_][]const u8{ "https://example.com/a.tar.gz", "https://example.com/b\u{200D}.tar.gz" };

    var info = pkgbuild.Pkgbuild{
        .pkg_name = "valid-package",
        .source = &source,
        .variables = std.StringHashMap([]const u8).init(std.testing.allocator),
        .local_source_contents = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer cleanup_pkgbuild_test_fields(&info);

    var result = try validator.validate(info);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.has_findings);
    try std.testing.expectEqualStrings("source", result.findings.items[0].hook);
}

test "validate - findings accumulate across multiple fields" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };
    var depends = [_][]const u8{"open\u{200B}ssl"};

    var info = pkgbuild.Pkgbuild{
        .pkg_name = "pkg\u{200B}name",
        .depends = &depends,
        .url = "https://exampl\u{0435}.com",
        .variables = std.StringHashMap([]const u8).init(std.testing.allocator),
        .local_source_contents = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer cleanup_pkgbuild_test_fields(&info);

    var result = try validator.validate(info);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(@as(usize, 3), result.findings.items.len);
}

test "validate - null and unset fields are skipped safely" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };

    var info = pkgbuild.Pkgbuild{
        .variables = std.StringHashMap([]const u8).init(std.testing.allocator),
        .local_source_contents = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer cleanup_pkgbuild_test_fields(&info);

    var result = try validator.validate(info);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(false, result.has_findings);
    try std.testing.expectEqual(@as(usize, 0), result.findings.items.len);
}

test "validate_field - clean value has no findings" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };

    var result = try validator.validate_field("John Smith", "Maintainer");
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(false, result.has_findings);
}

test "validate_field - hidden character flagged under given field name" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };

    var result = try validator.validate_field("John\u{200B}Smith", "Maintainer");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expectEqualStrings("Maintainer", result.findings.items[0].hook);
}

test "validate_field - mixed script flagged" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };

    var result = try validator.validate_field("Smith\u{0430}", "Name"); // Cyrillic а
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.has_findings);
    try std.testing.expectEqualStrings("Name", result.findings.items[0].hook);
}

test "validate_field - null value produces no findings" {
    const validator = HomographValidator{ .allocator = std.testing.allocator };

    var result = try validator.validate_field(null, "Url");
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(false, result.has_findings);
}
