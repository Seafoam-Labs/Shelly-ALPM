//! Parses ANSI/VT escape sequences out of console output lines so the
//! transaction terminal can render colors and styles instead of raw
//! control bytes (https://github.com/Seafoam-Labs/Shelly-ALPM/issues/2051).
//!
//! Only SGR (colors and text attributes) carry meaning in a single-line
//! log view. Cursor movement, erase, and OSC sequences (including OSC-8
//! hyperlinks) are consumed and dropped: full terminal emulation is out
//! of scope. Carriage return and backspace follow the overwrite semantics
//! a terminal would show for a single line.

const std = @import("std");

/// An 8-bit RGB color parsed from an SGR sequence.
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// Text attributes active for a run of console text.
pub const Attrs = struct {
    fg: ?Rgb = null,
    bg: ?Rgb = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
    hidden: bool = false,

    pub const default: Attrs = .{};

    pub fn isEmpty(self: Attrs) bool {
        return std.meta.eql(self, default);
    }
};

/// A contiguous span of text sharing one attribute set.
pub const Run = struct {
    text: []const u8,
    attrs: Attrs,
};

/// One parsed console line. `runs` slice into `text`; deinit frees both.
pub const Line = struct {
    text: []u8,
    runs: []const Run,

    pub fn deinit(self: *Line, allocator: std.mem.Allocator) void {
        // Empty lines reuse static storage and were never allocated.
        if (self.text.len > 0) allocator.free(self.text);
        if (self.runs.len > 0) allocator.free(self.runs);
        self.* = undefined;
    }
};

/// The standard 16-color ANSI palette (xterm defaults).
pub const palette16 = [16]Rgb{
    .{ .r = 0x00, .g = 0x00, .b = 0x00 },
    .{ .r = 0xcd, .g = 0x00, .b = 0x00 },
    .{ .r = 0x00, .g = 0xcd, .b = 0x00 },
    .{ .r = 0xcd, .g = 0xcd, .b = 0x00 },
    .{ .r = 0x00, .g = 0x00, .b = 0xee },
    .{ .r = 0xcd, .g = 0x00, .b = 0xcd },
    .{ .r = 0x00, .g = 0xcd, .b = 0xcd },
    .{ .r = 0xe5, .g = 0xe5, .b = 0xe5 },
    .{ .r = 0x7f, .g = 0x7f, .b = 0x7f },
    .{ .r = 0xff, .g = 0x00, .b = 0x00 },
    .{ .r = 0x00, .g = 0xff, .b = 0x00 },
    .{ .r = 0xff, .g = 0xff, .b = 0x00 },
    .{ .r = 0x5c, .g = 0x5c, .b = 0xee },
    .{ .r = 0xff, .g = 0x00, .b = 0xff },
    .{ .r = 0x00, .g = 0xff, .b = 0xff },
    .{ .r = 0xff, .g = 0xff, .b = 0xff },
};

/// Maps a 256-color palette index to RGB (xterm cube/grayscale scheme).
pub fn color256(index: u8) Rgb {
    if (index < 16) return palette16[index];
    if (index < 232) {
        const cube = [_]u8{ 0, 95, 135, 175, 215, 255 };
        const value = index - 16;
        return .{
            .r = cube[@intCast(value / 36)],
            .g = cube[@intCast(value % 36 / 6)],
            .b = cube[@intCast(value % 6)],
        };
    }
    const gray = 8 + (@as(u16, index) - 232) * 10;
    const byte: u8 = @intCast(@min(gray, 255));
    return .{ .r = byte, .g = byte, .b = byte };
}

/// Returns the index just past an escape sequence starting at `index`,
/// or null when `index` does not start one. An unterminated sequence at
/// the end of the input consumes the remainder so partial frames never
/// leak control bytes into the view.
pub fn skipSequence(input: []const u8, index: usize) ?usize {
    if (input[index] != 0x1b) return null;
    if (index + 1 >= input.len) return input.len;
    switch (input[index + 1]) {
        '[' => {
            var end = index + 2;
            while (end < input.len) : (end += 1) {
                const final = input[end];
                if (final >= 0x40 and final <= 0x7e) return end + 1;
            }
            return input.len;
        },
        ']' => {
            var end = index + 2;
            while (end < input.len) : (end += 1) {
                if (input[end] == 0x07) return end + 1;
                if (input[end] == 0x1b and end + 1 < input.len and input[end + 1] == '\\')
                    return end + 2;
            }
            return input.len;
        },
        else => return index + 2,
    }
}

/// True when the escape sequence spanning `start..end` is a CSI SGR
/// sequence (final byte 'm'), whose parameters change text attributes.
fn isSgrSequence(input: []const u8, start: usize, end: usize) bool {
    return end > start + 2 and end <= input.len and
        input[start + 1] == '[' and input[end - 1] == 'm';
}

