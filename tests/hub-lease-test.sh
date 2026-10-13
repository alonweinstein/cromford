#!/bin/bash
# tests/hub-lease-test.sh — drives bin/hub-lease.sh renew|check|promote against
# a stubbed curl, asserting cache state, exit codes, ALERTS line count, and
# request content — every scenario from the acceptance test list.
#
# Run from anywhere: tests/hub-lease-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/box-name.sh" "$T/bin/box-name.sh"
printf 'box-hub\n' > "$T/state/box-name"
# BH-2272: promote refuses a holder that is not the registered hub or a
# standby, read through bin/fleet-conf.sh from a FIXTURE registry.
cp "$DIR/bin/fleet-conf.sh" "$T/bin/fleet-conf.sh"
cat > "$T/fleet-fixture.conf" <<'CONF'
# FIXTURE fleet.conf for tests/hub-lease-test.sh
# @standby box-small box-hub hub
demo-os example-org/demo-os - - 3 box-demo 192.0.2.10
CONF
export FLEET_CONF="$T/fleet-fixture.conf"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Fake curl: outputs payload\nHTTP_CODE matching real curl -w $'\n%{http_code}'.
# No trailing newline after HTTP_CODE — that breaks _jobs_req's ##* parsing.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; METHOD=""; BODY=""; HTTP=200
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2 ;;
    -H*) shift;; *) shift;;
  esac
done
[ -n "${REQ_SINK:-}" ] && printf '[%s] %s\n%s\n---\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"

case "$URL" in
  */api/hub/promote*)
    # BH-2272: the guarded route. The lease it answers with names the target
    # the BODY asked for, so a promote that sent the wrong holder shows up in
    # the cache and the output, not only in the request log.
    case "${CURL_MODE:-ok}" in
      promote-disabled) printf '{"error":"promote-disabled"}\n403'; exit 0 ;;
      promote-live) printf '{"error":"lease_live","lease":{"holder":"box-other","epoch":1,"expired":false,"live":true}}\n409'; exit 0 ;;
    esac
    TGT=$(printf '%s' "$BODY" | jq -r '.target // ""' 2>/dev/null)
    jq -nc --arg h "$TGT" '{ok:true, promoted:true, lease:{holder:$h,epoch:2,expired:false,live:true,expires_at:"2026-09-16T11:00:00Z",updated_at:"2026-09-16T10:00:00Z"}, stop_old_hub:"stop the old hub now"}'
    printf '200'
    exit 0
    ;;
  */api/hub-lease/promote*|*/api/hub/lease/promote*)
    # Retired (BH-2272): the client must never call it again.
    printf '{"error":"gone"}\n410'; exit 0
    ;;
  */api/hub-lease*)
    case "${CURL_MODE:-ok}" in
      conflict)
        printf '{"lease":{"holder":"box-other","epoch":5,"expired":false,"expires_at":"2026-09-16T11:00:00Z","updated_at":"2026-09-16T10:00:00Z"}}\n409'
        exit 0
        ;;
      other-holder)
        printf '{"lease":{"holder":"box-other","epoch":3,"expired":false,"expires_at":"2026-09-16T11:00:00Z","updated_at":"2026-09-16T10:00:00Z"}}\n200'
        exit 0
        ;;
      down)
        exit 7
        ;;
      expired)
        printf '{"lease":{"holder":"box-hub","epoch":2,"expired":true,"expires_at":"2026-09-16T09:00:00Z","updated_at":"2026-09-16T09:00:00Z"}}\n200'
        exit 0
        ;;
      expired-string)
        printf '{"lease":{"holder":"box-hub","epoch":2,"expired":"false","expires_at":"2026-09-16T11:00:00Z","updated_at":"2026-09-16T10:00:00Z"}}\n200'
        exit 0
        ;;
      missing-lease)
        printf '{"not_lease":true}\n200'
        exit 0
        ;;
      ok|*)
        printf '{"lease":{"holder":"box-hub","epoch":1,"expired":false,"expires_at":"2026-09-16T11:00:00Z","updated_at":"2026-09-16T10:00:00Z"}}\n200'
        exit 0
        ;;
    esac
    ;;
  *)
    printf '{}\n404'; exit 0
    ;;
