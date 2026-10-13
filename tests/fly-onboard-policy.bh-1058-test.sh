#!/bin/bash
# tests/fly-onboard-policy.bh-1058-test.sh — fly-onboard drain resolves its
# attempt cap and retry window from retry_policies before the env knobs.
#
# Drives the REAL bin/fly-pool-tick.sh inside the # >>> fly-onboard-drain block
# against a scratch $HARNESS with a recording stub for bin/fly-onboard.sh and
# a stub curl that answers the worker's retry-policy API.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/state" "$T/bin" "$T/bin/lib" "$T/env" "$T/fakebin" "$T/fly"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cp "$DIR/bin/fly-pool-tick.sh" "$T/bin/fly-pool-tick.sh"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR/bin/alert-line.sh" "$T/bin/alert-line.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/hub-box.sh" "$T/bin/lib/hub-box.sh"
cp "$DIR/bin/lib/env-path.sh" "$T/bin/lib/env-path.sh"
cp "$DIR/bin/box-name.sh" "$T/bin/box-name.sh"
cp "$DIR/bin/pool-cap.sh" "$T/bin/pool-cap.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/fly-lock-guard.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/fly-pool.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/logs/onboard-argv.log"\nexit 0\n' "$T" > "$T/bin/fly-onboard.sh"
chmod +x "$T/bin"/*.sh "$T/bin/lib"/*.sh

# Env defaults the policy should beat or fall back to.
cat > "$T/env/global.env" <<'ENV'
FLY_ONBOARD_MAX_ATTEMPTS=3
FLY_ONBOARD_RETRY_MIN=360
ENV

ARGV="$T/logs/onboard-argv.log"
REQ="$T/logs/req.log"

# Fake curl: records every request, answers the policy route, and follows
# CURL_MODE for failure cases. Everything else returns a harmless 200.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL=""; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2;;
    -H|--connect-timeout|-m|-w) shift 2;;
    -sS) shift;;
    *) URL="$1"; shift;;
  esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down) exit 7 ;;
esac
case "$METHOD $URL" in
  "GET "*/api/retry-policies/*)
    case "${CURL_MODE:-ok}" in
      policy-hit)
        printf '{"policy":{"lane":"fly-onboard/tproj/hub","max_attempts":1,"backoff_seconds":60,"escalate_allowed":0}}\n200\n'; exit 0 ;;
      policy-null)
        printf '{"policy":null}\n200\n'; exit 0 ;;
      policy-bad)
        printf '{"policy":{"lane":"fly-onboard/tproj/hub","max_attempts":"abc","backoff_seconds":60,"escalate_allowed":0}}\n200\n'; exit 0 ;;
      policy-backoff)
        printf '{"policy":{"lane":"fly-onboard/tproj/hub","max_attempts":3,"backoff_seconds":4000000000,"escalate_allowed":0}}\n200\n'; exit 0 ;;
      policy-negative)
        printf '{"policy":{"lane":"fly-onboard/tproj/hub","max_attempts":"-5","backoff_seconds":"1.5","escalate_allowed":0}}\n200\n'; exit 0 ;;
      policy-down)
        exit 7 ;;
    esac
    printf '{"policy":null}\n200\n'; exit 0 ;;
  *) printf '{"ok":true}\n200\n'; exit 0 ;;
esac
CURL
chmod +x "$T/fakebin/curl"

# One tick against the scratch harness. BOX_NAME=box-hub makes
# hub-box.sh answer "yes, this is the hub".
tick() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" BOX_NAME=box-hub \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
           JOBS_RETRIES=0 REQ_SINK="$REQ" CURL_MODE="${1:-ok}" \
           FLY_MACHINES_ROWS=${FLY_MACHINES_ROWS:-on}
    bash "$T/bin/fly-pool-tick.sh" )
}

# Reset mutable state between cases.
reset() {
  rm -rf "$T/state" "$T/logs" "$T/flags" "$T/fly/onboard-queue.conf"
  mkdir -p "$T/state" "$T/logs" "$T/flags" "$T/fly"
  : > "$REQ"
}

queue() { printf '%s\n' "tproj 2026-09-17T18:00:00Z" > "$T/fly/onboard-queue.conf"; }

# Bounded spin: wait for the detached recorder stub to write.
settle() { local i=0; until [ -e "$ARGV" ] || [ "$i" -gt 120000 ]; do i=$((i+1)); done; }

# ══ §10a: policy row beats env default, suppresses launch, pages once ═══════
reset; queue
mkdir -p "$T/state/fly-onboard"; echo 1 > "$T/state/fly-onboard/tproj.attempts"
tick policy-hit
settle
[ ! -e "$ARGV" ] \
  && ok || bad "§10a: policy max_attempts=1 must suppress launch (got '$(cat "$ARGV" 2>/dev/null)')"
A=$(grep -c '\[fly-onboard\] tproj: 1 onboarding attempts failed' "$T/logs/ALERTS.log" 2>/dev/null || true)
[ "$A" = 1 ] \
  && ok || bad "§10a: give-up must page exactly once (got $A)"
grep -q 'not retrying (policy fly-onboard/tproj/hub max_attempts=1 backoff=60s)' "$T/logs/ALERTS.log" \
  && ok || bad "§10a: give-up line must carry the policy values (got '$(cat "$T/logs/ALERTS.log" 2>/dev/null)')"
[ ! -e "$T/logs/fly-pool.log" ] || ! grep -q 'policy fly-onboard' "$T/logs/fly-pool.log" \
  && ok || bad "§10a: no per-tick policy line of its own in fly-pool.log (got '$(cat "$T/logs/fly-pool.log" 2>/dev/null)')"
# Second tick after give-up: the flag short-circuits before the policy lookup.
: > "$REQ"
tick policy-hit
PR=$(grep -c 'GET .*/api/retry-policies/' "$REQ" 2>/dev/null || true)
[ "$PR" = 0 ] \
  && ok || bad "§10a: a project that gave up must make zero retry-policy requests on later ticks (got $PR)"

