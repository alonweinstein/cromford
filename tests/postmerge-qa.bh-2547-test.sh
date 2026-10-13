#!/bin/bash
# tests/postmerge-qa.bh-2547-test.sh — BH-2547: the prodqa agent is paid only
# when the deterministic drive FAILED. A green drive is the verdict.
#
# THE SPEND THIS REMOVES. bin/postmerge-qa.sh used to open the prodqa agent on
# every GREEN drive (to "drive the flow" on top of a drive that had already
# passed) and never on a failed one. That is $127 in 7 days over 82 calls to
# re-confirm PASSes. The ticket inverts it: a green drive writes its verdict
# with no model call, and the agent runs only to characterise a failure. The
# drive stays authoritative — the agent can never talk a drive FAIL back.
#
# WHAT IS DRIVEN HERE, against the REAL script in a scratch harness (fake gh,
# curl and node; an agent-call.sh stub that records each call):
#
#   a  classic green drive: 0 agent calls, QA: PASS, done row PASS, and the
#      report says the flow drive was not run because the drive was green
#   b  persona drive, all flows pass: 0 agent calls, PASS
#   c  persona drive, a fail row at rc 1: exactly 1 agent call through
#      `prodqa project-3`, the prompt says the drive FAILED and names the row;
#      FAIL, ALERTS line, fleet_alert beat
#   d  persona drive, a fail row at rc 0: the drive still counts as failed —
#      1 agent call, FAIL. d2: same, where the failing persona is not the
#      last driven, so the fail ROW is the only failure signal
#   e  classic drive, rc 1 + `QA: FAIL`: 1 agent call, FAIL. e2: a crashed
#      drive (rc 1, no verdict line), so the rc is the only failure signal
#   f  the agent writes a trailing `QA: PASS` on a failed drive: still FAIL
#   g  BLOCKED (unban did not take, rc 91) and requeue (rc 75): 0 agent calls
#   h  POSTMERGE_QA_AGENT=0 on a failed drive: 0 agent calls, FAIL
#
# Every assertion is on what the run WROTE (agent-calls.txt, qa-prod.md, the
# done file, ALERTS.log, beats) — never on the script's source text.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/postmerge-qa.bh-2547-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-1941: the script under test resolves its vendor base URL through
# endpoint_url (env, else the registry default); this sandbox composes no
# registry, so the env carries today's URL — the registry default itself.
export ENDPOINT_CLERK=https://api.clerk.com
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "postmerge-qa.bh-2547: jq is required"; exit 1; }
command -v flock >/dev/null || { echo "postmerge-qa.bh-2547: flock is required"; exit 1; }
BASE="$T"

. "$DIR/tests/lib/model-route-stub.sh" || exit 1
new_harness() {
  local T; T=$(mktemp -d "$BASE/h-XXXXXX")
  mkdir -p "$T/bin/lib" "$T/fakebin" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" \
           "$T/builds" "$T/clerk" "$T/repo/qa"
  local F
  for F in postmerge-qa.sh qa-unbanned.sh qa-clerk-ban.sh \
           fleet-conf.sh prod-url.sh findings-log.sh alert_family.py; do
    cp "$DIR/bin/$F" "$T/bin/$F"; chmod +x "$T/bin/$F"
  done
  cp "$DIR/bin/lib/endpoints.sh" "$DIR/bin/lib/qa-personas.sh" "$T/bin/lib/"
  cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$T/bin/lib/"
  printf 'project-3 example-org/project-3 https://os.project-3.test /api/board 6 box-project-3-2\n' > "$T/fleet.conf"
  : > "$T/env/global.env"
  mrs_fixture "$T" project-3
  printf 'QA_CLERK_SECRET_KEY=sk_test_fake\nQA_TEST_USER_ID=user_QA\n' > "$T/env/project-3.env"
  echo active > "$T/clerk/user_QA"
  printf '#!/bin/bash\necho "$*" >> "%s/beats.txt"\nexit 0\n' "$T" > "$T/bin/beat.sh"
  chmod +x "$T/bin/beat.sh"
  # The agent stub: one row per call in agent-calls.txt (argv minus the prompt),
  # the prompt in prompt.txt. AGENT_WRITES_PASS makes it do what a lenient
  # agent would: append a clean coverage line and `QA: PASS` to the report.
  cat > "$T/bin/agent-call.sh" <<EOF
#!/bin/bash
echo "\$1 \$2 \$3 \$4 \$5" >> "$T/agent-calls.txt"
printf '%s' "\${!#}" > "$T/prompt.txt"
if [ "\${AGENT_WRITES_PASS:-0}" = 1 ]; then
  printf -- '- everything looked fine to me\nQA COVERAGE: screens=1 flows=1 shots=1\nQA: PASS\n' >> "\$(dirname "\$5")/qa-prod.md"
fi
exit 0
EOF
  chmod +x "$T/bin/agent-call.sh"
  cat > "$T/bin/qa-account.sh" <<'EOF'
#!/bin/bash
case "${2:-}" in
  qa-owner) echo user_OWNER ;;
  qa-admin) echo user_ADMIN ;;
  user_*)   echo "$2" ;;
  *) echo "no QA account for ${1:-}/${2:-}" >&2; exit 1 ;;
