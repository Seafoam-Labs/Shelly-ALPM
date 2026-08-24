const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gdk = bindings.gdk;
const gobject = bindings.gobject;
const package_page_module = @import("pages/package_page.zig");
const PackagePage = package_page_module.PackagePage;
const FlatpakPage = @import("pages/flatpak/flatpak_page.zig").FlatpakPage;
const FlatpakInstallView = @import("pages/flatpak/flatpak_install_view.zig").FlatpakInstallView;
const AppstreamAppObject = @import("g_objects/appstream_app_object.zig").AppstreamAppObject;
const AurPage = @import("pages/aur_page.zig").AurPage;
const AppImagePage = @import("pages/appimage_page.zig").AppImagePage;
const RecommendPage = @import("pages/recommend_page.zig").RecommendPage;
const PackageDetail = @import("pages/package_detail.zig").PackageDetail;
const AurPackageDetail = @import("pages/aur_package_detail.zig").PackageDetail;
const AurPackage = @import("models/aur_package.zig").AurPackage;
const version_history = @import("dialog/page/version_history.zig");
const VersionHistoryDialog = version_history.VersionHistoryDialog;
const PermissionsDialog = @import("dialog/page/permissions.zig").PermissionsDialog;
const PkgbuildReviewDialog = @import("dialog/page/pkg_build.zig").PkgbuildReviewDialog;
const PkgbuildPreviewDialog = @import("dialog/page/preview_pkgbuild.zig").PkgbuildReviewDialog;
const MultiSelectDialog = @import("dialog/page/multiselect.zig").MultiSelectDialog;
const package_toolbar_layout = @import("helpers/package_toolbar_layout.zig");

fn findByCssClass(widget: *gtk.Widget, class_name: [:0]const u8) ?*gtk.Widget {
    if (gtk.Widget.hasCssClass(widget, class_name) != 0) return widget;

    var child = gtk.Widget.getFirstChild(widget);
    while (child) |current| : (child = gtk.Widget.getNextSibling(current)) {
        if (findByCssClass(current, class_name)) |match| return match;
    }
    return null;
}

fn findFirstMenuButton(widget: *gtk.Widget) ?*gtk.Widget {
    if (gobject.ext.cast(gtk.MenuButton, widget) != null) return widget;

    var child = gtk.Widget.getFirstChild(widget);
    while (child) |current| : (child = gtk.Widget.getNextSibling(current)) {
        if (findFirstMenuButton(current)) |match| return match;
    }
    return null;
}

fn findFirstFrame(widget: *gtk.Widget) ?*gtk.Frame {
    if (gobject.ext.cast(gtk.Frame, widget)) |frame| return frame;

    var child = gtk.Widget.getFirstChild(widget);
    while (child) |current| : (child = gtk.Widget.getNextSibling(current)) {
        if (findFirstFrame(current)) |match| return match;
    }
    return null;
}

fn findFirstScrolledWindow(widget: *gtk.Widget) ?*gtk.ScrolledWindow {
    if (gobject.ext.cast(gtk.ScrolledWindow, widget)) |scroller| return scroller;

    var child = gtk.Widget.getFirstChild(widget);
    while (child) |current| : (child = gtk.Widget.getNextSibling(current)) {
        if (findFirstScrolledWindow(current)) |match| return match;
    }
    return null;
}

fn findFirstStack(widget: *gtk.Widget) ?*gtk.Stack {
    if (gobject.ext.cast(gtk.Stack, widget)) |stack| return stack;

    var child = gtk.Widget.getFirstChild(widget);
    while (child) |current| : (child = gtk.Widget.getNextSibling(current)) {
        if (findFirstStack(current)) |match| return match;
    }
    return null;
}

fn findFirstRevealer(widget: *gtk.Widget) ?*gtk.Revealer {
    if (gobject.ext.cast(gtk.Revealer, widget)) |revealer| return revealer;

    var child = gtk.Widget.getFirstChild(widget);
    while (child) |current| : (child = gtk.Widget.getNextSibling(current)) {
        if (findFirstRevealer(current)) |match| return match;
    }
    return null;
}

fn expectOnlyConceptToolbar() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const page = PackagePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();

    const toolbar = findByCssClass(page.as(gtk.Widget), "package-toolbar-concept") orelse
        return error.ConceptToolbarMissing;
    try std.testing.expect(gtk.Widget.hasCssClass(toolbar, "compact-search-zone") != 0);
    try std.testing.expect(gtk.Widget.hasCssClass(toolbar, "page-toolbar") == 0);
    try std.testing.expect(findByCssClass(page.as(gtk.Widget), "package-toolbar-legacy") == null);
}

fn expectAuxiliarySearchZonesHaveNoCardBackground() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const aur_page = AurPage.new();
    _ = aur_page.as(gobject.Object).refSink();
    defer aur_page.as(gobject.Object).unref();

    const appimage_page = AppImagePage.new();
    _ = appimage_page.as(gobject.Object).refSink();
    defer appimage_page.as(gobject.Object).unref();

    for ([_]*gtk.Widget{ aur_page.as(gtk.Widget), appimage_page.as(gtk.Widget) }) |page| {
        const search_zone = findByCssClass(page, "compact-search-zone") orelse
            return error.CompactSearchZoneMissing;
        try std.testing.expect(gtk.Widget.hasCssClass(search_zone, "page-toolbar") == 0);
    }
}

