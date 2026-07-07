//! An XML writer, intended to output XML documents conforming to the [XML 1.0
//! (Fifth Edition)](https://www.w3.org/TR/2008/REC-xml-20081126) and
//! [Namespaces in XML 1.0 (Third
//! Edition)](https://www.w3.org/TR/2009/REC-xml-names-20091208/)
//! specifications.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const xml = @import("xml.zig");
const ns_xmlns = xml.ns_xmlns;
const predefined_namespace_prefixes = xml.predefined_namespace_prefixes;

options: Options,

state: State,
/// String data for the current element nesting context.
/// Each element start node appends the name of the element to this buffer, and
/// the element name is followed by any namespace prefixes and URIs declared on
/// the element so they can be referenced by `ns_prefixes`.
strings: std.ArrayListUnmanaged(u8),
/// The start indexes of the element names in `strings`.
element_names: std.ArrayListUnmanaged(StringIndex),
/// The namespace prefixes declared by the current nesting context of elements.
ns_prefixes: std.ArrayListUnmanaged(std.AutoArrayHashMapUnmanaged(StringIndex, StringIndex)),
/// Pending namespace prefixes to be declared on the next element start.
pending_ns: std.AutoArrayHashMapUnmanaged(StringIndex, StringIndex),
/// A counter for the next generated `ns123` namespace prefix to be used.
gen_ns_prefix_counter: u32,

out: *std.Io.Writer,

gpa: Allocator,

const Writer = @This();

test Writer {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.xmlDeclaration("UTF-8", null);
    try writer.elementStart("test");
    try writer.elementStart("inner");
    try writer.text("Hello, world!");
    try writer.elementEnd();
    try writer.elementEnd();

    try expectEqualStrings(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<test>
        \\  <inner>Hello, world!</inner>
        \\</test>
    , bytes.written());
}

pub const Options = struct {
    /// A string to be used as indentation for the output.
    /// An empty value indicates no attempt should be made to pretty-print the
    /// output.
    ///
    /// Using any value aside from an empty string may technically change the
    /// content of the output according to the spec, because leading and
    /// trailing whitespace within element content is always significant.
    /// For example, the following XML samples are _not_ strictly equivalent:
    ///
    /// ```xml
    /// <root><inner/></root>
    /// ```
    ///
    /// and
    ///
    /// ```xml
    /// <root>
    ///   <inner/>
    /// </root>
    /// ```
    indent: []const u8 = "",
    /// Whether the writer should be aware of XML namespaces. The `Ns`-suffixed
    /// functions of `Writer` may only be used when this is enabled.
    namespace_aware: bool = true,
};

const State = enum {
    start,
    after_bom,
    after_xml_declaration,
    element_start,
    after_structure_end,
    text,
    end,
    eof,
};

pub fn init(gpa: Allocator, writer: *std.Io.Writer, options: Options) Writer {
    return .{
        .options = options,

        .state = .start,
        .strings = .empty,
        .element_names = .empty,
        .ns_prefixes = .empty,
        .pending_ns = .empty,
        .gen_ns_prefix_counter = 0,

        .out = writer,

        .gpa = gpa,
    };
}

pub fn deinit(writer: *Writer) void {
    writer.strings.deinit(writer.gpa);
    writer.element_names.deinit(writer.gpa);
    for (writer.ns_prefixes.items) |*map| map.deinit(writer.gpa);
    writer.ns_prefixes.deinit(writer.gpa);
    writer.pending_ns.deinit(writer.gpa);
    writer.* = undefined;
}

pub const WriteError = error{ WriteFailed, OutOfMemory };

/// Writes the end of the document.
/// If `Options.indent` is non-empty, this writes a trailing newline;
/// otherwise, it does not write anything, but signals that further write
/// functions should not be called.
/// Asserts that the writer is after the root element.
pub fn eof(writer: *Writer) WriteError!void {
    assert(writer.state == .end);
    if (writer.options.indent.len != 0) try writer.write("\n");
    writer.state = .eof;
}

