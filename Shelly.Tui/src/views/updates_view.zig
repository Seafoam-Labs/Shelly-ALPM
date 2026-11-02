const std = @import("std");
const Border = @import("border.zig");
const commands = @import("../commands.zig");
const diagnostics = @import("diagnostics");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const sync = @import("../models/sync.zig");
const Allocator = std.mem.Allocator;

/// Borrows query results and the list widget; Model owns their lifetimes.
pub const View = struct {
    list: *vxfw.ScrollView,
    data: ?*const sync.CheckUpdates,
    loading: bool,
    failed: bool,
    checked: bool,
    flatpak_available: bool = false,
    flatpak_enabled: bool = true,
    aur_enabled: bool = true,

    /// A full upgrade synchronizes sources again, even when the cached check is empty.
    pub fn canUpgradeAll(self: View) bool {
        return !self.loading and !self.failed and self.data != null;
    }

    pub fn canUpgrade(self: View) bool {
        return !self.loading and !self.failed and self.data != null and self.data.?.Packages.len > 0;
    }

    pub fn canUpgradeAur(self: View) bool {
        return self.aur_enabled and !self.loading and !self.failed and self.data != null and self.data.?.Aur.len > 0;
    }

    pub fn canUpgradeFlatpak(self: View) bool {
        return self.flatpak_available and !self.loading and !self.failed and self.data != null and self.data.?.Flatpak.len > 0;
    }

    pub fn handleKey(self: View, key: vaxis.Key) ?commands.Updates {
        const action = commands.updates(key) orelse return null;
        if (action == .upgrade_all and !self.canUpgradeAll()) return null;
        if (action == .upgrade_system and !self.canUpgrade()) return null;
        if (action == .upgrade_aur and !self.canUpgradeAur()) return null;
        if (action == .upgrade_flatpak and !self.canUpgradeFlatpak()) return null;
        return action;
    }

    pub fn statusText(self: View, arena: Allocator) Allocator.Error![]const u8 {
        if (self.loading) return "Checking for updates…";
        if (self.failed) return "Update check failed";
        if (self.data) |data| return std.fmt.allocPrint(arena, "{d} updates — System: {d}, AUR: {d}, Flatpak: {d}", .{ data.count(), data.Packages.len, data.Aur.len, data.Flatpak.len });
        return "Updates have not been checked.";
    }

    pub fn appendContent(self: View, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface)) Allocator.Error!void {
        const size = ctx.max.size();
        const body = try ctx.arena.create(View);
        body.* = self;
        const content: vxfw.Widget = .{ .userdata = body, .drawFn = drawBody };
        const labels = [_]Border.BorderLabel{.{ .text = "Updates", .alignment = .top_left }};
        var border: Border = .{ .child = content, .labels = &labels, .style = .{ .fg = .{ .index = 7 }, .bold = true } };
        const height = size.height -| 2;
        try children.append(ctx.arena, .{
            .origin = .{ .row = 1, .col = 0 },
            .surface = if (size.width >= 2 and height >= 2)
                try border.draw(ctx.withConstraints(.{ .width = size.width, .height = height }, .{ .width = size.width, .height = height }))
            else
                try content.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = height })),
        });
    }

    fn drawBody(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *const View = @ptrCast(@alignCast(ptr));
        const size = ctx.max.size();
        const widget: vxfw.Widget = .{ .userdata = ptr, .drawFn = drawBody };
        if (size.width == 0 or size.height == 0) return .{ .size = size, .widget = widget, .buffer = &.{}, .children = &.{} };
        const message: ?[]const u8 = if (self.loading)
            "Checking for updates…"
        else if (self.failed)
            "Could not check for updates."
        else if (self.data != null)
            null
        else if (!self.checked)
            "Updates have not been checked."
        else
            "No update data received.";
        if (message) |text| {
            var label: vxfw.Text = .{ .text = text, .softwrap = true, .text_align = .center, .width_basis = .parent };
            return label.draw(ctx);
        }
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        var summary: vxfw.Text = .{ .text = try self.sourceSummary(ctx.arena), .text_align = .center, .width_basis = .parent, .softwrap = true, .style = .{ .fg = .{ .index = 7 }, .bold = true } };
        const summary_surface = try summary.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height }));
        try children.append(ctx.arena, .{ .origin = .{ .row = 0, .col = 0 }, .surface = summary_surface });
        var top = summary_surface.size.height;
        if (size.height >= 8) top += 1;
        const row_width = try tableWidth(ctx, self.data.?);
        const table_col = (size.width - row_width) / 2;
        const empty = self.data.?.count() == 0;
        if (empty and top < size.height) {
            var label: vxfw.Text = .{ .text = "No updates reported for checked sources.", .softwrap = true, .text_align = .center, .width_basis = .parent };
            try children.append(ctx.arena, .{
                .origin = .{ .row = @intCast(top), .col = 0 },
                .surface = try label.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height - top })),
            });
        }
        if (!empty and row_width >= table_min_width and top < size.height) {
            const heading = try drawColumns(ctx.withConstraints(.{}, .{ .width = row_width, .height = 1 }), .{ .source = "Source", .name = "Package", .current = "Upgrade", .available = "" }, true);
            try children.append(ctx.arena, .{ .origin = .{ .row = @intCast(top), .col = @intCast(table_col) }, .surface = heading });
            top += if (size.height >= 10) @as(u16, 2) else 1;
        }
        if (!empty and top < size.height) try children.append(ctx.arena, .{
            .origin = .{ .row = @intCast(top), .col = @intCast(table_col) },
            .surface = try self.list.draw(ctx.withConstraints(.{}, .{ .width = row_width, .height = size.height - top })),
        });
        return .{ .size = size, .widget = widget, .buffer = &.{}, .children = children.items };
    }

    pub fn sourceSummary(self: View, arena: Allocator) Allocator.Error![]const u8 {
        const data = self.data orelse return "";
        const aur = if (self.aur_enabled) try std.fmt.allocPrint(arena, " · AUR {d}", .{data.Aur.len}) else "";
        const flatpak = if (!self.flatpak_enabled) "" else if (self.flatpak_available) try std.fmt.allocPrint(arena, " · Flatpak {d}", .{data.Flatpak.len}) else " · Flatpak unavailable";
        return std.fmt.allocPrint(arena, "System {d}{s}{s} · AppImage {d}", .{ data.Packages.len, aur, flatpak, data.AppImage.len });
    }
};

