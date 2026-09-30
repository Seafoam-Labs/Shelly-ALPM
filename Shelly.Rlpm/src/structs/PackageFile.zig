//! File metadata is borrowed from the package arena or the current iterator entry.
const PackageFile = @This();
name: []const u8,
/// Database file lists do not record size or mode. Unknown is distinct from zero.
size: ?u64 = null,
mode: ?u32 = null,
kind: enum { unknown, regular, directory, symlink, hardlink, other } = .unknown,
link_target: ?[]const u8 = null,
