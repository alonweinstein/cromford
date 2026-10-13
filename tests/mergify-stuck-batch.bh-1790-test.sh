#!/bin/bash
# tests/mergify-stuck-batch.bh-1790-test.sh — BH-1790: the conductor refreshes a
# Mergify batch draft that sits green and unmerged.
#
# THE STALL THIS ENDS (2026-09-23). Mergify three times left a merge-queue batch
# draft (`mergify/merge-queue/*`) with every check green for 18-25 minutes,
# "Waiting for check-success = ..." on two `if: always()` aggregate jobs that had
# passed. It had missed their completion event. `@mergifyio refresh` on the
# DRAFT unstuck it within 2 minutes every time; until then the whole queue sat.
#
# WHAT IS PINNED.
#   §1  a green draft older than MC_MERGIFY_STUCK_SECS gets exactly ONE
#       `@mergifyio refresh`; a second pass adds none (the ticket's first
#       acceptance line). Mergify's own check does not count as "not green".
#   §2  a pending check, a failed check, no checks at all, green for less than
#       the knob, and a PR that is not a batch draft: no refresh.
#   §3  FAIL-SAFE: an unreadable list, an unreadable check-run page (403, 000)
#       and a partial page each refresh nothing and record nothing, so the next
#       readable pass still refreshes.
#   §4  observe (writes=0) says WOULD and records nothing; MC_MERGIFY_STUCK_SECS=0
#       reads nothing at all.
#   §5  THE WINDOW: one refresh per MC_MERGIFY_REFRESH_WINDOW_SECS while the draft
#       stays stuck; 0 = one per (draft, head, green moment) for ever.
#   §6  still stuck MC_MERGIFY_STUCK_ALERT_SECS past a refresh = ONE alert per
#       draft per day.
#   §7  the three knobs are registered, with read_in naming their reader.
#   §8  THE WIRING: two REAL bin/merge-conductor.sh ticks on a Mergify repo post
#       one refresh; the same ticks without the merge flag post none.
#
# The ledger is the conductor's attempts ledger (mc_attempt_put), which has the
# pr_attempts row twin — the DB-backed record the ticket asks for.
# Run from anywhere: tests/mergify-stuck-batch.bh-1790-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
# NOW is the most recent 12:00Z, not the wall clock (BH-2611): the once-per-day
# ticks at NOW+600 and NOW+1200 must never straddle midnight UTC.
NOW=$(( ( $(date -u +%s) - 43200 ) / 86400 * 86400 + 43200 ))

SLUG=example-org/demo-os
B=1751                                   # the batch draft
HB=abababababababababababababababababababab
HT=cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos"
for f in gh-pr-list.sh merge-conductor-lib.sh gh-budget.sh gh-rest.sh gh-rest-var.sh gh-rest-list.sh; do
  cp "$DIR/bin/lib/$f" "$T/h/bin/lib/" || exit 1
done
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/" || exit 1
[ -f "$DIR/bin/lib/mc/queue.sh" ] || exit 1   # impact: this suite runs when bin/lib/mc/queue.sh changes
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$T/h/bin/" || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
: > "$T/h/env/global.env"
printf 'demo-os %s - - 2 box-d\n' "$SLUG" > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
for s in beat.sh deploy-request.sh pre-arm-guards.sh codegraph-ensure.sh deploy-verify.sh prod-url.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "VERDICT: APPROVE\\n" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
chmod +x "$T/h/bin/agent-call.sh"
cat > "$T/h/bin/jobs-client.sh" <<'EOF'
job_verdict_rebind() { return 0; }
job_ledger_put() { return 0; }
EOF

# ── the stub gh ──────────────────────────────────────────────────────────────
# pulls.json is the open list; checks-<sha>.json a head's check-run page;
# listmode / checkmode (200|403|500|000) make a read fail. Every comment POST
# is recorded in posted.txt as "<path> <body>".
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\nSLUG=%s\n' "$T" "$MGFY_YML" "$SLUG"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
answer() { # answer <mode> <file>
  case "$1" in
    000) echo "gh: error connecting to api.github.com" >&2; exit 1 ;;
    200) restpr --raw 200 "$(cat "$2" 2>/dev/null)" ;;
    *)   restpr --raw "$1" '{"message":"stub refusal"}' ;;
  esac
}
case "$*" in
  *"auth token"*) echo faketoken ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"api -i -X GET repos/$SLUG/pulls -f"*|*"api -i -X GET repos/$SLUG/pulls?"*)
    answer "$(cat "$T/listmode" 2>/dev/null || echo 200)" "$T/pulls.json" ;;
  *"api -i -X GET repos/$SLUG/commits/"*"/check-runs"*)
    S=$(sed -n 's|.*/commits/\([0-9a-f]*\)/check-runs.*|\1|p' <<<"$*")
    answer "$(cat "$T/checkmode" 2>/dev/null || echo 200)" "$T/checks-$S.json" ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*)
    P=$(sed -n 's|.*\(repos/[^ ]*/comments\).*|\1|p' <<<"$*")
    BODY=$(sed -n 's|.* body=\(.*\)$|\1|p' <<<"$*")
    printf '%s %s\n' "$P" "$BODY" >> "$T/posted.txt"; exit 0 ;;
  *"api -i -X GET repos/"*"/pulls/"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf '"'"'{"error":"not found"}\\n404\\n'"'"'\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
