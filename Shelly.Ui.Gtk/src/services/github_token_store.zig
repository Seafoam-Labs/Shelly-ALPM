const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gio = bindings.gio;
const glib = bindings.glib;

const service_name: [:0]const u8 = "org.freedesktop.secrets";
const service_path: [:0]const u8 = "/org/freedesktop/secrets";
const service_interface: [:0]const u8 = "org.freedesktop.Secret.Service";
const session_interface: [:0]const u8 = "org.freedesktop.Secret.Session";
const item_interface: [:0]const u8 = "org.freedesktop.Secret.Item";
const application_attribute: [:0]const u8 = "com.shellyorg.shelly";
const purpose_attribute: [:0]const u8 = "github-token";
const item_label: [:0]const u8 = "Shelly GitHub token";

pub fn read(allocator: std.mem.Allocator) !?[]u8 {
    const connection = try sessionConnection();
    defer connection.unref();
    const session = try openSession(connection);
    defer std.heap.c_allocator.free(session.path);
    defer closeSession(connection, session) catch |err| {
        std.log.warn("Could not close the temporary keyring session: {s}", .{@errorName(err)});
    };

    const search = try searchItems(connection);
    defer search.unref();
    const unlocked = search.getChildValue(0);
    defer unlocked.unref();
    const locked = search.getChildValue(1);
    defer locked.unref();

    if (unlocked.nChildren() == 0) {
        if (locked.nChildren() > 0) return error.SecretStoreLocked;
        return null;
    }

    const item = unlocked.getChildValue(0);
    defer item.unref();
    const item_path = variantString(item);
    const params = glib.Variant.new("(o)", session.path.ptr);
    const secret = try call(
        connection,
        item_path,
        item_interface,
        "GetSecret",
        params,
        "((oayays))",
    );
    defer secret.unref();

    const value = secretValue(secret);
    defer value.unref();
    var len: usize = 0;
    const raw = value.getFixedArray(&len, @sizeOf(u8));
    if (len == 0) return null;
    const bytes: [*]const u8 = @ptrCast(raw);
    try validateToken(bytes[0..len]);
    return try allocator.dupe(u8, bytes[0..len]);
}

pub fn store(token: []const u8) !void {
    try validateToken(token);
    const connection = try sessionConnection();
    defer connection.unref();
    const session = try openSession(connection);
    defer std.heap.c_allocator.free(session.path);
    defer closeSession(connection, session) catch |err| {
        std.log.warn("Could not close the temporary keyring session: {s}", .{@errorName(err)});
    };
    const collection_path = try defaultCollection(connection);
    defer std.heap.c_allocator.free(collection_path);

    const properties = buildItemProperties();
    const secret = buildSecret(session.path, token);
    const params = glib.Variant.new("(@a{sv}@(oayays)b)", properties, secret, @as(c_int, 1));
    const result = try call(
        connection,
        collection_path,
        "org.freedesktop.Secret.Collection",
        "CreateItem",
        params,
        "(oo)",
    );
    defer result.unref();

    const prompt = result.getChildValue(1);
    defer prompt.unref();
    if (!std.mem.eql(u8, variantString(prompt), "/")) return error.SecretStorePromptRequired;
}

pub fn clear() !void {
    const connection = try sessionConnection();
    defer connection.unref();
    const search = try searchItems(connection);
    defer search.unref();
    const unlocked = search.getChildValue(0);
    defer unlocked.unref();
    const locked = search.getChildValue(1);
    defer locked.unref();

    if (unlocked.nChildren() == 0) {
        if (locked.nChildren() > 0) return error.SecretStoreLocked;
        return;
    }

    const item = unlocked.getChildValue(0);
    defer item.unref();
    const item_path = variantString(item);
    const result = try call(
        connection,
        item_path,
        item_interface,
        "Delete",
        glib.Variant.new("()"),
        "(o)",
    );
    defer result.unref();

    const prompt = result.getChildValue(0);
    defer prompt.unref();
    if (!std.mem.eql(u8, variantString(prompt), "/")) return error.SecretStorePromptRequired;
}

fn validateToken(token: []const u8) !void {
    if (token.len == 0 or std.mem.findScalar(u8, token, 0) != null or
        std.mem.findScalar(u8, token, '\r') != null or
        std.mem.findScalar(u8, token, '\n') != null)
    {
        return error.InvalidGitHubToken;
    }
}

test "GitHub token validation rejects empty values and header injection" {
    try std.testing.expectError(error.InvalidGitHubToken, validateToken(""));
    try std.testing.expectError(error.InvalidGitHubToken, validateToken("line\r\ninjection"));
    try validateToken("github-token");
}

const Session = struct {
    path: [:0]u8,
};

fn openSession(connection: *gio.DBusConnection) !Session {
    const result = try call(
        connection,
        service_path,
        service_interface,
        "OpenSession",
        glib.Variant.new("(sv)", "plain", glib.Variant.new("s", "")),
        "(vo)",
    );
    defer result.unref();

    const path = result.getChildValue(1);
    defer path.unref();
    const path_slice = variantString(path);
    return .{ .path = try std.heap.c_allocator.dupeSentinel(u8, path_slice, 0) };
}

fn closeSession(connection: *gio.DBusConnection, session: Session) !void {
    const result = try call(
        connection,
        session.path,
        session_interface,
        "Close",
        glib.Variant.new("()"),
        "()",
    );
    result.unref();
}

