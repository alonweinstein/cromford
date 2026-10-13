#!/bin/bash
# tests/mc-rebase-consume-test.sh — rebase_consume's once-marker, and the TTL
# forget that has to be able to clear it (BH-523).
#
# THE INCIDENT THIS PINS (hub, 2026-09-16). rebase_consume recorded
# `rebasedone <key> <head>` in attempts.txt with mc_attempted, which APPENDS ON
# FIRST SIGHT — five lines before rebase_result applied the result. A worker
# killed in that window (or any second reader of the same job file) left the
# marker behind with no transition behind it: the row stayed REBASING /
# NEEDS_REBASE, no BLOCKED_AGENT line was ever written, bin/blocked-resolver.sh
# never saw the park, and the 30-minute TTL forget cleared `rebase` and
# `mergetree` but not `rebasedone` — so the respawned rebase's result was
# dropped exactly the same way, for ever. ~20 heads on the hub were in that
# shape and had to be applied by hand.
#
# WHAT IS DRIVEN, AND WHY IT IS NOT GREPPED. The three functions are extracted
# VERBATIM from the shipped bin/merge-conductor.sh (the same sed-by-header trick
# tests/conductor-detached-lanes-test.sh uses for rebase_result) and run against
# a scratch $HARNESS with a real detached-rebase job file and a real
# pr-state.tsv row. Every assertion is on an artifact — the row, attempts.txt,
# the job file, the log — never on the source text of the script.
#
# No gh, no git, no network: these three functions only read a job file and
# write local state.
#
# Run from anywhere: tests/mc-rebase-consume-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || {
  # tests/lib/scratch.sh ships in #609. Until it is on main this file owns its
  # own tree under the same $T name the lib hands out, so the scratch rule
  # ("only $T is ever deleted") holds either way.
  T=$(mktemp -d "${TMPDIR:-/tmp}/scratch.XXXXXX") || exit 1
  export T
  trap 'rm -rf "$T"' EXIT
}
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# ONE clock read, every fixture timestamp derived from it.
NOW=$(date +%s)

OLD=1111111111111111111111111111111111111111
NEW=2222222222222222222222222222222222222222
SLUG=example-org/demo-os
NUM=23
KEY="$SLUG#$NUM"
URL="https://github.com/$SLUG/pull/$NUM"
CONFLICT="src/lib/engine/analysis-config.ts"

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/locks" "$T/h/env"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/"
# TEST-CHANGE (BH-1585): the open list is REST now; the contract lib rides beside gh-pr-list.sh.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$T/h/bin/"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"
mc_init
ACTIONS=0; MERGES=0

# THE CODE UNDER TEST IS THE SHIPPED CODE.
eval "$(sed -n '/^rebase_result() {/,/^}/p; /^rebase_consume() {/,/^}/p' "$T/h/bin/lib/mc/rebase.sh"
          sed -n '/^stuck_rekick() {/,/^}/p' "$T/h/bin/lib/mc/classify.sh")"
type rebase_consume >/dev/null 2>&1 && ok || bad "rebase_consume did not extract from bin/lib/mc/rebase.sh — the rest of this file proves nothing"
type rebase_result  >/dev/null 2>&1 && ok || bad "rebase_result did not extract from bin/lib/mc/rebase.sh"
type stuck_rekick   >/dev/null 2>&1 && ok || bad "stuck_rekick did not extract from bin/lib/mc/classify.sh"

