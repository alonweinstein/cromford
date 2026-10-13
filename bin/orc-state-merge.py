#!/usr/bin/env python3
"""bin/orc-state-merge.py <live> <base> <mine> [turn-key] — section 3-way merge.

Parallel orchestrator turns (BH-5336) each edit their own copy of STATE.md or
facts.md. When a turn ends, bin/lib/orc-turns.sh runs this script under a short
lock to merge the copy back into the live file. The merged text goes to stdout.

A file is split into sections on lines that start with "## ". The text before
the first heading is the preamble. A section's key is its heading line plus how
many times that heading occurred before it. Per key, with b = base (the live
file when the turn started), m = mine (the turn's copy), l = live (now):

  m == b             keep l (another turn's change, or no change at all)
  l == b             take m (only this turn changed it; absent in m = deleted)
  both changed       m absent: keep l. l absent: take m. Else keep l, then
                     append m as "## <heading> (concurrent edit from turn <key>)".

Nothing another turn wrote is ever dropped. Output order: the live order, then
sections that are new in mine, in mine's order. A file that does not exist is
empty. Any read error exits 1 and prints nothing, so the caller keeps the live
file unchanged.
"""
import os
import sys


def read(path):
    if not os.path.lexists(path):
        return ""
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
        return fh.read()


def sections(text):
    """Ordered list of (key, heading, body) and a dict key -> full text."""
    out = []
    head, buf = None, []

    def flush():
        if head is None and not buf:
            return
        out.append((head, "".join(buf)))

    for line in text.splitlines(keepends=True):
        if line.startswith("## "):
            flush()
            head, buf = line.rstrip("\n"), [line]
        else:
            buf.append(line)
    flush()
    seen, keyed = {}, []
    for h, body in out:
        n = seen.get(h, 0)
        seen[h] = n + 1
        keyed.append(((h or "", n), h, body))
    return keyed


def main(argv):
    if len(argv) < 4:
        sys.stderr.write("usage: orc-state-merge.py <live> <base> <mine> [turn-key]\n")
        return 2
    turn = argv[4] if len(argv) > 4 and argv[4] else "?"
    try:
        live, base, mine = (sections(read(p)) for p in argv[1:4])
    except (OSError, UnicodeError) as exc:
        sys.stderr.write("orc-state-merge: %s\n" % exc)
        return 1
    L = {k: t for k, _h, t in live}
    B = {k: t for k, _h, t in base}
    M = {k: t for k, _h, t in mine}
    heads = {k: h for k, h, _t in live + base + mine}

    def merged(k):
        l, b, m = L.get(k), B.get(k), M.get(k)
        if m == b:
            return l
        if l == b:
            return m
        if m is None:
            return l
        if l is None:
            return m
        h = heads.get(k)
        title = (h[3:] if h else "Preamble")
        body = m.split("\n", 1)[1] if h and "\n" in m else ("" if h else m)
        extra = "## %s (concurrent edit from turn %s)\n%s" % (title, turn, body)
        return l + ("" if l.endswith("\n") else "\n") + extra

    order = [k for k, _h, _t in live] + [k for k, _h, _t in mine if k not in L]
    parts = []
    for k in order:
        t = merged(k)
        if t is None or t == "":
            continue
        if parts and not parts[-1].endswith("\n"):
            parts[-1] += "\n"
        parts.append(t)
    sys.stdout.buffer.write("".join(parts).encode("utf-8", errors="surrogateescape"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