# ══ §10b: policy:null → env default applies and launch is recorded ═════════
reset; queue
tick policy-null
settle
[ "$(cat "$ARGV" 2>/dev/null)" = tproj ] \
  && ok || bad "§10b: policy:null must fall back to env default and launch (got '$(cat "$ARGV" 2>/dev/null)')"
grep -q 'attempt 1 of 3' "$T/logs/fly-pool.log" \
  && ok || bad "§10b: launch log must show env cap 3"

# ══ §10c: machines_rows_on off → zero policy requests, env path ════════════
reset; queue
( export FLY_MACHINES_ROWS=off
  tick ok )
settle
[ "$(cat "$ARGV" 2>/dev/null)" = tproj ] \
  && ok || bad "§10c: contract off must still launch via env defaults (got '$(cat "$ARGV" 2>/dev/null)')"
PR=$(grep -c 'GET .*/api/retry-policies/' "$REQ" 2>/dev/null || true)
[ "$PR" = 0 ] \
  && ok || bad "§10c: contract off must make zero retry-policy requests (got $PR)"

# ══ §10d: worker transport failure on policy path → env path, tick exits 0 ═
reset; queue
tick policy-down; RC=$?
settle
[ "$RC" = 0 ] \
  && ok || bad "§10d: policy transport failure must leave tick exit 0 (got $RC)"
[ "$(cat "$ARGV" 2>/dev/null)" = tproj ] \
  && ok || bad "§10d: policy transport failure must fall back to env defaults and launch (got '$(cat "$ARGV" 2>/dev/null)')"

# ══ §10e: malformed max_attempts → env default, never retry-forever ════════
reset; queue
tick policy-bad
settle
[ "$(cat "$ARGV" 2>/dev/null)" = tproj ] \
  && ok || bad "§10e: malformed max_attempts must fall back to env default and launch (got '$(cat "$ARGV" 2>/dev/null)')"
grep -q 'attempt 1 of 3' "$T/logs/fly-pool.log" \
  && ok || bad "§10e: launch log must show env cap 3 after malformed policy"

# ══ §10f: policy backoff beats the env window — .last=1 would launch under the
# env 21600s window; the row's 4000000000s window must hold it back (no clock).
reset; queue
mkdir -p "$T/state/fly-onboard"; echo 1 > "$T/state/fly-onboard/tproj.attempts"; echo 1 > "$T/state/fly-onboard/tproj.last"
tick policy-backoff
settle
[ ! -e "$ARGV" ] \
  && ok || bad "§10f: policy backoff_seconds=4000000000 must suppress launch (got '$(cat "$ARGV" 2>/dev/null)')"

