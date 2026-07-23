const std = @import("std");

extern fn dgettext(domainname: [*:0]const u8, msgid: [*:0]const u8) [*:0]const u8;

pub fn _(msgid: [:0]const u8) [:0]const u8 {
    return std.mem.span(dgettext("shelly-ui", msgid.ptr));
}
