#!/usr/bin/env bash
# Build the Flatpak backend and CLI, then build this project and optionally run it.
# Usage: ./build.sh [--build-only] [zig build args...]
# Example: ./build.sh -Doptimize=ReleaseFast
set -euo pipefail
cd "$(dirname "$0")"

RUN_AFTER_BUILD=1
if [[ "${1:-}" == "--build-only" ]]; then
    RUN_AFTER_BUILD=0
    shift
fi

CLI_DIR="../Shelly.Cli.Zig"
FLATPAK_BACKEND_DIR="../Shelly.Flatpak.Backend"

echo "==> Building Flatpak backend ($FLATPAK_BACKEND_DIR)..."
( cd "$FLATPAK_BACKEND_DIR" && zig build "$@" )

FLATPAK_BACKEND_PATH="$(cd "$FLATPAK_BACKEND_DIR" && pwd)/zig-out/lib/libshelly-flatpak-backend.so.1"
if [[ ! -e "$FLATPAK_BACKEND_PATH" ]]; then
    echo "error: expected Flatpak backend not found at $FLATPAK_BACKEND_PATH" >&2
    exit 1
fi

echo "==> Building CLI ($CLI_DIR)..."
( cd "$CLI_DIR" && zig build "$@" -Dflatpak-backend-path="$FLATPAK_BACKEND_PATH" )

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
