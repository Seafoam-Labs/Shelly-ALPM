const types = @import("types.zig");

const booleanOptionWithDefault = types.booleanOptionWithDefault;
const flag = types.flag;
const optionalArgument = types.optionalArgument;
const optionalArgumentWithChoices = types.optionalArgumentWithChoices;
const stringOption = types.stringOption;

pub const variants = [_]types.Variant{
    .{
        .action = .sync,
        .name = "standard",
        .type_code = 's',
        .default_for_action = true,
        .description = "Synchronize the configured ALPM package databases; use --force to refresh databases even when they appear current.",
        .implementation = "PackageManager.Manager.sync",
        .options = &.{flag(
            "--force",
            &.{"-f"},
            "Force every configured ALPM package database to refresh",
        )},
    },
    .{
        .action = .sync,
        .name = "appimage",
        .type_code = 'i',
        .description = "Synchronize extracted AppImage metadata, or configure an installed AppImage's update source with the appimage/url/type overload.",
        .implementation = "PackageManager.AppImageManager.syncAppImageMeta / PackageManager.appimage.UpdateManager.configure_updates",
        .arguments = &.{
            optionalArgument(
                "appimage",
                "Optional case-insensitive AppImage name query",
            ),
            optionalArgument(
                "url",
                "Update URL or owner/repository value when configuring updates",
            ),
            optionalArgumentWithChoices(
                "type",
                "Update source type when configuring updates",
                &.{ "None", "StaticUrl", "GitHub", "GitLab", "Codeberg", "Forgejo" },
            ),
        },
        .options = &.{
            flag("--prerelease", &.{"-p"}, "Allow prerelease versions for the configured update source"),
            .{
                .name = "--configure-updates",
                .description = "Select the AppImage update-configuration overload",
                .hidden = true,
            },
        },
    },
    .{
        .action = .sync,
        .name = "flatpak",
        .type_code = 'f',
        .description = "Update cached AppStream metadata, or add and remove configured system or user Flatpak remotes.",
        .implementation = "PackageManager.flatpak.AppstreamManager.updateAllAppstreams; PackageManager.flatpak.RemoteManager.addRemote / removeRemote",
        .arguments = &.{
            optionalArgumentWithChoices(
                "mode",
                "Use remote to configure Flatpak remotes; omit to update AppStream metadata",
                &.{"remote"},
            ),
            optionalArgumentWithChoices(
                "operation",
                "Add or remove a configured remote",
                &.{ "add", "remove" },
            ),
            optionalArgument(
                "name",
                "Flatpak remote name, such as flathub",
            ),
        },
        .options = &.{
            stringOption("--remote-url", &.{"-u"}, "Remote URL or .flatpakrepo URL; required for remote add", false),
            booleanOptionWithDefault("--system", &.{"-s"}, "Use system scope; defaults to true", true),
            booleanOptionWithDefault("--gpg-verify", &.{"-g"}, "Enable GPG verification when adding; defaults to true", true),
        },
    },
};
