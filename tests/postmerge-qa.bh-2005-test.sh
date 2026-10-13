#!/bin/bash
# tests/postmerge-qa.bh-2005-test.sh — BH-2005.2 (built as BH-2036): the prodqa
# agent is told which verification-map entries cover the screens it drives.
#
# Drives the REAL bin/postmerge-qa.sh in a scratch harness (the scaffolding of
# tests/postmerge-qa.bh-1022-test.sh: fake gh / curl / node, a served merge sha,
# a FAILED drive, since BH-2547 only a failed drive calls the agent) with the
# REAL bin/lib/vmap-entry.sh beside it. The agent-call
# stub writes the prompt it was handed to a file, so every assertion is on the
# prompt text and on qa-prod.md, never on the script's source.
#
#   a  a matching entry: its lies bullet and the instruction reach the prompt,
#      and the first note line lands under `## Observed (driven flows)`
#   b  no matching entry: the prompt carries `no map entry for screens: /billing`
#   c  the verdict, the done-ledger row and rc are the same in a and b
#   d  lib not copied: the prompt says `lookup unavailable (lib absent)`, and the
#      verdict is unchanged
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/postmerge-qa.bh-2005-test.sh
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
command -v jq >/dev/null || { echo "postmerge-qa.bh-2005: jq is required"; exit 1; }
BASE="$T"
SHA_A=deadbeefcafe1234
SCRIPT="${POSTMERGE_QA:-$DIR/bin/postmerge-qa.sh}"

. "$DIR/tests/lib/model-route-stub.sh" || exit 1
new_harness() { # new_harness <with-lib: 1|0>
  local T; T=$(mktemp -d "$BASE/h-XXXXXX")
  mkdir -p "$T/bin/lib" "$T/fakebin" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" \
           "$T/builds" "$T/clerk" "$T/repo/docs/verification-map"
  local F
  for F in qa-unbanned.sh qa-clerk-ban.sh qa-account.sh \
           fleet-conf.sh prod-url.sh findings-log.sh alert_family.py; do
    cp "$DIR/bin/$F" "$T/bin/$F"; chmod +x "$T/bin/$F"
  done
  # BH-1941: the Clerk base URL resolves through bin/lib/endpoints.sh, shipped beside the script.
  mkdir -p "$T/bin/lib"; cp "$DIR/bin/lib/endpoints.sh" "$T/bin/lib/"
  cp "$SCRIPT" "$T/bin/postmerge-qa.sh"; chmod +x "$T/bin/postmerge-qa.sh"
  cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$T/bin/lib/"
  [ "$1" = 1 ] && cp "$DIR/bin/lib/vmap-entry.sh" "$T/bin/lib/vmap-entry.sh"
  printf 'project-3 example-org/project-3 https://os.project-3.test /api/board 6 box-project-3-2\n' > "$T/fleet.conf"
  : > "$T/env/global.env"
  mrs_fixture "$T" project-3
  printf 'QA_CLERK_SECRET_KEY=sk_test_fake\nQA_TEST_USER_ID=user_QA\n' > "$T/env/project-3.env"
  echo active > "$T/clerk/user_QA"
  printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
  # The prompt is the agent-call's LAST argument.
  printf '#!/bin/bash\nprintf "%%s" "${!#}" > "%s/prompt.txt"\nexit 0\n' "$T" > "$T/bin/agent-call.sh"
  chmod +x "$T/bin/agent-call.sh"
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pr view"*state,mergeCommit*) printf 'MERGED\t%s\t-\n' "$SHA_A" ;;
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
      */unban) echo active > "$SF"; printf '200'; exit 0 ;;
    esac
    if [ "$(cat "$SF")" = banned ]; then B=true; else B=false; fi
    printf '{"id":"%s","banned":%s}' "$UID_" "$B" ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/curl"
  cat > "$T/fakebin/node" <<'EOF'
#!/bin/bash
OUT=""
for A in "$@"; do case "$A" in */qa-prod-shots) OUT="$A" ;; esac; done
[ -n "$OUT" ] && { mkdir -p "$OUT"; : > "$OUT/root-1280.png"; }
echo "LANDED:https://os.project-3.test/dashboard"
echo "FAIL: /clients/42: console error TypeError: x is undefined"
echo "QA COVERAGE: screens=1 flows=0 shots=1"
echo "QA: FAIL"
exit 1
EOF
  chmod +x "$T/fakebin/node"
  cat > "$T/repo/docs/verification-map/clients.md" <<'MD'
# Clients

**Key routes/screens:**
- `/clients/[id]` — one client