/// Collects SGR numeric parameters separated by ';' or ':'. Empty fields
/// mean 0, matching terminal behavior; trailing private markers collapse
/// to 0 (reset) which is harmless for the attributes kept here.
fn parseParams(text: []const u8, out: []i32) usize {
    var count: usize = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= text.len) : (index += 1) {
        if (index < text.len and text[index] != ';' and text[index] != ':') continue;
        if (count >= out.len) break;
        out[count] = if (index == start) 0 else std.fmt.parseInt(i32, text[start..index], 10) catch 0;
        count += 1;
        start = index + 1;
    }
    return count;
}

fn clampU8(value: i32) u8 {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return @intCast(value);
}

/// Applies one SGR parameter list to the running attribute state.
fn applySgr(attrs: *Attrs, params: []const i32) void {
    if (params.len == 0) {
        attrs.* = .default;
        return;
    }
    var index: usize = 0;
    while (index < params.len) : (index += 1) {
        switch (params[index]) {
            0 => attrs.* = .default,
            1 => attrs.bold = true,
            2 => attrs.dim = true,
            3 => attrs.italic = true,
            4 => attrs.underline = true,
            7 => attrs.inverse = true,
            8 => attrs.hidden = true,
            21, 22 => {
                attrs.bold = false;
                attrs.dim = false;
            },
            23 => attrs.italic = false,
            24 => attrs.underline = false,
            27 => attrs.inverse = false,
            28 => attrs.hidden = false,
            30...37 => attrs.fg = palette16[@intCast(params[index] - 30)],
            38, 48 => {
                const is_fg = params[index] == 38;
                if (index + 1 < params.len) {
                    switch (params[index + 1]) {
                        5 => {
                            if (index + 2 < params.len) {
                                const color = color256(clampU8(params[index + 2]));
                                if (is_fg) attrs.fg = color else attrs.bg = color;
                                index += 2;
                            }
                        },
                        2 => {
                            if (index + 4 < params.len) {
                                const color = Rgb{
                                    .r = clampU8(params[index + 2]),
                                    .g = clampU8(params[index + 3]),
                                    .b = clampU8(params[index + 4]),
                                };
                                if (is_fg) attrs.fg = color else attrs.bg = color;
                                index += 4;
                            }
                        },
                        else => {},
                    }
                }
            },
            39 => attrs.fg = null,
            40...47 => attrs.bg = palette16[@intCast(params[index] - 40)],
            49 => attrs.bg = null,
            90...97 => attrs.fg = palette16[@intCast(params[index] - 90 + 8)],
            100...107 => attrs.bg = palette16[@intCast(params[index] - 100 + 8)],
            else => {},
        }
    }
}

const Cell = struct {
    codepoint: u21,
    attrs: Attrs,
};

fn putCell(
    cells: *std.ArrayListUnmanaged(Cell),
    allocator: std.mem.Allocator,
    column: usize,
    cell: Cell,
) !void {
    if (column == cells.items.len) {
        try cells.append(allocator, cell);
    } else {
        cells.items[column] = cell;
    }
}

/// Builds the visible cell row for one logical console line. Carriage
/// return rewinds the write column and backspace steps it back so later
/// text overwrites earlier text exactly like a terminal repaint would.
fn parseCells(allocator: std.mem.Allocator, raw: []const u8) !std.ArrayListUnmanaged(Cell) {
    var cells: std.ArrayListUnmanaged(Cell) = .empty;
    errdefer cells.deinit(allocator);
    var attrs = Attrs.default;
    var column: usize = 0;
    var index: usize = 0;
    var params: [16]i32 = undefined;

    while (index < raw.len) {
        const byte = raw[index];
        if (byte == 0x1b) {
            const end = skipSequence(raw, index) orelse break;
            if (isSgrSequence(raw, index, end)) {
                const count = parseParams(raw[index + 2 .. end - 1], &params);
                applySgr(&attrs, params[0..count]);
            }
            index = end;
            continue;
        }
        switch (byte) {
            '\n' => break, // A frame line ends at the first newline.
            '\r' => column = 0,
            0x08 => column = column -| 1,
            '\t' => {
                const stop = (column / 8 + 1) * 8;
                while (column < stop) : (column += 1) {
                    try putCell(&cells, allocator, column, .{ .codepoint = ' ', .attrs = attrs });
                }
            },
            else => {
                if (byte < 0x20 or byte == 0x7f) {
                    index += 1;
                    continue;
                }
                var codepoint: u21 = 0xFFFD;
                var width: usize = 1;
                if (byte < 0x80) {
                    codepoint = byte;
                } else if (std.unicode.utf8ByteSequenceLength(byte)) |length| {
                    const span: usize = length;
                    if (index + span <= raw.len) {
                        if (std.unicode.utf8Decode(raw[index..][0..span])) |decoded| {
                            codepoint = decoded;
                            width = span;
                        } else |_| {}
                    }
                } else |_| {}
                try putCell(&cells, allocator, column, .{ .codepoint = codepoint, .attrs = attrs });
                column += 1;
                index += width;
                continue;
            },
        }
        index += 1;
    }
    return cells;
}

