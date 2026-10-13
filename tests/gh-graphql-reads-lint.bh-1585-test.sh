#!/bin/bash
# tests/gh-graphql-reads-lint.bh-1585-test.sh — BH-1585: no NEW GraphQL call in bin/
# (`gh pr view|list`, `gh issue view|list|comment|close|edit` — BH-1648 added
# the three issue write verbs, which spend GraphQL too — and a bare
# `gh api graphql`). `gh issue create` and `gh pr` write verbs are not counted.
#
# THE BUCKET NOBODY WATCHED. `gh pr view|list` and `gh issue view|list` speak
# GraphQL, which is a separate 6,600/h budget from REST, and on 2026-09-23 it
# ran at ~4,700/h while `bin/gh-token.sh --status` reported graphql used=0.
# BH-1585 moved the biggest spenders to REST (bin/lib/gh-rest.sh); this lint is
# what keeps the count from growing back one "just this once" call at a time.
#
# THE RULE. Every tracked shell file under bin/ may carry at most as many
# GraphQL read lines as tests/gh-graphql-reads-allowlist.tsv grants it (a file
# the list does not name is granted 0). A line that genuinely needs one carries
# `# gh-guard-allow: <one-line reason>` — the same exemption sentence
# tests/gh-no-graphql-decision-guard-test.sh honours, and a blank reason
# exempts nothing. A file that went BELOW its grant is not a failure (a sibling
# PR converting a call must not have to edit this list to stay green); the run
# prints it so the next edit can lower the grant.
#
# The scanner peels the prefixes this repo actually writes in front of a call
# (`$(timeout 20 gh pr view …)`, `if gh …`, `GH_TOKEN=x gh …`, a backtick) —
# the same shapes tests/gh-no-graphql-decision-guard-test.sh documents — and
# the SAME program scans the repo and the fixtures below, so the guard is one
# somebody has watched fail. It prints `path:line`, never the line's contents.
#
# TWO MODES (tests/lib/ratchet-delta.sh). The grant check above is STRICT
# (RATCHET_MODE=strict or --strict), for a scheduled or post-merge run. The
# default, DELTA, is what every PR and merge-queue run uses: count each file's
# un-exempted GraphQL read lines at the base (the newest main this HEAD
# contains) and at HEAD, and go red only when THIS diff raised a file's count
# or added a file with one. Grants are never raised, so a raise was always the
# violation; what delta mode drops is the red a batch got from lines main (or
# a sibling PR in the same batch) landed elsewhere. A base that does not
# resolve is red. Block 3 drives both modes through hermetic git repos.
#
# Run from anywhere: tests/gh-graphql-reads-lint.bh-1585-test.sh [--strict]
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

cat > "$T/scan.py" <<'PY'
import os, re, sys

# Review round 1 (Q7): a bare `gh api graphql` is GraphQL too, and unlike the
# ledgered `gh_rest POST graphql` (bin/lib/gh-pr-list.sh's one mergeQueue read)
# nothing counts it.
CALL = re.compile(r"^gh\s+(?:pr\s+(?:view|list)|issue\s+(?:view|list|comment|close|edit)|api(?:\s+\S+)*?\s+graphql)(?:\s|$)")
ALLOW = re.compile(r"#\s*gh-guard-allow:\s*\S")
SPLIT = re.compile(r"\$\(|\|\||&&|[|;{(`]")
KEYWORD = re.compile(
    r"^(?:if|then|else|elif|do|done|while|until|!|time|exec|command|env|nohup|sudo)$")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
TIMEOUT_ARG = re.compile(r"^-|^[0-9]+(?:\.[0-9]+)?[smhd]?$")


def balanced(word):
    return word.count('"') % 2 == 0 and word.count("'") % 2 == 0


def peel(chunk):
    words, i = chunk.split(), 0
    while i < len(words):
        w = words[i]
        if KEYWORD.match(w) or (ASSIGN.match(w) and balanced(w)):
            i += 1
        elif w == "timeout":
            i += 1
            while i < len(words) and TIMEOUT_ARG.match(words[i]):
                i += 1
        else:
            break
    return " ".join(words[i:]) + " "