test eof {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.elementStart("root");
    try writer.elementEndEmpty();
    try writer.eof();

    try expectEqualStrings("<root/>\n", bytes.written());
}

/// Writes the BOM (byte-order mark).
/// Asserts that the writer is at the beginning of the document.
pub fn bom(writer: *Writer) WriteError!void {
    assert(writer.state == .start);
    try writer.write("\u{FEFF}");
    writer.state = .after_bom;
}

test bom {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.bom();
    try writer.elementStart("root");
    try writer.elementEndEmpty();
    try writer.eof();

    try expectEqualStrings("\u{FEFF}<root/>\n", bytes.written());
}

/// Writes the XML declaration.
/// Asserts that the writer is at the beginning of the document or just after the BOM (if any).
pub fn xmlDeclaration(writer: *Writer, encoding: ?[]const u8, standalone: ?bool) WriteError!void {
    assert(writer.state == .start or writer.state == .after_bom);
    try writer.write("<?xml version=\"1.0\"");
    if (encoding) |e| {
        try writer.write(" encoding=\"");
        try writer.attributeText(e);
        try writer.write("\"");
    }
    if (standalone) |s| {
        if (s) {
            try writer.write(" standalone=\"yes\"");
        } else {
            try writer.write(" standalone=\"no\"");
        }
    }
    try writer.write("?>");
    if (writer.options.indent.len > 0) try writer.newLineAndIndent();
    writer.state = .after_xml_declaration;
}

test xmlDeclaration {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.xmlDeclaration("UTF-8", true);
    try writer.elementStart("root");
    try writer.elementEndEmpty();
    try writer.eof();

    try expectEqualStrings(
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<root/>
        \\
    , bytes.written());
}

/// Starts an element.
/// Asserts that the writer is not after the end of the root element.
pub fn elementStart(writer: *Writer, name: []const u8) WriteError!void {
    if (writer.options.namespace_aware) prefixed: {
        const colon_pos = std.mem.indexOfScalar(u8, name, ':') orelse break :prefixed;
        const prefix = name[0..colon_pos];
        const local = name[colon_pos + 1 ..];
        try writer.elementStartInternal(prefix, local);
        return;
    }
    try writer.elementStartInternal("", name);
}

test elementStart {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.elementStart("root");
    try writer.elementStart("element");
    try writer.elementEnd();
    try writer.elementEnd();
    try writer.eof();

    try expectEqualStrings(
        \\<root>
        \\  <element>
        \\  </element>
        \\</root>
        \\
    , bytes.written());
}

/// Starts a namespaced element.
/// Asserts that the writer is namespace-aware and not after the end of the
/// root element.
///
/// Currently, this function also asserts that `ns` is not empty, although that
/// may be supported in the future.
///
/// If `ns` is already bound to a prefix (via an attribute or `bindNs`), that
/// prefix will be used. Otherwise, a generated namespace prefix counting
/// upwards from `ns0` will be declared and used.
pub fn elementStartNs(writer: *Writer, ns: []const u8, local: []const u8) WriteError!void {
    assert(writer.options.namespace_aware);
    // TODO: XML 1.0 does not allow undeclaring namespace prefixes, so ensuring
    //  the empty namespace is actually used here is potentially quite tricky.
    //  For now, it is not allowed.
    assert(ns.len > 0);
    const prefix = writer.getNsPrefix(ns) orelse prefix: {
        const str = try writer.generateNsPrefix();
        // If we are already inside an element start, we don't want to
        // immediately bind our new prefix in that scope. Rather, we
        // want to wait to bind it on the newly started element.
        try writer.pending_ns.put(writer.gpa, str, try writer.addString(ns));
        break :prefix writer.string(str);
    };
    try writer.elementStartInternal(prefix, local);
}

test elementStartNs {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.elementStartNs("http://example.com/foo", "root");
    try writer.elementStartNs("http://example.com/bar", "element");
    try writer.elementStartNs("http://example.com/foo", "element");
    try writer.elementEnd();
    try writer.elementEnd();
    try writer.elementEnd();
    try writer.eof();

    try expectEqualStrings(
        \\<ns0:root xmlns:ns0="http://example.com/foo">
        \\  <ns1:element xmlns:ns1="http://example.com/bar">
        \\    <ns0:element>
        \\    </ns0:element>
        \\  </ns1:element>
        \\</ns0:root>
        \\
    , bytes.written());
}