fn searchItems(connection: *gio.DBusConnection) !*glib.Variant {
    const variant_type = glib.VariantType.new("a{ss}");
    defer variant_type.free();
    const builder = glib.VariantBuilder.new(variant_type);
    defer builder.unref();
    builder.add("{ss}", "application", application_attribute.ptr);
    builder.add("{ss}", "purpose", purpose_attribute.ptr);
    const attributes = builder.end();
    const params = glib.Variant.new("(@a{ss})", attributes);
    return try call(
        connection,
        service_path,
        service_interface,
        "SearchItems",
        params,
        "(aoao)",
    );
}

fn defaultCollection(connection: *gio.DBusConnection) ![:0]u8 {
    const result = try call(
        connection,
        service_path,
        service_interface,
        "ReadAlias",
        glib.Variant.new("(s)", "default"),
        "(o)",
    );
    defer result.unref();
    const path = result.getChildValue(0);
    defer path.unref();
    const path_slice = variantString(path);
    if (std.mem.eql(u8, path_slice, "/")) return error.SecretStoreUnavailable;
    return try std.heap.c_allocator.dupeSentinel(u8, path_slice, 0);
}

fn buildItemProperties() *glib.Variant {
    const attribute_type = glib.VariantType.new("a{ss}");
    defer attribute_type.free();
    const attribute_builder = glib.VariantBuilder.new(attribute_type);
    defer attribute_builder.unref();
    attribute_builder.add("{ss}", "application", application_attribute.ptr);
    attribute_builder.add("{ss}", "purpose", purpose_attribute.ptr);
    const attributes = attribute_builder.end();

    const properties_type = glib.VariantType.new("a{sv}");
    defer properties_type.free();
    const properties_builder = glib.VariantBuilder.new(properties_type);
    defer properties_builder.unref();
    properties_builder.add(
        "{sv}",
        "org.freedesktop.Secret.Item.Label",
        glib.Variant.new("s", item_label.ptr),
    );
    properties_builder.add(
        "{sv}",
        "org.freedesktop.Secret.Item.Attributes",
        attributes,
    );
    return properties_builder.end();
}

fn buildSecret(session_path: [:0]const u8, token: []const u8) *glib.Variant {
    const byte_type = glib.VariantType.new("y");
    defer byte_type.free();
    const parameters = glib.Variant.newFixedArray(
        byte_type,
        null,
        0,
        @sizeOf(u8),
    );
    const value = glib.Variant.newFixedArray(
        byte_type,
        @ptrCast(token.ptr),
        token.len,
        @sizeOf(u8),
    );
    return glib.Variant.new(
        "(o@ay@ays)",
        session_path.ptr,
        parameters,
        value,
        "text/plain",
    );
}

fn secretValue(secret_response: *glib.Variant) *glib.Variant {
    const secret = secret_response.getChildValue(0);
    defer secret.unref();
    return secret.getChildValue(2);
}

test "keyring item metadata builds a Secret Service property dictionary" {
    const properties = buildItemProperties();
    defer properties.unref();
    try std.testing.expectEqual(@as(usize, 2), properties.nChildren());
}

test "Secret Service item stores token bytes as the secret value" {
    const secret = buildSecret("/org/freedesktop/secrets/session/test", "test-token");
    defer secret.unref();

    const parameters = secret.getChildValue(1);
    defer parameters.unref();
    var parameters_len: usize = 0;
    _ = parameters.getFixedArray(&parameters_len, @sizeOf(u8));
    try std.testing.expectEqual(@as(usize, 0), parameters_len);

    const value = secret.getChildValue(2);
    defer value.unref();
    var value_len: usize = 0;
    const raw = value.getFixedArray(&value_len, @sizeOf(u8));
    try std.testing.expectEqualStrings("test-token", @as([*]const u8, @ptrCast(raw))[0..value_len]);
}

test "Secret Service GetSecret reply unwraps the returned secret struct" {
    const secret_response = glib.Variant.new("(@(oayays))", buildSecret(
        "/org/freedesktop/secrets/session/test",
        "test-token",
    ));
    defer secret_response.unref();
    const value = secretValue(secret_response);
    defer value.unref();
    var value_len: usize = 0;
    const raw = value.getFixedArray(&value_len, @sizeOf(u8));
    try std.testing.expectEqualStrings("test-token", @as([*]const u8, @ptrCast(raw))[0..value_len]);
}

fn sessionConnection() !*gio.DBusConnection {
    var error_out: ?*glib.Error = null;
    const connection = gio.busGetSync(.session, null, &error_out);
    if (error_out) |err| {
        glib.Error.free(err);
        return error.SecretServiceUnavailable;
    }
    return connection orelse error.SecretServiceUnavailable;
}

fn call(
    connection: *gio.DBusConnection,
    object_path: [:0]const u8,
    interface: [:0]const u8,
    method: [:0]const u8,
    params: *glib.Variant,
    reply_signature: [:0]const u8,
) !*glib.Variant {
    const reply_type = glib.VariantType.new(reply_signature);
    defer reply_type.free();
    var error_out: ?*glib.Error = null;
    const result = connection.callSync(
        service_name,
        object_path,
        interface,
        method,
        params,
        reply_type,
        .{},
        5000,
        null,
        &error_out,
    );
    if (error_out) |err| {
        std.log.warn("Secret Service method {s} failed: {s}", .{
            method,
            std.mem.span(err.f_message orelse "unknown D-Bus error"),
        });
        glib.Error.free(err);
        return error.SecretServiceCallFailed;
    }
    return result orelse error.SecretServiceCallFailed;
}

fn variantString(value: *glib.Variant) [:0]const u8 {
    return std.mem.span(value.getString(null));
}
