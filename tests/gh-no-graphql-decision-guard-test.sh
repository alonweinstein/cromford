#!/bin/bash
# tests/gh-no-graphql-decision-guard-test.sh — the marker-driven guard that
# keeps GraphQL out of the decision paths that were converted to REST.
#
# THE RULE. A `*.sh` under bin/ that carries the exact line
#
#     # gh-rest: no-graphql
#
# makes a promise: it decides nothing from `gh pr`, `gh issue` or `gh run`.
# Those three speak GraphQL, and on 2026-09-18 (#768) a rate-limited `gh pr
# view` answered an EMPTY STRING that the decision path read as "no such PR" —
# five real PRs rewritten RESULT_UNVERIFIED, TK-2302 launched three times.
# `gh api` is REST and is never flagged. A line that genuinely needs one of the
# three carries `# gh-guard-allow: <one-line reason>`; a blank reason is not an
# exemption, it is a way to silence the guard without saying anything.
#
# THE INVOCATION SHAPES THIS REPO ACTUALLY WRITES. Nobody writes the call bare.
# `bin/triage-gate.sh` reads PR state as `$(timeout 20 gh pr view … --json
# state)`, `bin/lib/revdep-lib.sh` as `$(timeout 30 gh issue view …)`, and a
# lane reaches for `if gh …`, `! gh …`, a backtick, or `GH_TOKEN=x gh …`. Every
# one of those is the #768 read with a word in front of it, so the scanner peels
# leading keywords, `NAME=value` assignments and `timeout …` off a chunk before
# it matches, and splits on a backtick as well as on `$(`. A guard a `timeout`
# prefix walks past would leave every real lane unpoliced while staying green.
#
# WHY THE FLOOR IS `>= 1` AND NOT `== 1`. In this child only bin/lib/gh-rest.sh
# carries the marker. #781..#784 each add the marker to the lane they convert,
# and none of them should have to edit this file to stay green.
#
# A SCAN THAT SCANNED NOTHING IS NOT A PASS (D9): a tree where no file carries
# the marker exits 2, never 0.
#
# The scanner is written out as a standalone program and the SAME program scans
# the repo and the fixtures below — a guard nobody has watched fail is a guard
# nobody knows is wired up. It prints `path:line`, never the line's contents: a
# flagged line can carry a token in its arguments.
#
# Run from anywhere: bash tests/gh-no-graphql-decision-guard-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

mkdir -p "$T/mut"

cat > "$T/scan.py" <<'PY'
import os, re, sys

MARKER = "# gh-rest: no-graphql"
# The three GraphQL-backed verb groups. `gh api` is REST and is never a hit.
CALL = re.compile(r"^gh\s+(?:pr|issue|run)\s")
# An exemption is the SENTENCE, not the marker: a blank reason exempts nothing.
ALLOW = re.compile(r"#\s*gh-guard-allow:\s*\S")
# Prefixes that leave the next word at command position. A backtick is one of
# them: `X=`gh pr view 7`` is the same read as X=$(gh pr view 7).
SPLIT = re.compile(r"\$\(|\|\||&&|[|;{(`]")
# WORDS THAT SIT IN FRONT OF THE COMMAND AND CHANGE NOTHING ABOUT IT. The lanes
# this guard polices do not write `gh pr view` bare: bin/triage-gate.sh reads PR
# state as `$(timeout 20 gh pr view … --json state)`, bin/lib/revdep-lib.sh as
# `$(timeout 30 gh issue view …)`, and a converted lane will reach for
# `if gh …`, `! gh …` or `GH_TOKEN=x gh …`. A guard a `timeout` defeats polices
# nothing, so every such word is peeled off before the match.
KEYWORD = re.compile(
    r"^(?:if|then|else|elif|do|done|while|until|!|time|exec|command|env|nohup|sudo)$")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# `timeout` eats its own flags and duration before the real command starts.
TIMEOUT_ARG = re.compile(r"^-|^[0-9]+(?:\.[0-9]+)?[smhd]?$")


def balanced(word):
    """A word with an odd quote count opens a string: stop peeling there, the
    rest of the line is data, not a command (MSG="gh pr view is what … ")."""
    return word.count('"') % 2 == 0 and word.count("'") % 2 == 0


def peel(chunk):
    """Drop leading keywords, env assignments and `timeout …` so what is left
    starts at the command itself."""
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
    """Drop a `#` comment, honouring quotes so a "#" inside a string survives."""
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


def marked(lines):
    return any(l.rstrip() == MARKER for l in lines)