pub fn row(data: *const sync.CheckUpdates, index: usize) ?vxfw.Widget {
    if (index < data.Packages.len) return .{ .userdata = @constCast(&data.Packages[index]), .drawFn = drawNative };
    const aur_index = index - data.Packages.len;
    if (aur_index < data.Aur.len) return .{ .userdata = @constCast(&data.Aur[aur_index]), .drawFn = if (aur_index == 0 and data.Packages.len > 0) groupStart(drawAur).draw else drawAur };
    const flatpak_index = aur_index - data.Aur.len;
    if (flatpak_index < data.Flatpak.len) return .{ .userdata = @constCast(&data.Flatpak[flatpak_index]), .drawFn = if (flatpak_index == 0 and data.Packages.len + data.Aur.len > 0) groupStart(drawFlatpak).draw else drawFlatpak };
    const appimage_index = flatpak_index - data.Flatpak.len;
    if (appimage_index < data.AppImage.len) return .{ .userdata = @constCast(&data.AppImage[appimage_index]), .drawFn = if (appimage_index == 0 and data.Packages.len + data.Aur.len + data.Flatpak.len > 0) groupStart(drawAppImage).draw else drawAppImage };
    return null;
}

/// One blank line separates sources; entries within each source stay compact.
fn groupStart(comptime drawItem: anytype) type {
    return struct {
        fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
            const gap: u16 = if (ctx.max.height == 0) 0 else 1;
            const content = try drawItem(ptr, ctx.withConstraints(.{ .width = ctx.min.width }, .{
                .width = ctx.max.width,
                .height = if (ctx.max.height) |height| height -| gap else null,
            }));
            const surface = try vxfw.Surface.init(ctx.arena, .{ .userdata = ptr, .drawFn = draw }, .{ .width = content.size.width, .height = content.size.height + gap });
            @memset(surface.buffer, .{});
            const offset = @as(usize, gap) * content.size.width;
            @memcpy(surface.buffer[offset..][0..content.buffer.len], content.buffer);
            return surface;
        }
    };
}

const table_min_width = 56;

fn tableWidth(ctx: vxfw.DrawContext, data: *const sync.CheckUpdates) Allocator.Error!u16 {
    var upgrade_width: usize = 0;
    for (data.Packages) |pkg| try measureUpgrade(ctx, &upgrade_width, version(pkg.CurrentVersion), version(pkg.NewVersion));
    for (data.Aur) |pkg| try measureUpgrade(ctx, &upgrade_width, version(pkg.Version), version(pkg.NewVersion));
    for (data.Flatpak) |pkg| try measureUpgrade(ctx, &upgrade_width, version(pkg.Version), flatpakVersion(&pkg));
    for (data.AppImage) |pkg| try measureUpgrade(ctx, &upgrade_width, "—", version(pkg.Version));
    const natural_width = 44 + @min(upgrade_width, 68);
    return @intCast(@min(ctx.max.width.?, @max(table_min_width, natural_width)));
}

