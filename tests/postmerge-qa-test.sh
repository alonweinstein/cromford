#!/bin/bash
# tests/postmerge-qa-test.sh — bin/postmerge-qa.sh, DRIVEN against a scratch
# harness with a fake GitHub, a fake Clerk, a fake browser and a fake agent.
#
# WHAT THIS PINS. The stage's whole value is that it observes production AFTER
# the merge, and its whole risk is that it becomes another guard that reports a
# pass it did not earn. So the properties driven here are the ones that decide
# which of those it is:
#
#   1. THE DEPLOY GATE COMES FIRST. If prod is not yet serving the merge sha,
#      NOTHING is driven and the build stays eligible. Driving the previous
#      build and calling it this ticket's result is the one way this stage could
#      manufacture a false FAIL — and a false FAIL on prod pages a human.
#   2. "CANNOT TELL" IS NOT "YES". An unreadable deployments API requeues.
#   3. THE AGENT LANE RUNS ONLY ON A FAILED DRIVE (BH-2547). A green drive is
#      the verdict and costs no model call; a failed one is a FAIL whatever the
#      agent then finds, and the agent is paid only to characterise it. (This is
#      the `[lane:deterministic_prefix]` bound declared VERIFIED in
#      catalog/context-budgets.json.)
#   4. ONE BUILD PER TICK. (`[lane:one_build_per_tick]`, same manifest row.)
#   5. IT FAILS OPEN. No QA env, no console, no worker: exit 0, having SAID what
#      it could not cover. It runs after the merge, so it must never be able to
#      turn into something that blocks one.
#   6. FAILS ARE LOUD. ALERTS.log + a fleet_alert beat, and the observation is
#      attached to the ticket record (qa-prod.md, findings.log, the PR comment).
#   7. IDEMPOTENT. A second tick re-drives nothing.
#
# Run from anywhere: tests/postmerge-qa-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-1941: the script under test resolves its vendor base URL through
# endpoint_url (env, else the registry default); this sandbox composes no
# registry, so the env carries today's URL — the registry default itself.
export ENDPOINT_CLERK=https://api.clerk.com
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
BASE="$T"

# ---------------------------------------------------------------------------
# A fresh scratch $HARNESS per scenario. Everything the stage shells out to is
# either the REAL script (fleet-conf, prod-url, findings-log, qa-unbanned,
# qa-clerk-ban, qa-account — the code under test) or a fake that records what it
# was asked to do (gh, curl, node, agent-call.sh, beat.sh).
# ---------------------------------------------------------------------------
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
new_harness() {
  local T; T=$(mktemp -d "$BASE/h-XXXXXX")
  mkdir -p "$T/bin" "$T/fakebin" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" \
           "$T/builds" "$T/clerk" "$T/repo"
  local F
  for F in postmerge-qa.sh qa-unbanned.sh qa-clerk-ban.sh qa-account.sh \
           fleet-conf.sh prod-url.sh findings-log.sh alert_family.py; do
    cp "$DIR/bin/$F" "$T/bin/$F"; chmod +x "$T/bin/$F"
  done
  # BH-1941: the Clerk base URL resolves through bin/lib/endpoints.sh, shipped beside the script.
  mkdir -p "$T/bin/lib"; cp "$DIR/bin/lib/endpoints.sh" "$T/bin/lib/"
  cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$T/bin/lib/"
  printf 'project-3 example-org/project-3 https://os.project-3.test /api/board 6 box-project-3-2\n' > "$T/fleet.conf"
  : > "$T/env/global.env"
  # BH-1510.1: this lane's model is a model_routes row (postmerge.qa); this
  # worker-less box carries the resolver beside the lane and its cache of #1507's table.
  mkdir -p "$T/bin/lib"
  mrs_fixture "$T" project-3
  printf 'QA_CLERK_SECRET_KEY=sk_test_fake\nQA_TEST_USER_ID=user_QA\n' > "$T/env/project-3.env"
  echo active > "$T/clerk/user_QA"
  printf '#!/bin/bash\necho "$*" >> "%s/beats.txt"\nexit 0\n' "$T" > "$T/bin/beat.sh"
  chmod +x "$T/bin/beat.sh"
  printf '#!/bin/bash\necho "$*" >> "%s/agent-calls.txt"\nexit "${AGENT_RC:-0}"\n' "$T" > "$T/bin/agent-call.sh"
  chmod +x "$T/bin/agent-call.sh"
  # Fake gh: PR state/merge sha, deployments, and a recorded pr comment.
  cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$GH_SINK"
case "$*" in
  *"pr view"*state,mergeCommit*) printf '%s\t%s\n' "${PR_STATE:-MERGED}" "${MERGE_SHA:-deadbeefcafe1234}" ;;
  *"deployments/"*"/statuses"*)  echo "${DEPLOY_STATE:-success}" ;;
  *deployments*)                 [ "${DEPLOY_API:-ok}" = down ] && exit 1; echo "${DEPLOY_ID:-99}" ;;
  *"pr comment"*)                : ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/gh"
  # Fake curl: Clerk's users API (so the real qa-clerk-ban.sh runs) and nothing
  # else — VERSION_URL is unset in these scenarios, so the gate uses gh.
  cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET; PREV=""
