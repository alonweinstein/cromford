#!/bin/bash
# tests/lane-down-lib.bh-1686-test.sh — BH-1686 (part 1 of BH-1674): the shared
# lane-down state library bin/lib/lane-down.sh, sourced for real into a scratch
# harness. The canary and the re-probe lane (siblings 2-5) both call it, so a
# lane that went down is marked, cleared and announced the same way by both.
#
# The cases, from the issue:
#   A0 sourcing creates nothing and defines the seven public functions
#   A1 ld_mark makes the record, the exact STATE line and today's flag (once)
#   A2 since backfills from the CONTIGUOUS flag run; ld_get tolerates absence
#   A3 ld_clear removes ONLY the exact line; bare box lines survive
#   A4 ld_probe_ok accepts a standalone ok and rejects every listed negative
#   A5 ld_fmt_dur
#   A6 last_error flattened + capped at 160; since/addr kept; no tmp left over
#   A7 ld_recovered: one "back on" line, one RECOVERED line, both resolves
#   A8 the STATE edit really waits on locks/lane-down-state.lock
#   A9 a set -euo pipefail caller survives ld_mark/ld_clear on a flagless lane
#
# Run from anywhere: tests/lane-down-lib.bh-1686-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
LIB=$(cd "$(dirname "$0")/.." && pwd)/bin/lib/lane-down.sh
. "$LIB" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=1790000000
day() { date -u -d "@$((NOW - $1*86400))" +%Y%m%d; }
TODAY=$(day 0)
H=$T/h; mkdir -p "$H"
STATE=$H/state/claude-auth-down.txt

# A0 ------------------------------------------------------------------------
mkdir -p "$T/h0"
( cd "$T/h0" && H=$T/h0 HARNESS=$T/h0 . "$LIB" )
[ -z "$(find "$T/h0" -mindepth 1)" ] && ok || bad "A0: sourcing the lib created files"
for f in ld_record_path ld_get ld_probe_ok ld_fmt_dur ld_mark ld_clear ld_recovered; do
  declare -F "$f" >/dev/null && ok || bad "A0: $f is not defined"
done

# A1 ------------------------------------------------------------------------
ld_mark "$H" hub-grok 1.2.3.4 "401 Unauthorized" "$NOW"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "A1: ld_mark rc=$rc"
REC=$(ld_record_path "$H" hub-grok)
[ "$REC" = "$H/state/lane-down/hub-grok" ] && ok || bad "A1: record path is '$REC'"
[ -f "$REC" ] && ok || bad "A1: no record at $REC"
[ "$(ld_get "$REC" box)" = hub ] && ok || bad "A1: box='$(ld_get "$REC" box)'"
[ "$(ld_get "$REC" lane)" = grok ] && ok || bad "A1: lane='$(ld_get "$REC" lane)'"
[ "$(ld_get "$REC" last_probe)" = "$NOW" ] && ok || bad "A1: last_probe='$(ld_get "$REC" last_probe)'"
[ "$(grep -cxF hub-grok "$STATE" 2>/dev/null)" = 1 ] && ok || bad "A1: STATE line hub-grok missing"
[ -f "$H/flags/lanedown-hub-grok-$TODAY" ] && ok || bad "A1: today's flag missing"
ld_mark "$H" hub-grok "" "401 Unauthorized" "$((NOW+60))"
[ "$(grep -cxF hub-grok "$STATE")" = 1 ] && ok || bad "A1: second ld_mark duplicated the STATE line"

# A2 ------------------------------------------------------------------------
mkdir -p "$H/flags"
touch "$H/flags/lanedown-project-4-fireworks-$(day 0)" "$H/flags/lanedown-project-4-fireworks-$(day 1)" \
      "$H/flags/lanedown-project-4-fireworks-$(day 3)"