fn expectAurKebabMatchesPackageKebab() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const package_page = PackagePage.new();
    _ = package_page.as(gobject.Object).refSink();
    defer package_page.as(gobject.Object).unref();

    const aur_page = AurPage.new();
    _ = aur_page.as(gobject.Object).refSink();
    defer aur_page.as(gobject.Object).unref();

    const package_kebab = findByCssClass(package_page.as(gtk.Widget), "package-options-button-concept") orelse
        return error.PackageKebabMissing;
    const aur_kebab = findFirstMenuButton(aur_page.as(gtk.Widget)) orelse
        return error.AurKebabMissing;

    try std.testing.expect(gtk.Widget.hasCssClass(aur_kebab, "package-options-button-concept") != 0);

    var package_width: c_int = 0;
    var package_height: c_int = 0;
    var aur_width: c_int = 0;
    var aur_height: c_int = 0;
    gtk.Widget.measure(package_kebab, .horizontal, -1, &package_width, null, null, null);
    gtk.Widget.measure(package_kebab, .vertical, -1, &package_height, null, null, null);
    gtk.Widget.measure(aur_kebab, .horizontal, -1, &aur_width, null, null, null);
    gtk.Widget.measure(aur_kebab, .vertical, -1, &aur_height, null, null, null);
    try std.testing.expectEqual(package_width, aur_width);
    try std.testing.expectEqual(package_height, aur_height);
}

fn expectSearchEntriesShareCompactHeight() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;
    const display = gdk.Display.getDefault() orelse return error.GtkUnavailable;

    const base_provider = gtk.CssProvider.new();
    defer base_provider.unref();
    gtk.CssProvider.loadFromString(base_provider, @embedFile("themes/style.css"));
    gtk.StyleContext.addProviderForDisplay(
        display,
        base_provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    defer gtk.StyleContext.removeProviderForDisplay(display, base_provider.as(gtk.StyleProvider));

    const package_page = PackagePage.new();
    _ = package_page.as(gobject.Object).refSink();
    defer package_page.as(gobject.Object).unref();

    const aur_page = AurPage.new();
    _ = aur_page.as(gobject.Object).refSink();
    defer aur_page.as(gobject.Object).unref();

    const flatpak_page = FlatpakPage.new();
    _ = flatpak_page.as(gobject.Object).refSink();
    defer flatpak_page.as(gobject.Object).unref();

    const appimage_page = AppImagePage.new();
    _ = appimage_page.as(gobject.Object).refSink();
    defer appimage_page.as(gobject.Object).unref();

    const searches = [_]*gtk.Widget{
        findByCssClass(package_page.as(gtk.Widget), "package-search-concept") orelse
            return error.PackageSearchMissing,
        findByCssClass(aur_page.as(gtk.Widget), "spaced-search") orelse
            return error.AurSearchMissing,
        findByCssClass(flatpak_page.as(gtk.Widget), "flatpak-sidebar-search") orelse
            return error.FlatpakSearchMissing,
        findByCssClass(appimage_page.as(gtk.Widget), "spaced-search") orelse
            return error.AppImageSearchMissing,
    };

    var expected_height: c_int = 0;
    gtk.Widget.measure(searches[0], .vertical, -1, &expected_height, null, null, null);
    for (searches[1..]) |search| {
        var height: c_int = 0;
        gtk.Widget.measure(search, .vertical, -1, &height, null, null, null);
        try std.testing.expectEqual(expected_height, height);
    }

    var package_search_width: c_int = 0;
    gtk.Widget.measure(searches[0], .horizontal, -1, &package_search_width, null, null, null);
    for ([_]usize{ 1, 3 }) |index| {
        var search_width: c_int = 0;
        gtk.Widget.measure(searches[index], .horizontal, -1, &search_width, null, null, null);
        try std.testing.expectEqual(package_search_width, search_width);
        try std.testing.expectEqual(
            gtk.Widget.getHexpand(searches[0]),
            gtk.Widget.getHexpand(searches[index]),
        );
    }
}

fn expectRecommendedContentUsesFullWidth() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;
    const display = gdk.Display.getDefault() orelse return error.GtkUnavailable;

    const base_provider = gtk.CssProvider.new();
    defer base_provider.unref();
    gtk.CssProvider.loadFromString(base_provider, @embedFile("themes/style.css"));
    gtk.StyleContext.addProviderForDisplay(
        display,
        base_provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    defer gtk.StyleContext.removeProviderForDisplay(display, base_provider.as(gtk.StyleProvider));

    const page = RecommendPage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();

    const header = gtk.Widget.getFirstChild(page.as(gtk.Widget)) orelse
        return error.RecommendedHeaderMissing;
    gtk.Widget.allocate(page.as(gtk.Widget), 1000, 600, -1, null);

    try std.testing.expectEqual(@as(c_int, 980), gtk.Widget.getWidth(page.as(gtk.Widget)));
    try std.testing.expectEqual(@as(c_int, 980), gtk.Widget.getWidth(header));
}

