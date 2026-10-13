#!/bin/bash
# tests/postmerge-qa-personas-test.sh — bin/postmerge-qa.sh's PERSONA lane,
# driven against a scratch harness with a fake GitHub, a fake Clerk, a fake
# browser and a fake agent. Sibling of tests/postmerge-qa-test.sh, which pins
# the same script's single-account lane; the helpers are copied from it on
# purpose (BH-536 allows the copy) because the two suites want different fakes
# for `node` and `qa-account.sh` and a shared block would have to be both.
#
# WHAT THIS PINS. The persona lane's whole risk is that it drives production as
# more privileged users than the old lane ever did, so the properties driven
# here are the ones that decide whether that is safe and whether the report
# about it is true:
#
#   1. A WRITE FLOW IS NEVER EXECUTED IN PRODUCTION. `production_safe: false`
#      reaches the drive with no steps, `--production` is on every call,
#      `--preview` on none, and the flow shows up as `skipped` in the report.
#   2. ONE UNBAN WINDOW PER PERSONA, with that persona's own role. Two personas
#      in scope means two Clerk accounts were really touched.
#   3. "WE COULD NOT LOOK" IS NEVER A PASS. An unresolvable role, a wrapper that
#      says the account is unusable (rc 90/91), a drive that emitted no rows —
#      each is BLOCKED with explicit `FLOW … blocked <reason>` rows, never a
#      silent skip and never a FAIL about the app.
#   4. A `fail` ROW IS A FAIL EVEN AT rc 0. A per-flow assertion that timed out
#      is a row, not an exit code.
#   5. CAPPED WORK IS VISIBLE. `E2E_MAX_PERSONAS` prints `not driven (persona
#      cap)` rows rather than dropping the personas it did not reach.
#   6. THE OLD LANE IS UNTOUCHED. No personas file, an invalid one, or a scope
#      of NONE keeps today's single-account screen drive, and `PERSONAS:` in the
#      report says which of those happened.
#
# Run from anywhere: tests/postmerge-qa-personas-test.sh   (exit 0 = all pass)
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
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
BASE="$T"

# ---------------------------------------------------------------------------
# A fresh scratch $HARNESS per scenario. Everything the stage shells out to is
# either the REAL script (fleet-conf, prod-url, findings-log, qa-unbanned,
# qa-clerk-ban, bin/lib/qa-personas.sh — the code under test and the contract it
# imports) or a fake that records what it was asked to do (gh, curl, node,
# qa-account.sh, agent-call.sh, beat.sh).
# ---------------------------------------------------------------------------
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
  # BH-1941: the Clerk base URL resolves through bin/lib/endpoints.sh, shipped beside the script.
  mkdir -p "$T/bin/lib"; cp "$DIR/bin/lib/endpoints.sh" "$T/bin/lib/"
  cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$T/bin/lib/"
  cp "$DIR/bin/lib/qa-personas.sh" "$T/bin/lib/qa-personas.sh"
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
  # Fake qa-account.sh: the role map this project would have in
  # state/qa-accounts.json. An unknown role FAILS — the property tested is that
  # the lane blocks rather than falling through to the default account.
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
  # Fake curl: Clerk's users API (so the real qa-clerk-ban.sh runs), one state
  # file per user id — which is also how this suite proves that TWO accounts
  # were really opened rather than one being reused.
  cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
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
  # Fake node: stands in for qa-drive.mjs in BOTH shapes.
  #   * no --flows/--persona  -> the single-account screen drive it prints today
  #   * --flows/--persona     -> the contract grammar: one row per flow of the
  #     named persona, `skipped` for a flow the scoper stripped, `EXEC <id>`
  #     into the sink for every flow it really executed, one png per executed
  #     flow. NODE_FAIL_FLOW turns one row into a `fail`, NODE_NO_ROWS prints no
  #     rows at all, NODE_RC is the exit code.
  cat > "$T/fakebin/node" <<'EOF'
#!/bin/bash
echo "$*" >> "$NODE_SINK"
OUT="${4:-}"
FLOWS=""; PERSONA=""; PREV=""
for A in "$@"; do
  case "$PREV" in --flows) FLOWS="$A" ;; --persona) PERSONA="$A" ;; esac
  PREV="$A"
