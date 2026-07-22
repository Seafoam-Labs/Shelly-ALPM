const std = @import("std");

pub const binary = "shelly";
pub const version = "2.4.1+4";
pub const informational_version = version;
pub const root_description = "Shelly — a native, unified package manager for Arch Linux repository packages, the AUR, Flatpaks, and AppImages. A bare value searches standard repositories and the AUR, then prompts for a package to install.";

pub const Argument = struct {
    name: []const u8,
    type: []const u8 = "string",
    minimumArity: usize,
    maximumArity: ?usize,
    description: ?[]const u8 = null,
    choices: []const []const u8 = &.{},
};

pub const Option = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    type: []const u8 = "bool",
    minimumArity: usize = 0,
    maximumArity: ?usize = 1,
    required: bool = false,
    description: ?[]const u8 = null,
    hidden: bool = false,
    recursive: bool = false,
    builtIn: bool = false,
    hasExplicitDefault: bool = false,
    defaultValue: ?std.json.Value = null,
    choices: []const []const u8 = &.{},

    pub fn matches(self: Option, token: []const u8) bool {
        if (std.mem.eql(u8, self.name, token)) return true;
        for (self.aliases) |alias| {
            if (std.mem.eql(u8, alias, token)) return true;
        }
        return false;
    }
};

pub const root_options = [_]Option{
    voidOption("--help", &.{ "-?", "-h", "/?", "/h" }, "Show command-specific help and usage information", true, true),
    voidOption("--version", &.{"-V"}, "Show version information", false, true),
    globalFlag("--no-confirm", &.{"-n"}, "Use safe automatic answers instead of prompting"),
    globalFlag("--ui-mode", &.{"-U"}, "Emit framed output for the Shelly UI"),
    globalFlag("--json", &.{"-j"}, "Output structured JSON where the command supports it"),
};

pub const root_arguments = [_]Argument{.{
    .name = "query",
    .minimumArity = 1,
    .maximumArity = null,
    .description = "Package search words used by the interactive standard/AUR install fallback",
}};

pub const Type = struct {
    name: []const u8,
    code: ?u8,
    description: []const u8,
};

pub const types = [_]Type{
    .{ .name = "standard", .code = 's', .description = "Arch Linux repository and local ALPM packages" },
    .{ .name = "aur", .code = 'a', .description = "Arch User Repository packages" },
    .{ .name = "flatpak", .code = 'f', .description = "Flatpak applications and runtimes" },
    .{ .name = "appimage", .code = 'i', .description = "AppImage applications" },
    .{ .name = "utility", .code = 'u', .description = "System and Shelly utility operations" },
    .{ .name = "keyring", .code = 'k', .description = "Pacman keyring operations" },
    .{ .name = "all", .code = 'x', .description = "All supported package backends" },
};

pub const Variant = struct {
    action: []const u8,
    type_name: []const u8,
    action_code: ?u8,
    type_code: ?u8,
    default_for_action: bool = false,
    help: Help = .{},
};

pub const HelpText = struct {
    name: []const u8,
    description: []const u8,
};

pub const Help = struct {
    description: ?[]const u8 = null,
    implementation: ?[]const u8 = null,
    arguments: []const HelpText = &.{},
    options: []const HelpText = &.{},
};

