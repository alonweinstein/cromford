#!/bin/bash
# tests/main-red-queue-thaw.bh-3886-test.sh — BH-3889 (2 of 5 of BH-3886):
# bin/lib/main-red-queue-thaw.sh, the lib behind the detector's mrqt_clear_ok
# and mrqt_stand_down hooks, driven through the REAL bin/main-red-detector.sh.
#
# THE INCIDENT, ON ITS OWN PAGES. tests/fixtures/bh-3886/ holds the
# cromford runs of 2026-10-02 as `gh api` returned them. At 06:01:34Z the
# queue arm froze main on three independent red batches (newest 36969794399,
# created 05:37:50, finished 05:53:34) while the greens 36971026756 and
# 36971039150 (created 05:54Z) were still running. They finished green at
# 06:09Z, but the clear compared their created_at with the flag's detected=,
# and nothing merges during a freeze, so no newer batch was ever created.
#
# A page is the fixture as GitHub showed it at a CUT instant: only runs created
# by then, and a run that finished after it is served in_progress. Every
# timestamp is then shifted by ONE offset (06:01:34Z, the raise, lands on NOW),
# so detected= (the real clock at the tick) falls where it fell that morning.
#   C1 06:01:34  the raise tick: the 05:54Z greens are in flight
#   C2 06:09:40  both 05:54Z greens have finished, no push on main yet
#   C3 06:11:30  the push runs of 06:09:50 and 06:09:57 have finished
#
#   A3  the incident: raised at C1 with qred_t=/qred_done=, cleared at C2 with
#       one --resolve because a green batch was CREATED after the newest red
#   A4  a green created before the newest red but FINISHED after it clears
#   A5  a green created and finished before the newest red holds
#   A6  a legacy flag (no qred_t=) keeps today's detected= rule
#   B1  a push of Harness CI on 78cd5df9 at 06:09:57, after the red finished,
#       clears
#   B2  an older push holds (B2a raise side, B2b clear side)
#   B3  a skip-listed workflow's green holds
#   B4  a schedule run's green holds
#   B5  raise side: three reds and a newer green push raise nothing
# Each behaviour has a mutation of the lib that must flip it (D1).
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/main-red-queue-thaw.bh-3886-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  [ -n "${CI:-}" ] && { echo "FAIL: jq/python3 missing on a CI runner"; exit 1; }
  echo "main-red-queue-thaw.bh-3886-test: SKIPPED — jq/python3 is not installed"; exit 0; }
FX="$DIR/tests/fixtures/bh-3886"
[ -s "$FX/queue-2026-10-02.json" ] && [ -s "$FX/main-2026-10-02.json" ] || {
  echo "FAIL: the bh-3886 fixtures are missing"; exit 1; }
REG=$(rendered_registry)

NOW=$(date +%s)                     # the ONLY clock read in this file
SLUG=o/r
OFF=$((NOW - $(date -u -d 2026-10-02T06:01:34Z +%s)))
C1=2026-10-02T06:01:34Z; C2=2026-10-02T06:09:40Z; C3=2026-10-02T06:11:30Z

