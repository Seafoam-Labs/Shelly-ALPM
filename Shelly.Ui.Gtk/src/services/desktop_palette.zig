//! System colors palette, read from the installed GTK theme and the user's
//! `gtk-4.0/gtk.css`. Shelly redefines the same names, so the values come
//! from the files.
const std = @import("std");

pub const Rgb = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64 = 1,

    fn over(top: Rgb, bottom: Rgb) Rgb {
        return .{
            .r = top.r * top.a + bottom.r * (1 - top.a),
            .g = top.g * top.a + bottom.g * (1 - top.a),
            .b = top.b * top.a + bottom.b * (1 - top.a),
        };
    }

    fn luminance(c: Rgb) f64 {
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
    }

    fn linear(v: f64) f64 {
        return if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
    }
};

pub const min_contrast: f64 = 4.5;

const max_import_depth = 8;

/// caps values grown by nested references; real colors stay far below.
const max_resolved_len = 4096;

/// First defined name wins.
const sources = struct {
    const bg = [_][]const u8{ "window_bg_color", "theme_bg_color_breeze", "theme_bg_color" };
    const fg = [_][]const u8{ "window_fg_color", "theme_fg_color_breeze", "theme_fg_color" };
    const view_bg = [_][]const u8{ "view_bg_color", "theme_base_color_breeze", "theme_base_color" };
    const header_bg = [_][]const u8{ "headerbar_bg_color", "theme_titlebar_background_breeze", "theme_header_background_breeze" };
    const sidebar_bg = [_][]const u8{"sidebar_bg_color"};
    const card_bg = [_][]const u8{"card_bg_color"};
    const accent = [_][]const u8{ "accent_bg_color", "accent_color", "theme_selected_bg_color_breeze", "theme_selected_bg_color" };
    const accent_fg = [_][]const u8{ "accent_fg_color", "theme_selected_fg_color_breeze", "theme_selected_fg_color" };
    const borders = [_][]const u8{ "borders", "borders_breeze" };
};

pub const Defines = std.StringHashMapUnmanaged([]const u8);

pub const ReadFn = *const fn (arena: std.mem.Allocator, path: []const u8) ?[]const u8;

pub fn collectFile(
    arena: std.mem.Allocator,
    defines: *Defines,
    path: []const u8,
    read: ReadFn,
    scheme: Scheme,
    depth: u8,
) std.mem.Allocator.Error!void {
    if (depth > max_import_depth) return;
    const css = read(arena, path) orelse return;
    const dir = std.fs.path.dirname(path) orelse ".";
    try collectText(arena, defines, css, dir, read, scheme, depth);
}

/// Reads only `@import` and `@define-color` statements. `@media` blocks
/// count only when they match `scheme`.
pub fn collectText(
    arena: std.mem.Allocator,
    defines: *Defines,
    css: []const u8,
    dir: []const u8,
    read: ReadFn,
    scheme: Scheme,
    depth: u8,
) std.mem.Allocator.Error!void {
    const text = try stripComments(arena, css);
    var nesting: usize = 0;
    // nesting level of the outermost skipped `@media` block.
    var skip_level: ?usize = null;
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            '{' => {
                nesting += 1;
                i += 1;
                continue;
            },
            '}' => {
                if (nesting > 0) nesting -= 1;
                if (skip_level) |level| {
                    if (nesting < level) skip_level = null;
                }
                i += 1;
                continue;
            },
            '@' => {},
            else => {
                i += 1;
                continue;
            },
        }
        const rest = text[i..];
        if (std.mem.startsWith(u8, rest, "@media")) {
            const open = std.mem.indexOfScalarPos(u8, text, i, '{') orelse break;
            nesting += 1;
            if (skip_level == null and !mediaMatches(text[i + "@media".len .. open], scheme)) {
                skip_level = nesting;
            }
            i = open + 1;
            continue;
        }
        const is_define = std.mem.startsWith(u8, rest, "@define-color");
        if (!is_define and !std.mem.startsWith(u8, rest, "@import")) {
            i += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, text, i, ';') orelse break;
        const stmt = text[i..end];
        i = end + 1;
        if (skip_level != null) continue;
        if (is_define) {
            const body = std.mem.trim(u8, stmt["@define-color".len..], " \t\r\n");
            const split = std.mem.indexOfAny(u8, body, " \t\r\n") orelse continue;
            const name = body[0..split];
            const value = std.mem.trim(u8, body[split..], " \t\r\n");
            if (name.len == 0 or value.len == 0) continue;
            try defines.put(arena, name, value);
        } else {
            const target = importTarget(stmt["@import".len..]) orelse continue;
            const full = if (std.fs.path.isAbsolute(target))
                target
            else
                try std.fs.path.join(arena, &.{ dir, target });
            try collectFile(arena, defines, full, read, scheme, depth + 1);
        }
    }
}

