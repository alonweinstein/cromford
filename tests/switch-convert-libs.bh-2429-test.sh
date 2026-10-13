#!/bin/bash
# tests/switch-convert-libs.bh-2429-test.sh — five sourced libs read their kill
# switch through bin/lib/lane-switch.sh, in a subshell (BH-2429, BH-2409.3):
#   pool-account-routing-off     bin/lib/pool-account.sh  pool_account_armed
#   pr-create-rest-fallback-off  bin/lib/gh-pr-create.sh  _gpc_fallback_on
#   pr-merge-rest-off            bin/lib/gh-pr-merge.sh   _gpm_on
#   pr-dep-gate-off              bin/lib/pr-dep-gate.sh   pdg_enabled
#   resume-disabled              bin/lib/resume-dead.sh   resume_dead_pass
#
# What is proved here, each through the REAL lib's own predicate:
#   G1 each switch has catalog/switches.d/<name>.json in the pilot's shape;
#   L1-L5 (a) a fleet row of 1 with no file turns it ON, (b) a row of 0 beats
#      the file, (c) no row = the file decides, as before;
#   L3 a box row reaches this box; L4 PR_DEP_GATE=0 still stops the gate
#      whatever the row says;
#   L6 with no lane-switch.sh beside the lib the file still answers (never
#      fails open), and no file still answers OFF;
#   L7 the resolver's functions (and the jobs client's flag_active) never
#      leak into the calling shell;
#   L8 each predicate called bare under `set -euo pipefail` returns to the
#      next line;
#   N1 unreadable, other-box, prefix-colliding and seeded rows are not ON;
#      an outage keeps the last cached row.
# Run from anywhere: tests/switch-convert-libs.bh-2429-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/switch-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

SWITCHES="pool-account-routing-off pr-create-rest-fallback-off pr-merge-rest-off pr-dep-gate-off resume-disabled"
lib_of() {
  case "$1" in
    pool-account-routing-off)    echo bin/lib/pool-account.sh ;;
    pr-create-rest-fallback-off) echo bin/lib/gh-pr-create.sh ;;
    pr-merge-rest-off)           echo bin/lib/gh-pr-merge.sh ;;
    pr-dep-gate-off)             echo bin/lib/pr-dep-gate.sh ;;
    resume-disabled)             echo bin/lib/resume-dead.sh ;;
  esac
}

# ---- G1: the registry --------------------------------------------------------
for n in $SWITCHES; do
  j="$DIR/catalog/switches.d/$n.json"
  if [ ! -f "$j" ]; then bad "G1 $n: no catalog/switches.d/$n.json"; continue; fi
  eq "G1 $n name" "$(jq -r .name "$j" 2>/dev/null)" "$n"
  eq "G1 $n box_scoped is boolean" "$(jq -r '.box_scoped|type' "$j" 2>/dev/null)" boolean
  eq "G1 $n reader is its lib" "$(jq -r '.readers|join(",")' "$j" 2>/dev/null)" "$(lib_of "$n")"
  for r in $(jq -r '.readers[]?' "$j" 2>/dev/null); do
    [ -f "$DIR/$r" ] && ok || bad "G1 $n: reader $r does not exist"
  done
done

# ---- the scratch harness -----------------------------------------------------
swf_setup "$SCRATCH/h" || { echo "FAIL: swf_setup"; exit 1; }
for n in $SWITCHES; do swf_install "$(lib_of "$n")" || { echo "FAIL: install $n"; exit 1; }; done
export STUB_FLAG_ACTIVE=1

# pred <name> — sources the REAL lib from the harness in $HARNESS and calls its
# predicate in a fresh bash; prints on|off (plus the reason for pool-account).
pred() {
  # resume-disabled proves its OFF state by what resume_dead_pass leaves behind,
  # so clear that here, where scratch_rm can check the path (the child cannot)
  if [ "$1" = resume-disabled ]; then
    scratch_rm "$HARNESS/locks" || return 1
    rm -f "$HARNESS/.rd-called"
  fi
  bash -c '
    set -uo pipefail
    n=$1; lib=$2
    . "$HARNESS/$lib" >/dev/null 2>&1 || { echo source-failed; exit 0; }
    case "$n" in
      pool-account-routing-off)
        out=$(pool_account_armed); rc=$?
        if [ "$rc" = 1 ] && [ "$out" = kill_flag ]; then echo on; else echo "off:$out"; fi ;;
      pr-create-rest-fallback-off) if _gpc_fallback_on; then echo off; else echo on; fi ;;
      pr-merge-rest-off)           if _gpm_on; then echo off; else echo on; fi ;;
      pr-dep-gate-off)             if pdg_enabled; then echo off; else echo on; fi ;;
      resume-disabled)
        _rd_rows() { echo called > "$HARNESS/.rd-called"; return 1; }
        resume_dead_pass; rc=$?
        if [ "$rc" = 0 ] && [ ! -e "$HARNESS/.rd-called" ] && [ ! -d "$HARNESS/locks" ]; then echo on
        elif [ -e "$HARNESS/.rd-called" ]; then echo off
        else echo "odd:rc=$rc"; fi ;;
    esac' _ "$1" "$(lib_of "$1")"
}
state() { case "$1" in on) echo on ;; off*) echo off ;; *) echo "$1" ;; esac; }

