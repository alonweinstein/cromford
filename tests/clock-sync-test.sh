#!/bin/bash
# tests/clock-sync-test.sh — bin/clock-sync.sh against a frozen fake clock, a
# stubbed curl and a stubbed process table. Nothing here touches the real clock.
#
# WHY THE SCRIPT EXISTS (2026-09-14). The fleet's boxes are Orgo containers:
# init is init.sh, no systemd, no ntpd, no chrony, nothing disciplines the clock.
# Measured that afternoon every box was SLOW by 66-464 seconds. bin/gh-token.sh
# hands out a cached App token while it still has 300s of life BY THIS BOX'S
# CLOCK, so a box 444s slow hands out tokens GitHub has already expired and the
# build dies mid-push; the App JWT's iat/exp and every deferred_at age drift with
# it too.
#
# What is proved here:
#   1. an offset past the tolerance is SET, from the HTTP Date header, and the
#      line says by how much;
#   2. it is idempotent — the run right after a set changes nothing;
#   3. inside the tolerance nothing is set (a clock is not nudged for 3 seconds);
#   4. api.github.com down falls back to cloudflare; both down changes nothing
#      and does NOT alert (that is a network fact, not a clock fact);
#   5. a box where an NTP daemon IS running is left alone entirely — two writers
#      is how a clock oscillates;
#   6. `date -s` denied writes ONE actionable ALERTS line, however many ticks
#      follow, naming what is needed and from whom;
#   7. CLOCK_SYNC=0 and flags/clock-sync-off stop it dead.
# Run from anywhere: tests/clock-sync-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
REALDATE=$(command -v date)

mkdir -p "$T/fakebin" "$T/h/bin" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/env"
cp "$DIR/bin/clock-sync.sh" "$T/h/bin/"; chmod +x "$T/h/bin/clock-sync.sh"

# --- a frozen clock ----------------------------------------------------------
# BASE is "what this box's clock reads" and never advances on its own, so the
# offset the script computes is exact and the assertions are not races. `date -s`
# moves it (by writing the skew) or refuses (when $T/deny-set exists), which is
# the one behaviour that distinguishes a box with CAP_SYS_TIME from one without.
cat > "$T/fakebin/date" <<SH
#!/bin/bash
R="$REALDATE"
T="$T"
SH
cat >> "$T/fakebin/date" <<'SH'
now() { echo $(( $(cat "$T/base") + $(cat "$T/skew" 2>/dev/null || echo 0) )); }
if [ "${1:-}" = -u ] && [ "${2:-}" = -s ]; then
  if [ -f "$T/deny-set" ]; then echo "date: cannot set date: Operation not permitted" >&2; exit 1; fi
  V="${3#@}"; echo "$(( V - $(cat "$T/base") ))" > "$T/skew"; echo "$V" >> "$T/set.log"; exit 0
fi
if [ "${1:-}" = -u ] && [ "${2:-}" = -d ]; then exec "$R" "$@"; fi
if [ "${1:-}" = -u ]; then exec "$R" -u -d "@$(now)" "${@:2}"; fi
exec "$R" "$@"
SH
chmod +x "$T/fakebin/date"

# --- the time sources --------------------------------------------------------
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${*: -1}"
case "$URL" in
  *api.github.com*)  F="$T/gh-date" ;;
  *cloudflare*)      F="$T/cf-date" ;;
  *)                 exit 1 ;;
esac
[ -s "$F" ] || exit 1
printf 'HTTP/2 200\r\ndate: %s\r\nserver: fake\r\n\r\n' "$(cat "$F")"
SH
sed -i "2i T=\"$T\"" "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

# --- the process table -------------------------------------------------------
cat > "$T/fakebin/pgrep" <<'SH'
#!/bin/bash
[ -f "$T/ntp" ] && exit 0
exit 1
SH
sed -i "2i T=\"$T\"" "$T/fakebin/pgrep"; chmod +x "$T/fakebin/pgrep"
cat > "$T/fakebin/timedatectl" <<'SH'
#!/bin/bash
if [ -f "$T/ntp" ]; then echo yes; else echo no; fi
SH
sed -i "2i T=\"$T\"" "$T/fakebin/timedatectl"; chmod +x "$T/fakebin/timedatectl"

BASE=1789000000          # what the box's clock reads; never advances by itself
setup() { # setup <box-offset-seconds> — the remote is BASE + offset
  rm -rf "$T/h/logs" "$T/h/state" "$T/h/flags"; mkdir -p "$T/h/logs" "$T/h/state" "$T/h/flags"
  rm -f "$T/skew" "$T/set.log" "$T/ntp" "$T/deny-set" "$T/gh-date" "$T/cf-date"
  echo "$BASE" > "$T/base"
  "$REALDATE" -u -R -d "@$((BASE + $1))" > "$T/gh-date"
  "$REALDATE" -u -R -d "@$((BASE + $1))" > "$T/cf-date"
}
run() { env PATH="$T/fakebin:$PATH" HARNESS="$T/h" "$@" bash "$T/h/bin/clock-sync.sh" >/dev/null 2>&1; }
sets() { [ -f "$T/set.log" ] && wc -l < "$T/set.log" || echo 0; }
LOG="$T/h/logs/clock-sync.log"

