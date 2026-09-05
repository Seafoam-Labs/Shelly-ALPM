const std = @import("std");

pub const max_app_id_len = 255;

const appstream_prefix = "appstream://";
const flatpak_https_prefix= "flatpak+https://";
const flatpak_ref_suffix = ".flatpakref";

pub const PageTarget = enum {
    flatpak_install,
    flatpak_remove, 
    updates,    
};

pub fn extractFlatpakAppId(
    arg: []const u8,
    buffer: *[max_app_id_len + 1]u8,
) ?[:0]const u8 {
    var app_id: []const u8 = undefined;

    if (std.mem.startsWith(u8, arg, appstream_prefix)) {
        var remainder = stripQueryAndFragment(arg[appstream_prefix.len..]);

        remainder = std.mem.trimLeft(u8, remainder, "/");

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

    @memcpy(buffer[0..app_id.len], app_id);
    buffer[app_id.len] = 0;

    return buffer[0..app_id.len :0];
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