fn measureUpgrade(ctx: vxfw.DrawContext, widest: *usize, current: []const u8, available: []const u8) Allocator.Error!void {
    const text = try std.fmt.allocPrint(ctx.arena, "{f} ---> {f}", .{ diagnostics.safe(current), diagnostics.safe(available) });
    widest.* = @max(widest.*, ctx.stringWidth(text));
}

fn flatpakVersion(pkg: *const sync.CheckUpdatesFlatpak) []const u8 {
    return if (pkg.NewVersion.len > 0) pkg.NewVersion else if (pkg.LatestCommit.len > 0) pkg.LatestCommit[0..@min(12, pkg.LatestCommit.len)] else "Update available";
}

const Entry = struct {
    source: []const u8,
    name: []const u8,
    current: []const u8,
    available: []const u8,
};

const ColumnRow = struct {
    entry: Entry,
    heading: bool,

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *const ColumnRow = @ptrCast(@alignCast(ptr));
        return drawColumns(ctx, self.entry, self.heading);
    }
};

/// Both the headings and rows use terminal-cell constraints, rather than byte padding.
fn drawColumns(ctx: vxfw.DrawContext, entry: Entry, heading: bool) Allocator.Error!vxfw.Surface {
    const width = ctx.max.width.?;
    const source_width = 14;
    const name_width = 28;
    const upgrade_width = width - source_width - name_width - 2;
    const widths = [_]u16{ source_width, name_width, upgrade_width };
    const upgrade = if (heading) entry.current else try std.fmt.allocPrint(ctx.arena, "{s} ---> {s}", .{ entry.current, entry.available });
    const values = [_][]const u8{ entry.source, entry.name, upgrade };
    const row_data = try ctx.arena.create(ColumnRow);
    row_data.* = .{ .entry = entry, .heading = heading };
    const surface = try vxfw.Surface.init(ctx.arena, .{ .userdata = row_data, .drawFn = ColumnRow.draw }, .{ .width = width, .height = @min(@as(u16, 1), ctx.max.height orelse 1) });
    @memset(surface.buffer, .{});
    if (surface.size.height == 0) return surface;
    var col: u16 = 0;
    for (values, widths, 0..) |value, cell_width, i| {
        var text: vxfw.Text = .{
            .text = try std.fmt.allocPrint(ctx.arena, "{f}", .{diagnostics.safe(value)}),
            .softwrap = false,
            .overflow = .ellipsis,
            .style = .{ .bold = heading or i == 1, .fg = .{ .index = if (heading or i == 0) 250 else 7 } },
        };
        const cell = try text.draw(ctx.withConstraints(.{}, .{ .width = cell_width, .height = 1 }));
        @memcpy(surface.buffer[col .. col + cell.size.width], cell.buffer);
        col += cell_width;
        if (i + 1 < values.len) col += 1;
    }
    return surface;
}

fn drawEntry(parent_ctx: vxfw.DrawContext, entry: Entry) Allocator.Error!vxfw.Surface {
    // ScrollView permits unbounded children. Keep this document at its viewport width.
    const width = parent_ctx.max.width orelse parent_ctx.min.width;
    const ctx = parent_ctx.withConstraints(.{}, .{ .width = width, .height = parent_ctx.max.height });
    if (ctx.max.width.? >= table_min_width) return drawColumns(ctx, entry, false);
    const spans = [_]vxfw.RichText.TextSpan{
        .{ .text = try std.fmt.allocPrint(ctx.arena, "{f}", .{diagnostics.safe(entry.name)}), .style = .{ .bold = true } },
        .{ .text = try std.fmt.allocPrint(ctx.arena, "  [{f}]\n", .{diagnostics.safe(entry.source)}), .style = .{ .fg = .{ .index = 250 } } },
        .{ .text = try std.fmt.allocPrint(ctx.arena, "{f} ---> {f}", .{ diagnostics.safe(entry.current), diagnostics.safe(entry.available) }) },
    };
    var text: vxfw.RichText = .{ .text = &spans, .softwrap = true };
    return text.draw(ctx);
}

fn version(value: []const u8) []const u8 {
    return if (value.len > 0) value else "—";
}

fn drawNative(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const pkg: *const sync.CheckUpdatesPackage = @ptrCast(@alignCast(ptr));
    return drawEntry(ctx, .{ .source = "System", .name = pkg.Name, .current = version(pkg.CurrentVersion), .available = version(pkg.NewVersion) });
}

