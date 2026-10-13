#!/bin/bash
# tests/utilization-quiet.bh-3988-test.sh — BH-4012 (BH-3988.4): the daily
# went-quiet alert. The pure predicate util_quiet (bin/lib/utilization-quiet.sh)
# and the hub lane bin/utilization-quiet.sh that turns it into one --id alert
# per project.
#
# The lane runs AS SHIPPED from a scratch $HARNESS (a symlink copy of the real
# bin/ and catalog/) with the real jobs-client.sh, lane-alert.sh and
# alert-state.sh. Stubbed: fleet-conf.sh (the projects in FAKE_PROJECTS), gh
# (records argv; must never be called) and curl, which answers
#   GET /api/utilization?project=<p>&since=…  from $T/rows/<p>.json (404 when
#       absent; FAKE_UTIL_CODE overrides the status)
#   GET /api/metrics/dora?project=<p>&days=<n> from $T/dora/<p>-<n>.json
#       (FAKE_DORA_CODE overrides the status)
# and records every call as `<METHOD> <path>` in $H/calls.txt.
#
#   Q*      util_quiet sourced alone, HARNESS and H unset: every result line
#   A       starved 72h + 5 prior-week merges: one warn util-went-quiet-A with
#           the fixed text; a rerun adds no ALERTS line; the since= and both
#           DORA reads are the ones asked for
#   B C D E the ticket's negatives: 0 merges, 40 rows, ready at hour 50
#           (resolves an open id), paused all window
#   NULLFREE UNKNOWN SAT READYNULL NEGMERGE  more negatives
#   DORA-OUTAGE UTIL-404  unmeasured; an open went-quiet id stays OPEN
#   UNMEAS-RESOLVE  a fully measured run resolves util-quiet-unmeasured
#   NO-GH   gh never called, no issues path
#   OFF BUSY SEAM KNOBS RENDER
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/utilization-quiet.bh-3988-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', wanted '$3'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
TAB=$'\t'

LANE_SRC="$DIR/bin/utilization-quiet.sh"
LIB_SRC="$DIR/bin/lib/utilization-quiet.sh"
CRON_SRC="$DIR/cron/lanes/725-utilization-quiet.cron"
REG_SRC="$DIR/catalog/lanes.d/utilization-quiet.json"
for f in "$LANE_SRC" "$LIB_SRC" "$CRON_SRC" "$REG_SRC"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; echo "utilization-quiet: 0 passed, 1 failed"; exit 1; }
done

# ── fixtures ────────────────────────────────────────────────────────────────
# UTIL_NOW is 2026-10-03T07:20:00Z, the lane's daily slot; rows end at its hour.
UTIL_NOW=$(date -u -d '2026-10-03T07:20:00Z' +%s)
NOW_HOUR=$(date -u -d '2026-10-03T07:00:00Z' +%s)
# gen <project> <n> [jq filter over the {rows,truncated,as_of} body]
# Rows are rowOut-shaped (worker/jobs/src/routes/utilization.js): the builds
# section utilization-push.sh PUTs, plus the tickets section the verdict reads.
gen() {
  jq -nc --arg p "$1" --argjson n "$2" --argjson now "$NOW_HOUR" '
    {rows: [range(0; $n) as $i | ($now - ($n - 1 - $i) * 3600) as $h | {
      project: $p, hour: ($h | todate), verdict: "starved",
      payload: {tickets: {ready: 0}, builds: {running: 1, pool_cap: 3, free_slots: 2},
                pauses: [], prs: {}, basis: {builds: "measured", tickets: "measured"}},
      box: "hub", as_of: ($h + 420 | todate)}],
     truncated: false, as_of: ($now + 1200 | todate)}' | jq -c "${3:-.}"
}
rows_of() { gen "$@" | jq -c .rows; }

# ── Q: the pure predicate, sourced alone ────────────────────────────────────
qrun() { env -u HARNESS -u H bash -c '. "$0" || exit 9; util_quiet "$@"; echo "rc=$?"' "$LIB_SRC" "$@"; }
R72=$(rows_of q 72)
eq "Q-QUIET" "$(qrun "$R72" 5 60)" "quiet${TAB}72 rows starved, 5 merges prior week"$'\n'"rc=0"
eq "Q-UNLIMITED" "$(qrun "$(rows_of q 72 '.rows[].payload.builds.free_slots="unlimited"')" 5 60 | head -n1)" \
  "quiet${TAB}72 rows starved, 5 merges prior week"
