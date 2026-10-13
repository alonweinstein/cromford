#!/bin/bash
# tests/preplan-ready.bh-2543-test.sh — BH-2543.3: the v1 readiness rules of
# bin/lib/preplan-ready.sh, asked by the `# >>> preplan readiness (BH-2543)`
# block of bin/preplan-tick.sh before a pre-plan session is bought.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/preplan-ready.bh-2543-test.sh
#
# B1a-B1d source the lib and assert rc + stdout per class and per knob value
# (env, and a per-project settings row read through the real lane_knob). B2
# drives the REAL tick with the REAL lib: the blocked key is skipped with one
# log line, the ahead key launches, and a second tick changes neither. M1/M2
# break the lib and confirm the assertions above would go red.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

READY_LIB="$DIR/bin/lib/preplan-ready.sh"
REASON='blocker not started: cannot build within the pre-plan TTL'
unset PREPLAN_READY_ONLY

# ask <lib> <project> <class> — "rc[stdout]" of preplan_not_ready under set -u,
# in a child with no lane_knob and whatever PREPLAN_READY_ONLY the caller set.
ask() {
  bash -c 'set -u; . "$1"; o=$(preplan_not_ready /tmp "$2" K "$3"); echo "$?[$o]"' _ "$@"
}

# --- B1a. blocked is not ready, with the reason ------------------------------
F=$(ask "$READY_LIB" p1 blocked)
[ "$F" = "0[$REASON]" ] && ok || bad "B1a blocked: rc 0 and the reason (got $F)"

# --- B1b. the five ready classes ---------------------------------------------
for c in queued hotfix child child-building ahead; do
  F=$(ask "$READY_LIB" p1 "$c")
  [ "$F" = "1[]" ] && ok || bad "B1b $c: rc 1, prints nothing (got $F)"
done

# --- B1c. the knob: env 0, and a per-project settings row --------------------
F=$(PREPLAN_READY_ONLY=0 ask "$READY_LIB" p1 blocked)
[ "$F" = "1[]" ] && ok || bad "B1c PREPLAN_READY_ONLY=0: blocked is ready (got $F)"
F=$(PREPLAN_READY_ONLY=1 ask "$READY_LIB" p1 blocked)
[ "$F" = "0[$REASON]" ] && ok || bad "B1c PREPLAN_READY_ONLY=1: blocked is not ready (got $F)"

K="$T/knob"; mkdir -p "$K/bin/lib" "$K/state"
cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/scheduler-conf.sh" "$K/bin/lib/"
printf '{"fetched_at":%s,"values":{"lane.preplan-tick.p1.preplan_ready_only":"0"}}\n' \
  "$(date -u +%s)" > "$K/state/settings-cache.json"
askrow() {  # askrow <project> — through the real lane_knob and the row above
  HARNESS="$K" LANE_REGISTRY="$K/none.json" bash -c \
    'set -u; . "$HARNESS/bin/lib/lane-gate.sh"; . "$1";
     command -v lane_knob >/dev/null || { echo no-lane-knob; exit; }
     o=$(preplan_not_ready "$HARNESS" "$2" K blocked); echo "$?[$o]"' _ "$READY_LIB" "$1"
}
F=$(askrow p1)
[ "$F" = "1[]" ] && ok || bad "B1c the p1 row preplan_ready_only=0 makes p1's blocked ready (got $F)"
F=$(askrow p2)
[ "$F" = "0[$REASON]" ] && ok || bad "B1c the p1 row leaves p2 filtered (got $F)"
F=$(HARNESS="$K" LANE_REGISTRY="$K/none.json" bash -c \
  '. "$HARNESS/bin/lib/lane-gate.sh"; . "$1"; preplan_ready_on "$HARNESS" p1; a=$?; preplan_ready_on "$HARNESS" p2; echo "$a $?"' _ "$READY_LIB")
[ "$F" = "1 0" ] && ok || bad "B1c preplan_ready_on <h> <p> reads the per-project row (got $F)"

# --- B1d. empty and unknown class are ready, under set -u --------------------
F=$(ask "$READY_LIB" p1 "")
[ "$F" = "1[]" ] && ok || bad "B1d empty class: rc 1, prints nothing (got $F)"
F=$(ask "$READY_LIB" p1 bogus)
[ "$F" = "1[]" ] && ok || bad "B1d unknown class: rc 1, prints nothing (got $F)"
F=$(bash -c 'set -u; . "$1"; o=$(preplan_not_ready); echo "$?[$o]"' _ "$READY_LIB" 2>&1)
[ "$F" = "1[]" ] && ok || bad "B1d no arguments at all under set -u: rc 1, no error (got $F)"

