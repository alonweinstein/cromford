#!/bin/bash
# tests/mergify-stuck-batch.bh-1887-test.sh — BH-1887: the four follow-ups from
# the #1885 review of the BH-1790 stuck-batch refresh.
#
# WHAT IS PINNED.
#   §1  REQUIRED SET: a batch draft is green only when every `check-success`
#       name in .mergify.yml's queue_rules has a run on its head and that run
#       is green. A missing one = no refresh, logged. pull_request_rules names,
#       `~=` / `!=` / negated conditions are not required. An unreadable
#       .mergify.yml refreshes nothing. No check-success in queue_rules = the
#       BH-1790 rule. The repo's own .mergify.yml parses to its seven names.
#   §2  OLDEST ONLY: a green batch N+1 behind a pending batch N is refreshed but
#       never alerted; with both green only N alerts.
#   §3  WINDOW FLOOR: MC_MERGIFY_REFRESH_WINDOW_SECS 1-299 reads as 300 (or the
#       conductor tick when that is longer), so the alert can fire; 0 is still
#       one refresh per head; the registry note says so.
#   §4  ATTEMPTED vs POSTED: a failed POST is retried on the next tick in the
#       same window; `mergifyrefresh` (attempted) and `mergifyposted` are
#       separate ledger lines; the alert says the refresh could NOT be posted
#       when it never was.
#   §5  THE WIRING: real bin/merge-conductor.sh ticks do not refresh a draft
#       that lacks a required check, and do once it has it.
#
# The scaffold is tests/mergify-stuck-batch.bh-1790-test.sh's, plus a stub
# .mergify.yml that names required checks and a POST that can fail.
# Run from anywhere: tests/mergify-stuck-batch.bh-1887-test.sh   (exit 0 = all pass)
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
B=1751                                   # the batch draft (the oldest)
B2=1752                                  # a newer batch draft behind it
HB=abababababababababababababababababababab
H2=efefefefefefefefefefefefefefefefefefefef
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
# listmode / checkmode / ymlmode (200|403|500|000) make a read fail;
# mergify.yml is the repo's .mergify.yml, served base64 as the contents API
# serves it. Every comment POST is logged in post-tries.txt as "<path> <body>";
# postmode fail makes it exit 1 as gh does on a 403, and only a POST that
# returned 0 lands in posted.txt.
{ printf '#!/bin/bash\nT=%s\nSLUG=%s\n' "$T" "$SLUG"; cat <<'SHIM'
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
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*)
    M=$(cat "$T/ymlmode" 2>/dev/null || echo 200)
    if [ "$M" = 200 ]; then restpr --raw 200 "{\"content\":\"$(base64 < "$T/mergify.yml" | tr -d '\n')\"}"
    else answer "$M" /dev/null; fi ;;
  *"api -i -X GET repos/$SLUG/pulls -f"*|*"api -i -X GET repos/$SLUG/pulls?"*)
    answer "$(cat "$T/listmode" 2>/dev/null || echo 200)" "$T/pulls.json" ;;
  *"api -i -X GET repos/$SLUG/commits/"*"/check-runs"*)
    S=$(sed -n 's|.*/commits/\([0-9a-f]*\)/check-runs.*|\1|p' <<<"$*")
    answer "$(cat "$T/checkmode" 2>/dev/null || echo 200)" "$T/checks-$S.json" ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*)
    P=$(sed -n 's|.*\(repos/[^ ]*/comments\).*|\1|p' <<<"$*")
    BODY=$(sed -n 's|.* body=\(.*\)$|\1|p' <<<"$*")
    printf '%s %s\n' "$P" "$BODY" >> "$T/post-tries.txt"
    [ "$(cat "$T/postmode" 2>/dev/null || echo 200)" = 200 ] || { echo "HTTP 403: Resource not accessible" >&2; exit 1; }
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
# checks <sha> <status|conclusion|age-secs|app-slug|name> ... — one check run per
# arg; name defaults to job-<index>, which is what the stub yml requires;
# age is how long before NOW it completed. A run whose status is not completed
# carries completed_at null, as GitHub sends it.
checks() {
  local sha="$1" out='[]' st con age app name ts; shift
  for c in "$@"; do
    IFS='|' read -r st con age app name <<<"$c"
    ts=null; [ "$st" = completed ] && ts="\"$(iso $((NOW - age)))\""
    out=$(jq -c --arg st "$st" --arg con "$con" --argjson ts "$ts" --arg app "${app:-github-actions}" --arg nm "${name:-}" \
      '. + [{name:(if $nm=="" then "job-"+(length|tostring) else $nm end),status:$st,conclusion:(if $con=="" then null else $con end),completed_at:$ts,app:{slug:$app}}]' <<<"$out")
  done
  jq -c '{total_count:length,check_runs:.}' <<<"$out" > "$T/checks-$sha.json"
}
# The stub .mergify.yml: queue_rules require job-0 and job-1 (in the spellings
# Mergify accepts), plus a regex and a negated condition that must NOT count;
# pull_request_rules name lint-extra, which is not a queue condition.
REQ_YML='# a comment at column 0
merge_queue:
  max_parallel_checks: 8
