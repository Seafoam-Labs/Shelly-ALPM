const std = @import("std");
const core = @import("core.zig");

pub const Arg = struct {
    name: []const u8,
    type: []const u8,
    direction: []const u8 = "in",
};

pub const Method = struct {
    name: []const u8,
    args: []const Arg,
};

pub const Signal = struct {
    name: []const u8,
    args: []const Arg,
};

pub const Property = struct {
    name: []const u8,
    type: []const u8,
    access: []const u8,
};

pub const Interface = struct {
    name: []const u8,
    methods: []const Method,
    signals: []const Signal,
    properties: []const Property,
};

/// Represents a node in the D-Bus object hierarchy, containing interfaces and child nodes.
pub const Node = struct {
    name: []const u8 = "",
    interfaces: []const Interface,
    children: []const Node,

    /// Recursively releases memory used by the node and its children.
    pub fn deinit(self: Node, allocator: std.mem.Allocator) void {
        for (self.interfaces) |iface| {
            for (iface.methods) |m| allocator.free(m.args);
            for (iface.signals) |s| allocator.free(s.args);
            allocator.free(iface.methods);
            allocator.free(iface.signals);
            allocator.free(iface.properties);
        }
        allocator.free(self.interfaces);
        for (self.children) |child| {
            child.deinit(allocator);
        }
        allocator.free(self.children);
    }
};

const Tag = struct {
    name: []const u8,
    attrs: []const u8,
    is_closing: bool,
    is_self_closing: bool,
};

const Scanner = struct {
    xml: []const u8,
    pos: usize = 0,

    fn nextTag(self: *Scanner) ?Tag {
        while (self.pos < self.xml.len) {
            // Find start of tag
            const start = std.mem.indexOfScalarPos(u8, self.xml, self.pos, '<') orelse return null;
            self.pos = start + 1;

            if (self.pos >= self.xml.len) return null;

            // Handle comments <!-- ... -->
            if (std.mem.startsWith(u8, self.xml[self.pos..], "!--")) {
                if (std.mem.indexOf(u8, self.xml[self.pos..], "-->")) |end| {
                    self.pos += end + 3;
                    continue;
                }
            }
            // Handle declarations <? ... ?> or <! ... >
            if (self.xml[self.pos] == '?' or self.xml[self.pos] == '!') {
                if (std.mem.indexOfScalarPos(u8, self.xml, self.pos, '>')) |end| {
                    self.pos = end + 1;
                    continue;
                }
            }

            const end = std.mem.indexOfScalarPos(u8, self.xml, self.pos, '>') orelse return null;
            const content = std.mem.trim(u8, self.xml[self.pos..end], " \t\r\n");
            self.pos = end + 1;

            if (content.len == 0) continue;

            var is_closing = false;
            var is_self_closing = false;
            var actual_content = content;

            if (actual_content[0] == '/') {
                is_closing = true;
                actual_content = actual_content[1..];
            }
            if (!is_closing and actual_content[actual_content.len - 1] == '/') {
                is_self_closing = true;
                actual_content = std.mem.trimEnd(u8, actual_content[0 .. actual_content.len - 1], " \t\r\n");
            }

            // Split name and attributes
            var name_end: usize = 0;
            while (name_end < actual_content.len and !std.ascii.isWhitespace(actual_content[name_end])) : (name_end += 1) {}

            return Tag{
                .name = actual_content[0..name_end],
                .attrs = if (name_end < actual_content.len) actual_content[name_end..] else "",
                .is_closing = is_closing,
                .is_self_closing = is_self_closing,
            };
        }
        return null;
    }
};

/// Parses a D-Bus introspection XML string into a Node tree.
pub fn parse(allocator: std.mem.Allocator, xml: []const u8) !Node {
    var scanner = Scanner{ .xml = xml };
    var interfaces = try std.ArrayList(Interface).initCapacity(allocator, 0);
    var children = try std.ArrayList(Node).initCapacity(allocator, 0);

    while (scanner.nextTag()) |tag| {
        if (tag.is_closing) continue;

        if (std.mem.eql(u8, tag.name, "interface")) {
            try interfaces.append(allocator, try parseInterface(allocator, tag, &scanner));
        } else if (std.mem.eql(u8, tag.name, "node")) {
            if (getAttr(tag.attrs, "name")) |name| {
                if (name.len > 0) {
                    try children.append(allocator, .{ .name = name, .interfaces = &.{}, .children = &.{} });
                }
            }
        }
    }

    return Node{
        .interfaces = try interfaces.toOwnedSlice(allocator),
        .children = try children.toOwnedSlice(allocator),
    };
}

