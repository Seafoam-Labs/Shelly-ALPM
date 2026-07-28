const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("zig-xml");
const types = @import("types.zig");

pub const AppstreamIcon = types.AppstreamIcon;
pub const AppstreamImage = types.AppstreamImage;
pub const AppstreamScreenshot = types.AppstreamScreenshot;
pub const AppstreamRelease = types.AppstreamRelease;
pub const AppstreamApp = types.AppstreamApp;

pub const AppstreamParser = struct {
    arena: Allocator,
    io: std.Io,
    scratch_allocator: Allocator = std.heap.page_allocator,

    pub fn parseFile(self: AppstreamParser, path: []const u8) ![]AppstreamApp {
        if (!std.ascii.endsWithIgnoreCase(path, ".gz")) {
            const contents = try std.Io.Dir.cwd().readFileAlloc(
                self.io,
                path,
                self.scratch_allocator,
                .unlimited,
            );
            defer self.scratch_allocator.free(contents);
            var static_reader: xml.Reader.Static = .init(
                self.scratch_allocator,
                contents,
                reader_options,
            );
            defer static_reader.deinit();
            return self.parseStream(&static_reader.interface);
        }

        var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);

        var buf: [64 * 1024]u8 = undefined;
        var file_reader = file.reader(self.io, &buf);
        var decompression_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompressor: std.compress.flate.Decompress = .init(
            &file_reader.interface,
            .gzip,
            &decompression_buffer,
        );
        const contents = try decompressor.reader.allocRemaining(
            self.scratch_allocator,
            .unlimited,
        );
        defer self.scratch_allocator.free(contents);
        var static_reader: xml.Reader.Static = .init(
            self.scratch_allocator,
            contents,
            reader_options,
        );
        defer static_reader.deinit();

        return self.parseStream(&static_reader.interface);
    }

    pub fn parseStream(self: AppstreamParser, reader: *xml.Reader) ![]AppstreamApp {
        var apps: std.ArrayList(AppstreamApp) = .empty;
        defer apps.deinit(self.scratch_allocator);
        var addons: std.ArrayList(AppstreamApp) = .empty;
        defer addons.deinit(self.scratch_allocator);

        var component_arena = std.heap.ArenaAllocator.init(self.scratch_allocator);
        defer component_arena.deinit();

        while (true) {
            switch (try reader.read()) {
                .eof => break,
                .element_start => {
                    if (!std.mem.eql(u8, reader.elementName(), "component")) continue;
                    const parsed = try parseComponent(reader, component_arena.allocator());
                    if (parsed) |component| {
                        const owned = try cloneApp(self.arena, component);
                        if (std.mem.eql(u8, owned.type, "addon"))
                            try addons.append(self.scratch_allocator, owned)
                        else
                            try apps.append(self.scratch_allocator, owned);
                    }
                    _ = component_arena.reset(.retain_capacity);
                },
                else => continue,
            }
        }

        var indices: std.StringHashMapUnmanaged(usize) = .empty;
        defer indices.deinit(self.scratch_allocator);
        for (apps.items, 0..) |app, index| {
            const entry = try indices.getOrPut(self.scratch_allocator, app.id);
            if (!entry.found_existing) entry.value_ptr.* = index;
        }

        const addon_lists = try self.scratch_allocator.alloc(std.ArrayList(AppstreamApp), apps.items.len);
        defer self.scratch_allocator.free(addon_lists);
        for (addon_lists) |*list| list.* = .empty;
        defer for (addon_lists) |*list| list.deinit(self.scratch_allocator);

        for (addons.items) |addon| {
            const extends = addon.extends orelse continue;
            const index = indices.get(extends) orelse continue;
            try addon_lists[index].append(self.scratch_allocator, addon);
        }
        for (apps.items, addon_lists) |*app, list| {
            if (list.items.len > 0) app.addons = try self.arena.dupe(AppstreamApp, list.items);
        }

        return self.arena.dupe(AppstreamApp, apps.items);
    }

    fn parseComponent(
        reader: *xml.Reader,
        scratch: Allocator,
    ) !?AppstreamApp {
        const comp_type = try attributeDupe(reader, scratch, "type") orelse {
            try skipElement(reader);
            return null;
        };
        if (!std.mem.eql(u8, comp_type, "desktop-application") and
            !std.mem.eql(u8, comp_type, "console-application") and
            !std.mem.eql(u8, comp_type, "addon") and
            !std.mem.eql(u8, comp_type, "desktop"))
        {
            try skipElement(reader);
            return null;
        }

        var app: AppstreamApp = .{
            .type = comp_type,
            .id = "",
            .name = "",
            .summary = "",
            .project_license = "",
            .developer_name = "",
            .extends = null,
            .description = "",
            .categories = &.{},
            .keywords = &.{},
            .urls = .empty,
            .icons = &.{},
            .screenshots = &.{},
            .releases = &.{},
            .is_verified = false,
            .verification_method = null,
            .addons = &.{},
        };
        var icons: std.ArrayList(AppstreamIcon) = .empty;
        var screenshots: std.ArrayList(AppstreamScreenshot) = .empty;
        var releases: std.ArrayList(AppstreamRelease) = .empty;
        var fallback_developer: []const u8 = "";
        var id_seen = false;
        var name_seen = false;
        var summary_seen = false;
        var license_seen = false;
        var developer_seen = false;
        var fallback_developer_seen = false;
        var extends_seen = false;
        var description_seen = false;
        var categories_seen = false;
        var keywords_seen = false;
        var releases_seen = false;
        var custom_seen = false;

        while (true) {
            switch (try reader.read()) {
                .eof => return error.UnexpectedEndOfStream,
                .element_end => {
                    if (std.mem.eql(u8, reader.elementName(), "component")) break;
                },
                .element_start => {
                    const name = reader.elementName();
                    if (std.mem.eql(u8, name, "id")) {
                        if (id_seen) try skipElement(reader) else {
                            app.id = try readElementText(reader, scratch);
                            if (std.mem.endsWith(u8, app.id, ".desktop"))
                                app.id = app.id[0 .. app.id.len - ".desktop".len];
                            id_seen = true;
                        }
                    } else if (std.mem.eql(u8, name, "name")) {
                        if (name_seen or hasLanguage(reader)) try skipElement(reader) else {
                            app.name = try readElementText(reader, scratch);
                            name_seen = true;
                        }
                    } else if (std.mem.eql(u8, name, "summary")) {
                        if (summary_seen or hasLanguage(reader)) try skipElement(reader) else {
                            app.summary = try readElementText(reader, scratch);
                            summary_seen = true;
                        }
                    } else if (std.mem.eql(u8, name, "project_license")) {
                        if (license_seen) try skipElement(reader) else {
                            app.project_license = try readElementText(reader, scratch);
                            license_seen = true;
                        }
                    } else if (std.mem.eql(u8, name, "developer_name")) {
                        if (developer_seen) try skipElement(reader) else {
                            app.developer_name = try readElementText(reader, scratch);
                            developer_seen = true;
                        }
                    } else if (std.mem.eql(u8, name, "developer")) {
                        if (fallback_developer_seen) try skipElement(reader) else {
                            fallback_developer = try parseDeveloper(reader, scratch);
                            fallback_developer_seen = true;
                        }
                    } else if (std.mem.eql(u8, name, "extends")) {
                        if (extends_seen) try skipElement(reader) else {
                            app.extends = try readElementText(reader, scratch);
                            extends_seen = true;
                        }
                    } else if (std.mem.eql(u8, name, "description")) {
                        if (description_seen or hasLanguage(reader)) try skipElement(reader) else {
                            app.description = try parseDescription(reader, scratch);
                            description_seen = true;
                        }
                    } else if (std.mem.eql(u8, name, "categories")) {
                        if (categories_seen) try skipElement(reader) else {
                            app.categories = try parseStringContainer(reader, scratch, "category");
                            categories_seen = true;
                        }
                    } else if (std.mem.eql(u8, name, "keywords")) {
                        if (keywords_seen) try skipElement(reader) else {
                            app.keywords = try parseStringContainer(reader, scratch, "keyword");
                            keywords_seen = true;
                        }
                    } else if (std.mem.eql(u8, name, "url")) {
                        const url_type = try attributeDupe(reader, scratch, "type");
                        const value = try readElementText(reader, scratch);
                        if (url_type) |key| try app.urls.put(scratch, key, value);
                    } else if (std.mem.eql(u8, name, "icon")) {
                        if (try parseIcon(reader, scratch)) |icon|
                            try icons.append(scratch, icon);
                    } else if (std.mem.eql(u8, name, "screenshots")) {
                        try parseScreenshots(reader, scratch, &screenshots);
                    } else if (std.mem.eql(u8, name, "releases")) {
                        if (releases_seen) try skipElement(reader) else {
                            try parseReleases(reader, scratch, &releases);
                            releases_seen = true;
                        }
                    } else if (std.mem.eql(u8, name, "custom")) {
                        if (custom_seen) try skipElement(reader) else {
                            try parseCustom(reader, scratch, &app);
                            custom_seen = true;
                        }
                    } else {
                        try skipElement(reader);
                    }
                },
                else => {},
            }
        }

        if (!developer_seen) app.developer_name = fallback_developer;
        app.icons = try icons.toOwnedSlice(scratch);
        app.screenshots = try screenshots.toOwnedSlice(scratch);
        app.releases = try releases.toOwnedSlice(scratch);
        return app;
    }
};