// This is the authoritative native action/type routing table. Arguments,
// modifiers, help, shortcodes, and defaults are all resolved in this module.
pub const variants = [_]Variant{
    .{
        .action = "search",
        .type_name = "standard",
        .action_code = 'S',
        .type_code = 's',
        .help = .{
            .description = "Search ALPM repository and installed packages, or Shelly-managed local binary packages. With a package and no source modifier, show exact package details.",
            .implementation = "Zigalpm.AlpmManager.get_installed_packages / get_available_packages; Zigalpm.LocalManager.getInstalledBinaryPackages for --local",
            .arguments = &.{.{
                .name = "package",
                .description = "Package name or search term; without a source modifier, an exact name opens package details",
            }},
            .options = &.{
                .{ .name = "--repos", .description = "List repositories parsed from pacman.conf and ignore other search modifiers" },
                .{ .name = "--available", .description = "Search packages from the configured ALPM synchronization databases" },
                .{ .name = "--installed", .description = "Search packages from the local ALPM database" },
                .{ .name = "--local", .description = "Search Shelly-managed binary packages installed under /opt/shelly" },
                .{ .name = "--show-hidden", .description = "Include packages hidden by pacman IgnorePkg configuration" },
                .{ .name = "--detail", .description = "Show complete metadata for one exact ALPM package name" },
                .{ .name = "--group", .description = "List package groups or restrict available packages to the requested group" },
                .{ .name = "--explicit", .description = "Shows only explicitly installed pacakges" },
                .{ .name = "--depends", .description = "Shows only dependency packages" },
            },
        },
    },
    .{
        .action = "install",
        .type_name = "standard",
        .action_code = 'I',
        .type_code = 's',
        .help = .{
            .description = "Install ALPM repository packages, local Arch or Shelly binary archives, and package archives downloaded from HTTP(S) URLs.",
            .implementation = "Zigalpm.AlpmManager.install_packages / install_local_packages / install_dependencies_only; Zigalpm.LocalManager.installBinariesPackage; Zigalpm.shared.Downloader.downloadToFile for URLs",
            .arguments = &.{.{
                .name = "packages",
                .description = "One or more repository names, repository-qualified names, local archive paths, or HTTP(S) package URLs",
            }},
            .options = &.{
                .{ .name = "--no-deps", .description = "Pass the ALPM nodeps transaction flag when installing repository packages" },
                .{ .name = "--upgrade", .description = "Synchronize and upgrade the standard system before installing the requested repository packages" },
            },
        },
    },
    .{
        .action = "upgrade",
        .type_name = "standard",
        .action_code = 'U',
        .type_code = 's',
        .help = .{
            .description = "Synchronize ALPM repositories, show the available repository package upgrades, perform a full system upgrade, and report required restarts.",
            .implementation = "Zigalpm.AlpmManager.sync / get_updates_available / sync_system_update",
        },
    },
    .{
        .action = "upgrade",
        .type_name = "all",
        .action_code = 'U',
        .type_code = 'x',
        .help = .{
            .description = "Build and confirm an invoking-user upgrade plan, then upgrade every enabled package backend in one coordinated action, continuing through independent backend failures and returning failure if any selected backend fails.",
            .implementation = "Combined Zig coordinator over AlpmManager, AurManager, FlatpakManager, and appimage.UpdateManager",
        },
    },
    .{
        .action = "downgrade",
        .type_name = "standard",
        .action_code = 'D',
        .type_code = null,
        .default_for_action = true,
        .help = .{
            .description = "Discover cached and archived versions of an installed ALPM package, select one, and install it as a downgrade.",
            .implementation = "Zigalpm.AlpmManager.get_single_installed_package / Zigalpm.alpm.ArchiveManager.find_candidates / install_candidate / AlpmManager.ignore_package",
            .arguments = &.{.{
                .name = "package",
                .description = "Installed ALPM package to downgrade",
            }},
            .options = &.{
                .{ .name = "--oldest", .description = "Select the oldest available version instead of prompting or selecting the newest version" },
                .{ .name = "--ignore", .description = "Add the package to IgnorePkg after a successful downgrade" },
                .{ .name = "--list-options", .description = "List cached and archived versions without installing one" },
                .{ .name = "--target", .description = "Install an exact version-release or package filename" },
            },
        },
    },
    .{
        .action = "mark",
        .type_name = "ignore",
        .action_code = 'M',
        .type_code = 'g',
        .help = .{
            .description = "List or modify packages excluded from ALPM upgrades through IgnorePkg.",
            .implementation = "Zigalpm.AlpmManager ignore_package(s) / unignore_package(s) / get_ignored_packages",
        },
    },
    .{
        .action = "mark",
        .type_name = "hold",
        .action_code = 'M',
        .type_code = 'o',
        .help = .{
            .description = "List or modify packages protected from removal through HoldPkg.",
            .implementation = "Zigalpm.AlpmManager hold_package(s) / unhold_package(s) / get_held_packages",
        },
    },
    .{
        .action = "mark",
        .type_name = "explicit",
        .action_code = 'M',
        .type_code = 'e',
        .help = .{
            .description = "Mark an installed ALPM package as explicitly installed.",
            .implementation = "Zigalpm.AlpmManager.update_package_reason(.Explicit)",
        },
    },
    .{
        .action = "mark",
        .type_name = "dependency",
        .action_code = 'M',
        .type_code = 'd',
        .help = .{
            .description = "Mark an installed ALPM package as installed as a dependency.",
            .implementation = "Zigalpm.AlpmManager.update_package_reason(.Dependency)",
        },
    },
    .{
        .action = "news",
        .type_name = "standard",
        .action_code = 'N',
        .type_code = null,
        .default_for_action = true,
        .help = .{
            .description = "Fetch Arch Linux news, display unread entries by default, and remember viewed entries in the invoking user's XDG cache.",
        },
    },
    .{
        .action = "list-updates",
        .type_name = "all",
        .action_code = 'P',
        .type_code = 'x',
        .help = .{
            .description = "Query available updates from every supported package backend, continuing through independent backend failures.",
            .implementation = "Combined Zig coordinator over AlpmManager, appimage.UpdateManager, AurManager, and FlatpakManager",
        },
    },
    .{
        .action = "list-updates",
        .type_name = "standard",
        .action_code = 'P',
        .type_code = 's',
        .help = .{ .implementation = "Zigalpm.AlpmManager.sync_for_update_check / get_updates_available" },
    },
    .{
        .action = "list",
        .type_name = "standard",
        .action_code = 'L',
        .type_code = 's',
        .help = .{
            .description = "List packages installed in the local ALPM database, with optional IgnorePkg and install-reason filters.",
            .implementation = "Zigalpm.AlpmManager.get_installed_packages",
        },
    },
    .{
        .action = "backup",
        .type_name = "utility",
        .action_code = 'B',
        .type_code = null,
        .default_for_action = true,
        .help = .{
            .description = "Back up explicitly installed standard packages, AUR packages, and Flatpak applications as type-grouped TOML.",
            .options = &.{
                .{ .name = "--export", .description = "Exports a declaritive list of explicitly installed standard packages, AUR packages, and Flatpak applications" },
                .{ .name = "--import", .description = "Imports a previously exported backup and installs the latest versions of all items listed" },
            },
        },
    },
    .{
        .action = "utility",
        .type_name = "utility",
        .action_code = 'T',
        .type_code = null,
        .default_for_action = true,
        .help = .{
            .description = "Run Shelly maintenance, pacnew/pacsave management, and command-catalog generators.",
            .implementation = "Native Zig ownership repair; Zigalpm.PacfileManager pacdiff workflow; Markdown documentation and Bash/Fish/Zsh completion generators",
            .options = &.{
                .{ .name = "--fix-permissions", .description = "Restore the invoking user's ownership of Shelly's configuration, cache, and data directories" },
                .{ .name = "--repair-db", .description = "Remove a stale database lock" },
                .{ .name = "--docs", .description = "Write Markdown CLI reference documentation to standard output" },
                .{ .name = "--completions", .description = "Write a Bash, Fish, or Zsh completion script to standard output" },
                .{ .name = "--pacfiles", .description = "Run the pacdiff-compatible pacnew, pacorig, and pacsave maintenance workflow" },
            },
        },
    },
    .{
        .action = "purify",
        .type_name = "standard",
        .action_code = 'Z',
        .type_code = 's',
        .help = .{
            .description = "Plan corrupted archives, optional orphan cleanup, and optional cache retention cleanup; show the targets, then confirm before changing ALPM or cache state.",
            .implementation = "Zigalpm.AlpmManager.purify / Zigalpm.alpm.CacheManager",
        },
    },
    .{
        .action = "remove",
        .type_name = "standard",
        .action_code = 'R',
        .type_code = 's',
        .help = .{
            .description = "Remove installed ALPM packages or Shelly-managed local binaries, with optional dependency and configuration cleanup.",
            .implementation = "Zigalpm.AlpmManager.remove_packages / LocalManager.removeBinaryPackages",
        },
    },
    .{
        .action = "sync",
        .type_name = "standard",
        .action_code = 'Y',
        .type_code = 's',
        .default_for_action = true,
        .help = .{
            .description = "Synchronize the configured ALPM package databases; use --force to refresh databases even when they appear current.",
            .implementation = "Zigalpm.AlpmManager.sync",
            .options = &.{.{
                .name = "--force",
                .description = "Force every configured ALPM package database to refresh",
            }},
        },
    },
    .{
        .action = "update",
        .type_name = "standard",
        .action_code = 'E',
        .type_code = 's',
        .help = .{
            .description = "Update only the named installed ALPM packages after an explicit partial-upgrade warning and confirmation.",
            .implementation = "Zigalpm.AlpmManager.update_packages",
            .arguments = &.{.{
                .name = "packages",
                .description = "One or more installed repository package names to update; partial upgrades are unsupported by Arch Linux and require confirmation",
            }},
        },
    },
    .{
        .action = "install",
        .type_name = "appimage",
        .action_code = 'I',
        .type_code = 'i',
        .help = .{
            .description = "Install a local AppImage into the configured AppImage directory and update Shelly's AppImage metadata database.",
            .implementation = "Zigalpm.AppImageManager.installAppImage",
            .arguments = &.{.{
                .name = "location",
                .description = "Path to an existing file whose extension is .AppImage",
            }},
        },
    },
    .{
        .action = "remove",
        .type_name = "appimage",
        .action_code = 'R',
        .type_code = 'i',
        .help = .{
            .description = "Remove an installed AppImage and optionally delete its associated configuration.",
            .implementation = "Zigalpm.AppImageManager.removeAppImage",
        },
    },
    .{
        .action = "list",
        .type_name = "appimage",
        .action_code = 'L',
        .type_code = 'i',
        .help = .{ .implementation = "Zigalpm.AppImageManager.getAppImagesFromLocalDb" },
    },
    .{
        .action = "upgrade",
        .type_name = "appimage",
        .action_code = 'U',
        .type_code = 'i',
        .help = .{
            .description = "Check every configured AppImage update source and replace each AppImage for which a newer version is available.",
            .implementation = "Zigalpm.appimage.UpdateManager.get_updates / update",
        },
    },
    .{
        .action = "sync",
        .type_name = "appimage",
        .action_code = 'Y',
        .type_code = 'i',
        .help = .{
            .description = "Synchronize extracted AppImage metadata, or configure an installed AppImage's update source with the appimage/url/type overload.",
            .implementation = "Zigalpm.AppImageManager.syncAppImageMeta / Zigalpm.appimage.UpdateManager.configure_updates",
            .arguments = &.{
                .{
                    .name = "appimage",
                    .description = "Optional case-insensitive AppImage name query",
                },
                .{
                    .name = "url",
                    .description = "Update URL or owner/repository value when configuring updates",
                },
                .{
                    .name = "type",
                    .description = "Update source type when configuring updates",
                },
            },
            .options = &.{.{
                .name = "--prerelease",
                .description = "Allow prerelease versions for the configured update source",
            }},
        },
    },
    .{
        .action = "list-updates",
        .type_name = "appimage",
        .action_code = 'P',
        .type_code = 'i',
        .help = .{ .implementation = "Zigalpm.appimage.UpdateManager.get_updates" },
    },
    .{
        .action = "config",
        .type_name = "list",
        .action_code = 'C',
        .type_code = null,
        .default_for_action = true,
        .help = .{
            .description = "List every Shelly configuration value.",
            .implementation = "config_manager.Manager.read",
        },
    },
    .{
        .action = "config",
        .type_name = "get",
        .action_code = 'C',
        .type_code = 'g',
        .help = .{
            .description = "Read a Shelly configuration value.",
            .implementation = "config_manager.Manager.get",
        },
    },
    .{
        .action = "config",
        .type_name = "set",
        .action_code = 'C',
        .type_code = 's',
        .help = .{
            .description = "Set a Shelly configuration value.",
            .implementation = "config_manager.Manager.update",
        },
    },
    .{
        .action = "config",
        .type_name = "reset",
        .action_code = 'C',
        .type_code = 'r',
        .help = .{
            .description = "Reset Shelly configuration to native defaults.",
            .implementation = "config_manager.Manager.reset",
        },
    },
    .{
        .action = "config",
        .type_name = "parallel",
        .action_code = 'C',
        .type_code = 'p',
        .help = .{
            .description = "Set Shelly's parallel download count.",
            .implementation = "config_manager.Manager.update(\"ParallelDownloadCount\", value)",
        },
    },

    .{
        .action = "install",
        .type_name = "aur",
        .action_code = 'I',
        .type_code = 'a',
        .help = .{
            .description = "Fetch, review, build, and install one or more AUR packages, install one package's build dependencies, or install one package at an exact Git commit.",
            .implementation = "Zigalpm.AurManager.installPackages / installDependenciesOnly / installPackageVersion",
            .arguments = &.{.{
                .name = "packages",
                .description = "AUR package names; dependency-only mode accepts one package, while --version requires exactly one package followed by its Git commit",
            }},
            .options = &.{
                .{ .name = "--chroot", .description = "Build packages in a clean chroot with makechrootpkg" },
                .{ .name = "--check", .description = "Enable the PKGBUILD check() function during package builds" },
                .{ .name = "--version", .description = "Install exactly one AUR package from the following Git commit operand" },
            },
        },
    },
    .{
        .action = "remove",
        .type_name = "aur",
        .action_code = 'R',
        .type_code = 'a',
        .help = .{
            .description = "Remove installed AUR packages and optionally remove dependent or optional packages through ALPM.",
            .implementation = "Zigalpm.AurManager.removePackages",
        },
    },
    .{
        .action = "update",
        .type_name = "aur",
        .action_code = 'E',
        .type_code = 'a',
        .help = .{
            .description = "Fetch, review, rebuild, and reinstall only the named AUR packages.",
            .implementation = "Zigalpm.AurManager.updatePackages",
            .arguments = &.{.{
                .name = "packages",
                .description = "One or more AUR package names to rebuild and reinstall",
            }},
            .options = &.{.{
                .name = "--check",
                .description = "Run each PKGBUILD check() function during the rebuild",
            }},
        },
    },
    .{
        .action = "upgrade",
        .type_name = "aur",
        .action_code = 'U',
        .type_code = 'a',
        .help = .{
            .description = "Find installed foreign packages with newer AUR or VCS revisions, then build and install all available upgrades.",
            .implementation = "Zigalpm.AurManager.getPackagesNeedingUpdate / updatePackages",
            .options = &.{
                .{ .name = "--check", .description = "Run each PKGBUILD check() function during AUR upgrade builds" },
                .{ .name = "--singlepane", .description = "Use the shared pacman-style linear output (already the native Zig non-UI output mode)" },
            },
        },
    },
    .{
        .action = "list",
        .type_name = "aur",
        .action_code = 'L',
        .type_code = 'a',
        .help = .{ .implementation = "Zigalpm.AurManager.getInstalledPackages" },
    },
    .{
        .action = "list-updates",
        .type_name = "aur",
        .action_code = 'P',
        .type_code = 'a',
        .help = .{ .implementation = "Zigalpm.AurManager.getPackagesNeedingUpdate" },
    },
    .{
        .action = "search",
        .type_name = "aur",
        .action_code = 'S',
        .type_code = 'a',
        .help = .{
            .description = "Search the AUR RPC, fetch exact package PKGBUILDs, or append high-confidence standard repository matches.",
            .implementation = "Zigalpm.AurManager.searchPackages / fetchPkgbuild; Zigalpm.AlpmManager.get_available_packages when --standard is passed",
            .arguments = &.{.{
                .name = "query",
                .description = "Search words joined for an AUR RPC query, or exact AUR package names when --pkgbuild is passed",
            }},
            .options = &.{
                .{
                    .name = "--standard",
                    .description = "Append high-confidence standard ALPM repository matches to the AUR results",
                },
                .{
                    .name = "--pkgbuild",
                    .description = "Fetch and display the PKGBUILD for each exact AUR package name",
                },
            },
        },
    },
    .{
        .action = "keyring",
        .type_name = "init",
        .action_code = 'K',
        .type_code = 'i',
        .help = .{
            .description = "Initialize the pacman keyring.",
            .implementation = "pacman-key --init",
        },
    },
    .{
        .action = "keyring",
        .type_name = "list",
        .action_code = 'K',
        .type_code = 'l',
        .help = .{
            .description = "List keys in the pacman keyring.",
            .implementation = "pacman-key --list-keys",
        },
    },
    .{
        .action = "keyring",
        .type_name = "refresh",
        .action_code = 'K',
        .type_code = 'r',
        .help = .{
            .description = "Refresh pacman keyring keys from the configured keyserver.",
            .implementation = "pacman-key --refresh-keys",
        },
    },
    .{
        .action = "keyring",
        .type_name = "lsign",
        .action_code = 'K',
        .type_code = 's',
        .help = .{
            .description = "Locally sign one or more keys in the pacman keyring.",
            .implementation = "pacman-key --lsign-key for each requested key",
        },
    },
    .{
        .action = "keyring",
        .type_name = "populate",
        .action_code = 'K',
        .type_code = 'p',
        .help = .{
            .description = "Populate the pacman keyring with default or named distribution keys.",
            .implementation = "pacman-key --populate",
        },
    },
    .{
        .action = "keyring",
        .type_name = "recv",
        .action_code = 'K',
        .type_code = 'v',
        .help = .{
            .description = "Receive one or more keys from the configured or requested keyserver.",
            .implementation = "pacman-key --recv-keys [keys...] [--keyserver server]",
        },
    },
    .{
        .action = "install",
        .type_name = "flatpak",
        .action_code = 'I',
        .type_code = 'f',
        .help = .{
            .description = "Install a Flatpak application, runtime, .flatpakref file, or bundle, or repair an installed Flatpak while preserving its configuration.",
            .implementation = "Zigalpm.flatpak.AppstreamManager.getAllRemoteCatalogs; Zigalpm.FlatpakManager.install_flatpak / install_from_ref_flatpak / install_from_bundle_flatpak / repair_installed_flatpak",
            .arguments = &.{.{
                .name = "package",
                .description = "Application/runtime ID, friendly AppStream name, installed target with --repair, .flatpakref path with --ref-file, or bundle path with --bundle",
            }},
            .options = &.{
                .{ .name = "--user", .description = "Install into the invoking user's Flatpak installation instead of the system installation" },
                .{ .name = "--remote", .description = "Install from this remote instead of resolving a remote from cached AppStream metadata" },
                .{ .name = "--branch", .description = "Install this branch; defaults to stable" },
                .{ .name = "--runtime", .description = "Build a runtime ref instead of an application ref" },
                .{ .name = "--ref-file", .description = "Treat the package operand as a local .flatpakref file" },
                .{ .name = "--bundle", .description = "Treat the package operand as a local Flatpak bundle" },
                .{ .name = "--repair", .description = "Reinstall the installed Flatpak and its dependencies while preserving application configuration" },
            },
        },
    },
    .{
        .action = "update",
        .type_name = "flatpak",
        .action_code = 'E',
        .type_code = 'f',
        .help = .{
            .description = "Update one installed Flatpak application or runtime in its existing user or system installation.",
            .implementation = "Zigalpm.FlatpakManager.update_installed_flatpak",
            .arguments = &.{.{
                .name = "package",
                .description = "Installed Flatpak application/runtime ID or unambiguous friendly name",
            }},
        },
    },
    .{
        .action = "list",
        .type_name = "flatpak",
        .action_code = 'L',
        .type_code = 'f',
        .help = .{
            .description = "List installed Flatpaks, configured system and user remotes, or cached AppStream JSON for one or every remote.",
            .implementation = "Zigalpm.FlatpakManager.list_installed_applications / get_remote_appstream / get_all_remote_appstreams",
            .arguments = &.{
                .{
                    .name = "source",
                    .description = "Use remote to return cached remote AppStream applications instead of installed Flatpaks",
                },
                .{
                    .name = "query",
                    .description = "Remote name, or all; omit it to list the configured system and user remotes",
                },
            },
        },
    },
    .{
        .action = "list-updates",
        .type_name = "flatpak",
        .action_code = 'P',
        .type_code = 'f',
        .help = .{ .implementation = "Zigalpm.FlatpakManager.get_updates_flatpak" },
    },
    .{
        .action = "remove",
        .type_name = "flatpak",
        .action_code = 'R',
        .type_code = 'f',
        .help = .{
            .description = "Remove an installed Flatpak application or runtime, with optional unused dependency and configuration cleanup.",
            .implementation = "Zigalpm.FlatpakManager.find_installed_flatpak / uninstall_flatpak",
        },
    },
    .{
        .action = "run",
        .type_name = "flatpak",
        .action_code = 'X',
        .type_code = 'f',
        .help = .{
            .description = "Launch an installed Flatpak application, stop it with --kill, or list running instances with `run flatpak list`.",
            .implementation = "Zigalpm.FlatpakManager.launch_flatpak / kill_flatpak / get_running_instances_flatpak",
            .options = &.{
                .{
                    .name = "--kill",
                    .description = "Stop the selected application instead of launching it",
                },
                .{
                    .name = "--list",
                    .description = "List running Flatpak applications and process identifiers",
                },
            },
        },
    },
    .{
        .action = "run",
        .type_name = "appimage",
        .action_code = 'X',
        .type_code = 'i',
        .help = .{
            .description = "Launch an installed AppImage, or stop it with --kill.",
            .implementation = "Native AppImage resolution, process spawning, tracking, and signaling",
            .options = &.{.{
                .name = "--kill",
                .description = "Stop the selected application instead of launching it",
            }},
        },
    },
    .{
        .action = "search",
        .type_name = "flatpak",
        .action_code = 'S',
        .type_code = 'f',
        .help = .{
            .description = "Search cached AppStream catalogs from every configured system and user Flatpak remote, with local pagination and remote-reference sizes and permissions.",
            .implementation = "Zigalpm.flatpak.AppstreamManager.getAllRemoteCatalogs; Zigalpm.FlatpakManager.get_remote_ref_info_flatpak",
            .arguments = &.{.{
                .name = "query",
                .description = "Application name or ID matched against the configured remotes' local AppStream catalogs",
            }},
        },
    },
    .{
        .action = "sync",
        .type_name = "flatpak",
        .action_code = 'Y',
        .type_code = 'f',
        .help = .{
            .description = "Update cached AppStream metadata, or add and remove configured system or user Flatpak remotes.",
            .implementation = "Zigalpm.flatpak.AppstreamManager.updateAllAppstreams; Zigalpm.flatpak.RemoteManager.addRemote / removeRemote",
            .arguments = &.{
                .{ .name = "remote", .description = "Select Flatpak remote configuration" },
                .{ .name = "operation", .description = "Add or remove a configured remote" },
                .{ .name = "name", .description = "Flatpak remote name, such as flathub" },
            },
            .options = &.{
                .{ .name = "--remote-url", .description = "Remote URL or .flatpakrepo URL; required for remote add" },
                .{ .name = "--system", .description = "Use system scope; defaults to true" },
                .{ .name = "--gpg-verify", .description = "Enable GPG verification when adding; defaults to true" },
            },
        },
    },
    .{
        .action = "upgrade",
        .type_name = "flatpak",
        .action_code = 'U',
        .type_code = 'f',
        .help = .{
            .description = "Upgrade every application and runtime with an available update in the system and user Flatpak installations.",
            .implementation = "Zigalpm.FlatpakManager.upgrade_flatpaks",
        },
    },
    .{
        .action = "purify",
        .type_name = "flatpak",
        .action_code = 'Z',
        .type_code = 'f',
        .help = .{
            .description = "Plan unused dependency cleanup across system and user Flatpak installations, then show and confirm the targets.",
            .implementation = "Zigalpm.FlatpakManager.remove_unused_dependencies",
        },
    },
};

