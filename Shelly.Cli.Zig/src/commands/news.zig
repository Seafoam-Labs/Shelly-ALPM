const std = @import("std");
const Zigalpm = @import("Zigalpm");
const output = @import("../output/config.zig");
const colors = @import("../output/colors.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const spec = @import("../cli/spec.zig");
const xdg = @import("../runtime/xdg.zig");

const command_path = "shelly news standard";
const arch_linux_feed = "https://archlinux.org/feeds/news/";
const max_feed_size = 8 * 1024 * 1024;
const max_cache_size = 32 * 1024 * 1024;

pub const NewsItem = struct {
    title: []const u8,
    link: []const u8,
    description: []const u8,
    pub_date: []const u8,
};

const Fetcher = struct {
    data: ?*anyopaque = null,
    call: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        url: []const u8,
    ) anyerror![]u8,
};

const real_fetcher: Fetcher = .{ .call = fetchFeed };

const ExecutionOptions = struct {
    show_all: bool = false,
    ui_mode: bool = false,
    json: bool = false,
};

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;
    return try executeWithFetcher(context, invocation, real_fetcher);
}

pub fn showUnread(context: *runtime.RuntimeContext) !u8 {
    return execute(context, .{}, real_fetcher);
}

fn executeWithFetcher(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    fetcher: Fetcher,
) !u8 {
    return execute(context, .{
        .show_all = optionEnabled(invocation, "--all"),
        .ui_mode = invocation.globals.ui_mode,
        .json = invocation.globals.json,
    }, fetcher);
}

fn execute(
    context: *runtime.RuntimeContext,
    options: ExecutionOptions,
    fetcher: Fetcher,
) !u8 {
    const raw_feed = fetcher.call(fetcher.data, context, arch_linux_feed) catch |err| {
        try writeFailure(context, options, err);
        return 1;
    };
    const full_feed = parseFeed(context.allocator, raw_feed) catch |err| {
        try writeFailure(context, options, err);
        return 1;
    };
    const viewed_links = if (options.show_all)
        &.{}
    else
        loadViewedLinks(context) catch &.{};

    var selected: std.ArrayList(NewsItem) = .empty;
    if (options.show_all) {
        try selected.appendSlice(context.allocator, full_feed);
    } else {
        for (full_feed) |item| {
            if (!containsLink(viewed_links, item.link))
                try selected.append(context.allocator, item);
        }
    }

    if (options.ui_mode) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeJson(&payload.writer, selected.items);
        try output.writeFrame(context, payload.writer.buffered());
    } else if (options.json) {
        try writeJson(context.stdout, selected.items);
        try context.stdout.writeByte('\n');
    } else {
        try writePlain(context, selected.items);
        if (!options.show_all and selected.items.len == 0)
            try output.writeSuccess(context, "No new news found");
    }

    if (options.show_all or selected.items.len > 0) {
        saveFeed(context, full_feed) catch |err| {
            try writeFailure(context, options, err);
            return 1;
        };
    }
    return 0;
}

