const SignaturePolicy = @This();
const std = @import("std");

pub const Verification = enum {
    disabled,
    optional,
    required,
};

package: Verification = .required,
database: Verification = .required,

test "SignaturePolicy requires package and database signatures by default" {
    const policy: SignaturePolicy = .{};

    try std.testing.expectEqual(Verification.required, policy.package);
    try std.testing.expectEqual(Verification.required, policy.database);
}

test "SignaturePolicy configures package and database verification separately" {
    const policy: SignaturePolicy = .{
        .package = .optional,
        .database = .disabled,
    };

    try std.testing.expectEqual(Verification.optional, policy.package);
    try std.testing.expectEqual(Verification.disabled, policy.database);
}