eq "Q-B 0 merges" "$(qrun "$R72" 0 60 | head -n1)" "not-quiet${TAB}0 merges prior week"
H40=$(jq -r '.[40].hour' <<<"$R72"); H50=$(jq -r '.[50].hour' <<<"$R72"); H60=$(jq -r '.[60].hour' <<<"$R72")
eq "Q-PAUSED one row" "$(qrun "$(rows_of q 72 '.rows[40].verdict="paused"')" 5 60 | head -n1)" "not-quiet${TAB}verdict paused at $H40"
eq "Q-UNKNOWN" "$(qrun "$(rows_of q 72 '.rows[].verdict="unknown"')" 5 60 | head -n1)" "not-quiet${TAB}verdict unknown at $(jq -r '.[71].hour' <<<"$R72")"
eq "Q-NULLFREE" "$(qrun "$(rows_of q 72 '.rows[50].payload.builds.free_slots=null')" 5 60 | head -n1)" "not-quiet${TAB}free_slots null at $H50"
eq "Q-SAT" "$(qrun "$(rows_of q 72 '.rows[].payload.builds.free_slots=0 | .rows[].verdict="saturated"')" 5 60 | head -n1)" \
  "not-quiet${TAB}free_slots 0 at $(jq -r '.[71].hour' <<<"$R72")"
eq "Q-READYNULL" "$(qrun "$(rows_of q 72 '.rows[60].payload.tickets.ready=null')" 5 60 | head -n1)" "not-quiet${TAB}ready unmeasured at $H60"
eq "Q-READYGONE payload_error row" "$(qrun "$(rows_of q 72 '.rows[60].payload=null | .rows[60].payload_error="unparseable"')" 5 60 | head -n1)" \
  "not-quiet${TAB}free_slots null at $H60"
eq "Q-READYSTR ready \"0\" is not 0" "$(qrun "$(rows_of q 72 '.rows[60].payload.tickets.ready="0"')" 5 60 | head -n1)" \
  "not-quiet${TAB}ready unmeasured at $H60"
eq "Q-READY latest hour named" "$(qrun "$(rows_of q 72 '.rows[40].payload.tickets.ready=2 | .rows[50].payload.tickets.ready=1')" 5 60 | head -n1)" \
  "not-quiet${TAB}ready>0 at $H50"
eq "Q-MIN 59 rows" "$(qrun "$(rows_of q 59)" 5 60 | head -n1)" "unmeasured${TAB}59 rows < 60"
eq "Q-MIN 0 rows, min 0" "$(qrun '[]' 5 0 | head -n1)" "unmeasured${TAB}0 rows < 1"
eq "Q-MERGES-X" "$(qrun "$R72" x 60 | head -n1)" "unmeasured${TAB}merges unreadable"
eq "Q-MERGES-NEG" "$(qrun "$R72" -1 60 | head -n1)" "unmeasured${TAB}merges unreadable"
eq "Q-MERGES-EMPTY" "$(qrun "$R72" '' 60 | head -n1)" "unmeasured${TAB}merges unreadable"
eq "Q-MINROWS-X" "$(qrun "$R72" 5 abc | head -n1)" "unmeasured${TAB}min_rows not an integer"
eq "Q-NOT-ARRAY object" "$(qrun '{"rows":[]}' 5 60)" "unmeasured${TAB}rows unparseable"$'\n'"rc=0"
eq "Q-NOT-ARRAY garbage" "$(qrun 'not json' 5 60)" "unmeasured${TAB}rows unparseable"$'\n'"rc=0"
eq "Q-ROW not an object" "$(qrun "$(jq -c '.[5]="x"' <<<"$R72")" 5 60 | head -n1)" "not-quiet${TAB}free_slots null at ?"
grep -q '/root/harness' "$LIB_SRC" && bad "Q the lib names /root/harness (D43)" || ok