# ── 1. a real offset is set, and the line says by how much ───────────────────
setup 444
run
[ "$(sets)" -eq 1 ] && ok || bad "a 444s offset must be set"
grep -q 'clock-sync: offset=444 set' "$LOG" && ok || bad "the set must name the offset: $(cat "$LOG")"
grep -q 'source=https://api.github.com' "$LOG" && ok || bad "the set must name its source: $(cat "$LOG")"
[ -s "$T/h/logs/ALERTS.log" ] && bad "a clock this box CAN fix is not an alert" || ok

# ── 2. idempotent: the next tick has nothing to do ───────────────────────────
run
[ "$(sets)" -eq 1 ] && ok || bad "the run after a set must change nothing (sets=$(sets))"
grep -q 'offset=0s within 30s' "$LOG" && ok || bad "the second run should report a zero offset: $(cat "$LOG")"

# a SLOW box, the fleet's actual shape, and a FAST one: both directions
setup -120
run
grep -q 'clock-sync: offset=-120 set' "$LOG" && ok || bad "a fast box must be corrected too: $(cat "$LOG")"

# ── 3. inside the tolerance nothing moves ────────────────────────────────────
setup 29
run
[ "$(sets)" -eq 0 ] && ok || bad "29s is inside the 30s tolerance and must not set the clock"
grep -q 'offset=29s within 30s' "$LOG" && ok || bad "the no-op must still say what it saw: $(cat "$LOG")"
setup -30
run
[ "$(sets)" -eq 0 ] && ok || bad "-30s is exactly the tolerance and must not set the clock"
# and the tolerance is a knob, not a constant
setup 45
run CLOCK_SYNC_TOLERANCE=60
[ "$(sets)" -eq 0 ] && ok || bad "CLOCK_SYNC_TOLERANCE must raise the floor"

# ── 4. the fallback source, and no source at all ─────────────────────────────
setup 300; : > "$T/gh-date"     # api.github.com answers nothing
run
[ "$(sets)" -eq 1 ] && ok || bad "a dead first source must fall through to the second"
grep -q 'source=https://www.cloudflare.com' "$LOG" && ok || bad "the fallback source must be named: $(cat "$LOG")"

setup 300; : > "$T/gh-date"; : > "$T/cf-date"
run
[ "$(sets)" -eq 0 ] && ok || bad "with no time source the clock must be left alone"
grep -q 'no time source answered' "$LOG" && ok || bad "a dead network must say so: $(cat "$LOG")"
[ -s "$T/h/logs/ALERTS.log" ] && bad "an unreachable time source is not an ALERT" || ok

# ── 5. a box with a real NTP daemon is not ours to touch ─────────────────────
setup 444; touch "$T/ntp"
run
[ "$(sets)" -eq 0 ] && ok || bad "an NTP daemon owns the clock — clock-sync must not set it"
grep -q 'NTP daemon owns this clock' "$LOG" && ok || bad "the skip must say why: $(cat "$LOG")"

# ── 6. denied: ONE actionable alert, however many ticks ──────────────────────
setup 444; touch "$T/deny-set"
run; run; run
[ "$(sets)" -eq 0 ] && ok || bad "a denied set must not be recorded as a set"
[ "$(grep -c 'clock-sync' "$T/h/logs/ALERTS.log" 2>/dev/null || echo 0)" -eq 1 ] \
  && ok || bad "a denied set must alert exactly once: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
grep -q 'NEEDED FROM' "$T/h/logs/ALERTS.log" \
  && ok || bad "the alert must name what is needed and from whom"
grep -q "DENIED" "$LOG" && ok || bad "the log must record the refusal too"

# ── 7. the kill switches ─────────────────────────────────────────────────────
setup 444
run CLOCK_SYNC=0
[ "$(sets)" -eq 0 ] && ok || bad "CLOCK_SYNC=0 must stop it"
[ -f "$LOG" ] && bad "CLOCK_SYNC=0 must cost nothing at all, not even a log line" || ok
setup 444; touch "$T/h/flags/clock-sync-off"
run
[ "$(sets)" -eq 0 ] && ok || bad "flags/clock-sync-off must stop it"
[ -f "$LOG" ] && bad "flags/clock-sync-off must cost nothing at all" || ok
# ... and CLOCK_SYNC=0 out of env/global.env, where an operator would put it
setup 444; printf 'CLOCK_SYNC=0\n' > "$T/h/env/global.env"
run
[ "$(sets)" -eq 0 ] && ok || bad "CLOCK_SYNC=0 in env/global.env must stop it"
: > "$T/h/env/global.env"

echo "clock-sync: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
