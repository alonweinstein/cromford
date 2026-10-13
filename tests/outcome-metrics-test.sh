#!/bin/bash
# tests/outcome-metrics-test.sh — SDLC 7: the outcome detectors, driven.
#
# bin/outcome-metrics.sh is the only lane in the fleet that measures whether a
# merge HELD, and its whole value is that the three answers are objective. So
# the three detectors are exercised against fixtures with their near-misses
# beside them — a revert that predates the merge, a revert touching other files,
# a reopen dated before the merge, a PR whose checks are green. A detector that
# fires on everything is as useless as one that never fires, and only the pairs
# below can tell those apart.
#
# NO LIVE CALLS: curl (the harness-jobs worker) and gh (GitHub) are both stubs
# fed from JSON fixtures, and every gh invocation is recorded so the test can
# assert the run is READ-ONLY — the standing constraint is that this lane
# detects and reports and never reverts, reopens, closes or merges anything.
#
# Fixtures use invented repos and tickets on purpose (Acme/widget-os, WD-nn):
# no client name belongs in a test file.
#
# Run from anywhere: tests/outcome-metrics-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-3223: scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
export JOBS_URL=https://jobs.invalid
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }
BASE="$T"

iso() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ; }
ymd() { date -u -d "$1 days ago" +%Y%m%d 2>/dev/null || date -u -v-"$1"d +%Y%m%d; }

T="$BASE/h"
mkdir -p "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fix" "$T/stub" "$T/builds"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T" || exit 1  # BH-1510.2: lanes read models from model_routes
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"
cat > "$T/fleet.conf" <<'EOF'
widget-os  Acme/widget-os   https://os.widget.example  /api/board  2 box-widget
gadget-os  Acme/gadget-os   https://os.gadget.example  /api/board  4 box-gadget
EOF
export FLEET_CONF="$T/fleet.conf"
export GH_SINK="$T/gh-calls.log"; : > "$GH_SINK"
export FIX="$T/fix"
export PATH="$T/stub:$PATH"

printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"; chmod +x "$T/stub/flock"

# ── curl stub: the harness-jobs worker, in _jobs_req's exact wire shape ──────
cat > "$T/stub/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
case "${CURL_MODE:-ok}" in down) exit 7 ;; esac
body='{}'; code=404
case "$URL" in
  */api/ledger\?kind=merge*) body=$(cat "$FIX/ledger.json"); code=200 ;;
  */api/verdict\?pr=*)
    N=$(printf '%s' "$URL" | grep -oE '[0-9]+$')
    if [ -f "$FIX/verdict-$N.json" ]; then body=$(cat "$FIX/verdict-$N.json"); code=200
    else body='{"error":"no job has recorded this PR"}'; code=404; fi ;;
esac
printf '%s\n%s\n' "$body" "$code"
EOF
chmod +x "$T/stub/curl"

# ── gh stub: reads fixtures, records argv, and refuses to be a writer ────────
cat > "$T/stub/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
JQ=""; A=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jq|-q) JQ="$2"; shift 2 ;;
    --json)  shift 2 ;;
    *) A+=("$1"); shift ;;
  esac
