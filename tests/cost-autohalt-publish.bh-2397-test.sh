#!/bin/bash
# tests/cost-autohalt-publish.bh-2397-test.sh — the hub publishes what
# pipeline-health's cost autohalt ACTUALLY does, as the settings row
# cost.autohalt.effective = "on|off <flag-file|settings|env|default>" (BH-2397
# item 3). The console's COST BREAKER card reads that row instead of a code
# copy of the registry default, which could not see an env override or the
# hub's flags/cost-autohalt-off.
#
# The `cost budget` block of bin/pipeline-health.sh is extracted VERBATIM by
# its markers (the tests/cost-containment.k1-test.sh pattern) and driven in a
# scratch tree, with setting_set / is_hub_box / local_box_name stubbed and the
# REAL bin/lib/lane-gate.sh for the settings-row cases.
#
#   a  nothing set                                  -> on default
#   b  flags/cost-autohalt-off                      -> off flag-file
#   c  env COST_AUTOHALT=0                          -> off env
#   d  the real row lane.pipeline-health.cost_autohalt=0 -> off settings
#   e  row "abc" with env 0 -> on default (cb_knob never reads the env when
#      the row is non-empty, and a non-number is the default)
#   f  in every case on/off agrees with cb_autohalt_off's own rc
#   g  a box that is not the hub writes nothing
#   h  setting_set failing still pauses an over-budget project, logs one line,
#      and leaves the block's rc as it was
#   s  flags/cost-autohalt-off keeps main's meaning in all three states (lead
#      fix round): file + no row -> off flag-file; no file + no row -> on at the
#      registry default; a row present -> cb_autohalt_off's order, file first
#      (row 1 + file is still off flag-file), then the row. The flag-file
#      source now comes from cb_autohalt_off's output, not a second bare read
#      (tests/switch-ratchet.bh-2320-test.sh)
#
# Run from anywhere: tests/cost-autohalt-publish.bh-2397-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/rendered.sh
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v awk >/dev/null || { echo "jq/awk missing — skipping"; exit 0; }
NOW=$(date +%s)
REG=$(rendered_registry)
PH="$DIR/bin/pipeline-health.sh"

mkdir -p "$T/lib" "$T/bin" "$T/logs" "$T/state/cost" "$T/flags" "$T/stub"
awk '/^# >>> cost budget/{f=1;next} /^# <<< cost budget/{exit} f' "$PH" > "$T/blk.sh"
[ -s "$T/blk.sh" ] && ok || bad "could not extract the cost budget block from $PH — markers missing?"
cp "$DIR/bin/lib/cost-budget.sh" "$T/lib/"
printf '#!/bin/bash\nexit 1\n' > "$T/bin/fleet-conf.sh"; chmod +x "$T/bin/fleet-conf.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/stub/ssh"; chmod +x "$T/stub/ssh"
CONF="$T/caps.conf"
printf 'default 80 5\nbudget busy 40 10\nceiling 100000\n' > "$CONF"
# busy: $80/PR on 90 PRs against a $40 budget — 2x, the autohalt line.
cat > "$T/state/cost/summary.json" <<'JSON'
{ "projects": {
  "busy": {"delivery_cost_24h": 7200, "merged_prs_24h": 90, "cost_7d": 30000, "product_7d": 0,
           "merged_prs_7d": 400, "merged_prs_status": "ok", "stages_24h": {"execute": 7200}}
} }
JSON
echo "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note" > "$T/logs/cost.csv"
echo '{"per_token":{}}' > "$T/prices.json"

settings() { # the settings cache the REAL lane_knob reads
  jq -n --argjson v "$1" --argjson t "$NOW" '{fetched_at: $t, values: $v}' > "$T/state/settings-cache.json"
}

# drive <hub 0|1> <setting_set rc> [VAR=value ...]
#   -> $T/set.txt (setting_set's args, tab-separated), $T/out.txt (off_rc=, blk_rc=)
drive() {
  local hub="$1" setrc="$2"; shift 2
  rm -f "$T/set.txt" "$T/flags/spend-hold-busy" "$T/logs/pipeline-health.log"; rm -rf "$T/state/costhalt"
  echo 0 > "$T/state/costbreaker.stamp"
  ( export T NOW DIR REG HUB="$hub" SETRC="$setrc"
    export HARNESS="$T" COST_CAPS_CONF="$CONF" MODEL_PRICES="$T/prices.json" PATH="$T/stub:$PATH"
    unset COST_AUTOHALT
    [ $# -gt 0 ] && export "${@?}"
    bash -c '
      set -uo pipefail
      H="$T"
      alert() { :; }
      page_critical() { :; }
      setting_set() { printf "%s\t%s\t%s\n" "$1" "$2" "${3:-}" >> "$T/set.txt"; return "$SETRC"; }
      is_hub_box() { [ "$HUB" = 1 ] && [ "$1" = box-hub ]; }
      local_box_name() { printf box-hub; }
      if [ -n "${REAL_LANE_GATE:-}" ]; then
        export LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW" JOBS_URL= HARNESS_JOBS_URL=
        . "$DIR/bin/lib/lane-gate.sh" || exit 1
      fi
      # The pause is a flag ROW (BH-2529: with no client the halt fails
      # closed and writes nothing). This stands in for the jobs client the
      # way flag_set behaves: file first, then an answered PUT.
      flag_set() { [ "$2" = on ] && : > "$T/flags/$1"; return 0; }
      . "$0"; rc=$?
      if cb_autohalt_off >/dev/null; then echo off_rc=0; else echo off_rc=1; fi
      echo "blk_rc=$rc"' "$T/blk.sh" >"$T/out.txt" 2>"$T/err.txt" )
}
published() { awk -F'\t' '$1=="cost.autohalt.effective"{print $2}' "$T/set.txt" 2>/dev/null; }
off_rc() { sed -n 's/^off_rc=//p' "$T/out.txt"; }
blk_rc() { sed -n 's/^blk_rc=//p' "$T/out.txt"; }

# expect <case> <want> — the published value, exactly one write, and (f) its
# on/off agreeing with cb_autohalt_off.
expect() {
  local c="$1" want="$2" got n
  got=$(published); n=$(grep -c . "$T/set.txt" 2>/dev/null || true)
  [ "$got" = "$want" ] && [ "${n:-0}" = 1 ] && ok \
    || bad "$c: want one write of '$want', got '${got}' (${n:-0} writes) $(cat "$T/err.txt")"
  case "$want" in
    off\ *) [ "$(off_rc)" = 0 ] && ok || bad "f/$c: published off but cb_autohalt_off rc=$(off_rc)" ;;
    on\ *)  [ "$(off_rc)" = 1 ] && ok || bad "f/$c: published on but cb_autohalt_off rc=$(off_rc)" ;;
  esac
}

