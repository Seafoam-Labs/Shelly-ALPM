const std = @import("std");

pub const max_app_id_len = 255;
pub const max_file_path_len = std.fs.max_path_bytes;

const appstream_prefix = "appstream://";
const flatpak_https_prefix = "flatpak+https://";
const flatpak_ref_suffix = ".flatpakref";

const file_uri_prefix = "file://";
const flatpak_bundle_suffix = ".flatpak";

pub const PageTarget = enum {
    flatpak_install,
    flatpak_remove,
    updates,
};

pub fn extractLocalFlatpakFile(arg: []const u8, path_buffer: *[max_file_path_len + 1]u8) ?[:0]const u8 {
    if (std.mem.startsWith(u8, arg, file_uri_prefix)) {
        const path = fileUriToPath(arg, path_buffer) orelse return null;
        if (!hasFlatpakFileSuffix(path)) return null;
        return path_buffer[0..path.len :0];
    }

    if (std.mem.indexOf(u8, arg, "://") != null) return null;
    if (arg.len == 0 or arg.len > max_file_path_len) return null;
    if (!hasFlatpakFileSuffix(arg)) return null;

    @memcpy(path_buffer[0..arg.len], arg);
    path_buffer[arg.len] = 0;
    return path_buffer[0..arg.len :0];
}

fn hasFlatpakFileSuffix(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, flatpak_ref_suffix) or
        std.ascii.endsWithIgnoreCase(path, flatpak_bundle_suffix);
}

