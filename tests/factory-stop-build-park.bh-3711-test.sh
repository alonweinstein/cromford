#!/bin/bash
# tests/factory-stop-build-park.bh-3711-test.sh — BH-3711 (slice 4 of BH-3687):
# while settings row switch.factory-stop is on, a build parks at its next phase
# boundary and the two direct merge paths hold.
#
# Each production span is extracted VERBATIM by its markers and run against a
# scratch $HARNESS carrying the real bin/lib/factory-stop.sh, lane-switch.sh and
# lane-gate.sh plus a stub jobs worker (the stub shape of
# tests/factory-stop-lib.bh-3687-test.sh):
#   P1 `# >>> held issue skip` of bin/lib/rb/gates.sh (it ends in the queue
#      boundary's own HOLD_STAGE_CHECK call), row 1 -> RESULT
#      `BUILD_DEFERRED factory-stop at queue`, rc 3, FACTORY-STOP line;
#   P2 HOLD_STAGE_CHECK review -> the same at review;
#   P3 row 0 -> rc 0, no RESULT, to_build_hold still asked;
#   P4 no lib in the tree -> rc 0, no RESULT, one `lib not loaded` line;
#   M1 the tier-1 merge gate of bin/lib/rb/result.sh, row 1 -> HELD line,
#      PR_CREATED, zero `gh pr merge`;
#   M2 bin/review-prs.sh's merge_step, row 1 -> HELD line, MERGED=no, zero merges;
#   M3 row 0 -> both paths reach `gh pr merge` once;
#   M4 merge_retry seven ticks at row 1 -> merge_retries stays 0, no ALERT;
#   N1 row values `yes`, ` on`, `2`, empty -> no park, review-prs merges;
#   N2 look-alike keys and a pauses row what=builds -> no park, no hold;
#   N3 worker down with no cache -> no park, no hold; a day-old cached row 1
#      with the worker down -> parks and holds;
#   X  (D1) P1 against gates.sh with the FACTORY_STOP_CHECK call deleted, and
#      M2 against review-prs with the hold_factory_stop elif deleted: each red.
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

NOW=1758300000
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" "$H/tmp" "$T/fakebin"
cp "$DIR/bin/lib/factory-stop.sh" "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
# The tier-1 gate's own reads, as tests/conductor-owns-merges-test.sh carries them.
cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
printf 'p o/p - - 2 box-p\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"; : > "$H/env/p.env"
for s in flock sleep; do printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/$s"; chmod +x "$T/fakebin/$s"; done
for s in beat.sh lander.sh deploy-request.sh; do printf '#!/bin/bash\nexit 0\n' > "$H/bin/$s"; chmod +x "$H/bin/$s"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\n' "$H" > "$H/bin/alert-line.sh"; chmod +x "$H/bin/alert-line.sh"

# The stub worker: /api/settings answers $ROWS_FILE, the single-key GET answers
# $ONE_FILE, /api/pauses answers a builds pause; UNREACHABLE is an outage.
cat > "$H/bin/jobs-client.sh" <<'SH'
_jobs_req() {
  [ -n "${UNREACHABLE:-}" ] && return 1
  case "$2" in
    /api/settings) printf '{"settings":%s}' "$(cat "$ROWS_FILE" 2>/dev/null || echo '[]')" ;;
    /api/settings/switch.factory-stop) [ -r "$ONE_FILE" ] || return 1; cat "$ONE_FILE" ;;
    /api/pauses*) printf '{"pauses":[{"what":"builds","active":1}]}' ;;
    *) return 1 ;;
  esac
}
SH

