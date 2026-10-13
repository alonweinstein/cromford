#!/bin/bash
# tests/conductor-hold-comment-sites.bh-3456-test.sh — BH-3456 (BH-3436.4): every
# conductor hold decision a person can act on hands itself to the BH-3452
# contract `mc_hold_comment <key> <head> <kind> <reason>`, and every other skip
# stays silent. Proven through the contract's own seam, MC_HOLD_COMMENT_TRACE:
# one TSV line key<TAB>head<TAB>kind<TAB>reason per call.
#
# Part 1 (H6, H15 ae gates) sources bin/lib/autoenqueue.sh and the REAL
# bin/lib/mc-hold-comment.sh and calls ae_project with the conductor's 13-column
# rows, the gates' neighbours stubbed at their entry points (the unit harness of
# tests/tier2-autoenqueue-test.sh). Those gates (hold label, lead, ticket-hold,
# hotfix) are shadowed by the conductor's own READY arm in a full tick, so this
# is the only place they are reachable.
# Part 2 (H1-H5, H7, H15 conductor) drives the WHOLE bin/merge-conductor.sh in a
# scratch tree, with to_lane_hold / to_lane_lead_fence / pdg_hold answered from
# fixture files.
# Run from anywhere; exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -r "$DIR/bin/lib/mc-hold-comment.sh" ] || { echo "FAIL: bin/lib/mc-hold-comment.sh does not exist"; exit 1; }

SLUG=example-org/mgfy-os
H1=$(printf 'a%.0s' $(seq 40)); H0=$(printf 'c%.0s' $(seq 40))
U="https://github.com/$SLUG/pull"
TR="$T/trace"
# kinds <file> -> the kind column of every trace line, space-joined
kinds() { cut -f3 "${1:-$TR}" 2>/dev/null | paste -sd' ' -; }
lines() { grep -c . "${1:-$TR}" 2>/dev/null || true; }