root = sys.argv[1]
nmarked, hits = 0, []
for dirpath, dirs, names in os.walk(root):
    dirs.sort()
    for name in sorted(names):
        if not name.endswith(".sh"):
            continue
        path = os.path.join(dirpath, name)
        try:
            with open(path, errors="ignore") as fh:
                lines = fh.read().split("\n")
        except OSError:
            continue
        if not marked(lines):
            continue
        nmarked += 1
        for n, raw in enumerate(lines, 1):
            if ALLOW.search(raw):
                continue
            code = strip_comment(raw).strip()
            if not code:
                continue
            for chunk in SPLIT.split(code):
                if CALL.match(peel(chunk)):
                    hits.append("%s:%d" % (os.path.relpath(path, root), n))
                    break

for h in hits:
    print(h)
print("marked files: %d, offending lines: %d" % (nmarked, len(hits)))
if nmarked == 0:
    sys.exit(2)
sys.exit(1 if hits else 0)
PY

scan() { python3 "$T/scan.py" "$1" > "$T/scan.out" 2>&1; }

tree() { # tree <name> — a fixture root holding one marked file, $F/<name>/
  F="$T/fx/$1"
  rm -rf "$T/fx/$1"
  mkdir -p "$F"
  { echo '#!/bin/bash'; echo '# gh-rest: no-graphql'; } > "$F/marked.sh"
}

expect() { # expect <label> <tree> <want-rc> [text that must appear]
  local label=$1 root=$2 wrc=$3 want=${4:-}
  local rc
  scan "$root"; rc=$?
  if [ "$rc" != "$wrc" ]; then
    bad "$label: rc=$rc (want $wrc); output: $(cat "$T/scan.out")"
    return
  fi
  if [ -n "$want" ] && ! grep -q -- "$want" "$T/scan.out"; then
    bad "$label: '$want' missing from: $(cat "$T/scan.out")"
    return
  fi
  ok
}

# ══ 1. the fixtures ═════════════════════════════════════════════════════════
tree ok
echo 'gh api repos/x/y' >> "$F/marked.sh"
cat > "$F/unmarked.sh" <<'EOF2'
#!/bin/bash
gh pr view a/b/1
EOF2
expect 'marked + gh api, unmarked file ignored' "$F" 0 'marked files: 1, offending lines: 0'

tree pr
echo 'gh pr view a/b/1' >> "$F/marked.sh"
expect 'marked + gh pr view' "$F" 1 'marked.sh:3'
if grep -q 'a/b/1' "$T/scan.out"; then bad 'the scanner printed the offending line CONTENTS'; else ok; fi

tree run
echo 'gh run list -R x/y' >> "$F/marked.sh"
expect 'marked + gh run list' "$F" 1 'marked.sh:3'

tree issue
echo 'gh issue comment 1 -R x/y -b hi' >> "$F/marked.sh"
expect 'marked + gh issue comment' "$F" 1 'marked.sh:3'

tree sub
echo 'S=$(gh pr view x/y/1 --json state)' >> "$F/marked.sh"
expect 'marked + $(gh pr view ...)' "$F" 1 'marked.sh:3'

tree chained
echo '[ -n "$x" ] && gh pr view x/y/1' >> "$F/marked.sh"
expect 'marked + && gh pr view' "$F" 1 'marked.sh:3'

# The shapes the lanes really use: a word in front of the call hides nothing.
tree timeout
echo 'S=$(timeout 20 gh pr view 7 -R o/r --json state -q .state)' >> "$F/marked.sh"
expect 'marked + $(timeout N gh pr view ...)' "$F" 1 'marked.sh:3'

tree timeoutflags
echo 'timeout -k 5 30s gh issue view 7 -R o/r --json state' >> "$F/marked.sh"
expect 'marked + timeout with flags' "$F" 1 'marked.sh:3'

tree envassign
echo 'GH_TOKEN="$tok" gh pr view 7 -R o/r' >> "$F/marked.sh"
expect 'marked + NAME=value gh pr view' "$F" 1 'marked.sh:3'

tree envword
echo 'env GH_TOKEN=x gh pr list -R o/r --json number' >> "$F/marked.sh"
expect 'marked + env ... gh pr list' "$F" 1 'marked.sh:3'

tree ifkw
echo 'if gh pr view 7 -R o/r >/dev/null; then :; fi' >> "$F/marked.sh"
expect 'marked + if gh pr view' "$F" 1 'marked.sh:3'

tree bangkw
echo '! timeout 20 gh run list -R o/r' >> "$F/marked.sh"
expect 'marked + ! timeout gh run list' "$F" 1 'marked.sh:3'

tree whilekw
echo 'while gh run list -R o/r; do :; done' >> "$F/marked.sh"
expect 'marked + while gh run list' "$F" 1 'marked.sh:3'

tree backtick
echo 'X=`gh pr view 7 -R o/r`' >> "$F/marked.sh"
expect 'marked + backtick substitution' "$F" 1 'marked.sh:3'