# The scratch harness root: the real detector and ALL of bin/lib/, so the lib
# under test is loaded exactly as the hub loads it.
R="$T/h"
mkdir -p "$R/bin/lib" "$R/logs" "$R/state" "$R/flags" "$R/locks" "$R/env" "$R/fakebin" "$R/ledger"
cp "$DIR/bin/main-red-detector.sh" "$R/bin/"
cp -R "$DIR/bin/lib/." "$R/bin/lib/"
: > "$R/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$R/bin/beat.sh"; chmod +x "$R/bin/beat.sh"
cat > "$R/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$R/bin/lane-alert.sh"
cat > "$R/bin/jobs-client.sh" <<'SHIM'
flag_set() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$PUBLISH_SINK"; return 0; }
_lrow() { printf '%s/%s__%s' "$LEDGER_DIR" "$1" "$(printf '%s' "$2" | tr '/#' '-_')"; }
job_ledger_get() { local f; f=$(_lrow "$1" "$2"); [ -f "$f" ] || return 2; cat "$f"; return 0; }
job_ledger_put() { printf '%s' "$3" > "$(_lrow "$1" "$2")"; return 0; }
_jobs_req() { case "$2" in /api/settings) printf '{"settings":[]}' ;; *) return 1 ;; esac; }
SHIM
# The gh fake logs every call and APPLIES THE DETECTOR'S OWN -q FILTER to the
# page on disk; event=pull_request is the queue page, any other runs read main.
cat > "$R/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
q=""; a=("$@"); for i in "${!a[@]}"; do [ "${a[$i]}" = -q ] && q="${a[$((i+1))]}"; done
case "$*" in
  "api repos/"*" -q .id") exit 0 ;;
  *"/actions/runs/"*"/jobs"*) echo "" ;;
  *"event=pull_request"*) [ -s "$PAGES/queue.json" ] || exit 1; jq -c "$q" "$PAGES/queue.json" ;;
  *"actions/runs"*)       [ -s "$PAGES/main.json" ]  || exit 1; jq -c "$q" "$PAGES/main.json" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$R/fakebin/gh"
PAGES="$T/pages"; mkdir -p "$PAGES"