# ============================================================================
# Part 1 — the self-enqueue's gates (_ae_skip), in a subshell. It prints its
# own FAIL lines and exits with its fail count.
# ============================================================================
(
  PASS=0; FAIL=0
  export HARNESS="$T/u"; H="$HARNESS"; MC_H="$H"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$T/fx" "$T/ubin"
  printf 'GH_ADMIN_TOKEN=pat-admin\n' > "$H/env/github-admin.env"
  printf '#!/bin/bash\n[ "$2" = board_prefix ] && echo X\nexit 0\n' > "$H/bin/fleet-conf.sh"; chmod +x "$H/bin/fleet-conf.sh"
  cp "$DIR/tests/lib/rest-emit.sh" "$T/ubin/restpr"; chmod +x "$T/ubin/restpr"
  MC_ATTEMPTS="$H/state/attempts.txt"; MC_LOG="$H/logs/merge-conductor.log"; : > "$MC_ATTEMPTS"; : > "$MC_LOG"
  MC_TICK_ID=unit-tick; MC_TICK_DIR="$H/state/tick"
  export MC_ATTEMPTS MC_LOG MC_TICK_ID MC_TICK_DIR
  cat > "$T/ubin/gh" <<EOF
#!/bin/bash
FX="$T/fx"
num_of() { printf '%s' "\$1" | sed -nE 's#.*/(pulls|issues)/([0-9]+).*#\2#p'; }
case "\$*" in
  "api repos/$SLUG -q .id") echo 1 ;;
  *"api -i -X GET repos/$SLUG/commits/"*"/check-runs"*)
    restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X POST repos/$SLUG/issues/"*"/comments"*)
    printf '%s\n' "\$*" >> "$T/posts.txt"; restpr --raw 201 '{"id":777,"body":"@mergifyio queue"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*) restpr open "$H1" "ticket/mg-\$(num_of "\$*")" main "" MERGEABLE clean operator ;;
  *) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$T/ubin/gh"
  export PATH="$T/ubin:$PATH"
  export GH_TOKEN=pat-default
  # shellcheck source=bin/lib/gh-rest.sh
  . "$DIR/bin/lib/gh-rest.sh" || exit 1
  # shellcheck source=bin/lib/gh-repo-token.sh
  . "$DIR/bin/lib/gh-repo-token.sh" || exit 1
  export GH_ETAG=0
  mc_log()   { echo "$*" >> "$MC_LOG"; }
  mc_alert() { :; }
  mc_attempt_has() { grep -qxF "$1" "$MC_ATTEMPTS"; }
  mc_attempt_put() { echo "$1" >> "$MC_ATTEMPTS"; }
  mc_record_for() { echo "$T/rec"; }
  mc_issue_of() { echo 1; }
  mc_verdict() { printf 'APPROVE\t-\t%s\tJ31\t-' "$H1"; }
  vd_standing() { return 1; }
  to_lane_lead_fence() { TO_LEAD_CLEARED=0; [ -f "$T/fx/lead" ] && return 0; [ -f "$T/fx/lead-down" ] && return 2
                         [ -f "$T/fx/lead-cleared" ] && TO_LEAD_CLEARED=1; return 1; }
  to_lane_hold() { [ -f "$T/fx/held" ]; }
  hold_check_thread() { [ -f "$T/fx/prhold" ] && { printf 'HOLD\toperator 2026-09-29: HOLD'; return 1; }
                        [ -f "$T/fx/prhold-down" ] && { printf 'x\tthread unreadable'; return 2; }; printf 'CLEAR\t-'; return 0; }
  bg_scan_read() { [ -f "$T/fx/block" ] && return 1; return 0; }
  main_red_exempt() { return 1; }
  hotfix_pr_is() { case ",$1," in *,hotfix,*) return 0 ;; esac; return 1; }
  mc_hotfix_proof() { cat "$T/fx/hproof" 2>/dev/null || echo ok; }
  flag_active() { [ -f "$H/flags/$1" ]; }
  job_ledger_get() { return 2; }
  job_ledger_put() { :; }
  job_artifact_put() { :; }
  # shellcheck source=bin/lib/autoenqueue.sh
  . "$DIR/bin/lib/autoenqueue.sh" || exit 1
  # shellcheck source=bin/lib/mc-hold-comment.sh
  . "$DIR/bin/lib/mc-hold-comment.sh" || exit 1
  export MC_HOLD_COMMENT_TRACE="$TR"
  row() { printf '%s\t%s\t%s\tticket/mg-%s\tfalse\tCLEAN\tMERGEABLE\tOPEN\tfalse\t%s\tmain\t-\tfalse' "$1" "$U/$1" "$2" "$1" "${3:--}"; }
  reset() { rm -f "$T/fx"/*; : > "$T/posts.txt"; : > "$MC_LOG"; : > "$MC_ATTEMPTS"; : > "$TR"; unset MAIN_RED
            rm -f "$H/state/tier2-autoenqueue.txt"; scratch_rm "$MC_TICK_DIR"; ae_mark mgfy ready "$SLUG#31" "$H1"; }
  ae() { ( MODE=merge; MERGES=1; ae_project mgfy "$SLUG" mergify main "$@" ) >/dev/null 2>&1; }
  aeline() { printf '%s\t%s\t%s' "$SLUG#31" "$H1" "$1"; }

  # the control: an eligible row posts and hands nothing to the contract
  reset; ae "$(row 31 "$H1")"
  [ -s "$T/posts.txt" ] && ok || bad "U0 control: the eligible row posts @mergifyio queue (log: $(cat "$MC_LOG"))"
  [ "$(lines)" = 0 ] && ok || bad "U0/H4 an enqueued row hands nothing to mc_hold_comment (trace: $(cat "$TR"))"

  # H6 — the five hold gates, one each
  reset; ae "$(row 31 "$H1" hold)"
  [ "$(lines)" = 1 ] && grep -q "^$(aeline hold-label)	labelled hold\$" "$TR" && ok \
    || bad "H6 the hold label gate gives one hold-label line (trace: $(cat "$TR"))"
  reset; touch "$T/fx/lead"; ae "$(row 31 "$H1")"
  [ "$(kinds)" = lead ] && grep -q "^$(aeline lead)	" "$TR" && ok || bad "H6 the lead gate gives one lead line (trace: $(cat "$TR"))"
  # ...and only a HELD lead PR: an unread fence, or a cleared one, still refuses
  # under its own gate word and hands nothing over.
  reset; touch "$T/fx/lead-down"; ae "$(row 31 "$H1")"
  [ "$(lines)" = 0 ] && grep -q ": lead-read — " "$MC_LOG" && [ ! -s "$T/posts.txt" ] && ok \
    || bad "H6 an unreadable lead fence refuses as lead-read and is silent (trace: $(cat "$TR"); log: $(cat "$MC_LOG"))"
  reset; touch "$T/fx/lead-cleared"; ae "$(row 31 "$H1")"
  [ "$(lines)" = 0 ] && grep -q ": lead-cleared — " "$MC_LOG" && [ ! -s "$T/posts.txt" ] && ok \
    || bad "H6 a cleared lead PR refuses as lead-cleared and is silent (trace: $(cat "$TR"); log: $(cat "$MC_LOG"))"
  reset; touch "$T/fx/held"; ae "$(row 31 "$H1")"
  [ "$(kinds)" = ticket-hold ] && ok || bad "H6 the ticket-hold gate gives one ticket-hold line (trace: $(cat "$TR"))"
  reset; touch "$T/fx/prhold"; ae "$(row 31 "$H1")"
  [ "$(kinds)" = pr-hold ] && grep -q "RESUME on the PR lifts it" "$TR" && ok || bad "H6 the pr-hold gate gives one pr-hold line with its reason (trace: $(cat "$TR"))"
  reset; echo hold > "$T/fx/hproof"; ae "$(row 31 "$H1" hotfix)"
  [ "$(kinds)" = hotfix ] && ok || bad "H6 the hotfix proof gate gives one hotfix line (trace: $(cat "$TR"))"
  # every tick the hold stands, not once per head: #3455 dedupes, not the call site
  reset; ae "$(row 31 "$H1" hold)"; ae_mark mgfy ready "$SLUG#31" "$H1"; ae "$(row 31 "$H1" hold)"
  [ "$(kinds)" = "hold-label hold-label" ] && ok || bad "H6 a standing hold calls on every tick, past _ae_once (trace: $(cat "$TR"))"
  [ "$(grep -c "^aeskip $SLUG#31 $H1 hold\$" "$MC_ATTEMPTS")" = 1 ] && ok || bad "H6 the _ae_once refusal line is still said once (attempts: $(cat "$MC_ATTEMPTS"))"

  # H15 — the other gates stay silent
  reset; touch "$T/fx/prhold-down"; ae "$(row 31 "$H1")"
  [ "$(lines)" = 0 ] && grep -q ": pr-hold-read — " "$MC_LOG" && ok || bad "H15 pr-hold-read is silent (trace: $(cat "$TR"); log: $(cat "$MC_LOG"))"
  reset; MAIN_RED=main-red-mgfy; ae "$(row 31 "$H1")"
  [ "$(lines)" = 0 ] && grep -q ": main-red — " "$MC_LOG" && ok || bad "H15 main-red is silent (trace: $(cat "$TR"); log: $(cat "$MC_LOG"))"
  reset; touch "$T/fx/block"; ae "$(row 31 "$H1")"
  [ "$(lines)" = 0 ] && grep -q ": block-gate — " "$MC_LOG" && ok || bad "H15 block-gate is silent: bg_refuse owns that comment (trace: $(cat "$TR"); log: $(cat "$MC_LOG"))"
  reset; ae_mark mgfy asked "$SLUG#31" "$H1"; ae "$(row 31 "$H1")"
  [ "$(lines)" = 0 ] && grep -q ": asked — " "$MC_LOG" && ok || bad "H15 asked is silent (trace: $(cat "$TR"); log: $(cat "$MC_LOG"))"
  reset; scratch_rm "$MC_TICK_DIR"; ae "$(row 31 "$H1")"
  [ "$(lines)" = 0 ] && grep -q ": conductor — " "$MC_LOG" && ok || bad "H15 conductor is silent (trace: $(cat "$TR"); log: $(cat "$MC_LOG"))"
  reset; ae "$(printf '31\t%s\t%s\tticket/mg-31\tfalse\tCLEAN\tMERGEABLE\tOPEN\tfalse\t-\tother\t-\tfalse' "$U/31" "$H1")"
  [ "$(lines)" = 0 ] && grep -q ": base — " "$MC_LOG" && ok || bad "H15 base is silent (trace: $(cat "$TR"); log: $(cat "$MC_LOG"))"
  # the knob: MC_HOLD_COMMENT=0 turns the contract inert, the gate still refuses
  reset; MC_HOLD_COMMENT=0 ae "$(row 31 "$H1" hold)"
  [ "$(lines)" = 0 ] && [ ! -s "$T/posts.txt" ] && ok || bad "H6 MC_HOLD_COMMENT=0: no trace, still no post (trace: $(cat "$TR"))"
  echo "part1: $PASS passed, $FAIL failed"
  exit "$FAIL"
)
P1=$?; FAIL=$((FAIL + P1))

# ============================================================================
# Part 2 — the WHOLE bin/merge-conductor.sh in a scratch tree (AT-13's shape).
# ============================================================================
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
export HARNESS="$T/h"; FX="$T/cfx"
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin" "$FX"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/autoenqueue.sh" "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/mc-hold-comment.sh" "$T/h/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"; cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
# The contract, as shipped, plus one wrapper that records the _MC_HC_IN each call
# arrived with (H1b): the re-entry guard #3455's body reads.
cat >> "$T/h/bin/lib/mc-hold-comment.sh" <<EOF
eval "\$(declare -f mc_hold_comment | sed '1s/^mc_hold_comment/_hc_real_mc_hold_comment/')"
mc_hold_comment() { printf '%s\t%s\n' "\${3-}" "\${_MC_HC_IN:-unset}" >> "$T/hcin"; _hc_real_mc_hold_comment "\$@"; }
EOF
# The three fences, answered from fixture files (their real reads are pinned in
# their own suites): held = to_lane_hold rc 0; lead-rc = to_lane_lead_fence's rc
# (absent: 1, not a lead PR), lead-cleared = TO_LEAD_CLEARED=1; pdg-rc / pdg-out
# = pdg_hold's rc and stdout (absent: 1, no dependency).
cat > "$T/h/bin/lib/ticket-ownership.sh" <<EOF
to_lane_hold() { [ -f "$FX/held" ]; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; [ -f "$FX/lead-cleared" ] && TO_LEAD_CLEARED=1
  [ -f "$FX/lead-rc" ] && return "\$(cat "$FX/lead-rc")"; return 1; }
EOF
cat > "$T/h/bin/lib/pr-dep-gate.sh" <<EOF
pdg_hold() { [ -f "$FX/pdg-rc" ] || return 1; cat "$FX/pdg-out" 2>/dev/null; return "\$(cat "$FX/pdg-rc")"; }
EOF
printf 'mgfy %s - - 2 box-m\n' "$SLUG" > "$T/h/fleet.conf"; export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"; done
REC="$T/h/builds/pool-mgfy-MG-31-202609120001"; mkdir -p "$REC"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
cat > "$T/list.json" <<J
[{"number":31,"url":"$U/31","headRefOid":"$H1","headRefName":"ticket/mg-31","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# ci-runs: the actions/runs page mc_ci_state reads (absent: one green run).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 "\$(cat "$FX/ci-runs" 2>/dev/null || echo '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-09-29T10:00:00Z"}]}')" ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/31/comments -f body=@mergifyio queue"*) printf '%s\n' "\$*" >> "$T/c-posts.txt"; restpr --raw 201 '{"id":901}' ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$T/c-cond-cmds.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$T/c-cond-cmds.txt" ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/c-merges.txt"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$T/c-merges.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/$SLUG/issues/31/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/31"*"v3.diff"*) if [ -f "$FX/diff" ]; then restpr --diff "\$(cat "$FX/diff")"; else restpr --diff; fi ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/31"*) restpr OPEN "$H1" ticket/mg-31 main "" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$T/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
  "PUT "*) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
# tick [env...] — one conductor tick from a clean slate, with the fixture as set.
tick() {
  : > "$TR"; : > "$T/hcin"; : > "$T/c-posts.txt"; : > "$T/c-merges.txt"; : > "$T/h/logs/merge-conductor.log"
  scratch_rm "$T/h/state/merge-conductor"; scratch_rm "$T/h/state/tier2-autoenqueue.txt"
  ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
    MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_HOLD_COMMENT_TRACE="$TR" "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }
}
# fixture [verdict] [reviewed-sha] — the build record and a clean fence slate
fixture() {
  rm -f "$FX"/*
  echo "PR_CREATED $U/31" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: %s\n' "${1:-APPROVE}" > "$REC/review.md"
  echo "${2:-$H1}" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
  rm -f "$T/h/flags/review-tighten-example-org-mgfy-os" "$T/h/flags/main-red-mgfy" "$T/h/bin/lib/main-red-gate.sh"
  touch "$T/h/flags/merge-conductor-merge"
}
clog() { grep -E '#31|AUTOENQUEUE' "$T/h/logs/merge-conductor.log" | tail -"${1:-5}"; }
RW="$T/h/state/merge-conductor/ready-why"

# H4 — a clean READY PR that the self-enqueue posts for: no trace at all.
fixture; tick
[ -s "$T/c-posts.txt" ] && ok || bad "H4 control: the clean row is enqueued (log: $(clog))"
[ "$(lines)" = 0 ] && ok || bad "H4 a READY row that enqueues hands nothing to mc_hold_comment (trace: $(cat "$TR"))"

# H1 — a ticket HOLD in the READY arm: one ticket-hold line, the note names it.
fixture; touch "$FX/held"; tick
[ "$(lines)" = 1 ] && grep -q "^$SLUG#31	$H1	ticket-hold	held by a HOLD on its ticket" "$TR" && ok \
  || bad "H1 a ticket-held READY row gives exactly one ticket-hold line (trace: $(cat "$TR"); log: $(clog))"
grep -qs "	$H1	ticket-hold	held by a HOLD" "$RW"/* && ok || bad "H1 the ready-why note still names the hold ($(cat "$RW"/* 2>/dev/null))"
# H1b — the mc_ready_why call carries the re-entry guard.
[ "$(cat "$T/hcin")" = "ticket-hold	1" ] && ok || bad "H1b the call arrives with _MC_HC_IN=1 (got: $(cat "$T/hcin"))"

# H2 — the lead fence holds (rc 0): kind lead. H2b — unread (rc 2): none.
# The fence sits after the merge-budget take, so these ticks carry a budget. It
# also sits after ae_mark, so the self-enqueue's own lead gate asks it again:
# two calls of ONE kind, which #3455's <repo#n>@<kind> dedupe makes one comment.
fixture; echo 0 > "$FX/lead-rc"; tick MC_MERGE_BUDGET=1
[ "$(kinds)" = "lead lead" ] && grep -q "^$SLUG#31	$H1	lead	lead PR: merges only" "$TR" && ok \
  || bad "H2 a lead-held READY row gives kind lead from both lead fences (trace: $(cat "$TR"); log: $(clog))"
fixture; echo 2 > "$FX/lead-rc"; tick MC_MERGE_BUDGET=1
[ "$(lines)" = 0 ] && grep -qs "lead-unread" "$RW"/* && ok || bad "H2b an unreadable lead fence is not a comment kind (trace: $(cat "$TR"); note: $(cat "$RW"/* 2>/dev/null))"

# H3 — the dependency gate holds: one dep-hold line naming the dependency.
fixture; echo 0 > "$FX/pdg-rc"; echo '#5' > "$FX/pdg-out"; tick
[ "$(kinds)" = dep-hold ] && grep -q "^$SLUG#31	$H1	dep-hold	.*#5" "$TR" && ok \
  || bad "H3 a dependency hold gives one dep-hold line naming #5 (trace: $(cat "$TR"); log: $(clog))"
fixture; echo 2 > "$FX/pdg-rc"; tick
[ "$(lines)" = 0 ] && grep -q "PR-dependency gate could not read" "$T/h/logs/merge-conductor.log" && ok \
  || bad "H3 an unreadable dependency (rc 2) is silent (trace: $(cat "$TR"); log: $(clog))"

# H5 — a cleared lead PR on a Mergify repo: one lead-mergify line.
fixture; touch "$FX/lead-cleared"; tick MC_MERGE_BUDGET=1
[ "$(kinds)" = lead-mergify ] && ok || bad "H5 a cleared lead PR on Mergify gives one lead-mergify line (trace: $(cat "$TR"); log: $(clog))"

# H7 — the classifier's human parks.
fixture; printf '+++ b/src/agent.ts\n+const model = "claude-opus-5-5";\n' > "$FX/diff"; tick
[ "$(lines)" = 1 ] && grep -q "^$SLUG#31	$H1	iron-law	iron-law (1 hit(s))\$" "$TR" && ok \
  || bad "H7 iron-law, CI green, reviewed == head: one iron-law line (trace: $(cat "$TR"); log: $(clog))"
fixture; touch "$T/h/flags/review-tighten-example-org-mgfy-os"; tick
[ "$(kinds)" = tightened ] && ok || bad "H7 tightened, CI green, reviewed == head: one tightened line (trace: $(cat "$TR"); log: $(clog))"
fixture; echo "judge provenance: fallback runner wrote this verdict" > "$REC/pipeline.log"; tick
[ "$(kinds)" = provenance ] && ok || bad "H7 provenance, CI green, reviewed == head: one provenance line (trace: $(cat "$TR"); log: $(clog))"
fixture; touch "$T/h/flags/review-tighten-example-org-mgfy-os"
echo '{"workflow_runs":[{"id":1,"name":"CI","status":"in_progress","conclusion":null,"run_started_at":"2026-09-29T10:00:00Z"}]}' > "$FX/ci-runs"; tick
[ "$(lines)" = 0 ] && grep -q "tightened" "$T/h/logs/merge-conductor.log" && ok \
  || bad "H7 tightened with CI pending: no line (trace: $(cat "$TR"); log: $(clog))"
fixture; echo "judge provenance: fallback runner wrote this verdict" > "$REC/pipeline.log"; echo "$H0" > "$REC/reviewed-sha"; tick
[ "$(lines)" = 0 ] && grep -q "provenance" "$T/h/logs/merge-conductor.log" && ok \
  || bad "H7 provenance with reviewed != head: no line (trace: $(cat "$TR"); log: $(clog))"
fixture BLOCK; tick
[ "$(lines)" = 0 ] && grep -q "review-block" "$T/h/logs/merge-conductor.log" && ok \
  || bad "H7 a review-block park: no line (trace: $(cat "$TR"); log: $(clog))"
fixture; echo '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"failure","run_started_at":"2026-09-29T10:00:00Z"}]}' > "$FX/ci-runs"; tick
[ "$(lines)" = 0 ] && ok || bad "H7 a red head: no line (trace: $(cat "$TR"); log: $(clog))"

# H15 — merges off, and a main-red freeze, hold the row silently.
fixture; rm -f "$T/h/flags/merge-conductor-merge"; tick MC_AUTOENQUEUE=0
[ "$(lines)" = 0 ] && grep -qs "merges-off" "$RW"/* && ok || bad "H15 merges-off is not a comment kind (trace: $(cat "$TR"); note: $(cat "$RW"/* 2>/dev/null))"
fixture; cp "$DIR/bin/lib/main-red-gate.sh" "$T/h/bin/lib/"; touch "$T/h/flags/main-red-mgfy"; tick MC_MAIN_RED_TEST_PATHS="tests/*" MC_MAIN_RED_LABEL=fix-main-red
[ "$(lines)" = 0 ] && grep -q "HELD by the main-red freeze" "$T/h/logs/merge-conductor.log" && ok \
  || bad "H15 a main-red freeze is silent (trace: $(cat "$TR"); log: $(tail -5 "$T/h/logs/merge-conductor.log"); err: $(tail -3 "$T/tick.err"))"
fixture

echo "conductor-hold-comment-sites: part 2 $PASS passed; $FAIL failed in all (part 1 counted above)"
[ "$FAIL" -eq 0 ]
