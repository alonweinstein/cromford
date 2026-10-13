#!/bin/bash
# bin/lib/fixround-closure-lint.sh — BH-5064. The scratch-closure lint for
# bin/blocked-resolver.sh fix rounds. Sourced, never executed.
#
# THE INCIDENT. On 2026-10-06 #4189 and #4680 each carried a new suite that
# hand-copied bin/lib files; their PR checks predated #4884 (the lint's rules-pack
# row) and a hand-applied merge-queue label skipped the conductor's red pre-queue
# verdict, so each sank a Mergify batch (#4922, #5054). The builder gate and PR CI
# run the lint since #4884, but a blocked-resolver fix round verified only npm
# typecheck + unit, so on this repo it pushed after checking nothing at all.
#
# CONTRACT
#   frcl_on                      rc 0 when FIXROUND_CLOSURE_LINT resolves to 1,
#                                rc 1 when it resolves to 0. lane_knob (libs
#                                scope), then the env, then this lib's registry
#                                fragment default; anything not 0/1 is the
#                                fragment default. No literal here.
#   frcl_scan <wt> <base> <out>  Runs `bin/rules-pack.sh --only scratch-closure`
#                                from <wt> against <base>. Writes
#                                <out>/closure-lint.findings (the pack's stdout),
#                                <out>/closure-lint.err and <out>/closure-lint.rp/
#                                (the pack's --out, cleared first). Prints one word:
#                                  clean          rc 0  pack rc 0
#                                  red            rc 1  pack rc 1 with a finding
#                                  could-not-run  rc 2  any other pack rc, or rc 1
#                                                       with no finding line
#                                  skipped        rc 3  <wt> has no executable
#                                                       bin/rules-pack.sh, or its
#                                                       catalog has no row for it
#                                  off            rc 4  frcl_on says 0
#   frcl_findings <out>          The findings, `scratch-closure: ` stripped, at
#                                most 20 lines.
#
# Knob: FIXROUND_CLOSURE_LINT (catalog/lanes.d/_lib.fixround-closure-lint.json).
# The pack's own time budget is the fly-pool RULES_PACK_BUDGET_S knob, bounded
# at three times that, the same bound bin/lib/prepr-gate.sh puts on it.

_FRCL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The rules-pack id, catalog/rules-pack.tsv's `scratch-closure` row: this lib's
# subject, not a tunable.
FRCL_COMPONENT=scratch-closure

# _frcl_default — the knob's default from this lib's own registry fragment,
# under the harness root first and beside this lib second.
_frcl_default() {
  local f root="${HARNESS:-${H:-}}" v=""
  for f in ${root:+"$root/catalog/lanes.d/_lib.fixround-closure-lint.json"} \
           "$_FRCL_LIB/../../catalog/lanes.d/_lib.fixround-closure-lint.json"; do
    [ -r "$f" ] || continue
    v=$(jq -r '.libs[]? | select(.id == "fixround-closure-lint") | .knobs[]?
               | select(.env == "FIXROUND_CLOSURE_LINT") | .default // empty' "$f" 2>/dev/null)
    [ -n "$v" ] && break
  done
  printf '%s' "$v"
}

frcl_on() {
  local _LG_KIND=libs v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob fixround-closure-lint FIXROUND_CLOSURE_LINT 2>/dev/null)
  [ -n "$v" ] || v="${FIXROUND_CLOSURE_LINT:-}"
  case "$v" in 0|1) ;; *) v=$(_frcl_default) ;; esac
  # An unreadable fragment leaves the gate on: a scan that cannot run is
  # could-not-run, which never refuses a round.
  [ "$v" != 0 ]
}

# _frcl_budget — the fly-pool RULES_PACK_BUDGET_S, else the pack's own
# documented fallback.
_frcl_budget() {
  local v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob fly-pool RULES_PACK_BUDGET_S "${PROJECT:-}" 2>/dev/null)
  [ -n "$v" ] || v="${RULES_PACK_BUDGET_S:-}"
  case "$v" in ''|*[!0-9]*|0) v=60 ;; esac
  printf '%s' "$v"
}

frcl_scan() {
  local wt="${1:-}" base="${2:-}" out="${3:-}" rpo prc budget
  if ! frcl_on; then echo off; return 4; fi
  if [ ! -x "$wt/bin/rules-pack.sh" ] \
     || ! cut -f1 "$wt/catalog/rules-pack.tsv" 2>/dev/null | grep -qx "$FRCL_COMPONENT"; then
    echo skipped; return 3
  fi
  mkdir -p "$out" 2>/dev/null || { echo could-not-run; return 2; }
  rpo="$(cd "$out" && pwd)/closure-lint.rp"
  rm -rf -- "${rpo:?}"
  budget=$(_frcl_budget)
  ( cd "$wt" && timeout $((3 * budget)) bin/rules-pack.sh --tree . --base "$base" \
      --only "$FRCL_COMPONENT" --out "$rpo" ) > "$out/closure-lint.findings" 2> "$out/closure-lint.err"; prc=$?
  if [ "$prc" = 0 ]; then echo clean; return 0; fi
  if [ "$prc" = 1 ] && grep -q "^$FRCL_COMPONENT: " "$out/closure-lint.findings"; then echo red; return 1; fi
  echo could-not-run; return 2
}

frcl_findings() {
  sed -n "s/^$FRCL_COMPONENT: //p" "${1:-}/closure-lint.findings" 2>/dev/null | head -20
}
