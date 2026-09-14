const std = @import("std");
const translations = @import("translations.zig");

pub const WireKind = enum {
    CacheCleanExtraEntries,
    PackageConflict,
    InstallIgnored,
    ReplacePackage,
    CorruptedPackage,
    RemovePackagesSkip,
    ImportPgpKey,
    PartialUpgrade,
    StandardUpgrade,
    TransactionInstall,
    TransactionRemove,
    TransactionAurInstall,
    SelectProvider,
    SelectOptionalDependency,
    SelectOptionalDependencies,
    PurifyConfirm,
    ImportSourceSigningKey,
};

pub const QuestionTemplate = struct {
    wire_kind: WireKind,
    placeholders: []const []const u8 = &.{},
};

// This table contains all the identifiers for each question template entry as well as all their placeholder
// items. In order to add a new entry, create a new "WireKind" enum, then add to the table. If there are any
// placeholders, just add them inside their list. 
pub const Table: []const QuestionTemplate = &.{
    .{ .wire_kind = .CacheCleanExtraEntries },
    .{ .wire_kind = .PackageConflict, .placeholders = &. {
        "package_one", "version_one", "package_two", "version_two", "package_to_remove",
    } },
    .{ .wire_kind = .InstallIgnored, .placeholders = &. { "package"} },
    .{ .wire_kind = .ReplacePackage, .placeholders = &. {
        "package_one", "version_one", "package_two", "version_two",
    } },
    .{ .wire_kind = .CorruptedPackage, .placeholders = &. {"file"} },
    .{ .wire_kind = .RemovePackagesSkip },
    .{ .wire_kind = .ImportPgpKey, .placeholders = &. {"key_id"} },
    .{ .wire_kind = .PartialUpgrade },
    .{ .wire_kind = .StandardUpgrade },
    .{ .wire_kind = .TransactionInstall },
    .{ .wire_kind = .TransactionAurInstall },
    .{ .wire_kind = .TransactionRemove },
    .{ .wire_kind = .SelectProvider },
    .{ .wire_kind = .SelectOptionalDependency, .placeholders = &. {"pkg"} },
    .{ .wire_kind = .SelectOptionalDependencies, .placeholders = &.{"pkg"} },
    .{ .wire_kind = .PurifyConfirm },
    .{ .wire_kind = .ImportSourceSigningKey, .placeholders = &.{ "package", "fingerprint" } },
};


fn localized(row: QuestionTemplate) [:0]const u8 {
    return switch (row.wire_kind) {
        .CacheCleanExtraEntries    => translations._("Would you like to remove extra cache entries?"),
        .PackageConflict           => translations._("{package_one}-{version_one} conflicts with {package_two}-{version_two}. Remove {package_to_remove}?"),
        .InstallIgnored            => translations._("Install ignored package: {package}?"),
        .ReplacePackage            => translations._("Replace {package_one}-{version_one} with {package_two}-{version_two}?"),
        .CorruptedPackage          => translations._("Corrupted package {file}. Delete?"),
        .RemovePackagesSkip        => translations._("Some packages must be removed to proceed. Skip them instead?"),
        .ImportPgpKey              => translations._("Import PGP key {key_id}?"),
        .PartialUpgrade            => translations._("Proceed with this partial upgrade?"),
        .StandardUpgrade           => translations._("Proceed with the standard system upgrade?"),
        .TransactionInstall        => translations._("Proceed with package installation?"),
        .TransactionRemove         => translations._("Proceed with package removal?"),
        .TransactionAurInstall     => translations._("Proceed with AUR package installation?"),
        .SelectProvider            => translations._("Select Provider"),
        .SelectOptionalDependency  => translations._("Select an optional dependency for {pkg}"),
        .SelectOptionalDependencies => translations._("Select optional dependencies for {pkg}"),
        .PurifyConfirm             => translations._("Proceed with purify?"),
        .ImportSourceSigningKey => translations._("PKGBUILD {package} requires source-signing key {fingerprint}. Import it using `shelly keyring recv --user`?"),
    };
}

fn lookup(wire_kind: WireKind) ?QuestionTemplate {
       for (Table) |row| if (row.wire_kind == wire_kind) return row;
       return null;
}

   
fn formatTemplate(allocator: std.mem.Allocator, template: []const u8, placeholders: []const []const u8, arguments: []const []const u8,) ![]u8 {
    var current = try allocator.dupe(u8, template);
    errdefer allocator.free(current);
    var name_buf: [64]u8 = undefined;
    for (placeholders, arguments) |name, value| {
        const wrapped = std.fmt.bufPrint(&name_buf, "{{{s}}}", .{name}) catch return error.PlaceholderTooLong;
        const next = try std.mem.replaceOwned(u8, allocator, current, wrapped, value);
        allocator.free(current);
        current = next;
    }
    return current;
}

fn translate(allocator: std.mem.Allocator, wire_kind: WireKind, arguments: []const []const u8, fallback: []const u8,) ![:0]const u8 {
    const row = lookup(wire_kind) orelse return allocator.dupeZ(u8, fallback);
    if (arguments.len < row.placeholders.len) return allocator.dupeZ(u8, fallback);
    const translated = localized(row);
    const formatted = try formatTemplate(allocator, translated, row.placeholders, arguments);
    defer allocator.free(formatted);
    return allocator.dupeZ(u8, formatted);
}

pub fn translateFromWire(allocator: std.mem.Allocator, wire_kind: []const u8, arguments: []const []const u8, fallback: []const u8,) ![:0]const u8 {
    if (std.meta.stringToEnum(WireKind, wire_kind)) |kind| {
        return translate(allocator, kind, arguments, fallback);
    }
    return allocator.dupeZ(u8, fallback);
}


test "table covers every wire kind and renders every arm" {
    inline for (std.meta.fields(WireKind)) |field| {
        const kind: WireKind = @enumFromInt(field.value);
        const row = lookup(kind) orelse return error.TableMissingWireKind;
        _ = localized(row);
        for (row.placeholders) |p| try std.testing.expect(p.len > 0);
    }
}