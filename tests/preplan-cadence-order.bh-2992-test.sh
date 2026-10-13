#!/bin/bash
# tests/preplan-cadence-order.bh-2992-test.sh — BH-2998 (BH-2992.4): the
# cadence gate runs BEFORE the stale re-plan spends anything.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/preplan-cadence-order.bh-2992-test.sh
#
# WHAT THIS PINS AND WHY. In the speculative loop of bin/preplan-tick.sh a
# stale plan used to be dropped, and its re-plan counted in
# state/preplan/<p>-<k>.replans, before the `# >>> preplan cadence (BH-2543)`
# block had decided whether anything would launch. A cadence deny then
# `continue`d with nothing launched: one unit of PREPLAN_STALE_MAX burnt and a
# plan the build stage could have adopted or discarded for free thrown away.
# The order is now: fresh-plan continue, cadence, re-plan cap + drop, launch.
# Every case drives the REAL tick; O4 moves the cadence block back and must go
# red.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T" FLEET_CONF="$T/fleet.conf" REPOS_ROOT="$T/repos"
export PREPLAN_READY_ONLY=0
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/locks" "$T/plans" \
         "$T/state" "$T/prompts" "$T/repos/proj"
cp "$DIR/bin/lib/preplan-lib.sh" "$T/bin/lib/"
for f in preplan-tick.sh fleet-conf.sh project-of.sh fleet-projects-or-alert.sh kind-gate.sh; do
  cp "$DIR/bin/$f" "$T/bin/"
