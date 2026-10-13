#!/bin/bash
# tests/minter-test.sh — minter-lane matrix against `wrangler dev --local`.
# Run from locks-worker/: tests/minter-test.sh   (exit 0 = all pass)
# Red-first: this matrix FAILS against the pre-2026-08-21 worker (no minter
# lane) and passes after. MINT_CAP=2 in dev vars exercises the rate cap.
set -uo pipefail
cd "$(dirname "$0")/.."
PORT=8788
B="http://127.0.0.1:$PORT"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

rm -rf .wrangler/state 2>/dev/null
ADMIN_TOKEN=testadmin MINT_CAP=2 npx wrangler dev --local --port "$PORT" \
  --var ADMIN_TOKEN:testadmin --var MINT_CAP:2 --var "HARNESS_TOKENS:{}" \
  > /tmp/wrangler-dev.log 2>&1 &
WPID=$!
trap 'kill $WPID 2>/dev/null; wait $WPID 2>/dev/null' EXIT
for i in $(seq 1 60); do curl -s -m 2 "$B/v1/locks" >/dev/null 2>&1 && break; sleep 1; done
# schema into the local D1
npx wrangler d1 execute harness-locks --local --file schema.sql >/dev/null 2>&1

A='-H Authorization:\ Bearer\ testadmin'
req() { curl -s -m 10 -w "\n%{http_code}" "$@"; }
code() { tail -1 <<<"$1"; }
body() { sed '$d' <<<"$1"; }

# 1. admin mints a machine token (existing behavior intact)
R=$(req -X POST -H "Authorization: Bearer testadmin" -H "Content-Type: application/json" \
  -d '{"name":"fleet-test","ttl_days":30}' "$B/v1/admin/tokens")
[ "$(code "$R")" = 201 ] && grep -q '"role":"machine"' <<<"$(body "$R")" && ok || bad "1 admin machine mint: $R"
FLEET_TOK=$(body "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])" 2>/dev/null)

# 2. admin minter mint without prefix -> 400
R=$(req -X POST -H "Authorization: Bearer testadmin" -H "Content-Type: application/json" \
  -d '{"name":"partner-minter-x","role":"minter"}' "$B/v1/admin/tokens")
[ "$(code "$R")" = 400 ] && ok || bad "2 minter-no-prefix should 400: $R"

# 3. admin mints a minter with prefix
R=$(req -X POST -H "Authorization: Bearer testadmin" -H "Content-Type: application/json" \
  -d '{"name":"partner-minter-test","role":"minter","prefix":"partner-","ttl_days":90}' "$B/v1/admin/tokens")
[ "$(code "$R")" = 201 ] && grep -q '"role":"minter"' <<<"$(body "$R")" && ok || bad "3 admin minter mint: $R"
MINTER_TOK=$(body "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])" 2>/dev/null)

# 4. minter mints inside its prefix -> 201 machine
R=$(req -X POST -H "Authorization: Bearer $MINTER_TOK" -H "Content-Type: application/json" \
  -d '{"name":"partner-office-9","ttl_days":90}' "$B/v1/admin/tokens")
[ "$(code "$R")" = 201 ] && grep -q '"role":"machine"' <<<"$(body "$R")" && ok || bad "4 minter in-prefix mint: $R"
OFFICE_TOK=$(body "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])" 2>/dev/null)

# 5. minter mints outside prefix -> 403
R=$(req -X POST -H "Authorization: Bearer $MINTER_TOK" -H "Content-Type: application/json" \
  -d '{"name":"project-1-sneaky"}' "$B/v1/admin/tokens")
[ "$(code "$R")" = 403 ] && ok || bad "5 out-of-prefix should 403: $R"

# 6. minter mints a minter -> 403
R=$(req -X POST -H "Authorization: Bearer $MINTER_TOK" -H "Content-Type: application/json" \
  -d '{"name":"partner-minter-2","role":"minter","prefix":"partner-"}' "$B/v1/admin/tokens")
[ "$(code "$R")" = 403 ] && ok || bad "6 minter-mints-minter should 403: $R"

# 7. minter list -> only its prefix
R=$(req -H "Authorization: Bearer $MINTER_TOK" "$B/v1/admin/tokens")
[ "$(code "$R")" = 200 ] && ! grep -q "fleet-test" <<<"$(body "$R")" && grep -q "partner-office-9" <<<"$(body "$R")" \
  && ok || bad "7 minter list scoping: $R"

# 8. minted machine token can hold a lease
R=$(req -X POST -H "Authorization: Bearer $OFFICE_TOK" -H "Content-Type: application/json" \
  -d '{"key":"project-1:TK-999","ttl_s":120}' "$B/v1/acquire")
[ "$(code "$R")" = 201 ] && grep -q '"holder":"partner-office-9"' <<<"$(body "$R")" && ok || bad "8 machine lease: $R"

# 9. minter token CANNOT hold a lease (lane separation)
R=$(req -X POST -H "Authorization: Bearer $MINTER_TOK" -H "Content-Type: application/json" \
  -d '{"key":"project-1:TK-998","ttl_s":120}' "$B/v1/acquire")
[ "$(code "$R")" = 401 ] && ok || bad "9 minter lease should 401: $R"

# 10. minter revoking an out-of-prefix token -> 403
R=$(req -X POST -H "Authorization: Bearer $MINTER_TOK" -H "Content-Type: application/json" \
  -d '{"name":"fleet-test"}' "$B/v1/admin/revoke")
[ "$(code "$R")" = 403 ] && ok || bad "10 out-of-prefix revoke should 403: $R"

# 11. minter revokes its own machine token -> 200, token dies
R=$(req -X POST -H "Authorization: Bearer $MINTER_TOK" -H "Content-Type: application/json" \
  -d '{"name":"partner-office-9"}' "$B/v1/admin/revoke")
[ "$(code "$R")" = 200 ] && ok || bad "11 in-prefix revoke: $R"
R=$(req -X POST -H "Authorization: Bearer $OFFICE_TOK" -H "Content-Type: application/json" \
  -d '{"key":"project-1:TK-997","ttl_s":120}' "$B/v1/acquire")
[ "$(code "$R")" = 401 ] && ok || bad "11b revoked token should 401: $R"

# 12. mint cap (MINT_CAP=2; one mint used in #4) -> second ok, third 429
R=$(req -X POST -H "Authorization: Bearer $MINTER_TOK" -H "Content-Type: application/json" \
  -d '{"name":"partner-office-10"}' "$B/v1/admin/tokens")
[ "$(code "$R")" = 201 ] && ok || bad "12a second mint within cap: $R"
R=$(req -X POST -H "Authorization: Bearer $MINTER_TOK" -H "Content-Type: application/json" \
  -d '{"name":"partner-office-11"}' "$B/v1/admin/tokens")
[ "$(code "$R")" = 429 ] && ok || bad "12b third mint should 429: $R"

# 13. log endpoint: admin 200 with mint entries; minter 403
R=$(req -H "Authorization: Bearer testadmin" "$B/v1/admin/log?action=token-mint")
[ "$(code "$R")" = 200 ] && grep -q "partner-minter-test" <<<"$(body "$R")" && ok || bad "13a admin log: $R"
R=$(req -H "Authorization: Bearer $MINTER_TOK" "$B/v1/admin/log")
[ "$(code "$R")" = 403 ] && ok || bad "13b minter log should 403: $R"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
