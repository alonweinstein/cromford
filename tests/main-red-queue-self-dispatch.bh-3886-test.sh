#!/bin/bash
# tests/main-red-queue-self-dispatch.bh-3886-test.sh — BH-3891 (4 of 5 of
# BH-3886): bin/lib/main-red-queue-dispatch.sh, the one workflow_dispatch of a
# queue freeze's workflow on main per freeze episode, driven through the REAL
# bin/main-red-detector.sh at both of its call sites (the queue hold branch and
# the same-sha still-red path).
#
# THE PAGES ARE REAL. tests/fixtures/bh-3886/ holds the cromford runs of
# 2026-10-02 as `gh api` returned them. Every timestamp is rebased onto NOW with
# its gaps kept and a page is CUT at an instant, exactly as
# tests/main-red-queue-hooks.bh-3886-test.sh does. The workflow page the lib
# reads is main's harness-ci.yml runs from the same fixture; D4/D4b change ONE
# declared field of ONE real run (wfpage's jq transform), nothing is hand-typed.
#
#   D1  held 61 min, newest push green: one POST, row requested, SELF-DISPATCH:
#   D1-order  the ledger row is written before the POST
#   D2  a second tick in the episode: no second POST
#   D3  held 59 min: nothing read, nothing posted
#   D4  newest push run red: no POST, no row
#   D4b a run in flight on main: no POST, no row
#   D5  the ledger read fails: no POST, no row
#   D6  the ledger write fails: no POST
#   D7  a refused POST: row refused, one warn naming the manual step, never
#       logged as SELF-DISPATCH:, not retried on the next tick
#   D8  the knob at 0: no gh read and no ledger read by the lib
#   D9  a new episode (new since=) dispatches again, under its own row
#   D10 --explain: WOULD SELF-DISPATCH, nothing written, nothing posted
#   D11 the settings row beats env
#   D12 the same-sha still-red call site dispatches
#   D13 a reason=streak flag never dispatches (D13b: the lib's own gate, called directly)
#   D14 a legacy flag with no raised= ages from detected=
#   D15 no since=: no episode key, no dispatch
#   D16 the workflow comes from path=, never a constant
#   M2-M7 mutations of the real lib, each turning its case red
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/main-red-queue-self-dispatch.bh-3886-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  [ -n "${CI:-}" ] && { echo "FAIL: jq/python3 missing on a CI runner"; exit 1; }
  echo "main-red-queue-self-dispatch.bh-3886-test: SKIPPED — jq/python3 is not installed"; exit 0; }
FX="$DIR/tests/fixtures/bh-3886"
[ -s "$FX/queue-2026-10-02.json" ] && [ -s "$FX/main-2026-10-02.json" ] || {
  echo "FAIL: the bh-3886 fixtures are missing"; exit 1; }
REG=$(rendered_registry)
unset MAIN_RED_QUEUE_SELF_DISPATCH_MIN MAIN_RED_QUEUE_ATTR

NOW=$(date +%s)                     # the ONLY clock read in this file
SLUG=example-org/cromford
LIB="$DIR/bin/lib/main-red-queue-dispatch.sh"
R="$T/new"

