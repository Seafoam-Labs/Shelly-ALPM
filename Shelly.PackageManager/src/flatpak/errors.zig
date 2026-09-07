const std = @import("std");
const protocol = @import("Shelly_Flatpak_Protocol");

pub const Error = error{
    FlatpakBackendUnavailable,
    FlatpakBackendIncompatible,
    FlatpakBackendInvalid,
    FlatpakBackendCreateFailed,
    FlatpakBackendTransportFailed,
    FlatpakProtocolInvalid,
    FlatpakProtocolMismatch,
    FlatpakProtocolMessageTooLarge,
    FlatpakOperationFailed,
    FlatpakRemoteNotFound,
    FlatpakCatalogNotFound,
    FlatpakNotFound,
    Cancelled,
};

pub fn fromStatus(status: protocol.Status) Error!void {
    return switch (status) {
        .success => {},
        .incompatible => Error.FlatpakBackendIncompatible,
        .unavailable => Error.FlatpakBackendUnavailable,
        .cancelled => Error.Cancelled,
        .invalid_argument => Error.FlatpakProtocolInvalid,
        .internal_error => Error.FlatpakBackendTransportFailed,
    };
}

pub fn fromCode(code: []const u8) Error {
    if (std.mem.eql(u8, code, "flatpak.cancelled"))
        return Error.Cancelled;
    if (std.mem.eql(u8, code, "flatpak.remote_not_found"))
        return Error.FlatpakRemoteNotFound;
    if (std.mem.eql(u8, code, "flatpak.catalog_not_found"))
        return Error.FlatpakCatalogNotFound;
    if (std.mem.eql(u8, code, "flatpak.not_found"))
        return Error.FlatpakNotFound;
    if (std.mem.eql(u8, code, "protocol.unsupported_schema"))
        return Error.FlatpakProtocolMismatch;
    if (std.mem.eql(u8, code, "protocol.message_too_large"))
        return Error.FlatpakProtocolMessageTooLarge;
    if (std.mem.startsWith(u8, code, "protocol."))
        return Error.FlatpakProtocolInvalid;
    return Error.FlatpakOperationFailed;
}

pub fn unavailableMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        Error.FlatpakBackendUnavailable => "Flatpak support is not installed. Install flatpak and shelly-flatpak-backend, then try again.",
        Error.FlatpakBackendIncompatible => "Shelly and its Flatpak backend have incompatible versions. Upgrade shelly and shelly-flatpak-backend together, then try again.",
        else => null,
    };
}
