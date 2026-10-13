#!/bin/bash
# tests/triage-gate-keymap-derived.bh-1169-test.sh — BH-1169: a board whose
# list endpoint returns `number` but not `key` (project-4) still produces
# state/<project>.keymap.json entries from the board's keyPrefix plus number.
#
# The fingerprint cannot carry `number` or `key` for un-adopted boards
# (bin/triage-gate.sh:24-27); the derivation uses the raw listing and the
# board's own keyPrefix instead. Board-sent keys always win over derived ones,
# including when a derived key COLLIDES with a key the board sent for another
# id (K8) — that is the BH-1042 failure class and the reason the board-sent map
# is the right operand of the `+`. A listing whose rows all carry `key` is
# byte-for-byte what the gate wrote before this change (K9). Closed statuses
# stay OUT of the keymap (BH-1042). A board with no keyPrefix derives nothing.
# `key: ""` counts as no key, because jq reads "" as true (K10).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1

DIR=$(cd "$(dirname "$0")/.." && pwd)
GATE_SRC="$DIR/bin/triage-gate.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "triage-gate-keymap-derived: jq missing, cannot run" >&2; exit 1; }
[ -r "$GATE_SRC" ] || { echo "triage-gate-keymap-derived: no bin/triage-gate.sh at $GATE_SRC" >&2; exit 1; }

mkdir -p "$T/bin" "$T/env" "$T/state" "$T/logs" "$T/fixture"
cp "$GATE_SRC" "$T/bin/triage-gate.sh"
# BH-1955: the generic arm resolves its token through these two libs.
mkdir -p "$T/bin/lib" && cp "$DIR/bin/lib/board-creds.sh" "$DIR/bin/lib/internal-token.sh" "$T/bin/lib/"
chmod +x "$T/bin/triage-gate.sh"

# A gate WITHOUT the derive block, built once by stripping the BH-1169 markers.
# Two cases use it: K5 (the malformed-board failure path is unchanged by the
# block) and K7 (the suite is really exercising the block). A moved marker
# cannot make this suite lie: the strip would then be a no-op, the "mutant"
# would be the real gate, and K7 — which requires the derive-less gate to write
# `{}` — goes red on it. On the merge base the strip is a no-op for the honest
# reason that the block is not there yet, and K7 passes because that gate really
# does write `{}`; K1/K3/K10 are what carry the red there.
mutant="$T/bin/triage-gate-mutant.sh"
sed '/# >>> derived keymap rows (BH-1169)/,/# <<< derived keymap rows/d' "$T/bin/triage-gate.sh" > "$mutant"
chmod +x "$mutant"

cat > "$T/bin/fleet-conf.sh" <<'EOC'
#!/bin/bash
case "${1:-}" in
  x-os)
    case "${2:-}" in
      repo) echo "" ;;
      board_prefix|*) echo "/api/board" ;;
    esac ;;
  *) echo "" ;;
esac
EOC
chmod +x "$T/bin/fleet-conf.sh"

cat > "$T/env/x-os.env" <<'EOC'
XOS_API_BASE=https://board.example
XOS_INTERNAL_API_TOKEN=tok
EOC

cat > "$T/bin/curl" <<EOC
#!/bin/bash
OUT=""; URL=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) shift; OUT="\${1:-}" ;;
    -H) shift; : ;;
    -m) shift; : ;;
    -w) shift; : ;;
    -*) : ;;
    *) URL="\$1" ;;
  esac
  shift || true
done
F=""
case "\$URL" in
  */boards/*/tickets) F="$T/fixture/tickets.json" ;;
  */boards)           F="$T/fixture/boards.json" ;;
esac
[ -n "\$F" ] && [ -f "\$F" ] || exit 22
if [ -n "\$OUT" ]; then cat "\$F" > "\$OUT"; else cat "\$F"; fi
exit 0
EOC
chmod +x "$T/bin/curl"

run_seed() {
  rm -f "$T/state/x-os.keymap.json" "$T/state/x-os.gate.json"
  PATH="$T/bin:$PATH" \
    HARNESS="$T" \
    bash "$T/bin/triage-gate.sh" x-os --seed 2>"$T/seed.err" >"$T/seed.out"
}

assert_keymap() {
  local want="$1" got
  got=$(jq -S -c . "$T/state/x-os.keymap.json" 2>/dev/null) || got="(missing)"
  if [ "$got" = "$want" ]; then
    ok
  else
    bad "keymap mismatch: want $want, got $got"
  fi
}