queue_rules:
  - name: hotfix
    queue_conditions:
      - base = main
      - check-success = "job-0"
# a column-0 comment inside the block does not end it
    merge_conditions:
      - check-success=job-1   # bare, with a comment
      - check-success~=^shard-
      - check-success!=never-a
      - -check-success = never-b
      - check-success-or-neutral = never-c
  - name: default
    merge_conditions:
      - "check-success = job-0"
      - check-success = '"'"'job-1'"'"'
pull_request_rules:
  - name: automerge
    conditions:
      - check-success = "lint-extra"
'
# A batch draft with job-0 and job-1 green (and one more), the newest
# completion 400s ago.
green_stale() { pulls "$B" "mergify/merge-queue/7b1c0a2e" "$HB"
  checks "$HB" 'completed|success|900' 'completed|success|400' 'completed|skipped|600' \
    'in_progress||0|mergify'; }
reset_case() {
  : > "$A"; : > "$LOG"; : > "$T/posted.txt"; : > "$T/post-tries.txt"; : > "$T/alerts.txt"; : > "$T/gh-calls.txt"
  rm -f "$T/listmode" "$T/checkmode" "$T/ymlmode" "$T/postmode" "$T"/checks-*.json
  printf '%s' "$REQ_YML" > "$T/mergify.yml"
  CLOCK=$NOW
}
mc_now() { printf '%s' "$CLOCK"; }
tries() { grep -c "repos/$SLUG/issues/${1:-$B}/comments @mergifyio refresh" "$T/post-tries.txt" 2>/dev/null || true; }
stuck_alerts() { grep -c "MERGIFY_BATCH_STUCK" "$T/alerts.txt" 2>/dev/null || true; }
refreshes() { grep -c "repos/$SLUG/issues/${1:-$B}/comments @mergifyio refresh" "$T/posted.txt" 2>/dev/null || true; }
pass() { mc_mergify_stuck_pass demo-os "$SLUG" "${1:-1}"; }

command -v mc_mergify_stuck_pass >/dev/null 2>&1 || bad "mc_mergify_stuck_pass is not defined by bin/lib/mc/queue.sh"

# ============================================================================
# §1. the required set from .mergify.yml's queue_rules
# ============================================================================
# §1a: job-1 (required) has no run; the runs that ARE there are all green.
reset_case; pulls "$B" "mergify/merge-queue/7b1c0a2e" "$HB"
checks "$HB" 'completed|success|900' 'completed|success|400|github-actions|other-job' 'in_progress||0|mergify'
pass
[ "$(tries)" = 0 ] && ok || bad "§1a: no refresh while required job-1 has no run (tried: $(cat "$T/post-tries.txt"))"
grep -q "^mergifyrefresh " "$A" && bad "§1a: nothing recorded (attempts: $(cat "$A"))" || ok
grep -q "$SLUG#$B MERGIFY_REFRESH: batch draft ${HB:0:8} has no run for required check(s) job-1 " "$LOG" && ok \
  || bad "§1a: the log names the missing required check (log: $(cat "$LOG"))"
