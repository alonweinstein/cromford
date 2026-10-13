#!/bin/bash
# tests/vmap-entry.bh-2005-test.sh — the lookup slice of BH-2005 (built as
# BH-2036): vmap_plan_screens, vmap_entries_for and vmap_note in
# bin/lib/vmap-entry.sh, the three functions the contract slice left as stubs.
#
# Sources the REAL lib under `set -u` and runs it against a scratch repo whose
# map uses both layouts (`docs/verification-map/*.md` and `entries/*.md`).
# Asserts on what the functions print and return, never on the lib's source.
#
#   1  vmap_plan_screens: app paths from the QA screens section only
#   2  vmap_entries_for positives, both layouts, `[id]` = one segment
#   3  vmap_entries_for negatives (prefix, extra segment, `/`, /api, prose)
#   4  output is unique and sorted
#   5  vmap_note's three outcomes, rc 0 each
#   6  the 3-entry / 3000-byte cap, announced with what it dropped
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/vmap-entry.bh-2005-test.sh
set -u
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="${VMAP_LIB:-$DIR/bin/lib/vmap-entry.sh}"

ok=0; bad=0
pass() { ok=$((ok+1)); }
fail() { bad=$((bad+1)); echo "FAIL: $*"; }
check() { if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$3] got [$2]"; fi; }

# shellcheck source=/dev/null
. "$LIB" || { echo "FAIL: sourcing $LIB"; exit 1; }

# --- fixture repo -------------------------------------------------------------
R="$T/repo"; M="$R/docs/verification-map"
mkdir -p "$M/entries"
printf '# index\n\n| a | `/clients` |\n' > "$M/README.md"
printf '**Key routes/screens:**\n- `/clients` — template example\n' > "$M/TEMPLATE.md"
cat > "$M/clients.md" <<'MD'
# Clients

**What it is:** the client list. Not `/settings`.

**Key routes/screens:**
- `/clients` — the list
- `/clients/[id]` — one client

**Selectors:**
- `/invoices-selector-only`

**What usually lies:**
- a client count cached from before the import
MD
cat > "$M/entries/BH-1.md" <<'MD'
| Invoices | x | y |

**Key routes/screens:** `/invoices/` and `/billing?tab=open`
MD
cat > "$M/settings.md" <<'MD'
# Settings

**What it is:** reached at `/settings` from the avatar menu.

**Selectors:**
- `/settings` — written here, not under Key routes
MD

# --- 1. vmap_plan_screens -----------------------------------------------------
cat > "$T/plan.md" <<'MD'
# plan

Touches `/elsewhere` outside the section.

## QA screens
- `/clients/42` — detail
- /invoices (list), and logs under /root/x and /tmp/y
- the page at "/settings"

## Next
- `/after`
MD
out=$(vmap_plan_screens "$T/plan.md"); rc=$?
check "1 screens" "$out" $'/clients/42\n/invoices\n/settings'
check "1 rc" "$rc" 0
printf '# plan\n\n## Tasks\n- `/clients`\n' > "$T/nosec.md"
check "1 no section" "$(vmap_plan_screens "$T/nosec.md")" ""
check "1 missing file" "$(vmap_plan_screens "$T/nope.md")" ""
check "1 no arg" "$(vmap_plan_screens)" ""
printf '## QA screens\n\nNone: only /root/logs and /tmp/x.\n' > "$T/sys.md"
check "1 system paths only -> nothing, never /" "$(vmap_plan_screens "$T/sys.md")" ""
printf '## QA screens\n- `/`\n' > "$T/slash.md"
check "1 listed / is kept" "$(vmap_plan_screens "$T/slash.md")" "/"

# --- 2. positives ---------------------------------------------------------------
check "2 /clients" "$(vmap_entries_for "$R" /clients)" "docs/verification-map/clients.md"
check "2 /clients/42 via [id]" "$(vmap_entries_for "$R" /clients/42)" "docs/verification-map/clients.md"
check "2 /invoices (entries/ layout, trailing / on entry)" "$(vmap_entries_for "$R" /invoices)" "docs/verification-map/entries/BH-1.md"
check "2 /billing (query stripped)" "$(vmap_entries_for "$R" /billing)" "docs/verification-map/entries/BH-1.md"
check "2 route side normalised" "$(vmap_entries_for "$R" '/clients/?x=1')" "docs/verification-map/clients.md"

# --- 3. negatives ---------------------------------------------------------------
for r in /clients-archive /client /clients/123/edit / /api/clients /settings /invoices-selector-only /elsewhere; do
  out=$(vmap_entries_for "$R" "$r"); rc=$?
  check "3 negative $r" "$out" ""
  check "3 negative $r rc" "$rc" 0
done
check "3 no routes" "$(vmap_entries_for "$R")" ""
check "3 no map" "$(vmap_entries_for "$T/empty-repo" /clients)" ""
# `/` matches when an entry lists it literally
mkdir -p "$T/root-repo/docs/verification-map"
printf '**Key routes/screens:**\n- `/` — home\n' > "$T/root-repo/docs/verification-map/home.md"
check "3 literal / entry" "$(vmap_entries_for "$T/root-repo" /)" "docs/verification-map/home.md"
check "3 / entry vs /x" "$(vmap_entries_for "$T/root-repo" /x)" ""