# gh: `pr merge` lands in its own sink; a merged PR reads back MERGED.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merges"; exit 0 ;;
  *"api repos/"*"/rulesets"*) : ;;
  *"--json state,isInMergeQueue"*) echo "MERGED false" ;;
  *"--json state"*) [ -s "$T/merges" ] && echo MERGED || echo OPEN ;;
  *"--json mergeCommit"*) echo deadbeefcafe ;;
  *"api -i -X GET repos/o/p/pulls/"*)
    if [ -s "$T/merges" ]; then restpr MERGED headsha ticket/x main "" MERGEABLE CLEAN operator deadbeefcafe
    else restpr OPEN headsha ticket/x main "" MERGEABLE CLEAN operator; fi ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

rows() {
  local out='[]' kv
  for kv in "$@"; do
    out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"api"}]')
  done
  printf '%s' "$out" > "$T/rows.json"
}
reset() {
  scratch_rm "$H/state/lane-gate"; scratch_rm "$H/logs/lane-gate.log"; scratch_rm "$H/builds/gate"
  rm -f "$H/state/settings-cache.json" "$H/flags"/* "$T/rows.json" "$T/one.json" "$T/merges" "$T/RESULT"
  : > "$H/logs/ALERTS.log"; UNREACHABLE=""
}
sw() { reset; rows "switch.factory-stop=$1"; }
# Every child gets the worker environment the lib reads. BUILDER_NO_MERGE is a
# Fly builder's own setting and would send the tier-1 gate past the merge.
fsenv() {
  env -u BUILDER_NO_MERGE PATH="$T/fakebin:$PATH" HARNESS="$H" LANE_GATE_NOW="$NOW" ROWS_FILE="$T/rows.json" ONE_FILE="$T/one.json" \
      UNREACHABLE="$UNREACHABLE" JOBS_BOX=box-p JOBS_URL=http://stub.invalid "$@"
}
merges() { [ -f "$T/merges" ] && grep -c 'pr merge' "$T/merges" || echo 0; }

# ════════════════════════════════════════════════════════════════════════════
# P. The phase-boundary park: `# >>> held issue skip` of the flattened pipeline.
# ════════════════════════════════════════════════════════════════════════════
awk '/^# >>> held issue skip/{f=1;next} /^# <<< held issue skip/{exit} f' "$RB_ALL" > "$T/held.sh"
grep -q '^HOLD_STAGE_CHECK queue$' "$T/held.sh" && ok || bad "P0: the held span must end in the queue boundary's HOLD_STAGE_CHECK call"
# park <held-span> <stage> — the span (which runs the queue check itself); for
# any other stage the call a later boundary makes. Prints `rc=<n> after=<0|1>`.
park() {
  rm -rf "$T/build"; mkdir -p "$T/build"; : > "$T/tbh.calls"
  ( cd "$T" && fsenv PROJECT=p TICKET=3711 KEY=BH-3711 BUILD="$T/build" TBH="$T/tbh.calls" \
      bash -c 'STAMP(){ printf TS; }; RESULT(){ printf "%s\n" "$*" > "$BUILD/RESULT"; }
               to_build_hold(){ echo x >> "$TBH"; return 1; }
               grep -v "^HOLD_STAGE_CHECK queue\$" "$1" > "$1.fns"
               if [ "$2" = queue ]; then . "$1"; else . "$1.fns"; HOLD_STAGE_CHECK "$2"; fi
               echo AFTER >> "$BUILD/after"' _ "$1" "$2" >/dev/null 2>&1 )
  echo "rc=$? after=$([ -f "$T/build/after" ] && echo 1 || echo 0)"
}
result() { head -1 "$T/build/RESULT" 2>/dev/null; }
plog()   { cat "$T/build/pipeline.log" 2>/dev/null; }
# p_parks <held-span> <stage> — rc 0 when the build parked exactly as the ticket says.
p_parks() {
  local o; o=$(park "$1" "$2")
  [ "$o" = "rc=3 after=0" ] && [[ "$(result)" == "BUILD_DEFERRED factory-stop at $2 — bin/factory-stop.sh off resumes; the next tick re-offers BH-3711" ]] \
    && grep -q "TS \[p/BH-3711\] FACTORY-STOP at $2: switch.factory-stop is on — parking" "$T/build/pipeline.log" 2>/dev/null
}
p_builds() { # rc 0 when the build went on: no park, no RESULT
  local o; o=$(park "$1" "$2"); [ "$o" = "rc=0 after=1" ] && [ ! -f "$T/build/RESULT" ]
}

sw 1
p_parks "$T/held.sh" queue && ok || bad "P1: row 1 must park at queue (got $(park "$T/held.sh" queue), RESULT '$(result)', log: $(plog))"
sw 1
p_parks "$T/held.sh" review && ok || bad "P2: row 1 must park at review (got $(park "$T/held.sh" review), RESULT '$(result)', log: $(plog))"
sw 0
p_builds "$T/held.sh" queue && ok || bad "P3: row 0 must build on (got $(park "$T/held.sh" queue), RESULT '$(result)')"
[ -s "$T/tbh.calls" ] && ok || bad "P3: with the switch off the ticket hold is still asked"
sw 0
p_builds "$T/held.sh" execute && ok || bad "P3: row 0 builds on at execute too"

mv "$H/bin/lib/factory-stop.sh" "$T/factory-stop.sh.away"
sw 1
p_builds "$T/held.sh" queue && ok || bad "P4: no lib must build as today (got $(park "$T/held.sh" queue), RESULT '$(result)')"
grep -q 'factory-stop lib not loaded at queue — building as today' "$T/build/pipeline.log" 2>/dev/null \
  && ok || bad "P4: a missing lib says so once in pipeline.log (log: $(plog))"
mv "$T/factory-stop.sh.away" "$H/bin/lib/factory-stop.sh"

# ════════════════════════════════════════════════════════════════════════════
# M1/M3. The tier-1 merge gate of bin/lib/rb/result.sh.
# ════════════════════════════════════════════════════════════════════════════
awk '/^# >>> tier-1 merge gate/{f=1;next} /^# <<< tier-1 merge gate/{exit} f' "$RB_ALL" > "$T/gate.sh"
[ -s "$T/gate.sh" ] && ok || bad "M0: could not extract the tier-1 merge gate"
run_gate() { # prints the RESULT line
  mkdir -p "$H/builds/gate"
  printf 'VERDICT: APPROVE\n' > "$H/builds/gate/review.md"; printf 'plan\n' > "$H/builds/gate/plan.md"
  ( cd "$T" && fsenv BUILD="$H/builds/gate" ALERTS="$H/logs/ALERTS.log" \
      PROJECT=p KEY=TK-9 SLUG=o/p TIER=1 PR_URL=https://github.com/o/p/pull/9 \
      QA_NOTE="" MIG_NOTE="" REBASE_NOTE="" \
      bash -c 'set -uo pipefail
        STAMP() { echo TS; }
        RESULT() { echo "$*" > '"$T"'/RESULT; }
        BB() { :; }
        CLOSE_ISSUE_AFTER_MERGE() { :; }
        . "$0"' "$T/gate.sh" >/dev/null 2>&1 ) || true
  cat "$T/RESULT" 2>/dev/null
}
t1_holds() { # rc 0 when the gate held: HELD line, PR_CREATED, no merge
  local out; out=$(run_gate)
  [ "$(merges)" = 0 ] && grep -q '^PR_CREATED https://github.com/o/p/pull/9' <<<"$out" \
    && grep -q 'TS \[p/TK-9\] tier-1 merge HELD by factory-stop — the PR stays open and the conductor merges it after bin/factory-stop.sh off' "$H/builds/gate/pipeline.log" 2>/dev/null
}
t1_merges() { local out; out=$(run_gate); [ "$(merges)" = 1 ] && grep -q '^PR_MERGED' <<<"$out"; }
sw 1
t1_holds && ok || bad "M1: row 1 must hold the tier-1 merge (merges=$(merges), RESULT '$(cat "$T/RESULT" 2>/dev/null)', log: $(cat "$H/builds/gate/pipeline.log" 2>/dev/null))"
sw 0
t1_merges && ok || bad "M3: row 0 — the tier-1 gate merges as today (merges=$(merges), RESULT '$(cat "$T/RESULT" 2>/dev/null)')"
grep -q 'HELD by factory-stop' "$H/builds/gate/pipeline.log" 2>/dev/null && bad "M3: no HELD line with the switch off" || ok

# ════════════════════════════════════════════════════════════════════════════
# M2/M3/M4. bin/review-prs.sh's merge_step and merge_retry.
# ════════════════════════════════════════════════════════════════════════════
awk '/^# >>> review-prs merge/{f=1;next} /^# <<< review-prs merge/{exit} f' "$DIR/bin/review-prs.sh" > "$T/rp.sh"
awk '/^# >>> review-prs merge-retry/{f=1;next} /^# <<< review-prs merge-retry/{exit} f' "$DIR/bin/review-prs.sh" > "$T/rpr.sh"
[ -s "$T/rp.sh" ] && [ -s "$T/rpr.sh" ] && ok || bad "M0: could not extract the review-prs merge blocks"
RPLOG="$T/rp.log"; RPSTATE="$T/rp-state.json"
RP_STUBS='STAMP() { printf TS; }
  rp_prov_is_claude() { return 0; }
  mc_queue_conductor_only() { return 1; }
  mc_pr_queued() { return 1; }
  gh_rest_var() { return 1; }
  mc_pr_view() { case "$2" in
      .base.ref) echo main ;;
      .STATE) [ -s "$MERGES" ] && echo MERGED || echo OPEN ;;
      *) echo "OPEN CLEAN" ;; esac; }
  rp_state_write() { jq "$@" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"; }'
rp() { # rp <rp-block> — merge_step on #41; prints MERGED=<v>
  : > "$RPLOG"
  ( cd "$T" && fsenv SLUG=o/p PROJECT=p LOG="$RPLOG" STATE="$RPSTATE" MERGES="$T/merges" \
      bash -c 'set -uo pipefail
        eval "$1"
        . "$0"
        MERGED=
        merge_step 41 aaaaaaaa1111 claude
        printf "MERGED=%s\n" "$MERGED"' "$1" "$RP_STUBS" 2>"$T/rp.err" )
}
rp_holds() { # rc 0 when merge_step held: HELD line, MERGED=no, no merge
  local out; out=$(rp "$1")
  [ "$out" = "MERGED=no" ] && [ "$(merges)" = 0 ] \
    && grep -q '^TS \[p\] #41 APPROVE left unmerged, HELD by factory-stop: switch.factory-stop is on — it merges on a later tick after bin/factory-stop.sh off$' "$RPLOG"
}
rp_merges() { local out; out=$(rp "$1"); [ "$out" = "MERGED=yes" ] && [ "$(merges)" = 1 ]; }
sw 1
rp_holds "$T/rp.sh" && ok || bad "M2: row 1 must hold merge_step (got '$(rp "$T/rp.sh")', merges=$(merges), log: $(cat "$RPLOG"), stderr: $(cat "$T/rp.err"))"
sw 0
rp_merges "$T/rp.sh" && ok || bad "M3: row 0 — merge_step merges as today (got '$(rp "$T/rp.sh")', merges=$(merges), log: $(cat "$RPLOG"), stderr: $(cat "$T/rp.err"))"

rpr() { # rpr <ticks> — merge_retry on #41
  : > "$RPLOG"
  ( cd "$T" && fsenv SLUG=o/p PROJECT=p LOG="$RPLOG" STATE="$RPSTATE" MERGES="$T/merges" \
      bash -c 'set -uo pipefail
        eval "$3"
        . "$1"
        . "$0"
        i=0; while [ "$i" -lt "$2" ]; do MERGED=; merge_retry 41 aaaaaaaa1111; i=$((i+1)); done' \
        "$T/rpr.sh" "$T/rp.sh" "$1" "$RP_STUBS" 2>"$T/rpr.err" )
}
sw 1
printf '{"41":{"verdict":"APPROVE","served":"claude","merge_retries":0}}\n' > "$RPSTATE"
rpr 7
eq "M4: seven stopped ticks spend no retry budget" "$(jq -r '.["41"].merge_retries' "$RPSTATE")" "0"
eq "M4: no merge while stopped" "$(merges)" "0"
[ -s "$H/logs/ALERTS.log" ] && bad "M4: a stopped tick is not a failed attempt — no ALERT ($(cat "$H/logs/ALERTS.log"))" || ok
sw 0
printf '{"41":{"verdict":"APPROVE","served":"claude","merge_retries":0}}\n' > "$RPSTATE"
rpr 1
eq "M4: switch off — the same APPROVE is retried and merges" "$(merges)" "1"

# ════════════════════════════════════════════════════════════════════════════
# N. Nothing but the row stops the factory; a stale cached stop still does.
# ════════════════════════════════════════════════════════════════════════════
for v in yes ' on' 2 ''; do
  sw "$v"; p_builds "$T/held.sh" queue && ok || bad "N1: value '$v' must not park (got $(park "$T/held.sh" queue))"
  sw "$v"; rp_merges "$T/rp.sh" && ok || bad "N1: value '$v' must not hold review-prs (log: $(cat "$RPLOG"))"
done
for kv in switch.factory-stopped=1 switch.factory-stop-x=1; do
  reset; rows "$kv"; p_builds "$T/held.sh" queue && ok || bad "N2: look-alike $kv must not park"
  reset; rows "$kv"; rp_merges "$T/rp.sh" && ok || bad "N2: look-alike $kv must not hold review-prs"
done
# The stub's /api/pauses always answers a live builds pause: a pause is not the switch.
reset; rows; p_builds "$T/held.sh" queue && ok || bad "N2: a pauses row what=builds must not park"
reset; UNREACHABLE=1
p_builds "$T/held.sh" queue && ok || bad "N3: worker down, no cache — builds as today"
reset; UNREACHABLE=1
rp_merges "$T/rp.sh" && ok || bad "N3: worker down, no cache — review-prs merges as today"
stale() { reset; UNREACHABLE=1
  jq -nc --argjson fa $((NOW-86400)) '{fetched_at:$fa,values:{"switch.factory-stop":"1"},seeded:{}}' > "$H/state/settings-cache.json"; }
stale; p_parks "$T/held.sh" queue && ok || bad "N3: a day-old cached row 1 with the worker down must park (got $(park "$T/held.sh" queue))"
stale; rp_holds "$T/rp.sh" && ok || bad "N3: a day-old cached row 1 with the worker down must hold review-prs"

# ════════════════════════════════════════════════════════════════════════════
# X. (D1) The suite goes red when either production call site is removed.
# ════════════════════════════════════════════════════════════════════════════
grep -v '^ *FACTORY_STOP_CHECK "\$1"$' "$T/held.sh" > "$T/held-mut.sh"
if cmp -s "$T/held.sh" "$T/held-mut.sh"; then bad "X1: the FACTORY_STOP_CHECK call is not in the held span"
else sw 1; p_parks "$T/held-mut.sh" queue && bad "X1: P1 stays green with the FACTORY_STOP_CHECK call deleted" || ok; fi
grep -v 'elif hold_factory_stop "\$NUM"' "$T/rp.sh" > "$T/rp-mut.sh"
if cmp -s "$T/rp.sh" "$T/rp-mut.sh"; then bad "X2: the hold_factory_stop elif is not in merge_step"
else sw 1; rp_holds "$T/rp-mut.sh" && bad "X2: M2 stays green with the hold_factory_stop elif deleted" || ok; fi

echo "factory-stop-build-park.bh-3711-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
