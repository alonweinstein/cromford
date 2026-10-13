#!/bin/bash
# tests/switch-convert-scripts-b.bh-2428-test.sh — BH-2428 (BH-2409.2): six kill
# switches in five scripts read through lane_switch (bin/lib/lane-switch.sh), so
# a `switch.<name>[.<box>]` settings row settles them before flags/<name> does.
#
# Every case runs the REAL script from $DIR/bin against a scratch HARNESS built
# by tests/lib/switch-fixture.sh (stub settings worker), with record-and-fail
# gh/curl/claude on PATH and every run under `timeout`. The observable is a
# lock the script takes right after the switch, or, where there is none, a
# `+<file>:<LINENO>:` xtrace read for whether the run got past the switch line.
#
#   G1  the six catalog/switches.d files parse, name = basename, box_scoped is
#       a boolean, every reader exists. Nothing is asserted about registry
#       files this slice does not add: sibling slices own those, and a
#       tree-scoped absence check went red the day one of them merged (r1).
#   G2  the real bin/switch-migrate.sh --dry-run walks all six
#   S1  watchdog-responder responder-disabled: (a) row 1 no file -> no lock,
#       (b) row 0 + file -> lock + `flags/responder-disabled ignored`,
#       (c) no row + file -> no lock
#   S2  watchdog-responder responder-prefetch-off: PREFETCH=0 on (a) and (c),
#       PREFETCH=1 on (b) with the ignored line
#   S3  review-rescue review-rescue-disabled: stops at the switch on (a)/(c),
#       passes it on (b)
#   S4  review-tighten review-tighten-disabled: locks/review-tighten.lock
#   S5  rule-miner rule-miner-disabled: locks/rule-miner.lock
#   S6  rebase-train-ahead rebase-train-off, and automerge-disabled still
#       stops the script with a `switch.automerge-disabled=0` row (not row-driven)
#   X1  one responder run, no rows, no files: both switches read, one GET
#   N1  rule-miner: junk / other-box / prefix-collision / seed rows never turn
#       the switch ON; an outage never turns it OFF
#   W   no PUT/POST /api/settings in any case (this change writes no row)
# Run from anywhere: tests/switch-convert-scripts-b.bh-2428-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/switch-fixture.sh" || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null 2>&1 || { echo "switch-convert-scripts-b.bh-2428-test: SKIPPED — jq missing"; exit 0; }

# --- G1: the registry files -------------------------------------------------
NAMES="responder-disabled responder-prefetch-off review-rescue-disabled review-tighten-disabled rule-miner-disabled rebase-train-off"
REG=("$DIR/catalog/switches.d/responder-disabled.json" "$DIR/catalog/switches.d/responder-prefetch-off.json"
     "$DIR/catalog/switches.d/review-rescue-disabled.json" "$DIR/catalog/switches.d/review-tighten-disabled.json"
     "$DIR/catalog/switches.d/rule-miner-disabled.json" "$DIR/catalog/switches.d/rebase-train-off.json")
SCRIPTS=("$DIR/bin/watchdog-responder.sh" "$DIR/bin/review-rescue.sh" "$DIR/bin/review-tighten.sh"
         "$DIR/bin/rule-miner.sh" "$DIR/bin/rebase-train-ahead.sh")
for s in "${SCRIPTS[@]}"; do [ -x "$s" ] && ok || bad "G1 $s missing or not executable"; done
for f in "${REG[@]}"; do
  n=$(basename "$f" .json)
  if ! jq -e --arg n "$n" '.name==$n and (.box_scoped|type=="boolean") and (.readers|type=="array" and length>0) and (.what|type=="string" and length>0)' "$f" >/dev/null 2>&1; then
    bad "G1 $n.json missing or not the pilot's shape"; continue
  fi
  ok
  while IFS= read -r r; do
    [ -f "$DIR/$r" ] && ok || bad "G1 $n.json reader $r does not exist"
  done < <(jq -r '.readers[]' "$f")
done
# Both readers this slice registered must be listed; a later slice that adds a
# reader of the same switch is not this suite's to refuse (the exact-array pin
# went red the day a neighbour's conversion touched the registry file).
eq "G1 review-rescue-disabled names review-rescue and the resolver's flag_on read" \
  "$(jq -r '[.readers[] | select(. == "bin/review-rescue.sh" or . == "bin/blocked-resolver.sh")] | sort | join(",")' \
      "$DIR/catalog/switches.d/review-rescue-disabled.json" 2>/dev/null)" \
  'bin/blocked-resolver.sh,bin/review-rescue.sh'
