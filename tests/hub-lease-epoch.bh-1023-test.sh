#!/bin/bash
# tests/hub-lease-epoch.bh-1023-test.sh — BH-1023.
#
# Two behaviours, both driven through the real `bin/hub-lease.sh` CLI against a
# stubbed curl (never a sourced function, never a grep over the script's source):
#
#   1. `check` re-validates the CACHED epoch against the row whenever it answers
#      "held" from a fresh cache — but only when the epoch knob is on. Dark, the
#      fresh-cache short-circuit is byte-for-byte today's behaviour (E0).
#   2. `renew` still caches the epoch the SERVER granted (never the one it asked
#      for), and reconciles the `hub-lease-epoch-check` flag row into the file
#      the knob reads.
#
# Point the suite at another copy of the script to prove it red:
#   git show main:bin/hub-lease.sh > /tmp/m.sh
#   HUB_LEASE_SCRIPT=/tmp/m.sh HARNESS_TEST_SANDBOX=1 bash tests/hub-lease-epoch.bh-1023-test.sh
#
# Run from anywhere: tests/hub-lease-epoch.bh-1023-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
HUB_LEASE_SCRIPT="${HUB_LEASE_SCRIPT:-$DIR/bin/hub-lease.sh}"
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/fakebin" "$T/env"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/box-name.sh" "$T/bin/box-name.sh"
printf 'box-hub\n' > "$T/state/box-name"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Fake curl: outputs payload\nHTTP_CODE matching real curl -w $'\n%{http_code}'.
# No trailing newline after HTTP_CODE — that breaks _jobs_req's ##* parsing.
# Payload shapes mirror the worker verbatim: {"lease":{holder,epoch,expired,
# expires_at,updated_at}} (worker/jobs/src/index.js GET /api/hub/lease) and
# {"flag":{name,active,updated_at},"as_of":…} (GET /api/flags/<name>, 404 when
# there is no row).
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; METHOD=""; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2 ;;
    -H*) shift;; *) shift;;
  esac
done
[ -n "${REQ_SINK:-}" ] && printf '[%s] %s\n%s\n---\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"

case "$URL" in
  */api/flags/*)
    case "${FLAG_MODE:-flag-404}" in
      flag-on)
        printf '{"flag":{"name":"hub-lease-epoch-check","active":1,"updated_at":"%s"},"as_of":"2026-09-19T21:00:00Z"}\n200' \
          "${FLAG_UPDATED_AT:-2026-09-19T21:00:00Z}"
        ;;
      flag-off)
        printf '{"flag":{"name":"hub-lease-epoch-check","active":0,"updated_at":"%s"},"as_of":"2026-09-19T21:00:00Z"}\n200' \
          "${FLAG_UPDATED_AT:-2026-09-19T21:00:00Z}"
        ;;
      flag-down) exit 7 ;;
      flag-404|*) printf '{"error":"not found"}\n404' ;;
    esac
    exit 0
    ;;
  */api/hub-lease*)
    case "${CURL_MODE:-ok}" in
      down) exit 7 ;;
      same-holder-epoch-bump)
        printf '{"lease":{"holder":"box-hub","epoch":2,"expired":false,"expires_at":"2026-09-19T21:03:00Z","updated_at":"2026-09-19T21:00:00Z"}}\n200'
        ;;
      same-holder-epoch3)
        printf '{"lease":{"holder":"box-hub","epoch":3,"expired":false,"expires_at":"2026-09-19T21:03:00Z","updated_at":"2026-09-19T21:00:00Z"}}\n200'
        ;;
      same-holder-epoch-string)
        printf '{"lease":{"holder":"box-hub","epoch":"1","expired":false,"expires_at":"2026-09-19T21:03:00Z","updated_at":"2026-09-19T21:00:00Z"}}\n200'
        ;;
      same-holder-no-epoch)
        printf '{"lease":{"holder":"box-hub","expired":false,"expires_at":"2026-09-19T21:03:00Z","updated_at":"2026-09-19T21:00:00Z"}}\n200'
        ;;
      other-holder)
        printf '{"lease":{"holder":"box-other","epoch":1,"expired":false,"expires_at":"2026-09-19T21:03:00Z","updated_at":"2026-09-19T21:00:00Z"}}\n200'
        ;;
      conflict)
        printf '{"error":"lease held","lease":{"holder":"box-other","epoch":5,"expired":false,"expires_at":"2026-09-19T21:03:00Z","updated_at":"2026-09-19T21:00:00Z"}}\n409'
        ;;
      renew-taken-bump)
        printf '{"lease":{"holder":"box-hub","epoch":2,"expired":false,"expires_at":"2026-09-19T21:03:00Z","updated_at":"2026-09-19T21:00:00Z"},"taken":true}\n200'
        ;;
      ok|*)
        printf '{"lease":{"holder":"box-hub","epoch":1,"expired":false,"expires_at":"2026-09-19T21:03:00Z","updated_at":"2026-09-19T21:00:00Z"}}\n200'
        ;;
    esac
    exit 0
    ;;
  *)
    printf '{}\n404'; exit 0
    ;;
