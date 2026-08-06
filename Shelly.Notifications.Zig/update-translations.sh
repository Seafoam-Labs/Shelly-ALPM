#!/usr/bin/env bash
#
# update-translations.sh — extract, merge, and maintain gettext translations
# for the shelly-notifications tray.
#
# What it does:
#   1. Extracts translatable strings from src/ into po/<DOMAIN>.pot, rebasing
#      the template on the sources while keeping the existing header.
#   2. Merges the template into every existing po/<lang>.po, keeping all
#      existing translations and dropping messages that no longer appear in
#      the sources (obsolete entries are pruned).
#   3. Optionally compiles .po -> .mo and installs them.
#
# Usage:
#   ./update-translations.sh                # extract + merge all existing .po
#   ./update-translations.sh --new es       # also create po/es.po if missing
#   ./update-translations.sh --compile      # build .mo files into build/locale
#   ./update-translations.sh --install      # install .mo into $PREFIX/share/locale
#   ./update-translations.sh --new de --compile   # combine flags
#
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd -- "$project_dir"

# ---- Config -----------------------------------------------------------------
DOMAIN="shelly-notifications"
SRC_DIR="src"
PO_DIR="po"
POT="${PO_DIR}/${DOMAIN}.pot"
# Where compiled .mo files go for local testing:
BUILD_LOCALE_DIR="build/locale"
# Where --install puts them (override with PREFIX=/foo ./update-translations.sh --install):
PREFIX="${PREFIX:-/usr}"
INSTALL_LOCALE_DIR="${PREFIX}/share/locale"
# Package metadata for the .pot header:
PKG_NAME="Shelly Notifications"
PKG_VERSION="0.0.1"
BUGS_ADDRESS="https://github.com/Seafoam-Labs/conch/issues"
# -----------------------------------------------------------------------------

NEW_LANGS=()
DO_COMPILE=0
DO_INSTALL=0
FUZZY_MODE="clear"   # keep | accept | clear  (default: clear -> no fuzzy, untranslated)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --new)     NEW_LANGS+=("$2"); shift 2 ;;
        --compile) DO_COMPILE=1; shift ;;
        --install) DO_INSTALL=1; DO_COMPILE=1; shift ;;   # install implies compile
        --accept-fuzzy) FUZZY_MODE="accept"; shift ;;  # un-fuzzy, keep the guessed text
        --keep-fuzzy)   FUZZY_MODE="keep";   shift ;;  # leave #, fuzzy markers as-is
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

# Fail fast on missing dependencies, before touching any files.
for tool in find xgettext msgmerge msgfmt msginit msgattrib; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: '$tool' not found. Install the 'gettext' package." >&2
        exit 1
    }
done

# Zig isn't a native xgettext language; --language=C + --keyword pick up the
# trans("...") alias for translations._ used by this project. Add more
# --keyword flags here if you introduce other translation helpers
# (e.g. ngettext).
mapfile -d '' -t ZIG_FILES < <(
    find "$SRC_DIR" -type f -name '*.zig' -print0 | sort -z
)

