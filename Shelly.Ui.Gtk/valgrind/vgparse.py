#!/usr/bin/env python3
"""Split valgrind memcheck loss records and group them by top frames.

Usage: python3 valgrind/vgparse.py <pid-or-logfile>

Accepts a PID (reads ./valgrind-<pid>.log) or a direct log path. Mostly useful
for historical logs recorded with --show-leak-kinds=definite,indirect; the
valgrind build step now prints only error contexts (definite,possible), which
are small enough to triage by eye.

Record headers are not indented; frame lines are `   at 0x...:` / `   by
0x...:` after the `==<pid>== ` prefix — matching those two formats is where
most ad-hoc greps of these logs fail. Sizes may be comma-separated.

Keep it clean under `ruff check`, `ruff format --check` and `ty check`: the
repo carries no config for either tool, so run them on this file. Type rules
(same as scripts/check-a11y.py): `from __future__ import annotations`, full
parameter/return annotations on every function, builtin generics
(`list[str]`, `tuple[str, ...]`), and frozen dataclasses for record types —
a loss record is a `Record`, never a heterogeneous list. Stdlib only, so
unlike check-a11y.py no Protocols are needed: ty sees every import.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class Record:
    kind: str  # "definitely", "indirectly", "possibly", ...
    nbytes: int
    blocks: int
    lines: tuple[str, ...]  # header body first, then at/by frame bodies


def read_records(path: str) -> list[Record]:
    """Split the log's loss records for its main PID, in log order."""
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    pid: str | None = None
    for ln in lines:
        m = re.match(r"==(\d+)== ", ln)
        if m:
            pid = m.group(1)
            break
    if pid is None:
        sys.exit(f"no ==<pid>== lines found in {path}")
    pre = f"=={pid}== "

    hdr = re.compile(r"([\d,]+) bytes in ([\d,]+) blocks are (\w+) lost in loss record")
    recs: list[Record] = []
    kind = ""
    nbytes = 0
    blocks = 0
    bodies: list[str] = []
    for ln in lines:
        ln = ln.rstrip("\n")
        if not ln.startswith(pre):
            if bodies:
                recs.append(Record(kind, nbytes, blocks, tuple(bodies)))
                bodies = []
            continue
        body = ln[len(pre) :].strip()
        m = hdr.search(body)
        if m:
            if bodies:
                recs.append(Record(kind, nbytes, blocks, tuple(bodies)))
            kind = m.group(3)
            nbytes = int(m.group(1).replace(",", ""))
            blocks = int(m.group(2).replace(",", ""))
            bodies = [body]
        elif bodies and body.startswith(("at ", "by ", "0x")):
            bodies.append(body)
    if bodies:
        recs.append(Record(kind, nbytes, blocks, tuple(bodies)))
    return recs


def frame_chain(lines: tuple[str, ...]) -> list[str]:
    """Function names of a record's frames, location suffixes stripped."""
    fs: list[str] = []
    for b in lines[1:]:
        b = re.sub(r"^(at|by) ", "", b)
        m = re.match(r"(?:0x[0-9A-Fa-f]+: )?(\S+?)(?: \([^)]*\))?(?: in .*)?$", b)
        if m:
            fs.append(m.group(1))
    return fs


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: vgparse.py <pid-or-logfile>")
    arg = sys.argv[1]
    path = arg if re.search(r"\.log$", arg) else f"valgrind-{arg}.log"
    recs = read_records(path)

    tot: dict[tuple[str, str], list[int]] = {}
    for r in recs:
        g = tot.setdefault((r.kind, ">".join(frame_chain(r.lines)[:5])), [0, 0])
        g[0] += r.nbytes
        g[1] += 1
    for k in ("definitely", "indirectly"):
        grp = sorted([(v, kk) for (kk, _), v in tot.items() if kk == k], reverse=True)
        s = sum(v[0] for v, _ in grp) or 1
        print(f"TOP {k} lost chains (groups={len(grp)}, total={s} B):")
        for v, kk in grp[:8]:
            print(f"   {v[0]:9d} B {v[1]:4d} recs {100 * v[0] / s:5.1f}%  {kk[:150]}")
        print()

    frames: set[str] = set()
    for r in recs:
        for b in r.lines[1:]:
            m = re.match(r"(?:at|by) 0x[0-9A-Fa-f]+: (\S+) \(([^)]+)\)", b)
            if m:
                frames.add(m.group(1) + " (" + m.group(2) + ")")
            elif re.match(r"(?:at|by) 0x[0-9A-Fa-f]+: (\S+) in ", b):
                frames.add(re.sub(r"^at |^by ", "", b))
    app = [f for f in frames if "Shelly." in f or f.endswith(".zig)") or ".zig:" in f]
    print(f"APP FRAMES in leak records ({len(app)}):")
    for f in sorted(app):
        print("   ", f)


if __name__ == "__main__":
    main()