fn elementStartInternal(writer: *Writer, prefix: []const u8, local: []const u8) !void {
    switch (writer.state) {
        .start, .after_bom, .after_xml_declaration, .text => {},
        .element_start => {
            try writer.write(">");
            try writer.newLineAndIndent();
        },
        .after_structure_end => {
            try writer.newLineAndIndent();
        },
        .end, .eof => unreachable,
    }

    try writer.write("<");
    if (prefix.len > 0) {
        try writer.write(prefix);
        try writer.write(":");
    }
    try writer.write(local);

    // TODO: this is what I would _like_ to do, but prefix may point into
    //  strings, which can be invalidated while resizing it...
    // const element_name = try writer.addPrefixedString(prefix, local);
    // This temporary allocation is reliable, but ugly. At least local won't
    // point into strings, so we can avoid the allocation if there's no prefix.
    const element_name = if (prefix.len > 0) name: {
        const tmp = try std.fmt.allocPrint(writer.gpa, "{s}:{s}", .{ prefix, local });
        defer writer.gpa.free(tmp);
        break :name try writer.addString(tmp);
    } else try writer.addString(local);
    try writer.element_names.append(writer.gpa, element_name);
    writer.state = .element_start;

    if (writer.options.namespace_aware) {
        var ns_prefixes: std.AutoArrayHashMapUnmanaged(StringIndex, StringIndex) = .empty;
        try ns_prefixes.ensureUnusedCapacity(writer.gpa, writer.pending_ns.count());
        var pending_ns_iter = writer.pending_ns.iterator();
        while (pending_ns_iter.next()) |pending_ns| {
            try writer.attributeInternal("xmlns", writer.string(pending_ns.key_ptr.*), writer.string(pending_ns.value_ptr.*));
            // The pending_ns strings point into the string memory of the
            // enclosing element, so they are guaranteed to remain valid for
            // the lifetime of the current element.
            try ns_prefixes.put(writer.gpa, pending_ns.key_ptr.*, pending_ns.value_ptr.*);
        }
        try writer.ns_prefixes.append(writer.gpa, ns_prefixes);
        writer.pending_ns.clearRetainingCapacity();
    }
}

/// Ends the currently open element.
/// Asserts that the writer is inside an element.
pub fn elementEnd(writer: *Writer) WriteError!void {
    const name = @as(?StringIndex, writer.element_names.pop()).?;
    switch (writer.state) {
        .text => {},
        .element_start => {
            try writer.write(">");
            try writer.newLineAndIndent();
        },
        .after_structure_end => {
            try writer.newLineAndIndent();
        },
        .start, .after_bom, .after_xml_declaration, .end, .eof => unreachable,
    }
    try writer.write("</");
    try writer.write(writer.string(name));
    try writer.write(">");
    writer.state = if (writer.element_names.items.len > 0) .after_structure_end else .end;
    writer.strings.shrinkRetainingCapacity(@intFromEnum(name));
    if (writer.options.namespace_aware) {
        var ns_prefixes = writer.ns_prefixes.pop().?;
        ns_prefixes.deinit(writer.gpa);
        writer.pending_ns.clearRetainingCapacity();
    }
}

test elementEnd {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.elementStart("root");
    try writer.elementStart("element");
    try writer.elementEnd();
    try writer.elementEnd();
    try writer.eof();

    try expectEqualStrings(
        \\<root>
        \\  <element>
        \\  </element>
        \\</root>
        \\
    , bytes.written());
}

/// Ends the currently open element as an empty element (`<foo/>`).
/// Asserts that the writer is in an element start.
pub fn elementEndEmpty(writer: *Writer) WriteError!void {
    _ = writer.element_names.pop();
    assert(writer.state == .element_start);
    try writer.write("/>");
    writer.state = if (writer.element_names.items.len > 0) .after_structure_end else .end;
}

