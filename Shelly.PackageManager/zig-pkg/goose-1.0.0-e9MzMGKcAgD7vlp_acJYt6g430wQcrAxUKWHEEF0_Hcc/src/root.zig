const std = @import("std");

pub const core = @import("core.zig");
pub const message = @import("message_utils.zig");
pub const proxy = @import("proxy.zig");
pub const introspection = @import("introspection.zig");
pub const generator = @import("generator.zig");
pub const xml_generator = @import("xml_generator.zig");

// Re-export types
const dbus_types = @import("dbus_types.zig");
pub const Signal = dbus_types.Signal;
pub const signal = dbus_types.signal;
pub const Property = dbus_types.Property;
pub const property = dbus_types.property;
pub const Access = dbus_types.Access;

// Re-export Connection
pub const Connection = @import("connection.zig").Connection;
pub const BusType = @import("connection.zig").BusType;
pub const SignalHandler = @import("common.zig").SignalHandler;
