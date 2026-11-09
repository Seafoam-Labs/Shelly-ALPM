#!/usr/bin/env bash
# build the flatpak backend, cli and tui.
# usage: ./build.sh [--build-only] [zig build args...]
# example: ./build.sh --build-only -Doptimize=ReleaseSafe
set -euo pipefail
cd "$(dirname "$0")"

RUN_AFTER_BUILD=1
CLI_ARGS=()
COMMON_ARGS=()
TUI_BIN=""
for arg in "$@"; do
    case "$arg" in
        --build-only) RUN_AFTER_BUILD=0 ;;
        -Dlibalpm|-Dlibalpm=*|-Dpath-profile=*) CLI_ARGS+=("$arg") ;;
        -Dflatpak-backend-path=*)
            echo "error: this script uses its freshly built flatpak backend" >&2
            exit 1 ;;
        -Dshelly-bin=*) TUI_BIN="${arg#*=}" ;;
        --help|-h)
            echo "usage: ./build.sh [--build-only] [zig build args...]"
            echo "always builds the flatpak backend and requires libflatpak."
            echo "-Dlibalpm and -Dpath-profile go to the CLI only."
            echo "-Dshelly-bin overrides the TUI's CLI path; other arguments go to all builds."
            exit 0 ;;
        *) COMMON_ARGS+=("$arg") ;;
    esac
done
CLI_DIR="../Shelly.Cli.Zig"
FLATPAK_BACKEND_DIR="../Shelly.Flatpak.Backend"

echo "==> Building Flatpak backend ($FLATPAK_BACKEND_DIR)..."
( cd "$FLATPAK_BACKEND_DIR" && zig build "${COMMON_ARGS[@]}" )

FLATPAK_BACKEND_PATH="$(cd "$FLATPAK_BACKEND_DIR" && pwd)/zig-out/lib/libshelly-flatpak-backend.so.1"
if [[ ! -e "$FLATPAK_BACKEND_PATH" ]]; then
    echo "error: expected Flatpak backend not found at $FLATPAK_BACKEND_PATH" >&2
    exit 1
fi
CLI_ARGS+=("-Dflatpak-backend-path=$FLATPAK_BACKEND_PATH")

echo "==> Building CLI ($CLI_DIR)..."
( cd "$CLI_DIR" && zig build "${COMMON_ARGS[@]}" "${CLI_ARGS[@]}" )

CLI_PATH="$(cd "$CLI_DIR" && pwd)/zig-out/bin/shelly"
if [[ ! -x "$CLI_PATH" ]]; then
    echo "error: expected CLI binary not found at $CLI_PATH" >&2
    exit 1
fi

echo "==> Building TUI..."
zig build "${COMMON_ARGS[@]}" -Dshelly-bin="${TUI_BIN:-$CLI_PATH}"

BIN_PATH="zig-out/bin/Shelly_Tui"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: expected binary not found at $BIN_PATH" >&2
    exit 1
fi

if [[ "$RUN_AFTER_BUILD" -eq 1 ]]; then
    echo "==> Running $BIN_PATH"
    exec "$BIN_PATH"
fi
