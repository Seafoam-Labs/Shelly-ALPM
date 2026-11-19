//! System colors palette, read from the desktop's `gtk-4.0/gtk.css`.
//! Shelly redefines the same names, so the values come from the files.
const std = @import("std");

pub const Rgb = struct {
    r: f64,
    g: f64,
    b: f64,

    fn luminance(c: Rgb) f64 {
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
    }

    fn linear(v: f64) f64 {
        return if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
    }
};

pub const min_contrast: f64 = 4.5;

const max_import_depth = 8;

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
    depth: u8,
) std.mem.Allocator.Error!void {
    if (depth > max_import_depth) return;
    const css = read(arena, path) orelse return;
    const dir = std.fs.path.dirname(path) orelse ".";
    try collectText(arena, defines, css, dir, read, depth);
}

/// Reads only `@import` and `@define-color` statements.
pub fn collectText(
    arena: std.mem.Allocator,
    defines: *Defines,
    css: []const u8,
    dir: []const u8,
    read: ReadFn,
    depth: u8,
) std.mem.Allocator.Error!void {
    const text = try stripComments(arena, css);
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '@')) |at| {
        const rest = text[at..];
        const end = std.mem.indexOfScalarPos(u8, text, at, ';') orelse break;
        const stmt = text[at..end];
        i = end + 1;
        if (std.mem.startsWith(u8, rest, "@define-color")) {
            const body = std.mem.trim(u8, stmt["@define-color".len..], " \t\r\n");
            const split = std.mem.indexOfAny(u8, body, " \t\r\n") orelse continue;
            const name = body[0..split];
            const value = std.mem.trim(u8, body[split..], " \t\r\n");
            if (name.len == 0 or value.len == 0) continue;
            try defines.put(arena, name, value);
        } else if (std.mem.startsWith(u8, rest, "@import")) {
            const target = importTarget(stmt["@import".len..]) orelse continue;
            const full = if (std.fs.path.isAbsolute(target))
                target
            else
                try std.fs.path.join(arena, &.{ dir, target });
            try collectFile(arena, defines, full, read, depth + 1);
        } else {
            i = at + 1;
        }
    }
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
    if (std.mem.startsWith(u8, spec, "url(")) {
        const close = std.mem.lastIndexOfScalar(u8, spec, ')') orelse return null;
        spec = std.mem.trim(u8, spec[4..close], " \t\r\n");
    } else {
        // Drop media queries after the quoted target.
        if (spec.len > 0 and (spec[0] == '"' or spec[0] == '\'')) {
            const close = std.mem.indexOfScalarPos(u8, spec, 1, spec[0]) orelse return null;
            spec = spec[0 .. close + 1];
        }
    }
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

fn first(arena: std.mem.Allocator, defines: *const Defines, names: []const []const u8) !?[]const u8 {
    for (names) |name| {
        const raw = defines.get(name) orelse continue;
        if (try resolve(arena, defines, raw)) |value| return value;
    }
    return null;
}