ST="$T/h/state/merge-conductor"
A="$ST/attempts.txt"
LOG="$T/h/logs/merge-conductor.log"

# ── fixtures ────────────────────────────────────────────────────────────────
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
# pulls <number> <head-ref> <sha> [<number> <head-ref> <sha> ...] — the open list.
pulls() {
  local out='[]'
  while [ $# -ge 3 ]; do
    out=$(jq -c --argjson n "$1" --arg r "$2" --arg s "$3" \
      '. + [{number:$n,html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)),state:"open",draft:true,user:{login:"mergify[bot]",type:"Bot"},head:{ref:$r,sha:$s},base:{ref:"main"},labels:[]}]' <<<"$out")
    shift 3
  done
  printf '%s' "$out" > "$T/pulls.json"
}
# checks <sha> <status|conclusion|age-secs|app-slug> ... — one check run per arg;
# age is how long before NOW it completed. A run whose status is not completed
# carries completed_at null, as GitHub sends it.
checks() {
  local sha="$1" out='[]' st con age app ts; shift
  for c in "$@"; do
    IFS='|' read -r st con age app <<<"$c"
    ts=null; [ "$st" = completed ] && ts="\"$(iso $((NOW - age)))\""
    out=$(jq -c --arg st "$st" --arg con "$con" --argjson ts "$ts" --arg app "${app:-github-actions}" \
      '. + [{name:("job-"+(length|tostring)),status:$st,conclusion:(if $con=="" then null else $con end),completed_at:$ts,app:{slug:$app}}]' <<<"$out")
  done
  jq -c '{total_count:length,check_runs:.}' <<<"$out" > "$T/checks-$sha.json"
}
# A batch draft with every check green, the newest completion 400s ago.
green_stale() { pulls "$B" "mergify/merge-queue/7b1c0a2e" "$HB"
  checks "$HB" 'completed|success|900' 'completed|success|400' 'completed|skipped|600' \
    'in_progress||0|mergify'; }
reset_case() {
  : > "$A"; : > "$LOG"; : > "$T/posted.txt"; : > "$T/alerts.txt"; : > "$T/gh-calls.txt"
  rm -f "$T/listmode" "$T/checkmode" "$T"/checks-*.json
  CLOCK=$NOW
}
mc_now() { printf '%s' "$CLOCK"; }
refreshes() { grep -c "repos/$SLUG/issues/${1:-$B}/comments @mergifyio refresh" "$T/posted.txt" 2>/dev/null || true; }
pass() { mc_mergify_stuck_pass demo-os "$SLUG" "${1:-1}"; }

command -v mc_mergify_stuck_pass >/dev/null 2>&1 || bad "mc_mergify_stuck_pass is not defined by bin/lib/mc/queue.sh"

# ============================================================================
# §1. a green, stale batch draft gets exactly one refresh
# ============================================================================
reset_case; green_stale
pass
[ "$(refreshes)" = 1 ] && ok || bad "§1: one @mergifyio refresh on the stale green draft (posted: $(cat "$T/posted.txt"))"
grep -q "^mergifyrefresh $SLUG#$B $HB " "$A" && ok || bad "§1: the refresh is recorded in the attempts ledger (attempts: $(cat "$A"))"
grep -q "$SLUG#$B MERGIFY_REFRESH" "$LOG" && ok || bad "§1: one log line names the refresh (log: $(cat "$LOG"))"
pass
[ "$(refreshes)" = 1 ] && ok || bad "§1: a second pass adds no refresh (posted: $(cat "$T/posted.txt"))"
CLOCK=$((NOW + 240)); pass
[ "$(refreshes)" = 1 ] && ok || bad "§1: nor a third, 4 minutes later (posted: $(cat "$T/posted.txt"))"

# ============================================================================
# §2. drafts that must NOT be refreshed
# ============================================================================
for c in pending failed none young notbatch cancelled; do
  reset_case
  pulls "$B" "mergify/merge-queue/7b1c0a2e" "$HB"
  case "$c" in
    pending)   checks "$HB" 'completed|success|900' 'in_progress||0' ;;
    failed)    checks "$HB" 'completed|success|900' 'completed|failure|400' ;;
    cancelled) checks "$HB" 'completed|success|900' 'completed|cancelled|400' ;;
    none)      checks "$HB" 'in_progress||0|mergify' ;;
    young)     checks "$HB" 'completed|success|900' 'completed|success|200' ;;
    notbatch)  pulls 12 "ticket/TK-12" "$HT"; checks "$HT" 'completed|success|900' ;;
  esac
  pass
  [ "$(refreshes)" = 0 ] && [ "$(refreshes 12)" = 0 ] && ok || bad "§2 $c: no refresh (posted: $(cat "$T/posted.txt"))"
  grep -q "^mergifyrefresh " "$A" && bad "§2 $c: nothing recorded (attempts: $(cat "$A"))" || ok
