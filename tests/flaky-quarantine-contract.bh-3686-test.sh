#!/bin/bash
# tests/flaky-quarantine-contract.bh-3686-test.sh — BH-3686.0: the contract the
# flaky-tier siblings import.
#
# Pins tp_protected (bin/lib/test-protected.sh) against a fixture catalog root
# and against the committed catalog/test-quarantine-protected.txt, the two new
# quarantine clients in bin/lib/jobs/cost.sh (metric_flake_quarantine_rows,
# metric_flake_quarantine_put) loaded through the real bin/jobs-client.sh shim
# with a recording _jobs_req, and the ft_release stub
# (bin/lib/flaky-tier-release.sh), which must release nothing.
#
# Run from anywhere: tests/flaky-quarantine-contract.bh-3686-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

TP_LIB="$DIR/bin/lib/test-protected.sh"
FT_LIB="$DIR/bin/lib/flaky-tier-release.sh"
REAL_LIST="$DIR/catalog/test-quarantine-protected.txt"

# --- fixture catalog root ------------------------------------------------------
mkdir -p "$T/catalog"
cat > "$T/catalog/test-quarantine-protected.txt" <<'EOF'
# fixture named list
tests/switch-*      a glob before the exact line
tests/a-test.sh     an exact path

tests/sw*           a second glob that must never be the one reported
EOF
printf '%s\n' '# fixture tiers' \
  "tests/g-test.sh	guard	3	bin/x.sh	a guard" \
  "tests/b-test.sh	batch	3	-	a batch row" > "$T/catalog/test-tiers.tsv"
printf '%s\n' '# fixture always' 'tests/al-test.sh   reason' > "$T/catalog/test-impact-always.txt"
printf '%s\n' '# fixture nightly' 'tests/ns-test.sh   reason' > "$T/catalog/nightly-strict.txt"

# tp <suite> [root] — run tp_protected in a clean subshell: "rc|stdout".
tp() {
  ( unset HARNESS H TP_PROTECTED_LIST
    # shellcheck source=/dev/null
    . "$TP_LIB" || exit 99
    out=$(tp_protected "$@"); rc=$?
    printf '%s|%s' "$rc" "$out" )
}

# --- Q-P1: a named exact path -------------------------------------------------
R=$(tp tests/a-test.sh "$T");            [ "$R" = "0|named list" ] && ok || bad "Q-P1 fixture: got '$R'"
R=$(tp ./tests/a-test.sh "$T");          [ "$R" = "0|named list" ] && ok || bad "Q-P1 ./ prefix: got '$R'"
R=$(tp tests/test-tiers-test.sh "$DIR"); [ "$R" = "0|named list" ] && ok || bad "Q-P1 real list: got '$R'"

# --- Q-P2: a named glob -------------------------------------------------------
R=$(tp tests/switch-foo-test.sh "$T");   [ "$R" = "0|named glob tests/switch-*" ] && ok || bad "Q-P2 fixture: got '$R'"
R=$(tp tests/switch-foo-test.sh "$DIR"); [ "$R" = "0|named glob tests/switch-*" ] && ok || bad "Q-P2 real list: got '$R'"

# --- Q-P3: the three secondary catalogs --------------------------------------
R=$(tp tests/g-test.sh "$T");  [ "$R" = "0|guard tier" ] && ok || bad "Q-P3 guard: got '$R'"
R=$(tp tests/al-test.sh "$T"); [ "$R" = "0|test-impact always" ] && ok || bad "Q-P3 always: got '$R'"
R=$(tp tests/ns-test.sh "$T"); [ "$R" = "0|nightly strict" ] && ok || bad "Q-P3 nightly: got '$R'"

# --- Q-P4: an ordinary suite is not protected; a batch row is not a guard ----
R=$(tp tests/ordinary-test.sh "$T"); [ "$R" = "1|" ] && ok || bad "Q-P4 ordinary: got '$R'"
R=$(tp tests/b-test.sh "$T");        [ "$R" = "1|" ] && ok || bad "Q-P4 batch row: got '$R'"
R=$(tp "" "$T");                     [ "$R" = "2|" ] && ok || bad "Q-P4 empty suite: got '$R'"