done
SUB="${A[0]:-}"; P="${A[1]:-}"
[ -n "${GH_FAIL_REPO:-}" ] && case "$P" in *"$GH_FAIL_REPO"*) exit 1 ;; esac
flat() { printf '%s' "$1" | tr '/' '_'; }
OUT=""
case "$SUB" in
  api)
    case "$P" in
      repos/*/commits\?since=*)
        R=${P#repos/}; R=${R%%/commits*}; OUT=$(cat "$FIX/commits-$(flat "$R").json" 2>/dev/null) ;;
      repos/*/commits/*/check-runs)
        S=${P%/check-runs}; S=${S##*/}; OUT=$(cat "$FIX/checkruns-$S.json" 2>/dev/null || echo '{"check_runs":[]}') ;;
      repos/*/commits/*)
        S=${P##*/}; OUT=$(cat "$FIX/commitfiles-$S.json" 2>/dev/null || echo '{"files":[]}') ;;
      repos/*/pulls/*/files*)
        R=${P#repos/}; R=${R%%/pulls/*}; N=${P#*/pulls/}; N=${N%%/*}
        OUT=$(cat "$FIX/prfiles-$(flat "$R")-$N.json" 2>/dev/null || echo '[]') ;;
      *) OUT='{}' ;;
    esac ;;
  pr)
    case "${A[1]:-}" in
      view)
        N=$(printf '%s' "${A[2]:-}" | grep -oE '[0-9]+$')
        OUT='{"mergeCommit":{"oid":"'"$(cat "$FIX/mergeoid-$N" 2>/dev/null)"'"}}' ;;
      *)    echo "gh WRITE attempted: $*" >&2; exit 90 ;;
    esac ;;
  *) echo "gh WRITE attempted: $*" >&2; exit 90 ;;
esac
[ -z "$OUT" ] && exit 1
if [ -n "$JQ" ]; then printf '%s' "$OUT" | jq -r "$JQ"; else printf '%s' "$OUT"; fi
EOF
chmod +x "$T/stub/gh"