# G2 — the real bin/switch-migrate.sh walks the six (no row, no file: absent).
M="$T/m"; mkdir -p "$M/bin" "$M/flags" "$M/state" "$M/logs" "$M/catalog"
cp -r "$DIR/catalog/switches.d" "$M/catalog/"
cat > "$M/bin/jobs-client.sh" <<'SH'
_jobs_req() { case "$1 $2" in "GET /api/settings") JOBS_HTTP=200; printf '{"settings":[]}' ;; *) return 1 ;; esac; }
SH
env HARNESS="$M" JOBS_BOX=hub-1 "$DIR/bin/switch-migrate.sh" --dry-run > "$T/m.out" 2>&1
eq "G2 switch-migrate --dry-run rc" "$?" "0"
for n in $NAMES; do
  grep -qx "absent $n" "$T/m.out" && ok || bad "G2 switch-migrate does not walk $n: $(grep -F "$n" "$T/m.out")"
done

# --- the scratch harness -------------------------------------------------------
swf_setup "$T/h" || { echo "FAIL: swf_setup"; exit 1; }
H="$T/h"
# BH-5942: a responder run is one project's run (bin/lib/llm-lane-project.sh).
( cd "$DIR" && scratch_install_closure bin/lib/llm-lane-project.sh "$H" ) >/dev/null || { echo "FAIL: install llm-lane-project"; exit 1; }
mkdir -p "$T/stubs"
for n in gh curl claude; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/calls.log"\nexit 1\n' "$n" "$T/stubs" > "$T/stubs/$n"
  chmod +x "$T/stubs/$n"
done
export PATH="$T/stubs:$PATH"
# review-rescue refuses on an empty registry before its switch.
printf '#!/bin/bash\necho x-os\n' > "$H/bin/fleet-projects-or-alert.sh"; chmod +x "$H/bin/fleet-projects-or-alert.sh"
# rule-miner resolves its model route before its switch.
model_routes_fixture "$H" >/dev/null || { echo "FAIL: model_routes_fixture"; exit 1; }
export RESPONDER_DRY=1 RULE_MINER_DRY=1 REVIEW_TIGHTEN_DRY=1 HARNESS_TEST_SANDBOX=1
printf "PS4='+\${BASH_SOURCE[0]##*/}:\${LINENO}: '\n" > "$T/.ps4"

# fresh — a clean box: no flags, locks, state, logs or calls.
fresh() {
  local p
  for p in flags locks logs state/lane-gate state/settings-cache.json \
           state/responder state/watchdog-responder state/rule-mining state/rebase-train; do
    scratch_rm "$H/$p" || exit 1
  done
  mkdir -p "$H/flags" "$H/locks" "$H/logs"
  : > "$CALLS"; unset UNREACHABLE
}
# run <trace> <script> [args] — the real script, xtraced; the trace names each line
# `+<file>:<LINENO>:` so a sourced library's line numbers never count as the
# script's. BASH_ENV sets PS4 because bash ignores an inherited PS4 as root.
run() {
  local trace="$1" s="$2"; shift 2
  BASH_ENV="$T/.ps4" timeout 60 bash -x "$DIR/bin/$s" "$@" > "$T/run.out" 2> "$trace"
}
# swline <script> <name> — the last non-comment line of <script> reading <name>.
swline() {
  grep -n -- "$2" "$DIR/bin/$1" | grep -vE '^[0-9]+:[[:space:]]*#' | tail -1 | cut -d: -f1
}
# past <trace> <script> <line> — rc 0 when the trace ran a line of <script>
# after <line>, rc 1 when it did not.
past() {
  grep -oE "^\++$2:[0-9]+:" "$1" | sed -E 's/^\++[^:]+:([0-9]+):$/\1/' \
    | awk -v l="$3" '$1 + 0 > l + 0 { f = 1 } END { exit f ? 0 : 1 }'
}
ign() { local n; n=$(grep -cF "flags/$1 ignored" "$H/logs/lane-gate.log" 2>/dev/null) || n=0; echo "$n"; }
lock() { [ -e "$H/locks/$1" ] && echo held || echo absent; }
nowrite() {
  if grep -qE '^(PUT|POST) /api/settings' "$CALLS"; then bad "W $1 wrote a settings row: $(grep -E '^(PUT|POST)' "$CALLS")"; else ok; fi
}

