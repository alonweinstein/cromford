#!/bin/bash
# tests/pr-state-rehydrate-test.sh — mc_rows_rehydrate: an EMPTY pr-state.tsv is
# rebuilt from the D1 `ledgers` rows the conductor has been writing all along.
#
# WHY THIS EXISTS (BH-435). state/merge-conductor/pr-state.tsv is per-box, and
# every transition is already mirrored to D1 as kind=pr_state (mc_ledger_put).
# Rebuild the hub and the file comes back empty while the table is full: every
# `since` restarts at now, every `alerted` mark is gone, and the first tick
# re-alerts every closed-unmerged PR the old box had already paged about. The
# rows are right there; nothing read them back.
#
# WHY DRIVEN AND NOT GREPPED. The claim is about a SIDE EFFECT ORDER — the file
# is rebuilt inside mc_init, before the tick classifies anything, and only if it
# is still empty under the same flock mc_row_put takes. So the real
# bin/merge-conductor.sh runs against a stubbed worker and the assertions read
# pr-state.tsv, logs/ALERTS.log and the recorded requests. The headline case is
# an alert that must NOT fire: tests/merge-conductor-test.sh:427 proves this
# same fixture pages for issuer#7 when D1 answers nothing.
# Run from anywhere: tests/pr-state-rehydrate-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-3223: scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
export JOBS_URL=https://jobs.invalid
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The clock is read ONCE (the determinism lint's pin). Every stamp this suite
# COMPARES is absolute: the two below, and the epochs jq derives from them.
NOW=$(date -u +%s)
IS7_ISO=2026-09-12T01:00:00Z
IS7_EPOCH=1789174800            # `date -u -d 2026-09-12T01:00:00Z +%s`
BULK_EPOCH=1789174800           # the bulk pages count DOWN from here

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" \
         "$T/h/builds" "$T/h/env" "$T/fakebin" "$T/pages"
# TEST-CHANGE (BH-782): bin/lib/gh-pr-list.sh reads REST through the contract
# lib now. Without gh-rest.sh beside it every REST list answers 75 "no contract
# lib on this box" and the all-mappable closed-PR list never happens.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\nissuer example-org/issuer - - 3 box-issuer\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/sh\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
# Observe mode: this suite is about a READ, and a tick that merged would be
# testing something else entirely.
touch "$T/h/flags/merge-conductor-observe"

H1=aaaaaaaa1111; H2=bbbbbbbb2222
mkdir -p "$T/h/builds/demo-os-TK-11-202609120001"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/11" > "$T/h/builds/demo-os-TK-11-202609120001/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/demo-os-TK-11-202609120001/review.md"
echo "$H1" > "$T/h/builds/demo-os-TK-11-202609120001/reviewed-sha"

# gh shim — tests/merge-conductor-test.sh §3's, which is what makes issuer#7 a
# closed-unmerged PR with an OPEN issue: the one that alerts.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none" from a real read (not a fallback on an unreadable probe).
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*)
    echo "WRITE VERB IN OBSERVE MODE: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<'J'
[{"number":11,"url":"https://github.com/example-org/demo-os/pull/11","headRefOid":"$H1","headRefName":"ticket/TK-11","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]
J
    ;;
  *"repos/example-org/demo-os/pulls?state=closed"*) printf 'HTTP/2.0 200\r\n\r\n[]\n' ;;
  *"pr list -R example-org/issuer --state open"*) echo "[]" ;;
  # TEST-CHANGE (BH-782): the CLOSED list is all-mappable, so it is a REST read
  # (bin/lib/gh-rest.sh) and a REST failure is no longer retried over
  # a GraphQL pr list. The shim answers the REST path with a status line and a
  # REST-shaped body; the open list still carries GraphQL-only fields
  # (mergeStateStatus/mergeable/isInMergeQueue) and is unchanged.
  *"repos/example-org/issuer/pulls?state=closed"*)
    printf 'HTTP/2.0 200\r\n\r\n'
    cat <<'JR'