**What usually lies:**
- the balance column reads a stale cache after an edit
MD
  printf '%s' "$T"
}
seed_build() { # seed_build <harness> <screen>
  local d="$1/builds/project-3-TK-1-202609240000"; mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/project-3/pull/7" > "$d/RESULT"
  printf '# plan\n\n## QA screens\n\n- `%s`\n' "$2" > "$d/plan.md"
  printf '%s' "$d"
}
run() { # run <harness> -> the script's rc
  local T="$1"
  env -i ENDPOINT_CLERK="$ENDPOINT_CLERK" PATH="$T/fakebin:/usr/bin:/bin" HOME="$T" \
      HARNESS="$T" FLEET_CONF="$T/fleet.conf" QA_ACCOUNTS="$T/state/qa-accounts.json" \
      CLERK_STATE_DIR="$T/clerk" QA_REPO_DIR="$T/repo" \
      "$T/bin/postmerge-qa.sh" project-3 >/dev/null 2>&1
  echo $?
}
verdict() { grep -E '^QA: ' "$1/qa-prod.md" 2>/dev/null | tail -1; }
ledger()  { awk '{print $(NF-2), $(NF-1), $NF}' "$1/state/postmerge-qa-done.txt" 2>/dev/null; }
prompt()  { cat "$1/prompt.txt" 2>/dev/null; }

# --- a. a matching entry --------------------------------------------------------
TA=$(new_harness 1); BA=$(seed_build "$TA" /clients/42)
RC_A=$(run "$TA")
[ -s "$TA/prompt.txt" ] && ok || bad "a: the agent was never called (rc=$RC_A)"
grep -qF 'VERIFICATION MAP: 1 entry for this ticket'"'"'s screens' <<<"$(prompt "$TA")" \
  && ok || bad "a: the prompt must carry the note header (got: $(prompt "$TA" | head -c 400))"
grep -qF -- '- the balance column reads a stale cache after an edit' <<<"$(prompt "$TA")" \
  && ok || bad "a: the prompt must carry the entry's lies bullet"
grep -qF "check each 'What usually lies' bullet against what you observed" <<<"$(prompt "$TA")" \
  && ok || bad "a: the prompt must carry the What usually lies instruction"
if awk '/^## Observed \(driven flows\)/{h=NR} /^VERIFICATION MAP: 1 entry for this ticket/{v=NR} END{exit !(h && v > h)}' "$BA/qa-prod.md"; then ok
else bad "a: qa-prod.md must carry the note's first line after the observed header (got: $(cat "$BA/qa-prod.md"))"; fi
[ "$(grep -c '^VERIFICATION MAP' "$BA/qa-prod.md")" = 1 ] && ok \
  || bad "a: qa-prod.md gets the note's FIRST line only"

# --- b. no matching entry --------------------------------------------------------
TB=$(new_harness 1); BB=$(seed_build "$TB" /billing)
RC_B=$(run "$TB")
grep -qF 'VERIFICATION MAP: no map entry for screens: /billing (map has 1 entries)' <<<"$(prompt "$TB")" \
  && ok || bad "b: the prompt must carry the no-entry note (got: $(prompt "$TB" | head -c 400))"
grep -q '^VERIFICATION MAP: no map entry for screens: /billing' "$BB/qa-prod.md" \
  && ok || bad "b: qa-prod.md must carry the no-entry line"

# --- c. verdict unchanged ---------------------------------------------------------
[ "$RC_A" = 0 ] && [ "$RC_B" = 0 ] && ok || bad "c: rc must be 0 in a and b (a=$RC_A b=$RC_B)"
[ "$(verdict "$BA")" = "QA: FAIL" ] && ok || bad "c: verdict in a must be the drive's FAIL (got [$(verdict "$BA")])"
[ "$(verdict "$BA")" = "$(verdict "$BB")" ] && ok || bad "c: verdicts differ: a=[$(verdict "$BA")] b=[$(verdict "$BB")]"
[ -n "$(ledger "$TA")" ] && [ "$(ledger "$TA")" = "$(ledger "$TB")" ] && ok \
  || bad "c: done-ledger rows differ: a=[$(ledger "$TA")] b=[$(ledger "$TB")]"

# --- d. the lib is absent -----------------------------------------------------------
TD=$(new_harness 0); BD=$(seed_build "$TD" /clients/42)
RC_D=$(run "$TD")
grep -qF 'VERIFICATION MAP: lookup unavailable (lib absent)' <<<"$(prompt "$TD")" \
  && ok || bad "d: with no lib the prompt must say so (got: $(prompt "$TD" | head -c 400))"
grep -q '^VERIFICATION MAP: lookup unavailable (lib absent)' "$BD/qa-prod.md" \
  && ok || bad "d: with no lib qa-prod.md must say so"
[ "$RC_D" = "$RC_A" ] && [ "$(verdict "$BD")" = "$(verdict "$BA")" ] && [ "$(ledger "$TD")" = "$(ledger "$TA")" ] \
  && ok || bad "d: rc/verdict/ledger must match a (rc=$RC_D verdict=[$(verdict "$BD")] ledger=[$(ledger "$TD")])"

echo "postmerge-qa.bh-2005: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