# --- S1: responder-disabled -------------------------------------------------------
fresh; swf_rows switch.responder-disabled=1
run "$T/s1a" watchdog-responder.sh x-os; eq "S1a row 1 no file rc" "$?" "0"
eq "S1a row 1 no file: no watchdog-responder-x-os.lock" "$(lock watchdog-responder-x-os.lock)" "absent"
nowrite S1a
fresh; swf_rows switch.responder-disabled.hub-1=0; swf_flag responder-disabled
run "$T/s1b" watchdog-responder.sh x-os
eq "S1b box row 0 + file: watchdog-responder-x-os.lock taken" "$(lock watchdog-responder-x-os.lock)" "held"
eq "S1b the file is logged as ignored" "$(ign responder-disabled)" "1"
nowrite S1b
fresh; swf_rows; swf_flag responder-disabled
run "$T/s1c" watchdog-responder.sh x-os; eq "S1c no row + file rc" "$?" "0"
eq "S1c no row + file: no watchdog-responder-x-os.lock" "$(lock watchdog-responder-x-os.lock)" "absent"
nowrite S1c

# --- S2: responder-prefetch-off ------------------------------------------------------
PF=$(swline watchdog-responder.sh responder-prefetch-off)
pf_off() { grep -qE "^\++watchdog-responder.sh:$PF: PREFETCH=0$" "$1" && echo off || echo on; }
fresh; swf_rows switch.responder-prefetch-off=1
run "$T/s2a" watchdog-responder.sh x-os
eq "S2a row 1 no file: PREFETCH=0" "$(pf_off "$T/s2a")" "off"
past "$T/s2a" watchdog-responder.sh "$PF"; eq "S2a the run went on past the prefetch switch" "$?" "0"
nowrite S2a
fresh; swf_rows switch.responder-prefetch-off=0; swf_flag responder-prefetch-off
run "$T/s2b" watchdog-responder.sh x-os
eq "S2b row 0 + file: PREFETCH stays 1" "$(pf_off "$T/s2b")" "on"
past "$T/s2b" watchdog-responder.sh "$PF"; eq "S2b the run reached the prefetch switch" "$?" "0"
eq "S2b the file is logged as ignored" "$(ign responder-prefetch-off)" "1"
nowrite S2b
fresh; swf_rows; swf_flag responder-prefetch-off
run "$T/s2c" watchdog-responder.sh x-os
eq "S2c no row + file: PREFETCH=0" "$(pf_off "$T/s2c")" "off"
nowrite S2c

# --- X1: both responder switches, one GET ---------------------------------------
fresh; swf_rows
run "$T/x1" watchdog-responder.sh x-os
eq "X1 watchdog-responder-x-os.lock taken with no row and no file" "$(lock watchdog-responder-x-os.lock)" "held"
eq "X1 both switches read through lane_switch" \
  "$(grep -cE '^\++watchdog-responder.sh:[0-9]+: lane_switch responder-(disabled|prefetch-off)$' "$T/x1")" "2"
eq "X1 one GET /api/settings for the whole run" "$(swf_gets)" "1"
nowrite X1

# --- S3: review-rescue-disabled -----------------------------------------------------
RR=$(swline review-rescue.sh review-rescue-disabled)
fresh; swf_rows switch.review-rescue-disabled=1
run "$T/s3a" review-rescue.sh; eq "S3a row 1 no file rc" "$?" "0"
past "$T/s3a" review-rescue.sh "$RR"; eq "S3a row 1: stops at the switch" "$?" "1"
nowrite S3a
fresh; swf_rows switch.review-rescue-disabled=0; swf_flag review-rescue-disabled
run "$T/s3b" review-rescue.sh
past "$T/s3b" review-rescue.sh "$RR"; eq "S3b row 0 + file: runs past the switch" "$?" "0"
eq "S3b the file is logged as ignored" "$(ign review-rescue-disabled)" "1"
nowrite S3b
fresh; swf_rows; swf_flag review-rescue-disabled
run "$T/s3c" review-rescue.sh; eq "S3c no row + file rc" "$?" "0"
past "$T/s3c" review-rescue.sh "$RR"; eq "S3c no row + file: stops at the switch" "$?" "1"
nowrite S3c

# --- S4: review-tighten-disabled ---------------------------------------------------
fresh; swf_rows switch.review-tighten-disabled=1
run "$T/s4a" review-tighten.sh; eq "S4a row 1 no file rc" "$?" "0"
eq "S4a row 1 no file: no review-tighten.lock" "$(lock review-tighten.lock)" "absent"
nowrite S4a
fresh; swf_rows switch.review-tighten-disabled.hub-1=0; swf_flag review-tighten-disabled
run "$T/s4b" review-tighten.sh
eq "S4b box row 0 + file: review-tighten.lock taken" "$(lock review-tighten.lock)" "held"
eq "S4b the file is logged as ignored" "$(ign review-tighten-disabled)" "1"
nowrite S4b
fresh; swf_rows; swf_flag review-tighten-disabled
run "$T/s4c" review-tighten.sh; eq "S4c no row + file rc" "$?" "0"
eq "S4c no row + file: no review-tighten.lock" "$(lock review-tighten.lock)" "absent"
nowrite S4c