[{"number":7,"html_url":"https://github.com/example-org/issuer/pull/7","title":"IS-7","body":"","state":"closed","merged_at":null,"closed_at":"2026-09-12T01:00:00Z","created_at":"2026-09-11T00:00:00Z","updated_at":"2026-09-12T01:00:00Z","draft":false,"labels":[],"user":{"login":"operator","type":"User"},"head":{"ref":"ticket/is-7","sha":"deadbe7"},"base":{"ref":"main"}}]
JR
    ;;
  *"issue view 7"*) echo "OPEN" ;;
  # TEST-CHANGE (BH-1592): the closed-unmerged pass reads its candidates by
  # number now, not through the raw closed list above.
  *"api -i -X GET repos/example-org/issuer/pulls/7")
    printf 'HTTP/2.0 200\r\n\r\n{"number":7,"state":"closed","merged_at":null,"head":{"ref":"ticket/is-7","sha":"deadbe7"},"base":{"ref":"main"}}\n' ;;
  *"actions/runs?head_sha=$H1"*) printf 'completed|success\ncompleted|success\n' ;;
  *"actions/runs?head_sha=$H2"*) printf 'in_progress|\n' ;;
  *"pr view"*"--json body"*) echo "plain body" ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

# curl shim. GET /api/ledger?kind=pr_state serves $PAGE_DIR/page.<n>.json —
# page 1 when there is no cursor, page 2 when there is one. PRE_FILL_ROW is B5's
# race: a row lands in the TSV between the fetch and the lock.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET; BODY=""
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in down) exit 7 ;; esac
case "$M $URL" in
  "GET "*/api/ledger?kind=pr_state*)
    [ -n "${PRE_FILL_ROW:-}" ] && [ -n "${MC_TSV:-}" ] && printf '%s\n' "$PRE_FILL_ROW" >> "$MC_TSV"
    case "$URL" in
      *before=*) PG="${PAGE_DIR:-/nonexistent}/page.2.json" ;;
      *)         PG="${PAGE_DIR:-/nonexistent}/page.1.json" ;;
    esac
    if [ -s "$PG" ]; then cat "$PG"; printf '\n200\n'
    else printf '{"ledgers":[],"as_of":"2026-09-17T00:00:00Z"}\n200\n'; fi ;;
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

MCDIR="$T/h/state/merge-conductor"
TSV="$MCDIR/pr-state.tsv"
export PAGE_DIR="$T/pages" MC_TSV="$TSV"
run_tick() {
  local rc
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
      REQ_SINK="$T/req.txt" PAGE_DIR="$T/pages" MC_TSV="$TSV" \
      "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" )
  rc=$?
  [ "$rc" = 0 ] || { echo "tick rc=$rc stderr:"; cat "$T/tick.err"; }
  return "$rc"
}
mcreset() {
  scratch_rm "$MCDIR"; scratch_rm "$T/h/logs"
  mkdir -p "$MCDIR" "$T/h/logs"
  rm -f "$T/req.txt" "$T/gh-calls.txt" "$T/gh-writes.txt" "$T/pages/page.1.json" "$T/pages/page.2.json"
  unset PRE_FILL_ROW
}
row_of()   { awk -F'\t' -v k="$1" '$1==k {print; exit}' "$TSV" 2>/dev/null; }
n_ledger_get() { grep -c 'GET [^ ]*/api/ledger?kind=pr_state' "$T/req.txt" 2>/dev/null || true; }
mclog()    { cat "$T/h/logs/merge-conductor.log" 2>/dev/null; }
alerts()   { cat "$T/h/logs/ALERTS.log" 2>/dev/null; }
# An ALERTS.log that was never created is zero alerts, not an empty string: a
# bare `grep -c` on a missing file prints nothing and the comparison below would
# then fail on the very outcome this suite wants.
n_alert()  { local n; n=$(grep -c "$1" "$T/h/logs/ALERTS.log" 2>/dev/null); printf '%s' "${n:-0}"; }

# A ledger row the way the worker stores it: `detail` is a TEXT column holding
# the JSON mc_ledger_put wrote, so it is a STRING here, not an object.
lrow() { # lrow <key> <status> <updated_at> <detail-json-or-literal>
  jq -nc --arg k "$1" --arg s "$2" --arg u "$3" --arg d "$4" \
    '{kind:"pr_state",key:$k,status:$s,actor:"hub",updated_at:$u,created_at:$u,detail:$d}'
}
page() { # page <n>  <<< one JSON row per line
  jq -sc '{ledgers: ., as_of: "2026-09-17T00:00:00Z"}' > "$T/pages/page.$1.json"
}