test elementEndEmpty {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.elementStart("root");
    try writer.elementStart("element");
    try writer.elementEndEmpty();
    try writer.elementEnd();
    try writer.eof();

    try expectEqualStrings(
        \\<root>
        \\  <element/>
        \\</root>
        \\
    , bytes.written());
}

/// Adds an attribute to the current element start.
/// Asserts that the writer is in an element start.
///
/// If the writer is namespace-aware, namespace declarations are recognized and
/// registered for future use by "Ns"-suffixed functions.
pub fn attribute(writer: *Writer, name: []const u8, value: []const u8) WriteError!void {
    assert(writer.state == .element_start);
    if (writer.options.namespace_aware) prefixed: {
        if (std.mem.eql(u8, name, "xmlns")) {
            const new_ns = try writer.addString(value);
            const ns_prefixes = &writer.ns_prefixes.items[writer.ns_prefixes.items.len - 1];
            try ns_prefixes.put(writer.gpa, .empty, new_ns);
        }
        const colon_pos = std.mem.indexOfScalar(u8, name, ':') orelse break :prefixed;
        const prefix = name[0..colon_pos];
        const local = name[colon_pos + 1 ..];
        if (std.mem.eql(u8, prefix, "xmlns")) {
            const new_prefix = try writer.addString(local);
            const new_ns = try writer.addString(value);
            const ns_prefixes = &writer.ns_prefixes.items[writer.ns_prefixes.items.len - 1];
            try ns_prefixes.put(writer.gpa, new_prefix, new_ns);
        }
        try writer.attributeInternal(prefix, local, value);
        return;
    }
    try writer.attributeInternal("", name, value);
}

test attribute {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.elementStart("root");
    try writer.attribute("key", "value");
    try writer.attribute("xmlns", "http://example.com");
    try writer.attribute("xmlns:a", "http://example.com/a");
    try writer.elementStartNs("http://example.com", "element");
    try writer.elementEndEmpty();
    try writer.elementStartNs("http://example.com/a", "element");
    try writer.elementEndEmpty();
    try writer.elementEnd();
    try writer.eof();

    try expectEqualStrings(
        \\<root key="value" xmlns="http://example.com" xmlns:a="http://example.com/a">
        \\  <element/>
        \\  <a:element/>
        \\</root>
        \\
    , bytes.written());
}

/// Adds a namespaced attribute to the current element start.
/// Asserts that the writer is namespace-aware and in an element start.
///
/// Currently, this function also asserts that `ns` is not empty, although that
/// may be supported in the future.
///
/// If `ns` is already bound to a prefix (via an attribute or `bindNs`), that
/// prefix will be used. Otherwise, a generated namespace prefix counting
/// upwards from `ns0` will be declared and used.
///
/// If the writer is namespace-aware, namespace declarations are recognized and
/// registered for future use by "Ns"-suffixed functions.
pub fn attributeNs(writer: *Writer, ns: []const u8, local: []const u8, value: []const u8) WriteError!void {
    assert(writer.options.namespace_aware);
    // TODO: XML 1.0 does not allow undeclaring namespace prefixes, so ensuring
    //  the empty namespace is actually used here is potentially quite tricky.
    //  For now, it is not allowed.
    assert(ns.len > 0);
    if (std.mem.eql(u8, ns, ns_xmlns)) {
        const new_prefix = try writer.addString(local);
        const new_ns = try writer.addString(value);
        const ns_prefixes = &writer.ns_prefixes.items[writer.ns_prefixes.items.len - 1];
        try ns_prefixes.put(writer.gpa, new_prefix, new_ns);
    }
    const prefix = writer.getNsPrefix(ns) orelse prefix: {
        const str = try writer.generateNsPrefix();
        try writer.bindNsImmediate(str, ns);
        break :prefix writer.string(str);
    };
    try writer.attributeInternal(prefix, local, value);
}

