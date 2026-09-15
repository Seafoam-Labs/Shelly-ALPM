const DatabaseConfiguration = @This();

const std = @import("std");
const SignaturePolicy = @import("SignaturePolicy.zig");

database_name: []u8,
signature_policy: SignaturePolicy
