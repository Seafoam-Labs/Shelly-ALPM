//! Private process modes shared by Shelly and explicit library hosts.
const std = @import("std");
const download_worker = @import("download_worker");
const action_worker = @import("action_worker");

pub const self_executable = "/proc/self/exe";
pub const download_argument = "--internal-download-worker";
pub const action_argument = "--internal-rlpm-action-worker";

/// Call before application setup. A returned status must terminate the process;
/// null means the arguments belong to the application. Worker streams are private
/// protocols and must never pass through normal CLI output or error formatting.
pub fn dispatch(init: std.process.Init, arguments: []const []const u8) ?u8 {
    if (arguments.len == 0) return null;
    const download = std.mem.eql(u8, arguments[0], download_argument);
    const action = std.mem.eql(u8, arguments[0], action_argument);
    if (!download and !action) return null;
    if (arguments.len != 1) return 2;
    if (download) {
        download_worker.run(init) catch return 1;
        return 0;
    }
    action_worker.run(init);
}
