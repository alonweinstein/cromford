#!/bin/bash
# tests/tz-check.bh-445-test.sh — bin/lib/tz-check.sh driven through BOTH of its
# production callers (bin/healthcheck.sh, bin/clock-sync.sh) and once on its
# own, against a scratch tree. Nothing here touches the real /tmp, the real
# clock or a real alert path.
#
# WHY THE CHECK EXISTS (2026-09-15). The hub was on CDT. Every log line, alert
# and forensic timestamp it wrote was five hours off, and the first pass over
# the wipe (#388) burned those five hours reconciling stamps that disagreed.
# A box whose timezone is not UTC must say so, loudly, from a lane that runs on
# every box, which is why the same lib hangs off healthcheck.sh (prod-bearing
# projects, 43 6,18) AND clock-sync.sh (every cron file including hub.cron).
#
# What is proved here:
#   1. healthcheck on a non-UTC box fires exactly one critical alert, keyed
#      tz:<box-id>, naming the zone, carrying a fix that works on a box with no
#      systemd, and its own exit code is unchanged;
#   2. healthcheck on a UTC box resolves ONLY while an alert row is open: no
#      row and a closed row both make no call at all, so a healthy box writes
#      no resolve-silent line every half hour for the life of the box;
#   3. TZ_CHECK=0 in the environment silences it, with no call at all;
#   4. TZ_CHECK=0 in env/global.env silences it too. healthcheck never sources
#      that file, so the lib reads the key itself or the documented kill switch
#      is a lie on this lane;
#   5. the PRODUCTION detection path (`date +%Z`, no TZ_OVERRIDE) both fires
#      and stays quiet, driven by POSIX TZ strings that need no tzdata;
#   6. the clock-sync hook fires on a non-UTC box without ever setting a clock;
#   7. CLOCK_SYNC=0 and flags/clock-sync-off stop everything, TZ check included;
#   8. the lib alone: no state/box-id falls back to $(hostname), a non-UTC box
#      returns 1, and a `date +%Z` that prints nothing alerts as "unknown";
#   9. the lib does not reintroduce a hardcoded env path (tests/env-path-test.sh
#      scans bin/**/*.sh live; this is the same program over the one new file).
# Every healthcheck section also asserts the stubbed `find` ran, which is the
# proof the real /tmp sweep was never let loose on this machine.
# Run from anywhere: tests/tz-check.bh-445-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
HOST=$(hostname)
REALDATE=$(command -v date)
EMDASH=$'\xe2\x80\x94'

mkdir -p "$T/fakebin" "$T/fakebin-noz" "$T/h/bin/lib" "$T/h/logs" "$T/h/state" \
         "$T/h/state/alerts" "$T/h/flags" "$T/h/env"
cp "$DIR/bin/lib/tz-check.sh" "$T/h/bin/lib/" || { echo "FAIL: bin/lib/tz-check.sh is missing"; exit 1; }
cp "$DIR/bin/lib/env-path.sh" "$T/h/bin/lib/"
cp "$DIR/bin/healthcheck.sh" "$DIR/bin/clock-sync.sh" "$T/h/bin/"
chmod +x "$T/h/bin/healthcheck.sh" "$T/h/bin/clock-sync.sh"
: > "$T/h/env/global.env"

# --- the recorder ------------------------------------------------------------
# Its own location, not $HARNESS, decides where it writes: the lib must be able
# to call it without anything being exported, and a recorder that silently
# wrote nowhere would make every "0 calls" assertion below vacuous.
cat > "$T/h/bin/lane-alert.sh" <<'SH'
#!/bin/bash
D=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$D/logs"
printf '%s\n' "$*" >> "$D/logs/lane-alert.calls"
SH
printf '#!/bin/bash\nexit 0\n'   > "$T/h/bin/beat.sh"
printf '#!/bin/bash\necho -\n'   > "$T/h/bin/prod-url.sh"
# healthcheck's `# >>> hardened report` block (#689) pages when the box's
# hardening figure is short or unknown; a fixture with no harden-state.sh reads
# as unknown and writes an ALERTS line that is not this lane's, which would make
# every "no ALERTS line" assertion below fail for the wrong reason.
printf '#!/bin/bash\necho hardened=1/1\n' > "$T/h/bin/harden-state.sh"
chmod +x "$T/h/bin/lane-alert.sh" "$T/h/bin/beat.sh" "$T/h/bin/prod-url.sh" \
         "$T/h/bin/harden-state.sh"