ld_mark "$H" project-4-fireworks 5.6.7.8 "xAI: team credit limit reached" "$NOW"
WANT=$(date -u -d "$(day 1)" +%s)
GOT=$(ld_get "$(ld_record_path "$H" project-4-fireworks)" since)
[ "$GOT" = "$WANT" ] && ok || bad "A2: since=$GOT, want yesterday 00:00Z $WANT"
# a run ending YESTERDAY (no flag today) still backfills
touch "$H/flags/lanedown-project-3-grok-$(day 1)" "$H/flags/lanedown-project-3-grok-$(day 2)"
ld_mark "$H" project-3-grok "" "x" "$NOW"
WANT=$(date -u -d "$(day 2)" +%s)
GOT=$(ld_get "$(ld_record_path "$H" project-3-grok)" since)
[ "$GOT" = "$WANT" ] && ok || bad "A2: run ending yesterday: since=$GOT, want $WANT"
ld_mark "$H" hub-openrouter "" "x" "$NOW"
GOT=$(ld_get "$(ld_record_path "$H" hub-openrouter)" since)
[ "$GOT" = "$NOW" ] && ok || bad "A2: no flags: since=$GOT, want $NOW"
[ -z "$(ld_get "$(ld_record_path "$H" hub-openrouter)" nosuchkey)" ] && ok || bad "A2: missing key not empty"
OUT=$(ld_get "$H/state/lane-down/nope-nope" box); rc=$?
[ -z "$OUT" ] && [ "$rc" -eq 0 ] && ok || bad "A2: missing record gave '$OUT' rc=$rc"

# A3 ------------------------------------------------------------------------
printf '%s\n' hub project-4 project-4-grok project-4-grok-extra >> "$STATE"
ld_mark "$H" project-4-grok 9.9.9.9 "Connection timed out" "$NOW"
DUR=$(ld_clear "$H" project-4-grok "$((NOW+3900))"); rc=$?
[ "$rc" -eq 0 ] && ok || bad "A3: ld_clear rc=$rc"
for l in hub project-4 project-4-grok-extra hub-grok; do
  grep -qxF "$l" "$STATE" && ok || bad "A3: line '$l' did not survive ld_clear project-4-grok"
done
grep -qxF project-4-grok "$STATE" && bad "A3: project-4-grok still in STATE" || ok
[ -e "$H/flags/lanedown-project-4-grok-$TODAY" ] && bad "A3: today's flag not removed" || ok
[ -e "$(ld_record_path "$H" project-4-grok)" ] && bad "A3: record not removed" || ok
[ "$DUR" = "1h 5m" ] && ok || bad "A3: duration '$DUR', want '1h 5m'"
# a bad ID writes nothing
ld_mark "$H" "../evil" "" "x" "$NOW"; rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$H/state/evil" ] && ! grep -qxF "../evil" "$STATE" && ok || bad "A3: bad ID rc=$rc"

# A4 ------------------------------------------------------------------------
ld_probe_ok "ok" && ok || bad "A4: 'ok' rejected"
ld_probe_ok "claude says OK." && ok || bad "A4: 'claude says OK.' rejected"
for neg in "no model route for the grok lane (rc 75) — not probed" "" "codex-cli-version=0.46.0" \
    "401 Unauthorized" "ssh: connect to host 1.2.3.4 port 22: Connection timed out" \
    "xAI: team credit limit reached" tokens broken invoked; do
  ld_probe_ok "$neg" && bad "A4: accepted '$neg'" || ok
done

# A5 ------------------------------------------------------------------------
for c in "59:0m" "3900:1h 5m" "90061:1d 1h" "-5:0m" "abc:0m"; do
  got=$(ld_fmt_dur "${c%%:*}")
  [ "$got" = "${c#*:}" ] && ok || bad "A5: ld_fmt_dur ${c%%:*} = '$got', want '${c#*:}'"
done

# A6 ------------------------------------------------------------------------
LONG=$(printf 'line one=%s\nline two %s\n' "$(printf 'a%.0s' $(seq 140))" "$(printf 'b%.0s' $(seq 140))")
ld_mark "$H" hub-codex 1.2.3.4 "$LONG" "$NOW"
REC=$(ld_record_path "$H" hub-codex)
E=$(ld_get "$REC" last_error)
[ "${#E}" -eq 160 ] && ok || bad "A6: last_error length ${#E}, want 160"
[ "$(grep -c '^last_error=' "$REC")" = 1 ] && [ "$(wc -l < "$REC")" -eq 7 ] && ok || bad "A6: record is not 7 one-line fields"
[ "${E:0:9}" = "line one=" ] && ok || bad "A6: last_error lost the '=' value prefix: '${E:0:12}'"
S1=$(ld_get "$REC" since)
ld_mark "$H" hub-codex "" "again" "$((NOW+600))"
[ "$(ld_get "$REC" addr)" = 1.2.3.4 ] && ok || bad "A6: empty addr overwrote addr"
[ "$(ld_get "$REC" since)" = "$S1" ] && ok || bad "A6: since changed on re-mark"
[ "$(ld_get "$REC" last_probe)" = "$((NOW+600))" ] && ok || bad "A6: last_probe not updated"
ld_mark "$H" hub-codex 4.4.4.4 "again" "$((NOW+700))"
[ "$(ld_get "$REC" addr)" = 4.4.4.4 ] && ok || bad "A6: non-empty addr not updated"
[ -z "$(find "$H/state" -name '*.tmp.*')" ] && ok || bad "A6: tmp files left under state/"

