const std = @import("std");
const PackageManager = @import("PackageManager");

// Distribution policy is independent of the selected native package backend.
pub const arch_news_enabled = !std.mem.eql(u8, PackageManager.paths.profile, "devario");
pub const arch_news_unavailable = "Arch Linux news is unavailable in Devario builds.";
