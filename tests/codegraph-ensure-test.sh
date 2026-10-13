#!/bin/bash
# tests/codegraph-ensure-test.sh — the graph is CAPABILITY-tested before a build
# is told it has one, and the line it gets carries the command that works.
#
# THE DEFECT, verbatim: every repo commits a `.codegraph/.gitignore`, so
# `git worktree add` materialises an EMPTY `.codegraph/` in the worktree. The
# nearest-ancestor index resolution then stops there, a bare `codegraph explore`
# answers "isn't available here", and `ls .codegraph/` prints nothing at all
# (the only file is dotted). A live session read that listing as "indexed" and
# did ~100 shell reads against a graph it never touched. Path present,
# capability absent — the fly-probe shape one layer down, which is why the first
# assertion here is that exact directory rendering NOT AVAILABLE.
#
# These tests use the REAL codegraph CLI against REAL tiny repos. Nothing about
# an index is mocked: a mocked index would prove the mock.
# Run from anywhere: tests/codegraph-ensure-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
ENSURE="$DIR/bin/codegraph-ensure.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# SKIP is for a dev laptop that genuinely has no CLI. It is NOT allowed where
# the fleet's ground truth runs: a capability suite that skips in CI is a green
# that proves nothing, which is the same shape as the path-probe this file was
# written to catch. CI sets CODEGRAPH_REQUIRED=1, and then a missing CLI is a
# hard failure — including the case where the pinned install silently left
# nothing on PATH, which would otherwise read as "tests passed".
skip_all() {
  if [ -n "${CODEGRAPH_REQUIRED:-}" ]; then
    echo "FAIL: CODEGRAPH_REQUIRED is set but no codegraph CLI is on PATH — the capability suite may not skip here"
    echo "pass=0 fail=1"
    exit 1
  fi
  echo "SKIP: codegraph CLI not installed — capability tests need the real thing (set CODEGRAPH_REQUIRED=1 to make this a failure)"
  echo "pass=$PASS fail=$FAIL"
  exit 0
}
command -v codegraph >/dev/null 2>&1 || skip_all

ensure() { CODEGRAPH_REPO="$1" "$ENSURE" testproj "${2:-$T/fakewt}" 2>/dev/null; }
mkrepo() {  # mkrepo <dir> — a tiny REAL repo with real indexable symbols
  mkdir -p "$1/src"
  printf 'export function alphaThing(x){ return betaHelper(x) }\nexport function betaHelper(x){ return x + 1 }\n' > "$1/src/a.ts"
  git -C "$1" init -q .
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
}

# ---------- 1. THE LIVE DEFECT, reproduced end to end -----------------------
# A repo that commits .codegraph/.gitignore, a worktree cut from it, and the
# bare command the old prompt told builds to run. This is the failure verbatim.
mkrepo "$T/src"
mkdir -p "$T/src/.codegraph"
printf '# CodeGraph data files\n*\n!.gitignore\n' > "$T/src/.codegraph/.gitignore"
git -C "$T/src" add -f .codegraph/.gitignore >/dev/null 2>&1
git -C "$T/src" -c user.email=t@t -c user.name=t commit -qm "commit codegraph gitignore" >/dev/null 2>&1
codegraph init "$T/src" >/dev/null 2>&1          # the MAIN clone is properly indexed
git -C "$T/src" worktree add -q "$T/wt" -b feat >/dev/null 2>&1
[ -d "$T/wt/.codegraph" ] \
  && ok || bad "fixture invalid: the worktree should inherit an empty .codegraph/ from the tracked .gitignore"
[ ! -f "$T/wt/.codegraph/codegraph.db" ] \
  && ok || bad "fixture invalid: the worktree's .codegraph/ should hold no index"
# the bare form — what builds were being told to run — finds nothing at all
BARE=$(cd "$T/wt" && codegraph explore "alphaThing" 2>&1)
! grep -q 'alphaThing' <<<"$BARE" \
  && ok || bad "the bare in-worktree command should NOT find the symbol (that is the whole defect)"
# ...while the -p form this change advertises finds it from the same cwd
PFORM=$(cd "$T/wt" && codegraph explore -p "$T/src" "alphaThing" 2>&1)
grep -q 'alphaThing' <<<"$PFORM" \
  && ok || bad "the -p form must work from inside the worktree (got: $(head -2 <<<"$PFORM"))"

# ---------- 1b. path present, capability absent -> NOT AVAILABLE ------------
# A .codegraph/ directory is not an index. Nothing indexable here, so no amount
# of directory-probing may produce an AVAILABLE line.
mkdir -p "$T/hollow/.codegraph"
printf '*\n!.gitignore\n' > "$T/hollow/.codegraph/.gitignore"
printf 'not source\n' > "$T/hollow/readme.txt"
OUT=$(ensure "$T/hollow")
grep -q '^CODEGRAPH NOT AVAILABLE' <<<"$OUT" \
  && ok || bad "a .codegraph/ dir with no queryable index must render NOT AVAILABLE (got: $OUT)"
grep -qE 'NOT AVAILABLE \(.+\)' <<<"$OUT" \
  && ok || bad "NOT AVAILABLE must carry a reason"
[ -d "$T/hollow/.codegraph" ] && ok || bad "fixture invalid: the .codegraph dir should exist"