# The scratch harness root: the real detector, the libs it needs, and the REAL
# dispatch lib. No thaw or attr lib, so the hold branch is today's comparison.
mkdir -p "$R/bin/lib" "$R/logs" "$R/state" "$R/flags" "$R/locks" "$R/env" "$R/fakebin" "$R/ledger"
cp "$DIR/bin/main-red-detector.sh" "$R/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/lane-gate.sh" "$R/bin/lib/"
TLIB="$R/bin/lib/main-red-queue-dispatch.sh"
cp "$LIB" "$TLIB" 2>/dev/null || bad "setup: $LIB is not there to copy"
: > "$R/env/global.env"
cat > "$R/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$R/bin/lane-alert.sh"
# The coordination-DB client: ledger verbs over files, /api/settings from $ROWS.
# Every get/put is logged; QD_GET_FAIL/QD_PUT_FAIL break only the dispatch kind.
# A put also lands in seq.txt, the one sequence the gh fake's POST shares.
cat > "$R/bin/jobs-client.sh" <<'SHIM'
flag_set() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$PUBLISH_SINK"; return 0; }
_lrow() { printf '%s/%s__%s' "$LEDGER_DIR" "$1" "$(printf '%s' "$2" | tr '/#' '-_')"; }
job_ledger_get() {
  echo "get $1 $2" >> "$LEDGER_LOG"
  [ "$1" = main_red_qdispatch ] && [ "${QD_GET_FAIL:-0}" = 1 ] && return 1
  local f; f=$(_lrow "$1" "$2"); [ -f "$f" ] || return 2; cat "$f"; return 0
}
job_ledger_put() {
  echo "put $1 $2 $3" >> "$LEDGER_LOG"; echo "put $1 $3" >> "$SEQ_SINK"
  [ "$1" = main_red_qdispatch ] && [ "${QD_PUT_FAIL:-0}" = 1 ] && return 1
  printf '%s' "$3" > "$(_lrow "$1" "$2")"; return 0
}
_jobs_req() {
  case "$2" in
    /api/settings)
      local out="[]" kv IFS=$'\n'
      for kv in ${ROWS:-}; do
        out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"t"}]')
      done
      printf '{"settings":%s}' "$out" ;;
    *) return 1 ;;
  esac
}
SHIM
# The gh fake APPLIES THE -q FILTER the caller passed to the page on disk.
cat > "$R/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
q=""; a=("$@"); for i in "${!a[@]}"; do [ "${a[$i]}" = -q ] && q="${a[$((i+1))]}"; done
case "$*" in
  "api repos/"*" -q .id") exit 0 ;;
  *"/actions/workflows/"*"/dispatches"*)
    echo "gh POST $*" >> "$SEQ_SINK"
    [ "${GH_POST_RC:-0}" = 0 ] || echo "HTTP 422: Workflow does not have 'workflow_dispatch' trigger" >&2
    exit "${GH_POST_RC:-0}" ;;
  *"/actions/workflows/"*"/runs"*) [ -s "$PAGES/wf.json" ] || exit 1; jq -c "$q" "$PAGES/wf.json" ;;
  *"/actions/runs/"*"/jobs"*) exit 1 ;;
  *"event=pull_request"*) [ -s "$PAGES/queue.json" ] || exit 1; jq -c "$q" "$PAGES/queue.json" ;;
  *"actions/runs"*)       [ -s "$PAGES/main.json" ]  || exit 1; jq -c "$q" "$PAGES/main.json" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$R/fakebin/gh"
PAGES="$T/pages"; mkdir -p "$PAGES"

# page <queue|main> <cut-iso> — the fixture runs whose updated_at <= cut, every
# timestamp shifted by ONE offset (05:53:34Z lands one minute before NOW).
# wfpage <cut> [jq-transform] — main's harness-ci.yml runs, cut and rebased the
# same way, then the transform (one field of one real run) applied.
rebase() { # rebase <src> <cut> <out> [path-filter]
  python3 - "$1" "$2" "$NOW" "$3" "${4:-}" <<'PY'
import calendar, json, sys, time
src, cut, now, out, path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
P = lambda s: calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
F = lambda e: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(e))
off = now - 60 - P("2026-10-02T05:53:34Z")
runs = [r for r in json.load(open(src))["workflow_runs"] if P(r["updated_at"]) <= P(cut) and (not path or r.get("path") == path)]
for r in runs:
    r["created_at"] = F(P(r["created_at"]) + off); r["updated_at"] = F(P(r["updated_at"]) + off)
json.dump({"workflow_runs": runs}, open(out, "w"))
PY
}
page() { rebase "$FX/$1-2026-10-02.json" "$2" "$PAGES/$1.json"; }
wfpage() {
  rebase "$FX/main-2026-10-02.json" "$1" "$PAGES/wf.json" .github/workflows/harness-ci.yml
  [ -n "${2:-}" ] || return 0
  jq -c --argjson id "$NEWEST" "$2" "$PAGES/wf.json" > "$PAGES/wf.t" && mv "$PAGES/wf.t" "$PAGES/wf.json"
}
rebased() { jq -r --argjson id "$1" ".workflow_runs[] | select(.id == \$id) | .$2" "$PAGES/queue.json"; }
CUT3=2026-10-02T05:53:34Z   # 3 independent reds: 36969794399, 36967597297, 36966459398
CUT2=2026-10-02T05:23:13Z   # 2 independent reds — no verdict, so a queue flag HOLDS

