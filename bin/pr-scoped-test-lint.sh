#!/bin/bash
# bin/pr-scoped-test-lint.sh [--root DIR] [path ...]
#
# A TEST MUST PASS ON MAIN AFTER ITS PR MERGES (BH-5684).
#
# Some tests assert on their OWN PR's diff or commits: "this PR does not touch
# X", or "at least one of this ticket's commits exists". That holds while the
# PR is open. Once it merges, the range is empty or carries other PRs, and the
# test fails on main and on every later batch.
#   - W6 in tests/harness-ci-spa-worker-gate.bh-4969-test.sh ran
#     `git diff --quiet $(merge-base HEAD origin/main) -- .mergify.yml` and
#     failed every PR that changed .mergify.yml (#5527 was blocked on it).
#   - Q-SCOPE in tests/archie-fm-queue.bh-4584-test.sh required one BH-4584
#     commit in origin/main..HEAD. After #4675 merged, main and batch #5673
#     went red.
#
# WHAT IS A HIT (one per line; the pattern id is in the output):
#   diff-quiet   `diff --quiet <base> -- <path>`, where <base> holds `origin/`,
#                `merge-base` or `$`. A bare `HEAD` base reads the worktree,
#                not the PR range, so it is not a hit.
#   grep-bh      `--grep` with a bh-<n> value, on a line that holds an A..B or
#                A...B range.
#   range        `origin/main..HEAD` or `origin/main...HEAD`.
#   merge-base   a `git ... diff|log` line that holds `$(... merge-base ...
#                origin/main ...)`, or reads $VAR where an earlier line did
#                `VAR=$(... merge-base ... origin/main ...)`.
#
# WHAT IS NOT SCANNED: blank lines, comment lines (`#`, `//`), heredoc bodies
# (fixture text; a real read inside a generated script is a known miss), and
# lines whose first command is `echo` or `printf` (message text).
#
# WHAT GUARDS A HIT:
#   - a marker on the previous non-blank line: `# pr-scoped: ok <reason>`
#     (`// pr-scoped: ok <reason>` in JS). A marker with no reason is its own
#     finding, `marker-no-reason`, and guards nothing.
#   - an empty-range skip. The hit's subject is the variable the hit line
#     assigns (`VAR=$(`, `local VAR=`), else the function whose body holds it
#     (the nearest `name() {` above). Within WINDOW (25) lines of the hit, one
#     line tests that subject for emptiness (`[ -n`, `[ -z`, `[[ -n`, `[[ -z`,
#     `test -n`, `test -z` with `$VAR`, `${VAR}` or `$(name)`), and another
#     prints a skip note (`echo`/`printf` with "skip"). WINDOW is a parser
#     constant, not a business setting.
#
# FILES: with no path, `git -C <root> ls-files tests` filtered to `*-test.sh`
# and `*.test.js`. <root> is this script's repo, or --root DIR. With paths,
# exactly those files.
#
# OUTPUT: `<file>:<line>: pr-scoped-unguarded: <id>: <line, trimmed, max 160>`
# per finding, then `pr-scoped-test-lint: <n> unguarded in <m> files (<k> scanned)`.
#
# EXIT: 0 clean, 1 one or more findings, 2 scanned nothing (no files, no git,
# no python3, an unreadable path). A scan of nothing is never green.
# No clock, randomness or network.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
PATHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root)    [ $# -ge 2 ] || { echo "pr-scoped-test-lint: --root needs a directory" >&2; exit 2; }
               ROOT="$2"; shift ;;
    -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
    -*)        echo "pr-scoped-test-lint: unknown flag $1" >&2; exit 2 ;;
    *)         PATHS+=("$1") ;;
  esac
  shift
done
command -v python3 >/dev/null 2>&1 || { echo "pr-scoped-test-lint: no python3, scanned nothing" >&2; exit 2; }

LIST=$(mktemp) || exit 2
trap 'rm -f "$LIST"' EXIT
if [ "${#PATHS[@]}" -gt 0 ]; then
  printf '%s\n' "${PATHS[@]}" > "$LIST"
  BASE_DIR="."
else
  command -v git >/dev/null 2>&1 || { echo "pr-scoped-test-lint: no git, scanned nothing" >&2; exit 2; }
  git -C "$ROOT" ls-files tests 2>/dev/null | grep -E '(-test\.sh|\.test\.js)$' > "$LIST"
  BASE_DIR="$ROOT"
fi

python3 -I - "$LIST" "$BASE_DIR" <<'PY'
import os, re, sys

WINDOW = 25
list_path, base_dir = sys.argv[1], sys.argv[2]
files = [l for l in open(list_path).read().split('\n') if l]

HEREDOC = re.compile(r'''(?<![<\d])<<(?!<)(-?)\s*\\?(['"]?)([A-Za-z_][\w.-]*)\2''')
RANGE = re.compile(r'origin/main\.\.\.?HEAD')
ANY_RANGE = re.compile(r'\S\.\.\.?\S')
GREP_BH = re.compile(r'--grep[= ]\s*[\'"]?[^\'"\s]*bh-[0-9]+', re.I)
GIT_DIFF_LOG = re.compile(r'\bgit\b.*\b(diff|log)(?![\w-])')
MB_INLINE = re.compile(r'\$\([^)]*merge-base[^)]*origin/main|\$\([^)]*origin/main[^)]*merge-base')
MB_ASSIGN = re.compile(r'^\s*(?:local\s+|export\s+|readonly\s+)?([A-Za-z_]\w*)=.*\$\(.*merge-base.*origin/main')
DIFF_QUIET = re.compile(r'\bdiff\b(.*?)\s--\s')
MARKER = re.compile(r'^(?:#|//)\s*pr-scoped:\s*ok\b(.*)$')
ASSIGN = re.compile(r'^\s*(?:local\s+|export\s+)?([A-Za-z_]\w*)=')
FUNC = re.compile(r'^\s*(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)\s*(?:\{|$)')
EMPTY_TEST = re.compile(r'(\[\[?|\btest)\s+-[nz]\s')
SKIP_NOTE = re.compile(r'^\s*(?:.*[;&|{]\s*)?(?:echo|printf)\b.*skip', re.I)
MSG = re.compile(r'^\s*(echo|printf)\b')