pub const Scheme = struct {
    dark: bool,
    high_contrast: bool = false,
};

/// unknown features never match.
fn mediaMatches(query: []const u8, scheme: Scheme) bool {
    var rest = std.mem.trim(u8, query, " \t\r\n");
    if (rest.len == 0) return false;
    while (true) {
        if (rest.len == 0 or rest[0] != '(') return false;
        const close = std.mem.indexOfScalar(u8, rest, ')') orelse return false;
        const feature = rest[1..close];
        const colon = std.mem.indexOfScalar(u8, feature, ':') orelse return false;
        const name = std.mem.trim(u8, feature[0..colon], " \t\r\n");
        const value = std.mem.trim(u8, feature[colon + 1 ..], " \t\r\n");
        const matches = if (std.mem.eql(u8, name, "prefers-color-scheme"))
            std.mem.eql(u8, value, if (scheme.dark) "dark" else "light")
        else if (std.mem.eql(u8, name, "prefers-contrast"))
            std.mem.eql(u8, value, if (scheme.high_contrast) "more" else "no-preference")
        else
            false;
        if (!matches) return false;
        rest = std.mem.trim(u8, rest[close + 1 ..], " \t\r\n");
        if (rest.len == 0) return true;
        if (!std.mem.startsWith(u8, rest, "and")) return false;
        rest = std.mem.trim(u8, rest["and".len..], " \t\r\n");
    }
}

pub const ThemeVariable = struct { name: []const u8, variant: []const u8 };

/// splits like gtk: the variant follows the last `:`.
pub fn splitThemeVariable(value: []const u8) ThemeVariable {
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return .{ .name = value, .variant = "" };
    return .{ .name = value[0..colon], .variant = value[colon + 1 ..] };
}

pub const ExistsFn = *const fn (arena: std.mem.Allocator, path: []const u8) bool;

/// gtk's lookup: the first `<dir>/<name>` holding the file wins, newest
/// `gtk-4.N` folder first.
pub fn findThemeFile(
    arena: std.mem.Allocator,
    dirs: []const []const u8,
    name: []const u8,
    file: []const u8,
    gtk_minor: u32,
    exists: ExistsFn,
) std.mem.Allocator.Error!?[]const u8 {
    if (name.len == 0) return null;
    const newest = gtk_minor + gtk_minor % 2;
    for (dirs) |dir| {
        const base = try std.fs.path.join(arena, &.{ dir, name });
        if (!exists(arena, base)) continue;
        var minor: u32 = newest;
        while (true) : (minor -= 2) {
            const path = try std.fmt.allocPrint(arena, "{s}/gtk-4.{d}/{s}", .{ base, minor, file });
            if (exists(arena, path)) return path;
            if (minor < 2) break;
        }
    }
    return null;
}

