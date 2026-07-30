const std = @import("std");

const format = @import("format.zig");
const output = @import("config.zig");
const colors = @import("colors.zig");
const runtime = @import("../runtime/context.zig");

const StandardPackage = @import("../commands/search.zig").StandardPackage;
const AurPackage = @import("../commands/search.zig").AurPackage;

const none_value = "None";

const FieldWriter = struct {
    context: *runtime.RuntimeContext,
    label_width: usize,

    const separator = " : ";

    pub fn init(context: *runtime.RuntimeContext, label_width: usize) FieldWriter {
        return .{ .context = context, .label_width = label_width };
    }

    fn render(self: *FieldWriter, label: []const u8, value: []const u8) !void {
        const writer = self.context.stdout;
        const use_color = output.supportsAnsi(self.context);
        if (use_color) try writer.writeAll(colors.colorCode(.heading));
        try writer.writeAll(label);
        if (self.label_width > label.len) try writer.splatByteAll(' ', self.label_width - label.len);
        if (use_color) try writer.writeAll(colors.reset);
        try writer.writeAll(separator);
        try writer.writeAll(value);
        try writer.writeByte('\n');
    }

    pub fn text(self: *FieldWriter, label: []const u8, value: []const u8) !void {
        try self.render(label, value);
    }

    pub fn optionalText(
        self: *FieldWriter,
        label: []const u8,
        value: ?[]const u8,
        fallback: []const u8,
    ) !void {
        try self.text(label, value orelse fallback);
    }

    pub fn joined(
        self: *FieldWriter,
        label: []const u8,
        items: []const []const u8,
    ) !void {
        if (items.len == 0) {
            try self.render(label, none_value);
            return;
        }
        const items_text = try format.joined(self.context.allocator, items);
        defer self.context.allocator.free(items_text);
        try self.render(label, items_text);
    }

    pub fn optionalJoined(
        self: *FieldWriter,
        label: []const u8,
        items: ?[]const []const u8,
    ) !void {
        try self.joined(label, items orelse &.{});
    }

    pub fn int(self: *FieldWriter, label: []const u8, value: anytype) !void {
        const int_text = try std.fmt.allocPrint(self.context.allocator, "{d}", .{value});
        defer self.context.allocator.free(int_text);
        try self.render(label, int_text);
    }

    pub fn float2(self: *FieldWriter, label: []const u8, value: f64) !void {
        const float_text = try std.fmt.allocPrint(self.context.allocator, "{d:.2}", .{value});
        defer self.context.allocator.free(float_text);
        try self.render(label, float_text);
    }

    pub fn date(self: *FieldWriter, label: []const u8, ts: i64) !void {
        const date_text = try format.formatLongDate(self.context.allocator, ts);
        defer self.context.allocator.free(date_text);
        try self.render(label, date_text);
    }

    pub fn optionalDate(
        self: *FieldWriter,
        label: []const u8,
        ts: ?i64,
        fallback: []const u8,
    ) !void {
        if (ts) |v| {
            try self.date(label, v);
        } else {
            try self.text(label, fallback);
        }
    }

    pub fn installedSize(
        self: *FieldWriter,
        label: []const u8,
        size_display: format.SizeDisplay,
        raw_size: i64,
    ) !void {
        const size_text = try format.formatSize(
            self.context.allocator,
            size_display,
            format.nonNegative(raw_size),
        );
        defer self.context.allocator.free(size_text);
        try self.render(label, size_text);
    }
};

pub fn writePackageDetail(context: *runtime.RuntimeContext, package: StandardPackage) !void {
    const size_display = try format.loadSizeDisplay(context);
    var w = FieldWriter.init(context, "Optional Depends".len);

    try w.text("Name", package.name);
    try w.text("Repository", package.repository);
    try w.text("Version", package.version);
    try w.text("Description", package.description);
    try w.text("URL", package.url);

    try w.joined("Licenses", package.licenses);
    try w.joined("Groups", package.groups);
    try w.joined("Provides", package.provides);
    try w.joined("Depends On", package.depends);
    try w.joined("Optional Depends", package.optional_depends);
    try w.joined("Required By", package.required_by);
    try w.joined("Conflicts With", package.conflicts);
    try w.joined("Replaces", package.replaces);

    try w.installedSize("Download Size", size_display, package.download_size);
    try w.installedSize("Installed Size", size_display, package.installed_size);
    try w.date("Build Date", package.build_date);
    try w.optionalDate("Install Date", package.install_date, "Not Installed");
    try w.text("Install Reason", package.install_reason);
}