for A in "$@"; do [ "$PREV" = "-X" ] && METHOD="$A"; PREV="$A"; done
case "$URL" in
  *"/v1/users/"*)
    UID_="${URL##*/v1/users/}"; UID_="${UID_%%/*}"
    SF="$CLERK_STATE_DIR/$UID_"; [ -f "$SF" ] || echo active > "$SF"
    case "$URL" in
      */ban)   [ "${CLERK_FAIL_BAN:-}" = 1 ] && { printf '500'; exit 0; }
               echo banned > "$SF"; printf '200'; exit 0 ;;
      */unban) [ "${CLERK_UNBAN_NOOP:-}" = 1 ] && { printf '200'; exit 0; }
               echo active > "$SF"; printf '200'; exit 0 ;;
    esac
    if [ "$(cat "$SF")" = banned ]; then B=true; else B=false; fi
    printf '{"id":"%s","banned":%s}' "$UID_" "$B" ;;
  *) printf '%s' "${VERSION_BODY:-}" ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/curl"
  # Fake node: stands in for qa-drive.mjs. Writes the shape the real one writes
  # (a QA COVERAGE line, a verdict line, screenshots) and honours NODE_RC.
  cat > "$T/fakebin/node" <<'EOF'
#!/bin/bash
echo "$*" >> "$NODE_SINK"
OUT=""
for A in "$@"; do case "$A" in */qa-prod-shots) OUT="$A" ;; esac; done
if [ "${NODE_RC:-0}" = 0 ]; then
  [ -n "$OUT" ] && { mkdir -p "$OUT"; : > "$OUT/root-1280.png"; : > "$OUT/root-375.png"; }
  echo "LANDED:https://os.project-3.test/dashboard"
  echo "QA COVERAGE: screens=2 flows=0 shots=2"
  echo "QA: PASS"
else
  echo "FAIL: sign-in: QA user user_QA is BANNED in Clerk"
  echo "QA COVERAGE: screens=0 flows=0 shots=0"
  echo "QA: FAIL"
fi
exit "${NODE_RC:-0}"
EOF
  chmod +x "$T/fakebin/node"
  printf '%s' "$T"
}

seed_build() { # seed_build <harness> <name> [plan-screens]
  local T="$1" name="$2" screens="${3:-}"
  local d="$T/builds/$name"; mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/project-3/pull/7" > "$d/RESULT"
  [ -n "$screens" ] && printf '# plan\n\n## QA screens\n\n%s\n' "$screens" > "$d/plan.md"
  printf '%s' "$d"
}

