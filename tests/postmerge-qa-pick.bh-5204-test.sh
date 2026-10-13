#!/bin/bash
# tests/postmerge-qa-pick.bh-5204-test.sh — BH-5204 through bin/postmerge-qa.sh,
# the production lane: the planned files decide which app areas changed, and the
# lane drives ONE persona per changed area (least privileged first), never a
# role whose area the diff did not touch, and says in qa-prod.md and its log
# who it picked and who it skipped and why.
#
# The fakes are copied from tests/postmerge-qa-personas-test.sh (a copy, not a
# source, so the two suites cannot break each other); the persona file is this
# ticket's four-role fixture, built in the suite.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export ENDPOINT_CLERK=https://api.clerk.com
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
BASE="$T"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1

new_harness() {
  local T F; T=$(mktemp -d "$BASE/h-XXXXXX")
  mkdir -p "$T/bin/lib" "$T/fakebin" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" \
           "$T/builds" "$T/clerk" "$T/repo/qa"
  for F in postmerge-qa.sh qa-unbanned.sh qa-clerk-ban.sh fleet-conf.sh prod-url.sh findings-log.sh; do
    scratch_install_closure "bin/$F" "$T" >/dev/null || { echo "FAIL: closure of $F"; exit 1; }
  done
  cp "$DIR/bin/alert_family.py" "$T/bin/"
  chmod +x "$T"/bin/*.sh
  printf 'project-3 example-org/project-3 https://os.project-3.test /api/board 6 box-project-3-2\n' > "$T/fleet.conf"
  : > "$T/env/global.env"
  mrs_fixture "$T" project-3
  printf 'QA_CLERK_SECRET_KEY=sk_test_fake\nQA_TEST_USER_ID=user_QA\n' > "$T/env/project-3.env"
  echo active > "$T/clerk/user_QA"
  printf '#!/bin/bash\necho "$*" >> "%s/beats.txt"\nexit 0\n' "$T" > "$T/bin/beat.sh"
  printf '#!/bin/bash\necho "$*" >> "%s/agent-calls.txt"\nexit 0\n' "$T" > "$T/bin/agent-call.sh"
  cat > "$T/bin/qa-account.sh" <<'EOF'
#!/bin/bash
case "${2:-}" in
  qa-viewer) echo user_VIEWER ;; qa-finance) echo user_FINANCE ;;
  qa-ops) echo user_OPS ;;       qa-admin) echo user_ADMIN ;;
  *) echo "no QA account for ${1:-}/${2:-}" >&2; exit 1 ;;
esac
EOF
  chmod +x "$T/bin/beat.sh" "$T/bin/agent-call.sh" "$T/bin/qa-account.sh"
  cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$GH_SINK"
case "$*" in
  *"pr view"*state,mergeCommit*) printf '%s\t%s\n' MERGED deadbeefcafe1234 ;;
  *"deployments/"*"/statuses"*)  echo success ;;
  *deployments*)                 echo 99 ;;
esac
exit 0
EOF
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
  # Fake node: one row per flow of the named persona from the scoped file.
  cat > "$T/fakebin/node" <<'EOF'
#!/bin/bash
echo "$*" >> "$NODE_SINK"
OUT="${4:-}"; FLOWS=""; PERSONA=""; PREV=""
for A in "$@"; do
  case "$PREV" in --flows) FLOWS="$A" ;; --persona) PERSONA="$A" ;; esac
  PREV="$A"
done
if [ -z "$FLOWS" ]; then echo "QA COVERAGE: screens=0 flows=0 shots=0"; echo "QA: PASS"; exit 0; fi
mkdir -p "$OUT"
jq -r --arg p "$PERSONA" '.personas[] | select(.id == $p) | .flows[]
  | if .skipped then "FLOW \($p) \(.id) skipped (write flow, production)"
    else "FLOW \($p) \(.id) pass steps=1/1 shot=-" end' "$FLOWS"
echo "QA: PASS"
exit 0
EOF
  chmod +x "$T/fakebin/"*
  cat > "$T/repo/qa/apps.json" <<'JSON'
{"version":1,"apps":{"finance":["apps/web/app/finance/**"],"ops":["apps/web/app/ops/**"],"shared":["packages/**","apps/web/lib/**"]}}
JSON
  cat > "$T/repo/qa/personas.json" <<'JSON'
{"version":1,"personas":[
 {"id":"viewer","role":"qa-viewer","sign_in":"clerk-ticket","apps":["shared"],"out_of_bounds":["/settings"],
  "flows":[{"id":"home","route":"/","observable":"home renders","production_safe":true,"steps":[{"goto":"/"}]}]},
 {"id":"finance-lead","role":"qa-finance","sign_in":"clerk-ticket","apps":["finance","shared"],"out_of_bounds":["refunds","mark-paid"],
  "flows":[
   {"id":"invoices","apps":["finance"],"route":"/finance/invoices","observable":"invoice table","production_safe":true,"steps":[{"goto":"/finance/invoices"}]},
   {"id":"ledger","route":"/finance/ledger","observable":"ledger renders","production_safe":true,"steps":[{"goto":"/finance/ledger"}]},
   {"id":"close-month","apps":["finance"],"route":"/finance/close","observable":"month closed","production_safe":false,"cleanup":"reopen the month","steps":[{"goto":"/finance/close"},{"click":"button"}]}]},
 {"id":"ops-lead","role":"qa-ops","sign_in":"clerk-ticket","apps":["ops"],"out_of_bounds":["send SMS"],
  "flows":[{"id":"queue","route":"/ops/queue","observable":"queue renders","production_safe":true,"steps":[{"goto":"/ops/queue"}]}]},
 {"id":"admin","role":"qa-admin","sign_in":"clerk-ticket","apps":["finance","ops","shared"],"out_of_bounds":["role changes","deletes"],
  "flows":[
   {"id":"users","apps":["ops"],"route":"/ops/users","observable":"users table","production_safe":true,"steps":[{"goto":"/ops/users"}]},
   {"id":"billing","apps":["finance"],"route":"/finance/billing","observable":"billing renders","production_safe":true,"steps":[{"goto":"/finance/billing"}]}]}
]}
JSON
  printf '%s' "$T"
}
seed_build() { # seed_build <harness> <name> <planned-files...>
  local T="$1" name="$2" d; shift 2
  d="$T/builds/$name"; mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/project-3/pull/7" > "$d/RESULT"
  printf '# plan\n\n## QA screens\n\n/\n' > "$d/plan.md"
  printf '%s\n' "$@" > "$d/planned-files.txt"
  printf '%s' "$d"
}
run() { # run <harness> [env assignments...]
  local T="$1"; shift
  env -i ENDPOINT_CLERK="$ENDPOINT_CLERK" PATH="$T/fakebin:/usr/bin:/bin" HOME="$T" \
      HARNESS="$T" FLEET_CONF="$T/fleet.conf" QA_ACCOUNTS="$T/state/qa-accounts.json" \
      CLERK_STATE_DIR="$T/clerk" GH_SINK="$T/gh.txt" NODE_SINK="$T/node.txt" \
      QA_REPO_DIR="$T/repo" "$@" "$T/bin/postmerge-qa.sh" project-3 2>&1
}
drives()  { [ -f "$1/node.txt" ] || { echo 0; return 0; }; grep -c 'qa-drive.mjs' "$1/node.txt"; }
driven()  { grep -o -- '--persona [a-z-]*' "$1/node.txt" 2>/dev/null | cut -d' ' -f2 | tr '\n' ' ' | sed 's/ $//'; }
# L4 on every run: production only, the write flow never executed
prod_only() { # prod_only <label> <harness> <build>
  local n p
  n=$(grep -c 'qa-drive\.mjs' "$2/node.txt"); p=$(grep -c 'qa-drive\.mjs.*--production' "$2/node.txt")
  [ "$n" = "$p" ] && ! grep -q -- '--preview' "$2/node.txt" && ok || bad "$1: L4 --production on every drive, never --preview"
}

# ── L1 finance-only: one drive, finance-lead ────────────────────────────────
T=$(new_harness); B=$(seed_build "$T" project-3-TK-1-202610070000 apps/web/app/finance/a.tsx)
run "$T" >/dev/null
[ "$(drives "$T")" = 1 ] && [ "$(driven "$T")" = finance-lead ] \
  && ok || bad "L1 finance-only must drive finance-lead once (got $(drives "$T"): $(driven "$T"))"
[ -f "$T/clerk/user_FINANCE" ] && [ ! -f "$T/clerk/user_ADMIN" ] && [ ! -f "$T/clerk/user_VIEWER" ] && [ ! -f "$T/clerk/user_OPS" ] \
  && ok || bad "L1 only the finance QA account may be touched: $(ls "$T/clerk" | tr '\n' ' ')"
grep -qF -- '- PERSONAS: finance-lead (mode production) — picked finance:finance-lead; skipped (not relevant to the diff): viewer ops-lead; skipped (area already covered): admin' "$B/qa-prod.md" \
  && ok || bad "L1 PERSONAS line: $(grep -o 'PERSONAS: .*' "$B/qa-prod.md" 2>/dev/null)"
grep -q '^FLOW finance-lead close-month skipped (write flow, production)' "$B/qa-prod.md" \
  && ok || bad "L4 the write flow is reported skipped in production"
prod_only L1 "$T"
# ── L6 the log line ─────────────────────────────────────────────────────────
[ "$(grep -c 'TK-1-202610070000: PERSONAS: picked finance:finance-lead' "$T/logs/postmerge-qa.log")" = 1 ] \
  && ok || bad "L6 one PERSONAS: picked log line: $(grep PERSONAS "$T/logs/postmerge-qa.log")"

# ── L2 finance + ops: two drives, no admin, no viewer ───────────────────────
T=$(new_harness); B=$(seed_build "$T" project-3-TK-2-202610070000 apps/web/app/finance/a.tsx apps/web/app/ops/q.tsx)
run "$T" >/dev/null
[ "$(driven "$T")" = "finance-lead ops-lead" ] && ok || bad "L2 finance+ops drives finance-lead,ops-lead (got $(driven "$T"))"
prod_only L2 "$T"

# ── L3 shared-only: the least privileged role ───────────────────────────────
T=$(new_harness); B=$(seed_build "$T" project-3-TK-3-202610070000 packages/ui/x.ts)
run "$T" >/dev/null
[ "$(driven "$T")" = viewer ] && ok || bad "L3 shared-only drives viewer (got $(driven "$T"))"
prod_only L3 "$T"

# ── L5 the knob, and the cap still the ceiling ──────────────────────────────
T=$(new_harness); B=$(seed_build "$T" project-3-TK-5-202610070000 apps/web/app/finance/a.tsx)
run "$T" QA_PERSONAS_PER_AREA=2 >/dev/null
[ "$(driven "$T")" = "finance-lead admin" ] && ok || bad "L5 per-area 2 drives finance-lead,admin (got $(driven "$T"))"
T=$(new_harness); B=$(seed_build "$T" project-3-TK-5b-202610070000 apps/web/app/finance/a.tsx)
run "$T" QA_PERSONAS_PER_AREA=2 E2E_MAX_PERSONAS=1 >/dev/null
[ "$(driven "$T")" = finance-lead ] && ok || bad "L5 cap 1 drives one (got $(driven "$T"))"
grep -q '^FLOW admin billing blocked not driven (persona cap)' "$B/qa-prod.md" \
  && ok || bad "L5 the capped persona is printed as not driven"

# ── L7 nobody owns the change: NONE, said why ──────────────────────────────
T=$(new_harness); B=$(seed_build "$T" project-3-TK-7-202610070000 README.md)
run "$T" >/dev/null
grep -q 'PERSONAS: NONE (no persona owns a changed area)' "$B/qa-prod.md" \
  && ok || bad "L7 NONE note: $(grep -o 'PERSONAS: .*' "$B/qa-prod.md" 2>/dev/null)"

echo "postmerge-qa-pick: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