esac
exit 0
EOF
  chmod +x "$T/bin/qa-account.sh"
  cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"pr view"*state,mergeCommit*) printf 'MERGED\tdeadbeefcafe1234\t-\n' ;;
  *"deployments/"*"/statuses"*)  echo success ;;
  *deployments*)                 echo 99 ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/gh"
  cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
case "$URL" in
  *"/v1/users/"*)
    UID_="${URL##*/v1/users/}"; UID_="${UID_%%/*}"
    SF="$CLERK_STATE_DIR/$UID_"; [ -f "$SF" ] || echo active > "$SF"
    case "$URL" in
      */ban)   echo banned > "$SF"; printf '200'; exit 0 ;;
      */unban) [ "${CLERK_UNBAN_NOOP:-}" = 1 ] && { printf '200'; exit 0; }
               echo active > "$SF"; printf '200'; exit 0 ;;
    esac
    if [ "$(cat "$SF")" = banned ]; then B=true; else B=false; fi
    printf '{"id":"%s","banned":%s}' "$UID_" "$B" ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/curl"
  # Fake node (qa-drive.mjs), both shapes: the classic screen drive, and the
  # persona grammar (one FLOW row per flow). NODE_FAIL_FLOW turns one row into
  # a fail; NODE_RC is the exit code.
  cat > "$T/fakebin/node" <<'EOF'
#!/bin/bash
echo "$*" >> "$NODE_SINK"
OUT="${4:-}"; FLOWS=""; PERSONA=""; PREV=""
for A in "$@"; do
  case "$PREV" in --flows) FLOWS="$A" ;; --persona) PERSONA="$A" ;; esac
  PREV="$A"
done
if [ -z "$FLOWS" ]; then
  mkdir -p "$OUT"
  # A crashed drive: a stack trace, no verdict line, non-zero rc.
  [ "${NODE_CRASH:-0}" = 1 ] && { echo "TypeError: Cannot read properties of undefined (reading 'goto')"; exit 1; }
  if [ "${NODE_RC:-0}" = 0 ]; then
    : > "$OUT/root-1280.png"
    echo "LANDED:https://os.project-3.test/dashboard"
    echo "QA COVERAGE: screens=1 flows=0 shots=1"
    echo "QA: PASS"
  else
    echo "FAIL: /clients: console error TypeError: x is undefined"
    echo "QA COVERAGE: screens=1 flows=0 shots=0"
    echo "QA: FAIL"
  fi
  exit "${NODE_RC:-0}"
fi
mkdir -p "$OUT"; VERD=PASS
while IFS=$'\t' read -r FID KIND; do
  if [ "$KIND" = skipped ]; then echo "FLOW $PERSONA $FID skipped (write flow, production)"; continue; fi
  : > "$OUT/$FID-1280.png"
  if [ "$FID" = "${NODE_FAIL_FLOW:-}" ]; then
    echo "FLOW $PERSONA $FID fail steps=1/2 shot=- expect timed out"; VERD=FAIL
  else
    echo "FLOW $PERSONA $FID pass steps=2/2 shot=$OUT/$FID-1280.png"
  fi
