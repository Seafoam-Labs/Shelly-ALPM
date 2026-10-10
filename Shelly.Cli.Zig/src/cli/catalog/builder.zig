const types = @import("types.zig");

const flag = types.flag;
const stringOption = types.stringOption;

fn hiddenFlag(name: []const u8, description: []const u8) types.Option {
    var option = types.flag(name, &.{}, description);
    option.hidden = true;
    return option;
}

fn hiddenStringOption(name: []const u8, description: []const u8) types.Option {
    var option = types.stringOption(name, &.{}, description, false);
    option.hidden = true;
    return option;
}

pub const variants = [_]types.Variant{.{
    .action = .build,
    .name = "build",
    .default_for_action = true,
    .description = "Builds a PKGBUILD into an installable package",
    .options = &.{
        flag("--reviewed", &.{"-r"}, "Marks the package as reviewed"),
        flag("--resolve-dependencies", &.{}, "Resolves a pinned isolated build environment without installing packages"),
        stringOption("--dependency-plan", &.{}, "Requires the pinned JSON environment plan for an isolated build", false),
        hiddenFlag("--review-build-environment", "Includes the complete pinned environment in coordinator review"),
        flag("--review-only", &.{}, "Reviews evaluated PKGBUILD inputs and emits JSON without building"),
        stringOption("--review-digest", &.{}, "Requires an accepted 64-character SHA-256 review digest", false),
        stringOption("--package-destination", &.{}, "Writes packages to an existing absolute directory", false),
        stringOption("--compression-level", &.{}, "Selects archive compression preset 1-5: conservative, fast, balanced, compact, maximum; omission uses configured or library defaults", false),
        flag("--makesrcinfo", &.{}, "Generates SRCINFO; when pkgver() exists, prepares sources and updates PKGBUILD version first"),
        flag("--sync-deps", &.{"-s"}, "Installs missing dependencies"),
        flag("--check", &.{"-c"}, "Performs check on PKGBUILD and installs check depends"),
        flag("--no-check", &.{}, "Skips the PKGBUILD check() function"),
        flag("--sign", &.{}, "Signs the resulting packages with GPG"),
        flag("--nosign", &.{}, "Skips signing the resulting packages"),
        stringOption("--key", &.{}, "Specifies the GPG key used for package signing", false),
        flag("--noverify", &.{}, "Skips the PKGBUILD verify() function"),
        flag("--isolated", &.{"-i"}, "Builds as an unprivileged user in a fresh systemd-nspawn root"),
        flag("--install", &.{"-l"}, "Installs the built packages after a successful build (with --sync-deps this mirrors makepkg -si; -i is --isolated, not install)"),
        hiddenFlag("--coordinator-child", "Runs as a non-root child of an elevated package operation"),
        hiddenFlag("--prepare-isolated-source-keys", "Prepares approved public source keys as the invoking user"),
        hiddenStringOption("--apply-pkgver", "Applies a validated isolated version change as the invoking user"),
        hiddenStringOption("--pkgver-original-sha256", "Requires the original PKGBUILD checksum before version writeback"),
        hiddenFlag("--isolated-source-keys", "Imports the coordinator's public source keys in the guest"),
        hiddenFlag("--review-dependencies", "Includes evaluated dependency resolution in coordinator review transport"),
        hiddenFlag("--review-host-dependencies", "Resolves coordinator review dependencies against the host package state"),
        hiddenStringOption("--artifact-report", "Writes built artifact names and paths for the elevated coordinator to install"),
        hiddenStringOption("--package", "Builds only the selected split-package member; repeatable"),
        hiddenFlag("--skip-source-pgp-verification", "Skips source PGP verification for coordinator builds"),
        hiddenFlag("--no-overwrite", "Rejects an existing package artifact"),
        hiddenFlag("--keep-workdirs", "Keeps src and pkg work directories after success"),
    },
    .arguments = &.{types.optionalArgument("pkgbuild", "File path of PKGBUILD. If left empty will look in executed directory for file named PKGBUILD.")},
}};