fn expectDetailPanelsUseNaturalWidth() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const package_detail = PackageDetail.new();
    _ = package_detail.as(gobject.Object).refSink();
    defer package_detail.as(gobject.Object).unref();

    const aur_detail = AurPackageDetail.new();
    _ = aur_detail.as(gobject.Object).refSink();
    defer aur_detail.as(gobject.Object).unref();

    for ([_]*gtk.Widget{ package_detail.as(gtk.Widget), aur_detail.as(gtk.Widget) }) |detail| {
        var width_request: c_int = 0;
        gtk.Widget.getSizeRequest(detail, &width_request, null);
        try std.testing.expectEqual(@as(c_int, -1), width_request);

        const scroller_widget = gtk.Widget.getFirstChild(detail) orelse
            return error.DetailScrollerMissing;
        const scroller = gobject.ext.cast(gtk.ScrolledWindow, scroller_widget) orelse
            return error.DetailScrollerHasWrongType;
        try std.testing.expect(gtk.ScrolledWindow.getPropagateNaturalWidth(scroller) != 0);
    }
}

fn expectDetailPanelsMatchPageBottomAndRightSpacing() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const package_page = PackagePage.new();
    _ = package_page.as(gobject.Object).refSink();
    defer package_page.as(gobject.Object).unref();

    const aur_page = AurPage.new();
    _ = aur_page.as(gobject.Object).refSink();
    defer aur_page.as(gobject.Object).unref();

    for ([_]*gtk.Widget{ package_page.as(gtk.Widget), aur_page.as(gtk.Widget) }) |page| {
        const detail_revealer = findFirstRevealer(page) orelse return error.DetailRevealerMissing;
        const bottom_spacing = gtk.Widget.getMarginBottom(page);

        try std.testing.expect(bottom_spacing > 0);
        try std.testing.expectEqual(bottom_spacing, gtk.Widget.getMarginEnd(detail_revealer.as(gtk.Widget)));
    }
}

fn expectPackageLoadingUsesFrameSizedBatches() !void {
    try std.testing.expectEqual(@as(usize, 64), package_page_module.nextLoadBatchEnd(0, 1000));
    try std.testing.expectEqual(@as(usize, 128), package_page_module.nextLoadBatchEnd(64, 1000));
    try std.testing.expectEqual(@as(usize, 1000), package_page_module.nextLoadBatchEnd(992, 1000));
    try std.testing.expectEqual(@as(usize, 1000), package_page_module.nextLoadBatchEnd(1000, 1000));
}

fn expectPackageLoadingDetailKeepsReadableWidth() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const detail = PackageDetail.new();
    _ = detail.as(gobject.Object).refSink();
    defer detail.as(gobject.Object).unref();

    const description_widget = findByCssClass(detail.as(gtk.Widget), "dim-label") orelse
        return error.DetailDescriptionMissing;
    const description = gobject.ext.cast(gtk.Label, description_widget) orelse
        return error.DetailDescriptionHasWrongType;

    try std.testing.expectEqual(@as(c_int, 32), gtk.Label.getWidthChars(description));
}

fn expectDetailValuesUseReadableRows() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const detail = AurPackageDetail.new();
    _ = detail.as(gobject.Object).refSink();
    defer detail.as(gobject.Object).unref();

    const licenses = [_][:0]const u8{"GPL-3.0-or-later"};
    const package: AurPackage = .{
        .Id = 1,
        .Name = "example-package",
        .PackageBaseId = 1,
        .PackageBase = "example-package",
        .Version = "1.0.0-1",
        .Description = "A long package description used to verify readable detail rows",
        .Url = "https://example.com/packages/example-package",
        .NumVotes = 42,
        .Popularity = 1.25,
        .Maintainer = "example-maintainer",
        .FirstSubmitted = 1_700_000_000,
        .LastModified = 1_710_000_000,
        .UrlPath = "/cgit/aur.git/snapshot/example-package.tar.gz",
        .License = &licenses,
    };
    detail.showPackage(&package);

    const row_widget = findByCssClass(detail.as(gtk.Widget), "spec-row") orelse
        return error.DetailSpecRowMissing;
    const row = gobject.ext.cast(gtk.Box, row_widget) orelse
        return error.DetailSpecRowHasWrongType;
    try std.testing.expectEqual(
        gtk.Orientation.vertical,
        gtk.Orientable.getOrientation(row.as(gtk.Orientable)),
    );

    const key_widget = gtk.Widget.getFirstChild(row_widget) orelse
        return error.DetailSpecKeyMissing;
    const value_widget = gtk.Widget.getNextSibling(key_widget) orelse
        return error.DetailSpecValueMissing;
    const value = gobject.ext.cast(gtk.Label, value_widget) orelse
        return error.DetailSpecValueHasWrongType;

    try std.testing.expect(gtk.Label.getWrap(value) != 0);
    try std.testing.expect(gtk.Label.getSelectable(value) != 0);
    try std.testing.expectEqual(bindings.pango.EllipsizeMode.none, gtk.Label.getEllipsize(value));
    try std.testing.expectEqual(gtk.Align.fill, gtk.Widget.getHalign(value_widget));
    try std.testing.expectEqual(@as(f32, 0), gtk.Label.getXalign(value));
}

fn expectFlatpakSearchFollowsCategoryWidth() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const page = FlatpakPage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();

    const search = findByCssClass(page.as(gtk.Widget), "flatpak-sidebar-search") orelse
        return error.FlatpakSidebarSearchMissing;
    const categories = findByCssClass(page.as(gtk.Widget), "flatpak-category-list") orelse
        return error.FlatpakCategoryListMissing;

    var search_minimum_width: c_int = 0;
    var category_minimum_width: c_int = 0;
    gtk.Widget.measure(search, .horizontal, -1, &search_minimum_width, null, null, null);
    gtk.Widget.measure(categories, .horizontal, -1, &category_minimum_width, null, null, null);

    try std.testing.expect(gtk.Widget.getHexpand(search) != 0);
    try std.testing.expect(search_minimum_width <= category_minimum_width);
}