fn drawAur(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const pkg: *const sync.CheckUpdatesAur = @ptrCast(@alignCast(ptr));
    return drawEntry(ctx, .{ .source = "AUR", .name = pkg.Name, .current = version(pkg.Version), .available = version(pkg.NewVersion) });
}

fn drawFlatpak(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const pkg: *const sync.CheckUpdatesFlatpak = @ptrCast(@alignCast(ptr));
    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(ctx.arena, if (pkg.Name.len > 0) pkg.Name else pkg.Id);
    // Preserve ref identity where multiple branches or remotes share an app ID.
    for ([_][]const u8{ pkg.Branch, pkg.Arch, pkg.Remote }) |part| if (part.len > 0) try parts.append(ctx.arena, part);
    return drawEntry(ctx, .{
        .source = if (pkg.InstallLevel == 0) "Flatpak:system" else "Flatpak:user",
        .name = try std.mem.join(ctx.arena, " · ", parts.items),
        .current = version(pkg.Version),
        .available = flatpakVersion(pkg),
    });
}

fn drawAppImage(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const pkg: *const @import("../models/appimage.zig").AppImageUpdate = @ptrCast(@alignCast(ptr));
    return drawEntry(ctx, .{ .source = "AppImage", .name = pkg.Name, .current = "—", .available = version(pkg.Version) });
}

fn surfaceText(arena: Allocator, surface: vxfw.Surface) Allocator.Error![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (surface.buffer) |cell| try text.appendSlice(arena, cell.char.grapheme);
    for (surface.children) |child| try text.appendSlice(arena, try surfaceText(arena, child.surface));
    return text.toOwnedSlice(arena);
}

test "update rows keep compact source and package columns with inline upgrades" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var data: sync.CheckUpdates = .{
        .Packages = @constCast(&[_]sync.CheckUpdatesPackage{.{ .Name = "native", .CurrentVersion = "1.0", .NewVersion = "2.0" }}),
        .Aur = @constCast(&[_]sync.CheckUpdatesAur{.{ .Name = "foreign", .Version = "1.0", .NewVersion = "2.0" }}),
        .Flatpak = @constCast(&[_]sync.CheckUpdatesFlatpak{.{ .Id = "org.example.App", .Version = "1.0", .NewVersion = "2.0", .InstallLevel = 1 }}),
    };
    for ([_]u16{ 56, 80, 160 }) |width| {
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = null }, .cell_size = .{ .width = 10, .height = 20 } };
        const heading = try drawColumns(ctx, .{ .source = "Source", .name = "Package", .current = "Upgrade", .available = "" }, true);
        try std.testing.expectEqualStrings("P", heading.buffer[15].char.grapheme);
        const upgrade_col = 44;
        try std.testing.expectEqualStrings("U", heading.buffer[upgrade_col].char.grapheme);
        for (0..3) |index| {
            const surface = try row(&data, index).?.draw(ctx);
            const gap: u16 = if (index == 0) 0 else 1;
            try std.testing.expectEqual(@as(u16, 1) + gap, surface.size.height);
            try std.testing.expectEqual(width, surface.size.width);
            const offset = @as(usize, gap) * width;
            try std.testing.expectEqualStrings("1", surface.buffer[offset + upgrade_col].char.grapheme);
            try std.testing.expect(surface.buffer[offset + 15].style.bold);
            if (gap > 0) for (surface.buffer[0..width]) |cell| try std.testing.expectEqualStrings(" ", cell.char.grapheme);
            try std.testing.expect(std.mem.indexOf(u8, try surfaceText(arena.allocator(), surface), "1.0 ---> 2.0") != null);
        }
        const flatpak_text = try surfaceText(arena.allocator(), try row(&data, 2).?.draw(ctx));
        try std.testing.expect(std.mem.indexOf(u8, flatpak_text, "Flatpak:user") != null);
    }
}

test "compact update rows retain scope versions and Flatpak ref metadata" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pkg: sync.CheckUpdatesFlatpak = .{ .Name = "Calculator", .Id = "org.gnome.Calculator", .Version = "49.0", .NewVersion = "49.1", .InstallLevel = 0, .Branch = "stable", .Arch = "x86_64", .Remote = "flathub" };
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = null }, .cell_size = .{ .width = 10, .height = 20 } };
    const surface = try drawFlatpak(&pkg, ctx);
    try std.testing.expect(surface.size.height > 1);
    const text = try surfaceText(arena.allocator(), surface);
    for ([_][]const u8{ "Calculator", "stable", "x86_64", "flathub", "Flatpak:system", "49.0", "49.1" }) |expected| try std.testing.expect(std.mem.indexOf(u8, text, expected) != null);
    pkg.NewVersion = "";
    pkg.LatestCommit = "123456789abcdef0123456789";
    const fallback = try surfaceText(arena.allocator(), try drawFlatpak(&pkg, ctx));
    try std.testing.expect(std.mem.indexOf(u8, fallback, "123456789abc") != null);
    try std.testing.expect(std.mem.indexOf(u8, fallback, "def0123456789") == null);
}