done

# ============================================================================
# §3. FAIL-SAFE: a read that cannot be answered refreshes and records nothing
# ============================================================================
for m in list-500 list-000 checks-403 checks-000 partial; do
  reset_case; green_stale
  case "$m" in
    list-500)   echo 500 > "$T/listmode" ;;
    list-000)   echo 000 > "$T/listmode" ;;
    checks-403) echo 403 > "$T/checkmode" ;;
    checks-000) echo 000 > "$T/checkmode" ;;
    partial)    jq -c '.total_count = 250' "$T/checks-$HB.json" > "$T/c.tmp" && mv "$T/c.tmp" "$T/checks-$HB.json" ;;
  esac
  pass
  [ "$(refreshes)" = 0 ] && ok || bad "§3 $m: no refresh on an unreadable answer (posted: $(cat "$T/posted.txt"))"
  grep -q "^mergifyrefresh " "$A" && bad "§3 $m: nothing recorded (attempts: $(cat "$A"))" || ok
  grep -q "UNVERIFIABLE" "$LOG" && ok || bad "§3 $m: the log says the read was unverifiable (log: $(cat "$LOG"))"
  rm -f "$T/listmode" "$T/checkmode"; green_stale
  pass
  [ "$(refreshes)" = 1 ] && ok || bad "§3 $m: the next readable pass still refreshes (posted: $(cat "$T/posted.txt"))"
done

# ============================================================================
# §4. observe mode and the off switch
# ============================================================================
reset_case; green_stale
pass 0
[ "$(refreshes)" = 0 ] && ok || bad "§4: writes=0 posts nothing (posted: $(cat "$T/posted.txt"))"
grep -q "WOULD" "$LOG" && ok || bad "§4: writes=0 logs a WOULD line (log: $(cat "$LOG"))"
grep -q "^mergifyrefresh " "$A" && bad "§4: writes=0 records nothing (attempts: $(cat "$A"))" || ok
pass 1
[ "$(refreshes)" = 1 ] && ok || bad "§4: the refresh is still owed once writes come back (posted: $(cat "$T/posted.txt"))"
reset_case; green_stale
MC_MERGIFY_STUCK_SECS=0 pass
[ "$(refreshes)" = 0 ] && ok || bad "§4: MC_MERGIFY_STUCK_SECS=0 posts nothing"
[ -s "$T/gh-calls.txt" ] && bad "§4: MC_MERGIFY_STUCK_SECS=0 reads nothing (calls: $(cat "$T/gh-calls.txt"))" || ok

