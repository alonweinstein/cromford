#!/bin/bash
# tests/lead-enqueue-traced-wait.bh-5795-test.sh — BH-5795: the lead-review
# enqueue does not ask for a review of a head CI never tested.
#
# WHY. 22 review BLOCKs (#4189..#5395) said "no suite ran on this head": a PR
# stacked on a ticket/** base skipped every `Tests, traced` shard, and a DIRTY
# head ran no CI at all. A review requested there can only say so. Now
# bin/lead-review-enqueue.sh holds such a head, logs why, and asks again on a
# later tick. A PR on the default branch keeps its skipped shards BY DESIGN
# (the merge-queue batch tests it), so it is requested as before.
#
#   T1  stacked base, every traced job skipped: no request, the reason logged,
#       skipped_traced=1
#   T2  stacked base, a traced job ran: requested
#   T3  stacked base, no traced job on the head at all: no request
#   T4  a DIRTY head on main: no request, DIRTY logged
#   T5  base main, traced jobs skipped (an ordinary PR): requested
#   T6  LEAD_REVIEW_TRACED_WAIT=0: T1's head is requested
#   T7  stacked base, the check runs unreadable: no request
#   D1  the first held tick dispatches harness-ci.yml with scope=impact on the
#       head branch, once; a second held tick dispatches nothing more
#   D2  a dispatch that fails is logged and the head stays held (bounded)
#   B1  held past LEAD_REVIEW_TRACED_MAX_WAIT_MIN (default 30): requested,
#       scope note `tests did not run`
#   B2  the knob: 5 minutes, a 6-minute hold is requested; 4 minutes is held
#   T8  stacked base, a traced job still QUEUED (conclusion null): held, not
#       counted as ran (lead/Fable review of #5805)
#   T9  a DIRTY head whose traced job completed green (the dispatched run):
#       released and requested
#   D3  LEAD_REVIEW_TRACED_MAX_WAIT_MIN=0: requested at once, nothing dispatched
#   D4  a pull_request run of harness-ci.yml already exists on the head: no
#       second run is dispatched (each tree is tested once)
#   R1  LEAD_REVIEW_REBASE_HOLD=1 (BH-5796): a DIRTY head is the rebase hold's;
#       the traced hold neither dispatches nor counts it
#   (every other case runs with LEAD_REVIEW_REBASE_HOLD=0, to judge this hold alone)
#   D4b a COMPLETED pull_request run whose traced shards all skipped (a DIRTY
#       head after main moved, or a stacked base cut before this merge): it is
#       not the test, so the run is dispatched (lead review of 973ce2e9)
#
# The script runs WHOLE (`tick`) against a scratch harness: its sourced closure
# (bin/lead-review.sh included), and stubs for curl (the jobs worker) and gh
# (REST: the PR list, the PR, .mergify.yml, the check runs, the compare). The
# builder's APPROVE is on the head, so only the new gate decides.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-enqueue-traced-wait.bh-5795-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
unset LEAD_REVIEW_REQUIRE_BUILDER_APPROVE LEAD_REVIEW_TRACED_WAIT LEAD_REVIEW_TRACED_JOB

HEADSHA=0123456789abcdef0123456789abcdef01234567
H12=${HEADSHA:0:12}
Q="$T/hq"; mkdir -p "$Q/bin/lib/jobs" "$Q/state" "$Q/logs" "$Q/catalog/lanes.d" "$T/cfg" "$T/qrepos" "$T/log" "$T/qbin"
cat > "$Q/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/post"
exit 0
EOF
cat > "$Q/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/qalerts"
EOF
chmod +x "$Q/bin/lead-verdict.sh" "$Q/bin/lane-alert.sh"
scratch_install_closure bin/lead-review-enqueue.sh "$Q" >/dev/null || bad "closure of bin/lead-review-enqueue.sh"
scratch_install_closure bin/jobs-client.sh "$Q" >/dev/null || bad "closure of bin/jobs-client.sh"
scratch_install_closure bin/lead-review.sh "$Q" >/dev/null || bad "closure of bin/lead-review.sh"
SRC=$(cd "$(dirname "$0")/.." && pwd)
cp "$SRC/catalog/lanes.d/_lib.json" "$Q/catalog/lanes.d/"
printf 'lead-fixture-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'demo-os example-org/demo-os https://192.0.2.10 /api 3 box-hub\n' > "$Q/fleet.conf"
printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success = "CI"\n' | base64 | tr -d '\n' > "$T/mergify.b64"