# ── K1: project-4-style board with keyPrefix derives open rows ───────────────────
# Fixture A from the plan.
printf '[{"id":"b1","keyPrefix":"TK"}]\n' > "$T/fixture/boards.json"
cat > "$T/fixture/tickets.json" <<'EOF'
{
  "capped": false,
  "tickets": [
    {"id":9001,"number":1784,"status":"in_progress","waitingOn":"team","triageVerdict":"buildable","commentCount":0,"lastActivityAt":"2026-09-20T12:00:00Z","title":"open with number"},
    {"id":9002,"number":1785,"status":"Done","waitingOn":"client","triageVerdict":"needs_clarification","commentCount":0,"lastActivityAt":"2026-09-20T12:00:00Z","title":"closed number"},
    {"id":9003,"status":"in_progress","waitingOn":"team","triageVerdict":"buildable","commentCount":0,"lastActivityAt":"2026-09-20T12:00:00Z","title":"open no number"},
    {"id":9004,"number":1786,"status":"review","waitingOn":"team","triageVerdict":"buildable","commentCount":0,"lastActivityAt":"2026-09-20T12:00:00Z","title":"open number two"}
  ]
}
EOF
run_seed
assert_keymap '{"9001":"TK-1784","9004":"TK-1786","TK-1784":"9001","TK-1786":"9004"}'
case "$(cat "$T/seed.out")" in
  *SEEDED*) ok ;;
  *) bad "K1: --seed did not print SEEDED: $(cat "$T/seed.out")" ;;
esac

# ── K2: board-sent key wins over a derived key with the same number ─────────
# If the listing later starts carrying `key` (adoption), that real key wins.
printf '[{"id":"b1","keyPrefix":"TK"}]\n' > "$T/fixture/boards.json"
cat > "$T/fixture/tickets.json" <<'EOF'
{
  "tickets": [
    {"id":9001,"number":1784,"key":"TK-9999","blocked":true,"status":"in_progress","waitingOn":"team","triageVerdict":"buildable","commentCount":0,"lastActivityAt":"2026-09-20T12:00:00Z","title":"adopted"}
  ]
}
EOF
run_seed
assert_keymap '{"9001":"TK-9999","TK-9999":"9001"}'

# ── K3: raw array shape (project-3-style) still derives with keyPrefix ───────────
printf '[{"id":"b1","keyPrefix":"TK"}]\n' > "$T/fixture/boards.json"
printf '[{"id":7001,"number":42,"status":"in_progress","waitingOn":"team","triageVerdict":"buildable","commentCount":0,"lastActivityAt":"2026-09-20T12:00:00Z","title":"array row"}]\n' > "$T/fixture/tickets.json"
run_seed
assert_keymap '{"7001":"TK-42","TK-42":"7001"}'

# ── K4: no keyPrefix = no derivation; existing key-bearing rows still written ──
printf '[{"id":"b1"}]\n' > "$T/fixture/boards.json"
cat > "$T/fixture/tickets.json" <<'EOF'
{
  "tickets": [
    {"id":9001,"number":1784,"status":"in_progress","waitingOn":"team","triageVerdict":"buildable","commentCount":0,"lastActivityAt":"2026-09-20T12:00:00Z","title":"no prefix"},
    {"id":9002,"key":"TK-8888","blocked":true,"status":"in_progress","waitingOn":"team","triageVerdict":"buildable","commentCount":0,"lastActivityAt":"2026-09-20T12:00:00Z","title":"with key"}
  ]
}
EOF
run_seed
assert_keymap '{"9002":"TK-8888","TK-8888":"9002"}'

# ── K5: the derive block leaves the malformed-board failure path alone ───────
# A boards body jq cannot read fails the fetch at `ids=$(jq …) || return 1`,
# BEFORE the loop the derive block sits in. So this is NOT evidence about the
# block's own `|| pfx=""` / `|| dk='[]'` guards; it is the differential that
# proves the block did not move that failure path: the real gate and the
# block-stripped mutant must answer with the same rc and the same stdout, and
# that answer must still be the documented fail-open SEED-FAILED.
printf '[{"id":"b1","keyPrefix":"TK"' > "$T/fixture/boards.json"
printf '[{"id":9001,"number":1784,"status":"in_progress","waitingOn":"team","triageVerdict":"buildable","commentCount":0,"lastActivityAt":"2026-09-20T12:00:00Z","title":"no-widen"}]\n' > "$T/fixture/tickets.json"
rm -f "$T/state/x-os.keymap.json" "$T/state/x-os.gate.json"
PATH="$T/bin:$PATH" HARNESS="$T" bash "$T/bin/triage-gate.sh" x-os --seed 2>"$T/seed2.err" >"$T/seed2.out"; rc=$?
rm -f "$T/state/x-os.keymap.json" "$T/state/x-os.gate.json"
PATH="$T/bin:$PATH" HARNESS="$T" bash "$mutant" x-os --seed 2>"$T/seed2m.err" >"$T/seed2m.out"; rcm=$?
case "$(cat "$T/seed2.out")" in
  *SEED-FAILED*) ok ;;
  *) bad "K5: malformed boards must fail-open to SEED-FAILED, got rc=$rc out=$(cat "$T/seed2.out") err=$(cat "$T/seed2.err")" ;;