# --- Q-P5: an unreadable named list protects every suite ---------------------
R=$( ( unset HARNESS H
       # shellcheck source=/dev/null
       . "$TP_LIB" || exit 99
       out=$(TP_PROTECTED_LIST="$T/missing" tp_protected tests/ordinary-test.sh "$T"); printf '%s|%s' "$?" "$out" ) )
[ "$R" = "0|protected list unreadable" ] && ok || bad "Q-P5 missing list: got '$R'"
# Q-P5b: no root arg and no HARNESS / H / TP_PROTECTED_LIST.
R=$(tp tests/ordinary-test.sh); [ "$R" = "0|protected list unreadable" ] && ok || bad "Q-P5b no root: got '$R'"
# Root from HARNESS when [root] is omitted.
R=$( ( unset H TP_PROTECTED_LIST; export HARNESS="$T"
       # shellcheck source=/dev/null
       . "$TP_LIB" || exit 99
       out=$(tp_protected tests/ordinary-test.sh); printf '%s|%s' "$?" "$out" ) )
[ "$R" = "1|" ] && ok || bad "Q-P5c HARNESS root: got '$R'"

# --- C1: every line of the committed list matches at least one file ----------
[ -r "$REAL_LIST" ] && ok || bad "C1: $REAL_LIST is not readable"
C1_BAD=""; C1_N=0
while read -r g _; do
  case "$g" in ''|'#'*) continue ;; esac
  C1_N=$((C1_N+1))
  ( cd "$DIR" && compgen -G "$g" >/dev/null ) || C1_BAD="$C1_BAD $g"
done < "$REAL_LIST"
[ -z "$C1_BAD" ] && [ "$C1_N" -ge 20 ] && ok || bad "C1: n=$C1_N, lines matching no file:$C1_BAD"

# --- the real client modules, loaded through the shim -------------------------
mkdir -p "$T/bin/lib/jobs" "$T/env"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
echo 'HARNESS_SECRET=test-secret' > "$T/env/global.env"

# fn <fake-rc> <fake-body> <function> [args...] — run a client function with
# _jobs_req replaced by a recorder: one line "METHOD PATH" then the body.
fn() {
  local frc="$1" fbody="$2"; shift 2
  ( export HARNESS="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh" 2>/dev/null
    _jobs_req() { printf '%s %s\n%s\n' "$1" "$2" "${3:-}" >> "$T/req.log"; [ "$frc" -eq 0 ] || return "$frc"; printf '%s' "$fbody"; }
    "$@" )
}
reqs() { if [ -f "$T/req.log" ]; then grep -c '^[A-Z]* /' "$T/req.log"; else echo 0; fi; }

# --- J1: rows = GET with no active, 5 TSV columns, reason flattened ---------
rm -f "$T/req.log"
J1_BODY='{"rows":[{"test":"t1","active":1,"actor":"a","updated_at":"u","reason":"x\ty\nz"},{"test":"t2","active":false,"actor":"b","updated_at":"v","reason":""}]}'
OUT=$(fn 0 "$J1_BODY" metric_flake_quarantine_rows example-org/x); RC=$?
[ "$(head -1 "$T/req.log")" = "GET /api/metrics/flakes/quarantine?repo=example-org/x" ] \
  && ok || bad "J1 request: '$(head -1 "$T/req.log")'"
grep -q 'active' "$T/req.log" && bad "J1: request carries an active filter" || ok
[ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | wc -l)" -eq 2 ] \
  && [ "$(printf '%s\n' "$OUT" | awk -F'\t' 'NF!=5' | wc -l)" -eq 0 ] \
  && ok || bad "J1 shape: rc=$RC out='$OUT'"
