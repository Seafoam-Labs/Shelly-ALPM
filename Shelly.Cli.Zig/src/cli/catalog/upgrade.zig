const types = @import("types.zig");

const flag = types.flag;

pub const variants = [_]types.Variant{
    .{
        .action = .upgrade,
        .name = "standard",
        .type_code = 's',
        .description = "Synchronize ALPM repositories, show the available repository package upgrades, perform a full system upgrade, and report required restarts.",
        .implementation = "Zigalpm.AlpmManager.sync / get_updates_available / sync_system_update",
        .options = &.{flag(
            "--all",
            &.{"-a"},
            "Upgrade standard, AUR, Flatpak, and AppImage backends",
        )},
    },
    .{
        .action = .upgrade,
        .name = "all",
        .type_code = 'x',
        .bare_action_code = true,
        .description = "Build and confirm an invoking-user upgrade plan, then upgrade every enabled package backend in one coordinated action, continuing through independent backend failures and returning failure if any selected backend fails.",
        .implementation = "Combined Zig coordinator over AlpmManager, AurManager, FlatpakManager, and appimage.UpdateManager",
        .options = &.{ flag("--no-repo", &.{}, "Skip the standard ALPM backend"), flag("--no-aur", &.{}, "Skip the AUR backend"), flag("--no-flatpak", &.{}, "Skip the Flatpak backend"), flag("--no-appimage", &.{}, "Skip the AppImage backend"), flag("--no-devel", &.{}, "Skip -git aur") },
    },
    .{
        .action = .upgrade,
        .name = "appimage",
        .type_code = 'i',
        .description = "Check every configured AppImage update source and replace each AppImage for which a newer version is available.",
        .implementation = "Zigalpm.appimage.UpdateManager.get_updates / update",
    },
    .{
        .action = .upgrade,
        .name = "aur",
        .type_code = 'a',
        .description = "Find installed foreign packages with newer AUR or VCS revisions, then build and install all available upgrades.",
        .implementation = "Zigalpm.AurManager.getPackagesNeedingUpdate / updatePackages",
        .options = &.{ flag("--check", &.{}, "Run each PKGBUILD check() function during AUR upgrade builds"), flag("--no-check", &.{}, "Skip each PKGBUILD check() function during AUR upgrade builds"), flag("--sign", &.{}, "Sign upgraded AUR packages with GPG"), flag("--nosign", &.{}, "Skip signing upgraded AUR packages"), flag("--singlepane", &.{}, "Use single-pane terminal output."), flag("--no-devel", &.{}, "Skip checking -git packages") },
    },
    .{
        .action = .upgrade,
        .name = "flatpak",
        .type_code = 'f',
        .description = "Upgrade every application and runtime with an available update in the system and user Flatpak installations.",
        .implementation = "Zigalpm.FlatpakManager.upgrade_flatpaks",
    },
};
