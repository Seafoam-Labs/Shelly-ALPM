//! Shared bounded queue; keeps the existing PackageManager import path.
const queue = @import("Shelly_Download").Queue;
pub const default_limit = queue.default_limit;
pub const normalizeLimit = queue.normalizeLimit;
pub const run = queue.run;
