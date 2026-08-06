#!/usr/bin/env bash
#
# update-translations.sh — extract, merge, and maintain gettext translations
# for the Shelly GTK UI.
#
# What it does:
#   1. Extracts translatable strings from GtkBuilder (.ui) files and Zig
#      sources into po/shelly-ui.pot, rebasing the template on the sources
#      while keeping the existing header (translations-service metadata such
#      as Weblate fields).
#   2. Merges the template into every existing po/<lang>.po, keeping all
#      existing translations and dropping messages that no longer appear in
#      the sources (obsolete entries are pruned).
#
# Usage:
#   ./update-translations.sh                # extract + merge all existing .po
#   ./update-translations.sh --new es       # also create po/es.po if missing
#   ./update-translations.sh --accept-fuzzy # un-fuzzy, keep the guessed text
#   ./update-translations.sh --clear-fuzzy  # drop fuzzy guesses entirely
#
set -euo pipefail

script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
cd -- "$(dirname -- "$script_path")"

# ---- Config -----------------------------------------------------------------
DOMAIN="shelly-ui"
SRC_DIR="src"
PO_DIR="po"
POT="${PO_DIR}/${DOMAIN}.pot"
# Package metadata for the .pot header (only used when no POT exists yet;
# afterwards the existing header is preserved by the rebase below).
PKG_NAME="shelly-ui"
BUGS_ADDRESS="csnyder@seafoamlabs.org"
# -----------------------------------------------------------------------------

NEW_LANGS=()
FUZZY_MODE="clear"   # keep | accept | clear

while [[ $# -gt 0 ]]; do
    case "$1" in
        --new)          NEW_LANGS+=("$2"); shift 2 ;;
        --accept-fuzzy) FUZZY_MODE="accept"; shift ;;  # un-fuzzy, keep the guessed text
        --clear-fuzzy)  FUZZY_MODE="clear";  shift ;;  # drop fuzzy guesses (-> untranslated)
        -h|--help)
            sed -n '2,/^set -euo/p' "$script_path" | sed '$d'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

# Fail fast on missing dependencies, before touching any files.
for tool in find xgettext msgcat msguniq msgmerge msgattrib msgfmt; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: '$tool' not found. Install the 'gettext' package." >&2
        exit 1
    }
done

# GNU gettext has no Zig parser; the C parser recognizes the
# translations._("literal") calls used by this project.
mapfile -d '' -t UI_FILES < <(
    find "$SRC_DIR/ui" "$SRC_DIR/dialog/ui" -type f -name '*.ui' -print0 | sort -z
)
mapfile -d '' -t ZIG_FILES < <(
    find "$SRC_DIR" -type f -name '*.zig' -print0 | sort -z
)

if ((${#UI_FILES[@]} == 0 || ${#ZIG_FILES[@]} == 0)); then
    echo "error: no UI or Zig source files were found under $SRC_DIR" >&2
    exit 1
fi

mkdir -p "$PO_DIR"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/shelly-ui-gettext.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

# ---- 1. Extract strings -> .pot ---------------------------------------------
echo ">> Extracting translatable strings from ${SRC_DIR}/ ..."
ui_pot="$temp_dir/ui.pot"
zig_pot="$temp_dir/zig.pot"
extracted_pot="$temp_dir/extracted.pot"

xgettext \
    --language=Glade \
    --from-code=UTF-8 \
    --force-po \
    --no-location \
    --no-check=url \
    --add-comments=TRANSLATORS \
    --package-name="$PKG_NAME" \
    --msgid-bugs-address="$BUGS_ADDRESS" \
    --output="$ui_pot" \
    "${UI_FILES[@]}"

xgettext \
    --language=C \
    --keyword=_ \
    --from-code=UTF-8 \
    --force-po \
    --no-location \
    --no-check=url \
    --add-comments=TRANSLATORS \
    --package-name="$PKG_NAME" \
    --msgid-bugs-address="$BUGS_ADDRESS" \
    --output="$zig_pot" \
    "${ZIG_FILES[@]}"

msgcat --use-first --no-location --output-file="$extracted_pot" "$ui_pot" "$zig_pot"

stats="$(msgfmt --statistics --output-file=/dev/null "$extracted_pot" 2>&1 || true)"
echo "   extracted: ${stats}"

if [[ -f "$POT" ]]; then
    # Rebase the template on the freshly extracted sources while keeping the
    # existing header. msgmerge copies the header from its PO input;
    # msgattrib then drops the messages that no longer appear in the sources.
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
        normalized_po="$temp_dir/$(basename -- "$po").normalized"
        merged="$temp_dir/$(basename -- "$po").merged"

        # Some legacy catalogs contain duplicate msgids. Normalize them
        # before merging, preserving the first existing translation.
        msguniq --use-first --output-file="$normalized_po" "$po"
        # Merge the template into the catalog, keeping every existing
        # translation. Messages that no longer appear in the sources are
        # dropped, and --previous records the old msgid next to fuzzy
        # guesses so translators can review them.
        msgmerge \
            --no-location \
            --previous \
            "$normalized_po" "$POT" \
            | msgattrib --no-obsolete --output-file="$merged"

        # Handle fuzzy entries. Unlike the notifications tray, these
        # catalogs are managed by translators (Weblate) and fuzzy entries
        # may hold real work-in-progress text, so the default is to leave
        # them untouched; msgfmt skips fuzzy entries when compiling anyway.
        case "$FUZZY_MODE" in
            clear)
                # Remove the fuzzy flag AND blank the guessed text, so the
                # entry is cleanly untranslated (no #, fuzzy, empty msgstr).
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

echo ">> Done."