[ "$OUT" = $'t1\t1\ta\tu\tx y z\nt2\t0\tb\tv\t-' ] && ok || bad "J1 values: '$OUT'"
# A row with no test, or an active value that is not a boolean, is dropped.
OUT=$(fn 0 '{"rows":[{"active":1},{"test":"t3","active":"maybe"},{"test":"t4","active":true}]}' metric_flake_quarantine_rows example-org/x); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = $'t4\t1\t-\t-\t-' ] && ok || bad "J1b drops: rc=$RC out='$OUT'"
# Empty repo (after the cut) sends nothing.
rm -f "$T/req.log"
OUT=$(fn 0 "$J1_BODY" metric_flake_quarantine_rows ';; '); RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUT" ] && [ "$(reqs)" = 0 ] && ok || bad "J1c empty repo: rc=$RC reqs=$(reqs)"

# --- J2: unknown is never empty ----------------------------------------------
OUT=$(fn 1 '' metric_flake_quarantine_rows example-org/x); RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUT" ] && ok || bad "J2 transport: rc=$RC out='$OUT'"
OUT=$(fn 0 'not json' metric_flake_quarantine_rows example-org/x); RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUT" ] && ok || bad "J2 non-JSON: rc=$RC out='$OUT'"
OUT=$(fn 0 '{}' metric_flake_quarantine_rows example-org/x); RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUT" ] && ok || bad "J2 no rows: rc=$RC out='$OUT'"
OUT=$(fn 0 '{"rows":[]}' metric_flake_quarantine_rows example-org/x); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "J2 empty set: rc=$RC out='$OUT'"

# --- J3: put sends {repo,test,active,reason,actor} ---------------------------
rm -f "$T/req.log"
fn 0 '{"ok":true}' metric_flake_quarantine_put example-org/x tests/a.sh 1 "why" flaky-tier; RC=$?
LINE=$(sed -n 1p "$T/req.log"); BODY=$(sed -n 2p "$T/req.log")
[ "$RC" -eq 0 ] && [ "$LINE" = "PUT /api/metrics/flakes/quarantine" ] && ok || bad "J3: rc=$RC request '$LINE'"
[ "$(printf '%s' "$BODY" | jq -c -S . 2>/dev/null)" = '{"active":1,"actor":"flaky-tier","reason":"why","repo":"example-org/x","test":"tests/a.sh"}' ] \
  && ok || bad "J3 body: $BODY"
fn 7 '' metric_flake_quarantine_put example-org/x tests/a.sh 0 "why" flaky-tier; RC=$?
[ "$RC" -eq 7 ] && ok || bad "J3b: transport rc not returned, got $RC"

# --- J4: put refuses bad input with no request -------------------------------
rm -f "$T/req.log"
fn 0 '{"ok":true}' metric_flake_quarantine_put example-org/x tests/a.sh 2 "why" flaky-tier; RC=$?
[ "$RC" -eq 1 ] && [ "$(reqs)" = 0 ] && ok || bad "J4 active=2: rc=$RC reqs=$(reqs)"
fn 0 '{"ok":true}' metric_flake_quarantine_put example-org/x '' 1 "why" flaky-tier; RC=$?
[ "$RC" -eq 1 ] && [ "$(reqs)" = 0 ] && ok || bad "J4 empty test: rc=$RC reqs=$(reqs)"
fn 0 '{"ok":true}' metric_flake_quarantine_put example-org/x tests/a.sh 1 "why" ''; RC=$?
[ "$RC" -eq 1 ] && [ "$(reqs)" = 0 ] && ok || bad "J4 empty actor: rc=$RC reqs=$(reqs)"

# --- S1: the ft_release stub releases nothing --------------------------------
printf 't1\t1\tflaky-tier\tu\twhy\n' > "$T/rows.tsv"
OUT=$( (
  # shellcheck source=/dev/null
  . "$FT_LIB" || exit 99
  ft_release example-org/x "$T/rows.tsv" ) ); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "S1: rc=$RC out='$OUT'"
for v in FLAKY_TIER_ACT FLAKY_TIER_DRY FLAKY_TIER_RELEASE_ACTORS; do
  grep -q "^#.*$v" "$FT_LIB" 2>/dev/null && ok || bad "S1: header does not name $v"
done

echo "flaky-quarantine-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