# The jobs worker: the builder's APPROVE on the head, no standing verdict, and
# lead-review requests recorded in log/created.
cat > "$T/qbin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d|--data) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-fixture-token' <<<"\$hdrs" && lead=1
p="\${url#https://192.0.2.20}"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/verdict?pr="*)
    jq -nc --arg s "$HEADSHA" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:\$s,
      artifacts:[{artifact_kind:"verdict", detail:({tier:"2", reviewed_sha:\$s, settled:true}|tojson)}]}' > "$T/jvout"
    out=\$(cat "$T/jvout") ;;
  "GET /api/verdicts?"*standing_only=1*) out='{"standing":null,"rows":[],"truncated":false}' ;;
  "GET /api/verdicts?"*) out='{"rows":[],"truncated":false}' ;;
  "GET /api/settings/"*) code=404; out='{"error":"no such setting"}' ;;
  "POST /api/lead-reviews")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else printf '%s\n' "\$body" >> "$T/log/created"; code=201; out=\$(jq -c '{request:(. + {id:"lr-9", status:"requested"})}' <<<"\$body"); fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
# GitHub: the base and mergeable_state come from files; the check runs from
# $T/checks.json (absent = the read fails).
cat > "$T/qbin/gh" <<EOF
#!/bin/bash
BASE=\$(cat "$T/base"); MS=\$(cat "$T/ms")
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/demo-os/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg h "$HEADSHA" --arg b "\$BASE" '[{number:41, html_url:"https://github.com/example-org/demo-os/pull/41", title:"t", draft:false, state:"open",
      user:{login:"operator",type:"User"}, head:{sha:\$h,ref:"ticket/bh-41"}, base:{ref:\$b}}]' ;;
  *"-X GET repos/example-org/demo-os/pulls/41"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "$HEADSHA" --arg b "\$BASE" --arg ms "\$MS" '{head:{sha:\$s, ref:"ticket/bh-41"}, base:{ref:\$b, repo:{default_branch:"main"}},
      mergeable_state:\$ms, user:{login:"operator"}}' ;;
  *"-X GET repos/example-org/demo-os/contents/.mergify.yml"*)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg c "\$(cat "$T/mergify.b64")" '{content:\$c, encoding:"base64"}' ;;
  *"-X GET repos/example-org/demo-os/commits/"*"/check-runs"*)
    echo x >> "$T/log/ciread"
    [ -f "$T/checks.json" ] || { printf 'HTTP/2 502\r\n\r\n{"message":"fixture: unreadable"}\n'; exit 1; }
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/checks.json" ;;
  *"-X POST repos/example-org/demo-os/actions/workflows/"*"/dispatches"*)
    printf '%s\n' "\$*" >> "$T/log/dispatch"
    if [ -f "$T/dispatch-fails" ]; then printf 'HTTP/2 404\r\n\r\n{"message":"fixture: Not Found"}\n'; exit 1; fi
    printf 'HTTP/2 204\r\n\r\n' ;;
  *"-X GET repos/example-org/demo-os/actions/runs?"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/prruns.json" 2>/dev/null || echo '{"total_count":0,"workflow_runs":[]}' ;;
  *"-X GET repos/example-org/demo-os/compare/"*)
    printf 'HTTP/2 200\r\n\r\n{"total_commits":1,"commits":[{"parents":[{"sha":"p"}],"commit":{"message":"feat: a change"}}],"files":[]}\n' ;;
