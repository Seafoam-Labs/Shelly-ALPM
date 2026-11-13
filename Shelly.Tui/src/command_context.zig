const std = @import("std");
const commands = @import("commands.zig");
const Model = @import("model.zig").Model;
const packages_model = @import("models/packages_model.zig");
const aur_model = @import("models/aur_model.zig");
const flatpak_model = @import("models/flatpak_model.zig");
const updates_model = @import("models/updates_model.zig");
const settings_model = @import("models/settings_model.zig");
const operation_model = @import("models/operation_model.zig");

pub fn resolve(self: *Model) commands.Context {
    var context: commands.Context = .{ .tab_count = self.visibleTabs().len, .quit_blocked = self.operation_state.install_job != null };
    if (operation_model.operationPrompt(self)) |prompt| {
        context.mode = switch (prompt.state) {
            .entering => if (prompt.elevated) .authentication else .confirmation,
            .running => .running,
            .succeeded, .failed, .declined => .result,
        };
        context.scrollable = prompt.panel.scroll.scroll.has_more_vertical or
            prompt.panel.scroll.scroll.top > 0 or prompt.panel.scroll.scroll.vertical_offset != 0;
        context.authenticating = prompt.progress.authenticating;
        return context;
    }
    context.categories_available = self.active == .flatpak and !self.flatpak_state.flatpak_installed_only and (self.overlay == null or self.overlay.? == .flatpak);
    if (self.flatpak_state.flatpak_category_open) {
        context.mode = .choice;
        context.category_choice = true;
        return context;
    }
    if (self.overlay) |overlay| switch (overlay) {
        .package => context.split_details = true,
        .aur => |pkg| {
            context.mode = .details;
            context.selected_count = self.aur_state.aur_selection.items.len;
            for (self.aur_state.aur_selection.items) |selected| if (selected.installed) {
                context.selected_installed += 1;
            };
            context.installable = true;
            context.removable = if (context.selected_count > 0) context.selected_installed > 0 else pkg.Installed;
            context.preview = true;
            context.preview_button = self.aur_state.aur_preview_button.focused;
            context.split_details = true;
            context.scrollable = self.aur_state.aur_details_scroll.scroll.has_more_vertical or self.aur_state.aur_details_scroll.scroll.top > 0 or self.aur_state.aur_details_scroll.scroll.vertical_offset != 0;
            return context;
        },
        .flatpak => |row| {
            context.mode = .details;
            context.screenshots_navigable = flatpak_model.screenshotsEnabled(self) and self.flatpak_state.screenshot_open and self.flatpak_state.screenshot_items.len > 1;
            context.screenshot_retry = flatpak_model.screenshotsEnabled(self) and self.flatpak_state.screenshot_open and self.flatpak_state.screenshot_failure != null;
            context.installable = row == .catalog and row.catalog.Remotes.len > 0;
            context.removable = row == .installed;
            context.split_details = true;
            context.scrollable = true;
            return context;
        },
        .pkgbuild => {
            context.mode = if (self.operation_state.operation_question) |question|
                if (question.value.question == .select_one or question.value.question == .select_many) .answers else .review
            else
                .preview_document;
            context.scrollable = self.operation_state.pkgbuild_document != null and !operation_model.pkgbuildView(self).loading;
            context.source_wrap = self.operation_state.pkgbuild_wrap;
            context.multiple_choices = if (self.operation_state.operation_question) |q| q.value.question == .select_many else false;
            return context;
        },
        .flatpak_install => {
            context.mode = .choice;
            return context;
        },
        .sudo => unreachable,
    };
    switch (self.active) {
        .packages => {
            context.mode = if (context.split_details) .details else if (self.packages_state.package_list_active) .packages else .search;
            context.installed_only = self.packages_state.installed_only;
            context.selected_count = self.packages_state.selected_packages.items.len;
            for (self.packages_state.selected_packages.items) |name| for (self.packages_state.packages) |pkg| {
                if (std.mem.eql(u8, name, pkg.Name)) {
                    if (pkg.Installed) context.selected_installed += 1;
                    break;
                }
            };
            context.installable = !self.packages_state.loading and !self.packages_state.load_failed and (packages_model.selectedPackage(self) != null or context.selected_count > 0);
            context.removable = context.installable and if (context.selected_count > 0) context.selected_installed > 0 else if (packages_model.selectedPackage(self)) |pkg| pkg.Installed else false;
            context.scrollable = context.split_details and (self.packages_state.package_details_scroll.scroll.has_more_vertical or
                self.packages_state.package_details_scroll.scroll.top > 0 or self.packages_state.package_details_scroll.scroll.vertical_offset != 0);
        },
        .aur => {
            context.mode = .aur;
            context.catalog_available = aur_model.catalogActive(self);
            context.catalog_previous = context.catalog_available and self.aur_state.aur_job == null and self.aur_state.catalog_page > 1;
            context.catalog_next = context.catalog_available and self.aur_state.aur_job == null and self.aur_state.catalog_page < self.aur_state.catalog_total_pages;
            context.installed_only = self.aur_state.aur_installed_only;
            context.browsing_list = self.aur_state.aur_list_active;
            context.selected_count = self.aur_state.aur_selection.items.len;
            for (self.aur_state.aur_selection.items) |selected| if (selected.installed) {
                context.selected_installed += 1;
            };
            context.installable = self.aur_state.aur_list_active and (aur_model.selectedAur(self) != null or self.aur_state.aur_selection.items.len > 0);
            context.removable = self.aur_state.aur_list_active and if (context.selected_count > 0) context.selected_installed > 0 else if (aur_model.selectedAur(self)) |pkg| pkg.Installed else false;
            context.preview = self.aur_state.aur_list_active and aur_model.selectedAur(self) != null;
        },
        .flatpak => {
            context.mode = .flatpak;
            context.browsing_list = self.flatpak_state.flatpak_list_active;
            if (self.flatpak_state.flatpak_list_active and self.flatpak_state.flatpak_job == null and self.flatpak_state.flatpak_list.cursor < self.flatpak_state.flatpak_rows.items.len) {
                const row = self.flatpak_state.flatpak_rows.items[self.flatpak_state.flatpak_list.cursor];
                context.installable = row == .catalog and row.catalog.Remotes.len > 0;
                context.removable = row == .installed;
            }
            context.installed_only = self.flatpak_state.flatpak_installed_only;
        },
        .upgrade => {
            const view = updates_model.updatesView(self);
            context.mode = .updates;
            context.upgrade_all = view.canUpgradeAll();
            context.upgrade_system = view.canUpgrade();
            context.upgrade_aur = view.canUpgradeAur();
            context.upgrade_flatpak = view.canUpgradeFlatpak();
        },
        .appimage => {
            context.mode = .appimage;
            context.appimage_path = self.appimage_state.install_form != null;
            if (self.appimage_state.install_form) |form| {
                context.appimage_path_editing = form.editing_path;
                context.hidden_files = form.show_hidden;
            }
            context.split_details = self.appimage_state.details_active;
        },
        .settings => {
            context.mode = .settings;
            context.settings_keybindings = self.settings_state.keybindings_open;
            context.settings_keybindings_button = self.settings_state.settings_selected == @import("models/settings.zig").keybindings_index;
            context.settings_capture = self.settings_state.keybinding_capture;
            context.settings_binding_selected = context.settings_keybindings;
            context.settings_save_selected = !context.settings_keybindings and self.settings_state.settings_selected == settings_model.save_index;
            context.settings_header_open = self.settings_state.header_open;
            context.settings_discard_selected = !context.settings_keybindings and self.settings_state.settings_selected == @import("models/settings.zig").discard_index;
            context.settings_cycle_selected = self.settings_state.settings_selected == @import("models/settings.zig").header_index;
        },
    }
    return context;
}