test attributeNs {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.elementStart("root");
    try writer.attributeNs("http://example.com", "key", "value");
    try writer.attributeNs("http://www.w3.org/2000/xmlns/", "a", "http://example.com/a");
    try writer.elementStartNs("http://example.com", "element");
    try writer.elementEndEmpty();
    try writer.elementStartNs("http://example.com/a", "element");
    try writer.elementEndEmpty();
    try writer.elementEnd();
    try writer.eof();

    try expectEqualStrings(
        \\<root xmlns:ns0="http://example.com" ns0:key="value" xmlns:a="http://example.com/a">
        \\  <ns0:element/>
        \\  <a:element/>
        \\</root>
        \\
    , bytes.written());
}

fn attributeInternal(writer: *Writer, prefix: []const u8, name: []const u8, value: []const u8) !void {
    assert(writer.state == .element_start);
    try writer.write(" ");
    if (prefix.len > 0) {
        try writer.write(prefix);
        if (name.len > 0) {
            try writer.write(":");
        }
    }
    try writer.write(name);
    try writer.write("=\"");
    try writer.attributeText(value);
    try writer.write("\"");
}

fn attributeText(writer: *Writer, s: []const u8) WriteError!void {
    var pos: usize = 0;
    while (std.mem.indexOfAnyPos(u8, s, pos, "&<\"")) |esc_pos| {
        try writer.write(s[pos..esc_pos]);
        try writer.write(switch (s[esc_pos]) {
            '&' => "&amp;",
            '<' => "&lt;",
            '"' => "&quot;",
            else => unreachable,
        });
        pos = esc_pos + 1;
    }
    try writer.write(s[pos..]);
}

/// Writes a comment.
pub fn comment(writer: *Writer, s: []const u8) WriteError!void {
    switch (writer.state) {
        .start, .after_bom, .after_xml_declaration, .text, .end => {},
        .element_start => {
            try writer.write(">");
            try writer.newLineAndIndent();
        },
        .after_structure_end => {
            try writer.newLineAndIndent();
        },
        .eof => unreachable,
    }
    try writer.write("<!--");
    try writer.write(s);
    try writer.write("-->");
    writer.state = .after_structure_end;
}

test comment {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.comment(" Here is the document: ");
    try writer.elementStart("root");
    try writer.comment(" I am inside the document ");
    try writer.elementEnd();
    try writer.eof();

    try expectEqualStrings(
        \\<!-- Here is the document: -->
        \\<root>
        \\  <!-- I am inside the document -->
        \\</root>
        \\
    , bytes.written());
}

/// Writes a PI (processing instruction).
pub fn pi(writer: *Writer, target: []const u8, data: []const u8) WriteError!void {
    switch (writer.state) {
        .start, .after_bom, .after_xml_declaration, .text, .end => {},
        .element_start => {
            try writer.write(">");
            try writer.newLineAndIndent();
        },
        .after_structure_end => {
            try writer.newLineAndIndent();
        },
        .eof => unreachable,
    }
    try writer.write("<?");
    try writer.write(target);
    if (data.len > 0) {
        try writer.write(" ");
        try writer.write(data);
    }
    try writer.write("?>");
    writer.state = .after_structure_end;
}

test pi {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.pi("some-pi", "some pi data");
    try writer.elementStart("root");
    try writer.pi("handle-me", "");
    try writer.elementEnd();
    try writer.eof();

    try expectEqualStrings(
        \\<?some-pi some pi data?>
        \\<root>
        \\  <?handle-me?>
        \\</root>
        \\
    , bytes.written());
}

/// Writes a text node, escaping the text where necessary to preserve its value
/// in the resulting XML.
/// Asserts that the writer is in an element.
pub fn text(writer: *Writer, s: []const u8) WriteError!void {
    try writer.textStart();
    try writer.textWrite(s);
}

test text {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.elementStart("root");
    try writer.text("Sample XML: <root>\n&amp;\n</root>");
    try writer.elementEnd();
    try writer.eof();

    try expectEqualStrings(
        \\<root>Sample XML: &lt;root>
        \\&amp;amp;
        \\&lt;/root></root>
        \\
    , bytes.written());
}