fn fetchFeed(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    url: []const u8,
) ![]u8 {
    const uri = try std.Uri.parse(url);
    var client: Zigalpm.HttpClient = .{ .allocator = context.allocator, .io = context.io };
    defer client.deinit();

    const accept_headers = [_]std.http.Header{.{
        .name = "accept",
        .value = "application/rss+xml, application/xml;q=0.9, text/xml;q=0.8",
    }};
    var request = try client.request(.GET, uri, .{
        .headers = .{
            .user_agent = .{ .override = "Shelly/2.4 Arch-News" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &accept_headers,
        .redirect_behavior = .init(10),
    });
    defer request.deinit();
    request.accept_encoding[@intFromEnum(std.http.ContentEncoding.gzip)] = false;
    request.accept_encoding[@intFromEnum(std.http.ContentEncoding.deflate)] = false;
    try request.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (response.head.status.class() != .success) return error.ArchNewsHttpStatus;

    var transfer_buffer: [8 * 1024]u8 = undefined;
    return response.reader(&transfer_buffer).allocRemaining(
        context.allocator,
        .limited(max_feed_size),
    );
}

fn parseFeed(allocator: std.mem.Allocator, xml: []const u8) ![]const NewsItem {
    var items: std.ArrayList(NewsItem) = .empty;
    var cursor: usize = 0;
    while (findOpeningTag(xml, "item", cursor)) |item_start| {
        const opening_end = std.mem.indexOfScalarPos(u8, xml, item_start, '>') orelse
            return error.InvalidArchNewsFeed;
        const closing_start = std.mem.indexOfPos(u8, xml, opening_end + 1, "</item>") orelse
            return error.InvalidArchNewsFeed;
        const item_xml = xml[opening_end + 1 .. closing_start];

        const title = try decodedElement(allocator, item_xml, "title");
        const link = try decodedElement(allocator, item_xml, "link");
        const description_html = try decodedElement(allocator, item_xml, "description");
        const pub_date = try decodedElement(allocator, item_xml, "pubDate");
        try items.append(allocator, .{
            .title = title,
            .link = link,
            .description = try htmlToMarkdown(allocator, description_html),
            .pub_date = pub_date,
        });
        cursor = closing_start + "</item>".len;
    }

    std.mem.reverse(NewsItem, items.items);
    return items.toOwnedSlice(allocator);
}

fn decodedElement(
    allocator: std.mem.Allocator,
    item_xml: []const u8,
    tag: []const u8,
) ![]const u8 {
    const opening_start = findOpeningTag(item_xml, tag, 0) orelse
        return allocator.dupe(u8, "");
    const opening_end = std.mem.indexOfScalarPos(u8, item_xml, opening_start, '>') orelse
        return error.InvalidArchNewsFeed;
    const closing = try std.fmt.allocPrint(allocator, "</{s}>", .{tag});
    const closing_start = std.mem.indexOfPos(u8, item_xml, opening_end + 1, closing) orelse
        return error.InvalidArchNewsFeed;
    return decodeXmlText(allocator, item_xml[opening_end + 1 .. closing_start]);
}

fn findOpeningTag(haystack: []const u8, tag: []const u8, start: usize) ?usize {
    var cursor = start;
    while (std.mem.indexOfScalarPos(u8, haystack, cursor, '<')) |candidate| {
        const name_start = candidate + 1;
        if (name_start + tag.len <= haystack.len and
            std.mem.eql(u8, haystack[name_start .. name_start + tag.len], tag))
        {
            const boundary = name_start + tag.len;
            if (boundary < haystack.len and
                (haystack[boundary] == '>' or std.ascii.isWhitespace(haystack[boundary])))
                return candidate;
        }
        cursor = candidate + 1;
    }
    return null;
}

fn decodeXmlText(allocator: std.mem.Allocator, raw_value: []const u8) ![]const u8 {
    var value = std.mem.trim(u8, raw_value, " \t\r\n");
    if (std.mem.startsWith(u8, value, "<![CDATA[") and std.mem.endsWith(u8, value, "]]>") and value.len >= 12)
        value = value[9 .. value.len - 3];

    return decodeXmlEntities(allocator, value);
}

fn decodeXmlEntities(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var decoded: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    while (cursor < value.len) {
        if (value[cursor] != '&') {
            try decoded.append(allocator, value[cursor]);
            cursor += 1;
            continue;
        }
        const semicolon = std.mem.indexOfScalarPos(u8, value, cursor + 1, ';') orelse {
            try decoded.append(allocator, value[cursor]);
            cursor += 1;
            continue;
        };
        if (semicolon - cursor > 16) {
            try decoded.append(allocator, value[cursor]);
            cursor += 1;
            continue;
        }
        const entity = value[cursor + 1 .. semicolon];
        if (try appendEntity(allocator, &decoded, entity)) {
            cursor = semicolon + 1;
        } else {
            try decoded.appendSlice(allocator, value[cursor .. semicolon + 1]);
            cursor = semicolon + 1;
        }
    }
    return decoded.toOwnedSlice(allocator);
}

fn appendEntity(
    allocator: std.mem.Allocator,
    target: *std.ArrayList(u8),
    entity: []const u8,
) !bool {
    const replacement: ?[]const u8 = if (std.mem.eql(u8, entity, "amp"))
        "&"
    else if (std.mem.eql(u8, entity, "lt"))
        "<"
    else if (std.mem.eql(u8, entity, "gt"))
        ">"
    else if (std.mem.eql(u8, entity, "quot"))
        "\""
    else if (std.mem.eql(u8, entity, "apos") or std.mem.eql(u8, entity, "#39"))
        "'"
    else if (std.mem.eql(u8, entity, "nbsp"))
        " "
    else
        null;
    if (replacement) |bytes| {
        try target.appendSlice(allocator, bytes);
        return true;
    }
    if (entity.len < 2 or entity[0] != '#') return false;
    const hexadecimal = entity.len > 2 and (entity[1] == 'x' or entity[1] == 'X');
    const digits = entity[if (hexadecimal) 2 else 1..];
    if (digits.len == 0) return false;
    const codepoint = std.fmt.parseInt(u21, digits, if (hexadecimal) 16 else 10) catch return false;
    if (!std.unicode.utf8ValidCodepoint(codepoint)) return false;
    var buffer: [4]u8 = undefined;
    const length = try std.unicode.utf8Encode(codepoint, &buffer);
    try target.appendSlice(allocator, buffer[0..length]);
    return true;
}

const Reference = struct {
    id: usize,
    url: []const u8,
};

fn htmlToMarkdown(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    var markdown: std.ArrayList(u8) = .empty;
    var references: std.ArrayList(Reference) = .empty;
    var active_anchor: ?usize = null;
    var ordered_list = false;
    var ordered_index: usize = 1;
    var cursor: usize = 0;

    while (cursor < html.len) {
        const tag_start = std.mem.indexOfScalarPos(u8, html, cursor, '<') orelse {
            try appendNormalizedText(allocator, &markdown, html[cursor..]);
            break;
        };
        try appendNormalizedText(allocator, &markdown, html[cursor..tag_start]);
        const tag_end = std.mem.indexOfScalarPos(u8, html, tag_start + 1, '>') orelse {
            try appendNormalizedText(allocator, &markdown, html[tag_start..]);
            break;
        };
        const raw_tag = std.mem.trim(u8, html[tag_start + 1 .. tag_end], " \t\r\n");
        if (raw_tag.len == 0 or raw_tag[0] == '!' or raw_tag[0] == '?') {
            cursor = tag_end + 1;
            continue;
        }
        const closing = raw_tag[0] == '/';
        const name_start: usize = if (closing) 1 else 0;
        var name_end = name_start;
        while (name_end < raw_tag.len and
            (std.ascii.isAlphanumeric(raw_tag[name_end]) or raw_tag[name_end] == '-')) : (name_end += 1)
        {}
        const name = raw_tag[name_start..name_end];

        if (std.ascii.eqlIgnoreCase(name, "p")) {
            try ensureNewlines(allocator, &markdown, 2);
        } else if (std.ascii.eqlIgnoreCase(name, "br")) {
            try ensureNewlines(allocator, &markdown, 1);
        } else if (std.ascii.eqlIgnoreCase(name, "strong") or std.ascii.eqlIgnoreCase(name, "b")) {
            try markdown.appendSlice(allocator, "**");
        } else if (std.ascii.eqlIgnoreCase(name, "em") or std.ascii.eqlIgnoreCase(name, "i")) {
            try markdown.append(allocator, '*');
        } else if (std.ascii.eqlIgnoreCase(name, "code")) {
            try markdown.append(allocator, '`');
        } else if (std.ascii.eqlIgnoreCase(name, "a")) {
            if (closing) {
                if (active_anchor) |reference_id| {
                    const suffix = try std.fmt.allocPrint(allocator, "][{d}]", .{reference_id});
                    try markdown.appendSlice(allocator, suffix);
                    active_anchor = null;
                }
            } else if (attributeValue(raw_tag[name_end..], "href")) |href| {
                const reference_id = references.items.len + 1;
                try references.append(allocator, .{
                    .id = reference_id,
                    .url = try decodeXmlText(allocator, href),
                });
                active_anchor = reference_id;
                try markdown.append(allocator, '[');
            }
        } else if (std.ascii.eqlIgnoreCase(name, "ul")) {
            try ensureNewlines(allocator, &markdown, 1);
            if (!closing) ordered_list = false;
        } else if (std.ascii.eqlIgnoreCase(name, "ol")) {
            try ensureNewlines(allocator, &markdown, 1);
            if (!closing) {
                ordered_list = true;
                ordered_index = 1;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "li")) {
            if (!closing) {
                try ensureNewlines(allocator, &markdown, 1);
                const prefix = if (ordered_list)
                    try std.fmt.allocPrint(allocator, "{d}. ", .{ordered_index})
                else
                    "- ";
                try markdown.appendSlice(allocator, prefix);
                if (ordered_list) ordered_index += 1;
            } else {
                try ensureNewlines(allocator, &markdown, 1);
            }
        } else if (name.len == 2 and (name[0] == 'h' or name[0] == 'H') and name[1] >= '1' and name[1] <= '6') {
            if (!closing) {
                try ensureNewlines(allocator, &markdown, 2);
                try markdown.appendNTimes(allocator, '#', name[1] - '0');
                try markdown.append(allocator, ' ');
            } else {
                try ensureNewlines(allocator, &markdown, 2);
            }
        } else if (std.ascii.eqlIgnoreCase(name, "blockquote")) {
            try ensureNewlines(allocator, &markdown, 2);
            if (!closing) try markdown.appendSlice(allocator, "> ");
        }
        cursor = tag_end + 1;
    }

    const body = std.mem.trim(u8, markdown.items, " \t\r\n");
    var result: std.ArrayList(u8) = .empty;
    try result.appendSlice(allocator, body);
    if (references.items.len > 0) {
        try ensureNewlines(allocator, &result, 2);
        for (references.items, 0..) |reference, index| {
            const line = try std.fmt.allocPrint(
                allocator,
                "[{d}]: {s}",
                .{ reference.id, reference.url },
            );
            try result.appendSlice(allocator, line);
            if (index + 1 < references.items.len) try result.append(allocator, '\n');
        }
    }
    return result.toOwnedSlice(allocator);
}

fn attributeValue(attributes: []const u8, wanted_name: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < attributes.len) {
        while (cursor < attributes.len and std.ascii.isWhitespace(attributes[cursor])) cursor += 1;
        const name_start = cursor;
        while (cursor < attributes.len and
            (std.ascii.isAlphanumeric(attributes[cursor]) or
                attributes[cursor] == '-' or attributes[cursor] == '_')) : (cursor += 1)
        {}
        const name = attributes[name_start..cursor];
        while (cursor < attributes.len and std.ascii.isWhitespace(attributes[cursor])) cursor += 1;
        if (cursor >= attributes.len or attributes[cursor] != '=') {
            while (cursor < attributes.len and !std.ascii.isWhitespace(attributes[cursor])) cursor += 1;
            continue;
        }
        cursor += 1;
        while (cursor < attributes.len and std.ascii.isWhitespace(attributes[cursor])) cursor += 1;
        if (cursor >= attributes.len) return null;
        const quote = attributes[cursor];
        const value_start = if (quote == '\'' or quote == '"') cursor + 1 else cursor;
        if (quote == '\'' or quote == '"') {
            const value_end = std.mem.indexOfScalarPos(u8, attributes, value_start, quote) orelse
                return null;
            if (std.ascii.eqlIgnoreCase(name, wanted_name)) return attributes[value_start..value_end];
            cursor = value_end + 1;
        } else {
            var value_end = value_start;
            while (value_end < attributes.len and !std.ascii.isWhitespace(attributes[value_end])) value_end += 1;
            if (std.ascii.eqlIgnoreCase(name, wanted_name)) return attributes[value_start..value_end];
            cursor = value_end;
        }
    }
    return null;
}

fn appendNormalizedText(
    allocator: std.mem.Allocator,
    target: *std.ArrayList(u8),
    raw_text: []const u8,
) !void {
    const decoded = try decodeXmlEntities(allocator, raw_text);
    var pending_space = false;
    for (decoded) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = target.items.len > 0;
            continue;
        }
        if (pending_space and target.items.len > 0 and target.items[target.items.len - 1] != '\n')
            try target.append(allocator, ' ');
        pending_space = false;
        try target.append(allocator, byte);
    }
    if (pending_space and target.items.len > 0 and target.items[target.items.len - 1] != '\n')
        try target.append(allocator, ' ');
}

