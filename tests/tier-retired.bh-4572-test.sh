#!/bin/bash
# tests/tier-retired.bh-4572-test.sh — THE TIER NO LONGER DECIDES WHO MERGES
# (BH-4572, tracer slice BH-4579).
#
# the operator, 2026-10-05: retire the tier-2 human sign-off. The tier stays computed
# and recorded as a risk class. A tier-2 APPROVE goes on the merge queue like
# any other, unless an operator sets the settings row
# tier_gate_mode[.<project>] to `human`. An unreadable or garbage row holds
# (fail closed) and pages once per (project, UTC day).
#
# DRIVEN, NOT GREPPED (D2/D3). Both hand-off blocks — `# >>> verdict at review`
# (bin/lib/rb/pr.sh) and its settle twin `# >>> verdict artifact`
# (bin/lib/rb/result.sh) — are extracted from the flattened pipeline by their
# own markers and executed against a scratch $HARNESS that carries the real
# bin/lib/tier-gate.sh and the real bin/alert-line.sh. setting_get is a stub
# over $T/rows/<key> (absent = rc 2 no row, $T/rows/FAIL = rc 1 outage), and
# merge_queue_put appends its arguments to $T/calls. Every assertion reads
# $T/calls, the build's pipeline.log, ALERTS.log or the page stamp.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/tier-retired.bh-4572-test.sh
# (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR JOB_ID JOB_PHASE_ID

PROJECT=demo-os
SLUG=example-org/demo-os
DAY=2026-10-05          # pinned through TG_PAGE_DAY: no clock read in this file
ROWS="$T/rows"; CALLS="$T/calls"
marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1} f{print} f && index($0,e){exit}' "$3"; }

EARLY="$T/rb-early.sh"; SETTLE="$T/rb-settle.sh"
marked '# >>> verdict at review' '# <<< verdict at review' "$RB" > "$EARLY"
marked '# >>> verdict artifact'  '# <<< verdict artifact'  "$RB" > "$SETTLE"
[ -s "$EARLY" ]  && ok || bad "the pipeline carries no '# >>> verdict at review' block"
[ -s "$SETTLE" ] && ok || bad "the pipeline carries no '# >>> verdict artifact' block"

# fresh_h <name> [mutant-lib] — a scratch harness with the gate lib and the
# pager, each with its source closure (BH-4552). A mutant is written first:
# scratch_install_closure keeps a file already there.
fresh_h() {
  local h="$T/h-$1"
  scratch_rm "$h"; mkdir -p "$h/bin/lib" "$h/logs" "$h/flags" "$h/state"
  [ -z "${2:-}" ] || cat "$2" > "$h/bin/lib/tier-gate.sh"
  scratch_install_closure bin/lib/tier-gate.sh "$h" >/dev/null || return 1
  scratch_install_closure bin/alert-line.sh "$h" >/dev/null || return 1
  printf '%s\n' "$h"
}
rows_reset() { scratch_rm "$ROWS"; mkdir -p "$ROWS"; }
row_set() { printf '%s\n' "$2" > "$ROWS/$1"; }

