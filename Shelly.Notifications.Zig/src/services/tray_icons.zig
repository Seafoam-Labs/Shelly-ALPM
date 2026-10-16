const std = @import("std");

const ConfigResolver = @import("config.zig").ConfigResolver;

pub const default = "shelly-tray";
pub const default_attention = "shelly-update";

const MAX_NAME_LEN = 256;

var name_buf: [MAX_NAME_LEN:0]u8 = undefined;
var attention_buf: [MAX_NAME_LEN:0]u8 = undefined;

var normal_name: [:0]const u8 = default;
var attention_name: [:0]const u8 = default_attention;

pub const IconsToUse = struct {
    icon_name: []const u8,
    attention_icon_name: []const u8,
};

pub fn normal() [:0]const u8 {
    return normal_name;
}

pub fn attention() [:0]const u8 {
    return attention_name;
}

pub fn forCount(update_count: usize) [:0]const u8 {
    return if (update_count > 0) attention_name else normal_name;
}

pub fn loadFromConfig(config: *ConfigResolver) bool {
    const icons = fromConfig(config);

    if (icons.icon_name.len >= name_buf.len or icons.attention_icon_name.len >= attention_buf.len) {
        return false;
    }

    @memcpy(name_buf[0..icons.icon_name.len], icons.icon_name);
    name_buf[icons.icon_name.len] = 0;
    @memcpy(attention_buf[0..icons.attention_icon_name.len], icons.attention_icon_name);
    attention_buf[icons.attention_icon_name.len] = 0;

    normal_name = name_buf[0..icons.icon_name.len :0];
    attention_name = attention_buf[0..icons.attention_icon_name.len :0];
    return true;
}

fn fromConfig(config: *ConfigResolver) IconsToUse {
    const conf = config.get() catch return defaults();

    if (conf.TrayIconPath.len > 0 or conf.TrayUpdatesIconPath.len > 0) {
        return .{
            .icon_name = conf.TrayIconPath,
            .attention_icon_name = conf.TrayUpdatesIconPath,
        };
    }

    if (conf.UseSymbolicTray) {
        return .{
            .icon_name = "shelly-shell-symbolic",
            .attention_icon_name = "shelly-updates-symbolic",
        };
    }

    return defaults();
}

fn defaults() IconsToUse {
    return .{ .icon_name = default, .attention_icon_name = default_attention };
}
