const protocol = @import("Shelly_Flatpak_Protocol");

export fn shelly_flatpak_backend_get_api(
    _: u32,
    _: *const protocol.HostApiV1,
    api: *protocol.BackendApiV1,
) callconv(.c) protocol.Status {
    api.* = .{
        .struct_size = @offsetOf(protocol.BackendApiV1, "execute"),
        .abi_version = protocol.abi_version,
        .create = null,
        .destroy = null,
        .execute = null,
        .cancel = null,
        .free_response = null,
    };
    return .success;
}