# ── the scratch harness ─────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/flags" "$H/logs" "$H/state" "$T/stub" "$T/env" "$T/rows" "$T/dora"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/catalog" "$H/catalog"
rm -f "$H/catalog/lanes.json"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" > "$H/catalog/lanes.json" 2> "$T/build.err" \
  || bad "setup: bin/lanes-build.sh failed: $(cat "$T/build.err")"
rm -f "$H/bin/fleet-conf.sh"
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ -n "${FAKE_NO_FLEET:-}" ] && exit 1
case "${1:-}" in
  --projects) for p in ${FAKE_PROJECTS:-}; do echo "$p"; done ;;
  --*) exit 1 ;;
  *) case "${2:-}" in
       repo) echo "example-org/$1" ;;
       board_prefix) echo "${FAKE_BOARD_PREFIX:--}" ;;
       prod) echo "${FAKE_PROD:-}" ;;
       *) exit 1 ;;
     esac ;;
esac
SH
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/gh.txt"
exit 1
SH
cat > "$T/stub/curl" <<SH
#!/bin/bash
M=GET; U=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) M="\$2"; shift 2 ;;
    -m|--connect-timeout|-w|-H|-d|--data|--data-binary|--data-urlencode|--max-time) shift 2 ;;
    -*) shift ;;
    *) U="\$1"; shift ;;
  esac
done
case "\$U" in
  http://jobs.test*) ;;
  *) echo "OTHER \$U" >> "\$HARNESS/calls.txt"; printf '{"ok":true}\n200'; exit 0 ;;
esac
P="\${U#http://jobs.test}"
echo "\$M \$P" >> "\$HARNESS/calls.txt"
qp() { printf '%s' "\$P" | sed -n "s/.*[?&]\$1=\\([^&]*\\).*/\\1/p"; }
case "\$M \$P" in
  "GET /api/utilization?"*)
    f="$T/rows/\$(qp project).json"
    if [ -n "\${FAKE_UTIL_CODE:-}" ]; then printf '{"error":"fixture"}\n%s' "\$FAKE_UTIL_CODE"
    elif [ -f "\$f" ]; then cat "\$f"; printf '\n200'
    else printf '{"error":"not found"}\n404'; fi ;;
  "GET /api/metrics/dora?"*)
    f="$T/dora/\$(qp project)-\$(qp days).json"
    if [ -n "\${FAKE_DORA_CODE:-}" ]; then printf 'upstream error\n%s' "\$FAKE_DORA_CODE"
    elif [ -f "\$f" ]; then cat "\$f"; printf '\n200'
    else printf '{"error":"not found"}\n404'; fi ;;
  *) printf '{"error":"unknown endpoint"}\n404' ;;
esac
SH
chmod +x "$H/bin/fleet-conf.sh" "$T/stub/gh" "$T/stub/curl"
LOG="$H/logs/utilization-quiet.log"
ALERTS="$H/logs/ALERTS.log"

# run_lane [VAR=val...] — the shipped entry from the scratch harness, clean env.
run_lane() {
  rm -f "$H/calls.txt"
  env -i PATH="$T/stub:$PATH" HOME="$T" HARNESS="$H" HARNESS_ENV_DIR="$T/env" HARNESS_TEST_SANDBOX=1 \
    JOBS_URL=http://jobs.test HARNESS_SECRET=s3cret JOBS_RETRY_SLEEP=0 UTIL_NOW="$UTIL_NOW" "$@" \
    bash "$H/bin/utilization-quiet.sh" > "$T/lane.out" 2> "$T/lane.err"
}
reset() {
  local f
  for f in "$H/state/alerts" "$H/state/alert-warn-batch.jsonl"*; do [ -e "$f" ] && scratch_rm "$f"; done
  : > "$ALERTS"; : > "$LOG"; rm -f "$H/calls.txt"; }