fn expectFlatpakPermissionsActionIsImmediatelyAvailable() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const view = FlatpakInstallView.new();
    _ = view.as(gobject.Object).refSink();
    defer view.as(gobject.Object).unref();

    const app = try AppstreamAppObject.new(.{
        .Id = "org.example.Application",
        .Name = "Example Application",
    });
    defer app.as(gobject.Object).unref();

    view.showDetails(app);
    const permissions_action = findByCssClass(view.as(gtk.Widget), "flatpak-permissions-action") orelse
        return error.FlatpakPermissionsActionMissing;
    try std.testing.expect(gtk.Widget.getSensitive(permissions_action) != 0);
}

fn expectNoFixedWidthRequests(widget: *gtk.Widget) !void {
    var width_request: c_int = 0;
    gtk.Widget.getSizeRequest(widget, &width_request, null);
    try std.testing.expect(width_request <= 0);

    var child = gtk.Widget.getFirstChild(widget);
    while (child) |current| : (child = gtk.Widget.getNextSibling(current)) {
        try expectNoFixedWidthRequests(current);
    }
}

fn expectAppImageDetailUsesAvailableWidth() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const page = AppImagePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();

    const detail_object = gtk.Widget.getTemplateChild(
        page.as(gtk.Widget),
        AppImagePage.getGObjectType(),
        "AppImageDetailView",
    );
    const detail = gobject.ext.cast(gtk.ScrolledWindow, detail_object) orelse
        return error.AppImageDetailViewMissing;
    const content = gtk.ScrolledWindow.getChild(detail) orelse
        return error.AppImageDetailContentMissing;

    try expectNoFixedWidthRequests(content);
}

fn expectAppImageDetailAdaptsToAvailableWidth() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const page = AppImagePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();

    const header_widget = findByCssClass(page.as(gtk.Widget), "appimage-detail-header") orelse
        return error.AppImageDetailHeaderMissing;
    const columns_widget = findByCssClass(page.as(gtk.Widget), "appimage-detail-columns") orelse
        return error.AppImageDetailColumnsMissing;
    const actions_widget = findByCssClass(page.as(gtk.Widget), "appimage-detail-actions") orelse
        return error.AppImageDetailActionsMissing;
    const content = findByCssClass(page.as(gtk.Widget), "appimage-detail-content") orelse
        return error.AppImageDetailContentMissing;
    const header = gobject.ext.cast(gtk.Box, header_widget) orelse
        return error.AppImageDetailHeaderInvalid;
    const columns = gobject.ext.cast(gtk.Box, columns_widget) orelse
        return error.AppImageDetailColumnsInvalid;
    const actions = gobject.ext.cast(gtk.Box, actions_widget) orelse
        return error.AppImageDetailActionsInvalid;

    page.applyDetailLayout(700);
    try std.testing.expectEqual(
        gtk.Orientation.vertical,
        gtk.Orientable.getOrientation(header.as(gtk.Orientable)),
    );
    try std.testing.expectEqual(
        gtk.Orientation.vertical,
        gtk.Orientable.getOrientation(columns.as(gtk.Orientable)),
    );

    page.applyDetailLayout(300);
    try std.testing.expectEqual(
        gtk.Orientation.vertical,
        gtk.Orientable.getOrientation(actions.as(gtk.Orientable)),
    );

    page.applyDetailLayout(450);
    var narrow_minimum_width: c_int = 0;
    gtk.Widget.measure(content, .horizontal, -1, &narrow_minimum_width, null, null, null);
    try std.testing.expect(narrow_minimum_width <= 450);

    for ([_]c_int{ 1280, 1920, 3840 }) |width| {
        page.applyDetailLayout(width);
        try std.testing.expectEqual(
            gtk.Orientation.horizontal,
            gtk.Orientable.getOrientation(header.as(gtk.Orientable)),
        );
        try std.testing.expectEqual(
            gtk.Orientation.horizontal,
            gtk.Orientable.getOrientation(columns.as(gtk.Orientable)),
        );
        try std.testing.expectEqual(
            gtk.Orientation.horizontal,
            gtk.Orientable.getOrientation(actions.as(gtk.Orientable)),
        );
    }
}