const reader_options: xml.Reader.Options = .{
    .namespace_aware = false,
    .updateLocation = null,
    .assume_valid_utf8 = true,
};

fn hasLanguage(reader: *xml.Reader) bool {
    return reader.attributeIndex("xml:lang") != null;
}

fn attributeDupe(
    reader: *xml.Reader,
    allocator: Allocator,
    name: []const u8,
) !?[]const u8 {
    const index = reader.attributeIndex(name) orelse return null;
    return try allocator.dupe(u8, try reader.attributeValue(index));
}

fn attributeInt(
    comptime T: type,
    reader: *xml.Reader,
    name: []const u8,
) !?T {
    const index = reader.attributeIndex(name) orelse return null;
    return std.fmt.parseInt(T, try reader.attributeValue(index), 10) catch null;
}

fn skipElement(reader: *xml.Reader) !void {
    var depth: usize = 1;
    while (depth > 0) {
        switch (try reader.read()) {
            .eof => return error.UnexpectedEndOfStream,
            .element_start => depth += 1,
            .element_end => depth -= 1,
            else => {},
        }
    }
}

fn readElementText(reader: *xml.Reader, allocator: Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    var depth: usize = 1;
    while (depth > 0) {
        switch (try reader.read()) {
            .eof => return error.UnexpectedEndOfStream,
            .element_start => depth += 1,
            .element_end => depth -= 1,
            .text => try reader.textWrite(&out.writer),
            .cdata => try reader.cdataWrite(&out.writer),
            .character_reference => try out.writer.print("{u}", .{reader.characterReferenceChar()}),
            .entity_reference => try out.writer.writeAll(
                xml.predefined_entities.get(reader.entityReferenceName()).?,
            ),
            else => {},
        }
    }
    return out.toOwnedSlice();
}