esac
CURL
chmod +x "$T/fakebin/curl"

run_renew()  { PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
                HUB_LEASE_HOLDER=box-hub HUB_LEASE_NOW="$PINNED_NOW" bash "$DIR/bin/hub-lease.sh" renew 2>/dev/null; echo $?; }
run_check()  { PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
                HUB_LEASE_HOLDER=box-hub HUB_LEASE_NOW="$PINNED_NOW" bash "$DIR/bin/hub-lease.sh" check 2>/dev/null; echo $?; }
run_promote(){ ADDL="${1:+--holder $1}"; PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
                HUB_LEASE_HOLDER=box-hub HUB_LEASE_NOW="$PINNED_NOW" bash "$DIR/bin/hub-lease.sh" promote $ADDL 2>/dev/null; echo $?; }
cache_val()  { jq -r "$1" "$T/state/hub-lease.json" 2>/dev/null; }
flag_exists(){ [ -f "$T/flags/alerted-hub-lease-unreachable" ] && echo 1 || echo 0; }
alerts_lines(){ grep -c 'hub-lease' "$T/logs/ALERTS.log" 2>/dev/null || echo 0; }

# Pin the clock so ages and cache freshness are deterministic
PINNED_NOW=$(( 1000000000 ))  # 2001-09-09T01:46:40Z

# Clean state between scenarios
setup() {
  rm -f "$T/state/hub-lease.json" "$T/flags/alerted-hub-lease-unreachable"
  rm -f "$T/logs/hub-lease.log" "$T/logs/ALERTS.log"
  # BH-1000: the outage clock is cross-run state like the flag, so a scenario
  # that inherited it would page on the previous scenario's elapsed time.
  rm -f "$T/state/hub-lease-failing-since"
}
setup_cache() {
  # $1 = held (0|1), $2 = fetched_at epoch age offset relative to PINNED_NOW
  local held="${1:-1}" age_off="${2:--60}"
  local fa=$(( PINNED_NOW + age_off ))
  local ua_epoch=$(( fa - 30 ))
  local ua; ua=$(date -u -d "@$ua_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                 date -u -r "$ua_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
  [ -n "$ua" ] || ua="2001-09-09T01:46:10Z"
  jq -nc --arg h "box-hub" --argjson e 1 --argjson held "$held" --argjson fa "$fa" --arg ua "$ua" \
    '{holder: $h, epoch: $e, expired: false, expires_at: "2001-09-09T02:46:40Z",
      updated_at: $ua, as_of: "2001-09-09T01:46:40Z", held: $held, fetched_at: $fa}' \
    > "$T/state/hub-lease.json"
}

# ==============================================================================
# S1: renew → server answers with held=1 → exit 0, cache written
# ==============================================================================
setup; setup_cache 1 -120
RC=$(CURL_MODE=ok run_renew)
[ "$RC" = 0 ] && ok || bad "S1: renew with held=1 must exit 0 (got: $RC)"
[ "$(cache_val '.holder')" = 'box-hub' ] && ok || bad "S1: cache holder must be box-hub (got: $(cache_val '.holder'))"
[ "$(cache_val '.held')" = 1 ] && ok || bad "S1: cache held must be 1 (got: $(cache_val '.held'))"
[ "$(cache_val '.epoch')" = 1 ] && ok || bad "S1: cache epoch must be 1 (got: $(cache_val '.epoch'))"

# ==============================================================================
# S2: renew → server 409 (lost lease) → exit 1, cache updated with new holder
# ==============================================================================
setup; setup_cache 1 -120
RC=$(CURL_MODE=conflict run_renew)
[ "$RC" = 1 ] && ok || bad "S2: renew with 409 must exit 1 (got: $RC)"
[ "$(cache_val '.holder')" = 'box-other' ] && ok || bad "S2: cache must reflect new holder (got: $(cache_val '.holder'))"
[ "$(cache_val '.held')" = 0 ] && ok || bad "S2: cache held must be 0 (got: $(cache_val '.held'))"
[ "$(cache_val '.epoch')" = 5 ] && ok || bad "S2: cache epoch must be 5 (got: $(cache_val '.epoch'))"

