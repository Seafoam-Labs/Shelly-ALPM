//! A streaming XML parser, aiming to conform to the [XML 1.0 (Fifth
//! Edition)](https://www.w3.org/TR/2008/REC-xml-20081126) and [Namespaces in
//! XML 1.0 (Third Edition)](https://www.w3.org/TR/2009/REC-xml-names-20091208/)
//! specifications.
//!
//! Calling `read` returns the next `Node` in the document, and other reader
//! functions specific to each node type can be used to obtain more information
//! about the current node. The convention is that functions associated with a
//! specific node type have names starting with the node type (and `attribute`
//! functions can only be called on an `element_start` node).
//!
//! The names of the reader functions which return information about the current
//! `Node` carry information about their behavior and the lifetime of any
//! returned memory:
//!
//! - Memory returned by functions whose names end in `Alloc` is allocated using
//!   a provided allocator and owned by the caller.
//! - Memory returned by functions whose names do not end in `Alloc` is owned by
//!   the `Reader` and is only valid until the next call to another reader
//!   function.
//!   - Functions such as `attributeValue` which only conditionally allocate
//!     store any allocated data in a scratch buffer in the reader which is
//!     cleared on every call to such a function.
//! - Functions whose names end in `Write` write their results into a
//!   `std.Io.Writer`.
//! - Functions whose names end in `Ns` may only be called on a `Reader`
//!   configured as namespace-aware. Namespace awareness is on by default in
//!   `Options`.
//! - Functions whose names end in `Raw` return values as they appear in the
//!   source document, which may not match the value required to be exposed by
//!   the XML standard (for example, attribute values returned by
//!   `attributeValueRaw` may contain unexpanded character and entity
//!   references).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const expectError = std.testing.expectError;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqualStrings = std.testing.expectEqualStrings;

const xml = @import("xml.zig");
const Location = xml.Location;
const QName = xml.QName;
const PrefixedQName = xml.PrefixedQName;
const predefined_entities = xml.predefined_entities;
const predefined_namespace_uris = xml.predefined_namespace_uris;
const ns_xml = xml.ns_xml;
const ns_xmlns = xml.ns_xmlns;

options: Options,

state: State,
/// An array of buffer spans relevant to the current node.
/// The layout of the spans depends on the node type:
/// - `eof` - none
/// - `xml_declaration` - "xml" (NAME VALUE)...
/// - `element_start` - NAME (NAME VALUE)...
/// - `element_end` - NAME
/// - `comment` - COMMENT
/// - `pi` - TARGET DATA
/// - `text` - none
/// - `cdata` - CDATA
/// - `character_reference` - REF
/// - `entity_reference` - REF
spans: std.ArrayListUnmanaged(BufSpan),
/// A map of attribute names to indexes.
/// The keys are slices into `buf`.
attributes: std.StringArrayHashMapUnmanaged(usize),
/// A map of attribute qnames to indexes.
/// The key `ns` and `local` values are slices into `buf`.
q_attributes: std.ArrayHashMapUnmanaged(QName, usize, QNameContext, true),
/// String data for the current element nesting context.
/// Each element start node appends the name of the element to this buffer, and
/// the element name is followed by any namespace prefixes and URIs declared on
/// the element so they can be referenced by `ns_prefixes`.
strings: std.ArrayListUnmanaged(u8),
/// The start indexes of the element names in `strings`.
element_names: std.ArrayListUnmanaged(StringIndex),
/// The namespace prefixes declared by the current nesting context of elements.
ns_prefixes: std.ArrayListUnmanaged(std.AutoArrayHashMapUnmanaged(StringIndex, StringIndex)),
/// The Unicode code point associated with the current character reference.
character: u21,

vtable: *const VTable,
/// The source location of the beginning of `buf`.
loc: Location,
/// Buffered data read from `source`.
buf: []const u8,
/// The current position of the reader in `buf`.
pos: usize,

/// The last node returned by `read` (that is, the current node).
node: ?Node,
/// The current error code (only valid if `read` returned `error.MalformedXml`).
error_code: ErrorCode,
/// The position of the current error in `buf`.
error_pos: usize,

scratch: std.Io.Writer.Allocating,

gpa: Allocator,

const Reader = @This();

pub const Options = struct {
    /// Whether the reader should handle namespaces in element and attribute
    /// names. The `Ns`-suffixed functions of `Reader` may only be used when
    /// this is enabled.
    namespace_aware: bool = true,
    /// The function to use to update the reader's current location in the
    /// document. This may be set to null, in which case the reader is not
    /// location-aware, and using functions which access the location are
    /// checked illegal behavior.
    updateLocation: ?xml.Location.UpdateFn = xml.Location.updateBytes,
    /// Whether the reader may assume that its input data is valid UTF-8.
    assume_valid_utf8: bool = false,
};

pub const Node = enum {
    eof,
    xml_declaration,
    element_start,
    element_end,
    comment,
    pi,
    text,
    cdata,
    character_reference,
    entity_reference,
};

pub const ErrorCode = enum {
    xml_declaration_attribute_unsupported,
    xml_declaration_version_missing,
    xml_declaration_version_unsupported,
    xml_declaration_encoding_unsupported,
    xml_declaration_standalone_malformed,
    doctype_unsupported,
    directive_unknown,
    attribute_missing_space,
    attribute_duplicate,
    attribute_prefix_undeclared,
    attribute_illegal_character,
    element_end_mismatched,
    element_end_unclosed,
    comment_malformed,
    comment_unclosed,
    pi_unclosed,
    pi_target_disallowed,
    pi_missing_space,
    text_cdata_end_disallowed,
    cdata_unclosed,
    entity_reference_unclosed,
    entity_reference_undefined,
    character_reference_unclosed,
    character_reference_malformed,
    name_malformed,
    namespace_prefix_unbound,
    namespace_binding_illegal,
    namespace_prefix_illegal,
    unexpected_character,
    unexpected_eof,
    expected_equals,
    expected_quote,
    missing_end_quote,
    invalid_encoding,
    illegal_character,
};

pub const VTable = struct {
    /// Moves the start of the window forward by `advance` bytes and sets the
    /// length of the window from the new starting position to `len` bytes, or
    /// until the end of the document if it contains fewer than `len` bytes from
    /// the starting position. Returns a slice of the underlying UTF-8 document
    /// content in the window.
    ///
    /// The new start of the window must not exceed the document's length.
    move: *const fn (reader: *Reader, advance: usize, len: usize) MoveError!void,
    /// Returns whether `encoding` is a supported value for the encoding in the
    /// XML declaration.
    ///
    /// At least one call to `moveFn` must be made before calling this function.
    checkEncoding: *const fn (reader: *Reader, encoding: []const u8) bool,
};

pub const MoveError = error{ReadFailed};

fn move(reader: *Reader, advance: usize, len: usize) MoveError!void {
    return reader.vtable.move(reader, advance, len);
}

fn checkEncoding(reader: *Reader, encoding: []const u8) bool {
    return reader.vtable.checkEncoding(reader, encoding);
}

pub fn checkEncodingUtf8(reader: *Reader, encoding: []const u8) bool {
    _ = reader;
    return std.ascii.eqlIgnoreCase(encoding, "UTF-8");
}

const State = enum {
    invalid,
    start,
    after_xml_declaration,
    after_doctype,
    in_root,
    empty_element,
    empty_root,
    after_root,
    eof,
};

/// Reads from a UTF-8 encoded XML document stored entirely in memory.
pub const Static = struct {
    data: []const u8,
    pos: usize,
    interface: Reader,

    pub fn init(gpa: Allocator, data: []const u8, options: Options) Static {
        return .{
            .data = data,
            .pos = 0,
            .interface = .init(gpa, options, &.{
                .move = &Static.move,
                .checkEncoding = &checkEncodingUtf8,
            }),
        };
    }

    pub fn deinit(reader: *Static) void {
        reader.interface.deinit();
        reader.* = undefined;
    }

    fn move(reader: *Reader, advance: usize, len: usize) MoveError!void {
        const self: *Static = @alignCast(@fieldParentPtr("interface", reader));
        self.pos += advance;
        const data = self.data[self.pos..];
        reader.buf = data[0..@min(len, data.len)];
    }
};

test Static {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<?xml version="1.0"?>
        \\<root>Hello, 世界 👋!</root>
        \\
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.xml_declaration, try reader.read());
    try expectEqualStrings("1.0", reader.xmlDeclarationVersion());

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.text, try reader.read());
    try expectEqualStrings("Hello, 世界 👋!", reader.textRaw());

    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.eof, try reader.read());
}