def strip_comment(line):
    out, sq, dq, prev = [], False, False, ""
    for ch in line:
        if ch == "'" and not dq:
            sq = not sq
        elif ch == '"' and not sq:
            dq = not dq
        elif ch == "#" and not sq and not dq and (prev == "" or prev.isspace() or prev in ";&|("):
            break
        out.append(ch)
        prev = ch
    return "".join(out)


def shell(path):
    if path.endswith(".sh"):
        return True
    try:
        with open(path, errors="ignore") as fh:
            first = fh.readline()
    except OSError:
        return False
    return first.startswith("#!") and ("bash" in first or first.rstrip().endswith("/sh"))


root, allow_f = sys.argv[1], sys.argv[2]
counts_only = len(sys.argv) > 3 and sys.argv[3] == "--counts"
grant = {}
if os.path.exists(allow_f):
    for raw in open(allow_f):
        raw = raw.split("#", 1)[0].strip()
        if not raw:
            continue
        n, path = raw.split(None, 1)
        grant[path.strip()] = int(n)

scanned, over, under, hits = 0, [], [], {}
bindir = os.path.join(root, "bin")
for dirpath, dirs, names in os.walk(bindir):
    dirs.sort()
    for name in sorted(names):
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root)
        if not shell(path):
            continue
        scanned += 1
        with open(path, errors="ignore") as fh:
            lines = fh.read().split("\n")
        found = []
        for n, raw in enumerate(lines, 1):
            if ALLOW.search(raw):
                continue
            code = strip_comment(raw).strip()
            if not code:
                continue
            for chunk in SPLIT.split(code):
                if CALL.match(peel(chunk)):
                    found.append(n)
                    break
        if found:
            hits[rel] = found
        g = grant.get(rel, 0)
        if len(found) > g:
            over.append(rel)
        elif len(found) < g:
            under.append((rel, len(found), g))

if counts_only:
    # delta mode's input: "<path>\t<lines>" per file with a read, nothing else
    for rel in sorted(hits):
        print("%s\t%d" % (rel, len(hits[rel])))
    sys.exit(2 if scanned == 0 else 0)
for rel in over:
    print("OVER %s: %d GraphQL read line(s), granted %d: %s" % (
        rel, len(hits[rel]), grant.get(rel, 0), ",".join("%s:%d" % (rel, n) for n in hits[rel])))
for rel, have, g in under:
    print("below grant (lower it): %s has %d, granted %d" % (rel, have, g))
print("scanned %d shell files, %d over their grant" % (scanned, len(over)))
if scanned == 0:
    sys.exit(2)
sys.exit(1 if over else 0)
PY

scan() { python3 "$T/scan.py" "$1" "$2" > "$T/scan.out" 2>&1; }

# ══ 1. the repo, against its allowlist ═══════════════════════════════════════
[ -r "$DIR/tests/gh-graphql-reads-allowlist.tsv" ] && ok || bad "1a tests/gh-graphql-reads-allowlist.tsv is missing"
# delta_check <repo> <base-commit> — red when THIS diff adds a GraphQL read line.
delta_check() {
  local repo="$1" ref="$2" w p n b rc=0
  w=$(mktemp -d "$T/delta-base.XXXXXX") || return 1
  rd_tree "$repo" "$ref" "$w" bin || { echo "cannot read bin/ at base $ref"; return 1; }
  mkdir -p "$w/bin"
  python3 "$T/scan.py" "$w" /dev/null --counts > "$w.base"; [ $? -le 2 ] || { echo "scanner failed on base $ref"; return 1; }
  python3 "$T/scan.py" "$repo" /dev/null --counts > "$w.head" || { echo "scanner failed on $repo (a tree with no shell file is not a pass)"; return 1; }
  while IFS=$'\t' read -r p n b; do
    echo "OVER $p: $n GraphQL read line(s), $b at base ${ref:0:12} — move it to bin/lib/gh-rest.sh, or give it a '# gh-guard-allow: <reason>'"
    rc=1
  done < <(rd_delta "$w.head" "$w.base")
  return $rc
}
# real_check <repo> — the check the run makes, by mode.
real_check() {
  local base
  case "$MODE" in
    strict) scan "$1" "$1/tests/gh-graphql-reads-allowlist.tsv" || { cat "$T/scan.out"; return 1; } ;;
    delta)  base=$(rd_base "$1") || { echo "$base"; return 1; }
            delta_check "$1" "$base" ;;
  esac
}
MODE=$(rd_mode "$@") || { echo "FAIL: $MODE"; exit 1; }
OUT=$(real_check "$DIR"); rc=$?
[ "$rc" = 0 ] && ok || bad "1b bin/ grew a GraphQL read ($MODE mode, rc $rc) — move it to bin/lib/gh-rest.sh, or give it a '# gh-guard-allow: <reason>':
$(grep -v '^below grant' <<<"$OUT")"
scan "$DIR" "$DIR/tests/gh-graphql-reads-allowlist.tsv"
grep '^below grant' "$T/scan.out" || true
for f in bin/rebase-train.sh bin/lib/mc/classify.sh bin/pre-arm-guards.sh; do
  awk -v f="$f" '$2==f && $1>0{e=1} END{exit !e}' "$DIR/tests/gh-graphql-reads-allowlist.tsv" 2>/dev/null \
    && bad "1c $f was converted by BH-1585 and must carry no grant" || ok
