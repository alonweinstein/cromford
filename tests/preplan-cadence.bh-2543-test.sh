#!/bin/bash
# tests/preplan-cadence.bh-2543-test.sh — BH-2543.4: the adoption-driven
# per-project pre-plan cadence cut.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/preplan-cadence.bh-2543-test.sh
#
# WHAT THIS PINS AND WHY. A speculative pre-plan is a paid session, and one that
# the build later throws away (STALE) bought nothing. bin/lib/preplan-cadence.sh
# reads the project's adoption numbers from GET /api/preplans/adoption and, when
# fewer than PREPLAN_ADOPT_FLOOR_PCT of at least PREPLAN_ADOPT_MIN_SAMPLES bought
# pre-plans were adopted, holds that project to one speculative launch per
# PREPLAN_CUT_INTERVAL_S. `queued` and `hotfix` are never held, and an answer
# the lib cannot read is UNKNOWN: no cut, today's cadence.
#
# The route is another child's, so `_jobs_req` is stubbed here; the tick-level
# case (C2) drives the real bin/preplan-tick.sh with a stub bin/jobs-client.sh.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/preplan-cadence.sh"
NOW=$(date +%s)  # determinism: ok — only ever used as an offset for touch -d

H="$T/h"
mkdir -p "$H/state" "$H/logs"
# shellcheck disable=SC1090
. "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }

# The transport stub. /api/settings answers rc 1, so a loaded lane-gate keeps
# whatever settings cache the case seeded; every other path is recorded.
_jobs_req() {
  case "$2" in /api/settings) return 1 ;; esac
  echo "$2" >> "$T/calls"
  local r; r=$(cat "$T/answer.rc")
  [ "$r" = 0 ] && cat "$T/answer.json"
  return "$r"
}
# answer "p1 A S" ["p2 A S" ...] — the documented route shape (bin/lib/preplan-cadence.sh).
answer() {
  printf '%s\n' "$@" \
    | jq -R 'split(" ") | {project:.[0], adopted:(.[1]|tonumber), stale:(.[2]|tonumber), miss:0, off:0}
             | .bought = (.adopted + .stale)
             | .rate = (if .bought == 0 then null else .adopted / .bought end)' \
    | jq -s '{window_days:7, since:"2026-09-19T00:00:00Z", projects:., days:[], recent:[],
              recent_truncated:false, as_of:"2026-09-26T00:00:00Z"}' > "$T/answer.json"
  echo 0 > "$T/answer.rc"
}
answer_raw() { printf '%s' "$1" > "$T/answer.json"; echo "${2:-0}" > "$T/answer.rc"; }
fresh() { scratch_rm "$H/state/preplan"; rm -f "$H/logs/preplan.log"; : > "$T/calls"; }
adopt_calls() { grep -c '^/api/preplans/adoption' "$T/calls"; }

# --- C1a: 4 adopted / 8 stale (33%) over 12 bought is cut ---------------------
fresh; answer "p1 4 8"
OUT=$(preplan_adopt_stats "$H" p1); RC=$?
[ "$RC:$OUT" = "0:4 8" ] && ok || bad "C1a adopt_stats prints 'adopted stale' rc 0 (got $RC:[$OUT])"
grep -qxF '/api/preplans/adoption?project=p1&days=7' "$T/calls" && ok \
  || bad "C1a the request carries project and the default 7-day window (calls: $(cat "$T/calls"))"  # determinism: ok — fixed window knob, no clock
fresh
R=$(preplan_cadence_cut "$H" p1); RC=$?
[ "$RC" = 0 ] && ok || bad "C1a 4/8 is cut (rc $RC)"
case "$R" in *33%*"(4/12)"*"floor 50%"*) ok ;; *) bad "C1a the reason names 33%, 4/12 and the floor (got [$R])" ;; esac

# --- C1b: 9 / 3 (75%) is not cut ---------------------------------------------
fresh; answer "p1 9 3"
R=$(preplan_cadence_cut "$H" p1); RC=$?
[ "$RC:$R" = "1:" ] && ok || bad "C1b 9/3 is not cut and prints nothing (got $RC:[$R])"

