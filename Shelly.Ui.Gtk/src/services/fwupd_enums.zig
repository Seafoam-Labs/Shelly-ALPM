//! fwupd wire enums and flag bits, transcribed from the installed fwupd 2.1.10 headers:
//!   /usr/include/fwupd-3/libfwupd/fwupd-enums-struct.h   (Status, FeatureFlags, UpdateState, VersionFormat)
//!   /usr/include/fwupd-3/libfwupd/fwupd-enums.h          (FWUPD_BATTERY_LEVEL_INVALID)
//!   /usr/include/fwupd-3/libfwupd/fwupd-device-struct.h  (device flags, Problems)
//!   /usr/include/fwupd-3/libfwupd/fwupd-release-struct.h (TrustFlags, Urgency)
//!   /usr/include/fwupd-3/libfwupd/fwupd-remote-struct.h  (RemoteKind)
//!   /usr/include/fwupd-3/libfwupd/fwupd-request-struct.h (RequestKind, RequestFlags)
//!   /usr/include/fwupd-3/libfwupd/fwupd-error-struct.h   (22 error names)
//! Decoders map unrecognized values to `.unknown` instead of casting blindly; bits
//! removed in fwupd 2.x are not listed.

const std = @import("std");

/// Sentinel for "battery level not reported" (FWUPD_BATTERY_LEVEL_INVALID).
pub const battery_level_invalid: u32 = 101;

/// FwupdStatus: daemon `Status` property (wire type u).
pub const Status = enum {
    unknown,
    idle,
    loading,
    decompressing,
    device_restart,
    device_write,
    device_verify,
    scheduling,
    downloading,
    device_read,
    device_erase,
    waiting_for_auth,
    device_busy,
    shutdown,
    waiting_for_user,

    pub fn decode(raw: u32) Status {
        return switch (raw) {
            0 => .unknown,
            1 => .idle,
            2 => .loading,
            3 => .decompressing,
            4 => .device_restart,
            5 => .device_write,
            6 => .device_verify,
            7 => .scheduling,
            8 => .downloading,
            9 => .device_read,
            10 => .device_erase,
            11 => .waiting_for_auth,
            12 => .device_busy,
            13 => .shutdown,
            14 => .waiting_for_user,
            else => .unknown,
        };
    }
};

/// FwupdFeatureFlags: advertised via SetFeatureFlags before any device scan.
pub const FeatureFlags = struct {
    pub const can_report: u64 = 1 << 0;
    pub const detach_action: u64 = 1 << 1;
    pub const update_action: u64 = 1 << 2;
    pub const switch_branch: u64 = 1 << 3;
    pub const requests: u64 = 1 << 4;
    pub const fde_warning: u64 = 1 << 5;
    pub const community_text: u64 = 1 << 6;
    pub const show_problems: u64 = 1 << 7;
    pub const allow_authentication: u64 = 1 << 8;
    pub const requests_non_generic: u64 = 1 << 9;

    /// Capabilities advertised by this client; ALLOW_AUTHENTICATION is omitted
    /// until a remote-credential UI exists.
    pub const client: u64 = update_action | switch_branch | requests | fde_warning |
        show_problems | requests_non_generic;

    pub fn has(flags: u64, bit: u64) bool {
        return flags & bit != 0;
    }
};

