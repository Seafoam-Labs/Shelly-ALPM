//! Post-upgrade service restart policy, shared by configuration parsing and
//! the restart report contract without creating an import cycle.

const std = @import("std");

pub const ParseError = error{InvalidRestartPolicy};

/// How the package manager treats services left running against replaced
/// libraries after a successful transaction. `automatic` is the default;
/// `report` lists affected services without restarting them.
pub const RestartPolicy = enum {
    /// Report every affected service and leave restarts to the caller.
    report,
    /// Restart affected services that are safe to restart. Session-critical
    /// units are reported instead and inactive units are never started.
    automatic,

    pub fn parse(value: []const u8) ParseError!RestartPolicy {
        if (std.ascii.eqlIgnoreCase(value, "report")) return .report;
        if (std.ascii.eqlIgnoreCase(value, "automatic")) return .automatic;
        return error.InvalidRestartPolicy;
    }

    pub fn name(self: RestartPolicy) []const u8 {
        return switch (self) {
            .report => "report",
            .automatic => "automatic",
        };
    }
};

test "restart policy parses only its documented values" {
    const testing = std.testing;
    try testing.expectEqual(RestartPolicy.report, try RestartPolicy.parse("report"));
    try testing.expectEqual(RestartPolicy.automatic, try RestartPolicy.parse("AUTOMATIC"));
    try testing.expectError(error.InvalidRestartPolicy, RestartPolicy.parse("prompt"));
    try testing.expectEqualStrings("report", RestartPolicy.report.name());
}