# --- S5: rule-miner-disabled -------------------------------------------------------
fresh; swf_rows switch.rule-miner-disabled=1
run "$T/s5a" rule-miner.sh; eq "S5a row 1 no file rc" "$?" "0"
eq "S5a row 1 no file: no rule-miner.lock" "$(lock rule-miner.lock)" "absent"
nowrite S5a
fresh; swf_rows switch.rule-miner-disabled=0; swf_flag rule-miner-disabled
run "$T/s5b" rule-miner.sh
eq "S5b row 0 + file: rule-miner.lock taken" "$(lock rule-miner.lock)" "held"
eq "S5b the file is logged as ignored" "$(ign rule-miner-disabled)" "1"
nowrite S5b
fresh; swf_rows; swf_flag rule-miner-disabled
run "$T/s5c" rule-miner.sh; eq "S5c no row + file rc" "$?" "0"
eq "S5c no row + file: no rule-miner.lock" "$(lock rule-miner.lock)" "absent"
nowrite S5c

# --- S6: rebase-train-off, and automerge-disabled left alone -----------------------
RT=$(swline rebase-train-ahead.sh rebase-train-off)
AM=$(swline rebase-train-ahead.sh automerge-disabled)
fresh; swf_rows switch.rebase-train-off=1
run "$T/s6a" rebase-train-ahead.sh; eq "S6a row 1 no file rc" "$?" "0"
past "$T/s6a" rebase-train-ahead.sh "$RT"; eq "S6a row 1: stops at the switch" "$?" "1"
nowrite S6a
fresh; swf_rows switch.rebase-train-off=0; swf_flag rebase-train-off
run "$T/s6b" rebase-train-ahead.sh
past "$T/s6b" rebase-train-ahead.sh "$AM"; eq "S6b row 0 + file: runs past the automerge check" "$?" "0"
eq "S6b the file is logged as ignored" "$(ign rebase-train-off)" "1"
nowrite S6b
fresh; swf_rows; swf_flag rebase-train-off
run "$T/s6c" rebase-train-ahead.sh; eq "S6c no row + file rc" "$?" "0"
past "$T/s6c" rebase-train-ahead.sh "$RT"; eq "S6c no row + file: stops at the switch" "$?" "1"
nowrite S6c
fresh; swf_rows switch.automerge-disabled=0; swf_flag automerge-disabled
run "$T/s6d" rebase-train-ahead.sh; eq "S6d automerge-disabled file rc" "$?" "0"
past "$T/s6d" rebase-train-ahead.sh "$RT"; eq "S6d passes the rebase-train switch" "$?" "0"
past "$T/s6d" rebase-train-ahead.sh "$AM"; eq "S6d a switch.automerge-disabled=0 row does not beat its file" "$?" "1"
nowrite S6d

# --- N1: rule-miner adversarial rows ------------------------------------------------
for row in "switch.rule-miner-disabled=2" "switch.rule-miner-disabled=yes please" \
           "switch.rule-miner-disabled=" "switch.rule-miner-disabled=null" \
           "switch.rule-miner-disabled.otherbox=1" "switch.rule-miner-disabled-x=1" \
           "seed:switch.rule-miner-disabled=maybe"; do
  fresh; swf_rows "$row"
  run "$T/n1" rule-miner.sh
  eq "N1 '$row' with no file is NOT on" "$(lock rule-miner.lock)" "held"
  nowrite "N1 $row"
done
# Outage with a warm cache of row 1: the cache answers, NOT off.
fresh; swf_rows switch.rule-miner-disabled=1
run "$T/n1w" rule-miner.sh
UNREACHABLE=1 LANE_GATE_NOW=$((LANE_GATE_NOW + 3600)) run "$T/n1o" rule-miner.sh
eq "N1 outage, cached row 1: still off" "$(lock rule-miner.lock)" "absent"
# Outage, no cache, file present: the file answers, NOT off.
fresh; swf_rows; swf_flag rule-miner-disabled
UNREACHABLE=1 run "$T/n1f" rule-miner.sh
eq "N1 outage, no cache, file present: still off" "$(lock rule-miner.lock)" "absent"
nowrite N1-outage

echo "switch-convert-scripts-b.bh-2428: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
