#!/bin/bash
# tests/restore-drill-health.bh-400-test.sh — BH-1733 (BH-400.3): the hub pages
# when the last restore drill FAILED, or when no drill has passed in
# RESTORE_DRILL_STALE_DAYS days (default 8), counted from last_ok_ts and from
# first_run_ts when none has ever passed. No marker, or one that will not parse,
# never pages: it writes one pipeline-health.log line. Both keys retract on the
# next tick where the condition has cleared.
#
# WHAT IS UNDER TEST: the `# >>> restore drill` block of bin/pipeline-health.sh,
# extracted VERBATIM by its markers and run with the REAL alert() and the REAL
# retraction epilogue (same shape as tests/backup-freshness-test.sh §B), plus
# one run of the whole cron script so a block that is fine in isolation but
# unreachable in the file goes red too. Fixtures follow the marker schema
# pinned in bin/restore-drill.sh:23-25.
#
# PH_FILE=<path> points the suite at another copy of the lane (mutation checks).
#
# Run from anywhere: tests/restore-drill-health.bh-400-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PH="${PH_FILE:-$DIR/bin/pipeline-health.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=$(date +%s)
DAY=86400
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/stubs" "$T/tmp"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEATS"\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/bin/"

# ── R0: extraction from the shipped file ─────────────────────────────────────
grep -c '^# >>> restore drill$' "$PH" >/dev/null && grep -c '^# <<< restore drill$' "$PH" >/dev/null \
  && ok || bad "R0a: the # >>> restore drill / # <<< restore drill markers must both exist in $PH"
grep '^RETRACT_NS=' "$PH"                                                 > "$T/p1.sh"
awk '/^# >>> alert emit cap/{f=1;next} /^# <<< alert emit cap/{exit} f' "$PH" > "$T/p0.sh"
awk '/^alert\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$PH"                  > "$T/p2.sh"
awk '/^# >>> restore drill/{f=1;next} /^# <<< restore drill/{exit} f' "$PH" > "$T/p3.sh"
awk '/^# ── Retraction epilogue/{f=1} f{print} /^rm -f "\$FIRED"$/&&f{exit}' "$PH" > "$T/p4.sh"
[ -s "$T/p1.sh" ] && ok || bad "R0b: no RETRACT_NS= line"
[ -s "$T/p2.sh" ] && ok || bad "R0c: could not extract alert()"
grep -q '[^[:space:]]' "$T/p3.sh" && ok || bad "R0d: the restore drill block is missing or empty"
[ -s "$T/p4.sh" ] && ok || bad "R0e: could not extract the retraction epilogue"
cat "$T/p1.sh" "$T/p0.sh" "$T/p2.sh" "$T/p3.sh" "$T/p4.sh" > "$T/block.sh"
bash -n "$T/block.sh" 2>/dev/null && ok || bad "R0f: the extracted block is not valid bash"

MARK="$T/state/restore-drill-last.json"
FIRED="$T/state/health-fired.test"
ACTIVE="$T/state/health-active.txt"
DEDUP="$T/state/health-alerted.json"