pub const TextWriter = struct {
    writer: *Writer,
    interface: std.Io.Writer,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const tw: *TextWriter = @fieldParentPtr("interface", w);
        try tw.writer.textWrite(tw.interface.buffered());
        tw.interface.end = 0;
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |s| {
            try tw.writer.textWrite(s);
            written += s.len;
        }
        for (0..splat) |_| {
            try tw.writer.textWrite(data[data.len - 1]);
            written += data[data.len - 1].len;
        }
        return written;
    }
};

pub fn textWriter(writer: *Writer, buffer: []u8) WriteError!TextWriter {
    try writer.textStart();
    return .{
        .writer = writer,
        .interface = .{
            .vtable = &.{
                .drain = TextWriter.drain,
            },
            .buffer = buffer,
        },
    };
}

test textWriter {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.elementStart("root");
    // The buffer is intentionally not large enough to hold all the written
    // bytes, for example purposes.
    var buf: [16]u8 = undefined;
    var tw = try writer.textWriter(&buf);
    const text_writer = &tw.interface;
    try text_writer.print("0xFF & 0x30 = 0x{X:0>2}\n", .{0xFF & 0x30});
    try text_writer.writeAll("<root>1 + 1 < 3</root>");
    try text_writer.flush();
    try writer.elementEnd();
    try writer.eof();

    try expectEqualStrings(
        \\<root>0xFF &amp; 0x30 = 0x30
        \\&lt;root>1 + 1 &lt; 3&lt;/root></root>
        \\
    , bytes.written());
}

fn textStart(writer: *Writer) !void {
    switch (writer.state) {
        .after_structure_end, .text => {},
        .element_start => try writer.write(">"),
        .start, .after_bom, .after_xml_declaration, .end, .eof => unreachable,
    }
    writer.state = .text;
}

fn textWrite(writer: *Writer, s: []const u8) !void {
    assert(writer.state == .text);
    var pos: usize = 0;
    while (std.mem.indexOfAnyPos(u8, s, pos, "&<")) |esc_pos| {
        try writer.write(s[pos..esc_pos]);
        try writer.write(switch (s[esc_pos]) {
            '&' => "&amp;",
            '<' => "&lt;",
            else => unreachable,
        });
        pos = esc_pos + 1;
    }
    try writer.write(s[pos..]);
}

/// Writes a CDATA node.
/// Asserts that the writer is in an element.
pub fn cdata(writer: *Writer, s: []const u8) WriteError!void {
    switch (writer.state) {
        .after_structure_end, .text => {},
        .element_start => try writer.write(">"),
        .start, .after_bom, .after_xml_declaration, .end, .eof => unreachable,
    }
    try writer.write("<![CDATA[");
    try writer.write(s);
    try writer.write("]]>");
    writer.state = .text;
}

test cdata {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.elementStart("root");
    try writer.cdata("Look, no <escaping> needed!");
    try writer.elementEnd();
    try writer.eof();

    try expectEqualStrings(
        \\<root><![CDATA[Look, no <escaping> needed!]]></root>
        \\
    , bytes.written());
}

/// Writes a character reference.
/// Asserts that the writer is in an element.
pub fn characterReference(writer: *Writer, c: u21) WriteError!void {
    switch (writer.state) {
        .after_structure_end, .text => {},
        .element_start => try writer.write(">"),
        .start, .after_bom, .after_xml_declaration, .end, .eof => unreachable,
    }
    const fmt = "&#x{X};";
    var buf: [std.fmt.count(fmt, .{std.math.maxInt(u21)})]u8 = undefined;
    try writer.write(std.fmt.bufPrint(&buf, fmt, .{c}) catch unreachable);
    writer.state = .text;
}

test characterReference {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.elementStart("root");
    try writer.characterReference('龍');
    try writer.elementEnd();
    try writer.eof();

    try expectEqualStrings(
        \\<root>&#x9F8D;</root>
        \\
    , bytes.written());
}

