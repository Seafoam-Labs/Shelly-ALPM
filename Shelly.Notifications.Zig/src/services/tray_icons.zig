//! The two tray icon names.
//!
//! The tray wants `[:0]const u8` names that outlive the tray object, and the
//! worker thread replaces them after a config change, so both live in fixed
//! buffers here rather than in reallocated memory. Readers get a snapshot via
//! `normal`, `attention`, or `forCount`.
const std = @import("std");

const ConfigResolver = @import("config.zig").ConfigResolver;

pub const default = "shelly-tray";
pub const default_attention = "shelly-update";

const max_name_len = 256;

var name_buf: [max_name_len:0]u8 = undefined;
var attention_buf: [max_name_len:0]u8 = undefined;

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

/// The icon to show for `update_count` pending updates.
pub fn forCount(update_count: usize) [:0]const u8 {
    return if (update_count > 0) attention_name else normal_name;
}

/// Reads the configured names and swaps them in. Returns false, leaving the
/// previous names in place, if either name is too long for its buffer.
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

/// Explicit paths win, then the symbolic setting, then the bundled defaults.
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
