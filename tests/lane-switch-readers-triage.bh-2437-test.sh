#!/bin/bash
# tests/lane-switch-readers-triage.bh-2437-test.sh — the four triage kill
# switches are read through lane_switch (BH-2437, child of BH-2410): a settings
# row decides before flags/<name>, and with no row the file decides as before.
#
#   L3  triage_shards_on        (bin/lib/triage-shards-lib.sh) prints 0 / 1 / 0
#   L3b triage_caps_on          (same lib, TRIAGE_SHARD_CAPS=1) prints 0 / 1 / 0
#   L4  triage_health_on        (bin/lib/triage-throttle.sh)    prints 0 / 1 / 0
#   S3  the real bin/triage-spool-retire.sh on one aged line: row 1 keeps it,
#       row 0 plus the file retires it into state/alert-triage-expired-<day>.tsv
#   L7a a tree with no lane-switch.sh/lane-gate.sh: the file still kills each of
#       the four, and no file leaves each on (the loader's stub fallback)
#   L7b sourcing either lib alone defines no lane_switch (the load is lazy)
#   L7c rows `yes please`, `2` and another box's row do not kill shards
#   L7d a cached row keeps answering when the worker is unreachable
#   D1  a copy with the triage-shards-off read reverted to the bare file fails L3
#       on the row cases, and L3b/L4/S3 on that same copy still pass
# Run from anywhere: tests/lane-switch-readers-triage.bh-2437-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/lane-switch-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
cases() { local out; out=$(lsf_cases "$@"); local rc=$?; [ -n "$out" ] && echo "$out"; [ "$rc" -eq 0 ] && ok || FAIL=$((FAIL+rc)); }

READERS="bin/lib/triage-shards-lib.sh bin/lib/triage-throttle.sh bin/triage-spool-retire.sh"
# shellcheck disable=SC2086
lsf_setup $READERS || { echo "FAIL: lsf_setup"; exit 1; }

probe_shards() { . "$H/bin/lib/triage-shards-lib.sh"; triage_shards_on "$H"; }
probe_caps()   { . "$H/bin/lib/triage-shards-lib.sh"; TRIAGE_SHARD_CAPS=1 triage_caps_on "$H"; }
probe_health() { . "$H/bin/lib/triage-throttle.sh"; triage_health_on "$H"; }

# S3 — one line two days old; kept -> 0 (the switch held it), retired -> 1.
NOW=1790000000
DAY=$(date -u -d "@$NOW" +%Y%m%d)
probe_spool() {
  local wf="$T/spool.tsv"
  printf 'hub\t%s\t{"kind":"fleet_alert","line":"the bh2437 subsystem is unhappy"}\n' "$((NOW - 172800))" > "$wf"
  rm -f "$H/state/alert-triage-expired-$DAY.tsv"
  TRIAGE_NOW="$NOW" TRIAGE_PRSTATE_MAX_LOOKUPS=0 "$H/bin/triage-spool-retire.sh" "$wf" >/dev/null 2>&1
  if grep -q 'bh2437 subsystem' "$wf" && ! grep -qs 'bh2437 subsystem' "$H/state/alert-triage-expired-$DAY.tsv"; then
    printf 0
  elif ! grep -q 'bh2437 subsystem' "$wf" && grep -qs 'bh2437 subsystem' "$H/state/alert-triage-expired-$DAY.tsv"; then
    printf 1
  else
    printf 'inconsistent'
  fi
}

run_all() {
  cases triage-shards-off probe_shards 0 1
  cases triage-shard-caps-off probe_caps 0 1
  cases triage-health-off probe_health 0 1
  cases triage-spool-age-off probe_spool 0 1
}
run_all

