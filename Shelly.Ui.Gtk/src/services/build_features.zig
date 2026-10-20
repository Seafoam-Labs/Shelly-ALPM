const options = @import("options");
const ShellyTabs = @import("../models/shelly_config.zig").ShellyTabs;

pub const version = options.version;

pub const flatpak_backend_package = options.flatpak_backend_package;

pub const builtWithDevario = options.devario;

pub const builtWithBackgroundServices = !options.skip_background_services;

pub const builtWithFlatpak = !options.exclude_flatpak;
pub const builtWithAur = options.aur_backend != .none;
pub const builtWithAtoll = options.aur_backend == .atoll or options.aur_backend == .both;
pub const builtWithAtollOnly = options.aur_backend == .atoll;
pub const builtWithBuiltinAur = options.aur_backend == .aur or options.aur_backend == .both;
pub const builtWithRecommend = !options.exclude_recommend;
pub const builtWithAppImage = !options.exclude_appimage;
pub const builtWithShellySearch = !options.exclude_shelly_search;

pub const aur_source_name: [:0]const u8 = if (builtWithAtollOnly) "Atoll" else "AUR";

pub fn builtWith(tab: ShellyTabs) bool {
    return switch (tab) {
        .packages, .update => true,
        .recommend => builtWithRecommend,
        .aur => builtWithAur,
        .flatpak => builtWithFlatpak,
        .app_image => builtWithAppImage,
        .shelly_search => builtWithShellySearch,
    };
}