fn expectVersionHistoryTracksAvailableWindowSize() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const entries = try std.heap.c_allocator.alloc(version_history.Entry, 0);
    const dialog = VersionHistoryDialog.new("Version History", "Example", entries, &struct {
        fn close(_: ?*anyopaque) void {}
    }.close, null);
    _ = dialog.as(gobject.Object).refSink();
    defer dialog.as(gobject.Object).unref();

    const frame = findFirstFrame(dialog.as(gtk.Widget)) orelse
        return error.VersionHistoryFrameMissing;
    const scroller = findFirstScrolledWindow(dialog.as(gtk.Widget)) orelse
        return error.VersionHistoryScrollerMissing;

    var width: c_int = 0;
    var height: c_int = 0;
    const cases = [_]struct {
        available_width: c_int,
        available_height: c_int,
        expected_width: c_int,
        expected_height: c_int,
    }{
        .{ .available_width = 700, .available_height = 450, .expected_width = 525, .expected_height = 337 },
        .{ .available_width = 1280, .available_height = 720, .expected_width = 960, .expected_height = 540 },
        .{ .available_width = 1920, .available_height = 1080, .expected_width = 1440, .expected_height = 810 },
        .{ .available_width = 3840, .available_height = 2160, .expected_width = 2880, .expected_height = 1620 },
    };
    for (cases) |case| {
        dialog.applyAvailableSize(case.available_width, case.available_height);
        gtk.Widget.getSizeRequest(frame.as(gtk.Widget), &width, &height);
        try std.testing.expectEqual(case.expected_width, width);
        try std.testing.expectEqual(case.expected_height, height);
    }

    try std.testing.expect(gtk.Widget.getHexpand(scroller.as(gtk.Widget)) != 0);
    try std.testing.expect(gtk.Widget.getVexpand(scroller.as(gtk.Widget)) != 0);
}

fn expectPermissionsTracksAvailableWindowSize() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const permissions = [_][:0]const u8{
        "Context=filesystems:home",
        "Context=sockets:wayland",
    };
    const dialog = PermissionsDialog.new("Permissions", "Example", &permissions, &struct {
        fn close(_: ?*anyopaque) void {}
    }.close, null);
    _ = dialog.as(gobject.Object).refSink();
    defer dialog.as(gobject.Object).unref();

    const frame = findFirstFrame(dialog.as(gtk.Widget)) orelse
        return error.PermissionsFrameMissing;
    const scroller = findFirstScrolledWindow(dialog.as(gtk.Widget)) orelse
        return error.PermissionsScrollerMissing;

    var width: c_int = 0;
    var height: c_int = 0;
    const cases = [_]struct {
        available_width: c_int,
        available_height: c_int,
        expected_width: c_int,
        expected_height: c_int,
    }{
        .{ .available_width = 700, .available_height = 450, .expected_width = 525, .expected_height = 337 },
        .{ .available_width = 1280, .available_height = 720, .expected_width = 960, .expected_height = 540 },
        .{ .available_width = 1920, .available_height = 1080, .expected_width = 1440, .expected_height = 810 },
        .{ .available_width = 3840, .available_height = 2160, .expected_width = 2880, .expected_height = 1620 },
    };
    for (cases) |case| {
        dialog.applyAvailableSize(case.available_width, case.available_height);
        gtk.Widget.getSizeRequest(frame.as(gtk.Widget), &width, &height);
        try std.testing.expectEqual(case.expected_width, width);
        try std.testing.expectEqual(case.expected_height, height);
    }

    try std.testing.expect(gtk.Widget.getHexpand(scroller.as(gtk.Widget)) != 0);
    try std.testing.expect(gtk.Widget.getVexpand(scroller.as(gtk.Widget)) != 0);
}

fn expectPermissionsDialogUpdatesLoadingStateInPlace() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const dialog = PermissionsDialog.new("Permissions", "Example", &.{}, &struct {
        fn close(_: ?*anyopaque) void {}
    }.close, null);
    _ = dialog.as(gobject.Object).refSink();
    defer dialog.as(gobject.Object).unref();

    const stack = findFirstStack(dialog.as(gtk.Widget)) orelse
        return error.PermissionsStackMissing;

    dialog.showLoading();
    const loading_page = gtk.Stack.getVisibleChildName(stack) orelse
        return error.PermissionsLoadingPageMissing;
    try std.testing.expectEqualStrings("loading", std.mem.span(loading_page));

    const permissions = [_][:0]const u8{
        "Context=filesystems:home",
        "Context=sockets:wayland",
    };
    dialog.setPermissions(&permissions);
    const list_page = gtk.Stack.getVisibleChildName(stack) orelse
        return error.PermissionsListPageMissing;
    try std.testing.expectEqualStrings("list", std.mem.span(list_page));
}

fn expectPermissionsDialogStopsLoadingOnError() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const dialog = PermissionsDialog.new("Permissions", "Example", &.{}, &struct {
        fn close(_: ?*anyopaque) void {}
    }.close, null);
    _ = dialog.as(gobject.Object).refSink();
    defer dialog.as(gobject.Object).unref();

    const stack = findFirstStack(dialog.as(gtk.Widget)) orelse
        return error.PermissionsStackMissing;

    dialog.showLoading();
    dialog.showLoadError();
    const error_page = gtk.Stack.getVisibleChildName(stack) orelse
        return error.PermissionsErrorPageMissing;
    try std.testing.expectEqualStrings("error", std.mem.span(error_page));
}

fn expectPkgbuildReviewTracksAvailableWindowSize() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const dialog = gobject.ext.newInstance(PkgbuildReviewDialog, .{});
    _ = dialog.as(gobject.Object).refSink();
    defer dialog.as(gobject.Object).unref();

    var width: c_int = 0;
    var height: c_int = 0;
    const cases = [_]struct {
        available_width: c_int,
        available_height: c_int,
        expected_width: c_int,
        expected_height: c_int,
    }{
        .{ .available_width = 700, .available_height = 450, .expected_width = 525, .expected_height = 337 },
        .{ .available_width = 1280, .available_height = 720, .expected_width = 960, .expected_height = 540 },
        .{ .available_width = 1920, .available_height = 1080, .expected_width = 1440, .expected_height = 810 },
        .{ .available_width = 3840, .available_height = 2160, .expected_width = 2880, .expected_height = 1620 },
    };
    for (cases) |case| {
        dialog.applyAvailableSize(case.available_width, case.available_height);
        gtk.Window.getDefaultSize(dialog.as(gtk.Window), &width, &height);
        try std.testing.expectEqual(case.expected_width, width);
        try std.testing.expectEqual(case.expected_height, height);
    }
}

