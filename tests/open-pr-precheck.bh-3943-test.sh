#!/bin/bash
# tests/open-pr-precheck.bh-3943-test.sh — BH-3948 (BH-3943 slice C0):
# open_pr_for_key <slug> <KEY> in bin/lib/open-pr-precheck.sh.
#
#   A1-A6  hits, verified-none, and unreadable reads through the REAL
#          gh_rest_pr_list_var/_ghrv_run; only gh_rest_pr_list is stubbed
#   N1-N8  exact head match, CLOSED PR, unparsable / non-array bodies ({} too), a
#          matched head with no number, bad args (no read made)
#   S1     sourcing prints nothing and is re-sourceable
#   S2     no `$(gh_rest` capture and no `gh pr` call in the lib
#
# Run from anywhere: tests/open-pr-precheck.bh-3943-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

LIB="$DIR/bin/lib/open-pr-precheck.sh"
if [ ! -r "$LIB" ]; then bad "bin/lib/open-pr-precheck.sh must exist"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; fi

# ── S1: sourcing is silent and re-sourceable ────────────────────────────────
S1OUT=$( . "$LIB"; . "$LIB"; echo "rc=$? t=$T"; command -v open_pr_for_key >/dev/null && echo fn ) 2>&1
[ "$S1OUT" = "rc=0 t=$T
fn" ] && ok || bad "(S1) source twice prints nothing, keeps T, defines the fn [$S1OUT]"

# The real lib, which pulls in the real gh-rest.sh and gh-rest-var.sh.
. "$LIB"

# Fixture table: $T/fx/<head with : and / as _> holds "rc|status|body".
mkdir -p "$T/fx"
fx() { printf '%s' "$2" > "$T/fx/$(printf '%s' "$1" | tr ':/' '__')"; }
gh_rest_pr_list() { # the bottom of the production path; everything above is real
  local f row
  printf '%s|%s|%s|%s\n' "$1" "$2" "${3:-}" "${4:-}" >> "$T/calls"
  f="$T/fx/$(printf '%s' "${3:-}" | tr ':/' '__')"
  row=$(cat "$f" 2>/dev/null || printf '0|200|[]')
  GH_REST_STATUS="${row#*|}"; GH_REST_STATUS="${GH_REST_STATUS%%|*}"
  GH_REST_REASON=stub
  if [ "${row%%|*}" != 0 ]; then return "${row%%|*}"; fi
  printf '%s\n' "${row#*|*|}"
}
pr() { printf '[{"number":%s,"state":"%s","head":{"ref":"%s"}}]' "$1" "$2" "$3"; }

# run <slug> <key>: sets RC, OUT, NCALLS; runs in THIS shell (no $( ) around it).
run() {
  rm -f "$T/calls" "$T/out"; : > "$T/calls"; RC=0
  open_pr_for_key "$1" "$2" > "$T/out" || RC=$?
  OUT=$(cat "$T/out"); NCALLS=$(wc -l < "$T/calls" | tr -d ' ')
}
reset() { rm -f "$T/fx/"*; }
S=example-org/cromford

# A1: agent/ hit, second probe skipped
reset; fx "example-org:agent/TK-2125" "0|200|$(pr 1787 open agent/TK-2125)"
run "$S" TK-2125
[ "$RC" = 0 ] && [ "$OUT" = "#1787" ] && [ "$NCALLS" = 1 ] && ok || bad "(A1) agent hit -> #1787 rc0 1 call [rc=$RC out=$OUT n=$NCALLS]"
[ "$(head -1 "$T/calls")" = "$S|open|example-org:agent/TK-2125|1" ] && ok || bad "(A1) first probe args [$(head -1 "$T/calls")]"

# A2: ticket/ hit, head lowercased
reset; fx "example-org:ticket/TK-2125" "0|200|$(pr 1790 open ticket/TK-2125)"
run "$S" TK-2125
[ "$RC" = 0 ] && [ "$OUT" = "#1790" ] && [ "$NCALLS" = 2 ] && ok || bad "(A2) ticket hit -> #1790 rc0 [rc=$RC out=$OUT n=$NCALLS]"
[ "$(sed -n 2p "$T/calls")" = "$S|open|example-org:ticket/TK-2125|1" ] && ok || bad "(A2) second probe head lowercased [$(sed -n 2p "$T/calls")]"

# A3: both verified empty
reset; run "$S" TK-2125
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$NCALLS" = 2 ] && ok || bad "(A3) both empty -> rc1, no output, 2 calls [rc=$RC out=$OUT n=$NCALLS]"

# A4: 403 on the first probe; status survives in this shell
reset; fx "example-org:agent/TK-2125" "75|403|"; GH_REST_STATUS=
run "$S" TK-2125
[ "$RC" = 2 ] && [ -z "$OUT" ] && [ "$NCALLS" = 1 ] && ok || bad "(A4) 403 -> rc2, no output, no 2nd call [rc=$RC out=$OUT n=$NCALLS]"
[ "$GH_REST_STATUS" = 403 ] && ok || bad "(A4) GH_REST_STATUS survives to the caller [$GH_REST_STATUS]"

# A5: first empty, second 502
reset; fx "example-org:ticket/TK-2125" "75|502|"
run "$S" TK-2125
[ "$RC" = 2 ] && [ -z "$OUT" ] && [ "$GH_REST_STATUS" = 502 ] && ok || bad "(A5) 502 on 2nd probe -> rc2 [rc=$RC out=$OUT st=$GH_REST_STATUS]"

# A6: sloppy API returns TK-21250 for TK-2125
reset; fx "example-org:agent/TK-2125" "0|200|$(pr 9 open agent/TK-21250)"
run "$S" TK-2125
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "(A6) TK-21250 is not TK-2125 -> rc1 [rc=$RC out=$OUT]"

# N1: TK-2125-other
reset; fx "example-org:agent/TK-2125" "0|200|$(pr 9 open agent/TK-2125-other)"
run "$S" TK-2125
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "(N1) TK-2125-other -> rc1 [rc=$RC out=$OUT]"

# N2: key TK-212, API returns TK-2125
reset; fx "example-org:agent/TK-212" "0|200|$(pr 9 open agent/TK-2125)"
run "$S" TK-212
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "(N2) TK-212 never matches TK-2125 -> rc1 [rc=$RC out=$OUT]"

# N3: closed PR on the exact head
reset; fx "example-org:agent/TK-2125" "0|200|$(pr 9 closed agent/TK-2125)"
run "$S" TK-2125
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "(N3) closed PR does not count -> rc1 [rc=$RC out=$OUT]"

# N4-N6: rc 0 but unreadable body
for c in "N4|not json" "N5|" 'N6|{"message":"x"}' 'N6b|{}'; do
  reset; fx "example-org:agent/TK-2125" "0|200|${c#*|}"
  run "$S" TK-2125
  [ "$RC" = 2 ] && [ -z "$OUT" ] && [ "$NCALLS" = 1 ] && ok || bad "(${c%%|*}) unreadable body -> rc2 [rc=$RC out=$OUT n=$NCALLS]"
done

# N7: matched head, null number
reset; fx "example-org:agent/TK-2125" '0|200|[{"number":null,"state":"open","head":{"ref":"agent/TK-2125"}}]'
run "$S" TK-2125
[ "$RC" = 2 ] && [ -z "$OUT" ] && ok || bad "(N7) matched head, null number -> rc2 [rc=$RC out=$OUT]"

# N8: bad args, no read
reset
for a in "$S|" "|TK-2125" "noslash|TK-2125" "/repo|TK-2125"; do
  run "${a%%|*}" "${a#*|}"
  [ "$RC" = 2 ] && [ -z "$OUT" ] && [ "$NCALLS" = 0 ] && ok || bad "(N8) bad args [$a] -> rc2, no read [rc=$RC out=$OUT n=$NCALLS]"
done

# ── S2: source-text guards (supplement, D3) ─────────────────────────────────
grep -q 'open_pr_for_key()' "$LIB" && ok || bad "(S2) function definition present"
CODE=$(grep -vE '^[[:space:]]*#' "$LIB")
case "$CODE" in *'$(gh_rest'*) bad "(S2) no \$(gh_rest capture" ;; *) ok ;; esac
[[ "$CODE" =~ (^|[^a-z_])gh\ pr ]] && bad "(S2) no gh pr call" || ok
grep -q '^# gh-rest: no-graphql' "$LIB" && ok || bad "(S2) no-graphql marker"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