/// Writes an entity reference.
/// Asserts that the writer is in an element.
pub fn entityReference(writer: *Writer, name: []const u8) WriteError!void {
    switch (writer.state) {
        .after_structure_end, .text => {},
        .element_start => try writer.write(">"),
        .start, .after_bom, .after_xml_declaration, .end, .eof => unreachable,
    }
    try writer.write("&");
    try writer.write(name);
    try writer.write(";");
    writer.state = .text;
}

test entityReference {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.elementStart("root");
    try writer.entityReference("amp");
    try writer.elementEnd();
    try writer.eof();

    try expectEqualStrings(
        \\<root>&amp;</root>
        \\
    , bytes.written());
}

/// Writes an XML fragment without escaping anything.
///
/// For correctness, the XML fragment must not contain any unclosed structures.
/// For example, the fragment `<foo>` is illegal, as the element `foo` remains
/// unclosed after embedding. Similarly, `<?foo` and `<!-- foo` are also illegal.
pub fn embed(writer: *Writer, s: []const u8) WriteError!void {
    switch (writer.state) {
        .start, .after_bom, .after_xml_declaration, .after_structure_end, .text, .end => {},
        .element_start => try writer.write(">"),
        .eof => unreachable,
    }
    try writer.write(s);
    writer.state = switch (writer.state) {
        .start, .after_bom, .after_xml_declaration => .after_xml_declaration,
        .element_start, .after_structure_end, .text => .text,
        .end => .end,
        .eof => unreachable,
    };
}

test embed {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.xmlDeclaration("UTF-8", null);
    try writer.elementStart("foo");
    try writer.embed("<bar>Baz!</bar>");
    try writer.elementEnd();
    try writer.eof();

    try expectEqualStrings(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<foo><bar>Baz!</bar></foo>
        \\
    , bytes.written());
}

/// Binds a namespace URI to a prefix.
///
/// If the writer is currently inside an element start, the namespace is
/// declared immediately. Otherwise, it will be declared on the next element
/// started. If/when `prefix` is null the namespace will be declared as a
/// default namespace (no prefix) for the element.
pub fn bindNs(writer: *Writer, prefix: []const u8, ns: []const u8) WriteError!void {
    try writer.bindNsInternal(try writer.addString(prefix), ns);
}

test bindNs {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    // Namespaces may be bound before the element they apply to, allowing a
    // prefix to be bound for a namespaced element.
    try writer.bindNs("ex", "http://example.com");
    try writer.elementStartNs("http://example.com", "root");
    try writer.attributeNs("http://example.com", "a", "value");
    try writer.elementStartNs("http://example.com", "element");
    try writer.bindNs("ex2", "http://example.com/ns2");
    try writer.attributeNs("http://example.com/ns2", "a", "value");
    // It doesn't matter if a namespace prefix is ever used: it will be
    // declared regardless.
    try writer.bindNs("ex3", "http://example.com/ns3");
    try writer.elementEndEmpty();
    try writer.elementStart("ex4");
    try writer.bindNs("", "http://example.com/ex4");
    try writer.elementEndEmpty();
    try writer.elementEnd();
    try writer.eof();

    try expectEqualStrings(
        \\<ex:root xmlns:ex="http://example.com" ex:a="value">
        \\  <ex:element xmlns:ex2="http://example.com/ns2" ex2:a="value" xmlns:ex3="http://example.com/ns3"/>
        \\  <ex4 xmlns="http://example.com/ex4"/>
        \\</ex:root>
        \\
    , bytes.written());
}

fn bindNsInternal(writer: *Writer, prefix_str: StringIndex, ns: []const u8) !void {
    if (writer.state == .element_start) {
        try writer.bindNsImmediate(prefix_str, ns);
    } else {
        const ns_str = try writer.addString(ns);
        try writer.pending_ns.put(writer.gpa, prefix_str, ns_str);
    }
}

fn bindNsImmediate(writer: *Writer, prefix_str: StringIndex, ns: []const u8) !void {
    const ns_str = try writer.addString(ns);
    try writer.attributeInternal("xmlns", writer.string(prefix_str), ns);
    const ns_prefixes = &writer.ns_prefixes.items[writer.ns_prefixes.items.len - 1];
    try ns_prefixes.put(writer.gpa, prefix_str, ns_str);
}