wfpage "$CUT3"
# The run D4/D4b transform: main's newest completed push run of harness-ci.yml.
NEWEST=$(jq '[.workflow_runs[] | select(.event == "push" and .status == "completed")] | max_by(.created_at) | .id' "$PAGES/wf.json")
{ [ -n "$NEWEST" ] && [ "$NEWEST" != null ] \
  && [ "$(jq -r --argjson id "$NEWEST" '.workflow_runs[] | select(.id == $id) | .conclusion' "$PAGES/wf.json")" = success ] \
  && [ "$(jq -r '[.workflow_runs[] | select(.status != "completed")] | length' "$PAGES/wf.json")" = 0 ]; } && ok \
  || bad "setup: the untransformed workflow page must have a green newest push run and nothing in flight (newest=$NEWEST)"

drive() { # drive [args] — one tick of the scratch detector
  ( export PATH="$R/fakebin:$PATH" HARNESS="$R" PAGES="$PAGES" GH_SINK="$R/gh.txt" LANE_REGISTRY="$REG" \
           ALERT_SINK="$R/alerts.txt" PUBLISH_SINK="$R/publish.txt" LEDGER_DIR="$R/ledger" ROWS="${ROWS:-}" \
           LEDGER_LOG="$R/ledger.txt" SEQ_SINK="$R/seq.txt" MAIN_RED_QUEUE_REPOS="$SLUG"; unset GH_TOKEN
    bash "$R/bin/main-red-detector.sh" "$@" "$SLUG" >/dev/null 2>>"$R/err.txt" )
}
reset() {
  local p; for p in ledger state/main-red state/lane-gate state/settings-cache.json; do scratch_rm "$R/$p" || exit 1; done
  mkdir -p "$R/ledger"
  rm -f "$R"/flags/main-red-*
  local f; for f in alerts gh ledger seq publish err; do : > "$R/$f.txt"; done; : > "$R/logs/main-red.log"
  ROWS=""
}
FLAG="$R/flags/main-red-example-org-cromford"
LOG="$R/logs/main-red.log"
ago() { date -u -d "@$((NOW - $1 * 60))" '+%Y-%m-%d %H:%M:%SZ'; }
# mkflag [k=v...] — a flag this detector already raised. raised=/detected= are
# minutes before NOW (raised=- omits the line); since=- omits since=.
mkflag() {
  local sha=deadbeef reason=queue since=2026-10-02T04:52:39Z raised=61 detected=0 path=.github/workflows/harness-ci.yml kv
  for kv in "$@"; do local "$kv"; done
  { echo "sha=$sha"; echo "workflow=Harness CI"; echo "path=$path"; echo "job=(job list unavailable)"
    [ "$since" = - ] || echo "since=$since"
    echo "streak=3"; echo "run=u"; echo "detected=$(ago "$detected")"; echo "reason=$reason"
    [ "$raised" = - ] || echo "raised=$(ago "$raised")"; } > "$FLAG"
}
hold()     { reset; page main "$CUT3"; page queue "$CUT2"; wfpage "$CUT3" "${1:-}"; }   # the queue hold branch
samesha()  { reset; page main "$CUT3"; page queue "$CUT3"; wfpage "$CUT3"; }          # the same-sha still-red path
posts()    { grep -c '/dispatches' "$R/gh.txt"; }
wfreads()  { grep -c 'actions/workflows/' "$R/gh.txt"; }
rows()     { find "$R/ledger" -name 'main_red_qdispatch__*' | wc -l; }
row()      { cat "$R/ledger"/main_red_qdispatch__* 2>/dev/null; }
warns()    { grep -c '^--severity warn' "$R/alerts.txt"; }
qdledger() { grep -c ' main_red_qdispatch ' "$R/ledger.txt"; }

