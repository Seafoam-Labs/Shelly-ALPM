#!/usr/bin/env bash
#
# Extract GtkBuilder and Zig gettext messages into the Shelly UI template
# (POT), then merge the template into every existing PO catalog.
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd -- "$project_dir"

# Fail fast on missing dependencies, before touching any files.
for tool in find xgettext msgcat msguniq msgmerge msgattrib; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required gettext tool '$tool' was not found" >&2
        exit 1
    fi
done

source_dir="src"
po_dir="po"
pot_file="$po_dir/shelly-ui.pot"

mapfile -d '' -t ui_files < <(
    find "$source_dir/ui" "$source_dir/dialog/ui" -type f -name '*.ui' -print0
)
mapfile -d '' -t zig_files < <(
    find "$source_dir" -type f -name '*.zig' -print0
)

if ((${#ui_files[@]} == 0 || ${#zig_files[@]} == 0)); then
    echo "error: no UI or Zig source files were found under $source_dir" >&2
    exit 1
fi

mkdir -p "$po_dir"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/shelly-ui-gettext.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

ui_pot="$temp_dir/ui.pot"
zig_pot="$temp_dir/zig.pot"
extracted_pot="$temp_dir/extracted.pot"
merged_pot="$temp_dir/merged.pot"

xgettext \
    --language=Glade \
    --from-code=UTF-8 \
    --force-po \
    --no-location \
    --no-check=url \
    --package-name=shelly-ui \
    --msgid-bugs-address=csnyder@seafoamlabs.org \
    --output="$ui_pot" \
    "${ui_files[@]}"

# GNU gettext has no Zig parser. The C parser correctly recognizes the
# translations._("literal") calls used by this project.
xgettext \
    --language=C \
    --from-code=UTF-8 \
    --keyword=_ \
    --force-po \
    --no-location \
    --no-check=url \
    --package-name=shelly-ui \
    --msgid-bugs-address=csnyder@seafoamlabs.org \
    --output="$zig_pot" \
    "${zig_files[@]}"

msgcat --use-first --no-location --output-file="$extracted_pot" "$ui_pot" "$zig_pot"

if [[ -f "$pot_file" ]]; then
    # Rebase the template on the freshly extracted sources while keeping the
    # existing header (translations-service metadata such as Weblate fields).
    # msgmerge copies the header from its PO input; msgattrib then drops the
    # messages that no longer appear in the sources.
    msgmerge --no-location "$pot_file" "$extracted_pot" \
        | msgattrib --no-obsolete --output-file="$merged_pot"
    mv -- "$merged_pot" "$pot_file"
else
    mv -- "$extracted_pot" "$pot_file"
fi

po_count=0
while IFS= read -r -d '' po_file; do
    normalized_po="$temp_dir/$(basename -- "$po_file").normalized"
    updated_po="$temp_dir/$(basename -- "$po_file").updated"

    # Some legacy catalogs contain duplicate msgids. Normalize them before
    # merging, preserving the first existing translation for each msgid.
    msguniq --use-first --output-file="$normalized_po" "$po_file"
    # Merge the template into the catalog, keeping every existing translation.
    # Messages that no longer appear in the sources are dropped.
    msgmerge --no-location "$normalized_po" "$pot_file" \
        | msgattrib --no-obsolete --output-file="$updated_po"
    mv -- "$updated_po" "$po_file"
    po_count=$((po_count + 1))
done < <(find "$po_dir" -maxdepth 1 -type f -name '*.po' -print0)

printf 'Updated %s and merged %d PO catalog(s).\n' "$pot_file" "$po_count"
