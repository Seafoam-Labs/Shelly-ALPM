const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("zig-xml");

pub const Node = union(enum) {
    element: Element,
    text: []const u8,
};

pub const Element = struct {
    name: []const u8,
    attributes: std.StringArrayHashMapUnmanaged([]const u8),
    children: []const Node,

    pub fn attr(self: Element, name: []const u8) ?[]const u8 {
        return self.attributes.get(name);
    }

    pub fn element(self: Element, name: []const u8) ?Element {
        for (self.children) |child| {
            if (child == .element and std.mem.eql(u8, child.element.name, name)) {
                return child.element;
            }
        }
        return null;
    }

    pub fn elementNoLang(self: Element, name: []const u8) ?Element {
        for (self.children) |child| {
            if (child != .element) continue;
            if (!std.mem.eql(u8, child.element.name, name)) continue;
            if (child.element.attr("xml:lang") == null) return child.element;
        }
        return null;
    }

    pub fn elements(self: Element, allocator: Allocator, name: []const u8) ![]Element {
        var list: std.ArrayList(Element) = .empty;
        for (self.children) |child| {
            if (child == .element and std.mem.eql(u8, child.element.name, name)) {
                try list.append(allocator, child.element);
            }
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn value(self: Element, allocator: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try self.collectText(&out, allocator);
        return out.toOwnedSlice(allocator);
    }

    fn collectText(self: Element, out: *std.ArrayList(u8), allocator: Allocator) !void {
        for (self.children) |child| {
            switch (child) {
                .text => |t| try out.appendSlice(allocator, t),
                .element => |e| try e.collectText(out, allocator),
            }
        }
    }
};

pub const AppstreamIcon = struct {
    type: []const u8,
    url: []const u8,
    width: ?i32 = null,
    height: ?i32 = null,
    scale: ?i32 = null,
};

pub const AppstreamImage = struct {
    type: []const u8,
    url: []const u8,
    width: ?i32 = null,
    height: ?i32 = null,
};

pub const AppstreamScreenshot = struct {
    is_default: bool,
    caption: []const u8,
    images: []const AppstreamImage,
};

pub const AppstreamRelease = struct {
    version: []const u8,
    type: []const u8,
    timestamp: ?i64 = null,
    description: []const u8,
};

pub const AppstreamApp = struct {
    type: []const u8,
    id: []const u8,
    name: []const u8,
    summary: []const u8,
    project_license: []const u8,
    developer_name: []const u8,
    extends: ?[]const u8,
    description: []const u8,
    categories: []const []const u8,
    keywords: []const []const u8,
    urls: std.StringArrayHashMapUnmanaged([]const u8),
    icons: []const AppstreamIcon,
    screenshots: []const AppstreamScreenshot,
    releases: []const AppstreamRelease,
    is_verified: bool,
    verification_method: ?[]const u8,
    addons: []AppstreamApp,
};

pub const AppstreamParser = struct {
    arena: Allocator,
    io: std.Io,

    pub fn parseFile(self: AppstreamParser, path: []const u8) ![]AppstreamApp {
        var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);

        if (std.mem.endsWith(u8, path, ".gz")) {
            // TODO: gzip decompression not yet wired up.
            return error.GzipNotYetSupported;
        }

        var buf: [4096]u8 = undefined;
        var file_reader = file.reader(self.io, &buf);
        var streaming_reader: xml.Reader.Streaming = .init(self.arena, &file_reader.interface, .{});
        defer streaming_reader.deinit();

        return self.parseStream(&streaming_reader.interface);
    }

    pub fn parseStream(self: AppstreamParser, reader: *xml.Reader) ![]AppstreamApp {
        const root = try self.parseTree(reader);

        var apps: std.ArrayList(AppstreamApp) = .empty;
        var addons: std.ArrayList(AppstreamApp) = .empty;

        const components = try root.elements(self.arena, "component");
        for (components) |component| {
            const app = try self.parseComponent(component) orelse continue;
            if (std.mem.eql(u8, app.type, "addon")) {
                try addons.append(self.arena, app);
            } else {
                try apps.append(self.arena, app);
            }
        }

        for (addons.items) |addon| {
            const extends = addon.extends orelse continue;
            for (apps.items) |*app| {
                if (std.mem.eql(u8, app.id, extends)) {
                    var app_addons: std.ArrayList(AppstreamApp) = .fromOwnedSlice(app.addons);
                    try app_addons.append(self.arena, addon);
                    app.addons = try app_addons.toOwnedSlice(self.arena);
                    break;
                }
            }
        }

        return apps.toOwnedSlice(self.arena);
    }

    fn parseTree(self: AppstreamParser, reader: *xml.Reader) !Element {
        while (true) {
            switch (try reader.read()) {
                .eof => return error.NoRootElement,
                .element_start => return try self.parseElement(reader),
                else => continue,
            }
        }
    }

    fn parseElement(self: AppstreamParser, reader: *xml.Reader) !Element {
        const arena = self.arena;
        const name = try arena.dupe(u8, reader.elementName());
        var attributes: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        for (0..reader.attributeCount()) |i| {
            try attributes.put(
                arena,
                try arena.dupe(u8, reader.attributeName(i)),
                try reader.attributeValueAlloc(arena, i),
            );
        }

        var children: std.ArrayList(Node) = .empty;
        var text: std.Io.Writer.Allocating = .init(arena);

        while (true) {
            switch (try reader.read()) {
                .eof, .xml_declaration => unreachable,
                .element_start => {
                    if (text.written().len > 0) {
                        try children.append(arena, .{ .text = try text.toOwnedSlice() });
                        text = .init(arena);
                    }
                    try children.append(arena, .{ .element = try self.parseElement(reader) });
                },
                .element_end => break,
                .comment, .pi => continue,
                .text => reader.textWrite(&text.writer) catch return error.OutOfMemory,
                .cdata => reader.cdataWrite(&text.writer) catch return error.OutOfMemory,
                .character_reference => {
                    text.writer.print("{u}", .{reader.characterReferenceChar()}) catch return error.OutOfMemory;
                },
                .entity_reference => {
                    const val = xml.predefined_entities.get(reader.entityReferenceName()).?;
                    text.writer.writeAll(val) catch return error.OutOfMemory;
                },
            }
        }
        if (text.written().len > 0) {
            try children.append(arena, .{ .text = try text.toOwnedSlice() });
        }

        return .{
            .name = name,
            .attributes = attributes,
            .children = try children.toOwnedSlice(arena),
        };
    }

    fn parseComponent(self: AppstreamParser, component: Element) !?AppstreamApp {
        const arena = self.arena;
        const comp_type = component.attr("type") orelse return null;
        if (!std.mem.eql(u8, comp_type, "desktop-application") and
            !std.mem.eql(u8, comp_type, "console-application") and
            !std.mem.eql(u8, comp_type, "addon") and
            !std.mem.eql(u8, comp_type, "desktop"))
        {
            return null;
        }

        var id: []const u8 = "";
        if (component.element("id")) |id_el| {
            id = try id_el.value(arena);
            if (std.mem.endsWith(u8, id, ".desktop")) {
                id = id[0 .. id.len - ".desktop".len];
            }
        }

        const name = if (component.elementNoLang("name")) |el| try el.value(arena) else "";
        const summary = if (component.elementNoLang("summary")) |el| try el.value(arena) else "";
        const project_license = if (component.element("project_license")) |el| try el.value(arena) else "";

        const developer_name = blk: {
            if (component.element("developer_name")) |el| break :blk try el.value(arena);
            if (component.element("developer")) |dev| {
                if (dev.element("name")) |name_el| break :blk try name_el.value(arena);
            }
            break :blk "";
        };

        const extends: ?[]const u8 = if (component.element("extends")) |el| try el.value(arena) else null;

        const description = if (component.elementNoLang("description")) |el|
            try self.parseDescription(el)
        else
            "";

        var categories: []const []const u8 = &.{};
        if (component.element("categories")) |cats_el| {
            const cat_els = try cats_el.elements(arena, "category");
            var list: std.ArrayList([]const u8) = .empty;
            for (cat_els) |c| try list.append(arena, try c.value(arena));
            categories = try list.toOwnedSlice(arena);
        }

        var keywords: []const []const u8 = &.{};
        if (component.element("keywords")) |kw_el| {
            const kw_els = try kw_el.elements(arena, "keyword");
            var list: std.ArrayList([]const u8) = .empty;
            for (kw_els) |k| try list.append(arena, try k.value(arena));
            keywords = try list.toOwnedSlice(arena);
        }

        var urls: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        const url_els = try component.elements(arena, "url");
        for (url_els) |url_el| {
            const url_type = url_el.attr("type") orelse continue;
            try urls.put(arena, url_type, try url_el.value(arena));
        }

        var icons: std.ArrayList(AppstreamIcon) = .empty;
        const icon_els = try component.elements(arena, "icon");
        for (icon_els) |icon_el| {
            if (try self.parseIcon(icon_el)) |icon| try icons.append(arena, icon);
        }

        var screenshots: std.ArrayList(AppstreamScreenshot) = .empty;
        const screenshots_containers = try component.elements(arena, "screenshots");
        for (screenshots_containers) |container| {
            const shot_els = try container.elements(arena, "screenshot");
            for (shot_els) |shot_el| {
                try screenshots.append(arena, try self.parseScreenshot(shot_el));
            }
        }

        var releases: []const AppstreamRelease = &.{};
        if (component.element("releases")) |rel_container| {
            const rel_els = try rel_container.elements(arena, "release");
            var list: std.ArrayList(AppstreamRelease) = .empty;
            for (rel_els) |rel_el| try list.append(arena, try self.parseRelease(rel_el));
            releases = try list.toOwnedSlice(arena);
        }

        var is_verified = false;
        var verification_method: ?[]const u8 = null;
        if (component.element("custom")) |custom_el| {
            const values = try custom_el.elements(arena, "value");
            for (values) |v| {
                const key = v.attr("key") orelse continue;
                if (std.mem.eql(u8, key, "flathub::verification::verified")) {
                    const val = try v.value(arena);
                    if (std.ascii.eqlIgnoreCase(val, "true")) is_verified = true;
                }
            }
            if (is_verified) {
                for (values) |v| {
                    const key = v.attr("key") orelse continue;
                    if (std.mem.eql(u8, key, "flathub::verification::method")) {
                        verification_method = try v.value(arena);
                    }
                }
            }
        }

        return AppstreamApp{
            .type = comp_type,
            .id = id,
            .name = name,
            .summary = summary,
            .project_license = project_license,
            .developer_name = developer_name,
            .extends = extends,
            .description = description,
            .categories = categories,
            .keywords = keywords,
            .urls = urls,
            .icons = try icons.toOwnedSlice(arena),
            .screenshots = try screenshots.toOwnedSlice(arena),
            .releases = releases,
            .is_verified = is_verified,
            .verification_method = verification_method,
            .addons = &.{},
        };
    }

    fn parseDescription(self: AppstreamParser, description: Element) ![]const u8 {
        const arena = self.arena;
        var parts: std.ArrayList([]const u8) = .empty;

        for (description.children) |child| {
            if (child != .element) continue;
            const el = child.element;
            if (std.mem.eql(u8, el.name, "p")) {
                const text = try el.value(arena);
                try parts.append(arena, std.mem.trim(u8, text, " \t\r\n"));
            } else if (std.mem.eql(u8, el.name, "ul")) {
                const lis = try el.elements(arena, "li");
                for (lis) |li| {
                    const text = std.mem.trim(u8, try li.value(arena), " \t\r\n");
                    try parts.append(arena, try std.fmt.allocPrint(arena, "\u{2022} {s}", .{text}));
                }
            } else if (std.mem.eql(u8, el.name, "ol")) {
                const lis = try el.elements(arena, "li");
                for (lis, 1..) |li, index| {
                    const text = std.mem.trim(u8, try li.value(arena), " \t\r\n");
                    try parts.append(arena, try std.fmt.allocPrint(arena, "{d}. {s}", .{ index, text }));
                }
            }
        }

        return std.mem.join(arena, "\n\n", parts.items);
    }

    fn parseIcon(self: AppstreamParser, icon: Element) !?AppstreamIcon {
        const icon_type = icon.attr("type") orelse return null;
        return AppstreamIcon{
            .type = icon_type,
            .url = try icon.value(self.arena),
            .width = if (icon.attr("width")) |w| std.fmt.parseInt(i32, w, 10) catch null else null,
            .height = if (icon.attr("height")) |h| std.fmt.parseInt(i32, h, 10) catch null else null,
            .scale = if (icon.attr("scale")) |s| std.fmt.parseInt(i32, s, 10) catch null else null,
        };
    }

    fn parseScreenshot(self: AppstreamParser, screenshot: Element) !AppstreamScreenshot {
        const arena = self.arena;
        const is_default = if (screenshot.attr("type")) |t| std.mem.eql(u8, t, "default") else false;
        const caption = if (screenshot.element("caption")) |c| try c.value(arena) else "";

        const image_els = try screenshot.elements(arena, "image");
        var images: std.ArrayList(AppstreamImage) = .empty;
        for (image_els) |img_el| try images.append(arena, try self.parseImage(img_el));

        return .{
            .is_default = is_default,
            .caption = caption,
            .images = try images.toOwnedSlice(arena),
        };
    }

    fn parseImage(self: AppstreamParser, image: Element) !AppstreamImage {
        return .{
            .type = image.attr("type") orelse "",
            .url = try image.value(self.arena),
            .width = if (image.attr("width")) |w| std.fmt.parseInt(i32, w, 10) catch null else null,
            .height = if (image.attr("height")) |h| std.fmt.parseInt(i32, h, 10) catch null else null,
        };
    }

    fn parseRelease(self: AppstreamParser, release: Element) !AppstreamRelease {
        const version = release.attr("version") orelse "";
        const rel_type = release.attr("type") orelse "";
        const timestamp: ?i64 = if (release.attr("timestamp")) |t| std.fmt.parseInt(i64, t, 10) catch null else null;
        const description = if (release.element("description")) |d| try self.parseDescription(d) else "";

        return .{
            .version = version,
            .type = rel_type,
            .timestamp = timestamp,
            .description = description,
        };
    }
};

test "parseStream parses a full component with description, icons, screenshots, releases, urls and verification" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const source =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<components version="0.8" origin="flathub">
        \\  <component type="desktop-application">
        \\    <id>org.example.App.desktop</id>
        \\    <name>Example App</name>
        \\    <name xml:lang="fr">Exemple App</name>
        \\    <summary>An example application</summary>
        \\    <project_license>MIT</project_license>
        \\    <developer_name>Jane Doe</developer_name>
        \\    <description>
        \\      <p>This is a paragraph.</p>
        \\      <ul>
        \\        <li>First item</li>
        \\        <li>Second item</li>
        \\      </ul>
        \\      <ol>
        \\        <li>Step one</li>
        \\        <li>Step two</li>
        \\      </ol>
        \\    </description>
        \\    <categories>
        \\      <category>Utility</category>
        \\      <category>Development</category>
        \\    </categories>
        \\    <keywords>
        \\      <keyword>example</keyword>
        \\      <keyword>demo</keyword>
        \\    </keywords>
        \\    <url type="homepage">https://example.org</url>
        \\    <url type="bugtracker">https://example.org/issues</url>
        \\    <icon type="cached" width="64" height="64">org.example.App.png</icon>
        \\    <icon type="remote" scale="2">https://example.org/icon.png</icon>
        \\    <screenshots>
        \\      <screenshot type="default">
        \\        <caption>Main window</caption>
        \\        <image type="source" width="1200" height="800">https://example.org/shot1.png</image>
        \\      </screenshot>
        \\      <screenshot>
        \\        <image type="source">https://example.org/shot2.png</image>
        \\      </screenshot>
        \\    </screenshots>
        \\    <releases>
        \\      <release version="1.2.0" type="stable" timestamp="1700000000">
        \\        <description>
        \\          <p>Bug fixes and improvements.</p>
        \\        </description>
        \\      </release>
        \\    </releases>
        \\    <custom>
        \\      <value key="flathub::verification::verified">true</value>
        \\      <value key="flathub::verification::method">website</value>
        \\    </custom>
        \\  </component>
        \\  <component type="addon">
        \\    <id>org.example.App.Plugin</id>
        \\    <extends>org.example.App</extends>
        \\    <name>Example Plugin</name>
        \\  </component>
        \\  <component type="generic">
        \\    <id>org.example.Ignored</id>
        \\  </component>
        \\</components>
        \\
    ;

    var static_reader: xml.Reader.Static = .init(allocator, source, .{});
    defer static_reader.deinit();

    const parser = AppstreamParser{ .arena = allocator, .io = std.testing.io };
    const apps = try parser.parseStream(&static_reader.interface);

    // Unsupported component types (e.g. "generic") and addons are excluded
    // from the top-level app list.
    try std.testing.expectEqual(@as(usize, 1), apps.len);
    const app = apps[0];

    // The ".desktop" suffix is stripped from the id.
    try std.testing.expectEqualStrings("org.example.App", app.id);
    // elementNoLang picks the untranslated <name>, ignoring xml:lang variants.
    try std.testing.expectEqualStrings("Example App", app.name);
    try std.testing.expectEqualStrings("An example application", app.summary);
    try std.testing.expectEqualStrings("MIT", app.project_license);
    try std.testing.expectEqualStrings("Jane Doe", app.developer_name);

    try std.testing.expectEqualStrings(
        "This is a paragraph.\n\n\u{2022} First item\n\n\u{2022} Second item\n\n1. Step one\n\n2. Step two",
        app.description,
    );

    try std.testing.expectEqual(@as(usize, 2), app.categories.len);
    try std.testing.expectEqualStrings("Utility", app.categories[0]);
    try std.testing.expectEqualStrings("Development", app.categories[1]);

    try std.testing.expectEqual(@as(usize, 2), app.keywords.len);
    try std.testing.expectEqualStrings("example", app.keywords[0]);
    try std.testing.expectEqualStrings("demo", app.keywords[1]);

    try std.testing.expectEqualStrings("https://example.org", app.urls.get("homepage").?);
    try std.testing.expectEqualStrings("https://example.org/issues", app.urls.get("bugtracker").?);

    try std.testing.expectEqual(@as(usize, 2), app.icons.len);
    try std.testing.expectEqualStrings("cached", app.icons[0].type);
    try std.testing.expectEqualStrings("org.example.App.png", app.icons[0].url);
    try std.testing.expectEqual(@as(?i32, 64), app.icons[0].width);
    try std.testing.expectEqual(@as(?i32, 64), app.icons[0].height);
    try std.testing.expectEqual(@as(?i32, null), app.icons[0].scale);
    try std.testing.expectEqualStrings("remote", app.icons[1].type);
    try std.testing.expectEqual(@as(?i32, 2), app.icons[1].scale);
    try std.testing.expectEqual(@as(?i32, null), app.icons[1].width);

    try std.testing.expectEqual(@as(usize, 2), app.screenshots.len);
    try std.testing.expect(app.screenshots[0].is_default);
    try std.testing.expectEqualStrings("Main window", app.screenshots[0].caption);
    try std.testing.expectEqual(@as(usize, 1), app.screenshots[0].images.len);
    try std.testing.expectEqualStrings("source", app.screenshots[0].images[0].type);
    try std.testing.expectEqualStrings("https://example.org/shot1.png", app.screenshots[0].images[0].url);
    try std.testing.expectEqual(@as(?i32, 1200), app.screenshots[0].images[0].width);
    try std.testing.expectEqual(@as(?i32, 800), app.screenshots[0].images[0].height);

    try std.testing.expect(!app.screenshots[1].is_default);
    try std.testing.expectEqualStrings("", app.screenshots[1].caption);

    try std.testing.expectEqual(@as(usize, 1), app.releases.len);
    try std.testing.expectEqualStrings("1.2.0", app.releases[0].version);
    try std.testing.expectEqualStrings("stable", app.releases[0].type);
    try std.testing.expectEqual(@as(?i64, 1700000000), app.releases[0].timestamp);
    try std.testing.expectEqualStrings("Bug fixes and improvements.", app.releases[0].description);

    try std.testing.expect(app.is_verified);
    try std.testing.expectEqualStrings("website", app.verification_method.?);

    // The "addon" component is linked as a child of the app it extends via
    // <extends>, rather than appearing in the top-level app list.
    try std.testing.expectEqual(@as(usize, 1), app.addons.len);
    try std.testing.expectEqualStrings("org.example.App.Plugin", app.addons[0].id);
    try std.testing.expectEqualStrings("Example Plugin", app.addons[0].name);
}

test "parseComponent falls back to <developer><name> when developer_name is absent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const source =
        \\<components>
        \\  <component type="desktop-application">
        \\    <id>org.example.Nested</id>
        \\    <developer>
        \\      <name>Nested Dev</name>
        \\    </developer>
        \\  </component>
        \\</components>
        \\
    ;

    var static_reader: xml.Reader.Static = .init(allocator, source, .{});
    defer static_reader.deinit();

    const parser = AppstreamParser{ .arena = allocator, .io = std.testing.io };
    const apps = try parser.parseStream(&static_reader.interface);

    try std.testing.expectEqual(@as(usize, 1), apps.len);
    try std.testing.expectEqualStrings("Nested Dev", apps[0].developer_name);
}

// test "parseFile smoke test against a real Flathub appstream file (skipped if unavailable)" {
//     var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena_state.deinit();

//     const parser = AppstreamParser{ .arena = arena_state.allocator(), .io = std.testing.io };
//     const apps = parser.parseFile("/var/lib/flatpak/appstream/flathub/x86_64/active/appstream.xml") catch |err| switch (err) {
//         error.FileNotFound => return error.SkipZigTest,
//         else => return err,
//     };
//     try std.testing.expect(apps.len > 500);
// }