fn expectPkgbuildPreviewTracksAvailableWindowSize() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const dialog = PkgbuildPreviewDialog.new();
    _ = dialog.as(gobject.Object).refSink();
    defer dialog.as(gobject.Object).unref();

    var width: c_int = 0;
    var height: c_int = 0;
    const cases = [_]struct {
        available_width: c_int,
        available_height: c_int,
        expected_width: c_int,
        expected_height: c_int,
    }{
        .{ .available_width = 700, .available_height = 450, .expected_width = 525, .expected_height = 337 },
        .{ .available_width = 1280, .available_height = 720, .expected_width = 960, .expected_height = 540 },
        .{ .available_width = 1920, .available_height = 1080, .expected_width = 1440, .expected_height = 810 },
        .{ .available_width = 3840, .available_height = 2160, .expected_width = 2880, .expected_height = 1620 },
    };
    for (cases) |case| {
        dialog.applyAvailableSize(case.available_width, case.available_height);
        gtk.Window.getDefaultSize(dialog.as(gtk.Window), &width, &height);
        try std.testing.expectEqual(case.expected_width, width);
        try std.testing.expectEqual(case.expected_height, height);
    }
}

fn expectMultiSelectTracksAvailableWindowSize() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;

    const dialog = MultiSelectDialog.new(std.heap.c_allocator, "Select optional dependencies", &.{}, &struct {
        fn respond(_: ?*anyopaque, _: bool, _: []const usize) void {}
    }.respond, null);
    _ = dialog.as(gobject.Object).refSink();
    defer dialog.as(gobject.Object).unref();

    const frame = findFirstFrame(dialog.as(gtk.Widget)) orelse
        return error.MultiSelectFrameMissing;
    const scroller = findFirstScrolledWindow(dialog.as(gtk.Widget)) orelse
        return error.MultiSelectScrollerMissing;

    var width: c_int = 0;
    var height: c_int = 0;
    const cases = [_]struct {
        available_width: c_int,
        available_height: c_int,
        expected_width: c_int,
        expected_height: c_int,
    }{
        .{ .available_width = 700, .available_height = 450, .expected_width = 525, .expected_height = 337 },
        .{ .available_width = 1280, .available_height = 720, .expected_width = 960, .expected_height = 540 },
        .{ .available_width = 1920, .available_height = 1080, .expected_width = 1440, .expected_height = 810 },
        .{ .available_width = 3840, .available_height = 2160, .expected_width = 2880, .expected_height = 1620 },
    };
    for (cases) |case| {
        dialog.applyAvailableSize(case.available_width, case.available_height);
        gtk.Widget.getSizeRequest(frame.as(gtk.Widget), &width, &height);
        try std.testing.expectEqual(case.expected_width, width);
        try std.testing.expectEqual(case.expected_height, height);
    }

    try std.testing.expect(gtk.Widget.getHexpand(scroller.as(gtk.Widget)) != 0);
    try std.testing.expect(gtk.Widget.getVexpand(scroller.as(gtk.Widget)) != 0);
}