# --- the stubs on PATH -------------------------------------------------------
# find prints NOTHING (the sweep's rm loop gets no input) and leaves a marker,
# so every healthcheck section can prove the real /tmp was never scanned.
cat > "$T/fakebin/find" <<SH
#!/bin/bash
touch "$T/find-called"
exit 0
SH
# date refuses to set the clock and records the attempt; everything else is the
# real date, because \`date +%Z\` is the production path section 5 exercises.
cat > "$T/fakebin/date" <<SH
#!/bin/bash
R="$REALDATE"
T="$T"
SH
cat >> "$T/fakebin/date" <<'SH'
if [ "${1:-}" = -u ] && [ "${2:-}" = -s ]; then
  printf '%s\n' "$*" >> "$T/set.log"
  echo "date: cannot set date: Operation not permitted" >&2
  exit 1
fi
exec "$R" "$@"
SH
# The same date, except `+%Z` prints nothing. A box with a broken TZ setup is
# the only way to reach the "unknown" branch, and it is reached through the
# production expression, not by handing the lib an empty override.
cat > "$T/fakebin-noz/date" <<SH
#!/bin/bash
R="$REALDATE"
SH
cat >> "$T/fakebin-noz/date" <<'SH'
[ "${1:-}" = +%Z ] && exit 0
exec "$R" "$@"
SH
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/curl"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/pgrep"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/timedatectl"
chmod +x "$T/fakebin/find" "$T/fakebin/date" "$T/fakebin/curl" \
         "$T/fakebin/pgrep" "$T/fakebin/timedatectl" "$T/fakebin-noz/date"