fn stripComments(arena: std.mem.Allocator, css: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < css.len) {
        if (i + 1 < css.len and css[i] == '/' and css[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, css, i + 2, "*/") orelse break;
            i = close + 2;
            continue;
        }
        try out.append(arena, css[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// Only local files are followed.
fn importTarget(spec_raw: []const u8) ?[]const u8 {
    var spec = std.mem.trim(u8, spec_raw, " \t\r\n");
    var rest: []const u8 = "";
    if (std.mem.startsWith(u8, spec, "url(")) {
        // the first `)` after the target.
        const inner = std.mem.trimStart(u8, spec[4..], " \t\r\n");
        const offset = spec.len - inner.len;
        const from = if (inner.len > 0 and (inner[0] == '"' or inner[0] == '\''))
            offset + 1 + (std.mem.indexOfScalarPos(u8, inner, 1, inner[0]) orelse return null)
        else
            offset;
        const close = std.mem.indexOfScalarPos(u8, spec, from, ')') orelse return null;
        rest = spec[close + 1 ..];
        spec = std.mem.trim(u8, spec[4..close], " \t\r\n");
    } else if (spec.len > 0 and (spec[0] == '"' or spec[0] == '\'')) {
        const close = std.mem.indexOfScalarPos(u8, spec, 1, spec[0]) orelse return null;
        rest = spec[close + 1 ..];
        spec = spec[0 .. close + 1];
    }
    // gtk skips an import with anything after its target, such as a media query.
    if (std.mem.trim(u8, rest, " \t\r\n").len > 0) return null;
    if (spec.len >= 2 and (spec[0] == '"' or spec[0] == '\'') and spec[spec.len - 1] == spec[0]) {
        spec = spec[1 .. spec.len - 1];
    }
    if (std.mem.startsWith(u8, spec, "file://")) return spec["file://".len..];
    if (std.mem.indexOf(u8, spec, "://") != null) return null;
    if (spec.len == 0) return null;
    return spec;
}

/// Returns null when a reference is unknown or circular.
pub fn resolve(arena: std.mem.Allocator, defines: *const Defines, expr: []const u8) !?[]const u8 {
    var current = expr;
    var rounds: u8 = 0;
    while (std.mem.indexOfScalar(u8, current, '@') != null) : (rounds += 1) {
        if (rounds > 16) return null;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < current.len) {
            if (current[i] != '@') {
                try out.append(arena, current[i]);
                i += 1;
                continue;
            }
            var j = i + 1;
            while (j < current.len and (std.ascii.isAlphanumeric(current[j]) or current[j] == '_' or current[j] == '-')) j += 1;
            const value = defines.get(current[i + 1 .. j]) orelse return null;
            try out.append(arena, '(');
            try out.appendSlice(arena, value);
            try out.append(arena, ')');
            i = j;
        }
        if (out.items.len > max_resolved_len) return null;
        current = try out.toOwnedSlice(arena);
    }
    return try unwrapParens(arena, current);
}

/// GTK rejects a bare parenthesized color.
fn unwrapParens(arena: std.mem.Allocator, expr: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var stack: std.ArrayListUnmanaged(bool) = .empty;
    for (expr, 0..) |c, idx| {
        if (c == '(') {
            const prev = previousNonSpace(expr, idx);
            const is_call = prev != null and (std.ascii.isAlphanumeric(prev.?) or prev.? == '_' or prev.? == '-');
            try stack.append(arena, is_call);
            if (is_call) try out.append(arena, c);
        } else if (c == ')') {
            const is_call = if (stack.items.len > 0) stack.pop().? else true;
            if (is_call) try out.append(arena, c);
        } else {
            try out.append(arena, c);
        }
    }
    return out.toOwnedSlice(arena);
}

fn previousNonSpace(s: []const u8, idx: usize) ?u8 {
    var k = idx;
    while (k > 0) {
        k -= 1;
        if (s[k] != ' ' and s[k] != '\t') return s[k];
    }
    return null;
}

fn firstFrom(arena: std.mem.Allocator, defines: *const Defines, only: ?*const Defines, names: []const []const u8) !?[]const u8 {
    for (names) |name| {
        if (only) |subset| {
            if (!subset.contains(name)) continue;
        }
        const raw = defines.get(name) orelse continue;
        if (try resolve(arena, defines, raw)) |value| return value;
    }
    return null;
}

/// user names win over theme names, so plasma's `*_breeze` colors beat a
/// libadwaita-style theme.
fn first(arena: std.mem.Allocator, defines: *const Defines, user: *const Defines, names: []const []const u8) !?[]const u8 {
    return (try firstFrom(arena, defines, user, names)) orelse try firstFrom(arena, defines, null, names);
}

/// Null for computed values such as `mix()`.
pub fn parseRgb(text_raw: []const u8) ?Rgb {
    const text = std.mem.trim(u8, text_raw, " \t\r\n");
    if (text.len > 0 and text[0] == '#') {
        const hex = text[1..];
        return switch (hex.len) {
            3, 4 => .{
                .r = hexDigit(hex[0]) orelse return null,
                .g = hexDigit(hex[1]) orelse return null,
                .b = hexDigit(hex[2]) orelse return null,
                .a = if (hex.len == 4) hexDigit(hex[3]) orelse return null else 1,
            },
            6, 8 => .{
                .r = hexByte(hex[0..2]) orelse return null,
                .g = hexByte(hex[2..4]) orelse return null,
                .b = hexByte(hex[4..6]) orelse return null,
                .a = if (hex.len == 8) hexByte(hex[6..8]) orelse return null else 1,
            },
            else => null,
        };
    }
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    const func = text[0..open];
    if (!std.ascii.eqlIgnoreCase(func, "rgb") and !std.ascii.eqlIgnoreCase(func, "rgba")) return null;
    if (text[text.len - 1] != ')') return null;
    var parts = std.mem.tokenizeAny(u8, text[open + 1 .. text.len - 1], ", \t/");
    var channels: [4]f64 = .{ 0, 0, 0, 1 };
    for (&channels, 0..) |*ch, idx| {
        const part = parts.next() orelse {
            if (idx == 3) break;
            return null;
        };
        const scale: f64 = if (idx == 3) 1 else 255;
        if (std.mem.endsWith(u8, part, "%")) {
            const v = std.fmt.parseFloat(f64, part[0 .. part.len - 1]) catch return null;
            ch.* = std.math.clamp(v / 100.0, 0, 1);
        } else {
            const v = std.fmt.parseFloat(f64, part) catch return null;
            ch.* = std.math.clamp(v / scale, 0, 1);
        }
    }
    if (parts.next() != null) return null;
    return .{ .r = channels[0], .g = channels[1], .b = channels[2], .a = channels[3] };
}

fn hexDigit(c: u8) ?f64 {
    const v = std.fmt.charToDigit(c, 16) catch return null;
    return @as(f64, @floatFromInt(v * 17)) / 255.0;
}

fn hexByte(s: []const u8) ?f64 {
    const v = std.fmt.parseInt(u8, s, 16) catch return null;
    return @as(f64, @floatFromInt(v)) / 255.0;
}

pub fn contrastRatio(a: Rgb, b: Rgb) f64 {
    const la = a.luminance();
    const lb = b.luminance();
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

pub const Palette = struct {
    css: []const u8,
    /// Null when the background is not a literal color.
    dark: ?bool,
    full: bool,
};

pub const Rejection = enum { none, missing, low_contrast };

/// `user` holds only the user colors, `defines` the theme's as well. the
/// portal `accent` beats a theme accent, not a user one.
pub fn build(
    arena: std.mem.Allocator,
    defines: *const Defines,
    user: *const Defines,
    accent: ?Rgb,
    dark_hint: bool,
    rejection: *Rejection,
) !Palette {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    rejection.* = .none;

    const bg = try first(arena, defines, user, &sources.bg);
    const fg = try first(arena, defines, user, &sources.fg);
    var full = bg != null and fg != null;
    var dark: ?bool = null;

    if (full) {
        // blend see-through colors before checking contrast.
        const base: Rgb = if (dark_hint) .{ .r = 0, .g = 0, .b = 0 } else .{ .r = 1, .g = 1, .b = 1 };
        const bg_rgb = if (parseRgb(bg.?)) |c| c.over(base) else null;
        const fg_rgb = parseRgb(fg.?);
        if (bg_rgb != null and fg_rgb != null) {
            if (contrastRatio(bg_rgb.?, fg_rgb.?.over(bg_rgb.?)) < min_contrast) {
                rejection.* = .low_contrast;
                full = false;
            }
        }
        if (full) {
            if (bg_rgb) |c| dark = c.luminance() < 0.18;
        }
    } else {
        rejection.* = .missing;
    }

    const is_dark = dark orelse dark_hint;
    const w = Writer{ .arena = arena, .out = &out };

    if (full) {
        try w.role("shelly_bg", bg.?);
        try w.role("shelly_root_bg", "@shelly_bg");
        try w.role("shelly_fg", fg.?);
        try w.role("shelly_view_bg", (try first(arena, defines, user, &sources.view_bg)) orelse "mix(@shelly_bg, @shelly_fg, 0.02)");
        try w.role("shelly_header_bg", (try first(arena, defines, user, &sources.header_bg)) orelse "@shelly_bg");
        try w.role("shelly_sidebar_bg", (try first(arena, defines, user, &sources.sidebar_bg)) orelse "mix(@shelly_bg, @shelly_fg, 0.02)");
        try w.role("shelly_card_bg", (try first(arena, defines, user, &sources.card_bg)) orelse "mix(@shelly_bg, @shelly_fg, 0.05)");
        try w.role("shelly_card_hover_bg", "mix(@shelly_card_bg, @shelly_fg, 0.05)");
        try w.role("shelly_control_bg", "mix(@shelly_card_bg, @shelly_fg, 0.05)");
        try w.role("shelly_control_hover_bg", "mix(@shelly_card_bg, @shelly_fg, 0.11)");
        try w.role("shelly_track_bg", "mix(@shelly_bg, @shelly_fg, 0.10)");
        try w.role("shelly_track_hover_bg", "mix(@shelly_bg, @shelly_fg, 0.16)");
        try w.role("shelly_knob_bg", if (is_dark) "@shelly_bg" else "@shelly_view_bg");
        try w.role("shelly_insensitive_bg", "mix(@shelly_bg, @shelly_fg, 0.05)");
        try w.role("shelly_secondary_fg", "mix(@shelly_fg, @shelly_bg, 0.25)");
        try w.role("shelly_column_header_fg", "@shelly_secondary_fg");
        try w.role("shelly_muted_fg", "mix(@shelly_fg, @shelly_bg, 0.42)");
        const borders = (try first(arena, defines, user, &sources.borders)) orelse "mix(@shelly_bg, @shelly_fg, 0.22)";
        try w.role("shelly_borders", borders);
        try w.role("shelly_border", "@shelly_borders");
        try w.role("shelly_divider", "mix(@shelly_bg, @shelly_fg, 0.10)");
        try w.role("shelly_divider_strong", "mix(@shelly_bg, @shelly_fg, 0.16)");
    }

    // The accent stands alone: a stylesheet may set only the accent.
    var accent_value: ?[]const u8 = try firstFrom(arena, defines, user, &sources.accent);
    if (accent_value == null) {
        if (accent) |c| accent_value = try std.fmt.allocPrint(arena, "rgb({d},{d},{d})", .{
            channel(c.r), channel(c.g), channel(c.b),
        });
    }
    if (accent_value == null) accent_value = try firstFrom(arena, defines, null, &sources.accent);
    if (accent_value) |value| {
        try w.role("shelly_accent", value);
        const accent_fg = try first(arena, defines, user, &sources.accent_fg);
        try w.role("shelly_accent_fg", accent_fg orelse (if (is_dark) "mix(@shelly_accent, black, 0.75)" else "#ffffff"));
        try w.role("shelly_accent_hover", if (is_dark) "mix(@shelly_accent, white, 0.25)" else "mix(@shelly_accent, white, 0.15)");
        try w.role("shelly_accent_active", if (is_dark) "mix(@shelly_accent, black, 0.10)" else "mix(@shelly_accent, black, 0.15)");
        try w.role("shelly_selected_bg", if (is_dark) "mix(@shelly_bg, @shelly_accent, 0.35)" else "mix(@shelly_bg, @shelly_accent, 0.22)");
        try w.role("shelly_selected_fg", "mix(@shelly_fg, @shelly_accent, 0.20)");
    }

    return .{ .css = try out.toOwnedSlice(arena), .dark = dark, .full = full };
}

fn channel(v: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255.0));
}

const Writer = struct {
    arena: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),

    fn line(self: Writer, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.arena, fmt ++ "\n", args);
        try self.out.appendSlice(self.arena, text);
    }

    fn role(self: Writer, name: []const u8, value: []const u8) !void {
        try self.line("@define-color {s} {s};", .{ name, value });
    }
};