fn parseDeveloper(reader: *xml.Reader, allocator: Allocator) ![]const u8 {
    var developer_name: []const u8 = "";
    var seen = false;
    while (true) {
        switch (try reader.read()) {
            .eof => return error.UnexpectedEndOfStream,
            .element_end => if (std.mem.eql(u8, reader.elementName(), "developer")) return developer_name,
            .element_start => {
                if (!seen and std.mem.eql(u8, reader.elementName(), "name")) {
                    developer_name = try readElementText(reader, allocator);
                    seen = true;
                } else {
                    try skipElement(reader);
                }
            },
            else => {},
        }
    }
}

fn parseStringContainer(
    reader: *xml.Reader,
    allocator: Allocator,
    child_name: []const u8,
) ![]const []const u8 {
    var values: std.ArrayList([]const u8) = .empty;
    while (true) {
        switch (try reader.read()) {
            .eof => return error.UnexpectedEndOfStream,
            .element_end => return values.toOwnedSlice(allocator),
            .element_start => {
                if (std.mem.eql(u8, reader.elementName(), child_name))
                    try values.append(allocator, try readElementText(reader, allocator))
                else
                    try skipElement(reader);
            },
            else => {},
        }
    }
}

fn appendDescriptionPart(
    writer: *std.Io.Writer,
    has_part: *bool,
    prefix: []const u8,
    text: []const u8,
) !void {
    if (has_part.*) try writer.writeAll("\n\n");
    has_part.* = true;
    try writer.writeAll(prefix);
    try writer.writeAll(std.mem.trim(u8, text, " \t\r\n"));
}