run() { # run <harness> [env assignments...]
  local T="$1"; shift
  env -i ENDPOINT_CLERK="$ENDPOINT_CLERK" PATH="$T/fakebin:/usr/bin:/bin" HOME="$T" \
      HARNESS="$T" FLEET_CONF="$T/fleet.conf" QA_ACCOUNTS="$T/state/qa-accounts.json" \
      CLERK_STATE_DIR="$T/clerk" GH_SINK="$T/gh.txt" NODE_SINK="$T/node.txt" \
      QA_REPO_DIR="$T/repo" "$@" "$T/bin/postmerge-qa.sh" project-3 2>&1
}
# NO `|| echo 0`: grep -c already PRINTS 0 when it matches nothing and exits 1,
# so the fallback appends a SECOND zero and every comparison reads "0\n0". The
# empty case that actually needs a default is a sink that was never written.
drives() {
  [ -f "$1/node.txt" ] || { echo 0; return 0; }
  grep -c 'qa-drive.mjs' "$1/node.txt"
}

# ===========================================================================
# 1. THE DEPLOY GATE COMES FIRST
# ===========================================================================
T=$(new_harness); seed_build "$T" project-3-TK-1-202608290000 "/clients" >/dev/null
run "$T" DEPLOY_STATE=pending >/dev/null
[ "$(drives "$T")" = 0 ] && ok || bad "a build whose deploy has not succeeded must not be driven"
[ ! -s "$T/state/postmerge-qa-done.txt" ] && ok || bad "an ungated build must stay eligible, not be marked done"
grep -q 'not yet serving' "$T/logs/postmerge-qa.log" \
  && ok || bad "the requeue must be logged with its reason"

# 2. "cannot tell" requeues too — an unreadable API is never a green gate.
T=$(new_harness); seed_build "$T" project-3-TK-1-202608290000 "/clients" >/dev/null
run "$T" DEPLOY_API=down >/dev/null
[ "$(drives "$T")" = 0 ] && ok || bad "an unreadable deployments API must requeue, not drive"
grep -q 'cannot determine' "$T/logs/postmerge-qa.log" \
  && ok || bad "the unknown-gate branch must say it could not tell"

# 3. an UNMERGED PR is not a candidate at all
T=$(new_harness); seed_build "$T" project-3-TK-1-202608290000 "/clients" >/dev/null
run "$T" PR_STATE=OPEN >/dev/null
[ "$(drives "$T")" = 0 ] && ok || bad "an open PR must never be prod-QA'd"

