#!/usr/bin/env bash
#
# bump-version.sh — one-shot release version bump for Shelly.
#
# Sets the release version in every top-level build.zig.zon and every
# top-level PKGBUILD* in a single command instead of manual edits:
#
#   build.zig.zon   .version = "X.Y.Z"
#   PKGBUILD*       pkgver=X.Y.Z, pkgrel reset to 1, and the VCS pkgver()
#                   baseline (printf 'X.Y.Zr%s.g%s') used by the -git/-cli
#                   variants
#
# Skipped by default (versioned independently; pass --all to include):
#   Shelly.Flatpak.Backend/build.zig.zon
#   Shelly.Http/build.zig.zon
#
# Never touched, on purpose:
#   src/ and pkg/                       makepkg build artifacts
#   Shelly.Flatpak.Backend/build.zig    the ABI/SONAME version has its own
#                                       procedure (docs/flatpak-backend-abi.md)
#   sha256sums                          depend on release artifacts that do
#                                       not exist yet at bump time
#
# Usage:
#   scripts/bump-version.sh <new-version> [options]
#
# Options:
#   -n, --dry-run       Show what would change without editing anything
#   -a, --all           Also bump Shelly.Flatpak.Backend and Shelly.Http
#       --keep-pkgrel   Do not reset pkgrel to 1
#       --skip <glob>   Skip files whose path matches <glob> (repeatable)
#       --only <glob>   Only touch files whose path matches <glob> (repeatable)
#   -h, --help          Show this help
#
# Examples:
#   scripts/bump-version.sh 3.0.5
#   scripts/bump-version.sh 3.0.5 --all
#   scripts/bump-version.sh 3.1.0+1 --dry-run

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

usage() {
    cat <<'EOF'
Usage: scripts/bump-version.sh <new-version> [options]

Bumps .version in every top-level build.zig.zon and pkgver in every
top-level PKGBUILD* (also resets pkgrel to 1 and updates the VCS pkgver()
printf baseline in PKGBUILD-git / PKGBUILD-cli).

Skips Shelly.Flatpak.Backend and Shelly.Http by default because they are
versioned independently; pass --all to bump them too.

Options:
  -n, --dry-run       Show what would change without editing anything
  -a, --all           Also bump Shelly.Flatpak.Backend and Shelly.Http
      --keep-pkgrel   Do not reset pkgrel to 1
      --skip <glob>   Skip files whose path matches <glob> (repeatable)
      --only <glob>   Only touch files whose path matches <glob> (repeatable)
  -h, --help          Show this help

Examples:
  scripts/bump-version.sh 3.0.5
  scripts/bump-version.sh 3.0.5 --all
  scripts/bump-version.sh 3.1.0+1 --dry-run
EOF
}

dry_run=0
keep_pkgrel=0
include_all=0
skip_patterns=()
only_patterns=()
new_version=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) dry_run=1 ;;
        -a|--all) include_all=1 ;;
        --keep-pkgrel) keep_pkgrel=1 ;;
        --skip)
            if [[ $# -lt 2 ]]; then echo "error: --skip needs an argument" >&2; exit 2; fi
            skip_patterns+=("$2"); shift ;;
        --only)
            if [[ $# -lt 2 ]]; then echo "error: --only needs an argument" >&2; exit 2; fi
            only_patterns+=("$2"); shift ;;
        -h|--help) usage; exit 0 ;;
        -*)
            echo "error: unknown option '$1'" >&2
            usage >&2
            exit 2 ;;
        *)
            if [[ -n "${new_version}" ]]; then
                echo "error: unexpected extra argument '$1'" >&2
                exit 2
            fi
            new_version="$1" ;;
    esac
    shift
done

if [[ -z "${new_version}" ]]; then
    echo "error: missing <new-version>" >&2
    echo "usage: scripts/bump-version.sh <new-version> [--dry-run] [--keep-pkgrel]" >&2
    exit 2
fi