pub fn writeAurPackageDetail(context: *runtime.RuntimeContext, package: AurPackage) !void {
    var w = FieldWriter.init(context, "Optional Depends".len);

    try w.text("Name", package.name);
    try w.text("PackageBase", package.package_base);
    try w.text("Version", package.version);
    try w.optionalText("Description", package.description, "");
    try w.optionalText("URL", package.url, "");
    try w.optionalText("Maintainer", package.maintainer, "Orphaned");

    try w.int("Votes", package.num_votes);
    try w.float2("Popularity", package.popularity);
    try w.optionalDate("Out Of Date", package.out_of_date, "No");

    try w.optionalJoined("Licenses", package.licenses);
    try w.optionalJoined("Groups", package.groups);
    try w.optionalJoined("Provides", package.provides);
    try w.optionalJoined("Depends On", package.depends);
    try w.optionalJoined("Make Depends", package.make_depends);
    try w.optionalJoined("Optional Depends", package.optional_depends);
    try w.optionalJoined("Check Depends", package.check_depends);
    try w.optionalJoined("Conflicts With", package.conflicts);
    try w.optionalJoined("Replaces", package.replaces);
    try w.optionalJoined("Keywords", package.keywords);

    try w.date("First Submitted", package.first_submitted);
    try w.date("Last Modified", package.last_modified);
}

const test_field_label_width = "Optional Depends ".len;

fn expectField(rendered: []const u8, label: []const u8, value: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var len: usize = 0;
    @memcpy(buffer[len..][0..label.len], label);
    len += label.len;
    const pad = test_field_label_width -| label.len;
    if (pad > 0) {
        @memset(buffer[len..][0..pad], ' ');
        len += pad;
    }
    @memcpy(buffer[len..][0..2], ": ");
    len += 2;
    @memcpy(buffer[len..][0..value.len], value);
    len += value.len;
    const expected = buffer[0..len];
    if (std.mem.indexOf(u8, rendered, expected) == null) {
        std.debug.print("\nmissing field: '{s}'\nrendered:\n{s}\n", .{ expected, rendered });
        return error.TestExpectedField;
    }
}

fn detailTestContext(
    arena: *std.heap.ArenaAllocator,
    stdout: *std.Io.Writer.Allocating,
    stderr: *std.Io.Writer.Allocating,
) runtime.RuntimeContext {
    return .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
}

test "writePackageDetail aligns labels and renders every standard package field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context = detailTestContext(&arena, &stdout, &stderr);

    const package: StandardPackage = .{
        .name = "linux",
        .repository = "core",
        .version = "6.10.0-1",
        .description = "The Linux kernel",
        .url = "https://kernel.org",
        .licenses = &.{ "GPL2", "BSD" },
        .provides = &.{"kernel"},
        .depends = &.{ "coreutils", "glibc" },
        .download_size = 0,
        .installed_size = 1_048_576,
        .build_date = 0,
        .install_date = null,
        .install_reason = "Explicit",
    };

    try writePackageDetail(&context, package);
    const rendered = stdout.writer.buffered();

    // No environment is configured, so loadSizeDisplay falls back to megabytes.
    try expectField(rendered, "Name", "linux");
    try expectField(rendered, "Repository", "core");
    try expectField(rendered, "Version", "6.10.0-1");
    try expectField(rendered, "Description", "The Linux kernel");
    try expectField(rendered, "URL", "https://kernel.org");
    try expectField(rendered, "Licenses", "GPL2, BSD");
    try expectField(rendered, "Provides", "kernel");
    try expectField(rendered, "Depends On", "coreutils, glibc");
    try expectField(rendered, "Download Size", "0.00 MiB");
    try expectField(rendered, "Installed Size", "1.00 MiB");
    try expectField(rendered, "Build Date", "Thursday, January 1, 1970");
    try expectField(rendered, "Install Date", "Not Installed");
    try expectField(rendered, "Install Reason", "Explicit");
    // Test harness stdio is not a tty, so no ANSI escapes are emitted.
    try std.testing.expect(std.mem.indexOf(u8, rendered, colors.colorCode(.heading)) == null);
}

