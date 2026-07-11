pub const cli = @import("cli.zig");
pub const keyring = @import("keyring.zig");

test {
    _ = @import("cli.zig");
    _ = @import("keyring.zig");
}