done

# ══ 2. the fixtures — the same program, watched failing ═════════════════════
fx() { rm -rf "$T/fx"; mkdir -p "$T/fx/bin/lib"; : > "$T/fx/allow.tsv"; }
put() { printf '#!/bin/bash\n%s\n' "$1" > "$T/fx/bin/${2:-x.sh}"; }
expect() { # expect <label> <want-rc> [text]
  local rc; scan "$T/fx" "$T/fx/allow.tsv"; rc=$?
  if [ "$rc" != "$2" ]; then bad "$1: rc=$rc (want $2): $(cat "$T/scan.out")"; return; fi
  if [ -n "${3:-}" ] && ! grep -qF -- "$3" "$T/scan.out"; then bad "$1: '$3' not in $(cat "$T/scan.out")"; return; fi
  ok
}
fx; put 'S=$(timeout 20 gh pr view 7 -R o/r --json state -q .state)'
expect '2a a planted gh pr view (timeout, $()) is caught' 1 'bin/x.sh:2'
grep -q -- '--json' "$T/scan.out" && bad '2b the lint printed the offending line contents' || ok
fx; put 'if gh issue list -R o/r --json number >/dev/null; then :; fi'
expect '2c gh issue list after `if`' 1 'bin/x.sh:2'
fx; put 'L=`gh pr list -R o/r`' lib/y.sh
expect '2d a backtick in bin/lib' 1 'bin/lib/y.sh:2'
fx; put 'gh api "repos/o/r/pulls/7"'
expect '2e gh api is REST, never a hit' 0
fx; put '# gh pr view 7 is what this used to do'
expect '2f a comment is not a call' 0
fx; put 'S=$(gh pr view 7 --json state) # gh-guard-allow: needs isInMergeQueue'
expect '2g the exemption sentence exempts' 0
fx; put 'S=$(gh pr view 7 --json state) # gh-guard-allow:'
expect '2h a blank reason exempts nothing' 1
fx; put 'gh pr merge 7 -R o/r --squash'
expect '2i a write verb on gh pr is still not a read' 0
fx; put 'gh pr view 7'; printf '1 bin/x.sh\n' > "$T/fx/allow.tsv"
expect '2j a granted line passes' 0
fx; put 'gh pr view 7
gh issue view 8'; printf '1 bin/x.sh\n' > "$T/fx/allow.tsv"
expect '2k one over the grant fails' 1 'OVER bin/x.sh'
fx; put 'echo hi'; printf '3 bin/x.sh\n' > "$T/fx/allow.tsv"
expect '2l below the grant passes and says so' 0 'below grant'
fx; put 'J=$(gh api graphql -f query="$Q")'
expect '2n a bare gh api graphql is caught' 1 'bin/x.sh:2'
fx; put 'gh api -X POST graphql -F query=@q.graphql'
expect '2o gh api graphql with flags in front is caught' 1 'bin/x.sh:2'
fx; put 'gh_rest POST graphql -f "query=$Q" > "$f"'
expect '2p the ledgered gh_rest POST graphql is not a bare call' 0
fx; put 'gh api repos/o/r/contents/graphql.md'
expect '2q a REST path that merely contains the word is not GraphQL' 0
rm -rf "$T/fx"; mkdir -p "$T/fx"
expect '2m a tree with nothing to scan is not a pass' 2

