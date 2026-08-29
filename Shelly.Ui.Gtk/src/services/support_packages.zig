const std = @import("std");
const options = @import("options");

pub const Feature = enum {
    flatpak,
    appimage,
};

const flatpak_dependencies = [_][]const u8{"flatpak"};
const appimage_dependencies = [_][]const u8{"fuse2"};

pub fn dependenciesForFeature(feature: Feature) []const []const u8 {
    return switch (feature) {
        .flatpak => &flatpak_dependencies,
        .appimage => &appimage_dependencies,
    };
}

pub fn flatpakBackendPackage() []const u8 {
    return options.flatpak_backend_package;
}

pub fn selectedDependencies(
    buffer: *[2][]const u8,
    flatpak: bool,
    appimage: bool,
) []const []const u8 {
    var len: usize = 0;
    if (flatpak) {
        for (flatpak_dependencies) |package| {
            buffer[len] = package;
            len += 1;
        }
    }
    if (appimage) {
        for (appimage_dependencies) |package| {
            buffer[len] = package;
            len += 1;
        }
    }
    return buffer[0..len];
}

/// Returns the subset of `selectedDependencies` whose names are absent from
/// `installed_names`, so the caller can skip a redundant reinstall.
pub fn uninstalledDependencies(
    buffer: *[2][]const u8,
    flatpak: bool,
    appimage: bool,
    installed_names: []const []const u8,
) []const []const u8 {
    const candidates: [2][]const []const u8 = .{
        if (flatpak) &flatpak_dependencies else &.{},
        if (appimage) &appimage_dependencies else &.{},
    };
    var len: usize = 0;
    for (candidates) |list| {
        for (list) |pkg| {
            const already = for (installed_names) |n| {
                if (std.mem.eql(u8, n, pkg)) break true;
            } else false;
            if (!already) {
                buffer[len] = pkg;
                len += 1;
            }
        }
    }
    return buffer[0..len];
}

test "selected support dependencies combine Flatpak and AppImage requirements" {
    var buffer: [2][]const u8 = undefined;
    const packages = selectedDependencies(&buffer, true, true);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "flatpak", "fuse2" },
        packages,
    );
}

test "selected support dependencies include only requested features" {
    var buffer: [2][]const u8 = undefined;

    try std.testing.expectEqualSlices(
        []const u8,
        &.{"flatpak"},
        selectedDependencies(&buffer, true, false),
    );
    try std.testing.expectEqualSlices(
        []const u8,
        &.{"fuse2"},
        selectedDependencies(&buffer, false, true),
    );
    try std.testing.expectEqual(@as(usize, 0), selectedDependencies(&buffer, false, false).len);
}

test "uninstalled dependencies excludes packages already present" {
    var buffer: [2][]const u8 = undefined;

    // flatpak already installed → only fuse2 remains
    try std.testing.expectEqualSlices(
        []const u8,
        &.{"fuse2"},
        uninstalledDependencies(&buffer, true, true, &.{"flatpak"}),
    );

    // both already installed → nothing to install
    try std.testing.expectEqual(
        @as(usize, 0),
        uninstalledDependencies(&buffer, true, true, &.{ "flatpak", "fuse2" }).len,
    );

    // nothing installed → full list returned
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "flatpak", "fuse2" },
        uninstalledDependencies(&buffer, true, true, &.{}),
    );
}

test "Flatpak backend remains a separate configured package" {
    try std.testing.expectEqualStrings(
        options.flatpak_backend_package,
        flatpakBackendPackage(),
    );
}
