const std = @import("std");

pub const domain = "shelly-ui";
pub const locale_dir = "/usr/share/locale";

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const LC_ALL: c_int = 6;

extern fn setlocale(category: c_int, locale: [*:0]const u8) ?[*:0]const u8;
extern fn bindtextdomain(domainname: [*:0]const u8, dirname: [*:0]const u8) ?[*:0]const u8;
extern fn bind_textdomain_codeset(domainname: [*:0]const u8, codeset: [*:0]const u8) ?[*:0]const u8;
extern fn textdomain(domainname: [*:0]const u8) ?[*:0]const u8;
extern fn dgettext(domainname: [*:0]const u8, msgid: [*:0]const u8) [*:0]const u8;

pub fn init() bool {
    return initWithLocale(null);
}

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn initWithLocale(override_locale: ?[:0]const u8) bool {
    _ = setlocale(LC_ALL, "");

    if (override_locale) |loc| {
        _ = setenv("LANGUAGE", loc.ptr, 1);
    }

    const locale_directory = getenv("SHELLY_LOCALE_DIR") orelse locale_dir;
    const directory_ok = bindtextdomain(domain, locale_directory) != null;
    const codeset_ok = bind_textdomain_codeset(domain, "UTF-8") != null;
    const domain_ok = textdomain(domain) != null;
    return directory_ok and codeset_ok and domain_ok;
}

pub fn _(msgid: [:0]const u8) [:0]const u8 {
    return std.mem.span(dgettext(domain, msgid.ptr));
}
