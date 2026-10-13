#!/bin/bash
# tests/decompose-extractor-failure.bh-1343-test.sh — when the shared-file
# extractor runs and FAILS on one body, the split comment on the parent says so.
#
# WHY (BH-1343, from the round-2 review of #730). bin/lib/fc-issues.sh already
# refuses to read a failed extraction as "nothing shared" — the `|| return 2`
# arm — and it logs a WARN. But the WARN lands in the build's pipeline.log, and
# the person the shared-file list is FOR reads a GitHub comment. So a failed
# contract-body extraction rendered a split comment with no shared-file list at
# all, and a failed sibling extraction rendered one that was quietly short by
# that sibling's paths. Both read as "nothing is shared here", which is the one
# thing the return-2 arm exists to refuse saying.
#
# WHAT IS UNDER TEST: the bytes of $BUILD/decompose-comment.md, which is the
# file both the DRY and the real arm write and the real arm posts verbatim
# (`gh issue comment --body-file`). Driven through the production entry point,
# bin/run-decompose.sh, never fc_file_issues alone.
#
# No network, no model call, no secrets. DECOMPOSE_DRY_RUN=1 prints the gh
# commands instead of running them and reuses a handed-in children.json instead
# of buying a Fable call. Run from anywhere:
#   tests/decompose-extractor-failure.bh-1343-test.sh    (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

DEC="$DIR/bin/run-decompose.sh"
[ -x "$DEC" ] && ok || bad "bin/run-decompose.sh is missing or not executable"

# ---------------------------------------------------------------------------
# scratch harness — the same shape tests/decompose-contract-first-test.sh uses
# ---------------------------------------------------------------------------
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/env" "$T/h/prompts"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" scoutish || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
# The REAL extractor is what the double falls through to, so every body that is
# not the one under failure gets the production path's own answer.
cp "$DIR/bin/planned-files.sh" "$T/h/bin/planned-files-real.sh"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish      example-org/scoutish   https://scoutish.example  -           9 box-1 10.0.0.9
CONF
export FLEET_CONF="$T/h/fleet.conf"
printf '#!/bin/bash\necho "AGENT CALL: $*" >> "$AGENT_LOG"\nexit 0\n' > "$T/h/bin/agent-call.sh"
chmod +x "$T/h/bin/agent-call.sh"

# The double dies the way bin/planned-files.sh would: that script writes
# planned-files.txt progressively (`>`, then `>>`, then a rewrite), so a death
# part-way through leaves a PARTIAL list behind. PF_FAIL is a glob over the
# body directory's basename, so one double covers "the contract", "one sibling"
# and "everything".
cat > "$T/h/bin/planned-files.sh" <<'WRAP'
#!/bin/bash
if [ -n "${PF_FAIL:-}" ]; then
  case "$(basename "$1")" in
    $PF_FAIL)
      [ -n "${PF_PARTIAL:-}" ] && printf '%s\n' "$PF_PARTIAL" > "$1/planned-files.txt"
      [ -n "${PF_STDERR:-}" ] && echo "$PF_STDERR" >&2
      exit "${PF_RC:-1}" ;;
  esac
fi
exec "$(dirname "$0")/planned-files-real.sh" "$@"
WRAP
chmod +x "$T/h/bin/planned-files.sh"
export PF_FAIL="" PF_PARTIAL="" PF_STDERR="" PF_RC=1

# Prints the script's output and EXITS WITH ITS RC. Everything it writes lands
# in $T/b, which survives the subshell.
drive() { # drive <spec-json>
  rm -rf "$T/b"; mkdir -p "$T/b"
  printf '%s\n' "$1" > "$T/b/children.json"
  printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300; files=18>12\nSIZE_VERDICT: over\n' > "$T/b/size-gate.txt"
  : > "$T/agent.log"
  env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" \
      DECOMPOSE_DRY_RUN=1 "$DEC" scoutish 552 TK-552 "$T/b" 300 12 2>&1
}