def code_part(s):
    """The line with a trailing shell comment cut off (outside quotes)."""
    q = None
    for i, ch in enumerate(s):
        if q:
            if ch == q: q = None
        elif ch in '\'"': q = ch
        elif ch == '#' and (i == 0 or s[i-1] in ' \t;'): return s[:i]
    return s

def heredoc_part(s):
    """code_part with the text of quoted strings blanked, so `echo "use <<EOF"`
    opens no heredoc. A quote right after `<<` / `<<-` is the delimiter itself
    (`<<'EOF'`) and is kept."""
    s = code_part(s)
    out, q, keep = [], None, False
    for i, ch in enumerate(s):
        if q:
            if ch == q: q = None; out.append(ch)
            else: out.append(ch if keep else ' ')
        elif ch in '\'"':
            q = ch; out.append(ch)
            keep = re.search(r'<<-?\s*$', s[:i]) is not None
        else:
            out.append(ch)
    return ''.join(out)

def scan(path, label):
    try:
        raw = open(path, encoding='utf-8', errors='replace').read()
    except OSError as e:
        print('pr-scoped-test-lint: cannot read %s: %s' % (label, e), file=sys.stderr)
        return None
    lines = [l.rstrip('\r') for l in raw.split('\n')]
    is_js = path.endswith('.js')
    cmt = '//' if is_js else '#'
    # kind per line: 'blank' | 'comment' | 'heredoc' | 'code'
    kinds, pending, cur = [], [], None
    for l in lines:
        if cur is not None:
            kinds.append('heredoc')
            word, strip_tabs = cur
            if (l.lstrip('\t') if strip_tabs else l) == word:
                cur = pending.pop(0) if pending else None
            continue
        s = l.strip()
        if not s: kinds.append('blank'); continue
        if s.startswith(cmt): kinds.append('comment'); continue
        kinds.append('code')
        if not is_js:
            for m in HEREDOC.finditer(heredoc_part(l)):
                pending.append((m.group(3), m.group(1) == '-'))
            if pending: cur = pending.pop(0)
    out = []
    mb_vars = set()
    for i, l in enumerate(lines):
        k = kinds[i]
        if k == 'comment':
            m = MARKER.match(l.strip())
            if m and not m.group(1).strip():
                out.append((i + 1, 'marker-no-reason', l))
            continue
        if k != 'code': continue
        c = code_part(l) if not is_js else l
        hit = None
        dq = DIFF_QUIET.search(c)
        if dq and '--quiet' in dq.group(1):
            base = [t for t in dq.group(1).split() if not t.startswith('-')]
            if any(('origin/' in t or 'merge-base' in t or '$' in t) for t in base):
                hit = 'diff-quiet'
        if not hit and not MSG.match(c):
            if GREP_BH.search(c) and ANY_RANGE.search(c): hit = 'grep-bh'
            elif RANGE.search(c): hit = 'range'
            elif GIT_DIFF_LOG.search(c) and (MB_INLINE.search(c) or any(
                    re.search(r'\$\{?%s\b' % re.escape(v), c) for v in mb_vars)):
                hit = 'merge-base'
        ma = MB_ASSIGN.match(c)
        if ma: mb_vars.add(ma.group(1))
        if hit and not guarded(lines, kinds, i, c, cmt, out):
            out.append((i + 1, hit, l))
    return sorted(out)

def guarded(lines, kinds, i, c, cmt, out):
    j = i - 1
    while j >= 0 and not lines[j].strip(): j -= 1
    if j >= 0:
        m = MARKER.match(lines[j].strip())
        if m and lines[j].strip().startswith(cmt):
            return bool(m.group(1).strip())   # a reasonless marker is its own finding
    a = ASSIGN.match(c)
    if a:
        subj = r'\$\{?%s\b' % re.escape(a.group(1))
    else:
        subj = None
        for j in range(i, -1, -1):
            f = FUNC.match(lines[j]) if kinds[j] == 'code' else None
            if f:
                subj = r'\$\(\s*%s\s*\)' % re.escape(f.group(1)); break
        if subj is None: return False
    lo, hi = max(0, i - WINDOW), min(len(lines), i + WINDOW + 1)
    tested = noted = False
    for j in range(lo, hi):
        if kinds[j] != 'code': continue
        if EMPTY_TEST.search(lines[j]) and re.search(subj, lines[j]): tested = True
        if SKIP_NOTE.search(lines[j]): noted = True
    return tested and noted

n_find, n_files, n_scanned, unreadable = 0, 0, 0, 0
for f in files:
    path = f if os.path.isabs(f) else os.path.join(base_dir, f)
    res = scan(path, f)
    if res is None:
        unreadable += 1; continue
    n_scanned += 1
    if res: n_files += 1
    for ln, pid, text in res:
        n_find += 1
        print('%s:%d: pr-scoped-unguarded: %s: %s' % (f, ln, pid, text.strip()[:160]))
print('pr-scoped-test-lint: %d unguarded in %d files (%d scanned)' % (n_find, n_files, n_scanned))
if n_scanned == 0 or unreadable:
    print('pr-scoped-test-lint: scanned nothing or a path was unreadable; refusing to report green', file=sys.stderr)
    sys.exit(2)
sys.exit(1 if n_find else 0)
PY
