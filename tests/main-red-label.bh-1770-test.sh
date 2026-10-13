#!/bin/bash
# tests/main-red-label.bh-1770-test.sh — ONE knob names the main-red label, and
# every reader agrees on it (BH-1770 part A, the #1142 item 6 remainder).
#
# THE DEFECT. Two names, one label, one default: the merge lanes read
# MC_MAIN_RED_LABEL from the process env (bin/lib/main-red-gate.sh), the build
# priority rank read MAIN_RED_LABEL from the env or env/global.env
# (main_red_label in bin/lib/hotfix-lib.sh). Set one without the other and a
# build ranks one PR as the main-red fix while every merge lane exempts a
# different one from the freeze.
#
# THE CONTRACT pinned here. MC_MAIN_RED_LABEL is the one registered knob (the
# `main-red-label` lib in catalog/lanes.d/_lib.json, settings row
# lib.main-red-label.mc_main_red_label). MAIN_RED_LABEL is a deprecated alias:
# still honoured, logged once. Whichever name is set, and wherever (process env
# or env/global.env), EVERY reader answers the same label:
#   hotfix     main_red_label                      (bin/lib/hotfix-lib.sh)
#   gate       $MC_MAIN_RED_LABEL after sourcing   (bin/lib/main-red-gate.sh)
#   exempt     main_red_exempt on a PR carrying it (bin/lib/main-red-gate.sh)
#   rank       priority_rank_labels_csv of it      (bin/lib/hotfix-lib.sh)
# Every reader is the REAL sourced lib, in a child shell, so no case can leak
# a variable into the next.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/main-red-label.bh-1770-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
REG=$(rendered_registry)

# mkh <dir> [with-lib 0|1] [with-gate 0|1] — a scratch harness carrying the libs.
mkh() {
  local h="$1" lib="${2:-1}" gate="${3:-0}"
  mkdir -p "$h/bin/lib" "$h/env" "$h/flags" "$h/logs" "$h/state"
  cp "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/main-red-gate.sh" "$h/bin/lib/" || exit 1
  if [ "$lib" = 1 ]; then cp "$DIR/bin/lib/main-red-label.sh" "$h/bin/lib/" 2>/dev/null; fi
  if [ "$gate" = 1 ]; then
    cp "$DIR/bin/lib/lane-gate.sh" "$h/bin/lib/" || exit 1
    # The stub worker: /api/settings answers the rows in $ROWS (key=value
    # words), everything else is an outage — the gate fails OPEN on those.
    cat > "$h/bin/jobs-client.sh" <<'SH'
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
  fi
  : > "$h/env/global.env"
}