# ===========================================================================
# 4. THE HAPPY PATH: gate green -> drive -> attach, and NO agent spend
# ===========================================================================
T=$(new_harness); B=$(seed_build "$T" project-3-TK-2-202608290000 "/clients
/clients/abc123")
run "$T" >/dev/null
[ "$(drives "$T")" = 1 ] && ok || bad "a gated, merged build must be driven once"
grep -q 'os.project-3.test' "$T/node.txt" && ok || bad "the drive must target the PROD base url"
grep -q '/clients' "$T/node.txt" && ok || bad "the plan's QA screens must be the screens driven"
grep -q "$B/qa-prod-shots" "$T/node.txt" && ok || bad "screenshots must land in the build dir"
grep -q 'QA: PASS' "$B/qa-prod.md" && ok || bad "the report must carry the verdict"
grep -q 'deploy gate: prod confirmed serving' "$B/qa-prod.md" \
  && ok || bad "the report must state that the deploy gate was satisfied first"
[ ! -s "$T/agent-calls.txt" ] \
  && ok || bad "a green drive must make no agent call (BH-2547) (got: $(cat "$T/agent-calls.txt" 2>/dev/null))"
grep -q 'flow drive: not run — the deterministic drive was green' "$B/qa-prod.md" \
  && ok || bad "the report must say why the flow drive was not run"
grep -q 'lens=prodqa' "$T/logs/findings.log" \
  && ok || bad "observations must reach findings.log as lens=prodqa"
grep -q 'verdict=PASS' "$T/logs/findings.log" \
  && ok || bad "the prodqa lens must log its own verdict vocabulary (PASS/FAIL)"
grep -q 'pr comment' "$T/gh.txt" && ok || bad "the observed result must be attached to the merged PR"
[ ! -s "$T/beats.txt" ] && ok || bad "a PASS must not page anyone"
grep -q ' PASS$' "$T/state/postmerge-qa-done.txt" && ok || bad "a driven build must be marked done with its verdict"

# 5. IDEMPOTENT: a second tick re-drives nothing
run "$T" >/dev/null
[ "$(drives "$T")" = 1 ] && ok || bad "a second tick must not re-drive a finished build"

# ===========================================================================
# 6. A FAILED DRIVE: FAIL verdict, loud, and the agent characterises it
# ===========================================================================
T=$(new_harness); B=$(seed_build "$T" project-3-TK-3-202608290000 "/clients")
run "$T" NODE_RC=1 >/dev/null
grep -q 'QA: FAIL' "$B/qa-prod.md" && ok || bad "a failed drive must be a FAIL verdict"
grep -q '^prodqa project-3' "$T/agent-calls.txt" 2>/dev/null \
  && ok || bad "the prodqa agent lane must run on a failed drive (BH-2547) (got: $(cat "$T/agent-calls.txt" 2>/dev/null))"
grep -q 'deterministic drive FAILED' "$T/agent-calls.txt" 2>/dev/null \
  && ok || bad "the agent must be told the drive FAILED"
grep -q 'flow drive: ran' "$B/qa-prod.md" \
  && ok || bad "the report must say the flow drive ran"
grep -q 'POST-MERGE PROD QA FAILED' "$T/logs/ALERTS.log" \
  && ok || bad "a prod FAIL must write ALERTS.log"
grep -q 'fleet_alert' "$T/beats.txt" && ok || bad "a prod FAIL must fire a fleet_alert beat"
grep -q 'lens=prodqa verdict=FAIL' "$T/logs/findings.log" \
  && ok || bad "a FAIL must be recorded in findings.log as such"

# ===========================================================================
# 6b. BLOCKED IS NOT FAIL — "we could not look" must never be reported as
#     "prod is broken". A fabricated defect claim about a shipped feature is the
#     same dishonesty this stage exists to remove, pointing the other way.
# ===========================================================================
T=$(new_harness); B=$(seed_build "$T" project-3-TK-31-202608290000 "/clients")
echo banned > "$T/clerk/user_QA"
run "$T" CLERK_UNBAN_NOOP=1 >/dev/null
[ "$(drives "$T")" = 0 ] && ok || bad "an unban that did not take must drive nothing"
grep -q 'QA: BLOCKED' "$B/qa-prod.md" && ok || bad "an undrivable account is BLOCKED, not FAIL"
grep -q 'QA: FAIL' "$B/qa-prod.md" && bad "BLOCKED must not also claim a FAIL" || ok
grep -q 'BLOCKED' "$T/logs/ALERTS.log" && ok || bad "a BLOCKED run must alert — stopping is an alert, not a whisper"
grep -q 'NOT a defect claim' "$T/logs/ALERTS.log"   && ok || bad "the BLOCKED alert must say it is not a defect claim"
[ ! -s "$T/agent-calls.txt" ] && ok || bad "a BLOCKED run must not spend the agent lane"

# ...and a failed RE-ban blocks too, on top of qa-unbanned.sh's own alert.
T=$(new_harness); B=$(seed_build "$T" project-3-TK-32-202608290000 "/clients")
echo banned > "$T/clerk/user_QA"
run "$T" CLERK_FAIL_BAN=1 >/dev/null
grep -q 'QA: BLOCKED' "$B/qa-prod.md" && ok || bad "a failed re-ban must block the verdict"
grep -q 'QA ACCOUNT LEFT UNBANNED' "$T/logs/ALERTS.log"   && ok || bad "the unban wrapper's own alert must survive being called from the stage"

# 6c. an account that is BANNED at rest is really unbanned for the drive and
#     really re-banned after it — the whole point, driven end to end here.
T=$(new_harness); B=$(seed_build "$T" project-3-TK-33-202608290000 "/clients")
echo banned > "$T/clerk/user_QA"
run "$T" >/dev/null
[ "$(drives "$T")" = 1 ] && ok || bad "a banned-at-rest QA account must still be driven"
[ "$(cat "$T/clerk/user_QA")" = banned ]   && ok || bad "the QA account must be BANNED again once the stage is done"
grep -q 'QA: PASS' "$B/qa-prod.md" && ok || bad "the drive inside the unban window must be able to pass"

# ===========================================================================
# 7. ONE BUILD PER TICK (the [lane:one_build_per_tick] bound)
# ===========================================================================
T=$(new_harness)
seed_build "$T" project-3-TK-4-202608290000 "/a" >/dev/null
seed_build "$T" project-3-TK-5-202608290001 "/b" >/dev/null
run "$T" >/dev/null
[ "$(drives "$T")" = 1 ] && ok || bad "two eligible builds must still be one drive per tick (got $(drives "$T"))"
run "$T" >/dev/null
[ "$(drives "$T")" = 2 ] && ok || bad "the second build must be picked up on the NEXT tick"

# ===========================================================================
# 8. FAIL-OPEN, and honest about what was not covered
# ===========================================================================
T=$(new_harness); seed_build "$T" project-3-TK-6-202608290000 "/clients" >/dev/null
printf 'QA_CLERK_SECRET_KEY=\nQA_TEST_USER_ID=\n' > "$T/env/project-3.env"
run "$T" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "no QA env must exit 0 (fail-open), got $RC"
[ "$(drives "$T")" = 0 ] && ok || bad "no QA env must drive nothing"
grep -q 'no authed screen covered' "$T/logs/postmerge-qa.log" \
  && ok || bad "an uncovered run must SAY it covered nothing"

T=$(new_harness); seed_build "$T" project-3-TK-7-202608290000 "/clients" >/dev/null
touch "$T/flags/postmerge-qa-disabled"
run "$T" >/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(drives "$T")" = 0 ] && ok || bad "the kill switch must stop the stage cleanly (rc=$RC)"

T=$(new_harness); seed_build "$T" project-3-TK-8-202608290000 "/clients" >/dev/null
run "$T" POSTMERGE_QA_DISABLED=1 >/dev/null
[ "$(drives "$T")" = 0 ] && ok || bad "POSTMERGE_QA_DISABLED must stop the stage"

# 9. no plan.md at all is a thin pass, not a crash and not a false one
T=$(new_harness); B=$(seed_build "$T" project-3-TK-9-202608290000)
run "$T" >/dev/null
grep -q 'screens requested: /' "$B/qa-prod.md" \
  && ok || bad "with no plan the stage must drive / and say so (got: $(head -6 "$B/qa-prod.md" 2>/dev/null))"

# ===========================================================================
# 10. WIRING — a stage nothing calls is a stage that never runs
# ===========================================================================
for P in project-4 project-1 project-2 project-3; do
  grep -q 'postmerge-qa.sh' "$(rendered_cron "$P")" \
    && ok || bad "cron/$P.cron does not run the post-merge QA stage"
done
jq -e '[.lanes[] | select(.stage == "prodqa")] | length == 1' "$DIR/catalog/context-budgets.json" >/dev/null \
  && ok || bad "the prodqa lane is not declared exactly once in catalog/context-budgets.json"
grep -q 'qa-prod.md:prodqa' "$DIR/bin/findings-log.sh" \
  && ok || bad "findings-log.sh does not harvest the prod-QA lens"

echo "postmerge-qa-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
