#!/bin/bash
# tests/blocked-resolver-profile.bh-5946-test.sh — BH-5946: the run profile
# (bin/lib/br/opt/profile.sh). Each run of bin/blocked-resolver.sh that had
# candidates writes ONE `prof:` line to logs/blocked-resolver.log, after the
# unchanged `tick:` line, and one per-row TSV under
# state/blocked-resolver/profile/.
#
# WHAT IS CLAIMED. The hub's `tick:` line says how long a run took
# (secs=2991..3498 on 2026-10-09) but not where the time went or what it read.
# The `prof:` line carries the stage seconds, the GitHub calls by endpoint
# shape, the D1 calls, the model calls, the memo hits and the unchanged skips,
# so a before/after can be read off the hub's own log.
#
# The REAL bin/blocked-resolver.sh runs over a scratch $HARNESS
# (tests/lib/br-repeat-cuts-fixture.sh). The counts are checked against what the
# gh stub, the jobs stub and the agent stub recorded in the same run.
#
# Run from anywhere: tests/blocked-resolver-profile.bh-5946-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
. "$(dirname "$0")/lib/br-repeat-cuts-fixture.sh" || exit 1
BRF_MODULES="profile"
brf_setup || { echo "fixture setup failed"; exit 1; }
[ -r "$DIR/bin/lib/br/opt/profile.sh" ] || bad "bin/lib/br/opt/profile.sh is missing"

# Three rows: #51 no-verdict (the re-review rung: one model call), #52 a hold
# the rung gate respects, #53 a HELD record re-read.
P1FIX() {
  brf_reset
  PRADD 51; PRADD 52; PRADD 53
  CROW 51 'no-verdict: the review lane answered nothing'
  CROW 52 'head-not-reapproved: BLOCK on the head'
  CROW 53 'head-not-reapproved: BLOCK on the head'
  HOLDCMT 52; HOLDCMT 53
  SEED tproj-TK-53 '{"outcome":"HELD"}'
}
TICKFIELDS() { grep ' tick: ' "$H/logs/blocked-resolver.log" | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z tick: //' \
                 | grep -oE '(^| )[a-z_]+=' | tr -d ' =' | tr '\n' ' '; }
MAIN_TICK_FIELDS="candidates retired carried mechanical families llm_rungs projects visited skipped rungs reason secs rebuilds budget_carry oldest_untouched "

# ===========================================================================
# P1 — exactly one prof: line, every field an integer.
# ===========================================================================
P1FIX; TICK
[ "$(grep -c ' prof: ' "$H/logs/blocked-resolver.log")" = 1 ] && ok || bad "P1: one run must write exactly one prof: line, got $(grep -c ' prof: ' "$H/logs/blocked-resolver.log"): $(tail -3 "$T/run.log")"
for f in secs discovery prepass order loop rows gh gh_rows search pulls issues raw d1 llm memo_hits unchanged; do
  v=$(PFIELD "$f")
  case "$v" in ''|*[!0-9]*) bad "P1: prof: field $f= must be an integer, got '$v' in '$(PROF)'" ;; *) ok ;; esac
done
PROF | grep -qE ' top=\[[^]]*\]$' && ok || bad "P1: the prof: line must end with top=[...], got '$(PROF)'"
PROF | grep -qE 'top=\[tproj/o-tproj-5[123]:[0-9]+s' && ok || bad "P1: top=[] must name the slowest rows as <p>/<rkey>:<secs>s, got '$(PROF)'"
# The prof: line comes after the tick: line, and the tick: line is the field
# list main writes.
[ "$(grep -nE ' (tick|prof): ' "$H/logs/blocked-resolver.log" | cut -d' ' -f3 | tr '\n' ' ')" = "tick: prof: " ] && ok \
  || bad "P1: the prof: line must follow the tick: line: $(grep -E ' (tick|prof): ' "$H/logs/blocked-resolver.log")"
[ "$(TICKFIELDS)" = "$MAIN_TICK_FIELDS" ] && ok || bad "P1: the tick: line must keep main's field list, got '$(TICKFIELDS)'"