pub fn argumentsFor(comptime action: []const u8, comptime type_name: []const u8) []const Argument {
    return staticSlice(Argument, argumentDefinitions(action, type_name));
}

fn argumentDefinitions(comptime action: []const u8, comptime type_name: []const u8) []const Argument {
    if (pathIs(action, type_name, "search", "standard")) return &.{optionalArgument(
        "package",
        "Package name or search term; an exact name without a source modifier opens package details",
    )};
    if (pathIs(action, type_name, "search", "aur")) return &.{repeatedArgument(
        "query",
        1,
        "One or more words joined into the AUR search query",
    )};
    if (pathIs(action, type_name, "search", "flatpak")) return &.{requiredArgument(
        "query",
        "Application name or ID matched against cached AppStream catalogs",
    )};
    if (pathIs(action, type_name, "list", "flatpak")) return &.{
        optionalArgumentWithChoices(
            "source",
            "Use remote to return cached remote AppStream applications",
            &.{"remote"},
        ),
        optionalArgument(
            "query",
            "Remote name, or all; omit to list configured remotes",
        ),
    };

    if (pathIs(action, type_name, "install", "standard")) return &.{repeatedArgument(
        "packages",
        0,
        "Repository names, local package archives, or HTTP(S) package URLs",
    )};
    if (pathIs(action, type_name, "install", "aur")) return &.{repeatedArgument(
        "packages",
        0,
        "AUR package names to fetch, review, build, and install",
    )};
    if (pathIs(action, type_name, "install", "appimage")) return &.{requiredArgument(
        "location",
        "Path to an existing .AppImage file",
    )};
    if (pathIs(action, type_name, "install", "flatpak")) return &.{requiredArgument(
        "package",
        "Flatpak application/runtime ID, friendly AppStream name, .flatpakref path, or bundle path",
    )};

    if (pathIs(action, type_name, "downgrade", "standard")) return &.{optionalArgument(
        "package",
        "Installed ALPM package to downgrade",
    )};
    if (pathIs(action, type_name, "mark", "ignore")) return &.{repeatedArgument(
        "packages",
        0,
        "Package names to add to or remove from IgnorePkg",
    )};
    if (pathIs(action, type_name, "mark", "hold")) return &.{repeatedArgument(
        "packages",
        0,
        "Package names to add to or remove from HoldPkg",
    )};
    if (pathIs(action, type_name, "mark", "explicit") or
        pathIs(action, type_name, "mark", "dependency")) return &.{requiredArgument(
        "package",
        "Installed package whose reason should be changed",
    )};
    if (pathIs(action, type_name, "remove", "standard") or
        pathIs(action, type_name, "remove", "aur")) return &.{repeatedArgument(
        "packages",
        0,
        "Packages to remove",
    )};
    if (pathIs(action, type_name, "remove", "appimage")) return &.{requiredArgument(
        "appimage",
        "Installed AppImage to remove",
    )};
    if (pathIs(action, type_name, "remove", "flatpak")) return &.{requiredArgument(
        "package",
        "Installed Flatpak application or runtime ID",
    )};

    if (pathIs(action, type_name, "update", "standard") or
        pathIs(action, type_name, "update", "aur")) return &.{repeatedArgument(
        "packages",
        0,
        "Named packages to update",
    )};
    if (pathIs(action, type_name, "update", "flatpak")) return &.{requiredArgument(
        "package",
        "Flatpak application or runtime to update",
    )};
    if (pathIs(action, type_name, "sync", "appimage")) return &.{
        optionalArgument(
            "appimage",
            "Case-insensitive AppImage name query; omit to synchronize every AppImage",
        ),
        optionalArgument(
            "url",
            "Update URL or owner/repository value for the configuration overload",
        ),
        optionalArgumentWithChoices(
            "type",
            "Update source type for the configuration overload",
            &.{ "None", "StaticUrl", "GitHub", "GitLab", "Codeberg", "Forgejo" },
        ),
    };
    if (pathIs(action, type_name, "sync", "flatpak")) return &.{
        optionalArgumentWithChoices(
            "mode",
            "Use remote to configure Flatpak remotes; omit to update AppStream metadata",
            &.{"remote"},
        ),
        optionalArgumentWithChoices(
            "operation",
            "Remote operation",
            &.{ "add", "remove" },
        ),
        optionalArgument(
            "name",
            "Flatpak remote name, such as flathub",
        ),
    };

    if (pathIs(action, type_name, "config", "get")) return &.{requiredArgument(
        "key",
        "Configuration property name",
    )};
    if (pathIs(action, type_name, "config", "set")) return &.{
        requiredArgument("key", "Configuration property name"),
        requiredArgument("value", "New configuration value"),
    };
    if (pathIs(action, type_name, "config", "parallel")) return &.{integerArgument(
        "downloadCount",
        "Maximum number of parallel downloads",
    )};

    if (pathIs(action, type_name, "search-pkgbuild", "aur")) return &.{repeatedArgument(
        "packages",
        1,
        "AUR package names whose PKGBUILDs should be displayed",
    )};

    if (pathIs(action, type_name, "keyring", "lsign") or
        pathIs(action, type_name, "keyring", "recv")) return &.{repeatedArgument(
        "keys",
        1,
        "One or more key identifiers",
    )};
    if (pathIs(action, type_name, "keyring", "populate")) return &.{repeatedArgument(
        "keys",
        0,
        "Distribution keyring names; omit to populate the defaults",
    )};

    if (pathIs(action, type_name, "run", "flatpak")) return &.{optionalArgument(
        "package",
        "Flatpak application ID or friendly name; use `list` to show running applications",
    )};
    if (pathIs(action, type_name, "run", "appimage"))
        return &.{requiredArgument(
            "package",
            "Installed AppImage name or path",
        )};
    return &.{};
}