# ============================================================================
# §5. the refresh window
# ============================================================================
reset_case; green_stale
MC_MERGIFY_REFRESH_WINDOW_SECS=600 pass
CLOCK=$((NOW + 300)); MC_MERGIFY_REFRESH_WINDOW_SECS=600 pass
[ "$(refreshes)" = 1 ] && ok || bad "§5: inside the window, one refresh (posted: $(cat "$T/posted.txt"))"
CLOCK=$((NOW + 600)); MC_MERGIFY_REFRESH_WINDOW_SECS=600 pass
[ "$(refreshes)" = 2 ] && ok || bad "§5: one more once the window has passed and the draft is still stuck (posted: $(cat "$T/posted.txt"))"
CLOCK=$((NOW + 700)); MC_MERGIFY_REFRESH_WINDOW_SECS=600 pass
[ "$(refreshes)" = 2 ] && ok || bad "§5: and not again inside the new window (posted: $(cat "$T/posted.txt"))"
reset_case; green_stale
MC_MERGIFY_REFRESH_WINDOW_SECS=0 pass
CLOCK=$((NOW + 86400)); MC_MERGIFY_REFRESH_WINDOW_SECS=0 pass
[ "$(refreshes)" = 1 ] && ok || bad "§5: window 0 is one refresh per head for ever (posted: $(cat "$T/posted.txt"))"
# A new head on the same draft number is a new batch: it is owed its own refresh.
pulls "$B" "mergify/merge-queue/7b1c0a2e" "$HT"
checks "$HT" 'completed|success|86800'
MC_MERGIFY_REFRESH_WINDOW_SECS=0 pass
[ "$(refreshes)" = 2 ] && ok || bad "§5: a new head is a new batch (posted: $(cat "$T/posted.txt"))"

# ============================================================================
# §6. still stuck after a refresh: one alert per draft per day
# ============================================================================
reset_case; green_stale
pass
[ -s "$T/alerts.txt" ] && bad "§6: no alert on the tick that refreshed (alerts: $(cat "$T/alerts.txt"))" || ok
CLOCK=$((NOW + 300)); pass
[ -s "$T/alerts.txt" ] && bad "§6: no alert 5 minutes after the refresh (alerts: $(cat "$T/alerts.txt"))" || ok
CLOCK=$((NOW + 600)); pass
[ "$(grep -c "MERGIFY_BATCH_STUCK" "$T/alerts.txt")" = 1 ] && ok || bad "§6: one alert once it is still stuck 10 minutes on (alerts: $(cat "$T/alerts.txt"))"
grep -q "$SLUG#$B" "$T/alerts.txt" && ok || bad "§6: the alert names the draft (alerts: $(cat "$T/alerts.txt"))"
CLOCK=$((NOW + 1200)); pass
[ "$(grep -c "MERGIFY_BATCH_STUCK" "$T/alerts.txt")" = 1 ] && ok || bad "§6: and only one that day (alerts: $(cat "$T/alerts.txt"))"
# No refresh ever posted (observe) = nothing to have failed, so no alert.
reset_case; green_stale
CLOCK=$((NOW + 1200)); pass 0
[ -s "$T/alerts.txt" ] && bad "§6: no alert without a refresh (alerts: $(cat "$T/alerts.txt"))" || ok

# ============================================================================
# §7. the knobs are registered with their reader
# ============================================================================
R="$DIR/catalog/lanes.d/merge-conductor.json"
for k in MC_MERGIFY_STUCK_SECS MC_MERGIFY_REFRESH_WINDOW_SECS MC_MERGIFY_STUCK_ALERT_SECS; do
  [ "$(jq -r --arg k "$k" '.knobs[] | select(.env==$k) | .read_in' "$R")" = bin/lib/mc/queue.sh ] && ok \
    || bad "§7: $k is registered with read_in bin/lib/mc/queue.sh"
  grep -q "$k" "$DIR/bin/lib/mc/queue.sh" && ok || bad "§7: $k is read by bin/lib/mc/queue.sh"
done
[ "$(jq -r '.knobs[] | select(.env=="MC_MERGIFY_STUCK_SECS") | .default' "$R")" = 300 ] && ok \
  || bad "§7: MC_MERGIFY_STUCK_SECS defaults to 300 (the ticket's 5 minutes)"

# ============================================================================
# §8. THE WIRING: real conductor ticks on a Mergify repo
# ============================================================================
tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x MC_REPOS="$T/repos" \
  MC_RR_PATH="$T/fakebin:$PATH" MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 \
  MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MERGE_TREE=0 MC_LAND_REBASE=0 env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
reset_case; green_stale
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
tick; tick
[ "$(refreshes)" = 1 ] && ok || bad "§8: two merge-mode ticks post exactly one refresh (posted: $(cat "$T/posted.txt"); log: $(tail -5 "$LOG"))"
reset_case; green_stale
rm -f "$T/h/flags/merge-conductor-merge"
tick; tick
[ "$(refreshes)" = 0 ] && ok || bad "§8: without the merge flag the ticks post none (posted: $(cat "$T/posted.txt"))"
grep -q "MERGIFY_REFRESH WOULD" "$LOG" && ok || bad "§8: and say what they would do (log: $(tail -5 "$LOG"))"

echo "mergify-stuck-batch.bh-1790: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
