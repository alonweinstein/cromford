#!/bin/bash
# tests/switch-convert-cost.bh-2407-test.sh — BH-2433 (BH-2407 child 3): the six
# cost-side kill switches are read through bin/lib/lane-switch.sh's
# `lane_switch <name> file`, so a settings row settles them before the file.
#
# For each switch, driven through the REAL function or script:
#   (a) row switch.<name>=1, no file   -> the switch is on (the thing stops)
#   (b) row switch.<name>=0, file there -> the thing runs, and logs/lane-gate.log
#       carries exactly one `switch <name>: row says 0` line
#   (c) no row, file there              -> the switch is on (legacy, as before)
#
#   C1 cost-row-at-source-off  bin/lib/cost-row.sh      cost_row_at_source_enabled
#   C2 cost-rows-from-db-off   bin/lib/cost-rows-read.sh cost_rows_db_enabled
#   C3 cost-reconcile-off      bin/cost-reconcile.sh
#   C4 cost-rows-push-off      bin/cost-rows-push.sh --box (stdout names the source)
#   C5 cost-rows-push-off      fly/builder-runner.sh cost_rows_on + its log line
#   C6 extra-usage-track-off   bin/extra-usage-track.sh
#   C7 cost-autohalt-off       bin/pipeline-health.sh's cost budget block:
#      cb_autohalt_off's reason names the row or the file, the switch is read
#      BEFORE COST_AUTOHALT, and cb_autohalt_effective publishes `off settings`
#   N  a malformed row is no row; another box's row does not reach this box; a
#      tree with no lane-switch.sh takes the shim, which is exactly the file;
#      LANE_GATE_DISABLE=1 goes to the file
#   B7 sourcing cost-row.sh / cost-rows-read.sh loads no _lg_* until the read
#   S0 no bare `[ -f flags/<name> ]` read of the six names left in bin/ fly/
# Run from anywhere: tests/switch-convert-cost.bh-2407-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-3223: this suite asserts the POST to its own stub; the sandbox flag would refuse it.
unset HARNESS_TEST_SANDBOX
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/rendered.sh
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/flags" "$H/state/cost" "$H/logs" "$H/catalog" "$H/env" "$T/stub"
for f in lane-gate.sh lane-switch.sh env-path.sh cost-row.sh cost-rows-read.sh cost-budget.sh; do
  cp "$DIR/bin/lib/$f" "$H/bin/lib/"
done
for f in cost-reconcile.sh cost-rows-push.sh extra-usage-track.sh; do
  cp "$DIR/bin/$f" "$H/bin/" && chmod +x "$H/bin/$f"
done
cp "$(rendered_registry)" "$H/catalog/lanes.json"
: > "$H/env/global.env"

# The stub worker at the path lane-gate.sh sources: /api/settings answers from
# $ROWS_FILE, everything else fails (every lane here fails open on that).
cat > "$H/bin/jobs-client.sh" <<'SH'
_jobs_req() {
  echo "$1 $2" >> "$CALLS"
  case "$2" in
    /api/settings) printf '{"settings":%s}' "$(cat "$ROWS_FILE" 2>/dev/null || echo '[]')" ;;
    *) return 1 ;;
  esac
}
SH
printf '#!/bin/bash\nexit 1\n' > "$H/bin/fleet-conf.sh"; chmod +x "$H/bin/fleet-conf.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/stub/ssh"; chmod +x "$T/stub/ssh"