esac
if [ "$rc" = "$rcm" ] && [ "$(cat "$T/seed2.out")" = "$(cat "$T/seed2m.out")" ]; then
  ok
else
  bad "K5: derive block changed the malformed-board path: real rc=$rc out=$(cat "$T/seed2.out") vs stripped rc=$rcm out=$(cat "$T/seed2m.out")"
fi

# ── K6: derivation does not widen the fingerprint / gate.json ───────────────
# Reset to a valid board first, then verify the persisted fingerprint does not
# gain number or key from un-adopted rows.
printf '[{"id":"b1","keyPrefix":"TK"}]\n' > "$T/fixture/boards.json"
printf '[{"id":9001,"number":1784,"status":"in_progress","waitingOn":"team","triageVerdict":"buildable","commentCount":0,"lastActivityAt":"2026-09-20T12:00:00Z","title":"no-widen"}]\n' > "$T/fixture/tickets.json"
run_seed
if jq -e '[.. | objects | has("number")] | any' "$T/state/x-os.gate.json" >/dev/null 2>&1; then
  bad "K6: fingerprint carried number"
else
  ok
fi
if jq -e '[.. | objects | has("key")] | any' "$T/state/x-os.gate.json" >/dev/null 2>&1; then
  bad "K6: fingerprint carried key"
else
  ok
fi
expected='[{"commentCount":0,"id":9001,"lastActivityAt":"2026-09-20T12:00:00Z","status":"in_progress","title":"no-widen","triageVerdict":"buildable","waitingOn":"team"}]'
actual=$(jq -S -c '.b1 // []' "$T/state/x-os.gate.json" 2>/dev/null) || actual="(missing)"
if [ "$actual" = "$expected" ]; then
  ok
else
  bad "K6: fingerprint row set mismatch: want $expected, got $actual"
fi

# ── K7: D1 mutation check — disable the derive block and the keymap empties ─
# This validates the test is actually exercising the new behavior.
printf '[{"id":"b1","keyPrefix":"TK"}]\n' > "$T/fixture/boards.json"
cat > "$T/fixture/tickets.json" <<'EOF'
{
  "tickets": [
    {"id":9001,"number":1784,"status":"in_progress","waitingOn":"team","triageVerdict":"buildable","commentCount":0,"lastActivityAt":"2026-09-20T12:00:00Z","title":"mutate"}
  ]
}
EOF
# $mutant is the gate with the BH-1169 markers stripped, built at the top.
rm -f "$T/state/x-os.keymap.json"
PATH="$T/bin:$PATH" HARNESS="$T" bash "$mutant" x-os --seed 2>"$T/mut.err" >"$T/mut.out"
mutgot=$(jq -S -c . "$T/state/x-os.keymap.json" 2>/dev/null) || mutgot="(missing)"
if [ "$mutgot" = "{}" ]; then
  ok
else
  bad "K7: mutant without derive block should produce {}, got $mutgot"
fi

# ── K8: collision — a derived key equal to a key the board SENT for another id ─
# Criterion 3's second half: "the derived lane must never override a key the
# board sent". Row 1 carries key TK-9 from the board (and a boolean `blocked`,
# without which the fingerprint drops its key); row 2 has number 9 on a
# TK-prefixed board, so the derived lane also produces TK-9, pointing at 2.
# Board-sent is the RIGHT operand of the `+` in the keymap jq and therefore
# wins the key direction. Swap those two operands and TK-9 resolves to 2 — the
# BH-1042 failure class, the client-court guard sent to the wrong ticket — and
# this is the only case in the suite that goes red for it.
printf '[{"id":"b1","keyPrefix":"TK"}]\n' > "$T/fixture/boards.json"
cat > "$T/fixture/tickets.json" <<'EOF'
{
  "tickets": [
    {"id":1,"key":"TK-9","blocked":false,"parentId":null,"dependsOn":[],"status":"todo","waitingOn":"team","triageVerdict":"ready","commentCount":0,"lastActivityAt":"2026-09-20T12:00:00Z","title":"board sent TK-9"},
    {"id":2,"number":9,"status":"todo","waitingOn":"team","triageVerdict":"ready","commentCount":0,"lastActivityAt":"2026-09-20T12:00:00Z","title":"number 9, derives TK-9"}
  ]
}
EOF
run_seed
got=$(jq -r '."TK-9" // "(absent)"' "$T/state/x-os.keymap.json" 2>/dev/null) || got="(unreadable)"
if [ "$got" = "1" ]; then
  ok