# The same shared-path spec the BH-579.4 section of the contract-first suite
# uses: the contract owns src/x.ts and src/loader.ts, sibling .2 names src/x.ts,
# sibling .3 names both, sibling .4 is a near miss.
SHARE='[
 {"title":"config types","contract":"src/x.ts: Config, loadConfig()","after":[],"body":"Extract the loader.\n\nFiles: src/x.ts, src/loader.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"untouched","after":[],"body":"Own file only.\n\nFiles: src/jobs/a.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"shares x","after":[],"body":"Reads the loader in place.\n\nFiles: src/x.ts, src/jobs/b.ts. Also touches src/x.ts once more.\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"shares a body-only path","after":[],"body":"Files: src/loader.ts, src/x.ts, src/jobs/c.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"near miss","after":[],"body":"Files: src/x.tsx\n\n## Observable outcome\nThe slice acceptance test passes end to end."}
]'
# Nothing shared at all, and nothing fails: the state the note must NOT render in.
TWO='[
 {"title":"types","contract":"src/lib/t.ts: T","after":[],"body":"x\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"A","after":[],"body":"x\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"B","after":["2: a()"],"body":"x\n\n## Observable outcome\nThe slice acceptance test passes end to end."}
]'

CM="$T/b/decompose-comment.md"
PL="$T/b/pipeline.log"