/// Parses one console line into visible text plus styled runs. Escape
/// sequences never survive into the returned text.
pub fn renderLine(allocator: std.mem.Allocator, raw: []const u8) !Line {
    var cells = try parseCells(allocator, raw);
    defer cells.deinit(allocator);

    if (cells.items.len == 0) {
        return .{
            .text = @constCast(@as([]const u8, "")),
            .runs = &[_]Run{},
        };
    }

    var text: std.ArrayListUnmanaged(u8) = .empty;
    errdefer text.deinit(allocator);
    for (cells.items) |cell| {
        var buffer: [4]u8 = undefined;
        const encoded = std.unicode.utf8Encode(cell.codepoint, &buffer) catch {
            buffer[0] = '?';
            try text.appendSlice(allocator, buffer[0..1]);
            continue;
        };
        try text.appendSlice(allocator, buffer[0..encoded]);
    }
    // Take ownership before slicing: a shrinking realloc could move the
    // buffer, and every run must reference the final location.
    const owned_text = try text.toOwnedSlice(allocator);
    errdefer allocator.free(owned_text);

    var runs: std.ArrayListUnmanaged(Run) = .empty;
    errdefer runs.deinit(allocator);
    var run_start: usize = 0;
    var run_attrs: Attrs = cells.items[0].attrs;
    var offset: usize = 0;
    for (cells.items) |cell| {
        // Cells only carry scalars or the replacement character, so this
        // mirrors the encode pass byte-for-byte (surrogates measure 1).
        const length = std.unicode.utf8CodepointSequenceLength(cell.codepoint) catch 1;
        if (!std.meta.eql(run_attrs, cell.attrs)) {
            try runs.append(allocator, .{ .text = owned_text[run_start..offset], .attrs = run_attrs });
            run_start = offset;
            run_attrs = cell.attrs;
        }
        offset += length;
    }
    try runs.append(allocator, .{ .text = owned_text[run_start..offset], .attrs = run_attrs });

    return .{
        .text = owned_text,
        .runs = try runs.toOwnedSlice(allocator),
    };
}

/// Visible text of one console line without any styling information.
/// Deduplication and label rendering key on this stripped form. The
/// result is always allocator-owned so callers can free it uniformly.
pub fn stripLine(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const line = try renderLine(allocator, raw);
    if (line.runs.len > 0) allocator.free(line.runs);
    if (line.text.len == 0) return allocator.dupe(u8, "");
    return line.text;
}

/// Best-effort stack-buffer stripping for short label texts. Drops
/// escape sequences and control bytes but does not emulate carriage
/// return/backspace overwrites like renderLine does.
pub fn stripToBuffer(buffer: []u8, raw: []const u8) []const u8 {
    var count: usize = 0;
    var index: usize = 0;
    while (index < raw.len and count < buffer.len) {
        if (raw[index] == 0x1b) {
            index = skipSequence(raw, index) orelse raw.len;
            continue;
        }
        const byte = raw[index];
        if (byte >= 0x20 and byte != 0x7f) {
            buffer[count] = byte;
            count += 1;
        }
        index += 1;
    }
    return buffer[0..count];
}

const testing = std.testing;

fn rgb(r: u8, g: u8, b: u8) Rgb {
    return .{ .r = r, .g = g, .b = b };
}

test "renderLine keeps plain text as a single default run" {
    var line = try renderLine(testing.allocator, "creating package foo-1.0-1-x86_64");
    defer line.deinit(testing.allocator);
    try testing.expectEqualStrings("creating package foo-1.0-1-x86_64", line.text);
    try testing.expectEqual(@as(usize, 1), line.runs.len);
    try testing.expect(line.runs[0].attrs.isEmpty());
}

test "renderLine parses foreground colors and resets" {
    var line = try renderLine(testing.allocator, "\x1b[31merror\x1b[0m: install failed");
    defer line.deinit(testing.allocator);
    try testing.expectEqualStrings("error: install failed", line.text);
    try testing.expectEqual(@as(usize, 2), line.runs.len);
    try testing.expectEqualStrings("error", line.runs[0].text);
    try testing.expectEqual(palette16[1], line.runs[0].attrs.fg.?);
    try testing.expectEqualStrings(": install failed", line.runs[1].text);
    try testing.expect(line.runs[1].attrs.isEmpty());
}