last() { tail -n 1 "$LOG" 2>/dev/null | cut -d' ' -f2-; }
nlines() { grep -c -- "$1" "$ALERTS" 2>/dev/null; }
state() { jq -r '[(.resolved_at==null),.severity]|@tsv' "$H/state/alerts/$1.json" 2>/dev/null; }
dora() { # dora <project> <days> <merged|absent|raw:...>
  case "$3" in
    absent) echo '{"projects":[{"project":"someone-else","merged":4}],"days":'"$2"'}' > "$T/dora/$1-$2.json" ;;
    raw:*) printf '%s' "${3#raw:}" > "$T/dora/$1-$2.json" ;;
    *) jq -nc --arg p "$1" --argjson m "$3" --argjson d "$2" '{projects:[{project:$p,merged:$m}],days:$d}' > "$T/dora/$1-$2.json" ;;
  esac
}
# The worker reads this run made; a lane that stopped early makes none.
ncalls() { cat "$H/calls.txt" 2>/dev/null | grep -c 'utilization\|dora'; }
QTEXT() { echo "$1 has had free slots and no ready work for 72h (last ready: not in window), after $2 merges the week before. Board: $3"; }

# ── A ───────────────────────────────────────────────────────────────────────
reset
gen A 72 > "$T/rows/A.json"; dora A 10 7; dora A 3 2
run_lane FAKE_PROJECTS=A; rc=$?
eq "A rc" "$rc" 0
eq "A one went-quiet line" "$(nlines 'util-went-quiet-A\|A has had free slots')" 1
eq "A text" "$(sed -E 's/^[0-9-]+ [0-9:]+Z //' "$ALERTS" | grep 'has had free slots')" \
  "[orchestrator/utilization-quiet] $(QTEXT A 5 'https://github.com/example-org/A/issues?q=is%3Aopen+label%3Aai-build')"
eq "A state open, warn" "$(state util-went-quiet-A)" "true${TAB}warn"
eq "A since= is UTIL_NOW-72h" "$(grep -c '^GET /api/utilization?project=A&since=2026-09-30T07%3A20%3A00Z$' "$H/calls.txt")" 1
eq "A dora long" "$(grep -c '^GET /api/metrics/dora?project=A&days=10$' "$H/calls.txt")" 1   # determinism: ok clock-rolling-window a grep of the argv the curl stub recorded; days= is the UTIL_QUIET_PRIOR_DAYS knob and the stub answers from $T/dora files, not a clock
eq "A dora short" "$(grep -c '^GET /api/metrics/dora?project=A&days=3$' "$H/calls.txt")" 1   # determinism: ok clock-rolling-window a grep of the argv the curl stub recorded; days=3 is derived from the pinned UTIL_NOW window and the stub answers from $T/dora files, not a clock
eq "A log" "$(last)" "projects=1 quiet=1 not_quiet=0 unmeasured=0"
[ -s "$T/lane.out" ] && bad "A the lane wrote to stdout: $(head -c 300 "$T/lane.out")" || ok
run_lane FAKE_PROJECTS=A
eq "A rerun adds no ALERTS line" "$(nlines 'has had free slots')" 1
eq "A rerun still open" "$(state util-went-quiet-A)" "true${TAB}warn"
# In-app board: the project's prod URL; nothing configured: `not configured`.
reset
run_lane FAKE_PROJECTS=A FAKE_BOARD_PREFIX=/api/board FAKE_PROD=https://a.example.com
eq "A in-app board link" "$(grep -c 'Board: https://a.example.com$' "$ALERTS")" 1
reset
cp "$H/bin/fleet-conf.sh" "$T/fleet-conf.keep"
printf '#!/bin/bash\ncase "$1" in --projects) echo A ;; *) exit 1 ;; esac\n' > "$H/bin/fleet-conf.sh"
run_lane
eq "A board not configured" "$(grep -c 'Board: not configured$' "$ALERTS")" 1
cp "$T/fleet-conf.keep" "$H/bin/fleet-conf.sh"

# ── B: 0 merges prior week ──────────────────────────────────────────────────
reset
gen B 72 > "$T/rows/B.json"; dora B 10 3; dora B 3 3
run_lane FAKE_PROJECTS=B
eq "B no went-quiet" "$(nlines 'util-went-quiet-B\|B has had')" 0
eq "B log" "$(last)" "projects=1 quiet=0 not_quiet=1 unmeasured=0"
# The route answered and the project is not in .projects: that is 0 merges.
dora B 10 absent; dora B 3 absent
run_lane FAKE_PROJECTS=B
eq "B absent from .projects is 0, not unmeasured" "$(last)" "projects=1 quiet=0 not_quiet=1 unmeasured=0"