fn expectConceptToolbarWrapsWithAccessibleControls() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;
    const display = gdk.Display.getDefault() orelse return error.GtkUnavailable;

    const base_provider = gtk.CssProvider.new();
    defer base_provider.unref();
    gtk.CssProvider.loadFromString(base_provider, @embedFile("themes/style.css"));
    gtk.StyleContext.addProviderForDisplay(
        display,
        base_provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    defer gtk.StyleContext.removeProviderForDisplay(display, base_provider.as(gtk.StyleProvider));

    const midnight_provider = gtk.CssProvider.new();
    defer midnight_provider.unref();
    gtk.CssProvider.loadFromString(midnight_provider, @embedFile("themes/theme-midnight.css"));
    gtk.StyleContext.addProviderForDisplay(
        display,
        midnight_provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    defer gtk.StyleContext.removeProviderForDisplay(display, midnight_provider.as(gtk.StyleProvider));

    const page = PackagePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();
    gtk.Widget.addCssClass(page.as(gtk.Widget), "theme-midnight");

    const toolbar = findByCssClass(page.as(gtk.Widget), "package-toolbar-concept") orelse
        return error.ConceptToolbarMissing;
    const search = findByCssClass(page.as(gtk.Widget), "package-search-concept") orelse
        return error.ConceptSearchMissing;
    const install = findByCssClass(page.as(gtk.Widget), "package-install-concept") orelse
        return error.ConceptInstallButtonMissing;
    const grid = findByCssClass(page.as(gtk.Widget), "package-grid-concept") orelse
        return error.ConceptGridButtonMissing;
    const list = findByCssClass(page.as(gtk.Widget), "package-list-concept") orelse
        return error.ConceptListButtonMissing;
    const view_switch = gtk.Widget.getParent(grid) orelse return error.ConceptViewSwitchMissing;
    const options = gtk.Widget.getNextSibling(view_switch) orelse return error.ConceptOptionsButtonMissing;
    const count_label = findByCssClass(page.as(gtk.Widget), "package-count-concept") orelse
        return error.ConceptSelectionCountMissing;
    const count_button = find_count_button: {
        var ancestor = gtk.Widget.getParent(count_label);
        while (ancestor) |current| : (ancestor = gtk.Widget.getParent(current)) {
            if (gobject.ext.cast(gtk.MenuButton, current)) |button| break :find_count_button button;
        }
        return error.ConceptSelectionButtonMissing;
    };
    const count = count_button.as(gtk.Widget);
    const cart_popover = gtk.MenuButton.getPopover(count_button) orelse
        return error.ConceptSelectionPopoverMissing;
    const cart_content = findByCssClass(cart_popover.as(gtk.Widget), "package-cart-content") orelse
        return error.ConceptSelectionContentMissing;
    try std.testing.expect(gtk.Widget.hasCssClass(cart_content, "selection-panel") == 0);

    const oversized_checkbox_provider = gtk.CssProvider.new();
    defer oversized_checkbox_provider.unref();
    gtk.CssProvider.loadFromString(oversized_checkbox_provider,
        \\.package-checkbox-oversized-installed check { min-width: 0.9em; min-height: 0.9em; margin-right: 0.5em; }
        \\.package-checkbox-oversized-option check { min-width: 0.9em; min-height: 0.9em; margin-right: 0.4em; }
    );
    gtk.StyleContext.addProviderForDisplay(
        display,
        oversized_checkbox_provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1,
    );
    defer gtk.StyleContext.removeProviderForDisplay(display, oversized_checkbox_provider.as(gtk.StyleProvider));

    const checkbox_cases = [_]struct { class: [:0]const u8, label: [:0]const u8, baseline_class: [:0]const u8 }{
        .{ .class = "package-installed-concept", .label = "Installed Only", .baseline_class = "package-checkbox-oversized-installed" },
        .{ .class = "package-upgrade-concept", .label = "Perform Upgrade", .baseline_class = "package-checkbox-oversized-option" },
    };
    for (checkbox_cases) |case| {
        const concept_checkbox = findByCssClass(page.as(gtk.Widget), case.class) orelse
            return error.ConceptCheckboxMissing;
        const oversized_checkbox = gtk.CheckButton.newWithLabel(case.label);
        _ = oversized_checkbox.as(gobject.Object).refSink();
        defer oversized_checkbox.as(gobject.Object).unref();
        gtk.Widget.addCssClass(oversized_checkbox.as(gtk.Widget), case.baseline_class);
        const checkbox_parent_widget = gtk.Widget.getParent(concept_checkbox) orelse
            return error.ConceptCheckboxParentMissing;
        const checkbox_parent = gobject.ext.cast(gtk.Box, checkbox_parent_widget) orelse
            return error.ConceptCheckboxParentHasWrongType;
        gtk.Box.append(checkbox_parent, oversized_checkbox.as(gtk.Widget));
        defer gtk.Box.remove(checkbox_parent, oversized_checkbox.as(gtk.Widget));

        const concept_indicator = gtk.Widget.getFirstChild(concept_checkbox) orelse
            return error.ConceptCheckboxIndicatorMissing;
        const oversized_indicator = gtk.Widget.getFirstChild(oversized_checkbox.as(gtk.Widget)) orelse
            return error.OversizedCheckboxIndicatorMissing;

        var concept_minimum_width: c_int = 0;
        var oversized_minimum_width: c_int = 0;
        gtk.Widget.measure(concept_indicator, .horizontal, -1, &concept_minimum_width, null, null, null);
        gtk.Widget.measure(oversized_indicator, .horizontal, -1, &oversized_minimum_width, null, null, null);
        try std.testing.expect(concept_minimum_width < oversized_minimum_width);
    }

    const baseline_provider = gtk.CssProvider.new();
    defer baseline_provider.unref();
    gtk.CssProvider.loadFromString(
        baseline_provider,
        ".package-toolbar-height-baseline { min-height: 2.75em; }",
    );
    gtk.StyleContext.addProviderForDisplay(
        display,
        baseline_provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1,
    );
    defer gtk.StyleContext.removeProviderForDisplay(display, baseline_provider.as(gtk.StyleProvider));

    const baseline_search = gtk.SearchEntry.new();
    _ = baseline_search.as(gobject.Object).refSink();
    defer baseline_search.as(gobject.Object).unref();
    gtk.Widget.addCssClass(baseline_search.as(gtk.Widget), "package-toolbar-height-baseline");

    const baseline_install = gtk.Button.newWithLabel("Install Selected");
    _ = baseline_install.as(gobject.Object).refSink();
    defer baseline_install.as(gobject.Object).unref();
    gtk.Widget.addCssClass(baseline_install.as(gtk.Widget), "package-toolbar-height-baseline");
    const toolbar_box = gobject.ext.cast(gtk.Box, toolbar) orelse return error.ConceptToolbarHasWrongType;
    const filters_widget = findByCssClass(page.as(gtk.Widget), "package-toolbar-filters") orelse
        return error.ConceptFilterGroupMissing;
    const actions_widget = findByCssClass(page.as(gtk.Widget), "package-toolbar-actions") orelse
        return error.ConceptActionGroupMissing;
    const spacer_widget = findByCssClass(page.as(gtk.Widget), "package-toolbar-spacer") orelse
        return error.ConceptToolbarSpacerMissing;
    const filters = gobject.ext.cast(gtk.Box, filters_widget) orelse return error.ConceptFilterGroupHasWrongType;
    const actions = gobject.ext.cast(gtk.Box, actions_widget) orelse return error.ConceptActionGroupHasWrongType;
    const spacer = gobject.ext.cast(gtk.Box, spacer_widget) orelse return error.ConceptToolbarSpacerHasWrongType;

    var search_min_height: c_int = 0;
    var baseline_search_min_height: c_int = 0;
    var install_min_height: c_int = 0;
    var baseline_install_min_height: c_int = 0;
    gtk.Widget.measure(search, .vertical, -1, &search_min_height, null, null, null);
    gtk.Widget.measure(baseline_search.as(gtk.Widget), .vertical, -1, &baseline_search_min_height, null, null, null);
    gtk.Widget.measure(install, .vertical, -1, &install_min_height, null, null, null);
    gtk.Widget.measure(baseline_install.as(gtk.Widget), .vertical, -1, &baseline_install_min_height, null, null, null);
    try std.testing.expect(search_min_height * 5 <= baseline_search_min_height * 4 + 3);
    try std.testing.expect(install_min_height * 5 <= baseline_install_min_height * 4 + 3);

    const compact_buttons = [_]*gtk.Widget{ grid, list, options };
    for (compact_buttons) |button| {
        var minimum_width: c_int = 0;
        var minimum_height: c_int = 0;
        gtk.Widget.measure(button, .horizontal, -1, &minimum_width, null, null, null);
        gtk.Widget.measure(button, .vertical, -1, &minimum_height, null, null, null);
        try std.testing.expect(@abs(minimum_width - minimum_height) <= 4);
    }

    var count_min_height: c_int = 0;
    var grid_min_height: c_int = 0;
    gtk.Widget.measure(count, .vertical, -1, &count_min_height, null, null, null);
    gtk.Widget.measure(grid, .vertical, -1, &grid_min_height, null, null, null);
    try std.testing.expect(@abs(count_min_height - grid_min_height) <= 4);

    var initial_minimum_width: c_int = 0;
    gtk.Widget.measure(toolbar, .horizontal, -1, &initial_minimum_width, null, null, null);
    try std.testing.expect(initial_minimum_width <= 520);

    package_toolbar_layout.apply(toolbar_box, filters, actions, spacer, 520);
    var narrow_height: c_int = 0;
    var wide_height: c_int = 0;
    gtk.Widget.measure(toolbar, .vertical, 520, &narrow_height, null, null, null);

    var minimum_width: c_int = 0;
    gtk.Widget.measure(toolbar, .horizontal, -1, &minimum_width, null, null, null);
    try std.testing.expect(minimum_width <= 520);

    package_toolbar_layout.apply(toolbar_box, filters, actions, spacer, 1200);
    var toolbar_minimum_at_wide: c_int = 0;
    gtk.Widget.measure(toolbar, .horizontal, -1, &toolbar_minimum_at_wide, null, null, null);
    try std.testing.expect(toolbar_minimum_at_wide <= 1200);
    try std.testing.expectEqual(gtk.Orientation.horizontal, gtk.Orientable.getOrientation(toolbar_box.as(gtk.Orientable)));
    gtk.Widget.measure(toolbar, .vertical, 1200, &wide_height, null, null, null);
    try std.testing.expect(narrow_height > wide_height);

    for ([_]c_int{ 700, 1280, 1920, 3840 }) |width| {
        package_toolbar_layout.apply(toolbar_box, filters, actions, spacer, width);
        var responsive_minimum_width: c_int = 0;
        gtk.Widget.measure(toolbar, .horizontal, -1, &responsive_minimum_width, null, null, null);
        try std.testing.expect(responsive_minimum_width <= width);
    }
}

pub fn main() !void {
    try expectOnlyConceptToolbar();
    try expectAuxiliarySearchZonesHaveNoCardBackground();
    try expectAurKebabMatchesPackageKebab();
    try expectSearchEntriesShareCompactHeight();
    try expectRecommendedContentUsesFullWidth();
    try expectDetailPanelsUseNaturalWidth();
    try expectDetailPanelsMatchPageBottomAndRightSpacing();
    try expectPackageLoadingUsesFrameSizedBatches();
    try expectPackageLoadingDetailKeepsReadableWidth();
    try expectDetailValuesUseReadableRows();
    try expectConceptToolbarWrapsWithAccessibleControls();
    try expectFlatpakSearchFollowsCategoryWidth();
    try expectFlatpakPermissionsActionIsImmediatelyAvailable();
    try expectAppImageDetailUsesAvailableWidth();
    try expectAppImageDetailAdaptsToAvailableWidth();
    try expectVersionHistoryTracksAvailableWindowSize();
    try expectPermissionsTracksAvailableWindowSize();
    try expectPermissionsDialogUpdatesLoadingStateInPlace();
    try expectPermissionsDialogStopsLoadingOnError();
    try expectPkgbuildReviewTracksAvailableWindowSize();
    try expectPkgbuildPreviewTracksAvailableWindowSize();
    try expectMultiSelectTracksAvailableWindowSize();
}
