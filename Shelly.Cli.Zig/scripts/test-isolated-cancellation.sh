#!/usr/bin/env bash
set -euo pipefail

if [[ $(id -u) -eq 0 ]]; then
  printf 'run this test from the normal invoking-user session, not directly as root\n' >&2
  exit 77
fi
for command in systemd-nspawn unshare pgrep ps; do
  if ! command -v "$command" >/dev/null; then
    printf 'skipping isolated cancellation test: %s is unavailable\n' "$command" >&2
    exit 77
  fi
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
fixture_dir=$(mktemp -d /tmp/shelly-isolated-cancel.XXXXXX)
active_shelly_pid=""
observed_pids=()
elevator=${SHELLY_ELEVATOR:-sudo}
test_elevator=$elevator
cleanup() {
  if [[ -n $active_shelly_pid ]]; then
    kill -KILL "$active_shelly_pid" 2>/dev/null || true
    wait "$active_shelly_pid" 2>/dev/null || true
  fi
  if ((${#observed_pids[@]})); then
    "$test_elevator" kill -KILL "${observed_pids[@]}" 2>/dev/null || true
  fi
  rm -rf -- "$fixture_dir"
}
trap cleanup EXIT

# The Shelly process must run in the background so this fixture can send a
# signal specifically to its original PID. An uncached sudo prompt in that
# background process cannot safely read from the controlling terminal. Prompt
# once in the foreground, then make every test-time sudo call fail instead of
# trying to prompt again.
if [[ ${elevator##*/} == sudo ]]; then
  printf 'Authenticating sudo before starting the background cancellation test...\n' >&2
  "$elevator" -v
  sudo_path=$(command -v -- "$elevator")
  test_elevator="$fixture_dir/sudo-noninteractive"
  printf '#!/usr/bin/env bash\nexec %q -n "$@"\n' "$sudo_path" >"$test_elevator"
  chmod 0755 "$test_elevator"
fi

if [[ -z ${SHELLY_BIN:-} ]]; then
  env ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-/tmp/shelly-zig-global-cache}" \
    zig build --build-file "$project_dir/build.zig"
  shelly_bin="$project_dir/zig-out/bin/shelly"
else
  shelly_bin=$SHELLY_BIN
fi

printf '%s\n' \
  'pkgname=shelly-isolated-cancel' \
  'pkgver=1' \
  'pkgrel=1' \
  "arch=('any')" \
  'build() { sleep 300; }' \
  'package() { install -Dm644 /dev/null "$pkgdir/usr/share/shelly-isolated-cancel/marker"; }' \
  >"$fixture_dir/PKGBUILD"

collect_descendants() {
  local parent=$1 child
  while read -r child; do
    [[ -n $child ]] || continue
    observed_pids+=("$child")
    collect_descendants "$child"
  done < <(pgrep -P "$parent" 2>/dev/null || true)
}

run_case() {
  local signal=$1
  local case_dir="$fixture_dir/$signal"
  local status nspawn_pid nspawn_args root_path operation_path
  mkdir "$case_dir" "$case_dir/packages"
  SHELLY_ELEVATOR="$test_elevator" "$shelly_bin" build \
    --isolated \
    --nosign \
    --no-confirm \
    --reviewed \
    --no-check \
    --noverify \
    --package-destination "$case_dir/packages" \
    --json \
    "$fixture_dir/PKGBUILD" >"$case_dir/stdout" 2>"$case_dir/stderr" &
  active_shelly_pid=$!

  for _ in $(seq 1 2400); do
    grep -q 'Running unprivileged nspawn build' "$case_dir/stderr" 2>/dev/null && break
    kill -0 "$active_shelly_pid" 2>/dev/null || break
    sleep 0.05
  done
  grep -q 'Running unprivileged nspawn build' "$case_dir/stderr"

  observed_pids=()
  collect_descendants "$active_shelly_pid"
  nspawn_pid=""
  for pid in "${observed_pids[@]}"; do
    if [[ $(ps -o comm= -p "$pid" 2>/dev/null) == systemd-nspawn ]]; then
      nspawn_pid=$pid
      break
    fi
  done
  [[ -n $nspawn_pid ]]
  nspawn_args=$(ps -o args= -p "$nspawn_pid")
  root_path=$(sed -n 's|.*--directory \([^ ]*\).*|\1|p' <<<"$nspawn_args")
  [[ $root_path == /var/lib/shelly/build-roots/v1/operations/*/root ]]
  operation_path=${root_path%/root}

  kill -s "$signal" "$active_shelly_pid"
  if wait "$active_shelly_pid"; then
    status=0
  else
    status=$?
  fi
  active_shelly_pid=""
  [[ $status -eq 130 ]]

  for _ in $(seq 1 400); do
    remaining=0
    for pid in "${observed_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then remaining=1; fi
    done
    ((remaining == 0)) && break
    sleep 0.05
  done
  for pid in "${observed_pids[@]}"; do
    ! kill -0 "$pid" 2>/dev/null
  done
  observed_pids=()

  [[ $(wc -l <"$case_dir/stdout") -eq 1 ]]
  [[ $(grep -o '"schemaVersion"' "$case_dir/stdout" | wc -l) -eq 1 ]]
  grep -q '"success":false' "$case_dir/stdout"
  grep -q '"code":"Cancelled"' "$case_dir/stdout"
  "$test_elevator" test ! -e "$operation_path"
}

run_case INT
run_case TERM
printf 'isolated elevation cancellation integration test passed\n'