# ... and once job-1 turns up green, the refresh goes.
checks "$HB" 'completed|success|900' 'completed|success|400' 'in_progress||0|mergify'
pass
[ "$(refreshes)" = 1 ] && ok || bad "§1a: once job-1 is there and green, one refresh (posted: $(cat "$T/posted.txt"))"

# §1b: every required check present and green (plus the pull_request_rules one).
reset_case; pulls "$B" "mergify/merge-queue/7b1c0a2e" "$HB"
checks "$HB" 'completed|success|900' 'completed|success|400' 'completed|success|500|github-actions|lint-extra'
pass
[ "$(refreshes)" = 1 ] && ok || bad "§1b: all required green = one refresh (posted: $(cat "$T/posted.txt"))"

# §1c: a pull_request_rules check-success (lint-extra) is not required, nor are
# the ~=, != and negated names.
reset_case; green_stale
pass
[ "$(refreshes)" = 1 ] && ok || bad "§1c: lint-extra / never-* are not required (posted: $(cat "$T/posted.txt"); log: $(cat "$LOG"))"
REQ=$(mc_mergify_required_checks "$SLUG"); rc=$?
[ "$rc" = 0 ] && [ "$REQ" = "$(printf 'job-0\njob-1')" ] && ok \
  || bad "§1c: the required set is exactly job-0, job-1 (rc=$rc, got: $(tr '\n' ',' <<<"$REQ"))"

# §1d: .mergify.yml cannot be read: nothing is refreshed or recorded.
for m in 403 000; do
  reset_case; green_stale; echo "$m" > "$T/ymlmode"
  pass
  [ "$(tries)" = 0 ] && ok || bad "§1d $m: an unreadable .mergify.yml refreshes nothing (tried: $(cat "$T/post-tries.txt"))"
  grep -q "^mergifyrefresh " "$A" && bad "§1d $m: nothing recorded (attempts: $(cat "$A"))" || ok
  grep -q "MERGIFY_REFRESH: .mergify.yml UNVERIFIABLE" "$LOG" && ok || bad "§1d $m: the log says UNVERIFIABLE (log: $(cat "$LOG"))"
  mc_mergify_required_checks "$SLUG" >/dev/null; rc=$?
  [ "$rc" = 75 ] && ok || bad "§1d $m: mc_mergify_required_checks answers 75, not an empty set (rc=$rc)"
done

# §1e: no check-success in queue_rules = the BH-1790 rule (every present run green).
reset_case; printf 'queue_rules:\n  - name: default\n    merge_method: squash\npull_request_rules:\n  - conditions:\n      - check-success = lint-extra\n' > "$T/mergify.yml"
pulls "$B" "mergify/merge-queue/7b1c0a2e" "$HB"
checks "$HB" 'completed|success|900|github-actions|anything' 'completed|success|400|github-actions|else'
pass
[ "$(refreshes)" = 1 ] && ok || bad "§1e: no required names = the BH-1790 rule (posted: $(cat "$T/posted.txt"); log: $(cat "$LOG"))"

# §1f: the repo's own .mergify.yml (quoted names with spaces, an em dash, two
# queues repeating the same list) parses to its seven distinct names.
reset_case; cp "$DIR/.mergify.yml" "$T/mergify.yml"
REQ=$(mc_mergify_required_checks "$SLUG"); rc=$?
# BH-3348: minus lead-verdict, a commit status on the PR head that a batch
# draft never carries (mc_mergify_required_checks skips it).
WANT=$(sed -n '/^queue_rules:/,/^[a-z_]*:/p' "$DIR/.mergify.yml" | sed -n 's/.*check-success = "\(.*\)"$/\1/p' | grep -vx lead-verdict | awk '!s[$0]++')
[ "$rc" = 0 ] && [ -n "$WANT" ] && [ "$REQ" = "$WANT" ] && ok \
  || bad "§1f: the repo's .mergify.yml parses to its required names (rc=$rc, got: $REQ; want: $WANT)"
[ "$(grep -c . <<<"$REQ")" = 7 ] && ok || bad "§1f: seven names (got: $(grep -c . <<<"$REQ"))"
grep -qx "Mission Control SPA — unit tests + build" <<<"$REQ" && ok || bad "§1f: a name with an em dash survives intact"

