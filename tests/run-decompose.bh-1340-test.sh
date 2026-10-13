#!/bin/bash
# tests/run-decompose.bh-1340-test.sh — the DEC_FAIL arm of the
# `# >>> board child keys` block parks the parent at the BOARD'S OWN prefix,
# and the library's parent comment survives a caller with MAXL/MAXF unset.
#
# THE DEFECT THIS PINS (BH-1340, from the #1114 review). BH-982 moved the
# SUCCESS tail of bin/run-decompose.sh onto fc_board_base — fleet.conf column 4,
# the registry's own answer for where a project's board API lives — and left the
# failure arm above it pasting a literal `/api/board` onto the API base. On a
# project served anywhere else (ledger-os: `/api-accounting-board`) that URL does
# not exist, so after a failed label->key re-map the park POST 404s, the parent
# stays claimable, and the next triage tick re-splits it: a SECOND set of
# children on a board a client reads, which is the exact duplicate the block was
# written to stop. The WARN the arm logs in that case is true, and nobody is
# watching a warning at 3am.
#
# The bh-982 suite greps only the parking TAIL for `/api/board` (from the
# `# <<< board child keys` marker to EOF), which is how this arm survived a
# review that was looking straight at it. §1 here is the whole file.
#
# The second half is the same class of bug one file over: bin/lib/fc-issues.sh
# promises (`:51-53`) that a direct caller under `set -u` cannot be killed on an
# unset name, and the parent split comment read a bare `$MAXL`/`$MAXF` — after
# every `gh issue create` has already run, which is the worst possible line to
# die on. §4 drives the library with both unset.
#
# No network, no model call, no secrets, nothing written outside $T.
# Run from anywhere: tests/run-decompose.bh-1340-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

DEC="$DIR/bin/run-decompose.sh"
LIB="$DIR/bin/lib/file-children.sh"
FIX="$DIR/tests/fixtures/fc-issues"

# ════════════════════════════════════════════════════════════════════════════
# 1. NOT ONE HARDCODED BOARD PATH LEFT IN THE SCRIPT
# Whole file, comments included — the bh-982 assertion is scoped to the tail,
# and the arm this ticket fixes sits above that marker. Paired with §2 below so
# deleting the POST entirely does not buy a pass: the source negative alone is
# documentation, the drive is the proof (D3).
# ════════════════════════════════════════════════════════════════════════════
if [ -r "$DEC" ]; then
  ok
  N=$(grep -c '/api/board' "$DEC")
  [ "$N" -eq 0 ] \
    && ok || bad "bin/run-decompose.sh still hardcodes a board path in $N place(s) — fleet.conf column 4 is the registry answer, not a constant:
$(grep -n '/api/board' "$DEC")"
else
  bad "bin/run-decompose.sh is missing or unreadable — the §1 negative cannot pass by absence"
  bad "(the /api/board count was never taken)"
fi

# ─────────────────────────────────────────────────────────────── scratch tree
H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" ledger-os || exit 1  # BH-1510.2: lanes read models from model_routes
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$H/prompts" "$T/fakebin"
cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
# ledger-os is an in-app board whose prefix is NOT the default one — that is the
# whole point. scoutish is the GitHub-Issues lane ("-"), which §4 drives.
cat > "$H/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
ledger-os example-org/ledger-os https://ledger.example /api-accounting-board 3 box-1
scoutish  example-org/scoutish  https://scoutish.example -                    9 box-1
CONF
: > "$H/env/global.env"
ENV_FULL='LEDGER_INTERNAL_API_TOKEN=tok_fixture_1340
LEDGER_API_BASE=https://ar.example
'
ENV_TOKEN_ONLY='LEDGER_INTERNAL_API_TOKEN=tok_fixture_1340
'
printf '%s' "$ENV_FULL" > "$H/env/ledger-os.env"
# The model-filed path this suite pins lives behind the switch since BH-3965.
mkdir -p "$H/flags" && : > "$H/flags/decompose-board-filer-off"

# The model's half: it files the children on the board and writes back TITLE
# LABELS rather than the board's keys. That is what makes the re-map run, and
# the board below is what makes it fail.
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
B=$(dirname "$5")
printf 'LG-77.0\nLG-77.1\n' > "$B/children.txt"
printf 'DECOMPOSED: LG-77.0,LG-77.1\n' > "$5"
exit 0
SH
chmod +x "$H/bin/agent-call.sh"

# The board answers the single-ticket read with a boardId, and its ticket list
# with nothing that matches either label — so every label fails to resolve and
# the DEC_FAIL arm runs with the children already filed.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"
printf '%s\n' "\$URL" >> "$T/curl-calls.txt"
case "\$URL" in
  *"/tickets/77/move")        printf '{"status":"in_progress"}\n' ;;
  *"/tickets/77")             printf '{"ticket":{"id":"77","key":"LG-77","boardId":"bd-1"}}\n' ;;
  *"/boards/bd-1/tickets")    printf '{"tickets":[]}\n' ;;
  *)                          printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl"

B="$T/b"
run() { # run -> prints the rc of the real script
  scratch_rm "$B"; mkdir -p "$B"
  : > "$T/curl-calls.txt"
  ( env HARNESS="$H" FLEET_CONF="$H/fleet.conf" PATH="$T/fakebin:$PATH" \
        bash "$DEC" ledger-os 77 LG-77 "$B" 300 12 ) >"$T/dec.out" 2>"$T/dec.err"
  echo $?
}