/// FwupdDeviceFlags: device `Flags` key (wire type t). Kept as raw u64 + named bits.
/// Only bits present in 2.x are listed; gaps are removed/reserved values.
pub const DeviceFlags = struct {
    pub const internal: u64 = 1 << 0;
    pub const updatable: u64 = 1 << 1;
    pub const require_ac: u64 = 1 << 3;
    pub const locked: u64 = 1 << 4;
    pub const supported: u64 = 1 << 5;
    pub const needs_bootloader: u64 = 1 << 6;
    pub const needs_reboot: u64 = 1 << 8;
    pub const reported: u64 = 1 << 9;
    pub const notified: u64 = 1 << 10;
    pub const is_bootloader: u64 = 1 << 13;
    pub const wait_for_replug: u64 = 1 << 14;
    pub const needs_shutdown: u64 = 1 << 17;
    pub const another_write_required: u64 = 1 << 18;
    pub const needs_activation: u64 = 1 << 20;
    pub const historical: u64 = 1 << 22;
    pub const will_disappear: u64 = 1 << 24;
    pub const can_verify: u64 = 1 << 25;
    pub const can_verify_image: u64 = 1 << 26;
    pub const dual_image: u64 = 1 << 27;
    pub const self_recovery: u64 = 1 << 28;
    pub const usable_during_update: u64 = 1 << 29;
    pub const version_check_required: u64 = 1 << 30;
    pub const install_all_releases: u64 = 1 << 31;
    pub const updatable_hidden: u64 = 1 << 37;
    pub const has_multiple_branches: u64 = 1 << 39;
    pub const backup_before_install: u64 = 1 << 40;
    pub const wildcard_install: u64 = 1 << 42;
    pub const only_version_upgrade: u64 = 1 << 43;
    pub const @"unreachable": u64 = 1 << 44;
    pub const affects_fde: u64 = 1 << 45;
    pub const end_of_life: u64 = 1 << 46;
    pub const signed_payload: u64 = 1 << 47;
    pub const unsigned_payload: u64 = 1 << 48;
    pub const emulated: u64 = 1 << 49;
    pub const emulation_tag: u64 = 1 << 50;
    pub const only_explicit_updates: u64 = 1 << 51;
    pub const can_emulation_tag: u64 = 1 << 52;
    pub const install_skip_version_check: u64 = 1 << 53;

    pub fn has(flags: u64, bit: u64) bool {
        return flags & bit != 0;
    }

    /// Device-list filter: UPDATABLE or UPDATABLE_HIDDEN.
    pub fn isUpdatable(flags: u64) bool {
        return has(flags, updatable) or has(flags, updatable_hidden);
    }
};

/// FwupdDeviceProblem: device `Problems` key (wire type t), bit values.
pub const Problem = enum(u64) {
    system_power_too_low = 1 << 0,
    @"unreachable" = 1 << 1,
    power_too_low = 1 << 2,
    update_pending = 1 << 3,
    require_ac_power = 1 << 4,
    lid_is_closed = 1 << 5,
    is_emulated = 1 << 6,
    missing_license = 1 << 7,
    system_inhibit = 1 << 8,
    update_in_progress = 1 << 9,
    in_use = 1 << 10,
    display_required = 1 << 11,
    lower_priority = 1 << 12,
    insecure_platform = 1 << 13,
    firmware_locked = 1 << 14,

    /// FWUPD_DEVICE_PROBLEM_UNKNOWN sentinel: not a real bit.
    pub const unknown: u64 = std.math.maxInt(u64);

    pub const known_mask: u64 = blk: {
        var mask: u64 = 0;
        for (std.enums.values(Problem)) |p| mask |= @backingInt(p);
        break :blk mask;
    };
};

/// FwupdReleaseFlags: release `TrustFlags` key (wire type t).
pub const TrustFlags = struct {
    pub const trusted_payload: u64 = 1 << 0;
    pub const trusted_metadata: u64 = 1 << 1;
    pub const is_upgrade: u64 = 1 << 2;
    pub const is_downgrade: u64 = 1 << 3;
    pub const blocked_version: u64 = 1 << 4;
    pub const blocked_approval: u64 = 1 << 5;
    pub const is_alternate_branch: u64 = 1 << 6;
    pub const is_community: u64 = 1 << 7;
    pub const trusted_report: u64 = 1 << 8;
};

/// FwupdReleaseUrgency: release `Urgency` key (wire type u).
pub const Urgency = enum {
    unknown,
    low,
    medium,
    high,
    critical,

    pub fn decode(raw: u32) Urgency {
        return switch (raw) {
            0 => .unknown,
            1 => .low,
            2 => .medium,
            3 => .high,
            4 => .critical,
            else => .unknown,
        };
    }
};

/// FwupdRemoteKind: remote `Type` key (wire type u).
pub const RemoteKind = enum {
    unknown,
    download,
    local,
    directory,

    pub fn decode(raw: u32) RemoteKind {
        return switch (raw) {
            0 => .unknown,
            1 => .download,
            2 => .local,
            3 => .directory,
            else => .unknown,
        };
    }
};

