//! Bootstrap inputs are selected by compiled availability, not runtime preference.
//! These are baseline tools; recipe dependencies may add pacman or libalpm
//! regardless of the backend compiled into Shelly.
const selection = @import("backend.zig");

pub const rlpm_only = !selection.libalpm_enabled;
pub const packages: []const []const u8 = if (rlpm_only) &.{
    // Base userspace and the existing bootstrap finalizers.
    "filesystem",
    "glibc",
    "gcc-libs",
    "bash",
    "coreutils",
    "diffutils",
    "file",
    "findutils",
    "gawk",
    "grep",
    "procps-ng",
    "sed",
    "tar",
    "gettext",
    "pciutils",
    "psmisc",
    "shadow",
    "util-linux",
    "bzip2",
    "gzip",
    "xz",
    "licenses",
    "systemd",
    "systemd-sysvcompat",
    "iputils",
    "iproute2",
    // Build tools normally supplied by base-devel, without its pacman dependency.
    "autoconf",
    "automake",
    "binutils",
    "bison",
    "debugedit",
    "fakeroot",
    "flex",
    "gcc",
    "groff",
    "libtool",
    "m4",
    "make",
    "patch",
    "pkgconf",
    "sudo",
    "texinfo",
    "which",
    // Guest CLI and source acquisition. Package trust is copied by
    // bootstrap; archlinux-keyring itself depends on pacman and is not a target.
    "git",
    "ca-certificates",
    "gnupg",
    "libarchive",
    "curl",
    "sqlite",
    "zstd",
} else &.{ "base", "base-devel", "git", "ca-certificates" };
