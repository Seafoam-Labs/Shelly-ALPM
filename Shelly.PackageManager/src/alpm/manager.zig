const std = @import("std");
const bindings = @import("bindings.zig");
const events = @import("events.zig");

const libalpm = bindings.libalpm; // typed aliases (Handle, Database, Config, ...)
const rawLibalpm = bindings.libalpm.alpm;

threadlocal var active_manager: ?*Manager = null;

pub const ConfigError = error{
    InitFailed,
    RegisterDbFailed,
};

pub const Manager = struct {
    handle: libalpm.Handle = null,
    is_initialized: bool = false,
    is_cachyos: bool = false,
    allocator: std.mem.Allocator,

    // Holds subscribers
    dispatcher: events.Dispatcher,
    /// Initialize libalpm and apply `config`.
    ///
    /// `root_dir` and `db_dir` are the only values required by
    /// `alpm_initialize`; both fall back to the standard system locations when
    /// left null. Everything else in `config` is applied afterwards through the
    /// `alpm_option_*` setters.
    pub fn init(allocator: std.mem.Allocator, config: libalpm.Config) ConfigError!Manager {
        const root = if (config.root_dir) |r| r.ptr else "/";
        const dbpath = if (config.db_dir) |d| d.ptr else "/var/lib/pacman/";

        var err: rawLibalpm.alpm_errno_t = 0;
        const handle = rawLibalpm.alpm_initialize(root, dbpath, &err) orelse {
            std.log.err("alpm_initialize failed: {s}", .{std.mem.span(rawLibalpm.alpm_strerror(err))});
            return error.InitFailed;
        };
        var self = Manager{
            .handle = handle,
            .is_initialized = true,
            .allocator = allocator,
            .dispatcher = events.Dispatcher.init(allocator),
        };
        self.applyConfig(config);
        return self;
    }

    pub fn deinit(self: *Manager) void {
        // NOTE: `self.dispatcher.deinit()` is intentionally not called yet:
        // events.zig still uses the pre-0.16 managed ArrayList API (append/deinit
        // without an allocator) and won't compile until updated.
        if (self.handle) |h| _ = libalpm.alpm.alpm_release(h);
        self.handle = null;
        self.is_initialized = false;
    }

    /// Apply the optional settings from `config` to the live handle. Option
    /// setter failures are logged but non-fatal; the resulting `alpm_errno` is
    /// reported for context.
    fn applyConfig(self: *Manager, config: libalpm.Config) void {
        const h = self.handle;

        // cachedir is a *list* in libalpm — use add, not set.
        if (config.cache_dir) |v| self.check("cachedir", rawLibalpm.alpm_option_add_cachedir(h, v.ptr));
        if (config.log_file) |v| self.check("logfile", rawLibalpm.alpm_option_set_logfile(h, v.ptr));
        if (config.gpg_dir) |v| self.check("gpgdir", rawLibalpm.alpm_option_set_gpgdir(h, v.ptr));
        if (config.Architecture) |v| self.check("architecture", rawLibalpm.alpm_option_add_architecture(h, v.ptr));

        self.check("check_space", rawLibalpm.alpm_option_set_check_space(h, @intFromBool(config.CheckSpace)));

        if (config.IgnorePkg) |v| self.check("ignorepkg", rawLibalpm.alpm_option_add_ignorepkg(h, v.ptr));
        if (config.IgnoreGroup) |v| self.check("ignoregroup", rawLibalpm.alpm_option_add_ignoregroup(h, v.ptr));

        // SigLevel is a bitmask (alpm_siglevel_t), not a string. Start from the
        // library default; parsing config.SigLevel into flags is a follow-up.
        self.check("default_siglevel", rawLibalpm.alpm_option_set_default_siglevel(h, rawLibalpm.ALPM_SIG_USE_DEFAULT));
    }

    fn check(self: *Manager, what: []const u8, ret: c_int) void {
        if (ret != 0) {
            std.log.warn("alpm option '{s}' failed: {s}", .{
                what,
                std.mem.span(rawLibalpm.alpm_strerror(rawLibalpm.alpm_errno(self.handle))),
            });
        }
    }

    /// Register a sync database (e.g. "core", "extra") and attach its servers.
    pub fn registerSyncDb(
        self: *Manager,
        name: [:0]const u8,
        servers: []const [:0]const u8,
    ) ConfigError!libalpm.Database {
        const db = rawLibalpm.alpm_register_syncdb(self.handle, name.ptr, rawLibalpm.ALPM_SIG_USE_DEFAULT) orelse {
            std.log.err("alpm_register_syncdb('{s}') failed: {s}", .{
                name,
                std.mem.span(rawLibalpm.alpm_strerror(rawLibalpm.alpm_errno(self.handle))),
            });
            return error.RegisterDbFailed;
        };
        for (servers) |url| {
            self.check("db_add_server", rawLibalpm.alpm_db_add_server(db, url.ptr));
        }
        return db;
    }
};

test "hi" {
    try std.testing.expectEqualStrings("test", "test");
}