pub fn optionsFor(comptime action: []const u8, comptime type_name: []const u8) []const Option {
    return staticSlice(Option, optionDefinitions(action, type_name));
}

pub fn findActionByCode(action_code: u8) ?[]const u8 {
    var result: ?[]const u8 = null;

    for (variants) |variant| {
        if (variant.action_code != action_code) continue;

        if (result) |existing| {
            if (!std.mem.eql(u8, existing, variant.action))
                return null;
        } else {
            result = variant.action;
        }
    }

    return result;
}

fn optionDefinitions(comptime action: []const u8, comptime type_name: []const u8) []const Option {
    if (pathIs(action, type_name, "utility", "utility")) return &.{
        flag("--fix-permissions", &.{"-f"}, "Restore ownership of Shelly's user directories"),
        flag("--repair-db", &.{"-r"}, "Remove a stale database lock"),
        flag("--docs", &.{"-d"}, "Generate Markdown CLI documentation"),
        .{
            .name = "--completions",
            .aliases = &.{"-c"},
            .type = "string",
            .minimumArity = 1,
            .maximumArity = 1,
            .description = "Generate shell completions for bash, fish, or zsh",
            .choices = &.{ "bash", "fish", "zsh" },
        },
        flag("--pacfiles", &.{"-p"}, "Manage pacnew, pacorig, and pacsave files like pacdiff"),
        flag("--find", &.{"-F"}, "Recursively find pacfiles instead of reading the pacman database"),
        flag("--locate", &.{"-l"}, "Find pacfiles with locate instead of reading the pacman database"),
        flag("--pacmandb", &.{"-P"}, "Search backup paths from the local pacman database (default)"),
        flag("--backup", &.{"-b"}, "Save the old original as .bak before overwriting"),
        stringOption("--cachedir", &.{"-C"}, "Package cache directory for three-way base archives; repeat to add directories", false),
        flag("--output", &.{"-o"}, "Print discovered pacfile paths without modifying them"),
        flag("--sudo", &.{"-s"}, "Explicitly request elevation; interactive pacfile maintenance elevates automatically"),
        flag("--threeway", &.{"-3"}, "Use a cached older package as the third input when viewing differences"),
        flag("--nocolor", &.{}, "Disable colored pacfile status output"),
        stringOption("--search-path", &.{}, "Path to scan with --find; repeat to add paths", false),
        stringOption("--diff-program", &.{}, "Diff command, overriding DIFFPROG", false),
        stringOption("--merge-program", &.{}, "Merge command, overriding MERGEPROG", false),
    };
    if (pathIs(action, type_name, "run", "flatpak")) return &.{
        flag("--kill", &.{"-k"}, "Stop the selected application instead of launching it"),
        flag("--list", &.{"-l"}, "List running Flatpaks; equivalent to `run flatpak list`"),
    };
    if (pathIs(action, type_name, "run", "appimage"))
        return &.{flag("--kill", &.{"-k"}, "Stop the selected application instead of launching it")};
    if (pathIs(action, type_name, "search", "standard")) return &.{
        flag("--repos", &.{"-r"}, "List configured ALPM repositories"),
        flag("--available", &.{"-v"}, "Search synchronized ALPM repositories"),
        flag("--installed", &.{"-i"}, "Search the local ALPM database"),
        flag("--local", &.{"-l"}, "Search Shelly-managed local binaries"),
        integerOption("--limit", &.{}, "Maximum results per page"),
        integerOption("--page", &.{}, "One-based result page"),
        flag("--show-hidden", &.{"-w"}, "Include packages hidden through IgnorePkg"),
        flag("--detail", &.{ "--info", "-d" }, "Show complete metadata for an exact package"),
        flag("--group", &.{"-g"}, "List groups or search within a group"),
        flag("--explicit", &.{"-e"}, "Returns only explicitly installed packages"),
        flag("--depends", &.{"-D"}, "Returns only dependency packages"),
    };
    if (pathIs(action, type_name, "search", "aur")) return &.{
        flag(
            "--standard",
            &.{"-s"},
            "Append high-confidence standard repository matches",
        ),
        flag(
            "--pkgbuild",
            &.{"-p"},
            "Fetch and display each exact AUR package PKGBUILD",
        ),
    };
    if (pathIs(action, type_name, "search", "flatpak")) return &.{
        integerOption("--limit", &.{}, "Maximum results per page"),
        integerOption("--page", &.{}, "One-based result page"),
    };

    if (pathIs(action, type_name, "install", "standard")) return &.{
        flag("--build-deps", &.{}, "Install build dependencies"),
        flag("--make-deps", &.{}, "Include make dependencies"),
        flag("--no-deps", &.{"-d"}, "Use the ALPM nodeps transaction flag"),
        flag("--upgrade", &.{"-u"}, "Upgrade standard packages before installing"),
    };
    if (pathIs(action, type_name, "install", "aur")) return &.{
        flag("--build-deps", &.{}, "Install build dependencies"),
        flag("--make-deps", &.{}, "Include make dependencies"),
        flag("--chroot", &.{"-c"}, "Build in a clean chroot"),
        flag("--check", &.{}, "Run the PKGBUILD check() function"),
        flag("--version", &.{"-v"}, "Install one package at the following Git commit"),
    };
    if (pathIs(action, type_name, "install", "flatpak")) return &.{
        flag("--user", &.{}, "Install into the user Flatpak installation"),
        stringOption("--remote", &.{"-r"}, "Remote to install from", false),
        stringOption("--branch", &.{"-b"}, "Branch to install; defaults to stable", false),
        flag("--runtime", &.{}, "Install a runtime instead of an application"),
        flag("--ref-file", &.{"-e"}, "Treat the package operand as a local .flatpakref file"),
        flag("--bundle", &.{"-u"}, "Treat the package operand as a local Flatpak bundle"),
        flag("--repair", &.{"-f"}, "Repair an installed Flatpak while preserving configuration"),
    };

    if (pathIs(action, type_name, "upgrade", "standard")) return &.{flag(
        "--all",
        &.{"-a"},
        "Upgrade standard, AUR, Flatpak, and AppImage backends",
    )};
    if (pathIs(action, type_name, "upgrade", "all")) return &.{
        flag("--no-repo", &.{}, "Skip the standard ALPM backend"),
        flag("--no-aur", &.{}, "Skip the AUR backend"),
        flag("--no-flatpak", &.{}, "Skip the Flatpak backend"),
        flag("--no-appimage", &.{}, "Skip the AppImage backend"),
    };
    if (pathIs(action, type_name, "upgrade", "aur")) return &.{
        flag("--check", &.{}, "Run PKGBUILD check() functions"),
        flag("--singlepane", &.{}, "Use linear single-pane output"),
    };

    if (pathIs(action, type_name, "downgrade", "standard")) return &.{
        flag("--oldest", &.{"-o"}, "Choose the oldest available version"),
        flag("--ignore", &.{"-i"}, "Add the downgraded package to IgnorePkg"),
        flag("--list-options", &.{"-l"}, "List available downgrade versions"),
        stringOption("--target", &.{"-t"}, "Install this exact version-release or package filename", false),
    };
    if (pathIs(action, type_name, "mark", "ignore")) return &.{
        flag("--list", &.{"-l"}, "List packages in IgnorePkg"),
        flag("--add", &.{"-a"}, "Add packages to IgnorePkg"),
        flag("--remove", &.{"-r"}, "Remove packages from IgnorePkg"),
        flag("--clear", &.{"-c"}, "Clear IgnorePkg"),
    };
    if (pathIs(action, type_name, "mark", "hold")) return &.{
        flag("--list", &.{"-l"}, "List packages in HoldPkg"),
        flag("--add", &.{"-a"}, "Add packages to HoldPkg"),
        flag("--remove", &.{"-r"}, "Remove packages from HoldPkg"),
        flag("--clear", &.{"-c"}, "Clear HoldPkg except for Shelly's protected entry"),
    };
    if (pathIs(action, type_name, "news", "standard")) return &.{flag(
        "--all",
        &.{"-a"},
        "Show previously viewed news as well as unread entries",
    )};
    if (pathIs(action, type_name, "cache-clean", "utility")) return &.{
        integerOption("--keep", &.{"-k"}, "Versions to retain for each package"),
        flag("--uninstalled", &.{"-i"}, "Include cached packages no longer installed"),
        flag("--dry-run", &.{"-d"}, "Show the cleanup plan without deleting files"),
        stringOption("--cache-dir", &.{"-c"}, "Package cache directory", false),
        stringOption("--target", &.{"-t"}, "Restrict cleanup to a package target", false),
    };
    if (pathIs(action, type_name, "check-updates", "utility")) return &.{
        flag("--aur", &.{"-a"}, "Include AUR updates"),
        flag("--flatpak", &.{"-l"}, "Include Flatpak updates"),
        flag("--count", &.{"-c"}, "Print only the update count"),
    };
    if (pathIs(action, type_name, "backup", "utility")) return &.{
        flag("--export", &.{"-e"}, "Export the current explicitly installed package state"),
        flag("--import", &.{"-i"}, "Import a previously existing backup toml and install the latest versions of the package."),
        stringOption("--name", &.{"-a"}, "File name without the .toml extension", false),
        stringOption("--directory", &.{"-d"}, "Directory in which to write/read the backup", false),
    };
    if (pathIs(action, type_name, "purify", "standard")) return &.{
        flag("--dry-run", &.{"-d"}, "Show the cleanup plan without changing packages"),
        flag("--orphans", &.{"-o"}, "Include orphaned packages"),
        optionalIntegerOptionWithDefault(
            "--cache",
            &.{"-c"},
            "Remove older cached package versions while retaining this many versions",
            3,
        ),
    };
    if (pathIs(action, type_name, "remove", "standard")) return &.{
        booleanOptionWithDefault("--cascade", &.{"-c"}, "Remove dependencies no longer needed", true),
        flag("--no-cascade", &.{}, "Keep dependencies that become unneeded after removal"),
        flag("--opt-deps", &.{"-o"}, "Remove unused optional dependencies"),
        flag("--ripple", &.{"-i"}, "Remove packages depending on the targets"),
        flag("--remove-config", &.{}, "Remove package configuration files"),
        flag("--local", &.{"-l"}, "Remove Shelly-managed local binaries"),
        flag("--force", &.{"-f"}, "Force local binary removal"),
    };
    if (pathIs(action, type_name, "remove", "aur")) return &.{
        flag("--cascade", &.{"-c"}, "Remove dependencies no longer needed"),
        flag("--opt-deps", &.{"-o"}, "Remove unused optional dependencies"),
        flag("--ripple", &.{"-i"}, "Remove packages depending on the targets"),
    };
    if (pathIs(action, type_name, "remove", "appimage")) return &.{flag(
        "--remove-config",
        &.{},
        "Remove associated AppImage configuration",
    )};
    if (pathIs(action, type_name, "remove", "flatpak")) return &.{
        flag("--remove-unused", &.{"-r"}, "Remove newly unused Flatpak dependencies"),
        flag("--remove-config", &.{}, "Remove associated Flatpak configuration"),
    };
    if (pathIs(action, type_name, "sync", "standard")) return &.{flag(
        "--force",
        &.{"-f"},
        "Refresh databases even when they appear current",
    )};
    if (pathIs(action, type_name, "sync", "appimage")) return &.{ flag(
        "--prerelease",
        &.{"-p"},
        "Allow prerelease updates for the configured AppImage",
    ), .{
        .name = "--configure-updates",
        .description = "Select the AppImage update-configuration overload",
        .hidden = true,
    } };
    if (pathIs(action, type_name, "sync", "flatpak")) return &.{
        stringOption("--remote-url", &.{"-u"}, "Remote URL or .flatpakrepo URL; required when adding", false),
        booleanOptionWithDefault("--system", &.{"-s"}, "Configure the system remote instead of the user remote", true),
        booleanOptionWithDefault("--gpg-verify", &.{"-g"}, "Enable GPG verification for an added remote", true),
    };

    if (pathIs(action, type_name, "update", "aur")) return &.{flag(
        "--check",
        &.{},
        "Run the PKGBUILD check() function",
    )};
    if (pathIs(action, type_name, "list", "standard")) return &.{
        flag("--show-hidden", &.{"-w"}, "Include hidden packages"),
        flag("--explicitOnly", &.{"-e"}, "List explicitly installed packages only"),
        flag("--dependencyOnly", &.{"-d"}, "List dependency-installed packages only"),
    };
    if (pathIs(action, type_name, "list", "aur")) return &.{
        flag("--show-hidden", &.{}, "Include hidden packages"),
        flag("--explicitOnly", &.{"-e"}, "List explicitly installed packages only"),
        flag("--dependencyOnly", &.{"-d"}, "List dependency-installed packages only"),
    };
    if (pathIs(action, type_name, "list-updates", "aur") or
        pathIs(action, type_name, "list-updates", "all")) return &.{flag(
        "--show-hidden",
        &.{},
        "Include hidden packages",
    )};
    if (pathIs(action, type_name, "keyring", "recv")) return &.{stringOption(
        "--keyserver",
        &.{},
        "Keyserver from which to receive keys",
        false,
    )};

    return &.{};
}