# ── C: a 40-row project ─────────────────────────────────────────────────────
reset
gen C 40 > "$T/rows/C.json"; dora C 10 7; dora C 3 2
run_lane FAKE_PROJECTS=C
eq "C no went-quiet" "$(nlines 'C has had')" 0
eq "C unmeasured log" "$(grep -c ' unmeasured project=C why=40 rows < 60$' "$LOG")" 1
eq "C one unmeasured alert naming C" "$(grep -c 'Went-quiet check could not measure: C (40 rows < 60)' "$ALERTS")" 1
eq "C unmeasured state" "$(state util-quiet-unmeasured)" "true${TAB}warn"
eq "C log" "$(last)" "projects=1 quiet=0 not_quiet=0 unmeasured=1"

# ── UNMEAS-RESOLVE: every project measured again ────────────────────────────
gen C 72 '.rows[].verdict="unknown"' > "$T/rows/C.json"
run_lane FAKE_PROJECTS=C
eq "UNMEAS-RESOLVE resolved line" "$(grep -c 'RESOLVED: Went-quiet check measured every project again' "$ALERTS")" 1
eq "UNMEAS-RESOLVE state closed" "$(state util-quiet-unmeasured | cut -f1)" false

# ── KNOBS: UTIL_QUIET_MIN_ROWS=30 makes the 40-row project measured ──────────
reset
gen C 40 > "$T/rows/C.json"
run_lane FAKE_PROJECTS=C UTIL_QUIET_MIN_ROWS=30
eq "KNOBS min_rows 30: C is quiet" "$(nlines 'C has had free slots')" 1
reset
run_lane FAKE_PROJECTS=C UTIL_QUIET_MIN_ROWS=abc
eq "KNOBS garbage falls back to 60" "$(grep -c ' unmeasured project=C why=40 rows < 60$' "$LOG")" 1
eq "KNOBS garbage is logged" "$(grep -c 'UTIL_QUIET_MIN_ROWS=abc is not an integer' "$LOG")" 1

# ── D: ready work returns at hour 50 ────────────────────────────────────────
reset
gen D 72 > "$T/rows/D.json"; dora D 10 7; dora D 3 2
run_lane FAKE_PROJECTS=D
eq "D opened first" "$(state util-went-quiet-D)" "true${TAB}warn"
gen D 72 '.rows[50].payload.tickets.ready=1 | .rows[50].verdict="busy"' > "$T/rows/D.json"
run_lane FAKE_PROJECTS=D
eq "D no new went-quiet line" "$(nlines 'D has had free slots')" 1
eq "D resolved" "$(state util-went-quiet-D | cut -f1)" false
eq "D resolve line" "$(grep -c "RESOLVED: D has ready work or recent activity again (ready>0 at $(jq -r '.rows[50].hour' "$T/rows/D.json"))" "$ALERTS")" 1

# ── E and the other negatives ───────────────────────────────────────────────
neg() { # neg <case> <project> <jq filter> [merges long short]
  reset
  gen "$2" 72 "$3" > "$T/rows/$2.json"; dora "$2" 10 "${4:-7}"; dora "$2" 3 "${5:-2}"
  run_lane FAKE_PROJECTS="$2"
  eq "$1 no went-quiet" "$(nlines "util-went-quiet-$2\|$2 has had")" 0
  eq "$1 no state file" "$(state "util-went-quiet-$2")" ""
}
neg E E '.rows[].verdict="paused"'
neg E1 E '.rows[30].verdict="paused"'
neg NULLFREE F '.rows[].payload.builds.free_slots=null'
neg UNKNOWN G '.rows[].verdict="unknown"'
neg SAT S '.rows[].payload.builds.free_slots=0 | .rows[].verdict="saturated" | .rows[].payload.tickets.ready=3'
neg READYNULL R '.rows[].payload.tickets.ready=null | .rows[].verdict="unknown"'
neg NEGMERGE N '.' 2 3
eq "NEGMERGE is unmeasured" "$(grep -c ' unmeasured project=N why=merges unreadable$' "$LOG")" 1
neg MISSING-HOUR M 'del(.rows[10:23])'
eq "MISSING-HOUR is unmeasured" "$(grep -c ' unmeasured project=M why=59 rows < 60$' "$LOG")" 1
neg TRUNCATED X '.truncated=true'
eq "TRUNCATED is unmeasured" "$(grep -c ' unmeasured project=X why=rows truncated$' "$LOG")" 1
# An old worker that ignores the params answers the newest row of every project.
neg OLDWORKER O '{rows: [.rows[-1], (.rows[-1] | .project="other")], as_of}'
eq "OLDWORKER is unmeasured" "$(grep -c ' unmeasured project=O why=1 rows < 60$' "$LOG")" 1

