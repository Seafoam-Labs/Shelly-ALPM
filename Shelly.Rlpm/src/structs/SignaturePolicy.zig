const SignaturePolicy = @This();

pub const Verification = enum {
    disabled,
    optional,
    required,
};

package: Verification = .required,
database: Verification = .required,