fn staticSlice(comptime T: type, comptime values: []const T) []const T {
    return &struct {
        const data: [values.len]T = values[0..values.len].*;
    }.data;
}

fn pathIs(
    action: []const u8,
    type_name: []const u8,
    expected_action: []const u8,
    expected_type: []const u8,
) bool {
    return std.mem.eql(u8, action, expected_action) and
        std.mem.eql(u8, type_name, expected_type);
}

fn requiredArgument(name: []const u8, description: []const u8) Argument {
    return .{ .name = name, .minimumArity = 1, .maximumArity = 1, .description = description };
}

fn optionalArgument(name: []const u8, description: []const u8) Argument {
    return .{ .name = name, .minimumArity = 0, .maximumArity = 1, .description = description };
}

fn optionalArgumentWithChoices(
    name: []const u8,
    description: []const u8,
    choices: []const []const u8,
) Argument {
    return .{
        .name = name,
        .minimumArity = 0,
        .maximumArity = 1,
        .description = description,
        .choices = choices,
    };
}

fn repeatedArgument(name: []const u8, minimum: usize, description: []const u8) Argument {
    return .{ .name = name, .type = "string[]", .minimumArity = minimum, .maximumArity = null, .description = description };
}

fn integerArgument(name: []const u8, description: []const u8) Argument {
    return .{ .name = name, .type = "int", .minimumArity = 1, .maximumArity = 1, .description = description };
}