# ── DORA-OUTAGE: unmeasured, and an open went-quiet id stays OPEN ───────────
reset
run_lane FAKE_PROJECTS=A
eq "DORA-OUTAGE A opened" "$(state util-went-quiet-A)" "true${TAB}warn"
run_lane FAKE_PROJECTS=A FAKE_DORA_CODE=500
eq "DORA-OUTAGE unmeasured" "$(last)" "projects=1 quiet=0 not_quiet=0 unmeasured=1"
eq "DORA-OUTAGE A still open" "$(state util-went-quiet-A)" "true${TAB}warn"
eq "DORA-OUTAGE no resolve line" "$(grep -c 'RESOLVED: A has' "$ALERTS")" 0
eq "DORA-OUTAGE unmeasured alert names A" "$(grep -c 'could not measure: A (merges unreadable)' "$ALERTS")" 1
dora A 10 'raw:not json'
run_lane FAKE_PROJECTS=A
eq "DORA not JSON is unmeasured" "$(last)" "projects=1 quiet=0 not_quiet=0 unmeasured=1"
dora A 10 'raw:{"error":"x"}'
run_lane FAKE_PROJECTS=A
eq "DORA without .projects is unmeasured" "$(last)" "projects=1 quiet=0 not_quiet=0 unmeasured=1"
eq "DORA A still open after both" "$(state util-went-quiet-A)" "true${TAB}warn"
dora A 10 7

# ── UTIL-404 / UTIL-500 ─────────────────────────────────────────────────────
reset
run_lane FAKE_PROJECTS=A FAKE_UTIL_CODE=404
eq "UTIL-404 unmeasured" "$(last)" "projects=1 quiet=0 not_quiet=0 unmeasured=1"
eq "UTIL-404 why" "$(grep -c ' unmeasured project=A why=utilization read failed$' "$LOG")" 1
eq "UTIL-404 no went-quiet" "$(nlines 'A has had')" 0
run_lane FAKE_PROJECTS=A FAKE_UTIL_CODE=503
eq "UTIL-503 unmeasured" "$(last)" "projects=1 quiet=0 not_quiet=0 unmeasured=1"
# An empty rows answer (utilization_rows rc 2) is 0 rows: unmeasured too.
echo '{"rows":[],"truncated":false}' > "$T/rows/Z.json"; dora Z 10 7; dora Z 3 2
run_lane FAKE_PROJECTS=Z
eq "UTIL-EMPTY unmeasured" "$(grep -c ' unmeasured project=Z why=0 rows < 60$' "$LOG")" 1

# ── a mixed fleet in one run ────────────────────────────────────────────────
reset
gen B 72 > "$T/rows/B.json"; dora B 10 3; dora B 3 3
gen C 40 > "$T/rows/C.json"
run_lane FAKE_PROJECTS="A B C"
eq "MIXED log" "$(last)" "projects=3 quiet=1 not_quiet=1 unmeasured=1"
eq "MIXED one went-quiet line" "$(nlines 'has had free slots')" 1

# ── NO-GH across every run above ────────────────────────────────────────────
[ -s "$H/gh.txt" ] && bad "NO-GH gh was called: $(head -c 300 "$H/gh.txt")" || ok
eq "NO-GH no issues path" "$(grep -c 'issues' "$H/calls.txt")" 0

