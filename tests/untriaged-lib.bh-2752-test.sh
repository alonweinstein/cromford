#!/bin/bash
# tests/untriaged-lib.bh-2752-test.sh — bin/lib/untriaged-lib.sh, the shared
# read layer of the BH-2751 untriaged lanes: ut_gh_projects (which projects are
# GitHub-Issues boards) and ut_open_issues (their open ai-build issues).
#
# The row that matters most is the negative one: a declined read (403, 429 on
# page 2, a dead gh) must print NOTHING and return 1, never `[]`. A lane that
# reads a failed fetch as an empty board goes quiet about every ticket on it.
#
# Nothing here touches the network: `gh` is a stub on PATH that replays queued
# fixtures, so the REAL gh_rest and gh_rest_issue_list run underneath.
#
# Run from anywhere: bash tests/untriaged-lib.bh-2752-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/untriaged-lib.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/tmp" "$T/bin" "$T/fx"
export TMPDIR="$T/tmp"
export PATH="$T/bin:$PATH"
export GH_STUB_DIR="$T"
export GH_ETAG=0

cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
D="$GH_STUB_DIR"
printf '%s\n' "$*" >> "$D/gh-calls.txt"
f=$(find "$D/fx" -maxdepth 1 -type f -name '[0-9][0-9]' 2>/dev/null | sort | head -1)
[ -n "$f" ] || exit 1
cat "$f"
rm -f "$f"
exit 0
STUB
chmod +x "$T/bin/gh"

