#!/usr/bin/env bash
#
# aur-release.sh — publish the AUR packages for the release in this checkout.
#
# For every selected package this clones the AUR repository into a temporary
# directory inside this repo, drops in the matching top-level PKGBUILD* plus
# each local file its source=() array references, regenerates the checksums
# (updpkgsums) and .SRCINFO (shelly build --makesrcinfo), test-builds the
# result, shows the resulting diff, and asks before committing and pushing.
#
# The temporary directory is offered for deletion once every package is done.
#
# Prerequisites:
#   * the artifacts referenced by source=() must already be published —
#     updpkgsums downloads them to compute the checksums
#   * SSH access to the AUR (push goes over ssh://aur@aur.archlinux.org)
#   * a git identity (user.name / user.email) for the AUR commit
#   * pacman-contrib (updpkgsums) and the shelly CLI on PATH
#   * makedepends installed; the test build does not sync dependencies
#
# Usage:
#   scripts/aur-release.sh [options] [new-version] [package...]
#
# A X.Y.Z (or X.Y.Z+build) argument runs scripts/bump-version.sh with it
# before anything is cloned, so the published PKGBUILDs carry the new version.
#
# Packages (default: all four):
#   shelly shelly-bin shelly-git shelly-cli
#
# Options:
#   -w, --workdir DIR   Temporary clone directory (default: <repo>/.aur-release)
#   -n, --dry-run       Prepare everything, show the diff, push nothing
#       --skip-build    Regenerate sums and .SRCINFO without test-building
#       --no-check      Pass --no-check to the test build
#       --keep          Keep the temporary directory when finished
#   -h, --help          Show this help
#
# Examples:
#   scripts/aur-release.sh 3.1.7
#   scripts/aur-release.sh
#   scripts/aur-release.sh shelly-bin
#   scripts/aur-release.sh --dry-run --skip-build
#
# Environment overrides: SHELLY UPDPKGSUMS AUR_GIT_BASE

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

shelly_bin=${SHELLY:-shelly}
updpkgsums_bin=${UPDPKGSUMS:-updpkgsums}
aur_git_base=${AUR_GIT_BASE:-ssh://aur@aur.archlinux.org}

# AUR package base -> PKGBUILD in this repository.
package_table=(
    "shelly:PKGBUILD"
    "shelly-bin:PKGBUILD-bin"
    "shelly-git:PKGBUILD-git"
    "shelly-cli:PKGBUILD-cli"
)

usage() {
    sed -n '3,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

step() { printf '==> %s\n' "$*"; }
ok() { printf '  ok    %s\n' "$*"; }
note() { printf '  note  %s\n' "$*"; }

confirm() { # confirm <prompt> [default y|n]
    local prompt="$1" default="${2:-n}" reply hint
    if [[ "${default}" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
    if [[ ! -t 0 ]]; then
        if [[ "${default}" == "y" ]]; then return 0; else return 1; fi
    fi
    while true; do
        printf '%s [%s] ' "${prompt}" "${hint}"
        read -r reply || return 1
        case "${reply,,}" in
            y | yes) return 0 ;;
            n | no) return 1 ;;
            '')
                if [[ "${default}" == "y" ]]; then return 0; else return 1; fi ;;
        esac
    done
}

pkgbuild_for() { # pkgbuild_for <aur package> -> PKGBUILD filename
    local entry
    for entry in "${package_table[@]}"; do
        if [[ "${entry%%:*}" == "$1" ]]; then
            printf '%s\n' "${entry#*:}"
            return 0
        fi
    done
    return 1
}

# Local (non-URL) members of the source=() array. Remote sources in these
# PKGBUILDs are double-quoted and carry :: or ://, local files are bare
# single-quoted names.
local_sources() { # local_sources <pkgbuild>
    awk '/^source=\(/{f=1} f{print} f&&/\)/{exit}' "$1" |
        grep -oE "'[^']+'" |
        tr -d "'" |
        { grep -vE '::|://|[/$]' || true; }
}

published_version() { # published_version <clone dir> -> pkgver-pkgrel
    local clone="$1" version
    version="$(awk -F' = ' '/^\tpkgver = /{print $2; exit}' "${clone}/.SRCINFO" 2>/dev/null || true)"
    [[ -n "${version}" ]] ||
        version="$(sed -n 's/^pkgver=//p' "${clone}/PKGBUILD" | head -1)"
    printf '%s-%s\n' "${version}" "$(sed -n 's/^pkgrel=//p' "${clone}/PKGBUILD" | head -1)"
}

workdir="${repo_root}/.aur-release"
dry_run=0
skip_build=0
no_check=0
keep=0
new_version=""
selected=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w | --workdir)
            [[ $# -ge 2 ]] || die "--workdir needs an argument"
            workdir="$2"
            shift ;;
        -n | --dry-run) dry_run=1 ;;
        --skip-build) skip_build=1 ;;
        --no-check) no_check=1 ;;
        --keep) keep=1 ;;
        -h | --help)
            usage
            exit 0 ;;
        -*) die "unknown option '$1' (see --help)" ;;
        *)
            # A version-shaped argument is the bump-version.sh target; anything
            # else selects an AUR package.
            if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9A-Za-z.]+)?$ ]]; then
                [[ -z "${new_version}" ]] ||
                    die "unexpected second version '$1' (already '${new_version}')"
                new_version="$1"
            else
                selected+=("$1")
            fi ;;
    esac
    shift
