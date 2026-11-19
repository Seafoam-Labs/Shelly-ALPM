#!/bin/sh
# Audit which memcheck suppressions fired in a valgrind run.
#
# Usage: sh valgrind/vgsupp.sh <supp-file> <valgrind-log>
#
# The log must come from a run with -s (--show-suppressed), e.g.
#   zig build valgrind -Dvalgrind-args="-s" -Dskip-background-services=true -- --page firmware
# memcheck never reports *unused* suppressions (not even with -v); -s prints
# one `used_suppression:` line per fired entry, keyed by the stanza's
# name-line number — a stable join key even for duplicate names.
#
# "Never fired" only means "not needed on the visited path": host-specific
# entries (Fcitx, i965, VMware) can only fire on other machines/inputs.
set -eu
[ $# -eq 2 ] || { echo "usage: $0 <supp-file> <valgrind-log>" >&2; exit 2; }

used=$(mktemp) decl=$(mktemp) never=$(mktemp)
trap 'rm -f "$used" "$decl" "$never"' EXIT

awk '/used_suppression/ { for (i=4;i<=NF;i++) if ($i ~ /\.[A-Za-z]+:[0-9]+$/) { sub(/^.*:/,"",$i); print $i+0; break } }' "$2" | sort -u > "$used"
awk '/^[[:space:]]*\{/{ getline n; ln=NR; getline k; if (k ~ /^[[:space:]]*Memcheck:/) print ln }' "$1" | sort > "$decl"
echo "declared memcheck stanzas: $(wc -l < "$decl"), fired: $(wc -l < "$used")"
comm -23 "$decl" "$used" > "$never"
echo "never fired: $(wc -l < "$never")"
awk 'NR==FNR{w[$1];next} FNR in w{printf "  line %d: %s\n", FNR, $0}' "$never" "$1"
