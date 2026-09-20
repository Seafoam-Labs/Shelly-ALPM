#!/usr/bin/env bash
set -euo pipefail

if [[ $(id -u) -eq 0 ]]; then
  printf 'skipping isolated smoke test: run from an authenticated normal-user session\n' >&2
  exit 77
fi
for command in sudo systemd-nspawn unshare jq pgrep; do
  if ! command -v "$command" >/dev/null; then
    printf 'skipping isolated smoke test: %s is unavailable\n' "$command" >&2
    exit 77
  fi
done
# Authenticate before any supervised build runs in the background.
if [[ -t 0 ]]; then
  sudo -v
elif ! sudo -n true; then
  printf 'skipping isolated smoke test: sudo authentication is required\n' >&2
  exit 77
fi

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

cat >"$fixture_dir/PKGBUILD" <<'PKGBUILD'
pkgname=shelly-isolated-smoke
pkgver=1
pkgrel=1
arch=('any')
license=('MIT')
options=('!strip')
source=('reviewed.txt')
build() {
  test "$(id -u)" = 1000
  test "$(id -g)" = 1000
  test "$PWD" = "$srcdir"
  test -x /build/source
  test -r /etc/shellybuild.conf
  for path in / /build /usr/local/libexec /usr/local/libexec/shelly /usr/local/libexec/shelly/shelly; do
    test "$(stat -c '%u:%g:%a' "$path")" = 0:0:755
  done
  test "$(stat -c '%u:%g:%a' /etc/shellybuild.conf)" = 0:0:644
  for setting in 'build = "/build/work"' 'packages = "/build/artifacts"' 'sources = "/build/sources"' 'logs = "/build/logs"'; do
    grep -Fxq "$setting" /etc/shellybuild.conf
  done
  for path in /build/source /build/artifacts /build/work /build/sources /build/logs /home/shelly-build; do
    test "$(stat -c '%u:%g' "$path")" = 1000:1000
    test -w "$path"
  done
  test "$(stat -c %a /build/source/reviewed.txt)" = 660
  grep -qx 'reviewed group-writable input' /build/source/reviewed.txt
  test -s /etc/ld.so.cache
  grep -q '^systemd-network:' /etc/passwd
  test -d /var/lib/private
  test -s /etc/ssl/certs/ca-certificates.crt
  # Keep the guest alive until the host supervisor checks its private boundary.
  for ((attempt = 0; attempt < 300; attempt++)); do
    if test -r /build/source/.host-boundary-checked; then
      return 0
    fi
    sleep 0.1
  done
  printf 'host operation-boundary check timed out\n' >&2
  return 1
}
package() {
  install -Dm644 /dev/null "$pkgdir/usr/share/shelly-isolated-smoke/marker"
  chown root:root "$pkgdir/usr/share/shelly-isolated-smoke/marker"
  mkdir -p "$pkgdir/usr/info" "$pkgdir/usr/share/info"
  for target in usr/info/dir usr/share/info/dir .packlist smoke.pod; do
    printf 'purge me\n' >"$pkgdir/$target"
  done
}
PKGBUILD
printf "sha256sums=('%s')\n" "$source_digest" >>"$fixture_dir/PKGBUILD"