CALLS="$T/h/logs/lane-alert.calls"
ROWS="$T/h/state/alerts"
reset() { rm -f "$CALLS" "$T/h/logs/ALERTS.log" "$T/find-called" "$T/set.log" \
                "$ROWS"/*.json; }
calls() { [ -f "$CALLS" ] && wc -l < "$CALLS" || echo 0; }
said()  { cat "$CALLS" 2>/dev/null; }
# An OPEN lifecycle row, exactly the shape bin/lib/alert-state.sh writes on a
# fire, under the SANITISED filename (as_sanitize_id folds ":" to "_").
open_row()   { printf '%s\n' '{"first_seen":1,"last_seen":1,"last_notified":1,"count":1,"severity":"critical","resolved_at":0,"line":"tz"}' > "$ROWS/tz_$1.json"; }
# ...and the same row after a resolve: alert_state_resolve stamps resolved_at
# and KEEPS the file, so file-existence alone is not "something is open".
closed_row() { printf '%s\n' '{"first_seen":1,"last_seen":1,"last_notified":1,"count":1,"severity":"critical","resolved_at":1700000000,"line":"tz"}' > "$ROWS/tz_$1.json"; }
# first-occurrence order of two substrings inside one string
before() {
  local s="$1" a="$2" b="$3" pa pb
  pa=${s%%"$a"*}; [ "$pa" = "$s" ] && return 1
  pb=${s%%"$b"*}; [ "$pb" = "$s" ] && return 1
  [ ${#pa} -lt ${#pb} ]
}
hc() { env PATH="$T/fakebin:$PATH" HARNESS="$T/h" "$@" \
         bash "$T/h/bin/healthcheck.sh" alpha-os >/dev/null 2>&1; }
cs() { env PATH="$T/fakebin:$PATH" HARNESS="$T/h" "$@" \
         bash "$T/h/bin/clock-sync.sh" >/dev/null 2>&1; }
lib() { env PATH="$T/fakebin:$PATH" HARNESS="$T/h" "$@" \
          bash -c '. "$HARNESS/bin/lib/tz-check.sh"; tz_check "$HARNESS"' >/dev/null 2>&1; }
lib_noz() { env PATH="$T/fakebin-noz:$PATH" HARNESS="$T/h" "$@" \
          bash -c '. "$HARNESS/bin/lib/tz-check.sh"; tz_check "$HARNESS"' >/dev/null 2>&1; }

echo small > "$T/h/state/box-id"

# ── 1. healthcheck on a CDT box: one critical alert, exit code untouched ─────
reset
hc TZ_OVERRIDE=CDT; RC=$?
[ "$RC" -eq 0 ] && ok || bad "the TZ result must not change healthcheck's exit code (rc=$RC)"
[ "$(calls)" -eq 1 ] && ok || bad "a non-UTC box must alert exactly once (calls=$(calls))"
grep -q -- '--critical --id tz:small' "$CALLS" 2>/dev/null \
  && ok || bad "the alert must be critical and keyed tz:small: $(said)"
grep -q -- '--severity critical' "$CALLS" 2>/dev/null \
  && ok || bad "the alert must carry --severity critical: $(said)"
grep -q 'CDT' "$CALLS" 2>/dev/null \
  && ok || bad "the alert must name the zone it saw: $(said)"
[ -f "$T/find-called" ] && ok || bad "the stubbed find must have run (the real /tmp is never swept)"
# These containers have no systemd. A fix line that leads with timedatectl is a
# fix the operator cannot run, so the symlink form comes first.
before "$(said)" 'ln -sf /usr/share/zoneinfo/Etc/UTC' 'timedatectl' \
  && ok || bad "the fix must lead with the symlink form, not timedatectl: $(said)"
grep -q 'echo Etc/UTC > /etc/timezone' "$CALLS" 2>/dev/null \
  && ok || bad "the fix must also write /etc/timezone: $(said)"
case "$(said)" in *"$EMDASH"*) bad "alert text must carry no em dash: $(said)" ;; *) ok ;; esac

# ── 2. healthcheck on a UTC box: resolve only while something is open ────────
reset
hc TZ_OVERRIDE=UTC
[ "$(calls)" -eq 0 ] && ok || bad "a UTC box with no open row must make no call: $(said)"
[ -s "$T/h/logs/ALERTS.log" ] && bad "a UTC box must write no ALERTS line" || ok
[ -f "$T/find-called" ] && ok || bad "the stubbed find must have run on the UTC path too"
reset
open_row small
hc TZ_OVERRIDE=UTC
[ "$(calls)" -eq 1 ] && ok || bad "a UTC box with an OPEN row resolves exactly once (calls=$(calls))"
grep -q -- '--resolve --id tz:small' "$CALLS" 2>/dev/null \
  && ok || bad "a recovered box must resolve the id: $(said)"
grep -q -- '--critical' "$CALLS" 2>/dev/null \
  && bad "a UTC box must never raise a critical: $(said)" || ok
reset
closed_row small
hc TZ_OVERRIDE=UTC
[ "$(calls)" -eq 0 ] && ok || bad "an already-resolved row must not be resolved again every tick: $(said)"

# ── 3. the kill switch in the environment ───────────────────────────────────
reset
hc TZ_CHECK=0 TZ_OVERRIDE=CDT
[ "$(calls)" -eq 0 ] && ok || bad "TZ_CHECK=0 must make no call at all: $(said)"
[ -f "$T/find-called" ] && ok || bad "TZ_CHECK=0 must not stop the rest of healthcheck"

# ── 4. the kill switch where it is DOCUMENTED: env/global.env ───────────────
# healthcheck.sh does not source global.env and never will (it would widen the
# environment of every child it spawns), so the lib reads the one key itself.
reset
printf 'TZ_CHECK=0\n' > "$T/h/env/global.env"
hc TZ_OVERRIDE=CDT
[ "$(calls)" -eq 0 ] && ok || bad "TZ_CHECK=0 in env/global.env must reach healthcheck: $(said)"
# ...and it is the KEY that silenced it, not the file merely being there.
reset
: > "$T/h/env/global.env"
hc TZ_OVERRIDE=CDT
[ "$(calls)" -eq 1 ] && ok || bad "an empty global.env must leave the check ON (calls=$(calls))"
reset
printf 'export TZ_CHECK="0"\n' > "$T/h/env/global.env"
hc TZ_OVERRIDE=CDT
[ "$(calls)" -eq 0 ] && ok || bad "the export/quoted form of the switch must be honoured: $(said)"
reset
printf 'TZ_CHECK=1\n' > "$T/h/env/global.env"
hc TZ_OVERRIDE=CDT
[ "$(calls)" -eq 1 ] && ok || bad "only 0 turns the check off (calls=$(calls))"
: > "$T/h/env/global.env"

# ── 5. the production path: date +%Z, no override ───────────────────────────
# POSIX TZ strings, so this is deterministic on a box with no tzdata and has no
# DST edge to pick a red day on.
reset
hc TZ=JST-9
[ "$(calls)" -eq 1 ] && ok || bad "date +%Z must drive the check with no TZ_OVERRIDE (calls=$(calls))"
grep -q 'JST' "$CALLS" 2>/dev/null \
  && ok || bad "the real zone name must reach the alert: $(said)"
reset
open_row small
hc TZ=UTC0
[ "$(calls)" -eq 1 ] && ok || bad "a real UTC box with an open row makes one call (calls=$(calls))"
grep -q -- '--resolve' "$CALLS" 2>/dev/null \
  && ok || bad "a real UTC box must only resolve: $(said)"
reset
hc TZ=UTC0
[ "$(calls)" -eq 0 ] && ok || bad "a real UTC box with nothing open stays silent: $(said)"

# ── 6. the clock-sync hook: the lane that covers the hub ────────────────────
reset
cs TZ_OVERRIDE=CDT; RC=$?
[ "$RC" -eq 0 ] && ok || bad "the TZ result must not change clock-sync's exit code (rc=$RC)"
[ "$(calls)" -eq 1 ] && ok || bad "clock-sync must alert once on a non-UTC box (calls=$(calls))"
grep -q 'tz:small' "$CALLS" 2>/dev/null \
  && ok || bad "the clock-sync alert must carry the box id: $(said)"
[ -e "$T/set.log" ] && bad "a timezone check must never touch the clock: $(cat "$T/set.log")" || ok

# ── 7. both kill switches stop everything, the TZ check included ────────────
reset
cs CLOCK_SYNC=0 TZ_OVERRIDE=CDT
[ "$(calls)" -eq 0 ] && ok || bad "CLOCK_SYNC=0 must stop the TZ check too: $(said)"
reset
touch "$T/h/flags/clock-sync-off"
cs TZ_OVERRIDE=CDT
[ "$(calls)" -eq 0 ] && ok || bad "flags/clock-sync-off must stop the TZ check too: $(said)"
rm -f "$T/h/flags/clock-sync-off"

# ── 8. the lib alone, with no state/box-id ──────────────────────────────────
rm -f "$T/h/state/box-id"
reset
open_row "$HOST"
lib TZ_OVERRIDE=UTC; RC=$?
[ "$RC" -eq 0 ] && ok || bad "a UTC box returns 0 (rc=$RC)"
[ "$(calls)" -eq 1 ] && ok || bad "one call on UTC with an open row (calls=$(calls))"
grep -q -- "--resolve --id tz:$HOST" "$CALLS" 2>/dev/null \
  && ok || bad "with no state/box-id the id must fall back to \$(hostname)=$HOST: $(said)"
reset
lib TZ_OVERRIDE=CDT; RC=$?
[ "$RC" -eq 1 ] && ok || bad "a non-UTC box returns 1 (rc=$RC)"
grep -q 'not UTC' "$CALLS" 2>/dev/null \
  && ok || bad "the alert must say the box is not UTC: $(said)"
grep -q -- "--id tz:$HOST" "$CALLS" 2>/dev/null \
  && ok || bad "the firing id must use the hostname fallback too: $(said)"
# A `date +%Z` that prints nothing is a broken TZ setup, not a UTC box.
reset
lib_noz; RC=$?
[ "$RC" -eq 1 ] && ok || bad "an empty zone must alert, not pass (rc=$RC)"
grep -q 'unknown' "$CALLS" 2>/dev/null \
  && ok || bad "an empty zone must be reported as unknown: $(said)"
echo small > "$T/h/state/box-id"

# ── 9. the env-path ratchet, on the one new file ────────────────────────────
# tests/env-path-test.sh scans bin/**/*.sh live with this program and is the
# authoritative check; running it here means a regression names THIS file.
OFF=$(awk -v file="$DIR/bin/lib/tz-check.sh" '
  /^[[:space:]]*#/ { next }
  /lib\/env-path\.sh/ { next }
  /\/run\/harness-env/ { next }
  /env-templates\// { next }
  /HARNESS\/env|\/root\/harness\/env|\$H\/env|\)\/env/ { print file ":" NR }
' "$DIR/bin/lib/tz-check.sh")
[ -z "$OFF" ] && ok || bad "the lib must resolve the env dir through harness_env_dir, not a literal path: $OFF"

echo "tz-check-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