fn parseDescription(reader: *xml.Reader, allocator: Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    var has_part = false;
    while (true) {
        switch (try reader.read()) {
            .eof => return error.UnexpectedEndOfStream,
            .element_end => return out.toOwnedSlice(),
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "p")) {
                    try appendDescriptionPart(
                        &out.writer,
                        &has_part,
                        "",
                        try readElementText(reader, allocator),
                    );
                } else if (std.mem.eql(u8, name, "ul")) {
                    try parseDescriptionList(reader, allocator, &out.writer, &has_part, false);
                } else if (std.mem.eql(u8, name, "ol")) {
                    try parseDescriptionList(reader, allocator, &out.writer, &has_part, true);
                } else {
                    try skipElement(reader);
                }
            },
            else => {},
        }
    }
}

fn parseDescriptionList(
    reader: *xml.Reader,
    allocator: Allocator,
    writer: *std.Io.Writer,
    has_part: *bool,
    ordered: bool,
) !void {
    var index: usize = 1;
    while (true) {
        switch (try reader.read()) {
            .eof => return error.UnexpectedEndOfStream,
            .element_end => return,
            .element_start => {
                if (!std.mem.eql(u8, reader.elementName(), "li")) {
                    try skipElement(reader);
                    continue;
                }
                const text = try readElementText(reader, allocator);
                if (has_part.*) try writer.writeAll("\n\n");
                has_part.* = true;
                if (ordered)
                    try writer.print("{d}. {s}", .{ index, std.mem.trim(u8, text, " \t\r\n") })
                else
                    try writer.print("\u{2022} {s}", .{std.mem.trim(u8, text, " \t\r\n")});
                index += 1;
            },
            else => {},
        }
    }
}

fn parseIcon(reader: *xml.Reader, allocator: Allocator) !?AppstreamIcon {
    const icon_type = try attributeDupe(reader, allocator, "type") orelse {
        try skipElement(reader);
        return null;
    };
    const width = try attributeInt(i32, reader, "width");
    const height = try attributeInt(i32, reader, "height");
    const scale = try attributeInt(i32, reader, "scale");
    return .{
        .type = icon_type,
        .url = try readElementText(reader, allocator),
        .width = width,
        .height = height,
        .scale = scale,
    };
}

fn parseScreenshots(
    reader: *xml.Reader,
    allocator: Allocator,
    screenshots: *std.ArrayList(AppstreamScreenshot),
) !void {
    while (true) {
        switch (try reader.read()) {
            .eof => return error.UnexpectedEndOfStream,
            .element_end => return,
            .element_start => {
                if (std.mem.eql(u8, reader.elementName(), "screenshot"))
                    try screenshots.append(allocator, try parseScreenshot(reader, allocator))
                else
                    try skipElement(reader);
            },
            else => {},
        }
    }
}

fn parseScreenshot(reader: *xml.Reader, allocator: Allocator) !AppstreamScreenshot {
    const screenshot_type = try attributeDupe(reader, allocator, "type");
    var caption: []const u8 = "";
    var caption_seen = false;
    var images: std.ArrayList(AppstreamImage) = .empty;
    while (true) {
        switch (try reader.read()) {
            .eof => return error.UnexpectedEndOfStream,
            .element_end => return .{
                .is_default = if (screenshot_type) |kind| std.mem.eql(u8, kind, "default") else false,
                .caption = caption,
                .images = try images.toOwnedSlice(allocator),
            },
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "caption") and !caption_seen) {
                    caption = try readElementText(reader, allocator);
                    caption_seen = true;
                } else if (std.mem.eql(u8, name, "image")) {
                    try images.append(allocator, try parseImage(reader, allocator));
                } else {
                    try skipElement(reader);
                }
            },
            else => {},
        }
    }
}

fn parseImage(reader: *xml.Reader, allocator: Allocator) !AppstreamImage {
    const image_type = try attributeDupe(reader, allocator, "type") orelse "";
    const width = try attributeInt(i32, reader, "width");
    const height = try attributeInt(i32, reader, "height");
    return .{
        .type = image_type,
        .url = try readElementText(reader, allocator),
        .width = width,
        .height = height,
    };
}

fn parseReleases(
    reader: *xml.Reader,
    allocator: Allocator,
    releases: *std.ArrayList(AppstreamRelease),
) !void {
    while (true) {
        switch (try reader.read()) {
            .eof => return error.UnexpectedEndOfStream,
            .element_end => return,
            .element_start => {
                if (std.mem.eql(u8, reader.elementName(), "release"))
                    try releases.append(allocator, try parseRelease(reader, allocator))
                else
                    try skipElement(reader);
            },
            else => {},
        }
    }
}

