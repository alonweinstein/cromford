#!/bin/bash
# tests/locks-worker-mint-cap.bh-5202-test.sh — BH-5202: the minter cap the
# live harness-locks worker runs (MINT_CAP=20) is pinned in
# locks-worker/wrangler.jsonc `vars`, so a plain `wrangler deploy` from the repo
# keeps it instead of dropping the var and falling back to the code default 5.
#   C1 wrangler.jsonc parses and vars.MINT_CAP is exactly the string "20"
#   C2 vars carries no secret (ADMIN_TOKEN / HARNESS_TOKENS stay secrets)
#   C3 the rest of the config is unchanged (name, main, the one D1 binding)
#   C4 src/index.js keeps the code fallback `Number(env.MINT_CAP) || 5`
#   C5 the index.js minter comment says 20 / wrangler.jsonc, not "(default 5)"
#   C6 docs/HARNESS-COORDINATION.md says 20 / wrangler.jsonc / fallback 5
#   C7 `wrangler deploy --dry-run` on a scratch copy of locks-worker reports
#      env.MINT_CAP ("20") — the deploy CLI itself reading the config. Runs only
#      when wrangler is already in the npx cache (never installs); SKIP otherwise.
# Reads repo files only; C7 works in a copy under the scratch tree $T. Exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
R="$(cd "$(dirname "$0")/.." && pwd)"
LW="${LOCKS_WORKER_DIR:-$R/locks-worker}"
DOC="${COORD_DOC:-$R/docs/HARNESS-COORDINATION.md}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }

# C1-C3: one python pass over the config (comment lines stripped first).
CFG_OUT=$(python3 -I - "$LW/wrangler.jsonc" <<'PY'
import json, re, sys
src = open(sys.argv[1]).read()
src = "\n".join(l for l in src.splitlines() if not re.match(r"\s*//", l))
try:
    d = json.loads(src)
except Exception as e:
    print("C1 parse:", e); print("C2 parse"); print("C3 parse"); sys.exit(0)
v = d.get("vars")
print("C1 ok" if isinstance(v, dict) and v.get("MINT_CAP") == "20"
      else "C1 vars.MINT_CAP is %r" % ((v or {}).get("MINT_CAP") if isinstance(v, dict) else v))
leak = [k for k in ("ADMIN_TOKEN", "HARNESS_TOKENS") if isinstance(v, dict) and k in v]
print("C2 ok" if not leak else "C2 secret in vars: %s" % leak)
dbs = d.get("d1_databases") or []
c3 = (d.get("name") == "harness-locks" and d.get("main") == "src/index.js"
      and len(dbs) == 1 and dbs[0].get("binding") == "DB"
      and dbs[0].get("database_id") == "00000000-0000-0000-0000-000000000003")
print("C3 ok" if c3 else "C3 config drifted: %s" % json.dumps({k: d.get(k) for k in ("name", "main", "d1_databases")}))
PY
)
for c in C1 C2 C3; do
  line=$(grep "^$c " <<<"$CFG_OUT")
  if [ "$line" = "$c ok" ]; then ok "$c"; else bad "${line:-$c no result}"; fi
done

IDX="$LW/src/index.js"
# C4: the code fallback stays 5 (the ticket keeps it; only the deployed value moves).
if [ -f "$IDX" ] && grep -qF 'Number(env.MINT_CAP) || 5' "$IDX"; then ok "C4"
else bad "C4 index.js lost the 'Number(env.MINT_CAP) || 5' fallback"; fi

# C5: the minter comment block (the `//` lines naming MINT_CAP) states 20 + wrangler.jsonc.
CMT=$(awk '/^[[:space:]]*\/\// && /capped at MINT_CAP/ {f=1} f && /^[[:space:]]*\/\// {print} f && !/^[[:space:]]*\/\// {exit}' "$IDX" 2>/dev/null)
if [ -n "$CMT" ] && grep -Eq '\b20\b' <<<"$CMT" && grep -q 'wrangler.jsonc' <<<"$CMT" \
   && ! grep -q '(default 5)' <<<"$CMT"; then ok "C5"
else bad "C5 index.js MINT_CAP comment: ${CMT:-<not found>}"; fi

# C6: the coordination doc's MINT_CAP bullet (that line through the end of the bullet).
BUL=$(awk '/capped at MINT_CAP/ {f=1} f {print} f && /^- / && !/capped at MINT_CAP/ {exit}' "$DOC" 2>/dev/null | sed '$d')
[ -z "$BUL" ] && BUL=$(grep -A3 'capped at MINT_CAP' "$DOC" 2>/dev/null)
if [ -n "$BUL" ] && grep -Eq '\b20\b' <<<"$BUL" && grep -q 'wrangler.jsonc' <<<"$BUL" \
   && tr '\n' ' ' <<<"$BUL" | grep -Eqi 'fallback[^.]*\b5\b' && ! grep -qF '(worker var, default 5)' "$DOC"; then ok "C6"
else bad "C6 HARNESS-COORDINATION.md MINT_CAP bullet: ${BUL:-<not found>}"; fi

# C7: the deploy CLI's own reading of the config, on a scratch copy.
if timeout 60 npx --no-install wrangler@4 --version >/dev/null 2>&1; then
  S="$T/c7"; mkdir -p "$S"
  cp -r "$LW/src" "$LW/wrangler.jsonc" "$S/"
  OUT=$(cd "$S" && timeout 120 npx --no-install wrangler@4 deploy --dry-run --outdir "$S/out" 2>&1); RC=$?
  if [ "$RC" = 0 ] && grep -qF 'env.MINT_CAP ("20")' <<<"$OUT"; then ok "C7"
  else bad "C7 wrangler deploy --dry-run rc=$RC, no env.MINT_CAP (\"20\") binding: $(grep -F 'env.' <<<"$OUT" | tr -s ' ')"; fi
else
  echo "SKIP C7 wrangler not in the npx cache (npx --yes wrangler@4 --version to enable)"
fi

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