/// Reads a UTF-8 or UTF-16 encoded XML document from a `std.Io.Reader`.
pub const Streaming = struct {
    in: *std.Io.Reader,
    state: enum {
        start,
        utf8,
        utf16be,
        utf16le,
    },
    err: ?StreamError = null,

    transcode_buf: [3]u8,
    transcode_buf_len: u2,

    buf: []u8,
    pos: usize,
    avail: usize,
    gpa: Allocator,

    interface: Reader,

    pub const StreamError = error{
        /// An error occurred when reading from the input reader. Consult the
        /// input reader's state for more detailed information.
        ReadFailed,
        /// Ran out of memory when trying to grow the internal buffer.
        OutOfMemory,
    };

    /// Asserts that `in` has a buffer of at least 2 bytes.
    pub fn init(gpa: Allocator, in: *std.Io.Reader, options: Options) @This() {
        assert(in.buffer.len >= 2);
        return .{
            .in = in,
            .state = .start,

            .transcode_buf = undefined,
            .transcode_buf_len = 0,

            .buf = &.{},
            .pos = 0,
            .avail = 0,
            .gpa = gpa,

            .interface = .init(gpa, options, &.{
                .move = &Streaming.move,
                .checkEncoding = &Streaming.checkEncoding,
            }),
        };
    }

    pub fn deinit(reader: *Streaming) void {
        reader.gpa.free(reader.buf);
        reader.interface.deinit();
        reader.* = undefined;
    }

    fn move(reader: *Reader, advance: usize, len: usize) MoveError!void {
        const self: *Streaming = @alignCast(@fieldParentPtr("interface", reader));
        self.pos += advance;
        if (len <= self.avail - self.pos) {
            reader.buf = self.buf[self.pos..][0..len];
            return;
        }
        self.discardRead();
        self.fillBuffer(len) catch |err| {
            self.err = err;
            return error.ReadFailed;
        };
        reader.buf = self.buf[0..@min(len, self.avail)];
    }

    fn discardRead(reader: *Streaming) void {
        reader.avail -= reader.pos;
        std.mem.copyForwards(u8, reader.buf[0..reader.avail], reader.buf[reader.pos..][0..reader.avail]);
        reader.pos = 0;
    }

    const min_buf_len = 4096;

    fn fillBuffer(reader: *Streaming, target_len: usize) StreamError!void {
        if (target_len > reader.buf.len) {
            const new_buf_len = @max(min_buf_len, std.math.ceilPowerOfTwoAssert(usize, target_len));
            reader.buf = try reader.gpa.realloc(reader.buf, new_buf_len);
        }
        read: switch (reader.state) {
            .start => {
                const start = reader.in.peek(2) catch |err| switch (err) {
                    error.ReadFailed => return error.ReadFailed,
                    error.EndOfStream => {
                        reader.state = .utf8;
                        continue :read reader.state;
                    },
                };
                if (std.mem.eql(u8, start, "\xFE\xFF")) {
                    reader.in.toss(2);
                    reader.state = .utf16be;
                } else if (std.mem.eql(u8, start, "\xFF\xFE")) {
                    reader.in.toss(2);
                    reader.state = .utf16le;
                } else {
                    reader.state = .utf8;
                }
                continue :read reader.state;
            },
            .utf8 => {
                reader.avail += try reader.in.readSliceShort(reader.buf[reader.avail..]);
            },
            .utf16be => {
                try reader.fillBufferUtf16(.big);
            },
            .utf16le => {
                try reader.fillBufferUtf16(.little);
            },
        }
    }

    /// Transcodes UTF-16 from the input buffer into UTF-8 in the document
    /// buffer. Invalid UTF-16 is transcoded to invalid UTF-8.
    fn fillBufferUtf16(reader: *Streaming, endian: std.builtin.Endian) !void {
        if (reader.transcode_buf_len > 0) {
            const can_copy = @min(reader.transcode_buf_len, reader.buf.len - reader.avail);
            @memcpy(reader.buf[reader.avail..][0..can_copy], reader.transcode_buf[0..can_copy]);
            std.mem.copyForwards(u8, &reader.transcode_buf, reader.transcode_buf[can_copy..]);
            reader.transcode_buf_len -= can_copy;
            reader.avail += can_copy;
        }

        while (reader.avail < reader.buf.len) {
            const cp: u21 = cp: {
                const u = reader.in.takeInt(u16, endian) catch |err| switch (err) {
                    error.ReadFailed => return error.ReadFailed,
                    error.EndOfStream => {
                        // We have to check if we have an odd input length here
                        // and, if so, produce invalid UTF-8 (an unpaired high
                        // surrogate).
                        if (reader.in.takeByte()) |b| {
                            break :cp 0xD800 + @as(u16, b);
                        } else |e| switch (e) {
                            error.ReadFailed => return error.ReadFailed,
                            error.EndOfStream => break,
                        }
                    },
                };
                if (!std.unicode.utf16IsHighSurrogate(u)) break :cp u;
                const low = reader.in.takeInt(u16, endian) catch |err| switch (err) {
                    error.ReadFailed => return error.ReadFailed,
                    error.EndOfStream => break :cp u,
                };
                break :cp std.unicode.utf16DecodeSurrogatePair(&.{ u, low }) catch u;
            };

            // No error is possible since the codepoint was decoded from
            // UTF-16, so it can't be too large (and utf8CodepointSequenceLength
            // doesn't check for unpaired surrogates).
            const enc_len = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
            if (reader.avail + enc_len <= reader.buf.len) {
                // Happy path: encode directly into the available buffer.
                @branchHint(.likely);
                _ = std.unicode.wtf8Encode(cp, reader.buf[reader.avail..]) catch unreachable;
                reader.avail += enc_len;
            } else {
                // Encode into a temporary buffer and keep what we can't
                // encode in the transcode buffer.
                const can_encode = reader.buf.len - reader.avail;
                var buf: [4]u8 = undefined;
                _ = std.unicode.wtf8Encode(cp, &buf) catch unreachable;
                @memcpy(reader.buf[reader.avail..][0..can_encode], buf[0..can_encode]);
                reader.avail += can_encode;
                const must_store = enc_len - can_encode;
                @memcpy(reader.transcode_buf[0..must_store], buf[can_encode..][0..must_store]);
                reader.transcode_buf_len = @intCast(must_store);
            }
        }
    }

    fn checkEncoding(reader: *Reader, encoding: []const u8) bool {
        const self: *const Streaming = @alignCast(@fieldParentPtr("interface", reader));
        return switch (self.state) {
            .start => unreachable, // Can't check encoding before reading anything.
            .utf8 => std.ascii.eqlIgnoreCase(encoding, "UTF-8"),
            .utf16be, .utf16le => std.ascii.eqlIgnoreCase(encoding, "UTF-16"),
        };
    }
};

test Streaming {
    var bytes: std.Io.Reader = .fixed(
        \\<?xml version="1.0"?>
        \\<root>Hello, 世界 👋!</root>
        \\
    );
    var streaming_reader: xml.Reader.Streaming = .init(std.testing.allocator, &bytes, .{});
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    try expectEqual(.xml_declaration, try reader.read());
    try expectEqualStrings("1.0", reader.xmlDeclarationVersion());

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.text, try reader.read());
    try expectEqualStrings("Hello, 世界 👋!", reader.textRaw());

    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.eof, try reader.read());
}

test "streaming with UTF-16BE" {
    try testStreamingUtf16(.big);
}

test "streaming with UTF-16LE" {
    try testStreamingUtf16(.little);
}

fn testStreamingUtf16(comptime endian: std.builtin.Endian) !void {
    var bytes: std.Io.Reader = .fixed(utf16BytesLiteral(endian, "\u{FEFF}" ++
        \\<?xml version="1.0"?>
        \\<root>Hello, 世界 👋!</root>
        \\
    ));
    var streaming_reader: xml.Reader.Streaming = .init(std.testing.allocator, &bytes, .{});
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    try expectEqual(.xml_declaration, try reader.read());
    try expectEqualStrings("1.0", reader.xmlDeclarationVersion());

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.text, try reader.read());
    try expectEqualStrings("Hello, 世界 👋!", reader.textRaw());

    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.eof, try reader.read());
}

inline fn utf16BytesLiteral(comptime endian: std.builtin.Endian, comptime utf8: []const u8) []const u8 {
    const utf16 = std.unicode.utf8ToUtf16LeStringLiteral(utf8);
    var utf16_bytes: [utf16.len * 2]u8 = undefined;
    for (utf16, 0..) |cu, i| {
        std.mem.writeInt(u16, utf16_bytes[i * 2 ..][0..2], cu, endian);
    }
    const utf16_bytes_final = utf16_bytes;
    return &utf16_bytes_final;
}

test "streaming with extremely long element name" {
    const name: [65536]u8 = @splat('a');
    var bytes: std.Io.Reader = .fixed("<" ++ name ++ "/>");
    var streaming_reader: xml.Reader.Streaming = .init(std.testing.allocator, &bytes, .{});
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings(&name, reader.elementName());

    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings(&name, reader.elementName());

    try expectEqual(.eof, try reader.read());
}

pub fn init(gpa: Allocator, options: Options, vtable: *const VTable) Reader {
    return .{
        .options = options,

        .state = .start,
        .spans = .empty,
        .attributes = .empty,
        .q_attributes = .empty,
        .strings = .empty,
        .element_names = .empty,
        .ns_prefixes = .empty,
        .character = undefined,

        .vtable = vtable,
        .loc = if (options.updateLocation != null) Location.start else undefined,
        .buf = &.{},
        .pos = 0,

        .node = null,
        .error_code = undefined,
        .error_pos = undefined,

        .scratch = .init(gpa),

        .gpa = gpa,
    };
}

pub fn deinit(reader: *Reader) void {
    reader.spans.deinit(reader.gpa);
    reader.attributes.deinit(reader.gpa);
    reader.q_attributes.deinit(reader.gpa);
    reader.strings.deinit(reader.gpa);
    reader.element_names.deinit(reader.gpa);
    for (reader.ns_prefixes.items) |*map| map.deinit(reader.gpa);
    reader.ns_prefixes.deinit(reader.gpa);
    reader.scratch.deinit();
    reader.* = undefined;
}

/// Returns the location of the node.
/// Asserts that the reader is location-aware and there is a current node (`read` was called and did not return an error).
pub fn location(reader: Reader) Location {
    assert(reader.options.updateLocation != null and reader.node != null);
    return reader.loc;
}

test location {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root>
        \\  <sub>Hello, world!</sub>
        \\</root>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqualDeep(Location{ .line = 1, .column = 1 }, reader.location());

    try expectEqual(.text, try reader.read());
    try expectEqualDeep(Location{ .line = 1, .column = 7 }, reader.location());

    try expectEqual(.element_start, try reader.read());
    try expectEqualDeep(Location{ .line = 2, .column = 3 }, reader.location());

    try expectEqual(.text, try reader.read());
    try expectEqualDeep(Location{ .line = 2, .column = 8 }, reader.location());

    try expectEqual(.element_end, try reader.read());
    try expectEqualDeep(Location{ .line = 2, .column = 21 }, reader.location());

    try expectEqual(.text, try reader.read());
    try expectEqualDeep(Location{ .line = 2, .column = 27 }, reader.location());

    try expectEqual(.element_end, try reader.read());
    try expectEqualDeep(Location{ .line = 3, .column = 1 }, reader.location());

    try expectEqual(.eof, try reader.read());
    try expectEqualDeep(Location{ .line = 3, .column = 8 }, reader.location());
}

/// Returns the error code associated with the error.
/// Asserts that `error.MalformedXml` was returned by the last call to `read`.
pub fn errorCode(reader: Reader) ErrorCode {
    assert(reader.state == .invalid);
    return reader.error_code;
}

test errorCode {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root>
        \\  <123>Hello, world!</123>
        \\</root>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqual(.text, try reader.read());
    try expectError(error.MalformedXml, reader.read());
    try expectEqual(.name_malformed, reader.errorCode());
}

/// Returns the location where the error occurred.
/// Asserts that the reader is location-aware and `error.MalformedXml` was returned by the last call to `read`.
pub fn errorLocation(reader: Reader) Location {
    assert(reader.state == .invalid);
    var loc = reader.loc;
    reader.options.updateLocation.?(&loc, reader.buf[0..reader.error_pos]);
    return loc;
}