done
if [ -z "$FLOWS" ] || [ -z "$PERSONA" ]; then
  # The classic shape: $OUT is the shots dir, two screenshots, one verdict.
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
fi
mkdir -p "$OUT"
if [ "${NODE_NO_ROWS:-0}" = 1 ]; then
  echo "FAIL: --flows was not understood by this build of the drive"
  echo "QA COVERAGE: screens=0 flows=0 shots=0"
  echo "QA: FAIL"
  exit "${NODE_RC:-0}"
fi
NF=0; NS=0; VERD=PASS
while IFS=$'\t' read -r FID KIND; do
  if [ "$KIND" = skipped ]; then
    echo "FLOW $PERSONA $FID skipped (write flow, production)"
    NS=$((NS + 1))
    continue
  fi
  echo "EXEC $FID" >> "$NODE_SINK"
  echo "EXEC $FID"
  : > "$OUT/$FID-1280.png"
  NF=$((NF + 1))
  if [ "$FID" = "${NODE_FAIL_FLOW:-}" ]; then
    echo "FLOW $PERSONA $FID fail steps=1/2 shot=- expect timed out"
    VERD=FAIL
  else
    echo "FLOW $PERSONA $FID pass steps=2/2 shot=$OUT/$FID-1280.png"
  fi
done < <(jq -r --arg p "$PERSONA" \
  '.personas[] | select(.id == $p) | .flows[] | "\(.id)\t\(if .skipped then "skipped" else "steps" end)"' \
  "$FLOWS")
echo "QA COVERAGE: screens=$NF flows=$NF shots=$NF"
echo "QA: $VERD"
exit "${NODE_RC:-0}"
EOF
  chmod +x "$T/fakebin/node"
  printf '%s' "$T"
}

# The repo's persona files, from the contract's own fixtures.
seed_personas() { # seed_personas <harness>
  cp "$DIR/tests/fixtures/qa-personas/valid.json" "$1/repo/qa/personas.json"
  cp "$DIR/tests/fixtures/qa-personas/apps.json"  "$1/repo/qa/apps.json"
}

