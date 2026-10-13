#!/bin/bash
# BH-2457 — the review-prs D1 hold is time-limited, and a box that lost its
# HARNESS_SECRET holds instead of paying.
#
# BH-2315 made review-prs HOLD (buy nothing) while the D1 verdict ledger cannot
# be read. Held forever, that is a lane that reviews nothing for as long as the
# worker is down. So after REVIEW_D1_HOLD_MAX_H hours of one outage the lane
# falls back to the runners bin/billing-mode.sh calls `subscription` on this
# box (metered and unknown are never in the list), with the call-guard's
# metered refusal pinned on. The fallback start is one ALERTS line and one beat
# per outage, not per tick.
#
# And `jobs_configured` judges on JOBS_URL alone: an UNSET JOBS_URL defaults to
# the fleet worker, so a missing secret there is "configured but unreadable"
# (hold), never "no worker here" (pay).
#
# Every case drives the REAL bin/review-prs.sh with `gh`, `agent-call`,
# `beat.sh` and `billing-mode.sh` stubbed, and a jobs client that sources the
# REAL bin/lib/jobs/req.sh. It counts the one thing that costs money: how many
# times agent-call.sh ran, and with which runner list.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RP="$DIR/bin/review-prs.sh"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

REAL_JQ=$(command -v jq)
export REAL_JQ TEST_ROOT="$T"
HOLDF="$T/h/state/project-1.review-d1-hold"

mkdir -p "$T/fakebin"

# One open PR by default (#7); GH_PRS=two lists #7 then #8. No review of either
# head exists on GitHub, and there is no CI run list.
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
if [ "${1:-}" = pr ] && [ "${2:-}" = list ]; then
  printf '7\thead7aaaaaaa\texternaldev\tChange under review\n'
  if [ "${GH_PRS:-one}" = two ]; then printf '8\thead8ccccccc\texternaldev\tSecond change\n'; fi
elif [ "${1:-}" = api ] && [[ "$*" == */pulls/*/reviews* ]]; then
  Q=""; prev=""
  for a in "$@"; do [ "$prev" = "-q" ] && Q="$a"; prev="$a"; done
  printf '[]' | "$REAL_JQ" -r "${Q:-.}"
elif [ "${1:-}" = api ]; then
  :
elif [ "${1:-}" = pr ] && [ "${2:-}" = diff ]; then
  if [[ "$*" == *--name-only* ]]; then printf 'lib/pricing.ts\n'
  else printf 'diff --git a/a.ts b/a.ts\n+const changed = true\n'; fi
elif [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  printf '\n'
fi
STUB

# The fake agent-call records the runner restriction and the K3 metered switch
# it was handed: the fallback IS those two variables.
cat > "$T/fakebin/agent-call" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/agent-calls.log"
printf 'runners=%s metered=%s fp=%s\n' "${AGENT_CALL_RUNNERS-<unset>}" \
  "${CALL_GUARD_FAIL_CLOSED_METERED-<unset>}" "${AGENT_CALL_FP:-}" >> "$TEST_ROOT/agent-env.log"
printf 'Static review.\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > "$5"
printf 'claude\n' > "$5.runner"
STUB

# billing-mode.sh answers from BM_<runner>; an unset one is `unknown`, the
# script's own answer for a runner it cannot classify.
cat > "$T/fakebin/billing-mode" <<'STUB'
#!/bin/bash
v="BM_${1:-}"
printf '%s\n' "${!v:-unknown}"
STUB
chmod +x "$T/fakebin/gh" "$T/fakebin/agent-call" "$T/fakebin/billing-mode"

# The jobs client: the REAL transport module (so jobs_configured is the shipped
# function, not a mirror) and a job_verdict driven by JOBS_RC / JOBS_VERDICT,
# per PR through JOBS_RC_<n> / JOBS_VERDICT_<n>.
cat > "$T/jobs-client.sh" <<STUB
#!/bin/bash
JOBS_HARNESS="\${HARNESS:-$T/h}"
. "$DIR/bin/lib/jobs/req.sh"
STUB
cat >> "$T/jobs-client.sh" <<'STUB'
job_verdict() {
  local n="${1##*/}" rv vv
  rv="JOBS_RC_$n"; vv="JOBS_VERDICT_$n"
  local rc="${!rv:-${JOBS_RC:-2}}" row="${!vv:-${JOBS_VERDICT:-}}"
  [ -n "$row" ] || return "$rc"
  printf '%s' "$row"
  return "$rc"
}
STUB