fresh() { # a clean tree: no alerts, no dedupe, no active set, no marker
  : > "$T/logs/ALERTS.log"; : > "$T/logs/pipeline-health.log"; : > "$T/beats.txt"
  : > "$ACTIVE"; echo '{}' > "$DEDUP"; rm -f "$MARK"
}
tick() { # one cron tick of the real block + the real epilogue; extra args are env
  : > "$FIRED"
  ( export HARNESS="$T" BEATS="$T/beats.txt" T NOW FIRED ACTIVE
    # shellcheck disable=SC2163  # the args are NAME=value pairs
    [ $# -eq 0 ] || export "$@"
    bash -c '
      set -uo pipefail
      H="$T"; DEDUP="$T/state/health-alerted.json"
      STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
      . "$0"' "$T/block.sh" >/dev/null 2>"$T/err.txt" )
  echo $? > "$T/rc.txt"
}
# marker <verdict> <last_ok_ts|null> <first_run_ts|null> [detail]
marker() {
  jq -n --argjson ts "$NOW" --arg v "$1" --argjson lo "$2" --argjson fr "$3" --arg d "${4:-}" \
    '{ts: $ts, verdict: $v, detail: $d, rpo_s: null, deleted: true, last_ok_ts: $lo, first_run_ts: $fr}
     | if $fr == null then del(.first_run_ts) else . end' > "$MARK"
}
alines() { local n; n=$(grep -c "$1" "$T/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }
allalines() { local n; n=$(grep -c . "$T/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }
rdlog() { local n; n=$(grep -c 'restore drill' "$T/logs/pipeline-health.log" 2>/dev/null); echo "${n:-0}"; }
fired() { grep -qxF "$1" "$ACTIVE"; }   # the epilogue copies FIRED (sorted) into ACTIVE
clean() { [ "$(cat "$T/rc.txt")" = 0 ] && [ ! -s "$T/err.txt" ]; }
A() { cat "$T/logs/ALERTS.log"; }

# ── C4-stale-ok: last pass 9 days ago ────────────────────────────────────────
fresh; marker OK $((NOW - 9*DAY)) $((NOW - 30*DAY)); tick
clean && ok || bad "C4-stale-ok: tick rc=$(cat "$T/rc.txt") err=$(cat "$T/err.txt")"
[ "$(allalines)" = 1 ] && ok || bad "C4-stale-ok: exactly one ALERTS line (got: $(A))"
grep -q 'restore drill.*9 days' "$T/logs/ALERTS.log" \
  && ok || bad "C4-stale-ok: the stale line must name the drill and the 9 days (got: $(A))"
fired restoredrillstale:hub && ok || bad "C4-stale-ok: restoredrillstale:hub must fire"
fired restoredrillfail:hub && bad "C4-stale-ok: an OK verdict must not fire restoredrillfail" || ok
grep -q 'restoredrillstale:hub' "$T/beats.txt" && ok || bad "C4-stale-ok: the page must be beaten with its key"

# ── C4-fail: FAIL verdict, last pass yesterday ───────────────────────────────
fresh; marker FAIL $((NOW - 1*DAY)) $((NOW - 30*DAY)) 'pg_restore exited 1'; tick
clean && ok || bad "C4-fail: tick rc=$(cat "$T/rc.txt") err=$(cat "$T/err.txt")"
grep -q 'pg_restore exited 1' "$T/logs/ALERTS.log" \
  && ok || bad "C4-fail: the page must carry the marker's detail (got: $(A))"
fired restoredrillfail:hub && ok || bad "C4-fail: restoredrillfail:hub must fire"
fired restoredrillstale:hub && bad "C4-fail: a pass 1 day ago is not stale" || ok
[ "$(allalines)" = 1 ] && ok || bad "C4-fail: exactly one ALERTS line (got: $(A))"

# FAIL with no detail still says something true.
fresh; marker FAIL $((NOW - 1*DAY)) $((NOW - 30*DAY)); tick
grep -q 'no detail given' "$T/logs/ALERTS.log" \
  && ok || bad "C4-fail-nodetail: an empty detail renders as 'no detail given' (got: $(A))"

# FAIL AND stale page together: different conditions, different keys.
fresh; marker FAIL $((NOW - 20*DAY)) $((NOW - 30*DAY)) 'boom'; tick
fired restoredrillfail:hub && fired restoredrillstale:hub \
  && ok || bad "C4-fail+stale: both keys must fire (active: $(cat "$ACTIVE"))"
[ "$(allalines)" = 2 ] && ok || bad "C4-fail+stale: two ALERTS lines (got: $(A))"

# ── C4-never-ok: SKIP, never passed, first run 9 days ago ────────────────────
fresh; marker SKIP null $((NOW - 9*DAY)); tick
clean && ok || bad "C4-never-ok: tick rc=$(cat "$T/rc.txt") err=$(cat "$T/err.txt")"
fired restoredrillstale:hub && ok || bad "C4-never-ok: staleness counts from first_run_ts when last_ok_ts is null"
grep -q '9 days' "$T/logs/ALERTS.log" && ok || bad "C4-never-ok: the line carries the age (got: $(A))"
fired restoredrillfail:hub && bad "C4-never-ok: SKIP is not FAIL" || ok

# ── C4b: the states that must NOT page ───────────────────────────────────────
fresh; marker OK $((NOW - 7*DAY)) $((NOW - 30*DAY)); tick
clean && [ ! -s "$T/logs/ALERTS.log" ] && ok || bad "C4b-ok-7d: a pass 7 days ago must not page (got: $(A))"

fresh; marker SKIP null $((NOW - 7*DAY)); tick
clean && [ ! -s "$T/logs/ALERTS.log" ] && ok || bad "C4b-skip-young: an unarmed drill 7 days old must not page (got: $(A))"

fresh; tick
clean && ok || bad "C4b-no-marker: tick rc=$(cat "$T/rc.txt") err=$(cat "$T/err.txt")"
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "C4b-no-marker: no marker must not page (got: $(A))"
[ "$(rdlog)" = 1 ] && ok || bad "C4b-no-marker: exactly one pipeline-health.log line (got: $(cat "$T/logs/pipeline-health.log"))"
[ ! -e "$MARK" ] && ok || bad "C4b-no-marker: the block must never create the marker"

for G in empty notjson emptyobj; do
  fresh
  case $G in empty) : > "$MARK" ;; notjson) echo 'not json' > "$MARK" ;; emptyobj) echo '{}' > "$MARK" ;; esac
  tick
  clean && ok || bad "C4b-garbage($G): rc=$(cat "$T/rc.txt") stderr=$(cat "$T/err.txt")"
  [ ! -s "$T/logs/ALERTS.log" ] && ok || bad "C4b-garbage($G): must not page (got: $(A))"
  [ "$(rdlog)" = 1 ] && ok || bad "C4b-garbage($G): exactly one pipeline-health.log line (got: $(cat "$T/logs/pipeline-health.log"))"
done

fresh; marker OK $((NOW + 3*DAY)) $((NOW + 3*DAY)); tick
clean && [ ! -s "$T/logs/ALERTS.log" ] && ok || bad "C4b-future: a base in the future must not page (got: $(A))"

# D11: no base at all is not epoch 0 (which would read as 20,000 days stale).
fresh; marker SKIP null null; tick
clean && [ ! -s "$T/logs/ALERTS.log" ] && ok || bad "C4b-nobase: a missing base must not page on staleness (got: $(A))"
[ "$(rdlog)" = 1 ] && ok || bad "C4b-nobase: one log line says staleness was not checked (got: $(cat "$T/logs/pipeline-health.log"))"

# ── R-dedupe: two ticks at the same NOW page once ────────────────────────────
fresh; marker FAIL $((NOW - 1*DAY)) $((NOW - 30*DAY)) 'x'; tick; tick
[ "$(alines 'restore drill failed')" = 1 ] && ok || bad "R-dedupe: a second tick must not page again (got: $(A))"

# ── R-retract: FAIL pages, then an OK marker retracts it ─────────────────────
fresh; marker FAIL $((NOW - 1*DAY)) $((NOW - 30*DAY)) 'x'; tick
[ "$(jq -r 'has("restoredrillfail:hub")' "$DEDUP")" = true ] && ok || bad "R-retract: the page must stamp DEDUP"
marker OK "$NOW" $((NOW - 30*DAY)); tick
grep -q 'RESOLVED restoredrillfail:hub' "$T/logs/ALERTS.log" \
  && ok || bad "R-retract: an OK drill must retract restoredrillfail:hub (got: $(A))"
[ "$(jq -r 'has("restoredrillfail:hub")' "$DEDUP")" = false ] && ok || bad "R-retract: the DEDUP stamp must be cleared"

fresh; marker OK $((NOW - 9*DAY)) $((NOW - 30*DAY)); tick
marker OK "$NOW" $((NOW - 30*DAY)); tick
grep -q 'RESOLVED restoredrillstale:hub' "$T/logs/ALERTS.log" \
  && ok || bad "R-retract: a fresh pass must retract restoredrillstale:hub (got: $(A))"

# ── C-knob ───────────────────────────────────────────────────────────────────
fresh; marker OK $((NOW - 9*DAY)) $((NOW - 30*DAY)); tick RESTORE_DRILL_STALE_DAYS=10
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "C-knob: RESTORE_DRILL_STALE_DAYS=10 puts 9 days under the line (got: $(A))"
fresh; marker OK $((NOW - 9*DAY)) $((NOW - 30*DAY)); tick RESTORE_DRILL_STALE_DAYS=abc
clean && ok || bad "C-knob: a bad knob must not break the tick: $(cat "$T/err.txt")"
fired restoredrillstale:hub && ok || bad "C-knob: RESTORE_DRILL_STALE_DAYS=abc falls back to 8 and pages at 9 days"
grep -q "abc" "$T/logs/pipeline-health.log" && ok || bad "C-knob: the fallback must name the bad value (got: $(cat "$T/logs/pipeline-health.log"))"

# ── C-copy: no em dashes in any page this block writes ───────────────────────
fresh; marker FAIL $((NOW - 20*DAY)) $((NOW - 30*DAY)) 'boom'; tick
grep -q '—' "$T/logs/ALERTS.log" && bad "C-copy: the pages must carry no em dash (got: $(A))" || ok

# ── C-readonly: the block never writes the marker ────────────────────────────
fresh; marker FAIL $((NOW - 20*DAY)) $((NOW - 30*DAY)) 'boom'
S1=$(sha256sum < "$MARK"); tick; S2=$(sha256sum < "$MARK")
[ "$S1" = "$S2" ] && ok || bad "C-readonly: the marker changed under a tick"

# ── D2: the whole cron script, not the extract ───────────────────────────────
fresh; marker FAIL $((NOW - 1*DAY)) $((NOW - 30*DAY)) 'pg_restore exited 1'
for C in gh git curl ssh flock timeout; do
  printf '#!/bin/bash\nexit 1\n' > "$T/stubs/$C"; chmod +x "$T/stubs/$C"
done
: > "$T/fleet.conf"
( export HARNESS="$T" PATH="$T/stubs:$PATH" HEALTH_TMP_ROOT="$T/tmp" BEATS="$T/beats.txt"
  bash "$PH" >/dev/null 2>"$T/err-full.txt" )
echo $? > "$T/rc.txt"
[ "$(cat "$T/rc.txt")" = 0 ] && ok || bad "D2: the whole script must exit 0: rc=$(cat "$T/rc.txt") $(cat "$T/err-full.txt")"
grep -q 'pg_restore exited 1' "$T/logs/ALERTS.log" \
  && ok || bad "D2: a real run of the lane must page on a FAIL marker (got: $(A))"

echo "restore-drill-health.bh-400-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