# --- C1c: min samples, the strict floor, floor 0 ------------------------------
fresh; answer "p1 2 5"
preplan_cadence_cut "$H" p1 >/dev/null && bad "C1c 2/5 is under min samples: not cut" || ok
fresh; answer "p1 4 6"
preplan_cadence_cut "$H" p1 >/dev/null && ok || bad "C1c 4/6 (bought = min samples 10, 40%) is cut"
fresh; answer "p1 10 10"
preplan_cadence_cut "$H" p1 >/dev/null && bad "C1c exactly 50% at 20 samples is not cut" || ok
fresh; answer "p1 1 19"
preplan_cadence_cut "$H" p1 >/dev/null && ok || bad "C1c 1/19 is cut at the default floor (control)"
fresh
( PREPLAN_ADOPT_FLOOR_PCT=0; preplan_cadence_cut "$H" p1 >/dev/null ) && bad "C1c a floor of 0 never cuts" || ok
fresh
( PREPLAN_ADOPT_MIN_SAMPLES=21; preplan_cadence_cut "$H" p1 >/dev/null ) && bad "C1c PREPLAN_ADOPT_MIN_SAMPLES=21 over 20 bought: not cut" || ok
fresh
( PREPLAN_ADOPT_WINDOW_DAYS=14; preplan_adopt_stats "$H" p1 >/dev/null )
grep -qxF '/api/preplans/adoption?project=p1&days=14' "$T/calls" && ok \
  || bad "C1c PREPLAN_ADOPT_WINDOW_DAYS reaches the request (calls: $(cat "$T/calls"))"  # determinism: ok — knob value, no clock

# --- C1d: every failure is UNKNOWN: no numbers, no cut, allow -----------------
unknown_case() {  # $1 = label; the answer is already staged
  local out rc
  fresh
  out=$(preplan_adopt_stats "$H" p1); rc=$?
  [ "$rc:$out" = "1:" ] && ok || bad "C1d $1: adopt_stats rc 1, prints nothing (got $rc:[$out])"
  fresh
  out=$(preplan_cadence_cut "$H" p1); rc=$?
  [ "$rc:$out" = "1:" ] && ok || bad "C1d $1: cut rc 1, prints nothing (got $rc:[$out])"
  fresh
  preplan_cadence_allow "$H" p1 ahead && ok || bad "C1d $1: allow ahead rc 0"
  [ -e "$H/logs/preplan.log" ] && bad "C1d $1: UNKNOWN from normal writes no mode line" || ok
}
answer_raw '' 75;                                   unknown_case "rc 75"
answer_raw 'not json' 0;                            unknown_case "malformed body"
answer_raw '' 2;                                    unknown_case "404 (route not deployed)"
answer "p2 4 16";                                   unknown_case "project absent from .projects"
answer_raw '{"window_days":7,"projects":[{"project":"p1","adopted":null,"stale":8,"bought":8,"rate":0}]}' 0
unknown_case "adopted null"
answer_raw '{"window_days":7,"projects":[{"project":"p1","adopted":-1,"stale":20}]}' 0
unknown_case "negative adopted"
# A failure is remembered for the cache window: an undeployed route is asked once.
fresh; answer_raw '' 2
preplan_adopt_stats "$H" p1 >/dev/null; preplan_adopt_stats "$H" p1 >/dev/null; preplan_adopt_stats "$H" p1 >/dev/null
N=$(adopt_calls)
[ "$N" = 1 ] && ok || bad "C1d a failed read is cached: 3 calls, 1 request (got $N)"
# No transport at all (no _jobs_req, no bin/jobs-client.sh): UNKNOWN, nothing written.
E="$T/empty"; mkdir -p "$E"
F=$(bash -c 'set -u; . "$1"; o=$(preplan_adopt_stats "$2" p); s=$?; preplan_cadence_cut "$2" p; c=$?; preplan_cadence_allow "$2" p ahead; a=$?; echo "$s $c $a [$o]"' _ "$LIB" "$E")
[ "$F" = "1 1 0 []" ] && ok || bad "C1d no transport: 1 1 0 [] (got $F)"
[ -z "$(ls -A "$E")" ] && ok || bad "C1d no transport writes nothing (found: $(find "$E" -mindepth 1))"