FXN=0
fx() {  # fx <status> <body>
  FXN=$((FXN+1))
  printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2" > "$(printf '%s/fx/%02d' "$T" "$FXN")"
}
reset() { rm -f "$T"/fx/* "$T/out" 2>/dev/null; FXN=0; : > "$T/gh-calls.txt"; }
page() { # page <n> <first> [pr]
  jq -nc --argjson n "$1" --argjson f "$2" --arg pr "${3:-}" \
    '[range($n) | {number: (. + $f), title: "t", body: "b", comments: 0,
       created_at: "2026-09-26T00:00:00Z", user: {login: "x"}, labels: []}
      | if $pr == "pr" then . + {pull_request:{url:"u"}} else . end]'
}
rows() { jq -r 'length' "$T/out" 2>/dev/null || echo "-"; }
pages_asked() { grep -c 'page=' "$T/gh-calls.txt" 2>/dev/null || echo 0; }

# ══ 0. sourcing is silent, set -u safe, and declares both functions ═════════
SRC=$(bash -c 'set -u; . "$1" 2>&1; echo "rc=$?"; declare -F ut_gh_projects ut_open_issues' _ "$LIB")
[ "$SRC" = "rc=0
ut_gh_projects
ut_open_issues" ] && ok || bad "0: sourcing must be silent and declare both functions, got: $SRC"

# shellcheck source=bin/lib/untriaged-lib.sh
. "$LIB" || { echo "cannot source $LIB"; exit 2; }
declare -F ut_gh_projects >/dev/null || { echo "FAIL: ut_gh_projects not defined"; exit 1; }

# ══ 1. only `-` rows, comments and blanks skipped, default path honoured ════
cat > "$T/h/fleet.conf" <<'EOF'
# project repo prod board-prefix offset
gh-proj Owner/gh-repo - - 3 box-small

app-proj Owner/app-repo https://app.example /api/board 1 box
  # old-proj Owner/old-repo - - 2
EOF
RC=0; OUT=$(ut_gh_projects "$T/h/fleet.conf") || RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "gh-proj Owner/gh-repo" ] && ok || bad "1: explicit conf: rc=$RC out='$OUT'"
RC=0; OUT=$(ut_gh_projects) || RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "gh-proj Owner/gh-repo" ] && ok || bad "1: default \$HARNESS/fleet.conf: rc=$RC out='$OUT'"

# ══ 2. the real fleet.conf agrees with bin/fleet-conf.sh ════════════════════
WANT=$(comm -23 <(FLEET_CONF="$DIR/fleet.conf" bash "$DIR/bin/fleet-conf.sh" --projects | sort -u) \
                <(FLEET_CONF="$DIR/fleet.conf" bash "$DIR/bin/fleet-conf.sh" --projects-with-board | sort -u))
GOT=$(ut_gh_projects "$DIR/fleet.conf" | awk '{print $1}' | sort -u)
[ -n "$GOT" ] && [ "$GOT" = "$WANT" ] && ok || bad "2: real fleet.conf: got '$GOT' want '$WANT'"

# ══ 3. a missing registry is not "no GitHub boards" ═════════════════════════
RC=0; OUT=$(ut_gh_projects "$T/nope.conf") || RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "3: missing conf must be rc 1 and silent: rc=$RC out='$OUT'"

# ══ 4. two pages, one PR: one compact array, PR gone, exact keys ════════════
reset
fx 200 "$(jq -nc --argjson a "$(page 99 1)" --argjson b "$(page 1 500 pr)" '$a + $b')"
fx 200 "$(page 3 101)"
RC=0; ut_open_issues o/r > "$T/out" || RC=$?
[ "$RC" = 0 ] && ok || bad "4: two-page read must be rc 0, got $RC"
[ "$(rows)" = 102 ] && ok || bad "4: 102 rows expected, got $(rows)"
[ "$(jq '[.[].number] | index(500)' "$T/out")" = null ] && ok || bad "4: the PR must be dropped"
[ "$(jq -c '[.[] | keys] | unique' "$T/out")" = '[["body","comments","created_at","number","title"]]' ] && ok \
  || bad "4: key set wrong: $(jq -c '[.[] | keys] | unique' "$T/out")"
[ "$(wc -l < "$T/out")" = 1 ] && ok || bad "4: output must be one line"
for a in labels=ai-build state=open page=1 page=2 'repos/o/r/issues'; do
  grep -q "$a" "$T/gh-calls.txt" && ok || bad "4: request must carry $a: $(cat "$T/gh-calls.txt")"
done
[ "$UT_OPEN_ISSUES_CAPPED" = 0 ] && ok || bad "4: an uncapped read must say CAPPED=0"

# ══ 5. 403 rate limit: nothing, rc 1, status visible to the caller ══════════
reset
fx 403 '{"message":"API rate limit exceeded for installation."}'
RC=0; ut_open_issues o/r > "$T/out" || RC=$?
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && ok || bad "5: 403 must be rc 1 and silent: rc=$RC out=$(cat "$T/out")"
[ "${GH_REST_STATUS:-}" = 403 ] && ok || bad "5: GH_REST_STATUS must be 403 in the caller, got '${GH_REST_STATUS:-}'"

# ══ 6. page 2 answers 429: no partial list ══════════════════════════════════
reset
fx 200 "$(page 100 1)"
fx 429 '{"message":"API rate limit exceeded"}'
RC=0; ut_open_issues o/r > "$T/out" || RC=$?
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && ok || bad "6: a 429 on page 2 must be rc 1 and silent: rc=$RC rows=$(rows)"

# ══ 7. dead gh (the exit-75 path) ═══════════════════════════════════════════
reset
RC=0; ut_open_issues o/r > "$T/out" || RC=$?
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && ok || bad "7: a dead gh must be rc 1 and silent: rc=$RC out=$(cat "$T/out")"

# ══ 8. an empty board is a fact ═════════════════════════════════════════════
reset
fx 200 '[]'
RC=0; ut_open_issues o/r > "$T/out" || RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "[]" ] && ok || bad "8: empty board must be [] rc 0: rc=$RC out='$(cat "$T/out")'"

# ══ 9. bad arguments never reach the network ════════════════════════════════
for args in "nope" "o/r 0" "o/r x" "o/r -1" ""; do
  reset
  # shellcheck disable=SC2086
  RC=0; ut_open_issues $args > "$T/out" 2>&1 || RC=$?
  [ "$RC" = 1 ] && [ ! -s "$T/out" ] && [ ! -s "$T/gh-calls.txt" ] && ok \
    || bad "9: '$args' must be rc 1, silent, no gh call: rc=$RC out=$(cat "$T/out") calls=$(cat "$T/gh-calls.txt")"
done

# ══ 10. the cap is flagged, and stops the paging ════════════════════════════
reset
fx 200 "$(page 100 1)"
fx 200 "$(page 100 101)"
RC=0; ut_open_issues o/r 1 > "$T/out" || RC=$?
[ "$RC" = 0 ] && [ "$(rows)" = 100 ] && ok || bad "10: max_pages=1 must be rc 0 with 100 rows: rc=$RC rows=$(rows)"
[ "$UT_OPEN_ISSUES_CAPPED" = 1 ] && ok || bad "10: a capped read must set UT_OPEN_ISSUES_CAPPED=1"
[ "$(pages_asked)" = 1 ] && ok || bad "10: exactly one page must be asked for, asked $(pages_asked)"

# ══ 11. hygiene ═════════════════════════════════════════════════════════════
LEFT=$(find "$TMPDIR" -maxdepth 1 \( -name 'gh-rest.*' -o -name 'ut.*' \) | wc -l)
[ "$LEFT" = 0 ] && ok || bad "11: no temp files may be left behind: $(ls "$TMPDIR")"

echo "untriaged-lib: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