. "$DIR/tests/lib/model-route-stub.sh" || exit 1
fresh_harness() {
  scratch_rm "$T/h" || return 1
  rm -f "$T/agent-calls.log" "$T/agent-env.log" "$T/beats.log"
  mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/locks" "$T/h/env" "$T/h/builds"
  cp "$T/fakebin/agent-call" "$T/h/bin/agent-call.sh"
  cp "$T/fakebin/billing-mode" "$T/h/bin/billing-mode.sh"
  cp "$DIR/bin/lib/review-model.sh" "$T/h/bin/lib/"
  mrs_fixture "$T/h" project-1
  cp "$DIR/bin/lib/e2e-paths.sh" "$T/h/bin/lib/"
  cp "$DIR/bin/alert-line.sh" "$T/h/bin/"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$TEST_ROOT/beats.log"\nexit 0\n' > "$T/h/bin/beat.sh"
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/deploy-request.sh"
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/merge-queue.sh"
  chmod +x "$T/h/bin/beat.sh" "$T/h/bin/deploy-request.sh" "$T/h/bin/merge-queue.sh"
  cp "$T/jobs-client.sh" "$T/h/bin/jobs-client.sh"
  printf '{}\n' > "$T/h/state/project-1.pr-reviews.json"
}

# Defaults: D1 unreadable on a fully configured box, claude on its subscription.
reset_env() {
  JOBS_URL_MODE=set; SECRET_MODE=set; JOBS_RC=1; JOBS_VERDICT=""; GH_PRS=one
  BM_claude=subscription; BM_codex=metered; BM_grok=metered; BM_gemini=unknown
  MAXH=6; ACR=""; unset JOBS_RC_8 JOBS_VERDICT_8
}
RC=0
run_lane() { # sets RC
  # env takes every -u before the first assignment, so the two are built apart.
  local u=(-u AGENT_CALL_RUNNERS -u CALL_GUARD_FAIL_CLOSED_METERED -u REVIEW_D1_HOLD_MAX_H) a=()
  case "$JOBS_URL_MODE" in
    set) a+=(JOBS_URL=https://jobs.example.test) ;;
    empty) a+=(JOBS_URL=) ;;
    unset) u+=(-u JOBS_URL) ;;
  esac
  if [ "$SECRET_MODE" = set ]; then a+=(HARNESS_SECRET=FIXTURE-secret); else u+=(-u HARNESS_SECRET); fi
  [ "$MAXH" = "<unset>" ] || a+=(REVIEW_D1_HOLD_MAX_H="$MAXH")
  [ -z "$ACR" ] || a+=(AGENT_CALL_RUNNERS="$ACR")
  env "${u[@]}" "${a[@]}" PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$DIR/fleet.conf" \
    GH_PRS="$GH_PRS" JOBS_RC="$JOBS_RC" JOBS_VERDICT="$JOBS_VERDICT" \
    JOBS_RC_8="${JOBS_RC_8:-}" JOBS_VERDICT_8="${JOBS_VERDICT_8:-}" \
    BM_claude="$BM_claude" BM_codex="$BM_codex" BM_grok="$BM_grok" BM_gemini="$BM_gemini" \
    bash "$RP" project-1 >"$T/lane.out" 2>&1
  RC=$?
}
calls() { if [ -f "$T/agent-calls.log" ]; then wc -l < "$T/agent-calls.log"; else echo 0; fi; }
nlines() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
seed_age() { printf '%s\n' "$(( $(date +%s) - $1 ))" > "$HOLDF"; }