# ══ §10g: negative/decimal policy values are refused, not digit-stripped ═════
# "-5" stripped would be cap 5; "1.5" stripped would be 15s. Both must fall
# back to env: cap 3 (launch logs "of 3") and window 21600s.
reset; queue
tick policy-negative
settle
[ "$(cat "$ARGV" 2>/dev/null)" = tproj ] \
  && ok || bad "§10g: negative/decimal policy must fall back to env defaults and launch (got '$(cat "$ARGV" 2>/dev/null)')"
grep -q 'attempt 1 of 3' "$T/logs/fly-pool.log" \
  && ok || bad "§10g: launch log must show env cap 3 after refused policy values"

# ══ §10h: the contract read is owed to a project, not to the tick ════════
# FLY_MACHINES_ROWS is deliberately NOT exported here, so machines_rows_on has
# to ask the worker (GET /api/settings/fly_machines_rows). This loop runs 720
# times a day on a hub whose queue holds only projects that are already routed
# or have already given up, and none of those reaches the policy lookup.
tick_no_env() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" BOX_NAME=box-hub \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
           JOBS_RETRIES=0 REQ_SINK="$REQ" CURL_MODE="${1:-ok}"
    bash "$T/bin/fly-pool-tick.sh" )
}
settings_reqs() { grep -c 'GET .*/api/settings/fly_machines_rows' "$REQ" 2>/dev/null || true; }

reset; queue
: > "$T/flags/alerted-fly-onboard-gaveup-tproj"
tick_no_env ok
SR=$(settings_reqs)
[ "$SR" = 0 ] \
  && ok || bad "§10h: a project that gave up must cost zero contract reads (got $SR)"

reset; queue
: > "$T/flags/fly-pool-tproj"; : > "$T/flags/builder-fly-tproj"
tick_no_env ok
SR=$(settings_reqs)
[ "$SR" = 0 ] \
  && ok || bad "§10h: an already-routed project must cost zero contract reads (got $SR)"

# ...and a project that DOES reach the lookup still resolves it exactly once.
reset; queue
tick_no_env ok
settle
SR=$(settings_reqs)
[ "$SR" = 1 ] \
  && ok || bad "§10h: a live project must resolve the contract flag exactly once per tick (got $SR)"

# ══ Mutation check (D1): removing MAXA assignment from policy branch breaks §10a
reset; queue
sed '/MAXA=\$P_MAXA/d' "$T/bin/fly-pool-tick.sh" > "$T/bin/fly-pool-tick-mutant.sh"
chmod +x "$T/bin/fly-pool-tick-mutant.sh"
mkdir -p "$T/state/fly-onboard"; echo 1 > "$T/state/fly-onboard/tproj.attempts"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" BOX_NAME=box-hub \
         HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 \
         REQ_SINK="$REQ" CURL_MODE=policy-hit FLY_MACHINES_ROWS=on
  bash "$T/bin/fly-pool-tick-mutant.sh" )
settle
if [ -e "$ARGV" ]; then
  ok
else
  bad "D1 mutation: removing MAXA assignment must let launch through (nothing recorded)"
fi

# ══ Mutation check (D2): removing RETRY assignment from policy branch breaks §10f
reset; queue
sed '/RETRY=\$P_RETRY/d' "$T/bin/fly-pool-tick.sh" > "$T/bin/fly-pool-tick-mutant2.sh"
chmod +x "$T/bin/fly-pool-tick-mutant2.sh"
mkdir -p "$T/state/fly-onboard"; echo 1 > "$T/state/fly-onboard/tproj.attempts"; echo 1 > "$T/state/fly-onboard/tproj.last"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" BOX_NAME=box-hub \
         HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 \
         REQ_SINK="$REQ" CURL_MODE=policy-backoff FLY_MACHINES_ROWS=on
  bash "$T/bin/fly-pool-tick-mutant2.sh" )
settle
if [ -e "$ARGV" ]; then
  ok
else
  bad "D2 mutation: removing RETRY assignment must let launch through (nothing recorded)"
fi

echo "fly-onboard-policy: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