# blk <harness> <case> <tier> <block...> — run the blocks in ONE bash process.
blk() {
  local h="$1" c="$2" tier="$3"; shift 3
  B="$T/b-$c"; scratch_rm "$B"; mkdir -p "$B"; : > "$CALLS"
  printf 'read the diff\nVERDICT: APPROVE\n' > "$B/review.md"
  ( export HARNESS="$h" BUILD="$B" PROJECT="$PROJECT" KEY=BH-4579 SLUG="$SLUG" \
           JOB_ID=job-1 TIER="$tier" PR_URL="https://github.com/$SLUG/pull/42" \
           ROWS="$ROWS" CALLS="$CALLS" TG_PAGE_DAY="$DAY" ALERT_LINE_STAMP="$DAY 04:00:00Z" \
           SCRIPTS="$*"
    bash -c '
      STAMP() { printf "2026-10-05 04:00:00Z"; }
      job_artifact_put() { return 0; }
      rp_out_is_claude() { return 0; }
      rp_out_prov() { printf claude; }
      to_lane_lead_hold() { return 1; }
      merge_queue_put() { printf "%s\n" "$*" >> "$CALLS"; }
      setting_get() { [ -e "$ROWS/FAIL" ] && return 1; [ -f "$ROWS/$1" ] || return 2; cat "$ROWS/$1"; }
      for s in $SCRIPTS; do . "$s"; done' ) 2>"$T/err-$c"
}
ncalls() { grep -c . "$CALLS" 2>/dev/null || true; }
nalerts() { if [ -f "$1/logs/ALERTS.log" ]; then grep -c . "$1/logs/ALERTS.log"; else echo 0; fi; }
plog() { cat "$B/pipeline.log" 2>/dev/null; }

# ── T1: no row → a tier-2 APPROVE enqueues exactly once, same shape as before ─
rows_reset; H1=$(fresh_h t1)
blk "$H1" t1 2 "$EARLY"
[ "$(ncalls)" = 1 ] && ok || bad "T1: no row must enqueue once, got $(ncalls) ($(cat "$T/err-t1"))"
[ "$(cat "$CALLS")" = "$PROJECT 42 $SLUG tier-2 APPROVE from BH-4579" ] \
  && ok || bad "T1: the enqueue must keep its shape, got: $(cat "$CALLS")"
grep -q 'APPROVE enqueued #42' <<<"$(plog)" && ok || bad "T1: pipeline.log must say enqueued: $(plog)"
[ "$(nalerts "$H1")" = 0 ] && ok || bad "T1: no row is not an alert: $(cat "$H1/logs/ALERTS.log")"

# ── T1b: the settle twin, MQ_ENQUEUED unset, no row → one call ───────────────
rows_reset; blk "$H1" t1b 2 "$SETTLE"
[ "$(ncalls)" = 1 ] && ok || bad "T1b: the settle block with no row must enqueue once, got $(ncalls) ($(cat "$T/err-t1b"))"

# ── T2: per-project human → held, named, no page ─────────────────────────────
rows_reset; row_set tier_gate_mode.$PROJECT human; H2=$(fresh_h t2)
blk "$H2" t2 2 "$EARLY"
[ "$(ncalls)" = 0 ] && ok || bad "T2: tier_gate_mode.$PROJECT=human must hold, got $(ncalls) calls"
grep -qF 'APPROVE not enqueued: tier_gate_mode=human (tier_gate_mode.demo-os) holds tier 2' <<<"$(plog)" \
  && ok || bad "T2: the hold line is missing: $(plog)"
[ "$(nalerts "$H2")" = 0 ] && ok || bad "T2: a readable human row is not an alert: $(cat "$H2/logs/ALERTS.log")"

# ── T2b: the settle twin under the same row → held too ───────────────────────
blk "$H2" t2b 2 "$SETTLE"
[ "$(ncalls)" = 0 ] && ok || bad "T2b: the settle twin must hold under human, got $(ncalls) calls"
grep -qF 'APPROVE not enqueued: tier_gate_mode=human (tier_gate_mode.demo-os) holds tier 2' <<<"$(plog)" \
  && ok || bad "T2b: the settle hold line is missing: $(plog)"
blk "$H2" t2b2 2 "$EARLY" "$SETTLE"
[ "$(ncalls)" = 0 ] && ok || bad "T2b: both blocks in one build must write no row under human, got $(ncalls)"

# ── T2c: global human, per-project off → the per-project row wins ────────────
rows_reset; row_set tier_gate_mode human; row_set tier_gate_mode.$PROJECT off
blk "$H2" t2c 2 "$EARLY"
[ "$(ncalls)" = 1 ] && ok || bad "T2c: a per-project off must beat a global human, got $(ncalls) calls"
rows_reset; row_set tier_gate_mode human
blk "$H2" t2c2 2 "$EARLY"
[ "$(ncalls)" = 0 ] && ok || bad "T2c: a global human with no project row must hold, got $(ncalls)"
grep -qF 'tier_gate_mode=human (tier_gate_mode) holds tier 2' <<<"$(plog)" \
  && ok || bad "T2c: the global source must be named: $(plog)"

# ── T2d: ' HUMAN ' trims and lowercases to human ─────────────────────────────
rows_reset; row_set tier_gate_mode.$PROJECT ' HUMAN '
blk "$H2" t2d 3 "$EARLY"
[ "$(ncalls)" = 0 ] && ok || bad "T2d: ' HUMAN ' must read as human and hold, got $(ncalls)"
grep -qF 'APPROVE not enqueued: tier_gate_mode=human (tier_gate_mode.demo-os) holds tier 3' <<<"$(plog)" \
  && ok || bad "T2d: ' HUMAN ' must read as human, not as garbage: $(plog)"
[ "$(nalerts "$H2")" = 0 ] && ok || bad "T2d: a mixed-case human is readable, so no page: $(cat "$H2/logs/ALERTS.log")"

# ── T3: an unreadable row → held, ONE page, stamp written ────────────────────
rows_reset; touch "$ROWS/FAIL"; H3=$(fresh_h t3)
blk "$H3" t3 2 "$EARLY"
[ "$(ncalls)" = 0 ] && ok || bad "T3: an unreadable row must hold, got $(ncalls) calls"
[ "$(nalerts "$H3")" = 1 ] && ok || bad "T3: exactly one page, got $(nalerts "$H3"): $(cat "$H3/logs/ALERTS.log" 2>/dev/null)"
grep -qF '[tier-gate] demo-os' "$H3/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "T3: the page must name [tier-gate] demo-os: $(cat "$H3/logs/ALERTS.log" 2>/dev/null)"
[ -e "$H3/state/tier-gate/page-demo-os-$DAY" ] && ok || bad "T3: the page stamp is missing"
grep -qF 'APPROVE not enqueued: tier_gate_mode=unreadable' <<<"$(plog)" \
  && ok || bad "T3: the hold line must say unreadable: $(plog)"

# ── T4: again the same day → still held, still ONE page ──────────────────────
blk "$H3" t4 2 "$EARLY" "$SETTLE"
[ "$(ncalls)" = 0 ] && ok || bad "T4: a second unreadable read must still hold, got $(ncalls)"
[ "$(nalerts "$H3")" = 1 ] && ok || bad "T4: the page must not repeat the same day, got $(nalerts "$H3")"

# ── T4b: garbage 'maybe' → held, one page ────────────────────────────────────
rows_reset; row_set tier_gate_mode.$PROJECT maybe; H4=$(fresh_h t4b)
blk "$H4" t4b 2 "$EARLY"
[ "$(ncalls)" = 0 ] && ok || bad "T4b: 'maybe' must hold, got $(ncalls)"
[ "$(nalerts "$H4")" = 1 ] && ok || bad "T4b: 'maybe' must page once, got $(nalerts "$H4")"
grep -qF "value 'maybe'" "$H4/logs/ALERTS.log" 2>/dev/null && ok || bad "T4b: the page names the value: $(cat "$H4/logs/ALERTS.log" 2>/dev/null)"

# ── T4c: the pager is gone → a page failure still holds ──────────────────────
rows_reset; touch "$ROWS/FAIL"; H4C=$(fresh_h t4c); rm -f "$H4C/bin/alert-line.sh"
blk "$H4C" t4c 2 "$EARLY"
[ "$(ncalls)" = 0 ] && ok || bad "T4c: no pager must still hold, got $(ncalls)"
[ ! -e "$H4C/state/tier-gate/page-demo-os-$DAY" ] && ok || bad "T4c: no page sent means no stamp (the next call retries)"

# ── T5: TIER 1 never reaches merge_queue_put from either block ───────────────
rows_reset; blk "$H1" t5 1 "$EARLY" "$SETTLE"
[ "$(ncalls)" = 0 ] && ok || bad "T5: tier 1 must never enqueue from the hand-off, got $(ncalls)"
rows_reset; touch "$ROWS/FAIL"; H5=$(fresh_h t5)
blk "$H5" t5b 1 "$EARLY" "$SETTLE"
[ "$(nalerts "$H5")" = 0 ] && ok || bad "T5: a tier-1 build never reads the gate, so never pages"

# ── T6: there is no file flag ────────────────────────────────────────────────
rows_reset; H6=$(fresh_h t6); touch "$H6/flags/tier-gate-mode" "$H6/flags/tier-gate" "$H6/flags/tier_gate_mode"
blk "$H6" t6 2 "$EARLY"
[ "$(ncalls)" = 1 ] && ok || bad "T6: a flags/tier-gate* file must have no effect, got $(ncalls) calls"

# ── T7: the rename ───────────────────────────────────────────────────────────
grep -qE '^[^#]*\. "\$H/bin/lib/autoenqueue\.sh"' "$DIR/bin/merge-conductor.sh" \
  && ok || bad "T7: bin/merge-conductor.sh must source \$H/bin/lib/autoenqueue.sh on a non-comment line"
[ -f "$DIR/bin/lib/autoenqueue.sh" ] && ok || bad "T7: bin/lib/autoenqueue.sh is missing"
[ ! -e "$DIR/bin/lib/tier2-autoenqueue.sh" ] && ok || bad "T7: bin/lib/tier2-autoenqueue.sh must be gone"
# A suite that still copies or sources the old path exits at setup; a merge from main can bring one in.
T7_STALE=$(grep -rlE 'tier2-autoenqueue\.sh' "$DIR/tests" --include='*.sh' 2>/dev/null | grep -vF "$DIR/tests/fixtures/" | grep -vxF "$DIR/tests/tier-retired.bh-4572-test.sh")
[ -z "$T7_STALE" ] && ok || bad "T7: tests still name bin/lib/tier2-autoenqueue.sh: $T7_STALE"
grep -qF 'state/tier2-autoenqueue.txt' "$DIR/bin/lib/autoenqueue.sh" \
  && ok || bad "T7: the ledger path state/tier2-autoenqueue.txt must be kept"

# ── T8: a harness without the lib enqueues as before, and says so ────────────
rows_reset; row_set tier_gate_mode.$PROJECT human; H8=$(fresh_h t8); rm -f "$H8/bin/lib/tier-gate.sh"
blk "$H8" t8 2 "$EARLY"
[ "$(ncalls)" = 1 ] && ok || bad "T8: no lib must enqueue as before, got $(ncalls)"
grep -qF 'tier gate lib not loaded' <<<"$(plog)" && ok || bad "T8: the missing lib must be named: $(plog)"

# ── T9: tg_holds called directly (the contract sibling callers import) ──────
# tg <tier> — rc of tg_holds against $ROWS, through the real lib in $H9.
H9=$(fresh_h t9)
tg() {
  ( export HARNESS="$H9" ROWS="$ROWS" TG_PAGE_DAY="$DAY" ALERT_LINE_STAMP="$DAY 04:00:00Z"
    bash -c 'setting_get() { [ -e "$ROWS/FAIL" ] && return 1; [ -f "$ROWS/$1" ] || return 2; cat "$ROWS/$1"; }
      . "$HARNESS/bin/lib/tier-gate.sh" || exit 9
      tg_holds demo-os "$1"' _ "$1" ) 2>/dev/null
}
rows_reset; row_set tier_gate_mode.$PROJECT human
tg 1; [ "$?" = 1 ] && ok || bad "T9: human must let tier 1 proceed"
tg 2; [ "$?" = 0 ] && ok || bad "T9: human must hold tier 2"
rows_reset
tg 2; [ "$?" = 1 ] && ok || bad "T9: no row must let tier 2 proceed"
rows_reset; touch "$ROWS/FAIL"
tg 1; [ "$?" = 0 ] && ok || bad "T9: an unreadable row must hold even tier 1 for a direct caller"

# ── T10: the renamed lib with no root writes nothing (BH-2613 contract) ─────
# The rename makes bin/lib/autoenqueue.sh a new path to the root-literal
# ratchet, so its /root/harness fallback went: with MC_H, HARNESS and H all
# empty, ae_mark and ae_project must write nothing. The tick path is pointed
# into $NR after the source, so a regressed guard writes there, never under /.
NR="$T/noroot"; scratch_rm "$NR"; mkdir -p "$NR"
( cd "$NR" && env -u HARNESS -u H -u MC_H -u MC_TICK_DIR MC_TICK_ID=t1 NR="$NR" \
    AE="$DIR/bin/lib/autoenqueue.sh" bash -c '
    mc_log() { printf "%s\n" "$*" >> "$NR/mc.log"; }
    . "$AE" || exit 9
    [ -z "$(_ae_home)" ] || exit 8
    _ae_tick_file() { printf "%s/leak" "$NR"; }
    ae_mark demo-os ready k1 abc
    ae_project demo-os example-org/demo-os mergify main' ) 2>/dev/null
[ ! -e "$NR/leak" ] && ok || bad "T10: ae_mark with no root must write no tick file"
grep -qF 'no harness root' "$NR/mc.log" 2>/dev/null \
  && ok || bad "T10: ae_project with no root must say so: $(cat "$NR/mc.log" 2>/dev/null)"

# ── T11: _ae_alert with no mc_alert pages through bin/alert-line.sh ────────
# The rename made the lib new to the alert-writers ratchet too, so its raw
# ALERTS.log fallback now goes through the pager.
H11=$(fresh_h t11)
( MC_H="$H11" ALERT_LINE_STAMP="$DAY 04:00:00Z" AE="$DIR/bin/lib/autoenqueue.sh" bash -c '
    . "$AE" || exit 9
    _ae_alert demo-os#42 "fixture line"' ) 2>/dev/null
grep -qxF "$DAY 04:00:00Z [merge-conductor] demo-os#42 AUTOENQUEUE — fixture line" "$H11/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "T11: the fallback page is missing: $(cat "$H11/logs/ALERTS.log" 2>/dev/null)"

# ── M1: THE MUTATION. tg_holds always proceeds → T2 and T3 must enqueue ──────
MUT="$T/tier-gate-mutant.sh"
sed 's/^tg_holds() {$/tg_holds() { return 1/' "$DIR/bin/lib/tier-gate.sh" > "$MUT"
if cmp -s "$DIR/bin/lib/tier-gate.sh" "$MUT"; then
  bad "M1: could not build the mutant — no 'tg_holds() {' line in bin/lib/tier-gate.sh"
else
  rows_reset; row_set tier_gate_mode.$PROJECT human; HM=$(fresh_h m1 "$MUT")
  blk "$HM" m1a 2 "$EARLY"
  [ "$(ncalls)" = 1 ] && ok || bad "M1: the mutant must enqueue under human (T2 has no teeth), got $(ncalls)"
  rows_reset; touch "$ROWS/FAIL"
  blk "$HM" m1b 2 "$EARLY"
  [ "$(ncalls)" = 1 ] && ok || bad "M1: the mutant must enqueue when unreadable (T3 has no teeth), got $(ncalls)"
fi

echo "tier-retired.bh-4572: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