# ==============================================================================
# S3: check → fresh cache (age < CACHE_S=60) → skip network, exit per held
# ==============================================================================
setup; setup_cache 1 -10  # 10s old = fresh
RC=$(CURL_MODE=down run_check)
[ "$RC" = 0 ] && ok || bad "S3: check with fresh cache held=1 must exit 0 (got: $RC)"

setup_cache 0 -10
RC=$(CURL_MODE=down run_check)
[ "$RC" = 1 ] && ok || bad "S3: check with fresh cache held=0 must exit 1 (got: $RC)"

# ==============================================================================
# S4: check → stale cache held=1, server down, within GRACE_S=600 → exit 0
# ==============================================================================
setup; setup_cache 1 -300  # 300s old = stale but within 600s grace
RC=$(CURL_MODE=down run_check)
[ "$RC" = 0 ] && ok || bad "S4: check with grace must exit 0 (got: $RC)"

# ==============================================================================
# S5: check → stale cache held=1, server down, grace exhausted → exit 0, ALERTS
#
# BH-1000 CHANGED THIS SPEC. It used to exit 1: the hub stopped every one of its
# 52 gated lanes because its own worker was unreachable, while no other box
# could possibly have taken the lease (the only way to take it is through that
# same worker). The configured hub now keeps running and PAGES instead — the
# alert is the point, so the ALERTS assertions below are unchanged and the exit
# code is the one thing that flipped. tests/hub-lease.bh-1000-test.sh carries
# the negatives (a non-hub box, a held=0 cache, a 404) that stay fail-closed.
# ==============================================================================
setup; setup_cache 1 -700  # 700s old = grace exhausted (600)
RC=$(CURL_MODE=down run_check)
[ "$RC" = 0 ] && ok || bad "S5: the configured hub past grace must fail OPEN (got: $RC)"
[ "$(alerts_lines)" = 1 ] && ok || bad "S5: must write exactly 1 ALERTS line (got: $(alerts_lines))"
[ "$(flag_exists)" = 1 ] && ok || bad "S5: flag must exist after ALERTS"

# Second check with same state → still exit 0, NO extra ALERTS line
RC=$(CURL_MODE=down run_check)
[ "$RC" = 0 ] && ok || bad "S5: second check must still fail open (got: $RC)"
[ "$(alerts_lines)" = 1 ] && ok || bad "S5: second check must not add another ALERTS (got: $(alerts_lines))"

# ==============================================================================
# S5b: check → stale cache held=0 (not current holder), server down → exit 1, ALERTS
# ==============================================================================
setup; setup_cache 0 -300
RC=$(CURL_MODE=down run_check)
[ "$RC" = 1 ] && ok || bad "S5b: check with held=0 must exit 1 (got: $RC)"
[ "$(alerts_lines)" = 1 ] && ok || bad "S5b: must write ALERTS (got: $(alerts_lines))"

# ==============================================================================
# S5c: check → no cache at all, server down → exit 0 on the configured hub
#
# BH-1000 CHANGED THIS SPEC TOO, and this is the exact incident shape: a hub
# that has never cached a lease (or was wiped) used to exit 1 and write NOTHING
# — no grace, no alert, 52 lanes skipped in silence. It now fails open and
# starts the outage clock; the page follows at HUB_LEASE_PAGE_S, which is why
# this first tick still writes no ALERTS line.
# ==============================================================================
setup
rm -f "$T/state/hub-lease.json"
RC=$(CURL_MODE=down run_check)
[ "$RC" = 0 ] && ok || bad "S5c: the configured hub with no cache must fail OPEN (got: $RC)"
[ "$(alerts_lines)" = 0 ] && ok || bad "S5c: a fresh outage must not page on its first tick (got: $(alerts_lines))"
[ -f "$T/state/hub-lease-failing-since" ] && ok || bad "S5c: the outage clock must start, or the page never comes"

# ==============================================================================
# S6: after S5 recovery, server back → check → exit 0, flag and clock cleared
# ==============================================================================
setup; setup_cache 1 -700
RC=$(CURL_MODE=down run_check)  # establish outage (fails open and pages)
# Now server comes back
RC=$(CURL_MODE=ok run_check)
[ "$RC" = 0 ] && ok || bad "S6: recovery check must exit 0 (got: $RC)"
[ "$(flag_exists)" = 0 ] && ok || bad "S6: flag must be cleared on recovery (got: $(flag_exists))"
[ -f "$T/state/hub-lease-failing-since" ] \
  && bad "S6: recovery must clear the outage clock, or the next blip pages instantly" || ok

