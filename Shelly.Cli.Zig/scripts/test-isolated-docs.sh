#!/usr/bin/env bash
# Exercises the a2x -> dblatex -> TeX toolchain in a fresh isolated root.
set -euo pipefail

if [[ $(id -u) -eq 0 ]]; then
  printf 'skipping isolated documentation test: run from a normal user session\n' >&2
  exit 77
fi
for command in sudo systemd-nspawn unshare jq; do
  if ! command -v "$command" >/dev/null; then
    printf 'skipping isolated documentation test: %s is unavailable\n' "$command" >&2
    exit 77
  fi
done
if [[ -t 0 ]]; then
  sudo -v
elif ! sudo -n true; then
  printf 'skipping isolated documentation test: sudo authentication is required\n' >&2
  exit 77
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
if [[ -z ${SHELLY_BIN:-} ]]; then
  (cd -- "$project_dir" && zig build)
  shelly_bin="$project_dir/zig-out/bin/shelly"
else
  shelly_bin=$(realpath -- "$SHELLY_BIN")
fi
fixture_dir=$(mktemp -d /tmp/shelly-isolated-docs.XXXXXX)
cleanup() {
  local status=$?
  if [[ $status -eq 0 ]]; then
    rm -rf -- "$fixture_dir"
  else
    printf 'documentation test failed; fixture and build output retained in %s\n' "$fixture_dir" >&2
  fi
}
trap cleanup EXIT

cat >"$fixture_dir/PKGBUILD" <<'PKGBUILD'
pkgname=shelly-isolated-docs
pkgver=1
pkgrel=1
arch=('any')
license=('MIT')
makedepends=('asciidoc' 'dblatex')
options=('!strip')
build() {
  test "$(id -u)" = 1000
  test -n "$(kpsewhich pdflatex.fmt)"
  test -n "$(kpsewhich pdftex.map)"
  cat >manual.txt <<'MANUAL'
Shelly isolated documentation test
=================================

Introduction
------------
This PDF verifies that package hooks initialized the isolated TeX installation.
MANUAL
  a2x --verbose --format=pdf manual.txt
  test -s manual.pdf
}
package() {
  install -Dm644 manual.pdf "$pkgdir/usr/share/doc/$pkgname/manual.pdf"
}
PKGBUILD

review_json=$("$shelly_bin" build --review-only --json "$fixture_dir/PKGBUILD")
review_digest=$(jq -er '.reviewDigest | select(test("^[0-9a-f]{64}$"))' <<<"$review_json")
"$shelly_bin" build --isolated --sync-deps --no-confirm \
  --review-digest "$review_digest" --no-check --nosign \
  --package-destination "$fixture_dir" "$fixture_dir/PKGBUILD" \
  2>&1 | tee "$fixture_dir/build.log"
artifact="$fixture_dir/shelly-isolated-docs-1-1-any.pkg.tar.zst"
test -s "$artifact"
tar -xOf "$artifact" usr/share/doc/shelly-isolated-docs/manual.pdf >"$fixture_dir/manual.pdf"
test "$(head -c 5 "$fixture_dir/manual.pdf")" = '%PDF-'
printf 'isolated documentation test passed\n'