# Each scenario is a function so a mutation can re-run it unchanged.
sc_d1() { hold; mkflag; drive; }
sc_d2() { sc_d1; drive; }
sc_d3() { hold; mkflag raised=59; drive; }
sc_d4() { hold '(.workflow_runs[] | select(.id == $id)).conclusion = "failure"'; mkflag; drive; }
sc_d4b() { hold '(.workflow_runs[] | select(.id == $id)) |= (.status = "in_progress" | .conclusion = null)'; mkflag; drive; }
sc_d6() { hold; mkflag; ( export QD_PUT_FAIL=1; drive ); }
sc_d7() { hold; mkflag; ( export GH_POST_RC=1; drive; drive ); }

# ── D1 + D1-order
sc_d1
[ "$(posts)" = 1 ] && grep -qx "api -X POST repos/$SLUG/actions/workflows/harness-ci.yml/dispatches -f ref=main" "$R/gh.txt" && ok \
  || bad "D1: one POST to harness-ci.yml's dispatches on main (posts=$(posts); gh=$(grep workflows "$R/gh.txt"); log=$(tail -3 "$LOG"))"
[ "$(rows)" = 1 ] && row | grep -qE '^dispatch=requested at=[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}Z$' && ok \
  || bad "D1: the row is dispatch=requested at=<stamp> (rows=$(rows) row=$(row))"
[ -f "$R/ledger/main_red_qdispatch__example-org-cromford_2026-10-02T04:52:39Z" ] && ok \
  || bad "D1: the row's key is <owner>/<repo>#<since>: $(ls "$R/ledger")"
grep -q "SELF-DISPATCH: $SLUG harness-ci.yml on main — queue freeze held 61 min, main's newest push run is green; one dispatch for this episode" "$LOG" && ok \
  || bad "D1: the success line: $(grep -i dispatch "$LOG")"
grep -q 'unbound variable' "$R/err.txt" && bad "D1: set -u tripped: $(cat "$R/err.txt")" || ok
PUTL=$(grep -n '^put main_red_qdispatch dispatch=requested' "$R/seq.txt" | cut -d: -f1 | head -1)
POSTL=$(grep -n '^gh POST' "$R/seq.txt" | cut -d: -f1 | head -1)
[ -n "$PUTL" ] && [ -n "$POSTL" ] && [ "$PUTL" -lt "$POSTL" ] && ok \
  || bad "D1-order: the row is written before the POST: $(cat "$R/seq.txt")"

# ── D2
sc_d2
{ [ "$(posts)" = 1 ] && grep -q "self-dispatch: $SLUG already requested for the episode since 2026-10-02T04:52:39Z (dispatch=requested at=.*) — not again" "$LOG"; } && ok \
  || bad "D2: a second tick posts nothing and says so (posts=$(posts); log=$(grep dispatch "$LOG"))"

# ── D3
sc_d3
{ [ "$(posts)" = 0 ] && [ "$(rows)" = 0 ] && [ "$(wfreads)" = 0 ]; } && ok \
  || bad "D3: 59 min posts nothing, writes nothing, reads nothing (posts=$(posts) rows=$(rows) reads=$(wfreads))"

# ── D4 / D4b
sc_d4
{ [ "$(posts)" = 0 ] && [ "$(rows)" = 0 ] && grep -q "main's newest push run of harness-ci.yml is failure — no dispatch" "$LOG"; } && ok \
  || bad "D4: newest push red posts nothing (posts=$(posts) rows=$(rows); log=$(grep dispatch "$LOG"))"
sc_d4b
{ [ "$(posts)" = 0 ] && [ "$(rows)" = 0 ] && grep -q "harness-ci.yml has a run in flight on main ($NEWEST) — no dispatch" "$LOG"; } && ok \
  || bad "D4b: a run in flight posts nothing (posts=$(posts) rows=$(rows); log=$(grep dispatch "$LOG"))"

# ── D5
hold; mkflag; ( export QD_GET_FAIL=1; drive )
{ [ "$(posts)" = 0 ] && [ "$(rows)" = 0 ] && [ "$(wfreads)" = 0 ] && grep -q 'could not read the dispatch ledger' "$LOG"; } && ok \
  || bad "D5: an unreadable ledger posts nothing (posts=$(posts) rows=$(rows); log=$(grep dispatch "$LOG"))"

