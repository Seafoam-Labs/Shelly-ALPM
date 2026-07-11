pub const cli = @import("cli.zig");
pub const keyring = @import("keyring.zig");
pub const elevate = @import("elevate.zig");

test {
    _ = @import("cli.zig");
    _ = @import("keyring.zig");
    _ = @import("elevate.zig");
}