esac
CURL
chmod +x "$T/fakebin/curl"

export REQ_SINK="$T/req.log"

# The knob is passed ONLY when a case sets it. Unset means unset in the child,
# the way a bare crontab line runs it — not "exported empty", which would let an
# env-file read pass for the wrong reason.
_run() { # _run <subcommand>
  local -a knob
  if [ -n "${HUB_LEASE_EPOCH_CHECK:-}" ]; then
    knob=(HUB_LEASE_EPOCH_CHECK="$HUB_LEASE_EPOCH_CHECK")
  else
    knob=(-u HUB_LEASE_EPOCH_CHECK)
  fi
  # -u HARNESS_ENV_DIR: harness_env_dir honours it FIRST, so a runner that
  # exports it would point E9b–E9g at the real box's global.env instead of
  # $T/env/global.env (same reason tests/pr-create-ladder-test.sh:48 unsets it).
  # -u FIRST: env stops reading options at the first NAME=VALUE operand, so
  # `env FOO=1 -u BAR cmd` would run `-u` as the command (rc 127).
  env -u HARNESS_ENV_DIR "${knob[@]}" \
    PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
    JOBS_RETRIES=0 HUB_LEASE_HOLDER=box-hub HUB_LEASE_NOW="$PINNED_NOW" \
    CURL_MODE="${CURL_MODE:-ok}" FLAG_MODE="${FLAG_MODE:-flag-404}" \
    FLAG_UPDATED_AT="${FLAG_UPDATED_AT:-2026-09-19T21:00:00Z}" \
    bash "$HUB_LEASE_SCRIPT" "$1" 2>/dev/null; echo $?
}
run_check() { _run check; }
run_renew() { _run renew; }

cache_val()  { jq -r "$1" "$T/state/hub-lease.json" 2>/dev/null; }
count_in()   { local c; c=$(grep -c "$1" "$2" 2>/dev/null); printf '%s' "${c:-0}"; }
gets()       { count_in '^\[GET\] https://jobs.invalid/api/hub-lease' "$T/req.log"; }
flag_gets()  { count_in '/api/flags/hub-lease-epoch-check' "$T/req.log"; }
# hub-lease.sh's OWN grace-exhausted line. jobs-client.sh writes its own
# once-a-day "harness-jobs unreachable (GET /api/hub-lease…)" line to the same
# file on any transport failure, and that one is not what these cases are about.
alerts()     { count_in '\[hub-lease\] hub-lease worker unreachable' "$T/logs/ALERTS.log"; }
outage_flag(){ [ -f "$T/flags/alerted-hub-lease-unreachable" ] && echo 1 || echo 0; }
knob_file()  { [ -f "$T/flags/hub-lease-epoch-check" ] && echo 1 || echo 0; }
knob_stamp() { stat -c %Y "$T/flags/hub-lease-epoch-check" 2>/dev/null; }
# hub-lease.sh's OWN "this knob value was ignored" line (E9l). Anchored on the
# script's log prefix so it can never match jobs-client.sh's unreachable lines.
knob_ignored(){ count_in '^\[hub-lease\] .*knob: HUB_LEASE_EPOCH_CHECK=' "$T/logs/hub-lease.log"; }
# the once-per-incident gate on that line (E9o), the same shape as the
# unreachable alert's flag.
knob_alerted(){ [ -f "$T/flags/alerted-hub-lease-knob" ] && echo 1 || echo 0; }

# Pin the clock so ages and cache freshness are deterministic
PINNED_NOW=$(( 1000000000 ))  # 2001-09-09T01:46:40Z

setup() {
  rm -f "$T/state/hub-lease.json" "$T/flags/alerted-hub-lease-unreachable"
  rm -f "$T/flags/alerted-hub-lease-knob"
  rm -f "$T/flags/hub-lease-epoch-check"
  rm -f "$T/logs/hub-lease.log" "$T/logs/ALERTS.log" "$T/env/global.env"
  : > "$T/req.log"
}

setup_cache() {
  # $1 = held (0|1), $2 = cached epoch, $3 = fetched_at offset from PINNED_NOW
  local held="${1:-1}" epoch="${2:-1}" age_off="${3:--10}"
  local fa=$(( PINNED_NOW + age_off ))
  jq -nc --arg h "box-hub" --argjson e "$epoch" --argjson held "$held" --argjson fa "$fa" \
    '{holder: $h, epoch: $e, expired: false, expires_at: "2001-09-09T02:46:40Z",
      updated_at: "2001-09-09T01:45:40Z", as_of: "2001-09-09T01:46:40Z",
      held: $held, fetched_at: $fa}' > "$T/state/hub-lease.json"
}