# ===========================================================================
# A. the CONTRACT body's extraction fails — the comment has no list at all, so
#    it has to say why
# ===========================================================================
PF_FAIL="contract"; PF_PARTIAL="src/x.ts"; PF_STDERR="boom-contract"
OUT=$(drive "$SHARE"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "a failed contract-body extraction must not fail the split (rc=$RC): $OUT"
[ "$(grep -c '^DRYRUN gh issue create ' <<<"$OUT")" -eq 5 ] \
  && ok || bad "all five children still file (got: $OUT)"
[ -s "$T/agent.log" ] && bad "a dry run with a spec in hand must not buy a Fable call" || ok

[ "$(grep -c '^shared-file extraction failed: contract body (rc=1: boom-contract)$' "$CM")" -eq 1 ] \
  && ok || bad "the split comment names the failed contract extraction once, with its reason: $(cat "$CM" 2>/dev/null)"
[ "$(grep -c 'could not check every part for shared files' "$CM")" -eq 1 ] \
  && ok || bad "the failure line sits under one sentence that says what it means: $(cat "$CM" 2>/dev/null)"
# The sentence has to be TRUE in this state (D13): with the contract's own
# extraction dead there is no shared-file list at all, which is the "or missing"
# half of the copy.
[ "$(grep -c '^CONTESTED:' "$CM")" -eq 0 ] \
  && ok || bad "a failed contract extraction yields no contested list: $(cat "$CM" 2>/dev/null)"
[ "$(grep -c "the contract's to move" "$CM")" -eq 0 ] \
  && ok || bad "the contested sentence must not render over an empty list: $(cat "$CM" 2>/dev/null)"
[ -z "$(grep -l '^CONTESTED:' "$T/b"/children/*.md 2>/dev/null)" ] \
  && ok || bad "no child gets a contested line when the contract's own extraction failed"
# pipeline.log keeps the operator's half: the reason AND what the extractor had
# written when it died.
grep -qE "WARN:.*failed on the contract body \(rc=1: boom-contract\).*partial list.*src/x\.ts" "$PL" 2>/dev/null \
  && ok || bad "the contract WARN carries the reason and the partial list: $(cat "$PL" 2>/dev/null)"

# ===========================================================================
# B. ONE SIBLING's extraction fails — the list renders, short by that sibling,
#    and the comment says which one is missing
# ===========================================================================
PF_FAIL="child-3"; PF_PARTIAL="src/x.ts"; PF_STDERR="boom: test double died mid-run"
OUT=$(drive "$SHARE"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "a failed sibling extraction must not fail the split (rc=$RC): $OUT"
[ "$(grep -c '^DRYRUN gh issue create ' <<<"$OUT")" -eq 5 ] \
  && ok || bad "all five children still file (got: $OUT)"

# child-4 shares both paths and its extraction worked, so the list is still
# there — this is the "shorter than it should be" state, not the missing one.
[ "$(grep -c '^CONTESTED: src/x.ts -> #553$' "$CM")" -eq 1 ] \
  && ok || bad "the surviving siblings' contested list still renders: $(cat "$CM" 2>/dev/null)"
[ "$(grep -c '^CONTESTED: src/loader.ts -> #553$' "$CM")" -eq 1 ] \
  && ok || bad "the surviving siblings' second contested path still renders: $(cat "$CM" 2>/dev/null)"
[ "$(grep -c '^shared-file extraction failed: TK-552.2 body (rc=1: boom: test double died mid-run)$' "$CM")" -eq 1 ] \
  && ok || bad "the failed sibling is named by the key the comment's own link list uses: $(cat "$CM" 2>/dev/null)"
# The key must be one the reader can actually find: it is the same TK-552.<n>
# label the split comment lists the children under.
grep -q '^TK-552\.2 (#555): shares x$' "$CM" \
  && ok || bad "the named key matches the child link line in the same comment: $(cat "$CM" 2>/dev/null)"
[ "$(grep -c 'could not check every part for shared files' "$CM")" -eq 1 ] \
  && ok || bad "one sentence, once, over the failure lines: $(cat "$CM" 2>/dev/null)"
[ "$(grep -c '—' "$CM")" -le 1 ] \
  && ok || bad "the comment stays in the project's voice, near-zero em dashes: $(cat "$CM" 2>/dev/null)"
# The failed sibling's own body is untouched: no contested line guessed from a
# partial list, blocker intact.
K3="$T/b/children/child-3.md"
[ "$(grep -c '^CONTESTED:' "$K3")" -eq 0 ] \
  && ok || bad "the failed sibling gets no contested line from its partial list: $(cat "$K3" 2>/dev/null)"
grep -q '^Blocked-by: #553 (hard)$' "$K3" \
  && ok || bad "the failed sibling keeps its contract blocker: $(cat "$K3" 2>/dev/null)"

# TWO siblings failing gives one line each, in filing order.
PF_FAIL="child-[34]"
OUT=$(drive "$SHARE"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "two failed siblings must not fail the split (rc=$RC): $OUT"
[ "$(grep -c '^shared-file extraction failed: ' "$CM")" -eq 2 ] \
  && ok || bad "one failure line per failed body: $(cat "$CM" 2>/dev/null)"
[ "$(grep '^shared-file extraction failed: ' "$CM" | head -1)" = 'shared-file extraction failed: TK-552.2 body (rc=1: boom: test double died mid-run)' ] \
  && ok || bad "the failure lines are in filing order: $(cat "$CM" 2>/dev/null)"

# An extractor that dies with NOTHING on stderr still gets a reason, and it is
# the rc alone — no trailing colon inviting the reader to look for more.
PF_FAIL="child-3"; PF_STDERR=""; PF_RC=3
OUT=$(drive "$SHARE"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "a silent extractor failure must not fail the split (rc=$RC): $OUT"
[ "$(grep -c '^shared-file extraction failed: TK-552.2 body (rc=3)$' "$CM")" -eq 1 ] \
  && ok || bad "a failure with empty stderr reads as the rc alone: $(cat "$CM" 2>/dev/null)"
# ...and one that dies before writing anything logs the partial list as `none`,
# rather than an empty tail that reads as a truncated log line.
PF_PARTIAL=""
OUT=$(drive "$SHARE"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "an extractor that wrote nothing must not fail the split (rc=$RC): $OUT"
grep -qE "WARN:.*failed on child 3's body \(rc=3\).*partial list left in .*: none$" "$PL" 2>/dev/null \
  && ok || bad "no partial file on disk logs as 'none': $(cat "$PL" 2>/dev/null)"
[ ! -e "$T/b/decompose-paths/child-3/planned-files.txt" ] \
  && ok || bad "the driver does not invent a planned-files.txt the extractor never wrote"
PF_RC=1; PF_PARTIAL="src/x.ts"

# ===========================================================================
# C. NEGATIVE — nothing failed, so none of this copy renders (D13)
# ===========================================================================
PF_FAIL=""; PF_STDERR=""
OUT=$(drive "$SHARE"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "the clean shared-path split still exits 0 (rc=$RC): $OUT"
[ "$(grep -c 'shared-file extraction failed' "$CM")" -eq 0 ] \
  && ok || bad "no failure line when the extractor never failed: $(cat "$CM" 2>/dev/null)"
[ "$(grep -c 'could not check every part for shared files' "$CM")" -eq 0 ] \
  && ok || bad "no failure sentence when the extractor never failed: $(cat "$CM" 2>/dev/null)"
# ...and the contested list it would have undermined is intact.
[ "$(grep -c '^CONTESTED: src/x.ts -> #553$' "$CM")" -eq 1 ] \
  && ok || bad "the clean split still lists its contested paths: $(cat "$CM" 2>/dev/null)"

OUT=$(drive "$TWO"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "a split with nothing shared and nothing failed exits 0 (rc=$RC): $OUT"
[ "$(grep -c 'shared-file extraction failed' "$CM")" -eq 0 ] \
  && ok || bad "nothing shared and nothing failed says neither thing: $(cat "$CM" 2>/dev/null)"
[ "$(grep -c 'could not check every part for shared files' "$CM")" -eq 0 ] \
  && ok || bad "nothing shared and nothing failed renders no sentence: $(cat "$CM" 2>/dev/null)"
[ "$(grep -c 'CONTESTED' "$CM")" -eq 0 ] \
  && ok || bad "nothing shared says nothing about contested paths: $(cat "$CM" 2>/dev/null)"

# ===========================================================================
# D. a ROLLOUT wave has no contract, so the whole paths block is skipped and
#    none of this can reach its comment — even with the extractor failing on
#    every body
# ===========================================================================
# Driven through bin/run-rollout.sh, the rollout lane's own production entry
# point, against the REAL bin/lib/fc-issues.sh: the rollout arm resolves its
# lane module from $HARNESS/bin/lib, so the copy is what gets exercised.
cp "$DIR/bin/lib/fc-issues.sh" "$T/h/bin/lib/"
cat > "$T/h/bin/gh" <<'SH'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then cat "$GH_BODY_552"; exit 0; fi
echo "gh stub: $*" >&2; exit 1
SH
chmod +x "$T/h/bin/gh"
ROLLOUT="$DIR/bin/run-rollout.sh"
FIX="$DIR/tests/fixtures/run-rollout"
if [ -x "$ROLLOUT" ] && [ -s "$FIX/canonical.md" ]; then
  rm -rf "$T/b"; mkdir -p "$T/b"
  OUT=$(env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
        AGENT_LOG="$T/agent.log" GH_BODY_552="$FIX/canonical.md" \
        PF_FAIL='*' PF_PARTIAL="src/x.ts" PF_STDERR="boom-rollout" \
        DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" 2>&1); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "the rollout lane still exits 0 with a dead extractor (rc=$RC): $OUT"
  [ -s "$CM" ] && ok || bad "the rollout lane still writes its split comment: $OUT"
  [ "$(grep -c 'shared-file extraction failed' "$CM")" -eq 0 ] \
    && ok || bad "a rollout wave has no contract, so it says nothing about shared files: $(cat "$CM" 2>/dev/null)"
  [ "$(grep -c 'could not check every part for shared files' "$CM")" -eq 0 ] \
    && ok || bad "no failure sentence on a rollout comment: $(cat "$CM" 2>/dev/null)"
  # The block is SKIPPED, not merely quiet: it never made a body directory.
  [ ! -d "$T/b/decompose-paths" ] \
    && ok || bad "the rollout arm must not run the extractor at all"
else
  echo "note: rollout fixture absent — section D did not run"
fi

echo "decompose-extractor-failure: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
