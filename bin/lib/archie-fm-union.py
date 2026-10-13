#!/usr/bin/env python3
"""bin/lib/archie-fm-union.py — BH-4585 (BH-4574.3): the append-only union
resolver behind Archie's rebase-repair playbook (bin/lib/archie-fm-repair.sh).

No network. No git writes: it reads the index stages of a path a merge left
conflicted (`git show :1:<p>`, `:2:<p>`, `:3:<p>`), and the only thing it
writes is the resolved file in the worktree, which the caller then stages.

  resolve  <worktree> <path>
      rc 0  the file is written; stdout is `shape=union-lines` or
            `shape=union-json`
      rc 1  refused; ONE reason line on stderr. Nothing is written.
      rc 2  could not run (no stages, git failed, a validator missing)

  diagnose <worktree> <path> [note]
      a bounded text block (<= 1500 chars) for a path left conflicted: the
      shape, each hunk's line range, the nearest enclosing definition above
      it, and up to 20 lines from each side. rc 0, or rc 2 when the stages
      cannot be read.

  untar    <tar> <dest> <declared-path>...
      extract a regenerate's output over <dest>, refusing the WHOLE archive
      (rc 1, nothing extracted) when any member is not a regular file or a
      directory, is absolute, has a `..` component, or is not under one of the
      declared paths.

THE RULE (resolve). The three stages go through `git merge-file --diff3`, and
each conflict hunk is base B, ours O (the PR branch) and theirs T
(origin/<target>). With P the common prefix and S the common suffix of O and
T, O = P+Oa+S and T = P+Ta+S, and the candidate is P+Oa+Ta+S (Ta dropped when
it equals Oa).
  * lines files: accepted only when B == P+S in every hunk — both sides
    inserted at the same point and neither changed or deleted a base line —
    and the result passes the extension's validator (node --check for
    .js/.mjs/.cjs, an in-memory sqlite run under an authorizer that denies
    ATTACH/DETACH/PRAGMA for .sql, bash -n for .sh). A validator that rejects
    origin/<target>'s own copy cannot vouch for anything, so the path is
    refused, never "validated".
  * JSON: the text is the two sides' own (never re-serialized, formatting and
    escapes stay byte for byte), a comma is repaired at the ours|theirs
    junction, and the candidate is accepted only when json.loads of it equals
    merge3(base, ours, theirs), an append-only structural merge: an unchanged
    side takes the other, dicts merge per key, a list needs base as a prefix
    of both sides and becomes base + ours' tail + theirs' tail minus
    duplicates. Anything else is refused.
"""
import itertools
import json
import os
import re
import sqlite3
import subprocess
import sys
import tarfile
import tempfile

MARK = 31
OPEN, BASE, MID, CLOSE = "<" * MARK, "|" * MARK, "=" * MARK, ">" * MARK
SIDE_MAX = 20
DIAG_MAX = 1500


class Refuse(Exception):
    pass


def enc(b):
    return b.decode("utf-8", "surrogateescape")


