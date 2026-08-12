const std = @import("std");
const catalog = @import("catalog.zig");

pub const Argument = catalog.Argument;
pub const Option = catalog.Option;

pub const Command = struct {
    path: []const u8,
    parentPath: ?[]const u8,
    name: []const u8,
    description: ?[]const u8,
    hidden: bool,
    isBranch: bool,
    hasAction: bool,
    aliases: []const []const u8,
    arguments: []const Argument,
    options: []const Option,
    implementation: ?[]const u8 = null,
    actionCode: ?u8 = null,
    typeCode: ?u8 = null,
    aliasTypeCodes: []const u8 = &.{},
    bareActionCode: bool = false,
    defaultForAction: bool = false,

    pub fn matches(self: Command, token: []const u8) bool {
        if (std.mem.eql(u8, self.name, token)) return true;
        for (self.aliases) |alias| {
            if (std.mem.eql(u8, alias, token)) return true;
        }
        return false;
    }
};

pub const Manifest = struct {
    binary: []const u8,
    version: []const u8,
    informationalVersion: []const u8,
    commandCount: usize,
    leafCommandCount: usize,
    commands: []const Command,

    pub fn load(allocator: std.mem.Allocator) !Manifest {
        @setEvalBranchQuota(100_000);
        var commands: std.ArrayList(Command) = .empty;
        try commands.append(allocator, .{
            .path = catalog.binary,
            .parentPath = null,
            .name = catalog.binary,
            .description = catalog.root_description,
            .hidden = false,
            .isBranch = true,
            .hasAction = true,
            .aliases = &.{},
            .arguments = &catalog.root_arguments,
            .options = &catalog.root_options,
            .implementation = "Native Zig action/type dispatcher",
        });

        inline for (catalog.variants, 0..) |variant, variant_index| {
            if (comptime actionAppearedBefore(variant.action, variant_index)) continue;

            const action_path = try std.fmt.allocPrint(allocator, "{s} {s}", .{ catalog.binary, variant.action.name() });
            try commands.append(allocator, .{
                .path = action_path,
                .parentPath = catalog.binary,
                .name = variant.action.name(),
                .description = variant.action.description(),
                .hidden = false,
                .isBranch = true,
                .hasAction = false,
                .aliases = &.{},
                .arguments = &.{},
                .options = &.{},
                .implementation = "Native Zig action dispatcher",
            });

            inline for (catalog.variants) |candidate| {
                if (comptime candidate.action != variant.action) continue;
                const command_path = try std.fmt.allocPrint(
                    allocator,
                    "{s} {s} {s}",
                    .{ catalog.binary, candidate.action.name(), candidate.name },
                );
                try commands.append(allocator, .{
                    .path = command_path,
                    .parentPath = action_path,
                    .name = candidate.name,
                    .description = candidate.description,
                    .hidden = false,
                    .isBranch = false,
                    .hasAction = true,
                    .aliases = &.{},
                    .arguments = candidate.arguments,
                    .options = catalog.resolveOptions(candidate),
                    .implementation = candidate.implementation,
                    .actionCode = candidate.action.code(),
                    .typeCode = candidate.type_code,
                    .aliasTypeCodes = candidate.alias_type_codes,
                    .bareActionCode = candidate.bare_action_code,
                    .defaultForAction = candidate.default_for_action,
                });
            }
        }

        const native_commands = try commands.toOwnedSlice(allocator);
        return .{
            .binary = catalog.binary,
            .version = catalog.version,
            .informationalVersion = catalog.informational_version,
            .commandCount = native_commands.len,
            .leafCommandCount = catalog.variants.len,
            .commands = native_commands,
        };
    }

    pub fn root(self: *const Manifest) *const Command {
        return &self.commands[0];
    }

    pub fn findByPath(self: *const Manifest, path: []const u8) ?*const Command {
        for (self.commands) |*command| {
            if (std.mem.eql(u8, command.path, path)) return command;
        }
        return null;
    }

    pub fn findChild(self: *const Manifest, parent: *const Command, token: []const u8) ?*const Command {
        for (self.commands) |*command| {
            const parent_path = command.parentPath orelse continue;
            if (std.mem.eql(u8, parent_path, parent.path) and command.matches(token)) return command;
        }
        return null;
    }

    pub fn findDefaultChild(self: *const Manifest, parent: *const Command) ?*const Command {
        for (self.commands) |*command| {
            const parent_path = command.parentPath orelse continue;
            if (command.defaultForAction and std.mem.eql(u8, parent_path, parent.path)) return command;
        }
        return null;
    }

    pub fn findOption(self: *const Manifest, command: *const Command, token: []const u8) ?*const Option {
        for (command.options) |*option| {
            if (option.matches(token)) return option;
        }
        if (self.findDefaultChild(command)) |default_child| {
            for (default_child.options) |*option| {
                if (option.matches(token)) return option;
            }
        }
        if (command != self.root()) {
            for (self.root().options) |*option| {
                if (option.recursive and option.matches(token)) return option;
            }
        }
        return null;
    }
};