# page <main|queue> <cut-iso> [jq-transform] — the fixture at a cut, rebased.
# In the transform, `rb` rebases a recorded ISO time and $all is the whole
# recorded page (pre-cut, pre-rebase).
page() {
  jq --argjson off "$OFF" --arg cut "$2" "
    def rb: fromdateiso8601 + \$off | todateiso8601;
    .workflow_runs as \$all
    | .workflow_runs |= (map(select(.created_at <= \$cut))
        | map(if .updated_at > \$cut then .status = \"in_progress\" | .conclusion = null else . end)
        | map(.created_at |= rb | .updated_at |= rb))
    | ${3:-.}" "$FX/$1-2026-10-02.json" > "$PAGES/$1.json" || { echo "FAIL: page $1 $2 did not build"; exit 1; }
}
rb() { date -u -d "@$(( $(date -u -d "$1" +%s) + OFF ))" +%FT%TZ; }
GREENS='(.id == 36971026756 or .id == 36971039150)'

drive() {
  ( export PATH="$R/fakebin:$PATH" HARNESS="$R" PAGES="$PAGES" GH_SINK="$R/gh.txt" LANE_REGISTRY="$REG" \
           ALERT_SINK="$R/alerts.txt" PUBLISH_SINK="$R/publish.txt" LEDGER_DIR="$R/ledger" \
           MAIN_RED_QUEUE_REPOS="$SLUG" MAIN_RED_QUEUE_ATTR=0 MAIN_RED_QUEUE_SELF_DISPATCH_MIN=0; unset GH_TOKEN
    bash "$R/bin/main-red-detector.sh" "$SLUG" >/dev/null 2>>"$R/err.txt" )
}
FLAG="$R/flags/main-red-o-r"
LOG="$R/logs/main-red.log"
reset() {
  local p; for p in ledger state/main-red state/lane-gate state/settings-cache.json; do scratch_rm "$R/$p" || exit 1; done
  mkdir -p "$R/ledger"
  rm -f "$R"/flags/main-red-*
  : > "$R/alerts.txt"; : > "$R/gh.txt"; : > "$LOG"; : > "$R/publish.txt"
}
fl()       { sed -n "s/^$1=//p" "$FLAG" 2>/dev/null | head -1; }
resolves() { grep -c -- '^--resolve' "$R/alerts.txt" 2>/dev/null; }
crit()     { grep -c -- '^--critical' "$R/alerts.txt" 2>/dev/null; }
clears()   { [ ! -f "$FLAG" ] && [ "$(resolves)" = 1 ]; }
stays()    { [ -f "$FLAG" ] && [ "$(resolves)" = 0 ]; }
why()      { echo "flag=$([ -f "$FLAG" ] && echo yes || echo no) resolves=$(resolves) log=$(tail -4 "$LOG" | sed -E 's/^[0-9-]+ [0-9:]+Z //' | tr '\n' '|')"; }
unbound()  { if grep -q 'unbound variable' "$R/err.txt"; then bad "$1: set -u tripped: $(grep 'unbound variable' "$R/err.txt" | head -2)"; else ok; fi; : > "$R/err.txt"; }

# The lib under test, and its mutants. mutate <sed> installs one; it fails when
# the sed matched nothing, so a mutation that silently stopped applying is red.
LIB="$R/bin/lib/main-red-queue-thaw.sh"
PRISTINE="$T/thaw.pristine"
[ -f "$DIR/bin/lib/main-red-queue-thaw.sh" ] && cp "$DIR/bin/lib/main-red-queue-thaw.sh" "$PRISTINE"
# The C1 raise always runs on the pristine lib (raise() re-installs the mutant
# after it), so a mutant is judged on the tick under test only.
MUT=""
mutate()  { [ -f "$PRISTINE" ] || { bad "mutation $1: bin/lib/main-red-queue-thaw.sh is not installed"; return 1; }
            sed "$1" "$PRISTINE" > "$LIB"; cmp -s "$PRISTINE" "$LIB" && { bad "mutation $1 changed nothing"; return 1; }
            MUT="$1"; return 0; }
restore() { MUT=""; if [ -f "$PRISTINE" ]; then cp "$PRISTINE" "$LIB"; else rm -f "$LIB"; fi; }

# raise — tick 1: the incident's 06:01:34 raise, then the alerts are emptied so
# tick 2 is judged alone.
raise() {
  [ -n "$MUT" ] && cp "$PRISTINE" "$LIB"
  reset; page main "$C1"; page queue "$C1"; drive
  [ -n "$MUT" ] && sed "$MUT" "$PRISTINE" > "$LIB"
  [ -f "$FLAG" ] || { bad "the C1 tick must raise the freeze: $(why)"; return 1; }
  : > "$R/alerts.txt"; : > "$LOG"
}
RED_T=$(rb 2026-10-02T05:37:50Z); RED_DONE=$(rb 2026-10-02T05:53:34Z)

# ── A3. the incident: the C2 tick clears on a green batch created after the red.
a3() { raise || return 1; page queue "$C2"; page main "$C1"; drive; }
reset; page main "$C1"; page queue "$C1"; drive
{ [ "$(fl reason)" = queue ] && [ "$(fl qred_t)" = "$RED_T" ] && [ "$(fl qred_done)" = "$RED_DONE" ]; } && ok \
  || bad "A3: the C1 raise carries reason=queue qred_t=$RED_T qred_done=$RED_DONE: $(cat "$FLAG" 2>/dev/null | tr '\n' ' ')"
unbound A3-raise
a3
{ clears && [ "$(wc -l < "$R/alerts.txt")" = 1 ] \
  && grep -q "queue freeze thawed — merge-queue batch created at $(rb 2026-10-02T05:54:23Z) went green" "$LOG"; } && ok \
  || bad "A3: the C2 tick must clear with one --resolve, on the batch created at $(rb 2026-10-02T05:54:23Z): $(why)"
unbound A3
N_LIB=$(grep -c . "$R/gh.txt")
# The same tick with no lib is the defect itself, and the lib adds no gh read.
if [ -f "$PRISTINE" ]; then
  rm -f "$LIB"; a3
  { stays && [ "$(grep -c . "$R/gh.txt")" = "$N_LIB" ]; } && ok \
    || bad "A3-nolib: without the lib the flag stays (the deadlock), on the same $N_LIB gh calls: gh=$(grep -c . "$R/gh.txt") $(why)"
  restore
fi
if mutate 's/if \[ -z "\$qt" \]; then/if true; then/'; then
  a3; stays && ok || bad "A3-mut: every flag on the detected= rule must hold: $(why)"; restore
fi

# ── A4. created before the newest red, finished after it: clears.
a4() { raise || return 1; page queue "$C2" "(.workflow_runs[] | select($GREENS) | .created_at) = (\"2026-10-02T05:30:00Z\" | rb)"; page main "$C1"; drive; }
a4
{ clears && grep -q "queue freeze thawed — a merge-queue batch finished green at $(rb 2026-10-02T06:09:28Z), after the newest red batch finished at $RED_DONE" "$LOG"; } && ok \
  || bad "A4: a green finished after the red must clear: $(why)"
unbound A4
if mutate '/QGREEN_DONE:-}" \] && \[ -n "\$qd" \]/d'; then
  a4; stays && ok || bad "A4-mut: without the finish compare it must hold: $(why)"; restore
fi

# ── A5. created and finished before the newest red: holds.
a5() { raise || return 1
  page queue "$C2" "(.workflow_runs[] | select($GREENS) | .created_at) = (\"2026-10-02T05:30:00Z\" | rb) | (.workflow_runs[] | select($GREENS) | .updated_at) = (\"2026-10-02T05:50:00Z\" | rb)"
  page main "$C1"; drive; }
a5
{ stays && [ ! -s "$R/alerts.txt" ] && grep -q 'thaw.sh holds it — no green batch created after' "$LOG"; } && ok \
  || bad "A5: a green created and finished before the red must hold: $(why)"
unbound A5
if mutate 's/\[\[ "\$QGREEN_DONE" > "\$qd" \]\]/[[ "$QGREEN_DONE" < "$qd" ]]/'; then
  a5; clears && ok || bad "A5-mut: the finish compare reversed must clear (A5 is held BY the compare): $(why)"; restore
fi

# ── A6. a legacy flag (no qred_t=): today's comparison against detected=.
legacy() { raise || return 1; sed -i '/^qred_t=/d;/^qred_done=/d;/^raised=/d' "$FLAG"
  DET=$(fl detected); AFTER=$(date -u -d "@$(( $(date -u -d "${DET% *}T${DET#* }" +%s) + 60 ))" +%FT%TZ); }
a6a() { legacy || return 1; page queue "$C2"; page main "$C1"; drive; }
a6a
{ stays && grep -q 'holds it — a legacy flag (no qred_t=)' "$LOG"; } && ok \
  || bad "A6a: a legacy flag with only a pre-freeze green holds: $(why)"
unbound A6a
legacy && page queue "$C2" "(.workflow_runs[] | select(.id == 36971039150) | .created_at) = \"$AFTER\"" && page main "$C1" && drive
{ clears && grep -q "a legacy flag (no qred_t=) and a green batch created $AFTER" "$LOG"; } && ok \
  || bad "A6b: a legacy flag with a green batch created after detected= clears: $(why)"
unbound A6b
legacy && page queue "$C1" && page main "$C1" ".workflow_runs += [\$all[] | select(.id == 36999809011) | .created_at = \"$AFTER\" | .updated_at = \"$AFTER\"]" && drive
clears && ok || bad "A6c: a legacy flag with a workflow_dispatch green after detected= clears: $(why)"
unbound A6c
if mutate 's/if \[ -z "\$qt" \]; then/if false; then/'; then
  a6a; clears && ok || bad "A6-mut: a legacy flag on the new rule must clear: $(why)"; restore
fi

# ── Q4b. a queue that could not be read thaws nothing on the batch arm.
raise && page main "$C1" && : > "$PAGES/queue.json" && drive
{ stays && grep -q '(queue read: fail)' "$LOG"; } && ok || bad "Q4b: an unreadable queue must hold: $(why)"
unbound Q4b

# ── B1. a green push of Harness CI on main after the red finished: clears.
b1() { raise || return 1; page queue "$C1"; page main "$C3"; drive; }
b1
{ clears && grep -q "queue freeze thawed — a push run of Harness CI passed on main at $(rb 2026-10-02T06:09:57Z) on 78cd5df9, after the newest red batch finished at $RED_DONE" "$LOG"; } && ok \
  || bad "B1: the 06:09:57 push on 78cd5df9 must clear: $(why)"
unbound B1
if mutate 's/_mrqt_main_green "\$floor"/false/'; then
  b1; stays && ok || bad "B1-mut: without the main-run arm the clear must hold: $(why)"; restore
fi

# hold <label> <main-transform> — B2/B3/B4: a raised flag, main at C3 through the
# transform. (a) queue C1: the reds are still counted, so the raise side
# (mrqt_stand_down) decides. (b) the same page with a streak no page reaches:
# no verdict, so the clear side (mrqt_clear_ok) decides.
hold_a() { raise || return 1; page queue "$C1"; page main "$1" "$2"; drive; }
hold_b() { raise || return 1; page queue "$C1"; page main "$1" "$2"; ( export MAIN_RED_QUEUE_STREAK=99; drive ); }
hold() { # hold <label> <main-cut> <transform> <mutation>
  hold_a "$2" "$3"
  { stays && ! grep -q 'stands down' "$LOG"; } && ok || bad "$1a: raise side must not stand down: $(why)"
  unbound "$1a"
  hold_b "$2" "$3"
  { stays && grep -q 'thaw.sh holds it — no green batch created after' "$LOG" \
    && grep -q "no green push or dispatch run on main after $RED_DONE" "$LOG"; } && ok || bad "$1b: clear side must hold: $(why)"
  unbound "$1b"
  if mutate "$4"; then
    hold_a "$2" "$3"; clears && ok || bad "$1a-mut: the mutant must stand down and clear: $(why)"
    hold_b "$2" "$3"; clears && ok || bad "$1b-mut: the mutant must clear: $(why)"
    restore
  fi
}
# B2: main at C1, whose newest green push (03:29:51) is older than the red's finish.
hold B2 "$C1" "." 's/select((.t \/\/ "") > \$floor)/select((.t \/\/ "") > "")/'
# B3: the Harness CI pushes after the red gone, Publish share mirror (skip-listed) green.
hold B3 "$C3" "del(.workflow_runs[] | select(.name == \"Harness CI\" and .created_at > \"$RED_DONE\")) | (.workflow_runs[] | select(.id == 36972248080)) |= (.status = \"completed\" | .conclusion = \"success\")" \
  '/test(\$re; "i"))) | not)$/d'
# B4: the Harness CI pushes after the red ran as schedule.
hold B4 "$C3" "(.workflow_runs[] | select(.name == \"Harness CI\" and .created_at > \"$RED_DONE\") | .event) = \"schedule\"" \
  's/select(.e == "push" or .e == "workflow_dispatch")/select(true)/'

# ── B5. raise side: three independent reds and a newer green push raise nothing.
b5() { reset; page queue "$C1"; page main "$C3"; drive; }
b5
{ [ ! -f "$FLAG" ] && [ "$(crit)" = 0 ] \
  && grep -q "o/r: 3 red merge-queue batches, but a push run of Harness CI passed on main at $(rb 2026-10-02T06:09:57Z) on 78cd5df9, after the newest red batch finished at $RED_DONE — the queue arm stands down" "$LOG"; } && ok \
  || bad "B5: three reds and a newer green push must stand the arm down: $(why)"
unbound B5
if mutate 's/^mrqt_stand_down() {$/mrqt_stand_down() { return 1/'; then
  b5; { [ -f "$FLAG" ] && [ "$(fl reason)" = queue ]; } && ok || bad "B5-mut: a stand-down that never answers must raise: $(why)"; restore
fi

# B5b: GitHub gave no updated_at, so QRED_DONE is empty and the floor is the
# newest counted red's created_at (QVERDICT column 10).
b5b() { reset; page queue "$C1" 'del(.workflow_runs[].updated_at)'; page main "$C3"; drive; }
b5b
{ [ ! -f "$FLAG" ] && grep -q "passed on main at $(rb 2026-10-02T06:09:57Z) on 78cd5df9, after the newest red batch was created at $RED_T (its finish unknown) — the queue arm stands down" "$LOG"; } && ok \
  || bad "B5b: with no finish recorded the red's created_at is the floor: $(why)"
unbound B5b
if mutate 's/case "\$ep" in .*/return 1/'; then
  b5b; [ -f "$FLAG" ] && ok || bad "B5b-mut: without the column-10 fallback the arm must raise: $(why)"; restore
fi

echo "main-red-queue-thaw.bh-3886: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