done

if [[ ${#selected[@]} -eq 0 ]]; then
    for entry in "${package_table[@]}"; do selected+=("${entry%%:*}"); done
fi

for tool in git "${shelly_bin}" "${updpkgsums_bin}"; do
    command -v "${tool}" >/dev/null || die "'${tool}' not found on PATH"
done

for name in "${selected[@]}"; do
    pkgbuild_for "${name}" >/dev/null ||
        die "unknown package '${name}' (known: ${package_table[*]%%:*})"
    [[ -f "${repo_root}/$(pkgbuild_for "${name}")" ]] ||
        die "${name}: $(pkgbuild_for "${name}") not found in ${repo_root}"
done

if [[ -n "${new_version}" ]]; then
    bump_args=("${new_version}")
    if [[ ${dry_run} -eq 1 ]]; then bump_args+=(--dry-run); fi
    step "bumping version to ${new_version}"
    "${repo_root}/scripts/bump-version.sh" "${bump_args[@]}"
    printf '\n'
fi

mkdir -p "${workdir}"

release_one() { # release_one <aur package>
    local name="$1" pkgbuild_file clone locals=() local_name
    pkgbuild_file="$(pkgbuild_for "${name}")"
    clone="${workdir}/${name}"

    step "${name} (${pkgbuild_file})"

    if [[ -d "${clone}/.git" ]]; then
        git -C "${clone}" fetch --quiet origin
        git -C "${clone}" reset --hard --quiet \
            "$(git -C "${clone}" rev-parse --abbrev-ref --symbolic-full-name '@{u}')"
        git -C "${clone}" clean -fdxq
    else
        git clone --quiet "${aur_git_base}/${name}.git" "${clone}"
    fi

    cp "${repo_root}/${pkgbuild_file}" "${clone}/PKGBUILD"
    mapfile -t locals < <(local_sources "${clone}/PKGBUILD")
    for local_name in ${locals+"${locals[@]}"}; do
        [[ -f "${repo_root}/${local_name}" ]] ||
            die "${name}: PKGBUILD references local source '${local_name}', missing from ${repo_root}"
        cp "${repo_root}/${local_name}" "${clone}/${local_name}"
        printf '  copy  %s\n' "${local_name}"
    done

    # Stage now so the git clean before the diff cannot drop the copied files;
    # it only removes what updpkgsums downloads and what the build leaves.
    git -C "${clone}" add -A

    step "${name}: updating checksums"
    (cd "${clone}" && "${updpkgsums_bin}" PKGBUILD)

    step "${name}: generating .SRCINFO"
    (cd "${clone}" &&
        "${shelly_bin}" build --reviewed --no-confirm --makesrcinfo PKGBUILD >.SRCINFO.tmp)
    mv "${clone}/.SRCINFO.tmp" "${clone}/.SRCINFO"

    if [[ ${skip_build} -eq 0 ]]; then
        local build_args=(--reviewed --no-confirm)
        if [[ ${no_check} -eq 1 ]]; then build_args+=(--no-check); fi
        step "${name}: test build"
        (cd "${clone}" && "${shelly_bin}" build "${build_args[@]}" PKGBUILD)
    else
        note "${name}: test build skipped"
    fi

    git -C "${clone}" clean -fdxq
    git -C "${clone}" add -A

    if git -C "${clone}" diff --cached --quiet; then
        note "${name}: nothing to publish, AUR already matches"
        return 0
    fi

    local version
    version="$(published_version "${clone}")"
    printf '\n'
    git -C "${clone}" --no-pager diff --cached
    printf '\n'

    if [[ ${dry_run} -eq 1 ]]; then
        note "${name}: dry run, left uncommitted in ${clone}"
        return 0
    fi

    if ! confirm "Push ${name} ${version} to the AUR?"; then
        note "${name}: skipped, changes left staged in ${clone}"
        return 0
    fi

    git -C "${clone}" commit --quiet -m "upgpkg: ${name} ${version}"
    git -C "${clone}" push --quiet origin HEAD
    ok "${name}: pushed ${version}"
}

failed=()
for name in "${selected[@]}"; do
    # errexit is suppressed inside a function called from an if/|| condition,
    # and bash 5.3 does not restore it with a `set -e` in that subshell, so the
    # per-package run is invoked as a plain command and its status captured.
    set +e
    (set -e; release_one "${name}")
    status=$?
    set -e
    if [[ ${status} -ne 0 ]]; then
        printf 'error: %s: a release step failed (exit %d)\n' "${name}" "${status}" >&2
        failed+=("${name}")
    fi
    printf '\n'
done

if [[ ${#failed[@]} -gt 0 ]]; then
    printf 'Failed: %s\n' "${failed[*]}" >&2
    printf 'Temporary directory kept for inspection: %s\n' "${workdir}" >&2
    exit 1
fi

if [[ ${dry_run} -eq 1 || ${keep} -eq 1 ]]; then
    printf 'Temporary directory kept: %s\n' "${workdir}"
elif [[ ! -t 0 ]]; then
    printf 'Temporary directory kept (no terminal to confirm deletion): %s\n' "${workdir}"
elif confirm "Delete ${workdir}?" y; then
    rm -rf -- "${workdir}"
    printf 'Removed %s\n' "${workdir}"
else
    printf 'Temporary directory kept: %s\n' "${workdir}"
fi
