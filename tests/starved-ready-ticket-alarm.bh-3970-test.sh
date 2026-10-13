#!/bin/bash
# tests/starved-ready-ticket-alarm.bh-3970-test.sh — BH-3970 item 3: an in-app
# ticket the board says is todo + ready + team, that the buildable gate answers
# OK for, and that nothing owns (no ready line or row, no queue row, no build
# dir) for 60+ minutes pages ONCE per project.
#
# WHY. On project-8 (2026-10-03) 32 decompose children sat in exactly
# that state for ~90 minutes while every triage tick logged `gate no-change`.
# Nothing was wrong with any single lane's answer; the work simply had no owner,
# and no lane asked. bin/lib/starved-ready.sh asks, on every triage tick, from
# the gate's own stored board view (no new board list call).
#
# Sources the REAL lib from a scratch tree with a stub triage-gate.sh (one
# answer file per ticket id), a stub lane-alert.sh that records its argv, and
# stub queue_list / queue_ready_list. S12 drives the REAL rt_gate with the gate
# answering SKIP no-change, which is the tick that page has to fire on. One NOW,
# read once and handed in as STARVED_READY_NOW.
#
# Run from anywhere: tests/starved-ready-ticket-alarm.bh-3970-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "starved-ready-ticket-alarm: jq missing, cannot run" >&2; exit 1; }

NOW=$(date +%s)
export STARVED_READY_NOW="$NOW"
export HARNESS="$T" FLEET_CONF="$T/fleet.conf"
mkdir -p "$T/bin/lib/rt" "$T/state" "$T/logs" "$T/flags" "$T/builds" "$T/answers"
[ -r "$DIR/bin/lib/starved-ready.sh" ] && cp "$DIR/bin/lib/starved-ready.sh" "$T/bin/lib/"
cp "$DIR/bin/lib/ready-queue.sh" "$T/bin/lib/"
cp "$DIR/bin/fleet-conf.sh" "$T/bin/"
cat > "$T/fleet.conf" <<'CONF'
x-os    Example/x-os    https://x.example   /api/board  0 box-a -
ghproj  Example/ghproj  https://g.example   -           0 box-a -
CONF
# triage-gate.sh: --buildable-strict answers from answers/<id> (default OK) and
# records the probe; the plain mode is the tick's gate answer.
cat > "$T/bin/triage-gate.sh" <<'SH'
#!/bin/bash
case "${2:-}" in
  --buildable-strict) echo "$3" >> "$HARNESS/probes.txt"; cat "$HARNESS/answers/$3" 2>/dev/null || echo OK ;;
  --pending) exit 1 ;;
  *) echo "${GATE_STUB:-SKIP no-change (57 tickets)}" ;;
esac
SH
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/lane-alerts.txt"\n' > "$T/bin/lane-alert.sh"
chmod +x "$T/bin/"*.sh

# The jobs client, stubbed. Defined BEFORE the lib is sourced, so
# bin/lib/ready-queue.sh sees ready_queue_rows_on and loads no real client.
ready_queue_rows_on() { [ "${RQ_ON:-1}" = 1 ]; }
queue_ready_list() { cat "$T/ready-rows.tsv" 2>/dev/null; return 0; }
queue_list() { echo "${1:-}" >> "$T/ql-calls.txt"; [ "${QL_RC:-0}" = 0 ] || return "$QL_RC"; cat "$T/queue-rows.tsv" 2>/dev/null; return 0; }