fn noRead(_: std.mem.Allocator, _: []const u8) ?[]const u8 {
    return null;
}

fn fakeRead(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "/cfg/colors.css")) {
        return arena.dupe(u8, "@define-color theme_bg_color_breeze #202326;\n@define-color theme_fg_color_breeze #fcfcfc;\n@define-color theme_selected_bg_color_breeze #3daee9;") catch null;
    }
    return null;
}

test "collects defines and follows plasma style imports" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var defines: Defines = .empty;
    try collectText(arena, &defines,
        \\/* generated */
        \\@import 'colors.css';
        \\window { color: red; }
        \\@define-color theme_bg_color_breeze #111111;
    , "/cfg", &fakeRead, .{ .dark = false }, 0);
    try std.testing.expectEqualStrings("#111111", defines.get("theme_bg_color_breeze").?);
    try std.testing.expectEqualStrings("#fcfcfc", defines.get("theme_fg_color_breeze").?);
}

test "import targets accept url and quoted forms and skip remote schemes" {
    try std.testing.expectEqualStrings("noctalia.css", importTarget(" url(\"noctalia.css\")").?);
    try std.testing.expectEqualStrings("a.css", importTarget(" url(a.css)").?);
    try std.testing.expectEqualStrings("colors.css", importTarget(" 'colors.css'").?);
    try std.testing.expectEqualStrings("/x/y.css", importTarget(" url(\"file:///x/y.css\")").?);
    try std.testing.expect(importTarget(" url(\"resource:///org/x.css\")") == null);
    try std.testing.expectEqualStrings("b (1).css", importTarget(" url('b (1).css')").?);
    try std.testing.expect(importTarget(" url(a.css) (prefers-color-scheme: dark)") == null);
    try std.testing.expect(importTarget(" 'a.css' (prefers-color-scheme: dark)") == null);
}