# rows k=v [k=v...] — the settings table.
rows() {
  local out='[]' kv
  for kv in "$@"; do
    out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"api"}]')
  done
  printf '%s' "$out" > "$T/rows.json"
}
reset() {
  local p
  for p in "$H/state/lane-gate" "$H/logs"/* "$H/state/settings-cache.json" "$H/flags"/* "$T/rows.json"; do
    scratch_rm "$p"
  done
  rm -f "$H/state/costbreaker.stamp" "$H/state"/extra-usage* "$H/state"/cost-rows-push*
  : > "$T/calls"
}
flag() { : > "$H/flags/$1"; }
# row0log <name> — lines in logs/lane-gate.log saying a 0 row beat the file.
row0log() { grep -c "switch $1: row says 0" "$H/logs/lane-gate.log" 2>/dev/null || echo 0; }

# run <cmd...> — a cold child with the scratch harness and the stub worker.
run() {
  env HARNESS="$H" CALLS="$T/calls" ROWS_FILE="$T/rows.json" JOBS_BOX="${BOX:-hub-1}" \
      CLAUDE_CONFIG_DIR="$T/noclaude" PATH="$T/stub:$PATH" "$@"
}

# ── C1 / C2: the libs ──────────────────────────────────────────────────────
# lib_rc <lib> <fn> — the function's rc, read in a fresh shell that sourced
# only that lib.
lib_rc() {
  run bash -c '. "$HARNESS/bin/lib/$1" || exit 9; "$2"; echo "rc=$?"' _ "$1" "$2" 2>/dev/null
}
for spec in "C1 cost-row.sh cost_row_at_source_enabled cost-row-at-source-off" \
            "C2 cost-rows-read.sh cost_rows_db_enabled cost-rows-from-db-off"; do
  set -- $spec; c=$1 lib=$2 fn=$3 name=$4
  reset; rows "switch.$name=1"
  eq "${c}a row 1, no file -> switch on ($fn off)" "$(lib_rc "$lib" "$fn")" "rc=1"
  reset; rows "switch.$name=0"; flag "$name"
  eq "${c}b row 0 + file -> runs" "$(lib_rc "$lib" "$fn")" "rc=0"
  eq "${c}b one lane-gate.log line" "$(row0log "$name")" "1"
  reset; flag "$name"
  eq "${c}c no row + file -> switch on (legacy)" "$(lib_rc "$lib" "$fn")" "rc=1"
  reset
  eq "${c} control: no row, no file -> runs" "$(lib_rc "$lib" "$fn")" "rc=0"
  reset; BOX=hub-1; rows "switch.$name.hub-1=1" "switch.$name=0"
  eq "${c} box row beats the fleet row" "$(lib_rc "$lib" "$fn")" "rc=1"
done

# B7: sourcing either lib defines no _lg_* until its switch is read.
for spec in "B7a cost-row.sh cost_row_at_source_enabled" "B7b cost-rows-read.sh cost_rows_db_enabled"; do
  set -- $spec
  reset
  got=$(run bash -c '. "$HARNESS/bin/lib/$1" || exit 9
    a=$(declare -F | grep -c " _lg_"); "$2" >/dev/null; b=$(declare -F | grep -c " _lg_")
    echo "before=$a after=$([ "$b" -gt 0 ] && echo some || echo none)"' _ "$2" "$3" 2>/dev/null)
  eq "$1 lazy load of lane-switch.sh" "$got" "before=0 after=some"
done

# ── C3: bin/cost-reconcile.sh ─────────────────────────────────────────────
# Past the switch, with no account map, it writes "no account map" to its log.
reconciled() { rm -f "$H/logs/cost-reconcile.log"; run bash "$H/bin/cost-reconcile.sh" --window 24h >/dev/null 2>&1
               [ -s "$H/logs/cost-reconcile.log" ] && echo ran || echo stopped; }
reset; rows switch.cost-reconcile-off=1
eq "C3a row 1, no file -> stopped" "$(reconciled)" stopped
reset; rows switch.cost-reconcile-off=0; flag cost-reconcile-off
eq "C3b row 0 + file -> runs" "$(reconciled)" ran
eq "C3b one lane-gate.log line" "$(row0log cost-reconcile-off)" 1
reset; flag cost-reconcile-off
eq "C3c no row + file -> stopped (legacy)" "$(reconciled)" stopped
reset
eq "C3 control: nothing set -> runs" "$(reconciled)" ran
reset; rows switch.cost-reconcile-off.other-box=1
eq "N another box's row does not stop this box" "$(reconciled)" ran

# ── C4: bin/cost-rows-push.sh --box ───────────────────────────────────────
push_out() { printf 'ts,host\nx,y\n' > "$H/logs/cost.csv"
             run "$@" bash "$H/bin/cost-rows-push.sh" --box hub-1 2>/dev/null | head -1; }
OFFMSG="pushed 0 (0 dup) — cost-rows-push is off"
reset; rows switch.cost-rows-push-off=1
eq "C4a row 1, no file -> off, names the fleet row" "$(push_out)" "$OFFMSG (settings switch.cost-rows-push-off)"
reset; rows switch.cost-rows-push-off.hub-1=1
eq "C4a' box row -> off, names the box row" "$(push_out)" "$OFFMSG (settings switch.cost-rows-push-off.hub-1)"
reset; rows switch.cost-rows-push-off=0; flag cost-rows-push-off
got=$(push_out)
case "$got" in *"is off"*) bad "C4b row 0 + file must push, got '$got'" ;; ''|*) ok ;; esac
[ -n "$got" ] && ok || bad "C4b row 0 + file printed nothing"
eq "C4b one lane-gate.log line" "$(row0log cost-rows-push-off)" 1
reset; flag cost-rows-push-off
eq "C4c no row + file -> off, names the file" "$(push_out)" "$OFFMSG (flags/cost-rows-push-off)"
reset
eq "C4 COST_ROWS_PUSH=0 names the env" "$(push_out COST_ROWS_PUSH=0)" "$OFFMSG (COST_ROWS_PUSH=0)"

# ── C5: fly/builder-runner.sh's cost block ────────────────────────────────
sed -n '/^# --- cost rows: the machine pushes its OWN bill while it runs/,/^load_env() {/p' \
  "$DIR/fly/builder-runner.sh" | sed '$d' > "$T/costblock.sh"
grep -q '^cost_rows_on()' "$T/costblock.sh" && grep -q '^start_cost_rows_loop()' "$T/costblock.sh" \
  && ok || bad "C5 could not extract the cost-rows block from fly/builder-runner.sh"
# runner_says — cost_rows_on's rc and, when it is off, start_cost_rows_loop's log.
runner_says() {
  run "$@" bash -c 'HARNESS="$HARNESS"; PROJECT=project-5
    log() { echo "LOG $*"; }; model_prices_pull() { :; }
    . "$1"
    cost_rows_on; echo "rc=$?"
    cost_rows_on || start_cost_rows_loop' _ "$T/costblock.sh" 2>/dev/null | tr '\n' '|'
}
reset; rows switch.cost-rows-push-off=1
eq "C5a row 1, no file -> off, log names the row" "$(runner_says)" \
  "rc=1|LOG cost rows: push OFF (settings switch.cost-rows-push-off)|"
reset; rows switch.cost-rows-push-off.hub-1=1
eq "C5a' box row -> log names the box row" "$(runner_says)" \
  "rc=1|LOG cost rows: push OFF (settings switch.cost-rows-push-off.hub-1)|"
reset; rows switch.cost-rows-push-off=0; flag cost-rows-push-off
eq "C5b row 0 + file -> on" "$(runner_says)" "rc=0|"
eq "C5b one lane-gate.log line" "$(row0log cost-rows-push-off)" 1
reset; flag cost-rows-push-off
eq "C5c no row + file -> off, log names the file" "$(runner_says)" \
  "rc=1|LOG cost rows: push OFF (flags/cost-rows-push-off)|"
reset
eq "C5 COST_ROWS_PUSH=0 -> log names the env" "$(runner_says COST_ROWS_PUSH=0)" \
  "rc=1|LOG cost rows: push OFF (COST_ROWS_PUSH=0)|"

# ── C6: bin/extra-usage-track.sh ──────────────────────────────────────────
# Past the switch it polls and writes logs/extra-usage.csv (no-login here).
polled() { rm -f "$H/logs/extra-usage.csv"; run bash "$H/bin/extra-usage-track.sh" hub >/dev/null 2>&1
           [ -s "$H/logs/extra-usage.csv" ] && echo polled || echo stopped; }
reset; rows switch.extra-usage-track-off=1
eq "C6a row 1, no file -> stopped" "$(polled)" stopped
reset; rows switch.extra-usage-track-off=0; flag extra-usage-track-off
eq "C6b row 0 + file -> polls" "$(polled)" polled
eq "C6b one lane-gate.log line" "$(row0log extra-usage-track-off)" 1
reset; flag extra-usage-track-off
eq "C6c no row + file -> stopped (legacy)" "$(polled)" stopped
reset
eq "C6 control: nothing set -> polls" "$(polled)" polled

# ── C7: bin/pipeline-health.sh's cost budget block ────────────────────────
# Extracted by its markers (the cost-autohalt-publish.bh-2397 pattern) into
# $H/bin, so its sibling-first lib lookups find the scratch libs.
awk '/^# >>> cost budget/{f=1;next} /^# <<< cost budget/{exit} f' "$DIR/bin/pipeline-health.sh" > "$H/bin/blk.sh"
[ -s "$H/bin/blk.sh" ] && ok || bad "C7 could not extract the cost budget block"
CONF="$T/caps.conf"
printf 'default 80 5\nbudget busy 40 10\nceiling 100000\n' > "$CONF"
echo '{"per_token":{}}' > "$T/prices.json"
halt() { # halt [VAR=value ...] -> "off_rc=<n> why=<reason> eff=<effective> paused=<y|n>"
  mkdir -p "$H/state/cost"
  cat > "$H/state/cost/summary.json" <<'JSON'
{ "projects": {
  "busy": {"delivery_cost_24h": 7200, "merged_prs_24h": 90, "cost_7d": 30000, "product_7d": 0,
           "merged_prs_7d": 400, "merged_prs_status": "ok", "stages_24h": {"execute": 7200}}
} }
JSON
  echo "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note" > "$H/logs/cost.csv"
  echo 0 > "$H/state/costbreaker.stamp"; rm -f "$H/flags/spend-hold-busy"; scratch_rm "$H/state/costhalt"
  run env -u COST_AUTOHALT NOW="$(date +%s)" COST_CAPS_CONF="$CONF" MODEL_PRICES="$T/prices.json" "$@" bash -c '
    set -uo pipefail
    H="$HARNESS"
    alert() { :; }; page_critical() { :; }
    setting_set() { :; }; is_hub_box() { return 1; }; local_box_name() { printf hub-1; }
    flag_set() { [ "$2" = on ] && : > "$H/flags/$1"; return 0; }
    . "$0" >/dev/null 2>&1
    why=$(cb_autohalt_off); rc=$?
    printf "off_rc=%s why=%s eff=%s paused=%s" "$rc" "$why" "$(cb_autohalt_effective)" \
      "$([ -e "$H/flags/spend-hold-busy" ] && echo y || echo n)"' "$H/bin/blk.sh" 2>/dev/null
}
reset; rows switch.cost-autohalt-off=1
eq "C7a row 1, no file -> autohalt off, reason names the row" "$(halt)" \
  "off_rc=0 why=settings switch.cost-autohalt-off eff=off settings paused=n"
reset; rows switch.cost-autohalt-off.hub-1=1
eq "C7a' box row -> reason names the box row" "$(halt)" \
  "off_rc=0 why=settings switch.cost-autohalt-off.hub-1 eff=off settings paused=n"
reset; rows switch.cost-autohalt-off=1
eq "C7a'' row 1 beats COST_AUTOHALT=1 (checked first)" "$(halt COST_AUTOHALT=1)" \
  "off_rc=0 why=settings switch.cost-autohalt-off eff=off settings paused=n"
reset; rows switch.cost-autohalt-off=0; flag cost-autohalt-off
eq "C7b row 0 + file + COST_AUTOHALT=1 -> autohalt on, it pauses" "$(halt COST_AUTOHALT=1)" \
  "off_rc=1 why= eff=on env paused=y"
eq "C7b one lane-gate.log line" "$(row0log cost-autohalt-off)" 1
reset; rows switch.cost-autohalt-off=0; flag cost-autohalt-off
eq "C7b' row 0 + file + COST_AUTOHALT=0 -> COST_AUTOHALT decides" "$(halt COST_AUTOHALT=0)" \
  "off_rc=0 why=COST_AUTOHALT=0 eff=off env paused=n"
reset; flag cost-autohalt-off
eq "C7c no row + file -> off, reason names the file" "$(halt)" \
  "off_rc=0 why=flags/cost-autohalt-off eff=off flag-file paused=n"
reset
eq "C7 control: nothing set -> on default, pauses" "$(halt)" \
  "off_rc=1 why= eff=on default paused=y"

# ── N: adversarial negatives ──────────────────────────────────────────────
reset; rows switch.cost-row-at-source-off=maybe; flag cost-row-at-source-off
eq "N malformed row + file -> the file decides (on)" "$(lib_rc cost-row.sh cost_row_at_source_enabled)" "rc=1"
grep -q "switch cost-row-at-source-off: row switch.cost-row-at-source-off='maybe'" "$H/logs/lane-gate.log" 2>/dev/null \
  && ok || bad "N a malformed row writes a lane-gate.log line"
reset; rows switch.cost-row-at-source-off=maybe
eq "N malformed row, no file -> runs" "$(lib_rc cost-row.sh cost_row_at_source_enabled)" "rc=0"
reset; rows switch.cost-rows-from-db-off=0; flag cost-rows-from-db-off
eq "N LANE_GATE_DISABLE=1 + row 0 + file -> the file (on)" \
  "$(run env LANE_GATE_DISABLE=1 bash -c '. "$HARNESS/bin/lib/cost-rows-read.sh"; cost_rows_db_enabled; echo "rc=$?"' 2>/dev/null)" "rc=1"

# No lane-switch.sh anywhere: the shim answers exactly the file, never rc 127.
B="$T/bare"; mkdir -p "$B/bin/lib" "$B/flags" "$B/logs" "$B/env"
cp "$DIR/bin/lib/cost-row.sh" "$DIR/bin/lib/cost-rows-read.sh" "$DIR/bin/lib/env-path.sh" "$B/bin/lib/"
cp "$DIR/bin/cost-reconcile.sh" "$B/bin/"; : > "$B/env/global.env"
bare_lib() { env HARNESS="$B" bash -c '. "$HARNESS/bin/lib/$1"; "$2"; echo "rc=$?"' _ "$1" "$2" 2>/dev/null; }
rm -f "$B/flags"/*
eq "N no lib, no file -> cost_row_at_source_enabled runs" "$(bare_lib cost-row.sh cost_row_at_source_enabled)" "rc=0"
eq "N no lib, no file -> cost_rows_db_enabled runs" "$(bare_lib cost-rows-read.sh cost_rows_db_enabled)" "rc=0"
: > "$B/flags/cost-row-at-source-off"; : > "$B/flags/cost-rows-from-db-off"
eq "N no lib + file -> cost_row_at_source_enabled off" "$(bare_lib cost-row.sh cost_row_at_source_enabled)" "rc=1"
eq "N no lib + file -> cost_rows_db_enabled off" "$(bare_lib cost-rows-read.sh cost_rows_db_enabled)" "rc=1"
: > "$B/flags/cost-reconcile-off"
env HARNESS="$B" bash "$B/bin/cost-reconcile.sh" --window 24h >/dev/null 2>&1
[ ! -e "$B/logs/cost-reconcile.log" ] && ok || bad "N no lib + file -> cost-reconcile must stop"
rm -f "$B/flags/cost-reconcile-off"
env HARNESS="$B" bash "$B/bin/cost-reconcile.sh" --window 24h >/dev/null 2>&1
[ -s "$B/logs/cost-reconcile.log" ] && ok || bad "N no lib, no file -> cost-reconcile must run"

# ── S0: no bare read of the six names left in bin/ or fly/ ────────────────
BARE_RE='\[ -[ef] [^]]*flags/[a-z0-9-]+-(off|disabled)'
NAMES='flags/(cost-row-at-source-off|cost-rows-from-db-off|cost-reconcile-off|cost-rows-push-off|extra-usage-track-off|cost-autohalt-off)'
if [ -d "$DIR/bin" ] && [ -d "$DIR/fly" ]; then
  left=$(grep -rnoE "$BARE_RE" "$DIR/bin" "$DIR/fly" | grep -E "$NAMES")
  [ -z "$left" ] && ok || bad "S0 bare switch reads left:
$left"
else
  bad "S0 bin/ or fly/ missing under $DIR"
fi

echo "switch-convert-cost.bh-2407-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
