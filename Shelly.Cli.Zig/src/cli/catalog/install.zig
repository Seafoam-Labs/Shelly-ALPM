const types = @import("types.zig");

const flag = types.flag;
const repeatedArgument = types.repeatedArgument;
const requiredArgument = types.requiredArgument;
const stringOption = types.stringOption;

pub const variants = [_]types.Variant{
    .{
        .action = .install,
        .name = "standard",
        .type_code = 's',
        .description = "Install ALPM repository packages, local Arch or Shelly binary archives, and package archives downloaded from HTTP(S) URLs.",
        .implementation = "Zigalpm.AlpmManager.install_packages / install_local_packages / install_dependencies_only; Zigalpm.LocalManager.installBinariesPackage; Zigalpm.shared.Downloader.downloadToFile for URLs",
        .arguments = &.{repeatedArgument(
            "packages",
            0,
            "One or more repository names, repository-qualified names, local archive paths, or HTTP(S) package URLs",
        )},
        .options = &.{
            flag("--build-deps", &.{"-b"}, "Install build dependencies for the requested packages"),
            flag("--make-deps", &.{"-m"}, "Install make dependencies for the requested packages"),
            flag("--no-deps", &.{"-d"}, "Pass the ALPM nodeps transaction flag when installing repository packages"),
            flag("--upgrade", &.{"-u"}, "After confirmation, synchronize and upgrade the standard system before installing the requested repository packages"),
        },
    },
    .{
        .action = .install,
        .name = "appimage",
        .type_code = 'i',
        .description = "Install a local AppImage into the configured AppImage directory and update Shelly's AppImage metadata database.",
        .implementation = "Zigalpm.AppImageManager.installAppImage",
        .arguments = &.{requiredArgument(
            "location",
            "Path to an existing file whose extension is .AppImage",
        )},
        .options = &.{stringOption(
            "--install-path",
            &.{},
            "Directory to install the AppImage into; overrides the configured AppImageInstallPath",
            false,
        )},
    },
    .{
        .action = .install,
        .name = "aur",
        .type_code = 'a',
        .description = "Fetch, review, build, and install one or more AUR packages, install one package's build dependencies, or install one package at an exact Git commit.",
        .implementation = "Zigalpm.AurManager.installPackages / installDependenciesOnly / installPackageVersion",
        .arguments = &.{repeatedArgument(
            "packages",
            0,
            "AUR package names; dependency-only mode accepts one package, while --version requires exactly one package followed by its Git commit",
        )},
        .options = &.{
            flag("--build-deps", &.{"-b"}, "Install build dependencies for the requested packages"),
            flag("--make-deps", &.{"-m"}, "Install make dependencies for the requested packages"),
            flag("--chroot", &.{"-c"}, "Build packages in a clean chroot with makechrootpkg"),
            flag("--check", &.{}, "Enable the PKGBUILD check() function during package builds"),
            flag("--version", &.{"-v"}, "Install exactly one AUR package from the following Git commit operand"),
        },
    },
    .{
        .action = .install,
        .name = "flatpak",
        .type_code = 'f',
        .description = "Install a Flatpak application, runtime, .flatpakref file, or bundle, or repair an installed Flatpak while preserving its configuration.",
        .implementation = "Zigalpm.flatpak.AppstreamManager.getAllRemoteCatalogs; Zigalpm.FlatpakManager.install_flatpak / install_from_ref_flatpak / install_from_bundle_flatpak / repair_installed_flatpak",
        .arguments = &.{requiredArgument(
            "package",
            "Application/runtime ID, friendly AppStream name, installed target with --repair, .flatpakref path with --ref-file, or bundle path with --bundle",
        )},
        .options = &.{
            flag("--user", &.{}, "Install into the invoking user's Flatpak installation instead of the system installation"),
            stringOption("--remote", &.{"-r"}, "Install from this remote instead of resolving a remote from cached AppStream metadata", false),
            stringOption("--branch", &.{"-b"}, "Install this branch; defaults to the branch the remote publishes for the package", false),
            flag("--runtime", &.{}, "Build a runtime ref instead of an application ref"),
            flag("--ref-file", &.{"-e"}, "Treat the package operand as a local .flatpakref file"),
            flag("--bundle", &.{"-u"}, "Treat the package operand as a local Flatpak bundle"),
            flag("--repair", &.{"-f"}, "Reinstall the installed Flatpak and its dependencies while preserving application configuration"),
        },
    },
};