else
  bad "K8: board-sent TK-9 must resolve to ticket 1, got $got (map: $(jq -S -c . "$T/state/x-os.keymap.json" 2>/dev/null))"
fi
got=$(jq -r '."1" // "(absent)"' "$T/state/x-os.keymap.json" 2>/dev/null) || got="(unreadable)"
if [ "$got" = "TK-9" ]; then
  ok
else
  bad "K8: ticket 1 must still resolve to its board-sent key TK-9, got $got"
fi

# ── K9: a key-bearing listing is byte-for-byte what the gate wrote before ────
# Criterion 3's first half. Fixture B is the bh-1042 K1 shape — every row
# carries `key` plus a boolean `blocked` — on a board with NO keyPrefix, which
# is what the merge-base gate saw. Fixture B2 is the same rows with a `number`
# added to every one of them AND a board that does carry keyPrefix: every row
# has a key, so the derived lane emits nothing and the file must be identical
# BYTE for byte, not merely equal as JSON. Both are then compared against the
# expected bytes computed independently with `jq -S`.
write_fixture_b_rows() { # $1 = extra per-row fields
  cat > "$T/fixture/tickets.json" <<EOF
{
  "tickets": [
    {"id":1,"key":"TK-1","blocked":false,"parentId":null,"dependsOn":[],"status":"todo","waitingOn":"team","triageVerdict":"ready","commentCount":1,"lastActivityAt":"2026-09-20T12:00:00Z","title":"open"${1:-}},
    {"id":2,"key":"TK-2","blocked":false,"parentId":null,"dependsOn":[],"status":"done","waitingOn":"client","triageVerdict":"ready","commentCount":1,"lastActivityAt":"2026-09-20T12:00:00Z","title":"closed"${1:-}},
    {"id":3,"key":"TK-3","blocked":false,"parentId":null,"dependsOn":[],"status":"Review","waitingOn":"team","triageVerdict":"ready","commentCount":1,"lastActivityAt":"2026-09-20T12:00:00Z","title":"open, mixed case"${1:-}}
  ]
}
EOF
}
printf '[{"id":"b1"}]\n' > "$T/fixture/boards.json"
write_fixture_b_rows
run_seed
cp "$T/state/x-os.keymap.json" "$T/keymap.b"
jq -S . <<<'{"1":"TK-1","3":"TK-3","TK-1":"1","TK-3":"3"}' > "$T/keymap.expected"
if cmp -s "$T/keymap.b" "$T/keymap.expected"; then
  ok
else
  bad "K9: key-bearing keymap is not the expected bytes: $(cat "$T/keymap.b")"
fi
printf '[{"id":"b1","keyPrefix":"TK"}]\n' > "$T/fixture/boards.json"
write_fixture_b_rows ',"number":777'
run_seed
if cmp -s "$T/state/x-os.keymap.json" "$T/keymap.b"; then
  ok
else
  bad "K9: adding keyPrefix + number to key-bearing rows changed the file: $(cat "$T/state/x-os.keymap.json")"
fi

# ── K10: `key: ""` is an absent key, not a key the board sent ───────────────
# jq reads "" as TRUE, so a `== null` test would call an empty-string key a
# board-sent key and derive nothing for that row. A board that sends "" has not
# named the ticket; its number still does. `null` is the same case.
printf '[{"id":"b1","keyPrefix":"TK"}]\n' > "$T/fixture/boards.json"
cat > "$T/fixture/tickets.json" <<'EOF'
{
  "tickets": [
    {"id":9101,"key":"","number":77,"status":"in_progress","waitingOn":"team","triageVerdict":"buildable","commentCount":0,"lastActivityAt":"2026-09-20T12:00:00Z","title":"empty string key"},
    {"id":9102,"key":null,"number":78,"status":"in_progress","waitingOn":"team","triageVerdict":"buildable","commentCount":0,"lastActivityAt":"2026-09-20T12:00:00Z","title":"null key"}
  ]
}
EOF
run_seed
assert_keymap '{"9101":"TK-77","9102":"TK-78","TK-77":"9101","TK-78":"9102"}'

echo "triage-gate-keymap-derived: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
