//! Backend availability is fixed by the build; a manager captures its choice.
const std = @import("std");
pub const libalpm_enabled = @import("package_options").libalpm;
pub const Backend = enum(u8) {
    libalpm,
    rlpm,

    pub fn available(self: Backend) bool {
        return self == .rlpm or libalpm_enabled;
    }
    pub fn parse(value: []const u8) error{InvalidBackend}!Backend {
        inline for (std.meta.fields(Backend)) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, value)) return @enumFromInt(field.value);
        }
        return error.InvalidBackend;
    }
    pub fn validate(self: Backend) error{BackendUnavailable}!void {
        if (!self.available()) return error.BackendUnavailable;
    }
};
pub const default_backend: Backend = if (libalpm_enabled) .libalpm else .rlpm;
var process_default = std.atomic.Value(Backend).init(default_backend);
pub fn selectedDefault() Backend {
    return process_default.load(.acquire);
}
pub fn setDefault(value: Backend) error{BackendUnavailable}!void {
    try value.validate();
    process_default.store(value, .release);
}
test "backend defaults and explicit availability follow the build" {
    try std.testing.expect(Backend.rlpm.available());
    try std.testing.expectEqual(libalpm_enabled, Backend.libalpm.available());
    try std.testing.expectEqual(Backend.rlpm, try Backend.parse("rlpm"));
    try std.testing.expectError(error.InvalidBackend, Backend.parse("automatic"));
    if (!libalpm_enabled) try std.testing.expectError(error.BackendUnavailable, Backend.libalpm.validate());
}
