#!/bin/bash
# tests/gh-rest-var.bh-1485-test.sh — BH-1485: GH_REST_STATUS and GH_REST_REASON
# are REAL in the caller's shell at every converted site.
#
# THE BUG. `bin/lib/gh-rest.sh` assigns the two variables in the shell that
# CALLS a helper, and its header says so: run the helper with `> file`, never
# inside `$( )`. Twenty-one lanes wrote `st=$(gh_rest_pr_state …)` anyway. The
# rc survived the subshell — every decision was right — and the status did not,
# so a 403, a 500 and a dead client all logged `HTTP 000`. BH-781 named this
# exact failure once already; it came back because the correct shape is four
# lines and the wrong one is eight characters.
#
# WHAT THIS SUITE PROVES, in the order it matters:
#   A. the `_var` variants keep gh-rest.sh's contract exactly — 0 / 44 / 75, the
#      same bytes on stdout the `$( )` produced, empty on every failure;
#   B. after one, the two variables hold what the LIBRARY set, in THIS shell —
#      403 rate-limit, 404, 000 network — which is the whole ticket;
#   C. the converted lane says it out loud: bin/lib/mc/rebase.sh's stack-parent
#      read logs `HTTP 403 rate-limit` where it logged `HTTP 000`;
#   D. the variants leave no temp file behind, on success or on refusal;
#   E. a name the caller must not be able to clobber is refused, not written.
#
# NOT GREPPED. Every row drives the real library (and, in C, the real
# bin/lib/mc/rebase.sh) against the shared stub `gh` from tests/lib/gh-rest-fx.sh,
# which answers HTTP STATUS LINES — a grep for `_var` in the source would pass on
# a lane that calls it and then reads a stale variable anyway.
#
# RED AT THE MERGE BASE: on main `gh_rest_pr_state_var` does not exist, so row A1
# fails with `command not found` before anything else runs.
#
#   HARNESS_TEST_SANDBOX=1 bash tests/gh-rest-var.bh-1485-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/gh-rest-fx.sh
. "$DIR/tests/lib/gh-rest-fx.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/h/bin/lib/mc" "$T/h/logs" "$T/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
ghfx_init
export HARNESS="$T/h" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH"
# shellcheck source=bin/lib/gh-rest.sh
. "$T/h/bin/lib/gh-rest.sh" || { echo "gh-rest.sh did not load"; exit 1; }
command -v gh_rest_pr_state_var >/dev/null 2>&1 && ok \
  || { bad "A0: gh-rest.sh must source gh-rest-var.sh from beside itself"; echo "gh-rest-var: PASS=$PASS FAIL=$FAIL"; exit 1; }

tmpcount() { find "$T/tmp" -type f 2>/dev/null | wc -l | tr -d ' '; }

# ════ A. THE CONTRACT IS gh-rest.sh's, UNCHANGED ════════════════════════════
ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls/1' 200 '{"state":"open","merged_at":null}'
ST=zzz; RC=0; gh_rest_pr_state_var ST o/r 1 || RC=$?
[ "$RC" = 0 ]    && ok || bad "A1: a 200 read must be rc 0 (got $RC)"
[ "$ST" = open ] && ok || bad "A1: the variant must assign the helper's answer (got '$ST')"

ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls/1' 200 '{"state":"closed","merged_at":"2026-09-18T00:00:00Z"}'
ST=zzz; gh_rest_pr_state_var ST o/r 1 || bad "A2: a merged PR must read rc 0"
[ "$ST" = merged ] && ok || bad "A2: merged_at set must answer merged (got '$ST')"

ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls/1' 404 '{"message":"Not Found"}'
ST=zzz; RC=0; gh_rest_pr_state_var ST o/r 1 || RC=$?
[ "$RC" = 44 ] && ok || bad "A3: a 404 must stay rc 44 ABSENT, never 75 (got $RC)"
[ -z "$ST" ]   && ok || bad "A3: a failed read must leave the variable EMPTY, as the capture did (got '$ST')"

ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls/1' 403 '{"message":"API rate limit exceeded"}'
ST=zzz; RC=0; gh_rest_pr_state_var ST o/r 1 || RC=$?
[ "$RC" = 75 ] && ok || bad "A4: a 403 must stay rc 75 UNVERIFIABLE (got $RC)"
[ -z "$ST" ]   && ok || bad "A4: a refused read must leave the variable empty (got '$ST')"

