#!/usr/bin/env bash
# Build the CLI, then build this project and run it.
# Usage: ./run.sh [zig build args...]
# Example: ./run.sh -Doptimize=ReleaseFast
set -euo pipefail
cd "$(dirname "$0")"

CLI_DIR="../Shelly.Cli.Zig"

echo "==> Building CLI ($CLI_DIR)..."
( cd "$CLI_DIR" && zig build "$@" )

echo "==> Building UI..."
zig build "$@"

# Grab the exe name straight from build.zig so this script
# doesn't need updating if you rename the project.
EXE_NAME=$(grep -oP '\.name\s*=\s*"\K[^"]+' build.zig | head -n1)
BIN_PATH="zig-out/bin/${EXE_NAME}"

if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: expected binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Running $BIN_PATH"
exec "$BIN_PATH"