test errorLocation {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root>
        \\  <123>Hello, world!</123>
        \\</root>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqual(.text, try reader.read());
    try expectError(error.MalformedXml, reader.read());
    try expectEqualDeep(Location{ .line = 2, .column = 4 }, reader.errorLocation());
}

/// Returns the version declared in the XML declaration.
/// Asserts that the current node is `Node.xml_declaration`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn xmlDeclarationVersion(reader: Reader) []const u8 {
    assert(reader.node == .xml_declaration);
    return reader.attributeValueUnchecked(0);
}

test xmlDeclarationVersion {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<?xml version="1.0"?>
        \\<root/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.xml_declaration, try reader.read());
    try expectEqualStrings("1.0", reader.xmlDeclarationVersion());
}

/// Returns the encoding declared in the XML declaration.
/// Asserts that the current node is `Node.xml_declaration`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn xmlDeclarationEncoding(reader: Reader) ?[]const u8 {
    assert(reader.node == .xml_declaration);
    const n = reader.attributes.get("encoding") orelse return null;
    return reader.attributeValueUnchecked(n);
}

test xmlDeclarationEncoding {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<root/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.xml_declaration, try reader.read());
    try expectEqualStrings("UTF-8", reader.xmlDeclarationEncoding().?);
}

/// Returns whether the XML declaration declares the document to be standalone.
/// Asserts that the current node is `Node.xml_declaration`.
pub fn xmlDeclarationStandalone(reader: Reader) ?bool {
    assert(reader.node == .xml_declaration);
    const n = reader.attributes.get("standalone") orelse return null;
    return std.mem.eql(u8, reader.attributeValueUnchecked(n), "yes");
}

test xmlDeclarationStandalone {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<root/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.xml_declaration, try reader.read());
    try expectEqual(true, reader.xmlDeclarationStandalone());
}

/// Returns the name of the element.
/// Asserts that the current node is `Node.element_start` or `Node.element_end`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn elementName(reader: Reader) []const u8 {
    assert(reader.node == .element_start or reader.node == .element_end);
    return reader.elementNameUnchecked();
}

test elementName {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("root", reader.elementName());
    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings("root", reader.elementName());
}

/// Returns the name of the element as a `PrefixedQName`.
/// Asserts that the current node is `Node.element_start` or `Node.element_end` and that `reader` is namespace-aware.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn elementNameNs(reader: Reader) PrefixedQName {
    assert(reader.options.namespace_aware);
    return reader.parseQName(reader.elementName());
}

test elementNameNs {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root xmlns="https://example.com/ns" xmlns:a="https://example.com/ns2">
        \\  <a:a/>
        \\</root>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("", reader.elementNameNs().prefix);
    try expectEqualStrings("https://example.com/ns", reader.elementNameNs().ns);
    try expectEqualStrings("root", reader.elementNameNs().local);

    try expectEqual(.text, try reader.read());

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("a", reader.elementNameNs().prefix);
    try expectEqualStrings("https://example.com/ns2", reader.elementNameNs().ns);
    try expectEqualStrings("a", reader.elementNameNs().local);

    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings("a", reader.elementNameNs().prefix);
    try expectEqualStrings("https://example.com/ns2", reader.elementNameNs().ns);
    try expectEqualStrings("a", reader.elementNameNs().local);

    try expectEqual(.text, try reader.read());

    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings("", reader.elementNameNs().prefix);
    try expectEqualStrings("https://example.com/ns", reader.elementNameNs().ns);
    try expectEqualStrings("root", reader.elementNameNs().local);
}

fn elementNameUnchecked(reader: Reader) []const u8 {
    return reader.bufSlice(reader.spans.items[0]);
}

fn elementNamePos(reader: Reader) usize {
    return reader.spans.items[0].start;
}

/// Returns the number of attributes of the element.
/// Asserts that the current node is `Node.element_start`.
pub fn attributeCount(reader: Reader) usize {
    assert(reader.node == .element_start);
    return reader.attributeCountUnchecked();
}

test attributeCount {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root a="1" b="2" c="3"/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqual(3, reader.attributeCount());
}

fn attributeCountUnchecked(reader: Reader) usize {
    return @divExact(reader.spans.items.len - 1, 2);
}

/// Returns the name of the `n`th attribute of the element.
/// Asserts that the current node is `Node.element_start` and `n` is less than `reader.nAttributes()`.
/// The returned memory is valid only until the next call to a `read` function or `deinit`.
pub fn attributeName(reader: Reader, n: usize) []const u8 {
    assert(reader.node == .element_start and n < reader.attributeCount());
    return reader.attributeNameUnchecked(n);
}

test attributeName {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root a="1" b="2" c="3"/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("a", reader.attributeName(0));
    try expectEqualStrings("b", reader.attributeName(1));
    try expectEqualStrings("c", reader.attributeName(2));
}

/// Returns the name of the `n`th attribute of the element as a `PrefixedQName`.
/// If the reader is not namespace-aware, only the `local` part will be non-empty.
/// Asserts that the current node is `Node.element_start` and `n` is less than `reader.nAttributes()`.
/// The returned memory is valid only until the next call to a `read` function or `deinit`.
pub fn attributeNameNs(reader: Reader, n: usize) PrefixedQName {
    const name = reader.attributeName(n);
    return if (reader.options.namespace_aware) reader.parseQName(name) else .{
        .prefix = "",
        .ns = "",
        .local = name,
    };
}

test attributeNameNs {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root xmlns:pre="https://example.com/ns" a="1" pre:b="2"/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());

    try expectEqualStrings("xmlns", reader.attributeNameNs(0).prefix);
    try expectEqualStrings("http://www.w3.org/2000/xmlns/", reader.attributeNameNs(0).ns);
    try expectEqualStrings("pre", reader.attributeNameNs(0).local);

    try expectEqualStrings("", reader.attributeNameNs(1).prefix);
    try expectEqualStrings("", reader.attributeNameNs(1).ns);
    try expectEqualStrings("a", reader.attributeNameNs(1).local);

    try expectEqualStrings("pre", reader.attributeNameNs(2).prefix);
    try expectEqualStrings("https://example.com/ns", reader.attributeNameNs(2).ns);
    try expectEqualStrings("b", reader.attributeNameNs(2).local);
}

fn attributeNameUnchecked(reader: Reader, n: usize) []const u8 {
    return reader.bufSlice(reader.spans.items[n * 2 + 1]);
}

fn attributeNamePos(reader: Reader, n: usize) usize {
    return reader.spans.items[n * 2 + 1].start;
}

/// Returns the value of the `n`th attribute of the element.
/// This function may incur allocations if the attribute value contains entity or character
/// references, or CR, LF, or TAB characters which must be normalized according to the spec.
/// Asserts that the current node is `Node.element_start` and `n` is less than `reader.nAttributes()`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn attributeValue(reader: *Reader, n: usize) Allocator.Error![]const u8 {
    const raw = reader.attributeValueRaw(n);
    if (std.mem.indexOfAny(u8, raw, "&\t\r\n") == null) return raw;
    reader.scratch.clearRetainingCapacity();
    reader.attributeValueWrite(n, &reader.scratch.writer) catch return error.OutOfMemory;
    return reader.scratch.written();
}

test attributeValue {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root a="1" b="2" c="1 &amp; 2"/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("1", try reader.attributeValue(0));
    try expectEqualStrings("2", try reader.attributeValue(1));
    try expectEqualStrings("1 & 2", try reader.attributeValue(2));
}

/// Returns the value of the `n`th attribute of the element.
/// Asserts that the current node is `Node.element_start` and `n` is less than `reader.nAttributes()`.
/// The returned value is allocated using `gpa` and is owned by the caller.
pub fn attributeValueAlloc(reader: Reader, gpa: Allocator, n: usize) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    reader.attributeValueWrite(n, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

test attributeValueAlloc {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root a="1" b="2" c="1 &amp; 2"/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());

    const attr0 = try reader.attributeValueAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(attr0);
    try expectEqualStrings("1", attr0);
    const attr1 = try reader.attributeValueAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(attr1);
    try expectEqualStrings("2", attr1);
    const attr2 = try reader.attributeValueAlloc(std.testing.allocator, 2);
    defer std.testing.allocator.free(attr2);
    try expectEqualStrings("1 & 2", attr2);
}

/// Writes the value of the `n`th attribute of the element to `writer`.
/// Asserts that the current node is `Node.element_start` and `n` is less than `reader.nAttributes()`.
pub fn attributeValueWrite(reader: Reader, n: usize, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const raw = reader.attributeValueRaw(n);
    var pos: usize = 0;
    while (std.mem.indexOfAnyPos(u8, raw, pos, "&\t\r\n")) |split_pos| {
        try writer.writeAll(raw[pos..split_pos]);
        pos = split_pos;
        switch (raw[pos]) {
            '&' => {
                const entity_end = std.mem.indexOfScalarPos(u8, raw, pos, ';') orelse unreachable;
                if (raw[pos + "&".len] == '#') {
                    const c = if (raw[pos + "&#".len] == 'x')
                        std.fmt.parseInt(u21, raw[pos + "&#x".len .. entity_end], 16) catch unreachable
                    else
                        std.fmt.parseInt(u21, raw[pos + "&#".len .. entity_end], 10) catch unreachable;
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(c, &buf) catch unreachable;
                    try writer.writeAll(buf[0..len]);
                } else {
                    try writer.writeAll(predefined_entities.get(raw[pos + "&".len .. entity_end]) orelse unreachable);
                }
                pos = entity_end + 1;
            },
            '\t', '\n' => {
                try writer.writeByte(' ');
                pos += 1;
            },
            '\r' => {
                try writer.writeByte(' ');
                if (pos + 1 < raw.len and raw[pos + 1] == '\n') {
                    pos += 2;
                } else {
                    pos += 1;
                }
            },
            else => unreachable,
        }
    }
    try writer.writeAll(raw[pos..]);
}

test attributeValueWrite {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root a="1" b="2" c="1 &amp; 2"/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try reader.attributeValueWrite(0, &out.writer);
    try expectEqualStrings("1", out.written());

    out.clearRetainingCapacity();
    try reader.attributeValueWrite(1, &out.writer);
    try expectEqualStrings("2", out.written());

    out.clearRetainingCapacity();
    try reader.attributeValueWrite(2, &out.writer);
    try expectEqualStrings("1 & 2", out.written());
}