fn flag(name: []const u8, aliases: []const []const u8, description: []const u8) Option {
    return .{ .name = name, .aliases = aliases, .description = description };
}

fn booleanOptionWithDefault(
    name: []const u8,
    aliases: []const []const u8,
    description: []const u8,
    default_value: bool,
) Option {
    var option = flag(name, aliases, description);
    option.hasExplicitDefault = true;
    option.defaultValue = .{ .bool = default_value };
    return option;
}

fn globalFlag(name: []const u8, aliases: []const []const u8, description: []const u8) Option {
    var option = flag(name, aliases, description);
    option.recursive = true;
    return option;
}

fn voidOption(
    name: []const u8,
    aliases: []const []const u8,
    description: []const u8,
    recursive: bool,
    built_in: bool,
) Option {
    return .{
        .name = name,
        .aliases = aliases,
        .type = "void",
        .maximumArity = 0,
        .description = description,
        .recursive = recursive,
        .builtIn = built_in,
    };
}

fn integerOption(name: []const u8, aliases: []const []const u8, description: []const u8) Option {
    return .{
        .name = name,
        .aliases = aliases,
        .type = "int",
        .minimumArity = 1,
        .maximumArity = 1,
        .description = description,
    };
}

fn optionalIntegerOptionWithDefault(
    name: []const u8,
    aliases: []const []const u8,
    description: []const u8,
    default_value: i64,
) Option {
    return .{
        .name = name,
        .aliases = aliases,
        .type = "uint",
        .minimumArity = 0,
        .maximumArity = 1,
        .description = description,
        .hasExplicitDefault = true,
        .defaultValue = .{ .integer = default_value },
    };
}

