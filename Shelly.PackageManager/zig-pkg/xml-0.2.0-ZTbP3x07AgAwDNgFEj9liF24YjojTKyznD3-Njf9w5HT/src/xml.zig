const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqualStrings = std.testing.expectEqualStrings;

const xml = @This();

/// A line and column position in an XML document.
///
/// The meaning of "column" is chosen by the function used to update the
/// location in the reader.
pub const Location = struct {
    line: usize,
    column: usize,

    pub const start: Location = .{ .line = 1, .column = 1 };

    /// A function which updates a location from the beginning of a document
    /// slice to its end.
    pub const UpdateFn = *const fn (*Location, []const u8) void;

    /// Updates the location, using bytes (UTF-8 code units) when counting
    /// columns.
    pub fn updateBytes(loc: *Location, s: []const u8) void {
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, s, pos, '\n')) |nl_pos| {
            loc.line += 1;
            loc.column = 1;
            pos = nl_pos + 1;
        }
        loc.column += s.len - pos;
    }

    test updateBytes {
        var static_reader: xml.Reader.Static = .init(std.testing.allocator,
            \\<root>こんにちは</root>
        , .{ .updateLocation = xml.Location.updateBytes });
        defer static_reader.deinit();
        const reader = &static_reader.interface;

        try expectEqual(.element_start, try reader.read());
        try expectEqualDeep(Location{ .line = 1, .column = 1 }, reader.location());

        try expectEqual(.text, try reader.read());
        try expectEqualDeep(Location{ .line = 1, .column = 7 }, reader.location());

        try expectEqual(.element_end, try reader.read());
        try expectEqualDeep(Location{ .line = 1, .column = 22 }, reader.location());

        try expectEqual(.eof, try reader.read());
        try expectEqualDeep(Location{ .line = 1, .column = 29 }, reader.location());
    }

    /// Updates the location, using Unicode codepoints when counting columns.
    pub fn updateCodepoints(loc: *Location, s: []const u8) void {
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, s, pos, '\n')) |nl_pos| {
            loc.line += 1;
            loc.column = 1;
            pos = nl_pos + 1;
        }
        while (pos < s.len) {
            pos += std.unicode.utf8ByteSequenceLength(s[pos]) catch 1;
            loc.column += 1;
        }
    }

    test updateCodepoints {
        var static_reader: xml.Reader.Static = .init(std.testing.allocator,
            \\<root>こんにちは</root>
        , .{ .updateLocation = xml.Location.updateCodepoints });
        defer static_reader.deinit();
        const reader = &static_reader.interface;

        try expectEqual(.element_start, try reader.read());
        try expectEqualDeep(Location{ .line = 1, .column = 1 }, reader.location());

        try expectEqual(.text, try reader.read());
        try expectEqualDeep(Location{ .line = 1, .column = 7 }, reader.location());

        try expectEqual(.element_end, try reader.read());
        try expectEqualDeep(Location{ .line = 1, .column = 12 }, reader.location());

        try expectEqual(.eof, try reader.read());
        try expectEqualDeep(Location{ .line = 1, .column = 19 }, reader.location());
    }

    pub fn format(loc: Location, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{}:{}", .{ loc.line, loc.column });
    }

    test format {
        const loc: Location = .{ .line = 45, .column = 5 };
        var buf: [4]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{f}", .{loc});
        try expectEqualStrings("45:5", s);
    }
};

pub const QName = struct {
    ns: []const u8,
    local: []const u8,

    pub fn is(qname: QName, ns: []const u8, local: []const u8) bool {
        return std.mem.eql(u8, qname.ns, ns) and std.mem.eql(u8, qname.local, local);
    }
};

pub const PrefixedQName = struct {
    prefix: []const u8,
    ns: []const u8,
    local: []const u8,

    pub fn is(qname: PrefixedQName, ns: []const u8, local: []const u8) bool {
        return std.mem.eql(u8, qname.ns, ns) and std.mem.eql(u8, qname.local, local);
    }
};

pub const predefined_entities = std.StaticStringMap([]const u8).initComptime(.{
    .{ "lt", "<" },
    .{ "gt", ">" },
    .{ "amp", "&" },
    .{ "apos", "'" },
    .{ "quot", "\"" },
});

pub const ns_xml = "http://www.w3.org/XML/1998/namespace";
pub const ns_xmlns = "http://www.w3.org/2000/xmlns/";
pub const predefined_namespace_uris = std.StaticStringMap([]const u8).initComptime(.{
    .{ "xml", ns_xml },
    .{ "xmlns", ns_xmlns },
});
pub const predefined_namespace_prefixes = std.StaticStringMap([]const u8).initComptime(.{
    .{ ns_xml, "xml" },
    .{ ns_xmlns, "xmlns" },
});

pub const Reader = @import("Reader.zig");
pub const Writer = @import("Writer.zig");

test {
    _ = Location;
    _ = QName;
    _ = PrefixedQName;
    _ = Reader;
    _ = Writer;
}
