#!/bin/bash
# tests/untriaged-sweep-gate-test.sh — the SHIPPED bin/untriaged-sweep.sh, run
# under a stopped switch, must not touch a single client board (BH-1165 review).
#
# WHY THIS FILE EXISTS. The lane's gate header was pasted in at the bottom of
# the script, after three of its four board sweeps. `bin/harness-ctl.sh all-off
# "incident"` therefore stopped a quarter of the lane: at the next */30 tick the
# hub still curled the project-1, project-2 and project-3 boards with each client's
# internal API token, wrote their `UNTRIAGED >1h` ALERTS lines and beat for
# them — and then wrote `untriaged-sweep SKIPPED — all-off` into
# logs/lane-gate.log, so the operator's stop looked like it had taken. Section 5
# of tests/lanes-registry-test.sh could not see it: it lifts the header's two
# lines out of the script and runs them on their own, which proves the header
# WORKS, never where it sits. Section 19 of that suite now orders the gate
# against the lane's first outbound command for all 77 wired lanes; this file is
# the same fact for this lane behaviourally — the real script, a real `curl` on
# PATH, counting the hosts it reached.
#
# What is proved here:
#   1. flags/all-off              -> ZERO board requests, ZERO beats, rc 0, and
#                                    the SKIPPED line is written;
#   2. flags/lane-off-untriaged-sweep -> the same;
#   3. no flag at all             -> all FOUR boards are reached. Without this
#      control, 1 and 2 would pass just as happily on a script that cannot run
#      at all, which is the way a zero-work assertion usually lies.
# Run from anywhere: tests/untriaged-sweep-gate-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/state" "$H/catalog" "$T/shim"
cp "$DIR/bin/untriaged-sweep.sh" "$H/bin/"          # the SHIPPED bytes, unedited
cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/untriaged-board-read.sh" "$H/bin/lib/"
cp "$(rendered_registry)" "$H/catalog/lanes.json"
chmod +x "$H/bin/untriaged-sweep.sh"

cat > "$H/env/global.env" <<'E'
JOBS_BOX=probe-box
E
cat > "$H/env/project-1.env" <<'E'
PROJECT_1_API_BASE=https://m.example
PROJECT_1_INTERNAL_API_TOKEN=tok-m
E
cat > "$H/env/project-2.env" <<'E'
PROJECT_2_APP_BASE=https://t.example
PROJECT_2_INTERNAL_API_TOKEN=tok-t
E
cat > "$H/env/project-3.env" <<'E'
PROJECT_3_APP_BASE=https://o.example
PROJECT_3_INTERNAL_API_TOKEN=tok-o
E
cat > "$H/env/project-4.env" <<'E'
PROJECT_4_API_BASE=https://c.example
PROJECT_4_INTERNAL_API_TOKEN=tok-c
E

# The shims. `curl` records every URL it was asked for and answers with an empty
# board list, so one request per sweep is enough to prove the lane left the box;
# `beat.sh` records that a client was paged.
cat > "$T/shim/curl" <<'SH'
#!/bin/bash
for a in "$@"; do case "$a" in http*) echo "$a" >> "$CURLLOG" ;; esac; done
printf '[]'
SH
chmod +x "$T/shim/curl"
cat > "$H/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$BEATLOG"
SH
chmod +x "$H/bin/beat.sh"

CURLLOG="$T/curl.log"; BEATLOG="$T/beat.log"
run() { # run -> rc of the shipped lane, with the logs reset
  : > "$CURLLOG"; : > "$BEATLOG"
  scratch_rm "$H/state/lane-gate" >/dev/null 2>&1
  scratch_rm "$H/logs/lane-gate.log" >/dev/null 2>&1
  env PATH="$T/shim:$PATH" HARNESS="$H" CURLLOG="$CURLLOG" BEATLOG="$BEATLOG" \
      bash "$H/bin/untriaged-sweep.sh" >/dev/null 2>&1
}
hosts() { sed -E 's#^(https?://[^/]+).*#\1#' "$CURLLOG" 2>/dev/null | sort -u | tr '\n' ' '; }

# --- 3 first: the CONTROL. Without a flag the lane really does reach all four
# boards, so the zero-request assertions below are about the gate and not about
# a probe that never drove anything.
rm -f "$H/flags"/*
run; RC=$?
N=$(sort -u "$CURLLOG" | wc -l | tr -d ' ')
[ "$RC" -eq 0 ] || bad "3a ungated lane exited $RC"
[ "$RC" -eq 0 ] && ok
if [ "$N" -eq 4 ]; then ok; else bad "3b ungated lane reached $N boards (want 4): $(hosts)"; fi

# --- 1. flags/all-off: nothing leaves this box.
: > "$H/flags/all-off"
run; RC=$?
N=$(wc -l < "$CURLLOG" | tr -d ' ')
B=$(wc -l < "$BEATLOG" | tr -d ' ')
if [ "$N" -eq 0 ]; then ok; else bad "1a all-off still curled $N board request(s): $(hosts)"; fi
if [ "$B" -eq 0 ]; then ok; else bad "1b all-off still beat $B time(s) for a client"; fi
[ "$RC" -eq 0 ] && ok || bad "1c a gated tick exited $RC (cron mails on nonzero)"
grep -q 'untriaged-sweep SKIPPED' "$H/logs/lane-gate.log" 2>/dev/null && ok \
  || bad "1d the skip was not recorded in logs/lane-gate.log"
rm -f "$H/flags/all-off"

# --- 2. the lane's own switch.
: > "$H/flags/lane-off-untriaged-sweep"
run
N=$(wc -l < "$CURLLOG" | tr -d ' ')
B=$(wc -l < "$BEATLOG" | tr -d ' ')
if [ "$N" -eq 0 ] && [ "$B" -eq 0 ]; then ok
else bad "2 lane-off-untriaged-sweep still made $N board request(s) and $B beat(s): $(hosts)"; fi
rm -f "$H/flags/lane-off-untriaged-sweep"

echo "untriaged-sweep-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