# ---------- 1c. status healthy, QUERY broken -> NOT AVAILABLE ---------------
# This is the case the smoke query exists for, and nothing else covers it: the
# index reports itself initialized with thousands of symbols, and querying it
# fails anyway (corrupt db, unreadable file, a CLI that cannot open it). Every
# check short of running a real query says AVAILABLE here. A wrapper that passes
# `status` through to the real CLI and breaks only `query` isolates that arm
# exactly — without it, deleting the smoke query entirely leaves this file green,
# which is how it stood until this fixture was added.
mkrepo "$T/broken"
codegraph init "$T/broken" >/dev/null 2>&1
cat > "$T/cg-badquery" <<'STUB'
#!/bin/sh
case "$1" in
  query) echo "error: unable to open database file" >&2; exit 1 ;;
  *) exec codegraph "$@" ;;
esac
STUB
chmod +x "$T/cg-badquery"
OUT=$(CODEGRAPH_BIN="$T/cg-badquery" CODEGRAPH_REPO="$T/broken" "$ENSURE" p "$T/fakewt" 2>/dev/null)
grep -q '^CODEGRAPH NOT AVAILABLE' <<<"$OUT" \
  && ok || bad "a healthy-looking index whose QUERY fails must render NOT AVAILABLE (got: $OUT)"
grep -q 'smoke query' <<<"$OUT" \
  && ok || bad "the reason must name the failed smoke query, not a generic excuse"
# and prove the fixture is only breaking the query arm — status still works
grep -q '"initialized":true' <<<"$("$T/cg-badquery" status -j "$T/broken" 2>/dev/null)" \
  && ok || bad "fixture invalid: status should still report a healthy index"

# ---------- 2. no CLI / no clone -> NOT AVAILABLE, with the right reason -----
grep -q 'CLI not installed' <<<"$(CODEGRAPH_BIN=definitely-no-such-binary CODEGRAPH_REPO="$T/empty" "$ENSURE" p "$T/fakewt" 2>/dev/null)" \
  && ok || bad "a missing CLI must be named as the reason"
grep -q 'no main clone' <<<"$(ensure "$T/does-not-exist")" \
  && ok || bad "a missing main clone must be named as the reason"

# ---------- 3. a real index -> AVAILABLE, with the command that works --------
mkrepo "$T/live"
OUT=$(ensure "$T/live" "$T/wt-live")
grep -q '^CODEGRAPH AVAILABLE' <<<"$OUT" \
  && ok || bad "a repo with real symbols must render AVAILABLE (got: $OUT)"
# the index was CREATED by ensure — the create path is the point of "always current"
[ -f "$T/live/.codegraph/codegraph.db" ] \
  && ok || bad "ensure must create the index when it is missing"
# the line must carry the -p form. A bare 'codegraph explore' is exactly what
# fails in a worktree, so a line that advertised it would recreate the defect.
grep -q -- "explore -p $T/live" <<<"$OUT" \
  && ok || bad "the AVAILABLE line must give the explicit -p query form (got: $OUT)"
grep -q 'symbols' <<<"$OUT" && ok || bad "the line must report the symbol count"
# freshness has to be legible, or 'always current' is unfalsifiable
grep -qE 'index @ [^ ]+ [0-9a-f]{7,}' <<<"$OUT" \
  && ok || bad "the AVAILABLE line must name the branch and commit the index is at (got: $OUT)"
grep -q 'indexed 20' <<<"$OUT" && ok || bad "the line must carry the index timestamp"
# the drift caveat: the index is main's tree, the build is on a branch
grep -qi "index is MAIN's tree" <<<"$OUT" \
  && ok || bad "the line must warn that the index lags this branch's own edits"
# and it must warn off the bare form that silently fails in the worktree
grep -q 'Do NOT run a bare codegraph' <<<"$OUT" \
  && ok || bad "the line must warn against the bare command that fails in a worktree"

# ---------- 4. the query form it advertises actually works -------------------
# Assert the promise, not just its wording: run the exact command from the line.
CMD=$(sed -E 's/.*query via: (.*) "<symbols or question>".*/\1/' <<<"$(head -1 <<<"$OUT")")
[ -n "$CMD" ] && grep -q ' -p ' <<<"$CMD" && ok || bad "could not extract the advertised command"
RES=$($CMD "alphaThing" 2>&1)
grep -q 'alphaThing' <<<"$RES" \
  && ok || bad "the advertised command must actually return the symbol (got: $(head -2 <<<"$RES"))"

# ---------- 5. staleness: an edit is synced, not silently served stale -------
printf 'export function gammaNew(x){ return alphaThing(x) }\n' >> "$T/live/src/a.ts"
PEND=$(codegraph status -j "$T/live" 2>/dev/null | python3 -c 'import json,sys; p=json.load(sys.stdin)["pendingChanges"]; print(sum(p.values()))')
[ "${PEND:-0}" -gt 0 ] && ok || bad "fixture invalid: an edited indexed file should show pendingChanges (got $PEND)"
ensure "$T/live" >/dev/null
PEND2=$(codegraph status -j "$T/live" 2>/dev/null | python3 -c 'import json,sys; p=json.load(sys.stdin)["pendingChanges"]; print(sum(p.values()))')
[ "${PEND2:-1}" = 0 ] && ok || bad "ensure must sync a stale index (pending still $PEND2)"
# the new symbol is now findable — the sync did work, it did not just clear a flag
grep -q 'gammaNew' <<<"$(codegraph query -p "$T/live" -l 5 gammaNew 2>&1)" \
  && ok || bad "after ensure, a newly added symbol must be queryable"

# ---------- 6. it is cheap enough to sit on the per-build path --------------
# The whole design rests on this: if refresh were slow it would have to be an
# out-of-band rollout, and boxes would silently run un-indexed between rollouts.
START=$(date +%s)
ensure "$T/live" >/dev/null
[ $(( $(date +%s) - START )) -le 5 ] \
  && ok || bad "a no-op ensure must be fast enough to run at every build start"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