# ── H1 — the first held tick starts the clock; 5h59m is still held ─────────
reset_env; fresh_harness
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "H1 a first held tick bought a review: $(calls) call(s)"
now=$(date +%s); since=$(cat "$HOLDF" 2>/dev/null)
case "$since" in ''|*[!0-9]*) bad "H1 the first held tick wrote no clock: '${since}'" ;;
  *) [ $((now - since)) -ge 0 ] && [ $((now - since)) -le 60 ] && ok || bad "H1 the clock is not ~now: $since vs $now" ;; esac
[ "$(nlines 'NOT reviewed this tick' "$T/h/logs/pr-reviews.log")" -eq 1 ] && ok || bad "H1 expected one held line: $(cat "$T/h/logs/pr-reviews.log" 2>/dev/null)"
seed_age $((6 * 3600 - 60))
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "H1 held 5h59m with N=6 bought a review: $(calls)"
grep -q 'review-d1-fallback' "$T/beats.log" 2>/dev/null && bad "H1 fell back before N hours" || ok

# ── H2 — past N hours: one call, subscription runners only, one alert ──────
reset_env; fresh_harness
seed_age $((7 * 3600))
run_lane
[ "$(calls)" -eq 1 ] && ok || bad "H2 held 7h with N=6 did not fall back: $(calls) call(s), expected 1"
grep -q '^runners=claude metered=1 ' "$T/agent-env.log" 2>/dev/null \
  && ok || bad "H2 the call was not restricted to subscription runners with K3 pinned: $(cat "$T/agent-env.log" 2>/dev/null)"
[ "$(nlines 'review-d1-fallback:project-1:' "$T/beats.log")" -eq 1 ] && ok || bad "H2 expected one fallback beat: $(cat "$T/beats.log" 2>/dev/null)"
[ "$(nlines 'REVIEW_D1_HOLD_MAX_H' "$T/h/logs/ALERTS.log")" -eq 1 ] && ok || bad "H2 expected one fallback ALERTS line: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
[ "$(nlines 'fallback: subscription-only (claude)' "$T/h/logs/pr-reviews.log")" -eq 1 ] && ok || bad "H2 expected the fallback log line: $(cat "$T/h/logs/pr-reviews.log")"
# A second tick on a new head: bought again, alerted once.
printf '{}\n' > "$T/h/state/project-1.pr-reviews.json"
run_lane
[ "$(calls)" -eq 2 ] && ok || bad "H2 tick 2 on a new ledger: $(calls) call(s), expected 2"
[ "$(nlines 'review-d1-fallback:project-1:' "$T/beats.log")" -eq 1 ] && ok || bad "H2 re-alerted on tick 2: $(cat "$T/beats.log")"
[ "$(nlines 'REVIEW_D1_HOLD_MAX_H' "$T/h/logs/ALERTS.log")" -eq 1 ] && ok || bad "H2 tick 2 wrote another ALERTS line: $(cat "$T/h/logs/ALERTS.log")"

# ── H3 — metered and unknown are never in the list ─────────────────────────
reset_env; fresh_harness
BM_claude=metered; BM_codex=subscription; BM_grok=metered; BM_gemini=unknown
seed_age $((7 * 3600))
run_lane
[ "$(calls)" -eq 1 ] && ok || bad "H3 expected 1 call on codex: $(calls)"
grep -q '^runners=codex metered=1 ' "$T/agent-env.log" 2>/dev/null \
  && ok || bad "H3 the list must be exactly codex: $(cat "$T/agent-env.log" 2>/dev/null)"
