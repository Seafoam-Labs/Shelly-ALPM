//! Private versioned protocol, shared only by the matching native Zig worker.
//! stdin: u32-le JSON size, JSON, then unframed action stdin. stderr: 8-byte
//! setup reports (stage, fatal, reserved, reserved, i32-le errno), closed on exec.
const std = @import("std");

pub const Network = enum { required, best_effort, allowed };

pub const Request = struct {
    version: u32 = 1,
    root_descriptor: []const u8,
    chroot: bool,
    command: []const u8,
    argv: []const []const u8,
    network: Network,
};

pub const Stage = enum(u8) { protocol = 1, root, network, environment, descriptors, execute };

pub const Failure = struct {
    stage: Stage,
    errno: i32,
};

pub const Result = struct {
    term: std.process.Child.Term,
    setup_failure: ?Failure = null,
    network_warning: ?i32 = null,

    pub fn success(self: Result) bool {
        return self.setup_failure == null and self.term == .exited and self.term.exited == 0;
    }
};
pub const maximum_request = 1024 * 1024;
pub const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/ioctl.h");
    @cInclude("net/if.h");
    @cInclude("sched.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("poll.h");
    @cInclude("errno.h");
});