fn parseRelease(reader: *xml.Reader, allocator: Allocator) !AppstreamRelease {
    const version = try attributeDupe(reader, allocator, "version") orelse "";
    const release_type = try attributeDupe(reader, allocator, "type") orelse "";
    const timestamp = try attributeInt(i64, reader, "timestamp");
    var description: []const u8 = "";
    var description_seen = false;
    while (true) {
        switch (try reader.read()) {
            .eof => return error.UnexpectedEndOfStream,
            .element_end => return .{
                .version = version,
                .type = release_type,
                .timestamp = timestamp,
                .description = description,
            },
            .element_start => {
                if (std.mem.eql(u8, reader.elementName(), "description") and !description_seen) {
                    description = try parseDescription(reader, allocator);
                    description_seen = true;
                } else {
                    try skipElement(reader);
                }
            },
            else => {},
        }
    }
}

fn parseCustom(
    reader: *xml.Reader,
    allocator: Allocator,
    app: *AppstreamApp,
) !void {
    while (true) {
        switch (try reader.read()) {
            .eof => return error.UnexpectedEndOfStream,
            .element_end => {
                if (!app.is_verified) app.verification_method = null;
                return;
            },
            .element_start => {
                if (!std.mem.eql(u8, reader.elementName(), "value")) {
                    try skipElement(reader);
                    continue;
                }
                const key_index = reader.attributeIndex("key");
                const is_verified = if (key_index) |index|
                    std.mem.eql(u8, try reader.attributeValue(index), "flathub::verification::verified")
                else
                    false;
                const is_method = if (key_index) |index|
                    std.mem.eql(u8, try reader.attributeValue(index), "flathub::verification::method")
                else
                    false;
                const value = try readElementText(reader, allocator);
                if (is_verified and std.ascii.eqlIgnoreCase(value, "true")) app.is_verified = true;
                if (is_method) app.verification_method = value;
            },
            else => {},
        }
    }
}

fn cloneText(allocator: Allocator, value: []const u8) ![]const u8 {
    if (value.len == 0) return "";
    return allocator.dupe(u8, value);
}

fn cloneOptionalText(allocator: Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |text| try cloneText(allocator, text) else null;
}

fn cloneTextSlice(allocator: Allocator, values: []const []const u8) ![]const []const u8 {
    if (values.len == 0) return &.{};
    const result = try allocator.alloc([]const u8, values.len);
    for (values, result) |value, *copy| copy.* = try cloneText(allocator, value);
    return result;
}

fn cloneApp(allocator: Allocator, app: AppstreamApp) !AppstreamApp {
    var urls: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var url_iterator = app.urls.iterator();
    while (url_iterator.next()) |entry| {
        try urls.put(
            allocator,
            try cloneText(allocator, entry.key_ptr.*),
            try cloneText(allocator, entry.value_ptr.*),
        );
    }

    const icons = try allocator.alloc(AppstreamIcon, app.icons.len);
    for (app.icons, icons) |icon, *copy| copy.* = .{
        .type = try cloneText(allocator, icon.type),
        .url = try cloneText(allocator, icon.url),
        .width = icon.width,
        .height = icon.height,
        .scale = icon.scale,
    };

    const screenshots = try allocator.alloc(AppstreamScreenshot, app.screenshots.len);
    for (app.screenshots, screenshots) |screenshot, *copy| {
        const images = try allocator.alloc(AppstreamImage, screenshot.images.len);
        for (screenshot.images, images) |image, *image_copy| image_copy.* = .{
            .type = try cloneText(allocator, image.type),
            .url = try cloneText(allocator, image.url),
            .width = image.width,
            .height = image.height,
        };
        copy.* = .{
            .is_default = screenshot.is_default,
            .caption = try cloneText(allocator, screenshot.caption),
            .images = images,
        };
    }

    const releases = try allocator.alloc(AppstreamRelease, app.releases.len);
    for (app.releases, releases) |release, *copy| copy.* = .{
        .version = try cloneText(allocator, release.version),
        .type = try cloneText(allocator, release.type),
        .timestamp = release.timestamp,
        .description = try cloneText(allocator, release.description),
    };

    const addons = try allocator.alloc(AppstreamApp, app.addons.len);
    for (app.addons, addons) |addon, *copy| copy.* = try cloneApp(allocator, addon);

    return .{
        .type = try cloneText(allocator, app.type),
        .id = try cloneText(allocator, app.id),
        .name = try cloneText(allocator, app.name),
        .summary = try cloneText(allocator, app.summary),
        .project_license = try cloneText(allocator, app.project_license),
        .developer_name = try cloneText(allocator, app.developer_name),
        .extends = try cloneOptionalText(allocator, app.extends),
        .description = try cloneText(allocator, app.description),
        .categories = try cloneTextSlice(allocator, app.categories),
        .keywords = try cloneTextSlice(allocator, app.keywords),
        .urls = urls,
        .icons = icons,
        .screenshots = screenshots,
        .releases = releases,
        .is_verified = app.is_verified,
        .verification_method = try cloneOptionalText(allocator, app.verification_method),
        .addons = addons,
    };
}

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