done
# Readiness is not what this suite is about: no lib, no gate.
rm -f "$T/bin/lib/preplan-ready.sh"
: > "$T/env/global.env"
cat > "$T/fleet.conf" <<'CONF'
proj  example-org/proj   -   -   0 local -
CONF
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$T/prompts/proj.md"
printf '#!/bin/bash\necho local\n' > "$T/bin/box-name.sh"
cat > "$T/bin/preplan-candidates.sh" <<'SH'
#!/bin/bash
printf 'AB-1\t1\tahead\n'
SH
cat > "$T/bin/run-preplan.sh" <<'SH'
#!/bin/bash
echo "$3" >> "$HARNESS/launched.txt"
SH
chmod +x "$T/bin/box-name.sh" "$T/bin/preplan-candidates.sh" "$T/bin/run-preplan.sh"
( cd "$T/repos/proj" && git init -q -b main && git config user.email t@t && git config user.name t \
  && mkdir -p src/lib && echo x > src/lib/pay.ts && git add -A && git commit -qm base \
  && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
printf '%s\n' 'AB-1 1 — ready project=proj' > "$T/logs/READY-QUEUE.log"

PD="$T/plans/proj-AB-1"
REPLANS="$T/state/preplan/proj-AB-1.replans"
CLAST="$T/state/preplan/cadence-proj.last"
CALLS="$T/cadence-calls.txt"

# The cadence lib, stubbed per case. Every call is recorded; the allow stub
# stamps cadence-<p>.last the way the real lib does on allow.
cadence() {  # $1 = allow | deny
  local rc=0; [ "$1" = deny ] && rc=1
  cat > "$T/bin/lib/preplan-cadence.sh" <<SH
preplan_adopt_stats() { return 1; }
preplan_cadence_cut() { return 1; }
preplan_cadence_allow() {
  echo "\$2 \$3" >> "$CALLS"
  [ $rc = 0 ] && { mkdir -p "\$1/state/preplan"; touch "\$1/state/preplan/cadence-\$2.last"; }
  return $rc
}
SH
}
seed_plan() {  # a pre-plan for AB-1 pinned to main as it stands now
  mkdir -p "$PD"
  printf 'plan\nTouch src/lib/pay.ts\n' > "$PD/plan.md"
  git -C "$T/repos/proj" rev-parse origin/main > "$PD/base-sha"
  echo 'src/lib/pay.ts' > "$PD/planned-files.txt"
}
move_planned() {  # main moves in the file the plan named: the plan is stale
  ( cd "$T/repos/proj" && echo more >> src/lib/pay.ts && git add -A \
    && git commit -qm "moved planned" && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
}
reset() {
  rm -rf "$T/plans/"* "$T/state/"* 2>/dev/null
  : > "$T/launched.txt"; : > "$T/logs/preplan.log"; : > "$CALLS"
}
tick() {  # [script] — run the tick, then wait for the setsid child it launched
  local s="${1:-$T/bin/preplan-tick.sh}" want i
  PREPLAN_PARALLEL=3 bash "$s" >/dev/null 2>&1; TRC=$?
  want=$(grep -c 'pre-plan launch' "$T/logs/preplan.log" 2>/dev/null)
  for i in $(seq 1 30); do
    [ "$(wc -l < "$T/launched.txt")" -ge "${want:-0}" ] && break
    sleep 0.1
  done
  sleep 0.2
}
lines() { local n; n=$(grep -c . "$1" 2>/dev/null); printf '%s\n' "${n:-0}"; }
stale_lines() { local n; n=$(grep -c 'PREPLAN_STALE' "$T/logs/preplan.log" 2>/dev/null); printf '%s\n' "${n:-0}"; }

# o1 <tag> [script] — stale plan + cadence deny; returns the failure count.
o1() {
  local tag="$1" s="${2:-}" f=0
  cadence deny; reset; seed_plan; move_planned
  tick $s
  [ "$TRC" = 0 ] || { echo "FAIL: $tag the tick exits 0 (rc $TRC)"; f=$((f+1)); }
  [ -s "$PD/plan.md" ] || { echo "FAIL: $tag a cadence deny must keep the stale plan on disk"; f=$((f+1)); }
  [ "$(lines "$REPLANS")" = 0 ] || { echo "FAIL: $tag a cadence deny must count no re-plan (.replans has $(lines "$REPLANS") lines)"; f=$((f+1)); }
  [ "$(stale_lines)" = 0 ] || { echo "FAIL: $tag a cadence deny must log no PREPLAN_STALE line"; f=$((f+1)); }
  [ -s "$T/launched.txt" ] && { echo "FAIL: $tag a cadence deny launches nothing"; f=$((f+1)); }
  [ "$(lines "$CALLS")" = 1 ] || { echo "FAIL: $tag cadence is asked once for the stale key (got $(lines "$CALLS"))"; f=$((f+1)); }
  return "$f"
}

# --- O1 stale plan + cadence deny: nothing spent -----------------------------
o1 O1; n=$?
[ "$n" = 0 ] && ok || { FAIL=$((FAIL+n)); }

# --- O2 stale plan + cadence allow: the old behaviour ------------------------
cadence allow; reset; seed_plan; move_planned
tick
[ "$(lines "$REPLANS")" = 1 ] && ok || bad "O2 one re-plan counted (.replans has $(lines "$REPLANS") lines)"
[ -e "$PD/plan.md" ] && bad "O2 the stale plan is dropped" || ok
[ "$(stale_lines)" = 1 ] && ok || bad "O2 exactly one PREPLAN_STALE line (got $(stale_lines))"
[ "$(grep -cx AB-1 "$T/launched.txt")" = 1 ] && ok || bad "O2 AB-1 launched once (launched: $(tr '\n' ' ' < "$T/launched.txt"))"
[ "$(lines "$CALLS")" = 1 ] && ok || bad "O2 cadence asked once (got $(lines "$CALLS"))"

# --- O2b stale + cadence allow + replan cap reached: cap still denies --------
cadence allow; reset; seed_plan; move_planned
mkdir -p "$T/state/preplan"; d=$(date +%s); printf '%s\n%s\n' "$d" "$d" > "$REPLANS"
tick
[ -s "$PD/plan.md" ] && ok || bad "O2b a capped re-plan keeps the plan on disk"
[ "$(lines "$REPLANS")" = 2 ] && ok || bad "O2b a capped re-plan adds no .replans line (got $(lines "$REPLANS"))"
grep -q 'PREPLAN_SKIP stale re-plan cap reached' "$T/logs/preplan.log" && ok || bad "O2b the cap line is logged"
[ -s "$T/launched.txt" ] && bad "O2b a capped key launches nothing" || ok

# --- O3 fresh plan: cadence not consulted, cadence-<p>.last untouched --------
cadence allow; reset; seed_plan
tick
[ "$(lines "$CALLS")" = 0 ] && ok || bad "O3 a fresh plan must not consult cadence (calls: $(lines "$CALLS"))"
[ -e "$CLAST" ] && bad "O3 a fresh plan must not stamp cadence-proj.last" || ok
[ -s "$T/launched.txt" ] && bad "O3 a fresh plan launches nothing" || ok
[ -s "$PD/plan.md" ] && ok || bad "O3 the fresh plan stays"

# --- O3b no plan: cadence consulted, launch ---------------------------------
cadence allow; reset
tick
[ "$(lines "$CALLS")" = 1 ] && ok || bad "O3b a missing plan asks cadence once (got $(lines "$CALLS"))"
[ "$(grep -cx AB-1 "$T/launched.txt")" = 1 ] && ok || bad "O3b a missing plan launches"
[ "$(stale_lines)" = 0 ] && ok || bad "O3b a missing plan logs no PREPLAN_STALE"

# --- O4 mutation: the cadence block moved back after the re-plan -------------
# Cut the block between its markers and paste it straight before the launch
# line, which is where it sat before BH-2998. O1 must go red on that mutant.
MUT="$T/bin/preplan-tick.mut.sh"
awk '
  /# >>> preplan cadence \(BH-2543\)/ { inb=1 }
  inb { blk = blk $0 "\n"; if ($0 ~ /# <<< preplan cadence$/) { inb=0; got=1 }; next }
  /pre-plan launch \(/ && got && !put { printf "%s", blk; put=1 }
  { print }
  END { if (!got || !put) exit 3 }
' "$T/bin/preplan-tick.sh" > "$MUT"; ARC=$?
if [ "$ARC" != 0 ]; then
  bad "O4 the cadence markers or the launch line are missing from bin/preplan-tick.sh (awk rc $ARC)"
elif cmp -s "$T/bin/preplan-tick.sh" "$MUT"; then
  bad "O4 the mutant is identical to the tick: the cadence block already sits after the re-plan"
else
  o1 O4-mutant "$MUT" >/dev/null; n=$?
  [ "$n" -gt 0 ] && ok || bad "O4 with the cadence block moved after the re-plan, O1 must go red"
fi
rm -f "$MUT"

echo "preplan-cadence-order: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