/// FwupdRequestKind: request `RequestKind` key (wire type u).
pub const RequestKind = enum {
    unknown,
    post,
    immediate,

    pub fn decode(raw: u32) RequestKind {
        return switch (raw) {
            0 => .unknown,
            1 => .post,
            2 => .immediate,
            else => .unknown,
        };
    }
};

/// FwupdRequestFlags: request `Flags` key (wire type t).
pub const RequestFlags = struct {
    pub const allow_generic_message: u64 = 1 << 0;
    pub const allow_generic_image: u64 = 1 << 1;
    pub const non_generic_message: u64 = 1 << 2;
    pub const non_generic_image: u64 = 1 << 3;
};

/// FwupdUpdateState: device `UpdateState` key (wire type u).
pub const UpdateState = enum {
    unknown,
    pending,
    success,
    failed,
    needs_reboot,
    failed_transient,

    pub fn decode(raw: u32) UpdateState {
        return switch (raw) {
            0 => .unknown,
            1 => .pending,
            2 => .success,
            3 => .failed,
            4 => .needs_reboot,
            5 => .failed_transient,
            else => .unknown,
        };
    }
};

/// FwupdVersionFormat: device `VersionFormat` key (wire type u).
/// Versions are displayed as the daemon-provided string; the format is informational.
pub const VersionFormat = enum {
    unknown,
    plain,
    number,
    pair,
    triplet,
    quad,
    bcd,
    intel_me,
    intel_me2,
    surface_legacy,
    surface,
    dell_bios,
    hex,
    dell_bios_msb,
    intel_csme19,
    compal_bios,

    pub fn decode(raw: u32) VersionFormat {
        return switch (raw) {
            0 => .unknown,
            1 => .plain,
            2 => .number,
            3 => .pair,
            4 => .triplet,
            5 => .quad,
            6 => .bcd,
            7 => .intel_me,
            8 => .intel_me2,
            9 => .surface_legacy,
            10 => .surface,
            11 => .dell_bios,
            12 => .hex,
            13 => .dell_bios_msb,
            14 => .intel_csme19,
            15 => .compal_bios,
            else => .unknown,
        };
    }
};

/// FwupdError: D-Bus error names under `org.freedesktop.fwupd.`.
/// `.unknown` is a client-side fallback for unrecognized names, not a wire value.
pub const Error = enum {
    internal,
    version_newer,
    version_same,
    already_pending,
    auth_failed,
    read,
    write,
    invalid_file,
    not_found,
    nothing_to_do,
    not_supported,
    signature_invalid,
    ac_power_required,
    permission_denied,
    broken_system,
    battery_level_too_low,
    needs_user_action,
    auth_expired,
    invalid_data,
    timed_out,
    busy,
    not_reachable,
    unknown,

    /// Bare wire name (without the `org.freedesktop.fwupd.` prefix), null for the fallback.
    pub fn wireName(self: Error) ?[]const u8 {
        return switch (self) {
            .internal => "Internal",
            .version_newer => "VersionNewer",
            .version_same => "VersionSame",
            .already_pending => "AlreadyPending",
            .auth_failed => "AuthFailed",
            .read => "Read",
            .write => "Write",
            .invalid_file => "InvalidFile",
            .not_found => "NotFound",
            .nothing_to_do => "NothingToDo",
            .not_supported => "NotSupported",
            .signature_invalid => "SignatureInvalid",
            .ac_power_required => "AcPowerRequired",
            .permission_denied => "PermissionDenied",
            .broken_system => "BrokenSystem",
            .battery_level_too_low => "BatteryLevelTooLow",
            .needs_user_action => "NeedsUserAction",
            .auth_expired => "AuthExpired",
            .invalid_data => "InvalidData",
            .timed_out => "TimedOut",
            .busy => "Busy",
            .not_reachable => "NotReachable",
            .unknown => null,
        };
    }

    pub fn fromName(name: []const u8) ?Error {
        inline for (std.enums.values(Error)) |e| {
            if (e.wireName()) |wire| {
                if (std.mem.eql(u8, name, wire)) return e;
            }
        }
        return null;
    }
};