# X.Y.Z with an optional +build suffix. Pacman's pkgver must not contain '-',
# so pre-release versions are rejected on purpose.
if [[ ! "${new_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9A-Za-z.]+)?$ ]]; then
    echo "error: '${new_version}' is not a valid version (expected X.Y.Z or X.Y.Z+build)" >&2
    exit 2
fi

# Shelly.Flatpak.Backend and Shelly.Http carry their own versions and are
# skipped unless --all is given.
if [[ ${include_all} -eq 0 ]]; then
    skip_patterns+=("Shelly.Flatpak.Backend/*" "Shelly.Http/*")
fi

selected() {
    local path="$1" pattern match
    if [[ ${#only_patterns[@]} -gt 0 ]]; then
        match=0
        for pattern in "${only_patterns[@]}"; do
            # shellcheck disable=SC2053
            if [[ "${path}" == ${pattern} ]]; then match=1; break; fi
        done
        [[ ${match} -eq 1 ]] || return 1
    fi
    for pattern in "${skip_patterns[@]}"; do
        # shellcheck disable=SC2053
        if [[ "${path}" == ${pattern} ]]; then return 1; fi
    done
    return 0
}

zon_version() {
    grep -m1 -E '^[[:space:]]*\.version = "' "$1" \
        | sed -E 's/^[[:space:]]*\.version = "([^"]*)".*/\1/' || true
}

pkgbuild_version() {
    grep -m1 -E '^pkgver=' "$1" | cut -d= -f2- || true
}

pkgbuild_pkgrel() {
    grep -m1 -E '^pkgrel=' "$1" | cut -d= -f2- || true
}

pkgbuild_printf_baseline() {
    grep -m1 -oE "printf '[^']*r%s\.g%s'" "$1" \
        | sed -E "s/printf '([^']*)r%s\.g%s'/\1/" || true
}

mapfile -t zon_files < <(find . -type f -maxdepth 2 -name 'build.zig.zon' \
    -not -path './src/*' -not -path './pkg/*' -not -path './.zig-cache/*' | sort)
mapfile -t pkgbuild_files < <(find . -type f -maxdepth 1 -name 'PKGBUILD*' | sort)

if [[ ${#zon_files[@]} -eq 0 && ${#pkgbuild_files[@]} -eq 0 ]]; then
    echo "error: no build.zig.zon or PKGBUILD files found under ${repo_root}" >&2
    exit 1
fi

old_versions=()
changed=0

echo "Bumping version to ${new_version}$([[ ${dry_run} -eq 1 ]] && echo ' (dry run)')"
echo

if [[ ${#zon_files[@]} -gt 0 ]]; then
    echo "zig packages:"
    for file in "${zon_files[@]}"; do
        rel="${file#./}"
        if ! selected "${rel}"; then
            echo "  skip  ${rel}"
            continue
        fi
        old="$(zon_version "${file}")"
        if [[ -z "${old}" ]]; then
            echo "  warn  ${rel}: no .version field found, skipping" >&2
            continue
        fi
        old_versions+=("${old}")
        if [[ "${old}" == "${new_version}" ]]; then
            echo "  ok    ${rel} (already ${new_version})"
            continue
        fi
        if [[ ${dry_run} -eq 0 ]]; then
            sed -i -E "s|^([[:space:]]*\.version = \")[^\"]*(\")|\1${new_version}\2|" "${file}"
        fi
        printf '  bump  %-44s %s -> %s\n' "${rel}" "${old}" "${new_version}"
        changed=$((changed + 1))
    done
    echo
fi

if [[ ${#pkgbuild_files[@]} -gt 0 ]]; then
    echo "pkgbuilds:"
    for file in "${pkgbuild_files[@]}"; do
        rel="${file#./}"
        if ! selected "${rel}"; then
            echo "  skip  ${rel}"
            continue
        fi
        old="$(pkgbuild_version "${file}")"
        if [[ -z "${old}" ]]; then
            echo "  warn  ${rel}: no pkgver found, skipping" >&2
            continue
        fi
        old_versions+=("${old}")
        old_rel="$(pkgbuild_pkgrel "${file}")"
        baseline="$(pkgbuild_printf_baseline "${file}")"

        notes=()
        if [[ "${old}" != "${new_version}" ]]; then
            notes+=("pkgver ${old} -> ${new_version}")
        fi
        if [[ ${keep_pkgrel} -eq 0 && -n "${old_rel}" && "${old_rel}" != "1" ]]; then
            notes+=("pkgrel ${old_rel} -> 1")
        fi
        if [[ -n "${baseline}" && "${baseline}" != "${new_version}" ]]; then
            notes+=("pkgver() baseline ${baseline} -> ${new_version}")
        fi

        if [[ ${#notes[@]} -eq 0 ]]; then
            echo "  ok    ${rel} (already ${new_version})"
            continue
        fi

        if [[ ${dry_run} -eq 0 ]]; then
            sed -i -E "s|^pkgver=.*|pkgver=${new_version}|" "${file}"
            if [[ ${keep_pkgrel} -eq 0 ]]; then
                sed -i -E 's|^pkgrel=.*|pkgrel=1|' "${file}"
            fi
            if [[ -n "${baseline}" ]]; then
                sed -i -E "s|^([[:space:]]*printf ')[^']*(r%s\.g%s')|\1${new_version}\2|" "${file}"
            fi
        fi
        printf '  bump  %-44s %s\n' "${rel}" "$(IFS=', '; echo "${notes[*]}")"
        changed=$((changed + 1))
    done
    echo
fi

if [[ ${dry_run} -eq 1 ]]; then
    echo "Dry run complete: ${changed} file(s) would change, nothing was modified."
else
    echo "Bumped ${changed} file(s) to ${new_version}."
fi

# Surface version drift between files before this bump (informational only).
if [[ ${#old_versions[@]} -gt 0 ]]; then
    distinct="$(printf '%s\n' "${old_versions[@]}" | sort -u)"
    if [[ "$(printf '%s\n' "${distinct}" | wc -l)" -gt 1 ]]; then
        echo
        echo "Note: files were at different versions before this bump:"
        echo "  $(printf '%s\n' "${distinct}" | tr '\n' ' ')"
    fi
fi

if [[ ${dry_run} -eq 0 && ${changed} -gt 0 ]]; then
    cat <<EOF

Reminders:
  * sha256sums in PKGBUILD and PKGBUILD-bin must be regenerated once the
    release artifacts exist (e.g. with updpkgsums).
  * The Flatpak backend ABI/SONAME version in Shelly.Flatpak.Backend/build.zig
    is intentionally untouched; follow docs/flatpak-backend-abi.md if the ABI
    changed.
EOF
fi