# This test-only wrapper runs after sudo, so sudo's umask policy cannot mask
# the regression. SUDO_USER/UID/GID continue to identify the normal caller.
cat >"$fixture_dir/root-wrapper" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
mask=$1
shift
umask "$mask"
# Inner review subprocesses use sudo's ordinary -u invocation, not this wrapper.
export SHELLY_ELEVATOR=/usr/bin/sudo
coordinator=""
cleanup() {
  if [[ -n $coordinator ]]; then
    kill -INT "$coordinator" 2>/dev/null || true
    wait "$coordinator" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

find_nspawn_root() {
  local parent=$1 pid index
  local -a arguments
  while read -r pid; do
    [[ -n $pid ]] || continue
    if [[ $(cat "/proc/$pid/comm" 2>/dev/null) == systemd-nspawn ]]; then
      if mapfile -d '' -t arguments <"/proc/$pid/cmdline"; then
        for ((index = 0; index + 1 < ${#arguments[@]}; index++)); do
          if [[ ${arguments[index]} == --directory ]]; then
            printf '%s\n' "${arguments[index + 1]}"
            return 0
          fi
        done
      fi
    fi
    if find_nspawn_root "$pid"; then return 0; fi
  done < <(pgrep -P "$parent" || true)
  return 1
}

"$@" &
coordinator=$!
root_path=""
deadline=$((SECONDS + 300))
while ((SECONDS < deadline)); do
  if root_path=$(find_nspawn_root "$coordinator"); then break; fi
  kill -0 "$coordinator" 2>/dev/null || break
  sleep 0.1
done
[[ $root_path =~ ^/var/lib/shelly/build-roots/v1/operations/[a-f0-9]{32}/root$ ]]
operation_path=${root_path%/root}
test "$(stat -c '%u:%g:%a' "$operation_path")" = 0:0:700
test "$(stat -c '%u:%g:%a' "${operation_path%/*}")" = 0:0:700
actual_mask=$(awk '/^Umask:/ {print $2}' "/proc/$coordinator/status")
test "$actual_mask" = "$mask"
printf '%s\n' "$mask" >"$root_path/build/source/.host-boundary-checked"
chmod 0644 "$root_path/build/source/.host-boundary-checked"
status=0
wait "$coordinator" || status=$?
coordinator=""
test "$status" = 0
test ! -e "$operation_path"
WRAPPER

if [[ -z ${SHELLY_BIN:-} ]]; then
  env ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-/tmp/shelly-zig-global-cache}" \
    zig build --build-file "$project_dir/build.zig"
  shelly_bin="$project_dir/zig-out/bin/shelly"
else
  shelly_bin=$SHELLY_BIN
fi

shelly_bin=$(realpath -- "$shelly_bin")

review_json=$("$shelly_bin" build --review-only --json "$fixture_dir/PKGBUILD")
review_digest=$(jq -er '.reviewDigest | select(test("^[0-9a-f]{64}$"))' <<<"$review_json")
jq -e '.relatedFiles[] | select(.name == "reviewed.txt" and .permissions == 432)' \
  <<<"$review_json" >/dev/null

for mask in 0022 0007 0027 0077; do
  case_dir="$fixture_dir/$mask"
  mkdir "$case_dir"
  # %q preserves literal paths and arguments in the generated shell wrapper.
  printf '#!/usr/bin/env bash\nexec /usr/bin/sudo -n /bin/bash %q %q "$@"\n' \
    "$fixture_dir/root-wrapper" "$mask" >"$case_dir/elevator"
  chmod 0755 "$case_dir/elevator"
  SHELLY_ELEVATOR="$case_dir/elevator" "$shelly_bin" build \
    --isolated \
    --review-digest "$review_digest" \
    --no-confirm \
    --no-check \
    --nosign \
    --package-destination "$case_dir" \
    "$fixture_dir/PKGBUILD"

  artifact="$case_dir/shelly-isolated-smoke-1-1-any.pkg.tar.zst"
  test -f "$artifact"
  test "$(stat -c %u "$artifact")" = "$(id -u)"
  test "$(stat -c %g "$artifact")" = "$(id -g)"
  tar -tf "$artifact" >"$case_dir/archive-entries"
  grep -Fxq 'usr/share/shelly-isolated-smoke/marker' "$case_dir/archive-entries"
  if grep -Exq '(\./)?(usr/info/dir|usr/share/info/dir|\.packlist|smoke\.pod)' "$case_dir/archive-entries"; then
    printf 'isolated package retained a purge target\n' >&2
    exit 1
  fi
  printf 'isolated build smoke test passed with coordinator umask %s\n' "$mask"
done