# ── Fixtures ────────────────────────────────────────────────────────────────
# Five merged PRs on Acme/widget-os, one on Acme/gadget-os:
#   11 reverted (file overlap)     12 revert predates the merge -> clean
#   13 revert touches other files -> clean                       14 reopened
#   15 merged_then_red             21 (gadget) clean
M11=$(iso 6); M12=$(iso 6); M13=$(iso 5); M14=$(iso 4); M15=$(iso 3); M21=$(iso 2)
cat > "$FIX/ledger.json" <<EOF
{"ledgers":[
 {"key":"https://github.com/Acme/widget-os/pull/11","status":"merged","job_id":"b-11","updated_at":"$M11"},
 {"key":"https://github.com/Acme/widget-os/pull/12","status":"merged","job_id":"b-12","updated_at":"$M12"},
 {"key":"https://github.com/Acme/widget-os/pull/13","status":"merged","job_id":"b-13","updated_at":"$M13"},
 {"key":"https://github.com/Acme/widget-os/pull/14","status":"merged","job_id":"b-14","updated_at":"$M14"},
 {"key":"https://github.com/Acme/widget-os/pull/15","status":"merged","job_id":"b-15","updated_at":"$M15"},
 {"key":"https://github.com/Acme/gadget-os/pull/21","status":"merged","job_id":"b-21","updated_at":"$M21"},
 {"key":"https://github.com/Acme/widget-os/pull/99","status":"parked","job_id":"b-99","updated_at":"$M21"}
]}
EOF
# The 5th argument is the build's repair count (SDLC item 3); omitted on PR 14,
# which is what a build from before the count existed looks like to this lane.
verdict() { # verdict <n> <project> <ticket> <merge-sha> [repairs]
  cat > "$FIX/verdict-$1.json" <<EOF
{"pr":"https://github.com/$2/pull/$1","job_id":"b-$1","verdict":"APPROVE","tier":1,
 "merge_sha":"$4"${5:+,\"repairs\":$5},"job":{"id":"b-$1","project":"$2","ticket_id":"$3"}}
EOF
}
verdict 11 widget-os WD-11 aaaa111111111111111111111111111111111111 2
verdict 12 widget-os WD-12 bbbb222222222222222222222222222222222222
verdict 13 widget-os WD-13 cccc333333333333333333333333333333333333
verdict 14 widget-os WD-14 dddd444444444444444444444444444444444444
verdict 15 widget-os WD-15 eeee555555555555555555555555555555555555 0
verdict 21 gadget-os GD-21 ffff666666666666666666666666666666666666
# The verdict fixtures are keyed by PR number; the project field above is the
# harness project name, which is what the reopen test joins on.
for N in 11 12 13 14 15; do
  python3 - "$FIX/verdict-$N.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["pr"]="https://github.com/Acme/widget-os/pull/%s" % p.rsplit("-",1)[1].split(".")[0]
json.dump(d,open(p,"w"))
PY
done

R_AFTER=$(iso 1); R_BEFORE=$(iso 9)
cat > "$FIX/commits-Acme_widget-os.json" <<EOF
[
 {"sha":"revert1111111111111111111111111111111111","commit":{"message":"Revert \"widgets: rework the pricing panel\"\n\nBroke checkout.","committer":{"date":"$R_AFTER"}}},
 {"sha":"revert2222222222222222222222222222222222","commit":{"message":"Revert \"ancient change\"","committer":{"date":"$R_BEFORE"}}},
 {"sha":"feat3333333333333333333333333333333333333","commit":{"message":"widgets: add a thing","committer":{"date":"$R_AFTER"}}}
]
EOF
echo '[]' > "$FIX/commits-Acme_gadget-os.json"
# revert1 undoes src/app/pricing/panel.tsx -> overlaps PR 11 only.
cat > "$FIX/commitfiles-revert1111111111111111111111111111111111.json" <<'EOF'
{"files":[{"filename":"src/app/pricing/panel.tsx"},{"filename":"src/app/pricing/panel.test.ts"}]}
EOF
cat > "$FIX/commitfiles-revert2222222222222222222222222222222222.json" <<'EOF'
{"files":[{"filename":"src/app/legacy/old.tsx"}]}
EOF
pf() { printf '%s' "$2" > "$FIX/prfiles-Acme_widget-os-$1.json"; }
pf 11 '[{"filename":"src/app/pricing/panel.tsx"},{"filename":"src/app/pricing/rate.ts"}]'
pf 12 '[{"filename":"src/app/legacy/old.tsx"}]'
pf 13 '[{"filename":"src/lib/mailer/send.ts"}]'
pf 14 '[{"filename":"src/app/tasks/board.tsx"}]'
pf 15 '[{"filename":"scripts/migrations/2026-08-01-x.sql"}]'
printf '%s' '[{"filename":"src/app/x.tsx"}]' > "$FIX/prfiles-Acme_gadget-os-21.json"
# What `gh pr view` answers when the ledger has no merge sha (degraded mode).
printf '%s' aaaa111111111111111111111111111111111111 > "$FIX/mergeoid-11"
printf '%s' dddd444444444444444444444444444444444444 > "$FIX/mergeoid-14"
printf '%s' eeee555555555555555555555555555555555555 > "$FIX/mergeoid-15"
# Only PR 15's merge commit went red.
echo '{"check_runs":[{"name":"harness-ci","conclusion":"failure"},{"name":"build","conclusion":"success"}]}' \
  > "$FIX/checkruns-eeee555555555555555555555555555555555555.json"
# The board reopen: WD-14 regressed AFTER its merge; WD-13 regressed BEFORE its.
{ echo "date,project,key,from,to"
  echo "$(ymd 2),widget-os,WD-14,review,in_progress"
  echo "$(ymd 20),widget-os,WD-13,done,in_progress"
} > "$T/logs/reopens.csv"

run() { env HARNESS="$T" "$@" bash "$DIR/bin/outcome-metrics.sh"; }

# ── 1. The happy path: three findings, one per detector, and no others ──────
OUT=$(run); RC=$?
[ "$RC" = 0 ] && ok || bad "clean run exited $RC"
CSV="$T/logs/outcome-metrics.csv"; FL="$T/logs/findings.log"
[ -s "$CSV" ] && ok || bad "no outcome-metrics.csv written"
head -1 "$CSV" | grep -qx 'date,repo,pr,outcome,evidence,repairs' && ok || bad "CSV header wrong: $(head -1 "$CSV")"

grep -q ',reverted,' "$CSV" && grep -q 'pull/11' "$CSV" && ok || bad "PR 11 (file-overlap revert) not detected"
grep -qE 'pull/12,reverted' "$CSV" && bad "a revert PREDATING the merge was counted" || ok
grep -qE 'pull/13,reverted' "$CSV" && bad "a revert touching unrelated files was counted" || ok
grep -q 'pull/14,reopened' "$CSV" && ok || bad "the board reopen on WD-14 was not detected"
grep -qE 'pull/13,reopened' "$CSV" && bad "a reopen dated BEFORE the merge was counted" || ok
grep -q 'pull/15,merged_then_red' "$CSV" && ok || bad "merged-then-red main was not detected"
grep -q 'pull/21' "$CSV" && bad "a clean PR produced a finding" || ok
grep -q 'pull/99' "$CSV" && bad "a PARKED ledger row was treated as a merge" || ok
[ "$(tail -n +2 "$CSV" | wc -l | tr -d ' ')" = 3 ] && ok || bad "expected exactly 3 rollup rows, got $(tail -n +2 "$CSV" | wc -l)"

# ── 2. The findings.log rows are in rule-miner's input format ────────────────
[ "$(grep -c 'lens=outcome' "$FL")" = 3 ] && ok || bad "expected 3 findings.log rows, got $(grep -c 'lens=outcome' "$FL" 2>/dev/null)"
grep -q 'lens=outcome' "$FL" && grep -qE 'family=[0-9a-f]{12} :: ' "$FL" && ok \
  || bad "findings row is missing a family key immediately before the :: separator"
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}Z \[widget-os\] ticket=WD-1' "$FL" && ok \
  || bad "findings row does not start with <stamp> [<project>] ticket=<key>"
grep -q 'outcome=reverted' "$FL" && ok || bad "the outcome class is not a parseable field"
# family= must stay the LAST field before ::, the anchor every consumer keys on
awk -F' :: ' '/lens=outcome/ {n=split($1,a," "); if (a[n] !~ /^family=/) bad=1} END {exit bad+0}' "$FL" \
  && ok || bad "family= is not the last field before ::"

# ── 3. The family groups by CLASS+AREA, which is what lets a pattern recur ──
F11=$(grep 'pull/11' "$FL" | grep -oE 'family=[0-9a-f]+' | head -1)
F15=$(grep 'pull/15' "$FL" | grep -oE 'family=[0-9a-f]+' | head -1)
[ -n "$F11" ] && [ "$F11" != "$F15" ] && ok || bad "two different outcome classes share a family key"

# ── 4. Idempotent: a second run in the same window writes nothing new ───────
B_CSV=$(wc -l < "$CSV"); B_FL=$(wc -l < "$FL")
run >/dev/null 2>&1
[ "$(wc -l < "$CSV")" = "$B_CSV" ] && [ "$(wc -l < "$FL")" = "$B_FL" ] && ok \
  || bad "a second run duplicated findings (csv $B_CSV -> $(wc -l < "$CSV"))"

# ── 5. Resumable: the cursor records the highest PR scanned per repo ────────
grep -qE '^Acme/widget-os'$'\t''15' "$T/state/outcome-metrics.state" && ok \
  || bad "no per-repo cursor for Acme/widget-os: $(cat "$T/state/outcome-metrics.state")"
grep -qE '^Acme/gadget-os'$'\t''21' "$T/state/outcome-metrics.state" && ok \
  || bad "no per-repo cursor for Acme/gadget-os"

# ── 6. A settled PR outside the recheck window is not re-examined ───────────
# PR 11 merged 6 days ago; with RECHECK=1 it is settled and below the cursor.
: > "$GH_SINK"
run env OUTCOME_RECHECK_DAYS=1 >/dev/null 2>&1
grep -q 'pulls/11/files' "$GH_SINK" && bad "a settled PR below the cursor was re-fetched" || ok
# ...but with the default 7-day recheck it IS re-examined, because that is when
# reverts and reopens actually arrive.
: > "$GH_SINK"
run >/dev/null 2>&1
grep -q 'pulls/11/files' "$GH_SINK" && ok || bad "a PR inside the recheck window was skipped"

# ── 7. READ-ONLY: nothing in the run can revert, reopen, close or merge ─────
grep -qE 'pr (merge|close|reopen|edit)|issue (reopen|close)|-X (POST|PATCH|PUT|DELETE)|--method (POST|PATCH|PUT|DELETE)|git (revert|push)' "$GH_SINK" \
  && bad "the run issued a mutating GitHub call: $(grep -E 'merge|reopen|POST' "$GH_SINK" | head -1)" || ok

# ── 8. Fail-quiet per repo: one repo's GitHub dying costs only its evidence ─
T2="$BASE/h2"; cp -r "$T" "$T2"; rm -f "$T2/logs/outcome-metrics.csv" "$T2/logs/findings.log" \
  "$T2/state/outcome-metrics-seen.txt" "$T2/state/outcome-metrics.state" "$T2/logs/ALERTS.log"
OUT=$(env HARNESS="$T2" GH_FAIL_REPO="widget-os" bash "$DIR/bin/outcome-metrics.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "a single failing repo failed the whole run (rc=$RC)"
# The board reopen is LOCAL evidence — it survives GitHub being unreachable.
grep -q 'pull/14,reopened' "$T2/logs/outcome-metrics.csv" 2>/dev/null && ok \
  || bad "local reopen evidence was lost when one repo's GitHub reads failed"
grep -q 'reverted' "$T2/logs/outcome-metrics.csv" 2>/dev/null && bad "revert evidence invented while gh was down" || ok
[ -s "$T2/logs/ALERTS.log" ] && bad "one failing repo raised an ALERT (should be a log line)" || ok

# ── 9. Whole-run failure: exactly ONE alert, naming what is needed ──────────
T3="$BASE/h3"; mkdir -p "$T3/logs" "$T3/state" "$T3/flags" "$T3/locks" "$T3/env"
cp "$T/env/global.env" "$T3/env/"
env HARNESS="$T3" CURL_MODE=down bash "$DIR/bin/outcome-metrics.sh" >/dev/null 2>&1; RC=$?
[ "$RC" != 0 ] && ok || bad "a run that measured nothing exited 0"
[ "$(grep -c '\[outcome-metrics\]' "$T3/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "expected exactly one ALERTS line, got $(grep -c '\[outcome-metrics\]' "$T3/logs/ALERTS.log" 2>/dev/null)"
grep -q 'UNMEASURED' "$T3/logs/ALERTS.log" && ok || bad "the alert does not say the week is unmeasured"
env HARNESS="$T3" CURL_MODE=down bash "$DIR/bin/outcome-metrics.sh" >/dev/null 2>&1
[ "$(grep -c '\[outcome-metrics\]' "$T3/logs/ALERTS.log")" = 1 ] && ok \
  || bad "a second failed run the same day wrote a second ALERTS line"

# ── 10. Kill switch + dry run ───────────────────────────────────────────────
T4="$BASE/h4"; cp -r "$T" "$T4"; rm -f "$T4/logs/outcome-metrics.csv" \
  "$T4/state/outcome-metrics-seen.txt" "$T4/state/outcome-metrics.state"
touch "$T4/flags/outcome-metrics-disabled"
env HARNESS="$T4" bash "$DIR/bin/outcome-metrics.sh" >/dev/null 2>&1
[ -f "$T4/logs/outcome-metrics.csv" ] && bad "the kill switch did not stop the run" || ok
rm -f "$T4/flags/outcome-metrics-disabled"
env HARNESS="$T4" OUTCOME_DRY=1 bash "$DIR/bin/outcome-metrics.sh" >/dev/null 2>&1
[ -s "$T4/logs/outcome-metrics.csv" ] && bad "OUTCOME_DRY=1 wrote the rollup CSV" || ok
[ -s "$T4/state/outcome-metrics-seen.txt" ] && bad "OUTCOME_DRY=1 burned the seen file" || ok

# ── 11. Degraded mode: no ledger, only state/merge-sweep-done.txt ───────────
# That file carries no merge TIME, so the two detectors whose whole claim is
# "after the merge" must stand down rather than guess an ordering.
T6="$BASE/h6"; cp -r "$T" "$T6"
rm -f "$T6/logs/outcome-metrics.csv" "$T6/logs/findings.log" \
      "$T6/state/outcome-metrics-seen.txt" "$T6/state/outcome-metrics.state"
printf '%s\n' "https://github.com/Acme/widget-os/pull/11" \
               "https://github.com/Acme/widget-os/pull/14" \
               "https://github.com/Acme/widget-os/pull/15" > "$T6/state/merge-sweep-done.txt"
env HARNESS="$T6" CURL_MODE=down bash "$DIR/bin/outcome-metrics.sh" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "the file-fallback list did not carry the run (rc=$RC)"
grep -q 'source=file' "$T6/logs/outcome-metrics.log" && ok || bad "the run did not record the degraded source"
grep -q 'reverted' "$T6/logs/outcome-metrics.csv" 2>/dev/null \
  && bad "circumstantial file-overlap revert was attributed with no merge time" || ok
grep -q 'reopened' "$T6/logs/outcome-metrics.csv" 2>/dev/null \
  && bad "a reopen was attributed to a PR with no known merge time" || ok
# The merge commit's OWN checks still stand: that evidence carries its ordering,
# and the sha comes from gh because the ledger could not be reached.
grep -q 'pull/15,merged_then_red' "$T6/logs/outcome-metrics.csv" 2>/dev/null && ok \
  || bad "merged-then-red must still fire without a merge time (csv: $(cat "$T6/logs/outcome-metrics.csv" 2>/dev/null))"
[ "$(tail -n +2 "$T6/logs/outcome-metrics.csv" | wc -l | tr -d ' ')" = 1 ] && ok \
  || bad "degraded mode produced more than the one finding it can honestly stand behind"

# ── 12. The loop actually closes: rule-miner mines an outcome family ────────
# The point of the whole lane. PROMOTE_MIN=1 so one occurrence is enough to
# prove the miner PARSES and BUNDLES these rows; the 3-in-30-days threshold
# itself is tests/rule-miner-findings-test.sh's subject, not this one's.
T5="$BASE/h5"; mkdir -p "$T5/logs" "$T5/state/rule-mining" "$T5/flags" "$T5/env" "$T5/locks"
model_routes_fixture "$T5" || exit 1  # BH-1510.2: this root runs a converted lane too
cp "$T/logs/findings.log" "$T5/logs/findings.log"
MOUT=$(env HARNESS="$T5" RULE_MINER_DRY=1 PROMOTE_MIN=1 FLEET_CONF="$T/fleet.conf" \
        bash "$DIR/bin/rule-miner.sh" 2>/dev/null)
FAM=$(printf '%s' "$F11" | cut -d= -f2)
grep -q "findings:$FAM" <<<"$MOUT" && ok \
  || bad "rule-miner did not mine the outcome family $FAM (out: $(head -c 400 <<<"$MOUT"))"
B=$(grep -rl "outcome reverted" "$T5/state/rule-mining" 2>/dev/null | head -1)
[ -n "$B" ] && grep -q 'TYPE: recurring-finding' "$B" && ok \
  || bad "the mined bundle carries no outcome occurrence as evidence"
# ...and the dry miner must not have written findings through its own feed call
[ "$(grep -c 'lens=outcome' "$T5/logs/findings.log")" = 3 ] && ok \
  || bad "RULE_MINER_DRY=1 let the feed call write new findings rows"

# ── 13. The repair count rides from the build's verdict onto the outcome ────
# SDLC item 3. This lane never re-derives the count — it copies what the BUILD
# recorded — so the question "do the builds that had to be fixed twice get
# reverted" is one query instead of a join across a ledger and a box's disk.
# The evidence column is quoted free text with commas of its own, so the count
# is read as the LAST field of the row rather than by counting commas. The CR
# goes first: python's csv.writer ends a data row CRLF, so anything anchored on
# the end of one has to say so.
last_field() { grep "$1" "$CSV" | tr -d '\r' | sed 's/.*,//'; }
[ "$(last_field 'pull/11,reverted')" = 2 ] && ok \
  || bad "the repair count did not reach the reverted row: $(grep 'pull/11' "$CSV")"
[ "$(last_field 'pull/15,merged_then_red')" = 0 ] && ok \
  || bad "a measured-and-clean build must record 0, not '-': $(grep 'pull/15' "$CSV")"
# PR 14's ledger row predates the count: "-", never 0. A build nobody measured
# is not a build that was never repaired.
[ "$(last_field 'pull/14,reopened')" = "-" ] && ok \
  || bad "an unmeasured PR must report '-' in the repairs column: $(grep 'pull/14' "$CSV")"
grep -q 'repairs=2 family=' "$FL" && ok \
  || bad "the findings row does not carry repairs= before family=: $(grep 'pull/11' "$FL")"
# ONE grep, not `grep file | grep -q`: grep -q exits at the first match and
# SIGPIPEs the upstream file-grep, which pipefail turns into a random red.
# tests/rollup-crash-loud-test.sh sweeps for that shape. repairs= is emitted
# before family=, so it always precedes the PR URL in the row's text.
grep -qE 'repairs=[0-9]+ .*pull/14' "$FL" \
  && bad "an unmeasured PR wrote a repairs= field: $(grep 'pull/14' "$FL")" || ok
# family= must STILL be the last field before ::, with the new field in front.
awk -F' :: ' '/lens=outcome/ {n=split($1,a," "); if (a[n] !~ /^family=/) bad=1} END {exit bad+0}' "$FL" \
  && ok || bad "repairs= displaced family= from the last field before ::"

# A CSV written before the column existed is upgraded in place, once, and its
# old rows stay readable (python's DictReader reports repairs=None for them).
T7="$BASE/h7"; cp -r "$T" "$T7"
rm -f "$T7/state/outcome-metrics-seen.txt" "$T7/state/outcome-metrics.state" "$T7/logs/findings.log"
{ echo "date,repo,pr,outcome,evidence"
  echo "2026-08-01,Acme/widget-os,https://github.com/Acme/widget-os/pull/2,reverted,old row"
} > "$T7/logs/outcome-metrics.csv"
env HARNESS="$T7" bash "$DIR/bin/outcome-metrics.sh" >/dev/null 2>&1
head -1 "$T7/logs/outcome-metrics.csv" | grep -qx 'date,repo,pr,outcome,evidence,repairs' \
  && ok || bad "the header of an existing CSV was not upgraded: $(head -1 "$T7/logs/outcome-metrics.csv")"
grep -q 'pull/2,reverted,old row' "$T7/logs/outcome-metrics.csv" \
  && ok || bad "the header upgrade rewrote or dropped an existing row"
OLDCOUNT=$(python3 -c 'import csv,sys
rows = list(csv.DictReader(open(sys.argv[1])))
print(sum(1 for r in rows if r.get("repairs") in (None, "")))' "$T7/logs/outcome-metrics.csv")
[ "${OLDCOUNT:-0}" -gt 0 ] && ok || bad "an old row did not read back as an unmeasured repairs value"

echo "outcome-metrics-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