reset_env; fresh_harness
BM_claude=subscription; BM_codex=subscription; BM_grok=metered; BM_gemini=subscription
seed_age $((7 * 3600))
run_lane
grep -q '^runners=claude,codex,gemini metered=1 ' "$T/agent-env.log" 2>/dev/null \
  && ok || bad "H3 every subscription runner, in order: $(cat "$T/agent-env.log" 2>/dev/null)"

# A lane already restricted to some runners keeps that restriction: the
# fallback list is the intersection, however the operator spelled it.
reset_env; fresh_harness
BM_claude=subscription; BM_codex=subscription; BM_grok=subscription
ACR=" grok, codex"
seed_age $((7 * 3600))
run_lane
grep -q '^runners=codex,grok metered=1 ' "$T/agent-env.log" 2>/dev/null \
  && ok || bad "H3 the list must be the lane's own runners that are subscription: $(cat "$T/agent-env.log" 2>/dev/null)"

# ── H4 — D1 answers: clock and marker gone; the next outage starts fresh ───
reset_env; fresh_harness
seed_age $((7 * 3600))
run_lane
[ -f "$HOLDF.fallback" ] && ok || bad "H4 setup: no fallback marker after a fallback tick"
# A new head, so the tick reaches the D1 read (a reviewed head never asks).
printf '{}\n' > "$T/h/state/project-1.pr-reviews.json"
JOBS_RC=2
run_lane
[ ! -e "$HOLDF" ] && [ ! -e "$HOLDF.fallback" ] && ok || bad "H4 D1 answered and the hold files stayed: $(ls "$T/h/state")"
printf '{}\n' > "$T/h/state/project-1.pr-reviews.json"; rm -f "$T/agent-calls.log"
JOBS_RC=1
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "H4 a new outage fell back at once instead of restarting the clock: $(calls)"
[ -f "$HOLDF" ] && [ ! -e "$HOLDF.fallback" ] && ok || bad "H4 the new outage has no fresh clock: $(ls "$T/h/state")"

# H4b — D1 came back while every head was already reviewed, so no tick asked
# it and nothing cleared the clock. A clock no held tick has touched for over
# an hour is a finished outage: the next one starts, and alerts, afresh.
reset_env; fresh_harness
seed_age $((7 * 3600)); : > "$HOLDF.fallback"
touch -d '2 hours ago' "$HOLDF" "$HOLDF.fallback"
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "H4b a stale clock from an earlier outage fell back at once: $(calls)"
[ ! -e "$HOLDF.fallback" ] && ok || bad "H4b the earlier outage's alert marker survived"
since=$(cat "$HOLDF" 2>/dev/null)
[ $(( $(date +%s) - ${since:-0} )) -le 60 ] && ok || bad "H4b the clock did not restart: $since"
# A clock touched by a recent held tick keeps its start (7h ago): falls back.
reset_env; fresh_harness
seed_age $((7 * 3600)); touch -d '40 minutes ago' "$HOLDF"
run_lane
[ "$(calls)" -eq 1 ] && ok || bad "H4b a live outage's clock was reset by its own cadence: $(calls)"

# ── H5 — JOBS_URL unset (fleet default) + no secret: hold, don't pay ───────
reset_env; fresh_harness
JOBS_URL_MODE=unset; SECRET_MODE=unset
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "H5 a missing secret with the default URL paid: $(calls) call(s), expected 0"
[ -f "$HOLDF" ] && ok || bad "H5 the hold did not start its clock"
# H5b — JOBS_URL explicitly empty is "no worker here": today's fail-open.
reset_env; fresh_harness
JOBS_URL_MODE=empty; SECRET_MODE=unset
run_lane
[ "$(calls)" -eq 1 ] && ok || bad "H5b an empty JOBS_URL must keep the fail-open: $(calls) call(s), expected 1"
[ ! -e "$HOLDF" ] && ok || bad "H5b a worker-less box wrote a hold clock"
grep -q '^runners=<unset> metered=<unset> ' "$T/agent-env.log" 2>/dev/null \
  && ok || bad "H5b a normal buy carried the fallback restriction: $(cat "$T/agent-env.log" 2>/dev/null)"