fn actionAppearedBefore(comptime action: catalog.Action, comptime index: usize) bool {
    for (catalog.variants[0..index]) |earlier| {
        if (earlier.action == action) return true;
    }
    return false;
}

test "builds the complete action-first manifest from native Zig metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try Manifest.load(arena.allocator());
    try std.testing.expectEqual(catalog.variants.len, manifest.leafCommandCount);
    try std.testing.expectEqualStrings(catalog.version, manifest.version);
    try std.testing.expect(manifest.findByPath("shelly search flatpak") != null);
    try std.testing.expect(manifest.findByPath("shelly sync flatpak") != null);
    try std.testing.expect(manifest.findByPath("shelly flatpak search") == null);
    try std.testing.expect(manifest.findByPath("shelly query") == null);
    try std.testing.expectEqualStrings("query", manifest.root().arguments[0].name);
    try std.testing.expect(manifest.findByPath("shelly config get") != null);
    try std.testing.expect(manifest.findByPath("shelly config set") != null);
    try std.testing.expect(manifest.findByPath("shelly config list") != null);
    try std.testing.expect(manifest.findByPath("shelly config reset") != null);
    try std.testing.expect(manifest.findByPath("shelly config parallel") != null);
    try std.testing.expect(manifest.findByPath("shelly get config") == null);
    try std.testing.expectEqualStrings(
        "shelly config list",
        manifest.findDefaultChild(manifest.findByPath("shelly config").?).?.path,
    );
    try std.testing.expectEqualStrings(
        "shelly sync standard",
        manifest.findDefaultChild(manifest.findByPath("shelly sync").?).?.path,
    );
}

test "centralizes shared modifiers while retaining type-specific additions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try Manifest.load(arena.allocator());

    const standard = manifest.findByPath("shelly install standard").?;
    const aur = manifest.findByPath("shelly install aur").?;
    try std.testing.expect(standard.options[0].matches("-b"));
    try std.testing.expect(aur.options[0].matches("-b"));
    try std.testing.expect(!aur.options[0].matches("-o"));
    try std.testing.expect(manifest.findOption(aur, "--chroot") != null);
    try std.testing.expect(manifest.findOption(aur, "--version") != null);
    try std.testing.expect(manifest.findOption(aur, "--verbose") == null);
    try std.testing.expectEqualStrings("--version", manifest.findOption(aur, "-v").?.name);
    try std.testing.expect(manifest.findByPath("shelly install-version aur") == null);

    const flatpak_install = manifest.findByPath("shelly install flatpak").?;
    try std.testing.expectEqualStrings("--ref-file", manifest.findOption(flatpak_install, "-e").?.name);
    try std.testing.expectEqualStrings("--bundle", manifest.findOption(flatpak_install, "-u").?.name);
    try std.testing.expect(manifest.findByPath("shelly install-ref-file flatpak") == null);
    try std.testing.expect(manifest.findByPath("shelly install-bundle flatpak") == null);

    const aur_search = manifest.findByPath("shelly search aur").?;
    try std.testing.expectEqualStrings("--pkgbuild", manifest.findOption(aur_search, "-p").?.name);

    const flatpak_remove = manifest.findByPath("shelly remove flatpak").?;
    try std.testing.expect(manifest.findOption(flatpak_remove, "--remove-config") != null);
    try std.testing.expect(manifest.findOption(flatpak_remove, "--config") == null);
}

test "native help describes the implementations that execute" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try Manifest.load(arena.allocator());

    const standard = manifest.findByPath("shelly search standard").?;
    try std.testing.expect(std.mem.indexOf(u8, standard.description.?, "ALPM repository") != null);
    try std.testing.expect(std.mem.indexOf(u8, standard.implementation.?, "get_installed_packages") != null);
    try std.testing.expectEqualStrings(
        "Search packages from the local ALPM database",
        manifest.findOption(standard, "--installed").?.description.?,
    );

    const install_standard = manifest.findByPath("shelly install standard").?;
    try std.testing.expect(std.mem.indexOf(u8, install_standard.implementation.?, "install_packages") != null);
    try std.testing.expect(manifest.findOption(manifest.findByPath("shelly upgrade standard").?, "--all") != null);
}