# --- 4. unique + sorted ---------------------------------------------------------
check "4 two routes one entry" "$(vmap_entries_for "$R" /clients /clients/42)" "docs/verification-map/clients.md"
check "4 sorted" "$(vmap_entries_for "$R" /invoices /clients)" \
  $'docs/verification-map/clients.md\ndocs/verification-map/entries/BH-1.md'

# --- 5. vmap_note outcomes --------------------------------------------------------
out=$(vmap_note "$R" "$T/plan.md"); rc=$?
check "5 match rc" "$rc" 0
check "5 match header" "$(head -n1 <<<"$out")" "VERIFICATION MAP: 2 entries for this ticket's screens"
case "$out" in *"--- docs/verification-map/clients.md ---"*"a client count cached"*) pass ;; *) fail "5 match must carry clients.md content: [$out]" ;; esac
case "$out" in *truncated*) fail "5 two small entries must not be truncated: [$out]" ;; *) pass ;; esac
printf '## QA screens\n- `/clients/7`\n' > "$T/one.md"
check "5 one entry header" "$(vmap_note "$R" "$T/one.md" | head -n1)" "VERIFICATION MAP: 1 entry for this ticket's screens"

printf '## QA screens\n- `/nowhere` and `/else`\n' > "$T/miss.md"
out=$(vmap_note "$R" "$T/miss.md"); rc=$?
check "5 no match" "$out" "VERIFICATION MAP: no map entry for screens: /else /nowhere (map has 3 entries)"
check "5 no match rc" "$rc" 0
out=$(vmap_note "$R" "$T/nosec.md"); rc=$?
check "5 plan lists none" "$out" "VERIFICATION MAP: no map entry for screens: (plan lists none) (map has 3 entries)"
check "5 plan lists none rc" "$rc" 0
check "5 missing plan" "$(vmap_note "$R" "$T/nope.md")" "VERIFICATION MAP: no map entry for screens: (plan lists none) (map has 3 entries)"

mkdir -p "$T/bare/docs/verification-map"
printf '# index\n' > "$T/bare/docs/verification-map/README.md"
out=$(vmap_note "$T/bare" "$T/plan.md"); rc=$?
check "5 empty map" "$out" "VERIFICATION MAP: none in this repo"
check "5 empty map rc" "$rc" 0
check "5 no dir" "$(vmap_note "$T/empty-repo" "$T/plan.md")" "VERIFICATION MAP: none in this repo"
check "5 no args" "$(vmap_note)" "VERIFICATION MAP: none in this repo"

# --- 6. the cap ------------------------------------------------------------------
C="$T/cap"; mkdir -p "$C/docs/verification-map/entries"
for i in 1 2 3 4 5; do
  printf '**Key routes/screens:**\n- `/p%s`\n\nbody %s\n' "$i" "$i" > "$C/docs/verification-map/entries/E$i.md"
done
printf '## QA screens\n- `/p1` `/p2` `/p3` `/p4` `/p5`\n' > "$T/five.md"
out=$(vmap_note "$C" "$T/five.md"); rc=$?
check "6 five rc" "$rc" 0
check "6 five header" "$(head -n1 <<<"$out")" "VERIFICATION MAP: 5 entries for this ticket's screens"
check "6 five shows 3" "$(grep -c '^--- ' <<<"$out")" 3
check "6 five tail" "$(tail -n1 <<<"$out")" \
  "VERIFICATION MAP: truncated, showing 3 of 5 entries (cap 3 entries / 3000 bytes); not shown: docs/verification-map/entries/E4.md docs/verification-map/entries/E5.md"

B="$T/big"; mkdir -p "$B/docs/verification-map"
{ printf '**Key routes/screens:**\n- `/big`\n'; head -c 4000 /dev/zero | tr '\0' 'x'; printf '\nEND-MARKER\n'; } > "$B/docs/verification-map/big.md"
printf '## QA screens\n- `/big`\n' > "$T/big.md"
out=$(vmap_note "$B" "$T/big.md"); rc=$?
check "6 big rc" "$rc" 0
body=$(sed -n '3,$p' <<<"$out" | sed '$d')
n=$(printf '%s' "$body" | wc -c)
[ "$n" -le 3000 ] && [ "$n" -ge 2900 ] && pass || fail "6 big entry content must be cut to <= 3000 bytes, got $n"
case "$out" in *END-MARKER*) fail "6 big entry must be cut before its end" ;; *) pass ;; esac
check "6 big tail" "$(tail -n1 <<<"$out")" \
  "VERIFICATION MAP: truncated, showing 1 of 1 entries (cap 3 entries / 3000 bytes); not shown: none; cut short: docs/verification-map/big.md"

echo "vmap-entry: $ok passed, $bad failed"
[ "$bad" -eq 0 ]