# ==============================================================================
# E0 — DARK. Knob unset, no flag file, fresh cache held=1 epoch=1, and the row
# the worker would answer with has moved to epoch 2. Today's behaviour, pinned:
# answer 0 from the file and never touch the network.
# ==============================================================================
setup; setup_cache 1 1 -10
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E0: dark check with fresh held=1 cache must exit 0 (got: $RC)"
[ "$(gets)" = 0 ] && ok || bad "E0: dark check must make NO GET (got: $(gets))"
[ "$(cache_val '.epoch')" = 1 ] && ok || bad "E0: dark check must leave the cache alone (got epoch: $(cache_val '.epoch'))"

# ==============================================================================
# E1 — THE TICKET'S RED CASE. Knob on, fresh cache says held=1 at epoch 1, the
# row says the same holder at epoch 2 (a promote, or an expired lease re-taken).
# The old holder must stop, inside the 60s window.
# ==============================================================================
setup; setup_cache 1 1 -10
RC=$(HUB_LEASE_EPOCH_CHECK=1 CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 1 ] && ok || bad "E1: epoch bump under a fresh held cache must exit 1 (got: $RC)"
[ "$(cache_val '.held')" = 0 ] && ok || bad "E1: cache held must be 0 (got: $(cache_val '.held'))"
[ "$(cache_val '.epoch')" = 2 ] && ok || bad "E1: cache must carry the ROW's epoch 2 (got: $(cache_val '.epoch'))"
[ "$(gets)" = 1 ] && ok || bad "E1: must make exactly one GET (got: $(gets))"

# ==============================================================================
# E2 — knob on, fresh held=1 cache, the row moved to another holder at our epoch
# ==============================================================================
setup; setup_cache 1 1 -10
RC=$(HUB_LEASE_EPOCH_CHECK=1 CURL_MODE=other-holder run_check)
[ "$RC" = 1 ] && ok || bad "E2: other holder must exit 1 (got: $RC)"
[ "$(cache_val '.held')" = 0 ] && ok || bad "E2: cache held must be 0 (got: $(cache_val '.held'))"
[ "$(cache_val '.holder')" = box-other ] && ok || bad "E2: cache must carry the new holder (got: $(cache_val '.holder'))"

# ==============================================================================
# E3 — knob on, fresh held=1 cache, worker unreachable. The re-validation cannot
# read a row it cannot reach: grace applies unchanged, and it is SILENT.
# ==============================================================================
setup; setup_cache 1 1 -10
RC=$(HUB_LEASE_EPOCH_CHECK=1 CURL_MODE=down run_check)
[ "$RC" = 0 ] && ok || bad "E3: unreachable inside grace must exit 0 (got: $RC)"
[ "$(alerts)" = 0 ] && ok || bad "E3: unreachable inside grace must write NO ALERTS (got: $(alerts))"
[ "$(outage_flag)" = 0 ] && ok || bad "E3: unreachable inside grace must not raise the outage flag"
[ "$(cache_val '.held')" = 1 ] && ok || bad "E3: cache must be left held=1 (got: $(cache_val '.held'))"

# E3b — same, past the 600s grace: exit 1 and exactly one ALERTS line.
#
# BH-1000 moved the DEFAULT on this path: past grace, the box that IS the
# configured hub now fails OPEN rather than exiting 1, because the only thing
# that could hand the lease elsewhere is the same worker that is not answering.
# The fail-CLOSED contract this case has always pinned is still real and still
# reachable — it is what `HUB_LEASE_FAIL_OPEN=0` restores — so the case keeps
# every assertion it had, verbatim, and states the configuration it holds in.
# The new default is pinned right below as E3c, and in full by
# tests/hub-lease.bh-1000-test.sh.
setup; setup_cache 1 1 -700
RC=$(HUB_LEASE_FAIL_OPEN=0 HUB_LEASE_EPOCH_CHECK=1 CURL_MODE=down run_check)
[ "$RC" = 1 ] && ok || bad "E3b: unreachable past grace must exit 1 (got: $RC)"
[ "$(alerts)" = 1 ] && ok || bad "E3b: unreachable past grace must write exactly 1 ALERTS line (got: $(alerts))"

# E3c — the BH-1000 default under the SAME outage, on the configured hub
# (HUB_LEASE_HOLDER is box-hub and so is hub_box_name's fallback): the
# gated lanes keep running, and the outage is loud through its own alert id
# instead of the fail-closed "worker unreachable" line. Re-validation is still
# on, and still has no row to compare against — the knob must not change any of
# this either way.
setup; setup_cache 1 1 -700
RC=$(HUB_LEASE_EPOCH_CHECK=1 CURL_MODE=down run_check)
[ "$RC" = 0 ] && ok || bad "E3c: the configured hub past grace must fail OPEN (got: $RC)"
[ "$(alerts)" = 0 ] && ok || bad "E3c: fail-open must not write the fail-closed unreachable line (got: $(alerts))"
[ "$(count_in 'hub lanes are running FAIL-OPEN' "$T/logs/ALERTS.log")" = 1 ] \
  && ok || bad "E3c: fail-open past HUB_LEASE_PAGE_S must page exactly once (got: $(count_in 'hub lanes are running FAIL-OPEN' "$T/logs/ALERTS.log"))"
