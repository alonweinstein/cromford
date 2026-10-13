#!/bin/bash
# tests/preplan-gates-contract.bh-2543-test.sh — BH-2543 slice 1: the contract
# the readiness and cadence children build on.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/preplan-gates-contract.bh-2543-test.sh
#
# WHAT THIS PINS AND WHY. Two gates are wired into the speculative loop of
# bin/preplan-tick.sh before a pre-plan session is bought:
#   - `# >>> preplan readiness (BH-2543)`: preplan_not_ready (bin/lib/preplan-ready.sh)
#     answers rc 0 + a reason for a key that is not ready; the tick logs it once
#     through preplan_small_log and skips the key;
#   - `# >>> preplan cadence (BH-2543)`: preplan_cadence_allow
#     (bin/lib/preplan-cadence.sh) answers rc 1 to hold a launch back.
# The cadence lib ships as a STUB that returns today's answer; the readiness
# lib carries the v1 rules (BH-2543.3), which this suite switches off with
# PREPLAN_READY_ONLY=0 so the real lib answers today's behaviour. The suite
# drives the REAL tick with the real libs, with test-local overrides, with the
# libs absent, and with each call site deleted (the mutation must go red).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait for the launch, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

READY_LIB="$DIR/bin/lib/preplan-ready.sh"
CADENCE_LIB="$DIR/bin/lib/preplan-cadence.sh"
NOTE="$DIR/docs/notes/2026-09-25-BH-2543-preplan-adoption.md"
REG="$DIR/catalog/lanes.d/preplan-tick.json"

export HARNESS="$T" FLEET_CONF="$T/fleet.conf" REPOS_ROOT="$T/repos"
# This suite pins the call-site wiring and fail-open; the readiness rules are
# pinned by tests/preplan-ready.bh-2543-test.sh. Knob 0 = today's behaviour.
export PREPLAN_READY_ONLY=0
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/locks" "$T/plans" \
         "$T/state" "$T/prompts" "$T/repos/proj"
cp "$DIR/bin/lib/preplan-lib.sh" "$T/bin/lib/"
for f in preplan-tick.sh fleet-conf.sh project-of.sh fleet-projects-or-alert.sh kind-gate.sh; do
  cp "$DIR/bin/$f" "$T/bin/"
