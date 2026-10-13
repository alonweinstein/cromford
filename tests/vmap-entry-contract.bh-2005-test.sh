#!/bin/bash
# tests/vmap-entry-contract.bh-2005-test.sh — the contract slice of BH-2005
# (built as BH-2034): the `**What usually lies:**` field in the verification-map
# TEMPLATE, and bin/lib/vmap-entry.sh, the lib every later slice sources.
#
# Sources the REAL lib and runs it under `set -u`, so an unbound-variable slip in
# the lib aborts this suite. Asserts on what the functions print and return.
#
#   1  TEMPLATE carries the field exactly once, after **Verify it works:**
#   2  sourcing defines all four functions and VMAP_LIES_HEADING
#   3  vmap_lies prints only the field's bullets (not the neighbours')
#   4  no field / missing file / no argument: nothing, rc 0
#   5  vmap_lies on the real TEMPLATE prints its four example bullets
#   6  the three lookups on a repo with no map: nothing / none, rc 0
#   7  docs/VMAP-BACKFILL-TICKET.md mirrors the field
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/vmap-entry-contract.bh-2005-test.sh
set -u
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
TPL="$DIR/docs/verification-map/TEMPLATE.md"

ok=0; bad=0
pass() { ok=$((ok+1)); }
fail() { bad=$((bad+1)); echo "FAIL: $*"; }
check() { if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$3] got [$2]"; fi; }

# 1
check "1 template field count" "$(grep -c '^\*\*What usually lies:\*\*' "$TPL")" "1"
if awk '/^\*\*Verify it works:\*\*/{v=NR} /^\*\*What usually lies:\*\*/{w=NR} END{exit !(v && w>v)}' "$TPL"; then pass; else fail "1 field is not after **Verify it works:**"; fi

# 2
if . "$DIR/bin/lib/vmap-entry.sh"; then pass; else fail "2 sourcing the lib failed"; fi
for fn in vmap_lies vmap_plan_screens vmap_entries_for vmap_note; do
  if declare -F "$fn" >/dev/null; then pass; else fail "2 $fn not defined after sourcing"; fi
done
check "2 heading constant" "${VMAP_LIES_HEADING:-}" "What usually lies"

# 3
cat > "$T/a.md" <<'MD'
# Invoices

**Verify it works:** the row appears.
- verify bullet that must not print

**What usually lies:** 1-3 bullets: the ways this feature looks right but isn't.
- a toast that fires before the write fails
  and keeps going on a continuation line
- a list cached from before the change

**Manual-only / not automatable:** payments.
- manual bullet that must not print
MD
want=$'- a toast that fires before the write fails\n  and keeps going on a continuation line\n- a list cached from before the change'
out=$(declare -F vmap_lies >/dev/null && vmap_lies "$T/a.md"); rc=$?
check "3 vmap_lies output" "$out" "$want"
check "3 vmap_lies rc" "$rc" "0"

# 3b field last in the file, then a heading ends it in another fixture
printf '**What usually lies:**\n- only lie\n' > "$T/last.md"
check "3b field at EOF" "$(declare -F vmap_lies >/dev/null && vmap_lies "$T/last.md")" "- only lie"
printf '**What usually lies:**\n- lie one\n## Next section\n- not a lie\n' > "$T/head.md"
check "3c heading stops field" "$(declare -F vmap_lies >/dev/null && vmap_lies "$T/head.md")" "- lie one"

# 4
printf '# Plain\n\n**Verify it works:** x\n- a bullet\n' > "$T/b.md"
for args in "$T/b.md" "$T/nope.md" ""; do
  if [ -n "$args" ]; then out=$(vmap_lies "$args" 2>&1); rc=$?; else out=$(vmap_lies 2>&1); rc=$?; fi
  check "4 [${args:-no arg}] output" "$out" ""
  check "4 [${args:-no arg}] rc" "$rc" "0"
done

# 5
out=$(declare -F vmap_lies >/dev/null && vmap_lies "$TPL")
check "5 template bullets" "$(printf '%s\n' "$out" | grep -c '^- ')" "4"
case "$out" in *"not_configured"*) pass ;; *) fail "5 template bullets miss the not_configured example" ;; esac

# 6
out=$(vmap_plan_screens x 2>&1); rc=$?
check "6 vmap_plan_screens out" "$out" ""; check "6 vmap_plan_screens rc" "$rc" "0"
out=$(vmap_entries_for r /a 2>&1); rc=$?
check "6 vmap_entries_for out" "$out" ""; check "6 vmap_entries_for rc" "$rc" "0"
out=$(vmap_note r p 2>&1); rc=$?
check "6 vmap_note out" "$out" "VERIFICATION MAP: none in this repo"
check "6 vmap_note rc" "$rc" "0"

# 7
n=$(grep -ic 'what usually lies' "$DIR/docs/VMAP-BACKFILL-TICKET.md")
if [ "${n:-0}" -ge 2 ]; then pass; else fail "7 backfill doc mentions 'what usually lies' $n times, want >= 2"; fi

echo "vmap-entry-contract: $ok passed, $bad failed"
[ "$bad" -eq 0 ]