fn ensureNewlines(
    allocator: std.mem.Allocator,
    target: *std.ArrayList(u8),
    count: usize,
) !void {
    while (target.items.len > 0 and
        (target.items[target.items.len - 1] == ' ' or target.items[target.items.len - 1] == '\t'))
        _ = target.pop();
    if (target.items.len == 0) return;
    var existing: usize = 0;
    var cursor = target.items.len;
    while (cursor > 0 and target.items[cursor - 1] == '\n') : (cursor -= 1) existing += 1;
    if (existing < count) try target.appendNTimes(allocator, '\n', count - existing);
}

fn loadViewedLinks(context: *runtime.RuntimeContext) ![]const []const u8 {
    const path = try feedCachePath(context);
    const contents = std.Io.Dir.cwd().readFileAlloc(
        context.io,
        path,
        context.allocator,
        .limited(max_cache_size),
    ) catch return &.{};
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        context.allocator,
        contents,
        .{},
    ) catch return &.{};
    if (parsed != .array) return &.{};

    var links: std.ArrayList([]const u8) = .empty;
    for (parsed.array.items) |entry| {
        if (entry != .object) continue;
        const value = entry.object.get("Link") orelse entry.object.get("link") orelse continue;
        if (value == .string) try links.append(context.allocator, value.string);
    }
    return links.toOwnedSlice(context.allocator);
}