LEDGER="$T/state/starved-ready/x-os.tsv"
MARKER="$T/state/starved-ready/x-os.alerted"
row() { # row <id> <key|-> [status] [waitingOn] [verdict]
  jq -nc --arg id "$1" --arg k "$2" --arg s "${3:-todo}" --arg w "${4:-team}" --arg v "${5:-ready}" \
    '{id:$id,status:$s,waitingOn:$w,triageVerdict:$v,title:("child "+$id),commentCount:2,lastActivityAt:null}
     + (if $k == "-" then {} else {key:$k} end)'
}
board() { # board <file> <row-json>...
  local f="$1"; shift
  printf '%s\n' "$@" | jq -sc '{"bd-1": .}' > "$f"
}
reset() {
  rm -rf "$T/state" "$T/builds" "$T/answers"
  mkdir -p "$T/state/starved-ready" "$T/builds" "$T/answers"
  rm -f "$T/lane-alerts.txt" "$T/probes.txt" "$T/ready-rows.tsv" "$T/queue-rows.tsv" "$T/ql-calls.txt" \
        "$T/logs/READY-QUEUE.log" "$T/logs/x-os.log"
  printf '{"9025":"TK-25","TK-25":"9025","9026":"TK-26","TK-26":"9026"}\n' > "$T/state/x-os.keymap.json"
}
seed() { # seed <id> <minutes-ago>...
  while [ $# -gt 1 ]; do printf '%s\t%s\n' "$1" "$((NOW - $2 * 60))" >> "$LEDGER"; shift 2; done
}
check() { # check [project] -> runs the lib in a subshell like rt_gate does
  ( . "$T/bin/lib/starved-ready.sh" && starved_ready_check "$T" "${1:-x-os}" ) >"$T/out.txt" 2>"$T/err.txt"
  echo $?
}
calls() { local n; n=$(grep -c . "$T/lane-alerts.txt" 2>/dev/null); echo "${n:-0}"; }
fires() { local n; n=$(cat "$T/lane-alerts.txt" 2>/dev/null | grep -v -- '--resolve' | grep -c -- '--id starved-ready-x-os'); echo "${n:-0}"; }

[ -r "$T/bin/lib/starved-ready.sh" ] || bad "bin/lib/starved-ready.sh must exist"

# ── S1: 61 min, buildable, unowned -> exactly one alert naming the key ──────
reset; board "$T/state/x-os.gate.json" "$(row 9025 -)"; seed 9025 61
RC=$(check)
[ "$RC" = 0 ] && ok || bad "S1: rc=$RC $(cat "$T/err.txt")"
[ "$(calls)" = 1 ] && [ "$(fires)" = 1 ] && ok || bad "S1: want exactly one --id starved-ready-x-os call, got: $(cat "$T/lane-alerts.txt" 2>/dev/null)"
grep -q -- '--severity warn triage' "$T/lane-alerts.txt" 2>/dev/null && ok || bad "S1: warn severity on the triage lane: $(cat "$T/lane-alerts.txt" 2>/dev/null)"
grep -q 'STARVED READY: 1 ticket(s).*TK-25 (61m)' "$T/lane-alerts.txt" 2>/dev/null && ok || bad "S1: the text names TK-25 and its age: $(cat "$T/lane-alerts.txt" 2>/dev/null)"
grep -q 'jobs-client.sh ready-put x-os TK-25 9025' "$T/lane-alerts.txt" 2>/dev/null && ok || bad "S1: the text says how to release it"
[ -e "$MARKER" ] && ok || bad "S1: the alerted marker is written"
[ "$(cat "$T/probes.txt" 2>/dev/null)" = 9025 ] && ok || bad "S1: exactly one strict probe for 9025, got [$(cat "$T/probes.txt" 2>/dev/null)]"

# ── S2-S4: evidence of an owner clears it ───────────────────────────────────
reset; board "$T/state/x-os.gate.json" "$(row 9025 -)"; seed 9025 61
printf 'x-os\tPB-25\t9025\tPB-25 9025 — ready row project=x-os\n' > "$T/ready-rows.tsv"
check >/dev/null; [ "$(calls)" = 0 ] && ok || bad "S2: a ready row owns it: $(cat "$T/lane-alerts.txt")"
[ -e "$T/probes.txt" ] && bad "S2: an owned ticket costs no probe" || ok
reset; board "$T/state/x-os.gate.json" "$(row 9025 -)"; seed 9025 61
printf 'TK-25 9025 — decompose child project=x-os\n' > "$T/logs/READY-QUEUE.log"
check >/dev/null; [ "$(calls)" = 0 ] && ok || bad "S2b: a READY-QUEUE.log line owns it: $(cat "$T/lane-alerts.txt")"
reset; board "$T/state/x-os.gate.json" "$(row 9025 -)"; seed 9025 61
printf 'x-os\tPB-25\t9025\tclaimed\tlocal\t1\tbox-a\t-\t-\t-\n' > "$T/queue-rows.tsv"
check >/dev/null; [ "$(calls)" = 0 ] && ok || bad "S3: a claimed queue row owns it: $(cat "$T/lane-alerts.txt")"
reset; board "$T/state/x-os.gate.json" "$(row 9025 -)"; seed 9025 61
printf 'x-os\tPB-25\t9025\tdone\tlocal\t1\tbox-a\t-\t-\t-\n' > "$T/queue-rows.tsv"
check >/dev/null; [ "$(fires)" = 1 ] && ok || bad "S3b: a DONE queue row is not an owner: $(cat "$T/lane-alerts.txt" 2>/dev/null)"
reset; board "$T/state/x-os.gate.json" "$(row 9025 -)"; seed 9025 61
mkdir -p "$T/builds/x-os-TK-25-202610031600"
check >/dev/null; [ "$(calls)" = 0 ] && ok || bad "S4: a build dir owns it: $(cat "$T/lane-alerts.txt")"
reset; board "$T/state/x-os.gate.json" "$(row 9025 -)"; seed 9025 61
mkdir -p "$T/builds/x-os-TK-250-202610031600"
check >/dev/null; [ "$(fires)" = 1 ] && ok || bad "S4b: TK-250's build dir is not TK-25's: $(cat "$T/lane-alerts.txt" 2>/dev/null)"

# ── S5: 59 min -> none, and the first-seen clock is kept ────────────────────
reset; board "$T/state/x-os.gate.json" "$(row 9025 -)"; seed 9025 59
check >/dev/null; [ "$(calls)" = 0 ] && ok || bad "S5: 59 minutes is not starved: $(cat "$T/lane-alerts.txt")"
[ "$(cat "$LEDGER")" = "9025	$((NOW - 59*60))" ] && ok || bad "S5: the ledger keeps the first-seen value, got [$(cat "$LEDGER")]"
# A new candidate starts its clock at NOW.
reset; board "$T/state/x-os.gate.json" "$(row 9025 -)"
check >/dev/null; [ "$(cat "$LEDGER")" = "9025	$NOW" ] && ok || bad "S5b: a first sighting is stamped NOW, got [$(cat "$LEDGER" 2>/dev/null)]"
[ "$(calls)" = 0 ] && ok || bad "S5b: a first sighting never pages"

# ── S6: the buildable probe says BLOCKED -> none ────────────────────────────
reset; board "$T/state/x-os.gate.json" "$(row 9025 -)"; seed 9025 61
echo "BLOCKED newest-comment-system" > "$T/answers/9025"
check >/dev/null; [ "$(calls)" = 0 ] && ok || bad "S6: a BLOCKED probe is not starved: $(cat "$T/lane-alerts.txt")"
echo "BLOCKED unreadable" > "$T/answers/9025"
check >/dev/null; [ "$(calls)" = 0 ] && ok || bad "S6b: an unreadable probe is not starved"

# ── S7: not a candidate -> none, and dropped from the ledger ────────────────
for spec in "todo client ready" "todo team needs_clarification" "in_progress team ready"; do
  set -- $spec
  reset; board "$T/state/x-os.gate.json" "$(row 9025 - "$1" "$2" "$3")"; seed 9025 61
  check >/dev/null
  [ "$(calls)" = 0 ] && ok || bad "S7 [$spec]: not a candidate: $(cat "$T/lane-alerts.txt")"
  [ -s "$LEDGER" ] && bad "S7 [$spec]: a non-candidate leaves the ledger: $(cat "$LEDGER")" || ok
done

# ── S8: two starved -> ONE call naming both ─────────────────────────────────
reset; board "$T/state/x-os.gate.json" "$(row 9025 -)" "$(row 9026 TK-26)"; seed 9025 73 9026 61
check >/dev/null
[ "$(calls)" = 1 ] && ok || bad "S8: one family per project, one call, got: $(cat "$T/lane-alerts.txt")"
grep -q 'STARVED READY: 2 ticket(s).*TK-25 (73m).*TK-26 (61m)' "$T/lane-alerts.txt" 2>/dev/null && ok \
  || bad "S8: the call names both: $(cat "$T/lane-alerts.txt" 2>/dev/null)"

# ── S9: fail-open on outages ────────────────────────────────────────────────
reset; board "$T/state/x-os.gate.json" "$(row 9025 -)"; seed 9025 61; touch "$MARKER"
BEFORE=$(cat "$LEDGER")
RC=$(QL_RC=1 check)
[ "$RC" = 0 ] && ok || bad "S9: an outage is rc 0"
[ "$(calls)" = 0 ] && ok || bad "S9: a queue outage never alerts or resolves: $(cat "$T/lane-alerts.txt")"
[ "$(cat "$LEDGER")" = "$BEFORE" ] && ok || bad "S9: the ledger is unchanged on an outage"
[ "$(grep -c 'starved-ready' "$T/logs/x-os.log" 2>/dev/null)" = 1 ] && ok || bad "S9: one log line names the outage: $(cat "$T/logs/x-os.log" 2>/dev/null)"
[ -e "$MARKER" ] && ok || bad "S9: the marker survives an outage"
reset
RC=$(check)
[ "$RC" = 0 ] && [ "$(calls)" = 0 ] && [ ! -s "$T/err.txt" ] && ok || bad "S9b: no gate state -> nothing, rc 0, no stderr (rc=$RC): $(cat "$T/err.txt")"
reset; printf 'not json' > "$T/state/x-os.gate.json"; seed 9025 61
BEFORE=$(cat "$LEDGER"); RC=$(check)
[ "$RC" = 0 ] && [ "$(calls)" = 0 ] && [ "$(cat "$LEDGER")" = "$BEFORE" ] && ok || bad "S9c: an unparseable gate state -> nothing, ledger unchanged"

# ── S10: resolve once when clean ────────────────────────────────────────────
reset; board "$T/state/x-os.gate.json" "$(row 9025 -)"; seed 9025 61; touch "$MARKER"
printf 'x-os\tPB-25\t9025\tqueued\tlocal\t1\t-\t-\t-\t-\n' > "$T/queue-rows.tsv"
check >/dev/null
[ "$(calls)" = 1 ] && grep -q -- '--resolve --id starved-ready-x-os triage' "$T/lane-alerts.txt" && ok \
  || bad "S10: one resolve call when the marker is set and nothing is starved: $(cat "$T/lane-alerts.txt" 2>/dev/null)"
[ -e "$MARKER" ] && bad "S10: the marker is removed on resolve" || ok
check >/dev/null
[ "$(calls)" = 1 ] && ok || bad "S10b: a clean tick with no marker sends no resolve: $(cat "$T/lane-alerts.txt")"

# ── S11: switches, lanes, sources, keys, cap ────────────────────────────────
reset; board "$T/state/x-os.gate.json" "$(row 9025 -)"; seed 9025 61
STARVED_READY=0 check >/dev/null; [ "$(calls)" = 0 ] && ok || bad "S11: STARVED_READY=0 is off"
reset; mkdir -p "$T/state"; board "$T/state/ghproj.gate.json" "$(row 9025 TK-25)"
printf '9025\t%s\n' "$((NOW - 7200))" > "$T/state/starved-ready/ghproj.tsv"
check ghproj >/dev/null; [ "$(calls)" = 0 ] && ok || bad "S11: a GitHub-Issues project is not this lib's"
reset; board "$T/state/x-os.gate.json" "$(row 9025 - done)"; board "$T/state/x-os.gate.pending" "$(row 9025 -)"; seed 9025 61
check >/dev/null; [ "$(fires)" = 1 ] && ok || bad "S11: gate.pending is preferred over gate.json"
reset; printf '{}\n' > "$T/state/x-os.keymap.json"; board "$T/state/x-os.gate.json" "$(row 9025 -)"; seed 9025 61
check >/dev/null; [ "$(calls)" = 0 ] && ok || bad "S11: a row with no key is skipped"
reset; board "$T/state/x-os.gate.json" "$(row 9025 -)" "$(row 9026 -)"; seed 9025 61 9026 61; touch "$MARKER"
echo "BLOCKED dependencies TK-25" > "$T/answers/9025"; echo "BLOCKED dependencies TK-25" > "$T/answers/9026"
STARVED_READY_PROBE_MAX=1 check >/dev/null
[ "$(grep -c . "$T/probes.txt")" = 1 ] && ok || bad "S11: probe cap 1 -> 1 probe, got $(grep -c . "$T/probes.txt")"
grep -q -- '--resolve' "$T/lane-alerts.txt" 2>/dev/null && bad "S11: a capped tick never resolves" || ok

reset; board "$T/state/x-os.gate.json" "$(row 9025 -)" "$(row 9026 -)"; seed 9025 61 9026 61
STARVED_READY_PROBE_MAX=1 check >/dev/null
grep -q 'STARVED READY: 1 ticket(s).*probe cap 1 reached: more may be starved' "$T/lane-alerts.txt" 2>/dev/null && ok \
  || bad "S11: a capped page says its count may be short: $(cat "$T/lane-alerts.txt" 2>/dev/null)"

# ── S12: the rt_gate wiring fires on a SKIP no-change tick ──────────────────
reset; board "$T/state/x-os.gate.json" "$(row 9025 -)"; seed 9025 61
cp "$DIR/bin/lib/rt/gate.sh" "$T/bin/lib/rt/"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/orphan-reconcile.sh"; cp "$T/bin/orphan-reconcile.sh" "$T/bin/hotfix-seen.sh"
chmod +x "$T/bin/"*.sh
OUT=$( ( PROJECT=x-os STAMP=now LOG="$T/logs/x-os.log" ALERTS="$T/logs/ALERTS.log" ORPHAN_RECONCILE=0
        LANE_TICK() { echo "$1" >> "$T/lane-ticks.txt"; }
        . "$T/bin/lib/rt/gate.sh"
        rt_gate
        echo "CONTINUED" ) 2>/dev/null ); RC=$?
[ "$RC" = 0 ] && ok || bad "S12: rt_gate exits 0 on a SKIP tick (rc=$RC)"
case "$OUT" in *CONTINUED*) bad "S12: a SKIP tick must end inside rt_gate" ;; *) ok ;; esac
grep -q 'rc=skip :: gate no-change (57 tickets)' "$T/logs/x-os.log" 2>/dev/null && ok || bad "S12: the tick was a SKIP: $(cat "$T/logs/x-os.log" 2>/dev/null)"
[ "$(fires)" = 1 ] && ok || bad "S12: the starved alert fires on the SKIP tick: $(cat "$T/lane-alerts.txt" 2>/dev/null)"

echo "starved-ready-ticket-alarm.bh-3970: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