# ==============================================================================
# S11: promote --holder NAME → prints lease JSON, cache written for self
# ==============================================================================
# BH-2272: the fake curl used to answer any body, so `--holder` itself was sent
# as the holder name and this still passed. It now asserts WHAT was sent: the
# guarded route, target = the named box, the epoch it just read, confirm:true.
setup
SINK="$T/state/req-sink"; : > "$SINK"
PROMO_OUT=$(PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
  HUB_LEASE_HOLDER=box-hub HUB_LEASE_NOW="$PINNED_NOW" REQ_SINK="$SINK" \
  bash "$DIR/bin/hub-lease.sh" promote --holder box-hub 2>/dev/null)
RC=$?
[ "$RC" = 0 ] && ok || bad "S11: promote must exit 0 (got: $RC)"
[ -n "$PROMO_OUT" ] && ok || bad "S11: promote must print lease JSON on stdout (got: empty)"
printf '%s' "$PROMO_OUT" | jq -e '.lease.holder' >/dev/null 2>&1 \
  && ok || bad "S11: promoted output must have .lease.holder"
[ "$(cache_val '.held')" = 1 ] && ok || bad "S11: cache held must be 1 for self-promote (got: $(cache_val '.held'))"
# The request that was sent: exactly one POST, to /api/hub/promote, never the retired route.
promote_bodies() { awk '/^\[POST\] .*\/api\/hub\/promote$/ {getline; print}' "$SINK"; }
[ "$(promote_bodies | wc -l | tr -d ' ')" = 1 ] && ok || bad "S11: exactly one POST /api/hub/promote (sink: $(cat "$SINK"))"
if grep -qE 'hub-lease/promote|hub/lease/promote' "$SINK"; then bad "S11: the retired legacy route must not be called"; else ok; fi
PB=$(promote_bodies | head -1)
[ "$(printf '%s' "$PB" | jq -r '.target')" = box-hub ] && ok || bad "S11: target must be the --holder value (body: $PB)"
[ "$(printf '%s' "$PB" | jq -r '.expected_epoch')" = 1 ] && ok || bad "S11: expected_epoch must be the epoch just read (body: $PB)"
[ "$(printf '%s' "$PB" | jq -r '.confirm')" = true ] && ok || bad "S11: confirm must be the literal true (body: $PB)"
[ -n "$(printf '%s' "$PB" | jq -r '.actor // empty')" ] && ok || bad "S11: an actor must be sent (body: $PB)"
[ "$(printf '%s' "$PB" | jq -r '.override_live_lease')" = false ] && ok || bad "S11: no override unless asked (body: $PB)"

# S11b-c: the positional form and --holder=NAME name the same box. A standby
# (fleet.conf `# @standby`) is a registered holder; the cache stays held=0
# because this box is not the one promoted.
for form in "box-small" "--holder=box-small"; do
  setup; : > "$SINK"
  RC=$(PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
    HUB_LEASE_HOLDER=box-hub HUB_LEASE_NOW="$PINNED_NOW" REQ_SINK="$SINK" \
    bash "$DIR/bin/hub-lease.sh" promote "$form" >/dev/null 2>&1; echo $?)
  [ "$RC" = 0 ] && ok || bad "S11b [$form]: promote must exit 0 (got: $RC)"
  [ "$(promote_bodies | head -1 | jq -r '.target')" = box-small ] && ok \
    || bad "S11b [$form]: target must be box-small (sink: $(cat "$SINK"))"
done

# S11d-f: a holder that is not the hub or a standby, a bare `--holder` with no
# value, and a stray argument are refused BEFORE any request: rc 2, nothing sent.
# `--holder` alone is the fleet-wide lane stop this ticket is about.
for args in "--holder box-99" "--holder" "--holder=" "box-demo" "--holder box-hub extra"; do
  setup; : > "$SINK"
  # shellcheck disable=SC2086
  ERR=$(PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
    HUB_LEASE_HOLDER=box-hub HUB_LEASE_NOW="$PINNED_NOW" REQ_SINK="$SINK" \
    bash "$DIR/bin/hub-lease.sh" promote $args 2>&1 >/dev/null); RC=$?
  [ "$RC" = 2 ] && ok || bad "S11d [$args]: must exit 2 (got: $RC)"
  [ ! -s "$SINK" ] && ok || bad "S11d [$args]: no request may be sent (sink: $(cat "$SINK"))"
  [ -n "$ERR" ] && ok || bad "S11d [$args]: must say why on stderr"