/// Returns the raw value of the `n`th attribute of the element, as it appears in the source.
/// Asserts that the current node is `Node.element_start` and `n` is less than `reader.nAttributes()`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn attributeValueRaw(reader: Reader, n: usize) []const u8 {
    assert(reader.node == .element_start and n < reader.attributeCount());
    return reader.attributeValueUnchecked(n);
}

test attributeValueRaw {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root a="1" b="2" c="1 &amp; 2"/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("1", reader.attributeValueRaw(0));
    try expectEqualStrings("2", reader.attributeValueRaw(1));
    try expectEqualStrings("1 &amp; 2", reader.attributeValueRaw(2));
}

fn attributeValueUnchecked(reader: Reader, n: usize) []const u8 {
    return reader.bufSlice(reader.spans.items[n * 2 + 2]);
}

fn attributeValuePos(reader: Reader, n: usize) usize {
    return reader.spans.items[n * 2 + 2].start;
}

fn attributeValueEndPos(reader: Reader, n: usize) usize {
    return reader.spans.items[n * 2 + 2].end;
}

/// Returns the location of the `n`th attribute of the element.
/// Asserts that the reader is location-aware, the current node is `Node.element_start`, and `n` is less than `reader.nAttributes()`.
pub fn attributeLocation(reader: Reader, n: usize) Location {
    assert(reader.node == .element_start and n < reader.attributeCount());
    var loc = reader.loc;
    reader.options.updateLocation.?(&loc, reader.buf[0..reader.attributeNamePos(n)]);
    return loc;
}

/// Returns the index of the attribute named `name`.
/// Asserts that the current node is `Node.element_start`.
pub fn attributeIndex(reader: Reader, name: []const u8) ?usize {
    assert(reader.node == .element_start);
    return reader.attributes.get(name);
}

test attributeIndex {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root one="1" two="2" three="3"/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqual(0, reader.attributeIndex("one"));
    try expectEqual(1, reader.attributeIndex("two"));
    try expectEqual(2, reader.attributeIndex("three"));
    try expectEqual(null, reader.attributeIndex("four"));
}

/// Returns the index of the attribute with namespace `ns` and local name `local`.
/// Asserts that the current node is `Node.element_start` and `reader` is namespace-aware.
pub fn attributeIndexNs(reader: Reader, ns: []const u8, local: []const u8) ?usize {
    assert(reader.node == .element_start and reader.options.namespace_aware);
    return reader.q_attributes.get(.{ .ns = ns, .local = local });
}

test attributeIndexNs {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root xmlns="http://example.com" xmlns:foo="http://example.com/foo" one="1" foo:two="2"/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqual(0, reader.attributeIndexNs("", "xmlns"));
    try expectEqual(1, reader.attributeIndexNs("http://www.w3.org/2000/xmlns/", "foo"));
    try expectEqual(2, reader.attributeIndexNs("", "one"));
    try expectEqual(3, reader.attributeIndexNs("http://example.com/foo", "two"));
    try expectEqual(null, reader.attributeIndexNs("http://example.com", "one"));
    try expectEqual(null, reader.attributeIndexNs("", "three"));
}

/// Returns the text of the comment.
/// This function may incur allocations if the comment text contains CR
/// characters which must be normalized according to the spec.
/// Asserts that the current node is `Node.comment`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn comment(reader: *Reader) Allocator.Error![]const u8 {
    return reader.newlineNormalizedScratch(reader.commentRaw());
}

test comment {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<!-- Hello, world! -->
        \\<root/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.comment, try reader.read());
    try expectEqualStrings(" Hello, world! ", try reader.comment());
}

/// Writes the text of the comment to `writer`.
/// Asserts that the current node is `Node.comment`.
pub fn commentWrite(reader: Reader, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeNewlineNormalized(reader.commentRaw(), writer);
}

test commentWrite {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<!-- Hello, world! -->
        \\<root/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.comment, try reader.read());

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try reader.commentWrite(&out.writer);
    try expectEqualStrings(" Hello, world! ", out.written());
}

/// Returns the raw text of the comment, as it appears in the source.
/// Asserts that the current node is `Node.comment`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn commentRaw(reader: Reader) []const u8 {
    assert(reader.node == .comment);
    return reader.commentUnchecked();
}

test commentRaw {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<!-- Hello, world! -->
        \\<root/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.comment, try reader.read());
    try expectEqualStrings(" Hello, world! ", reader.commentRaw());
}

fn commentUnchecked(reader: Reader) []const u8 {
    return reader.bufSlice(reader.spans.items[0]);
}

fn commentPos(reader: Reader) usize {
    return reader.spans.items[0].start;
}

/// Returns the target of the PI.
/// Asserts that the current node is `Node.pi`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn piTarget(reader: Reader) []const u8 {
    assert(reader.node == .pi);
    return reader.piTargetUnchecked();
}

test piTarget {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<?pi-target pi-data?>
        \\<root/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.pi, try reader.read());
    try expectEqualStrings("pi-target", reader.piTarget());
}

fn piTargetUnchecked(reader: Reader) []const u8 {
    return reader.bufSlice(reader.spans.items[0]);
}

fn piTargetPos(reader: Reader) usize {
    return reader.spans.items[0].start;
}

fn piTargetEndPos(reader: Reader) usize {
    return reader.spans.items[0].end;
}

/// Returns the data of the PI.
/// This function may incur allocations if the PI data contains CR
/// characters which must be normalized according to the spec.
/// Asserts that the current node is `Node.pi`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn piData(reader: *Reader) Allocator.Error![]const u8 {
    return reader.newlineNormalizedScratch(reader.piDataRaw());
}

test piData {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<?pi-target pi-data?>
        \\<root/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.pi, try reader.read());
    try expectEqualStrings("pi-data", try reader.piData());
}

/// Writes the data of the PI to `writer`.
/// Asserts that the current node is `Node.pi`.
pub fn piDataWrite(reader: Reader, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeNewlineNormalized(reader.piDataRaw(), writer);
}

test piDataWrite {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<?pi-target pi-data?>
        \\<root/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.pi, try reader.read());

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try reader.piDataWrite(&out.writer);
    try expectEqualStrings("pi-data", out.written());
}

/// Returns the raw data of the PI, as it appears in the source.
/// Asserts that the current node is `Node.pi`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn piDataRaw(reader: Reader) []const u8 {
    assert(reader.node == .pi);
    return reader.piDataUnchecked();
}

test piDataRaw {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<?pi-target pi-data?>
        \\<root/>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.pi, try reader.read());
    try expectEqualStrings("pi-data", reader.piDataRaw());
}

fn piDataUnchecked(reader: Reader) []const u8 {
    return reader.bufSlice(reader.spans.items[1]);
}

fn piDataPos(reader: Reader) usize {
    return reader.spans.items[1].start;
}

fn piDataEndPos(reader: Reader) usize {
    return reader.spans.items[1].end;
}

/// Returns the text.
/// This function may incur allocations if the text contains CR
/// characters which must be normalized according to the spec.
/// Asserts that the current node is `Node.text`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn text(reader: *Reader) Allocator.Error![]const u8 {
    return reader.newlineNormalizedScratch(reader.textRaw());
}

test text {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root>Hello, world!</root>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqual(.text, try reader.read());
    try expectEqualStrings("Hello, world!", try reader.text());
}

/// Writes the text to `writer`.
/// Asserts that the current node is `Node.text`.
pub fn textWrite(reader: Reader, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeNewlineNormalized(reader.textRaw(), writer);
}

test textWrite {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root>Hello, world!</root>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqual(.text, try reader.read());

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try reader.textWrite(&out.writer);
    try expectEqualStrings("Hello, world!", out.written());
}

/// Returns the raw text, as it appears in the source.
/// Asserts that the current node is `Node.text`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn textRaw(reader: Reader) []const u8 {
    assert(reader.node == .text);
    return reader.textUnchecked();
}

test textRaw {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root>Hello, world!</root>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqual(.text, try reader.read());
    try expectEqualStrings("Hello, world!", reader.textRaw());
}

fn textUnchecked(reader: Reader) []const u8 {
    return reader.buf[0..reader.pos];
}

fn textPos(reader: Reader) usize {
    _ = reader;
    return 0;
}

/// Returns the text of the CDATA section.
/// This function may incur allocations if the text contains CR
/// characters which must be normalized according to the spec.
/// Asserts that the current node is `Node.cdata`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn cdata(reader: *Reader) Allocator.Error![]const u8 {
    return reader.newlineNormalizedScratch(reader.cdataRaw());
}

test cdata {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root><![CDATA[Hello, world!]]></root>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqual(.cdata, try reader.read());
    try expectEqualStrings("Hello, world!", try reader.cdata());
}

/// Writes the text of the CDATA section to `writer`.
/// Asserts that the current node is `Node.cdata`.
pub fn cdataWrite(reader: Reader, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeNewlineNormalized(reader.cdataRaw(), writer);
}

test cdataWrite {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root><![CDATA[Hello, world!]]></root>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqual(.cdata, try reader.read());

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try reader.cdataWrite(&out.writer);
    try expectEqualStrings("Hello, world!", out.written());
}

/// Returns the raw text of the CDATA section, as it appears in the source.
/// Asserts that the current node is `Node.cdata`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn cdataRaw(reader: Reader) []const u8 {
    assert(reader.node == .cdata);
    return reader.cdataUnchecked();
}

test cdataRaw {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root><![CDATA[Hello, world!]]></root>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqual(.cdata, try reader.read());
    try expectEqualStrings("Hello, world!", reader.cdataRaw());
}

fn cdataUnchecked(reader: Reader) []const u8 {
    return reader.bufSlice(reader.spans.items[0]);
}

fn cdataPos(reader: Reader) usize {
    return reader.spans.items[0].start;
}

/// Returns the name of the referenced entity.
/// Asserts that the current node is `Node.entity_reference`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn entityReferenceName(reader: Reader) []const u8 {
    assert(reader.node == .entity_reference);
    return reader.entityReferenceNameUnchecked();
}

test entityReferenceName {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root>&amp;</root>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqual(.entity_reference, try reader.read());
    try expectEqualStrings("amp", reader.entityReferenceName());
}

fn entityReferenceNameUnchecked(reader: Reader) []const u8 {
    return reader.bufSlice(reader.spans.items[0]);
}

fn entityReferenceNamePos(reader: Reader) usize {
    return reader.spans.items[0].start;
}

/// Returns the referenced character (Unicode codepoint).
/// Asserts that the current node is `Node.character_reference`.
pub fn characterReferenceChar(reader: Reader) u21 {
    assert(reader.node == .character_reference);
    return reader.character;
}

