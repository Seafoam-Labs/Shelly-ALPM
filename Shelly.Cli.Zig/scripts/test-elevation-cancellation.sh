#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
fixture_dir=$(mktemp -d /tmp/shelly-elevation-cancel.XXXXXX)
cleanup() {
  if [[ -n ${active_shelly_pid:-} ]]; then
    kill -KILL "$active_shelly_pid" 2>/dev/null || true
    wait "$active_shelly_pid" 2>/dev/null || true
  fi
  rm -rf -- "$fixture_dir"
}
trap cleanup EXIT

if [[ -z ${SHELLY_BIN:-} ]]; then
  env ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-/tmp/shelly-zig-global-cache}" \
    zig build --build-file "$project_dir/build.zig"
  shelly_bin="$project_dir/zig-out/bin/shelly"
else
  shelly_bin=$SHELLY_BIN
fi

cat >"$fixture_dir/fake-elevator" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
test_dir=${SHELLY_ELEVATION_TEST_DIR:?}
worker_pid=""
cancel() {
  if [[ -n $worker_pid ]]; then
    kill -TERM "$worker_pid" 2>/dev/null || true
    wait "$worker_pid" 2>/dev/null || true
  fi
  : >"$test_dir/cleaned"
  printf '%s\n' '{"schemaVersion":1,"success":false,"packageBase":null,"reviewDigest":null,"isolated":true,"artifacts":[],"error":{"code":"Cancelled","message":"The build was cancelled."}}'
  exit 130
}
trap cancel INT TERM
sleep 300 &
worker_pid=$!
printf '%s %s\n' "$$" "$worker_pid" >"$test_dir/ready"
wait "$worker_pid"
EOF
chmod 0755 "$fixture_dir/fake-elevator"

printf '%s\n' \
  'pkgname=elevation-cancel-fixture' \
  'pkgver=1' \
  'pkgrel=1' \
  "arch=('any')" \
  'package() { :; }' >"$fixture_dir/PKGBUILD"

run_case() {
  local signal=$1
  local case_dir="$fixture_dir/$signal"
  mkdir "$case_dir"
  SHELLY_ELEVATOR="$fixture_dir/fake-elevator" \
    SHELLY_ELEVATION_TEST_DIR="$case_dir" \
    "$shelly_bin" build --isolated --json --no-confirm "$fixture_dir/PKGBUILD" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" &
  active_shelly_pid=$!

  for _ in $(seq 1 400); do
    [[ -f "$case_dir/ready" ]] && break
    kill -0 "$active_shelly_pid" 2>/dev/null || break
    sleep 0.01
  done
  [[ -f "$case_dir/ready" ]]
  read -r elevator_pid worker_pid <"$case_dir/ready"
  kill -s "$signal" "$active_shelly_pid"
  if wait "$active_shelly_pid"; then
    status=0
  else
    status=$?
  fi
  active_shelly_pid=""

  [[ $status -eq 130 ]]
  [[ -f "$case_dir/cleaned" ]]
  ! kill -0 "$elevator_pid" 2>/dev/null
  ! kill -0 "$worker_pid" 2>/dev/null
  [[ $(wc -l <"$case_dir/stdout") -eq 1 ]]
  [[ $(grep -o '"schemaVersion"' "$case_dir/stdout" | wc -l) -eq 1 ]]
  grep -q '"success":false' "$case_dir/stdout"
  grep -q '"code":"Cancelled"' "$case_dir/stdout"
}

run_case INT
run_case TERM
printf 'initial elevation cancellation integration test passed\n'
