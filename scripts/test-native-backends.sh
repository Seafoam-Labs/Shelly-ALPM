#!/usr/bin/env bash
# Private-root transactions, runtime selection, and installed ELF boundary.
set -euo pipefail
unset LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT
cd "$(dirname "$0")/.."
enabled=${1:-auto}
optimize=${2:-Debug}
case "$enabled" in auto|true|false) ;; *) echo 'Expected auto, true, or false' >&2; exit 2;; esac
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
# Probe native headers, linking, and runtime loading before choosing a variant.
# Explicit false needs no libalpm tooling; explicit true remains a CI requirement.
if [[ "$enabled" != false ]]; then
    available=false
    pkg_config=$(command -v pkg-config || command -v pkgconf || true)
    if [[ -n "$pkg_config" ]] && "$pkg_config" --exists libalpm; then
        cat > "$stage/alpm-probe.c" <<'PROBE'
#include <alpm.h>
#include <alpm_list.h>
int main(void) { return alpm_version() == 0; }
PROBE
        # pkg-config returns compiler flags separated by shell whitespace.
        read -r -a alpm_flags <<< "$("$pkg_config" --cflags --libs libalpm)"
        if zig cc "$stage/alpm-probe.c" "${alpm_flags[@]}" -o "$stage/alpm-probe" > "$stage/alpm-probe.log" 2>&1 &&
            "$stage/alpm-probe" >> "$stage/alpm-probe.log" 2>&1; then
            available=true
        fi
    fi
    if [[ "$enabled" == auto ]]; then
        enabled=$available
        if [[ "$enabled" == false ]]; then
            echo 'SKIP: libalpm-specific tests (native headers/library unavailable); running RLPM-only tests.' >&2
        fi
    elif [[ "$available" == false ]]; then
        echo 'libalpm=true was requested, but its native headers/library are unavailable. Use auto to skip or false for RLPM-only tests.' >&2
        [[ ! -f "$stage/alpm-probe.log" ]] || cat "$stage/alpm-probe.log" >&2
        exit 1
    fi
fi
build_args=(-Dlibalpm="$enabled" -Doptimize="$optimize" --summary all)
(cd Shelly.PackageManager && zig build native-backend-test "${build_args[@]}")
(cd Shelly.Cli.Zig && zig build test "${build_args[@]}")
(cd Shelly.Cli.Zig && zig build --prefix "$stage/install" "${build_args[@]}")
# Keep all settings and output in this disposable stage, including when run as root.
export XDG_CONFIG_HOME="$stage/config" XDG_CACHE_HOME="$stage/cache" XDG_DATA_HOME="$stage/data" XDG_STATE_HOME="$stage/state"
unset SUDO_USER SUDO_UID DOAS_USER PKEXEC_UID
cli="$stage/install/bin/shelly"
for name in shelly-rlpm-action-worker shelly-download-worker rlpm-worker-fixture; do
    test ! -e "$stage/install/bin/$name"
done
scripts/test-worker-modes.sh "$cli"
default=rlpm
if [[ "$enabled" == true ]]; then default=libalpm; fi
[[ $("$cli" config get NativePackageBackend) == "$default" ]]
"$cli" config set NativePackageBackend rlpm > /dev/null
[[ $("$cli" config get NativePackageBackend) == rlpm ]]
"$cli" --json config list > "$stage/config-list.json"
"$cli" --ui-mode config list > "$stage/config-ui.txt"
"$cli" --help > "$stage/help"
"$cli" --version > /dev/null
"$cli" utility --completions bash > "$stage/completions"
if grep -Eq -- '--internal-(download-worker|rlpm-action-worker)' "$stage/help" "$stage/completions"; then
    echo 'Private worker modes appeared in public command documentation' >&2; exit 1
fi
if [[ "$enabled" == true ]]; then
    "$cli" config set NativePackageBackend libalpm > /dev/null
    [[ $("$cli" config get NativePackageBackend) == libalpm ]]
else
    if "$cli" config set NativePackageBackend libalpm > "$stage/error" 2>&1; then
        echo 'RLPM-only build accepted libalpm' >&2; exit 1
    fi
    # A saved choice from a different build must remain visible and repairable.
    printf '%s\n' '{"NativePackageBackend":"libalpm"}' > "$XDG_CONFIG_HOME/shelly/config.json"
    [[ $("$cli" config get NativePackageBackend) == libalpm ]]
    if "$cli" utility --completions bash > "$stage/error" 2>&1; then exit 1; fi
    grep -q 'BackendUnavailable' "$stage/error"
fi
for invalid in '"unknown"' '42' 'null'; do
    printf '{"NativePackageBackend":%s}\n' "$invalid" > "$XDG_CONFIG_HOME/shelly/config.json"
    if "$cli" utility --completions bash > "$stage/error" 2>&1; then exit 1; fi
    grep -q 'InvalidBackend' "$stage/error"
    "$cli" config set NativePackageBackend rlpm > /dev/null
    [[ $("$cli" config get NativePackageBackend) == rlpm ]]
done
"$cli" config reset > /dev/null
[[ $("$cli" config get NativePackageBackend) == "$default" ]]
# An existing configuration that omits the setting uses the compiled default.
printf '%s\n' '{}' > "$XDG_CONFIG_HOME/shelly/config.json"
[[ $("$cli" config get NativePackageBackend) == "$default" ]]
for executable in "$cli"; do
    test -x "$executable"
    readelf -d "$executable" > "$stage/dynamic"
    readelf --dyn-syms --wide "$executable" > "$stage/symbols"
    ldd "$executable" > "$stage/linked"
    if grep -q 'not found' "$stage/linked"; then cat "$stage/linked"; exit 1; fi
    if [[ "$enabled" == false ]]; then
        if grep -Eq 'libalpm|\balpm_' "$stage/dynamic" "$stage/symbols" "$stage/linked"; then
            echo "Unexpected libalpm dependency: $executable" >&2; exit 1
        fi
    else
        grep -q libalpm "$stage/dynamic"
    fi
done
printf 'Native backend matrix passed: libalpm=%s optimize=%s\n' "$enabled" "$optimize"