test characterReferenceChar {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root>&#x20;</root>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqual(.character_reference, try reader.read());
    try expectEqual(0x20, reader.characterReferenceChar());
}

/// Returns the "name" of the referenced character, as it appears in the source.
/// Asserts that the current node is `Node.character_reference`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn characterReferenceName(reader: Reader) []const u8 {
    assert(reader.node == .character_reference);
    return reader.characterReferenceNameUnchecked();
}

test characterReferenceName {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root>&#x20;</root>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqual(.character_reference, try reader.read());
    try expectEqualStrings("x20", reader.characterReferenceName());
}

fn characterReferenceNameUnchecked(reader: Reader) []const u8 {
    return reader.bufSlice(reader.spans.items[0]);
}

fn characterReferenceNamePos(reader: Reader) usize {
    return reader.spans.items[0].start;
}

fn newlineNormalizedScratch(reader: *Reader, raw: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\r') == null) return raw;
    reader.scratch.clearRetainingCapacity();
    writeNewlineNormalized(raw, &reader.scratch.writer) catch return error.OutOfMemory;
    return reader.scratch.written();
}

fn writeNewlineNormalized(raw: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, raw, pos, '\r')) |cr_pos| {
        try writer.writeAll(raw[pos..cr_pos]);
        try writer.writeByte('\n');
        if (cr_pos + 1 < raw.len and raw[cr_pos + 1] == '\n') {
            pos = cr_pos + "\r\n".len;
        } else {
            pos = cr_pos + "\r".len;
        }
    }
    try writer.writeAll(raw[pos..]);
}

/// Returns the namespace URI bound to `prefix`, or an empty string if none.
/// If the reader is not namespace-aware, always returns an empty string.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn namespaceUri(reader: Reader, prefix: []const u8) []const u8 {
    if (!reader.options.namespace_aware) return "";
    if (predefined_namespace_uris.get(prefix)) |uri| return uri;
    var i = reader.ns_prefixes.items.len;
    const index = while (i > 0) {
        i -= 1;
        if (reader.ns_prefixes.items[i].getAdapted(prefix, StringIndexAdapter{
            .strings = reader.strings.items,
        })) |uri| break uri;
    } else return "";
    return reader.string(index);
}

test namespaceUri {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root
        \\  xmlns="https://example.com/default"
        \\  xmlns:other="https://example.com/other"
        \\>
        \\  <a xmlns:child="https://example.com/child"/>
        \\</root>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("https://example.com/default", reader.namespaceUri(""));
    try expectEqualStrings("https://example.com/other", reader.namespaceUri("other"));
    try expectEqualStrings("", reader.namespaceUri("child"));

    try expectEqual(.text, try reader.read());
    try expectEqualStrings("https://example.com/default", reader.namespaceUri(""));
    try expectEqualStrings("https://example.com/other", reader.namespaceUri("other"));
    try expectEqualStrings("", reader.namespaceUri("child"));

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("https://example.com/default", reader.namespaceUri(""));
    try expectEqualStrings("https://example.com/other", reader.namespaceUri("other"));
    try expectEqualStrings("https://example.com/child", reader.namespaceUri("child"));

    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings("https://example.com/default", reader.namespaceUri(""));
    try expectEqualStrings("https://example.com/other", reader.namespaceUri("other"));
    try expectEqualStrings("https://example.com/child", reader.namespaceUri("child"));

    try expectEqual(.text, try reader.read());
    try expectEqualStrings("https://example.com/default", reader.namespaceUri(""));
    try expectEqualStrings("https://example.com/other", reader.namespaceUri("other"));
    try expectEqualStrings("", reader.namespaceUri("child"));

    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings("https://example.com/default", reader.namespaceUri(""));
    try expectEqualStrings("https://example.com/other", reader.namespaceUri("other"));
    try expectEqualStrings("", reader.namespaceUri("child"));
}

fn parseQName(reader: Reader, name: []const u8) PrefixedQName {
    const prefix, const local = if (std.mem.indexOfScalar(u8, name, ':')) |colon_pos|
        .{ name[0..colon_pos], name[colon_pos + 1 ..] }
    else
        .{ "", name };
    return .{
        .prefix = prefix,
        .ns = reader.namespaceUri(prefix),
        .local = local,
    };
}

pub const ReadError = error{ MalformedXml, ReadFailed, OutOfMemory };
pub const ReadWriteError = ReadError || error{WriteFailed};

/// Reads and returns the next node in the document.
pub fn read(reader: *Reader) ReadError!Node {
    errdefer reader.node = null;
    const node: Node = node: switch (reader.state) {
        .invalid => return error.MalformedXml,
        .start => {
            try reader.shift();
            try reader.skipBom();
            if (try reader.readMatch("<?")) {
                try reader.readName();
                if (std.mem.eql(u8, reader.piTargetUnchecked(), "xml")) {
                    try reader.readXmlDeclarationContent();
                    reader.state = .after_xml_declaration;
                    try reader.checkXmlDeclaration();
                    break :node .xml_declaration;
                } else {
                    try reader.readPiContent();
                    reader.state = .after_xml_declaration;
                    try reader.checkPi();
                    break :node .pi;
                }
            }
            reader.state = .after_xml_declaration;
            continue :node reader.state;
        },
        .after_xml_declaration => {
            try reader.skipSpace();
            if (try reader.readMatch("<?")) {
                try reader.readName();
                try reader.readPiContent();
                try reader.checkPi();
                break :node .pi;
            } else if (try reader.readMatch("<!--")) {
                try reader.readCommentContent();
                try reader.checkComment();
                break :node .comment;
            } else if (try reader.readMatch("<!DOCTYPE")) {
                return reader.fatal(.doctype_unsupported, reader.pos);
            }
            reader.state = .after_doctype;
            continue :node reader.state;
        },
        .after_doctype => {
            try reader.skipSpace();
            if (reader.pos == reader.buf.len) {
                return reader.fatal(.unexpected_eof, reader.pos);
            } else if (try reader.readMatch("<?")) {
                try reader.readName();
                try reader.readPiContent();
                try reader.checkPi();
                break :node .pi;
            } else if (try reader.readMatch("<!--")) {
                try reader.readCommentContent();
                try reader.checkComment();
                break :node .comment;
            } else if (try reader.readMatch("<")) {
                try reader.readName();
                reader.state = if (try reader.readElementStartContent()) .empty_root else .in_root;
                try reader.checkElementStart();
                break :node .element_start;
            } else {
                return reader.fatal(.unexpected_character, reader.pos);
            }
        },
        .in_root => {
            try reader.shift();
            if (reader.pos == reader.buf.len) {
                return reader.fatal(.unexpected_eof, reader.pos);
            } else if (try reader.readMatch("&#")) {
                try reader.readCharacterReference();
                if (!try reader.readMatch(";")) return reader.fatal(.character_reference_unclosed, reader.pos);
                try reader.checkCharacterReference();
                break :node .character_reference;
            } else if (try reader.readMatch("&")) {
                try reader.readName();
                if (!try reader.readMatch(";")) return reader.fatal(.entity_reference_unclosed, reader.pos);
                try reader.checkEntityReference();
                break :node .entity_reference;
            } else if (try reader.readMatch("<?")) {
                try reader.readName();
                try reader.readPiContent();
                try reader.checkPi();
                break :node .pi;
            } else if (try reader.readMatch("<!--")) {
                try reader.readCommentContent();
                try reader.checkComment();
                break :node .comment;
            } else if (try reader.readMatch("<![CDATA[")) {
                try reader.readCdata();
                try reader.checkCdata();
                break :node .cdata;
            } else if (try reader.readMatch("</")) {
                try reader.readName();
                try reader.readSpace();
                if (!try reader.readMatch(">")) return reader.fatal(.element_end_unclosed, reader.pos);
                try reader.checkElementEnd();
                if (reader.element_names.items.len == 1) reader.state = .after_root;
                break :node .element_end;
            } else if (try reader.readMatch("<")) {
                try reader.readName();
                if (try reader.readElementStartContent()) {
                    reader.state = .empty_element;
                }
                try reader.checkElementStart();
                break :node .element_start;
            } else {
                try reader.readText();
                try reader.checkText();
                break :node .text;
            }
        },
        .empty_element => {
            reader.state = .in_root;
            break :node .element_end;
        },
        .empty_root => {
            reader.state = .after_root;
            break :node .element_end;
        },
        .after_root => {
            try reader.skipSpace();
            if (reader.pos == reader.buf.len) {
                reader.state = .eof;
                continue :node reader.state;
            } else if (try reader.readMatch("<?")) {
                try reader.readName();
                try reader.readPiContent();
                try reader.checkPi();
                break :node .pi;
            } else if (try reader.readMatch("<!--")) {
                try reader.readCommentContent();
                try reader.checkComment();
                break :node .comment;
            } else {
                return reader.fatal(.unexpected_character, reader.pos);
            }
        },
        .eof => .eof,
    };
    reader.node = node;
    return node;
}

