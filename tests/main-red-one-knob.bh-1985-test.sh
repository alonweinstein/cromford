#!/bin/bash
# tests/main-red-one-knob.bh-1985-test.sh — the main-red label is set in ONE
# place (BH-1985 item 1, a BH-1770 follow-up).
#
# THE DEFECT. BH-1770 made lib.main-red-label.mc_main_red_label the fleet-wide
# row every reader resolves first, but merge-queue and review-prs still
# registered MC_MAIN_RED_LABEL as a settable lane knob. A row on either lane
# (`harness-ctl set merge-queue MC_MAIN_RED_LABEL x`, or the console) was
# exported into that lane alone by lane_env_apply, and main-red-gate.sh took
# the env value — so one lane exempted a different PR from the freeze than
# every other lane did. The label split, which is what BH-1770 existed to end.
#
# THE CONTRACT pinned here:
#   M1 both lane-level MC_MAIN_RED_LABEL knobs are `settable: false` in the
#      rendered registry (still registered, so section 7 of
#      tests/lanes-registry-test.sh sees the lane's ${X:-} read);
#   M2 the real harness-ctl refuses `set <lane> MC_MAIN_RED_LABEL …` on both
#      lanes and writes nothing;
#   M3 lane-gate's lane_knob_settable answers "no" for both;
#   M4 a lane row that already exists does not reach the label: lane_env_apply
#      then main-red-gate.sh answers the fleet value, not the lane's;
#   M5 the lib row stays settable — it is the one place the label is set.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/main-red-one-knob.bh-1985-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
REG=$(rendered_registry)
LANES="merge-queue review-prs"

# ---------- M1 the rendered registry marks both lane knobs unsettable ---------
for L in $LANES; do
  V=$(jq -r --arg i "$L" '.lanes[]|select(.id==$i)|.knobs[]|select(.env=="MC_MAIN_RED_LABEL")
        |(if has("settable") then (.settable|tostring) else "missing" end)' "$REG")
  [ "$V" = false ] && ok || bad "M1 $L/MC_MAIN_RED_LABEL must be registered settable:false, got '$V'"
done

# ---------- M2 the real CLI refuses and writes nothing ------------------------
mkdir -p "$T/h/bin/lib" "$T/h/catalog" "$T/h/env"
cp "$DIR/bin/harness-ctl.sh" "$T/h/bin/"
cp "$DIR/bin/lib/env-path.sh" "$T/h/bin/lib/" 2>/dev/null || true
cp "$REG" "$T/h/catalog/lanes.json"
cat > "$T/h/bin/jobs-client.sh" <<'SH'
JOBS_BOX=testbox
flag_set()    { echo "flag_set $1 $2 $3" >> "$OPS"; }
setting_set() { echo "setting_set $1 $2" >> "$OPS"; }
_jobs_req()   { echo "req $1 $2 ${3:-}" >> "$OPS"; return 1; }
SH
for L in $LANES; do
  : > "$T/ops"
  OUT=$(env HARNESS="$T/h" OPS="$T/ops" bash "$T/h/bin/harness-ctl.sh" set "$L" MC_MAIN_RED_LABEL unbreak-main 2>&1); RC=$?
  { [ "$RC" -ne 0 ] && [ ! -s "$T/ops" ]; } && ok \
    || bad "M2 set $L MC_MAIN_RED_LABEL was accepted: rc=$RC out=$OUT ops=$(cat "$T/ops")"
  case "$OUT" in *"not settable"*) ok ;; *) bad "M2 $L refusal must say the knob is not settable: $OUT" ;; esac
done

# ---------- M3 lane-gate's reader agrees --------------------------------------
for L in $LANES; do
  ( export LANE_REGISTRY="$REG" HARNESS="$T/h"
    . "$DIR/bin/lib/lane-gate.sh" >/dev/null 2>&1
    lane_knob_settable "$L" MC_MAIN_RED_LABEL ) \
    && bad "M3 lane_knob_settable $L MC_MAIN_RED_LABEL answered settable" || ok
done

# ---------- M4 a lane row that exists does not split the label ----------------
# A scratch harness with the real lane-gate, main-red-label and main-red-gate,
# and a stub worker whose /api/settings answers $ROWS (key=value words).
H="$T/g"; mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/state"
cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/main-red-label.sh" "$DIR/bin/lib/main-red-gate.sh" "$H/bin/lib/" || exit 1
cat > "$H/bin/jobs-client.sh" <<'SH'
_jobs_req() {
  case "$2" in
    /api/settings)
      local out="[]" kv
      for kv in ${ROWS:-}; do
        out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"t"}]')
      done
      printf '{"settings":%s}' "$out" ;;
    *) return 1 ;;
  esac
}
SH
: > "$H/env/global.env"
lane_label() { # lane_label <lane> [VAR=value ...] -> the label the lane's merge gate uses
  local l="$1"; shift
  # the gate caches /api/settings for 60s in state/; each case is its own rows.
  rm -f "$H/state/settings-cache.json"
  env -u MC_MAIN_RED_LABEL -u MAIN_RED_LABEL HARNESS="$H" LANE_REGISTRY="$REG" "$@" bash -c '
    . "$HARNESS/bin/lib/lane-gate.sh" >/dev/null 2>&1
    lane_env_apply "$1" >/dev/null 2>&1
    . "$HARNESS/bin/lib/main-red-gate.sh" >/dev/null 2>&1
    printf "%s" "${MC_MAIN_RED_LABEL:-}"' _ "$l"
}
for L in $LANES; do
  GOT=$(lane_label "$L" ROWS="lane.$L.mc_main_red_label=split-red")
  [ "$GOT" = fix-main-red ] && ok \
    || bad "M4 a lane.$L.mc_main_red_label row split the label for $L: got '$GOT', want fix-main-red"
  GOT=$(lane_label "$L" ROWS="lane.$L.mc_main_red_label=split-red lib.main-red-label.mc_main_red_label=fleet-red")
  [ "$GOT" = fleet-red ] && ok \
    || bad "M4 with the lib row set, $L must use it over its own lane row: got '$GOT', want fleet-red"
done

# ---------- M5 the lib row is still the settable one --------------------------
V=$(jq -r '.libs[]|select(.id=="main-red-label")|.knobs[]|select(.env=="MC_MAIN_RED_LABEL")
      |(if has("settable") then (.settable|tostring) else "true" end)' "$REG")
[ "$V" = true ] && ok || bad "M5 lib main-red-label MC_MAIN_RED_LABEL must stay settable, got '$V'"

echo "main-red-one-knob.bh-1985: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