test "resolves references and rejects unknown ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var defines: Defines = .empty;
    try collectText(arena, &defines,
        \\@define-color base #102030;
        \\@define-color window_bg_color @base;
        \\@define-color hover alpha(@base, 0.5);
        \\@define-color broken @nowhere;
        \\@define-color loop_a @loop_b;
        \\@define-color loop_b @loop_a;
    , "/cfg", &noRead, .{ .dark = false }, 0);
    try std.testing.expectEqualStrings("#102030", (try resolve(arena, &defines, "@window_bg_color")).?);
    try std.testing.expectEqualStrings("alpha(#102030, 0.5)", (try resolve(arena, &defines, "@hover")).?);
    try std.testing.expect((try resolve(arena, &defines, "@broken")) == null);
    try std.testing.expect((try resolve(arena, &defines, "@loop_a")) == null);
}

test "parses literal colors" {
    const a = parseRgb("#ffffff").?;
    try std.testing.expectApproxEqAbs(@as(f64, 1), a.r, 1e-9);
    const b = parseRgb("rgb(255, 0, 0)").?;
    try std.testing.expectApproxEqAbs(@as(f64, 1), b.r, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), b.g, 1e-9);
    try std.testing.expect(parseRgb("#fff").?.b == 1);
    try std.testing.expect(parseRgb("mix(#000, #fff, 0.5)") == null);
    try std.testing.expectApproxEqAbs(@as(f64, 21), contrastRatio(parseRgb("#000000").?, parseRgb("#ffffff").?), 1e-6);
}

