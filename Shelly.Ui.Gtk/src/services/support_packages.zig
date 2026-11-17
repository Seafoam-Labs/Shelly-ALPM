const std = @import("std");
const features = @import("build_features.zig");
const ShellyCli = @import("shelly_cli.zig").ShellyCli;

pub const Feature = enum {
    flatpak,
    appimage,
    fwupd,
};

const flatpak_dependencies = [_][]const u8{"flatpak"};
const appimage_dependencies = [_][]const u8{"fuse2"};
const fwupd_dependencies = [_][]const u8{"fwupd"};

pub fn dependenciesForFeature(feature: Feature) []const []const u8 {
    return switch (feature) {
        .flatpak => &flatpak_dependencies,
        .appimage => &appimage_dependencies,
        .fwupd => &fwupd_dependencies,
    };
}

pub fn flatpakBackendPackage() []const u8 {
    return features.flatpak_backend_package;
}

pub fn selectedDependencies(
    buffer: *[3][]const u8,
    flatpak: bool,
    appimage: bool,
    fwupd: bool,
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
    if (fwupd) {
        for (fwupd_dependencies) |package| {
            buffer[len] = package;
            len += 1;
        }
    }
    return buffer[0..len];
}

pub fn missingPackages(
    alloc: std.mem.Allocator,
    io: std.Io,
    packages: []const []const u8,
    buffer: [][]const u8,
) []const []const u8 {
    const cli = ShellyCli{ .allocator = alloc, .io = io };
    var len: usize = 0;
    for (packages) |package| {
        if (len == buffer.len) break;
        if (cli.isPackageInstalled(package) catch false) continue;
        buffer[len] = package;
        len += 1;
    }
    return buffer[0..len];
}

test "selected support dependencies combine Flatpak, AppImage and Firmware requirements" {
    var buffer: [3][]const u8 = undefined;
    const packages = selectedDependencies(&buffer, true, true, true);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "flatpak", "fuse2", "fwupd" },
        packages,
    );
}

test "selected support dependencies include only requested features" {
    var buffer: [3][]const u8 = undefined;

    try std.testing.expectEqualSlices(
        []const u8,
        &.{"flatpak"},
        selectedDependencies(&buffer, true, false, false),
    );
    try std.testing.expectEqualSlices(
        []const u8,
        &.{"fuse2"},
        selectedDependencies(&buffer, false, true, false),
    );
    try std.testing.expectEqualSlices(
        []const u8,
        &.{"fwupd"},
        selectedDependencies(&buffer, false, false, true),
    );
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "flatpak", "fwupd" },
        selectedDependencies(&buffer, true, false, true),
    );
    try std.testing.expectEqual(@as(usize, 0), selectedDependencies(&buffer, false, false, false).len);
}

test "Flatpak backend remains a separate configured package" {
    try std.testing.expectEqualStrings(
        features.flatpak_backend_package,
        flatpakBackendPackage(),
    );
}