test "renderLine maps bright, background, and style codes" {
    var line = try renderLine(testing.allocator, "\x1b[1;4;93;44mwarn\x1b[0m");
    defer line.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), line.runs.len);
    const attrs = line.runs[0].attrs;
    try testing.expect(attrs.bold);
    try testing.expect(attrs.underline);
    try testing.expectEqual(palette16[11], attrs.fg.?);
    try testing.expectEqual(palette16[4], attrs.bg.?);
}

test "renderLine supports 256-color and truecolor parameters" {
    var line = try renderLine(testing.allocator, "\x1b[38;5;196mred\x1b[38;2;10;20;30mteal\x1b[0m");
    defer line.deinit(testing.allocator);
    try testing.expectEqualStrings("redteal", line.text);
    try testing.expectEqual(rgb(0xff, 0x00, 0x00), line.runs[0].attrs.fg.?);
    try testing.expectEqual(rgb(10, 20, 30), line.runs[1].attrs.fg.?);
}

test "renderLine drops OSC-8 hyperlinks but keeps the link text" {
    const bel = "see \x1b]8;;https://example.com\x07docs\x1b]8;;\x07 now";
    const st = "see \x1b]8;;https://example.com\x1b\\docs\x1b]8;;\x1b\\ now";
    for ([_][]const u8{ bel, st }) |raw| {
        var line = try renderLine(testing.allocator, raw);
        defer line.deinit(testing.allocator);
        try testing.expectEqualStrings("see docs now", line.text);
        try testing.expect(line.runs[0].attrs.isEmpty());
    }
}

test "renderLine drops cursor and erase control sequences" {
    var line = try renderLine(testing.allocator, "work\x1b[2K\x1b[1A\x1b[?25l ing");
    defer line.deinit(testing.allocator);
    try testing.expectEqualStrings("work ing", line.text);
}

test "renderLine applies terminal overwrite semantics for CR and BS" {
    var line = try renderLine(testing.allocator, "100% complete\r50%");
    defer line.deinit(testing.allocator);
    try testing.expectEqualStrings("50%% complete", line.text);

    var backspace = try renderLine(testing.allocator, "abcde\x08XY");
    defer backspace.deinit(testing.allocator);
    try testing.expectEqualStrings("abcdXY", backspace.text);
}

test "renderLine stops at the first newline and expands tabs" {
    var line = try renderLine(testing.allocator, "first\nsecond");
    defer line.deinit(testing.allocator);
    try testing.expectEqualStrings("first", line.text);

    var tabbed = try renderLine(testing.allocator, "a\tb");
    defer tabbed.deinit(testing.allocator);
    try testing.expectEqualStrings("a       b", tabbed.text);
}

test "renderLine drops incomplete trailing escape sequences" {
    for ([_][]const u8{
        "done\x1b",
        "done\x1b[3",
        "done\x1b[31",
        "done\x1b]8;;https://ex",
    }) |raw| {
        var line = try renderLine(testing.allocator, raw);
        defer line.deinit(testing.allocator);
        try testing.expectEqualStrings("done", line.text);
    }
}

test "renderLine preserves UTF-8 and replaces invalid bytes" {
    var line = try renderLine(testing.allocator, "\x1b[32mΩ≈ç√ → ok\x1b[0m");
    defer line.deinit(testing.allocator);
    try testing.expectEqualStrings("Ω≈ç√ → ok", line.text);
    try testing.expectEqual(palette16[2], line.runs[0].attrs.fg.?);

    var broken = try renderLine(testing.allocator, "ab\xFFcd");
    defer broken.deinit(testing.allocator);
    try testing.expectEqualStrings("ab\u{FFFD}cd", broken.text);
}

test "stripLine removes styling and is idempotent" {
    const colored = "\x1b[1;33m==> WARNING\x1b[0m \x1b]8;;https://archlinux.org\x07docs\x1b]8;;\x07";
    const first = try stripLine(testing.allocator, colored);
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("==> WARNING docs", first);

    const second = try stripLine(testing.allocator, first);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);
}

test "color256 converts cube and grayscale entries" {
    try testing.expectEqual(palette16[3], color256(3));
    try testing.expectEqual(rgb(0, 0, 0), color256(16));
    try testing.expectEqual(rgb(255, 0, 0), color256(196));
    try testing.expectEqual(rgb(255, 255, 255), color256(231));
    try testing.expectEqual(rgb(8, 8, 8), color256(232));
    try testing.expectEqual(rgb(238, 238, 238), color256(255));
}

test "stripToBuffer drops sequences and controls without allocation" {
    var buffer: [64]u8 = undefined;
    const stripped = stripToBuffer(&buffer, "\x1b[31mfailed\x1b[0m\x1b]8;;url\x07 \x07!");
    try testing.expectEqualStrings("failed !", stripped);

    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("fail", stripToBuffer(&tiny, "failed \x1b[0m"));
}