# readers <harness> <label-to-probe> [VAR=value ...] -> "hotfix|gate|exempt-rc|rank"
readers() {
  local h="$1" probe="$2"; shift 2
  env -u MC_MAIN_RED_LABEL -u MAIN_RED_LABEL HARNESS="$h" LANE_REGISTRY="$REG" "$@" \
    bash -c '
      . "$HARNESS/bin/lib/hotfix-lib.sh" 2>/dev/null
      a=$(main_red_label "$HARNESS" 2>/dev/null)
      r=$(priority_rank_labels_csv "$1" "$HARNESS" 2>/dev/null)
      b=$( . "$HARNESS/bin/lib/main-red-gate.sh" 2>/dev/null; printf "%s" "${MC_MAIN_RED_LABEL:-}")
      e=$( . "$HARNESS/bin/lib/main-red-gate.sh" 2>/dev/null
           main_red_exempt o/r 1 https://github.com/o/r/pull/1 abc "$1" >/dev/null 2>&1; echo $?)
      printf "%s|%s|%s|%s" "$a" "$b" "$e" "$r"' _ "$probe"
}

# agree <want-label> <what> <harness> [VAR=value ...] — every reader names it.
agree() {
  local want="$1" what="$2" h="$3" got; shift 3
  got=$(readers "$h" "$want" "$@")
  [ "$got" = "$want|$want|0|1" ] && ok \
    || bad "$what: every reader must name '$want' (hotfix|gate|exempt-rc|rank want $want|$want|0|1), got '$got'"
}

H1="$T/h1"; mkh "$H1" 1 0

# ---------- L1 nothing set anywhere -> the default, from every reader ----------
agree fix-main-red "L1 no knob" "$H1"

# ---------- L2 the canonical name in the process env --------------------------
agree canon-red "L2 MC_MAIN_RED_LABEL in the env" "$H1" MC_MAIN_RED_LABEL=canon-red

# ---------- L3 the deprecated alias in the process env ------------------------
agree alias-red "L3 MAIN_RED_LABEL (alias) in the env" "$H1" MAIN_RED_LABEL=alias-red

# ---------- L4 the canonical name in env/global.env ---------------------------
printf 'MC_MAIN_RED_LABEL=file-canon\n' > "$H1/env/global.env"
agree file-canon "L4 MC_MAIN_RED_LABEL in env/global.env" "$H1"

# ---------- L5 the alias in env/global.env ------------------------------------
printf 'MAIN_RED_LABEL=file-alias\n' > "$H1/env/global.env"
agree file-alias "L5 MAIN_RED_LABEL (alias) in env/global.env" "$H1"
: > "$H1/env/global.env"

# ---------- L6 both set and they disagree: the canonical wins everywhere ------
agree canon-wins "L6 both names set, env" "$H1" MC_MAIN_RED_LABEL=canon-wins MAIN_RED_LABEL=alias-loses
printf 'MAIN_RED_LABEL=alias-loses\n' > "$H1/env/global.env"
agree canon-wins "L6 canonical env over an alias in the file" "$H1" MC_MAIN_RED_LABEL=canon-wins
: > "$H1/env/global.env"

# ---------- L7 the alias is LOGGED, once, through the lane-gate log throttle --
H2="$T/h2"; mkh "$H2" 1 1
readers "$H2" x MAIN_RED_LABEL=alias-red >/dev/null
N=$(grep -c 'MAIN_RED_LABEL' "$H2/logs/lane-gate.log" 2>/dev/null); N=${N:-0}
[ "$N" = 1 ] && ok || bad "L7 one resolve through the alias must write ONE lane-gate.log line, got $N: $(cat "$H2/logs/lane-gate.log" 2>/dev/null)"
grep -q 'deprecated' "$H2/logs/lane-gate.log" 2>/dev/null && ok \
  || bad "L7 the line must say the alias is deprecated: $(cat "$H2/logs/lane-gate.log" 2>/dev/null)"
readers "$H2" x MAIN_RED_LABEL=alias-red >/dev/null
N=$(grep -c 'MAIN_RED_LABEL' "$H2/logs/lane-gate.log" 2>/dev/null); N=${N:-0}
[ "$N" = 1 ] && ok || bad "L7 a second resolve inside the hour must not log again, got $N lines"
# the canonical name alone logs nothing at all
H2B="$T/h2b"; mkh "$H2B" 1 1
readers "$H2B" x MC_MAIN_RED_LABEL=canon-red >/dev/null
grep -q 'MAIN_RED_LABEL' "$H2B/logs/lane-gate.log" 2>/dev/null \
  && bad "L7 the canonical name must not log a deprecation: $(cat "$H2B/logs/lane-gate.log")" || ok

# ---------- L8 the SETTINGS ROW is the knob: it beats both names, everywhere --
H3="$T/h3"; mkh "$H3" 1 1
agree row-red "L8 lib.main-red-label.mc_main_red_label row over the env" "$H3" \
  ROWS=lib.main-red-label.mc_main_red_label=row-red MC_MAIN_RED_LABEL=env-red MAIN_RED_LABEL=alias-red
# a row for ANOTHER key is not this knob
H3B="$T/h3b"; mkh "$H3B" 1 1
agree env-red "L8 an unrelated row changes nothing" "$H3B" \
  ROWS=lib.other.mc_main_red_label=row-red MC_MAIN_RED_LABEL=env-red

# ---------- L9 the registry carries ONE knob, and the alias is not a knob -----
jq -e '.libs[]? | select(.id == "main-red-label") | select(.file == "bin/lib/main-red-label.sh")
       | .knobs[] | select(.env == "MC_MAIN_RED_LABEL" and .default == "fix-main-red")' "$REG" >/dev/null 2>&1 \
  && ok || bad "L9 catalog/lanes.d/_lib.json must register lib main-red-label (bin/lib/main-red-label.sh) with MC_MAIN_RED_LABEL default fix-main-red"
N=$(jq -r '[(.lanes[]?, .libs[]?) | .knobs[]? | select(.env == "MAIN_RED_LABEL")] | length' "$REG")
[ "$N" = 0 ] && ok || bad "L9 the deprecated alias MAIN_RED_LABEL must not be registered as a knob of its own ($N found)"

# ---------- L10 the lib missing (a box mid-sync): both names still honoured ---
H4="$T/h4"; mkh "$H4" 0 0
agree canon-red "L10 no bin/lib/main-red-label.sh, canonical name" "$H4" MC_MAIN_RED_LABEL=canon-red
agree alias-red "L10 no bin/lib/main-red-label.sh, alias" "$H4" MAIN_RED_LABEL=alias-red

echo "main-red-label.bh-1770: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
