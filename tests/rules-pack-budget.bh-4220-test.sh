#!/bin/bash
# tests/rules-pack-budget.bh-4220-test.sh — the rules pack's budget arithmetic,
# pinned against a stubbed clock instead of the runner's (BH-4220).
#
# bin/rules-pack.sh reads `date +%s` twice (T0 and T1). A PATH `date` stub
# answers `+%s` with FAKE_NOW + n * DATE_STEP, so elapsed is exactly DATE_STEP.
# The pack is a tool copy with a one-row catalog (`noop`, a `true` cmd), and
# that copy is itself a one-commit git repo, so the pack's default tree (its
# own root) is the fixture. Run with --runner local and --jobs 1.
#   B1. over budget is a note, never a red: elapsed 10 > budget 5 is rc 0,
#       empty stdout, state clean, over_budget true and the stderr note.
#   B2. the boundary is strict: elapsed 5 with budget 5 is not over budget.
#   B3. under budget at the default: elapsed 0, budget 60, `0s of 60s`.
#   B4. the over-budget pack still wrote findings.txt and a green component.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/rules-pack-budget.bh-4220-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

unset RULES_PACK_BUDGET_S RULES_PACK_JOBS PROJECT
[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }
cd "$T" || exit 1
mkdir -p "$T/nolg"
FAKE_NOW=1790000000

# --- the fixture: the real pack, a one-row catalog, one commit on work ------
TL="$T/tool"
mkdir -p "$TL/bin/lib" "$TL/catalog"
cp "$DIR/bin/rules-pack.sh" "$TL/bin/rules-pack.sh"
cp "$DIR/bin/lib/rules-pack-checks.sh" "$TL/bin/lib/rules-pack-checks.sh"
printf 'noop\ttree\tcmd\ttrue\t-\tdoes nothing\n' > "$TL/catalog/rules-pack.tsv"
git -C "$TL" init -q -b work
git -C "$TL" add -A
git -C "$TL" -c user.name=t -c user.email=t@t commit -qm fixture
git -C "$TL" update-ref refs/remotes/origin/main HEAD

# --- the clock stub ---------------------------------------------------------
REAL_DATE=$(command -v date)
mkdir -p "$T/stub"
cat > "$T/stub/date" <<EOF
#!/bin/bash
if [ "\$#" -eq 1 ] && [ "\$1" = +%s ]; then
  n=\$(cat "\$DATE_CTR" 2>/dev/null || echo 0)
  echo \$((n + 1)) > "\$DATE_CTR"
  echo \$(($FAKE_NOW + n * DATE_STEP))
  exit 0
fi
exec "$REAL_DATE" "\$@"
EOF
chmod +x "$T/stub/date"

# pack <outname> <step> [env...] — sets RC, OUT, ERR
pack() {
  local o="$1" step="$2"; shift 2
  rm -f "$T/ctr-$o"
  env PATH="$T/stub:$PATH" DATE_CTR="$T/ctr-$o" DATE_STEP="$step" HARNESS="$T/nolg" "$@" \
    bash "$TL/bin/rules-pack.sh" --runner local --jobs 1 --out "$T/$o" >"$T/out" 2>"$T/err"
  RC=$?
  OUT=$(cat "$T/out"); ERR=$(cat "$T/err")
}
js() { jq -r "$2" "$T/$1/summary.json" 2>/dev/null; }

# --- B1 over budget is a note, never a red ---------------------------------
pack b1 10 RULES_PACK_BUDGET_S=5
[ "$RC" -eq 0 ] && ok || bad "B1 over budget rc $RC (want 0): $OUT $ERR"
[ -z "$OUT" ] && ok || bad "B1 over budget wrote stdout: $OUT"
[ "$(js b1 '"\(.state) \(.over_budget) \(.elapsed_s) \(.budget_s)"')" = "clean true 10 5" ] && ok \
  || bad "B1 summary $(js b1 '"\(.state) \(.over_budget) \(.elapsed_s) \(.budget_s)"') (want clean true 10 5)"
case "$ERR" in *"rules-pack: over budget (10s > 5s)"*) ok ;; *) bad "B1 stderr lacks the over-budget note: $ERR" ;; esac

# --- B4 the over-budget pack still wrote its artifacts ---------------------
[ -f "$T/b1/findings.txt" ] && [ ! -s "$T/b1/findings.txt" ] && ok || bad "B4 findings.txt missing or not empty"
[ "$(js b1 '.components[0]|"\(.id) \(.state)"')" = "noop green" ] && ok || bad "B4 component $(js b1 '.components[0]')"

# --- B2 the boundary is strict ----------------------------------------------
pack b2 5 RULES_PACK_BUDGET_S=5
[ "$(js b2 '"\(.over_budget) \(.elapsed_s) \(.budget_s)"')" = "false 5 5" ] && case "$ERR" in *"over budget"*) false ;; *) true ;; esac && ok \
  || bad "B2 at the boundary $(js b2 '"over=\(.over_budget) elapsed=\(.elapsed_s) budget=\(.budget_s)"'): $ERR"

# --- B3 under budget at the default ----------------------------------------
pack b3 0
[ "$(js b3 '"\(.over_budget) \(.elapsed_s) \(.budget_s)"')" = "false 0 60" ] && ok \
  || bad "B3 default $(js b3 '"over=\(.over_budget) elapsed=\(.elapsed_s) budget=\(.budget_s)"')"
case "$ERR" in *"0s of 60s") ok ;; *) bad "B3 stderr summary does not end '0s of 60s': $ERR" ;; esac

echo "rules-pack-budget.bh-4220: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