test "builds a full palette from libadwaita names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var defines: Defines = .empty;
    try collectText(arena, &defines,
        \\@define-color window_bg_color #1c1b1f;
        \\@define-color window_fg_color #e6e1e5;
        \\@define-color accent_bg_color #a8c7fa;
    , "/cfg", &noRead, .{ .dark = false }, 0);
    var rejection: Rejection = undefined;
    const p = try build(arena, &defines, &defines, null, false, &rejection);
    try std.testing.expect(p.full);
    try std.testing.expectEqual(true, p.dark.?);
    try std.testing.expectEqual(Rejection.none, rejection);
    try std.testing.expect(std.mem.indexOf(u8, p.css, "@define-color shelly_bg #1c1b1f;") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.css, "@define-color shelly_accent #a8c7fa;") != null);
}

test "rejects unreadable text and falls back to the portal accent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var defines: Defines = .empty;
    try collectText(arena, &defines,
        \\@define-color window_bg_color #777777;
        \\@define-color window_fg_color #888888;
    , "/cfg", &noRead, .{ .dark = false }, 0);
    var rejection: Rejection = undefined;
    const p = try build(arena, &defines, &defines, .{ .r = 1, .g = 0, .b = 0 }, true, &rejection);
    try std.testing.expect(!p.full);
    try std.testing.expectEqual(Rejection.low_contrast, rejection);
    try std.testing.expect(std.mem.indexOf(u8, p.css, "@define-color shelly_bg ") == null);
    try std.testing.expect(std.mem.indexOf(u8, p.css, "@define-color shelly_accent rgb(255,0,0);") != null);
}

test "a rejected palette leaves dark or light to the desktop" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var defines: Defines = .empty;
    try collectText(arena, &defines,
        \\@define-color window_bg_color #222222;
        \\@define-color window_fg_color #2a2a2a;
    , "/cfg", &noRead, .{ .dark = false }, 0);
    var rejection: Rejection = undefined;
    const p = try build(arena, &defines, &defines, null, false, &rejection);
    try std.testing.expectEqual(Rejection.low_contrast, rejection);
    try std.testing.expect(p.dark == null);
}

test "a stylesheet accent applies without background and text colors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var defines: Defines = .empty;
    try collectText(arena, &defines,
        \\@define-color accent_bg_color #e01b24;
    , "/cfg", &noRead, .{ .dark = false }, 0);
    var rejection: Rejection = undefined;
    const p = try build(arena, &defines, &defines, .{ .r = 0, .g = 0, .b = 1 }, false, &rejection);
    try std.testing.expect(!p.full);
    try std.testing.expectEqual(Rejection.missing, rejection);
    try std.testing.expect(std.mem.indexOf(u8, p.css, "@define-color shelly_bg ") == null);
    try std.testing.expect(std.mem.indexOf(u8, p.css, "@define-color shelly_accent #e01b24;") != null);
}

test "no desktop colors and no accent yields an empty palette" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var defines: Defines = .empty;
    var rejection: Rejection = undefined;
    const p = try build(arena, &defines, &defines, null, true, &rejection);
    try std.testing.expectEqual(@as(usize, 0), p.css.len);
    try std.testing.expectEqual(Rejection.missing, rejection);
}