# ── D6
sc_d6
{ [ "$(posts)" = 0 ] && grep -q 'could not write the dispatch ledger row — no dispatch' "$LOG" && ! grep -q 'SELF-DISPATCH:' "$LOG"; } && ok \
  || bad "D6: an unwritable ledger posts nothing (posts=$(posts); log=$(grep dispatch "$LOG"))"

# ── D7
sc_d7
{ [ "$(posts)" = 1 ] && row | grep -q '^dispatch=refused at=' && [ "$(warns)" = 1 ]; } && ok \
  || bad "D7: refused once, the row says refused, one warn — and the second tick does not retry (posts=$(posts) row=$(row) warns=$(warns))"
{ grep '^--severity warn' "$R/alerts.txt" | grep -q 'by hand' && grep '^--severity warn' "$R/alerts.txt" | grep -q 'gh workflow run harness-ci.yml -R example-org/cromford --ref main'; } && ok \
  || bad "D7: the warn names the manual step: $(cat "$R/alerts.txt")"
grep -q 'SELF-DISPATCH:' "$LOG" && bad "D7: a refused POST was logged as SELF-DISPATCH:" || ok
grep -q "harness-ci.yml dispatch REFUSED: HTTP 422" "$LOG" && ok || bad "D7: the refusal is logged: $(grep dispatch "$LOG")"

# ── D8
hold; mkflag; ( export MAIN_RED_QUEUE_SELF_DISPATCH_MIN=0; drive )
{ [ "$(posts)" = 0 ] && [ "$(wfreads)" = 0 ] && [ "$(qdledger)" = 0 ]; } && ok \
  || bad "D8: knob 0 reads and posts nothing (posts=$(posts) reads=$(wfreads) ledger=$(qdledger))"

# ── D9
sc_d1; sed -i 's/^since=.*/since=2026-10-02T09:00:00Z/' "$FLAG"; drive
{ [ "$(posts)" = 2 ] && [ "$(rows)" = 2 ]; } && ok \
  || bad "D9: a new since= is a new episode: a second POST under its own row (posts=$(posts) rows=$(rows))"

# ── D10
hold; mkflag; drive --explain
{ [ "$(posts)" = 0 ] && [ "$(rows)" = 0 ] && ! grep -q '^put main_red_qdispatch' "$R/ledger.txt" \
  && grep -q "WOULD SELF-DISPATCH $SLUG harness-ci.yml on main — queue freeze held 61 min, main's newest push run is green" "$LOG"; } && ok \
  || bad "D10: --explain writes and posts nothing (posts=$(posts) rows=$(rows); log=$(grep -i dispatch "$LOG"))"

# ── D11
hold; mkflag raised=6; ROWS="lib.main-red-detector.main_red_queue_self_dispatch_min=5"
( export MAIN_RED_QUEUE_SELF_DISPATCH_MIN=60; drive )
[ "$(posts)" = 1 ] && ok || bad "D11: row 5 beats env 60 at 6 min (posts=$(posts); log=$(grep -e knobs -e dispatch "$LOG"))"
hold; mkflag raised=6
( export MAIN_RED_QUEUE_SELF_DISPATCH_MIN=60; drive )
[ "$(posts)" = 0 ] && ok || bad "D11-inverse: env 60 with no row at 6 min posts nothing (posts=$(posts))"

# ── D12 / D13 — the same-sha still-red call site
samesha; mkflag sha="$(rebased 36969794399 head_sha)"; drive
{ [ "$(posts)" = 1 ] && grep -q 'still red' "$LOG"; } && ok \
  || bad "D12: the same-sha still-red path dispatches (posts=$(posts); log=$(tail -3 "$LOG"))"
samesha; mkflag sha="$(rebased 36969794399 head_sha)" reason=streak; drive
{ [ "$(posts)" = 0 ] && [ "$(wfreads)" = 0 ] && grep -q 'still red' "$LOG"; } && ok \
  || bad "D13: a reason=streak flag never dispatches (posts=$(posts) reads=$(wfreads))"