# ===========================================================================
# P2 — the counts are the recorded calls of the same run.
# ===========================================================================
REST_REC=$(grep -c -- '^api -i -X ' "$T/gh.txt")
[ "$(PFIELD gh)" = "$REST_REC" ] && ok || bad "P2: gh= must equal the $REST_REC REST calls the stub recorded, got '$(PROF)'"
[ "$(PFIELD search)" = "$(grep -c -- '^api -i -X GET search/issues' "$T/gh.txt")" ] && ok || bad "P2: search= must equal the recorded searches, got '$(PROF)'"
[ "$(PFIELD pulls)" = "$(grep -cE -- '^api -i -X [A-Z]+ repos/o/tproj/pulls/[0-9]+( |$)' "$T/gh.txt")" ] && ok || bad "P2: pulls= must equal the recorded pulls/<n> calls, got '$(PROF)'"
[ "$(PFIELD llm)" = "$(grep -c . "$T/agent.txt")" ] && ok || bad "P2: llm= must equal the $(grep -c . "$T/agent.txt") model calls recorded, got '$(PROF)'"
[ "$(PFIELD llm)" -ge 1 ] && ok || bad "P2: the re-review rung must have made a model call: $(LOG | grep o-tproj-51 | tail -3)"
# The lane gate's liveness post and the knob read run at the top of the script,
# before the tick's ledger exists: they are the only D1 calls not counted.
D1_REC=$(grep '^_jobs_req ' "$T/jobs.txt" | grep -cvE '^_jobs_req (POST /api/lanes/liveness|GET /api/settings)$')
[ "$(PFIELD d1)" = "$D1_REC" ] && ok || bad "P2: d1= must equal the $D1_REC _jobs_req calls recorded after the start, got '$(PROF)': $(cat "$T/jobs.txt")"
[ "$(PFIELD d1)" -ge 1 ] && ok || bad "P2: the verdicts read must be counted, got '$(PROF)'"

# ===========================================================================
# P3 — one TSV line per row the loop dispatched; its GitHub column adds up.
# ===========================================================================
[ "$(PROWS | grep -c .)" = "$(PFIELD rows)" ] && ok || bad "P3: the TSV must have rows= lines, got $(PROWS | grep -c .) for '$(PROF)'"
[ "$(PROWS | grep -c .)" = 3 ] && ok || bad "P3: three rows were dispatched, the TSV has $(PROWS | grep -c .): $(PROWS)"
[ "$(PROWS | awk -F'\t' 'NF != 14' | grep -c .)" = 0 ] && ok || bad "P3: every TSV line has 14 columns: $(PROWS)"
[ "$(PROWS | awk -F'\t' '{ s += $7 } END { print s + 0 }')" = "$(PFIELD gh_rows)" ] && ok \
  || bad "P3: the TSV gh_total column must sum to gh_rows=, got $(PROWS | awk -F'\t' '{ s += $7 } END { print s + 0 }') for '$(PROF)'"
[ "$(PFIELD gh_rows)" -le "$(( $(PFIELD gh) + $(PFIELD raw) ))" ] && ok || bad "P3: gh_rows= cannot exceed gh= + raw=, got '$(PROF)'"
[ "$(PROWS | awk -F'\t' '$2 == "o-tproj-51" { print $12 }')" = "$(PFIELD llm)" ] && ok || bad "P3: the model call belongs to #51's row: $(PROWS)"

# ===========================================================================
# P4 — BR_PROFILE_KEEP=2 keeps the newest 2 TSV files.
# ===========================================================================
P1FIX; BRENV=(BR_PROFILE_KEEP=2); TICK; TICK; TICK
[ "$(ls -1 "$ST/profile/" 2>/dev/null | grep -c '\.tsv$')" = 2 ] && ok || bad "P4: BR_PROFILE_KEEP=2 must keep 2 files, got: $(ls -1 "$ST/profile/" 2>/dev/null | tr '\n' ' ')"
[ "$(grep -c ' prof: ' "$H/logs/blocked-resolver.log")" = 3 ] && ok || bad "P4: three runs write three prof: lines"

# ===========================================================================
# P5 — the kill switches: no prof: line, and the tick: line is main's.
# ===========================================================================
P1FIX; BRENV=(BR_OPT_OFF=profile); TICK
[ "$(grep -c ' prof: ' "$H/logs/blocked-resolver.log")" = 0 ] && ok || bad "P5: BR_OPT_OFF=profile must write no prof: line"
[ -d "$ST/profile" ] && bad "P5: BR_OPT_OFF=profile must write no TSV: $(ls -A "$ST/profile")" || ok
[ "$(TICKFIELDS)" = "$MAIN_TICK_FIELDS" ] && ok || bad "P5: the tick: line must keep main's field list, got '$(TICKFIELDS)'"
P1FIX; BRENV=(BR_PROFILE=0); TICK
[ "$(grep -c ' prof: ' "$H/logs/blocked-resolver.log")" = 0 ] && ok || bad "P5: BR_PROFILE=0 must write no prof: line"
P1FIX; : > "$H/flags/br-profile-off"; TICK
[ "$(grep -c ' prof: ' "$H/logs/blocked-resolver.log")" = 0 ] && ok || bad "P5: flags/br-profile-off must write no prof: line"

echo "blocked-resolver-profile: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