done < <(jq -r --arg p "$PERSONA" \
  '.personas[] | select(.id == $p) | .flows[] | "\(.id)\t\(if .skipped then "skipped" else "steps" end)"' \
  "$FLOWS")
echo "QA: $VERD"
exit "${NODE_RC:-0}"
EOF
  chmod +x "$T/fakebin/node"
  printf '%s' "$T"
}
seed_personas() {
  cp "$DIR/tests/fixtures/qa-personas/valid.json" "$1/repo/qa/personas.json"
  cp "$DIR/tests/fixtures/qa-personas/apps.json"  "$1/repo/qa/apps.json"
}
seed_build() { # seed_build <harness> <name>
  local d="$1/builds/$2"; mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/project-3/pull/7" > "$d/RESULT"
  printf '# plan\n\n## QA screens\n\n/clients\n' > "$d/plan.md"
  printf 'apps/web/x.tsx\napps/admin/y.tsx\n' > "$d/planned-files.txt"
  printf '%s' "$d"
}
run() { # run <harness> [env assignments...]
  local T="$1"; shift
  env -i ENDPOINT_CLERK="$ENDPOINT_CLERK" PATH="$T/fakebin:/usr/bin:/bin" HOME="$T" \
      HARNESS="$T" FLEET_CONF="$T/fleet.conf" QA_ACCOUNTS="$T/state/qa-accounts.json" \
      CLERK_STATE_DIR="$T/clerk" NODE_SINK="$T/node.txt" \
      QA_REPO_DIR="$T/repo" "$@" "$T/bin/postmerge-qa.sh" project-3 >/dev/null 2>&1
}
# Agent-call ROWS: one per invocation of the stub. An absent file is 0 rows.
calls() {
  [ -f "$1/agent-calls.txt" ] || { echo 0; return 0; }
  grep -c '' "$1/agent-calls.txt"
}
# The STAGE's verdict: the last bare `QA: <verdict>` line in the report.
verdict() { grep -E '^QA: (PASS|FAIL|BLOCKED)$' "$1/qa-prod.md" 2>/dev/null | tail -1; }
drives() { [ -f "$1/node.txt" ] || { echo 0; return 0; }; grep -c 'qa-drive.mjs' "$1/node.txt"; }

# --- a. classic green drive: no model call ----------------------------------------
T=$(new_harness); B=$(seed_build "$T" project-3-TK-1-202609260000)
run "$T"
[ "$(drives "$T")" = 1 ] && ok || bad "a: the build must be driven once (got $(drives "$T"))"
[ "$(calls "$T")" = 0 ] && ok || bad "a: a green drive must make 0 agent-call rows (got $(calls "$T"): $(cat "$T/agent-calls.txt" 2>/dev/null))"
[ "$(verdict "$B")" = "QA: PASS" ] && ok || bad "a: a green drive's verdict is PASS (got [$(verdict "$B")])"
[ "$(tail -1 "$B/qa-prod.md")" = "QA: PASS" ] && ok || bad "a: qa-prod.md must END with QA: PASS"
grep -q 'flow drive: not run — the deterministic drive was green' "$B/qa-prod.md" \
  && ok || bad "a: the report must say why the flow drive was not run (got: $(grep 'flow drive' "$B/qa-prod.md" 2>/dev/null))"
grep -q ' PASS$' "$T/state/postmerge-qa-done.txt" && ok || bad "a: the done row must record PASS"
[ ! -s "$T/beats.txt" ] && ok || bad "a: a PASS must not page"

# --- b. persona drive, all pass: no model call ---------------------------------------
T=$(new_harness); seed_personas "$T"; B=$(seed_build "$T" project-3-TK-2-202609260000)
run "$T"
grep -q '^FLOW owner dashboard pass' "$B/qa-prod.md" && ok || bad "b: the persona lane must have driven (no pass row)"
[ "$(calls "$T")" = 0 ] && ok || bad "b: an all-pass persona drive must make 0 agent-call rows (got $(calls "$T"))"
[ "$(verdict "$B")" = "QA: PASS" ] && ok || bad "b: verdict must be PASS (got [$(verdict "$B")])"