# D13b: both call sites already check reason=queue, so the lib's own gate is
# pinned by calling it directly — the one case here that does not go through
# the detector, with every other gate open (aged, row absent, push green).
direct() { # direct — mrqd_self_dispatch on $FLAG, sourced the way the detector sources it
  ( export PATH="$R/fakebin:$PATH" PAGES GH_SINK="$R/gh.txt" SEQ_SINK="$R/seq.txt" LEDGER_DIR="$R/ledger" LEDGER_LOG="$R/ledger.txt"
    log() { echo "$*" >> "$LOG"; }; alert() { echo "$*" >> "$R/alerts.txt"; }; STAMP() { echo "2026-10-02 00:00:00Z"; }
    . "$R/bin/jobs-client.sh"; . "$TLIB"
    EXPLAIN=0 MR_QUEUE_SELF_DISPATCH_MIN=60; mrqd_self_dispatch "$SLUG" "$FLAG" ) 2>>"$R/err.txt"
}
reset; wfpage "$CUT3"; mkflag reason=streak; direct
D13B=$(posts); sed -i 's/^reason=.*/reason=queue/' "$FLAG"; direct
[ "$D13B" = 0 ] && [ "$(posts)" = 1 ] && ok \
  || bad "D13b: called directly, the streak flag posts nothing and the same flag as queue posts once (streak posts=$D13B, then queue posts=$(posts); err=$(cat "$R/err.txt"))"

# ── D14
hold; mkflag raised=- detected=61; drive
[ "$(posts)" = 1 ] && grep -q 'queue freeze held 61 min' "$LOG" && ok \
  || bad "D14: a flag with no raised= ages from detected= (posts=$(posts); log=$(grep dispatch "$LOG"))"

# ── D15
hold; mkflag since=-; drive
{ [ "$(posts)" = 0 ] && [ "$(rows)" = 0 ] && grep -q "self-dispatch: $SLUG flag has no since= — no episode key, no dispatch" "$LOG"; } && ok \
  || bad "D15: no since= posts nothing (posts=$(posts) rows=$(rows); log=$(grep dispatch "$LOG"))"

# ── D16
hold; mkflag path=.github/workflows/other-ci.yml; drive
{ grep -qx "api -X POST repos/$SLUG/actions/workflows/other-ci.yml/dispatches -f ref=main" "$R/gh.txt" \
  && grep -q "actions/workflows/other-ci.yml/runs" "$R/gh.txt" && ! grep -q 'harness-ci.yml' "$R/gh.txt"; } && ok \
  || bad "D16: the workflow is path='s basename: $(grep workflows "$R/gh.txt")"

# ── Mutations of the real lib: each one must turn its case red.
mutate() { # mutate <label> <sed-expr>
  sed -E "$2" "$LIB" > "$TLIB"
  cmp -s "$LIB" "$TLIB" && { bad "$1: the mutation did not apply ($2)"; return 1; }
  return 0
}
restore() { cp "$LIB" "$TLIB"; }
if mutate M2 's/(— not again"); return 0/\1/'; then
  sc_d2; [ "$(posts)" = 2 ] && ok || bad "M2: without the ledger-present return D2 must post twice (posts=$(posts))"
fi; restore
if mutate M3 's/\[ "\$held" -ge "\$min" \]/true/'; then
  sc_d3; [ "$(posts)" = 1 ] && ok || bad "M3: without the age gate D3 must post (posts=$(posts))"
fi; restore
if mutate M4 's/\[ "\$c" = success \]/true/'; then
  sc_d4; [ "$(posts)" = 1 ] && ok || bad "M4: without the success test D4 must post (posts=$(posts))"
fi; restore
if mutate M6 's/(a dispatch that cannot be recorded could repeat\)"); return 0/\1/'; then
  sc_d6; [ "$(posts)" = 1 ] && ok || bad "M6: without the write-failure return D6 must post (posts=$(posts))"
fi; restore
if mutate M7 's/(— not again"); return 0/\1/'; then
  sc_d7; { [ "$(posts)" = 2 ] && [ "$(warns)" = 2 ]; } && ok \
    || bad "M7: without the row's stop the second tick must POST and warn again (posts=$(posts) warns=$(warns))"
fi; restore
cmp -s "$LIB" "$TLIB" && ok || bad "the real lib is restored after the mutations"

echo "main-red-queue-self-dispatch.bh-3886: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