# ════════════════════════════════════════════════════════════════════════════
# 2. A FAILED RE-MAP PARKS AT THE BOARD'S OWN PREFIX
# The production entry point: the real bin/run-decompose.sh, driven end to end
# (D2). The assertion is the URL the park POST actually went to.
# ════════════════════════════════════════════════════════════════════════════
printf '%s' "$ENV_FULL" > "$H/env/ledger-os.env"
RC=$(run)
[ "$RC" = 1 ] \
  && ok || bad "a split whose labels resolve to nothing must fail (rc=$RC): $(cat "$B/decompose-run.txt" 2>/dev/null)"
grep -q 'DECOMPOSE_FAILED' "$B/decompose-run.txt" 2>/dev/null \
  && ok || bad "the failure must be written where the pipeline reads the decompose outcome: $(cat "$B/decompose-run.txt" 2>/dev/null)"
grep 'DECOMPOSE_FAILED' "$B/decompose-run.txt" 2>/dev/null | grep -q 'LG-77.0' \
  && ok || bad "...and must name the child that could not be resolved: $(cat "$B/decompose-run.txt" 2>/dev/null)"
grep -qF 'https://ar.example/api-accounting-board/tickets/77/move' "$T/curl-calls.txt" \
  && ok || bad "the park POST must go to <API base><fleet.conf column 4>/tickets/77/move — the same URL the success tail uses. Got:
$(cat "$T/curl-calls.txt")"
grep -q '/api/board/' "$T/curl-calls.txt" \
  && bad "no request may go to the hardcoded default prefix on a board served elsewhere:
$(cat "$T/curl-calls.txt")" || ok
grep -q 'parked in_progress after a FAILED re-map' "$B/pipeline.log" 2>/dev/null \
  && ok || bad "the record must say the parent was parked, or an operator cannot tell this from an unparked parent: $(cat "$B/pipeline.log" 2>/dev/null)"
grep -q 'tok_fixture_1340' "$B/pipeline.log" 2>/dev/null \
  && bad "the API token must never reach pipeline.log" || ok

# ════════════════════════════════════════════════════════════════════════════
# 3. NO RESOLVABLE BOARD BASE: NO CURL, ONE WARN
# fc_board_base fails closed — an empty base concatenated into a URL is a
# request to the wrong host, not an error anyone sees. The arm must say so out
# loud, because the parent really is left claimable (D13).
# ════════════════════════════════════════════════════════════════════════════
printf '%s' "$ENV_TOKEN_ONLY" > "$H/env/ledger-os.env"
RC=$(run)
[ "$RC" = 1 ] \
  && ok || bad "a split with no readable board base still fails (rc=$RC)"
grep -q '/move' "$T/curl-calls.txt" \
  && bad "with no resolvable base there is no host to POST to — nothing may be sent:
$(cat "$T/curl-calls.txt")" || ok
grep -q 'WARN: could not park the parent after a failed re-map' "$B/pipeline.log" 2>/dev/null \
  && ok || bad "a parent that could NOT be parked must say so — silence reads exactly like a successful park: $(cat "$B/pipeline.log" 2>/dev/null)"
printf '%s' "$ENV_FULL" > "$H/env/ledger-os.env"

# ════════════════════════════════════════════════════════════════════════════
# 4. THE LIBRARY UNDER `set -u` WITH MAXL/MAXF UNSET
# bin/lib/fc-issues.sh:51-53 promises a direct caller cannot be killed on an
# unset name. The parent split comment broke that promise, and it is composed
# AFTER every `gh issue create` has run — so the children exist and the thread
# never gets the comment that explains them.
# ════════════════════════════════════════════════════════════════════════════
if [ -s "$FIX/two-plain/children.json" ]; then
  ok
  B4="$T/b4"; scratch_rm "$B4"; mkdir -p "$B4"
  cp "$FIX/two-plain/children.json" "$B4/children.json"
  printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300; files=18>12\nSIZE_VERDICT: over\n' > "$B4/size-gate.txt"
  OUT=$( env -u MAXL -u MAXF HARNESS="$H" FLEET_CONF="$H/fleet.conf" DECOMPOSE_DRY_RUN=1 \
           bash -c 'set -u; . "$1"; file_children "$2" "$3" "$4" "$5" "$5/children.json" --kind decompose' \
           _ "$LIB" scoutish 552 TK-552 "$B4" 2>&1 ); RC4=$?
  [ "$RC4" -eq 0 ] \
    && ok || bad "file_children under \`set -u\` with MAXL/MAXF unset must not die (rc=$RC4): $OUT"
  grep -qF 'against a budget of 300 lines of product code across 12 files' "$B4/decompose-comment.md" 2>/dev/null \
    && ok || bad "the parent comment must carry the same defaults _fc_num uses (300 lines / 12 files): $(cat "$B4/decompose-comment.md" 2>/dev/null)"
else
  bad "fixture tests/fixtures/fc-issues/two-plain/children.json is missing — the §4 drive did not run"
  bad "(the set -u assertion was never taken)"
fi

echo "run-decompose.bh-1340: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