# ---- L1-L5: row ON, row 0 beats file, no row = file --------------------------
for n in $SWITCHES; do
  rm -f "$SWF_ROOT/flags/$n"
  swf_rows "switch.$n=1"
  eq "$n (a) row 1, no file" "$(pred "$n")" on
  swf_rows "switch.$n=0"; swf_flag "$n"
  eq "$n (b) row 0 beats the file" "$(state "$(pred "$n")")" off
  swf_rows; swf_flag "$n"
  eq "$n (c) no row, file" "$(pred "$n")" on
  rm -f "$SWF_ROOT/flags/$n"
  swf_rows
  eq "$n (c') no row, no file" "$(state "$(pred "$n")")" off
done
eq "pool-account (b) falls through to the next reason" "$(swf_rows switch.pool-account-routing-off=0; pred pool-account-routing-off)" off:no_tokens_dir

swf_rows "switch.pr-merge-rest-off.hub-1=1"
eq "L3 box row reaches this box" "$(pred pr-merge-rest-off)" on
swf_rows "switch.pr-dep-gate-off=0"
eq "L4 PR_DEP_GATE=0 still stops the gate over a 0 row" "$(PR_DEP_GATE=0 pred pr-dep-gate-off)" on

# ---- N1: rows that must not turn pr-merge-rest-off on ------------------------
for r in "switch.pr-merge-rest-off=maybe" "switch.pr-merge-rest-off.other-box=1" \
         "switch.pr-merge-rest-off-extra=1" "seed:switch.pr-merge-rest-off=1"; do
  swf_rows "$r"
  eq "N1 $r is not ON" "$(pred pr-merge-rest-off)" off
done
swf_rows "switch.pr-merge-rest-off=1"
eq "N1 row 1 before the outage" "$(pred pr-merge-rest-off)" on
g0=$(swf_gets)
scratch_rm "$SWF_ROOT/state/lane-gate"
eq "N1 outage keeps the cached row" "$(UNREACHABLE=1 LANE_GATE_NOW=$((LANE_GATE_NOW+600)) pred pr-merge-rest-off)" on
[ "$(swf_gets)" -gt "$g0" ] && ok || bad "N1 the outage case never asked the worker (cache was not stale)"

# ---- L6: the resolver cannot load -> the lib's own file test ------------------
for n in $SWITCHES; do
  b="$SCRATCH/bare-$n"
  mkdir -p "$b/bin/lib" "$b/flags" "$b/logs"
  cp "$DIR/$(lib_of "$n")" "$b/bin/lib/"
  # gh-pr-merge.sh defines nothing without the create ladder it borrows from
  [ "$n" = pr-merge-rest-off ] && cp "$DIR/bin/lib/gh-pr-create.sh" "$b/bin/lib/"
  touch "$b/flags/$n"
  eq "L6 $n: no resolver, file present" "$(HARNESS="$b" pred "$n")" on
  rm -f "$b/flags/$n"
  eq "L6 $n: no resolver, no file" "$(state "$(HARNESS="$b" pred "$n")")" off
done

# ---- L7: nothing leaks into the calling shell --------------------------------
swf_rows "switch.pr-dep-gate-off=0"
for n in $SWITCHES; do
  out=$(bash -c '
    n=$1; . "$HARNESS/$2" >/dev/null 2>&1
    # pool-account.sh loads the jobs client itself at source time, so only a
    # flag_active that appears DURING the call is the resolver leaking
    fa0=no; command -v flag_active >/dev/null 2>&1 && fa0=yes
    case "$n" in
      pool-account-routing-off)    pool_account_armed >/dev/null ;;
      pr-create-rest-fallback-off) _gpc_fallback_on ;;
      pr-merge-rest-off)           _gpm_on ;;
      pr-dep-gate-off)             pdg_enabled ;;
      resume-disabled)             _rd_rows() { return 1; }; resume_dead_pass ;;
    esac
    [ "$fa0" = no ] && command -v flag_active >/dev/null 2>&1 && echo leaked:flag_active
    command -v _lg_settings_refresh >/dev/null 2>&1 && echo leaked:_lg_settings_refresh
    command -v lane_switch >/dev/null 2>&1 && echo leaked:lane_switch
    echo done' _ "$n" "$(lib_of "$n")" 2>/dev/null)
  eq "L7 $n leaks nothing" "$out" done
done
# the resolver really ran in there: at least one settings GET was served
[ "$(swf_gets)" -gt 0 ] && ok || bad "L7 the resolver never asked for settings"

# ---- L8: set -euo pipefail callers survive an OFF switch ---------------------
swf_rows
mkdir -p "$SCRATCH/tok" && touch "$SCRATCH/tok/a-setup-token.env"
for n in $SWITCHES; do
  out=$(POOL_TOKENS_DIR="$SCRATCH/tok" bash -c '
    set -euo pipefail
    n=$1; . "$HARNESS/$2" >/dev/null 2>&1
    case "$n" in
      pool-account-routing-off)
        accounts_load() { :; }; declare -gA ACCT_VENDOR=([a]=claude) ACCT_ENABLED=([a]=1)
        pool_account_armed ;;
      pr-create-rest-fallback-off) _gpc_fallback_on ;;
      pr-merge-rest-off)           _gpm_on ;;
      pr-dep-gate-off)             pdg_enabled ;;
      resume-disabled)             _rd_rows() { :; }; RESUME_BUILDS_DIR=/nonexistent resume_dead_pass >/dev/null ;;
    esac
    echo reached' _ "$n" "$(lib_of "$n")" 2>/dev/null)
  eq "L8 $n under set -e" "$out" reached
done

echo "switch-convert-libs: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