fn parseInterface(allocator: std.mem.Allocator, root_tag: Tag, scanner: *Scanner) !Interface {
    const name = getAttr(root_tag.attrs, "name") orelse "unknown";
    var methods = try std.ArrayList(Method).initCapacity(allocator, 0);
    var signals = try std.ArrayList(Signal).initCapacity(allocator, 0);
    var properties = try std.ArrayList(Property).initCapacity(allocator, 0);

    if (root_tag.is_self_closing) return Interface{ .name = name, .methods = &.{}, .signals = &.{}, .properties = &.{} };

    while (scanner.nextTag()) |tag| {
        if (tag.is_closing) {
            if (std.mem.eql(u8, tag.name, "interface")) break;
            continue;
        }

        if (std.mem.eql(u8, tag.name, "method")) {
            try methods.append(allocator, try parseMethod(allocator, tag, scanner));
        } else if (std.mem.eql(u8, tag.name, "signal")) {
            try signals.append(allocator, try parseSignal(allocator, tag, scanner));
        } else if (std.mem.eql(u8, tag.name, "property")) {
            try properties.append(allocator, .{
                .name = getAttr(tag.attrs, "name") orelse "unknown",
                .type = getAttr(tag.attrs, "type") orelse "",
                .access = getAttr(tag.attrs, "access") orelse "read",
            });
            // Properties are always self-closing or empty in D-Bus
        }
    }

    return Interface{
        .name = name,
        .methods = try methods.toOwnedSlice(allocator),
        .signals = try signals.toOwnedSlice(allocator),
        .properties = try properties.toOwnedSlice(allocator),
    };
}

fn parseMethod(allocator: std.mem.Allocator, root_tag: Tag, scanner: *Scanner) !Method {
    const name = getAttr(root_tag.attrs, "name") orelse "unknown";
    var args = try std.ArrayList(Arg).initCapacity(allocator, 0);

    if (root_tag.is_self_closing) return Method{ .name = name, .args = &.{} };

    while (scanner.nextTag()) |tag| {
        if (tag.is_closing) {
            if (std.mem.eql(u8, tag.name, "method")) break;
            continue;
        }
        if (std.mem.eql(u8, tag.name, "arg")) {
            try args.append(allocator, .{
                .name = getAttr(tag.attrs, "name") orelse "",
                .type = getAttr(tag.attrs, "type") orelse "",
                .direction = getAttr(tag.attrs, "direction") orelse "in",
            });
        }
    }
    return Method{ .name = name, .args = try args.toOwnedSlice(allocator) };
}

fn parseSignal(allocator: std.mem.Allocator, root_tag: Tag, scanner: *Scanner) !Signal {
    const name = getAttr(root_tag.attrs, "name") orelse "unknown";
    var args = try std.ArrayList(Arg).initCapacity(allocator, 0);

    if (root_tag.is_self_closing) return Signal{ .name = name, .args = &.{} };

    while (scanner.nextTag()) |tag| {
        if (tag.is_closing) {
            if (std.mem.eql(u8, tag.name, "signal")) break;
            continue;
        }
        if (std.mem.eql(u8, tag.name, "arg")) {
            try args.append(allocator, .{
                .name = getAttr(tag.attrs, "name") orelse "",
                .type = getAttr(tag.attrs, "type") orelse "",
                .direction = "out",
            });
        }
    }
    return Signal{ .name = name, .args = try args.toOwnedSlice(allocator) };
}

fn getAttr(attrs: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + name.len + 1 < attrs.len) {
        // Find attribute name
        if (std.mem.startsWith(u8, attrs[i..], name)) {
            const next = i + name.len;
            // Check if it's followed by '=' (handling optional spaces)
            var eq_pos = next;
            while (eq_pos < attrs.len and std.ascii.isWhitespace(attrs[eq_pos])) : (eq_pos += 1) {}

            if (eq_pos < attrs.len and attrs[eq_pos] == '=') {
                var quote_pos = eq_pos + 1;
                while (quote_pos < attrs.len and std.ascii.isWhitespace(attrs[quote_pos])) : (quote_pos += 1) {}

                if (quote_pos < attrs.len) {
                    const quote = attrs[quote_pos];
                    if (quote == '"' or quote == '\'') {
                        const val_start = quote_pos + 1;
                        if (std.mem.indexOfScalarPos(u8, attrs, val_start, quote)) |val_end| {
                            return attrs[val_start..val_end];
                        }
                    }
                }
            }
        }
        // Move to next possible attribute
        while (i < attrs.len and !std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
    }
    return null;
}
