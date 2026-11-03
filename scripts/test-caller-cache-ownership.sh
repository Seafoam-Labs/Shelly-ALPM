#!/usr/bin/env bash
# Run the account test executable in a disposable user/mount namespace.
# Usage: this script /absolute/path/to/account-test
set -euo pipefail
test_binary=$(realpath "${1:?Expected the account-test executable}")
integration_binary=${2:+$(realpath "$2")}
cli_binary=${3:+$(realpath "$3")}
if [[ ${SHELLY_CALLER_TEST_NAMESPACE:-0} != 1 ]]; then
    exec unshare --user --map-auto --map-root-user --mount \
        env SHELLY_CALLER_TEST_NAMESPACE=1 bash "$0" "$test_binary" "${integration_binary:-}" "${cli_binary:-}"
fi
stage=$(mktemp -d /tmp/shelly-caller-ownership.XXXXXXXX)
trap 'rm -rf "$stage"' EXIT
chmod 755 "$stage"
mkdir "$stage/user" "$stage/root" "$stage/root-only"
chown nobody: "$stage/user"
chmod 700 "$stage/root-only"
awk -F: -v OFS=: -v root_home="$stage/root" -v user_home="$stage/user" '
    $1 == "root" { $6 = root_home }
    $1 == "nobody" { $6 = user_home }
    { print }
' /etc/passwd > "$stage/passwd"
mount --make-rprivate /
mount --bind "$stage/passwd" /etc/passwd
cp /etc/group "$stage/group"
printf 'shelly-caller-test:x:65533:nobody\n' >> "$stage/group"
mount --bind "$stage/group" /etc/group
unset SUDO_USER SUDO_UID SUDO_GID DOAS_USER PKEXEC_UID
export SHELLY_TEST_CALLER_IO_DIRECTORY="$stage"
"$test_binary"
if [[ -n "$integration_binary" ]]; then "$integration_binary"; fi
if [[ -n "$cli_binary" ]]; then
    # The manager fixture supplies an empty native database; no network or
    # host package transactions are required for these exports.
    test -f "$stage/native.conf"
    env SUDO_USER=nobody SHELLY_ELEVATOR=/usr/bin/runuser \
        XDG_CACHE_HOME="$stage/user/cli cache" XDG_CONFIG_HOME="$stage/user/config" \
        XDG_DATA_HOME="$stage/user/data" XDG_STATE_HOME="$stage/user/state" \
        "$cli_binary" --config "$stage/native.conf" backup --export --name caller > "$stage/backup-output"
    test "$(stat -c %u "$stage/user/cli cache/Shelly/caller.toml")" = "$(id -u nobody)"
    env XDG_CACHE_HOME="$stage/root/.cache" XDG_CONFIG_HOME="$stage/root/config" \
        XDG_DATA_HOME="$stage/root/data" XDG_STATE_HOME="$stage/root/state" \
        "$cli_binary" --config "$stage/native.conf" backup --export --name root > "$stage/root-output"
    test "$(stat -c %u "$stage/root/.cache/Shelly/root.toml")" = 0
fi
test "$(stat -c %u "$stage/user/.cache")" = "$(id -u nobody)"
test "$(stat -c %u "$stage/user/.cache/Shelly")" = "$(id -u nobody)"
test "$(stat -c %u "$stage/root/.cache/Shelly/feed")" = 0
test ! -e "$stage/root-only/must-not-exist"
printf 'Caller cache ownership and direct root checks passed.\n'