fn saveFeed(context: *runtime.RuntimeContext, feed: []const NewsItem) !void {
    const path = try feedCachePath(context);
    if (std.fs.path.dirname(path)) |directory|
        try std.Io.Dir.cwd().createDirPath(context.io, directory);

    var payload = std.Io.Writer.Allocating.init(context.allocator);
    defer payload.deinit();
    try writeJson(&payload.writer, feed);
    var file = try std.Io.Dir.createFileAbsolute(context.io, path, .{});
    defer file.close(context.io);
    try file.writeStreamingAll(context.io, payload.writer.buffered());
}

fn feedCachePath(context: *runtime.RuntimeContext) ![]const u8 {
    return xdg.shellyCache(context, &.{ "archNewsFeed", "Feed.json" });
}

fn containsLink(links: []const []const u8, wanted: []const u8) bool {
    for (links) |link| {
        if (std.mem.eql(u8, link, wanted)) return true;
    }
    return false;
}

fn writeJson(writer: *std.Io.Writer, feed: []const NewsItem) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    for (feed) |item| {
        try json.beginObject();
        try json.objectField("Title");
        try json.write(item.title);
        try json.objectField("Link");
        try json.write(item.link);
        try json.objectField("Description");
        try json.write(item.description);
        try json.objectField("PubDate");
        try json.write(item.pub_date);
        try json.endObject();
    }
    try json.endArray();
}

