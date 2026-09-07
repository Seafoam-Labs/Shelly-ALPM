#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
fixture_dir=$(mktemp -d /tmp/shelly-isolated-build.XXXXXX)
cleanup() {
  rm -rf -- "$fixture_dir"
}
trap cleanup EXIT

printf 'reviewed group-writable input\n' >"$fixture_dir/reviewed.txt"
chmod 0660 "$fixture_dir/reviewed.txt"
source_digest=$(sha256sum "$fixture_dir/reviewed.txt")
source_digest=${source_digest%% *}

printf '%s\n' \
  "pkgname=shelly-isolated-smoke" \
  "pkgver=1" \
  "pkgrel=1" \
  "arch=('any')" \
  "license=('MIT')" \
  "source=('reviewed.txt')" \
  "sha256sums=('$source_digest')" \
  "build() {" \
  "  test \"\$(stat -c %a /build/source/reviewed.txt)\" = 660" \
  "  grep -qx 'reviewed group-writable input' /build/source/reviewed.txt" \
  "  test -s /etc/ld.so.cache" \
  "  grep -q '^systemd-network:' /etc/passwd" \
  "  test -d /var/lib/private" \
  "  test -s /etc/ssl/certs/ca-certificates.crt" \
  "}" \
  "package() {" \
  "  install -Dm644 /dev/null \"\$pkgdir/usr/share/shelly-isolated-smoke/marker\"" \
  "  chown root:root \"\$pkgdir/usr/share/shelly-isolated-smoke/marker\"" \
  "}" >"$fixture_dir/PKGBUILD"

if [[ -z ${SHELLY_BIN:-} ]]; then
  env ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-/tmp/shelly-zig-global-cache}" \
    zig build --build-file "$project_dir/build.zig"
  shelly_bin="$project_dir/zig-out/bin/shelly"
else
  shelly_bin=$SHELLY_BIN
fi

review_json=$("$shelly_bin" build --review-only --json "$fixture_dir/PKGBUILD")
review_digest=$(jq -er '.reviewDigest | select(test("^[0-9a-f]{64}$"))' <<<"$review_json")
jq -e '.relatedFiles[] | select(.name == "reviewed.txt" and .permissions == 432)' \
  <<<"$review_json" >/dev/null

"$shelly_bin" build \
  --isolated \
  --review-digest "$review_digest" \
  --no-confirm \
  --no-check \
  "$fixture_dir/PKGBUILD"

artifact="$fixture_dir/shelly-isolated-smoke-1-1-any.pkg.tar.zst"
test -f "$artifact"
test "$(stat -c %u "$artifact")" = "$(id -u)"
printf 'isolated build smoke test passed: %s\n' "$artifact"