# --- c. persona fail row at rc 1: the agent investigates ------------------------------
T=$(new_harness); seed_personas "$T"; B=$(seed_build "$T" project-3-TK-3-202609260000)
run "$T" NODE_FAIL_FLOW=dashboard NODE_RC=1
[ "$(calls "$T")" = 1 ] && ok || bad "c: a failed drive must make exactly 1 agent call (got $(calls "$T"))"
grep -q '^prodqa project-3 ' "$T/agent-calls.txt" 2>/dev/null \
  && ok || bad "c: the call must go through agent-call.sh as prodqa project-3 (got: $(cat "$T/agent-calls.txt" 2>/dev/null))"
grep -q 'deterministic drive FAILED' "$T/prompt.txt" 2>/dev/null \
  && ok || bad "c: the prompt must tell the agent the drive FAILED (got: $(head -c 300 "$T/prompt.txt" 2>/dev/null))"
grep -q 'owner/dashboard fail' "$T/prompt.txt" 2>/dev/null \
  && ok || bad "c: the prompt must name the failing flow row"
[ "$(verdict "$B")" = "QA: FAIL" ] && ok || bad "c: verdict must be FAIL (got [$(verdict "$B")])"
grep -q 'POST-MERGE PROD QA FAILED' "$T/logs/ALERTS.log" 2>/dev/null && ok || bad "c: a FAIL must write ALERTS.log"
grep -q 'fleet_alert' "$T/beats.txt" 2>/dev/null && ok || bad "c: a FAIL must fire a fleet_alert beat"
grep -q 'flow drive: ran' "$B/qa-prod.md" && ok || bad "c: the report must say the flow drive ran"

# --- d. rc 0 with a fail row: still a failed drive -------------------------------------
T=$(new_harness); seed_personas "$T"; B=$(seed_build "$T" project-3-TK-4-202609260000)
run "$T" NODE_FAIL_FLOW=dashboard NODE_RC=0
[ "$(calls "$T")" = 1 ] && ok || bad "d: a fail ROW at rc 0 is a failed drive, 1 agent call (got $(calls "$T"))"
grep -q 'deterministic drive FAILED' "$T/prompt.txt" 2>/dev/null \
  && ok || bad "d: the agent must be told it is investigating a failure, not re-driving a pass"
# d2. the FAILING persona is not the last one driven, so the report's last drive
#     verdict line is the other persona's `QA: PASS` and rc is 0: the fail ROW is
#     the only signal left, and it alone must count as a failed drive.
T=$(new_harness); seed_personas "$T"; B=$(seed_build "$T" project-3-TK-41-202609260000)
run "$T" NODE_FAIL_FLOW=users NODE_RC=0
grep -q '^FLOW admin users fail' "$B/qa-prod.md" && ok || bad "d2: the admin fail row must be in the report"
[ "$(grep -E '^QA: (PASS|FAIL)$' "$B/qa-prod.md" | sed -n '$!p' | tail -1)" = "QA: PASS" ] \
  && ok || bad "d2: fixture drift — the last DRIVE verdict line must be the passing persona's"
[ "$(calls "$T")" = 1 ] && ok || bad "d2: a fail row alone is a failed drive, 1 agent call (got $(calls "$T"))"
[ "$(verdict "$B")" = "QA: FAIL" ] && ok || bad "d2: verdict must be FAIL (got [$(verdict "$B")])"
[ "$(verdict "$B")" = "QA: FAIL" ] && ok || bad "d: verdict must be FAIL (got [$(verdict "$B")])"

# --- e. classic rc 1 + QA: FAIL --------------------------------------------------------
T=$(new_harness); B=$(seed_build "$T" project-3-TK-5-202609260000)
run "$T" NODE_RC=1
[ "$(calls "$T")" = 1 ] && ok || bad "e: a failed classic drive must make 1 agent call (got $(calls "$T"))"
grep -q '^prodqa project-3 ' "$T/agent-calls.txt" 2>/dev/null && ok || bad "e: the call must be prodqa project-3"
[ "$(verdict "$B")" = "QA: FAIL" ] && ok || bad "e: verdict must be FAIL (got [$(verdict "$B")])"
grep -q ' FAIL$' "$T/state/postmerge-qa-done.txt" && ok || bad "e: the done row must record FAIL"