/// Null for computed values such as `mix()`.
pub fn parseRgb(text_raw: []const u8) ?Rgb {
    const text = std.mem.trim(u8, text_raw, " \t\r\n");
    if (text.len > 0 and text[0] == '#') {
        const hex = text[1..];
        return switch (hex.len) {
            3 => .{ .r = hexDigit(hex[0]) orelse return null, .g = hexDigit(hex[1]) orelse return null, .b = hexDigit(hex[2]) orelse return null },
            6, 8 => .{
                .r = hexByte(hex[0..2]) orelse return null,
                .g = hexByte(hex[2..4]) orelse return null,
                .b = hexByte(hex[4..6]) orelse return null,
            },
            else => null,
        };
    }
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    const func = text[0..open];
    if (!std.mem.eql(u8, func, "rgb") and !std.mem.eql(u8, func, "rgba")) return null;
    if (text[text.len - 1] != ')') return null;
    var parts = std.mem.tokenizeAny(u8, text[open + 1 .. text.len - 1], ", \t/");
    var channels: [3]f64 = undefined;
    for (&channels) |*ch| {
        const part = parts.next() orelse return null;
        if (std.mem.endsWith(u8, part, "%")) {
            const v = std.fmt.parseFloat(f64, part[0 .. part.len - 1]) catch return null;
            ch.* = std.math.clamp(v / 100.0, 0, 1);
        } else {
            const v = std.fmt.parseFloat(f64, part) catch return null;
            ch.* = std.math.clamp(v / 255.0, 0, 1);
        }
    }
    return .{ .r = channels[0], .g = channels[1], .b = channels[2] };
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

/// `accent` is the portal accent, used when the stylesheet names none.
pub fn build(
    arena: std.mem.Allocator,
    defines: *const Defines,
    accent: ?Rgb,
    dark_hint: bool,
    rejection: *Rejection,
) !Palette {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    rejection.* = .none;

    const bg = try first(arena, defines, &sources.bg);
    const fg = try first(arena, defines, &sources.fg);
    var full = bg != null and fg != null;
    var dark: ?bool = null;

    if (full) {
        const bg_rgb = parseRgb(bg.?);
        const fg_rgb = parseRgb(fg.?);
        if (bg_rgb != null and fg_rgb != null) {
            if (contrastRatio(bg_rgb.?, fg_rgb.?) < min_contrast) {
                rejection.* = .low_contrast;
                full = false;
            }
        }
        if (bg_rgb) |c| dark = c.luminance() < 0.18;
    } else {
        rejection.* = .missing;
    }

    const is_dark = dark orelse dark_hint;
    const w = Writer{ .arena = arena, .out = &out };

    if (full) {
        try w.role("shelly_bg", bg.?);
        try w.role("shelly_root_bg", "@shelly_bg");
        try w.role("shelly_fg", fg.?);
        try w.role("shelly_view_bg", (try first(arena, defines, &sources.view_bg)) orelse "mix(@shelly_bg, @shelly_fg, 0.02)");
        try w.role("shelly_header_bg", (try first(arena, defines, &sources.header_bg)) orelse "@shelly_bg");
        try w.role("shelly_sidebar_bg", (try first(arena, defines, &sources.sidebar_bg)) orelse "mix(@shelly_bg, @shelly_fg, 0.02)");
        try w.role("shelly_card_bg", (try first(arena, defines, &sources.card_bg)) orelse "mix(@shelly_bg, @shelly_fg, 0.05)");
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
        const borders = (try first(arena, defines, &sources.borders)) orelse "mix(@shelly_bg, @shelly_fg, 0.22)";
        try w.role("shelly_borders", borders);
        try w.role("shelly_border", "@shelly_borders");
        try w.role("shelly_divider", "mix(@shelly_bg, @shelly_fg, 0.10)");
        try w.role("shelly_divider_strong", "mix(@shelly_bg, @shelly_fg, 0.16)");
    }

    var accent_value: ?[]const u8 = if (full) try first(arena, defines, &sources.accent) else null;
    if (accent_value == null) {
        if (accent) |c| accent_value = try std.fmt.allocPrint(arena, "rgb({d},{d},{d})", .{
            channel(c.r), channel(c.g), channel(c.b),
        });
    }
    if (accent_value) |value| {
        try w.role("shelly_accent", value);
        const accent_fg = if (full) try first(arena, defines, &sources.accent_fg) else null;
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
    , "/cfg", &fakeRead, 0);
    try std.testing.expectEqualStrings("#111111", defines.get("theme_bg_color_breeze").?);
    try std.testing.expectEqualStrings("#fcfcfc", defines.get("theme_fg_color_breeze").?);
}

test "import targets accept url and quoted forms and skip remote schemes" {
    try std.testing.expectEqualStrings("noctalia.css", importTarget(" url(\"noctalia.css\")").?);
    try std.testing.expectEqualStrings("a.css", importTarget(" url(a.css)").?);
    try std.testing.expectEqualStrings("colors.css", importTarget(" 'colors.css'").?);
    try std.testing.expectEqualStrings("/x/y.css", importTarget(" url(\"file:///x/y.css\")").?);
    try std.testing.expect(importTarget(" url(\"resource:///org/x.css\")") == null);
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
    , "/cfg", &noRead, 0);
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
    , "/cfg", &noRead, 0);
    var rejection: Rejection = undefined;
    const p = try build(arena, &defines, null, false, &rejection);
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
    , "/cfg", &noRead, 0);
    var rejection: Rejection = undefined;
    const p = try build(arena, &defines, .{ .r = 1, .g = 0, .b = 0 }, true, &rejection);
    try std.testing.expect(!p.full);
    try std.testing.expectEqual(Rejection.low_contrast, rejection);
    try std.testing.expect(std.mem.indexOf(u8, p.css, "@define-color shelly_bg ") == null);
    try std.testing.expect(std.mem.indexOf(u8, p.css, "@define-color shelly_accent rgb(255,0,0);") != null);
}

test "no desktop colors and no accent yields an empty palette" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var defines: Defines = .empty;
    var rejection: Rejection = undefined;
    const p = try build(arena, &defines, null, true, &rejection);
    try std.testing.expectEqual(@as(usize, 0), p.css.len);
    try std.testing.expectEqual(Rejection.missing, rejection);
}