# ── OFF / BUSY ──────────────────────────────────────────────────────────────
reset
touch "$H/flags/lane-off-utilization-quiet"
run_lane FAKE_PROJECTS=A; rc=$?
eq "OFF rc" "$rc" 0
eq "OFF no calls" "$(ncalls)" 0
eq "OFF no alert" "$(nlines 'A has had')" 0
rm -f "$H/flags/lane-off-utilization-quiet"
run_lane FAKE_PROJECTS=A UTIL_QUIET_ENABLED=0; rc=$?
eq "DISABLED rc" "$rc" 0
eq "DISABLED log" "$(last)" "disabled"
eq "DISABLED no calls" "$(ncalls)" 0

mkdir -p "$H/locks"
flock "$H/locks/utilization-quiet.lock" sleep 30 &
HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  flock -n "$H/locks/utilization-quiet.lock" true 2>/dev/null || break
  sleep 0.2
done
run_lane FAKE_PROJECTS=A; rc=$?
# The sleep holds the lock fd too: kill it with its flock parent.
pkill -P "$HOLDER" 2>/dev/null; kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
eq "BUSY rc" "$rc" 0
eq "BUSY log" "$(last)" "busy"
eq "BUSY no calls" "$(ncalls)" 0

# ── SEAM: UTIL_NOW is ignored outside the sandbox ───────────────────────────
# A 2020 UTIL_NOW, so an honoured seam would ask for since=2020-01-01.
reset
env -i PATH="$T/stub:$PATH" HOME="$T" HARNESS="$H" HARNESS_ENV_DIR="$T/env" \
  JOBS_URL=http://jobs.test HARNESS_SECRET=s3cret JOBS_RETRY_SLEEP=0 UTIL_NOW="$(date -u -d 2020-01-04T00:00:00Z +%s)" FAKE_PROJECTS=A \
  bash "$H/bin/utilization-quiet.sh" > /dev/null 2>&1
S1=$(date -u -d '-72 hours' +%F); S2=$(date -u -d '-73 hours' +%F)
since=$(sed -n 's/^GET \/api\/utilization?project=A&since=\([0-9-]*\)T.*/\1/p' "$H/calls.txt")   # determinism: ok clock-rolling-window parses the since= the lane sent to the curl stub; it is compared against S1/S2, read from the real clock in this same run on purpose (the seam must ignore UTIL_NOW)
{ [ "$since" = "$S1" ] || [ "$since" = "$S2" ]; } && ok || bad "SEAM since date '$since' is not the real clock's ($S1)"

# ── RENDER ──────────────────────────────────────────────────────────────────
( cd "$DIR" && HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-cron.sh" --check && HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --check ) > "$T/render.out" 2>&1
rc=$?
eq "RENDER render-cron and lanes-build --check rc" "$rc" 0
[ "$rc" = 0 ] || cat "$T/render.out"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-cron.sh" hub > "$T/hub.cron" 2> "$T/hub.err"
eq "RENDER one hub line" "$(grep -c '^20 7 \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/utilization-quiet.sh' "$T/hub.cron")" 1
eq "RENDER one schedule line names the lane" "$(grep -v '^[[:space:]]*#' "$T/hub.cron" | grep -c 'utilization-quiet')" 1
eq "RENDER cron line 1" "$(head -n1 "$CRON_SRC")" "# @hub-lanes"
eq "RENDER registry" "$(jq -c '[.scope,.boxes,.switch.name,.script,.cadence,([.knobs[]|select(.settable)|[.env,.default]]|sort)]' "$REG_SRC")" \
  '["hub",["hub"],"lane-off-utilization-quiet","bin/utilization-quiet.sh","20 7 * * *",[["UTIL_QUIET_ENABLED",1],["UTIL_QUIET_MIN_ROWS",60],["UTIL_QUIET_PRIOR_DAYS",7],["UTIL_QUIET_WINDOW_H",72]]]'
eq "RENDER built lanes.json carries it" "$(jq -r '.lanes[]|select(.id=="utilization-quiet")|.script' "$H/catalog/lanes.json")" "bin/utilization-quiet.sh"

echo "utilization-quiet: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