# --- C1e: under a cut, one launch per interval; queued and hotfix exempt -----
fresh; answer "p1 4 16"
preplan_cadence_allow "$H" p1 ahead && ok || bad "C1e the first ahead under a cut is allowed"
preplan_cadence_allow "$H" p1 ahead && bad "C1e a second ahead inside the interval is refused" || ok
preplan_cadence_allow "$H" p1 child && bad "C1e child is held under a cut too" || ok
preplan_cadence_allow "$H" p1 blocked && bad "C1e blocked is held under a cut too" || ok
for pass in 1 2; do
  preplan_cadence_allow "$H" p1 queued && ok || bad "C1e queued is allowed under a cut (pass $pass)"
  preplan_cadence_allow "$H" p1 hotfix && ok || bad "C1e hotfix is allowed under a cut (pass $pass)"
done
touch -d "@$((NOW-1801))" "$H/state/preplan/cadence-p1.last"  # determinism: ok — offset from NOW
preplan_cadence_allow "$H" p1 ahead && ok || bad "C1e after the interval expires ahead is allowed again"
preplan_cadence_allow "$H" p1 ahead && bad "C1e ...and the stamp is renewed" || ok
( PREPLAN_CUT_INTERVAL_S=60; touch -d "@$((NOW-61))" "$H/state/preplan/cadence-p1.last"  # determinism: ok — offset from NOW
  preplan_cadence_allow "$H" p1 ahead ) && ok || bad "C1e PREPLAN_CUT_INTERVAL_S=60 is honoured"
# queued/hotfix do no read at all
fresh; answer "p1 4 16"
preplan_cadence_allow "$H" p1 queued; preplan_cadence_allow "$H" p1 hotfix
[ "$(adopt_calls)" = 0 ] && [ ! -e "$H/state/preplan" ] && ok \
  || bad "C1e queued/hotfix read no stats and write no state (calls $(adopt_calls))"

# --- C1f: the stamp exists before allow returns; a stamp that cannot be written denies
fresh; answer "p1 4 16"
if preplan_cadence_allow "$H" p1 ahead; then
  L="$H/state/preplan/cadence-p1.last"
  if [ -f "$L" ] && [ "$(stat -c %Y "$L")" -ge "$NOW" ]; then ok
  else bad "C1f .last must exist with a fresh mtime when allow returns rc 0"; fi
else bad "C1f the first ahead under a cut is allowed"; fi
# A .last that is a dangling link into a missing directory cannot be touched,
# even as root. Its own mtime is old, so only the failed write can refuse.
rm -f "$H/state/preplan/cadence-p1.last"
ln -s "$T/no-such-dir/x" "$H/state/preplan/cadence-p1.last"
touch -h -d "@$((NOW-7200))" "$H/state/preplan/cadence-p1.last"  # determinism: ok — offset from NOW
preplan_cadence_allow "$H" p1 ahead 2>/dev/null && bad "C1f an unwritable stamp under a cut must deny (fail closed)" || ok

# --- C1g: a per-project floor row un-cuts that project only ------------------
fresh; answer "p1 4 16" "p2 4 16"
jq '{lanes:[.]}' "$DIR/catalog/lanes.d/preplan-tick.json" > "$T/lanes.json"
jq -n --argjson f "$NOW" '{fetched_at:$f, values:{"lane.preplan-tick.p1.preplan_adopt_floor_pct":"20"}, seeded:{}}' \
  > "$H/state/settings-cache.json"
G=$(HARNESS="$H" LANE_REGISTRY="$T/lanes.json" LANE_GATE_CACHE_S=3600 bash -c '
  . "$1" || exit 9; . "$2" || exit 9; ANS="$3/answer.json"
  _jobs_req() { case "$2" in /api/settings) return 1 ;; esac; cat "$ANS"; }
  command -v lane_knob >/dev/null || exit 8
  preplan_cadence_cut "$HARNESS" p1 >/dev/null; a=$?
  preplan_cadence_cut "$HARNESS" p2 >/dev/null; b=$?
  echo "$a $b $(lane_knob preplan-tick PREPLAN_ADOPT_FLOOR_PCT p1) $(lane_knob preplan-tick PREPLAN_ADOPT_FLOOR_PCT p2)"