[ "$(cat "$T/flags/alerted-hub-lease-unreachable" 2>/dev/null)" = "$PINNED_NOW" ] \
  && ok || bad "E3c: the flag must carry the epoch of the page (got: $(cat "$T/flags/alerted-hub-lease-unreachable" 2>/dev/null))"

# ==============================================================================
# E4 — knob on, fresh held=1 cache, the row still says us at our epoch: exit 0,
# and the cache is REFRESHED (it was really re-validated, not just trusted).
# ==============================================================================
setup; setup_cache 1 1 -10
RC=$(HUB_LEASE_EPOCH_CHECK=1 CURL_MODE=ok run_check)
[ "$RC" = 0 ] && ok || bad "E4: matching epoch must exit 0 (got: $RC)"
[ "$(cache_val '.held')" = 1 ] && ok || bad "E4: cache held must stay 1 (got: $(cache_val '.held'))"
[ "$(cache_val '.fetched_at')" = "$PINNED_NOW" ] && ok || bad "E4: cache fetched_at must be refreshed to now (got: $(cache_val '.fetched_at'))"
[ "$(gets)" = 1 ] && ok || bad "E4: must make exactly one GET (got: $(gets))"

# ==============================================================================
# E5 — knob on, fresh cache says held=0. A non-holder pays for nothing.
# ==============================================================================
setup; setup_cache 0 1 -10
RC=$(HUB_LEASE_EPOCH_CHECK=1 CURL_MODE=ok run_check)
[ "$RC" = 1 ] && ok || bad "E5: fresh held=0 cache must exit 1 (got: $RC)"
[ "$(gets)" = 0 ] && ok || bad "E5: fresh held=0 cache must make NO GET (got: $(gets))"

# ==============================================================================
# E6 — knob on, NO cache at all: nothing to compare, _is_held decides alone.
# ==============================================================================
setup
RC=$(HUB_LEASE_EPOCH_CHECK=1 CURL_MODE=same-holder-epoch3 run_check)
[ "$RC" = 0 ] && ok || bad "E6: no cache + row says us must exit 0 (got: $RC)"
[ "$(cache_val '.epoch')" = 3 ] && ok || bad "E6: cache must be written with the row's epoch 3 (got: $(cache_val '.epoch'))"
[ "$(cache_val '.held')" = 1 ] && ok || bad "E6: cache held must be 1 (got: $(cache_val '.held'))"

# ==============================================================================
# E7 — renew sends the epoch it HOLDS and caches the epoch it was GRANTED.
# ==============================================================================
setup; setup_cache 1 1 -120
RC=$(CURL_MODE=renew-taken-bump run_renew)
[ "$RC" = 0 ] && ok || bad "E7: renew that was granted the lease must exit 0 (got: $RC)"
[ "$(cache_val '.epoch')" = 2 ] && ok || bad "E7: renew must cache the GRANTED epoch 2 (got: $(cache_val '.epoch'))"
[ "$(cache_val '.held')" = 1 ] && ok || bad "E7: renew must cache held=1 (got: $(cache_val '.held'))"
SENT=$(grep -A1 '^\[POST\] https://jobs.invalid/api/hub-lease$' "$T/req.log" | tail -1)
[ "$(printf '%s' "$SENT" | jq -r '.epoch' 2>/dev/null)" = 1 ] \
  && ok || bad "E7: renew must SEND the epoch it holds, 1 (sent: $SENT)"

# ==============================================================================
# E8 — the flag ROW drives the flag FILE, reconciled by the ungated renew lane.
# ==============================================================================
setup; setup_cache 1 1 -120
RC=$(CURL_MODE=ok FLAG_MODE=flag-on FLAG_UPDATED_AT=2026-09-19T21:00:00Z run_renew)
[ "$RC" = 0 ] && ok || bad "E8: renew must still exit 0 while syncing the flag (got: $RC)"
[ "$(flag_gets)" = 1 ] && ok || bad "E8: renew must GET the flag row exactly once (got: $(flag_gets))"
[ "$(knob_file)" = 1 ] && ok || bad "E8: an active row must create flags/hub-lease-epoch-check"
[ "$(knob_stamp)" = 1789851600 ] && ok || bad "E8: the flag file must carry the applied updated_at 2026-09-19T21:00:00Z as its mtime (got: $(knob_stamp))"

# row flipped off, with a NEWER updated_at → the file goes away
RC=$(CURL_MODE=ok FLAG_MODE=flag-off FLAG_UPDATED_AT=2026-09-19T22:00:00Z run_renew)
[ "$RC" = 0 ] && ok || bad "E8: renew must exit 0 on flag-off (got: $RC)"
[ "$(knob_file)" = 0 ] && ok || bad "E8: an inactive row must remove flags/hub-lease-epoch-check"