seed_build() { # seed_build <harness> <name> [plan-screens] [planned-files]
  local T="$1" name="$2" screens="${3:-}" planned="${4:-}"
  local d="$T/builds/$name"; mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/project-3/pull/7" > "$d/RESULT"
  [ -n "$screens" ] && printf '# plan\n\n## QA screens\n\n%s\n' "$screens" > "$d/plan.md"
  [ -n "$planned" ] && printf '%s\n' "$planned" > "$d/planned-files.txt"
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
# Count matches in a file that may not exist yet. `-e` so a pattern that starts
# with a dash (`--flows`, `--preview`) is a pattern and not a flag.
count() { # count <file> <ere>
  [ -f "$1" ] || { echo 0; return 0; }
  grep -cE -e "$2" "$1"
}

# The STAGE's verdict, which is the LAST `QA: <verdict>` line in the report. The
# drive's own output carries `QA: PASS`/`QA: FAIL` lines of its own inside the
# code fence, so a bare `grep -q 'QA: FAIL'` would pass on a report whose verdict
# said PASS — it would be asserting that the fake browser said what the fake
# browser was told to say.
verdict() { # verdict <report>
  [ -f "$1" ] || { echo "no report"; return 0; }
  grep -E '^QA: (PASS|FAIL|BLOCKED)$' "$1" | tail -1
}

# ===========================================================================
# 1. THE HAPPY PATH: two personas in scope, driven read-only, reported true
# ===========================================================================
T=$(new_harness); seed_personas "$T"
B=$(seed_build "$T" project-3-TK-1-202608290000 "/clients" "apps/web/x.tsx
apps/admin/y.tsx")
run "$T" >/dev/null
[ "$(drives "$T")" = 2 ] && ok || bad "two in-scope personas must be two drives (got $(drives "$T"))"
grep -q -- '--persona owner' "$T/node.txt" && ok || bad "the owner persona must be named on its own drive"
grep -q -- '--persona admin' "$T/node.txt" && ok || bad "the admin persona must be named on its own drive"
[ "$(count "$T/node.txt" 'qa-drive\.mjs')" = "$(count "$T/node.txt" 'qa-drive\.mjs.*--production')" ] \
  && ok || bad "--production must be on EVERY drive call"
[ "$(count "$T/node.txt" '--preview')" = 0 ] \
  && ok || bad "the production lane must never pass --preview"
[ -f "$T/clerk/user_OWNER" ] && [ -f "$T/clerk/user_ADMIN" ] \
  && ok || bad "each persona must get its OWN unban window (one Clerk account per role)"
# the plan's screens ride the FIRST drive only, so screen coverage is not lost
# and not multiplied
[ "$(count "$T/node.txt" 'qa-drive\.mjs.*/clients')" = 1 ] \
  && ok || bad "the plan's screens belong to the first persona's drive only (got $(count "$T/node.txt" 'qa-drive\.mjs.*/clients'))"
grep -q '^FLOW owner dashboard pass' "$B/qa-prod.md" && ok || bad "a read-only flow must be reported as pass"
grep -q '^FLOW admin users pass' "$B/qa-prod.md" && ok || bad "the admin persona's flow must be reported too"
grep -q 'persona flows: pass=2 fail=0 blocked=0 skipped=1' "$B/qa-prod.md" \
  && ok || bad "the verdict must carry the persona flow tally (got: $(grep -o 'persona flows: .*' "$B/qa-prod.md" 2>/dev/null))"
[ "$(verdict "$B/qa-prod.md")" = "QA: PASS" ] && ok || bad "an all-pass persona run must be a PASS (got: $(verdict "$B/qa-prod.md"))"
grep -q 'PERSONAS: admin owner (mode production)' "$B/qa-prod.md" \
  && ok || bad "the report header must name the personas in scope (got: $(grep -o 'PERSONAS: .*' "$B/qa-prod.md" 2>/dev/null))"
# SHOTS counts recursively: the pngs now live in $OUT/<persona>/, not $OUT/
NPNG=$(find "$B/qa-prod-shots" -type f -name '*.png' | wc -l)
[ "$NPNG" -gt 0 ] && grep -q "$NPNG screenshots on disk" "$B/qa-prod.md" \
  && ok || bad "screenshots must be counted recursively under the shots dir (disk=$NPNG, report: $(grep -o '[0-9]* screenshots on disk' "$B/qa-prod.md" 2>/dev/null))"
[ ! -s "$T/agent-calls.txt" ] \
  && ok || bad "an all-pass persona drive must make no agent call (BH-2547)"
grep -q ' PASS$' "$T/state/postmerge-qa-done.txt" && ok || bad "a driven build must be marked done with its verdict"

# ===========================================================================
# 2. A WRITE FLOW IS NEVER EXECUTED IN PRODUCTION
# ===========================================================================
jq -e '.mode == "production"' "$B/qa-prod-shots/scoped.json" >/dev/null \
  && ok || bad "the scoped file must be written in production mode"
[ "$(jq -r '.personas[] | select(.id=="owner") | .flows[] | select(.id=="new-scan") | has("steps")' \
     "$B/qa-prod-shots/scoped.json")" = false ] \
  && ok || bad "a production_safe:false flow must reach the drive with NO steps"
grep -q 'EXEC new-scan' "$T/node.txt" \
  && bad "the write flow was EXECUTED against production" || ok
grep -q '^FLOW owner new-scan skipped (write flow, production)' "$B/qa-prod.md" \
  && ok || bad "the skipped write flow must be visible in the report, not dropped"

# ===========================================================================
# 3. A `fail` ROW IS A FAIL — loud, and the agent is paid to characterise it
# ===========================================================================
T=$(new_harness); seed_personas "$T"
B=$(seed_build "$T" project-3-TK-2-202608290000 "/clients" "apps/web/x.tsx
apps/admin/y.tsx")
run "$T" NODE_FAIL_FLOW=dashboard NODE_RC=1 >/dev/null
[ "$(verdict "$B/qa-prod.md")" = "QA: FAIL" ] && ok || bad "a failed flow row with rc 1 must be a FAIL (got: $(verdict "$B/qa-prod.md"))"
grep -q 'POST-MERGE PROD QA FAILED' "$T/logs/ALERTS.log" \
  && ok || bad "a prod FAIL must write ALERTS.log"
grep -q 'fleet_alert' "$T/beats.txt" && ok || bad "a prod FAIL must fire a fleet_alert beat"
grep -q '^prodqa project-3' "$T/agent-calls.txt" 2>/dev/null \
  && ok || bad "a failed drive DOES spend the agent lane (BH-2547)"
grep -q 'Persona flows already driven' "$T/agent-calls.txt" 2>/dev/null \
  && ok || bad "the prodqa prompt must tell the agent which flows the lane already drove"
grep -q 'owner/dashboard fail' "$T/agent-calls.txt" 2>/dev/null \
  && ok || bad "that sentence must carry flow ids AND verdicts, the failing one included"
grep -q 'admin/users pass' "$T/agent-calls.txt" 2>/dev/null \
  && ok || bad "that sentence must carry the passing flows too"

# 3b. ...and rc 0 does not talk a fail row back. A per-flow assertion that timed
#     out is a ROW, not an exit code, so the rows decide the verdict too.
T=$(new_harness); seed_personas "$T"
B=$(seed_build "$T" project-3-TK-3-202608290000 "/clients" "apps/web/x.tsx
apps/admin/y.tsx")
run "$T" NODE_FAIL_FLOW=dashboard NODE_RC=0 >/dev/null
grep -q '^FLOW owner dashboard fail' "$B/qa-prod.md" && ok || bad "the fail row must be in the report"
[ "$(verdict "$B/qa-prod.md")" = "QA: FAIL" ] \
  && ok || bad "a fail ROW must be a FAIL even when the drive exited 0 (got: $(verdict "$B/qa-prod.md"))"
grep -q 'persona flows: pass=1 fail=1' "$B/qa-prod.md" \
  && ok || bad "the tally must count the failed flow (got: $(grep -o 'persona flows: .*' "$B/qa-prod.md" 2>/dev/null))"

# ===========================================================================
# 4. AN UNRESOLVABLE ROLE IS BLOCKED, NEVER THE DEFAULT ACCOUNT
# ===========================================================================
T=$(new_harness); seed_personas "$T"
jq '(.personas[] | select(.id=="admin") | .role) = "qa-nobody"' \
  "$DIR/tests/fixtures/qa-personas/valid.json" > "$T/repo/qa/personas.json"
B=$(seed_build "$T" project-3-TK-4-202608290000 "/clients" "apps/web/x.tsx
apps/admin/y.tsx")
run "$T" >/dev/null
grep -q '^FLOW admin users blocked no QA account for project-3/qa-nobody' "$B/qa-prod.md" \
  && ok || bad "an unknown role must print blocked rows naming the role"
[ "$(verdict "$B/qa-prod.md")" = "QA: BLOCKED" ] \
  && ok || bad "an unresolvable persona is BLOCKED (got: $(verdict "$B/qa-prod.md"))"
[ "$(verdict "$B/qa-prod.md")" = "QA: FAIL" ] && bad "BLOCKED must not also claim a FAIL about the app" || ok
grep -q 'NOT a defect claim' "$T/logs/ALERTS.log" \
  && ok || bad "the BLOCKED alert must say it is not a defect claim"
[ "$(drives "$T")" = 1 ] && ok || bad "the resolvable persona must still be driven (got $(drives "$T"))"
[ ! -f "$T/clerk/user_ADMIN" ] && ok || bad "an unresolved role must never open an unban window"
[ ! -s "$T/agent-calls.txt" ] && ok || bad "a BLOCKED run must not spend the agent lane"

# ===========================================================================
# 5. THE CAP DEFERS VISIBLY — capped work is never dropped silently
# ===========================================================================
T=$(new_harness); seed_personas "$T"
B=$(seed_build "$T" project-3-TK-5-202608290000 "/clients" "apps/web/x.tsx
apps/admin/y.tsx")
run "$T" E2E_MAX_PERSONAS=1 >/dev/null
[ "$(drives "$T")" = 1 ] && ok || bad "E2E_MAX_PERSONAS=1 must drive exactly one persona (got $(drives "$T"))"
grep -q '^FLOW owner dashboard blocked not driven (persona cap)' "$B/qa-prod.md" \
  && ok || bad "the personas past the cap must be reported as not driven"
[ "$(verdict "$B/qa-prod.md")" = "QA: PASS" ] \
  && ok || bad "a cap is an operator knob, not a harness failure (got: $(verdict "$B/qa-prod.md"))"

# 5b. ...and a cap that is not a whole number is REFUSED out loud, not read as
#     "no cap". `[ 2 -gt abc ]` errors and returns non-zero, which would have
#     read as under-the-cap forever.
T=$(new_harness); seed_personas "$T"
B=$(seed_build "$T" project-3-TK-5b-202608290000 "/clients" "apps/web/x.tsx
apps/admin/y.tsx")
run "$T" E2E_MAX_PERSONAS=lots >/dev/null
grep -q "E2E_MAX_PERSONAS='lots' is not a whole number" "$T/logs/postmerge-qa.log" \
  && ok || bad "a non-numeric persona cap must be named in the log, not silently ignored"
[ "$(drives "$T")" = 2 ] && ok || bad "a refused cap must fall back to the default of 4 (got $(drives "$T"))"

# ===========================================================================
# 6. A DRIVE THAT EMITTED NO ROWS IS BLOCKED, NEVER A PASS
# ===========================================================================
T=$(new_harness); seed_personas "$T"
B=$(seed_build "$T" project-3-TK-6-202608290000 "/clients" "apps/web/x.tsx
apps/admin/y.tsx")
run "$T" NODE_RC=3 NODE_NO_ROWS=1 >/dev/null
grep -q 'blocked drive emitted no FLOW rows (rc=3)' "$B/qa-prod.md" \
  && ok || bad "a non-zero drive with zero FLOW rows must print blocked rows saying so"
[ "$(verdict "$B/qa-prod.md")" = "QA: BLOCKED" ] \
  && ok || bad "zero observations is BLOCKED, not FAIL and not PASS (got: $(verdict "$B/qa-prod.md"))"

# ===========================================================================
# 7. A BUSY UNBAN WINDOW REQUEUES THE WHOLE BUILD — nothing is marked done
# ===========================================================================
# The window belongs to whoever holds locks/qa-unban-<P>-<uid>.lock. A holder is
# started in the background and handshakes over two FIFOs, so this test never
# sleeps and never races (bin/test-determinism-lint.sh forbids both).
T=$(new_harness); seed_personas "$T"
B=$(seed_build "$T" project-3-TK-7-202608290000 "/clients" "apps/web/x.tsx
apps/admin/y.tsx")
mkfifo "$T/held" "$T/release"
( exec 9>"$T/locks/qa-unban-project-3-user_OWNER.lock"
  flock 9 || exit 1
  echo held > "$T/held"
  read -r _ < "$T/release" ) &
HOLDER=$!
read -r _ < "$T/held"                 # blocks until the lock is really held
run "$T" QA_UNBAN_WAIT=1 >/dev/null
echo go > "$T/release"; wait "$HOLDER" 2>/dev/null
grep -q 'requeued' "$T/logs/postmerge-qa.log" \
  && ok || bad "a busy unban window must requeue the build with its reason"
[ ! -s "$T/state/postmerge-qa-done.txt" ] \
  && ok || bad "a requeued build must NOT be marked done"

# ===========================================================================
# 8. AN UNBAN THAT DID NOT TAKE (rc 91) BLOCKS THAT PERSONA
# ===========================================================================
T=$(new_harness); seed_personas "$T"
B=$(seed_build "$T" project-3-TK-8-202608290000 "/clients" "apps/web/x.tsx
apps/admin/y.tsx")
echo banned > "$T/clerk/user_OWNER"
run "$T" CLERK_UNBAN_NOOP=1 >/dev/null
grep -q '^FLOW owner dashboard blocked qa-unbanned rc=91' "$B/qa-prod.md" \
  && ok || bad "an unban that did not take must block that persona's flows"
[ "$(verdict "$B/qa-prod.md")" = "QA: BLOCKED" ] \
  && ok || bad "an undrivable account is BLOCKED (got: $(verdict "$B/qa-prod.md"))"
[ "$(verdict "$B/qa-prod.md")" = "QA: FAIL" ] && bad "rc 91 must not be reported as a prod defect" || ok
[ "$(drives "$T")" = 1 ] && ok || bad "the other persona must still be driven (got $(drives "$T"))"

# ===========================================================================
# 9. SCOPE `NONE` KEEPS TODAY'S SINGLE-ACCOUNT SCREEN DRIVE
# ===========================================================================
T=$(new_harness); seed_personas "$T"
B=$(seed_build "$T" project-3-TK-9-202608290000 "/clients" "tests/foo.sh")
run "$T" >/dev/null
grep -q 'PERSONAS: NONE' "$B/qa-prod.md" \
  && ok || bad "a scope of NONE must be stated in the report (got: $(grep -o 'PERSONAS: .*' "$B/qa-prod.md" 2>/dev/null))"
[ "$(drives "$T")" = 1 ] && ok || bad "NONE must fall back to exactly one screen drive"
[ "$(count "$T/node.txt" '--flows')" = 0 ] \
  && ok || bad "the fallback drive must be the classic call shape, with no --flows"
[ "$(verdict "$B/qa-prod.md")" = "QA: PASS" ] \
  && ok || bad "the NONE fallback must still be able to pass (got: $(verdict "$B/qa-prod.md"))"

# ===========================================================================
# 10. AN INVALID PERSONAS FILE SAYS SO AND FALLS BACK — never a partial drive
# ===========================================================================
T=$(new_harness); seed_personas "$T"
jq '.personas[0].flows[0].production_safe = "true"' \
  "$DIR/tests/fixtures/qa-personas/valid.json" > "$T/repo/qa/personas.json"
B=$(seed_build "$T" project-3-TK-10-202608290000 "/clients" "apps/web/x.tsx")
run "$T" >/dev/null
grep -q 'PERSONAS: invalid — personas.json: .personas\[0\].flows\[0\].production_safe' "$B/qa-prod.md" \
  && ok || bad "an invalid personas file must be named in the report (got: $(grep -o 'PERSONAS: .*' "$B/qa-prod.md" 2>/dev/null))"
[ "$(drives "$T")" = 1 ] && ok || bad "an invalid file must fall back to one screen drive"
[ "$(count "$T/node.txt" '--flows')" = 0 ] && ok || bad "an invalid file must never produce a persona drive"
[ "$(verdict "$B/qa-prod.md")" = "QA: PASS" ] \
  && ok || bad "an invalid personas file is not a prod defect (got: $(verdict "$B/qa-prod.md"))"
[ ! -f "$B/qa-prod-shots/scoped.json" ] && ok || bad "no scoped file may be written for an invalid personas file"

# ===========================================================================
# 11. NO PERSONAS FILE AT ALL — today's lane, byte for byte
# ===========================================================================
T=$(new_harness)   # no seed_personas
B=$(seed_build "$T" project-3-TK-11-202608290000 "/clients" "apps/web/x.tsx")
run "$T" >/dev/null
[ "$(drives "$T")" = 1 ] && ok || bad "a repo with no personas file must be driven exactly as today"
[ "$(count "$T/node.txt" '--flows')" = 0 ] && ok || bad "no personas file must mean no --flows"
grep -q 'PERSONAS: none (no qa/personas.json)' "$B/qa-prod.md" \
  && ok || bad "the report must say WHY no persona was driven"
[ "$(count "$T/agent-calls.txt" 'Persona flows')" = 0 ] \
  && ok || bad "the prodqa prompt must be unchanged when no persona lane ran"
[ "$(verdict "$B/qa-prod.md")" = "QA: PASS" ] \
  && ok || bad "the classic lane must still pass (got: $(verdict "$B/qa-prod.md"))"

# ===========================================================================
# 12. NO QA ENV — the env check still comes FIRST, personas or not
# ===========================================================================
T=$(new_harness); seed_personas "$T"
seed_build "$T" project-3-TK-12-202608290000 "/clients" "apps/web/x.tsx" >/dev/null
printf 'QA_CLERK_SECRET_KEY=\nQA_TEST_USER_ID=\n' > "$T/env/project-3.env"
run "$T" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "no QA env must still exit 0 (fail-open), got $RC"
[ "$(drives "$T")" = 0 ] && ok || bad "no QA env must drive nothing, personas file or not"
grep -q 'NOT_COVERED_NO_QA_ENV' "$T/state/postmerge-qa-done.txt" \
  && ok || bad "no QA env must be recorded as NOT_COVERED_NO_QA_ENV exactly as today"
grep -q 'no authed screen covered' "$T/logs/postmerge-qa.log" \
  && ok || bad "an uncovered run must SAY it covered nothing"

echo "postmerge-qa-personas-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
