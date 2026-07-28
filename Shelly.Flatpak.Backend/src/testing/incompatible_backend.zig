const protocol = @import("Shelly_Flatpak_Protocol");

export fn shelly_flatpak_backend_get_api(
    _: u32,
    _: *const protocol.HostApiV1,
    _: *protocol.BackendApiV1,
) callconv(.c) protocol.Status {
    return .incompatible;
}