done
: > "$T/env/global.env"
cat > "$T/fleet.conf" <<'CONF'
proj  example-org/proj   -   -   0 local -
CONF
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$T/prompts/proj.md"
printf '#!/bin/bash\necho local\n' > "$T/bin/box-name.sh"
cat > "$T/bin/preplan-candidates.sh" <<'SH'
#!/bin/bash
printf 'AB-1\t1\tblocked\nAB-2\t2\tahead\n'
SH
cat > "$T/bin/run-preplan.sh" <<'SH'
#!/bin/bash
echo "$3" >> "$HARNESS/launched.txt"
SH
chmod +x "$T/bin/box-name.sh" "$T/bin/preplan-candidates.sh" "$T/bin/run-preplan.sh"
( cd "$T/repos/proj" && git init -q -b main && git config user.email t@t && git config user.name t \
  && echo x > a && git add -A && git commit -qm base && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
printf '%s\n' 'AB-1 1 — ready project=proj' 'AB-2 2 — ready project=proj' > "$T/logs/READY-QUEUE.log"

# The real libs, and test-local overrides written over them per case.
real_libs() { cp "$READY_LIB" "$CADENCE_LIB" "$T/bin/lib/"; }
no_libs()   { rm -f "$T/bin/lib/preplan-ready.sh" "$T/bin/lib/preplan-cadence.sh"; }
ready_blocks_blocked() {
  cat > "$T/bin/lib/preplan-ready.sh" <<'SH'
preplan_ready_on() { return 0; }
preplan_not_ready() { [ "${4:-}" = blocked ] && { echo blocked-by-open; return 0; }; return 1; }
SH
}
cadence_denies() {  # $1 = class to deny, or "all"
  cat > "$T/bin/lib/preplan-cadence.sh" <<SH
preplan_adopt_stats() { return 1; }
preplan_cadence_cut() { return 1; }
preplan_cadence_allow() { [ "$1" = all ] && return 1; [ "\${3:-}" = "$1" ] && return 1; return 0; }
SH
}
reset() {
  : > "$T/launched.txt"; : > "$T/logs/preplan.log"
  rm -rf "$T/plans/"* "$T/state/"*.small "$T/state/preplan-candidates" 2>/dev/null
}
# tick [script] — run the tick, then wait for the setsid children it launched.
tick() {
  local s="${1:-$T/bin/preplan-tick.sh}" n want i
  PREPLAN_PARALLEL=3 bash "$s" >/dev/null 2>&1; TRC=$?
  want=$(grep -c 'pre-plan launch' "$T/logs/preplan.log" 2>/dev/null)
  for i in $(seq 1 30); do
    n=$(wc -l < "$T/launched.txt")
    [ "$n" -ge "${want:-0}" ] && break
    sleep 0.1
  done
  sleep 0.2
}
launched() { grep -qx "$1" "$T/launched.txt"; }
got() { tr '\n' ' ' < "$T/launched.txt"; }

# --- A. the real stub libs: today's behaviour --------------------------------
real_libs; reset; tick
[ "$TRC" = 0 ] && ok || bad "A0 the tick exits 0 with the stub libs (rc $TRC)"
launched AB-1 && ok || bad "A1 with the stub libs the blocked key still launches (launched: $(got))"
launched AB-2 && ok || bad "A1 with the stub libs the ahead key still launches (launched: $(got))"
grep -q 'not-ready:' "$T/logs/preplan.log" && bad "A2 the stub readiness gate logs nothing" || ok

# --- B. readiness override: not-ready key skipped, logged once ---------------
real_libs; ready_blocks_blocked; reset; tick
launched AB-1 && bad "B1 a not-ready key must not launch (launched: $(got))" || ok
launched AB-2 && ok || bad "B1 the ready key still launches (launched: $(got))"
N=$(grep -c 'not-ready:' "$T/logs/preplan.log")
[ "$N" = 1 ] && ok || bad "B2 exactly one not-ready: line (got $N)"
grep -q '\[proj/AB-1\] PREPLAN_SKIP small: not-ready: blocked-by-open' "$T/logs/preplan.log" && ok \
  || bad "B2 the line names AB-1 and the reason (log: $(tail -3 "$T/logs/preplan.log"))"
: > "$T/launched.txt"; tick
N=$(grep -c 'not-ready:' "$T/logs/preplan.log")
[ "$N" = 1 ] && ok || bad "B3 still one not-ready: line after a second tick (got $N)"
launched AB-1 && bad "B3 the second tick still skips the not-ready key" || ok

# B4 the readiness gate present but the logger missing (an old preplan-lib.sh):
# no silent skip. Only preplan_small_log goes — the rest of preplan-lib.sh stays,
# so the tick is still on the speculative path this block lives in.
echo 'unset -f preplan_small_log' >> "$T/bin/lib/preplan-ready.sh"; reset; tick
grep -q 'pre-plan launch (blocked' "$T/logs/preplan.log" && ok || bad "B4 the tick must still be on the speculative path"
launched AB-1 && ok || bad "B4 with no preplan_small_log the readiness gate must not skip silently (launched: $(got))"

# --- C. cadence override: denied keys never launch, FREE not consumed --------
real_libs; cadence_denies all; reset; tick
[ -s "$T/launched.txt" ] && bad "C1 a cadence deny must launch nothing (launched: $(got))" || ok
grep -q 'pre-plan launch' "$T/logs/preplan.log" && bad "C1 no launch line is written for a denied key" || ok
real_libs; cadence_denies blocked; reset; tick
launched AB-1 && bad "C2 the denied class must not launch (launched: $(got))" || ok
# PREPLAN_PARALLEL is 3 in tick(); force a cap of 1 so a consumed slot would starve AB-2.
real_libs; cadence_denies blocked; reset
PREPLAN_PARALLEL=1 bash "$T/bin/preplan-tick.sh" >/dev/null 2>&1; wait_for 10 launched AB-2
launched AB-2 && ok || bad "C3 at a cap of 1, a denied AB-1 must not consume the slot: AB-2 launches (launched: $(got))"

# --- D. both libs absent: fail open ------------------------------------------
no_libs; reset; tick
[ "$TRC" = 0 ] && ok || bad "D1 the tick exits 0 with the libs absent (rc $TRC)"
launched AB-1 && launched AB-2 && ok || bad "D1 with the libs absent both keys launch (launched: $(got))"

# --- E. mutation: each call site deleted turns its case red ------------------
mutant() {  # $1 = block name; writes $T/bin/preplan-tick.mut.sh without it
  local tag="$1"
  sed "/# >>> preplan $tag (BH-2543)/,/# <<< preplan $tag\$/d" "$T/bin/preplan-tick.sh" > "$T/bin/preplan-tick.mut.sh"
  cmp -s "$T/bin/preplan-tick.sh" "$T/bin/preplan-tick.mut.sh" && return 1
  return 0
}
real_libs; ready_blocks_blocked; reset
if mutant readiness; then
  tick "$T/bin/preplan-tick.mut.sh"
  launched AB-1 && ok || bad "E1 with the readiness call site deleted, B's assertion must go red (AB-1 launches)"
else bad "E1 the readiness block marker is missing from bin/preplan-tick.sh"; fi
real_libs; cadence_denies all; reset
if mutant cadence; then
  tick "$T/bin/preplan-tick.mut.sh"
  [ -s "$T/launched.txt" ] && ok || bad "E2 with the cadence call site deleted, C's assertion must go red (something launches)"
else bad "E2 the cadence block marker is missing from bin/preplan-tick.sh"; fi
rm -f "$T/bin/preplan-tick.mut.sh"

# --- F. the stub libs, sourced -----------------------------------------------
F=$(PREPLAN_READY_ONLY=0 bash -c '. "$1"; o=$(preplan_not_ready /tmp p K blocked); echo "$?[$o]"' _ "$READY_LIB")
[ "$F" = "1[]" ] && ok || bad "F1 preplan_not_ready knob 0: rc 1, prints nothing (got $F)"
bash -c 'unset PREPLAN_READY_ONLY; . "$1"; preplan_ready_on /tmp' _ "$READY_LIB" && ok || bad "F2 preplan_ready_on defaults on"
PREPLAN_READY_ONLY=1 bash -c '. "$1"; preplan_ready_on /tmp' _ "$READY_LIB" && ok || bad "F2 PREPLAN_READY_ONLY=1 is on"
PREPLAN_READY_ONLY=0 bash -c '. "$1"; preplan_ready_on /tmp' _ "$READY_LIB" && bad "F2 PREPLAN_READY_ONLY=0 is off" || ok
F=$(bash -c 'lane_knob() { [ "$1 $2" = "preplan-tick PREPLAN_READY_ONLY" ] && echo 0; }; . "$1"; preplan_ready_on /tmp; echo $?' _ "$READY_LIB")
[ "$F" = 1 ] && ok || bad "F2 preplan_ready_on reads lane_knob preplan-tick PREPLAN_READY_ONLY (got rc $F)"
F=$(bash -c 'set -u; . "$1"; o=$(preplan_adopt_stats /tmp p); s=$?; preplan_cadence_cut /tmp p; c=$?; preplan_cadence_allow /tmp p ahead; a=$?; echo "$s $c $a [$o]"' _ "$CADENCE_LIB")
[ "$F" = "1 1 0 []" ] && ok || bad "F3 cadence stubs: adopt_stats rc1 silent, cut rc1, allow rc0 (got $F)"

# --- G. the six knob rows ----------------------------------------------------
knob() {  # env type default min max zero_means read_in
  jq -e --arg e "$1" --arg t "$2" --argjson d "$3" --argjson mn "$4" --argjson mx "$5" \
        --argjson z "$6" --arg r "$7" \
    '.knobs[] | select(.env==$e) | select(.type==$t and .default==$d and .min==$mn and .max==$mx and .zero_means==$z and .read_in==$r)' \
    "$REG" >/dev/null 2>&1 && ok || bad "G the $1 knob row (type/default/min/max/zero_means/read_in)"
}
knob PREPLAN_READY_ONLY        int 1    0  1     '"off"' bin/lib/preplan-ready.sh
knob PREPLAN_ADOPT_FLOOR_PCT   int 50   0  100   '"off"' bin/lib/preplan-cadence.sh
knob PREPLAN_ADOPT_MIN_SAMPLES int 10   1  1000  null    bin/lib/preplan-cadence.sh
knob PREPLAN_ADOPT_WINDOW_DAYS int 7    1  30    null    bin/lib/preplan-cadence.sh
knob PREPLAN_CUT_INTERVAL_S    int 1800 60 86400 null    bin/lib/preplan-cadence.sh
knob PREPLAN_ADOPT_CACHE_S     int 900  0  3600  null    bin/lib/preplan-cadence.sh

# --- H. the route contract is written down in both places --------------------
for f in "$CADENCE_LIB" "$NOTE"; do
  for s in '/api/preplans/adoption' 'recent_truncated' "stage='preplan'"; do
    grep -qF "$s" "$f" 2>/dev/null && ok || bad "H $(basename "$f") must pin $s"
  done
done
grep -qx 'Doc: EVENTS' "$NOTE" 2>/dev/null && ok || bad "H the dated note carries Doc: EVENTS"

echo "preplan-gates-contract.bh-2543: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
