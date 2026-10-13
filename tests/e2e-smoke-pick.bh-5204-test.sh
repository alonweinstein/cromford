#!/bin/bash
# tests/e2e-smoke-pick.bh-5204-test.sh — BH-5204 through bin/e2e-smoke.sh, the
# preview lane: one persona per changed app area (least privileged first), the
# picked persona's flows narrowed to the areas it was picked for, and a
# `PERSONAS: picked …` line in e2e.md right before the `Personas:` count line.
#
# The real script runs in a scratch tree; node, wait-preview.sh, qa-unbanned.sh
# and qa-account.sh are stubs copied from tests/e2e-smoke-personas-test.sh.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/bin" "$T/out" "$T/repo/qa"
scratch_install_closure bin/e2e-smoke.sh "$T" >/dev/null || { echo "FAIL: closure"; exit 1; }
cp "$DIR/bin/e2e-smoke.mjs" "$T/bin/"
cp "$DIR/catalog/e2e-smoke-routes.json" "$T/routes.json"
printf 'demo-os team_x prj_x os.demo.example\n' > "$T/vercel.conf"
cat > "$T/repo/qa/apps.json" <<'JSON'
{"version":1,"apps":{"finance":["apps/web/app/finance/**"],"ops":["apps/web/app/ops/**"],"shared":["packages/**","apps/web/lib/**"]}}
JSON
cat > "$T/personas.json" <<'JSON'
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
cp "$T/personas.json" "$T/repo/qa/personas.json"

cat > "$T/bin/wait-preview.sh" <<'EOF'
#!/bin/bash
echo "https://demo-os-git-feat-abc123.vercel.app"
EOF
cat > "$T/bin/fakenode" <<'EOF'
#!/bin/bash
printf 'ARGV %s\n' "$*" >> "$NODE_SINK"
SMOKE_OUT="${3:-}"; SCOPEDF=""; PERSONA=""
while [ $# -gt 0 ]; do
  case "$1" in --flows) SCOPEDF="${2:-}"; shift ;; --persona) PERSONA="${2:-}"; shift ;; esac
  shift
done
if [ -n "$SCOPEDF" ]; then
  jq -r --arg p "$PERSONA" '.personas[]|select(.id==$p)|.id as $i|.flows[]|"FLOW \($i) \(.id) pass steps=1/1 shot=-"' "$SCOPEDF"
  exit 0
fi
printf 'ROUTE 200 / console=0 ok\nE2E COVERAGE: routes=1 failed=0\nE2E: PASS\n' > "$SMOKE_OUT/e2e.md"
EOF
cat > "$T/bin/qa-unbanned-stub" <<'EOF'
#!/bin/bash
printf '%s %s\n' "$1" "$2" >> "$UNBAN_SINK"
shift 3
exec "$@"
EOF
cat > "$T/bin/qa-account-stub" <<'EOF'
#!/bin/bash
case "${2:-}" in
  qa-viewer) echo user_v ;; qa-finance) echo user_f ;; qa-ops) echo user_o ;; qa-admin) echo user_a ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/"*

run() {
  rm -rf "$T/out"; mkdir -p "$T/out"; : > "$T/node.log"; : > "$T/unban.log"
  env -u QA_PERSONAS_PER_AREA -u E2E_MAX_PERSONAS QA_CLERK_SECRET_KEY=sk_test_fake \
    E2E_CHANGED_FILES="$T/changed.txt" \
    HARNESS="$T" VERCEL_CONF="$T/vercel.conf" E2E_ROUTES_FILE="$T/routes.json" \
    WAIT_PREVIEW="$T/bin/wait-preview.sh" E2E_NODE="$T/bin/fakenode" \
    E2E_QA_UNBANNED="$T/bin/qa-unbanned-stub" E2E_QA_ACCOUNT="$T/bin/qa-account-stub" \
    NODE_SINK="$T/node.log" UNBAN_SINK="$T/unban.log" "$@" \
    bash "$T/bin/e2e-smoke.sh" demo-os example-org/demo-os abc123def456 "$T/out" "$T/repo" \
      > "$T/stdout.log" 2>&1
  RC=$?
}
changed() { printf '%s\n' "$@" > "$T/changed.txt"; }
driven()  { grep -o -- '--persona [a-z-]*' "$T/node.log" | cut -d' ' -f2 | tr '\n' ' ' | sed 's/ $//'; }

