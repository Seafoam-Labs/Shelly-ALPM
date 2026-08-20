const std = @import("std");

const Role = enum { runtime, build, check };

const BuildNode = struct {
    package_base: []const u8,
    commit: []const u8,
};