tree prefixed_api
{ echo 'timeout 20 gh api repos/x/y'
  echo 'if gh api repos/x/y >/dev/null; then :; fi'
  echo 'GH_TOKEN="$tok" gh api repos/x/y'
  echo 'command -v gh >/dev/null'
  echo 'MSG="x gh pr view is only a sentence"'
} >> "$F/marked.sh"
expect 'a prefix does not turn gh api (or prose) into a hit' "$F" 0 'offending lines: 0'

tree allow
echo 'S=$(timeout 20 gh pr view x/y/1)   # gh-guard-allow: the merge-state field has no REST equivalent' >> "$F/marked.sh"
expect 'an allow line with a reason covers a prefixed call too' "$F" 0 'offending lines: 0'

tree allow2
echo 'gh pr view x/y/1   # gh-guard-allow: the merge-state field has no REST equivalent' >> "$F/marked.sh"
expect 'an allow line with a reason' "$F" 0 'offending lines: 0'

tree allowblank
echo 'gh pr view x/y/1   # gh-guard-allow:' >> "$F/marked.sh"
expect 'an allow line with a BLANK reason exempts nothing' "$F" 1 'marked.sh:3'

tree commented
{ echo '# gh pr view x/y/1'
  echo 'MSG="gh pr view is what the old lane ran"'
  echo 'gh auth token >/dev/null'
  echo 'gh_rest_pr_state o/r 7'
} >> "$F/marked.sh"
expect 'comments, strings, gh auth and gh_rest_* are not calls' "$F" 0 'marked files: 1, offending lines: 0'

tree nomarker
rm -f "$F/marked.sh"
cat > "$F/plain.sh" <<'EOF2'
#!/bin/bash
gh pr view a/b/1
EOF2
expect 'a tree with no marked file is rc 2, never green' "$F" 2 'marked files: 0'

# ══ 2. the repo itself ══════════════════════════════════════════════════════
scan "$DIR/bin"; RC=$?
if [ "$RC" = 0 ]; then ok; else bad "bin/ is not clean under the guard: $(cat "$T/scan.out")"; fi
NM=$(sed -n 's/^marked files: \([0-9]*\),.*/\1/p' "$T/scan.out")
# BH-782 raised the floor from 1 to 6: #781..#784 converted five launch-gate
# lanes onto the contract, and each carries the marker. The floor stays a floor
# (>=) because a later ticket converting a sixth lane must not have to edit this
# file to stay green — but a lane SILENTLY LOSING its marker would put the scan
# back under the count and is what this number catches.
if [ -n "$NM" ] && [ "$NM" -ge 6 ]; then ok
else bad "the repo scan found $NM marked files, expected at least 6 (got '$(cat "$T/scan.out")')"; fi
for _F in bin/lib/gh-rest.sh bin/lib/gh-pr-list.sh bin/preplan-candidates.sh \
          bin/triage-gate.sh bin/overlap-guard.sh bin/dep-verify.sh; do
  if grep -qx '# gh-rest: no-graphql' "$DIR/$_F" 2>/dev/null; then ok
  else bad "$_F does not carry the marker line"; fi
done

# ══ 3. mutation check (D1) ══════════════════════════════════════════════════
# The real library, plus one GraphQL call: the guard must go red on it. Both
# shapes are mutated — the bare one, and the `$(timeout N …)` one the lanes
# this guard will police actually write.
mutant() { # mutant <label> <line to append>
  rm -rf "$T/mut/bin"
  mkdir -p "$T/mut/bin/lib"
  if ! cp "$DIR/bin/lib/gh-rest.sh" "$T/mut/bin/lib/gh-rest.sh" 2>/dev/null; then
    bad "mutant ($1): bin/lib/gh-rest.sh is missing, nothing to mutate"
    return
  fi
  printf '%s\n' "$2" >> "$T/mut/bin/lib/gh-rest.sh"
  scan "$T/mut/bin"; local rc=$?
  if [ "$rc" = 1 ]; then ok; else bad "mutant ($1): a marked library with '$2' must be rc 1, got $rc"; fi
  if grep -q 'lib/gh-rest.sh:' "$T/scan.out"; then ok; else bad "mutant ($1): the hit must name the file: $(cat "$T/scan.out")"; fi
  if grep -q 'a/b/1' "$T/scan.out"; then bad "mutant ($1): the scanner printed the line contents"; else ok; fi
}
mutant 'bare call'         'gh pr view a/b/1'
mutant 'timeout-prefixed'  'S=$(timeout 20 gh pr view 7 -R a/b/1 --json state -q .state)'

echo "gh-no-graphql-decision-guard: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