IS7_DETAIL=$(jq -nc --arg s "$IS7_ISO" --arg a "CLOSED@$IS7_EPOCH" \
  '{since:$s,head_sha:"-",reviewed_sha:"-",verdict:"-",merge_state:"-",
    reason:"closed-unmerged-issue-open",record:"-",
    url:"https://github.com/example-org/issuer/pull/7",alerted:$a}')
# PR 11's row is stamped just before this run so the tick's own ageing/budget
# logic sees a fresh READY, exactly as it would on a box that never went away.
D11_SINCE_EPOCH=$((NOW - 60))
D11_SINCE=$(date -u -d "@$D11_SINCE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')
D11_DETAIL=$(jq -nc --arg s "$D11_SINCE" --arg h "$H1" \
  '{since:$s,head_sha:$h,reviewed_sha:$h,verdict:"APPROVE",merge_state:"CLEAN",
    reason:"approved at head",record:"-",
    url:"https://github.com/example-org/demo-os/pull/11",alerted:"-"}')
seed_two_rows() {
  { lrow 'example-org/issuer#7'   CLOSED "$IS7_ISO"   "$IS7_DETAIL"
    lrow 'example-org/demo-os#11' READY  "$D11_SINCE" "$D11_DETAIL"; } | page 1
}

# ---------- B1. an empty TSV is rebuilt, and the re-alert never fires -------
mcreset
seed_two_rows
: > "$TSV"
run_tick
WANT=$(printf 'example-org/issuer#7\tCLOSED\t%s\t-\t-\tCLOSED@%s\tclosed-unmerged-issue-open\thttps://github.com/example-org/issuer/pull/7' "$IS7_EPOCH" "$IS7_EPOCH")
[ "$(row_of 'example-org/issuer#7')" = "$WANT" ] && ok \
  || bad "the rehydrated row must be the ledger's detail, column for column:
 want: $WANT
 got : $(row_of 'example-org/issuer#7')"
[ "$(awk -F'\t' '$1=="example-org/demo-os#11" {print $3; exit}' "$TSV")" = "$D11_SINCE_EPOCH" ] && ok \
  || bad "…and its since is the detail's ISO stamp as an epoch: $(row_of 'example-org/demo-os#11')"
[ "$(n_alert 'issuer#7 CLOSED')" = 0 ] && ok \
  || bad "a restored terminal row must suppress the re-alert (merge-conductor-test.sh:427 proves it fires without one): $(alerts)"
grep -q 'rehydrated 2 pr-state rows from D1 (skipped=0, truncated=false)' <<<"$(mclog)" && ok \
  || bad "the rehydrate must say how many rows it restored: $(grep -i rehydrat <<<"$(mclog)")"
[ -s "$T/gh-writes.txt" ] && bad "observe-only tick used a write verb: $(cat "$T/gh-writes.txt")" || ok
# No new lock file: the write shares mc_row_put's own.
[ "$(cd "$MCDIR" && ls -1 ./*.lock 2>/dev/null | tr -d ' ')" = "./pr-state.tsv.lock" ] && ok \
  || bad "the rehydrate must take mc_row_put's lock, not a new one: $(ls -1 "$MCDIR" | tr '\n' ' ')"

# ---------- B1b. a row whose detail is not JSON is skipped and counted ------
mcreset
{ lrow 'example-org/issuer#7'   CLOSED "$IS7_ISO"   "$IS7_DETAIL"
  lrow 'example-org/demo-os#11' READY  "$D11_SINCE" "$D11_DETAIL"
  lrow 'example-org/demo-os#98' READY  "$D11_SINCE" 'not json'; } | page 1
: > "$TSV"
run_tick
grep -q 'rehydrated 2 pr-state rows from D1 (skipped=1, truncated=false)' <<<"$(mclog)" && ok \
  || bad "an unparsable detail is skipped AND counted, never a malformed row: $(grep -i rehydrat <<<"$(mclog)")"
[ "$(grep -c 'demo-os#98' "$TSV" 2>/dev/null)" = 0 ] && ok \
  || bad "the unparsable row must not reach the TSV: $(grep 'demo-os#98' "$TSV")"

# ---------- B2. a non-empty TSV never asks -----------------------------------
# This is the every-5-minutes case: no request at all.
mcreset
seed_two_rows
printf 'example-org/demo-os#11\tREADY\t%s\t%s\t%s\t-\tseeded\thttps://github.com/example-org/demo-os/pull/11\n' \
  "$D11_SINCE_EPOCH" "$H1" "$H1" > "$TSV"
# TEST-CHANGE (BH-1592): the closed-unmerged pass finds issuer#7 from the
# harness's own records now, not the repo's raw closed list, so for this case
# it has a build record. It is removed right after, so no other case sees it.
mkdir -p "$T/h/builds/issuer-IS-7-202609120001"
echo "PR_CREATED https://github.com/example-org/issuer/pull/7" > "$T/h/builds/issuer-IS-7-202609120001/RESULT"
run_tick
scratch_rm "$T/h/builds/issuer-IS-7-202609120001"
[ "$(n_ledger_get)" = 0 ] && ok || bad "a non-empty pr-state.tsv must cost no request: $(grep 'api/ledger' "$T/req.txt" | head -2)"
[ "$(grep -c 'issuer#7' "$TSV" 2>/dev/null)" -ge 1 ] && ok \
  || bad "…and the tick still does its own work: $(cat "$TSV")"

# B2b. the kill switch
mcreset
seed_two_rows
: > "$TSV"
run_tick env MC_REHYDRATE=0
[ "$(n_ledger_get)" = 0 ] && ok || bad "MC_REHYDRATE=0 must send no request: $(grep 'api/ledger' "$T/req.txt" | head -2)"
[ "$(grep -c "$IS7_EPOCH" "$TSV" 2>/dev/null)" = 0 ] && ok \
  || bad "MC_REHYDRATE=0 must restore nothing: $(row_of 'example-org/issuer#7')"

# ---------- B3. worker down: rc 0, file untouched, one page for the day -----
mcreset
seed_two_rows
: > "$TSV"
run_tick env CURL_MODE=down JOBS_RETRIES=0
RC=$?
[ "$RC" = 0 ] && ok || bad "an outage must not fail the tick (rc=$RC)"
[ "$(grep -c "$IS7_EPOCH" "$TSV" 2>/dev/null)" = 0 ] && ok \
  || bad "a mid-walk outage must write nothing: $(row_of 'example-org/issuer#7')"
grep -q 'pr-state rehydrate: ledger unreachable/empty' <<<"$(mclog)" && ok \
  || bad "…and must say so in the conductor log: $(grep -i rehydrat <<<"$(mclog)")"
[ "$(grep -c 'example-org/demo-os#11' "$TSV" 2>/dev/null)" = 1 ] && ok \
  || bad "the tick itself still ran and wrote its own row: $(cat "$TSV")"
[ "$(n_alert 'harness-jobs unreachable')" = 1 ] && ok \
  || bad "the outage page is jobs-client's existing once-a-day line, once: $(alerts)"

# ---------- B4. pagination, the cursor, and an honest truncated flag --------
mcreset
jq -nc --arg base "$BULK_EPOCH" '
  {ledgers: [range(1000) | (($base|tonumber) - .) as $e |
     {kind:"pr_state", key:("example-org/bulk#"+(.|tostring)), status:"MERGED",
      actor:"hub", updated_at:($e|todate), created_at:($e|todate),
      detail: ({since:($e|todate),head_sha:"-",reviewed_sha:"-",verdict:"-",
                merge_state:"-",reason:"bulk",record:"-",
                url:("https://github.com/example-org/bulk/pull/"+(.|tostring)),
                alerted:"-"}|tojson)}],
   as_of:"2026-09-17T00:00:00Z"}' > "$T/pages/page.1.json"
jq -nc --arg base "$BULK_EPOCH" '
  {ledgers: [range(1000;1003) | (($base|tonumber) - .) as $e |
     {kind:"pr_state", key:("example-org/bulk#"+(.|tostring)), status:"MERGED",
      actor:"hub", updated_at:($e|todate), created_at:($e|todate),
      detail: ({since:($e|todate),head_sha:"-",reviewed_sha:"-",verdict:"-",
                merge_state:"-",reason:"bulk",record:"-",
                url:("https://github.com/example-org/bulk/pull/"+(.|tostring)),
                alerted:"-"}|tojson)}],
   as_of:"2026-09-17T00:00:00Z"}' > "$T/pages/page.2.json"
CURSOR=$(jq -r '.ledgers[-1].updated_at' "$T/pages/page.1.json")
CURSOR_URI=$(jq -nr --arg b "$CURSOR" '$b|@uri')
: > "$TSV"
run_tick
[ "$(n_ledger_get)" = 2 ] && ok || bad "a full page must be followed by a second GET: $(n_ledger_get)"
grep -q "before=$CURSOR_URI" "$T/req.txt" && ok \
  || bad "the cursor is the previous page's last updated_at ($CURSOR): $(grep -o 'api/ledger[^ ]*' "$T/req.txt" | tail -1)"
[ "$(grep -c '^example-org/bulk#' "$TSV" 2>/dev/null)" = 1003 ] && ok \
  || bad "both pages must land: $(grep -c '^example-org/bulk#' "$TSV" 2>/dev/null)"
grep -q 'rehydrated 1003 pr-state rows from D1 (skipped=0, truncated=false)' <<<"$(mclog)" && ok \
  || bad "a walk that reached the end is not truncated: $(grep -i rehydrat <<<"$(mclog)")"

# B4b. the page cap says so rather than pretending it saw everything
mcreset
jq -nc --arg base "$BULK_EPOCH" '
  {ledgers: [range(1000) | (($base|tonumber) - .) as $e |
     {kind:"pr_state", key:("example-org/bulk#"+(.|tostring)), status:"MERGED",
      actor:"hub", updated_at:($e|todate), created_at:($e|todate),
      detail: ({since:($e|todate),head_sha:"-",reviewed_sha:"-",verdict:"-",
                merge_state:"-",reason:"bulk",record:"-",
                url:("https://github.com/example-org/bulk/pull/"+(.|tostring)),
                alerted:"-"}|tojson)}],
   as_of:"2026-09-17T00:00:00Z"}' > "$T/pages/page.1.json"
cp "$T/pages/page.1.json" "$T/pages/page.2.json"
: > "$TSV"
run_tick env MC_REHYDRATE_PAGES=1
[ "$(n_ledger_get)" = 1 ] && ok || bad "MC_REHYDRATE_PAGES=1 must stop after one GET: $(n_ledger_get)"
[ "$(grep -c '^example-org/bulk#' "$TSV" 2>/dev/null)" = 1000 ] && ok \
  || bad "one page of rows: $(grep -c '^example-org/bulk#' "$TSV" 2>/dev/null)"
grep -q 'rehydrated 1000 pr-state rows from D1 (skipped=0, truncated=true)' <<<"$(mclog)" && ok \
  || bad "a capped walk must say truncated=true: $(grep -i rehydrat <<<"$(mclog)")"

# ---------- B5. a TSV filled between the fetch and the lock wins ------------
# The conductor and bin/blocked-resolver.sh both call mc_init on the hub. The
# second one must drop its copy, not overwrite the first one's rows.
mcreset
seed_two_rows
: > "$TSV"
RACE_ROW=$(printf 'example-org/demo-os#99\tREADY\t%s\t%s\t%s\t-\traced\thttps://github.com/example-org/demo-os/pull/99' "$D11_SINCE_EPOCH" "$H1" "$H1")
run_tick env PRE_FILL_ROW="$RACE_ROW"
[ "$(grep -c 'example-org/demo-os#99' "$TSV" 2>/dev/null)" = 1 ] && ok \
  || bad "the row written under the lock first must survive: $(cat "$TSV")"
[ "$(grep -c "$IS7_EPOCH" "$TSV" 2>/dev/null)" = 0 ] && ok \
  || bad "a rehydrate that lost the race must write nothing: $(row_of 'example-org/issuer#7')"

echo "pr-state-rehydrate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
