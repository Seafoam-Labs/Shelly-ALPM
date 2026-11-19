#!/usr/bin/env python3
"""Diff two valgrind suppression files by memcheck stanza frame sequences.

Usage: python3 valgrind/supp-diff.py <upstream.supp> <local.supp>

A plain text diff is useless for tracking upstream drift: Shelly renames
entries, generalizes tail frames to `...`, and upstream adjusts
match-leak-kinds. This parses stanzas (`{`, name line, `Memcheck:`/`drd:`/
`Helgrind:` kind line, then `fun:`/`obj:`/`...` frames until `}`) and compares
the frame sequences of Memcheck stanzas only; drd/Helgrind stanzas are inert
for memcheck and skipped.

Reports identical / upstream-only / local stanzas with their name-line
numbers (the same join key valgrind's used_suppression lines use).

Keep it clean under `ruff check`, `ruff format --check` and `ty check`: the
repo carries no config for either tool, so run them on this file. Type rules
(same as scripts/check-a11y.py): `from __future__ import annotations`, full
parameter/return annotations on every function, builtin generics
(`list[str]`, `tuple[str, ...]`), and frozen dataclasses for record types —
a stanza is a `Stanza`, never a bare tuple. Stdlib only, so unlike
check-a11y.py no Protocols are needed: ty sees every import.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class Stanza:
    name_line: int  # 1-based line number of the name line
    name: str
    frames: tuple[str, ...]


def parse(path: str) -> list[Stanza]:
    """Return the memcheck stanzas of a suppression file, in file order."""
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = [ln.rstrip("\n") for ln in f]
    stanzas: list[Stanza] = []
    i = 0
    while i < len(lines):
        if lines[i].strip() != "{":
            i += 1
            continue
        # Skip blank lines after `{` (upstream has one such stanza; note that
        # valgrind itself silently drops stanzas with an empty name line).
        j = i + 1
        while j < len(lines) and not lines[j].strip():
            j += 1
        name_no = j + 1
        name = lines[j].strip() if j < len(lines) else ""
        kind = lines[j + 1].strip() if j + 1 < len(lines) else ""
        frames: list[str] = []
        j += 2
        while j < len(lines) and lines[j].strip() != "}":
            entry = lines[j].strip()
            if entry.startswith(("fun:", "obj:")) or entry == "...":
                frames.append(entry)
            j += 1
        if kind.startswith("Memcheck:"):
            stanzas.append(Stanza(name_no, name, tuple(frames)))
        i = j + 1
    return stanzas


def report(label: str, stanzas: list[Stanza]) -> None:
    print(f"{label}: {len(stanzas)}")
    for s in stanzas:
        print(f"  line {s.name_line}: {s.name} [{' > '.join(s.frames[:3])}]")


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("usage: supp-diff.py <upstream.supp> <local.supp>")
    upstream = parse(sys.argv[1])
    local = parse(sys.argv[2])
    up_frames = {s.frames for s in upstream}
    lo_frames = {s.frames for s in local}
    identical = [s for s in local if s.frames in up_frames]
    up_only = [s for s in upstream if s.frames not in lo_frames]
    lo_only = [s for s in local if s.frames not in up_frames]

    print(f"memcheck stanzas: upstream {len(upstream)}, local {len(local)}")
    print(f"identical frame sequences: {len(identical)}")
    report("upstream-only", up_only)
    report("local", lo_only)


if __name__ == "__main__":
    main()
