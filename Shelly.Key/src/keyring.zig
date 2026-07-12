const std = @import("std");
const Io = std.Io;

const keydir = @import("keydir.zig");

pub const KeyringError = keydir.KeydirError;

pub fn init(io: Io, keyring_path: []const u8) KeyringError!void {
    try keydir.createKeyringDir(.cwd(), io, keyring_path);
}