# ============================================================================
# §2. only the OLDEST open batch draft alerts
# ============================================================================
# §2a: #1751 pending, #1752 green and stale behind it.
reset_case
pulls "$B" "mergify/merge-queue/aaaa" "$HB" "$B2" "mergify/merge-queue/bbbb" "$H2"
checks "$HB" 'completed|success|900' 'in_progress||0'
checks "$H2" 'completed|success|900' 'completed|success|400'
for d in 0 300 600 1200; do CLOCK=$((NOW + d)); pass; done
[ "$(refreshes "$B2")" = 1 ] && ok || bad "§2a: the newer green draft is still refreshed once (posted: $(cat "$T/posted.txt"))"
[ "$(refreshes "$B")" = 0 ] && ok || bad "§2a: the pending draft is not refreshed"
[ "$(stuck_alerts)" = 0 ] && ok || bad "§2a: no MERGIFY_BATCH_STUCK for a draft that is not the oldest (alerts: $(cat "$T/alerts.txt"))"

# §2b: both green and stale: only the oldest alerts, once.
reset_case
pulls "$B2" "mergify/merge-queue/bbbb" "$H2" "$B" "mergify/merge-queue/aaaa" "$HB"
checks "$HB" 'completed|success|900' 'completed|success|400'
checks "$H2" 'completed|success|900' 'completed|success|400'
for d in 0 300 600 1200; do CLOCK=$((NOW + d)); pass; done
[ "$(refreshes "$B")" = 1 ] && [ "$(refreshes "$B2")" = 1 ] && ok || bad "§2b: both drafts refreshed once (posted: $(cat "$T/posted.txt"))"
[ "$(stuck_alerts)" = 1 ] && grep -q "$SLUG#$B " "$T/alerts.txt" && ! grep -q "$SLUG#$B2" "$T/alerts.txt" && ok \
  || bad "§2b: exactly one alert, naming the oldest draft #$B (alerts: $(cat "$T/alerts.txt"))"

# ============================================================================
# §3. the window floor
# ============================================================================
# §3a: a 60s window reads as 300: one refresh per 300s slot, and the alert fires.
reset_case; green_stale
for d in 0 60 300 360 600; do CLOCK=$((NOW + d)); MC_MERGIFY_REFRESH_WINDOW_SECS=60 pass; done
[ "$(refreshes)" = 3 ] && ok || bad "§3a: window 60 = one refresh per 300s slot, 3 by +600 (posted: $(cat "$T/posted.txt"))"
[ "$(stuck_alerts)" = 1 ] && ok || bad "§3a: window 60 no longer silences the alert (alerts: $(cat "$T/alerts.txt"))"
# §3a': a conductor tick longer than 300 raises the floor to the tick.
reset_case; green_stale
for d in 0 300; do CLOCK=$((NOW + d)); MC_TICK_SECS=600 MC_MERGIFY_REFRESH_WINDOW_SECS=60 pass; done
[ "$(refreshes)" = 1 ] && ok || bad "§3a': with MC_TICK_SECS=600 the floor is 600 (posted: $(cat "$T/posted.txt"))"
# §3b: 0 keeps its meaning: one refresh per head for ever.
reset_case; green_stale
for d in 0 300 3600 86400; do CLOCK=$((NOW + d)); MC_MERGIFY_REFRESH_WINDOW_SECS=0 pass; done
[ "$(refreshes)" = 1 ] && ok || bad "§3b: window 0 is still one refresh per head (posted: $(cat "$T/posted.txt"))"
# §3c: the registry says so.
R="$DIR/catalog/lanes.d/merge-conductor.json"
jq -r '.knobs[] | select(.env=="MC_MERGIFY_REFRESH_WINDOW_SECS") | .note' "$R" | grep -q "300" && ok \
  || bad "§3c: the MC_MERGIFY_REFRESH_WINDOW_SECS note states the 300 floor"