fn stringOption(
    name: []const u8,
    aliases: []const []const u8,
    description: []const u8,
    required: bool,
) Option {
    return .{
        .name = name,
        .aliases = aliases,
        .type = "string",
        .minimumArity = 1,
        .maximumArity = 1,
        .required = required,
        .description = description,
    };
}

pub const SharedModifier = struct {
    action: []const u8,
    type_names: []const []const u8,
    name: []const u8,
    aliases: []const []const u8,
    description: []const u8,

    pub fn appliesTo(self: SharedModifier, action: []const u8, type_name: []const u8, option_name: []const u8) bool {
        if (!std.mem.eql(u8, self.action, action)) return false;
        for (self.type_names) |candidate| {
            if (std.mem.eql(u8, candidate, type_name))
                return std.mem.eql(u8, self.name, option_name);
        }
        return false;
    }
};

// Shared semantic modifiers are defined once here. A type still receives only
// the modifiers that apply to it; all other source options remain type-specific.
pub const shared_modifiers = [_]SharedModifier{
    .{
        .action = "install",
        .type_names = &.{ "standard", "aur" },
        .name = "--build-deps",
        .aliases = &.{"-b"},
        .description = "Install build dependencies for the requested packages",
    },
    .{
        .action = "install",
        .type_names = &.{ "standard", "aur" },
        .name = "--make-deps",
        .aliases = &.{"-m"},
        .description = "Install make dependencies for the requested packages",
    },
    .{
        .action = "remove",
        .type_names = &.{ "standard", "aur" },
        .name = "--cascade",
        .aliases = &.{"-c"},
        .description = "Remove dependencies that are no longer needed",
    },
    .{
        .action = "remove",
        .type_names = &.{ "standard", "aur" },
        .name = "--opt-deps",
        .aliases = &.{"-o"},
        .description = "Remove unused optional dependencies installed with the packages",
    },
    .{
        .action = "remove",
        .type_names = &.{ "standard", "aur" },
        .name = "--ripple",
        .aliases = &.{"-i"},
        .description = "Remove packages that depend on the removed packages",
    },
    .{
        .action = "remove",
        .type_names = &.{ "standard", "flatpak", "appimage" },
        .name = "--remove-config",
        .aliases = &.{},
        .description = "Remove configuration associated with the removed package",
    },
    .{
        .action = "search",
        .type_names = &.{ "standard", "flatpak" },
        .name = "--limit",
        .aliases = &.{"-t"},
        .description = "Maximum number of search results to return per page",
    },
    .{
        .action = "search",
        .type_names = &.{ "standard", "flatpak" },
        .name = "--page",
        .aliases = &.{"-p"},
        .description = "Page number for paginated results",
    },
};

pub fn findVariantByCodes(action_code: u8, type_code: u8) ?*const Variant {
    for (&variants) |*variant| {
        if (variant.action_code == action_code and variant.type_code == type_code) return variant;
    }
    return null;
}

pub fn findStandaloneVariantByActionCode(action_code: u8) ?*const Variant {
    for (&variants) |*variant| {
        if (variant.action_code == action_code and
            variant.type_code == null and
            variant.default_for_action)
            return variant;
    }
    return null;
}

pub fn findTypeByCode(code: u8) ?Type {
    for (types) |command_type| {
        if (command_type.code == code) return command_type;
    }
    return null;
}