esac
exit 0
EOF
chmod +x "$T/qbin/curl" "$T/qbin/gh"

# checks <traced conclusion: skipped|success|none|queued> — CI green, plus the traced shard
checks() {
  jq -nc --arg h "$HEADSHA" --arg t "$1" '[{name:"CI", head_sha:$h, status:"completed", conclusion:"success", app:{slug:"github-actions"}}]
    + (if $t == "none" then [] elif $t == "queued" then [{name:"Tests, traced (shard 0/1)", head_sha:$h,
       status:"queued", conclusion:null, app:{slug:"github-actions"}}] else [{name:"Tests, traced (shard ${{ matrix.shard }}/${{ needs.plan.outputs.n }})", head_sha:$h,
       status:"completed", conclusion:$t, app:{slug:"github-actions"}}] end)
    | {total_count:length, check_runs:.}' > "$T/checks.json"
}
QLOG="$Q/logs/lead-review-enqueue.log"
reset() { # reset <base> <mergeable_state>
  rm -f "$T/log"/* "$T/checks.json" "$T/dispatch-fails" "$T/prruns.json" "$QLOG"
  scratch_rm "$Q/state"; mkdir -p "$Q/state"; echo box-hub > "$Q/state/box-name"
  echo "$1" > "$T/base"; echo "$2" > "$T/ms"
}
tick() {
  ( cd "$T" && env PATH="$T/qbin:$PATH" HARNESS="$Q" REPOS_ROOT="$T/qrepos" FLEET_CONF="$Q/fleet.conf" \
      LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" LEAD_REVIEW_AUTO_REPOS=example-org/demo-os \
      LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 JOBS_URL=https://192.0.2.20 \
      HARNESS_SECRET=fixture-secret JOBS_RETRIES=0 GH_ETAG=0 LEAD_REVIEW_REBASE_HOLD=0 "$@" \
      bash "$Q/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; RC=$?
}
dispatches() { [ -f "$T/log/dispatch" ] && wc -l < "$T/log/dispatch" | tr -d ' ' || echo 0; }
# aged <minutes> — the hold marker for the head, started that long ago, dispatched.
aged() { printf '%s\ndispatch ok harness-ci.yml ticket/bh-41\n' "$(( $(date +%s) - $1 * 60 ))" > "$Q/state/lead-review-enqueue/traced-example-org_demo-os-41-$H12"; }
created() { [ -f "$T/log/created" ] && wc -l < "$T/log/created" | tr -d ' ' || echo 0; }
summ() { grep ' tick repos=' "$QLOG" 2>/dev/null | tail -1; }
hasw() { summ | grep -qw -- "$1"; }

# ── T1: stacked base, every traced job skipped: held, said, counted ──
reset ticket/bh-40 clean; checks skipped; tick
[ "$RC" -eq 0 ] && ok || bad "T1 rc=$RC out=$(cat "$T/out")"
[ "$(created)" = 0 ] && ok || bad "T1 a head whose traced jobs were all skipped was requested: $(cat "$T/log/created")"
grep -q "@$H12: .*Tests, traced.*skipped" "$QLOG" && ok || bad "T1 no line naming the skipped traced jobs: $(tail -4 "$QLOG")"
hasw skipped_traced=1 && hasw requested=0 && ok || bad "T1 summary: $(summ)"

# ── T2: stacked base, a traced job ran: requested ──
reset ticket/bh-40 clean; checks success; tick
[ "$(created)" = 1 ] && ok || bad "T2 a stacked head with a traced run was not requested: $(summ) $(tail -4 "$QLOG")"
hasw skipped_traced=0 && ok || bad "T2 summary: $(summ)"

# ── T3: stacked base, no traced job at all: held ──
reset ticket/bh-40 clean; checks none; tick
[ "$(created)" = 0 ] && ok || bad "T3 a head with no traced job was requested"
grep -q "@$H12: .*no 'Tests, traced' job" "$QLOG" && ok || bad "T3 no line naming the missing traced job: $(tail -4 "$QLOG")"
hasw skipped_traced=1 && ok || bad "T3 summary: $(summ)"

# ── T4: a DIRTY head on main: held (its check runs are read: the dispatched run would release it) ──
reset main dirty; checks skipped; tick
[ "$(created)" = 0 ] && ok || bad "T4 a DIRTY head was requested"
grep -q "@$H12: .*DIRTY" "$QLOG" && ok || bad "T4 no DIRTY line: $(tail -4 "$QLOG")"
hasw skipped_traced=1 && ok || bad "T4 summary: $(summ)"

# ── T5: base main, traced skipped (an ordinary PR): requested as before ──
reset main clean; checks skipped; tick
[ "$(created)" = 1 ] && ok || bad "T5 an ordinary PR on main must still be requested (the queue tests it): $(summ) $(tail -4 "$QLOG")"
[ ! -f "$T/log/ciread" ] && ok || bad "T5 an approved head on main must cost no check-run read"

# ── T6: the knob off: T1's head is requested ──
reset ticket/bh-40 clean; checks skipped; tick LEAD_REVIEW_TRACED_WAIT=0
[ "$(created)" = 1 ] && ok || bad "T6 LEAD_REVIEW_TRACED_WAIT=0 must request as before: $(summ)"

# ── T7: stacked base, check runs unreadable: held ──
reset ticket/bh-40 clean; tick
[ "$(created)" = 0 ] && ok || bad "T7 an unreadable check-run list was read as go"
grep -q "@$H12: .*unreadable" "$QLOG" && ok || bad "T7 no unreadable line: $(tail -4 "$QLOG")"

# ── D1: the first held tick starts a real run, once ──
reset ticket/bh-40 clean; checks skipped; tick
[ "$(dispatches)" = 1 ] && ok || bad "D1 want one dispatch on the first held tick, got $(dispatches)"
grep -q 'actions/workflows/harness-ci.yml/dispatches.*ref=ticket/bh-41.*inputs\[scope\]=impact' "$T/log/dispatch" 2>/dev/null && ok \
  || bad "D1 the dispatch must be harness-ci.yml, ref=the head branch, scope=impact: $(cat "$T/log/dispatch" 2>/dev/null)"
tick
[ "$(dispatches)" = 1 ] && [ "$(created)" = 0 ] && ok || bad "D1 a second held tick must not dispatch again or request (dispatches=$(dispatches) created=$(created))"
hasw traced_dispatched=0 && hasw skipped_traced=1 && ok || bad "D1 second-tick summary: $(summ)"

# ── D2: a failed dispatch is logged, the head stays held ──
reset ticket/bh-40 clean; checks skipped; : > "$T/dispatch-fails"; tick
[ "$(created)" = 0 ] && ok || bad "D2 a failed dispatch must not request at once"
grep -q "@$H12: dispatch of harness-ci.yml scope=impact on ticket/bh-41 failed" "$QLOG" && ok || bad "D2 no failed-dispatch line: $(tail -4 "$QLOG")"

# ── B1: held past the default 30 minutes: requested, with the note ──
reset ticket/bh-40 clean; checks skipped; mkdir -p "$Q/state/lead-review-enqueue"; aged 31; tick
[ "$(created)" = 1 ] && ok || bad "B1 a head held 31m must be requested anyway: $(summ) $(tail -4 "$QLOG")"
jq -r .scope_notes "$T/log/created" 2>/dev/null | grep -q 'tests did not run' && ok || bad "B1 the scope note must say tests did not run: $(cat "$T/log/created" 2>/dev/null)"
[ "$(dispatches)" = 0 ] && ok || bad "B1 an already-dispatched head must not dispatch again"
hasw traced_bound=1 && ok || bad "B1 summary: $(summ)"
reset ticket/bh-40 clean; checks skipped; mkdir -p "$Q/state/lead-review-enqueue"; aged 29; tick
[ "$(created)" = 0 ] && ok || bad "B1 a head held 29m must still wait"

# ── B2: the knob sets the bound ──
reset ticket/bh-40 clean; checks skipped; mkdir -p "$Q/state/lead-review-enqueue"; aged 6; tick LEAD_REVIEW_TRACED_MAX_WAIT_MIN=5
[ "$(created)" = 1 ] && ok || bad "B2 LEAD_REVIEW_TRACED_MAX_WAIT_MIN=5: a 6m hold must be requested"
reset ticket/bh-40 clean; checks skipped; mkdir -p "$Q/state/lead-review-enqueue"; aged 4; tick LEAD_REVIEW_TRACED_MAX_WAIT_MIN=5
[ "$(created)" = 0 ] && ok || bad "B2 LEAD_REVIEW_TRACED_MAX_WAIT_MIN=5: a 4m hold must wait"

# ── T8: a queued traced job is not a run yet: held ──
reset ticket/bh-40 clean; checks queued; tick
[ "$(created)" = 0 ] && ok || bad "T8 a head whose traced job is still queued was requested"
grep -q "@$H12: .*still queued or running" "$QLOG" && ok || bad "T8 no still-running line: $(tail -3 "$QLOG")"

# ── T9: a DIRTY head whose traced job completed green: released ──
reset main dirty; checks success; tick
[ "$(created)" = 1 ] && ok || bad "T9 a DIRTY head with a completed traced run must be requested: $(summ) $(tail -3 "$QLOG")"

# ── D3: the bound 0: requested at once, nothing dispatched ──
reset ticket/bh-40 clean; checks skipped; tick LEAD_REVIEW_TRACED_MAX_WAIT_MIN=0
[ "$(created)" = 1 ] && [ "$(dispatches)" = 0 ] && ok || bad "D3 bound 0: want a request and no dispatch (created=$(created) dispatches=$(dispatches))"

# ── D4: a pull_request run exists on the head: no second run ──
reset ticket/bh-40 clean; checks none
printf '{"total_count":1,"workflow_runs":[{"path":".github/workflows/harness-ci.yml","event":"pull_request","status":"queued"}]}' > "$T/prruns.json"
tick
[ "$(dispatches)" = 0 ] && [ "$(created)" = 0 ] && ok || bad "D4 a head with a pull_request run must not be dispatched again, and stays held (dispatches=$(dispatches) created=$(created))"
grep -q "@$H12: not dispatched: a pull_request run" "$QLOG" && ok || bad "D4 no not-dispatched line: $(tail -3 "$QLOG")"

# ── D4b: a completed pull_request run with every traced shard skipped ──
reset main dirty; checks skipped
printf '{"total_count":1,"workflow_runs":[{"path":".github/workflows/harness-ci.yml","event":"pull_request","status":"completed","conclusion":"success"}]}' > "$T/prruns.json"
tick
[ "$(dispatches)" = 1 ] && [ "$(created)" = 0 ] && ok || bad "D4b a completed pull_request run whose traced shards skipped must not stop the dispatch (dispatches=$(dispatches) created=$(created)): $(tail -3 "$QLOG")"
grep -q "@$H12: not dispatched: " "$QLOG" && bad "D4b logged not-dispatched for a completed run: $(tail -3 "$QLOG")" || ok

# ── R1: the rebase hold on: a DIRTY head is its, never dispatched here ──
reset main dirty; checks skipped; tick LEAD_REVIEW_REBASE_HOLD=1
[ "$(dispatches)" = 0 ] && [ "$(created)" = 0 ] && ok || bad "R1 a DIRTY head under the rebase hold must be neither dispatched nor requested (dispatches=$(dispatches) created=$(created))"
hasw skipped_traced=0 && hasw skipped_rebase=1 && ok || bad "R1 summary: $(summ)"

echo "lead-enqueue-traced-wait.bh-5795: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