# --- 3. delta mode, hermetic repos: B has bin/x.sh with one read, granted 1.
dmk() {
  local R="$1"
  scratch_rm "$R" || return 1
  mkdir -p "$R/bin" "$R/tests"
  printf '#!/bin/bash\ngh pr view 7\n' > "$R/bin/x.sh"
  printf '#!/bin/bash\ntrue\n' > "$R/bin/y.sh"
  printf '1 bin/x.sh\n' > "$R/tests/gh-graphql-reads-allowlist.tsv"
  rd_fixture_repo "$R"
}
d_main_read() { printf 'gh issue list -R o/r\n' >> "$1/bin/y.sh"; }
d_drift()     { rd_main_commit "$1" 'main: y.sh gains a read' d_main_read; }
d_pr_docs()   { echo more >> "$1/README"; rd_git "$1" commit -qam 'pr: docs'; }
d_pr_read()   { printf 'S=$(timeout 20 gh pr list -R o/r)\n' >> "$1/bin/x.sh"; rd_git "$1" commit -qam 'pr: x.sh gains a read'; }
d_pr_allow()  { printf 'S=$(gh pr view 8 --json state) # gh-guard-allow: needs isInMergeQueue\n' >> "$1/bin/x.sh"; rd_git "$1" commit -qam 'pr: exempted read'; }
d_pr_new()    { printf '#!/bin/bash\ngh api graphql -f query=q\n' > "$1/bin/n.sh"; rd_git "$1" add -A; rd_git "$1" commit -qm 'pr: new file'; }
d_merge()     { rd_git "$1" merge -q --no-edit refs/remotes/origin/main; }
d_nomain()    { rd_git "$1" update-ref -d refs/remotes/origin/main; }
dcase() {  # <name> <want_rc> <RATCHET_BASE: main|B|none|bogus> <mode> <steps...>
  local name="$1" want="$2" rb="$3" mode="$4" R="$T/d-$1" b step out rc
  shift 4
  dmk "$R" || { bad "3 ($name): repo setup failed"; return; }
  b=$(rd_git "$R" rev-parse HEAD)
  for step in "$@"; do "$step" "$R" >/dev/null || { bad "3 ($name): step $step failed"; return; }; done
  case "$rb" in
    main)  rb=$(rd_git "$R" rev-parse refs/remotes/origin/main) ;;
    B)     rb="$b" ;;
    none)  rb="" ;;
    bogus) rb=0123456789abcdef0123456789abcdef01234567 ;;
  esac
  out=$(MODE="$mode" RATCHET_BASE="$rb" TI_BASE= real_check "$R" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then ok; else bad "3 ($name) rc=$rc want $want:"$'\n'"$out"; fi
}
dcase main-drift-pr-base      0 main  delta d_drift d_pr_docs d_merge
dcase main-drift-queue-draft  0 main  delta d_pr_docs d_drift d_merge
dcase main-drift-stale-base   0 B     delta d_drift d_pr_docs d_merge
dcase main-drift-local        0 none  delta d_drift d_pr_docs d_merge
dcase pr-adds-read            1 main  delta d_pr_read
dcase pr-adds-after-drift     1 main  delta d_drift d_pr_read d_merge
dcase pr-adds-new-file        1 main  delta d_pr_new
dcase pr-exempted-read        0 main  delta d_pr_allow
dcase bogus-base              1 bogus delta d_pr_docs
dcase no-base-at-all          1 none  delta d_pr_docs d_nomain
dcase strict-sees-drift       1 main  strict d_drift d_pr_docs d_merge
dcase strict-clean            0 main  strict d_pr_docs

echo "gh-graphql-reads-lint ($MODE): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