test "status decoder covers all 15 wire values and tolerates unknown ones" {
    const expected = [_]Status{
        .unknown,        .idle,         .loading,          .decompressing,
        .device_restart, .device_write, .device_verify,    .scheduling,
        .downloading,    .device_read,  .device_erase,     .waiting_for_auth,
        .device_busy,    .shutdown,     .waiting_for_user,
    };
    for (expected, 0..) |status, i| {
        try std.testing.expectEqual(status, Status.decode(@intCast(i)));
    }
    try std.testing.expectEqual(Status.unknown, Status.decode(15));
    try std.testing.expectEqual(Status.unknown, Status.decode(999));
}

test "update state decoder covers all 6 wire values" {
    const expected = [_]UpdateState{ .unknown, .pending, .success, .failed, .needs_reboot, .failed_transient };
    for (expected, 0..) |state, i| {
        try std.testing.expectEqual(state, UpdateState.decode(@intCast(i)));
    }
    try std.testing.expectEqual(UpdateState.unknown, UpdateState.decode(6));
}

test "urgency, remote kind and request kind decoders tolerate unknown values" {
    try std.testing.expectEqual(Urgency.critical, Urgency.decode(4));
    try std.testing.expectEqual(Urgency.unknown, Urgency.decode(5));
    try std.testing.expectEqual(RemoteKind.download, RemoteKind.decode(1));
    try std.testing.expectEqual(RemoteKind.directory, RemoteKind.decode(3));
    try std.testing.expectEqual(RemoteKind.unknown, RemoteKind.decode(4));
    try std.testing.expectEqual(RequestKind.post, RequestKind.decode(1));
    try std.testing.expectEqual(RequestKind.immediate, RequestKind.decode(2));
    try std.testing.expectEqual(RequestKind.unknown, RequestKind.decode(3));
}

test "version format decoder includes the 2.x additions" {
    try std.testing.expectEqual(VersionFormat.plain, VersionFormat.decode(1));
    try std.testing.expectEqual(VersionFormat.dell_bios_msb, VersionFormat.decode(13));
    try std.testing.expectEqual(VersionFormat.intel_csme19, VersionFormat.decode(14));
    try std.testing.expectEqual(VersionFormat.compal_bios, VersionFormat.decode(15));
    try std.testing.expectEqual(VersionFormat.unknown, VersionFormat.decode(16));
}

test "client feature flags are 0x2BC" {
    try std.testing.expectEqual(@as(u64, 0x2BC), FeatureFlags.client);
    try std.testing.expect(!FeatureFlags.has(FeatureFlags.client, FeatureFlags.allow_authentication));
}

test "updatable filter uses bit numbers 1 and 37" {
    try std.testing.expect(DeviceFlags.isUpdatable(1 << 1));
    try std.testing.expect(DeviceFlags.isUpdatable(1 << 37));
    try std.testing.expect(!DeviceFlags.isUpdatable(0));
    try std.testing.expect(!DeviceFlags.isUpdatable(DeviceFlags.supported));
    try std.testing.expectEqual(@as(u64, 1 << 45), DeviceFlags.affects_fde);
    try std.testing.expectEqual(@as(u64, 1 << 29), DeviceFlags.usable_during_update);
}

test "problem bits match the fwupd headers" {
    try std.testing.expectEqual(@as(u64, 1 << 0), @backingInt(Problem.system_power_too_low));
    try std.testing.expectEqual(@as(u64, 1 << 14), @backingInt(Problem.firmware_locked));
    try std.testing.expectEqual(@as(u64, 0x7FFF), Problem.known_mask);
    try std.testing.expectEqual(std.math.maxInt(u64), Problem.unknown);
}

test "error names round-trip for all 22 wire values" {
    var count: usize = 0;
    inline for (std.enums.values(Error)) |e| {
        if (e.wireName()) |name| {
            count += 1;
            try std.testing.expectEqual(e, Error.fromName(name).?);
        }
    }
    try std.testing.expectEqual(@as(usize, 22), count);
    try std.testing.expect(Error.fromName("Bogus") == null);
    try std.testing.expect(Error.fromName("") == null);
    try std.testing.expect(Error.unknown.wireName() == null);
}