test "writePackageDetail renders empty list fields as None" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context = detailTestContext(&arena, &stdout, &stderr);

    // Only the required fields are populated; everything else defaults to
    // empty slices / null / "Unknown".
    try writePackageDetail(&context, .{ .name = "ghost", .version = "1.0" });
    const rendered = stdout.writer.buffered();

    try expectField(rendered, "Licenses", "None");
    try expectField(rendered, "Groups", "None");
    try expectField(rendered, "Provides", "None");
    try expectField(rendered, "Depends On", "None");
    try expectField(rendered, "Optional Depends", "None");
    try expectField(rendered, "Required By", "None");
    try expectField(rendered, "Conflicts With", "None");
    try expectField(rendered, "Replaces", "None");
    try expectField(rendered, "Install Date", "Not Installed");
    try expectField(rendered, "Install Reason", "Unknown");
}

test "writeAurPackageDetail aligns labels and renders populated AUR metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context = detailTestContext(&arena, &stdout, &stderr);

    const package: AurPackage = .{
        .name = "yay",
        .package_base = "yay",
        .version = "12.0.0",
        .description = "AUR helper",
        .url = "https://github.com/Jguer/yay",
        .maintainer = "jguer",
        .num_votes = 1000,
        .popularity = 95.5,
        .licenses = &.{"MIT"},
        .provides = &.{"yay"},
        .depends = &.{ "pacman", "git" },
        .keywords = &.{ "aur", "helper" },
        .first_submitted = 0,
        .last_modified = 1_600_000_000,
    };

    try writeAurPackageDetail(&context, package);
    const rendered = stdout.writer.buffered();

    try expectField(rendered, "Name", "yay");
    try expectField(rendered, "PackageBase", "yay");
    try expectField(rendered, "Version", "12.0.0");
    try expectField(rendered, "Description", "AUR helper");
    try expectField(rendered, "URL", "https://github.com/Jguer/yay");
    try expectField(rendered, "Maintainer", "jguer");
    try expectField(rendered, "Votes", "1000");
    try expectField(rendered, "Popularity", "95.50");
    try expectField(rendered, "Out Of Date", "No");
    try expectField(rendered, "Licenses", "MIT");
    try expectField(rendered, "Provides", "yay");
    try expectField(rendered, "Depends On", "pacman, git");
    try expectField(rendered, "Keywords", "aur, helper");
    try expectField(rendered, "First Submitted", "Thursday, January 1, 1970");
    try expectField(rendered, "Last Modified", "Sunday, September 13, 2020");
    // Null list fields fall through to the empty-list path and render as None.
    try expectField(rendered, "Groups", "None");
    try expectField(rendered, "Make Depends", "None");
    try expectField(rendered, "Optional Depends", "None");
    try expectField(rendered, "Check Depends", "None");
    try expectField(rendered, "Conflicts With", "None");
    try expectField(rendered, "Replaces", "None");
}

test "writeAurPackageDetail substitutes Orphaned, None and No for missing values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context = detailTestContext(&arena, &stdout, &stderr);

    // Only the required fields are set; every optional stays null/zero/empty.
    try writeAurPackageDetail(&context, .{ .name = "orphan", .version = "1.0" });
    const rendered = stdout.writer.buffered();

    try expectField(rendered, "Name", "orphan");
    try expectField(rendered, "PackageBase", "");
    try expectField(rendered, "Version", "1.0");
    try expectField(rendered, "Description", "");
    try expectField(rendered, "URL", "");
    try expectField(rendered, "Maintainer", "Orphaned");
    try expectField(rendered, "Votes", "0");
    try expectField(rendered, "Popularity", "0.00");
    try expectField(rendered, "Out Of Date", "No");
    try expectField(rendered, "Licenses", "None");
    try expectField(rendered, "Groups", "None");
    try expectField(rendered, "Keywords", "None");
}