test "streaming parser skips localized payloads and associates addons by id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const source =
        \\<components>
        \\  <component type="addon">
        \\    <id>org.example.Parent.Plugin</id>
        \\    <extends>org.example.Parent</extends>
        \\    <name>Plugin</name>
        \\  </component>
        \\  <component type="generic">
        \\    <name xml:lang="de"><em>Ignored metadata</em></name>
        \\  </component>
        \\  <component type="desktop-application">
        \\    <id>org.example.Parent</id>
        \\    <name xml:lang="fr">Nom localise</name>
        \\    <summary xml:lang="fr">Resume localise</summary>
        \\    <description xml:lang="fr"><p>Description localisee</p></description>
        \\    <name>Parent</name>
        \\    <summary>Parent summary</summary>
        \\    <description><p>Parent description</p></description>
        \\  </component>
        \\</components>
        \\
    ;

    var static_reader: xml.Reader.Static = .init(allocator, source, .{});
    defer static_reader.deinit();

    const parser = AppstreamParser{ .arena = allocator, .io = std.testing.io };
    const apps = try parser.parseStream(&static_reader.interface);

    try std.testing.expectEqual(@as(usize, 1), apps.len);
    try std.testing.expectEqualStrings("Parent", apps[0].name);
    try std.testing.expectEqualStrings("Parent summary", apps[0].summary);
    try std.testing.expectEqualStrings("Parent description", apps[0].description);
    try std.testing.expectEqual(@as(usize, 1), apps[0].addons.len);
    try std.testing.expectEqualStrings("org.example.Parent.Plugin", apps[0].addons[0].id);
}

test "parseFile reads gzip-compressed AppStream catalogs" {
    const compressed = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x4d, 0x8c,
        0x31, 0x0e, 0x80, 0x20, 0x0c, 0x00, 0xbf, 0x42, 0xd8, 0x85, 0x0f, 0xd4,
        0x26, 0x4e, 0xbe, 0x83, 0x40, 0x63, 0x88, 0x40, 0x1b, 0x61, 0x50, 0x5f,
        0x2f, 0x3a, 0x10, 0xb7, 0xbb, 0x1b, 0x0e, 0x3c, 0x67, 0xe1, 0x42, 0xa5,
        0x55, 0x84, 0xc1, 0xaa, 0x5d, 0x42, 0xb3, 0x0e, 0x54, 0xf7, 0xc6, 0x32,
        0x39, 0x91, 0x14, 0xbd, 0x6b, 0x91, 0x8b, 0x46, 0x88, 0x01, 0xf9, 0xd8,
        0x0c, 0x9d, 0x2e, 0x4b, 0x22, 0xb3, 0xde, 0x51, 0xc0, 0xf6, 0x08, 0xc5,
        0x65, 0xc2, 0x57, 0xd5, 0x22, 0x3d, 0x7d, 0x0a, 0x76, 0x4c, 0xff, 0x5c,
        0xf1, 0x01, 0xf7, 0x03, 0x93, 0xaa, 0x79, 0x00, 0x00, 0x00,
    };

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/appstream.xml.gz",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(path);

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, &compressed);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parser = AppstreamParser{ .arena = arena_state.allocator(), .io = std.testing.io };
    const apps = try parser.parseFile(path);

    try std.testing.expectEqual(@as(usize, 1), apps.len);
    try std.testing.expectEqualStrings("org.example.Gzip", apps[0].id);
    try std.testing.expectEqualStrings("Gzip App", apps[0].name);
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