# --- B2. the real tick with the real lib -------------------------------------
H="$T/tick"
mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/locks" "$H/plans" \
         "$H/state" "$H/prompts" "$H/repos/proj"
cp "$DIR/bin/lib/preplan-lib.sh" "$H/bin/lib/"
for f in preplan-tick.sh fleet-conf.sh project-of.sh fleet-projects-or-alert.sh kind-gate.sh; do
  cp "$DIR/bin/$f" "$H/bin/"
done
: > "$H/env/global.env"
cat > "$H/fleet.conf" <<'CONF'
proj  example-org/proj   -   -   0 local -
CONF
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$H/prompts/proj.md"
printf '#!/bin/bash\necho local\n' > "$H/bin/box-name.sh"
cat > "$H/bin/preplan-candidates.sh" <<'SH'
#!/bin/bash
printf 'AB-1\t1\tblocked\nAB-2\t2\tahead\n'
SH
cat > "$H/bin/run-preplan.sh" <<'SH'
#!/bin/bash
echo "$3" >> "$HARNESS/launched.txt"
SH
chmod +x "$H/bin/box-name.sh" "$H/bin/preplan-candidates.sh" "$H/bin/run-preplan.sh"
( cd "$H/repos/proj" && git init -q -b main && git config user.email t@t && git config user.name t \
  && echo x > a && git add -A && git commit -qm base && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
printf '%s\n' 'AB-1 1 — ready project=proj' 'AB-2 2 — ready project=proj' > "$H/logs/READY-QUEUE.log"

reset() {
  : > "$H/launched.txt"; : > "$H/logs/preplan.log"
  for p in "$H/plans/"* "$H/state/"*.small "$H/state/preplan-candidates"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
}
tick() {  # run the tick, then wait for the setsid children it launched
  local n want i
  HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$H/repos" PREPLAN_PARALLEL=3 \
    bash "$H/bin/preplan-tick.sh" >/dev/null 2>&1; TRC=$?
  want=$(grep -c 'pre-plan launch' "$H/logs/preplan.log" 2>/dev/null)
  for i in $(seq 1 30); do
    n=$(wc -l < "$H/launched.txt")
    [ "$n" -ge "${want:-0}" ] && break
    sleep 0.1
  done
  sleep 0.2
}
launched() { grep -qx "$1" "$H/launched.txt"; }
got() { tr '\n' ' ' < "$H/launched.txt"; }
skips() { grep -c '\[proj/AB-1\] PREPLAN_SKIP small: not-ready: blocker not started' "$H/logs/preplan.log"; }

cp "$READY_LIB" "$H/bin/lib/"; reset; tick
[ "$TRC" = 0 ] && ok || bad "B2 the tick exits 0 (rc $TRC)"
launched AB-1 && bad "B2 the blocked key must not launch (launched: $(got))" || ok
launched AB-2 && ok || bad "B2 the ahead key launches (launched: $(got))"
N=$(skips)
[ "$N" = 1 ] && ok || bad "B2 exactly one not-ready line for AB-1 (got $N; log: $(tail -3 "$H/logs/preplan.log"))"
N=$(grep -c 'not-ready:' "$H/logs/preplan.log")
[ "$N" = 1 ] && ok || bad "B2 no not-ready line for any other key (got $N)"
: > "$H/launched.txt"; tick
N=$(skips)
[ "$N" = 1 ] && ok || bad "B2 still one not-ready line after a second tick (got $N)"
launched AB-1 && bad "B2 the second tick still skips the blocked key (launched: $(got))" || ok

# --- M. mutation: a broken lib must turn the cases above red -----------------
# M1: the stub answer (always ready) — B2's "AB-1 not launched" goes red.
cat > "$H/bin/lib/preplan-ready.sh" <<'SH'
preplan_ready_on() { return 0; }
preplan_not_ready() { return 1; }
SH
reset; tick
launched AB-1 && ok || bad "M1 with an always-ready lib the blocked key launches, so B2 would be red (launched: $(got))"
# M2: the blocked) arm deleted — B1a's rc flips.
sed '/^ *blocked)/d' "$READY_LIB" > "$T/mut.sh"
if cmp -s "$READY_LIB" "$T/mut.sh"; then
  bad "M2 no blocked) arm found in bin/lib/preplan-ready.sh to delete"
else
  F=$(ask "$T/mut.sh" p1 blocked)
  [ "$F" = "1[]" ] && ok || bad "M2 with the blocked) arm deleted, B1a would be red (got $F)"
fi

echo "preplan-ready.bh-2543: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