test "media blocks follow the color scheme and skip high contrast" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const css =
        \\@define-color window_bg_color #fafafb;
        \\@media (prefers-color-scheme: dark) { @define-color window_bg_color #222226; }
        \\@media (prefers-contrast: more) { @define-color window_bg_color #ffffff; }
        \\@media (prefers-color-scheme: light) and (prefers-contrast: more) {
        \\  window { color: @window_fg_color; }
        \\  @define-color window_bg_color #eeeeee;
        \\}
        \\@media (prefers-color-scheme: dark) {
        \\  .a { color: red; }
        \\  @media (prefers-contrast: more) { @define-color window_fg_color #000000; }
        \\  @define-color window_fg_color #fcfcfc;
        \\}
        \\window { background: @window_bg_color; }
        \\@define-color accent_bg_color #3584e4;
    ;
    var light: Defines = .empty;
    try collectText(arena, &light, css, "/cfg", &noRead, .{ .dark = false }, 0);
    try std.testing.expectEqualStrings("#fafafb", light.get("window_bg_color").?);
    try std.testing.expect(light.get("window_fg_color") == null);
    try std.testing.expectEqualStrings("#3584e4", light.get("accent_bg_color").?);

    var dark: Defines = .empty;
    try collectText(arena, &dark, css, "/cfg", &noRead, .{ .dark = true }, 0);
    try std.testing.expectEqualStrings("#222226", dark.get("window_bg_color").?);
    try std.testing.expectEqualStrings("#fcfcfc", dark.get("window_fg_color").?);
    try std.testing.expectEqualStrings("#3584e4", dark.get("accent_bg_color").?);
}

test "unknown media features never match" {
    try std.testing.expect(mediaMatches(" (prefers-color-scheme: dark)", .{ .dark = true }));
    try std.testing.expect(mediaMatches("(prefers-color-scheme:light) and (prefers-contrast: no-preference)", .{ .dark = false }));
    try std.testing.expect(!mediaMatches("(prefers-reduced-motion: reduce)", .{ .dark = true }));
    try std.testing.expect(!mediaMatches("screen", .{ .dark = true }));
    try std.testing.expect(!mediaMatches("", .{ .dark = true }));
    try std.testing.expect(!mediaMatches("(prefers-color-scheme: dark) or (prefers-contrast: more)", .{ .dark = true }));
}

fn fakeExists(_: std.mem.Allocator, path: []const u8) bool {
    const present = [_][]const u8{
        "/home/u/.local/share/themes/Nord",
        "/home/u/.local/share/themes/Nord/gtk-3.0/gtk.css",
        "/usr/share/themes/Nord",
        "/usr/share/themes/Nord/gtk-4.0/gtk.css",
        "/usr/share/themes/Nord/gtk-4.0/gtk-dark.css",
        "/usr/share/themes/Nord/gtk-4.20/gtk.css",
        "/usr/share/themes/Nord/gtk-4.26/gtk.css",
    };
    for (present) |p| {
        if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}

test "theme lookup follows the gtk search order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dirs = [_][]const u8{ "/home/u/.local/share/themes", "/home/u/.themes", "/usr/share/themes" };
    // the user folder has no gtk 4 sheet; 4.23 rounds up to 4.24, not 4.26.
    try std.testing.expectEqualStrings(
        "/usr/share/themes/Nord/gtk-4.20/gtk.css",
        (try findThemeFile(arena, &dirs, "Nord", "gtk.css", 23, &fakeExists)).?,
    );
    try std.testing.expectEqualStrings(
        "/usr/share/themes/Nord/gtk-4.0/gtk-dark.css",
        (try findThemeFile(arena, &dirs, "Nord", "gtk-dark.css", 24, &fakeExists)).?,
    );
    try std.testing.expect((try findThemeFile(arena, &dirs, "Missing", "gtk.css", 24, &fakeExists)) == null);
    try std.testing.expect((try findThemeFile(arena, &dirs, "", "gtk.css", 24, &fakeExists)) == null);
}

test "user colors beat the theme whatever their names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var defines: Defines = .empty;
    try collectText(arena, &defines,
        \\@define-color window_bg_color #fafafb;
        \\@define-color window_fg_color #000006;
        \\@define-color accent_bg_color #3584e4;
    , "/theme", &noRead, .{ .dark = true }, 0);
    var user: Defines = .empty;
    try collectText(arena, &user,
        \\@define-color theme_bg_color_breeze #202326;
        \\@define-color theme_fg_color_breeze #fcfcfc;
        \\@define-color theme_selected_bg_color_breeze #3daee9;
    , "/cfg", &noRead, .{ .dark = true }, 0);
    var it = user.iterator();
    while (it.next()) |entry| try defines.put(arena, entry.key_ptr.*, entry.value_ptr.*);

    var rejection: Rejection = undefined;
    const p = try build(arena, &defines, &user, .{ .r = 1, .g = 0, .b = 0 }, true, &rejection);
    try std.testing.expect(p.full);
    try std.testing.expect(std.mem.indexOf(u8, p.css, "@define-color shelly_bg #202326;") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.css, "@define-color shelly_fg #fcfcfc;") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.css, "@define-color shelly_accent #3daee9;") != null);
}