# A7 ------------------------------------------------------------------------
mkdir -p "$H/bin"
printf '#!/bin/bash\necho "$*" >> %q\n' "$T/calls" > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"
ld_mark "$H" project-4-grok 9.9.9.9 "x" "$NOW"
ld_recovered "$H" project-4-grok "$((NOW+7200))"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "A7: ld_recovered rc=$rc"
[ "$(grep -c ' lane grok back on project-4 after ' "$H/logs/lane-reprobe.log" 2>/dev/null)" = 1 ] && ok \
  || bad "A7: want exactly one 'back on' line"
grep -q ' lane grok back on project-4 after 2h 0m$' "$H/logs/lane-reprobe.log" && ok || bad "A7: duration wrong in back-on line"
[ "$(grep -cF '[auth] project-4-grok RECOVERED' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "A7: RECOVERED line"
[ "$(wc -l < "$T/calls" 2>/dev/null)" = 2 ] && ok || bad "A7: want 2 lane-alert calls"
grep -qF -- '--resolve --id lanedown-project-4-grok auth lane grok back on project-4 after' "$T/calls" && ok || bad "A7: lanedown resolve"
grep -qF -- '--resolve --id lanedown-stale-project-4-grok auth' "$T/calls" && ok || bad "A7: lanedown-stale resolve"
grep -qxF project-4-grok "$STATE" && bad "A7: STATE line not cleared" || ok

# A8 ------------------------------------------------------------------------
LOCK=$H/locks/lane-down-state.lock
[ -f "$LOCK" ] && ok || bad "A8: $LOCK not created"
exec 8>"$LOCK"
flock -n 8 || bad "A8: could not take the lock in the test"
( exec 8>&-; ld_clear "$H" hub-grok "$NOW" >/dev/null ) & CPID=$!
# held for 3 s: ld_clear (flock -w 10) must still be waiting, line untouched
timeout 3 tail --pid="$CPID" -f /dev/null && bad "A8: ld_clear finished while the lock was held" || ok
grep -qxF hub-grok "$STATE" && ok || bad "A8: STATE edited while the lock was held"
exec 8>&-
timeout 15 tail --pid="$CPID" -f /dev/null; wait "$CPID"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "A8: ld_clear after lock release rc=$rc"
grep -qxF hub-grok "$STATE" && bad "A8: hub-grok still present after release" || ok

# A9 ------------------------------------------------------------------------
H9=$T/h9; mkdir -p "$H9"
OUT9=$(bash -c 'set -euo pipefail; . "$1"; ld_mark "$2" hub-grok "" 401 "$3"; echo marked
  [ -f "$2/flags/lanedown-hub-grok-$4" ] && grep -qxF hub-grok "$2/state/claude-auth-down.txt" && echo half-ok
  ld_clear "$2" hub-grok "$3"; ld_clear "$2" project-4-none "$3"; echo survived' _ "$LIB" "$H9" "$NOW" "$TODAY" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok || bad "A9: set -e caller died rc=$rc: $OUT9"
grep -qx marked <<<"$OUT9" && ok || bad "A9: set -e caller died inside ld_mark on a flagless lane"
grep -qx half-ok <<<"$OUT9" && ok || bad "A9: ld_mark under set -e left no STATE line or flag"
grep -qx survived <<<"$OUT9" && ok || bad "A9: set -e caller died inside ld_clear on a flagless lane"

echo "lane-down-lib.bh-1686: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
