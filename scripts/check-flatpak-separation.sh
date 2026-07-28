#!/usr/bin/env bash

set -euo pipefail
unset LD_PRELOAD

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cli_path="${1:-${repo_root}/Shelly.Cli.Zig/zig-out/bin/shelly}"
backend_path="${2:-${repo_root}/Shelly.Flatpak.Backend/zig-out/lib/libshelly-flatpak-backend.so.1}"

for tool in readelf nm rg; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "error: ${tool} is required for the Flatpak separation check" >&2
        exit 1
    fi
done

if [[ ! -x "${cli_path}" ]]; then
    echo "error: Shelly CLI artifact not found: ${cli_path}" >&2
    exit 1
fi
if [[ ! -e "${backend_path}" ]]; then
    echo "error: Flatpak backend artifact not found: ${backend_path}" >&2
    exit 1
fi

cli_needed="$(readelf -d "${cli_path}" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')"
if grep -Eq '^(libflatpak|libostree|libgio|libgobject|libglib)' <<<"${cli_needed}"; then
    echo "error: the base Shelly CLI has a forbidden native Flatpak dependency" >&2
    grep -E '^(libflatpak|libostree|libgio|libgobject|libglib)' <<<"${cli_needed}" >&2
    exit 1
fi

backend_dynamic="$(readelf -d "${backend_path}")"
if ! grep -Fq 'Shared library: [libflatpak.so.0]' <<<"${backend_dynamic}"; then
    echo "error: the Flatpak backend does not depend on libflatpak.so.0" >&2
    exit 1
fi
if ! grep -Fq 'Library soname: [libshelly-flatpak-backend.so.1]' <<<"${backend_dynamic}"; then
    echo "error: the Flatpak backend SONAME is not ABI version 1" >&2
    exit 1
fi
if ! nm -D --defined-only "${backend_path}" |
    grep -Eq '[[:space:]]shelly_flatpak_backend_get_api$'; then
    echo "error: the Flatpak backend entry point is not exported" >&2
    exit 1
fi

if rg -n --glob '*.zig' \
    'flatpak\.bindings|bindings\.libflatpak|@import\("flatpak"\)|g_object_unref|refToString' \
    "${repo_root}/Shelly.PackageManager" \
    "${repo_root}/Shelly.Cli.Zig"; then
    echo "error: native Flatpak declarations escaped the backend project" >&2
    exit 1
fi
if rg -n --glob '*.zig' \
    'flatpak\.bindings|bindings\.libflatpak|@import\("flatpak"\)|Shelly_Flatpak_Protocol|shelly_flatpak_backend_get_api' \
    "${repo_root}/Shelly.Ui.Gtk" \
    "${repo_root}/Shelly.Tui"; then
    echo "error: a UI consumer bypasses the PackageManager Flatpak facade" >&2
    exit 1
fi
if rg -n 'linkSystemLibrary\("flatpak"' \
    "${repo_root}/Shelly.PackageManager/build.zig" \
    "${repo_root}/Shelly.Cli.Zig/build.zig" \
    "${repo_root}/Shelly.Ui.Gtk/build.zig" \
    "${repo_root}/Shelly.Tui/build.zig"; then
    echo "error: the base build graph still links libflatpak" >&2
    exit 1
fi

fake_backend="${repo_root}/Shelly.PackageManager/zig-out/test-flatpak-backend/libshelly-flatpak-backend-package-manager-test.so"
if [[ -e "${fake_backend}" ]] &&
    readelf -d "${fake_backend}" | grep -Fq 'Shared library: [libflatpak.so.0]'; then
    echo "error: the test-only fake backend unexpectedly links libflatpak" >&2
    exit 1
fi

for recipe in PKGBUILD PKGBUILD-git PKGBUILD-bin PKGBUILD-cli; do
    bash -n "${repo_root}/${recipe}"
done
if ! grep -Fq "pkgname=('shelly' 'shelly-flatpak-backend')" \
    "${repo_root}/PKGBUILD"; then
    echo "error: PKGBUILD does not declare the base/backend split" >&2
    exit 1
fi
if ! grep -Fq 'shelly-flatpak-backend: Flatpak package management support' \
    "${repo_root}/PKGBUILD"; then
    echo "error: the base package does not advertise the optional backend" >&2
    exit 1
fi
if ! grep -Fq 'package_shelly-flatpak-backend()' \
    "${repo_root}/PKGBUILD" ||
    ! grep -Fq 'usr/lib/shelly/libshelly-flatpak-backend.so.1' \
    "${repo_root}/PKGBUILD"; then
    echo "error: the backend subpackage does not stage the ABI-versioned library" >&2
    exit 1
fi
if ! grep -Fq 'Shelly-Flatpak-Backend-linux-x64' \
    "${repo_root}/PKGBUILD-bin"; then
    echo "error: binary packaging does not consume the separate backend archive" >&2
    exit 1
fi

echo "Flatpak backend separation checks passed."