def stage(wt, n, path):
    r = subprocess.run(["git", "-C", wt, "show", ":%d:%s" % (n, path)],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return enc(r.stdout) if r.returncode == 0 else None


def stages(wt, path):
    return stage(wt, 1, path), stage(wt, 2, path), stage(wt, 3, path)


def merge3_text(base, ours, theirs):
    """[('ok', lines) | ('hunk', O, B, T)], from git merge-file --diff3."""
    with tempfile.TemporaryDirectory(prefix="afm-union-") as d:
        files = []
        for name, txt in (("ours", ours), ("base", base), ("theirs", theirs)):
            f = os.path.join(d, name)
            with open(f, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
                fh.write(txt)
            files.append(f)
        r = subprocess.run(["git", "merge-file", "-p", "--diff3", "--marker-size=%d" % MARK,
                            "-L", "ours", "-L", "base", "-L", "theirs"] + files,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode < 0 or r.returncode > 127:
        raise RuntimeError("git merge-file failed: %s" % enc(r.stderr).strip())
    out = enc(r.stdout).splitlines(keepends=True)
    segs, cur, i = [], [], 0
    while i < len(out):
        ln = out[i]
        if ln.startswith(OPEN + " ") or ln.rstrip("\r\n") == OPEN:
            if cur:
                segs.append(("ok", cur))
                cur = []
            o, b, t, part = [], [], [], "o"
            i += 1
            while i < len(out):
                s = out[i]
                if s.startswith(BASE):
                    part = "b"
                elif s.startswith(MID) and s.rstrip("\r\n") == MID:
                    part = "t"
                elif s.startswith(CLOSE):
                    break
                else:
                    {"o": o, "b": b, "t": t}[part].append(s)
                i += 1
            else:
                raise RuntimeError("unterminated conflict hunk in git merge-file output")
            segs.append(("hunk", o, b, t))
        else:
            cur.append(ln)
        i += 1
    if cur:
        segs.append(("ok", cur))
    return segs


def split(o, t):
    """(P, Oa, Ta, S) with O = P+Oa+S and T = P+Ta+S."""
    p = 0
    while p < len(o) and p < len(t) and o[p] == t[p]:
        p += 1
    s = 0
    while s < len(o) - p and s < len(t) - p and o[len(o) - 1 - s] == t[len(t) - 1 - s]:
        s += 1
    return o[:p], o[p:len(o) - s], t[p:len(t) - s], o[len(o) - s:]


def norm_eol(lines):
    """A side that ends without a newline gets one before the other is glued on."""
    if lines and not lines[-1].endswith("\n"):
        return lines[:-1] + [lines[-1] + "\n"]
    return lines


# ── validators ──────────────────────────────────────────────────────────────
def _node_check(text):
    with tempfile.TemporaryDirectory(prefix="afm-node-") as d:
        last = ""
        for ext in (".mjs", ".cjs"):
            f = os.path.join(d, "candidate" + ext)
            with open(f, "w", encoding="utf-8", errors="surrogateescape") as fh:
                fh.write(text)
            r = subprocess.run(["node", "--check", f], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if r.returncode == 0:
                return None
            last = enc(r.stderr).strip().splitlines()
            last = next((x for x in last if "Error" in x), last[-1] if last else "node --check failed")
        return last


SQL_DENY = re.compile(r"\b(attach|detach|vacuum|load_extension)\b", re.I)


def _sql_strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"--[^\n]*", " ", text)


def _sql_check(text):
    if SQL_DENY.search(_sql_strip_comments(text)):
        return "ATTACH/DETACH/VACUUM/load_extension is not allowed in a resolved .sql file"
    deny = {sqlite3.SQLITE_ATTACH, sqlite3.SQLITE_DETACH, sqlite3.SQLITE_PRAGMA}

    def auth(action, *_):
        return sqlite3.SQLITE_DENY if action in deny else sqlite3.SQLITE_OK
    con = sqlite3.connect(":memory:")
    try:
        con.set_authorizer(auth)
        con.executescript(text)
    except sqlite3.Error as e:
        return "sqlite: %s" % e
    finally:
        con.close()
    return None


def _bash_check(text):
    r = subprocess.run(["bash", "-n"], input=text.encode("utf-8", "surrogateescape"),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return None if r.returncode == 0 else (enc(r.stderr).strip().splitlines() or ["bash -n failed"])[0]


def _json_check(text):
    try:
        json.loads(text, object_pairs_hook=no_dup_keys)
    except (ValueError, Refuse) as e:
        return "json: %s" % e
    return None


def validator(path):
    ext = os.path.splitext(path)[1].lower()
    return {".js": _node_check, ".mjs": _node_check, ".cjs": _node_check,
            ".sql": _sql_check, ".sh": _bash_check, ".json": _json_check}.get(ext)


def has_markers(text):
    return any(ln.startswith(("<<<<<<<", ">>>>>>>")) or ln.rstrip("\r\n") == "=======" for ln in text.splitlines())


# ── JSON: the structural proof ──────────────────────────────────────────────
def no_dup_keys(pairs):
    seen = {}
    for k, v in pairs:
        if k in seen:
            raise Refuse("duplicate key %r" % k)
        seen[k] = v
    return seen


def merge3(b, o, t):
    if o == t:
        return o
    if o == b:
        return t
    if t == b:
        return o
    if isinstance(b, dict) and isinstance(o, dict) and isinstance(t, dict):
        out = {}
        for k in list(b) + [k for k in o if k not in b] + [k for k in t if k not in b and k not in o]:
            if k in b:
                if k not in o or k not in t:
                    raise Refuse("key %r was deleted on one side" % k)
                out[k] = merge3(b[k], o[k], t[k])
            elif k in o and k in t:
                if o[k] != t[k]:
                    raise Refuse("key %r was added on both sides with different values" % k)
                out[k] = o[k]
            else:
                out[k] = o[k] if k in o else t[k]
        return out
    if isinstance(b, list) and isinstance(o, list) and isinstance(t, list):
        if o[:len(b)] != b or t[:len(b)] != b:
            raise Refuse("a list was reordered or had a base element removed")
        ot, tt = o[len(b):], t[len(b):]
        return b + ot + [x for x in tt if x not in ot]
    raise Refuse("both sides changed the same value")


def comma_join(left, right):
    """left + right, with a comma added after left's last value when the
    junction needs one (the 6f3fcaba case: neither side carried the `},`)."""
    li = next((i for i in range(len(left) - 1, -1, -1) if left[i].strip()), None)
    ri = next((i for i in range(len(right)) if right[i].strip()), None)
    if li is None or ri is None:
        return left + right
    lc, rc = left[li].rstrip()[-1], right[ri].lstrip()[0]
    if lc in ",[{:" or rc in "]},":
        return left + right
    ln = left[li]
    body = ln.rstrip("\r\n")
    eol = ln[len(body):]
    stripped = body.rstrip()
    left = left[:li] + [stripped + "," + body[len(stripped):] + eol] + left[li + 1:]
    return left + right


def json_candidates(o, t):
    """Every way to glue the two sides that keeps each side's own text: drop k
    lines of T's shared prefix and j lines of O's shared suffix. The first
    (k, j) is P+Oa+Ta+S; the rest are tried only when that one is not the
    structural merge."""
    p, _, _, s = split(o, t)
    seen = set()
    for k in range(len(p), -1, -1):
        for j in range(len(s), -1, -1):
            left = norm_eol(o[:len(o) - j])
            right = t[k:]
            for cand in (comma_join(left, right), left + right):
                key = "".join(cand)
                if key not in seen:
                    seen.add(key)
                    yield cand


def resolve_json(segs, base, ours, theirs):
    try:
        want = merge3(json.loads(base, object_pairs_hook=no_dup_keys),
                      json.loads(ours, object_pairs_hook=no_dup_keys),
                      json.loads(theirs, object_pairs_hook=no_dup_keys))
    except ValueError as e:
        raise Refuse("a side is not JSON: %s" % e)
    hunks = [i for i, s in enumerate(segs) if s[0] == "hunk"]
    options = [list(json_candidates(segs[i][1], segs[i][3])) for i in hunks]
    total = 1
    for opt in options:
        total *= len(opt)
    if total > 2000:
        raise Refuse("too many hunks to prove (%d candidate texts)" % total)
    for pick in itertools.product(*options):
        parts, h = [], 0
        for s in segs:
            if s[0] == "ok":
                parts.extend(s[1])
            else:
                parts.extend(pick[h])
                h += 1
        text = "".join(parts)
        try:
            got = json.loads(text, object_pairs_hook=no_dup_keys)
        except (ValueError, Refuse):
            continue
        if got == want:
            return text
    raise Refuse("no text union of the two sides parses to the append-only merge")


def resolve_lines(segs):
    parts = []
    for s in segs:
        if s[0] == "ok":
            parts.extend(s[1])
            continue
        _, o, b, t = s
        p, oa, ta, sfx = split(o, t)
        if b != p + sfx:
            raise Refuse("both sides changed the same base lines (not an append-only union)")
        mid = norm_eol(oa) if ta and ta != oa else oa
        parts.extend(p + mid + ([] if ta == oa else ta) + sfx)
    return "".join(parts)


def stage_modes(wt, path):
    r = subprocess.run(["git", "-C", wt, "ls-files", "-u", "--", path],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return {ln.split()[0] for ln in enc(r.stdout).splitlines() if ln.strip()}


def cmd_resolve(wt, path):
    modes = stage_modes(wt, path)
    if not modes or not modes <= {"100644", "100755"}:
        print("refused: %s is not a plain file on every side (modes %s)" % (path, " ".join(sorted(modes)) or "none"), file=sys.stderr)
        return 1
    if os.path.islink(os.path.join(wt, path)):
        print("refused: %s is a symlink in the worktree" % path, file=sys.stderr)
        return 1
    base, ours, theirs = stages(wt, path)
    if ours is None or theirs is None:
        print("refused: one side deleted %s, the other edited it" % path, file=sys.stderr)
        return 1
    if base is None:
        base = ""
    segs = merge3_text(base, ours, theirs)
    if not any(s[0] == "hunk" for s in segs):
        print("refused: git merge-file finds no conflict in %s" % path, file=sys.stderr)
        return 1
    check = validator(path)
    if check is not None:
        why = check(theirs)
        if why is not None:
            print("refused: the validator rejects origin's own copy of %s (%s), so it cannot vouch for a union" % (path, why), file=sys.stderr)
            return 1
    is_json = path.lower().endswith(".json")
    try:
        text = resolve_json(segs, base, ours, theirs) if is_json else resolve_lines(segs)
    except Refuse as e:
        print("refused: %s" % e, file=sys.stderr)
        return 1
    if has_markers(text):
        print("refused: the union still carries conflict markers", file=sys.stderr)
        return 1
    if check is not None:
        why = check(text)
        if why is not None:
            print("refused: validator refused: %s" % why, file=sys.stderr)
            return 1
    with open(os.path.join(wt, path), "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
        fh.write(text)
    print("shape=%s" % ("union-json" if is_json else "union-lines"))
    return 0


# ── diagnose ────────────────────────────────────────────────────────────────
DEF_RES = [
    re.compile(r"^\s*(?:export\s+)?(?:async\s+)?function\s+([\w$]+)"),
    re.compile(r"^\s*(?:function\s+)?([A-Za-z_][\w:-]*)\s*\(\)\s*\{?"),
    re.compile(r"^\s*(?:async\s+)?def\s+(\w+)"),
    re.compile(r"^\s*(?:export\s+)?(?:const|let|var)\s+([\w$]+)\s*="),
    re.compile(r"\bCREATE\s+(?:TABLE|INDEX|VIEW|TRIGGER)\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w.]+)", re.I),
]


def enclosing(lines, upto):
    for i in range(upto - 1, -1, -1):
        for rx in DEF_RES:
            m = rx.search(lines[i])
            if m:
                return "%s (line %d)" % (lines[i].strip()[:120], i + 1)
    return "(no enclosing definition found above it)"


def clip(lines):
    out = [ln.rstrip("\r\n")[:160] for ln in lines[:SIDE_MAX]]
    if len(lines) > SIDE_MAX:
        out.append("... (%d more lines)" % (len(lines) - SIDE_MAX))
    return out or ["(nothing)"]


def cmd_diagnose(wt, path, note):
    base, ours, theirs = stages(wt, path)
    out = ["--- %s ---" % path]
    if ours is None and theirs is None:
        print("\n".join(out + ["shape: the stages could not be read"]))
        return 2
    if ours is None or theirs is None:
        out.append("shape: one side deleted %s, the other edited it (%s deleted it)" %
                   (path, "this branch" if ours is None else "origin"))
        if note:
            out.append("note: " + note)
        print("\n".join(out)[:DIAG_MAX])
        return 0
    segs = merge3_text(base or "", ours, theirs)
    hunks, line, merged = [], 1, []
    for s in segs:
        if s[0] == "ok":
            merged.extend(s[1])
            line += len(s[1])
        else:
            hunks.append((line, s[1], s[2], s[3], len(merged)))
            merged.extend(s[1])
            line += len(s[1])
    shapes = []
    for _, o, b, t, _ in hunks:
        p, _, _, sfx = split(o, t)
        shapes.append("insert-only" if b == p + sfx else ("overlap" if not b else "changed"))
    if base is None:
        shape = "both sides added %s" % path
    elif "changed" in shapes:
        shape = "both sides changed the same base lines"
    elif "overlap" in shapes:
        shape = "both sides inserted overlapping lines at the same point"
    else:
        shape = "both sides inserted at the same point (append-only)"
    out.append("shape: %s; %d conflict hunk(s)" % (shape, len(hunks)))
    if note:
        out.append("note: " + note)
    for start, o, b, t, at in hunks[:3]:
        out.append("hunk at line %d-%d of this branch's copy (%d base line(s) at stake)" % (start, start + max(len(o), 1) - 1, len(b)))
        out.append("in: " + enclosing(merged, at))
        out.append("this branch:")
        out.extend("  " + x for x in clip(o))
        out.append("origin:")
        out.extend("  " + x for x in clip(t))
    if len(hunks) > 3:
        out.append("... and %d more hunk(s)" % (len(hunks) - 3))
    text = "\n".join(out)
    if len(text) > DIAG_MAX:
        text = text[:DIAG_MAX - 14] + "\n... (clipped)"
    print(text)
    return 0


# ── untar ───────────────────────────────────────────────────────────────────
def under(name, declared):
    for d in declared:
        d = d.rstrip("/")
        if name == d or name.startswith(d + "/"):
            return True
    return False


def cmd_untar(tar, dest, declared):
    try:
        tf = tarfile.open(tar)
    except (OSError, tarfile.TarError) as e:
        print("refused: the archive will not open: %s" % e, file=sys.stderr)
        return 2
    root = os.path.realpath(dest)
    with tf:
        members = tf.getmembers()
        for m in members:
            name = m.name[2:] if m.name.startswith("./") else m.name
            parts = name.split("/")
            if not (m.isreg() or m.isdir()):
                print("refused: %s is not a regular file or a directory" % m.name, file=sys.stderr)
                return 1
            if name.startswith("/") or ".." in parts:
                print("refused: %s escapes the tree" % m.name, file=sys.stderr)
                return 1
            if not under(name.rstrip("/"), declared):
                print("refused: %s is not under a declared path" % m.name, file=sys.stderr)
                return 1
            real = os.path.realpath(os.path.join(root, name))
            if real != root and not real.startswith(root + os.sep):
                print("refused: %s resolves outside the tree (a symlink on the way)" % m.name, file=sys.stderr)
                return 1
        for m in members:
            m.mode = (m.mode & 0o755) | (0o700 if m.isdir() else 0o600)
            m.uid = m.gid = 0
            m.uname = m.gname = ""
        if hasattr(tarfile, "data_filter"):
            tf.extractall(dest, members=members, filter="data")
        else:
            tf.extractall(dest, members=members)
    return 0


def main(argv):
    if len(argv) >= 3 and argv[0] == "resolve":
        try:
            return cmd_resolve(argv[1], argv[2])
        except (RuntimeError, OSError) as e:
            print("could not run: %s" % e, file=sys.stderr)
            return 2
    if len(argv) >= 3 and argv[0] == "diagnose":
        try:
            return cmd_diagnose(argv[1], argv[2], argv[3] if len(argv) > 3 else "")
        except (RuntimeError, OSError) as e:
            print("--- %s ---\nshape: could not be read (%s)" % (argv[2], e))
            return 2
    if len(argv) >= 4 and argv[0] == "untar":
        return cmd_untar(argv[1], argv[2], argv[3:])
    print("usage: archie-fm-union.py resolve <wt> <path> | diagnose <wt> <path> [note] | untar <tar> <dest> <path>...", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    sys.exit(main(sys.argv[1:]))
