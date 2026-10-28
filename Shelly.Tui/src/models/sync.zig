const std = @import("std");

pub const CheckUpdates = struct {
    Packages: []CheckUpdatesPackage = &.{},
    Aur: []CheckUpdatesAur = &.{},
    Flatpak: []CheckUpdatesFlatpak = &.{},

    pub fn count(self: *const CheckUpdates) usize {
        return self.Packages.len + self.Aur.len + self.Flatpak.len;
    }
};

pub const CheckUpdatesPackage = struct {
    Name: []const u8 = "",
    CurrentVersion: []const u8 = "",
    NewVersion: []const u8 = "",
    DownloadSize: i64 = 0,
    SizeDifference: i64 = 0,
    Description: []const u8 = "",
    Url: []const u8 = "",
    Repository: []const u8 = "",
    InstalledSize: i64 = 0,
    Depends: []const []const u8 = &.{},
    OptDepends: []const []const u8 = &.{},
    Licenses: []const []const u8 = &.{},
    Provides: []const []const u8 = &.{},
    Conflicts: []const []const u8 = &.{},
    Groups: []const []const u8 = &.{},
};

pub const CheckUpdatesAur = struct {
    Name: []const u8 = "",
    Version: []const u8 = "",
    NewVersion: []const u8 = "",
    DownloadSize: i64 = 0,
    Url: []const u8 = "",
    PackageBase: []const u8 = "",
    Description: []const u8 = "",
};

pub const CheckUpdatesFlatpak = struct {
    Id: []const u8 = "",
    Name: []const u8 = "",
    Version: []const u8 = "",
    Arch: []const u8 = "",
    Branch: []const u8 = "",
    LatestCommit: []const u8 = "",
    Summary: []const u8 = "",
    Kind: i32 = 0,
    Remote: []const u8 = "",
    InstallLevel: i32 = 0,
    Permissions: []const []const u8 = &.{},
    InstalledSize: u64 = 0,
    Ref: []const u8 = "",
    FullRef: []const u8 = "",
};
