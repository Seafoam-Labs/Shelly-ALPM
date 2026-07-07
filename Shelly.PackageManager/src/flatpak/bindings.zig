const std = @import("std");

pub const libflatpak = struct {
    pub const flatpak = @import("flatpak");

    pub fn str(ptr: [*c]const u8) ?[:0]const u8 {
        if (ptr == null) return null;
        return std.mem.span(ptr);
    }

    pub const Scope = enum(i32) { SYSTEM = 0, USER = 1, UNKNOWN = 2 };

    pub const Remote = struct {
        ptr: *flatpak.FlatpakRemote,
        scope: Scope,

        pub fn new(ptr: *flatpak.FlatpakRemote, scope: Scope) Remote {
            return .{ .ptr = ptr, .scope = scope };
        }

        pub fn name(self: Remote) ?[:0]const u8 {
            return str(flatpak.flatpak_remote_get_name(self.ptr));
        }

        pub fn priority(self: Remote) i32 {
            return flatpak.flatpak_remote_get_prio(self.ptr);
        }

        pub fn set_priority(self: Remote, prio: i32) void {
            flatpak.flatpak_remote_set_prio(self.ptr, prio);
        }

        pub fn url(self: Remote) ?[:0]const u8 {
            return str(flatpak.flatpak_remote_get_url(self.ptr));
        }

        pub fn set_url(self: Remote, url_str: [:0]const u8) void {
            flatpak.flatpak_remote_set_url(self.ptr, url_str.ptr);
        }

        pub fn get_scope(self: Remote) Scope {
            return self.scope;
        }

        pub fn gpg_verify(self: Remote) bool {
            return flatpak.flatpak_remote_get_gpg_verify(self.ptr) != 0;
        }

        pub fn nodeps(self: Remote) bool {
            return flatpak.flatpak_remote_get_nodeps(self.ptr) != 0;
        }

        pub fn noenumerate(self: Remote) bool {
            return flatpak.flatpak_remote_get_noenumerate(self.ptr) != 0;
        }

        pub fn remote_type(self: Remote) flatpak.FlatpakRemoteType {
            return flatpak.flatpak_remote_get_remote_type(self.ptr);
        }

        pub fn disabled(self: Remote) bool {
            return flatpak.flatpak_remote_get_disabled(self.ptr) != 0;
        }

        pub fn appstream_dir(self: Remote, arch: ?[:0]const u8) ?*flatpak.GFile {
            return flatpak.flatpak_remote_get_appstream_dir(self.ptr, if (arch) |a| a.ptr else null);
        }

        pub fn appstream_timestamp(self: Remote, arch: ?[:0]const u8) ?*flatpak.GFile {
            return flatpak.flatpak_remote_get_appstream_timestamp(self.ptr, if (arch) |a| a.ptr else null);
        }
    };

    pub const Flatpak = struct {
        ptr: *flatpak.FlatpakRef,
        scope: Scope,

        pub fn new(ptr: *flatpak.FlatpakRef, scope: Scope) Flatpak {
            return .{ .ptr = ptr, .scope = scope };
        }

        pub fn id(self: Flatpak) ?[:0]const u8 {
            return str(flatpak.flatpak_ref_get_name(self.ptr));
        }

        pub fn arch(self: Flatpak) ?[:0]const u8 {
            return str(flatpak.flatpak_ref_get_arch(self.ptr));
        }

        pub fn branch(self: Flatpak) ?[:0]const u8 {
            return str(flatpak.flatpak_ref_get_branch(self.ptr));
        }

        pub fn kind(self: Flatpak) i32 {
            return flatpak.flatpak_ref_get_kind(self.ptr);
        }

        pub fn get_scope(self: Flatpak) Scope {
            return self.scope;
        }
    };

    pub const RepoConfig = struct {
        url: ?[:0]const u8 = null,
        gpg_verify: ?bool = null,
        gpg_key: ?[:0]const u8 = null,
    };

    pub const RemoteRef = struct {
        ptr: *flatpak.FlatpakRemoteRef,
        scope: Scope,
        permissions: []const [:0]const u8 = &.{},

        pub fn new(ptr: *flatpak.FlatpakRemoteRef, scope: Scope, permissions: []const [:0]const u8) RemoteRef {
            return .{ .ptr = ptr, .scope = scope, .permissions = permissions };
        }

        pub fn remote_name(self: RemoteRef) ?[:0]const u8 {
            return str(flatpak.flatpak_remote_ref_get_remote_name(self.ptr));
        }

        pub fn installed_size(self: RemoteRef) u64 {
            return flatpak.flatpak_remote_ref_get_installed_size(self.ptr);
        }

        pub fn download_size(self: RemoteRef) u64 {
            return flatpak.flatpak_remote_ref_get_download_size(self.ptr);
        }

        pub fn metadata(self: RemoteRef) ?*flatpak.GBytes {
            return flatpak.flatpak_remote_ref_get_metadata(self.ptr);
        }

        pub fn eol(self: RemoteRef) ?[:0]const u8 {
            return str(flatpak.flatpak_remote_ref_get_eol(self.ptr));
        }

        pub fn eol_rebase(self: RemoteRef) ?[:0]const u8 {
            return str(flatpak.flatpak_remote_ref_get_eol_rebase(self.ptr));
        }

        pub fn get_scope(self: RemoteRef) Scope {
            return self.scope;
        }

        pub fn deinitPermissions(self: RemoteRef, allocator: std.mem.Allocator) void {
            for (self.permissions) |p| allocator.free(p);
            allocator.free(self.permissions);
        }
    };

    pub const InstalledFlatpak = struct {
        ptr: *flatpak.FlatpakRef,
        scope: Scope,
        permissions: []const [:0]const u8 = &.{},

        pub fn new(ptr: *flatpak.FlatpakRef, scope: Scope) InstalledFlatpak {
            return .{ .ptr = ptr, .scope = scope };
        }

        pub fn id(self: InstalledFlatpak) [:0]const u8 {
            return str(flatpak.flatpak_ref_get_name(self.ptr)) orelse "";
        }

        pub fn arch(self: InstalledFlatpak) [:0]const u8 {
            return str(flatpak.flatpak_ref_get_arch(self.ptr)) orelse "";
        }

        pub fn branch(self: InstalledFlatpak) [:0]const u8 {
            return str(flatpak.flatpak_ref_get_branch(self.ptr)) orelse "";
        }

        pub fn name(self: InstalledFlatpak) [:0]const u8 {
            const n = str(flatpak.flatpak_installed_ref_get_appdata_name(self.ptr)) orelse "";
            return if (n.len > 0) n else self.id();
        }

        pub fn summary(self: InstalledFlatpak) [:0]const u8 {
            return str(flatpak.flatpak_installed_ref_get_appdata_summary(self.ptr)) orelse "";
        }

        pub fn last_commit(self: InstalledFlatpak) [:0]const u8 {
            return str(flatpak.flatpak_installed_ref_get_latest_commit(self.ptr)) orelse "";
        }

        pub fn version(self: InstalledFlatpak) [:0]const u8 {
            const v = str(flatpak.flatpak_installed_ref_get_appdata_version(self.ptr)) orelse "";
            return if (v.len > 0) v else self.branch();
        }

        pub fn origin(self: InstalledFlatpak) [:0]const u8 {
            return str(flatpak.flatpak_installed_ref_get_origin(self.ptr)) orelse "";
        }

        pub fn installed_size(self: InstalledFlatpak) u64 {
            return flatpak.flatpak_installed_ref_get_installed_size(self.ptr);
        }

        pub fn kind(self: InstalledFlatpak) i32 {
            return flatpak.flatpak_ref_get_kind(self.ptr);
        }

        pub fn get_scope(self: InstalledFlatpak) Scope {
            return self.scope;
        }

        pub fn deinitPermissions(self: RemoteRef, allocator: std.mem.Allocator) void {
            for (self.permissions) |p| allocator.free(p);
            allocator.free(self.permissions);
        }
    };

    pub fn refToString(allocator: std.mem.Allocator, raw: *flatpak.FlatpakRef) ![:0]u8 {
        const kind = flatpak.flatpak_ref_get_kind(raw);
        const kind_string: []const u8 = if (kind == flatpak.FLATPAK_REF_KIND_APP) "app" else "runtime";

        const ref_str = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}/{s}",
            .{
                kind_string,
                flatpak.flatpak_ref_get_name(raw),
                flatpak.flatpak_ref_get_arch(raw),
                flatpak.flatpak_ref_get_branch(raw),
            },
        );
        defer allocator.free(ref_str);

        return allocator.dupeSentinel(u8, ref_str, 0);
    }
};
