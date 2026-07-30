const std = @import("std");

const format = @import("format.zig");
const output = @import("config.zig");
const runtime = @import("../runtime/context.zig");

const StandardPackage = @import("../commands/search.zig").StandardPackage;
const AurPackage = @import("../commands/search.zig").AurPackage;

const line_color = "\x1b[38;2;0;0;255m";

const FieldWriter = struct {
    context: *runtime.RuntimeContext,

    pub fn init(context: *runtime.RuntimeContext) FieldWriter {
        return .{ .context = context };
    }

    pub fn text(self: *FieldWriter, label: []const u8, value: []const u8) !void {
        try coloredLine(self.context, label, value, line_color);
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
        const items_text = try format.joined(self.context.allocator, items);
        defer self.context.allocator.free(items_text);
        try self.text(label, items_text);
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
        try self.text(label, int_text);
    }

    pub fn float2(self: *FieldWriter, label: []const u8, value: f64) !void {
        const float_text = try std.fmt.allocPrint(self.context.allocator, "{d:.2}", .{value});
        defer self.context.allocator.free(float_text);
        try self.text(label, float_text);
    }

    pub fn date(self: *FieldWriter, label: []const u8, ts: i64) !void {
        const date_text = try format.formatLongDate(self.context.allocator, ts);
        defer self.context.allocator.free(date_text);
        try self.text(label, date_text);
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
        try self.text(label, size_text);
    }
};

pub fn writePackageDetail(context: *runtime.RuntimeContext, package: StandardPackage) !void {
    const size_display = try format.loadSizeDisplay(context);
    var w = FieldWriter.init(context);

    try w.text("Name", package.name);
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

    try w.installedSize("Installed Size", size_display, package.installed_size);
    try w.date("Build Date", package.build_date);
    try w.optionalDate("Install Date", package.install_date, "Not Installed");
    try w.text("Install Reason", package.install_reason);
}

pub fn writeAurPackageDetail(context: *runtime.RuntimeContext, package: AurPackage) !void {
    var w = FieldWriter.init(context);

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

fn coloredLine(
    context: *runtime.RuntimeContext,
    label: []const u8,
    value: []const u8,
    color: []const u8,
) !void {
    if (output.supportsAnsi(context))
        try context.stdout.print("{s}{s}\x1b[0m: {s}\n", .{ color, label, value })
    else
        try context.stdout.print("{s}: {s}\n", .{ label, value });
}