test "update source summary respects settings and backend availability" {
    var list: vxfw.ScrollView = .{ .children = .{ .slice = &.{} } };
    const data: sync.CheckUpdates = .{};
    var view: View = .{ .list = &list, .data = &data, .loading = false, .failed = false, .checked = true, .aur_enabled = false, .flatpak_enabled = false };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("System 0 · AppImage 0", try view.sourceSummary(arena.allocator()));
    view.aur_enabled = true;
    view.flatpak_enabled = true;
    try std.testing.expectEqualStrings("System 0 · AUR 0 · Flatpak unavailable · AppImage 0", try view.sourceSummary(arena.allocator()));
    view.flatpak_available = true;
    try std.testing.expectEqualStrings("System 0 · AUR 0 · Flatpak 0 · AppImage 0", try view.sourceSummary(arena.allocator()));
}

test "updates panel centers its table below counts and retains empty source status" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var list: vxfw.ScrollView = .{ .children = .{ .slice = &.{} } };
    var data: sync.CheckUpdates = .{ .Packages = @constCast(&[_]sync.CheckUpdatesPackage{.{ .Name = "native" }}) };
    var view: View = .{ .list = &list, .data = &data, .loading = false, .failed = false, .checked = true, .aur_enabled = false, .flatpak_enabled = true };
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 20 }, .cell_size = .{ .width = 10, .height = 20 } };
    const body = try View.drawBody(&view, ctx);
    try std.testing.expectEqual(@as(usize, 3), body.children.len);
    const summary = body.children[0].surface;
    try std.testing.expectEqual(@as(u16, 80), summary.size.width);
    var first: ?usize = null;
    var last: usize = 0;
    for (summary.buffer, 0..) |cell, index| {
        if (std.mem.trim(u8, cell.char.grapheme, " ").len == 0) continue;
        if (first == null) first = index;
        last = index;
    }
    const trailing = summary.size.width - last - 1;
    try std.testing.expect(first.? == trailing or first.? + 1 == trailing or trailing + 1 == first.?);
    try std.testing.expectEqual(@as(i17, 12), body.children[1].origin.col);
    try std.testing.expectEqual(@as(u16, 56), body.children[1].surface.size.width);
    try std.testing.expect(body.children[1].origin.row > body.children[0].origin.row);
    const wide_ctx = ctx.withConstraints(.{}, .{ .width = 160, .height = 20 });
    const wide = try View.drawBody(&view, wide_ctx);
    try std.testing.expectEqual(@as(i17, 52), wide.children[1].origin.col);
    try std.testing.expectEqual(wide.children[1].origin.col, wide.children[2].origin.col);
    try std.testing.expectEqual(@as(u16, 56), wide.children[2].surface.size.width);
    data.Packages = @constCast(&[_]sync.CheckUpdatesPackage{.{ .Name = "dotnet-runtime", .CurrentVersion = "10.0.13.sdk113-1", .NewVersion = "10.0.14.sdk114-1" }});
    const measured = try View.drawBody(&view, wide_ctx);
    const table = measured.children[2];
    const entry = try row(&data, 0).?.draw(wide_ctx.withConstraints(.{}, .{ .width = table.surface.size.width, .height = null }));
    var visible_width: usize = 0;
    for (entry.buffer[0..entry.size.width], 0..) |cell, index| {
        if (std.mem.trim(u8, cell.char.grapheme, " ").len > 0) visible_width = index + 1;
    }
    try std.testing.expectEqual(@as(usize, entry.size.width), visible_width);
    try std.testing.expectEqual(@as(i17, @intCast((160 - visible_width) / 2)), table.origin.col);
    data.Packages = &.{};
    const empty_text = try surfaceText(arena.allocator(), try View.drawBody(&view, ctx));
    try std.testing.expect(std.mem.indexOf(u8, empty_text, "Flatpak unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_text, "No updates reported for checked sources.") != null);
    view.failed = true;
    const failure_text = try surfaceText(arena.allocator(), try View.drawBody(&view, ctx));
    try std.testing.expect(std.mem.indexOf(u8, failure_text, "Could not check for updates.") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure_text, "No updates reported") == null);
}