# L7a — no resolver in the tree: the stub reads the file.
H_SAVE="$H"
H="$T/l7a/h"
mkdir -p "$H/flags" "$H/state" "$H/logs"
for r in $READERS; do mkdir -p "$H/$(dirname "$r")"; cp "$DIR/$r" "$H/$r"; done
[ ! -e "$H/bin/lib/lane-switch.sh" ] && [ ! -e "$H/bin/lib/lane-gate.sh" ] && ok || bad "L7a tree carries the resolver"
for pair in triage-shards-off:probe_shards triage-shard-caps-off:probe_caps \
            triage-health-off:probe_health triage-spool-age-off:probe_spool; do
  n=${pair%%:*}; p=${pair#*:}
  touch "$H/flags/$n"
  eq "L7a $n file, no resolver" "$(_lsf_probe "$p")" 0
  rm -f "$H/flags/$n"
  eq "L7a $n no file, no resolver" "$(_lsf_probe "$p")" 1
done
H="$H_SAVE"

# L7b — sourcing the lib alone defines nothing new.
for lib in triage-shards-lib.sh triage-throttle.sh; do
  HARNESS="$H" bash -c '. "$1" >/dev/null 2>&1; command -v lane_switch >/dev/null 2>&1' _ "$H/bin/lib/$lib"
  eq "L7b $lib defines lane_switch at source time (rc)" "$?" 1
done

# L7c — unreadable values and another box's row are no row; no file -> on.
for v in 'yes please' 2; do
  lsf_reset; lsf_row triage-shards-off "$v"
  eq "L7c row '$v'" "$(_lsf_probe probe_shards)" 1
done
lsf_reset; lsf_row triage-shards-off 1 other-box
eq "L7c other box's row" "$(LSF_BOX=hub-1 _lsf_probe probe_shards)" 1
lsf_reset; lsf_row triage-shards-off 1 hub-1
eq "L7c this box's row (control)" "$(LSF_BOX=hub-1 _lsf_probe probe_shards)" 0

# L7d — the cache outlives the worker.
lsf_reset; lsf_row triage-shards-off 1
eq "L7d first read, worker up" "$(_lsf_probe probe_shards)" 0
: > "$CALLS"
eq "L7d worker down, cache past TTL" \
   "$(UNREACHABLE=1 LANE_GATE_NOW=$(( $(date -u +%s) + 864000 )) _lsf_probe probe_shards)" 0
grep -q 'GET /api/settings' "$CALLS" && ok || bad "L7d the second read never tried a refresh (TTL not passed)"
lsf_reset

# D1 — revert T1's read in a copy; L3 must go red on the row cases only.
cp "$H/bin/lib/triage-shards-lib.sh" "$T/shards-lib.orig"
# BH-2650 put an optional `[ -n "$h" ] && ` no-root guard in front of the read.
sed -i 's|^\(\s*\)\(\[ -n "\$h" \] && \)\{0,1\}HARNESS="\$h" lane_switch triage-shards-off &&|\1[ -e "$h/flags/triage-shards-off" ] \&\&|' "$H/bin/lib/triage-shards-lib.sh"
if cmp -s "$T/shards-lib.orig" "$H/bin/lib/triage-shards-lib.sh"; then
  bad "D1 the mutation did not apply (the triage-shards-off read is not the converted line)"
else
  out=$(lsf_cases triage-shards-off probe_shards 0 1); rc=$?
  [ "$rc" -ne 0 ] && ok || bad "D1 L3 stayed green on the reverted read"
  grep -q '(i):' <<<"$out" && ok || bad "D1 case (i) did not fail on the reverted read"
  grep -q '(iii):' <<<"$out" && bad "D1 case (iii) failed on the reverted read (file-only must still kill)" || ok
  for pair in triage-shard-caps-off:probe_caps triage-health-off:probe_health triage-spool-age-off:probe_spool; do
    lsf_cases "${pair%%:*}" "${pair#*:}" 0 1 >/dev/null && ok || bad "D1 ${pair%%:*} went red on the triage-shards-off mutation"
  done
fi
cp "$T/shards-lib.orig" "$H/bin/lib/triage-shards-lib.sh"

echo "lane-switch-readers-triage: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