rm -f "$T/state/settings-cache.json" "$T/flags/cost-autohalt-off"
drive 1 0;                                                     expect a "on default"
grep -q $'\tBH-2397' "$T/set.txt" && ok || bad "a: the write carries a note naming BH-2397: $(cat "$T/set.txt")"
[ -e "$T/flags/spend-hold-busy" ] && ok || bad "a: control — autohalt on, busy at 2x must be paused"
touch "$T/flags/cost-autohalt-off"; drive 1 0;                 expect b "off flag-file"
[ ! -e "$T/flags/spend-hold-busy" ] && ok || bad "b: control — the flag file stops the pause"
touch "$T/flags/cost-autohalt-off"; drive 1 0 COST_AUTOHALT=1; expect b2 "off flag-file"
rm -f "$T/flags/cost-autohalt-off"
drive 1 0 COST_AUTOHALT=0;                                     expect c "off env"
drive 1 0 COST_AUTOHALT=1;                                     expect c2 "on env"
drive 1 0 COST_AUTOHALT=yes;                                   expect c3 "on default"
settings '{"lane.pipeline-health.cost_autohalt":"0"}'
drive 1 0 REAL_LANE_GATE=1;                                    expect d "off settings"
drive 1 0 REAL_LANE_GATE=1 COST_AUTOHALT=1;                    expect d2 "off settings"
settings '{"lane.pipeline-health.cost_autohalt":"abc"}'
drive 1 0 REAL_LANE_GATE=1 COST_AUTOHALT=0;                    expect e "on default"
settings '{}'
drive 1 0 REAL_LANE_GATE=1;                                    expect e2 "on default"
drive 1 0 REAL_LANE_GATE=1 COST_AUTOHALT=0;                    expect e3 "off env"
rm -f "$T/state/settings-cache.json"

# s: the three states of flags/cost-autohalt-off, through cb_autohalt_effective
touch "$T/flags/cost-autohalt-off"; drive 1 0 REAL_LANE_GATE=1;  expect s1 "off flag-file"
rm -f "$T/flags/cost-autohalt-off"; drive 1 0 REAL_LANE_GATE=1;  expect s2 "on default"
settings '{"lane.pipeline-health.cost_autohalt":"1"}'
touch "$T/flags/cost-autohalt-off"; drive 1 0 REAL_LANE_GATE=1;  expect s3a "off flag-file"
settings '{"lane.pipeline-health.cost_autohalt":"0"}'
touch "$T/flags/cost-autohalt-off"; drive 1 0 REAL_LANE_GATE=1;  expect s3b "off flag-file"
rm -f "$T/flags/cost-autohalt-off"; drive 1 0 REAL_LANE_GATE=1;  expect s3c "off settings"
settings '{"lane.pipeline-health.cost_autohalt":"1"}'
drive 1 0 REAL_LANE_GATE=1;                                      expect s3d "on settings"
rm -f "$T/state/settings-cache.json"

# g: not the hub — nothing written, the halt logic untouched
drive 0 0
[ ! -s "$T/set.txt" ] && ok || bad "g: a non-hub box must not publish: $(cat "$T/set.txt")"
[ -e "$T/flags/spend-hold-busy" ] && ok || bad "g: control — the non-hub run still pauses busy"

# h: the write fails — the pause still lands, one log line, rc unchanged
drive 1 0; RC_OK=$(blk_rc)
drive 1 1
[ -e "$T/flags/spend-hold-busy" ] && ok || bad "h: a failed publish must not stop the pause ($(cat "$T/err.txt"))"
[ "$(blk_rc)" = "$RC_OK" ] && ok || bad "h: the block's rc moved on a failed publish: $RC_OK -> $(blk_rc)"
[ "$(grep -c 'cost.autohalt.effective' "$T/logs/pipeline-health.log" 2>/dev/null)" = 1 ] && ok \
  || bad "h: a failed publish writes exactly one pipeline-health.log line: $(cat "$T/logs/pipeline-health.log" 2>/dev/null)"

echo "cost-autohalt-publish: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
