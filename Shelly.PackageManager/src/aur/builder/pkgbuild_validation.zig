const std = @import("std");
const validation = @import("../../pkgbuild/shared_validtor.zig");
const pkgbuild_parser = @import("../../pkgbuild/pkgbuild_parser.zig");
const homograph_validator = @import("../../pkgbuild/homograph_validator.zig");
const post_install_validator = @import("../../pkgbuild/post_install_validator.zig");
const install_script = @import("../../pkgbuild/install_script.zig");
const install_script_scanner = @import("../../pkgbuild/install_script_scanner.zig");
const local_source_validator = @import("../../pkgbuild/local_source_validator.zig");

pub const ValidationFinding = validation.ValidationFinding;

pub const PkgbuildValidation = struct {
    scripts: validation.ValidationResult,
    homograph: validation.ValidationResult,
    local_source: validation.ValidationResult,

    pub fn deinit(self: *PkgbuildValidation, allocator: std.mem.Allocator) void {
        self.scripts.deinit(allocator);
        self.homograph.deinit(allocator);
        self.local_source.deinit(allocator);
        self.* = undefined;
    }

    pub fn hasFindings(self: *const PkgbuildValidation) bool {
        return self.scripts.has_findings or self.homograph.has_findings or self.local_source.has_findings;
    }

    pub fn flatten(self: *const PkgbuildValidation, allocator: std.mem.Allocator) ![]ValidationFinding {
        const post = self.scripts.findings.items;
        const homograph = self.homograph.findings.items;
        const local_source = self.local_source.findings.items;
        const findings = try allocator.alloc(ValidationFinding, post.len + homograph.len + local_source.len);
        @memcpy(findings[0..post.len], post);
        @memcpy(findings[post.len .. post.len + homograph.len], homograph);
        @memcpy(findings[post.len + homograph.len ..], local_source);
        return findings;
    }
};

pub fn validatePkgbuild(
    allocator: std.mem.Allocator,
    io: std.Io,
    content: []const u8,
    base_directory: ?[]const u8,
) !PkgbuildValidation {
    const parser = pkgbuild_parser.PkgbuildParser{ .allocator = allocator, .io = io };
    var info = try parser.parser_content(content, base_directory);
    defer info.deinit(allocator);

    return validatePkgbuildInfo(allocator, io, &info, base_directory, content);
}

pub fn validatePkgbuildInfo(
    allocator: std.mem.Allocator,
    io: std.Io,
    info: *const pkgbuild_parser.Pkgbuild,
    base_directory: ?[]const u8,
    content: ?[]const u8,
) !PkgbuildValidation {
    var owned_script: ?install_script.Script = null;
    defer if (owned_script) |*script| script.deinit(allocator);
    if (info.install_file) |file_name| if (base_directory) |directory| {
        const path = try std.fs.path.join(allocator, &.{ directory, file_name });
        defer allocator.free(path);
        const script_contents = try std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            allocator,
            .limited(32 * 1024 * 1024),
        );
        defer allocator.free(script_contents);
        owned_script = try install_script.Script.init(allocator, file_name, script_contents);
    };
    return validatePkgbuildInfoWithInstallScript(
        allocator,
        io,
        info,
        base_directory,
        content,
        if (owned_script) |*script| script else null,
    );
}

pub fn validatePkgbuildInfoWithInstallScript(
    allocator: std.mem.Allocator,
    io: std.Io,
    info: *const pkgbuild_parser.Pkgbuild,
    base_directory: ?[]const u8,
    content: ?[]const u8,
    reviewed_install_script: ?*const install_script.Script,
) !PkgbuildValidation {
    var scripts = try (post_install_validator.PostInstallValidator{ .allocator = allocator }).validateWithContent(info.*, content);
    errdefer scripts.deinit(allocator);
    if (reviewed_install_script) |script| {
        var install_findings = try (install_script_scanner.InstallScriptScanner{ .allocator = allocator }).validate(script);
        var transferred = false;
        defer {
            if (transferred) install_findings.findings.clearRetainingCapacity();
            install_findings.deinit(allocator);
        }
        try scripts.findings.appendSlice(allocator, install_findings.findings.items);
        scripts.has_findings = scripts.has_findings or install_findings.has_findings;
        transferred = true;
    }
    if (info.hasDynamicAssignments()) {
        for (info.dynamic_assignments) |assignment| {
            const hook = try std.fmt.allocPrint(allocator, "assignment: {s}", .{assignment.name});
            errdefer allocator.free(hook);
            const matched_line = try allocator.dupe(u8, assignment.statement);
            errdefer allocator.free(matched_line);
            const message = try std.fmt.allocPrint(
                allocator,
                "Top-level assignment '{s}' uses command substitution and will be executed while building. Review the command before proceeding.",
                .{assignment.statement},
            );
            errdefer allocator.free(message);
            try scripts.findings.append(allocator, .{
                .tool = "<pkgbuild>",
                .severity = .warning,
                .hook = hook,
                .matched_line = matched_line,
                .message = message,
            });
            scripts.has_findings = true;
        }
    }
    var homograph = try (homograph_validator.HomographValidator{ .allocator = allocator }).validate(info.*);
    errdefer homograph.deinit(allocator);
    return .{
        .scripts = scripts,
        .homograph = homograph,
        .local_source = try (local_source_validator.LocalSourceValidator{ .allocator = allocator, .io = io }).validate(info.*, base_directory),
    };
}