# ── H6 — N=0 never falls back; garbage N is the default; garbage clock ─────
reset_env; fresh_harness
MAXH=0; seed_age $((100 * 3600))
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "H6 N=0 at 100h fell back: $(calls)"
reset_env; fresh_harness
MAXH=abc; seed_age $((5 * 3600))
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "H6 N=abc read as 0 or less than 5: $(calls)"
[ "$(nlines 'REVIEW_D1_HOLD_MAX_H' "$T/h/logs/pr-reviews.log")" -ge 1 ] && ok || bad "H6 a bad knob was not logged"
seed_age $((7 * 3600))
run_lane
[ "$(calls)" -eq 1 ] && ok || bad "H6 N=abc at 7h must fall back as the default 6: $(calls)"
reset_env; fresh_harness
MAXH=99999999999999999999; seed_age $((5 * 3600))
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "H6 an overflowing N wrapped to 'past N': $(calls)"
reset_env; fresh_harness
MAXH="<unset>"; seed_age $((7 * 3600))
run_lane
[ "$(calls)" -eq 1 ] && ok || bad "H6 an unset knob is the default 6: $(calls)"
reset_env; fresh_harness
printf 'not-a-number\n' > "$HOLDF"
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "H6 a garbage clock was read as old: $(calls)"
for g in 0 17 999999999999999999999999999999; do
  reset_env; fresh_harness
  printf '%s\n' "$g" > "$HOLDF"
  run_lane
  [ "$(calls)" -eq 0 ] && ok || bad "H6 a clock of '$g' was read as held for ages: $(calls)"
done
reset_env; fresh_harness
seed_age $((-10 * 3600))
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "H6 a future clock fell back: $(calls)"

# ── H7 — the fallback does not leak into the next PR of the tick ───────────
reset_env; fresh_harness
GH_PRS=two; JOBS_RC_8=2
seed_age $((7 * 3600))
run_lane
[ "$(calls)" -eq 2 ] && ok || bad "H7 expected #7 (fallback) and #8 (D1 no row) bought: $(calls)"
sed -n 1p "$T/agent-env.log" 2>/dev/null | grep -q '^runners=claude metered=1 .*#7@' \
  && ok || bad "H7 #7 was not the fallback buy: $(cat "$T/agent-env.log" 2>/dev/null)"
sed -n 2p "$T/agent-env.log" 2>/dev/null | grep -q '^runners=<unset> metered=<unset> .*#8@' \
  && ok || bad "H7 #8 inherited #7's runner restriction: $(cat "$T/agent-env.log" 2>/dev/null)"
# #8's D1 verdict for its head: replayed, no call at all.
reset_env; fresh_harness
GH_PRS=two; JOBS_RC_8=0
JOBS_VERDICT_8=$(printf 'APPROVE\t1\tclaude\t-\t4242\thead8ccccccc')
seed_age $((7 * 3600))
run_lane
[ "$(calls)" -eq 1 ] && ok || bad "H7 a D1 verdict for #8 must not buy: $(calls) call(s), expected 1 (#7)"

# ── H8 — no subscription runner on this box: keep holding ──────────────────
reset_env; fresh_harness
BM_claude=metered; BM_codex=unknown; BM_grok=metered; BM_gemini=unknown
seed_age $((7 * 3600))
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "H8 fell back with no subscription runner: $(calls)"
[ "$(nlines 'no subscription runner' "$T/h/logs/pr-reviews.log")" -ge 1 ] && ok || bad "H8 no 'no subscription runner' line: $(cat "$T/h/logs/pr-reviews.log" 2>/dev/null)"
grep -q 'review-d1-fallback' "$T/beats.log" 2>/dev/null && bad "H8 alerted a fallback that did not happen" || ok

echo "review-prs-d1-hold (BH-2457): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