# ── E1 finance-only ─────────────────────────────────────────────────────────
changed apps/web/app/finance/a.tsx
run
[ "$RC" = 0 ] && [ "$(driven)" = finance-lead ] && ok || bad "E1 finance-only drives finance-lead (rc=$RC, got $(driven))"
grep -q -- '--persona finance-lead --preview' "$T/node.log" && ok || bad "E1 the drive is --preview"
PL=$(grep -n '^PERSONAS: picked finance:finance-lead; skipped (not relevant to the diff): viewer ops-lead; skipped (area already covered): admin$' "$T/out/e2e.md" | cut -d: -f1)
CL=$(grep -nx 'Personas: 1 in scope, 1 driven (mode preview)' "$T/out/e2e.md" | cut -d: -f1)
[ -n "$PL" ] && [ -n "$CL" ] && [ "$((PL + 1))" = "$CL" ] \
  && ok || bad "E1 PERSONAS line right before the count line: $(cat "$T/out/e2e.md")"

# ── E2 finance+ops, shared-only, admin never ────────────────────────────────
changed apps/web/app/finance/a.tsx apps/web/app/ops/q.tsx
run
[ "$(driven)" = "finance-lead ops-lead" ] && ok || bad "E2 finance+ops drives finance-lead,ops-lead (got $(driven))"
grep -q qa-admin "$T/unban.log" && bad "E2 admin's account was unbanned" || ok
changed packages/ui/x.ts
run
[ "$(driven)" = viewer ] && ok || bad "E2 shared-only drives viewer (got $(driven))"
grep -q qa-admin "$T/unban.log" && bad "E2 admin's account was unbanned" || ok

# ── E3 flow narrowing reaches the drive ─────────────────────────────────────
jq '.personas = ([.personas[3]] + .personas[0:3])' "$T/personas.json" > "$T/repo/qa/personas.json"
changed apps/web/app/ops/q.tsx
run
[ "$(driven)" = admin ] && ok || bad "E3 admin-first ops diff drives admin (got $(driven))"
jq -e '[.personas[0].flows[].id] == ["users"]' "$T/out/e2e-flows/scoped.json" >/dev/null 2>&1 \
  && ok || bad "E3 scoped.json must not carry billing: $(jq -c '[.personas[].flows[].id]' "$T/out/e2e-flows/scoped.json" 2>&1)"
grep -q '^FLOW admin billing' "$T/out/e2e.md" && bad "E3 billing was driven" || ok
grep -q '^PERSONAS: .*; flows not relevant to the diff: admin/billing$' "$T/out/e2e.md" \
  && ok || bad "E3 the dropped flow is named: $(grep PERSONAS "$T/out/e2e.md")"
cp "$T/personas.json" "$T/repo/qa/personas.json"

# ── E4 no lane-gate.sh on the box: still runs, per-area from env then 1 ─────
rm -f "$T/bin/lib/lane-gate.sh"
changed apps/web/app/finance/a.tsx
run
[ "$RC" = 0 ] && [ "$(driven)" = finance-lead ] && ok || bad "E4 without lane-gate.sh (rc=$RC, got $(driven))"
run QA_PERSONAS_PER_AREA=2
[ "$(driven)" = "finance-lead admin" ] && ok || bad "E4 env per-area 2 (got $(driven))"
run QA_PERSONAS_PER_AREA=2 E2E_MAX_PERSONAS=1
[ "$(driven)" = finance-lead ] && grep -q '^FLOW admin billing blocked not driven (persona cap)' "$T/out/e2e.md" \
  && ok || bad "E4 the cap stays the ceiling (got $(driven))"

echo "e2e-smoke-pick: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
