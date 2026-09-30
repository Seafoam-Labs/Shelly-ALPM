#!/usr/bin/env bash
# Exercise the deployed CLI's private streams in a directory with no helpers.
set -euo pipefail
cli=$(realpath "${1:?Expected a Shelly executable}")
stage=$(mktemp -d /tmp/shelly-worker-modes.XXXXXXXX)
trap 'rm -rf "$stage"' EXIT
install -m755 "$cli" "$stage/shelly"
cli="$stage/shelly"
export XDG_CONFIG_HOME="$stage/config" XDG_CACHE_HOME="$stage/cache" XDG_DATA_HOME="$stage/data" XDG_STATE_HOME="$stage/state"
unset SUDO_USER SUDO_UID DOAS_USER PKEXEC_UID
# Invalid normal configuration must be irrelevant to either private entry point.
mkdir -p "$XDG_CONFIG_HOME/shelly"
printf '%s\n' '{"NativePackageBackend":"invalid"}' > "$XDG_CONFIG_HOME/shelly/config.json"

frame() {
    local payload=$1 shift byte
    for shift in 0 8 16 24; do
        printf -v byte '\\%03o' "$(((${#payload} >> shift) & 255))"
        printf '%b' "$byte"
    done
    printf '%s' "$payload"
}
invoke() {
    local expected=$1 mode=$2 status=0
    shift 2
    "$cli" "$mode" "$@" < "$stage/input" > "$stage/output" 2> "$stage/error" || status=$?
    if [[ $status != "$expected" ]]; then
        printf 'Worker %s returned %s; expected %s\n' "$mode" "$status" "$expected" >&2
        exit 1
    fi
}
empty_streams() { test ! -s "$stage/output"; test ! -s "$stage/error"; }
protocol_failure() {
    invoke 125 --internal-rlpm-action-worker
    test ! -s "$stage/output"
    test "$(stat -c %s "$stage/error")" = 8
    test "$(od -An -tu1 -N2 "$stage/error" | xargs)" = '1 1'
}
for mode in --internal-download-worker --internal-rlpm-action-worker; do
    : > "$stage/input"
    invoke 2 "$mode" unexpected
    empty_streams
done
# Framing and bounded parsing fail without banners, logs or CLI error formatting.
: > "$stage/input"
protocol_failure
printf '\x20\x00\x00\x00{' > "$stage/input"
protocol_failure
printf '\x01\x00\x10\x00' > "$stage/input"
protocol_failure
frame '{}' > "$stage/input"
protocol_failure
for value in '' '{' '{}'; do
    printf '%s' "$value" > "$stage/input"
    invoke 1 --internal-download-worker
    empty_streams
done
head -c 1048577 /dev/zero > "$stage/input"
invoke 1 --internal-download-worker
empty_streams

frame '{"version":1,"root_descriptor":"/","chroot":false,"command":"/usr/bin/cat","argv":["cat"],"network":"allowed"}' > "$stage/input"
printf 'action stdin and output\n' >> "$stage/input"
invoke 0 --internal-rlpm-action-worker
printf 'action stdin and output\n' > "$stage/expected"
cmp "$stage/expected" "$stage/output"
test ! -s "$stage/error"
frame '{"version":1,"root_descriptor":"/","chroot":false,"command":"/bin/sh","argv":["sh","-c","exit 31"],"network":"allowed"}' > "$stage/input"
invoke 31 --internal-rlpm-action-worker
empty_streams

# A setup failure is also a protocol result, including in an unprivileged run.
printf '{"url":"file:///absent","path":"%s/output.pkg","directory":"%s","user":"shelly-nonexistent-worker-test","filesystem":true,"syscalls":true,"force":true,"timeout":5,"maximum":null,"mtime":null,"partial":null}' "$stage" "$stage" > "$stage/input"
invoke 0 --internal-download-worker
printf '\x0b' > "$stage/expected"
head -c 16 /dev/zero >> "$stage/expected"
cmp "$stage/expected" "$stage/output"
test ! -s "$stage/error"

if [[ ${SHELLY_TEST_DOWNLOAD_SANDBOX:-0} == 1 ]]; then
    test "$(id -u)" = 0
    # In a full subordinate-ID namespace this also tests the real credential drop.
    chmod 755 "$stage"
    mkdir "$stage/download"
    chown nobody: "$stage/download"
    printf 'sandboxed download\n' > "$stage/source"
    chmod 644 "$stage/source"
    printf '{"url":"file://%s/source","path":"%s/download/result","directory":"%s/download","user":"nobody","filesystem":true,"syscalls":true,"force":true,"timeout":5,"maximum":null,"mtime":null,"partial":null}' "$stage" "$stage" "$stage" > "$stage/input"
    invoke 0 --internal-download-worker
    test ! -s "$stage/error"
    cmp "$stage/source" "$stage/download/result"
    test "$(stat -c %u "$stage/download/result")" = "$(id -u nobody)"
    # Every packet is 17 bytes; the final packet reports success.
    test "$(( $(stat -c %s "$stage/output") % 17 ))" = 0
    printf '\x01' > "$stage/expected"
    head -c 16 /dev/zero >> "$stage/expected"
    tail -c 17 "$stage/output" > "$stage/final"
    cmp "$stage/expected" "$stage/final"
else
    printf 'Credential-drop test omitted; enable SHELLY_TEST_DOWNLOAD_SANDBOX=1 in a root or subordinate-ID namespace.\n'
fi
for path in "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"; do test ! -e "$path"; done
test "$(find "$XDG_CONFIG_HOME" -type f | wc -l)" = 1
printf 'Copied Shelly worker protocols passed.\n'