fn getNsPrefix(writer: *Writer, ns: []const u8) ?[]const u8 {
    if (predefined_namespace_prefixes.get(ns)) |prefix| return prefix;

    // Potential optimization opportunity: store a mapping of namespace URIs
    // to prefixes and update it when an element closes or a new prefix is
    // bound.

    var pending_ns = writer.pending_ns.iterator();
    while (pending_ns.next()) |pending| {
        if (std.mem.eql(u8, ns, writer.string(pending.value_ptr.*))) {
            return writer.string(pending.key_ptr.*);
        }
    }

    var i: usize = writer.ns_prefixes.items.len;
    while (i > 0) {
        i -= 1;
        var ns_prefixes = writer.ns_prefixes.items[i].iterator();
        while (ns_prefixes.next()) |ns_prefix| {
            if (std.mem.eql(u8, ns, writer.string(ns_prefix.value_ptr.*))) {
                return writer.string(ns_prefix.key_ptr.*);
            }
        }
    }
    return null;
}

fn generateNsPrefix(writer: *Writer) !StringIndex {
    gen_prefix: while (true) {
        const max_len = std.fmt.comptimePrint("ns{}", .{std.math.maxInt(@TypeOf(writer.gen_ns_prefix_counter))}).len;
        var buf: [max_len]u8 = undefined;
        const prefix = std.fmt.bufPrint(&buf, "ns{}", .{writer.gen_ns_prefix_counter}) catch unreachable;
        writer.gen_ns_prefix_counter += 1;
        for (writer.ns_prefixes.items) |ns_prefixes| {
            for (ns_prefixes.keys()) |existing_prefix| {
                if (std.mem.eql(u8, prefix, writer.string(existing_prefix))) {
                    continue :gen_prefix;
                }
            }
        }
        return try writer.addString(prefix);
    }
}

fn newLineAndIndent(writer: *Writer) !void {
    if (writer.options.indent.len == 0) return;

    try writer.write("\n");
    for (0..writer.element_names.items.len) |_| {
        try writer.write(writer.options.indent);
    }
}

fn write(writer: *Writer, s: []const u8) !void {
    try writer.out.writeAll(s);
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

fn addString(writer: *Writer, s: []const u8) !StringIndex {
    try writer.strings.ensureUnusedCapacity(writer.gpa, 1 + s.len);
    writer.strings.appendAssumeCapacity(0);
    const start = writer.strings.items.len;
    writer.strings.appendSliceAssumeCapacity(s);
    return @enumFromInt(start);
}

fn addPrefixedString(writer: *Writer, prefix: []const u8, s: []const u8) !StringIndex {
    if (prefix.len == 0) return writer.addString(s);
    try writer.strings.ensureUnusedCapacity(writer.gpa, 1 + prefix.len + ":".len + s.len);
    writer.strings.appendAssumeCapacity(0);
    const start = writer.strings.items.len;
    writer.strings.appendSliceAssumeCapacity(prefix);
    writer.strings.appendAssumeCapacity(':');
    writer.strings.appendSliceAssumeCapacity(s);
    return @enumFromInt(start);
}

fn string(writer: *const Writer, index: StringIndex) []const u8 {
    return std.mem.sliceTo(writer.strings.items[@intFromEnum(index)..], 0);
}

test "namespace prefix strings resize bug" {
    // Reported here: https://github.com/ianprime0509/zig-xml/pull/41#issuecomment-2449960818
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var writer: xml.Writer = .init(std.testing.allocator, &bytes.writer, .{ .indent = "  " });
    defer writer.deinit();

    try writer.bindNs("d", "foospace");
    try writer.elementStartNs("foospace", "root");
    try writer.elementStartNs("foospace", "child");
    try writer.text("Hello, Bug");
    try writer.elementEnd();
    try writer.elementEnd();

    try expectEqualStrings(
        \\<d:root xmlns:d="foospace">
        \\  <d:child>Hello, Bug</d:child>
        \\</d:root>
    , bytes.written());
}