pub fn findTypeByName(name: []const u8) ?Type {
    for (types) |command_type| {
        if (std.mem.eql(u8, command_type.name, name)) return command_type;
    }
    return null;
}

pub fn findSharedModifier(action: []const u8, type_name: []const u8, option_name: []const u8) ?SharedModifier {
    for (shared_modifiers) |modifier| {
        if (modifier.appliesTo(action, type_name, option_name)) return modifier;
    }
    return null;
}

pub fn actionDescription(action: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, action, "search"))
        return "Search ALPM repositories, the AUR, or cached Flatpak AppStream catalogs.";
    if (std.mem.eql(u8, action, "install"))
        return "Install packages or applications from ALPM repositories, the AUR, AppImages, Flatpak remotes, or local Flatpak files, and repair installed Flatpaks.";
    if (std.mem.eql(u8, action, "upgrade"))
        return "Upgrade standard, AUR, AppImage, or Flatpak packages, including all supported backends together.";
    if (std.mem.eql(u8, action, "list"))
        return "List installed standard packages, AppImages, AUR packages, or Flatpak applications.";
    if (std.mem.eql(u8, action, "list-updates"))
        return "List available updates for standard, AUR, AppImage, or Flatpak packages.";
    if (std.mem.eql(u8, action, "purify"))
        return "Remove corrupted or orphaned ALPM packages, optionally clean the package cache, or remove unused Flatpak dependencies.";
    if (std.mem.eql(u8, action, "remove"))
        return "Remove standard or local packages, AUR packages, AppImages, or Flatpak applications.";
    if (std.mem.eql(u8, action, "sync"))
        return "Synchronize ALPM package databases, AppImage metadata, or cached Flatpak AppStream metadata.";
    if (std.mem.eql(u8, action, "update"))
        return "Update selected standard, AUR, or Flatpak packages.";
    if (std.mem.eql(u8, action, "downgrade"))
        return "Select and install an older version of a standard package.";
    if (std.mem.eql(u8, action, "news"))
        return "Read Arch Linux news and track viewed entries.";
    if (std.mem.eql(u8, action, "backup"))
        return "Back up explicitly installed packages as type-grouped TOML.";
    if (std.mem.eql(u8, action, "utility"))
        return "Repair Shelly directory ownership, manage pacfiles, or generate CLI documentation and shell completions.";
    if (std.mem.eql(u8, action, "mark"))
        return "Manage IgnorePkg and HoldPkg package marks, or change an installed package's explicit/dependency reason.";
    if (std.mem.eql(u8, action, "keyring"))
        return "Initialize, inspect, refresh, populate, receive, or locally sign keys in the pacman keyring.";
    if (std.mem.eql(u8, action, "config"))
        return "Read and modify Shelly configuration.";
    if (std.mem.eql(u8, action, "run"))
        return "Launch or stop a Flatpak or AppImage application.";
    return null;
}

pub fn descriptionFor(variant: Variant) []const u8 {
    if (variant.help.description) |description| return description;
    if (pathIs(variant.action, variant.type_name, "list", "standard"))
        return "List packages installed in the local ALPM database.";
    if (pathIs(variant.action, variant.type_name, "list", "appimage"))
        return "List installed AppImages.";
    if (pathIs(variant.action, variant.type_name, "list", "aur"))
        return "List installed foreign packages tracked as AUR packages.";
    if (pathIs(variant.action, variant.type_name, "list", "flatpak"))
        return "List installed Flatpak applications and runtimes.";
    if (pathIs(variant.action, variant.type_name, "list-updates", "standard"))
        return "List available standard repository package updates.";
    if (pathIs(variant.action, variant.type_name, "list-updates", "appimage"))
        return "List installed AppImages with available updates.";
    if (pathIs(variant.action, variant.type_name, "list-updates", "aur"))
        return "List installed AUR packages with available updates.";
    if (pathIs(variant.action, variant.type_name, "list-updates", "flatpak"))
        return "List Flatpak applications and runtimes with available updates.";
    if (pathIs(variant.action, variant.type_name, "purify", "standard"))
        return "Remove corrupted or orphaned standard packages and optionally clean older cached package versions.";
    if (pathIs(variant.action, variant.type_name, "purify", "flatpak"))
        return "Remove unused Flatpak dependencies.";
    if (pathIs(variant.action, variant.type_name, "remove", "standard"))
        return "Remove ALPM packages or Shelly-managed local binaries.";
    if (pathIs(variant.action, variant.type_name, "remove", "aur"))
        return "Remove installed AUR packages through ALPM.";
    if (pathIs(variant.action, variant.type_name, "remove", "appimage"))
        return "Remove an installed AppImage.";
    if (pathIs(variant.action, variant.type_name, "remove", "flatpak"))
        return "Remove an installed Flatpak application or runtime.";
    if (pathIs(variant.action, variant.type_name, "update", "standard"))
        return "Update named standard repository packages.";
    if (pathIs(variant.action, variant.type_name, "update", "aur"))
        return "Review, rebuild, and reinstall named AUR packages.";
    if (pathIs(variant.action, variant.type_name, "update", "flatpak"))
        return "Update one Flatpak application or runtime.";
    return actionDescription(variant.action) orelse "Run the selected native Shelly operation.";
}

pub fn hasActionCode(code: u8) bool {
    for (variants) |variant| {
        if (variant.action_code == code) return true;
    }
    return false;
}

test "shortcode action-type pairs are unique" {
    for (variants, 0..) |variant, index| {
        if (variant.action_code == null or variant.type_code == null) continue;
        for (variants[index + 1 ..]) |other| {
            if (other.action_code == null or other.type_code == null) continue;
            try std.testing.expect(
                variant.action_code.? != other.action_code.? or
                    variant.type_code.? != other.type_code.?,
            );
        }
    }
}

test "every shared modifier is actually shared" {
    for (shared_modifiers) |modifier| {
        try std.testing.expect(modifier.type_names.len >= 2);
    }
}

test "an action has at most one default type" {
    for (variants, 0..) |variant, index| {
        if (!variant.default_for_action) continue;
        for (variants[index + 1 ..]) |other| {
            try std.testing.expect(
                !other.default_for_action or !std.mem.eql(u8, variant.action, other.action),
            );
        }
    }
}

test "remove variants expose native help and modifier aliases" {
    for ([_]u8{ 's', 'i', 'a', 'f' }) |type_code| {
        const variant = findVariantByCodes('R', type_code).?;
        try std.testing.expect(variant.help.description != null);
        try std.testing.expect(variant.help.implementation != null);
    }

    inline for (.{ "standard", "aur" }) |type_name| {
        const options = optionsFor("remove", type_name);
        for ([_]struct { name: []const u8, alias: []const u8 }{
            .{ .name = "--cascade", .alias = "-c" },
            .{ .name = "--opt-deps", .alias = "-o" },
            .{ .name = "--ripple", .alias = "-i" },
        }) |expected| {
            var found = false;
            for (options) |option| {
                if (!std.mem.eql(u8, option.name, expected.name)) continue;
                found = option.matches(expected.alias);
                break;
            }
            try std.testing.expect(found);
        }
    }

    const standard_options = optionsFor("remove", "standard");
    var found_no_cascade = false;
    for (standard_options) |option| {
        if (std.mem.eql(u8, option.name, "--cascade")) {
            try std.testing.expect(option.hasExplicitDefault);
            try std.testing.expect(option.defaultValue.?.bool);
        }
        if (std.mem.eql(u8, option.name, "--no-cascade")) {
            found_no_cascade = true;
            break;
        }
    }
    try std.testing.expect(found_no_cascade);
}