# ============================================================================
# §4. attempted vs posted
# ============================================================================
# §4a/b: the POST fails, then works on the next tick inside the same window.
reset_case; green_stale; echo fail > "$T/postmode"
pass
[ "$(tries)" = 1 ] && [ "$(refreshes)" = 0 ] && ok || bad "§4a: the first POST was tried and failed (tried: $(cat "$T/post-tries.txt"))"
grep -q "could NOT post @mergifyio refresh .* the next tick retries" "$LOG" && ok || bad "§4a: the failure log says the next tick retries (log: $(cat "$LOG"))"
[ "$(grep -c "^mergifyrefresh $SLUG#$B " "$A")" = 1 ] && ok || bad "§4b: the attempt is recorded (attempts: $(cat "$A"))"
grep -q "^mergifyposted " "$A" && bad "§4b: a failed POST records no mergifyposted (attempts: $(cat "$A"))" || ok
rm -f "$T/postmode"
CLOCK=$((NOW + 300)); pass
[ "$(refreshes)" = 1 ] && ok || bad "§4a: the next tick, same window, retries and posts (tried: $(cat "$T/post-tries.txt"))"
[ "$(grep -c "^mergifyrefresh $SLUG#$B " "$A")" = 1 ] && ok || bad "§4b: the retry adds no second attempted line (attempts: $(cat "$A"))"
grep -q "^mergifyposted $SLUG#$B $HB " "$A" && ok || bad "§4b: the POST that worked is recorded as mergifyposted (attempts: $(cat "$A"))"
CLOCK=$((NOW + 400)); pass
[ "$(tries)" = 2 ] && ok || bad "§4b: once posted, no third POST in the window (tried: $(cat "$T/post-tries.txt"))"

# §4c: the POST fails every tick: one try per tick, and the alert says it was never posted.
reset_case; green_stale; echo fail > "$T/postmode"
for d in 0 300 600; do CLOCK=$((NOW + d)); pass; done
[ "$(tries)" = 3 ] && ok || bad "§4c: one POST try per tick while it fails (tried: $(cat "$T/post-tries.txt"))"
[ "$(stuck_alerts)" = 1 ] && ok || bad "§4c: one alert (alerts: $(cat "$T/alerts.txt"))"
grep -q "could NOT be posted" "$T/alerts.txt" && ok || bad "§4c: the alert says the refresh could NOT be posted (alerts: $(cat "$T/alerts.txt"))"
grep -q "after @mergifyio refresh" "$T/alerts.txt" && bad "§4c: the alert does not claim a refresh was posted (alerts: $(cat "$T/alerts.txt"))" || ok

# §4d: the POST worked: the alert keeps the posted wording.
reset_case; green_stale
for d in 0 300 600; do CLOCK=$((NOW + d)); pass; done
[ "$(stuck_alerts)" = 1 ] && grep -q "after @mergifyio refresh" "$T/alerts.txt" && ! grep -q "could NOT" "$T/alerts.txt" && ok \
  || bad "§4d: a posted refresh keeps 'after @mergifyio refresh' (alerts: $(cat "$T/alerts.txt"))"

# ============================================================================
# §5. THE WIRING: real conductor ticks honour the required set
# ============================================================================
tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x MC_REPOS="$T/repos" \
  MC_RR_PATH="$T/fakebin:$PATH" MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 \
  MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MERGE_TREE=0 MC_LAND_REBASE=0 env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
reset_case; pulls "$B" "mergify/merge-queue/7b1c0a2e" "$HB"
checks "$HB" 'completed|success|900' 'completed|success|400|github-actions|other-job'
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
tick; tick
[ "$(tries)" = 0 ] && ok || bad "§5: two merge-mode ticks do not refresh a draft missing required job-1 (tried: $(cat "$T/post-tries.txt"); log: $(tail -5 "$LOG"))"
grep -q "no run for required check(s) job-1" "$LOG" && ok || bad "§5: the tick logs the missing check (log: $(tail -5 "$LOG"))"
checks "$HB" 'completed|success|900' 'completed|success|400'
tick
[ "$(refreshes)" = 1 ] && ok || bad "§5: once job-1 is green the tick refreshes once (posted: $(cat "$T/posted.txt"); log: $(tail -5 "$LOG"))"

echo "mergify-stuck-batch.bh-1887: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
