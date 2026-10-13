#!/bin/bash
# tests/pool-account.bh-1657-test.sh — BH-1657 test (a): a project pinned to its
# own account takes NO pool lease, and the bundle ships the pinned token, never
# the project-6 or a max token. An unpinned project still leases.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TOK_MASTER="sk-ant-oat01-FIXTURE-MASTER-token"
TOK_OWN="sk-ant-oat01-FIXTURE-project-3-own-token"
mkdir -p "$T/bin/lib" "$T/env/accounts.d" "$T/env/tokens.d" "$T/state/quota" "$T/logs" "$T/fly" "$T/bundle"
for f in account-pick.sh auth-fingerprint.sh; do cp "$DIR/bin/$f" "$T/bin/$f"; chmod +x "$T/bin/$f"; done
cp "$DIR/bin/lib/pool-account.sh" "$DIR/bin/lib/project-account.sh" "$T/bin/lib/"
printf 'claude 4\ncodex 4\n' > "$T/fly/account-capacity.conf"
printf 'ACCOUNT_NAME=max1\nACCOUNT_VENDOR=claude\nACCOUNT_ENABLED=1\nACCOUNT_PRIORITY=20\nACCOUNT_LABEL=max1@fixture.test\nCLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-max1\n' > "$T/env/accounts.d/max1.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-max1\n' > "$T/env/tokens.d/max1-setup-token.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOK_OWN" > "$T/env/accounts.d/own:project-3.env"
jq -n '{account:"max1",vendor:"claude",status:"unreadable",source:"none",polled_at:(now|todate),five_hour:null,seven_day:null,per_model:{}}' > "$T/state/quota/max1.json"
mkbundle() { printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nRUNNER_EXECUTE=claude\n' "$TOK_MASTER" > "$T/bundle/global.env"; }
lease() { env HARNESS="$T" JOBS_URL= ACCOUNT_OWN_PROJECTS=project-3=own:project-3 \
  bash -c '. "$0"; pool_account_lease "$@"' "$T/bin/lib/pool-account.sh" "$@" 2>"$T/lease.err"; }

mkbundle
out=$(lease project-3 BH-1 "$T/bundle/global.env" m1)
case "$out" in *"name=default reason=own_account label=own:project-3 "*) ok ;; *) bad "pinned answer: $out" ;; esac
[ -z "$(ls -A "$T/state/quota/leases" 2>/dev/null)" ] && ok || bad "pinned project wrote a lease"
grep -qxF "CLAUDE_CODE_OAUTH_TOKEN=$TOK_OWN" "$T/bundle/global.env" && ok || bad "bundle lacks own token"
grep -q "MASTER\|max1" "$T/bundle/global.env" && bad "bundle still carries project-6/max" || ok
grep -rqF "$TOK_OWN" "$T/lease.err" "$T/logs" 2>/dev/null && bad "own token leaked to logs" || ok

ov=$(jq -r '.[]' "$T/bundle/auth-accounts.local.json" 2>/dev/null)
[ "$ov" = own:project-3 ] && ok || bad "overlay label must be own:project-3, got '$ov'"

# unarmed pool: a pinned project still gets its own token, never project-6
mkbundle; rm -f "$T/bundle/auth-accounts.local.json"
out=$(env HARNESS="$T" JOBS_URL= POOL_ACCOUNT_ROUTING=0 ACCOUNT_OWN_PROJECTS=project-3=own:project-3 \
  bash -c '. "$0"; pool_account_lease "$@"' "$T/bin/lib/pool-account.sh" project-3 BH-3 "$T/bundle/global.env" m3 2>/dev/null)
grep -qxF "CLAUDE_CODE_OAUTH_TOKEN=$TOK_OWN" "$T/bundle/global.env" && ok || bad "unarmed pinned: $out"

# pinned but token file missing: fail closed, no project-6 token shipped
mkbundle
out=$(env HARNESS="$T" JOBS_URL= ACCOUNT_OWN_PROJECTS=project-9=own:project-9 \
  bash -c '. "$0"; pool_account_lease "$@"' "$T/bin/lib/pool-account.sh" project-9 BH-4 "$T/bundle/global.env" m4 2>/dev/null)
case "$out" in *"reason=own_account_unavailable label=own:project-9"*) ok ;; *) bad "unavailable answer: $out" ;; esac
grep -q MASTER "$T/bundle/global.env" && bad "unavailable pinned shipped project-6" || ok
[ -z "$(ls -A "$T/state/quota/leases" 2>/dev/null)" ] && ok || bad "unavailable pinned leased"

mkbundle
out=$(lease project-5-os BH-2 "$T/bundle/global.env" m2)
case "$out" in *"name=max1 "*) ok ;; *) bad "unpinned must still lease: $out" ;; esac

echo "pool-account.bh-1657: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
