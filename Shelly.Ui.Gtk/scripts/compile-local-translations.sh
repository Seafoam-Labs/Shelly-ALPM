#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${script_dir}/.." && pwd)"
locale_dir="${project_dir}/zig-out/share/locale"

if ! command -v msgfmt >/dev/null 2>&1; then
    echo "error: msgfmt not found. Install the 'gettext' package to build translations." >&2
    exit 1
fi

shopt -s nullglob
po_files=("${project_dir}"/po/*.po)
shopt -u nullglob

if (("${#po_files[@]}" == 0)); then
    echo "No gettext catalogs found in ${project_dir}/po; skipping local translations."
    exit 0
fi

for po_file in "${po_files[@]}"; do
    locale="$(basename -- "${po_file}" .po)"
    output_dir="${locale_dir}/${locale}/LC_MESSAGES"
    mkdir -p "${output_dir}"
    msgfmt --check --output-file="${output_dir}/shelly-ui.mo" "${po_file}"
    echo "Compiled ${locale} translation."
done
