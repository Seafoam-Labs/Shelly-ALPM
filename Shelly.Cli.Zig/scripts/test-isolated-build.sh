#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
fixture_dir=$(mktemp -d /tmp/shelly-isolated-build.XXXXXX)
cleanup() {
  rm -rf -- "$fixture_dir"
}
trap cleanup EXIT

printf '%s\n' \
  "pkgname=shelly-isolated-smoke" \
  "pkgver=1" \
  "pkgrel=1" \
  "arch=('any')" \
  "license=('MIT')" \
  "package() {" \
  "  install -Dm644 /dev/null \"\$pkgdir/usr/share/shelly-isolated-smoke/marker\"" \
  "  chown root:root \"\$pkgdir/usr/share/shelly-isolated-smoke/marker\"" \
  "}" >"$fixture_dir/PKGBUILD"

if [[ ! -x "$project_dir/zig-out/bin/shelly" ]]; then
  env ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-/tmp/shelly-zig-global-cache}" \
    zig build --build-file "$project_dir/build.zig"
fi

"$project_dir/zig-out/bin/shelly" build \
  --isolated \
  --reviewed \
  --no-confirm \
  --no-check \
  --noverify \
  "$fixture_dir/PKGBUILD"

artifact="$fixture_dir/shelly-isolated-smoke-1-1-any.pkg.tar.zst"
test -f "$artifact"
test "$(stat -c %u "$artifact")" = "$(id -u)"
printf 'isolated build smoke test passed: %s\n' "$artifact"
