#!/usr/bin/env bash
# Build the Flatpak backend and the CLI with the Devario native package
# backend, then build this project and optionally run it.
# Usage: ./build.sh [--build-only] [zig build args...]
# Example: ./build.sh -Doptimize=fast
#
# The CLI embeds the native package backend (RLPM, plus libalpm when its
# development files are available). Devario is the primary development
# target, so the CLI defaults to the devario path profile; set
# SHELLY_PATH_PROFILE=pacman for Arch-style paths. SHELLY_LIBALPM=true|false
# forces the libalpm backend on/off; the default (auto) probes pkg-config.
set -euo pipefail
cd "$(dirname "$0")"

RUN_AFTER_BUILD=1
if [[ "${1:-}" == "--build-only" ]]; then
    RUN_AFTER_BUILD=0
    shift
fi

CLI_DIR="../Shelly.Cli.Zig"
FLATPAK_BACKEND_DIR="../Shelly.Flatpak.Backend"

PATH_PROFILE="${SHELLY_PATH_PROFILE:-devario}"
case "$PATH_PROFILE" in
    pacman|devario) ;;
    *) echo "error: SHELLY_PATH_PROFILE must be pacman or devario" >&2; exit 1 ;;
esac

LIBALPM="${SHELLY_LIBALPM:-auto}"
case "$LIBALPM" in
    true|false) ;;
    auto)
        pkg_config=$(command -v pkg-config || command -v pkgconf || true)
        if [[ -n "$pkg_config" ]] && "$pkg_config" --exists libalpm; then
            LIBALPM=true
        else
            LIBALPM=false
        fi
        ;;
    *) echo "error: SHELLY_LIBALPM must be true, false, or auto" >&2; exit 1 ;;
esac

echo "==> Updating translations..."
./update-translations.sh

echo "==> Building Flatpak backend ($FLATPAK_BACKEND_DIR)..."
( cd "$FLATPAK_BACKEND_DIR" && zig build "$@" )

FLATPAK_BACKEND_PATH="$(cd "$FLATPAK_BACKEND_DIR" && pwd)/zig-out/lib/libshelly-flatpak-backend.so.1"
if [[ ! -e "$FLATPAK_BACKEND_PATH" ]]; then
    echo "error: expected Flatpak backend not found at $FLATPAK_BACKEND_PATH" >&2
    exit 1
fi

echo "==> Building CLI ($CLI_DIR, path profile $PATH_PROFILE, libalpm=$LIBALPM)..."
( cd "$CLI_DIR" && zig build "$@" -Dflatpak-backend-path="$FLATPAK_BACKEND_PATH" \
    -Dpath-profile="$PATH_PROFILE" -Dlibalpm="$LIBALPM" )

echo "==> Building UI..."
zig build "$@"

EXE_NAME=$(grep -oP '\.name\s*=\s*"\K[^"]+' build.zig | head -n1)
BIN_PATH="zig-out/bin/${EXE_NAME}"

if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: expected binary not found at $BIN_PATH" >&2
    exit 1
fi

if [[ "$RUN_AFTER_BUILD" -eq 1 ]]; then
    echo "==> Running $BIN_PATH"
    exec "$BIN_PATH"
fi
