pub fn cstr(buf: []u8, s: []const u8) [:0]const u8 {
    const len = @min(s.len, buf.len - 1);
    @memcpy(buf[0..len], s[0..len]);
    buf[len] = 0;
    return buf[0..len :0];
}