# no row (404) → the box is left exactly as it is, and renew is unaffected
touch "$T/flags/hub-lease-epoch-check"
RC=$(CURL_MODE=ok FLAG_MODE=flag-404 run_renew)
[ "$RC" = 0 ] && ok || bad "E8: renew must exit 0 when there is no flag row (got: $RC)"
[ "$(knob_file)" = 1 ] && ok || bad "E8: a 404 must leave the flag file untouched"

# a 409 renew still reconciles the flag — losing the lease is when the knob matters most
setup; setup_cache 1 1 -120
RC=$(CURL_MODE=conflict FLAG_MODE=flag-on run_renew)
[ "$RC" = 1 ] && ok || bad "E8: a 409 renew must still exit 1 (got: $RC)"
[ "$(flag_gets)" = 1 ] && ok || bad "E8: a renew that did not win must still sync the flag (got: $(flag_gets))"

# E8b (review F3) — a renew that could NOT REACH the worker must not fire a
# second request into the same outage. The flag GET can only fail the same way,
# so the sync would double the renew minute's timeout budget (~17s → ~34s) and
# write a second _jobs_log line a minute for nothing; the next answered renew
# reconciles within a minute anyway.
setup; setup_cache 1 1 -120
RC=$(CURL_MODE=down FLAG_MODE=flag-on run_renew)
[ "$RC" = 1 ] && ok || bad "E8b: an unreachable renew must still exit 1 (got: $RC)"
[ "$(flag_gets)" = 0 ] && ok || bad "E8b: an unreachable renew must make NO flag GET (got: $(flag_gets))"
[ "$(knob_file)" = 0 ] && ok || bad "E8b: an unreachable renew must not create the flag file"

# ==============================================================================
# E9 — resolution order: the FILE is the fleet switch, an explicit 1|0 wins —
# from the process environment, and from env/global.env, which is where a box
# actually carries one (E9b onwards).
# ==============================================================================
setup; setup_cache 1 1 -10
touch "$T/flags/hub-lease-epoch-check"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 1 ] && ok || bad "E9: the flag file alone must turn the re-validation on (got: $RC)"

setup_cache 1 1 -10; : > "$T/req.log"   # keep the flag file, forget the first half's request
RC=$(HUB_LEASE_EPOCH_CHECK=0 CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9: HUB_LEASE_EPOCH_CHECK=0 must win over the file (got: $RC)"
[ "$(gets)" = 0 ] && ok || bad "E9: the env kill switch must make NO GET (got: $(gets))"

# ==============================================================================
# E9b — THE CRON SHAPE. The gated consumers are bare crontab lines that source no
# env file, so the documented box-local kill switch has to work with the
# variable absent from the process and present only in env/global.env. Written
# QUOTED here, the way an env file is usually hand-edited; E9c is the bare form.
# ==============================================================================
setup; setup_cache 1 1 -10
touch "$T/flags/hub-lease-epoch-check"
printf 'HARNESS_SECRET=test-secret\nHUB_LEASE_EPOCH_CHECK="0"\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9b: HUB_LEASE_EPOCH_CHECK=0 in env/global.env must kill the re-validation (got: $RC)"
[ "$(gets)" = 0 ] && ok || bad "E9b: the env-file kill switch must make NO GET (got: $(gets))"

# E9c — the same file, the other way: =1 forces it on with no flag file present.
setup; setup_cache 1 1 -10
printf 'HUB_LEASE_EPOCH_CHECK=1\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 1 ] && ok || bad "E9c: HUB_LEASE_EPOCH_CHECK=1 in env/global.env must force it on (got: $RC)"
[ "$(gets)" = 1 ] && ok || bad "E9c: forced on from the env file must make exactly one GET (got: $(gets))"

# E9d — precedence: the process environment beats the env file, both ways.
setup; setup_cache 1 1 -10
printf 'HUB_LEASE_EPOCH_CHECK=0\n' > "$T/env/global.env"
RC=$(HUB_LEASE_EPOCH_CHECK=1 CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 1 ] && ok || bad "E9d: an exported 1 must beat =0 in the env file (got: $RC)"

setup; setup_cache 1 1 -10
printf 'HUB_LEASE_EPOCH_CHECK=1\n' > "$T/env/global.env"
RC=$(HUB_LEASE_EPOCH_CHECK=0 CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9d: an exported 0 must beat =1 in the env file (got: $RC)"
[ "$(gets)" = 0 ] && ok || bad "E9d: the exported kill switch must make NO GET (got: $(gets))"

# E9e — the env TEMPLATE ships the line commented out. A commented line is not a
# setting: the box must stay dark, and the flag file must stay the fleet switch.
setup; setup_cache 1 1 -10
printf '# ---- hub-lease epoch re-validation ----\n#HUB_LEASE_EPOCH_CHECK=1\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9e: a COMMENTED env line must not turn the knob on (got: $RC)"
[ "$(gets)" = 0 ] && ok || bad "E9e: a commented env line must make NO GET (got: $(gets))"

setup_cache 1 1 -10; : > "$T/req.log"
touch "$T/flags/hub-lease-epoch-check"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 1 ] && ok || bad "E9e: with the line commented the flag file still decides (got: $RC)"

# E9f — a value that is neither 1 nor 0 is not an override: it falls through to
# the file, exactly as unset does.
setup; setup_cache 1 1 -10
printf 'HUB_LEASE_EPOCH_CHECK=maybe\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9f: a junk env-file value with no flag file must stay dark (got: $RC)"
touch "$T/flags/hub-lease-epoch-check"
setup_cache 1 1 -10; : > "$T/req.log"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 1 ] && ok || bad "E9f: a junk env-file value must let the flag file decide (got: $RC)"