fn writePlain(context: *runtime.RuntimeContext, feed: []const NewsItem) !void {
    for (feed) |item| {
        try context.stdout.writeByte('\n');
        try writeColored(context, item.title, .warning);
        try writeColored(context, item.pub_date, .dim);
        try writeColored(context, item.link, .heading);
        try writeColored(context, item.description, .white);
        try context.stdout.writeByte('\n');
    }
}

fn writeColored(
    context: *runtime.RuntimeContext,
    value: []const u8,
    color: colors.Color,
) !void {
    try colors.printLine(context, color, "{s}", .{value});
}

fn writeFailure(
    context: *runtime.RuntimeContext,
    options: ExecutionOptions,
    err: anyerror,
) !void {
    const message = try std.fmt.allocPrint(
        context.allocator,
        "Error fetching Arch Linux news: {t}",
        .{err},
    );
    if (options.ui_mode)
        try output.writeErrorFrame(context, message)
    else if (options.json)
        try context.stderr.print("{s}\n", .{message})
    else
        try output.writeFailure(context, message);
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        return option.value == null or !std.ascii.eqlIgnoreCase(option.value.?, "false");
    }
    return false;
}

const test_feed =
    \\<?xml version="1.0"?>
    \\<rss><channel>
    \\  <item>
    \\    <title>Newest &amp; important</title>
    \\    <link>https://archlinux.org/news/newest/</link>
    \\    <description><![CDATA[<p>Read <strong>this</strong> <a href="https://example.test/details?a=1&amp;b=2">notice</a>.</p>]]></description>
    \\    <pubDate>Tue, 02 Jan 2024 00:00:00 +0000</pubDate>
    \\  </item>
    \\  <item>
    \\    <title>Older</title>
    \\    <link>https://archlinux.org/news/older/</link>
    \\    <description><![CDATA[<p>Older entry.</p>]]></description>
    \\    <pubDate>Mon, 01 Jan 2024 00:00:00 +0000</pubDate>
    \\  </item>
    \\</channel></rss>
;

fn testFetcher(
    data: ?*anyopaque,
    context: *runtime.RuntimeContext,
    url: []const u8,
) ![]u8 {
    const calls: *usize = @ptrCast(@alignCast(data.?));
    calls.* += 1;
    try std.testing.expectEqualStrings(arch_linux_feed, url);
    return context.allocator.dupe(u8, test_feed);
}