fn fileUriToPath(
    uri: []const u8,
    path_buffer: *[max_file_path_len + 1]u8,
) ?[]const u8 {
    const rest = uri[file_uri_prefix.len..];

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const authority = rest[0..slash];
    if (authority.len != 0 and !std.mem.eql(u8, authority, "localhost"))
        return null;

    const encoded = stripQueryAndFragment(rest[slash..]);

    var out: usize = 0;
    var i: usize = 0;
    while (i < encoded.len) {
        if (out >= max_file_path_len) return null;

        if (encoded[i] == '%') {
            if (i + 2 >= encoded.len) return null;
            const high = hexDigit(encoded[i + 1]) orelse return null;
            const low = hexDigit(encoded[i + 2]) orelse return null;
            path_buffer[out] = high * 16 + low;
            i += 3;
        } else {
            path_buffer[out] = encoded[i];
            i += 1;
        }
        out += 1;
    }
    if (out == 0) return null;
    path_buffer[out] = 0;
    return path_buffer[0..out];
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub fn extractFlatpakAppId(arg: []const u8, buffer: *[max_app_id_len + 1]u8) ?[:0]const u8 {
    var app_id: []const u8 = undefined;

    if (std.mem.startsWith(u8, arg, appstream_prefix)) {
        var remainder = stripQueryAndFragment(arg[appstream_prefix.len..]);

        remainder = std.mem.trimStart(u8, remainder, "/");

        if (remainder.len == 0 or
            std.mem.indexOfScalar(u8, remainder, '/') != null)
        {
            return null;
        }

        app_id = remainder;
    } else if (std.mem.startsWith(u8, arg, flatpak_https_prefix)) {
        const remainder =
            stripQueryAndFragment(arg[flatpak_https_prefix.len..]);

        const slash = std.mem.lastIndexOfScalar(u8, remainder, '/') orelse
            return null;

        var final_component = remainder[slash + 1 ..];
        if (final_component.len == 0)
            return null;

        if (std.mem.endsWith(
            u8,
            final_component,
            flatpak_ref_suffix,
        )) {
            final_component =
                final_component[0 .. final_component.len - flatpak_ref_suffix.len];
        }

        if (final_component.len == 0)
            return null;

        app_id = final_component;
    } else {
        return null;
    }

    if (app_id.len == 0 or app_id.len > max_app_id_len)
        return null;

    @memcpy(buffer[0..app_id.len], app_id);
    buffer[app_id.len] = 0;

    return buffer[0..app_id.len :0];
}

pub fn parsePageTarget(value: []const u8) ?PageTarget {
    if (std.mem.eql(u8, value, "flatpak-install"))
        return .flatpak_install;
    if (std.mem.eql(u8, value, "flatpak-remove"))
        return .flatpak_remove;
    if (std.mem.eql(u8, value, "flatpak-update"))
        return .updates;

    return null;
}

fn stripQueryAndFragment(value: []const u8) []const u8 {
    var end = value.len;

    if (std.mem.indexOfScalar(u8, value, '?')) |index|
        end = @min(end, index);

    if (std.mem.indexOfScalar(u8, value, '#')) |index|
        end = @min(end, index);

    return value[0..end];
}

test "extract appstream application ID" {
    var buffer: [max_app_id_len + 1]u8 = undefined;

    const result = extractFlatpakAppId(
        "appstream://org.example.App",
        &buffer,
    );

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(
        "org.example.App",
        result.?,
    );
}

test "extract appstream application ID with three slashes" {
    var buffer: [max_app_id_len + 1]u8 = undefined;

    const result = extractFlatpakAppId(
        "appstream:///org.example.App",
        &buffer,
    );

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(
        "org.example.App",
        result.?,
    );
}

test "extract appstream application ID before query and fragment" {
    var buffer: [max_app_id_len + 1]u8 = undefined;

    const query_result = extractFlatpakAppId(
        "appstream://org.example.App?branch=stable",
        &buffer,
    );

    try std.testing.expect(query_result != null);
    try std.testing.expectEqualStrings(
        "org.example.App",
        query_result.?,
    );

    const fragment_result = extractFlatpakAppId(
        "appstream://org.example.Other#details",
        &buffer,
    );

    try std.testing.expect(fragment_result != null);
    try std.testing.expectEqualStrings(
        "org.example.Other",
        fragment_result.?,
    );
}

test "extract application ID from flatpak+https URL" {
    var buffer: [max_app_id_len + 1]u8 = undefined;

    const result = extractFlatpakAppId(
        "flatpak+https://flathub.org/apps/org.example.App",
        &buffer,
    );

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(
        "org.example.App",
        result.?,
    );
}

test "extract application ID from details URL" {
    var buffer: [max_app_id_len + 1]u8 = undefined;

    const result = extractFlatpakAppId(
        "flatpak+https://flathub.org/apps/details/org.example.App",
        &buffer,
    );

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(
        "org.example.App",
        result.?,
    );
}

test "strip flatpakref suffix" {
    var buffer: [max_app_id_len + 1]u8 = undefined;

    const result = extractFlatpakAppId(
        "flatpak+https://dl.flathub.org/repo/appstream/org.example.App.flatpakref",
        &buffer,
    );

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(
        "org.example.App",
        result.?,
    );
}

test "reject invalid deep links" {
    var buffer: [max_app_id_len + 1]u8 = undefined;

    try std.testing.expect(
        extractFlatpakAppId("appstream://", &buffer) == null,
    );
    try std.testing.expect(
        extractFlatpakAppId("appstream:///", &buffer) == null,
    );
    try std.testing.expect(
        extractFlatpakAppId(
            "appstream://org.example.App/other",
            &buffer,
        ) == null,
    );
    try std.testing.expect(
        extractFlatpakAppId(
            "flatpak+https://flathub.org/",
            &buffer,
        ) == null,
    );
    try std.testing.expect(
        extractFlatpakAppId(
            "https://flathub.org/apps/org.example.App",
            &buffer,
        ) == null,
    );
}

test "reject overlong application ID" {
    var buffer: [max_app_id_len + 1]u8 = undefined;
    var uri_buffer: [appstream_prefix.len + max_app_id_len + 2]u8 =
        undefined;

    @memcpy(
        uri_buffer[0..appstream_prefix.len],
        appstream_prefix,
    );
    @memset(
        uri_buffer[appstream_prefix.len..],
        'a',
    );

    try std.testing.expect(
        extractFlatpakAppId(&uri_buffer, &buffer) == null,
    );
}

test "extract local flatpak file path" {
    var buffer: [max_file_path_len + 1]u8 = undefined;

    const ref = extractLocalFlatpakFile(
        "/home/user/Downloads/org.example.App.flatpakref",
        &buffer,
    );
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings(
        "/home/user/Downloads/org.example.App.flatpakref",
        ref.?,
    );

    const bundle = extractLocalFlatpakFile("/tmp/org.example.App.flatpak", &buffer);
    try std.testing.expect(bundle != null);
    try std.testing.expectEqualStrings("/tmp/org.example.App.flatpak", bundle.?);
}

test "extract local flatpak file from percent-encoded file URI" {
    var buffer: [max_file_path_len + 1]u8 = undefined;
    const result = extractLocalFlatpakFile(
        "file:///home/user/My%20Apps/org.example.App.flatpakref",
        &buffer,
    );
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(
        "/home/user/My Apps/org.example.App.flatpakref",
        result.?,
    );
}

test "reject unsupported local file arguments" {
    var buffer: [max_file_path_len + 1]u8 = undefined;

    try std.testing.expect(extractLocalFlatpakFile("/home/user/notes.txt", &buffer) == null);
    try std.testing.expect(extractLocalFlatpakFile("file:///home/user/notes.txt", &buffer) == null);
    try std.testing.expect(extractLocalFlatpakFile("https://flathub.org/apps/org.example.App", &buffer) == null);
    try std.testing.expect(extractLocalFlatpakFile("appstream://org.example.App", &buffer) == null);
    try std.testing.expect(extractLocalFlatpakFile("file://", &buffer) == null);
    try std.testing.expect(extractLocalFlatpakFile("file://server/share/org.example.App.flatpakref", &buffer) == null);
}