state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2; exit}' "$MC_ROWS" 2>/dev/null; }
head_of()   { awk -F'\t' -v k="$1" '$1==k {print $4; exit}' "$MC_ROWS" 2>/dev/null; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7; exit}' "$MC_ROWS" 2>/dev/null; }
nlines()    { local n; n=$(grep -cF "$1" "$MC_LOG" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
nattempt()  { local n; n=$(grep -cxF "$1" "$MC_ATTEMPTS" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }

# row <state> <head> [reason] — the pr-state.tsv row the tick would be holding.
row() { mc_row_put "$KEY" "$1" "$((NOW-600))" "$2" "$2" - "${3:-fixture}" "$URL"; }

# job_done <head> <rc> <out-text> — a FINISHED detached rebase job file.
job_done() {
  local jf of
  jf=$(mc_rb_file "$SLUG" "$NUM" "$1"); of="${jf%.json}.out"
  printf '%s' "$3" > "$of"
  mc_rb_write "$jf" done 0 "$((NOW-600))" "$((NOW-300))" "$2" "$1" - "$of"
}

# job_running <head> — a job that is still going, so nothing may be read off it.
job_running() {
  local jf of
  jf=$(mc_rb_file "$SLUG" "$NUM" "$1"); of="${jf%.json}.out"
  : > "$of"
  mc_rb_write "$jf" running "$$" "$((NOW-60))" 0 - "$1" - "$of"
}

reset() {
  : > "$MC_ROWS"; : > "$MC_ATTEMPTS"; : > "$MC_LOG"
  rm -f "$MC_RB_DIR"/*.json "$MC_RB_DIR"/*.out "$MC_HANDOFF_DIR"/* "$MC_HANDOFF_REL_DIR"/* 2>/dev/null
  return 0
}

consume() { rebase_consume "$KEY" "$SLUG" "$NUM" "$URL" "" "$1" "${2:-$OLD}" APPROVE DIRTY; }

# ── 1. a marker with no transition behind it is applied, exactly once ────────
# The strand: worker killed after the marker append, before rebase_result.
for st in REBASING NEEDS_REBASE; do
  reset
  echo "rebasedone $KEY $OLD" >> "$MC_ATTEMPTS"
  row "$st" "$OLD"
  job_done "$OLD" 1 "$CONFLICT"
  consume "$OLD"; rc=$?
  [ "$rc" = 0 ] && ok || bad "1/$st: a done job whose result was never applied must be consumed (rc $rc)"
  [ "$(state_of "$KEY")" = BLOCKED_HUMAN ] && ok || bad "1/$st: the conflict must reach BLOCKED_HUMAN (got $(state_of "$KEY"))"
  case "$(reason_of "$KEY")" in
    "conflict-unresolvable: $CONFLICT"*) ok ;;
    *) bad "1/$st: the reason must name the conflicting files (got '$(reason_of "$KEY")')" ;;
  esac
  [ "$(nlines "$KEY BLOCKED_AGENT conflict-unresolvable")" = 1 ] && ok || bad "1/$st: exactly one BLOCKED_AGENT hand-off line, got $(nlines "$KEY BLOCKED_AGENT conflict-unresolvable")"
  [ "$(nlines "finished rebase result on ${OLD:0:8} was never applied — applying now")" = 1 ] && ok || bad "1/$st: the late apply must say what it is doing, once"
  # and the double-tick guard still holds afterwards
  consume "$OLD"; rc=$?
  [ "$rc" = 1 ] && ok || bad "1/$st: the second tick must find nothing to read (rc $rc)"
  [ "$(nlines "$KEY BLOCKED_AGENT conflict-unresolvable")" = 1 ] && ok || bad "1/$st: the park must not be handed off twice"
  [ "$(nlines "finished rebase result on ${OLD:0:8} was never applied — applying now")" = 1 ] && ok || bad "1/$st: the late-apply line must not repeat every tick"
done

# ── 2. the TTL forget clears the consumed-result markers too ─────────────────
for st in NEEDS_REBASE REBASING; do
  reset
  row "$st" "$OLD"
  for m in rebase mergetree rebasedone rebasefailed; do echo "$m $KEY $OLD" >> "$MC_ATTEMPTS"; done
  echo "rebasedone $KEY $NEW" >> "$MC_ATTEMPTS"
  job_done "$OLD" 1 "$CONFLICT"
  JF=$(mc_rb_file "$SLUG" "$NUM" "$OLD")
  stuck_rekick "$KEY" "$st" fixture "$SLUG" "$NUM" "$URL" "$OLD" DIRTY CONFLICTING main main none
  for m in rebase mergetree rebasedone rebasefailed; do
    [ "$(nattempt "$m $KEY $OLD")" = 0 ] && ok || bad "2/$st: the forget must drop '$m $KEY $OLD' so the respawned rebase's result is read"
  done
  [ "$(nattempt "rebasedone $KEY $NEW")" = 1 ] && ok || bad "2/$st: another head's rebasedone marker must survive the forget"
  [ -f "$JF" ] && bad "2/$st: the detached job file must be gone" || ok
  [ "$(nlines "forgot this head's rebase attempt")" -ge 1 ] && ok || bad "2/$st: the forget must say so in the log"
done

# ── 3. the double-tick guard, on a job nobody interrupted ───────────────────
reset
row REBASING "$OLD"
job_done "$OLD" 1 "$CONFLICT"
[ "$(nattempt "rebasedone $KEY $OLD")" = 0 ] && ok || bad "3: no marker before the first read"
consume "$OLD"; rc=$?
[ "$rc" = 0 ] && ok || bad "3: the first read of a done job must consume it (rc $rc)"
[ "$(state_of "$KEY")" = BLOCKED_HUMAN ] && ok || bad "3: got $(state_of "$KEY")"
[ "$(nattempt "rebasedone $KEY $OLD")" = 1 ] && ok || bad "3: the marker must be recorded once, after the apply (got $(nattempt "rebasedone $KEY $OLD"))"
[ "$(nlines "$KEY BLOCKED_AGENT conflict-unresolvable")" = 1 ] && ok || bad "3: one hand-off line"
[ "$(nlines "was never applied — applying now")" = 0 ] && ok || bad "3: a result that WAS applied must not claim it was not"
consume "$OLD"; rc=$?
[ "$rc" = 1 ] && ok || bad "3: the same job must not be consumed twice (rc $rc)"
[ "$(nattempt "rebasedone $KEY $OLD")" = 1 ] && ok || bad "3: the marker must not be appended again"
[ "$(nlines "$KEY BLOCKED_AGENT conflict-unresolvable")" = 1 ] && ok || bad "3: still exactly one hand-off line"

# ── 4. the negatives: what a seen marker must NEVER re-apply ────────────────
# (a) an rc whose APPLIED state is NEEDS_REBASE on the same head is
#     indistinguishable from an unapplied one — re-applying would return 0 every
#     tick and starve the stuck detector.
for badrc in 3 4 7; do
  reset
  echo "rebasedone $KEY $OLD" >> "$MC_ATTEMPTS"
  row NEEDS_REBASE "$OLD"
  job_done "$OLD" "$badrc" ""
  consume "$OLD"; rc=$?
  [ "$rc" = 1 ] && ok || bad "4a/rc$badrc: a seen marker on an rc that parks NEEDS_REBASE on the same head must not be re-read (rc $rc)"
  [ "$(state_of "$KEY")" = NEEDS_REBASE ] && ok || bad "4a/rc$badrc: the row must not move (got $(state_of "$KEY"))"
  [ "$(nlines "was never applied — applying now")" = 0 ] && ok || bad "4a/rc$badrc: nothing to say — the row already shows the applied state"
done
# (b) the row is on a DIFFERENT head from the job: the job is history.
reset
echo "rebasedone $KEY $OLD" >> "$MC_ATTEMPTS"
row NEEDS_REBASE "$NEW"
job_done "$OLD" 1 "$CONFLICT"
consume "$OLD"; rc=$?
[ "$rc" = 1 ] && ok || bad "4b: a job for a head the row has moved off must not be applied (rc $rc)"
[ "$(state_of "$KEY")" = NEEDS_REBASE ] && ok || bad "4b: got $(state_of "$KEY")"
[ "$(head_of "$KEY")" = "$NEW" ] && ok || bad "4b: the row head must not be rewound to the job's head"
# (c) already parked: the transition landed, the marker is honest.
reset
echo "rebasedone $KEY $OLD" >> "$MC_ATTEMPTS"
row BLOCKED_HUMAN "$OLD" "conflict-unresolvable: $CONFLICT "
job_done "$OLD" 1 "$CONFLICT"
consume "$OLD"; rc=$?
[ "$rc" = 1 ] && ok || bad "4c: a park that already happened must not be re-applied (rc $rc)"
[ "$(nlines "$KEY BLOCKED_AGENT conflict-unresolvable")" = 0 ] && ok || bad "4c: a parked row must never be handed to the resolver a second time"
# (d) any other state: the row has moved on.
reset
echo "rebasedone $KEY $OLD" >> "$MC_ATTEMPTS"
row WAIT_CI "$OLD"
job_done "$OLD" 1 "$CONFLICT"
consume "$OLD"; rc=$?
[ "$rc" = 1 ] && ok || bad "4d: a row past the rebase lane must not be dragged back (rc $rc)"
[ "$(state_of "$KEY")" = WAIT_CI ] && ok || bad "4d: got $(state_of "$KEY")"
# (e) the job is still running. Nothing is readable off it, marker or no marker.
reset
echo "rebasedone $KEY $OLD" >> "$MC_ATTEMPTS"
row REBASING "$OLD"
job_running "$OLD"
consume "$OLD"; rc=$?
[ "$rc" = 1 ] && ok || bad "4e: a running job must not be read (rc $rc)"
[ "$(state_of "$KEY")" = REBASING ] && ok || bad "4e: got $(state_of "$KEY")"
[ "$(nlines "was never applied — applying now")" = 0 ] && ok || bad "4e: a running job is not an unapplied result"

# ── 5. rc 0: the marker is written after the apply, on the JOB's head ───────
reset
row REBASING "$OLD"
job_done "$OLD" 0 "$NEW"
consume "$OLD"; rc=$?
[ "$rc" = 0 ] && ok || bad "5: a pushed rebase must be consumed (rc $rc)"
[ "$(state_of "$KEY")" = WAIT_CI ] && ok || bad "5: a pushed rebase lands WAIT_CI (got $(state_of "$KEY"))"
[ "$(head_of "$KEY")" = "$NEW" ] && ok || bad "5: the row must carry the pushed head (got $(head_of "$KEY"))"
[ "$(nattempt "rebasedone $KEY $OLD")" = 1 ] && ok || bad "5: the marker is keyed on the head the job ran on, and written once"

# ── 6. THE PRODUCTION ENTRY POINT: one whole tick of bin/merge-conductor.sh ──
# Sections 1-5 drive the extracted functions. This one drives the SCRIPT: a real
# `bash bin/merge-conductor.sh` run over a fake `gh` whose open-PR list is the
# stranded PR, so the claim covers pr_worker's call site too — delete the
# `rebase_consume` line from pr_worker and this section goes red.
#
# The actions flag is deliberately OFF. Reading a finished result writes nothing
# to GitHub, so a job spawned before the flag went off must still be recorded —
# an observe-mode tick has to drain the strand exactly like an armed one.
mkdir -p "$T/h/builds" "$T/h/flags" "$T/fakebin" "$T/repos"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/deploy-request.sh" "$T/h/bin/"
printf 'demo-os %s https://demo.example /api/board 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf 'job_verdict_rebind() { return 0; }\n' > "$T/h/bin/jobs-client.sh"
for s in beat.sh lane-alert.sh prod-url.sh agent-call.sh deploy-verify.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"
done
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/git"; chmod +x "$T/fakebin/git"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"pr merge"*|*"issue close"*|*"pr review"*|*"pr edit"*) echo "WRITE VERB: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R $SLUG --state open"*)
    cat <<'J'
[{"number":$NUM,"url":"$URL","headRefOid":"$OLD","headRefName":"ticket/bh-523","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN"}]
J
    ;;
  *"pr list"*) echo "" ;;
  *"pr view"*"--json body"*) echo "plain body" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
REC="$T/h/builds/demo-os-BH-523-202609171926"
mkdir -p "$REC"
echo "PR_CREATED $URL" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$OLD" > "$REC/reviewed-sha"

reset
rm -f "$T/gh-writes.txt" "$T/gh-calls.txt"
echo "rebasedone $KEY $OLD" >> "$MC_ATTEMPTS"
row REBASING "$OLD"
job_done "$OLD" 1 "$CONFLICT"
( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" MC_REPOS="$T/repos" \
    MC_RR_PATH="$T/fakebin:$PATH" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
  || { echo "NOTE: tick rc=$? stderr:"; tail -5 "$T/tick.err"; }
[ -s "$T/gh-calls.txt" ] && ok || bad "6: the tick never reached the open-PR list — the fixture, not the fix, is what this section measured"
[ "$(state_of "$KEY")" = BLOCKED_HUMAN ] && ok || bad "6: a whole tick must drain the stranded head to BLOCKED_HUMAN (got '$(state_of "$KEY")')"
case "$(reason_of "$KEY")" in
  "conflict-unresolvable: $CONFLICT"*) ok ;;
  *) bad "6: the reason must name the conflicting files (got '$(reason_of "$KEY")')" ;;
esac
[ "$(nlines "$KEY BLOCKED_AGENT conflict-unresolvable")" = 1 ] && ok || bad "6: exactly one resolver hand-off line from the tick, got $(nlines "$KEY BLOCKED_AGENT conflict-unresolvable")"
[ -s "$T/gh-writes.txt" ] && bad "6: the tick wrote to GitHub: $(cat "$T/gh-writes.txt")" || ok
# and a second tick does not re-park it
( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" MC_REPOS="$T/repos" \
    MC_RR_PATH="$T/fakebin:$PATH" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
  || { echo "NOTE: second tick rc=$? stderr:"; tail -5 "$T/tick.err"; }
[ "$(nlines "$KEY BLOCKED_AGENT conflict-unresolvable")" = 1 ] && ok || bad "6: the second tick must not hand the same park off again"
[ "$(nlines "was never applied — applying now")" = 1 ] && ok || bad "6: the late-apply line must be written once, not once per tick"

echo "mc-rebase-consume-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