# E9g (review F4) — HARNESS_ENV_DIR must not leak in from the RUNNER. A runner
# that exports it would send `harness_env_dir` at the real box's env dir, and
# E9b–E9f would then pass or fail on a file this suite never wrote. Export a
# decoy that says the opposite of $T/env/global.env: the scratch file must still
# be the one that decides.
setup; setup_cache 1 1 -10
mkdir -p "$T/decoy-env"
printf 'HUB_LEASE_EPOCH_CHECK=1\n' > "$T/decoy-env/global.env"
printf 'HUB_LEASE_EPOCH_CHECK=0\n' > "$T/env/global.env"
RC=$(HARNESS_ENV_DIR="$T/decoy-env" CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9g: a runner's HARNESS_ENV_DIR must not override \$T/env/global.env (got: $RC)"
[ "$(gets)" = 0 ] && ok || bad "E9g: the scratch env file's kill switch must still make NO GET (got: $(gets))"
rm -rf "$T/decoy-env"

# ==============================================================================
# E9h-E9l (review F2, round 2/3) — THE SPELLINGS A HAND-EDITED ENV FILE ACTUALLY
# CARRIES. The PR's own headline is "make the box-local kill switch real from
# cron", and a switch that reads as set and is not is worse than no switch: the
# probe on the shipped script found `=0 # comment`, `export …=0`, a CRLF line
# ending and a leading indent all IGNORED, with a GET made and not one log line
# to see it by. Each case below is the kill switch (`=0`) with the flag file
# PRESENT, so an ignored spelling shows up as rc 1 plus a GET.
# ==============================================================================
setup; setup_cache 1 1 -10
touch "$T/flags/hub-lease-epoch-check"
printf 'HUB_LEASE_EPOCH_CHECK=0 # off during the incident\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9h: a trailing # comment must not disable the kill switch (got: $RC)"
[ "$(gets)" = 0 ] && ok || bad "E9h: the commented-tail kill switch must make NO GET (got: $(gets))"
[ "$(knob_ignored)" = 0 ] && ok || bad "E9h: an HONOURED value must not log 'ignored'"

# the same strip, the other way: `=1 # on` must still force it on, no flag file.
setup; setup_cache 1 1 -10
printf 'HUB_LEASE_EPOCH_CHECK=1   # on for BH-1023\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 1 ] && ok || bad "E9h: a trailing # comment must not disable =1 either (got: $RC)"
[ "$(gets)" = 1 ] && ok || bad "E9h: forced on with a commented tail must make one GET (got: $(gets))"

# E9i — `export ` prefix. The most common way a human writes a line into an env
# file, and the anchored sed missed it entirely.
setup; setup_cache 1 1 -10
touch "$T/flags/hub-lease-epoch-check"
printf 'export HUB_LEASE_EPOCH_CHECK=0\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9i: an 'export ' prefix must not disable the kill switch (got: $RC)"
[ "$(gets)" = 0 ] && ok || bad "E9i: the exported-form kill switch must make NO GET (got: $(gets))"

# E9j — CRLF. A file that has been through a Windows editor or a pasted heredoc
# leaves 0\r, which is neither 1 nor 0.
setup; setup_cache 1 1 -10
touch "$T/flags/hub-lease-epoch-check"
printf 'HARNESS_SECRET=test-secret\r\nHUB_LEASE_EPOCH_CHECK=0\r\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9j: a CRLF line ending must not disable the kill switch (got: $RC)"
[ "$(gets)" = 0 ] && ok || bad "E9j: the CRLF kill switch must make NO GET (got: $(gets))"

# E9k — leading indentation. Same class, same silence.
setup; setup_cache 1 1 -10
touch "$T/flags/hub-lease-epoch-check"
printf '  HUB_LEASE_EPOCH_CHECK=0\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9k: leading indentation must not disable the kill switch (got: $RC)"
[ "$(gets)" = 0 ] && ok || bad "E9k: the indented kill switch must make NO GET (got: $(gets))"

# a COMMENTED line is still not a setting — the strip above must not turn
# `#HUB_LEASE_EPOCH_CHECK=0` into one (E9e pins the =1 direction).
setup; setup_cache 1 1 -10
touch "$T/flags/hub-lease-epoch-check"
printf '#HUB_LEASE_EPOCH_CHECK=0\n#  HUB_LEASE_EPOCH_CHECK=0\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 1 ] && ok || bad "E9k: a COMMENTED kill switch is not a setting — the file must still decide (got: $RC)"
[ "$(knob_ignored)" = 0 ] && ok || bad "E9k: a commented line must log nothing (got: $(knob_ignored))"

# E9m (review B-1) — TWO assignments in one file: the LAST one wins, the way
# `. global.env` resolves it and therefore the way every other reader of that
# file does. The incident edit is an APPEND under whatever the rollout already
# wrote, so first-wins drops the kill switch on the floor AND stays silent about
# it (the earlier value is a valid 1) — reads-as-set-and-is-not, again.
setup; setup_cache 1 1 -10
touch "$T/flags/hub-lease-epoch-check"
printf 'HUB_LEASE_EPOCH_CHECK=1\nHUB_LEASE_EPOCH_CHECK=0\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9m: an APPENDED =0 must win over an earlier =1 (got: $RC)"
[ "$(gets)" = 0 ] && ok || bad "E9m: the appended kill switch must make NO GET (got: $(gets))"
[ "$(knob_ignored)" = 0 ] && ok || bad "E9m: a resolved append must log nothing (got: $(knob_ignored))"

# the other direction, so this pins LAST-wins and not "0 wins": an appended =1
# must force it on over an earlier =0, with no flag file present.
setup; setup_cache 1 1 -10
printf 'HUB_LEASE_EPOCH_CHECK=0\nHUB_LEASE_EPOCH_CHECK=1\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 1 ] && ok || bad "E9m: an APPENDED =1 must win over an earlier =0 (got: $RC)"
[ "$(gets)" = 1 ] && ok || bad "E9m: forced on by the last line must make exactly one GET (got: $(gets))"

# the real incident file: the template's commented line, the rollout's `=1`, and
# the operator's `echo 'export …=0' >> global.env` on the end.
setup; setup_cache 1 1 -10
touch "$T/flags/hub-lease-epoch-check"
printf '#HUB_LEASE_EPOCH_CHECK=1\nHUB_LEASE_EPOCH_CHECK=1\nexport HUB_LEASE_EPOCH_CHECK=0\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9m: an appended 'export …=0' must kill the re-validation (got: $RC)"
[ "$(gets)" = 0 ] && ok || bad "E9m: the appended export kill switch must make NO GET (got: $(gets))"

# E9n (review N-1) — a trailing TAB with no comment behind it. Same class as the
# CRLF: whitespace an editor leaves that made `0` stop being `0`.
setup; setup_cache 1 1 -10
touch "$T/flags/hub-lease-epoch-check"
printf 'HUB_LEASE_EPOCH_CHECK=0\t\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9n: a trailing tab must not disable the kill switch (got: $RC)"
[ "$(gets)" = 0 ] && ok || bad "E9n: the tab-suffixed kill switch must make NO GET (got: $(gets))"
[ "$(knob_ignored)" = 0 ] && ok || bad "E9n: a tab-suffixed value is resolved, so nothing is logged (got: $(knob_ignored))"

# E9l — the value that is still not an override gets a LOG LINE. Falling through
# is the documented behaviour; doing it in silence is what made the switch
# unfalsifiable from the hub.
setup; setup_cache 1 1 -10
printf 'HUB_LEASE_EPOCH_CHECK=maybe\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9l: a junk env-file value must still fall through to the file (got: $RC)"
[ "$(knob_ignored)" = 1 ] && ok || bad "E9l: an ignored knob value must be logged once (got: $(knob_ignored))"
grep -q 'HUB_LEASE_EPOCH_CHECK=maybe ignored' "$T/logs/hub-lease.log" \
  && ok || bad "E9l: the log line must name the value that was ignored"

setup; setup_cache 1 1 -10
RC=$(HUB_LEASE_EPOCH_CHECK=yes CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9l: an exported junk value must fall through to the file too (got: $RC)"
[ "$(knob_ignored)" = 1 ] && ok || bad "E9l: an exported junk value must also be logged (got: $(knob_ignored))"

# E9l (review I-1) — a junk export that a SANE env-file value then masks is
# still a value the operator set and we ignored, and the contract in
# hub-lease.md / the template / the note is "a value that cannot be resolved is
# LOGGED". Deciding first and logging only on the fall-through made that false
# for exactly the case the operator later removes the masking line in and
# discovers the export was junk all along — with nothing in the log to have
# caught it. The knob still resolves to the file's 0: rc 0, no GET.
setup; setup_cache 1 1 -10
touch "$T/flags/hub-lease-epoch-check"
printf 'HUB_LEASE_EPOCH_CHECK=0\n' > "$T/env/global.env"
RC=$(HUB_LEASE_EPOCH_CHECK=yes CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9l: the env file's 0 must still decide over a junk export (got: $RC)"
[ "$(gets)" = 0 ] && ok || bad "E9l: a masked junk export must still make NO GET (got: $(gets))"
[ "$(knob_ignored)" = 1 ] && ok || bad "E9l: a junk export MASKED by the file must still be logged (got: $(knob_ignored))"
grep -q 'HUB_LEASE_EPOCH_CHECK=yes ignored' "$T/logs/hub-lease.log" \
  && ok || bad "E9l: the masked-export log line must name the value that was ignored"

# and the dark box stays silent: nothing set anywhere logs nothing.
setup; setup_cache 1 1 -10
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9l: nothing set anywhere must stay dark (got: $RC)"
[ "$(knob_ignored)" = 0 ] && ok || bad "E9l: a knob set nowhere must log nothing (got: $(knob_ignored))"
[ "$(knob_alerted)" = 0 ] && ok || bad "E9l: a dark box must not leave the knob flag behind"

# ==============================================================================
# E9o (review N-2) — the ignored-value line is once per INCIDENT, not once per
# invocation. With the knob on, every gated hub lane runs `check`, so an
# unattended typo wrote ~53 lines a minute into a log whose documented healthy
# state is SILENCE. Same gate as the unreachable alert: a flag file, removed
# the moment the knob resolves, so the next bad value is loud again.
# ==============================================================================
setup; setup_cache 1 1 -10
printf 'HUB_LEASE_EPOCH_CHECK=maybe\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9o: a junk value must still fall through (got: $RC)"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$(knob_ignored)" = 1 ] && ok || bad "E9o: three runs with the same junk value must log ONCE (got: $(knob_ignored))"
[ "$(knob_alerted)" = 1 ] && ok || bad "E9o: the first ignored value must raise the knob flag"

# fix the typo: the flag is dropped on the next run, so a LATER bad value is
# logged again instead of being swallowed by a stale flag.
printf 'HUB_LEASE_EPOCH_CHECK=0\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$RC" = 0 ] && ok || bad "E9o: the corrected kill switch must be honoured (got: $RC)"
[ "$(knob_alerted)" = 0 ] && ok || bad "E9o: a resolved knob must clear the flag"
printf 'HUB_LEASE_EPOCH_CHECK=nope\n' > "$T/env/global.env"
RC=$(CURL_MODE=same-holder-epoch-bump run_check)
[ "$(knob_ignored)" = 2 ] && ok || bad "E9o: a NEW bad value after a clean run must log again (got: $(knob_ignored))"
grep -q 'HUB_LEASE_EPOCH_CHECK=nope ignored' "$T/logs/hub-lease.log" \
  && ok || bad "E9o: the re-armed log line must name the new value"

# ==============================================================================
# E10 — adversarial epochs. "1" is 1; an ABSENT row epoch is never "the same".
# ==============================================================================
setup; setup_cache 1 1 -10
RC=$(HUB_LEASE_EPOCH_CHECK=1 CURL_MODE=same-holder-epoch-string run_check)
[ "$RC" = 0 ] && ok || bad "E10: a string epoch \"1\" must equal a cached 1 (got: $RC)"

setup; setup_cache 1 1 -10
RC=$(HUB_LEASE_EPOCH_CHECK=1 CURL_MODE=same-holder-no-epoch run_check)
[ "$RC" = 1 ] && ok || bad "E10: an ABSENT row epoch must not count as equal (got: $RC)"
[ "$(cache_val '.held')" = 0 ] && ok || bad "E10: cache held must be 0 for an absent row epoch (got: $(cache_val '.held'))"

# ==============================================================================
# D1 (review F2) — no doc this ticket owns may pin a LITERAL count of the gated
# `hub-lease.sh check &&` lanes. The number moved from 52 to 53 the day #926
# merged, so an operator running the hand recipe sees a mismatch and cannot tell
# it from real drift. The count lives in one place only — `cron/hub.cron` — and
# every probe compares against that rendered file.
# ==============================================================================
_lane_count=$(grep -c 'hub-lease.sh check && ' "$(rendered_cron hub)" 2>/dev/null)
[ "${_lane_count:-0}" -gt 0 ] \
  && ok || bad "D1: cron/hub.cron must carry gated hub-lease check lanes (got: ${_lane_count:-0})"
for f in docs/verification-map/entries/BH-1023.md \
         docs/verification-map/hub-lease.md \
         docs/notes/2026-09-19-BH-1023-hub-lease-epoch.md \
         bin/hub-lease.sh \
         "$(rendered_env)"; do
  # the PHRASE, not the bare number: a line citation, a byte count or a timeout
  # that happens to be 52 is not a pinned lane count, and this suite does not
  # grep source text for behaviour (see the header).
  hits=$(grep -nE '(^|[^0-9])52 (gated|hub-only|consumers|lines|lanes)' "$DIR/$f" 2>/dev/null)
  [ -z "$hits" ] \
    && ok || bad "D1: $f pins a stale lane count (cron/hub.cron has $_lane_count):
$hits"
done

echo "hub-lease-epoch-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