/// Reads and returns the text content of the element and its children.
/// The current node after returning is the end of the element.
/// Asserts that the current node is `Node.element_start`.
/// The returned memory is owned by `reader` and valid only until the next call to another reader function..
pub fn readElementText(reader: *Reader) ReadWriteError![]const u8 {
    reader.scratch.clearRetainingCapacity();
    reader.readElementTextWrite(&reader.scratch.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return reader.scratch.written();
}

test readElementText {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root>Hello, <em>world</em>!</root>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("root", reader.elementName());
    try expectEqualStrings("Hello, world!", try reader.readElementText());
    try expectEqualStrings("root", reader.elementName());
    try expectEqual(.eof, try reader.read());
}

/// Reads and returns the text content of the element and its children.
/// The current node after returning is the end of the element.
/// Asserts that the current node is `Node.element_start`.
/// The returned value is allocated using `gpa` and is owned by the caller.
pub fn readElementTextAlloc(reader: *Reader, gpa: Allocator) ReadError![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    reader.readElementTextWrite(&out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return out.toOwnedSlice();
}

test readElementTextAlloc {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root>Hello, <em>world</em>!</root>
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("root", reader.elementName());
    const element_text = try reader.readElementTextAlloc(std.testing.allocator);
    defer std.testing.allocator.free(element_text);
    try expectEqualStrings("Hello, world!", element_text);
    try expectEqualStrings("root", reader.elementName());
    try expectEqual(.eof, try reader.read());
}

/// Reads the text content of the element and its children and writes it to
/// `writer`.
/// The current node after returning is the end of the element.
/// Asserts that the current node is `Node.element_start`.
pub fn readElementTextWrite(reader: *Reader, writer: *std.Io.Writer) ReadWriteError!void {
    assert(reader.node == .element_start);
    const depth = reader.element_names.items.len;
    while (true) {
        switch (try reader.read()) {
            .xml_declaration, .eof => unreachable,
            .element_start, .comment, .pi => {},
            .element_end => if (reader.element_names.items.len == depth) return,
            .text => try reader.textWrite(writer),
            .cdata => try reader.cdataWrite(writer),
            .character_reference => {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(reader.characterReferenceChar(), &buf) catch unreachable;
                try writer.writeAll(buf[0..len]);
            },
            .entity_reference => {
                const expanded = predefined_entities.get(reader.entityReferenceName()) orelse unreachable;
                try writer.writeAll(expanded);
            },
        }
    }
}

/// Reads and discards all document content until the start of the root element,
/// which is the current node after this function returns successfully.
/// Asserts that the start of the root element has not yet been read.
pub fn skipProlog(reader: *Reader) ReadError!void {
    assert(reader.state == .start or reader.state == .after_xml_declaration or reader.state == .after_doctype);
    while (true) {
        if (try reader.read() == .element_start) return;
    }
}

test skipProlog {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<?xml version="1.0"?>
        \\<!-- Irrelevant comment -->
        \\<?some-pi?>
        \\<root/>
        \\
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try reader.skipProlog();
    try expectEqualStrings("root", reader.elementName());
    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings("root", reader.elementName());
    try expectEqual(.eof, try reader.read());
}

/// Reads and discards all document content until the end of the containing
/// element, which is the current node after this function returns successfully.
/// Asserts that the reader is currently inside an element (not before or after
/// the root element).
pub fn skipElement(reader: *Reader) ReadError!void {
    assert(reader.state == .in_root or reader.state == .empty_element or reader.state == .empty_root);
    const depth = reader.element_names.items.len;
    while (true) {
        if (try reader.read() == .element_end and reader.element_names.items.len == depth) return;
    }
}

test skipElement {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root>
        \\  <sub>Hello, world!</sub>
        \\  <!-- Some comment -->
        \\</root>
        \\
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("root", reader.elementName());
    try reader.skipElement();
    try expectEqualStrings("root", reader.elementName());
    try expectEqual(.eof, try reader.read());
}

/// Reads and discards the rest of the document.
pub fn skipDocument(reader: *Reader) ReadError!void {
    while (true) {
        if (try reader.read() == .eof) return;
    }
}

test skipDocument {
    var static_reader: xml.Reader.Static = .init(std.testing.allocator,
        \\<root/>
        \\<!-- A comment -->
        \\<?pi data?>
        \\
    , .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("root", reader.elementName());
    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings("root", reader.elementName());
    try reader.skipDocument();
    try expectEqual(.eof, try reader.read());
}

fn readXmlDeclarationContent(reader: *Reader) !void {
    while (true) {
        try reader.readSpace();
        if (try reader.readMatch("?>")) return;
        try reader.readPair();
    }
}

fn checkXmlDeclaration(reader: *Reader) !void {
    try reader.checkAttributes();
    var state: enum {
        start,
        after_version,
        after_encoding,
        end,
    } = .start;
    for (0..reader.attributeCountUnchecked()) |i| {
        const name = reader.attributeNameUnchecked(i);
        const value = reader.attributeValueUnchecked(i);
        switch (state) {
            .start => if (std.mem.eql(u8, name, "version")) {
                try reader.checkXmlVersion(value, i);
                state = .after_version;
            } else {
                return reader.fatal(.xml_declaration_version_missing, 0);
            },
            .after_version => if (std.mem.eql(u8, name, "encoding")) {
                try reader.checkXmlEncoding(value, i);
                state = .after_encoding;
            } else if (std.mem.eql(u8, name, "standalone")) {
                try reader.checkXmlStandalone(value, i);
                state = .end;
            } else {
                return reader.fatal(.xml_declaration_attribute_unsupported, reader.attributeNamePos(i));
            },
            .after_encoding => if (std.mem.eql(u8, name, "standalone")) {
                try reader.checkXmlStandalone(value, i);
                state = .end;
            } else {
                return reader.fatal(.xml_declaration_attribute_unsupported, reader.attributeNamePos(i));
            },
            .end => return reader.fatal(.xml_declaration_attribute_unsupported, reader.attributeNamePos(i)),
        }
    }
    if (state == .start) {
        return reader.fatal(.xml_declaration_version_missing, 0);
    }
}

fn checkXmlVersion(reader: *Reader, version: []const u8, n_attr: usize) !void {
    if (!std.mem.startsWith(u8, version, "1.")) {
        return reader.fatal(.xml_declaration_version_unsupported, reader.attributeValuePos(n_attr));
    }
    for (version["1.".len..]) |c| {
        switch (c) {
            '0'...'9' => {},
            else => return reader.fatal(.xml_declaration_version_unsupported, reader.attributeValuePos(n_attr)),
        }
    }
}

fn checkXmlEncoding(reader: *Reader, encoding: []const u8, n_attr: usize) !void {
    if (!reader.checkEncoding(encoding)) {
        return reader.fatal(.xml_declaration_encoding_unsupported, reader.attributeValuePos(n_attr));
    }
}

fn checkXmlStandalone(reader: *Reader, standalone: []const u8, n_attr: usize) !void {
    if (!std.mem.eql(u8, standalone, "yes") and !std.mem.eql(u8, standalone, "no")) {
        return reader.fatal(.xml_declaration_standalone_malformed, reader.attributeValuePos(n_attr));
    }
}

fn readElementStartContent(reader: *Reader) !bool {
    while (true) {
        try reader.readSpace();
        if (try reader.readMatch("/>")) {
            return true;
        } else if (try reader.readMatch(">")) {
            return false;
        } else {
            try reader.readPair();
        }
    }
}

fn checkElementStart(reader: *Reader) !void {
    const element_name = reader.elementNameUnchecked();
    const element_name_pos = reader.elementNamePos();
    try reader.checkName(element_name, element_name_pos);
    try reader.checkAttributes();

    const element_name_index = try reader.addString(element_name);
    try reader.element_names.append(reader.gpa, element_name_index);

    if (reader.options.namespace_aware) {
        try reader.ns_prefixes.append(reader.gpa, .{});
        try reader.checkAttributesNs();
        if (std.mem.indexOfScalar(u8, element_name, ':')) |colon_pos| {
            const prefix = element_name[0..colon_pos];
            if (std.mem.eql(u8, prefix, "xmlns")) return reader.fatal(.namespace_prefix_illegal, element_name_pos);
            try reader.checkNcName(prefix, element_name_pos);
            const local = element_name[colon_pos + 1 ..];
            try reader.checkNcName(local, element_name_pos);
            if (reader.namespaceUri(prefix).len == 0) return reader.fatal(.namespace_prefix_unbound, element_name_pos);
        }
    }
}

fn checkAttributes(reader: *Reader) !void {
    const n_attributes = reader.attributeCountUnchecked();
    try reader.attributes.ensureUnusedCapacity(reader.gpa, n_attributes);
    for (0..n_attributes) |i| {
        const name_pos = reader.attributeNamePos(i);
        if (i > 0 and name_pos == reader.attributeValueEndPos(i - 1) + 1) {
            return reader.fatal(.attribute_missing_space, name_pos);
        }

        const name = reader.attributeNameUnchecked(i);
        try reader.checkName(name, name_pos);

        const gop = reader.attributes.getOrPutAssumeCapacity(name);
        if (gop.found_existing) return reader.fatal(.attribute_duplicate, name_pos);
        gop.value_ptr.* = i;

        try reader.checkAttributeValue(i);
    }
}

fn checkAttributeValue(reader: *Reader, n: usize) !void {
    const s = reader.attributeValueUnchecked(n);
    const pos = reader.attributeValuePos(n);
    try reader.validateUtf8(s, pos);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '\t',
            '\n',
            '\r',
            0x20...('&' - 1),
            ('&' + 1)...('<' - 1),
            ('<' + 1)...0xEE,
            0xF0...0xFF,
            => {},
            0xEF => {
                // We already validated for correct UTF-8, so we know 2 bytes follow.
                // The Unicode codepoints U+FFFE and U+FFFF are not allowed as characters:
                // U+FFFE: EF BF BE
                // U+FFFF: EF BF BF
                if (s[i + 1] == 0xBF and (s[i + 2] == 0xBE or s[i + 2] == 0xBF)) {
                    return reader.fatal(.illegal_character, pos + i);
                }
            },
            '<' => return reader.fatal(.attribute_illegal_character, pos + i),
            '&' => {
                if (std.mem.startsWith(u8, s[i + "&".len ..], "#")) {
                    const end = std.mem.indexOfScalarPos(u8, s, i, ';') orelse return reader.fatal(.character_reference_unclosed, pos + i);
                    const ref = s[i + "&#".len .. end];
                    const c = if (std.mem.startsWith(u8, ref, "x"))
                        std.fmt.parseInt(u21, ref["x".len..], 16) catch return reader.fatal(.character_reference_malformed, pos + i)
                    else
                        std.fmt.parseInt(u21, ref, 10) catch return reader.fatal(.character_reference_malformed, pos + i);
                    if (!isChar(c)) return reader.fatal(.character_reference_malformed, pos + i);
                } else {
                    const end = std.mem.indexOfScalarPos(u8, s, i, ';') orelse return reader.fatal(.entity_reference_unclosed, pos + i);
                    const ref = s[i + "&".len .. end];
                    if (!predefined_entities.has(ref)) return reader.fatal(.entity_reference_undefined, pos + i);
                    i = end;
                }
            },
            else => return reader.fatal(.illegal_character, pos + i),
        }
    }
}

fn checkAttributesNs(reader: *Reader) !void {
    const n_attributes = reader.attributeCountUnchecked();
    try reader.q_attributes.ensureUnusedCapacity(reader.gpa, n_attributes);
    const prefix_bindings = &reader.ns_prefixes.items[reader.ns_prefixes.items.len - 1];

    for (0..n_attributes) |i| {
        const name = reader.attributeNameUnchecked(i);
        const pos = reader.attributeNamePos(i);
        if (std.mem.eql(u8, name, "xmlns")) {
            const value = reader.attributeValueUnchecked(i);
            const uri_index = try reader.addAttributeValueString(value);
            const uri = reader.string(uri_index);
            if (std.mem.eql(u8, uri, ns_xml) or std.mem.eql(u8, uri, ns_xmlns)) {
                return reader.fatal(.namespace_binding_illegal, pos);
            }
            try prefix_bindings.putNoClobber(reader.gpa, .empty, uri_index);
        } else if (std.mem.startsWith(u8, name, "xmlns:")) {
            const prefix = name["xmlns:".len..];
            if (std.mem.eql(u8, prefix, "xmlns")) return reader.fatal(.namespace_binding_illegal, pos);
            try reader.checkNcName(prefix, pos);
            const prefix_index = try reader.addString(prefix);
            const value = reader.attributeValueUnchecked(i);
            if (value.len == 0) return reader.fatal(.attribute_prefix_undeclared, pos);
            const uri_index = try reader.addAttributeValueString(value);
            const uri = reader.string(uri_index);
            if (std.mem.eql(u8, uri, "xml") != std.mem.eql(u8, uri, ns_xml)) return reader.fatal(.namespace_binding_illegal, pos);
            if (std.mem.eql(u8, uri, ns_xmlns)) return reader.fatal(.namespace_binding_illegal, pos);
            try prefix_bindings.putNoClobber(reader.gpa, prefix_index, uri_index);
        }
    }

    for (0..n_attributes) |i| {
        const name = reader.attributeNameUnchecked(i);
        const pos = reader.attributeNamePos(i);
        const colon_pos = std.mem.indexOfScalar(u8, name, ':') orelse {
            reader.q_attributes.putAssumeCapacityNoClobber(.{ .ns = "", .local = name }, i);
            continue;
        };
        const prefix = name[0..colon_pos];
        try reader.checkNcName(prefix, pos);
        const local = name[colon_pos + 1 ..];
        try reader.checkNcName(local, pos);
        const uri = reader.namespaceUri(prefix);
        if (uri.len == 0) return reader.fatal(.namespace_prefix_unbound, pos);
        const gop = reader.q_attributes.getOrPutAssumeCapacity(.{ .ns = uri, .local = local });
        if (gop.found_existing) return reader.fatal(.attribute_duplicate, pos);
        gop.value_ptr.* = i;
    }
}

fn addAttributeValueString(reader: *Reader, raw_value: []const u8) !StringIndex {
    try reader.strings.append(reader.gpa, 0);
    const start = reader.strings.items.len;
    var i: usize = 0;
    while (i < raw_value.len) : (i += 1) {
        switch (raw_value[i]) {
            '\t', '\n' => try reader.strings.append(reader.gpa, ' '),
            '\r' => {
                try reader.strings.append(reader.gpa, ' ');
                if (i + 1 < raw_value.len and raw_value[i + 1] == '\n') i += 1;
            },
            '&' => {
                const entity_end = std.mem.indexOfScalarPos(u8, raw_value, i, ';') orelse unreachable;
                if (raw_value[i + "&".len] == '#') {
                    const c = if (raw_value[i + "&#".len] == 'x')
                        std.fmt.parseInt(u21, raw_value[i + "&#x".len .. entity_end], 16) catch unreachable
                    else
                        std.fmt.parseInt(u21, raw_value[i + "&#".len .. entity_end], 10) catch unreachable;
                    try reader.strings.ensureUnusedCapacity(reader.gpa, 4);
                    reader.strings.items.len += std.unicode.utf8Encode(c, reader.strings.items) catch unreachable;
                } else {
                    const expansion = predefined_entities.get(raw_value[i + "&".len .. entity_end]) orelse unreachable;
                    try reader.strings.appendSlice(reader.gpa, expansion);
                }
                i = entity_end;
            },
            else => |b| try reader.strings.append(reader.gpa, b),
        }
    }
    return @enumFromInt(start);
}

fn checkElementEnd(reader: *Reader) !void {
    const element_name = if (@hasDecl(@TypeOf(reader.element_names), "last")) // zig 0.17
        reader.string((reader.element_names.last() orelse {
            return reader.fatal(.element_end_mismatched, reader.elementNamePos());
        }).*)
    else
        reader.string(reader.element_names.getLast());
    if (!std.mem.eql(u8, reader.elementNameUnchecked(), element_name)) {
        return reader.fatal(.element_end_mismatched, reader.elementNamePos());
    }
}

fn readCommentContent(reader: *Reader) !void {
    const start = reader.pos;
    while (true) {
        reader.pos = std.mem.indexOfPos(u8, reader.buf, reader.pos, "--") orelse reader.buf.len;
        if (reader.pos < reader.buf.len) {
            if (!std.mem.startsWith(u8, reader.buf[reader.pos + "--".len ..], ">")) {
                return reader.fatal(.comment_malformed, reader.pos);
            }
            try reader.spans.append(reader.gpa, .{ .start = start, .end = reader.pos });
            reader.pos += "-->".len;
            return;
        }
        try reader.more();
        if (reader.pos == reader.buf.len) return reader.fatal(.comment_unclosed, reader.pos);
    }
}

fn checkComment(reader: *Reader) !void {
    try reader.checkChars(reader.commentUnchecked(), reader.commentPos());
}

fn readPiContent(reader: *Reader) !void {
    try reader.readSpace();
    const start = reader.pos;
    while (true) {
        reader.pos = std.mem.indexOfPos(u8, reader.buf, reader.pos, "?>") orelse reader.buf.len;
        if (reader.pos < reader.buf.len) {
            try reader.spans.append(reader.gpa, .{ .start = start, .end = reader.pos });
            reader.pos += "?>".len;
            return;
        }
        try reader.more();
        if (reader.pos == reader.buf.len) return reader.fatal(.pi_unclosed, reader.pos);
    }
}

fn checkPi(reader: *Reader) !void {
    const target = reader.piTargetUnchecked();
    if (std.ascii.eqlIgnoreCase(target, "xml")) {
        return reader.fatal(.pi_target_disallowed, reader.piTargetPos());
    }
    try reader.checkName(target, reader.piTargetPos());
    if (reader.options.namespace_aware and std.mem.indexOfScalar(u8, target, ':') != null) {
        return reader.fatal(.name_malformed, reader.piTargetPos());
    }
    if (reader.piTargetEndPos() == reader.piDataPos() and reader.piDataEndPos() > reader.piDataPos()) {
        return reader.fatal(.pi_missing_space, reader.piDataPos());
    }
    try reader.checkChars(reader.piDataUnchecked(), reader.piDataPos());
}

fn readText(reader: *Reader) !void {
    while (reader.pos < reader.buf.len) {
        const b = reader.buf[reader.pos];
        if (b == '&' or b == '<') return;
        // We don't care about validating UTF-8 strictly here.
        // We just don't want to end in the possible middle of a codepoint.
        const nb: usize = if (b < 0x80) {
            reader.pos += 1;
            continue;
        } else if (b < 0xE0)
            2
        else if (b < 0xF0)
            3
        else
            4;
        if (reader.pos + nb > reader.buf.len) try reader.more();
        reader.pos = @min(reader.pos + nb, reader.buf.len);
    }
    // We don't want to end on a CR right before an LF, or CRLF normalization will not be possible.
    if (reader.pos > 0 and reader.buf[reader.pos - 1] == '\r') {
        try reader.more();
        if (reader.pos < reader.buf.len and reader.buf[reader.pos] == '\n') {
            reader.pos += 1;
        }
        return;
    }
    // We also don't want to end in the middle of ']]>' which checkText needs to reject.
    if (reader.pos > 0 and reader.buf[reader.pos - 1] == ']') {
        try reader.more();
        if (std.mem.startsWith(u8, reader.buf[reader.pos..], "]>")) {
            reader.pos += "]>".len;
        }
        return;
    }
}

fn checkText(reader: *Reader) !void {
    const s = reader.textUnchecked();
    const pos = reader.textPos();
    try reader.validateUtf8(s, pos);
    for (s, 0..) |c, i| {
        switch (c) {
            '\t',
            '\n',
            '\r',
            0x20...(']' - 1),
            (']' + 1)...0xEE,
            0xF0...0xFF,
            => {},
            ']' => {
                if (std.mem.startsWith(u8, s[i + 1 ..], "]>")) {
                    return reader.fatal(.text_cdata_end_disallowed, pos + i);
                }
            },
            0xEF => {
                // We already validated for correct UTF-8, so we know 2 bytes follow.
                // The Unicode codepoints U+FFFE and U+FFFF are not allowed as characters:
                // U+FFFE: EF BF BE
                // U+FFFF: EF BF BF
                if (s[i + 1] == 0xBF and (s[i + 2] == 0xBE or s[i + 2] == 0xBF)) {
                    return reader.fatal(.illegal_character, pos + i);
                }
            },
            else => return reader.fatal(.illegal_character, pos + i),
        }
    }
}

fn readCdata(reader: *Reader) !void {
    const start = reader.pos;
    while (true) {
        reader.pos = std.mem.indexOfPos(u8, reader.buf, reader.pos, "]]>") orelse reader.buf.len;
        if (reader.pos < reader.buf.len) {
            try reader.spans.append(reader.gpa, .{ .start = start, .end = reader.pos });
            reader.pos += "]]>".len;
            return;
        }
        try reader.more();
        if (reader.pos == reader.buf.len) return reader.fatal(.cdata_unclosed, reader.pos);
    }
}

fn checkCdata(reader: *Reader) !void {
    try reader.checkChars(reader.cdataUnchecked(), reader.cdataPos());
}

fn checkEntityReference(reader: *Reader) !void {
    if (!predefined_entities.has(reader.entityReferenceNameUnchecked())) {
        return reader.fatal(.entity_reference_undefined, reader.entityReferenceNamePos());
    }
}

fn readCharacterReference(reader: *Reader) !void {
    const start = reader.pos;
    while (true) {
        while (reader.pos < reader.buf.len) {
            switch (reader.buf[reader.pos]) {
                '0'...'9', 'A'...'Z', 'a'...'z' => reader.pos += 1,
                else => {
                    try reader.spans.append(reader.gpa, .{ .start = start, .end = reader.pos });
                    return;
                },
            }
        }
        try reader.more();
        if (reader.pos == reader.buf.len) {
            try reader.spans.append(reader.gpa, .{ .start = start, .end = reader.pos });
            return;
        }
    }
}

fn checkCharacterReference(reader: *Reader) !void {
    const ref = reader.characterReferenceNameUnchecked();
    const pos = reader.characterReferenceNamePos();
    const c = if (std.mem.startsWith(u8, ref, "x"))
        std.fmt.parseInt(u21, ref["x".len..], 16) catch return reader.fatal(.character_reference_malformed, pos)
    else
        std.fmt.parseInt(u21, ref, 10) catch return reader.fatal(.character_reference_malformed, pos);
    if (!isChar(c)) return reader.fatal(.character_reference_malformed, pos);
    reader.character = c;
}

fn readName(reader: *Reader) !void {
    const start = reader.pos;
    while (true) {
        while (reader.pos < reader.buf.len) {
            switch (reader.buf[reader.pos]) {
                'A'...'Z', 'a'...'z', '0'...'9', ':', '_', '-', '.', 0x80...0xFF => reader.pos += 1,
                else => {
                    try reader.spans.append(reader.gpa, .{ .start = start, .end = reader.pos });
                    return;
                },
            }
        }
        try reader.more();
        if (reader.pos == reader.buf.len) {
            try reader.spans.append(reader.gpa, .{ .start = start, .end = reader.pos });
            return;
        }
    }
}

fn readPair(reader: *Reader) !void {
    try reader.readName();
    try reader.readSpace();
    if (!try reader.readMatch("=")) return reader.fatal(.expected_equals, reader.pos);
    try reader.readSpace();
    try reader.readQuotedValue();
}

fn readQuotedValue(reader: *Reader) !void {
    const quote = quote: {
        if (reader.pos == reader.buf.len) {
            try reader.more();
            if (reader.pos == reader.buf.len) return reader.fatal(.expected_quote, reader.pos);
        }
        break :quote switch (reader.buf[reader.pos]) {
            '"', '\'' => |c| c,
            else => return reader.fatal(.expected_quote, reader.pos),
        };
    };
    reader.pos += 1;
    const start = reader.pos;
    while (true) {
        reader.pos = std.mem.indexOfScalarPos(u8, reader.buf, reader.pos, quote) orelse reader.buf.len;
        if (reader.pos < reader.buf.len) {
            try reader.spans.append(reader.gpa, .{ .start = start, .end = reader.pos });
            reader.pos += 1;
            return;
        }
        try reader.more();
        if (reader.pos == reader.buf.len) return reader.fatal(.missing_end_quote, reader.pos);
    }
}

fn readMatch(reader: *Reader, needle: []const u8) !bool {
    if (reader.pos + needle.len > reader.buf.len) {
        try reader.more();
        if (reader.pos + needle.len > reader.buf.len) return false;
    }
    if (std.mem.eql(u8, reader.buf[reader.pos..][0..needle.len], needle)) {
        reader.pos += needle.len;
        return true;
    }
    return false;
}

fn readSpace(reader: *Reader) !void {
    while (true) {
        while (reader.pos < reader.buf.len) {
            switch (reader.buf[reader.pos]) {
                ' ', '\t', '\r', '\n' => reader.pos += 1,
                else => return,
            }
        }
        try reader.more();
        if (reader.pos == reader.buf.len) return;
    }
}

fn checkName(reader: *Reader, s: []const u8, pos: usize) !void {
    const view = try reader.viewUtf8(s, pos);
    var iter = view.iterator();
    if (!isNameStartChar(iter.nextCodepoint() orelse return reader.fatal(.name_malformed, pos))) {
        return reader.fatal(.name_malformed, pos);
    }
    while (iter.nextCodepoint()) |c| {
        if (!isNameChar(c)) return reader.fatal(.name_malformed, pos);
    }
}

fn checkNcName(reader: *Reader, s: []const u8, pos: usize) !void {
    if (s.len == 0 or !isNameStartChar(s[0]) or std.mem.indexOfScalar(u8, s, ':') != null) {
        return reader.fatal(.name_malformed, pos);
    }
}

fn isNameStartChar(c: u21) bool {
    return switch (c) {
        ':',
        'A'...'Z',
        '_',
        'a'...'z',
        0xC0...0xD6,
        0xD8...0xF6,
        0xF8...0x2FF,
        0x370...0x37D,
        0x37F...0x1FFF,
        0x200C...0x200D,
        0x2070...0x218F,
        0x2C00...0x2FEF,
        0x3001...0xD7FF,
        0xF900...0xFDCF,
        0xFDF0...0xFFFD,
        0x10000...0xEFFFF,
        => true,
        else => false,
    };
}

fn isNameChar(c: u21) bool {
    return isNameStartChar(c) or switch (c) {
        '-',
        '.',
        '0'...'9',
        0xB7,
        0x0300...0x036F,
        0x203F...0x2040,
        => true,
        else => false,
    };
}

fn checkChars(reader: *Reader, s: []const u8, pos: usize) !void {
    try reader.validateUtf8(s, pos);
    for (s, 0..) |c, i| {
        switch (c) {
            '\t', '\n', '\r', 0x20...0xEE, 0xF0...0xFF => {},
            0xEF => {
                // We already validated for correct UTF-8, so we know 2 bytes follow.
                // The Unicode codepoints U+FFFE and U+FFFF are not allowed as characters:
                // U+FFFE: EF BF BE
                // U+FFFF: EF BF BF
                if (s[i + 1] == 0xBF and (s[i + 2] == 0xBE or s[i + 2] == 0xBF)) {
                    return reader.fatal(.illegal_character, pos + i);
                }
            },
            else => return reader.fatal(.illegal_character, pos + i),
        }
    }
}

fn isChar(c: u21) bool {
    return switch (c) {
        0x9,
        0xA,
        0xD,
        0x20...0xD7FF,
        0xE000...0xFFFD,
        0x10000...0x10FFFF,
        => true,
        else => false,
    };
}

fn skipBom(reader: *Reader) !void {
    const bom = "\u{FEFF}";
    if (std.mem.startsWith(u8, reader.buf[reader.pos..], bom)) {
        reader.pos += bom.len;
        try reader.shift();
    }
}

fn skipSpace(reader: *Reader) !void {
    while (true) {
        while (reader.pos < reader.buf.len) {
            switch (reader.buf[reader.pos]) {
                ' ', '\t', '\r', '\n' => reader.pos += 1,
                else => {
                    try reader.shift();
                    return;
                },
            }
        }
        try reader.shift();
        if (reader.pos == reader.buf.len) return;
    }
}

fn validateUtf8(reader: *Reader, s: []const u8, pos: usize) !void {
    if (reader.options.assume_valid_utf8) return;
    if (!std.unicode.utf8ValidateSlice(s)) return reader.fatalInvalidUtf8(s, pos);
}

fn viewUtf8(reader: *Reader, s: []const u8, pos: usize) !std.unicode.Utf8View {
    if (reader.options.assume_valid_utf8) return std.unicode.Utf8View.initUnchecked(s);
    return std.unicode.Utf8View.init(s) catch reader.fatalInvalidUtf8(s, pos);
}

fn fatalInvalidUtf8(reader: *Reader, s: []const u8, pos: usize) error{MalformedXml} {
    // We need to backtrack and redo the UTF-8 validation to set the correct
    // error location; the standard "validate UTF-8" function doesn't provide
    // an index for the invalid data.
    var invalid_pos: usize = 0;
    while (true) {
        const cp_len = std.unicode.utf8ByteSequenceLength(s[invalid_pos]) catch break;
        if (invalid_pos + cp_len > s.len) break;
        if (!std.unicode.utf8ValidateSlice(s[invalid_pos..][0..cp_len])) break;
        invalid_pos += cp_len;
    }
    return reader.fatal(.invalid_encoding, pos + invalid_pos);
}

const base_read_size = 4096;

fn shift(reader: *Reader) !void {
    if (reader.options.updateLocation) |updateLocation| {
        updateLocation(&reader.loc, reader.buf[0..reader.pos]);
    }

    try reader.move(reader.pos, base_read_size);
    reader.pos = 0;
    reader.spans.clearRetainingCapacity();
    reader.attributes.clearRetainingCapacity();
    reader.q_attributes.clearRetainingCapacity();

    if (reader.node == .element_end) {
        if (reader.options.namespace_aware) {
            var prefix_bindings = reader.ns_prefixes.pop().?;
            prefix_bindings.deinit(reader.gpa);
        }
        const element_name_start = reader.element_names.pop().?;
        reader.strings.shrinkRetainingCapacity(@intFromEnum(element_name_start));
    }
}

fn more(reader: *Reader) !void {
    try reader.move(0, reader.buf.len * 2);
}

fn fatal(reader: *Reader, error_code: ErrorCode, error_pos: usize) error{MalformedXml} {
    reader.state = .invalid;
    reader.error_code = error_code;
    reader.error_pos = error_pos;
    return error.MalformedXml;
}

const QNameContext = struct {
    pub fn hash(ctx: @This(), qname: QName) u32 {
        _ = ctx;
        var w = std.hash.Wyhash.init(0);
        w.update(qname.ns);
        w.update(qname.local);
        return @truncate(w.final());
    }

    pub fn eql(ctx: @This(), a: QName, b: QName, b_index: usize) bool {
        _ = ctx;
        _ = b_index;
        return std.mem.eql(u8, a.ns, b.ns) and std.mem.eql(u8, a.local, b.local);
    }
};

const BufSpan = struct {
    start: usize,
    end: usize,
};

fn bufSlice(reader: Reader, span: BufSpan) []const u8 {
    return reader.buf[span.start..span.end];
}

const StringIndex = enum(usize) { empty = 0, _ };

const StringIndexAdapter = struct {
    strings: []const u8,

    pub fn hash(ctx: @This(), key: []const u8) u32 {
        _ = ctx;
        return @truncate(std.hash.Wyhash.hash(0, key));
    }

    pub fn eql(ctx: @This(), a: []const u8, b: StringIndex, b_index: usize) bool {
        _ = b_index;
        const b_val = std.mem.sliceTo(ctx.strings[@intFromEnum(b)..], 0);
        return std.mem.eql(u8, a, b_val);
    }
};

fn addString(reader: *Reader, s: []const u8) !StringIndex {
    try reader.strings.ensureUnusedCapacity(reader.gpa, s.len + 1);
    reader.strings.appendAssumeCapacity(0);
    const start = reader.strings.items.len;
    reader.strings.appendSliceAssumeCapacity(s);
    return @enumFromInt(start);
}

fn string(reader: *const Reader, index: StringIndex) []const u8 {
    return std.mem.sliceTo(reader.strings.items[@intFromEnum(index)..], 0);
}