done

# S11g: no registry to check against → refused, not waved through.
setup; : > "$SINK"
RC=$(PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
  HUB_LEASE_HOLDER=box-hub HUB_LEASE_NOW="$PINNED_NOW" REQ_SINK="$SINK" FLEET_CONF="$T/no-such.conf" \
  bash "$DIR/bin/hub-lease.sh" promote --holder box-hub >/dev/null 2>&1; echo $?)
# fleet-conf.sh falls back to /root/harness/fleet.conf; only assert when the
# host running the suite has none (the fixture sits outside $T/bin/../fleet.conf).
if [ ! -f /root/harness/fleet.conf ]; then
  [ "$RC" = 2 ] && ok || bad "S11g: no fleet.conf must exit 2 (got: $RC)"
  [ ! -s "$SINK" ] && ok || bad "S11g: no request may be sent without a registry"
fi

# S11h: --override-live-lease is sent as the JSON literal true.
setup; : > "$SINK"
RC=$(PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
  HUB_LEASE_HOLDER=box-hub HUB_LEASE_NOW="$PINNED_NOW" REQ_SINK="$SINK" \
  bash "$DIR/bin/hub-lease.sh" promote --holder box-small --override-live-lease --reason drill >/dev/null 2>&1; echo $?)
[ "$RC" = 0 ] && ok || bad "S11h: override promote must exit 0 (got: $RC)"
[ "$(promote_bodies | head -1 | jq -c '[.override_live_lease, .reason]')" = '[true,"drill"]' ] && ok \
  || bad "S11h: override_live_lease must be true and reason passed (sink: $(cat "$SINK"))"

# S11i-j: the worker's refusal is an exit 1 with the worker's own words on
# stderr (403 promote-disabled, 409 lease_live), and nothing is cached as held.
for mode in promote-disabled:promote-disabled promote-live:lease_live; do
  setup
  ERR=$(CURL_MODE="${mode%%:*}" PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
    HUB_LEASE_HOLDER=box-hub HUB_LEASE_NOW="$PINNED_NOW" \
    bash "$DIR/bin/hub-lease.sh" promote --holder box-hub 2>&1 >/dev/null); RC=$?
  [ "$RC" = 1 ] && ok || bad "S11i [$mode]: a refused promote must exit 1 (got: $RC)"
  case "$ERR" in *"${mode##*:}"*) ok ;; *) bad "S11i [$mode]: stderr must carry the worker's reason (got: $ERR)" ;; esac
  [ "$(cache_val '.held')" != 1 ] && ok || bad "S11i [$mode]: a refused promote must not cache held=1"
done

# ==============================================================================
# ADV: check with expired-as-string (server returns expired="false") → held=0 because it's not a boolean false
setup
RC=$(CURL_MODE=expired-string run_check)
[ "$RC" = 1 ] && ok || bad "ADV: check with expired-string must exit 1 (got: $RC)"
[ "$(cache_val '.held')" = 0 ] && ok || bad "ADV: cache held must be 0 after expired-string (got: $(cache_val '.held'))"

# ADV: check with expired lease (server returns expired=true) → held=0
# ==============================================================================
setup
RC=$(CURL_MODE=expired run_check)
[ "$RC" = 1 ] && ok || bad "ADV: check with expired lease must exit 1 (got: $RC)"
[ "$(cache_val '.held')" = 0 ] && ok || bad "ADV: cache held must be 0 after expired (got: $(cache_val '.held'))"

# ==============================================================================
# ADV: check with missing lease object → held=0
# ==============================================================================
setup
RC=$(CURL_MODE=missing-lease run_check)
[ "$RC" = 1 ] && ok || bad "ADV: check with missing lease object must exit 1 (got: $RC)"

echo "hub-lease-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