test "the portal accent beats a theme accent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var defines: Defines = .empty;
    try collectText(arena, &defines,
        \\@define-color window_bg_color #222226;
        \\@define-color window_fg_color #ffffff;
        \\@define-color accent_bg_color #3584e4;
    , "/theme", &noRead, .{ .dark = true }, 0);
    const user: Defines = .empty;
    var rejection: Rejection = undefined;
    const with_portal = try build(arena, &defines, &user, .{ .r = 1, .g = 0, .b = 0 }, true, &rejection);
    try std.testing.expect(std.mem.indexOf(u8, with_portal.css, "@define-color shelly_accent rgb(255,0,0);") != null);
    const without = try build(arena, &defines, &user, null, true, &rejection);
    try std.testing.expect(std.mem.indexOf(u8, without.css, "@define-color shelly_accent #3584e4;") != null);
}

test "GTK_THEME splits at the last colon" {
    const plain = splitThemeVariable("adw-gtk3");
    try std.testing.expectEqualStrings("adw-gtk3", plain.name);
    try std.testing.expectEqualStrings("", plain.variant);
    const dark = splitThemeVariable("Foo:dark");
    try std.testing.expectEqualStrings("Foo", dark.name);
    try std.testing.expectEqualStrings("dark", dark.variant);
    const nested = splitThemeVariable("a:b:hc-dark");
    try std.testing.expectEqualStrings("a:b", nested.name);
    try std.testing.expectEqualStrings("hc-dark", nested.variant);
}

test "high contrast reads prefers-contrast: more blocks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var defines: Defines = .empty;
    try collectText(arena, &defines,
        \\@define-color window_bg_color #fafafb;
        \\@media (prefers-contrast: more) { @define-color window_bg_color #ffffff; }
        \\@media (prefers-contrast: no-preference) { @define-color window_fg_color #333333; }
    , "/cfg", &noRead, .{ .dark = false, .high_contrast = true }, 0);
    try std.testing.expectEqualStrings("#ffffff", defines.get("window_bg_color").?);
    try std.testing.expect(defines.get("window_fg_color") == null);
    try std.testing.expect(!mediaMatches("(prefers-contrast: less)", .{ .dark = false, .high_contrast = true }));
}

test "colors keep their alpha and translucent text is checked over the background" {
    const short = parseRgb("#0008").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0x88) / 255.0, short.a, 1e-9);
    try std.testing.expectEqual(@as(f64, 0), parseRgb("#00000000").?.a);
    const adw = parseRgb("RGB(0 0 6 / 80%)").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), adw.a, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), parseRgb("rgba(10, 20, 30, 0.5)").?.a, 1e-9);
    try std.testing.expect(parseRgb("rgb(1, 2)") == null);
    try std.testing.expect(parseRgb("rgb(1, 2, 3, 4, 5)") == null);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty: Defines = .empty;
    var rejection: Rejection = undefined;

    var faint: Defines = .empty;
    try collectText(arena, &faint,
        \\@define-color window_bg_color #ffffff;
        \\@define-color window_fg_color rgba(0, 0, 0, 0.1);
    , "/cfg", &noRead, .{ .dark = false }, 0);
    _ = try build(arena, &faint, &empty, null, false, &rejection);
    try std.testing.expectEqual(Rejection.low_contrast, rejection);

    var clear: Defines = .empty;
    try collectText(arena, &clear,
        \\@define-color window_bg_color #00000000;
        \\@define-color window_fg_color #ffffff;
    , "/cfg", &noRead, .{ .dark = false }, 0);
    _ = try build(arena, &clear, &empty, null, false, &rejection);
    try std.testing.expectEqual(Rejection.low_contrast, rejection);

    var readable: Defines = .empty;
    try collectText(arena, &readable,
        \\@define-color window_bg_color #fafafb;
        \\@define-color window_fg_color RGB(0 0 6 / 80%);
    , "/cfg", &noRead, .{ .dark = false }, 0);
    const p = try build(arena, &readable, &empty, null, false, &rejection);
    try std.testing.expectEqual(Rejection.none, rejection);
    try std.testing.expectEqual(false, p.dark.?);
}

test "deeply nested references stop growing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var defines: Defines = .empty;
    try defines.put(arena, "c0", "#101010");
    var names: [17][]const u8 = undefined;
    names[0] = "c0";
    for (1..names.len) |n| {
        names[n] = try std.fmt.allocPrint(arena, "c{d}", .{n});
        const prev = names[n - 1];
        try defines.put(arena, names[n], try std.fmt.allocPrint(arena, "mix(@{s}, @{s}, 0.5)", .{ prev, prev }));
    }
    try std.testing.expect((try resolve(arena, &defines, "@c16")) == null);
    try std.testing.expect((try resolve(arena, &defines, "@c2")) != null);
}