' _ "$DIR/bin/lib/lane-gate.sh" "$LIB" "$T")
[ "$G" = "1 0 20 50" ] && ok || bad "C1g floor row 20 for p1: p1 not cut, p2 cut (got [$G], want [1 0 20 50])"
rm -f "$H/state/settings-cache.json"

# --- C1h: one mode line per transition, one read per cache window ------------
fresh; answer "p1 4 16"
for i in 1 2 3; do
  preplan_cadence_allow "$H" p1 ahead || bad "C1h call $i: ahead allowed once the stamp is cleared"
  rm -f "$H/state/preplan/cadence-p1.last"
done
N=$(grep -c 'PREPLAN_CADENCE_CUT' "$H/logs/preplan.log" 2>/dev/null)
[ "$N" = 1 ] && ok || bad "C1h exactly one PREPLAN_CADENCE_CUT line across 3 calls (got $N)"
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}Z \[p1\] PREPLAN_CADENCE_CUT adopt 20% \(4/20\) under floor 50% over 7d, one launch per 1800s$' \
  "$H/logs/preplan.log" && ok || bad "C1h the CUT line shape (log: $(cat "$H/logs/preplan.log" 2>/dev/null))"
N=$(adopt_calls)
[ "$N" = 1 ] && ok || bad "C1h the cache means one adoption read across 3 calls (got $N)"
answer "p1 18 2"
touch -d "@$((NOW-901))" "$H/state/preplan/adoption-p1.json"  # determinism: ok — offset from NOW
for i in 1 2 3; do
  preplan_cadence_allow "$H" p1 ahead || bad "C1h restored call $i: ahead allowed"
done
N=$(grep -c 'PREPLAN_CADENCE_RESTORED' "$H/logs/preplan.log")
[ "$N" = 1 ] && ok || bad "C1h exactly one PREPLAN_CADENCE_RESTORED line across 3 calls (got $N)"
grep -qF '[p1] PREPLAN_CADENCE_RESTORED (adopt 18/20)' "$H/logs/preplan.log" && ok \
  || bad "C1h the RESTORED line names the numbers (log: $(tail -1 "$H/logs/preplan.log"))"
N=$(adopt_calls)
[ "$N" = 2 ] && ok || bad "C1h an expired cache is read once more (got $N reads)"

# --- C2: the real bin/preplan-tick.sh -----------------------------------------
P2="$T/tick"
mkdir -p "$P2/bin/lib" "$P2/env" "$P2/flags" "$P2/logs" "$P2/locks" "$P2/plans" \
         "$P2/state" "$P2/prompts" "$P2/repos/proj"
cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/preplan-ready.sh" "$LIB" "$P2/bin/lib/"
for f in preplan-tick.sh fleet-conf.sh project-of.sh fleet-projects-or-alert.sh kind-gate.sh; do
  cp "$DIR/bin/$f" "$P2/bin/"