# The list and issue variants, and the generic one, on the same contract.
ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls*' 200 '[{"state":"open"}]'
LS=zzz; RC=0; gh_rest_pr_list_var LS o/r all 'o:ticket/x' 1 || RC=$?
[ "$RC" = 0 ] && [ "$(printf '%s' "$LS" | jq -r '.[0].state')" = open ] && ok \
  || bad "A5: gh_rest_pr_list_var must assign the list body (rc $RC, got '$LS')"
ghfx_routes_reset; ghfx_route GET 'repos/o/r/issues/7' 200 '{"state":"closed"}'
IS=zzz; RC=0; gh_rest_issue_state_var IS o/r 7 || RC=$?
[ "$RC" = 0 ] && [ "$IS" = closed ] && ok || bad "A6: gh_rest_issue_state_var (rc $RC, got '$IS')"
ghfx_routes_reset; ghfx_route GET 'repos/o/r/commits/abc/check-runs*' 200 '{"check_runs":[]}'
BD=zzz; RC=0; gh_rest_var BD GET 'repos/o/r/commits/abc/check-runs' -F per_page=100 || RC=$?
[ "$RC" = 0 ] && [ "$(printf '%s' "$BD" | jq -r '.check_runs|length')" = 0 ] && ok \
  || bad "A7: gh_rest_var must assign a GET body (rc $RC, got '$BD')"

# BYTE-FOR-BYTE WHAT THE CAPTURE PRODUCED. `$( )` strips trailing newlines and so
# must the variant, or a converted site's `[ "$x" = merged ]` stops matching.
ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls/1' 200 '{"state":"open","merged_at":null}'
ST=""; gh_rest_pr_state_var ST o/r 1
CAP=$(gh_rest_pr_state o/r 1 2>/dev/null)   # the OLD shape, for the comparison only
[ "$ST" = "$CAP" ] && ok || bad "A8: the variant must assign exactly what the capture did ('$ST' vs '$CAP')"

# ════ B. THE TWO VARIABLES ARE REAL IN *THIS* SHELL ═════════════════════════
ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls/1' 403 '{"message":"API rate limit exceeded for user ID 2220366"}'
GH_REST_STATUS=000; GH_REST_REASON=
ST=""; gh_rest_pr_state_var ST o/r 1 || true
[ "$GH_REST_STATUS" = 403 ]        && ok || bad "B1: an exhausted quota must leave GH_REST_STATUS=403 here (got $GH_REST_STATUS)"
[ "$GH_REST_REASON" = rate-limit ] && ok || bad "B1: …and GH_REST_REASON=rate-limit (got '$GH_REST_REASON')"

# The same read through the OLD shape, to show what was lost. This is the bug,
# asserted: the capture is a subshell and this shell keeps its stale 000.
GH_REST_STATUS=000; GH_REST_REASON=
OLD=$(gh_rest_pr_state o/r 1 2>/dev/null) || true
[ "$GH_REST_STATUS" = 000 ] && ok \
  || bad "B2: the premise is gone — a \$( ) capture no longer loses the status (got $GH_REST_STATUS)"

ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls/1' 404 '{"message":"Not Found"}'
GH_REST_STATUS=000; ST=""; gh_rest_pr_state_var ST o/r 1 || true
[ "$GH_REST_STATUS" = 404 ] && ok || bad "B3: a 404 must leave 404 in the caller's shell (got $GH_REST_STATUS)"

ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls/1' 500 '{"message":"boom"}'
GH_REST_STATUS=000; GH_REST_REASON=x; ST=""; gh_rest_pr_state_var ST o/r 1 || true
[ "$GH_REST_STATUS" = 500 ] && ok || bad "B4: a 5xx must name itself, not 000 (got $GH_REST_STATUS)"
[ -z "$GH_REST_REASON" ] && ok || bad "B4: an unclassified non-2xx carries no reason word (got '$GH_REST_REASON')"

# A dead client is the one case that IS 000 — and it says network, so it no
# longer collides with every refusal.
GHSAVE=$(cat "$T/fakebin/gh"); printf '#!/bin/bash\nexit 7\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
GH_REST_STATUS=200; GH_REST_REASON=; ST=""; gh_rest_pr_state_var ST o/r 1 || true
[ "$GH_REST_STATUS" = 000 ]     && ok || bad "B5: a dead client is HTTP 000 (got $GH_REST_STATUS)"
[ "$GH_REST_REASON" = network ] && ok || bad "B5: …and the reason is 'network' (got '$GH_REST_REASON')"
printf '%s' "$GHSAVE" > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"