# e2. a drive that crashed: rc 1 and NO verdict line, so the rc is the only
#     failure signal, and it alone must count as a failed drive.
T=$(new_harness); B=$(seed_build "$T" project-3-TK-51-202609260000)
run "$T" NODE_CRASH=1
grep -qE '^QA: (PASS|FAIL)$' <(sed -n '/^## Observed (deterministic drive)/,/^## Verdict/p' "$B/qa-prod.md") \
  && bad "e2: fixture drift — the crashed drive must print no verdict line" || ok
[ "$(calls "$T")" = 1 ] && ok || bad "e2: a non-zero rc alone is a failed drive, 1 agent call (got $(calls "$T"))"
[ "$(verdict "$B")" = "QA: FAIL" ] && ok || bad "e2: verdict must be FAIL (got [$(verdict "$B")])"

# --- f. the agent cannot talk a drive FAIL back -------------------------------------------
T=$(new_harness); B=$(seed_build "$T" project-3-TK-6-202609260000)
run "$T" NODE_RC=1 AGENT_WRITES_PASS=1
[ "$(calls "$T")" = 1 ] && ok || bad "f: the agent must have run (got $(calls "$T"))"
grep -q 'everything looked fine to me' "$B/qa-prod.md" && ok || bad "f: the stub's PASS must be in the report for this case to mean anything"
[ "$(verdict "$B")" = "QA: FAIL" ] && ok || bad "f: an agent PASS must not flip a drive FAIL (got [$(verdict "$B")])"
T=$(new_harness); seed_personas "$T"; B=$(seed_build "$T" project-3-TK-61-202609260000)
run "$T" NODE_FAIL_FLOW=dashboard NODE_RC=0 AGENT_WRITES_PASS=1
[ "$(verdict "$B")" = "QA: FAIL" ] && ok || bad "f: an agent PASS must not flip a fail row at rc 0 (got [$(verdict "$B")])"

# --- g. nothing observed: no spend ----------------------------------------------------------
T=$(new_harness); B=$(seed_build "$T" project-3-TK-7-202609260000)
echo banned > "$T/clerk/user_QA"
run "$T" CLERK_UNBAN_NOOP=1
[ "$(verdict "$B")" = "QA: BLOCKED" ] && ok || bad "g: an unban that did not take is BLOCKED (got [$(verdict "$B")])"
[ "$(calls "$T")" = 0 ] && ok || bad "g: a BLOCKED run must make 0 agent calls (got $(calls "$T"))"

T=$(new_harness); B=$(seed_build "$T" project-3-TK-8-202609260000)
flock "$T/locks/qa-unban-project-3-user_QA.lock" sleep 20 &
HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  flock -n "$T/locks/qa-unban-project-3-user_QA.lock" true || break
  sleep 0.2
done
run "$T" QA_UNBAN_WAIT=0
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
grep -q 'requeued' "$T/logs/postmerge-qa.log" 2>/dev/null && ok || bad "g: a busy unban window must requeue (log: $(cat "$T/logs/postmerge-qa.log" 2>/dev/null))"
[ "$(calls "$T")" = 0 ] && ok || bad "g: a requeued run must make 0 agent calls (got $(calls "$T"))"
[ ! -s "$T/state/postmerge-qa-done.txt" ] && ok || bad "g: a requeued build must stay eligible"

# --- h. the knob still turns the agent off -------------------------------------------------
T=$(new_harness); B=$(seed_build "$T" project-3-TK-9-202609260000)
run "$T" NODE_RC=1 POSTMERGE_QA_AGENT=0
[ "$(calls "$T")" = 0 ] && ok || bad "h: POSTMERGE_QA_AGENT=0 must make 0 agent calls (got $(calls "$T"))"
[ "$(verdict "$B")" = "QA: FAIL" ] && ok || bad "h: verdict must still be FAIL (got [$(verdict "$B")])"

echo "postmerge-qa.bh-2547: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