done
: > "$P2/env/global.env"
cat > "$P2/fleet.conf" <<'CONF'
proj  example-org/proj   -   -   0 local -
CONF
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$P2/prompts/proj.md"
printf '#!/bin/bash\necho local\n' > "$P2/bin/box-name.sh"
cat > "$P2/bin/preplan-candidates.sh" <<'SH'
#!/bin/bash
printf 'AB-1\t1\tahead\nAB-2\t2\tahead\n'
SH
cat > "$P2/bin/run-preplan.sh" <<'SH'
#!/bin/bash
echo "$3" >> "$HARNESS/launched.txt"
SH
cat > "$P2/bin/jobs-client.sh" <<'SH'
_jobs_req() {
  case "$2" in /api/preplans/adoption*) ;; *) return 1 ;; esac
  echo "$2" >> "$HARNESS/calls"
  local r; r=$(cat "$HARNESS/answer.rc")
  [ "$r" = 0 ] && cat "$HARNESS/answer.json"
  return "$r"
}
SH
chmod +x "$P2/bin/box-name.sh" "$P2/bin/preplan-candidates.sh" "$P2/bin/run-preplan.sh"
( cd "$P2/repos/proj" && git init -q -b main && git config user.email t@t && git config user.name t \
  && echo x > a && git add -A && git commit -qm base && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
printf '%s\n' 'AB-1 1 — ready project=proj' 'AB-2 2 — ready project=proj' > "$P2/logs/READY-QUEUE.log"

treset() {
  : > "$P2/launched.txt"; : > "$P2/logs/preplan.log"; : > "$P2/calls"
  local d
  for d in "$P2/plans/"* "$P2/state/"*.small "$P2/state/preplan-candidates" "$P2/state/preplan"; do
    [ -e "$d" ] && scratch_rm "$d"
  done
}
tanswer() { cp "$T/answer.json" "$P2/answer.json"; cp "$T/answer.rc" "$P2/answer.rc"; }
# ttick — run the real tick, then wait for the setsid children it launched.
ttick() {
  local n want i
  : > "$P2/launched.txt"
  HARNESS="$P2" FLEET_CONF="$P2/fleet.conf" REPOS_ROOT="$P2/repos" PREPLAN_PARALLEL=2 \
    bash "$P2/bin/preplan-tick.sh" >/dev/null 2>&1; TRC=$?
  want=$(grep -c 'pre-plan launch' "$P2/logs/preplan.log" 2>/dev/null)
  for i in $(seq 1 30); do
    n=$(wc -l < "$P2/launched.txt")
    [ "$n" -ge "$((want - PRIOR))" ] && break
    sleep 0.1
  done
  sleep 0.2
  PRIOR=$want
}
nl_launched() { wc -l < "$P2/launched.txt" | tr -d ' '; }

answer "proj 4 16"; tanswer; treset; PRIOR=0
ttick
[ "$TRC" = 0 ] && ok || bad "C2 the tick exits 0 (rc $TRC)"
N=$(nl_launched)
[ "$N" = 1 ] && ok || bad "C2 at 20% over 20, tick 1 launches exactly 1 (got $N: $(tr '\n' ' ' < "$P2/launched.txt"))"
ttick
N=$(nl_launched)
[ "$N" = 0 ] && ok || bad "C2 at 20% over 20, tick 2 launches 0 (got $N)"
grep -q '\[proj\] PREPLAN_CADENCE_CUT' "$P2/logs/preplan.log" && ok || bad "C2 the tick's preplan.log carries the CUT line"
grep -qxF '/api/preplans/adoption?project=proj&days=7' "$P2/calls" && ok \
  || bad "C2 the tick read the adoption route through bin/jobs-client.sh (calls: $(cat "$P2/calls"))"  # determinism: ok — fixed window knob

answer "proj 16 4"; tanswer; treset; PRIOR=0
ttick
N=$(nl_launched)
[ "$N" = 2 ] && ok || bad "C2 at 80% over 20, tick 1 launches both (got $N)"

answer_raw '' 1; tanswer; treset; PRIOR=0
ttick
N=$(nl_launched)
[ "$N" = 2 ] && ok || bad "C2 with the route not answering, tick 1 launches both (got $N)"

# --- Mutation: `<` -> `<=` in the floor rule must cut exactly 50% -------------
MUT="$T/preplan-cadence.mut.sh"
sed 's/a \* 100 < floor/a * 100 <= floor/' "$LIB" > "$MUT"
if cmp -s "$LIB" "$MUT"; then
  bad "Mutation: the floor rule 'a * 100 < floor' is not in $LIB (the sed changed nothing)"
else
  fresh; answer "p1 10 10"
  ( . "$MUT"; preplan_cadence_cut "$H" p1 >/dev/null ) && ok \
    || bad "Mutation: with <= the exactly-50% case must turn cut (the strict < is load-bearing)"
fi

echo "preplan-cadence.bh-2543: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