# ════ C. THE CONVERTED LANE SAYS IT OUT LOUD ════════════════════════════════
# bin/lib/mc/rebase.sh's mc_stack_parent is the site the ticket opens with: it
# logged `HTTP 000` through an hour of a measurably exhausted hourly quota.
# The module is sourced the way production does it — through
# bin/lib/merge-conductor-lib.sh, which sets MC_H/MC_LOG/MC_STATE_DIR and pulls
# in bin/lib/mc/*.sh. Sourcing rebase.sh alone would die on an unbound variable
# under `set -u` and prove nothing about the lane.
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" "$T/h/bin/lib/"
cp "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/main-red-gate.sh" "$T/h/bin/lib/" 2>/dev/null || true
mkdir -p "$T/h/state" "$T/h/flags" "$T/h/locks"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh" || { bad "C: cannot source bin/lib/merge-conductor-lib.sh"; }
command -v mc_init >/dev/null 2>&1 && mc_init
MC_LOG="$T/h/logs/mc.log"; : > "$MC_LOG"
if command -v mc_stack_parent >/dev/null 2>&1; then
  ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls*' 403 '{"message":"API rate limit exceeded for user ID 2220366"}'
  : > "$MC_LOG"
  [ "$(mc_stack_parent o/r ticket/x)" = "$(printf 'NONE\t-')" ] && ok \
    || bad "C1: a refused parent read must still answer NONE — the decision does not change"
  grep -q 'HTTP 403 rate-limit' "$MC_LOG" && ok \
    || bad "C1: the log must read 'HTTP 403 rate-limit' (got: $(cat "$MC_LOG"))"
  grep -q 'HTTP 000' "$MC_LOG" && bad "C1: BH-781's bug, unchanged: a classified 403 logged as HTTP 000" || ok
  ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls*' 200 '[]'
  : > "$MC_LOG"
  [ "$(mc_stack_parent o/r ticket/x)" = "$(printf 'NONE\t-')" ] && ok || bad "C2: a real empty list answers NONE"
  grep -q 'UNVERIFIABLE' "$MC_LOG" && bad "C2: an empty list is a FACT and must not be logged as unverifiable" || ok
else
  bad "C: bin/lib/mc/rebase.sh did not define mc_stack_parent — the lane under test never loaded"
fi

# ════ D. NO TEMP FILE SURVIVES ══════════════════════════════════════════════
# The prescribed shape is mktemp + redirect + read + rm. A variant that leaks one
# per read fills /tmp on a box that reads every two minutes.
ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls/1' 200 '{"state":"open","merged_at":null}'
rm -rf "$T/tmp"; mkdir -p "$T/tmp"
ST=""; gh_rest_pr_state_var ST o/r 1
[ "$(tmpcount)" = 0 ] && ok || bad "D1: a clean read left $(tmpcount) temp file(s) under TMPDIR"
ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls/1' 403 '{"message":"API rate limit exceeded"}'
rm -rf "$T/tmp"; mkdir -p "$T/tmp"
ST=""; gh_rest_pr_state_var ST o/r 1 || true
[ "$(tmpcount)" = 0 ] && ok || bad "D2: a REFUSED read left $(tmpcount) temp file(s) under TMPDIR"

# ════ E. A NAME IT MUST NOT WRITE ═══════════════════════════════════════════
# `printf -v` would happily assign into this file's own locals and hand the
# caller a temp-file path where it asked for a PR state.
ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls/1' 200 '{"state":"open","merged_at":null}'
RC=0; gh_rest_pr_state_var _ghrv_t o/r 1 || RC=$?
[ "$RC" = 75 ] && ok || bad "E1: a reserved outvar must be refused as bad-args rc 75 (got $RC)"
RC=0; gh_rest_pr_state_var '1bad;name' o/r 1 || RC=$?
[ "$RC" = 75 ] && ok || bad "E2: a non-identifier outvar must be refused, never eval'd (got $RC)"
[ "$GH_REST_REASON" = bad-args ] && ok || bad "E2: …and say bad-args (got '$GH_REST_REASON')"
RC=0; gh_rest_var OUTV GET || RC=$?
[ "$RC" = 75 ] && ok || bad "E3: a helper called with no path must stay rc 75 (got $RC)"

echo "gh-rest-var.bh-1485: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