test "news is a standalone -N command with all and help modifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = try spec.Manifest.load(allocator);

    const base = try @import("../cli/shortcodes.zig").translate(allocator, &manifest, &.{"-N"});
    try std.testing.expect(base == .translated);
    try expectArguments(&.{"news"}, base.translated);

    const all = try @import("../cli/shortcodes.zig").translate(allocator, &manifest, &.{"-Na"});
    try std.testing.expect(all == .translated);
    try expectArguments(&.{ "news", "-a" }, all.translated);

    const help = try @import("../cli/shortcodes.zig").translate(allocator, &manifest, &.{"-Nh"});
    try std.testing.expect(help == .translated);
    try expectArguments(&.{ "news", "--help" }, help.translated);

    const long_form = try parser.parse(allocator, &manifest, &.{"news"});
    try std.testing.expect(long_form == .dispatch);
    try std.testing.expectEqualStrings(command_path, long_form.dispatch.command.path);
}

fn expectArguments(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |wanted, observed|
        try std.testing.expectEqualStrings(wanted, observed);
}

test "news parses RSS in chronological order and converts descriptions to Markdown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const feed = try parseFeed(arena.allocator(), test_feed);

    try std.testing.expectEqual(@as(usize, 2), feed.len);
    try std.testing.expectEqualStrings("Older", feed[0].title);
    try std.testing.expectEqualStrings("Newest & important", feed[1].title);
    try std.testing.expectEqualStrings(
        "Read **this** [notice][1].\n\n[1]: https://example.test/details?a=1&b=2",
        feed[1].description,
    );
}

test "news caches the full feed and subsequently displays only unseen entries" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("HOME", "/home/tester");
    try environment.put("XDG_CACHE_HOME", absolute_buffer[0..absolute_length]);
    const manifest = try spec.Manifest.load(arena.allocator());
    const json_outcome = try parser.parse(arena.allocator(), &manifest, &.{ "news", "--json" });
    const plain_outcome = try parser.parse(arena.allocator(), &manifest, &.{"news"});
    try std.testing.expect(json_outcome == .dispatch);
    try std.testing.expect(plain_outcome == .dispatch);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .environment = &environment,
    };
    var calls: usize = 0;
    const fetcher: Fetcher = .{ .data = &calls, .call = testFetcher };

    try std.testing.expectEqual(
        @as(u8, 0),
        try executeWithFetcher(&context, &json_outcome.dispatch, fetcher),
    );
    const first_output = stdout.writer.buffered();
    const older_position = std.mem.indexOf(u8, first_output, "Older").?;
    const newest_position = std.mem.indexOf(u8, first_output, "Newest & important").?;
    try std.testing.expect(older_position < newest_position);
    try std.testing.expect(std.mem.indexOf(u8, first_output, "\"Title\":\"Older\"") != null);

    const cached = try temporary.dir.readFileAlloc(
        std.testing.io,
        "Shelly/archNewsFeed/Feed.json",
        std.testing.allocator,
        .limited(max_cache_size),
    );
    defer std.testing.allocator.free(cached);
    try std.testing.expect(std.mem.indexOf(u8, cached, "\"Link\":\"https://archlinux.org/news/newest/\"") != null);

    stdout.writer.end = 0;
    try std.testing.expectEqual(
        @as(u8, 0),
        try executeWithFetcher(&context, &plain_outcome.dispatch, fetcher),
    );
    try std.testing.expectEqualStrings("No new news found\n", stdout.writer.buffered());
    try std.testing.expectEqual(@as(usize, 2), calls);
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
}

test "news all emits the full feed as a UI frame even when entries were viewed" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("HOME", "/home/tester");
    try environment.put("XDG_CACHE_HOME", absolute_buffer[0..absolute_length]);
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{ "news", "--all", "--ui-mode" });
    try std.testing.expect(outcome == .dispatch);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .environment = &environment,
    };
    var calls: usize = 0;
    try std.testing.expectEqual(
        @as(u8, 0),
        try executeWithFetcher(
            &context,
            &outcome.dispatch,
            .{ .data = &calls, .call = testFetcher },
        ),
    );
    try std.testing.expect(std.mem.startsWith(u8, stdout.writer.buffered(), "[JSON]"));
    try std.testing.expect(std.mem.endsWith(u8, stdout.writer.buffered(), "[/JSON]\n"));
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
}