if ((${#ZIG_FILES[@]} == 0)); then
    echo "error: no Zig source files were found under $SRC_DIR" >&2
    exit 1
fi

mkdir -p "$PO_DIR"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/shelly-notifications-gettext.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

# ---- 1. Extract strings -> .pot ---------------------------------------------
echo ">> Extracting translatable strings from ${SRC_DIR}/ ..."
extracted_pot="$temp_dir/extracted.pot"

xgettext \
    --language=C \
    --keyword=_ \
    --keyword=trans \
    --from-code=UTF-8 \
    --force-po \
    --no-location \
    --add-comments=TRANSLATORS \
    --package-name="$PKG_NAME" \
    --package-version="$PKG_VERSION" \
    --msgid-bugs-address="$BUGS_ADDRESS" \
    --output="$extracted_pot" \
    "${ZIG_FILES[@]}"

stats="$(msgfmt --statistics --output-file=/dev/null "$extracted_pot" 2>&1 || true)"
echo "   extracted: ${stats}"

if [[ -f "$POT" ]]; then
    # Rebase the template on the freshly extracted sources while keeping the
    # existing header (translations-service metadata). msgmerge copies the
    # header from its PO input; msgattrib then drops the messages that no
    # longer appear in the sources.
    merged_pot="$temp_dir/merged.pot"
    msgmerge --no-location "$POT" "$extracted_pot" \
        | msgattrib --no-obsolete --output-file="$merged_pot"
    mv -- "$merged_pot" "$POT"
else
    mv -- "$extracted_pot" "$POT"
fi
echo ">> Updated ${POT}."

# ---- 2. Create any requested new language .po files -------------------------
for lang in "${NEW_LANGS[@]:-}"; do
    [[ -z "$lang" ]] && continue
    target="${PO_DIR}/${lang}.po"
    if [[ -f "$target" ]]; then
        echo ">> ${target} already exists, will merge (not recreate)."
    else
        echo ">> Creating new translation ${target} ..."
        msginit \
            --no-translator \
            --input="$POT" \
            --locale="$lang" \
            --output="$target"
    fi
done

# ---- 3. Merge .pot into every existing .po ----------------------------------
shopt -s nullglob
PO_FILES=("${PO_DIR}"/*.po)
shopt -u nullglob

if [[ ${#PO_FILES[@]} -eq 0 ]]; then
    echo ">> No .po files found in ${PO_DIR}/. Create one with: $0 --new <lang>"
else
    for po in "${PO_FILES[@]}"; do
        echo ">> Merging into ${po} ..."
        merged="$temp_dir/$(basename -- "$po").merged"

        # Merge the template into the catalog, keeping every existing
        # translation. Messages that no longer appear in the sources are
        # dropped, and --previous records the old msgid next to fuzzy guesses.
        msgmerge \
            --no-location \
            --previous \
            "$po" "$POT" \
            | msgattrib --no-obsolete --output-file="$merged"

        # Handle fuzzy entries (msgmerge's guessed translations from similar
        # old strings). msgfmt skips fuzzy by default, so these never reach
        # the .mo.
        case "$FUZZY_MODE" in
            clear)
                # Remove the fuzzy flag AND blank the guessed text, so the
                # entry is cleanly untranslated (no #, fuzzy, empty msgstr)
                # for a human to fill in. This is the default.
                echo "   clearing fuzzy entries (-> untranslated) ..."
                msgattrib --clear-fuzzy --empty "$merged" --output-file="$merged.tmp"
                mv -- "$merged.tmp" "$merged"
                ;;
            accept)
                # Remove the fuzzy flag but KEEP the guessed translation.
                echo "   accepting fuzzy guesses ..."
                msgattrib --clear-fuzzy "$merged" --output-file="$merged.tmp"
                mv -- "$merged.tmp" "$merged"
                ;;
            keep)
                : # leave #, fuzzy markers untouched
                ;;
        esac

        mv -- "$merged" "$po"

        # Report translation status for this language.
        stats="$(msgfmt --statistics --output-file=/dev/null "$po" 2>&1 || true)"
        echo "   ${po}: ${stats}"
    done
fi

# ---- 4. Compile .po -> .mo --------------------------------------------------
if [[ "$DO_COMPILE" -eq 1 ]]; then
    shopt -s nullglob
    PO_FILES=("${PO_DIR}"/*.po)
    shopt -u nullglob
    for po in "${PO_FILES[@]}"; do
        lang="$(basename "$po" .po)"
        if [[ "$DO_INSTALL" -eq 1 ]]; then
            out_dir="${INSTALL_LOCALE_DIR}/${lang}/LC_MESSAGES"
        else
            out_dir="${BUILD_LOCALE_DIR}/${lang}/LC_MESSAGES"
        fi
        mkdir -p "$out_dir"
        out="${out_dir}/${DOMAIN}.mo"
        echo ">> Compiling ${po} -> ${out}"
        # --check validates format strings and header; fails on errors.
        msgfmt --check --output-file="$out" "$po"
    done
    if [[ "$DO_INSTALL" -eq 1 ]]; then
        echo ">> Installed .mo files under ${INSTALL_LOCALE_DIR}/"
    else
        echo ">> Compiled .mo files under ${BUILD_LOCALE_DIR}/ (test with:"
        echo "     LANG=<lang>.UTF-8 TEXTDOMAINDIR=$(pwd)/${BUILD_LOCALE_DIR} ./zig-out/bin/shelly-notifications )"
    fi
fi

echo ">> Done."
